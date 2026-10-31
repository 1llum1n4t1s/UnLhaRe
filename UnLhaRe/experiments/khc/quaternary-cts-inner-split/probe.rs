//! 数値不変のCTS/pool内訳診断。実時計は成功scopeの保存nsだけを報告する。
#![allow(dead_code)]
#[path="codec.rs"] mod codec;
#[path="integer_cts.rs"] mod new_cts;
#[path="../quaternary-cts-depth/integer_cts.rs"] mod frozen_cts;
#[path="../quaternary-cts-depth/model.rs"] mod frozen_model;
#[path="model.rs"] mod profiled_model;
#[path="../quaternary-cts-q32/integer_cts.rs"] mod reference_cts;
#[path="../quaternary-cts-integer-pool/fixed_math.rs"] mod fixed_math;
#[path="../quaternary-cts-integer-pool/integer_pool.rs"] mod integer_pool;
#[path="../causal-bayes-sais/bwt.rs"] mod bwt;
#[path="../rejected-binary-mix/packed_alphabet.rs"] mod packed_alphabet;
#[path="../direct-token/multi_range.rs"] mod multi_range;
// rootの二つのモデル契約もdepth CTSへ接続。旧modelは不変のpredictを呼ぶ。
use new_cts as integer_cts;
use std::{fs::File,io::{Read,Write},path::Path};
type Result<T>=std::result::Result<T,String>;
pub(crate) struct Encoded {frame:Vec<u8>,stats:String,proof:codec::Proof,elapsed_ns:u64}
pub(crate) struct Decoded {plain:Vec<u8>,stats:String,proof:codec::Proof,elapsed_ns:u64}
const FIXED_STATS:&str=r#"{"depth":5,"node_count":1365,"node_storage_bytes":196560,"magic":"KHQCID01","header_crc_covers_depth":true,"frame_bytes":478750,"header_bytes":285,"payload_bytes":478465,"plain_crc":433441561,"payload_crc":3616798779,"header_crc":621578488,"runs":889227,"primary":1762795,"alphabet_symbols":257,"rank_intervals":889227,"length_intervals":889227,"escape_bytes":742,"branches":[2725772, 1099568],"grammar_digest":"58735a2b7383d755","base_pool_digest":"0caac94407124a37","class_observations":[889227, 620240, 1216305, 889227, 64372, 145969],"cdf_entropy_bits":3820763.985142052}"#;

