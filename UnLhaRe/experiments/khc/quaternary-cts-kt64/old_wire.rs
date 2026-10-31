//! next-use rank/run lengthをmulti-symbol intervalへまとめる別研究形式。
//! KHQCIP01 / private 5feature integer CTS / 正準packed alphabet / integer CDF。
//! 製品wireや旧研究形式との互換性は主張しない。
#![allow(dead_code)]
#[path="model.rs"] mod model;

use crate::{fixed_math,integer_pool,pow2_cts as integer_cts,bwt,packed_alphabet,multi_range};
use bwt::bwt;
use multi_range::{Encoder,Decoder};
use model::{Model,exponent,digest};
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::Path;
const MAX_INPUT: usize = 8 * 1024 * 1024;
const MAX_PAYLOAD: usize = 1 << 20;
const MAX_FRAME: usize = MAX_PAYLOAD + 281;
const MAGIC: &[u8; 8] = b"KHQCIP01";
type Result<T> = std::result::Result<T, String>;
fn payload_limit(n: usize) -> Result<usize> {
    if n == 0 || n > MAX_INPUT + 1 { return Err("transform length outside bounds".into()); }
    Ok(n.checked_mul(32).and_then(|n| n.checked_add(6)).ok_or("payload bound overflow")?.min(MAX_PAYLOAD))
}

fn filled<T: Clone>(length: usize, value: T) -> Result<Vec<T>> {
    let mut v = Vec::new();
    v.try_reserve_exact(length)
        .map_err(|_| "allocation failed")?;
    v.resize(length, value);
    Ok(v)
}

fn crc_table() -> [u32; 256] {
    std::array::from_fn(|i| {
        let mut c = i as u32;
        for _ in 0..8 {
            c = (c >> 1) ^ if c & 1 != 0 { 0xedb8_8320 } else { 0 };
        }
        c
    })
}

fn crc_parts(parts: &[&[u8]]) -> u32 {
    let table = crc_table();
    let mut c = u32::MAX;
    for part in parts {
        for &b in *part {
            c = (c >> 8) ^ table[((c as u8) ^ b) as usize];
        }
    }
    !c
}

fn read_bounded(path: &Path, limit: usize) -> Result<Vec<u8>> {
    let f = File::open(path).map_err(|e| format!("input open: {e}"))?;
    let meta = f.metadata().map_err(|e| format!("input metadata: {e}"))?;
    if !meta.is_file() || meta.len() > limit as u64 {
        return Err("input is not a regular file within limit".into());
    }
    let mut bytes = Vec::new();
    bytes
        .try_reserve_exact(meta.len() as usize)
        .map_err(|_| "input allocation failed")?;
    f.take(limit as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| format!("input read: {e}"))?;
    if bytes.len() > limit {
        return Err("input exceeds limit".into());
    }
    Ok(bytes)
}

fn publish(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut f = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|e| format!("output create_new: {e}"))?;
    if let Err(e) = f.write_all(bytes).and_then(|()| f.sync_all()) {
        drop(f);
        // 今回create_newで作った出力だけを、I/O失敗時に清掃する。
        let _ = std::fs::remove_file(path);
        return Err(format!("output write: {e}"));
    }
    Ok(())
}

