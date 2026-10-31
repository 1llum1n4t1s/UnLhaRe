//! 固定ABBA4encode＋候補decode1のRAM全byte比較。内側計時なし、正式benchmarkではない。
#![allow(dead_code)]
#[path="old_wire.rs"] mod old_wire;
#[path="new_wire.rs"] mod new_wire;
#[path="../quaternary-cts-kt64/integer_cts.rs"] mod old_cts;
#[path="integer_cts.rs"] mod new_cts;
#[path="comparison.rs"] mod comparison;
#[path="../quaternary-cts-integer-pool/fixed_math.rs"] mod fixed_math;
#[path="../quaternary-cts-integer-pool/integer_pool.rs"] mod integer_pool;
#[path="../quaternary-cts-q32/integer_cts.rs"] mod reference_cts;
#[path="../causal-bayes-sais/bwt.rs"] mod bwt;
#[path="../rejected-binary-mix/packed_alphabet.rs"] mod packed_alphabet;
#[path="../direct-token/multi_range.rs"] mod multi_range;
use reference_cts as integer_cts;
use std::{fs::File,io::{Read,Write},path::Path};
type Result<T>=std::result::Result<T,String>;
pub(crate) struct Encoded {frame:Vec<u8>,stats:String,elapsed_ns:u64}
pub(crate) struct Decoded {plain:Vec<u8>,stats:String,elapsed_ns:u64}
struct Run {index:usize,variant:&'static str,stats:Option<String>,elapsed_ns:Option<u64>,matched_bytes:usize,frame_equal:bool,error:Option<String>}
fn quote(text:&str)->String{
    let mut result=String::from("\"");for c in text.chars().take(1024){match c{'"'=>result.push_str("\\\""),'\\'=>result.push_str("\\\\"),'\n'=>result.push_str("\\n"),'\r'=>result.push_str("\\r"),'\t'=>result.push_str("\\t"),c if c<' '=>result.push_str(&format!("\\u{:04x}",c as u32)),c=>result.push(c)}}result.push('"');result
}
fn emit(line:&str)->Result<()>{println!("{line}");std::io::stdout().flush().map_err(|e|format!("progress JSON flush: {e}"))}
impl Run{
    fn json(&self)->String{format!("{{\"index\":{},\"variant\":\"{}\",\"stats\":{},\"encode_elapsed_ns\":{},\"matched_bytes\":{},\"frame_equal\":{},\"error\":{}}}",self.index,self.variant,self.stats.as_deref().unwrap_or("null"),self.elapsed_ns.map_or("null".into(),|v|v.to_string()),self.matched_bytes,self.frame_equal,self.error.as_deref().map_or("null".into(),quote))}
}
fn read(path:&Path,limit:usize)->Result<Vec<u8>>{
    let file=File::open(path).map_err(|e|format!("bounded input open: {e}"))?;let m=file.metadata().map_err(|e|format!("bounded input metadata: {e}"))?;
    if !m.is_file()||m.len()>limit as u64{return Err("bounded input limit/type".into());}
    let mut bytes=Vec::new();bytes.try_reserve_exact(m.len() as usize).map_err(|_|"profile input allocation")?;
    file.take(limit as u64+1).read_to_end(&mut bytes).map_err(|e|format!("bounded input read: {e}"))?;if bytes.len()>limit{return Err("bounded input grew".into());}Ok(bytes)
}
fn one(index:usize,variant:&'static str,encoded:Result<Encoded>,baseline:&[u8],runs:&mut Vec<Run>)->Result<()>{
    let mut record=Run{index,variant,stats:None,elapsed_ns:None,matched_bytes:0,frame_equal:false,error:None};
    match encoded {
        Err(e)=>record.error=Some(e),
        Ok(encoded)=>{
            record.stats=Some(encoded.stats);record.elapsed_ns=Some(encoded.elapsed_ns);
            let common=encoded.frame.len().min(baseline.len());for j in 0..common{if encoded.frame[j]!=baseline[j]{record.error=Some(format!("frame byte mismatch at {j}"));break;}record.matched_bytes+=1;}
            if record.error.is_none()&&encoded.frame.len()!=baseline.len(){record.error=Some("frame byte length mismatch".into());}
            record.frame_equal=record.error.is_none();drop(encoded.frame);
        }
    }
    let error=record.error.clone();let line=format!("{{\"kind\":\"run\",\"record\":{}}}",record.json());runs.push(record);emit(&line)?;
    if let Some(e)=error{Err(e)}else{Ok(())}
}
fn execute(runs:&mut Vec<Run>,restored:&mut Option<String>)->Result<()>{
    let args:Vec<_>=std::env::args_os().collect();if args.len()!=4||args[1]!="profile"{return Err("usage: phase_profile profile INPUT PRIOR_FRAME".into());}
    let input=read(Path::new(&args[2]),8*1024*1024)?;let baseline=read(Path::new(&args[3]),(1<<20)+281)?;
    if input.len()!=2811006||baseline.len()!=474730{return Err("fixed input/baseline length".into());}
    // rootの選択だけ。hot model経路にruntime CTS enum/virtual dispatchはない。
    one(0,"kt64",old_wire::run_profile(&input),&baseline,runs)?;
    one(1,"sealed",new_wire::run_profile(&input),&baseline,runs)?;
    one(2,"sealed",new_wire::run_profile(&input),&baseline,runs)?;
    one(3,"kt64",old_wire::run_profile(&input),&baseline,runs)?;
    let decoded=new_wire::run_restore(&baseline);
    let mut matched=0usize;let mut equal=false;let mut error=None;let mut stats=None;let mut elapsed=None;
    match decoded {
        Err(e)=>error=Some(e),
        Ok(decoded)=>{
            stats=Some(decoded.stats);elapsed=Some(decoded.elapsed_ns);
            for j in 0..decoded.plain.len().min(input.len()){if decoded.plain[j]!=input[j]{error=Some(format!("restore byte mismatch {j}"));break;}matched+=1;}
            if error.is_none()&&decoded.plain.len()!=input.len(){error=Some("restore byte length mismatch".into());}
            equal=error.is_none();drop(decoded.plain);
        }
    }
    let record=format!("{{\"variant\":\"sealed\",\"stats\":{},\"decode_elapsed_ns\":{},\"matched_bytes\":{matched},\"plain_equal\":{equal},\"baseline_header_crc\":{},\"error\":{}}}",stats.as_deref().unwrap_or("null"),elapsed.map_or("null".into(),|v|v.to_string()),u32::from_le_bytes(baseline[32..36].try_into().map_err(|_|"baseline header CRC")?),error.as_deref().map_or("null".into(),quote));
    *restored=Some(record.clone());emit(&format!("{{\"kind\":\"restore\",\"record\":{record}}}"))?;
    if let Some(error)=error{return Err(error);}

    Ok(())
}
fn main(){
    let args:Vec<_>=std::env::args_os().collect();
    if args.len()==2&&(args[1]=="compare-snapshot"||args[1]=="selfcheck"){
        let result=if args[1]=="compare-snapshot"{comparison::run()}else{new_wire::run_selfcheck()};
        if let Err(e)=result{eprintln!("rejected: {e}");std::process::exit(1);}return;
    }
    let mut runs=Vec::new();let mut restored=None;let result=execute(&mut runs,&mut restored);
    let status=if result.is_ok(){"passed"}else{"failed"};let error=result.as_ref().err().map_or("null".into(),|e|quote(e));
    let records=runs.iter().map(Run::json).collect::<Vec<_>>().join(",");let matched=runs.iter().filter(|r|r.frame_equal).count();let restore_count=usize::from(result.is_ok()&&restored.is_some());let decode_calls=usize::from(restored.is_some());
    let final_json=format!("{{\"kind\":\"final\",\"status\":\"{status}\",\"operation\":\"sealed-profile\",\"ABBA\":[\"kt64\",\"sealed\",\"sealed\",\"kt64\"],\"runs_completed\":{matched},\"run_records\":[{records}],\"frame_comparisons\":{matched},\"expected_matched_bytes_per_run\":474730,\"restore_comparisons\":{restore_count},\"expected_restored_bytes\":2811006,\"restore\":{},\"warmup_runs\":0,\"additional_repeats\":0,\"inner_timers\":false,\"full_input_canonical_reencoded\":false,\"decode_calls\":{decode_calls},\"disk_frames_created\":false,\"disk_restores_created\":false,\"diagnostic_only\":true,\"formal_speed_CPU_verified\":false,\"full_benchmark_allowed\":false,\"general_8MiB_input_supported\":false,\"timing_scope\":\"encode calls only, excludes stats formatting/frame comparison/JSON/drop; no inner timer\",\"error\":{error}}}",restored.as_deref().unwrap_or("null"));
    if let Err(e)=emit(&final_json){eprintln!("profile reporting failed: {e}");std::process::exit(1);}
    if let Err(e)=result{eprintln!("profile failed: {e}");std::process::exit(1);}
}
