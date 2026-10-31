#[path="../packed-inverse/reference.rs"] mod reference;
#[path="../packed-inverse/contract.rs"] mod contract;
#[path="../packed-inverse/packed.rs"] mod packed23;
#[path="../packed-inverse/memory.rs"] mod memory;
#[path="../causal-bayes-sais/bwt.rs"] mod bwt;
mod packed;
mod happy;
mod adversarial;
use contract::{Result,reference_inverse,alphabet};
use std::time::Instant;
struct Sample {plain:Vec<u8>,ns:u64,scratch_capacity:usize,result_capacity:usize,route:&'static str}
const NAMES:[&str;3]=["reference","packed23","packed24"];
const ORDERS:[[usize;3];3]=[[0,1,2],[1,2,0],[2,0,1]];
fn median(values:&[u64])->Result<f64>{
    if values.is_empty(){return Err("empty timing samples".into());}
    let mut sorted=values.to_vec();sorted.sort_unstable();let m=sorted.len()/2;
    Ok(if sorted.len()%2==1{sorted[m] as f64}else{(sorted[m-1] as f64+sorted[m] as f64)/2.0})
}
fn elapsed(start:Instant)->Result<u64>{u64::try_from(start.elapsed().as_nanos()).map_err(|_|"timer ns overflow".into())}
fn invoke(method:usize,last:&[u16],primary:usize,symbols:&[u16],timed:bool)->Result<Sample>{
    let args=std::hint::black_box((last,primary,symbols));
    match method{
        0=>{let start=Instant::now();let plain=reference_inverse(args.0,args.1,args.2)?;let ns=elapsed(start)?;let result_capacity=plain.capacity();Ok(Sample{plain,ns:if timed{ns}else{0},scratch_capacity:0,result_capacity,route:"reference"})},
        1=>{let start=Instant::now();let output=packed23::inverse(args.0,args.1,args.2)?;let ns=elapsed(start)?;Ok(Sample{plain:output.plain,ns:if timed{ns}else{0},scratch_capacity:output.scratch_capacity_words,result_capacity:output.result_capacity,route:output.route})},
        2=>{let start=Instant::now();let output=packed::inverse(args.0,args.1,args.2)?;let ns=elapsed(start)?;Ok(Sample{plain:output.plain,ns:if timed{ns}else{0},scratch_capacity:output.scratch_capacity_words,result_capacity:output.result_capacity,route:output.route})},
        _=>Err("diagnostic method index".into()),
    }
}
fn compare(outputs:&[Option<Sample>;3],plain:&[u8],n:usize)->Result<()>{
    let reference=outputs[0].as_ref().ok_or("missing reference")?;
    for (i,output) in outputs.iter().enumerate(){let output=output.as_ref().ok_or("missing inverse")?;
        if output.plain!=plain || output.plain!=reference.plain || output.result_capacity!=n-1 || output.route!=NAMES[i] || (i>0 && output.scratch_capacity!=n){return Err("fixed three-way all-plain/capacity/route".into());}
    }Ok(())
}
fn fixed(path:&str)->Result<String>{
    let plain=std::fs::read(path).map_err(|e|format!("fixed input read: {e}"))?;
    if plain.len()!=2811006{return Err("fixed input length".into());}
    let(last,primary)=bwt::bwt(&plain)?;let symbols=alphabet(&last)?;let n=last.len();
    if n!=2811007 || primary!=1762795{return Err("fixed BWT metadata".into());}
    {
        let mut warmup:[Option<Sample>;3]=std::array::from_fn(|_|None);
        for (i,slot) in warmup.iter_mut().enumerate(){*slot=Some(invoke(i,&last,primary,&symbols,false)?);}
        compare(&warmup,&plain,n)?;
    }
    let mut records=Vec::new();let mut times:[Vec<u64>;3]=std::array::from_fn(|_|Vec::new());
    let mut rotated:[[Vec<u64>;3];3]=std::array::from_fn(|_|std::array::from_fn(|_|Vec::new()));
    for round in 0..9{
        let rotation=round%3;let order=ORDERS[rotation];let mut outputs:[Option<Sample>;3]=std::array::from_fn(|_|None);
        for method in order{outputs[method]=Some(invoke(method,&last,primary,&symbols,true)?);}
        compare(&outputs,&plain,n)?;
        let ns=std::array::from_fn::<_,3,_>(|i|outputs[i].as_ref().unwrap().ns);
        records.push(format!("{{\"round\":{round},\"rotation\":{rotation},\"order\":[\"{}\",\"{}\",\"{}\"],\"reference_ns\":{},\"packed23_ns\":{},\"packed24_ns\":{}}}",NAMES[order[0]],NAMES[order[1]],NAMES[order[2]],ns[0],ns[1],ns[2]));
        for i in 0..3{times[i].push(ns[i]);rotated[rotation][i].push(ns[i]);}
    }
    let mut rotation_stats=Vec::new();
    for (rotation,samples) in rotated.iter().enumerate(){rotation_stats.push(format!("{{\"rotation\":{rotation},\"rounds\":3,\"reference_median_ns\":{},\"packed23_median_ns\":{},\"packed24_median_ns\":{}}}",median(&samples[0])?,median(&samples[1])?,median(&samples[2])?));}
    let reference_working_logical=12*n-1;let packed_working_capacity=4*n+(n-1);
    let estimate=plain.capacity()+last.capacity()*2+2*(n-1)+reference_working_logical+(4<<20);
    if estimate>160<<20{return Err("fixed phase RAM estimate".into());}
    Ok(format!("{{\"input_reads\":1,\"BWT_calls\":1,\"input_length\":{},\"n\":{n},\"primary\":{primary},\"alphabet_count\":{},\"input_capacity\":{},\"last_capacity\":{},\"reference_result_capacity\":{},\"packed23_scratch_capacity_words\":{n},\"packed24_scratch_capacity_words\":{n},\"packed_result_capacity_each\":{},\"reference_working_logical_bytes\":{reference_working_logical},\"packed_working_capacity_bytes_each\":{packed_working_capacity},\"same_phase_RAM_estimate_bytes\":{estimate},\"warmups_each\":1,\"rounds\":9,\"timed_calls\":27,\"all_plain_direct_comparisons\":true,\"CPU_quiet_verified\":false,\"result_comparison_and_caller_drop_timed\":false,\"scratch_allocate_initialize_guard_walk_free_timed\":true,\"reference_median_ns\":{},\"packed23_median_ns\":{},\"packed24_median_ns\":{},\"rotations\":[{}],\"samples\":[{}]}}",plain.len(),symbols.len(),plain.capacity(),last.capacity(),n-1,n-1,median(&times[0])?,median(&times[1])?,median(&times[2])?,rotation_stats.join(","),records.join(",")))
}
fn execute()->Result<()>{
    let args:Vec<_>=std::env::args().collect();if args.len()!=3 || args[1]!="screen"{return Err("usage: screen fixed-input".into());}
    memory::validate_layout()?;let small=happy::small()?;if small!=9{return Err("small category extent".into());}
    let rejections=adversarial::checks()?;
    let timings=fixed(&args[2])?;
    // fixed関数のfixture/result破棄後に巨大境界を一caseずつ実行。
    let boundaries=happy::boundaries()?;
    let(memory,peak_gate)=memory::read_once()?;let gate=peak_gate.map_or("null",|p|if p{"true"}else{"false"});
    println!("{{\"status\":\"passed\",\"kind\":\"permutation_inverse_private_layout_diagnostic\",\"small_plain_cases\":{small},\"small_forward_BWT_calls\":{small},\"rejections\":{rejections},\"fixed\":{timings},\"boundaries\":{boundaries},\"memory\":{memory},\"RAM_estimate_limit_bytes\":167772160,\"BWT_phase_RAM_estimate_bytes\":141598926,\"precomputed_boundary_worst_bytes\":130023437,\"precomputed_fixed_worst_bytes\":51981419,\"peak_resource_gate_passed\":{gate},\"frame_encodes\":0,\"frame_decodes\":0,\"raw_trace_copies\":0,\"disk_plain_input_frame_copies\":0,\"formal_performance_claim\":false,\"four_native_verified\":false}}");Ok(())
}
fn main(){if let Err(error)=execute(){eprintln!("permutation-inverse: {error}");std::process::exit(1);}}