fn inverse_bwt(last: &[u16], primary: usize, alphabet: &[u16]) -> Result<Vec<u8>> {
    let n = last.len();
    if primary >= n || last[primary] != 0 {
        return Err("invalid primary sentinel".into());
    }
    let mut counts = [0_usize; 257];
    for &s in last {
        if s > 256 {
            return Err("BWT symbol out of range".into());
        }
        counts[s as usize] += 1;
    }
    if counts[0] != 1 {
        return Err("sentinel count".into());
    }
    let mut seen = [false; 257];
    for &s in alphabet {
        seen[s as usize] = true;
    }
    for (i, &c) in counts.iter().enumerate() {
        if (c != 0) != seen[i] {
            return Err("alphabet mismatch".into());
        }
    }
    let mut starts = [0_usize; 257];
    let mut total = 0;
    for (i, &c) in counts.iter().enumerate() {
        starts[i] = total;
        total += c;
    }
    let mut occurrence = [0_usize; 257];
    let mut lf = filled(n, 0_usize)?;
    for (i, &s) in last.iter().enumerate() {
        let s = s as usize;
        lf[i] = starts[s] + occurrence[s];
        occurrence[s] += 1;
    }
    let mut visited = filled(n, false)?;
    let mut text = filled(n, 0_u16)?;
    let mut row = primary;
    for out in text.iter_mut().rev() {
        if row >= n || visited[row] {
            return Err("LF cycle inconsistent".into());
        }
        visited[row] = true;
        *out = last[row];
        row = lf[row];
    }
    if row != primary
        || !visited.iter().all(|&v| v)
        || text[n - 1] != 0
        || text[..n - 1].contains(&0)
    {
        return Err("LF cycle/sentinel inconsistent".into());
    }
    let mut result = filled(n - 1, 0_u8)?;
    for (out, &s) in result.iter_mut().zip(&text) {
        *out = (s - 1) as u8;
    }
    Ok(result)
}


