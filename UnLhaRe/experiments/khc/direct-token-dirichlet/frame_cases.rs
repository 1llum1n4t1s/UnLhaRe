//! 通常u128除算・独立実配列counts・手組みmetadataによるCLI forged frame。
#![allow(dead_code)]
#[path = "../direct-token/multi_range.rs"]
mod multi_range;
use std::{env,fs};
fn crc(bytes: &[u8]) -> u32 {
    let mut c = !0u32;
    for &b in bytes { c ^= u32::from(b); for _ in 0..8 { c = (c >> 1) ^ (0xedb88320u32 & 0u32.wrapping_sub(c & 1)); } }
    !c
}
fn payload(intervals: &[(u32,u32,u32)]) -> Vec<u8> {
    let mut e=multi_range::Encoder::with_limit(64).unwrap();
    for &(c,f,t) in intervals { e.interval(c,f,t).unwrap(); }
    e.finish().unwrap()
}
fn frame(n: u32, primary: u32, order: &[u16], p: &[u8]) -> Vec<u8> {
    assert!(order.len()<=2);
    let mut m=vec![0u8;33];
    for &s in order { m[usize::from(s)/8] |= 1 << (s%8); }
    if order.len()==2 { m.push(u8::from(order[0]>order[1])); }
    let mut v=b"KHNDR001".to_vec();
    for x in [n-1,primary,order.len() as u32,p.len() as u32,0,crc(p),0] { v.extend_from_slice(&x.to_le_bytes()); }
    v.extend_from_slice(&m); let mut h=v[..32].to_vec();h.extend_from_slice(&m);
    v[32..36].copy_from_slice(&crc(&h).to_le_bytes());v.extend_from_slice(p);v
}

// 候補のFenwick/逆数/model/codec encoderを使わず、各causal更新から累積を計算する。
struct Counts { root: Vec<u32>, local: std::collections::BTreeMap<usize,Vec<u32>> }
impl Counts {
    fn new(a:usize)->Self { Self{root:vec![1;a],local:Default::default()} }
    fn token(&mut self,key:usize,token:usize,limit:usize)->(u32,u32,u32) {
        let local=self.local.entry(key).or_insert_with(||vec![0;self.root.len()]);
        let d:u128=self.root.iter().map(|&x|u128::from(x)).sum();
        let t:u128=local.iter().map(|&x|u128::from(x)).sum();
        let c=|k:usize| {
            let r:u128=self.root[..k].iter().map(|&x|u128::from(x)).sum();
            let l:u128=local[..k].iter().map(|&x|u128::from(x)).sum();
            (k as u128+32768*(64*r+d*l)/(d*(64+t))) as u32
        };
        let low=c(token);let high=c(token+1);let total=c(limit);
        self.root[token]+=1;local[token]+=1;
        if self.root.iter().sum::<u32>()>=16384 {for v in &mut self.root{*v=(*v+1)/2;}}
        if local.iter().sum::<u32>()>=16384 {for v in local{*v=(*v+1)/2;}}
        (low,high-low,total)
    }
}
struct Tiny { ranks:Counts,lengths:Counts }
impl Tiny {
    fn new()->Self {Self{ranks:Counts::new(257),lengths:Counts::new(256)}}
    fn rank(&mut self,symbol:usize,token:usize,limit:usize)->(u32,u32,u32) {self.ranks.token(symbol*4,token,limit)}
    fn length(&mut self,symbol:usize,rank:usize,token:usize,remaining:usize)->(u32,u32,u32) {
        let context=(usize::BITS-1-(rank+1).leading_zeros()) as usize;
        self.lengths.token(symbol*9+context,token,remaining.min(256))
    }
}

