//! 先行E2E仕様。未来probeが独立control/candidate scopeとmemory/Resultを供給する。
//! 計測付きbinaryのGlobalAlloc trait呼出しだけ。非計測allocation/正式速度ではない。
use crate::{control_scope,candidate_scope,memory,Result};
use std::{alloc::{GlobalAlloc,Layout,System},sync::atomic::{AtomicBool,AtomicU64,Ordering},fs::File,io::Read};
const INPUT_BYTES:usize=2811006;
const MAX_FRAME:usize=1048861;
pub const SELFCHECK_COUNTS:(usize,usize,usize)=(14,34,4);
static MEASURING:AtomicBool=AtomicBool::new(false);
static ENABLED:AtomicBool=AtomicBool::new(false);
static OVERFLOW:AtomicBool=AtomicBool::new(false);
static ALLOC_CALLS:AtomicU64=AtomicU64::new(0);
static ALLOC_BYTES:AtomicU64=AtomicU64::new(0);
static ZERO_CALLS:AtomicU64=AtomicU64::new(0);
static ZERO_BYTES:AtomicU64=AtomicU64::new(0);
static REALLOC_CALLS:AtomicU64=AtomicU64::new(0);
static REALLOC_BYTES:AtomicU64=AtomicU64::new(0);
fn add(counter:&AtomicU64,value:u64){if counter.fetch_update(Ordering::Relaxed,Ordering::Relaxed,|old|old.checked_add(value)).is_err(){OVERFLOW.store(true,Ordering::Relaxed);}}
fn record(calls:&AtomicU64,bytes:&AtomicU64,size:usize){if ENABLED.load(Ordering::SeqCst){add(calls,1);match u64::try_from(size){Ok(n)=>add(bytes,n),Err(_)=>OVERFLOW.store(true,Ordering::Relaxed)}}}
struct DiagnosticAllocator;
#[global_allocator]
static GLOBAL:DiagnosticAllocator=DiagnosticAllocator;
// Systemへ同じLayout/pointer/new_sizeを渡すだけ。counterはallocationしない。
unsafe impl GlobalAlloc for DiagnosticAllocator{
    unsafe fn alloc(&self,layout:Layout)->*mut u8{record(&ALLOC_CALLS,&ALLOC_BYTES,layout.size());unsafe{System.alloc(layout)}}
    unsafe fn alloc_zeroed(&self,layout:Layout)->*mut u8{record(&ZERO_CALLS,&ZERO_BYTES,layout.size());unsafe{System.alloc_zeroed(layout)}}
    unsafe fn realloc(&self,ptr:*mut u8,layout:Layout,new_size:usize)->*mut u8{record(&REALLOC_CALLS,&REALLOC_BYTES,new_size);unsafe{System.realloc(ptr,layout,new_size)}}
    unsafe fn dealloc(&self,ptr:*mut u8,layout:Layout){unsafe{System.dealloc(ptr,layout)}}
}
#[derive(Clone,Copy,Debug,PartialEq,Eq)]
struct Counts{alloc_calls:u64,alloc_requested_bytes:u64,alloc_zeroed_calls:u64,alloc_zeroed_requested_bytes:u64,realloc_calls:u64,realloc_requested_bytes:u64}
impl Counts{
    fn load()->Self{Self{alloc_calls:ALLOC_CALLS.load(Ordering::Relaxed),alloc_requested_bytes:ALLOC_BYTES.load(Ordering::Relaxed),alloc_zeroed_calls:ZERO_CALLS.load(Ordering::Relaxed),alloc_zeroed_requested_bytes:ZERO_BYTES.load(Ordering::Relaxed),realloc_calls:REALLOC_CALLS.load(Ordering::Relaxed),realloc_requested_bytes:REALLOC_BYTES.load(Ordering::Relaxed)}}
    fn calls(&self)->Result<u64>{self.alloc_calls.checked_add(self.alloc_zeroed_calls).and_then(|n|n.checked_add(self.realloc_calls)).ok_or_else(||"allocation count sum overflow".into())}
    fn bytes(&self)->Result<u64>{self.alloc_requested_bytes.checked_add(self.alloc_zeroed_requested_bytes).and_then(|n|n.checked_add(self.realloc_requested_bytes)).ok_or_else(||"allocation requested-byte sum overflow".into())}
    fn json(&self)->Result<String>{Ok(format!("{{\"alloc_calls\":{},\"alloc_requested_bytes\":{},\"alloc_zeroed_calls\":{},\"alloc_zeroed_requested_bytes\":{},\"realloc_calls\":{},\"realloc_requested_bytes\":{},\"total_calls\":{},\"total_requested_bytes\":{}}}",self.alloc_calls,self.alloc_requested_bytes,self.alloc_zeroed_calls,self.alloc_zeroed_requested_bytes,self.realloc_calls,self.realloc_requested_bytes,self.calls()?,self.bytes()?))}
}
struct Measurement;
impl Measurement{
    fn begin()->Result<Self>{if MEASURING.compare_exchange(false,true,Ordering::SeqCst,Ordering::SeqCst).is_err(){return Err("nested allocation measurement".into());}for c in [&ALLOC_CALLS,&ALLOC_BYTES,&ZERO_CALLS,&ZERO_BYTES,&REALLOC_CALLS,&REALLOC_BYTES]{c.store(0,Ordering::Relaxed);}OVERFLOW.store(false,Ordering::Relaxed);ENABLED.store(true,Ordering::SeqCst);Ok(Self)}
}
impl Drop for Measurement{fn drop(&mut self){ENABLED.store(false,Ordering::SeqCst);MEASURING.store(false,Ordering::SeqCst);}}
fn measured<T>(operation:impl FnOnce()->Result<T>)->Result<(T,Counts)>{let guard=Measurement::begin()?;let value=operation();drop(guard);let counts=Counts::load();if OVERFLOW.load(Ordering::Relaxed){return Err("allocation counter overflow".into());}let _=counts.calls()?;let _=counts.bytes()?;Ok((value?,counts))}
fn equal(a:&[u8],b:&[u8],name:&str)->Result<usize>{if a.len()!=b.len(){return Err(format!("{name} length"));}for(i,(&a,&b))in a.iter().zip(b).enumerate(){if a!=b{return Err(format!("{name} byte {i}"));}}Ok(a.len())}
fn read_fixed(path:&str)->Result<Vec<u8>>{let file=File::open(path).map_err(|e|e.to_string())?;let info=file.metadata().map_err(|e|e.to_string())?;if !info.is_file() || info.len()!=INPUT_BYTES as u64{return Err("fixed input length/type".into());}let mut input=Vec::new();input.try_reserve_exact(INPUT_BYTES).map_err(|_|"input allocation")?;file.take(INPUT_BYTES as u64+1).read_to_end(&mut input).map_err(|e|e.to_string())?;if input.len()!=INPUT_BYTES{return Err("fixed input grew".into());}Ok(input)}
fn field(f:&[u8],at:usize)->usize{u32::from_le_bytes(f[at..at+4].try_into().expect("checked header")) as usize}
fn fixed_compare(path:&str)->Result<()>{
    // 一読だけ。I/O/Debug/比較/printlnは全てENABLED=falseの区間。
    let input=read_fixed(path)?;
    let(control,control_encode)=measured(||control_scope::codec::run_profile(&input,5))?;control.proof.validate_fixed(5)?;
    let(control_plain,control_decode)=measured(||control_scope::codec::run_restore(&control.frame))?;control_plain.proof.validate_fixed(5)?;equal(&control_plain.plain,&input,"control full plain")?;
    if control.proof!=control_plain.proof || control.stats!=control_plain.stats{return Err("control typed Proof14/full stats".into());}let control_plain_capacity=control_plain.plain.capacity();drop(control_plain);
    // 保持controlframe1個だけをcandidateのBWT/model/inverse lifetimeへ加える。
    let(candidate,candidate_encode)=measured(||candidate_scope::codec::run_profile(&input,5))?;candidate.proof.validate_fixed(5)?;
    let(candidate_plain,candidate_decode)=measured(||candidate_scope::codec::run_restore(&candidate.frame))?;candidate_plain.proof.validate_fixed(5)?;equal(&candidate_plain.plain,&input,"candidate full plain")?;
    if candidate.proof!=candidate_plain.proof || candidate.stats!=candidate_plain.stats{return Err("candidate typed Proof14/full stats".into());}let candidate_plain_capacity=candidate_plain.plain.capacity();drop(candidate_plain);
    let frame_bytes=equal(&control.frame,&candidate.frame,"control/candidate full frame")?;
    let control_debug=format!("{:?}",control.proof);let candidate_debug=format!("{:?}",candidate.proof);
    // private Proofは別Rust型。cross-typeはDebug exactでありtyped Eqではない。
    if control_debug!=candidate_debug || control.stats!=candidate.stats{return Err("cross-type Debug Proof14/full stats".into());}
    if frame_bytes<73 || frame_bytes>MAX_FRAME || &control.frame[..8]!=b"KHQCHC01" || field(&control.frame,8)!=INPUT_BYTES || field(&control.frame,36)!=5{return Err("common wire shape".into());}
    let payload_bytes=field(&control.frame,20);let header_bytes=frame_bytes.checked_sub(payload_bytes).ok_or("wire length")?;if frame_bytes!=478856 || field(&control.frame,28)!=2323132388 || field(&control.frame,32)!=735823295{return Err("frozen hard-cut control/candidate frame fields".into());}
    let input_capacity=input.capacity();let control_frame_capacity=control.frame.capacity();let candidate_frame_capacity=candidate.frame.capacity();if input_capacity!=INPUT_BYTES || control_frame_capacity>MAX_FRAME || candidate_frame_capacity>MAX_FRAME || control_plain_capacity>INPUT_BYTES+1 || candidate_plain_capacity>INPUT_BYTES+1{return Err("comparison Vec capacities".into());}
    let model_bound=16777216+8190*40+4*65536+4194304;
    let encoder_bound=input_capacity+MAX_FRAME+2*(INPUT_BYTES+1)+1048576*12+1048576+MAX_FRAME+model_bound;
    let inverse_bound=input_capacity+2*MAX_FRAME+14*(INPUT_BYTES+1)+65536+4194304;
    let phase_bound=encoder_bound.max(inverse_bound);let bwt_bound=141598926+MAX_FRAME;
    if model_bound>33554432 || phase_bound>67108864 || bwt_bound>167772160{return Err("two-frame source RAM bound".into());}
    let enc_call_delta=i128::from(control_encode.calls()?)-i128::from(candidate_encode.calls()?);let dec_call_delta=i128::from(control_decode.calls()?)-i128::from(candidate_decode.calls()?);
    let enc_byte_delta=i128::from(control_encode.bytes()?)-i128::from(candidate_encode.bytes()?);let dec_byte_delta=i128::from(control_decode.bytes()?)-i128::from(candidate_decode.bytes()?);
    let reduced=enc_call_delta>0 && dec_call_delta>0;let same=control_encode==candidate_encode && control_decode==candidate_decode;
    let ce=control_encode.json()?;let cd=control_decode.json()?;let ne=candidate_encode.json()?;let nd=candidate_decode.json()?;let stats=control.stats;
    drop(control.frame);drop(candidate.frame);drop(input);if ENABLED.load(Ordering::SeqCst) || MEASURING.load(Ordering::SeqCst){return Err("measurement leaked active".into());}let(memory,peak)=memory::read_once()?;let gate=peak.map_or("null",|v|if v{"true"}else{"false"});
    println!("{{\"status\":\"passed\",\"operation\":\"paired-fixed-allocation-diagnostic\",\"input_reads\":1,\"encode_calls_per_side\":1,\"decode_calls_per_side\":1,\"fixed_reencode_calls\":0,\"matched_plain_bytes_per_side\":2811006,\"matched_frame_bytes\":{frame_bytes},\"header_bytes\":{header_bytes},\"payload_bytes\":{payload_bytes},\"full_frames_equal\":true,\"typed_Proof14_Eq_per_side\":true,\"cross_type_typed_Proof_Eq\":false,\"cross_type_Debug_Proof14_exact_equal\":true,\"full_stats_equal\":true,\"Proof14_debug\":{control_debug:?},\"stats\":{stats},\"control_encode\":{ce},\"control_decode\":{cd},\"candidate_encode\":{ne},\"candidate_decode\":{nd},\"encode_call_reduction\":{enc_call_delta},\"decode_call_reduction\":{dec_call_delta},\"encode_requested_byte_reduction\":{enc_byte_delta},\"decode_requested_byte_reduction\":{dec_byte_delta},\"both_call_counts_reduced\":{reduced},\"all_allocation_counters_equal\":{same},\"requested_bytes_are_resident_or_physical_malloc_bytes\":false,\"measurement_API_includes_stats_Proof_construction\":true,\"I_O_comparison_reporting_in_measured_interval\":false,\"nested_measurements_allowed\":false,\"counter_overflow_checked\":true,\"global_allocator_process_single_thread_diagnostic\":true,\"noninstrumented_allocation_verified\":false,\"instrumented_times_used_for_formal_speed\":false,\"input_capacity\":{input_capacity},\"control_frame_capacity\":{control_frame_capacity},\"candidate_frame_capacity\":{candidate_frame_capacity},\"control_plain_capacity\":{control_plain_capacity},\"candidate_plain_capacity\":{candidate_plain_capacity},\"simultaneous_frame_limit\":2,\"simultaneous_plain_limit\":1,\"model_source_RAM_bound_bytes\":{model_bound},\"encoder_source_RAM_bound_bytes\":{encoder_bound},\"inverse_source_RAM_bound_bytes\":{inverse_bound},\"fixed_phase_source_RAM_bound_bytes\":{phase_bound},\"BWT_with_retained_frame_source_RAM_bound_bytes\":{bwt_bound},\"memory\":{memory},\"peak_WS_gate_only\":{gate},\"disk_input_frame_plain_copies\":0,\"settings_sweeps\":0,\"speed_claimed\":false,\"adoption\":false}}");Ok(())
}
pub(crate) fn run()->Result<()>{
    memory::validate_layout()?;let args:Vec<_>=std::env::args().collect();
    // 各selfcheckは原finite14/34/4と原memory wrapperの1JSONだけを出力する。
    if args.len()==2 && args[1]=="selfcheck-control"{return control_scope::codec::run_selfcheck();}
    if args.len()==2 && args[1]=="selfcheck-candidate"{return candidate_scope::codec::run_selfcheck();}
    if args.len()==3 && args[1]=="fixed-compare"{return fixed_compare(&args[2]);}
    Err("usage: selfcheck-control | selfcheck-candidate | fixed-compare fixed-input".into())
}