#[derive(Clone,Copy)]
struct TokenAudit {rank_intervals:usize,length_intervals:usize,escape_bytes:usize,grammar:u64,state_digest:u64,branches:[u64;2],class_observations:[u32;6],cdf_entropy:f64}
impl Default for TokenAudit {fn default()->Self{Self{rank_intervals:0,length_intervals:0,escape_bytes:0,grammar:0xcbf29ce484222325,state_digest:0,branches:[0;2],class_observations:[0;6],cdf_entropy:0.0}}}
enum Coder<'a> {Encode(Encoder),Decode(Decoder<'a>)}
struct Stream<'a> {coder:Coder<'a>,model:Model,previous_rank:[usize;257],previous:[(usize,usize);257],recent:u32,audit:TokenAudit}
impl<'a> Stream<'a>{
    fn new(coder:Coder<'a>)->Result<Self>{Ok(Self{coder,model:Model::new()?,previous_rank:[0;257],previous:[(0,0);257],recent:0,audit:TokenAudit::default()})}
    fn token(&mut self,component:usize,context:usize,symbol:u16,desired:usize,limit:usize)->Result<usize>{
        let mut node=0;let token;loop{
            let prefix=self.model.trees[component].prefix(node,limit)?;
            let prediction=self.model.predict(component,context,node,usize::from(symbol),self.recent,self.previous[usize::from(symbol)],prefix)?;
            let child=match &mut self.coder {
                Coder::Encode(e)=>{let j=self.model.trees[component].known_child(node,desired,limit)?;let(c,f,t)=prediction.interval(j)?;e.interval(c,f,t)?;j}
                Coder::Decode(d)=>{let j=prediction.select(d.slot(32768)?)?;let(c,f,t)=prediction.interval(j)?;d.consume(c,f,t)?;j}
            };
            let edge=self.model.trees[component].edge(node,child,prefix)?;
            self.model.observe(&prediction,child)?;
            if let Some(next)=edge.node {node=next}else{token=edge.lo;break;}
        }
        let key=if component==0{usize::from(symbol)*4+self.previous_rank[usize::from(symbol)].min(3)}else{usize::from(symbol)*9+context};
        for value in [component,key,token,limit]{digest(&mut self.audit.grammar,value);}Ok(token)
    }
    fn rank(&mut self,symbol:u16,desired:usize,active:usize)->Result<usize>{let rank=self.token(0,0,symbol,desired,active)?;self.audit.rank_intervals+=1;Ok(rank)}
    fn byte(&mut self,desired:u8)->Result<u8>{
        let byte=match &mut self.coder {Coder::Encode(e)=>{e.interval(u32::from(desired),1,256)?;desired},Coder::Decode(d)=>{let b=d.slot(256)?;d.consume(b,1,256)?;u8::try_from(b).map_err(|_|"uniform byte outside bounds")?}};
        self.audit.escape_bytes+=1;Ok(byte)
    }
    fn length(&mut self,symbol:u16,desired:usize,rank:usize,remaining:usize)->Result<usize>{
        if remaining==0{return Err("no remaining transform symbols".into());}
        if matches!(self.coder,Coder::Encode(_))&&(desired==0||desired>remaining){return Err("run length outside remaining bound".into());}
        let token=self.token(1,exponent(rank+1),symbol,desired.saturating_sub(1).min(255),remaining.min(256))?;self.audit.length_intervals+=1;
        if token<255{return Ok(token+1);}
        if matches!(self.coder,Coder::Encode(_)){
            let mut value=u32::try_from(desired-256).map_err(|_|"length escape overflow")?;let mut groups=0;
            loop{groups+=1;if groups>4{return Err("length escape exceeds four bytes".into());}let mut b=(value&127) as u8;value>>=7;if value!=0{b|=128;}self.byte(b)?;if value==0{break;}}
            Ok(desired)
        }else{
            let mut value=0u32;for index in 0..4{let b=self.byte(0)?;let group=u32::from(b&127);value|=group<<(index*7);
                if b&128==0 {if index!=0&&group==0{return Err("noncanonical length escape".into());}let length=(value as usize).checked_add(256).ok_or("length escape overflow")?;if length>remaining{return Err("run length outside remaining bound".into());}return Ok(length);}}
            Err("length escape exceeds four bytes".into())
        }
    }
    fn run_done(&mut self,symbol:u16,rank:usize,length:usize){
        self.previous_rank[usize::from(symbol)]=rank;self.previous[usize::from(symbol)]=(exponent(rank.saturating_sub(1)),exponent(length-1));
        let class=match length{1=>0,2=>1,3..=4=>2,_=>3};self.recent=((self.recent<<4)|rank.min(3) as u32|class<<2)&0xffff;
    }
    fn finish_audit(&mut self)->TokenAudit{self.audit.state_digest=self.model.state_digest();self.audit.branches=self.model.audit.branches;self.audit.class_observations=self.model.class_observations();self.audit.cdf_entropy=self.model.audit.entropy();self.audit}
}

#[derive(Clone, Copy)]
struct Run { symbol: u16, length: u32, next: u32 }
const _: () = assert!(std::mem::size_of::<Run>() == 12);

fn encode_payload(last: &[u16]) -> Result<(Vec<u8>, Vec<u16>, usize, TokenAudit)> {
    let limit = payload_limit(last.len())?;
    let run_count = last.iter().enumerate()
        .filter(|&(i, symbol)| i == 0 || last[i - 1] != *symbol).count();
    let mut runs: Vec<Run> = Vec::new();
    runs.try_reserve_exact(run_count).map_err(|_| "run allocation failed")?;
    for &symbol in last {
        if let Some(run) = runs.last_mut().filter(|run| run.symbol == symbol) {
            run.length = run.length.checked_add(1).ok_or("run length overflow")?;
        } else { runs.push(Run { symbol, length: 1, next: u32::MAX }); }
    }
    let mut next = [u32::MAX; 257];
    for (index, run) in runs.iter_mut().enumerate().rev() {
        run.next = next[usize::from(run.symbol)];
        next[usize::from(run.symbol)] = u32::try_from(index).map_err(|_| "run index overflow")?;
    }
    let mut alphabet = Vec::new();
    alphabet.try_reserve_exact(257).map_err(|_| "alphabet allocation failed")?;
    for run in &runs { if !alphabet.contains(&run.symbol) { alphabet.push(run.symbol); } }
    let mut active = filled(alphabet.len(), 0u16)?;
    active.copy_from_slice(&alphabet);
    let mut stream = Stream::new(Coder::Encode(Encoder::with_limit(limit)?))?;
    let mut consumed = 0usize;
    for (index, run) in runs.iter().enumerate() {
        if active.first() != Some(&run.symbol) || next[usize::from(run.symbol)] as usize != index {
            return Err("next-use head inconsistent".into());
        }
        let symbol = active.remove(0);
        next[usize::from(symbol)] = run.next;
        let rank = if run.next == u32::MAX { 0 } else {
            let rank = active.iter().position(|&s| next[usize::from(s)] > run.next).unwrap_or(active.len());
            if rank == 0 { return Err("adjacent run symbol".into()); }
            rank
        };
        stream.rank(symbol, rank, active.len() + 1)?;
        let length = run.length as usize;
        stream.length(symbol, length, rank, last.len() - consumed)?;
        consumed = consumed.checked_add(length).ok_or("run sum overflow")?;
        stream.run_done(symbol, rank, length);
        if rank != 0 { active.insert(rank, symbol); }
    }
    if !active.is_empty() || consumed != last.len() { return Err("remaining next-use symbols".into()); }
    let audit=stream.finish_audit();
    let Coder::Encode(encoder) = stream.coder else { unreachable!() };
    Ok((encoder.finish()?, alphabet, runs.len(), audit))
}

fn decode_payload(payload: &[u8], alphabet: &[u16], n: usize) -> Result<(Vec<u16>, usize, TokenAudit)> {
    payload_limit(n)?;
    let mut active = filled(alphabet.len(), 0u16)?;
    active.copy_from_slice(alphabet);
    let mut last = Vec::new();
    last.try_reserve_exact(n).map_err(|_| "BWT allocation failed")?;
    let mut stream = Stream::new(Coder::Decode(Decoder::new(payload)?))?;
    let mut runs = 0usize;
    while last.len() < n {
        let symbol = *active.first().ok_or("active list exhausted before declared length")?;
        let rank = stream.rank(symbol, 0, active.len())?;
        let length = stream.length(symbol, 1, rank, n - last.len())?;
        if last.last() == Some(&symbol) { return Err("non-maximal adjacent run".into()); }
        let end = last.len().checked_add(length).ok_or("run sum overflow")?;
        if end > n { return Err("run length outside remaining bound".into()); }
        last.resize(end, symbol);
        active.remove(0);
        if rank != 0 { active.insert(rank, symbol); }
        stream.run_done(symbol, rank, length);
        runs += 1;
    }
    if !active.is_empty() { return Err("active list not empty at end".into()); }
    let audit=stream.finish_audit();
    let Coder::Decode(decoder) = stream.coder else { unreachable!() };
    decoder.finish()?;
    Ok((last, runs, audit))
}

fn field(frame: &[u8], offset: usize) -> usize {
    u32::from_le_bytes(frame[offset..offset + 4].try_into().unwrap()) as usize
}
struct Stats {
    runs: usize,
    primary: usize,
    alphabet: usize,
    payload: usize,
    plain_crc: u32,
    payload_crc: u32,
    tokens: TokenAudit,
}

fn encode(input: &[u8]) -> Result<(Vec<u8>, Stats)> {
    if input.len() > MAX_INPUT { return Err("input exceeds limit".into()); }
    let (last, primary) = bwt(input)?;
    let (payload, alphabet, runs, tokens) = encode_payload(&last)?;
    let plain_crc = crc_parts(&[input]);
    let payload_crc = crc_parts(&[&payload]);
    let metadata = packed_alphabet::encode(&alphabet)?;
    let header_len = 36_usize
        .checked_add(metadata.len())
        .ok_or("header overflow")?;
    let frame_len = header_len
        .checked_add(payload.len())
        .ok_or("frame overflow")?;
    let mut frame = Vec::new();
    frame
        .try_reserve_exact(frame_len)
        .map_err(|_| "frame allocation failed")?;
    frame.extend_from_slice(MAGIC);
    for value in [
        input.len(),
        primary,
        alphabet.len(),
        payload.len(),
        plain_crc as usize,
        payload_crc as usize,
        0,
    ] {
        frame.extend_from_slice(
            &u32::try_from(value)
                .map_err(|_| "frame field overflow")?
                .to_le_bytes(),
        );
    }
    frame.extend_from_slice(&metadata);
    let header_crc = crc_parts(&[&frame[..32], &frame[36..header_len]]);
    frame[32..36].copy_from_slice(&header_crc.to_le_bytes());
    frame.extend_from_slice(&payload);
    Ok((
        frame,
        Stats {
            runs,
            primary,
            alphabet: alphabet.len(),
            payload: payload.len(),
            plain_crc,
            payload_crc,
            tokens,
        },
    ))
}

fn decode(frame: &[u8]) -> Result<(Vec<u8>, Stats)> {
    if frame.len() < 36 || &frame[..8] != MAGIC {
        return Err("bad frame magic/header".into());
    }
    let length = field(frame, 8);
    let primary = field(frame, 12);
    let alphabet_len = field(frame, 16);
    let payload_len = field(frame, 20);
    let plain_crc = field(frame, 24) as u32;
    let payload_crc = field(frame, 28) as u32;
    if length > MAX_INPUT
        || primary > length
        || !(1..=257).contains(&alphabet_len)
        || !(5..=MAX_PAYLOAD).contains(&payload_len)
    {
        return Err("frame fields outside bounds".into());
    }
    if payload_len > payload_limit(length + 1)? { return Err("payload exceeds transformed bound".into()); }
    // payload長からmetadata境界を求め、凍結decoderで正準幅と順位を検査する。
    let header_len = frame
        .len()
        .checked_sub(payload_len)
        .ok_or("frame length mismatch")?;
    if !(69..=281).contains(&header_len) {
        return Err("packed header length outside bounds".into());
    }
    let full_len = header_len
        .checked_add(payload_len)
        .ok_or("frame overflow")?;
    if full_len != frame.len() {
        return Err("frame length mismatch".into());
    }
    if crc_parts(&[&frame[..32], &frame[36..header_len]]) != field(frame, 32) as u32 {
        return Err("header CRC mismatch".into());
    }
    let alphabet = packed_alphabet::decode(&frame[36..header_len])?;
    if alphabet.len() != alphabet_len {
        return Err("packed alphabet count mismatch".into());
    }
    let payload = &frame[header_len..];
    if crc_parts(&[payload]) != payload_crc {
        return Err("payload CRC mismatch".into());
    }
    let (last, runs, tokens) = decode_payload(
        payload,
        &alphabet,
        length.checked_add(1).ok_or("transform length overflow")?,
    )?;
    let plain = inverse_bwt(&last, primary, &alphabet)?;
    if plain.len() != length || crc_parts(&[&plain]) != plain_crc {
        return Err("plain length/CRC mismatch".into());
    }
    Ok((
        plain,
        Stats {
            runs,
            primary,
            alphabet: alphabet_len,
            payload: payload_len,
            plain_crc,
            payload_crc,
            tokens,
        },
    ))
}


fn stats_json(frame_len:usize,header_crc:usize,stats:&Stats)->String{
    let header=frame_len-stats.payload;
    format!("{{\"frame_bytes\":{frame_len},\"header_bytes\":{header},\"payload_bytes\":{},\"plain_crc\":{},\"payload_crc\":{},\"header_crc\":{header_crc},\"runs\":{},\"primary\":{},\"alphabet_symbols\":{},\"rank_intervals\":{},\"length_intervals\":{},\"escape_bytes\":{},\"branches\":{:?},\"grammar_digest\":\"{:016x}\",\"base_pool_digest\":\"{:016x}\",\"class_observations\":{:?},\"cdf_entropy_bits\":{:.9}}}",
        stats.payload,stats.plain_crc,stats.payload_crc,stats.runs,stats.primary,stats.alphabet,stats.tokens.rank_intervals,stats.tokens.length_intervals,stats.tokens.escape_bytes,stats.tokens.branches,stats.tokens.grammar,stats.tokens.state_digest,stats.tokens.class_observations,stats.tokens.cdf_entropy)
}
pub(crate) fn run_profile(input:&[u8])->crate::Result<crate::Encoded>{
    let begin=std::time::Instant::now();let result=encode(input);let elapsed_ns=u64::try_from(begin.elapsed().as_nanos()).map_err(|_|"encode timer overflow")?;
    let(frame,stats)=result?;let stats=stats_json(frame.len(),field(&frame,32),&stats);Ok(crate::Encoded{frame,stats,elapsed_ns})
}

