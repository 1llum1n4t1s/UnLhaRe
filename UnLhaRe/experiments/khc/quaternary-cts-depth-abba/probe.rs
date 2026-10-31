//! 同一binary ABBA1周のRAM E2E。正式benchmarkや改善率ではない。
#![allow(dead_code)]
#[path="../quaternary-cts-mid-depth/codec.rs"] mod codec;
#[path="../quaternary-cts-depth/integer_cts.rs"] mod new_cts;
#[path="../quaternary-cts-sealed/integer_cts.rs"] mod old_cts;
#[path="../quaternary-cts-mid-depth/comparison.rs"] mod comparison;
#[path="../quaternary-cts-integer-pool/fixed_math.rs"] mod fixed_math;
#[path="../quaternary-cts-integer-pool/integer_pool.rs"] mod integer_pool;
#[path="../quaternary-cts-q32/integer_cts.rs"] mod reference_cts;
#[path="../causal-bayes-sais/bwt.rs"] mod bwt;
#[path="../rejected-binary-mix/packed_alphabet.rs"] mod packed_alphabet;
#[path="../direct-token/multi_range.rs"] mod multi_range;
use reference_cts as integer_cts;
use std::{fs::File,io::{Read,Write},path::Path};
type Result<T>=std::result::Result<T,String>;
pub(crate) struct Encoded {frame:Vec<u8>,stats:String,proof:codec::Proof,elapsed_ns:u64}
pub(crate) struct Decoded {plain:Vec<u8>,stats:String,proof:codec::Proof,elapsed_ns:u64}
#[derive(Default)]
struct Accounting {
    encode_calls:usize,decode_calls:usize,plain_comparisons:usize,stats_comparisons:usize,
    input_read_attempts:usize,input_reads:usize,baseline_read_attempts:usize,baseline_reads:usize,
    protocol_reappearances:usize,repeat_frame_comparison_attempts:usize,
    repeat_frame_comparisons:usize,repeat_frame_matched_bytes:usize,size_gate_passed_count:usize,
    peak_reference_frames:usize,peak_reference_frame_bytes:usize,
    peak_live_candidate_frames:usize,peak_live_candidate_frame_bytes:usize,
}
struct References {frames:[Option<Vec<u8>>;2]}
impl References {
    fn new()->Self {Self{frames:[None,None]}}
    fn shape(&self)->(usize,usize) {(self.frames.iter().filter(|v|v.is_some()).count(),self.frames.iter().filter_map(|v|v.as_ref()).map(Vec::len).sum())}
}
fn quote(text:&str)->String{
    let mut result=String::from("\"");for c in text.chars().take(1024){match c{
        '"'=>result.push_str("\\\""),'\\'=>result.push_str("\\\\"),'\n'=>result.push_str("\\n"),'\r'=>result.push_str("\\r"),'\t'=>result.push_str("\\t"),
        c if c<' '=>result.push_str(&format!("\\u{:04x}",c as u32)),c=>result.push(c)}}result.push('"');result
}
fn emit(line:&str)->Result<()>{println!("{line}");std::io::stdout().flush().map_err(|e|format!("progress JSON flush: {e}"))}
fn read(path:&Path,limit:usize)->Result<Vec<u8>>{
    let file=File::open(path).map_err(|e|format!("bounded input open: {e}"))?;let m=file.metadata().map_err(|e|format!("bounded input metadata: {e}"))?;
    if !m.is_file()||m.len()>limit as u64{return Err("bounded input limit/type".into());}
    let mut bytes=Vec::new();bytes.try_reserve_exact(m.len() as usize).map_err(|_|"input allocation")?;
    file.take(limit as u64+1).read_to_end(&mut bytes).map_err(|e|format!("bounded input read: {e}"))?;
    if bytes.len()>limit{return Err("bounded input grew".into());}Ok(bytes)
}
fn bytes_equal(a:&[u8],b:&[u8],scope:&str)->Result<usize>{
    if a.len()!=b.len(){return Err(format!("{scope} length mismatch"));}
    for (j,(&a,&b)) in a.iter().zip(b).enumerate(){if a!=b{return Err(format!("{scope} mismatch at {j}"));}}Ok(a.len())
}
fn candidate(depth:usize,index:usize,input:&[u8],baseline:&[u8],counts:&mut Accounting,references:&mut References)->Result<(String,bool)>{
    counts.protocol_reappearances+=usize::from(index>=2);
    counts.encode_calls+=1;
    let encoded=codec::run_profile(input,depth)?;encoded.proof.validate_fixed(depth)?;
    let slot=match depth{8=>0,5=>1,_=>return Err("unplanned ABBA depth".into())};
    let expected_frame=if depth==8{474734}else{478750};
    if encoded.frame.len()!=expected_frame{return Err("ABBA fixed frame length".into());}
    let (reference_count,reference_bytes)=references.shape();
    let live_count=reference_count+1;let live_bytes=reference_bytes+encoded.frame.len();
    if live_count>3||live_bytes>1432234{return Err("ABBA candidate frame buffer bound".into());}
    counts.peak_live_candidate_frames=counts.peak_live_candidate_frames.max(live_count);
    counts.peak_live_candidate_frame_bytes=counts.peak_live_candidate_frame_bytes.max(live_bytes);
    let (bridge_fields,bridge_payload)=if depth==8 {
        if encoded.frame.len()!=474734{return Err("depth8 frame shape".into());}
        (bytes_equal(&encoded.frame[8..32],&baseline[8..32],"bridge fields")?,
         bytes_equal(&encoded.frame[40..],&baseline[36..],"bridge metadata/payload")?)
    }else{(0,0)};
    // 自己記述depthだけで復元。CLI/globalのdepth引数はdecoderへ渡さない。
    counts.decode_calls+=1;
    let decoded=codec::run_restore(&encoded.frame)?;
    let matched=bytes_equal(&decoded.plain,input,"full plain")?;
    counts.plain_comparisons+=1;
    if encoded.proof!=decoded.proof||encoded.stats!=decoded.stats{return Err("encode/decode all stats differ".into());}
    counts.stats_comparisons+=1;
    decoded.proof.validate_fixed(depth)?;
    let gate=encoded.frame.len()<=483599;
    if !gate{return Err("ABBA actual size gate exceeded".into());}
    counts.size_gate_passed_count+=1;
    drop(decoded.plain);
    // 既存codec timerの外で直接比較し、再出現のcurrent/referenceを直後に解放する。
    let repeat_bytes=if index>=2 {
        let prior=references.frames[slot].as_ref().ok_or("ABBA missing reference frame")?;
        counts.repeat_frame_comparison_attempts+=1;
        let compared=bytes_equal(&encoded.frame,prior,"repeat whole frame")?;
        counts.repeat_frame_comparisons+=1;counts.repeat_frame_matched_bytes+=compared;
        drop(references.frames[slot].take());drop(encoded.frame);compared
    }else {
        if references.frames[slot].is_some(){return Err("ABBA duplicate first reference".into());}
        references.frames[slot]=Some(encoded.frame);0
    };
    let (held_count,held_bytes)=references.shape();
    if held_count>2||held_bytes>953484{return Err("ABBA reference frame buffer bound".into());}
    counts.peak_reference_frames=counts.peak_reference_frames.max(held_count);
    counts.peak_reference_frame_bytes=counts.peak_reference_frame_bytes.max(held_bytes);
    let repeat_compared=index>=2;
    let record=format!("{{\"index\":{index},\"depth\":{depth},\"status\":\"passed\",\"encode_calls\":1,\"decode_calls\":1,\"encode_stats\":{},\"decode_stats\":{},\"stats_equal\":true,\"cdf_compared_as_bits\":true,\"encode_elapsed_ns\":{},\"decode_elapsed_ns\":{},\"matched_plain_bytes\":{matched},\"plain_equal\":true,\"bridge_field_matched_bytes\":{bridge_fields},\"bridge_metadata_payload_matched_bytes\":{bridge_payload},\"size_gate_limit_bytes\":483599,\"size_gate_passed\":{gate},\"repeat_frame_compared\":{repeat_compared},\"repeat_frame_matched_bytes\":{repeat_bytes},\"candidate_frames_before_comparison\":{live_count},\"candidate_frame_bytes_before_comparison\":{live_bytes},\"reference_frames_after\":{held_count},\"reference_frame_bytes_after\":{held_bytes},\"error\":null}}",
        encoded.stats,decoded.stats,encoded.elapsed_ns,decoded.elapsed_ns);
    Ok((record,gate))
}
fn execute(records:&mut Vec<String>,counts:&mut Accounting)->Result<()>{
    let args:Vec<_>=std::env::args_os().collect();if args.len()!=4||args[1]!="abba"{return Err("usage: depth_probe abba INPUT PRIOR_FRAME".into());}
    counts.input_read_attempts+=1;let input=read(Path::new(&args[2]),8*1024*1024)?;counts.input_reads+=1;
    counts.baseline_read_attempts+=1;let baseline=read(Path::new(&args[3]),(1<<20)+281)?;counts.baseline_reads+=1;
    if input.len()!=2811006||baseline.len()!=474730||&baseline[..8]!=b"KHQCIP01"{return Err("fixed input/baseline shape".into());}
    let mut references=References::new();
    for (index,depth) in [8,5,5,8].into_iter().enumerate() {
        match candidate(depth,index,&input,&baseline,counts,&mut references) {
            Ok((record,_))=>{emit(&format!("{{\"kind\":\"run\",\"record\":{record}}}"))?;records.push(record);}
            Err(e)=>{let record=format!("{{\"index\":{index},\"depth\":{depth},\"status\":\"failed\",\"error\":{}}}",quote(&e));
                emit(&format!("{{\"kind\":\"run\",\"record\":{record}}}"))?;records.push(record);return Err(e);}
        }
    }
    if references.shape()!=(0,0)||counts.repeat_frame_comparisons!=2||counts.repeat_frame_matched_bytes!=953484{return Err("ABBA complete repeat/reference counts".into());}
    Ok(())
}
fn main(){
    let args:Vec<_>=std::env::args_os().collect();
    if args.len()==2&&(args[1]=="compare-snapshot"||args[1]=="selfcheck"){
        let result=if args[1]=="compare-snapshot"{comparison::run()}else{codec::run_selfcheck()};
        if let Err(e)=result{eprintln!("rejected: {e}");std::process::exit(1);}return;
    }
    let mut records=Vec::new();let mut counts=Accounting::default();let result=execute(&mut records,&mut counts);
    let gates=counts.size_gate_passed_count;
    let status=if result.is_ok(){"passed"}else{"failed"};let error=result.as_ref().err().map_or("null".into(),|e|quote(e));
    let completed=records.iter().filter(|r|r.contains("\"status\":\"passed\"")).count();
    let final_json=format!("{{\"kind\":\"final\",\"status\":\"{status}\",\"operation\":\"depth-abba\",\"depth_order\":[8,5,5,8],\"runs_completed\":{completed},\"encode_calls\":{},\"decode_calls\":{},\"plain_comparisons\":{},\"stats_comparisons\":{},\"expected_restored_bytes\":2811006,\"size_gate_passed_count\":{gates},\"records\":[{}],\"input_read_attempts\":{},\"input_reads\":{},\"baseline_read_attempts\":{},\"baseline_reads\":{},\"warmup_runs\":0,\"abba_cycles\":{},\"protocol_reappearances\":{},\"repeat_frame_comparison_attempts\":{},\"repeat_frame_comparisons\":{},\"repeat_frame_matched_bytes\":{},\"peak_reference_frames\":{},\"peak_reference_frame_bytes\":{},\"peak_live_candidate_frames\":{},\"peak_live_candidate_frame_bytes\":{},\"references_remaining\":0,\"baseline_frame_bytes_excluded_from_candidate_peak\":474730,\"all_process_peak_verified\":false,\"frame_clones_created\":false,\"additional_repeats\":0,\"inner_timers\":false,\"full_input_canonical_reencoded\":false,\"disk_frames_created\":false,\"disk_restores_created\":false,\"diagnostic_only\":true,\"formal_speed_CPU_verified\":false,\"full_benchmark_allowed\":false,\"general_8MiB_input_supported\":false,\"timing_scope\":\"encode/decode calls only; excludes JSON/stats formatting/comparison/drop\",\"timing_limitations\":[\"single ABBA cycle\",\"no warmup\",\"code placement\",\"CPU scheduling\"],\"next_step\":\"single-cycle diagnostic only; parent evaluates direction and provisional depth5 basis\",\"error\":{error}}}",counts.encode_calls,counts.decode_calls,counts.plain_comparisons,counts.stats_comparisons,records.join(","),counts.input_read_attempts,counts.input_reads,counts.baseline_read_attempts,counts.baseline_reads,usize::from(result.is_ok()),counts.protocol_reappearances,counts.repeat_frame_comparison_attempts,counts.repeat_frame_comparisons,counts.repeat_frame_matched_bytes,counts.peak_reference_frames,counts.peak_reference_frame_bytes,counts.peak_live_candidate_frames,counts.peak_live_candidate_frame_bytes);
    if let Err(e)=emit(&final_json){eprintln!("ABBA reporting failed: {e}");std::process::exit(1);}
    if let Err(e)=result{eprintln!("ABBA failed: {e}");std::process::exit(1);}
}