pub(crate) mod predict_profile {
    use super::Result;
    use std::{cell::RefCell,time::Instant};
    const TOTALS:[u64;8]=[121,415562,13461,2296628,1,71469,7502,1020596];
    const SAMPLES:[u64;8]=[0,1623,53,8971,0,279,29,3987];
    #[derive(Clone,Copy,Debug,Default,PartialEq,Eq)]
    struct Stratum {total:u64,samples:u64,started:u64,completed:u64,parent_ns:u64,cts_ns:u64,pool_ns:u64,residual_ns:u64,gather_ns:u64,kernel_ns:u64,seal_ns:u64,inner_residual_ns:u64,active:Option<u64>}
    #[derive(Clone,Copy,Debug,Default,PartialEq,Eq)]
    struct State {enabled:bool,strata:[Stratum;8]}
    #[derive(Clone,Copy,Debug)]
    struct Ticket {index:usize,ordinal:u64}
    fn add(a:u64,b:u64)->Result<u64>{a.checked_add(b).ok_or_else(||"profile counter/ns overflow".into())}
    impl State {
        fn admit(&mut self,component:usize,prefix:usize)->Result<Option<Ticket>> {
            if component>1||!(1..=4).contains(&prefix){return Err("profile component/prefix".into());}
            if !self.enabled{return Ok(None);}
            let index=component*4+prefix-1;let mut next=self.strata[index];let ordinal=add(next.total,1)?;
            next.total=ordinal;
            let sampled=ordinal%256==128;
            if sampled {
                if next.active.is_some(){return Err("profile overlapping sampled scope".into());}
                next.samples=add(next.samples,1)?;next.started=add(next.started,1)?;next.active=Some(ordinal);
            }
            self.strata[index]=next;
            Ok(sampled.then_some(Ticket{index,ordinal}))
        }
        fn complete(&mut self,ticket:Option<Ticket>,times:[u64;3],inner:[u64;3])->Result<()> {
            let Some(t)=ticket else {return Ok(());};
            let mut next=*self.strata.get(t.index).ok_or("profile ticket index")?;
            if !self.enabled||next.active!=Some(t.ordinal){return Err("profile stale scope".into());}
            let children=add(times[1],times[2])?;
            let residual=times[0].checked_sub(children).ok_or("profile negative residual")?;
            let inner_sum=add(add(inner[0],inner[1])?,inner[2])?;
            let inner_residual=times[1].checked_sub(inner_sum).ok_or("profile negative inner residual")?;
            next.completed=add(next.completed,1)?;
            next.parent_ns=add(next.parent_ns,times[0])?;next.cts_ns=add(next.cts_ns,times[1])?;
            next.pool_ns=add(next.pool_ns,times[2])?;next.residual_ns=add(next.residual_ns,residual)?;
            next.gather_ns=add(next.gather_ns,inner[0])?;next.kernel_ns=add(next.kernel_ns,inner[1])?;
            next.seal_ns=add(next.seal_ns,inner[2])?;next.inner_residual_ns=add(next.inner_residual_ns,inner_residual)?;
            next.active=None;self.strata[t.index]=next;Ok(())
        }
        fn snapshot(&self)->Result<Snapshot> {
            for s in &self.strata {
                if s.active.is_some()||s.started!=s.completed||s.samples!=s.completed{return Err("profile unfinished scope".into());}
                if add(add(s.cts_ns,s.pool_ns)?,s.residual_ns)?!=s.parent_ns{return Err("profile ns decomposition".into());}
                if add(add(add(s.gather_ns,s.kernel_ns)?,s.seal_ns)?,s.inner_residual_ns)?!=s.cts_ns{return Err("profile inner decomposition".into());}
            }
            Ok(Snapshot{strata:self.strata})
        }
    }
    thread_local! {static STATE:RefCell<State>=RefCell::new(State::default());}
    pub(crate) fn reset(enabled:bool)->Result<()> {
        STATE.with(|state|{let mut state=state.borrow_mut();state.snapshot()?;*state=State{enabled,..State::default()};Ok(())})
    }
    pub(crate) struct Scope {ticket:Option<Ticket>,parent:Option<Instant>,cts_ns:Option<u64>,pool_ns:Option<u64>,inner:Option<[u64;3]>}
    impl Scope {
        pub(crate) fn admit(component:usize,prefix:usize)->Result<Self> {
            let ticket=STATE.with(|state|state.borrow_mut().admit(component,prefix))?;
            let parent=ticket.map(|_|Instant::now());
            Ok(Self{ticket,parent,cts_ns:None,pool_ns:None,inner:None})
        }
        pub(crate) fn sampled(&self)->bool {self.ticket.is_some()}
        pub(crate) fn cts<T,E:Into<String>>(&mut self,call:impl FnOnce()->std::result::Result<(T,Option<[u64;3]>),E>)->Result<T> {
            if self.cts_ns.is_some()||self.pool_ns.is_some(){return Err("profile CTS order".into());}
            let Some(_)=self.ticket else {let (value,inner)=call().map_err(Into::into)?;if inner.is_some(){return Err("unsampled inner clocks".into());}return Ok(value);};
            let begin=Instant::now();let result=call();let ns=u64::try_from(begin.elapsed().as_nanos()).map_err(|_|"profile CTS timer overflow")?;
            let (value,inner)=result.map_err(Into::into)?;self.inner=Some(inner.ok_or("sampled inner missing")?);self.cts_ns=Some(ns);Ok(value)
        }
        pub(crate) fn pool<T,E:Into<String>>(&mut self,call:impl FnOnce()->std::result::Result<T,E>)->Result<T> {
            let Some(_)=self.ticket else {return call().map_err(Into::into);};
            if self.cts_ns.is_none()||self.pool_ns.is_some(){return Err("profile pool order".into());}
            let begin=Instant::now();let result=call();let ns=u64::try_from(begin.elapsed().as_nanos()).map_err(|_|"profile pool timer overflow")?;
            let value=result.map_err(Into::into)?;self.pool_ns=Some(ns);Ok(value)
        }
        pub(crate) fn finish(self)->Result<()> {
            let Some(begin)=self.parent else {return Ok(());};
            let parent=u64::try_from(begin.elapsed().as_nanos()).map_err(|_|"profile parent timer overflow")?;
            let times=[parent,self.cts_ns.ok_or("profile CTS missing")?,self.pool_ns.ok_or("profile pool missing")?];
            STATE.with(|state|state.borrow_mut().complete(self.ticket,times,self.inner.ok_or("inner missing")?))
        }
    }
    pub(crate) struct Snapshot {strata:[Stratum;8]}
    impl Snapshot {
        pub(crate) fn json(&self)->String {
            let totals=self.strata.map(|s|s.total);let samples=self.strata.map(|s|s.samples);
            let started=self.strata.map(|s|s.started);let completed=self.strata.map(|s|s.completed);
            let parent=self.strata.map(|s|s.parent_ns);let cts=self.strata.map(|s|s.cts_ns);
            let pool=self.strata.map(|s|s.pool_ns);let residual=self.strata.map(|s|s.residual_ns);
            let gather=self.strata.map(|s|s.gather_ns);let kernel=self.strata.map(|s|s.kernel_ns);let seal=self.strata.map(|s|s.seal_ns);let inner_residual=self.strata.map(|s|s.inner_residual_ns);
            format!("{{\"totals\":{totals:?},\"samples\":{samples:?},\"started\":{started:?},\"completed\":{completed:?},\"parent_ns\":{parent:?},\"cts_ns\":{cts:?},\"pool_ns\":{pool:?},\"residual_ns\":{residual:?},\"gather_ns\":{gather:?},\"kernel_ns\":{kernel:?},\"seal_ns\":{seal:?},\"inner_residual_ns\":{inner_residual:?},\"unfinished_scopes\":0,\"saved_outer_timer_pairs_per_completed_scope\":3,\"saved_inner_timer_boundaries_per_completed_scope\":4,\"actual_clock_read_attempts\":null,\"clock_reads_rollbackable\":false,\"observe_unmeasured\":true,\"size_of_stratum\":{},\"size_of_state\":{},\"size_of_scope\":{}}}",std::mem::size_of::<Stratum>(),std::mem::size_of::<State>(),std::mem::size_of::<Scope>())
        }
    }
    pub(crate) fn finish()->Result<Snapshot> {
        STATE.with(|state| {
            let state=state.borrow();let snapshot=state.snapshot()?;
            if state.enabled&&(snapshot.strata.map(|s|s.total)!=TOTALS||snapshot.strata.map(|s|s.samples)!=SAMPLES){return Err("profile fixed strata totals/samples".into());}
            let mut sum=0;for s in snapshot.strata {sum=add(sum,s.total)?;}
            if state.enabled&&sum!=3825340{return Err("profile total branches".into());}Ok(snapshot)
        })
    }
    // 計画済みの直接契約診断。実時計を使わず、拒否前後の全8層を比較する。
    pub(crate) fn contract()->Result<String> {
        let mut passed=0usize;let mut expected_errors=0usize;
        fn rejected(state:&mut State,operation:impl FnOnce(&mut State)->Result<()>,errors:&mut usize)->Result<()> {
            let before=*state;if operation(state).is_ok(){return Err("contract expected rejection".into());}
            if *state!=before{return Err("contract rejection mutated state".into());}*errors+=1;Ok(())
        }
        let mut state=State::default();let before=state;
        let t=state.admit(0,1)?;state.complete(t,[0,0,0],[0,0,0])?;state.snapshot()?;
        if state!=before{return Err("contract disabled mutated".into());}passed+=1;
        for enabled in [false,true] {
            let mut state=State{enabled,..State::default()};
            for (component,prefix) in [(2,1),(0,0),(1,5)] {
                rejected(&mut state,|s|s.admit(component,prefix).map(|_|()),&mut expected_errors)?;
            }
        }passed+=1;
        let mut state=State{enabled:true,..State::default()};
        for ordinal in 1..=386 {
            let t=state.admit(0,1)?;
            if [127,128,383,384,385].contains(&ordinal)&&t.is_some()!=(ordinal==128||ordinal==384){return Err("contract sample boundary".into());}
            state.complete(t,[30,10,10],[2,3,1])?;
        }
        if state.strata[0].total!=386||state.strata[0].samples!=2||state.strata[0].residual_ns!=20||state.strata[0].gather_ns!=4||state.strata[0].kernel_ns!=6||state.strata[0].seal_ns!=2||state.strata[0].inner_residual_ns!=8{return Err("contract boundary counters".into());}
        state.snapshot()?;passed+=1;
        let mut state=State{enabled:true,..State::default()};state.strata[0].total=127;
        let ticket=state.admit(0,1)?;
        rejected(&mut state,|s|s.complete(ticket,[19,10,10],[2,3,1]),&mut expected_errors)?;passed+=1;
        rejected(&mut state,|s|s.complete(ticket,[u64::MAX,u64::MAX,1],[2,3,1]),&mut expected_errors)?;passed+=1;
        rejected(&mut state,|s|s.complete(ticket,[30,10,10],[4,4,4]),&mut expected_errors)?;passed+=1;
        rejected(&mut state,|s|s.complete(ticket,[u64::MAX,u64::MAX,0],[u64::MAX,1,0]),&mut expected_errors)?;passed+=1;
        for field in 0..3 {
            let mut state=State{enabled:true,..State::default()};state.strata[0].total=127;
            match field {0=>state.strata[0].total=u64::MAX,1=>state.strata[0].samples=u64::MAX,_=>state.strata[0].started=u64::MAX}
            rejected(&mut state,|s|s.admit(0,1).map(|_|()),&mut expected_errors)?;
        }
        for field in 0..9 {
            let mut state=State{enabled:true,..State::default()};state.strata[0].total=127;let ticket=state.admit(0,1)?;
            match field {0=>state.strata[0].completed=u64::MAX,1=>state.strata[0].parent_ns=u64::MAX,2=>state.strata[0].cts_ns=u64::MAX,3=>state.strata[0].pool_ns=u64::MAX,4=>state.strata[0].residual_ns=u64::MAX,5=>state.strata[0].gather_ns=u64::MAX,6=>state.strata[0].kernel_ns=u64::MAX,7=>state.strata[0].seal_ns=u64::MAX,_=>state.strata[0].inner_residual_ns=u64::MAX}
            rejected(&mut state,|s|s.complete(ticket,[30,10,10],[2,3,1]),&mut expected_errors)?;
        }passed+=1;
        let before=state;if state.snapshot().is_ok()||state!=before{return Err("contract unfinished rejection".into());}
        expected_errors+=1;passed+=1;
        if passed!=9||expected_errors!=23{return Err("contract case accounting".into());}
        Ok(format!("{{\"status\":\"passed\",\"operation\":\"selfcheck-profile\",\"passed_cases\":{passed},\"expected_error_count\":{expected_errors},\"strata\":8,\"real_clock_reads\":0,\"rejection_state_preserved\":true}}"))
    }
}

