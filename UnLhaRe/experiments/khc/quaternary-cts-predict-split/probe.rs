//! 数値不変のCTS/pool内訳診断。実時計は成功scopeの保存nsだけを報告する。
#![allow(dead_code)]
#[path="codec.rs"] mod codec;
#[path="../quaternary-cts-depth/integer_cts.rs"] mod new_cts;
#[path="../quaternary-cts-q32/integer_cts.rs"] mod reference_cts;
#[path="../quaternary-cts-integer-pool/fixed_math.rs"] mod fixed_math;
#[path="../quaternary-cts-integer-pool/integer_pool.rs"] mod integer_pool;
#[path="../causal-bayes-sais/bwt.rs"] mod bwt;
#[path="../rejected-binary-mix/packed_alphabet.rs"] mod packed_alphabet;
#[path="../direct-token/multi_range.rs"] mod multi_range;
use reference_cts as integer_cts;
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
    struct Stratum {total:u64,samples:u64,started:u64,completed:u64,parent_ns:u64,cts_ns:u64,pool_ns:u64,residual_ns:u64,active:Option<u64>}
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
        fn complete(&mut self,ticket:Option<Ticket>,times:[u64;3])->Result<()> {
            let Some(t)=ticket else {return Ok(());};
            let mut next=*self.strata.get(t.index).ok_or("profile ticket index")?;
            if !self.enabled||next.active!=Some(t.ordinal){return Err("profile stale scope".into());}
            let children=add(times[1],times[2])?;
            let residual=times[0].checked_sub(children).ok_or("profile negative residual")?;
            next.completed=add(next.completed,1)?;
            next.parent_ns=add(next.parent_ns,times[0])?;next.cts_ns=add(next.cts_ns,times[1])?;
            next.pool_ns=add(next.pool_ns,times[2])?;next.residual_ns=add(next.residual_ns,residual)?;
            next.active=None;self.strata[t.index]=next;Ok(())
        }
        fn snapshot(&self)->Result<Snapshot> {
            for s in &self.strata {
                if s.active.is_some()||s.started!=s.completed||s.samples!=s.completed{return Err("profile unfinished scope".into());}
                if add(add(s.cts_ns,s.pool_ns)?,s.residual_ns)?!=s.parent_ns{return Err("profile ns decomposition".into());}
            }
            Ok(Snapshot{strata:self.strata})
        }
    }
    thread_local! {static STATE:RefCell<State>=RefCell::new(State::default());}
    pub(crate) fn reset(enabled:bool)->Result<()> {
        STATE.with(|state|{let mut state=state.borrow_mut();state.snapshot()?;*state=State{enabled,..State::default()};Ok(())})
    }
    pub(crate) struct Scope {ticket:Option<Ticket>,parent:Option<Instant>,cts_ns:Option<u64>,pool_ns:Option<u64>}
    impl Scope {
        pub(crate) fn admit(component:usize,prefix:usize)->Result<Self> {
            let ticket=STATE.with(|state|state.borrow_mut().admit(component,prefix))?;
            let parent=ticket.map(|_|Instant::now());
            Ok(Self{ticket,parent,cts_ns:None,pool_ns:None})
        }
        pub(crate) fn cts<T,E:Into<String>>(&mut self,call:impl FnOnce()->std::result::Result<T,E>)->Result<T> {
            if self.cts_ns.is_some()||self.pool_ns.is_some(){return Err("profile CTS order".into());}
            let Some(_)=self.ticket else {return call().map_err(Into::into);};
            let begin=Instant::now();let result=call();let ns=u64::try_from(begin.elapsed().as_nanos()).map_err(|_|"profile CTS timer overflow")?;
            let value=result.map_err(Into::into)?;self.cts_ns=Some(ns);Ok(value)
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
            STATE.with(|state|state.borrow_mut().complete(self.ticket,times))
        }
    }
    pub(crate) struct Snapshot {strata:[Stratum;8]}
    impl Snapshot {
        pub(crate) fn json(&self)->String {
            let totals=self.strata.map(|s|s.total);let samples=self.strata.map(|s|s.samples);
            let started=self.strata.map(|s|s.started);let completed=self.strata.map(|s|s.completed);
            let parent=self.strata.map(|s|s.parent_ns);let cts=self.strata.map(|s|s.cts_ns);
            let pool=self.strata.map(|s|s.pool_ns);let residual=self.strata.map(|s|s.residual_ns);
            format!("{{\"totals\":{totals:?},\"samples\":{samples:?},\"started\":{started:?},\"completed\":{completed:?},\"parent_ns\":{parent:?},\"cts_ns\":{cts:?},\"pool_ns\":{pool:?},\"residual_ns\":{residual:?},\"unfinished_scopes\":0,\"saved_timer_pairs_per_completed_scope\":3,\"actual_clock_read_attempts\":null,\"clock_reads_rollbackable\":false}}")
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
        let t=state.admit(0,1)?;state.complete(t,[0,0,0])?;state.snapshot()?;
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
            state.complete(t,[30,10,10])?;
        }
        if state.strata[0].total!=386||state.strata[0].samples!=2||state.strata[0].residual_ns!=20{return Err("contract boundary counters".into());}
        state.snapshot()?;passed+=1;
        let mut state=State{enabled:true,..State::default()};state.strata[0].total=127;
        let ticket=state.admit(0,1)?;
        rejected(&mut state,|s|s.complete(ticket,[19,10,10]),&mut expected_errors)?;passed+=1;
        rejected(&mut state,|s|s.complete(ticket,[u64::MAX,u64::MAX,1]),&mut expected_errors)?;passed+=1;
        for field in 0..3 {
            let mut state=State{enabled:true,..State::default()};state.strata[0].total=127;
            match field {0=>state.strata[0].total=u64::MAX,1=>state.strata[0].samples=u64::MAX,_=>state.strata[0].started=u64::MAX}
            rejected(&mut state,|s|s.admit(0,1).map(|_|()),&mut expected_errors)?;
        }
        for field in 0..5 {
            let mut state=State{enabled:true,..State::default()};state.strata[0].total=127;let ticket=state.admit(0,1)?;
            match field {0=>state.strata[0].completed=u64::MAX,1=>state.strata[0].parent_ns=u64::MAX,2=>state.strata[0].cts_ns=u64::MAX,3=>state.strata[0].pool_ns=u64::MAX,_=>state.strata[0].residual_ns=u64::MAX}
            rejected(&mut state,|s|s.complete(ticket,[30,10,10]),&mut expected_errors)?;
        }passed+=1;
        let before=state;if state.snapshot().is_ok()||state!=before{return Err("contract unfinished rejection".into());}
        expected_errors+=1;passed+=1;
        if passed!=7||expected_errors!=17{return Err("contract case accounting".into());}
        Ok(format!("{{\"status\":\"passed\",\"operation\":\"selfcheck-profile\",\"passed_cases\":{passed},\"expected_error_count\":{expected_errors},\"strata\":8,\"real_clock_reads\":0,\"rejection_state_preserved\":true}}"))
    }
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
fn profile(path:&Path)->Result<String> {
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
    Ok(format!("{{\"status\":\"passed\",\"operation\":\"cts-predict-split\",\"depth\":5,\"input_read_attempts\":1,\"input_reads\":1,\"baseline_encode_calls\":1,\"profile_encode_calls\":1,\"profile_decode_calls\":1,\"encode_calls\":2,\"decode_calls\":1,\"frame_comparisons\":1,\"frame_matched_bytes\":{frame_matched},\"plain_comparisons\":1,\"plain_matched_bytes\":{plain_matched},\"proof_comparisons\":2,\"proof_fields_per_comparison\":14,\"cdf_compared_as_bits\":true,\"stats_comparisons\":3,\"peak_live_candidate_frames\":2,\"peak_live_candidate_frame_bytes\":{live_bytes},\"frames_remaining\":0,\"baseline_encode_elapsed_ns\":{baseline_elapsed_ns},\"profile_encode_elapsed_ns\":{encode_elapsed_ns},\"profile_decode_elapsed_ns\":{decode_elapsed_ns},\"predict_profile_encode\":{},\"predict_profile_decode\":{},\"fixed_stats\":{stats},\"timing_scope\":\"parent: after context/count retrieval, before CTS through pool completion; not full predict\",\"sampling_rule\":\"component*4+prefix-1; one-based ordinal%256==128; independent encode/decode\",\"saved_ns_transactional\":true,\"clock_attempts_not_rollbackable_or_counted\":true,\"sample_zero_time_unknown\":true,\"extrapolated\":false,\"overhead_corrected\":false,\"disk_frames_created\":false,\"disk_restores_created\":false,\"diagnostic_only\":true,\"formal_speed_CPU_verified\":false}}",encode_profile.json(),decode_profile.json()))
}
fn quote(text:&str)->String {
    let mut out=String::from("\"");for c in text.chars().take(1024){match c {
        '"'=>out.push_str("\\\""),'\\'=>out.push_str("\\\\"),'\n'=>out.push_str("\\n"),'\r'=>out.push_str("\\r"),'\t'=>out.push_str("\\t"),
        c if c<' '=>out.push_str(&format!("\\u{:04x}",c as u32)),c=>out.push(c)}}out.push('"');out
}
fn main() {
    let args:Vec<_>=std::env::args_os().collect();
    let result=if args.len()==2&&args[1]=="selfcheck-profile" {predict_profile::contract()}
        else if args.len()==3&&args[1]=="profile" {profile(Path::new(&args[2]))}
        else {Err("usage: predict_split_probe selfcheck-profile | profile INPUT".into())};
    let line=match &result {Ok(line)=>line.clone(),Err(error)=>format!("{{\"status\":\"failed\",\"error\":{}}}",quote(error))};
    println!("{line}");if let Err(error)=std::io::stdout().flush(){eprintln!("JSON flush: {error}");std::process::exit(1);}
    if let Err(error)=result {eprintln!("rejected: {error}");std::process::exit(1);}
}
