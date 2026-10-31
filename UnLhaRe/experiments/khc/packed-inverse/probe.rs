mod reference;
mod contract;
mod packed;
mod happy;
mod adversarial;
mod memory;
#[path="../causal-bayes-sais/bwt.rs"] mod bwt;
use contract::{Result,reference_inverse,alphabet};
use std::time::Instant;
fn median(values:&[u64])->Result<f64>{
    if values.is_empty(){return Err("empty timing samples".into());}
    let mut sorted=values.to_vec();sorted.sort_unstable();let m=sorted.len()/2;
    Ok(if sorted.len()%2==1{sorted[m] as f64}else{(sorted[m-1] as f64+sorted[m] as f64)/2.0})
}
fn timed_reference(last:&[u16],primary:usize,symbols:&[u16])->Result<(Vec<u8>,u64)>{
    let args=std::hint::black_box((last,primary,symbols));let start=Instant::now();
    let result=reference_inverse(args.0,args.1,args.2)?;
    let ns=u64::try_from(start.elapsed().as_nanos()).map_err(|_|"timer ns overflow")?;
    Ok((result,ns))
}
fn timed_packed(last:&[u16],primary:usize,symbols:&[u16])->Result<(packed::Output,u64)>{
    let args=std::hint::black_box((last,primary,symbols));let start=Instant::now();
    let result=packed::inverse(args.0,args.1,args.2)?;
    let ns=u64::try_from(start.elapsed().as_nanos()).map_err(|_|"timer ns overflow")?;
    Ok((result,ns))
}
fn fixed(path:&str)->Result<String>{
    let plain=std::fs::read(path).map_err(|e|format!("fixed input read: {e}"))?;
    if plain.len()!=2811006{return Err("fixed input length".into());}
    let(last,primary)=bwt::bwt(&plain)?;let symbols=alphabet(&last)?;let n=last.len();
    if n!=2811007 || primary!=1762795{return Err("fixed BWT metadata".into());}
    // Warmup両1回。比較とcaller result dropは計時外、scratch dropは関数内。
    let reference=reference_inverse(&last,primary,&symbols)?;
    let candidate=packed::inverse(&last,primary,&symbols)?;
    if reference!=plain || candidate.plain!=plain || reference!=candidate.plain || candidate.route!="packed23"{return Err("fixed warmup full plain".into());}
    let scratch_capacity=candidate.scratch_capacity_words;let result_capacity=candidate.result_capacity;
    let reference_result_capacity=reference.capacity();drop(reference);drop(candidate);
    if scratch_capacity!=n || result_capacity!=n-1 || reference_result_capacity!=n-1{return Err("fixed capacity".into());}
    let mut samples=Vec::new();let mut ref_times=Vec::new();let mut packed_times=Vec::new();
    let mut rf_ref=Vec::new();let mut rf_packed=Vec::new();let mut pf_ref=Vec::new();let mut pf_packed=Vec::new();
    for pair in 0..9{
        let(reference,candidate,reference_ns,packed_ns)=if pair%2==0{
            let(r,rt)=timed_reference(&last,primary,&symbols)?;let(p,pt)=timed_packed(&last,primary,&symbols)?;(r,p,rt,pt)
        }else{let(p,pt)=timed_packed(&last,primary,&symbols)?;let(r,rt)=timed_reference(&last,primary,&symbols)?;(r,p,rt,pt)};
        if reference!=plain || candidate.plain!=plain || reference!=candidate.plain || candidate.route!="packed23" || candidate.scratch_capacity_words!=scratch_capacity || candidate.result_capacity!=result_capacity{return Err("fixed timed full plain/capacity".into());}
        let order=if pair%2==0{"reference-packed"}else{"packed-reference"};
        samples.push(format!("{{\"pair\":{pair},\"order\":\"{order}\",\"reference_ns\":{reference_ns},\"packed_ns\":{packed_ns}}}"));
        ref_times.push(reference_ns);packed_times.push(packed_ns);
        if pair%2==0{rf_ref.push(reference_ns);rf_packed.push(packed_ns);}else{pf_ref.push(reference_ns);pf_packed.push(packed_ns);}
    }
    let reference_working_logical=12*n-1;let candidate_working_capacity=scratch_capacity*4+result_capacity;
    let estimate=plain.capacity()+last.capacity()*2+reference_result_capacity+reference_working_logical+(4<<20);
    if estimate>160<<20{return Err("fixed phase RAM estimate".into());}
    Ok(format!("{{\"input_reads\":1,\"BWT_calls\":1,\"input_length\":{},\"n\":{n},\"primary\":{primary},\"alphabet_count\":{},\"input_capacity\":{},\"last_capacity\":{},\"reference_result_capacity\":{reference_result_capacity},\"packed_result_capacity\":{result_capacity},\"packed_scratch_capacity_words\":{scratch_capacity},\"reference_working_logical_bytes\":{reference_working_logical},\"packed_working_capacity_bytes\":{candidate_working_capacity},\"same_phase_RAM_estimate_bytes\":{estimate},\"warmups_each\":1,\"pairs\":9,\"timed_calls\":18,\"all_plain_direct_comparisons\":true,\"CPU_quiet_verified\":false,\"result_comparison_and_caller_drop_timed\":false,\"scratch_allocate_initialize_guard_walk_free_timed\":true,\"reference_median_ns\":{},\"packed_median_ns\":{},\"reference_first_pairs\":5,\"reference_first_reference_median_ns\":{},\"reference_first_packed_median_ns\":{},\"packed_first_pairs\":4,\"packed_first_reference_median_ns\":{},\"packed_first_packed_median_ns\":{},\"samples\":[{}]}}",plain.len(),symbols.len(),plain.capacity(),last.capacity(),median(&ref_times)?,median(&packed_times)?,median(&rf_ref)?,median(&rf_packed)?,median(&pf_ref)?,median(&pf_packed)?,samples.join(",")))
}
fn execute()->Result<()>{
    let args:Vec<_>=std::env::args().collect();if args.len()!=3 || args[1]!="screen"{return Err("usage: screen fixed-input".into());}
    memory::validate_layout()?;
    let small=happy::small()?;
    let(internal_rejections,wrapper_rejections,bit_roundtrips,bit_rejections)=adversarial::rejection_checks()?;
    if small!=9 || internal_rejections!=11 || wrapper_rejections!=3 || bit_roundtrips!=8 || bit_rejections!=2{return Err("E2E category extent".into());}
    let timings=fixed(&args[2])?;
    // fixed fixtureは関数復帰時に破棄済み。巨大boundaryをtiming後だけ実行。
    let boundaries=happy::boundaries()?;
    let(memory,peak_gate)=memory::read_once()?;
    let gate=peak_gate.map_or("null",|pass|if pass{"true"}else{"false"});
    println!("{{\"status\":\"passed\",\"kind\":\"packed_inverse_private_layout_diagnostic\",\"small_plain_cases\":{small},\"small_forward_BWT_calls\":{small},\"internal_inverse_rejections\":{internal_rejections},\"common_wrapper_rejections\":{wrapper_rejections},\"alphabet_wrapper_rejections\":2,\"length_wrapper_rejections\":1,\"bit_roundtrip_checks\":{bit_roundtrips},\"bit_rejections\":{bit_rejections},\"fixed\":{timings},\"boundaries\":{boundaries},\"memory\":{memory},\"RAM_estimate_limit_bytes\":167772160,\"BWT_phase_RAM_estimate_bytes\":141598926,\"precomputed_boundary_worst_bytes\":130023437,\"precomputed_fixed_worst_bytes\":49170413,\"peak_resource_gate_passed\":{gate},\"frame_encodes\":0,\"frame_decodes\":0,\"raw_trace_copies\":0,\"disk_plain_input_frame_copies\":0,\"formal_performance_claim\":false,\"four_native_verified\":false}}");Ok(())
}
fn main(){if let Err(error)=execute(){eprintln!("packed-inverse: {error}");std::process::exit(1);}}
