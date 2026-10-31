//! @happypath @category happy,state,boundary @severity HIGH
//! engine実装前の有限oracle。逐次lossと終端best scoreは別物。
use crate::engine::{Cts,NodeState};
type Result<T>=std::result::Result<T,String>;
const N:usize=1365;
const CLASSES:usize=6;
fn path(history:u16)->[usize;6]{let mut ids=[0;6];let mut digits=usize::from(history);for d in 1..6{ids[d]=ids[d-1]*4+1+digits%4;digits/=4;}ids}
// engine helper/PRICESを呼ばず、整数指数・14bit正規化・一次fractionを独立算出。
fn log_q8(x:u64)->Result<u64>{if x==0{return Err("oracle positive scalar".into());}let mut e=0u32;let mut q=x;while q>=2{q/=2;e+=1;}let index=if e>=14{x/(1u64<<(e-14))}else{x*(1u64<<(14-e))};if !(16384..32768).contains(&index){return Err("oracle normalization".into());}Ok(u64::from(e)*256+(index-16384)*256/16384)}
fn price(raw:[u32;4],k:usize,child:usize)->Result<u64>{if k==1{return Ok(0);}let total=raw[..k].iter().map(|&v|u64::from(v)).sum::<u64>();log_q8(2*total+k as u64)?.checked_sub(log_q8(2*u64::from(raw[child])+1)?).ok_or("oracle price underflow".into())}
struct Oracle{raw:Vec<[u32;4]>,own:Vec<u64>,best:Vec<u64>,split:Vec<bool>,history:[u16;6],observations:[u32;6]}
impl Oracle{
    fn new()->Self{Self{raw:vec![[0;4];CLASSES*N],own:vec![0;CLASSES*N],best:vec![0;CLASSES*N],split:vec![false;CLASSES*N],history:[0;6],observations:[0;6]}}
    fn selected(&self,c:usize)->Result<usize>{let ids=path(self.history[c]);for d in 0..6{let index=c*N+ids[d];if !self.split[index]{return Ok(index);}}Err("oracle depth5 must be leaf".into())}
    fn distribution(&self,c:usize,k:usize)->Result<([f64;4],usize)>{let id=self.selected(c)?;let total=self.raw[id][..k].iter().map(|&v|u64::from(v)).sum::<u64>();let denominator=(2*total+k as u64) as f64;let mut p=[0.0;4];for j in 0..k{p[j]=(2*u64::from(self.raw[id][j])+1) as f64/denominator;}Ok((p,id))}
    fn recompute(&mut self,c:usize,id:usize,depth:usize)->Result<u64>{let index=c*N+id;let own=self.own[index];let split=if depth==5{None}else{let mut sum=256u64;for digit in 0..4{sum=sum.checked_add(self.recompute(c,4*id+1+digit,depth+1)?).ok_or("oracle split overflow")?;}Some(sum)};self.split[index]=split.is_some_and(|s|s<own);self.best[index]=if self.split[index]{split.unwrap()}else{own};Ok(self.best[index])}
    fn observe(&mut self,c:usize,k:usize,child:usize)->Result<()>{for id in path(self.history[c]){let index=c*N+id;self.own[index]=self.own[index].checked_add(price(self.raw[index],k,child)?).ok_or("oracle own overflow")?;self.raw[index][child]+=1;}self.history[c]=self.history[c].wrapping_mul(4).wrapping_add(child as u16);self.observations[c]+=1;for class in 0..6{self.recompute(class,0,0)?;}Ok(())}
    fn compare(&self,cts:&Cts)->Result<usize>{let dump=cts.audit_dump();if dump.nodes.len()!=CLASSES*N || dump.history!=self.history || dump.observations!=self.observations || cts.observations()!=self.observations{return Err("oracle dump extents/history/observations".into());}for i in 0..CLASSES*N{let want=NodeState{raw:self.raw[i],own:self.own[i],best:self.best[i],split:self.split[i]};if dump.nodes[i]!=want{return Err(format!("oracle whole node {i}"));}}Ok(CLASSES*N)}
}
// CloneをAPIへ要求せず、診断dumpから独立stateを再構築してsameを検査する。
pub fn mirror(cts:&Cts)->Result<Cts>{let d=cts.audit_dump();if d.nodes.len()!=8190{return Err("mirror dump extent".into());}let mut copy=Cts::new(5)?;for c in 0..6{copy.audit_seed_class(c,d.history[c],d.observations[c]);for id in 0..N{copy.audit_seed_node(c,id,d.nodes[c*N+id]);}}if !cts.same(&copy){return Err("whole-state mirror".into());}Ok(copy)}
fn close(a:f64,b:f64)->Result<()>{if !a.is_finite() || !b.is_finite() || (a-b).abs()>1e-12{return Err("oracle KT probability".into());}Ok(())}
pub fn run()->Result<String>{
    if std::mem::size_of::<NodeState>()>40{return Err("primary NodeState extent".into());}
    let mut cts=Cts::new(5)?;if cts.capacity_bytes()>1048576{return Err("finite primary capacity".into());}let mut oracle=Oracle::new();let mut whole_nodes=oracle.compare(&cts)?;let initial=mirror(&cts)?;let mut readonly=0;
    for c in 0..6{for k in 1..=4{let s=cts.predict(c,k)?;if s.prefix()!=k{return Err("initial prefix".into());}let p=s.mixed();for j in 0..4{close(p[j],if j<k{1.0/k as f64}else{0.0})?;if j>=k && p[j].to_bits()!=0{return Err("initial positive zero tail".into());}}if !cts.same(&initial){return Err("prediction readonly whole state".into());}readonly+=1;}}
    let mut prices=0;for index in 16384..32768u64{let expected=256-(index-16384)*256/16384;if crate::prices::bit_price(index as u16,false)!=expected{return Err("independent primary price table".into());}prices+=1;}
    let mut events=0;let mut cdf_comparisons=0;let mut selected_q8=0u64;let mut actual_loss=0.0;let mut root_cut_predictions=0;let mut deeper_cut_predictions=0;
    for c in 0..2{let count=if c==0{128}else{32};for i in 0..count{let k=if c==0{4}else{i%4+1};let child=if c==0{i%4}else if i<16{i%k}else{0};
        let(p,id)=oracle.distribution(c,k)?;let s=cts.predict(c,k)?;if s.prefix()!=k{return Err("finite prefix".into());}let got=s.mixed();for j in 0..4{close(got[j],p[j])?;if j>=k && got[j].to_bits()!=0{return Err("finite positive zero tail".into());}cdf_comparisons+=1;}if id%N==0{root_cut_predictions+=1;}else{deeper_cut_predictions+=1;}
        selected_q8=selected_q8.checked_add(price(oracle.raw[id],k,child)?).ok_or("selected score overflow")?;actual_loss-=p[child].log2();
        cts.observe(&s,child)?;oracle.observe(c,k,child)?;whole_nodes+=oracle.compare(&cts)?;events+=1;
    }}
    if events!=160 || cts.observations()!=[128,32,0,0,0,0] || !oracle.split[0] || deeper_cut_predictions==0 || cts.same(&initial){return Err("finite cut switch/observations".into());}
    let roots=std::array::from_fn::<_,6,_>(|c|oracle.best[c*N]);let reset=Cts::new(5)?;if !reset.same(&initial){return Err("fresh cold reset".into());}
    // 人工cached-score同点。ownにleaf tagを加えず、256==256+0でleafを保持。
    let mut tie=Cts::new(5)?;tie.audit_seed_node(0,0,NodeState{raw:[3,1,0,0],own:256,best:256,split:false});let s=tie.predict(0,2)?;let p=s.mixed();close(p[0],0.7)?;close(p[1],0.3)?;let dump=tie.audit_dump();if dump.nodes[0].split || dump.nodes[0].best!=256{return Err("tie leaf readonly".into());}
    Ok(format!("{{\"initial_readonly_CDFs\":{readonly},\"price_table_comparisons\":{prices},\"finite_events\":{events},\"full_node_comparisons\":{whole_nodes},\"probability_comparisons\":{cdf_comparisons},\"root_cut_predictions\":{root_cut_predictions},\"deeper_cut_predictions\":{deeper_cut_predictions},\"mixed_prefix_events\":32,\"prefix1_events\":8,\"class1_distribution_change_after_event\":16,\"terminal_root_best_Q8\":{roots:?},\"selected_sequential_price_Q8\":{selected_q8},\"selected_sequential_loss_bits\":{actual_loss:.17},\"synthetic_tie_leaf_checks\":1,\"fresh_cold_reset_checks\":1,\"whole_state_same_checked\":true,\"regret_claimed\":false}}"))
}
