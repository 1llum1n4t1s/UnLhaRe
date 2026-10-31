//! 同一binary ABBA1周のRAM E2E。正式benchmarkや改善率ではない。
#![allow(dead_code)]
#[path="codec.rs"] mod codec;
#[path="../quaternary-cts-depth/integer_cts.rs"] mod new_cts;
#[path="comparison.rs"] mod comparison;
#[path="integer_cts.rs"] mod optimized_cts;
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
    input_read_attempts:usize,input_reads:usize,reference_stats_comparisons:usize,
    repeat_frame_comparison_attempts:usize,repeat_frame_comparisons:usize,
    repeat_frame_matched_bytes:usize,size_gate_passed_count:usize,
    peak_reference_frames:usize,peak_reference_frame_bytes:usize,
    peak_live_candidate_frames:usize,peak_live_candidate_frame_bytes:usize,
}
struct Reference {frame:Vec<u8>,stats:String,proof:codec::Proof}
const FIXED_STATS:&str=r#"{"depth":5,"node_count":1365,"node_storage_bytes":196560,"magic":"KHQCID01","header_crc_covers_depth":true,"frame_bytes":478750,"header_bytes":285,"payload_bytes":478465,"plain_crc":433441561,"payload_crc":3616798779,"header_crc":621578488,"runs":889227,"primary":1762795,"alphabet_symbols":257,"rank_intervals":889227,"length_intervals":889227,"escape_bytes":742,"branches":[2725772, 1099568],"grammar_digest":"58735a2b7383d755","base_pool_digest":"0caac94407124a37","class_observations":[889227, 620240, 1216305, 889227, 64372, 145969],"cdf_entropy_bits":3820763.985142052}"#;
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

