//! 数値body不変のprivate計器。合成finiteと実codec、固定profileは別process。
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
mod float_scope;
mod profile;
mod profile_e2e;
use std::{cell::Cell,fs::File,io::Read};
type Result<T> = std::result::Result<T,String>;
thread_local! { static MODEL_PREFIXES: Cell<Option<[[u64;4];2]>> = const { Cell::new(None) }; }
pub(crate) fn record_model_prefixes(v:[[u64;4];2]) { let _=MODEL_PREFIXES.try_with(|m|m.set(Some(v))); }
fn reset(enabled:bool,d:profile::Direction) { MODEL_PREFIXES.with(|m|m.set(None));profile::reset(enabled,d); }
fn mirror()->Result<[[u64;4];2]>{MODEL_PREFIXES.with(|m|m.get()).ok_or("Model prefix mirror absent".into())}
fn need(ok:bool,what:&str)->Result<()>{if ok{Ok(())}else{Err(what.into())}}
fn field(f:&[u8],at:usize)->usize{u32::from_le_bytes(f[at..at+4].try_into().expect("checked header")) as usize}
fn crc(parts:&[&[u8]])->u32{let mut c=u32::MAX;for part in parts{for &b in *part{c^=u32::from(b);for _ in 0..8{c=(c>>1)^if c&1!=0{0xedb88320}else{0};}}}!c}
fn check_ledger(r:&profile::Report,prefixes:[[u64;4];2],complete:bool)->Result<()> {
    profile::validate().map_err(|f|format!("profile fault {f:?}"))?;
    need(!r.synthetic&&!r.pending_branch&&!r.pending_stage&&!r.pending_whole&&r.first_fault.is_none()&&r.fault_count==0,"runtime scope/fault")?;
    for c in 0..2 {for k in 0..4 {
        let row=&r.strata[c*4+k];let n=row.branch.attempts;
        let samples=if n<128{0}else{(n-128)/256+1};
        need(row.samples==samples&&row.branch.timer_pairs==samples,"sample ordinal formula")?;
        need(row.branch.success==prefixes[c][k],"Model mirror commits")?;
        if complete {
            need(row.branch.error==0&&row.branch.success==n,"all branches committed")?;
            for child in row.child {need(child.attempts==n&&child.success==n&&child.error==0&&child.timer_pairs==samples,"four exact child census")?;}
        }
        if samples>0 {need(row.branch.ns>0,"positive parent timer")?;if complete{for child in row.child{need(child.ns>0,"positive child timer")?;}}}
    }}
    Ok(())
}
fn bucket_json(b:profile::Bucket)->String{format!("{{\"attempts\":{},\"success\":{},\"error\":{},\"timer_starts\":{},\"timer_ends\":{},\"timer_pairs\":{},\"ns\":{}}}",b.attempts,b.success,b.error,b.timer_starts,b.timer_ends,b.timer_pairs,b.ns)}
fn ledger_json(r:&profile::Report,prefixes:[[u64;4];2],elapsed:u64)->Result<String>{
    let mut rows=Vec::new();let(mut parent,mut cts,mut pool,mut residual)=(0.0,0.0,0.0,0.0);
    for idx in 0..8 {
        let row=r.strata[idx];let cts_ns=row.child[0].ns.checked_add(row.child[3].ns).ok_or("CTS time sum")?;
        let pool_ns=row.child[1].ns.checked_add(row.child[2].ns).ok_or("pool time sum")?;
        let rest=row.branch.ns.checked_sub(cts_ns.checked_add(pool_ns).ok_or("children sum")?).ok_or("parent child residual")?;
        let weight=if row.samples==0{0.0}else{row.branch.attempts as f64/row.samples as f64};
        let ep=row.branch.ns as f64*weight;let ec=cts_ns as f64*weight;let eo=pool_ns as f64*weight;let er=rest as f64*weight;
        need([weight,ep,ec,eo,er].iter().all(|n|n.is_finite()),"finite estimate")?;
        parent+=ep;cts+=ec;pool+=eo;residual+=er;
        let children=row.child.map(bucket_json).join(",");
        rows.push(format!("{{\"component\":{},\"prefix\":{},\"branch\":{},\"samples\":{},\"children\":[{}],\"sampled_CTS_ns\":{cts_ns},\"sampled_pool_ns\":{pool_ns},\"sampled_residual_ns\":{rest},\"estimated_parent_ns\":{ep:?},\"estimated_CTS_ns\":{ec:?},\"estimated_pool_ns\":{eo:?},\"estimated_residual_ns\":{er:?}}}",idx/4,idx%4+1,bucket_json(row.branch),row.samples,children));
    }
    let whole=r.whole.map(bucket_json).join(",");let estimated_whole_residual=elapsed as f64-parent;
    need([parent,cts,pool,residual,estimated_whole_residual].iter().all(|n|n.is_finite()),"finite total estimate")?;
    Ok(format!("{{\"direction\":\"{:?}\",\"strata\":[{}],\"whole\":[{}],\"Model_prefixes\":{:?},\"pending_branch\":false,\"pending_stage\":false,\"pending_whole\":false,\"first_fault\":null,\"fault_count\":0,\"synthetic\":false,\"state_bytes\":{},\"estimated_parent_ns\":{parent:?},\"estimated_CTS_ns\":{cts:?},\"estimated_pool_ns\":{pool:?},\"estimated_residual_ns\":{residual:?},\"whole_codec_ns\":{elapsed},\"estimated_whole_residual_ns\":{estimated_whole_residual:?},\"estimate_within_whole\":{},\"negative_estimate_clamped\":false,\"formal_CPU_fraction_claimed\":false}}",r.direction,rows.join(","),whole,prefixes,r.state_bytes,estimated_whole_residual>=0.0))
}
fn actual_cases()->Result<String>{
    use profile::Direction::{Encode,Decode};
    profile::audit_clear();
    // 1: disabled→enabled→disabledの同frame。常に最大2frame/1plain。
    {
        let input=b"profile lifecycle\0abcdabcdabcd";
        reset(false,Encode);let a=float_scope::codec::run_profile(input,5)?;
        reset(false,Decode);let d=float_scope::codec::run_restore(&a.frame)?;need(d.plain==input&&d.proof==a.proof&&d.stats==a.stats,"disabled lifecycle plain/proof/stats")?;drop(d);
        reset(true,Encode);let b=float_scope::codec::run_profile(input,5)?;let r=profile::snapshot();check_ledger(&r,mirror()?,true)?;
        need(a.frame==b.frame&&a.proof==b.proof&&a.stats==b.stats,"enabled lifecycle frame/proof/stats")?;
        reset(true,Decode);let d=float_scope::codec::run_restore(&b.frame)?;let r=profile::snapshot();check_ledger(&r,mirror()?,true)?;
        need(d.plain==input&&d.proof==b.proof&&d.stats==b.stats,"enabled lifecycle plain/proof/stats")?;drop(d);drop(b);
        reset(false,Encode);let b=float_scope::codec::run_profile(input,5)?;need(a.frame==b.frame&&a.proof==b.proof&&a.stats==b.stats,"disabled recovery frame/proof/stats")?;
    }
    // 2: 空inputのrank/length prefix1各1、実sampleは0。
    {
        reset(false,Encode);let a=float_scope::codec::run_profile(&[],5)?;
        reset(true,Encode);let b=float_scope::codec::run_profile(&[],5)?;let r=profile::snapshot();let m=mirror()?;check_ledger(&r,m,true)?;
        need(m==[[1,0,0,0],[1,0,0,0]]&&a.frame==b.frame&&a.proof==b.proof&&a.stats==b.stats,"empty prefix1/frame")?;drop(a);
        reset(true,Decode);let d=float_scope::codec::run_restore(&b.frame)?;let r=profile::snapshot();check_ledger(&r,mirror()?,true)?;
        need(d.plain.is_empty()&&d.proof==b.proof&&d.stats==b.stats,"empty decode proof")?;
    }
    // 3: 実decoder帰路→RAII abort→同process空decode復帰。
    let(aborts,samples)={
        let mut seed=0x6d2b79f5u32;let input:Vec<u8>=(0..4096).map(|_|{seed=seed.wrapping_mul(1664525).wrapping_add(1013904223);(seed>>24)as u8}).collect();
        reset(false,Encode);let mut e=float_scope::codec::run_profile(&input,5)?;
        let h=e.frame.len().checked_sub(field(&e.frame,20)).ok_or("fixture payload bound")?;
        e.frame.truncate(h+5);e.frame[20..24].copy_from_slice(&5u32.to_le_bytes());
        let pc=crc(&[&e.frame[h..]]);e.frame[28..32].copy_from_slice(&pc.to_le_bytes());
        let hc=crc(&[&e.frame[..32],&e.frame[36..h]]);e.frame[32..36].copy_from_slice(&hc.to_le_bytes());
        reset(true,Decode);let error=match float_scope::codec::run_restore(&e.frame){Err(e)=>e,Ok(_)=>return Err("truncated stream accepted".into())};
        need(error=="truncated range stream","actual numeric rejection reason")?;
        profile::validate().map_err(|f|format!("rejection ledger {f:?}"))?;let r=profile::snapshot();
        let aborts=r.strata.iter().try_fold(0u64,|n,row|n.checked_add(row.branch.error)).ok_or("abort sum")?;
        let samples=r.strata.iter().try_fold(0u64,|n,row|n.checked_add(row.samples)).ok_or("sample sum")?;
        need(aborts>=1&&!r.pending_branch&&!r.pending_stage,"actual rejection abort/clear")?;drop(e);drop(input);
        reset(false,Encode);let e=float_scope::codec::run_profile(&[],5)?;
        reset(true,Decode);let d=float_scope::codec::run_restore(&e.frame)?;let r=profile::snapshot();check_ledger(&r,mirror()?,true)?;
        need(d.plain.is_empty()&&d.proof==e.proof&&d.stats==e.stats,"sameprocess rejection recovery")?;
        (aborts,samples)
    };
    profile::audit_clear();reset(false,Encode);
    Ok(format!("{{\"cases\":3,\"lifecycle_triptych\":1,\"prefix1_empty\":1,\"truncated_recovery_sequence\":1,\"LCG_seed\":1831565813,\"truncated_payload_bytes\":5,\"numeric_error\":\"truncated range stream\",\"aborts\":{aborts},\"rejection_samples\":{samples},\"rejection_sample_clock_observed\":{},\"pending_none\":true,\"sameprocess_recovery\":true,\"direction_reset\":true,\"allframe_Proof14_stats_plain_compared\":true}}",samples>0))
}
fn execute()->Result<()> {
    memory::validate_layout()?;let args:Vec<_>=std::env::args().collect();
    if args.len()==2&&args[1]=="selfcheck" {
        let synthetic=profile_e2e::run()?;let actual=actual_cases()?;
        println!("{{\"status\":\"passed\",\"operation\":\"profile-fixtures\",\"synthetic\":{synthetic},\"actual\":{actual}}}");
        return float_scope::codec::run_selfcheck();
    }
    if args.len()!=3||args[1]!="profile"{return Err("usage: selfcheck | profile fixed-input".into());}
    let file=File::open(&args[2]).map_err(|e|e.to_string())?;let meta=file.metadata().map_err(|e|e.to_string())?;
    need(meta.is_file()&&meta.len()==2811006,"fixed input length/type")?;
    let mut input=Vec::new();input.try_reserve_exact(2811006).map_err(|_|"fixed input allocation")?;
    file.take(2811007).read_to_end(&mut input).map_err(|e|e.to_string())?;need(input.len()==2811006,"fixed input grew")?;
    profile::audit_clear();let clock_pair_ns=profile::empty_clock_pairs().map_err(|f|format!("clock calibration {f:?}"))?;
    reset(false,profile::Direction::Encode);let reference=float_scope::codec::run_profile(&input,5)?;
    reset(true,profile::Direction::Encode);let e=float_scope::codec::run_profile(&input,5)?;let er=profile::snapshot();let ep=mirror()?;
    check_ledger(&er,ep,true)?;e.proof.validate_fixed(5)?;
    need(reference.frame==e.frame&&reference.proof==e.proof&&reference.stats==e.stats,"disabled enabled fullframe/proof/stats")?;
    let reference_capacity=reference.frame.capacity();drop(reference);
    need(e.frame.len()==478856&&&e.frame[..8]==b"KHQCHC01"&&field(&e.frame,8)==input.len()&&field(&e.frame,12)==1762795&&field(&e.frame,16)==257&&field(&e.frame,36)==5,"fixed frame/header")?;
    let payload=field(&e.frame,20);let header=e.frame.len().checked_sub(payload).ok_or("header payload bound")?;
    need((73..=285).contains(&header)&&(5..=1048576).contains(&payload),"header payload layout")?;
    need(crc(&[&e.frame[..32],&e.frame[36..header]])==field(&e.frame,32)as u32&&crc(&[&e.frame[header..]])==field(&e.frame,28)as u32&&crc(&[&input])==field(&e.frame,24)as u32&&field(&e.frame,24)==433441561,"actual common CRC")?;
    reset(true,profile::Direction::Decode);let d=float_scope::codec::run_restore(&e.frame)?;let dr=profile::snapshot();let dp=mirror()?;
    check_ledger(&dr,dp,true)?;d.proof.validate_fixed(5)?;
    need(d.plain==input&&e.proof==d.proof&&e.stats==d.stats&&ep==dp,"fullplain/typedProof14/fullstats/prefixes")?;
    for(r,counts)in [(&er,[1,0,1]),(&dr,[0,1,1])]{for(id,want)in counts.into_iter().enumerate(){let b=r.whole[id];need(b.attempts==want&&b.success==want&&b.error==0&&b.timer_pairs==want&&(want==0||b.ns>0),"whole BWT/inverse/constructor census")?;}}
    let input_capacity=input.capacity();let frame_capacity=e.frame.capacity();let plain_capacity=d.plain.capacity();
    need(input_capacity==2811006&&reference_capacity<=1048861&&frame_capacity<=1048861&&plain_capacity<=2811007,"actual data capacities")?;
    // TLS state、2報告snapshot、mirrorを同時容量へ含める。64KiB予約でsource推定。
    let profiler_snapshot_bytes=2*std::mem::size_of::<profile::Report>();let mirror_bytes=std::mem::size_of::<Cell<Option<[[u64;4];2]>>>()+2*std::mem::size_of::<[[u64;4];2]>();
    let profiler_actual=er.state_bytes+profiler_snapshot_bytes+mirror_bytes;
    need(profiler_actual<=65536,"combined profiler/snapshot/mirror capacity")?;
    let primary_node_size=std::mem::size_of::<float_cts::Node>();let primary_source_bound=8190*primary_node_size+65536;
    let model_ram=16777216+primary_source_bound+65536+65536+prices::MEMORY_BYTES+4194304+65536;
    let encoder_phase=input_capacity+2*2811007+1048576*12+1048576+1048861+model_ram+1048861;
    let inverse_phase=input_capacity+frame_capacity+14*2811007+65536+4194304+65536;
    let data_live=input_capacity+frame_capacity+plain_capacity;let phase=encoder_phase.max(inverse_phase).max(data_live+4194304+65536);
    need(primary_node_size==40&&model_ram==21626800&&encoder_phase==45789030&&inverse_phase==46969336&&phase<=67108864,"resource source arithmetic")?;
    let ej=ledger_json(&er,ep,e.elapsed_ns)?;let dj=ledger_json(&dr,dp,d.elapsed_ns)?;
    let frame_bytes=e.frame.len();let es=e.stats;let ds=d.stats;let proof=format!("{:?}",e.proof);let encode_ns=e.elapsed_ns;let decode_ns=d.elapsed_ns;
    drop(e.frame);drop(d.plain);drop(input);let(mem,peak)=memory::read_once()?;let peak=peak.map_or("null",|v|if v{"true"}else{"false"});
    println!("{{\"status\":\"passed\",\"operation\":\"stage-profile\",\"depth\":5,\"input_reads\":1,\"disabled_encode_calls\":1,\"encode_calls\":1,\"decode_calls\":1,\"fixed_reencode_calls\":0,\"matched_plain_bytes\":2811006,\"all_frame_bytes_directly_compared\":true,\"all_plain_bytes_compared\":true,\"typed_Proof14_Eq\":true,\"all_stats_equal\":true,\"validate_fixed_calls\":2,\"new_magic\":\"KHQCHC01\",\"header_layout_and_CRC_checked\":true,\"frame_bytes\":{frame_bytes},\"header_bytes\":{header},\"payload_bytes\":{payload},\"size_gate_limit_bytes\":483599,\"size_gate_passed\":{},\"encode_stats\":{es},\"decode_stats\":{ds},\"Proof14_debug\":{proof:?},\"diagnostic_encode_ns\":{encode_ns},\"diagnostic_decode_ns\":{decode_ns},\"encode_profile\":{ej},\"decode_profile\":{dj},\"clock_pair_count\":10000,\"clock_pair_total_ns\":{clock_pair_ns},\"clock_correction_subtracted\":false,\"input_capacity\":{input_capacity},\"reference_frame_capacity\":{reference_capacity},\"reference_frame_dropped_before_restore\":true,\"frame_capacity\":{frame_capacity},\"restored_plain_capacity\":{plain_capacity},\"actual_main_data_Vec_capacity_bytes\":{data_live},\"primary_node_size\":{primary_node_size},\"primary_source_bound_bytes\":{primary_source_bound},\"base_Model_source_bound_bytes\":16777216,\"base_private_Vec_capacities_measured\":false,\"price_static_bytes\":65536,\"profiler_snapshot_Report_bytes\":{profiler_snapshot_bytes},\"profiler_mirror_Cell_and_copies_bytes\":{mirror_bytes},\"profiler_combined_actual_bytes\":{profiler_actual},\"profiler_source_reservation_bytes\":65536,\"model_working_RAM_estimate_bytes\":{model_ram},\"encoder_phase_RAM_estimate_bytes\":{encoder_phase},\"inverse_phase_RAM_estimate_bytes\":{inverse_phase},\"fixed_phase_RAM_estimate_bytes\":{phase},\"BWT_phase_RAM_estimate_bytes\":142713323,\"RAM_limit_bytes\":167772160,\"memory\":{mem},\"peak_WS_gate_only\":{peak},\"disabled_reference_is_independent_oracle\":false,\"per_branch_metrics_allocation\":false,\"disk_frames\":0,\"disk_restores\":0,\"raw_event_Vecs\":0,\"speed_claimed\":false,\"portable_wire_verified\":false,\"adoption\":false}}",frame_bytes<=483599);
    Ok(())
}
fn main(){if let Err(e)=execute(){eprintln!("hard-cut-stage-profile: {e}");std::process::exit(1);}}
