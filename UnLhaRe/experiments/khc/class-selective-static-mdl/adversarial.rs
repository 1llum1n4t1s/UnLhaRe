use crate::{model,bundle};
type Result<T>=std::result::Result<T,String>;
const UNIFORM:[u8;12]=[64,0,42,171,85,86,64,0,128,1,0,0];
pub fn run()->Result<String>{
    let density=crate::density_adversarial::run()?;let mut h=model::Hist::new()?;bundle::ingest(&mut h,4,5,[0,10,0,0])?;let before=h.counts.clone();let mut ingest=0;
    for(k,row)in [(1,[1,0,0,0]),(5,[1,0,0,0]),(2,[0,0,1,0]),(4,[model::CAP+1,0,0,0]),(4,[model::CAP,0,0,0])]{if bundle::ingest(&mut h,k,5,row).is_ok() || h.counts!=before{return Err("weighted rejection whole state".into());}ingest+=1;}
    let mut bad_min=UNIFORM.to_vec();bad_min[0]=0;bad_min[1]=0;let mut bad_padding=UNIFORM.to_vec();bad_padding[11]|=1;let mut bad_depth=vec![0;12];bad_depth[0]=0xfc;let mut trailing=UNIFORM.to_vec();trailing.push(0);
    let cases=[(UNIFORM.to_vec(),0),(UNIFORM.to_vec(),model::MAX_BITS+1),(UNIFORM[..11].to_vec(),93),(trailing,93),(bad_min,93),(bad_padding,93),(bad_depth,93)];
    let mut out=Vec::new();bundle::append(&mut out,&UNIFORM,93)?;let saved=out.clone();let mut parsing=0;let mut appending=0;
    for(bytes,bits)in &cases{if model::parse(bytes,*bits).is_ok(){return Err("malformed model accepted".into());}parsing+=1;if bundle::append(&mut out,bytes,*bits).is_ok() || out!=saved{return Err("append rejection whole byte state".into());}appending+=1;}
    let mut good=Vec::new();for _ in 0..278{bundle::append(&mut good,&UNIFORM,93)?;}
    let mut truncated=good.clone();truncated.pop();let mut extra=good.clone();extra.push(0);let mut zero_bits=good.clone();zero_bits[..4].copy_from_slice(&0u32.to_le_bytes());let mut low=good.clone();low[4]=0;low[5]=0;let mut pad=good.clone();pad[15]|=1;
    let mut forests=0;for bytes in [truncated,extra,zero_bits,low,pad]{if bundle::Forest::parse(&bytes).is_ok(){return Err("malformed whole bundle accepted".into());}forests+=1;}
    Ok(format!("{{\"Density\":{density},\"weighted_rejections\":{ingest},\"whole_Hist_unchanged\":true,\"model_rejections\":{parsing},\"append_rejections\":{appending},\"whole_append_bytes_unchanged\":true,\"Forest_rejections\":{forests}}}"))
}
