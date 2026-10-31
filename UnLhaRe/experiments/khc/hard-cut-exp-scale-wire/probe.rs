//! 計器/allocatorなしの通常wire旧新各1回。単回screenで正式速度ではない。
#![allow(dead_code,unused_imports)]
#[path="../causal-bayes-sais/bwt.rs"] mod bwt;
#[path="../rejected-binary-mix/packed_alphabet.rs"] mod packed_alphabet;
#[path="../direct-token/multi_range.rs"] mod multi_range;
#[path="../lookup-float-cts/float_cts.rs"] mod old_cts;
#[path="../lookup-float-cts/float_math.rs"] mod float_math;
#[path="../lookup-float-cts/float_pool.rs"] mod float_pool;
#[path="../quaternary-cts-integer-pool/fixed_math.rs"] mod fixed_math;
#[path="../prices.rs"] mod prices;
#[path="../packed-inverse/reference.rs"] mod reference;
#[path="../packed-inverse/contract.rs"] mod contract;
#[path="../packed-inverse/memory.rs"] mod memory;
#[path="../hard-cut-model-lazy/adapter.rs"] mod float_cts;
#[path="../hard-cut-exp-scale/scaled_math.rs"] mod scaled_math;
mod scaled_pool;
mod control_scope;
mod candidate_scope;
use std::{fs::File,io::Read};
type Result<T> = std::result::Result<T,String>;
const INPUT:usize=2811006;
const MAX_FRAME:usize=1048861;
fn need(ok:bool,why:&str)->Result<()>{if ok{Ok(())}else{Err(why.into())}}
fn field(frame:&[u8],at:usize)->usize{u32::from_le_bytes(frame[at..at+4].try_into().expect("checked header"))as usize}
fn crc(parts:&[&[u8]])->u32{let mut c=u32::MAX;for part in parts{for &b in *part{c^=u32::from(b);for _ in 0..8{c=(c>>1)^if c&1!=0{0xedb88320}else{0};}}}!c}
fn check_frame(frame:&[u8],input:&[u8])->Result<(usize,usize)>{
    need(frame.len()==478856&&frame.len()<=MAX_FRAME,"frame size")?;
    need(&frame[..8]==b"KHQCHC01"&&field(frame,8)==INPUT&&field(frame,12)==1762795&&field(frame,16)==257&&field(frame,36)==5,"magic/header/grammar")?;
    let payload=field(frame,20);let header=frame.len().checked_sub(payload).ok_or("header payload bound")?;
    need(header==285&&payload==478571&&(73..=285).contains(&header)&&(5..=1048576).contains(&payload),"header payload layout")?;
    need(crc(&[&frame[..32],&frame[36..header]])==field(frame,32)as u32,"header CRC")?;
    need(crc(&[&frame[header..]])==field(frame,28)as u32,"payload CRC")?;
    need(crc(&[input])==field(frame,24)as u32&&field(frame,24)==433441561,"input CRC")?;
    Ok((header,payload))
}
fn full_plain(input:&[u8],plain:&[u8],side:&str)->Result<()>{
    need(plain.len()==input.len(),"plain length")?;
    for(i,(&a,&b))in input.iter().zip(plain).enumerate(){if a!=b{return Err(format!("{side} plain byte {i}"));}}
    Ok(())
}
fn execute()->Result<()>{
    memory::validate_layout()?;let mut args=std::env::args();let _=args.next();let command=args.next().ok_or("usage: selfcontrol | selfcandidate | pair fixedInput")?;
    if command=="selfcontrol" {need(args.next().is_none(),"selfcontrol arguments")?;return control_scope::codec::run_selfcheck();}
    if command=="selfcandidate" {need(args.next().is_none(),"selfcandidate arguments")?;return candidate_scope::codec::run_selfcheck();}
    need(command=="pair","unknown command")?;let path=args.next().ok_or("pair input missing")?;need(args.next().is_none(),"pair arguments")?;
    let file=File::open(path).map_err(|e|e.to_string())?;let meta=file.metadata().map_err(|e|e.to_string())?;
    need(meta.is_file()&&meta.len()==INPUT as u64,"fixed input length/type")?;
    let mut input=Vec::new();input.try_reserve_exact(INPUT).map_err(|_|"fixed input allocation")?;
    file.take(INPUT as u64+1).read_to_end(&mut input).map_err(|e|e.to_string())?;need(input.len()==INPUT,"fixed input grew")?;
    let ce=control_scope::codec::run_profile(&input,5)?;ce.proof.validate_fixed(5)?;
    let ne=candidate_scope::codec::run_profile(&input,5)?;ne.proof.validate_fixed(5)?;
    need(ce.frame==ne.frame,"full old/new frame bytes")?;
    let(header,payload)=check_frame(&ce.frame,&input)?;need(check_frame(&ne.frame,&input)?==(header,payload),"both layouts")?;
    let proof=format!("{:?}",ce.proof);need(format!("{:?}",ne.proof)==proof,"cross encode Debug14")?;
    need(ce.stats==ne.stats,"both full encode stats")?;
    let cd=control_scope::codec::run_restore(&ce.frame)?;cd.proof.validate_fixed(5)?;
    full_plain(&input,&cd.plain,"control")?;need(ce.proof==cd.proof&&ce.stats==cd.stats,"control typedProof14/fullstats")?;
    need(format!("{:?}",cd.proof)==proof,"control decode Debug14")?;
    let control_plain_capacity=cd.plain.capacity();let control_decode_stats=cd.stats;let control_decode_ns=cd.elapsed_ns;
    drop(cd.plain); // 最大2frame/1plain。候補inverse前に旧plainを解放する。
    let nd=candidate_scope::codec::run_restore(&ne.frame)?;nd.proof.validate_fixed(5)?;
    full_plain(&input,&nd.plain,"candidate")?;need(ne.proof==nd.proof&&ne.stats==nd.stats,"candidate typedProof14/fullstats")?;
    need(format!("{:?}",nd.proof)==proof&&control_decode_stats==nd.stats,"cross decode Debug14/fullstats")?;
    let input_capacity=input.capacity();let control_frame_capacity=ce.frame.capacity();let candidate_frame_capacity=ne.frame.capacity();let candidate_plain_capacity=nd.plain.capacity();
    need(input_capacity==INPUT&&[control_frame_capacity,candidate_frame_capacity].iter().all(|&n|(478856..=MAX_FRAME).contains(&n))&&[control_plain_capacity,candidate_plain_capacity].iter().all(|&n|(INPUT..=INPUT+1).contains(&n)),"actual Vec capacities")?;
    let primary_node_size=std::mem::size_of::<float_cts::Node>();let primary_source_bound=8190*primary_node_size+65536;
    let model_ram=16777216+primary_source_bound+65536+65536+prices::MEMORY_BYTES+4194304;
    let encoder_phase=input_capacity+2*(INPUT+1)+1048576*12+1048576+MAX_FRAME+model_ram+MAX_FRAME;
    let inverse_phase=input_capacity+control_frame_capacity+candidate_frame_capacity+14*(INPUT+1)+65536+4194304;
    let data_live=input_capacity+control_frame_capacity+candidate_frame_capacity+control_plain_capacity.max(candidate_plain_capacity);
    let phase=encoder_phase.max(inverse_phase).max(data_live+4194304);
    need(primary_node_size==40&&model_ram==21561264&&encoder_phase==45723494&&model_ram<=33554432&&phase<=67108864,"source RAM bound")?;
    let control_encode_ns=ce.elapsed_ns;let candidate_encode_ns=ne.elapsed_ns;let candidate_decode_ns=nd.elapsed_ns;
    let control_encode_stats=ce.stats;let candidate_encode_stats=ne.stats;let candidate_decode_stats=nd.stats;
    drop(ce.frame);drop(ne.frame);drop(nd.plain);drop(input);
    let(mem,peak)=memory::read_once()?;let peak=peak.map_or("null",|v|if v{"true"}else{"false"});
    println!("{{\"status\":\"passed\",\"operation\":\"exp-scale-wire-pair\",\"depth\":5,\"input_reads\":1,\"control_encode_calls\":1,\"candidate_encode_calls\":1,\"control_decode_calls\":1,\"candidate_decode_calls\":1,\"fixed_reencode_calls\":0,\"validate_fixed_calls\":4,\"matched_plain_bytes\":2811006,\"frame_bytes\":478856,\"control_frame_bytes\":478856,\"candidate_frame_bytes\":478856,\"header_bytes\":{header},\"payload_bytes\":{payload},\"size_gate_limit_bytes\":483599,\"size_gate_passed\":true,\"new_magic\":\"KHQCHC01\",\"all_frame_bytes_directly_compared\":true,\"all_plain_bytes_compared\":true,\"typed_Proof14_each_direction_Eq\":true,\"control_typed_Proof14_Eq\":true,\"candidate_typed_Proof14_Eq\":true,\"cross_Proof14_Debug_equal\":true,\"cross_typed_Proof_Eq_claimed\":false,\"all_stats_equal\":true,\"header_layout_and_CRC_checked\":true,\"Proof14_debug\":{proof:?},\"control_encode_stats\":{control_encode_stats},\"candidate_encode_stats\":{candidate_encode_stats},\"control_decode_stats\":{control_decode_stats},\"candidate_decode_stats\":{candidate_decode_stats},\"control_encode_ns\":{control_encode_ns},\"candidate_encode_ns\":{candidate_encode_ns},\"control_decode_ns\":{control_decode_ns},\"candidate_decode_ns\":{candidate_decode_ns},\"input_capacity\":{input_capacity},\"control_frame_capacity\":{control_frame_capacity},\"candidate_frame_capacity\":{candidate_frame_capacity},\"control_plain_capacity\":{control_plain_capacity},\"candidate_plain_capacity\":{candidate_plain_capacity},\"old_plain_dropped_before_candidate_restore\":true,\"reference_frames_held_through_restores\":2,\"actual_main_data_Vec_capacity_peak_bytes\":{data_live},\"primary_node_size\":{primary_node_size},\"primary_source_bound_bytes\":{primary_source_bound},\"base_Model_source_bound_bytes\":16777216,\"base_private_Vec_capacities_measured\":false,\"price_static_bytes\":65536,\"model_working_RAM_estimate_bytes\":{model_ram},\"encoder_phase_RAM_estimate_bytes\":{encoder_phase},\"inverse_phase_RAM_estimate_bytes\":{inverse_phase},\"fixed_phase_RAM_estimate_bytes\":{phase},\"BWT_phase_RAM_estimate_bytes\":142647787,\"RAM_limit_bytes\":167772160,\"memory\":{mem},\"peak_WS_gate_only\":{peak},\"custom_allocator_linked\":false,\"stage_profile_linked\":false,\"disk_frames\":0,\"disk_restores\":0,\"raw_event_Vecs\":0,\"control_first\":true,\"warmups\":0,\"speed_claimed\":false,\"formal_speed_verified\":false,\"native4_verified\":false,\"adoption\":false}}");
    Ok(())
}
fn main(){if let Err(e)=execute(){eprintln!("hard-cut-exp-scale-wire: {e}");std::process::exit(1);}}
