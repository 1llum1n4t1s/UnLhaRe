#[path="../packed-inverse/reference.rs"] mod reference;
#[path="../packed-inverse/contract.rs"] mod contract;
#[path="../packed-inverse/memory.rs"] mod memory;
#[path="../causal-bayes-sais/bwt.rs"] mod old_bwt;
#[path="../permutation-inverse/packed.rs"] mod packed;
#[path="../anchored-inverse/anchored.rs"] mod anchored;
mod bwt;
mod happy;
use contract::{Result,alphabet};
use std::time::Instant;
struct Output{last:Vec<u16>,primary:usize,metadata:Vec<u8>,bwt_ns:u64,LF_ns:u64,total_ns:u64}
fn elapsed(start:Instant)->Result<u64>{u64::try_from(start.elapsed().as_nanos()).map_err(|_|"timer overflow".into())}
fn old(input:&[u8],symbols:&[u16])->Result<Output>{let start=Instant::now();let t=Instant::now();let(last,primary)=old_bwt::bwt(std::hint::black_box(input))?;let bwt_ns=elapsed(t)?;let t=Instant::now();let metadata=anchored::generate(&last,primary,symbols)?;let LF_ns=elapsed(t)?;let total_ns=elapsed(start)?;Ok(Output{last,primary,metadata:metadata.bytes,bwt_ns,LF_ns,total_ns})}
fn new(input:&[u8])->Result<Output>{let start=Instant::now();let(last,primary,metadata)=bwt::bwt(std::hint::black_box(input))?;let total_ns=elapsed(start)?;Ok(Output{last,primary,metadata,bwt_ns:0,LF_ns:0,total_ns})}
fn equal(a:&Output,b:&Output)->Result<()>{if a.last!=b.last||a.primary!=b.primary||a.metadata!=b.metadata||a.metadata.len()!=32||a.primary!=1762795{return Err("whole pipeline last/primary/metadata".into());}Ok(())}
fn median(values:&[u64])->Result<f64>{if values.is_empty(){return Err("empty median".into());}let mut v=values.to_vec();v.sort_unstable();let m=v.len()/2;Ok(if v.len()%2==1{v[m]as f64}else{(v[m-1]as f64+v[m]as f64)/2.0})}
fn fixed(path:&str)->Result<String>{
    let input=std::fs::read(path).map_err(|e|e.to_string())?;if input.len()!=2811006{return Err("fixed input length".into());}
    let prep=Instant::now();let mut seen=[false;257];seen[0]=true;for &b in &input{seen[usize::from(b)+1]=true;}let symbols:Vec<u16>=seen.iter().enumerate().filter_map(|(i,&yes)|yes.then_some(i as u16)).collect();let alphabet_prep_ns=elapsed(prep)?;
    {let a=old(&input,&symbols)?;let b=new(&input)?;equal(&a,&b)?;if alphabet(&a.last)?!=symbols{return Err("prepared alphabet whole comparison".into());}}
    let mut records=Vec::new();let mut times:[Vec<u64>;4]=std::array::from_fn(|_|Vec::new());let mut ordered:[[Vec<u64>;2];2]=std::array::from_fn(|_|std::array::from_fn(|_|Vec::new()));
    let(mut last_capacity,mut metadata_capacity,mut final_last,mut final_metadata,mut primary)=(0usize,0usize,Vec::new(),Vec::new(),0usize);
    for round in 0..9{
        let order=round%2;
        let(a,b)=if order==0{let a=old(&input,&symbols)?;let b=new(&input)?;(a,b)}else{let b=new(&input)?;let a=old(&input,&symbols)?;(a,b)};
        equal(&a,&b)?;if a.last.len()!=2811007||b.last.len()!=2811007||[a.bwt_ns,a.LF_ns,a.total_ns,b.total_ns].contains(&0){return Err("fixed lengths/positive timer".into());}
        let timer_gap=a.total_ns.checked_sub(a.bwt_ns.checked_add(a.LF_ns).ok_or("component timer overflow")?).ok_or("component timer wall bound")?;
        last_capacity=last_capacity.max(a.last.capacity()).max(b.last.capacity());metadata_capacity=metadata_capacity.max(a.metadata.capacity()).max(b.metadata.capacity());
        if last_capacity!=2811007||metadata_capacity!=32{return Err("fixed Vec capacities".into());}
        records.push(format!("{{\"round\":{round},\"order\":\"{}\",\"old_BWT_ns\":{},\"old_LF_generation_ns\":{},\"old_total_ns\":{},\"new_total_ns\":{},\"old_total_minus_BWT_LF_ns\":{timer_gap}}}",if order==0{"AB"}else{"BA"},a.bwt_ns,a.LF_ns,a.total_ns,b.total_ns));
        for(i,value)in [a.bwt_ns,a.LF_ns,a.total_ns,b.total_ns].into_iter().enumerate(){times[i].push(value);}ordered[order][0].push(a.total_ns);ordered[order][1].push(b.total_ns);
        if round==8{final_last=b.last;final_metadata=b.metadata;primary=b.primary;}
    }
    let symbols=alphabet(&final_last)?;
    {let oldplain=packed::inverse(&final_last,primary,&symbols)?;if oldplain.plain!=input{return Err("fixed old all plain".into());}}
    let candidate=anchored::inverse(&final_last,primary,&symbols,&final_metadata)?;if candidate.plain!=input{return Err("fixed new all plain".into());}
    let restore_phase=input.capacity()+2*last_capacity+4*candidate.scratch_capacity_words+candidate.result_capacity+metadata_capacity+(4<<20);
    let extra_live=2*last_capacity+2*metadata_capacity+4096;let new_BWT_phase=141598926+extra_live;
    let old_LF_phase=input.capacity()+4*last_capacity+4*last_capacity+2*metadata_capacity+4096+(4<<20);
    if new_BWT_phase>160<<20||restore_phase>160<<20||old_LF_phase>160<<20{return Err("pipeline source RAM bound".into());}
    Ok(format!("{{\"input_reads\":1,\"alphabet_prep_calls\":1,\"alphabet_prep_ns\":{alphabet_prep_ns},\"alphabet_prep_outside_pipeline_timers\":true,\"alphabet_validation_calls\":1,\"prepared_alphabet_all_values_equal\":true,\"input_length\":2811006,\"input_capacity\":{},\"last_capacity_each\":{last_capacity},\"metadata_capacity_each\":{metadata_capacity},\"metadata_bytes\":32,\"n\":2811007,\"primary\":{primary},\"warmups_each\":1,\"rounds\":9,\"timed_calls\":18,\"timed_old_BWT_calls\":9,\"timed_old_LF_generation_calls\":9,\"timed_new_BWT_calls\":9,\"new_LF_generation_calls\":0,\"new_separate_SA_scans\":0,\"all18_pipeline_last_primary_metadata_comparisons\":true,\"all_plain_bytes_compared\":2811006,\"old_plain_dropped_before_candidate_restore\":true,\"candidate_scratch_capacity_words\":{},\"candidate_result_capacity\":{},\"new_BWT_source_phase_bytes\":{new_BWT_phase},\"both_BWT_phases_bound\":true,\"restore_alphabet_scan_calls\":1,\"old_LF_source_phase_bytes\":{old_LF_phase},\"restore_source_phase_bytes\":{restore_phase},\"old_BWT_median_ns\":{},\"old_LF_generation_median_ns\":{},\"old_total_median_ns\":{},\"new_total_median_ns\":{},\"AB_rounds\":5,\"BA_rounds\":4,\"AB_old_total_median_ns\":{},\"AB_new_total_median_ns\":{},\"BA_old_total_median_ns\":{},\"BA_new_total_median_ns\":{},\"samples\":[{}],\"CPU_quiet_verified\":false,\"comparison_and_caller_drop_timed\":false,\"function_SA_text_scratch_drop_timed\":true}}",input.capacity(),candidate.scratch_capacity_words,candidate.result_capacity,median(&times[0])?,median(&times[1])?,median(&times[2])?,median(&times[3])?,median(&ordered[0][0])?,median(&ordered[0][1])?,median(&ordered[1][0])?,median(&ordered[1][1])?,records.join(",")))
}
fn execute()->Result<()>{
    let args:Vec<_>=std::env::args().collect();if args.len()!=3||args[1]!="screen"{return Err("usage: screen fixed-input".into());}
    memory::validate_layout()?;let small=happy::small()?;let selector=happy::selector()?;let fixed=fixed(&args[2])?;
    let(mem,peak)=memory::read_once()?;let peak=peak.map_or("null",|p|if p{"true"}else{"false"});
    println!("{{\"status\":\"passed\",\"kind\":\"anchored_SA_generation_private_diagnostic\",\"small\":{small},\"selector\":{selector},\"fixed\":{fixed},\"memory\":{mem},\"peak_WS_gate_only\":{peak},\"metadata_CRC_protected\":false,\"completed_archive_wire\":false,\"formal_performance_claim\":false,\"four_native_verified\":false,\"adoption\":false,\"frame_encodes\":0,\"frame_decodes\":0,\"disk_plain_input_frame_copies\":0,\"raw_trace_copies\":0}}");Ok(())
}
fn main(){if let Err(e)=execute(){eprintln!("anchored-sa-generation: {e}");std::process::exit(1);}}