// 時計を使わない直接CLI契約。sealed tokenの可変visible契約を旧/新で照合する。
fn cts_contract()->Result<(usize,usize)> {
    let mut accepted=0;let mut rejected=0;
    macro_rules! check {
        ($module:ident)=>{{
            let mut current=$module::Cts::new(5)?;
            let first=current.predict(0,4)?;current.observe(&first,0)?;accepted+=1;
            let before=current.clone();
            if current.observe(&first,0).is_ok()||current!=before{return Err("CTS stale rejection/state".into());}rejected+=1;
            let mut foreign=$module::Cts::new(5)?;
            let s=foreign.predict(0,4)?;foreign.observe(&s,1)?;
            let mut repaired=foreign.predict(0,4)?;
            let now=current.predict(0,4)?;
            *std::ops::DerefMut::deref_mut(&mut repaired)=std::ops::Deref::deref(&now).clone();
            let mut expected=current.clone();expected.observe(&now,2)?;
            current.observe(&repaired,2)?;
            if current!=expected{return Err("CTS repaired visible acceptance/state".into());}accepted+=1;
            let mut changed=current.predict(0,4)?;changed.kernel.mixed[0][0]^=1;
            let before=current.clone();if current.observe(&changed,0).is_ok()||current!=before{return Err("CTS modified derived rejection/state".into());}rejected+=1;
            let mut tail=current.predict(0,4)?;tail.kernel.mixed[$module::LEVELS-1][3]^=1;
            let before=current.clone();if current.observe(&tail,0).is_ok()||current!=before{return Err("CTS tail rejection/state".into());}rejected+=1;
        }};
    }
    check!(frozen_cts);check!(new_cts);
    if accepted!=4||rejected!=6{return Err("CTS contract accounting".into());}Ok((accepted,rejected))
}
fn contracts()->Result<String> {
    let counters=predict_profile::contract()?;
    predict_profile::reset(false)?;
    let old=frozen_model::rejection_checks(5)?;let new=profiled_model::rejection_checks(5)?;
    if old!=(14,16,1)||new!=(14,16,1){return Err("model contract tuple".into());}
    let (accepted,rejected)=cts_contract()?;
    Ok(format!("{{\"status\":\"passed\",\"operation\":\"selfcheck-inner\",\"counter_contract\":{counters},\"old_model_tuple\":[14,16,1],\"new_model_tuple\":[14,16,1],\"cts_accepted\":{accepted},\"cts_rejected\":{rejected},\"repaired_current_visible_accepted_both\":true,\"cts_full_state_rejection_preserved\":true,\"real_clock_reads\":0,\"size_of_node\":{},\"size_of_kernel\":{},\"size_of_raw_snapshot\":{},\"size_of_sealed_snapshot\":{},\"size_of_cts\":{}}}",std::mem::size_of::<new_cts::Node>(),std::mem::size_of::<new_cts::Kernel>(),std::mem::size_of::<reference_cts::Snapshot>(),std::mem::size_of::<new_cts::Snapshot>(),std::mem::size_of::<new_cts::Cts>()))
}

