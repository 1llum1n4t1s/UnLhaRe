#[path="../packed-inverse/reference.rs"] mod reference;
#[path="../packed-inverse/contract.rs"] mod contract;
#[path="../packed-inverse/memory.rs"] mod memory;
#[path="../causal-bayes-sais/bwt.rs"] mod bwt;
#[path="../permutation-inverse/packed.rs"] mod packed;
mod anchored;
mod happy;
mod adversarial;
use contract::{Result,alphabet};
use std::time::Instant;
fn elapsed(start:Instant)->Result<u64>{u64::try_from(start.elapsed().as_nanos()).map_err(|_|"timer overflow".into())}
fn median(values:&[u64])->Result<f64>{if values.is_empty(){return Err("empty samples".into());}let mut sorted=values.to_vec();sorted.sort_unstable();let m=sorted.len()/2;Ok(if sorted.len()%2==1{sorted[m]as f64}else{(sorted[m-1]as f64+sorted[m]as f64)/2.0})}
fn invoke(candidate:bool,last:&[u16],primary:usize,symbols:&[u16],metadata:&[u8],plain:&[u8])->Result<u64>{
    let(last,primary,symbols,metadata)=std::hint::black_box((last,primary,symbols,metadata));
    let start=Instant::now();
    let(restore,capacity,result,route)=if candidate{let o=anchored::inverse(last,primary,symbols,metadata)?;(o.plain,o.scratch_capacity_words,o.result_capacity,o.route)}else{let o=packed::inverse(last,primary,symbols)?;(o.plain,o.scratch_capacity_words,o.result_capacity,o.route)};
    let ns=elapsed(start)?;
    if restore!=plain||capacity!=last.len()||result!=plain.len()||route!=if candidate{"anchored8"}else{"packed24"}{return Err("fixed fullplain/route/capacity".into());}
    drop(restore);Ok(ns)
}
fn fixed(path:&str)->Result<String>{
    let plain=std::fs::read(path).map_err(|e|e.to_string())?;if plain.len()!=2811006{return Err("fixed length".into());}
    let(last,primary)=bwt::bwt(&plain)?;let symbols=alphabet(&last)?;let n=last.len();if n!=2811007||primary!=1762795{return Err("fixed BWT".into());}
    let start=Instant::now();let metadata=anchored::generate(&last,primary,&symbols)?;let generation_ns=elapsed(start)?;
    if metadata.bytes.len()!=32||metadata.bytes.capacity()!=32||metadata.scratch_capacity_words!=n{return Err("fixed generation metadata/capacity".into());}
    let anchors=anchored::parse(&metadata.bytes,n,primary)?;
    let _=invoke(false,&last,primary,&symbols,&metadata.bytes,&plain)?;let _=invoke(true,&last,primary,&symbols,&metadata.bytes,&plain)?;
    let mut samples=Vec::new();let mut times:[Vec<u64>;2]=std::array::from_fn(|_|Vec::new());let mut order_times:[[Vec<u64>;2];2]=std::array::from_fn(|_|std::array::from_fn(|_|Vec::new()));
    for round in 0..9{let order=round%2;let methods=if order==0{[false,true]}else{[true,false]};let mut ns=[0u64;2];
        for candidate in methods{let i=usize::from(candidate);ns[i]=invoke(candidate,&last,primary,&symbols,&metadata.bytes,&plain)?;if ns[i]==0{return Err("positive timing".into());}times[i].push(ns[i]);order_times[order][i].push(ns[i]);}
        samples.push(format!("{{\"round\":{round},\"order\":\"{}\",\"old24_ns\":{},\"candidate_ns\":{}}}",if order==0{"AB"}else{"BA"},ns[0],ns[1]));
    }
    let generation_phase=plain.capacity()+last.capacity()*2+4*metadata.scratch_capacity_words+metadata.bytes.capacity()+(4<<20);
    let phase=plain.capacity()+last.capacity()*2+4*n+(n-1)+metadata.bytes.capacity()+(4<<20);
    if generation_phase>160<<20||phase>160<<20{return Err("fixed RAM estimate".into());}
    let hex:String=metadata.bytes.iter().map(|b|format!("{b:02x}")).collect();
    Ok(format!("{{\"input_reads\":1,\"BWT_calls\":1,\"n\":{n},\"primary\":{primary},\"metadata_generation_calls\":1,\"metadata_generation_ns\":{generation_ns},\"metadata_bytes\":32,\"metadata_hex\":\"{hex}\",\"anchors\":{anchors:?},\"generation_scratch_capacity_words\":{},\"input_capacity\":{},\"last_capacity\":{},\"metadata_capacity\":{},\"scratch_capacity_words_each\":{n},\"result_capacity_each\":{},\"generation_phase_RAM_estimate_bytes\":{generation_phase},\"same_phase_RAM_estimate_bytes\":{phase},\"warmups_each\":1,\"rounds\":9,\"timed_calls\":18,\"samples\":[{}],\"old24_median_ns\":{},\"candidate_median_ns\":{},\"AB_rounds\":5,\"BA_rounds\":4,\"AB_old24_median_ns\":{},\"AB_candidate_median_ns\":{},\"BA_old24_median_ns\":{},\"BA_candidate_median_ns\":{},\"all_plain_direct_comparisons\":true,\"metadata_generation_scratch_dropped_before_restore\":true,\"CPU_quiet_verified\":false,\"comparison_and_caller_drop_timed\":false,\"scratch_allocate_init_guard_walk_free_timed\":true,\"candidate_metadata_parse_timed\":true,\"encoder_metadata_cost_free\":false}}",metadata.scratch_capacity_words,plain.capacity(),last.capacity(),metadata.bytes.capacity(),n-1,samples.join(","),median(&times[0])?,median(&times[1])?,median(&order_times[0][0])?,median(&order_times[0][1])?,median(&order_times[1][0])?,median(&order_times[1][1])?))
}
fn execute()->Result<()>{
    let args:Vec<_>=std::env::args().collect();if args.len()!=3||args[1]!="screen"{return Err("usage: screen fixed-input".into());}
    memory::validate_layout()?;let small=happy::small()?;let rejected=adversarial::checks()?;
    let fixed=fixed(&args[2])?;let boundaries=happy::boundaries()?;
    let(mem,peak)=memory::read_once()?;let peak=peak.map_or("null",|p|if p{"true"}else{"false"});
    println!("{{\"status\":\"passed\",\"kind\":\"anchored_inverse_private_diagnostic\",\"small\":{small},\"rejections\":{rejected},\"fixed\":{fixed},\"boundaries\":{boundaries},\"memory\":{mem},\"peak_WS_gate_only\":{peak},\"BWT_phase_RAM_estimate_bytes\":141598926,\"boundary_reference_worst_bytes\":130023437,\"boundary_candidate_worst_bytes\":71303206,\"metadata_CRC_protected\":false,\"completed_archive_wire\":false,\"frame_encodes\":0,\"frame_decodes\":0,\"disk_plain_input_frame_copies\":0,\"raw_trace_copies\":0,\"formal_performance_claim\":false,\"four_native_verified\":false,\"adoption\":false}}");Ok(())
}
fn main(){if let Err(e)=execute(){eprintln!("anchored-inverse: {e}");std::process::exit(1);}}

