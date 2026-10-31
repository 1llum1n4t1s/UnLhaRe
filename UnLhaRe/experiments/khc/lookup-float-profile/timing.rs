//! 同一branchの親子を同じ採取点で計測する。数値/stateの計算へ値を渡さない。
use std::{cell::RefCell,time::Instant};
use crate::Result;
pub const PREDICT:usize=0;
pub const PREDICT_CTS:usize=1;
pub const PREDICT_POOL:usize=2;
pub const OBSERVE:usize=3;
pub const OBSERVE_POOL:usize=4;
pub const OBSERVE_CTS:usize=5;
pub const CODER:usize=6;
const NAMES:[&str;7]=["predict_inclusive","predict_cts","predict_pool","observe_inclusive","observe_pool","observe_cts","coder_selection_and_interval"];
#[derive(Clone,Copy,Default,Debug,PartialEq,Eq)]
pub struct Bucket {pub count:u64,pub ns:u128}
#[derive(Clone,Default,Debug,PartialEq,Eq)]
pub struct State {
    enabled:bool,current:Option<usize>,pub totals:[u64;8],pub samples:[u64;8],pub completed:[u64;8],
    pub stages:[[Bucket;7];8],pub constructors:Bucket,pub audited:Option<[[u64;4];2]>,
}
thread_local! {static STATE:RefCell<State>=RefCell::new(State::default());}
pub fn reset(enabled:bool){STATE.with(|s|*s.borrow_mut()=State{enabled,..State::default()});}
pub fn snapshot()->State {STATE.with(|s|s.borrow().clone())}
pub fn expected(n:u64)->u64 {if n<128{0}else{1+(n-128)/256}}
pub fn begin_branch(component:usize,prefix:usize){STATE.with(|s|{
    let mut s=s.borrow_mut();if !s.enabled{return;}
    let k=component*4+prefix-1;s.totals[k]+=1;
    s.current=if s.totals[k]%256==128 {s.samples[k]+=1;Some(k)}else{None};
});}
pub fn mark()->Option<Instant>{let sampled=STATE.with(|s|s.borrow().current.is_some());if sampled{Some(Instant::now())}else{None}}
pub fn end(stage:usize,begin:Option<Instant>){if let Some(begin)=begin{
    let ns=begin.elapsed().as_nanos();STATE.with(|s|{let mut s=s.borrow_mut();let k=s.current.expect("sample remains active");s.stages[k][stage].count+=1;s.stages[k][stage].ns+=ns;});
}}
pub fn complete_branch(){STATE.with(|s|{let mut s=s.borrow_mut();if s.enabled{let k=s.current.take();if let Some(k)=k{s.completed[k]+=1;}}});}
pub fn constructor(ns:u128){STATE.with(|s|{let mut s=s.borrow_mut();if s.enabled{s.constructors.count+=1;s.constructors.ns+=ns;}});}
pub fn audit(prefixes:[[u64;4];2]){STATE.with(|s|{let mut s=s.borrow_mut();if s.enabled{s.audited=Some(prefixes);}});}
impl State {
    pub fn validate(&self)->Result<()> {
        if !self.enabled||self.current.is_some()||self.constructors.count!=1{return Err("profile lifecycle".into());}
        let audited=self.audited.ok_or("profile audit missing")?;
        for k in 0..8 {
            if self.totals[k]!=audited[k/4][k%4]||self.samples[k]!=expected(self.totals[k])||self.completed[k]!=self.samples[k]{return Err(format!("profile sample/ordinal/audit stratum {k}"));}
            for b in &self.stages[k]{if b.count!=self.samples[k]{return Err(format!("profile stage count stratum {k}"));}}
            for (p,a,b) in [(PREDICT,PREDICT_CTS,PREDICT_POOL),(OBSERVE,OBSERVE_POOL,OBSERVE_CTS)] {
                if self.stages[k][p].ns<self.stages[k][a].ns+self.stages[k][b].ns{return Err(format!("nested profile residual stratum {k}"));}
            }
        }Ok(())
    }
    pub fn json(&self,whole_ns:u64)->String {
        let mut rows=Vec::new();let mut estimated=[0.0f64;9];let mut unrepresented=0;
        for k in 0..8 {
            let stages=self.stages[k].iter().enumerate().map(|(j,b)|format!("{{\"name\":\"{}\",\"samples\":{},\"sampled_ns\":{}}}",NAMES[j],b.count,b.ns)).collect::<Vec<_>>().join(",");
            let residuals=[self.stages[k][0].ns-self.stages[k][1].ns-self.stages[k][2].ns,self.stages[k][3].ns-self.stages[k][4].ns-self.stages[k][5].ns];
            if self.samples[k]>0 {let weight=self.totals[k] as f64/self.samples[k] as f64;for j in 0..7{estimated[j]+=self.stages[k][j].ns as f64*weight;}for j in 0..2{estimated[7+j]+=residuals[j] as f64*weight;}}else{unrepresented+=self.totals[k];}
            rows.push(format!("{{\"component\":{},\"prefix\":{},\"total\":{},\"samples\":{},\"completed_samples\":{},\"stages\":[{}],\"predict_residual_sampled_ns\":{},\"observe_residual_sampled_ns\":{}}}",k/4,k%4+1,self.totals[k],self.samples[k],self.completed[k],stages,residuals[0],residuals[1]));
        }
        format!("{{\"whole_ns\":{whole_ns},\"constructor_count\":{},\"constructor_ns\":{},\"ordinal_one_based_mod256_equals\":128,\"same_sample_parent_child\":true,\"strata\":[{}],\"stratum_weighted_estimated_ns\":{{\"predict_inclusive\":{:.3},\"predict_cts\":{:.3},\"predict_pool\":{:.3},\"observe_inclusive\":{:.3},\"observe_pool\":{:.3},\"observe_cts\":{:.3},\"coder\":{:.3},\"predict_residual\":{:.3},\"observe_residual\":{:.3}}},\"unsampled_branch_population\":{unrepresented},\"estimated_is_diagnostic_attribution_only\":true}}",self.constructors.count,self.constructors.ns,rows.join(","),estimated[0],estimated[1],estimated[2],estimated[3],estimated[4],estimated[5],estimated[6],estimated[7],estimated[8])
    }
}
