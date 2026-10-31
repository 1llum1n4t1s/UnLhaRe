//! 単一threadの計時集計だけ。codec数値stateへ触れない。
use crate::Result;
use std::{cell::RefCell,time::Instant};
pub(crate) const ALL_NAMES:[&str;7]=["full_encode","bwt","payload_setup","model_initialization","payload_loop","final_digest","metadata_crc_frame"];
pub(crate) const SAMPLE_NAMES:[&str;7]=["model_predict","cts_predict","pool_predict","range_interval","model_observe","pool_update","cts_observe"];
#[derive(Clone,Copy,Default)]
pub(crate) struct Metric {pub count:u64,pub elapsed_ns:u64}
#[derive(Clone,Default)]
pub(crate) struct Record {pub all:[Metric;7],pub sample:[Metric;7],pub samples:u64,pub components:[u64;2],pub prefixes:[u64;4],pub first_serial:Option<u64>,pub last_serial:Option<u64>}
thread_local! {static STATE:RefCell<Record>=RefCell::new(Record::default());}
pub(crate) fn reset(){STATE.with(|s|*s.borrow_mut()=Record::default());}
pub(crate) fn snapshot()->Record{STATE.with(|s|s.borrow().clone())}
pub(crate) fn start()->Instant{Instant::now()}
pub(crate) fn start_if(selected:bool)->Option<Instant>{selected.then(Instant::now)}
fn elapsed(begin:Instant)->Result<u64>{let d=Instant::now().checked_duration_since(begin).ok_or("clock time reversed")?;u64::try_from(d.as_nanos()).map_err(|_|"timer elapsed overflow".into())}
fn aggregate(m:&mut Metric,ns:u64)->Result<()>{let count=m.count.checked_add(1).ok_or("timer count overflow")?;let total=m.elapsed_ns.checked_add(ns).ok_or("timer record overflow")?;m.count=count;m.elapsed_ns=total;Ok(())}
pub(crate) fn end_all(phase:usize,begin:Instant)->Result<()>{
    let ns=elapsed(begin)?;STATE.with(|s|{let mut state=s.try_borrow_mut().map_err(|_|"timer nested borrow")?;aggregate(state.all.get_mut(phase).ok_or("all phase index")?,ns)})
}
pub(crate) fn end_sample(phase:usize,begin:Option<Instant>)->Result<()>{
    if let Some(begin)=begin{let ns=elapsed(begin)?;STATE.with(|s|{let mut state=s.try_borrow_mut().map_err(|_|"timer nested borrow")?;aggregate(state.sample.get_mut(phase).ok_or("sample phase index")?,ns)})}else{Ok(())}
}
pub(crate) fn branch(serial:u64,component:usize,prefix:usize)->Result<()>{
    if serial%1024!=0{return Ok(());}
    if component>1||!(1..=4).contains(&prefix){return Err("sample component/prefix".into());}
    STATE.with(|s|{
        let mut r=s.try_borrow_mut().map_err(|_|"timer nested borrow")?;
        if r.last_serial.is_some_and(|last|serial<=last){return Err("sample serial duplicate/reversed".into());}
        let samples=r.samples.checked_add(1).ok_or("sample count overflow")?;
        let components=r.components[component].checked_add(1).ok_or("sample component overflow")?;
        let prefixes=r.prefixes[prefix-1].checked_add(1).ok_or("sample prefix overflow")?;
        r.samples=samples;r.components[component]=components;r.prefixes[prefix-1]=prefixes;
        if r.first_serial.is_none(){r.first_serial=Some(serial);}r.last_serial=Some(serial);Ok(())
    })
}
impl Record {
    pub(crate) fn json(&self)->String{
        let metrics=|names:[&str;7],values:[Metric;7]|{
            names.iter().zip(values).map(|(name,m)|format!("{{\"name\":\"{name}\",\"count\":{},\"elapsed_ns\":{}}}",m.count,m.elapsed_ns)).collect::<Vec<_>>().join(",")
        };
        format!("{{\"all_phases\":[{}],\"sampled_phases\":[{}],\"sample_count\":{},\"sample_components\":{:?},\"sample_prefixes\":{:?},\"first_sample_serial\":{},\"last_sample_serial\":{}}}",metrics(ALL_NAMES,self.all),metrics(SAMPLE_NAMES,self.sample),self.samples,self.components,self.prefixes,self.first_serial.map_or("null".into(),|v|v.to_string()),self.last_serial.map_or("null".into(),|v|v.to_string()))
    }
}

