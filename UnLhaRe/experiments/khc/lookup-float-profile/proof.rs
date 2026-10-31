//! 凍結referenceのprivate Proof(Debug)を全14値の型付きprojectionへ厳密に読む。
use crate::Result;
use std::collections::BTreeMap;
#[derive(Clone,Debug,PartialEq,Eq)]
pub struct Proof14 {
    pub runs:usize,pub primary:usize,pub alphabet:usize,pub payload:usize,pub plain_crc:u32,pub payload_crc:u32,
    pub rank:usize,pub length:usize,pub escape:usize,pub grammar:u64,pub base_pool:u64,
    pub branches:[u64;2],pub classes:[u32;6],pub cdf_bits:u64,
}
fn unsigned<T:std::str::FromStr>(value:&str)->Result<T>{
    if value.is_empty()||!value.bytes().all(|c|c.is_ascii_digit()){return Err("Proof14 unsigned grammar".into());}
    value.parse().map_err(|_|"Proof14 numeric range".into())
}
fn scalar<T:std::str::FromStr>(fields:&mut BTreeMap<&str,&str>,name:&str)->Result<T>{unsigned(fields.remove(name).ok_or_else(||format!("Proof14 missing {name}"))?)}
fn array<T:std::str::FromStr,const N:usize>(fields:&mut BTreeMap<&str,&str>,name:&str)->Result<[T;N]>{
    let v=fields.remove(name).ok_or_else(||format!("Proof14 missing {name}"))?;
    let v=v.strip_prefix('[').and_then(|s|s.strip_suffix(']')).ok_or("Proof14 array brackets")?;
    let values=v.split(',').map(|s|unsigned(s.trim())).collect::<Result<Vec<T>>>()?;
    values.try_into().map_err(|_|"Proof14 array length".into())
}
impl Proof14 {
    pub fn frozen_debug(text:&str)->Result<Self>{
        let body=text.strip_prefix("Proof { ").and_then(|s|s.strip_suffix(" }" )).ok_or("Proof14 Debug wrapper")?;
        let mut fields=BTreeMap::new();let mut start=0;let mut nesting=0u8;
        for (i,c) in body.char_indices().chain(std::iter::once((body.len(),','))) {
            match c {'['=>{if nesting!=0{return Err("Proof14 nested array".into());}nesting=1;},']'=>{if nesting!=1{return Err("Proof14 unbalanced array".into());}nesting=0;},',' if nesting==0=>{
                let field=body[start..i].trim();let (name,value)=field.split_once(": ").ok_or("Proof14 field separator")?;
                if fields.insert(name,value).is_some(){return Err("Proof14 duplicate field".into());}start=i+1;
            },_=>{}}
        }
        if nesting!=0||fields.len()!=14{return Err("Proof14 field count/brackets".into());}
        let p=Self {runs:scalar(&mut fields,"runs")?,primary:scalar(&mut fields,"primary")?,alphabet:scalar(&mut fields,"alphabet")?,payload:scalar(&mut fields,"payload")?,
            plain_crc:scalar(&mut fields,"plain_crc")?,payload_crc:scalar(&mut fields,"payload_crc")?,rank:scalar(&mut fields,"rank")?,length:scalar(&mut fields,"length")?,escape:scalar(&mut fields,"escape")?,
            grammar:scalar(&mut fields,"grammar")?,base_pool:scalar(&mut fields,"base_pool")?,branches:array(&mut fields,"branches")?,classes:array(&mut fields,"classes")?,cdf_bits:scalar(&mut fields,"cdf_bits")?};
        if !fields.is_empty(){return Err("Proof14 unknown fields".into());}Ok(p)
    }
    pub fn json(&self)->String {format!("{{\"runs\":{},\"primary\":{},\"alphabet\":{},\"payload\":{},\"plain_crc\":{},\"payload_crc\":{},\"rank\":{},\"length\":{},\"escape\":{},\"grammar\":{},\"base_pool\":{},\"branches\":{:?},\"classes\":{:?},\"cdf_bits\":{}}}",self.runs,self.primary,self.alphabet,self.payload,self.plain_crc,self.payload_crc,self.rank,self.length,self.escape,self.grammar,self.base_pool,self.branches,self.classes,self.cdf_bits)}
}