fn candidate(optimized:bool,index:usize,input:&[u8],counts:&mut Accounting,reference:&mut Option<Reference>)->Result<String>{
    let implementation=if optimized{"new"}else{"old"};
    counts.encode_calls+=1;
    let encoded=if optimized{codec::optimized::run_profile(input,5)?}else{codec::run_profile(input,5)?};
    let live_count=usize::from(reference.is_some())+1;
    let live_bytes=reference.as_ref().map_or(0,|r|r.frame.len())+encoded.frame.len();
    counts.peak_live_candidate_frames=counts.peak_live_candidate_frames.max(live_count);
    counts.peak_live_candidate_frame_bytes=counts.peak_live_candidate_frame_bytes.max(live_bytes);
    if live_count>2||live_bytes>957500{return Err("pool ABBA frame buffer bound".into());}
    encoded.proof.validate_fixed(5)?;
    if encoded.frame.len()!=478750||encoded.stats!=FIXED_STATS{return Err("pool ABBA fixed frame/stats".into());}
    counts.decode_calls+=1;
    let decoded=if optimized{codec::optimized::run_restore(&encoded.frame)?}else{codec::run_restore(&encoded.frame)?};
    let matched=bytes_equal(&decoded.plain,input,"full plain")?;counts.plain_comparisons+=1;
    if encoded.proof!=decoded.proof||encoded.stats!=decoded.stats{return Err("pool encode/decode all Proof/stats differ".into());}
    counts.stats_comparisons+=1;decoded.proof.validate_fixed(5)?;
    if decoded.stats!=FIXED_STATS{return Err("pool decoded fixed stats".into());}
    if encoded.frame.len()>483599{return Err("pool actual size gate exceeded".into());}counts.size_gate_passed_count+=1;
    let stats_record=format!("\"encode_stats\":{},\"decode_stats\":{}",encoded.stats,decoded.stats);
    drop(decoded.plain);
    // frozen codec timer外。firstA全Proof/statsと後続全frameを直接比較、current即drop。
    let repeat_bytes=if index>0 {
        let prior=reference.as_ref().ok_or("pool missing first A reference")?;
        if encoded.proof!=prior.proof||encoded.stats!=prior.stats{return Err("pool reference all Proof/stats differ".into());}
        counts.reference_stats_comparisons+=1;counts.repeat_frame_comparison_attempts+=1;
        let compared=bytes_equal(&encoded.frame,&prior.frame,"pool whole reference frame")?;
        counts.repeat_frame_comparisons+=1;counts.repeat_frame_matched_bytes+=compared;
        drop(encoded.frame);if index==3{drop(reference.take());}compared
    }else{
        if reference.is_some(){return Err("pool duplicate reference".into());}
        *reference=Some(Reference{frame:encoded.frame,stats:encoded.stats,proof:encoded.proof});0
    };
    let held_count=usize::from(reference.is_some());let held_bytes=reference.as_ref().map_or(0,|r|r.frame.len());
    if held_count>1||held_bytes>478750{return Err("pool reference buffer bound".into());}
    counts.peak_reference_frames=counts.peak_reference_frames.max(held_count);
    counts.peak_reference_frame_bytes=counts.peak_reference_frame_bytes.max(held_bytes);
    Ok(format!("{{\"index\":{index},\"depth\":5,\"implementation\":\"{implementation}\",\"status\":\"passed\",\"encode_calls\":1,\"decode_calls\":1,{stats_record},\"stats_equal\":true,\"cdf_compared_as_bits\":true,\"all_proof_equal\":true,\"reference_all_proof_stats_compared\":{},\"encode_elapsed_ns\":{},\"decode_elapsed_ns\":{},\"matched_plain_bytes\":{matched},\"plain_equal\":true,\"size_gate_limit_bytes\":483599,\"size_gate_passed\":true,\"repeat_frame_compared\":{},\"repeat_frame_matched_bytes\":{repeat_bytes},\"candidate_frames_before_comparison\":{live_count},\"candidate_frame_bytes_before_comparison\":{live_bytes},\"reference_frames_after\":{held_count},\"reference_frame_bytes_after\":{held_bytes},\"error\":null}}",
        index>0,encoded.elapsed_ns,decoded.elapsed_ns,index>0))
}
fn execute(records:&mut Vec<String>,counts:&mut Accounting)->Result<()>{
    let args:Vec<_>=std::env::args_os().collect();if args.len()!=3||args[1]!="abba"{return Err("usage: pool_probe abba INPUT".into());}
    counts.input_read_attempts+=1;let input=read(Path::new(&args[2]),8*1024*1024)?;counts.input_reads+=1;
    if input.len()!=2811006{return Err("pool fixed input shape".into());}
    let mut reference=None;
    for (index,optimized) in [false,true,true,false].into_iter().enumerate(){
        match candidate(optimized,index,&input,counts,&mut reference){
            Ok(record)=>{emit(&format!("{{\"kind\":\"run\",\"record\":{record}}}"))?;records.push(record);}
            Err(e)=>{let implementation=if optimized{"new"}else{"old"};
                let record=format!("{{\"index\":{index},\"depth\":5,\"implementation\":\"{implementation}\",\"status\":\"failed\",\"error\":{}}}",quote(&e));
                emit(&format!("{{\"kind\":\"run\",\"record\":{record}}}"))?;records.push(record);return Err(e);}
        }
    }
    if reference.is_some()||counts.repeat_frame_comparisons!=3||counts.repeat_frame_matched_bytes!=1436250||counts.reference_stats_comparisons!=3{return Err("pool ABBA complete counts".into());}Ok(())
}
fn main(){
    let args:Vec<_>=std::env::args_os().collect();
    if args.len()==2 {
        let result=match args[1].to_str(){
            Some("compare-kt")=>Some(comparison::run()),
            Some("selfcheck")=>Some(codec::run_selfcheck()),Some("selfcheck-new")=>Some(codec::optimized::run_selfcheck()),_=>None};
        if let Some(result)=result{if let Err(e)=result{eprintln!("rejected: {e}");std::process::exit(1);}return;}
    }
    let mut records=Vec::new();let mut counts=Accounting::default();let result=execute(&mut records,&mut counts);
    let completed=records.iter().filter(|r|r.contains("\"status\":\"passed\"")).count();
    let status=if result.is_ok(){"passed"}else{"failed"};let error=result.as_ref().err().map_or("null".into(),|e|quote(e));
    let final_json=format!("{{\"kind\":\"final\",\"status\":\"{status}\",\"operation\":\"hamilton-select-abba\",\"depth_order\":[5,5,5,5],\"implementation_order\":[\"old\",\"new\",\"new\",\"old\"],\"records\":[{}],\"runs_completed\":{completed},\"encode_calls\":{},\"decode_calls\":{},\"plain_comparisons\":{},\"stats_comparisons\":{},\"reference_stats_comparisons\":{},\"expected_restored_bytes\":2811006,\"size_gate_passed_count\":{},\"input_read_attempts\":{},\"input_reads\":{},\"warmup_runs\":0,\"abba_cycles\":{},\"protocol_external_repeats\":0,\"repeat_frame_comparison_attempts\":{},\"repeat_frame_comparisons\":{},\"repeat_frame_matched_bytes\":{},\"peak_reference_frames\":{},\"peak_reference_frame_bytes\":{},\"peak_live_candidate_frames\":{},\"peak_live_candidate_frame_bytes\":{},\"references_remaining\":0,\"all_process_peak_verified\":false,\"frame_clones_created\":false,\"additional_repeats\":0,\"inner_timers\":false,\"full_input_canonical_reencoded\":false,\"disk_frames_created\":false,\"disk_restores_created\":false,\"diagnostic_only\":true,\"formal_speed_CPU_verified\":false,\"full_benchmark_allowed\":false,\"general_8MiB_input_supported\":false,\"timing_scope\":\"encode/decode calls only; excludes JSON/stats formatting/comparison/drop\",\"timing_limitations\":[\"single ABBA cycle\",\"no warmup\",\"code placement\",\"CPU scheduling\"],\"next_step\":\"single-cycle diagnostic only; parent evaluates Hamilton selection direction\",\"error\":{error}}}",
        records.join(","),counts.encode_calls,counts.decode_calls,counts.plain_comparisons,counts.stats_comparisons,counts.reference_stats_comparisons,
        counts.size_gate_passed_count,counts.input_read_attempts,counts.input_reads,usize::from(result.is_ok()),
        counts.repeat_frame_comparison_attempts,counts.repeat_frame_comparisons,counts.repeat_frame_matched_bytes,
        counts.peak_reference_frames,counts.peak_reference_frame_bytes,counts.peak_live_candidate_frames,counts.peak_live_candidate_frame_bytes);
    if let Err(e)=emit(&final_json){eprintln!("ABBA reporting failed: {e}");std::process::exit(1);}
    if let Err(e)=result{eprintln!("ABBA failed: {e}");std::process::exit(1);}
}


