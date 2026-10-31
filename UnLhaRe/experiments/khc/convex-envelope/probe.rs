//! 観測tokenを知った後のoracle。実codecではない。
#![allow(dead_code,unused_imports)]
#[path="../causal-bayes-sais/bwt.rs"] mod bwt;
#[path="../static-direct-mdl/frontend.rs"] mod frontend;
#[path="../static-direct-mdl/histogram.rs"] mod histogram;
#[path="../direct-feature-opportunity/features.rs"] mod features;
#[path="../direct-exact-context/fenwick.rs"] mod fenwick;
#[path="../direct-exact-context/dictionary.rs"] mod dictionary;
#[path="../direct-exact-context/mixture.rs"] mod mixture;
#[path="../packed-inverse/reference.rs"] mod reference;
#[path="../packed-inverse/contract.rs"] mod contract;
#[path="../packed-inverse/memory.rs"] mod memory;
use std::{fs::File,io::Read};
type Result<T>=std::result::Result<T,String>;
#[derive(Clone,Copy)] struct Ratio {count:u32,total:u32}
fn valid(r:Ratio)->Result<()> {if r.count==0||r.total==0||r.count>r.total||r.total>=32768 {return Err("ratio range".into());}Ok(())}
fn greater(a:Ratio,b:Ratio)->bool {u64::from(a.count)*u64::from(b.total)>u64::from(b.count)*u64::from(a.total)}
fn best(rows:[Ratio;4])->Result<Ratio> {for r in rows {valid(r)?;}let mut result=rows[0];for r in rows {if greater(r,result){result=r;}}let mut reverse=rows[3];for r in rows.into_iter().rev(){if greater(r,reverse){reverse=r;}}if u64::from(result.count)*u64::from(reverse.total)!=u64::from(reverse.count)*u64::from(result.total){return Err("forward/reverse best ratio".into());}Ok(result)}
fn upper(r:Ratio,limit:usize)->Result<u32> {valid(r)?;if !(1..=257).contains(&limit){return Err("limit range".into());}let n=(32768-limit as u64)*u64::from(r.count);let ceiling=(n+u64::from(r.total)-1)/u64::from(r.total);Ok((ceiling+3).min(32768) as u32)}
fn fixtures()->Result<(usize,usize)> {
    let r=best([Ratio{count:1,total:257},Ratio{count:2,total:5},Ratio{count:3,total:5},Ratio{count:6,total:10}])?;
    if r.count!=3||r.total!=5||upper(r,5)?!=19661||upper(Ratio{count:1,total:257},257)?!=130||upper(Ratio{count:1,total:1},1)?!=32768||!greater(Ratio{count:32766,total:32767},Ratio{count:32765,total:32766}){return Err("exact envelope fixtures".into());}
    let mut rejects=0;for (count,total,limit) in [(0,1,1),(1,0,1),(2,1,1),(1,32768,1),(1,1,0),(1,1,258)] {if upper(Ratio{count,total},limit).is_ok(){return Err("invalid envelope accepted".into());}rejects+=1;}
    Ok((5,rejects))
}
#[derive(Default,Clone,Copy)] struct Sum {value:f64,correction:f64}
impl Sum {fn add(&mut self,x:f64)->Result<()> {if !x.is_finite()||x<0.0{return Err("loss range".into());}let y=x-self.correction;let t=self.value+y;self.correction=(t-self.value)-y;self.value=t;Ok(())}}
fn execute()->Result<()> {
    let args:Vec<_>=std::env::args().collect();if args.len()!=2{return Err("usage fixed-input".into());}let (normal,rejected)=fixtures()?;
    let file=File::open(&args[1]).map_err(|e|e.to_string())?;if file.metadata().map_err(|e|e.to_string())?.len()!=2811006{return Err("fixed length".into());}
    let mut plain=Vec::new();plain.try_reserve_exact(2811006).map_err(|_|"input allocation")?;file.take(2811007).read_to_end(&mut plain).map_err(|e|e.to_string())?;if plain.len()!=2811006{return Err("bounded read".into());}
    let front=frontend::Front::new(&plain)?;if front.runs.len()!=889227||front.primary!=1762795||front.runs.capacity()>1048576{return Err("fixed frontend".into());}
    let mut mix=mixture::Mix::new()?;let capacity=mix.bytes();let estimate=capacity+front.runs.capacity()*12+plain.capacity()+1369112+4194304;if estimate>141613654{return Err("RAM estimate".into());}
    let mut ideal=[Sum::default();2];let mut optimistic=[Sum::default();2];let mut baseline=Sum::default();let mut interval_checks=0u64;
    let meta=features::walk(&front,features::Family::Joint,|component,joint,token,limit,recent| {
        let p=mix.predict(mixture::four_keys(component,joint,recent)?,token,limit)?;
        let mut ratios=[Ratio{count:1,total:1};4];for i in 0..4 {let table=&mut mix.banks[i].table;let count=table.count(p.rows[i],token)?;let total=table.prefix(p.rows[i],limit)?;ratios[i]=Ratio{count,total};if (count as f64/total as f64).to_bits()!=p.probabilities[i].to_bits(){return Err("expert ratio reconstruction".into());}}
        let r=best(ratios)?;let generous=upper(r,limit)?;let actual=p.high-p.low;if actual>generous{return Err("actual Q exceeds generous bound".into());}
        ideal[component].add((r.total as f64/r.count as f64).log2())?;optimistic[component].add((32768.0/generous as f64).log2())?;baseline.add((32768.0/actual as f64).log2())?;interval_checks+=1;mix.observe(p)?;Ok(())
    })?;
    if meta.tokens!=[889227,889227]||meta.runs!=889227||meta.escapes!=742||meta.history_checks!=1778454||meta.grammar!=0x58735a2b7383d755||interval_checks!=1778454||(baseline.value-4510058.854214707).abs()>1e-6{return Err("fixed history/baseline identity".into());}
    let terminal=mix.verify_terminal()?;if terminal!=29483040{return Err("whole terminal extent".into());}
    let total=optimistic[0].value+optimistic[1].value;let screen=(total/8.0).ceil() as u64+3079;let ideal_bits=ideal[0].value+ideal[1].value;
    drop(mix);drop(front);drop(plain);let (memory,peak)=memory::read_once()?;let peak=peak.map_or("null",|v|if v{"true"}else{"false"});
    println!("{{\"status\":\"passed\",\"oracle_not_codec\":true,\"fixtures_normal\":{normal},\"fixtures_rejected\":{rejected},\"events\":{interval_checks},\"baseline_Q_bits\":{},\"ideal_best_expert_bits\":{ideal_bits:.12},\"optimistic_component_bits\":[{},{}],\"optimistic_Q_bits\":{total:.12},\"optimistic_screen_bytes\":{screen},\"necessary_size_condition_has_room\":{},\"extra_free_frequency_units\":2,\"terminal_nodes\":{terminal},\"RAM_estimate_bytes\":{estimate},\"memory\":{memory},\"peak_resource_gate_passed\":{peak},\"frame_encodes\":0,\"frame_decodes\":0,\"CPU_quiet_verified\":false}}",baseline.value,optimistic[0].value,optimistic[1].value,screen<=483599);Ok(())
}
fn main(){if let Err(e)=execute(){eprintln!("convex-envelope: {e}");std::process::exit(1);}}
