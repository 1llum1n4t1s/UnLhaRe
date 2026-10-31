use crate::{frontend::Front,histogram};
pub const EVENTS:usize=1778454;
#[derive(Clone,Copy,Debug)]
pub enum Family { Global,Symbol,Recent,Joint }
impl Family {
    pub fn name(self)->&'static str{match self{Self::Global=>"global",Self::Symbol=>"symbol",Self::Recent=>"recent",Self::Joint=>"joint"}}
    pub fn bits(self)->usize{match self{Self::Global=>5,Self::Symbol=>14,Self::Recent=>21,Self::Joint=>23}}
    pub fn key(self,c:usize,x:usize,s:usize,recent:u32,rank_exp:usize,length_exp:usize)->Result<u32,String>{
        if c>1 || x>8 || (c==0 && x!=0) || s>=257 || recent>65535 || rank_exp>7 || length_exp>23{return Err("feature range".into());}
        let global=((c as u32)<<4)|(x as u32);
        let value=match self{Self::Global=>global,Self::Symbol=>(global<<9)|s as u32,Self::Recent=>(global<<16)|recent,Self::Joint=>(global<<18)|((s as u32)<<9)|((rank_exp as u32)<<5)|length_exp as u32};
        if value>=1u32<<self.bits(){return Err("feature key width".into());}Ok(value)
    }
    pub fn component(self,key:u32)->Result<usize,String>{if key>=1u32<<self.bits(){return Err("stored key range".into());}let global=key>>(self.bits()-5);let c=(global>>4) as usize;let context=(global&15) as usize;if c>1 || context>8 || (c==0 && context!=0){return Err("stored context".into());}Ok(c)}
}
pub fn packed(key:u32,token:usize)->Result<u32,String>{if key>u32::MAX>>9 || token>=257{return Err("packed range".into());}key.checked_mul(512).and_then(|k|k.checked_add(token as u32)).ok_or("packed overflow".into())}
#[derive(Default,Debug)]
pub struct Meta {pub tokens:[u64;2],pub runs:usize,pub escapes:usize,pub grammar:u64,pub history_checks:u64}
pub fn walk(front:&Front,family:Family,mut event:impl FnMut(usize,u32,usize,usize,u32)->Result<(),String>)->Result<Meta,String>{
    let mut rank=[0usize;257];let mut bucket=[0usize;257];let mut exponents=[(0usize,0usize);257];let mut recent=0u32;let mut pending:Option<(usize,usize)>=None;
    let mut meta=Meta{grammar:0xcbf29ce484222325,..Meta::default()};
    meta.escapes=front.walk(|c,s,x,b,t,limit,old_rank|{
        if s>=257 || c>1 || rank[s]!=old_rank || (c==0 && b!=rank[s].min(3)) || (c==1 && b!=bucket[s]){return Err("new/frozen history mismatch".into());}
        let current_run=front.runs.get(meta.runs).ok_or("feature run index")?;
        if current_run.symbol as usize!=s{return Err("feature current symbol".into());}
        if c==0{if pending.is_some(){return Err("feature rank order".into());}pending=Some((s,t));}else{let Some((old_symbol,r))=pending else{return Err("feature length order".into());};if old_symbol!=s || x!=histogram::exponent(r+1) || t!=(current_run.length as usize-1).min(255){return Err("feature length/context".into());}}
        let key=family.key(c,x,s,recent,exponents[s].0,exponents[s].1)?;let combined=packed(key,t)?;event(c,key,t,limit,recent)?;
        if combined>>9!=key{return Err("packed key roundtrip".into());}
        let old_grammar_key=if c==0{s*4+old_rank.min(3)}else{s*9+x};for value in [c,old_grammar_key,t,limit]{meta.grammar=(meta.grammar^value as u64).wrapping_mul(0x100000001b3);}
        meta.tokens[c]=meta.tokens[c].checked_add(1).ok_or("feature count overflow")?;meta.history_checks=meta.history_checks.checked_add(1).ok_or("history count overflow")?;
        if c==1{let(_,r)=pending.take().ok_or("feature pending update")?;let length=current_run.length as usize;if length==0{return Err("feature zero length".into());}rank[s]=r;bucket[s]=histogram::length_bucket(length);exponents[s]=(histogram::exponent(r.saturating_sub(1)),histogram::exponent(length-1));recent=((recent<<4)|(r.min(3) as u32)|((bucket[s] as u32)<<2))&65535;meta.runs=meta.runs.checked_add(1).ok_or("feature runs overflow")?;}
        Ok(())
    })?;
    if pending.is_some() || meta.runs!=front.runs.len() || meta.tokens!=[meta.runs as u64;2]{return Err("feature terminal totals".into());}Ok(meta)
}
pub fn history_e2e()->Result<usize,String>{
    use crate::frontend::Run;
    let front=Front{runs:vec![Run{symbol:1,length:1,next:2},Run{symbol:2,length:2,next:4},Run{symbol:1,length:3,next:u32::MAX},Run{symbol:3,length:256,next:5},Run{symbol:2,length:1,next:u32::MAX},Run{symbol:3,length:5,next:u32::MAX},Run{symbol:0,length:1,next:u32::MAX}],primary:0,last_len:269};
    let expected_rank=[1,2,0,1,0,0,0];let expected_recent=[0,1,0x16,0x168,0x168d,0x68d0,0x8d0c];let expected_rank_exp=[0,0,0,0,0,0,0];let expected_length_exp=[0,0,0,0,0,7,0];
    let mut checks=0;
    for family in [Family::Global,Family::Symbol,Family::Recent,Family::Joint]{let mut index=0;let meta=walk(&front,family,|c,key,t,limit,recent|{let i=index/2;let x=if c==0{0}else{histogram::exponent(expected_rank[i]+1)};let run=front.runs[i];let desired=if c==0{expected_rank[i]}else{(run.length as usize-1).min(255)};let expected_key=family.key(c,x,run.symbol as usize,expected_recent[i],expected_rank_exp[i],expected_length_exp[i])?;if key!=expected_key || t!=desired || recent!=expected_recent[i] || t>=limit{return Err("hand sequence history/key".into());}checks+=1;index+=1;Ok(())})?;if meta.runs!=7 || meta.escapes!=1 || meta.tokens!=[7,7]{return Err("hand sequence totals".into());}
        let max=family.key(1,8,256,65535,7,23)?;let composite=packed(max,256)?;if composite>>9!=max || family.component(max)?!=1{return Err("maximum key boundary".into());}checks+=1;
    }
    for family in [Family::Global,Family::Symbol,Family::Recent,Family::Joint]{for (c,x,s,r,e,l)in [(2,0,0,0,0,0),(0,1,0,0,0,0),(1,9,0,0,0,0),(0,0,257,0,0,0),(0,0,0,65536,0,0),(0,0,0,0,8,0),(0,0,0,0,0,24)]{if family.key(c,x,s,r,e,l).is_ok(){return Err("feature invalid boundary accepted".into());}checks+=1;}}
    if packed(1<<23,0).is_ok() || packed(0,257).is_ok(){return Err("packed rejection".into());}checks+=2;Ok(checks)
}
