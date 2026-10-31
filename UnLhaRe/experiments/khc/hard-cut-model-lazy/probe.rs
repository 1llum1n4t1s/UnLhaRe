//! 新hard-cut private frameだけ。有限selfcheckと固定入力は別process。
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
#[path="adapter.rs"] mod float_cts;
mod float_scope;
use std::{fs::File,io::Read};
type Result<T>=std::result::Result<T,String>;
fn field(f:&[u8],at:usize)->usize{u32::from_le_bytes(f[at..at+4].try_into().expect("checked header")) as usize}
fn crc(parts:&[&[u8]])->u32{let mut c=u32::MAX;for part in parts{for &b in *part{c^=u32::from(b);for _ in 0..8{c=(c>>1)^if c&1!=0{0xedb88320}else{0};}}}!c}
fn execute()->Result<()>{
    let args:Vec<_>=std::env::args().collect();memory::validate_layout()?;
    if args.len()==2 && args[1]=="selfcheck"{return float_scope::codec::run_selfcheck();}
    if args.len()!=3 || args[1]!="fixed"{return Err("usage: selfcheck | fixed fixed-input".into());}
    let file=File::open(&args[2]).map_err(|e|e.to_string())?;let meta=file.metadata().map_err(|e|e.to_string())?;if !meta.is_file() || meta.len()!=2811006{return Err("fixed input length/type".into());}
    let mut input=Vec::new();input.try_reserve_exact(2811006).map_err(|_|"fixed input allocation")?;file.take(2811007).read_to_end(&mut input).map_err(|e|e.to_string())?;if input.len()!=2811006{return Err("fixed input grew".into());}
    let e=float_scope::codec::run_profile(&input,5)?;e.proof.validate_fixed(5)?;
    if e.frame.len()<73 || e.frame.len()>1048861 || &e.frame[..8]!=b"KHQCHC01" || field(&e.frame,8)!=input.len() || field(&e.frame,12)!=1762795 || field(&e.frame,16)!=257 || field(&e.frame,36)!=5{return Err("actual new magic/header".into());}
    let payload=field(&e.frame,20);let header=e.frame.len().checked_sub(payload).ok_or("header payload bound")?;if !(73..=285).contains(&header) || payload>1048576 || payload<5{return Err("actual header/payload layout".into());}
    if crc(&[&e.frame[..32],&e.frame[36..header]])!=field(&e.frame,32) as u32 || crc(&[&e.frame[header..]])!=field(&e.frame,28) as u32 || crc(&[&input])!=field(&e.frame,24) as u32 || field(&e.frame,24)!=433441561{return Err("actual common CRC".into());}
    let d=float_scope::codec::run_restore(&e.frame)?;d.proof.validate_fixed(5)?;if d.plain.len()!=input.len(){return Err("fixed plain length".into());}for(i,(&a,&b))in input.iter().zip(&d.plain).enumerate(){if a!=b{return Err(format!("fixed full plain byte {i}"));}}
    if e.proof!=d.proof || e.stats!=d.stats{return Err("fixed typed Proof14/full stats divergence".into());}
    let input_capacity=input.capacity();let frame_capacity=e.frame.capacity();let plain_capacity=d.plain.capacity();if input_capacity!=2811006 || frame_capacity>1048861 || plain_capacity>2811007{return Err("main data Vec capacities".into());}
    // 原Modelのprivate Vec getterを加えない。primary実sizeofと基礎配列source boundを区別。
    let primary_node_size=std::mem::size_of::<float_cts::Node>();let primary_source_bound=8190*primary_node_size+65536;
    let base_bound=16777216;let model_ram=base_bound+primary_source_bound+65536+65536+prices::MEMORY_BYTES+4194304;
    let encoder_phase=input_capacity+2*2811007+1048576*12+1048576+1048861+model_ram;
    let inverse_phase=input_capacity+frame_capacity+14*2811007+65536+4194304;
    let data_live=input_capacity+frame_capacity+plain_capacity;
    let phase=encoder_phase.max(inverse_phase).max(data_live+4194304);
    if primary_node_size>40 || model_ram>33554432 || phase>67108864{return Err("wire model/fixed-phase source bound".into());}
    let frame_bytes=e.frame.len();let gate=frame_bytes<=483599;let es=e.stats;let ds=d.stats;let proof=format!("{:?}",e.proof);let encode_ns=e.elapsed_ns;let decode_ns=d.elapsed_ns;
    drop(e.frame);drop(d.plain);drop(input);let(memory,peak)=memory::read_once()?;let peak_gate=peak.map_or("null",|v|if v{"true"}else{"false"});
    println!("{{\"status\":\"passed\",\"operation\":\"fixed-wire\",\"depth\":5,\"input_reads\":1,\"encode_calls\":1,\"decode_calls\":1,\"fixed_reencode_calls\":0,\"matched_plain_bytes\":2811006,\"all_plain_bytes_compared\":true,\"typed_Proof14_Eq\":true,\"encode_decode_full_stats_equal\":true,\"validate_fixed_calls\":2,\"new_magic\":\"KHQCHC01\",\"header_layout_and_CRC_checked\":true,\"frame_bytes\":{frame_bytes},\"header_bytes\":{header},\"payload_bytes\":{payload},\"size_gate_limit_bytes\":483599,\"size_gate_passed\":{gate},\"encode_stats\":{es},\"decode_stats\":{ds},\"Proof14_debug\":{proof:?},\"diagnostic_encode_ns\":{encode_ns},\"diagnostic_decode_ns\":{decode_ns},\"input_capacity\":{input_capacity},\"frame_capacity\":{frame_capacity},\"restored_plain_capacity\":{plain_capacity},\"actual_main_data_Vec_capacity_bytes\":{data_live},\"primary_node_size\":{primary_node_size},\"primary_source_bound_bytes\":{primary_source_bound},\"base_Model_source_bound_bytes\":{base_bound},\"base_private_Vec_capacities_measured\":false,\"price_static_bytes\":{},\"model_working_RAM_estimate_bytes\":{model_ram},\"encoder_phase_RAM_estimate_bytes\":{encoder_phase},\"inverse_phase_RAM_estimate_bytes\":{inverse_phase},\"fixed_phase_RAM_estimate_bytes\":{phase},\"model_RAM_limit_bytes\":33554432,\"fixed_phase_RAM_limit_bytes\":67108864,\"BWT_phase_RAM_estimate_bytes\":141598926,\"RAM_limit_bytes\":167772160,\"memory\":{memory},\"peak_WS_gate_only\":{peak_gate},\"old_teacher_numerical_equality_required\":false,\"primary_whole_state_comparison_claimed\":false,\"disk_frames\":0,\"disk_restores\":0,\"raw_event_Vecs\":0,\"speed_claimed\":false,\"portable_wire_verified\":false,\"adoption\":false}}",prices::MEMORY_BYTES);Ok(())
}
fn main(){if let Err(e)=execute(){eprintln!("causal-hard-cut-wire: {e}");std::process::exit(1);}}
