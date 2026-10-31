//! 新規記述。既存validated model/range/packed APIを直接利用する自己完結frame。
use crate::{frontend,grammar,counts,model,paid_model,codebook,packet,multi_range,packed};
pub type Result<T>=std::result::Result<T,String>;
pub const MAX_INPUT:usize=1<<20;
pub const HEADER:usize=40;
pub const MAGIC:&[u8;8]=b"KHC1BLK\0";
pub const SCRATCH_BOUND:usize=32768;
#[derive(Default,Clone,Debug)]
pub struct Stats{pub method:u8,pub raw:usize,pub frame:usize,pub alphabet:usize,pub metadata:usize,pub payload:usize,pub bwt:usize,pub walks:usize,pub fits:usize,pub roots:usize,pub root_cdfs:usize,pub branches:usize,pub implicit:usize,pub escapes:usize,pub runs:usize,pub front_capacity:usize,pub dense_capacity:usize,pub hist_capacity:usize,pub fit_capacity:usize,pub packet_capacity:usize,pub forest_capacity:usize,pub parse_transient:usize,pub range_capacity_bound:usize,pub output_capacity:usize,pub inverse_capacity:usize,pub phase_capacity_bound:usize,pub scratch_capacity_bound:usize,pub stored_reason:&'static str}
pub fn crc32(bytes:&[u8])->u32{crc_parts(&[bytes])}
fn crc_parts(parts:&[&[u8]])->u32{let mut c=!0u32;for p in parts{for &b in *p{c^=u32::from(b);for _ in 0..8{c=(c>>1)^((0u32.wrapping_sub(c&1))&0xedb88320);}}}!c}
fn get32(b:&[u8],i:usize)->Result<usize>{Ok(u32::from_le_bytes(b.get(i..i+4).ok_or("header truncated")?.try_into().map_err(|_|"header u32")?) as usize)}
fn put32(b:&mut[u8],i:usize,v:usize)->Result<()>{b[i..i+4].copy_from_slice(&u32::try_from(v).map_err(|_|"header u32 overflow")?.to_le_bytes());Ok(())}
pub fn reseal(frame:&mut[u8])->Result<()>{if frame.len()<HEADER{return Err("header truncated".into());}let c=crc_parts(&[&frame[..36],&frame[40..]]);frame[36..40].copy_from_slice(&c.to_le_bytes());Ok(())}
fn allocate<T:Clone>(n:usize,v:T)->Result<Vec<T>>{let mut out=Vec::new();out.try_reserve_exact(n).map_err(|_|"frame allocation")?;out.resize(n,v);Ok(out)}
fn gate(s:&mut Stats,bound:usize)->Result<()>{s.phase_capacity_bound=s.phase_capacity_bound.max(bound);s.scratch_capacity_bound=SCRATCH_BOUND;if s.phase_capacity_bound>64*1024*1024{return Err("codec RAM bound".into());}Ok(())}
fn frame(raw:&[u8],primary:usize,alphabet:&[u16],metadata:&[u8],payload:&[u8],method:u8,s:&mut Stats)->Result<Vec<u8>>{
    let body=alphabet.len().checked_mul(2).and_then(|n|n.checked_add(metadata.len())).and_then(|n|n.checked_add(payload.len())).ok_or("frame length overflow")?;
    if (method==0 && body!=raw.len()) || (method==1 && body>=raw.len()){return Err("frame canonical size".into());}
    let mut out=allocate(HEADER.checked_add(body).ok_or("frame length overflow")?,0u8)?;out[..8].copy_from_slice(MAGIC);out[8..10].copy_from_slice(&1u16.to_le_bytes());out[10]=method;
    put32(&mut out,12,raw.len())?;put32(&mut out,16,primary)?;put32(&mut out,20,metadata.len())?;put32(&mut out,24,payload.len())?;out[28..30].copy_from_slice(&(alphabet.len() as u16).to_le_bytes());out[32..36].copy_from_slice(&crc32(raw).to_le_bytes());
    let mut at=HEADER;for &v in alphabet{out[at..at+2].copy_from_slice(&v.to_le_bytes());at+=2;}out[at..at+metadata.len()].copy_from_slice(metadata);at+=metadata.len();out[at..].copy_from_slice(payload);reseal(&mut out)?;
    s.method=method;s.raw=raw.len();s.frame=out.len();s.alphabet=alphabet.len()*2;s.metadata=metadata.len();s.payload=payload.len();s.output_capacity=out.capacity();Ok(out)
}
fn stored(raw:&[u8],mut s:Stats,reason:&'static str)->Result<(Vec<u8>,Stats)>{s.stored_reason=reason;let out=frame(raw,0,&[],&[],raw,0,&mut s)?;gate(&mut s,raw.len()+out.capacity()+SCRATCH_BOUND)?;Ok((out,s))}
fn encode_interval(enc:&mut multi_range::Encoder,f:[u16;4],k:usize,child:usize)->Result<()>{if child>=k{return Err("encode child".into());}let cumulative=f[..child].iter().map(|&v|u32::from(v)).sum();enc.interval(cumulative,u32::from(f[child]),32768).map_err(str::to_owned)}
fn escape_write(enc:&mut multi_range::Encoder,mut value:usize,s:&mut Stats)->Result<()>{loop{let mut b=(value&127) as u8;value>>=7;if value!=0{b|=128;}enc.interval(u32::from(b),1,256).map_err(str::to_owned)?;s.escapes+=1;if value==0{return Ok(());}}}
pub fn encode(raw:&[u8])->Result<(Vec<u8>,Stats)>{
    if raw.len()>MAX_INPUT{return Err("input exceeds block limit".into());}let mut s=Stats::default();s.raw=raw.len();
    // 最小packet241+alphabet4+range5=250B。raw<=250ではstrict利益なし。
    if raw.len()<=250{return stored(raw,s,"minimum body");}
    // SA-ISの幾何級数縮小workspaceとFront形成の保守的上界。入力1MiB限定。
    gate(&mut s,40*(raw.len()+1)+8*1024*1024+SCRATCH_BOUND)?;
    let front=frontend::Front::new(raw)?;s.bwt=1;s.front_capacity=front.runs.capacity()*12+std::mem::size_of::<frontend::Front>();s.runs=front.runs.len();
    let mut alphabet=[0u16;257];let mut seen=[false;257];let mut alphabet_len=0;for r in &front.runs{let symbol=r.symbol as usize;if symbol>256{return Err("front symbol".into());}if !seen[symbol]{seen[symbol]=true;alphabet[alphabet_len]=symbol as u16;alphabet_len+=1;}}
    let mut dense=counts::Dense::new()?;let trained=grammar::walk(&front,|c,n,_class,k,h,ch|{if k>1{dense.record(c,n,k,h,ch)?;}Ok(())})?;s.walks+=1;s.dense_capacity=dense.capacity_bytes();
    let book=codebook::Encoder::new(codebook::LENGTHS)?;let decoder=codebook::Decoder::new(codebook::LENGTHS)?;let codec_capacity=book.capacity_bytes()+decoder.capacity_bytes();let mut packet=packet::Packet::new(&book)?;
    for c in 0..2{for n in 0..142{let mut low=model::Hist::new()?;let mut high=model::Hist::new()?;for k in 2..=4{for h in 0..1024u16{let row=dense.row(c,n,k,h)?;crate::bundle::ingest(&mut low,k,h,row)?;crate::bundle::ingest(&mut high,k,model::reverse_history(h),row)?;}}
        s.hist_capacity=s.hist_capacity.max(low.capacity_bytes()+high.capacity_bytes());let l=paid_model::Fit::build(&low)?;let r=paid_model::Fit::build_high(&high)?;s.fits+=2;s.fit_capacity=s.fit_capacity.max(l.capacity_bytes()+r.capacity_bytes());let selected=paid_model::Selected::new(&l,&r)?;
        for k in 2..=4{let(bytes,bits)=selected.root_wire(k,&book)?;let d=paid_model::parse_root(&bytes,bits,k,&decoder)?;s.parse_transient=s.parse_transient.max(d.capacity_bytes()+bytes.capacity()+codec_capacity);
            for h in 0..1024u16{if d.lookup(0,k,h)?!=selected.lookup(0,k,h)?{return Err("frame root wire CDF".into());}s.root_cdfs+=1;}drop(d);drop(bytes);packet.append_root(&selected,k)?;s.roots+=1;}
    }}
    let metadata=packet.finish()?;s.packet_capacity=metadata.capacity();drop(dense);drop(book);drop(decoder);
    let model_bound=raw.len()+s.front_capacity+s.dense_capacity+s.hist_capacity+s.fit_capacity+s.packet_capacity+s.parse_transient+SCRATCH_BOUND+4*1024*1024;
    gate(&mut s,model_bound)?;
    let prefix=alphabet_len*2+metadata.len();if prefix.checked_add(5).ok_or("body length overflow")?>=raw.len(){drop(metadata);drop(front);return stored(raw,s,"metadata no benefit");}
    let forest=packet::Forest::parse(&metadata)?;s.forest_capacity=forest.capacity_bytes();s.parse_transient=s.parse_transient.max(forest.parse_dispatch_peak+forest.parse_reader_capacity);
    let limit=raw.len()-prefix-1;s.range_capacity_bound=limit;let mut enc=multi_range::Encoder::with_limit(limit).map_err(str::to_owned)?;let trees=[grammar::Tree::new(257),grammar::Tree::new(256)];let mut run=0;
    let encoded=grammar::walk(&front,|c,n,_class,k,h,ch|{s.branches+=1;if k==1{s.implicit+=1;}else{encode_interval(&mut enc,forest.lookup(c,n,k,h)?,k,ch)?;}
        if c==1 && trees[c].edge(n,ch,k)?.node.is_none(){let r=front.runs.get(run).ok_or("encode run")?;if r.length>=256{escape_write(&mut enc,r.length as usize-256,&mut s)?;}run+=1;}Ok(())});s.walks+=1;
    // 唯一許可するfallback error。allocation/model/state errorは伝播する。
    let encoded=match encoded{Ok(m)=>m,Err(e)if e=="range output limit"=>{drop(enc);drop(forest);drop(metadata);drop(front);return stored(raw,s,"range no benefit");},Err(e)=>return Err(e)};
    if encoded!=trained || run!=front.runs.len() || s.escapes!=trained.escapes{return Err("frame whole Meta encode equality".into());}
    let payload=match enc.finish(){Ok(p)=>p,Err("range output limit")=>{drop(forest);drop(metadata);drop(front);return stored(raw,s,"range finish no benefit");},Err(e)=>return Err(e.into())};s.range_capacity_bound=s.range_capacity_bound.max(payload.capacity());
    let encode_bound=raw.len()+s.front_capacity+s.dense_capacity+s.hist_capacity+s.fit_capacity+s.packet_capacity+s.forest_capacity+s.parse_transient+s.range_capacity_bound+HEADER+raw.len()+SCRATCH_BOUND+4*1024*1024;
    gate(&mut s,encode_bound)?;
    drop(forest);let out=frame(raw,front.primary,&alphabet[..alphabet_len],&metadata,&payload,1,&mut s)?;drop(front);drop(metadata);drop(payload);Ok((out,s))
}
fn decode_interval(dec:&mut multi_range::Decoder<'_>,f:[u16;4],k:usize)->Result<usize>{if f[..k].iter().any(|&v|v<2) || f[k..].iter().any(|&v|v!=0) || f.iter().map(|&v|u32::from(v)).sum::<u32>()!=32768{return Err("wire CDF support/total/tail".into());}let slot=dec.slot(32768).map_err(str::to_owned)?;let mut sum=0;for i in 0..k{let v=u32::from(f[i]);if slot<sum+v{dec.consume(sum,v,32768).map_err(str::to_owned)?;return Ok(i);}sum+=v;}Err("range CDF child".into())}
fn token(dec:&mut multi_range::Decoder<'_>,forest:&packet::Forest,tree:&grammar::Tree,c:usize,limit:usize,histories:&mut[u16;6],s:&mut Stats)->Result<usize>{let mut n=0;let mut depth=0;loop{depth+=1;if depth>16 || s.branches>16*(s.raw+1)*2{return Err("branch limit".into());}let k=tree.prefix(n,limit)?;let class=c*3+tree.class(n)?;let ch=if k==1{s.implicit+=1;0}else{decode_interval(dec,forest.lookup(c,n,k,histories[class])?,k)?};histories[class]=((histories[class]<<2)|ch as u16)&1023;s.branches+=1;let edge=tree.edge(n,ch,k)?;if let Some(next)=edge.node{n=next;}else{if edge.lo>=limit{return Err("decoded token limit".into());}return Ok(edge.lo);}}}
fn escape_read(dec:&mut multi_range::Decoder<'_>,remaining:usize,s:&mut Stats)->Result<usize>{let mut value=0usize;for i in 0..3{let b=dec.slot(256).map_err(str::to_owned)? as u8;dec.consume(u32::from(b),1,256).map_err(str::to_owned)?;s.escapes+=1;let part=usize::from(b&127);value=value.checked_add(part.checked_shl((7*i) as u32).ok_or("escape overflow")?).ok_or("escape overflow")?;if b&128==0{if i!=0 && part==0{return Err("noncanonical escape".into());}let length=value.checked_add(256).ok_or("escape overflow")?;if length>remaining{return Err("escape remaining".into());}return Ok(length);}}Err("escape length overflow".into())}
pub fn decode(bytes:&[u8])->Result<(Vec<u8>,Stats)>{
    if bytes.len()<HEADER{return Err("header truncated".into());}if &bytes[..8]!=MAGIC{return Err("frame magic".into());}if bytes[8..10]!=1u16.to_le_bytes(){return Err("frame revision".into());}let method=bytes[10];if method>1{return Err("frame method".into());}if bytes[11]!=0 || bytes[30..32]!=[0,0]{return Err("frame flags/reserved".into());}
    let raw=get32(bytes,12)?;if raw>MAX_INPUT{return Err("raw exceeds block limit".into());}let primary=get32(bytes,16)?;let model_len=get32(bytes,20)?;let payload_len=get32(bytes,24)?;let alphabet_len=u16::from_le_bytes(bytes[28..30].try_into().map_err(|_|"alphabet length")?) as usize;
    let body=alphabet_len.checked_mul(2).and_then(|n|n.checked_add(model_len)).and_then(|n|n.checked_add(payload_len)).ok_or("frame length overflow")?;
    if HEADER.checked_add(body).ok_or("frame length overflow")?!=bytes.len(){return Err("frame exact extent".into());}
    if (method==0 && (primary!=0 || model_len!=0 || alphabet_len!=0 || payload_len!=raw)) || (method==1 && (body>=raw || primary>=raw+1 || !(2..=257).contains(&alphabet_len) || !(241..=packet::MAX_BUNDLE_BYTES).contains(&model_len) || payload_len<5)){return Err("frame canonical fields".into());}
    if crc_parts(&[&bytes[..36],&bytes[40..]])!=get32(bytes,36)? as u32{return Err("wire CRC".into());}
    let mut s=Stats{method,raw,frame:bytes.len(),alphabet:alphabet_len*2,metadata:model_len,payload:payload_len,..Stats::default()};
    if method==0{let mut plain=allocate(raw,0u8)?;plain.copy_from_slice(&bytes[40..]);if crc32(&plain)!=get32(bytes,32)? as u32{return Err("plain CRC".into());}s.output_capacity=plain.capacity();gate(&mut s,bytes.len()+plain.capacity()+SCRATCH_BOUND)?;return Ok((plain,s));}
    let mut alphabet=[0u16;257];let mut active=[0u16;257];let mut seen=[false;257];for i in 0..alphabet_len{let off=40+i*2;let v=u16::from_le_bytes(bytes[off..off+2].try_into().map_err(|_|"alphabet field")?);if v>256 || seen[v as usize]{return Err("alphabet range/duplicate".into());}seen[v as usize]=true;alphabet[i]=v;active[i]=v;}if !seen[0]{return Err("alphabet sentinel absent".into());}
    let model_start=40+alphabet_len*2;let forest=packet::Forest::parse(&bytes[model_start..model_start+model_len])?;s.forest_capacity=forest.capacity_bytes();s.parse_transient=forest.parse_dispatch_peak+forest.parse_reader_capacity;let mut dec=multi_range::Decoder::new(&bytes[model_start+model_len..]).map_err(str::to_owned)?;
    let trees=[grammar::Tree::new(257),grammar::Tree::new(256)];let mut histories=[0u16;6];let mut remaining=raw+1;let mut active_len=alphabet_len;let mut last=allocate(raw+1,0u16)?;let mut written=0;let mut encountered=[false;257];let mut encounter_count=0;
    while remaining!=0{if active_len==0 || s.runs>raw{return Err("active/runs terminal".into());}let symbol=active[0];if !encountered[symbol as usize]{if alphabet[encounter_count]!=symbol{return Err("alphabet first occurrence order".into());}encountered[symbol as usize]=true;encounter_count+=1;}
        let rank=token(&mut dec,&forest,&trees[0],0,active_len,&mut histories,&mut s)?;let length_token=token(&mut dec,&forest,&trees[1],1,remaining.min(256),&mut histories,&mut s)?;let length=if length_token==255{escape_read(&mut dec,remaining,&mut s)?}else{length_token+1};if length>remaining || (symbol==0 && length!=1){return Err("run/sentinel length".into());}
        last[written..written+length].fill(symbol);written+=length;remaining-=length;s.runs+=1;
        active.copy_within(1..active_len,0);active_len-=1;if rank!=0{if rank>active_len{return Err("active insertion rank".into());}active.copy_within(rank..active_len,rank+1);active[rank]=symbol;active_len+=1;}
    }
    if active_len!=0 || encounter_count!=alphabet_len{return Err("active/alphabet terminal".into());}dec.finish().map_err(str::to_owned)?;drop(dec);drop(forest);
    let inverse=packed::inverse(&last,primary,&alphabet[..alphabet_len])?;if inverse.route!="packed23" || inverse.plain.len()!=raw{return Err("inverse route/length".into());}s.inverse_capacity=inverse.scratch_capacity_words*4;s.output_capacity=inverse.result_capacity;
    let decode_bound=bytes.len()+s.forest_capacity+s.parse_transient+last.capacity()*2+s.inverse_capacity+s.output_capacity+SCRATCH_BOUND+1048576;
    gate(&mut s,decode_bound)?;let plain=inverse.plain;if crc32(&plain)!=get32(bytes,32)? as u32{return Err("plain CRC".into());}Ok((plain,s))
}