fn make(name: &str) -> Vec<u8> {
    let mut tiny=Tiny::new();
    match name {
        "zeros255"|"zeros256"|"zeros257" => {
            let n: u32=name[5..].parse().unwrap();
            let mut i=vec![tiny.rank(1,0,2),tiny.length(1,0,n.saturating_sub(1).min(255) as usize,n as usize+1)];
            if n>=256 {i.push((n-256,1,256));}
            i.extend([tiny.rank(0,0,1),tiny.length(0,0,0,1)]);
            let mut v=frame(n+1,n,&[1,0],&payload(&i));
            v[24..28].copy_from_slice(&crc(&vec![0;n as usize]).to_le_bytes());
            let mut h=v[..32].to_vec();h.extend_from_slice(&v[36..70]);v[32..36].copy_from_slice(&crc(&h).to_le_bytes());v
        },
        "empty" => frame(1,0,&[0],&payload(&[tiny.rank(0,0,1),tiny.length(0,0,0,1)])),
        "early" => frame(2,0,&[0],&payload(&[tiny.rank(0,0,1),tiny.length(0,0,0,2)])),
        "remaining" => frame(1,0,&[1,0],&payload(&[tiny.rank(1,1,2),tiny.length(1,1,0,1)])),
        "noncanonical"|"unterminated"|"overflow" => {
            let b: &[u8]=match name { "noncanonical"=>&[128,0],"unterminated"=>&[128,128,128,128],_=>&[1] };
            let mut i=vec![tiny.rank(0,0,1),tiny.length(0,0,255,256)];
            i.extend(b.iter().map(|&b|(u32::from(b),1,256)));
            frame(256,0,&[0],&payload(&i))
        },
        "gap" => frame(1,0,&[0],&[0,255,255,255,255]),
        "terminal" => frame(1,0,&[0],&[0,0,0,0,1]),
        "trailing" => frame(1,0,&[0],&[0;6]),
        "sentinel" => frame(2,0,&[0],&payload(&[tiny.rank(0,0,1),tiny.length(0,0,1,2)])),
        "lf" => frame(2,0,&[0,1],&payload(&[tiny.rank(0,0,2),tiny.length(0,0,0,2),tiny.rank(1,0,1),tiny.length(1,0,0,1)])),
        "primary" => frame(2,1,&[0,1],&payload(&[tiny.rank(0,0,2),tiny.length(0,0,0,2),tiny.rank(1,0,1),tiny.length(1,0,0,1)])),
        "magic"|"header_crc"|"payload_crc"|"plain_crc"|"field"|"payload_bound"|"padding"|"metadata_count"|"metadata_rank"|"short_header"|"short_payload"|"prefix" => {
            let mut v=frame(1,0,&[0],&payload(&[tiny.rank(0,0,1),tiny.length(0,0,0,1)]));
            match name {
                "magic"=>v[0]^=1,"header_crc"=>v[32]^=1,"payload_crc"=>v[69]^=1,
                "plain_crc"=>v[24]=1,"field"=>v[12]=1,
                "payload_bound"=>v[20..24].copy_from_slice(&41u32.to_le_bytes()),
                "padding"=>v[68]|=2,"metadata_count"=>v[16]=2,
                "metadata_rank"=>{v[36]|=2;v.insert(69,2);v[16]=2;},
                "short_header"=>{v.truncate(31);return v},
                "short_payload"=>{v.pop();return v},
                "prefix"=>{v[69]=1;let c=crc(&v[69..]);v[28..32].copy_from_slice(&c.to_le_bytes());},
                _=>unreachable!(),
            }
            if !matches!(name,"magic"|"header_crc"|"payload_crc"|"payload_bound") {
                let end=v.len()-u32::from_le_bytes(v[20..24].try_into().unwrap()) as usize;
                if end>=36 {let mut h=v[..32].to_vec();h.extend_from_slice(&v[36..end]);v[32..36].copy_from_slice(&crc(&h).to_le_bytes());}
            }
            v
        },
        _=>panic!("unknown case"),
    }
}
fn main() {
    let a: Vec<_>=env::args().collect();
    if a.len()!=3 { eprintln!("usage: frame_cases case output");std::process::exit(2); }
    let v=make(&a[1]);
    let mut o=fs::OpenOptions::new().write(true).create_new(true).open(&a[2]).unwrap();
    use std::io::Write;o.write_all(&v).unwrap();
    println!("{{\"case\":\"{}\",\"bytes\":{}}}",a[1],v.len());
}
