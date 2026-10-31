//! depth5固定、非公開snapshot、順序固定f64 CTS。
use crate::Result;
pub const CLASSES:usize=6;
pub const LEVELS:usize=6;
pub const CAP:u32=3825340;
pub fn node_count(depth:usize)->Result<usize>{if depth!=5{return Err("unsupported CTS depth".into());}Ok(1365)}
pub fn path(history:u16)->[usize;LEVELS]{let mut ids=[0;LEVELS];for l in 1..LEVELS{ids[l]=4*ids[l-1]+1+usize::from((history>>(2*(l-1)))&3);}ids}
pub fn vector(p:[f64;4],k:usize)->Result<()>{
    if !(1..=4).contains(&k){return Err("invalid prefix".into());}
    if p[..k].iter().any(|&x|!x.is_finite()||x<=0.0||x>1.0)||p[k..].iter().any(|&x|x.to_bits()!=0){return Err("probability domain/tail".into());}
    let mut sum=0.0;for &x in &p[..k]{sum+=x;}if (sum-1.0).abs()>1e-12{return Err("probability sum".into());}Ok(())
}
pub fn kt(raw:[u32;4],k:usize)->Result<[f64;4]>{
    if !(1..=4).contains(&k){return Err("invalid prefix".into());}
    let total=raw.iter().map(|&v|u64::from(v)).sum::<u64>();if total>u64::from(CAP){return Err("raw observation cap".into());}
    let mut denominator=0.0;for &v in &raw[..k]{denominator+=v as f64+0.5;}
    let reciprocal=1.0/denominator;let mut p=[0.0;4];for j in 0..k{p[j]=(raw[j] as f64+0.5)*reciprocal;}vector(p,k)?;Ok(p)
}
#[derive(Clone,Copy,Debug)]
pub struct Node {pub raw:[u32;4],pub weight:f64}
#[derive(Clone,Debug)]
pub struct Kernel {pub kt:[[f64;4];LEVELS],pub mixed:[[f64;4];LEVELS]}
#[derive(Clone,Debug)]
pub struct Snapshot {class:usize,prefix:usize,ids:[usize;LEVELS],history:u16,observations:u32,raw:[[u32;4];LEVELS],weights:[f64;LEVELS],kernel:Kernel}
impl Snapshot {pub(crate) fn prefix(&self)->usize{self.prefix}pub(crate) fn mixed(&self)->[f64;4]{self.kernel.mixed[0]}}
#[derive(Clone)]
pub struct Cts {nodes:Vec<Node>,history:[u16;CLASSES],observations:[u32;CLASSES]}
fn weight(w:f64)->Result<()>{if !w.is_finite()||!(0.0..=1.0).contains(&w){Err("kernel weight".into())}else{Ok(())}}
pub fn predict_kernel(raw:[[u32;4];LEVELS],weights:[f64;LEVELS],k:usize)->Result<Kernel>{
    if weights[5].to_bits()!=0.5f64.to_bits(){return Err("invalid kernel leaf".into());}
    let mut result=Kernel{kt:[[0.0;4];LEVELS],mixed:[[0.0;4];LEVELS]};
    for l in 0..LEVELS{weight(weights[l])?;result.kt[l]=kt(raw[l],k)?;}
    result.mixed[5]=result.kt[5];
    for l in (0..5).rev(){for j in 0..k{result.mixed[l][j]=weights[l]*result.kt[l][j]+(1.0-weights[l])*result.mixed[l+1][j];}vector(result.mixed[l],k)?;}Ok(result)
}
impl Cts {
    pub fn new(depth:usize)->Result<Self>{let n=node_count(depth)?*CLASSES;let mut nodes=Vec::new();nodes.try_reserve_exact(n).map_err(|_|"CTS allocation")?;nodes.resize(n,Node{raw:[0;4],weight:0.5});Ok(Self{nodes,history:[0;CLASSES],observations:[0;CLASSES]})}
    pub fn predict(&self,class:usize,k:usize)->Result<Snapshot>{
        if class>=CLASSES{return Err("invalid class".into());}if self.observations[class]>CAP{return Err("class observation cap".into());}
        let ids=path(self.history[class]);let mut raw=[[0;4];LEVELS];let mut weights=[0.0;LEVELS];
        for l in 0..LEVELS{let node=self.nodes.get(class*1365+ids[l]).ok_or("prediction node index")?;raw[l]=node.raw;weights[l]=node.weight;}
        let kernel=predict_kernel(raw,weights,k)?;
        Ok(Snapshot{class,prefix:k,ids,history:self.history[class],observations:self.observations[class],raw,weights,kernel})
    }
    // standalone checked split/rejection専用。通常codecはobserve_freshだけ。
    #[cfg(frame_audit)]
    pub fn observe(&mut self,s:&Snapshot,child:usize)->Result<()>{
        if s.class>=CLASSES||!(1..=4).contains(&s.prefix)||child>=s.prefix{return Err("invalid observation".into());}
        if self.observations[s.class]>=CAP{return Err("class update cap".into());}
        if s.ids!=path(self.history[s.class])||s.history!=self.history[s.class]||s.observations!=self.observations[s.class]{return Err("stale snapshot".into());}
        let mut next=[Node{raw:[0;4],weight:0.5};LEVELS];let after=s.observations+1;let alpha=1.0/(after as f64+1.0);
        for (l,out) in next.iter_mut().enumerate(){
            let current=self.nodes.get(s.class*1365+s.ids[l]).ok_or("prediction node index")?;
            if current.raw!=s.raw[l]||current.weight.to_bits()!=s.weights[l].to_bits(){return Err("stale snapshot node".into());}
            weight(current.weight)?;let total=current.raw.iter().map(|&v|u64::from(v)).sum::<u64>();if total>=u64::from(CAP){return Err("raw update cap".into());}
            out.raw=current.raw;out.raw[child]=out.raw[child].checked_add(1).ok_or("raw overflow")?;
            if l<5{let posterior=current.weight*s.kernel.kt[l][child]/s.kernel.mixed[l][child];
                if !posterior.is_finite()||!(0.0..=1.0).contains(&posterior){return Err("posterior domain".into());}
                out.weight=alpha+(1.0-2.0*alpha)*posterior;weight(out.weight)?;
            }else if current.weight.to_bits()!=0.5f64.to_bits(){return Err("invalid kernel leaf".into());}
        }
        for (l,&node) in next.iter().enumerate(){self.nodes[s.class*1365+s.ids[l]]=node;}
        self.observations[s.class]=after;self.history[s.class]=(self.history[s.class]<<2)|child as u16;Ok(())
    }

