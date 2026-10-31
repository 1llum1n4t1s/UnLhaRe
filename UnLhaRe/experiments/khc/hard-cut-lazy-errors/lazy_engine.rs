//! 過去だけのcached hard cut。診断TLSはscalar集計のみ、モデルCDFへ戻さない。
use crate::Result;
pub use crate::old_cts::{node_count,vector,CAP,CLASSES,LEVELS};
use crate::old_cts::{path,kt};
#[derive(Clone,Copy,Debug,PartialEq,Eq)]
pub struct NodeState{pub raw:[u32;4],pub own:u64,pub best:u64,pub split:bool}
const ZERO:NodeState=NodeState{raw:[0;4],own:0,best:0,split:false};
pub struct Snapshot{class:usize,k:usize,ids:[usize;6],history:u16,observations:u32,nodes:[NodeState;6],depth:usize,p:[f64;4]}
impl Snapshot{pub(crate) fn prefix(&self)->usize{self.k}pub(crate) fn mixed(&self)->[f64;4]{self.p}}
pub struct Cts{nodes:Vec<NodeState>,history:[u16;6],observations:[u32;6]}
fn log_q8(x:u64)->Result<u64>{if x==0 || x>2*u64::from(CAP)+4{return Err("Q8 scalar domain".into());}let exp=x.ilog2();let index=if exp>=14{x>>(exp-14)}else{x<<(14-exp)};if !(16384..32768).contains(&index){return Err("Q8 normalized index".into());}let scale=(u64::from(exp)+1)*256;scale.checked_sub(crate::prices::bit_price(index as u16,false)).ok_or_else(||"Q8 log underflow".into())}
fn price(raw:[u32;4],k:usize,child:usize)->Result<u64>{if !(1..=4).contains(&k) || child>=k{return Err("Q8 child/prefix".into());}if k==1{return Ok(0);}let total=raw[..k].iter().map(|&v|u64::from(v)).sum::<u64>();log_q8(2*total+k as u64)?.checked_sub(log_q8(2*u64::from(raw[child])+1)?).ok_or_else(||"Q8 price underflow".into())}
#[cfg(primary_audit)]
#[derive(Clone,Copy,Debug,Default)]
pub struct AuditSummary{pub root_best_Q8:[u64;6],pub selected_price_Q8:[u64;6],pub selected_KT_loss_bits:[f64;6],correction:[f64;6],pub selected_depth_counts:[[u64;6];6],pub history:[u16;6],pub observations:[u32;6],pub node_capacity:usize,pub node_size:usize,pub capacity_bytes:usize}
#[cfg(primary_audit)]
std::thread_local!{static AUDIT:std::cell::Cell<AuditSummary>=std::cell::Cell::new(AuditSummary{root_best_Q8:[0;6],selected_price_Q8:[0;6],selected_KT_loss_bits:[0.0;6],correction:[0.0;6],selected_depth_counts:[[0;6];6],history:[0;6],observations:[0;6],node_capacity:0,node_size:0,capacity_bytes:0});}
#[cfg(primary_audit)]
pub fn audit_summary()->AuditSummary{AUDIT.with(|a|a.get())}
#[cfg(primary_audit)]
pub struct Dump{pub nodes:Vec<NodeState>,pub history:[u16;6],pub observations:[u32;6]}
impl Cts{
    pub fn new(depth:usize)->Result<Self>{let count=node_count(depth)?*CLASSES;let mut nodes=Vec::new();nodes.try_reserve_exact(count).map_err(|_|"cut allocation")?;nodes.resize(count,ZERO);let result=Self{nodes,history:[0;6],observations:[0;6]};
        #[cfg(primary_audit)]{AUDIT.with(|a|a.set(AuditSummary{node_capacity:result.nodes.capacity(),node_size:std::mem::size_of::<NodeState>(),capacity_bytes:result.capacity_bytes(),..AuditSummary::default()}));}Ok(result)
    }
    pub fn predict(&self,class:usize,k:usize)->Result<Snapshot>{
        if class>=6 || !(1..=4).contains(&k){return Err("cut class/prefix".into());}if self.observations[class]>CAP{return Err("cut class prediction cap".into());}let ids=path(self.history[class]);let mut nodes=[ZERO;6];
        for d in 0..6{nodes[d]=*self.nodes.get(class*1365+ids[d]).ok_or("cut path index")?;if nodes[d].raw.iter().map(|&v|u64::from(v)).sum::<u64>()>u64::from(CAP){return Err("cut raw prediction cap".into());}}
        if nodes[5].split{return Err("cut depth5 split".into());}let depth=(0..6).find(|&d|!nodes[d].split).ok_or("cut leaf missing")?;let p=kt(nodes[depth].raw,k)?;
        // own/best synthetic MAXはpredictで再評価せず、observeのchecked処理へ委ねる。
        Ok(Snapshot{class,k,ids,history:self.history[class],observations:self.observations[class],nodes,depth,p})
    }
    pub fn observe(&mut self,s:&Snapshot,child:usize)->Result<()>{
        if s.class>=6 || !(1..=4).contains(&s.k) || child>=s.k || s.depth>=6{return Err("cut observation domain".into());}let c=s.class;if self.observations[c]>=CAP{return Err("cut class update cap".into());}
        if s.history!=self.history[c] || s.observations!=self.observations[c] || s.ids!=path(self.history[c]){return Err("cut stale snapshot".into());}
        let mut next=[ZERO;6];for d in 0..6{let current=*self.nodes.get(c*1365+s.ids[d]).ok_or("cut update node")?;if current!=s.nodes[d]{return Err("cut stale node".into());}if current.raw.iter().map(|&v|u64::from(v)).sum::<u64>()>=u64::from(CAP){return Err("cut raw update cap".into());}
            next[d]=current;next[d].own=current.own.checked_add(price(current.raw,s.k,child)?).ok_or("cut own overflow")?;next[d].raw[child]=current.raw[child].checked_add(1).ok_or("cut raw overflow")?;
        }
        next[5].best=next[5].own;next[5].split=false;
        for d in (0..5).rev(){let mut sum=0u64;for digit in 0..4{let id=4*s.ids[d]+1+digit;let best=if id==s.ids[d+1]{next[d+1].best}else{self.nodes.get(c*1365+id).ok_or("cut sibling index")?.best};sum=sum.checked_add(best).ok_or("cut sibling best overflow")?;}let split=sum.checked_add(256).ok_or("cut split penalty overflow")?;next[d].split=split<next[d].own;next[d].best=if next[d].split{split}else{next[d].own};}
        let observations=self.observations[c].checked_add(1).ok_or("cut observations overflow")?;let history=self.history[c].wrapping_shl(2)|child as u16;
        #[cfg(primary_audit)]
        let audit={let mut a=AUDIT.with(|a|a.get());let cost=next[s.depth].own.checked_sub(s.nodes[s.depth].own).ok_or("diagnostic selected price")?;a.selected_price_Q8[c]=a.selected_price_Q8[c].checked_add(cost).ok_or("diagnostic price overflow")?;let loss=-s.p[child].log2();if !loss.is_finite() || loss<0.0{return Err("diagnostic KT loss".into());}let y=loss-a.correction[c];let total=a.selected_KT_loss_bits[c]+y;a.correction[c]=(total-a.selected_KT_loss_bits[c])-y;a.selected_KT_loss_bits[c]=total;if !total.is_finite(){return Err("diagnostic KT loss sum".into());}a.selected_depth_counts[c][s.depth]=a.selected_depth_counts[c][s.depth].checked_add(1).ok_or("diagnostic depth count overflow")?;a.root_best_Q8[c]=next[0].best;a.observations[c]=observations;a.history[c]=history;a};
        // 全6nextと診断集計を準備済み。ここから非fallible commitだけ。
        for d in 0..6{self.nodes[c*1365+s.ids[d]]=next[d];}self.observations[c]=observations;self.history[c]=history;
        #[cfg(primary_audit)]{AUDIT.with(|a|a.set(audit));}Ok(())
    }
    pub fn observations(&self)->[u32;6]{self.observations}
    pub fn capacity_bytes(&self)->usize{self.nodes.capacity()*std::mem::size_of::<NodeState>()+std::mem::size_of::<Self>()}
    pub fn same(&self,b:&Self)->bool{self.nodes==b.nodes && self.history==b.history && self.observations==b.observations}
    #[cfg(primary_audit)] pub fn audit_dump(&self)->Dump{Dump{nodes:self.nodes.clone(),history:self.history,observations:self.observations}}
    #[cfg(primary_audit)] pub fn audit_seed_class(&mut self,c:usize,h:u16,n:u32){self.history[c]=h;self.observations[c]=n;}
    #[cfg(primary_audit)] pub fn audit_seed_node(&mut self,c:usize,id:usize,n:NodeState){self.nodes[c*1365+id]=n;}
}
