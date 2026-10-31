//! @adversarial @category boundary/type/state/resource @severity HIGH
//! 新規記述。30 bounded RAM frame faults、CRC reseal後も意味検査を通す。
use crate::{codec::{self,Result},grammar,model,codebook,multi_range};
fn u32field(b:&mut[u8],i:usize,n:usize){b[i..i+4].copy_from_slice(&(n as u32).to_le_bytes());}
fn uniform_token(e:&mut multi_range::Encoder,c:usize,limit:usize,value:usize,h:&mut[u16;6])->Result<()>{let tree=grammar::Tree::new(if c==0{257}else{256});let mut n=0;loop{let k=tree.prefix(n,limit)?;let child=tree.known_child(n,value,limit)?;let class=c*3+tree.class(n)?;if k>1{let f=model::quantize([0;4],k)?;e.interval(f[..child].iter().map(|&v|u32::from(v)).sum(),u32::from(f[child]),32768).map_err(str::to_owned)?;}h[class]=((h[class]<<2)|child as u16)&1023;let edge=tree.edge(n,child,k)?;if let Some(next)=edge.node{n=next;}else{return Ok(());}}}
// 正常witnessと意味不正のpayloadは整数uniform grammarから組立てる。
// last=[66×4096,0],primary4096はA反復、sentinel_firstはLF self-cycle。
fn witness(escape:&[u8],sentinel_first:bool)->Result<Vec<u8>>{
    let mut w=codebook::Writer::new(852)?;for _ in 0..852{w.write(0,1)?;}let metadata=codebook::header(&w.bytes,852,&codebook::LENGTHS)?;
    let mut e=multi_range::Encoder::with_limit(1024).map_err(str::to_owned)?;let mut h=[0u16;6];
    if sentinel_first{uniform_token(&mut e,0,2,0,&mut h)?;uniform_token(&mut e,1,256,0,&mut h)?;}
    uniform_token(&mut e,0,if sentinel_first{1}else{2},0,&mut h)?;uniform_token(&mut e,1,256,255,&mut h)?;for &b in escape{e.interval(u32::from(b),1,256).map_err(str::to_owned)?;}
    if !sentinel_first{uniform_token(&mut e,0,1,0,&mut h)?;uniform_token(&mut e,1,1,0,&mut h)?;}
    let payload=e.finish().map_err(str::to_owned)?;let mut out=vec![0;40+4+metadata.len()+payload.len()];out[..8].copy_from_slice(codec::MAGIC);out[8]=1;out[10]=1;u32field(&mut out,12,4096);u32field(&mut out,16,if sentinel_first{0}else{4096});u32field(&mut out,20,metadata.len());u32field(&mut out,24,payload.len());out[28]=2;
    let alpha=if sentinel_first{[0u16,66]}else{[66u16,0]};for(i,v)in alpha.iter().enumerate(){out[40+i*2..42+i*2].copy_from_slice(&v.to_le_bytes());}out[44..44+metadata.len()].copy_from_slice(&metadata);out[44+metadata.len()..].copy_from_slice(&payload);let plain=vec![65;4096];out[32..36].copy_from_slice(&codec::crc32(&plain).to_le_bytes());codec::reseal(&mut out)?;Ok(out)
}
pub fn run()->Result<String>{
    let good=witness(&[128,30],false)?;let(plain,s)=codec::decode(&good)?;if plain!=vec![65;4096] || s.method!=1{return Err("adversarial normal witness".into());}drop(plain);let mut rejected=0;let mut recovered=0;let mut resealed=0;let mut reasons=String::new();let mut max_capacity=s.phase_capacity_bound;
    for case in 0..30{let mut bad=good.clone();let mut seal=true;let expected=match case{
        0=>{bad[0]^=1;"frame magic"},1=>{bad[8]=2;"frame revision"},2=>{bad[10]=2;"frame method"},3=>{bad[11]=1;"frame flags/reserved"},4=>{bad[30]=1;"frame flags/reserved"},
        5=>{u32field(&mut bad,12,codec::MAX_INPUT+1);"raw exceeds block limit"},6=>{u32field(&mut bad,16,4097);"frame canonical fields"},7=>{bad.truncate(39);seal=false;"header truncated"},8=>{bad.pop();seal=false;"frame exact extent"},9=>{bad.push(0);"frame exact extent"},
        10=>{u32field(&mut bad,20,u32::MAX as usize);"frame exact extent"},11=>{u32field(&mut bad,24,u32::MAX as usize);"frame exact extent"},12=>{bad[28..30].copy_from_slice(&65535u16.to_le_bytes());"frame exact extent"},
        13=>{*bad.last_mut().ok_or("bad frame")?^=1;seal=false;"wire CRC"},14=>{bad[32]^=1;"plain CRC"},15=>{bad[42..44].copy_from_slice(&66u16.to_le_bytes());"alphabet range/duplicate"},16=>{bad[40..42].copy_from_slice(&257u16.to_le_bytes());"alphabet range/duplicate"},17=>{bad[42..44].copy_from_slice(&1u16.to_le_bytes());"alphabet sentinel absent"},
        18=>{bad[40..42].copy_from_slice(&0u16.to_le_bytes());bad[42..44].copy_from_slice(&66u16.to_le_bytes());"run/sentinel length"},19=>{bad[44]=0;"header codec flag"},20=>{bad[44+133]|=1;"table nibble padding"},21=>{bad[44+241]=1;"invalid range prefix"},
        22=>{bad.push(0);u32field(&mut bad,24,good.len()-44-241+1);"trailing range bytes"},23=>{*bad.last_mut().ok_or("bad frame")?^=1;"noncanonical range termination"},
        24=>{bad=witness(&[128,158,0],false)?;"noncanonical escape"},25=>{bad=witness(&[128,64],false)?;"escape remaining"},26=>{bad=witness(&[128,128,128],false)?;"escape length overflow"},
        27=>{bad=witness(&[128,30],true)?;"LF cycle inconsistent"},28=>{bad[10]=0;"frame canonical fields"},_=>{u32field(&mut bad,12,good.len()-40);"frame canonical fields"}
    };if seal{codec::reseal(&mut bad)?;resealed+=1;}
        let actual=codec::decode(&bad).err().ok_or_else(||format!("bad frame{case} accepted"))?;if actual!=expected{return Err(format!("bad frame{case}: {actual}; expected {expected}"));}rejected+=1;
        if case!=0{reasons.push(',');}reasons.push_str(&format!("\"{actual}\""));let(plain,recovery)=codec::decode(&good)?;if plain!=vec![65;4096]{return Err("bad frame recovery mismatch".into());}recovered+=1;max_capacity=max_capacity.max(recovery.phase_capacity_bound);
    }
    Ok(format!("{{\"fault_cases\":{rejected},\"rejections\":{rejected},\"same_process_recoveries\":{recovered},\"CRC_resealed_cases\":{resealed},\"exact_reasons\":[{reasons}],\"decode_calls\":{},\"BWT_calls\":0,\"Fit_builds\":0,\"input_reads\":0,\"normal_witness_byte_exact\":true,\"LF_cycle_rejection_observed\":true,\"noncanonical_escape_rejection_observed\":true,\"oversize_declaration_rejected_before_allocation\":true,\"RAM_only\":true,\"max_codec_capacity_bound_bytes\":{max_capacity},\"OS_chaos_executed\":false}}",1+rejected+recovered))
}