fn read(path:&Path)->Result<Vec<u8>> {
    let file=File::open(path).map_err(|e|format!("input open: {e}"))?;
    let meta=file.metadata().map_err(|e|format!("input metadata: {e}"))?;
    if !meta.is_file()||meta.len()!=2811006{return Err("fixed input type/length".into());}
    let mut input=Vec::new();input.try_reserve_exact(2811006).map_err(|_|"input allocation")?;
    file.take(2811007).read_to_end(&mut input).map_err(|e|format!("input read: {e}"))?;
    if input.len()!=2811006{return Err("fixed input changed length".into());}Ok(input)
}
fn bytes_equal(a:&[u8],b:&[u8],scope:&str)->Result<usize> {
    if a.len()!=b.len(){return Err(format!("{scope} length mismatch"));}
    for (index,(&a,&b)) in a.iter().zip(b).enumerate(){if a!=b{return Err(format!("{scope} mismatch at {index}"));}}Ok(a.len())
}
fn outer_profile(path:&Path)->Result<String> {
    let input=read(path)?;
    predict_profile::reset(false)?;
    let baseline=codec::run_profile(&input,5)?;baseline.proof.validate_fixed(5)?;
    if baseline.frame.len()!=478750||baseline.stats!=FIXED_STATS{return Err("baseline fixed frame/stats".into());}
    predict_profile::reset(true)?;
    let encoded=codec::optimized::run_profile(&input,5)?;
    let encode_profile=predict_profile::finish()?;encoded.proof.validate_fixed(5)?;
    let live_bytes=baseline.frame.len().checked_add(encoded.frame.len()).ok_or("frame byte overflow")?;
    if live_bytes>957500||encoded.frame.len()!=478750{return Err("two frame bound".into());}
    let frame_matched=bytes_equal(&baseline.frame,&encoded.frame,"full frame")?;
    if baseline.proof!=encoded.proof||baseline.stats!=encoded.stats{return Err("baseline/profile all Proof/stats differ".into());}
    let baseline_elapsed_ns=baseline.elapsed_ns;drop(baseline.frame);
    predict_profile::reset(true)?;
    let decoded=codec::optimized::run_restore(&encoded.frame)?;
    let decode_profile=predict_profile::finish()?;decoded.proof.validate_fixed(5)?;
    let plain_matched=bytes_equal(&input,&decoded.plain,"full plain")?;
    if encoded.proof!=decoded.proof||encoded.stats!=decoded.stats||decoded.stats!=FIXED_STATS{return Err("profile encode/decode all Proof/stats differ".into());}
    let encode_elapsed_ns=encoded.elapsed_ns;let decode_elapsed_ns=decoded.elapsed_ns;
    let stats=encoded.stats;drop(encoded.frame);drop(decoded.plain);
    // 3組目はbaselineとdecodedのstats。部分move後も同じ文字列を直接比較する。
    if baseline.stats!=decoded.stats{return Err("baseline/decode stats differ".into());}
    predict_profile::reset(false)?;
    Ok(format!("{{\"status\":\"passed\",\"operation\":\"cts-inner-split\",\"depth\":5,\"input_read_attempts\":1,\"input_reads\":1,\"baseline_encode_calls\":1,\"profile_encode_calls\":1,\"profile_decode_calls\":1,\"encode_calls\":2,\"decode_calls\":1,\"frame_comparisons\":1,\"frame_matched_bytes\":{frame_matched},\"plain_comparisons\":1,\"plain_matched_bytes\":{plain_matched},\"proof_comparisons\":2,\"proof_fields_per_comparison\":14,\"cdf_compared_as_bits\":true,\"stats_comparisons\":3,\"peak_live_candidate_frames\":2,\"peak_live_candidate_frame_bytes\":{live_bytes},\"frames_remaining\":0,\"baseline_encode_elapsed_ns\":{baseline_elapsed_ns},\"profile_encode_elapsed_ns\":{encode_elapsed_ns},\"profile_decode_elapsed_ns\":{decode_elapsed_ns},\"predict_profile_encode\":{},\"predict_profile_decode\":{},\"fixed_stats\":{stats},\"timing_scope\":\"parent: after context/count retrieval, before CTS through pool completion; not full predict\",\"sampling_rule\":\"component*4+prefix-1; one-based ordinal%256==128; independent encode/decode\",\"saved_ns_transactional\":true,\"clock_attempts_not_rollbackable_or_counted\":true,\"sample_zero_time_unknown\":true,\"extrapolated\":false,\"overhead_corrected\":false,\"disk_frames_created\":false,\"disk_restores_created\":false,\"observe_unmeasured\":true,\"clock_and_layout_perturb_tiny_spans\":true,\"speed_claim\":false,\"diagnostic_only\":true,\"formal_speed_CPU_verified\":false}}",encode_profile.json(),decode_profile.json()))
}
fn profile(path:&Path)->Result<String> {
    // 外側の既存E2E比較をそのまま実行し、診断範囲を明示する。
    let line=outer_profile(path)?;
    Ok(line.replace("\"operation\":\"cts-predict-split\"","\"operation\":\"cts-inner-split\"")
        .replace("\"timing_scope\":","\"observe_unmeasured\":true,\"inner_timing_scope\":\"predict guard/gather; Kernel; snapshot construction/seal; enclosing CTS residual\",\"clock_and_layout_perturb_tiny_spans\":true,\"speed_claim\":false,\"timing_scope\":"))
}
fn quote(text:&str)->String {
    let mut out=String::from("\"");for c in text.chars().take(1024){match c {
        '"'=>out.push_str("\\\""),'\\'=>out.push_str("\\\\"),'\n'=>out.push_str("\\n"),'\r'=>out.push_str("\\r"),'\t'=>out.push_str("\\t"),
        c if c<' '=>out.push_str(&format!("\\u{:04x}",c as u32)),c=>out.push(c)}}out.push('"');out
}
fn main() {
    let args:Vec<_>=std::env::args_os().collect();
    let result=if args.len()==2&&args[1]=="selfcheck-inner" {contracts()}
        else if args.len()==3&&args[1]=="profile" {profile(Path::new(&args[2]))}
        else {Err("usage: inner_split_probe selfcheck-inner | profile INPUT".into())};
    let line=match &result {Ok(line)=>line.clone(),Err(error)=>format!("{{\"status\":\"failed\",\"error\":{}}}",quote(error))};
    println!("{line}");if let Err(error)=std::io::stdout().flush(){eprintln!("JSON flush: {error}");std::process::exit(1);}
    if let Err(error)=result {eprintln!("rejected: {error}");std::process::exit(1);}
}
