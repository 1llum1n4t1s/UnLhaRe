//! 固定ABBA4encodeのRAM全frame比較とphase診断。正式benchmarkではない。
#![allow(dead_code)]
#[path="timing.rs"] mod timing;
#[path="old_wire.rs"] mod old_wire;
#[path="pow2_wire.rs"] mod pow2_wire;
#[path="../quaternary-cts-integer-pool/fixed_math.rs"] mod fixed_math;
#[path="../quaternary-cts-integer-pool/integer_pool.rs"] mod integer_pool;
#[path="../quaternary-cts-q32/integer_cts.rs"] mod reference_cts;
#[path="../quaternary-cts-pow2/integer_cts.rs"] mod pow2_cts;
#[path="../causal-bayes-sais/bwt.rs"] mod bwt;
#[path="../rejected-binary-mix/packed_alphabet.rs"] mod packed_alphabet;
#[path="../direct-token/multi_range.rs"] mod multi_range;
use reference_cts as integer_cts;
use std::{fs::File,io::{Read,Write},path::Path};
type Result<T>=std::result::Result<T,String>;
pub(crate) struct Encoded {frame:Vec<u8>,stats:String}
struct Run {index:usize,variant:&'static str,stats:Option<String>,metrics:timing::Record,matched_bytes:usize,frame_equal:bool,error:Option<String>}
fn quote(text:&str)->String{
    let mut result=String::from("\"");for c in text.chars().take(1024){match c{'"'=>result.push_str("\\\""),'\\'=>result.push_str("\\\\"),'\n'=>result.push_str("\\n"),'\r'=>result.push_str("\\r"),'\t'=>result.push_str("\\t"),c if c<' '=>result.push_str(&format!("\\u{:04x}",c as u32)),c=>result.push(c)}}result.push('"');result
}
fn emit(line:&str)->Result<()>{println!("{line}");std::io::stdout().flush().map_err(|e|format!("progress JSON flush: {e}"))}
impl Run{
    fn json(&self)->String{format!("{{\"index\":{},\"variant\":\"{}\",\"stats\":{},\"metrics\":{},\"matched_bytes\":{},\"frame_equal\":{},\"error\":{}}}",self.index,self.variant,self.stats.as_deref().unwrap_or("null"),self.metrics.json(),self.matched_bytes,self.frame_equal,self.error.as_deref().map_or("null".into(),quote))}
}
fn read(path:&Path,limit:usize)->Result<Vec<u8>>{
    let file=File::open(path).map_err(|e|format!("bounded input open: {e}"))?;let m=file.metadata().map_err(|e|format!("bounded input metadata: {e}"))?;
    if !m.is_file()||m.len()>limit as u64{return Err("bounded input limit/type".into());}
    let mut bytes=Vec::new();bytes.try_reserve_exact(m.len() as usize).map_err(|_|"profile input allocation")?;
    file.take(limit as u64+1).read_to_end(&mut bytes).map_err(|e|format!("bounded input read: {e}"))?;if bytes.len()>limit{return Err("bounded input grew".into());}Ok(bytes)
}
fn one(index:usize,variant:&'static str,encoded:Result<Encoded>,baseline:&[u8],runs:&mut Vec<Run>)->Result<()>{
    let metrics=timing::snapshot();
    let mut record=Run{index,variant,stats:None,metrics,matched_bytes:0,frame_equal:false,error:None};
    match encoded {
        Err(e)=>record.error=Some(e),
        Ok(encoded)=>{
            record.stats=Some(encoded.stats);
            let common=encoded.frame.len().min(baseline.len());for j in 0..common{if encoded.frame[j]!=baseline[j]{record.error=Some(format!("frame byte mismatch at {j}"));break;}record.matched_bytes+=1;}
            if record.error.is_none()&&encoded.frame.len()!=baseline.len(){record.error=Some("frame byte length mismatch".into());}
            record.frame_equal=record.error.is_none();drop(encoded.frame);
        }
    }
    let error=record.error.clone();let line=format!("{{\"kind\":\"run\",\"record\":{}}}",record.json());runs.push(record);emit(&line)?;
    if let Some(e)=error{Err(e)}else{Ok(())}
}
fn execute(runs:&mut Vec<Run>)->Result<()>{
    let args:Vec<_>=std::env::args_os().collect();if args.len()!=4||args[1]!="profile"{return Err("usage: phase_profile profile INPUT PRIOR_FRAME".into());}
    let input=read(Path::new(&args[2]),8*1024*1024)?;let baseline=read(Path::new(&args[3]),(1<<20)+281)?;
    if input.len()!=2811006||baseline.len()!=474730{return Err("fixed input/baseline length".into());}
    // rootの選択だけ。hot model経路にruntime CTS enum/virtual dispatchはない。
    timing::reset();one(0,"old",old_wire::run_profile(&input),&baseline,runs)?;
    timing::reset();one(1,"pow2",pow2_wire::run_profile(&input),&baseline,runs)?;
    timing::reset();one(2,"pow2",pow2_wire::run_profile(&input),&baseline,runs)?;
    timing::reset();one(3,"old",old_wire::run_profile(&input),&baseline,runs)?;
    Ok(())
}
fn main(){
    let mut runs=Vec::new();let result=execute(&mut runs);
    let status=if result.is_ok(){"passed"}else{"failed"};let error=result.as_ref().err().map_or("null".into(),|e|quote(e));
    let records=runs.iter().map(Run::json).collect::<Vec<_>>().join(",");let matched=runs.iter().filter(|r|r.frame_equal).count();
    let final_json=format!("{{\"kind\":\"final\",\"status\":\"{status}\",\"operation\":\"phase-profile\",\"ABBA\":[\"old\",\"pow2\",\"pow2\",\"old\"],\"runs_completed\":{matched},\"run_records\":[{records}],\"frame_comparisons\":{matched},\"expected_matched_bytes_per_run\":474730,\"samples_per_run\":3736,\"phases_per_sample\":7,\"sample_stride\":1024,\"warmup_runs\":0,\"additional_repeats\":0,\"decode_repeated\":false,\"disk_frames_created\":false,\"disk_restores_created\":false,\"diagnostic_only\":true,\"formal_speed_CPU_verified\":false,\"full_benchmark_allowed\":false,\"phase_overlap\":\"full_encode contains all whole phases; inner CTS/pool samples contained in outer model samples; no phase-sum equality required; escape excluded from range samples; forced branches included\",\"sampling_limitations\":\"serial subset bias, clock and aggregation overhead, code placement, CPU scheduling; no extrapolation to exact full-input CPU time\",\"error\":{error}}}");
    if let Err(e)=emit(&final_json){eprintln!("profile reporting failed: {e}");std::process::exit(1);}
    if let Err(e)=result{eprintln!("profile failed: {e}");std::process::exit(1);}
}