    // 直前predictと同じCtsを排他的Model transactionが保持する専用入口。
    // Snapshotの構造は維持する。child/CAP/posterior/overflowを省かない。
    pub(crate) fn observe_fresh(&mut self,s:&Snapshot,child:usize)->Result<()>{
        if s.class>=CLASSES||!(1..=4).contains(&s.prefix)||child>=s.prefix{return Err("invalid observation".into());}
        if self.observations[s.class]>=CAP{return Err("class update cap".into());}
        let mut next=[Node{raw:[0;4],weight:0.5};LEVELS];let after=s.observations+1;let alpha=1.0/(after as f64+1.0);
        for (l,out) in next.iter_mut().enumerate(){
            let total=s.raw[l].iter().map(|&v|u64::from(v)).sum::<u64>();if total>=u64::from(CAP){return Err("raw update cap".into());}
            out.raw=s.raw[l];out.raw[child]=out.raw[child].checked_add(1).ok_or("raw overflow")?;
            if l<5{let posterior=s.weights[l]*s.kernel.kt[l][child]/s.kernel.mixed[l][child];
                if !posterior.is_finite()||!(0.0..=1.0).contains(&posterior){return Err("posterior domain".into());}
                out.weight=alpha+(1.0-2.0*alpha)*posterior;weight(out.weight)?;
            }
        }
        for (l,&node) in next.iter().enumerate(){self.nodes[s.class*1365+s.ids[l]]=node;}
        self.observations[s.class]=after;self.history[s.class]=(self.history[s.class]<<2)|child as u16;Ok(())
    }
    pub fn observations(&self)->[u32;6]{self.observations}
    pub(crate) fn same(&self,b:&Self)->bool{self.history==b.history&&self.observations==b.observations&&self.nodes.iter().zip(&b.nodes).all(|(a,b)|a.raw==b.raw&&a.weight.to_bits()==b.weight.to_bits())}
    #[cfg(frame_audit)]
    pub(crate) fn audit_seed_class(&mut self,c:usize,h:u16,n:u32){self.history[c]=h;self.observations[c]=n;}
    #[cfg(frame_audit)]
    pub(crate) fn audit_seed_node(&mut self,c:usize,id:usize,raw:[u32;4],w:f64){self.nodes[c*1365+id]=Node{raw,weight:w};}
    #[cfg(frame_audit)]
    pub(crate) fn audit_node(&self,c:usize,id:usize)->Node{self.nodes[c*1365+id]}
}

