//! 固定lookup-float referenceと新計器を同一process/RAMで直接比較する診断。
#![allow(dead_code)]
#[path="../lookup-float-cts/float_math.rs"] mod float_math;
#[path="../lookup-float-cts/float_cts.rs"] mod float_cts;
#[path="../lookup-float-cts/float_pool.rs"] mod float_pool;
#[path="../quaternary-cts-integer-pool/fixed_math.rs"] mod fixed_math;
#[path="../lookup-float-cts/float_scope.rs"] mod reference;
#[path="../causal-bayes-sais/bwt.rs"] mod bwt;
#[path="../rejected-binary-mix/packed_alphabet.rs"] mod packed_alphabet;
#[path="../direct-token/multi_range.rs"] mod multi_range;
mod profile_scope;
mod timing;
mod proof;
use std::{fs::File,io::Read,time::Instant};
type Result<T>=std::result::Result<T,String>;
fn equal(a:&[u8],b:&[u8],label:&str)->Result<usize>{
    if a.len()!=b.len(){return Err(format!("{label} length {} != {}",a.len(),b.len()));}
    for(i,(&x,&y)) in a.iter().zip(b).enumerate(){if x!=y{return Err(format!("{label} first different byte {i}: {x} != {y}"));}}Ok(a.len())
}
fn proof_equal(a:&proof::Proof14,b:&proof::Proof14)->Result<()>{if a!=b{return Err(format!("typed Proof14 differs {a:?} != {b:?}"));}Ok(())}
fn check(case:&str,bytes:&[u8],fixed:bool)->Result<(String,timing::State,timing::State)> {
    timing::reset(false);
    let re=reference::codec::run_profile(bytes,5)?;
    let rd=reference::codec::run_restore(&re.frame)?;
    let rp=proof::Proof14::frozen_debug(&format!("{:?}",re.proof))?;
    let rdp=proof::Proof14::frozen_debug(&format!("{:?}",rd.proof))?;
    proof_equal(&rp,&rdp)?;
    if timing::snapshot()!=timing::State::default(){return Err("reference touched profile state".into());}
    timing::reset(true);
    let pe=profile_scope::codec::run_profile(bytes,5)?;
    let en=timing::snapshot();en.validate()?;
    timing::reset(true);
    let pd=profile_scope::codec::run_restore(&re.frame)?;
    let de=timing::snapshot();de.validate()?;
    equal(&re.frame,&pe.frame,"complete reference/profile frame")?;
    equal(bytes,&rd.plain,"reference direct plain")?;
    equal(bytes,&pd.plain,"profile direct plain")?;
    equal(&rd.plain,&pd.plain,"both decoders direct plain")?;
    proof_equal(&rp,&pe.proof.projection())?;proof_equal(&rp,&pd.proof.projection())?;
    if re.stats!=rd.stats||re.stats!=pe.stats||re.stats!=pd.stats{return Err("full stats strings differ".into());}
    if en.totals!=de.totals||en.samples!=de.samples{return Err("encode/decode strata differ".into());}
    if fixed {
        re.proof.validate_fixed(5)?;rd.proof.validate_fixed(5)?;pe.proof.validate_fixed(5)?;pd.proof.validate_fixed(5)?;
        if re.frame.len()!=478750||en.totals.iter().sum::<u64>()!=3825340||en.totals[..4].iter().sum::<u64>()!=2725772||en.totals[4..].iter().sum::<u64>()!=1099568{return Err("fixed frozen shape/counters".into());}
    }
    Ok((format!("{{\"case\":\"{case}\",\"input_bytes\":{},\"frame_bytes\":{},\"complete_frame_compared\":true,\"direct_plain_comparisons\":3,\"typed_Proof14_comparisons\":3,\"full_stats_comparisons\":3,\"proof\":{},\"stats\":{},\"reference_encode_ns\":{},\"reference_decode_ns\":{},\"encode\":{},\"decode\":{}}}",bytes.len(),re.frame.len(),rp.json(),re.stats,re.elapsed_ns,rd.elapsed_ns,en.json(pe.elapsed_ns),de.json(pd.elapsed_ns)),en,de))
}
fn run()->Result<String>{
    let args=std::env::args_os().collect::<Vec<_>>();if args.len()!=3||args[1]!="profile"{return Err("usage: lookup-float-profile profile INPUT".into());}
    let f=File::open(&args[2]).map_err(|e|format!("fixed input open {e}"))?;let metadata=f.metadata().map_err(|e|e.to_string())?;
    if !metadata.is_file()||metadata.len()!=2811006{return Err("fixed input length/type".into());}
    let mut bytes=Vec::new();bytes.try_reserve_exact(2811006).map_err(|_|"input allocation")?;
    f.take(2811007).read_to_end(&mut bytes).map_err(|e|e.to_string())?;if bytes.len()!=2811006{return Err("fixed input changed length".into());}
    let clock_start=Instant::now();let mut clock_ns=0u128;for _ in 0..10000{let begin=Instant::now();clock_ns+=begin.elapsed().as_nanos();}let clock_whole=clock_start.elapsed().as_nanos();
    let mut records=Vec::new();
    for (name,small) in [("empty",Vec::new()),("small-1",vec![255]),("small-all256",(0..1024).map(|i|(i%256) as u8).collect()),("small-text",b"lookup f64 staged E2E\n".repeat(32))]{records.push(check(name,&small,false)?.0);}
    records.push(check("fixed-all-group",&bytes,true)?.0);
    timing::reset(false);
    Ok(format!("{{\"status\":\"passed\",\"diagnostic_only\":true,\"formal_performance\":false,\"independent_existing_reference_module\":true,\"proof_comparison\":\"strict lossless frozen Debug -> typed all 14 fields including cdf_bits and every array element\",\"cases\":5,\"codec_calls\":{{\"reference_encode\":5,\"reference_decode\":5,\"profile_encode\":5,\"profile_decode\":5}},\"clock_calibration\":{{\"pairs\":10000,\"sum_interval_ns\":{clock_ns},\"whole_loop_ns\":{clock_whole},\"subtracted\":false}},\"records\":[{}],\"limitations\":[\"fixed private Proof Debug layout required\",\"deterministic periodic sampling bias\",\"timer resolution and bookkeeping disturb residual\",\"all branches execute TLS and RefCell bookkeeping, including unsampled marks\",\"child timing accumulation occurs inside parent residual\",\"stratum estimates are not formal performance or improvement rates\",\"nonbranch transforms escapes framing validation and state digest remain in whole residual\"],\"disk_frame_plain_input_copies\":0,\"raw_traces\":0}}",records.join(",")))
}
fn main(){match run(){Ok(json)=>{if json.len()>65535{eprintln!("CLI JSON bound");std::process::exit(2);}println!("{json}");},Err(e)=>{eprintln!("rejected: {e}");std::process::exit(1);}}}
