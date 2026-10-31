//! mixed Q21専用のchecked64 CTS。旧Q32の公開形式へ接続しない。
pub const Q: u64 = 1 << 21;
pub const CAP: u32 = 3825340;
pub const CLASSES: usize = 6;
pub const LEVELS: usize = 9;
pub type Result<T> = std::result::Result<T, &'static str>;
fn prefix(k: usize) -> Result<()> { if (1..=4).contains(&k) { Ok(()) } else { Err("invalid prefix") } }
pub fn vector(v: [u64;4], k: usize) -> Result<()> {
    prefix(k)?;
    if v[..k].iter().any(|&n|n==0||n>Q)||v[k..].iter().any(|&n|n!=0){return Err("invalid categorical vector");}
    let t=v.iter().try_fold(0u64,|a,&b|a.checked_add(b).ok_or("vector sum overflow"))?;
    if t!=Q{return Err("vector sum differs from Q");} Ok(())
}
// KT予約と通常配分の違いはtargetとreserveで明示する。
fn distribute(m:[u64;4],k:usize,target:u64,reserve:u64)->Result<[u64;4]>{
    prefix(k)?;
    let t=m[..k].iter().try_fold(0u64,|a,&b|a.checked_add(b).ok_or("mass sum overflow"))?;
    if t==0{return Err("zero mass total");}
    let mut v=[0;4];let mut r=[0;4];let mut sum=0u64;
    for j in 0..k{let x=m[j].checked_mul(target).ok_or("mass scale overflow")?;v[j]=x/t;r[j]=x%t;sum=sum.checked_add(v[j]).ok_or("quotient sum overflow")?;}
    let left=target.checked_sub(sum).ok_or("Hamilton quotient exceeds Q")? as usize;
    if left>=k{return Err("Hamilton remainder count");}
    let mut order=[0,1,2,3];order[..k].sort_unstable_by(|&a,&b|r[b].cmp(&r[a]).then(a.cmp(&b)));
    for &j in &order[..left]{v[j]=v[j].checked_add(1).ok_or("Hamilton increment overflow")?;}
    for x in &mut v[..k]{*x=x.checked_add(reserve).ok_or("Hamilton increment overflow")?;}
    if v.iter().sum::<u64>()!=Q{return Err("Hamilton normalization");}Ok(v)
}
pub fn normalize(m:[u64;4],k:usize)->Result<[u64;4]>{
    prefix(k)?;
    if m[..k].iter().any(|&x|x>16381*Q)||m[k..].iter().any(|&x|x!=0){return Err("pool mass domain");}
    distribute(m,k,Q,0)
}
pub fn kt(raw:[u32;4],k:usize)->Result<[u64;4]>{
    prefix(k)?;
    let total=raw.iter().try_fold(0u64,|a,&b|a.checked_add(u64::from(b)).ok_or("raw total overflow"))?;
    if total>u64::from(CAP){return Err("raw observation cap");}
    let mut m=[0;4];for j in 0..k{m[j]=u64::from(raw[j]).checked_mul(2).and_then(|n|n.checked_add(1)).ok_or("KT mass overflow")?;}
    let v=distribute(m,k,Q-k as u64,1)?;vector(v,k)?;Ok(v)
}
pub fn mixture(w:u64,a:[u64;4],b:[u64;4],k:usize)->Result<([u64;4],[u64;4])>{
    if w>Q{return Err("weight outside Q");}vector(a,k)?;vector(b,k)?;
    let mut m=[0u64;4];for j in 0..k{m[j]=w.checked_mul(a[j]).and_then(|x|(Q-w).checked_mul(b[j]).and_then(|y|x.checked_add(y))).ok_or("mixture mass overflow")?;}
    let t=m.iter().try_fold(0u64,|a,&b|a.checked_add(b).ok_or("mixture total overflow"))?;
    if t!=Q*Q{return Err("mixture mass sum");}
    let v=distribute(m,k,Q,0)?;vector(v,k)?;Ok((v,m))
}
pub fn posterior_switch(w:u64,own:u64,m:u64,after:u32)->Result<(u64,u64,u64)>{
    if w>Q||own==0||own>Q||m==0||after==0||after>CAP{return Err("invalid switch input");}
    let ownmass=w.checked_mul(own).ok_or("posterior mass overflow")?;
    if m<ownmass.max(1)||m>Q*Q{return Err("posterior denominator outside mixture");}
    let p=ownmass.checked_mul(Q).ok_or("posterior scale overflow")?/m;
    if p>Q{return Err("posterior outside Q");}
    let alpha=(Q/u64::from(after.checked_add(1).ok_or("alpha denominator overflow")?)).max(1);
    let retained=Q.checked_sub(alpha.checked_mul(2).ok_or("alpha product overflow")?).ok_or("retained underflow")?;
    let next=alpha.checked_add(retained.checked_mul(p).ok_or("switch product overflow")?/Q).ok_or("next weight overflow")?;
    if next<alpha||next>Q-alpha{return Err("next weight bounds");}Ok((p,alpha,next))
}
pub fn path(history:u16)->[usize;LEVELS]{let mut p=[0;LEVELS];for l in 1..LEVELS{p[l]=4*p[l-1]+1+usize::from((history>>(2*(l-1)))&3);}p}
#[derive(Clone,Copy,Debug,PartialEq,Eq)]
pub struct Node{pub raw:[u32;4],pub weight:u64}
#[derive(Clone,Debug,PartialEq,Eq)]
pub struct Kernel{pub kt:[[u64;4];LEVELS],pub mixed:[[u64;4];LEVELS],pub masses:[[u64;4];LEVELS],pub depth:usize}
pub fn predict_kernel(raw:[[u32;4];LEVELS],weights:[u64;LEVELS],k:usize,depth:usize)->Result<Kernel>{
    prefix(k)?;if depth>=LEVELS||weights[depth]!=Q/2{return Err("invalid kernel depth/leaf");}
    let mut s=Kernel{kt:[[0;4];LEVELS],mixed:[[0;4];LEVELS],masses:[[0;4];LEVELS],depth};
    for l in 0..=depth{if weights[l]>Q{return Err("kernel weight");}s.kt[l]=kt(raw[l],k)?;}
    s.mixed[depth]=s.kt[depth];for l in (0..depth).rev(){(s.mixed[l],s.masses[l])=mixture(weights[l],s.kt[l],s.mixed[l+1],k)?;}Ok(s)
}
pub fn update_kernel(s:&Kernel,w:[u64;LEVELS],k:usize,child:usize,after:u32)->Result<[u64;LEVELS]>{
    prefix(k)?;if child>=k||s.depth>=LEVELS||after==0||after>CAP||w[s.depth]!=Q/2{return Err("invalid kernel update");}
    let mut next=[Q/2;LEVELS];for l in 0..s.depth{next[l]=posterior_switch(w[l],s.kt[l][child],s.masses[l][child],after)?.2;}Ok(next)
}
#[derive(Clone,Debug,PartialEq,Eq)]
pub struct RawSnapshot{pub class:usize,pub prefix:usize,pub ids:[usize;LEVELS],pub history:u16,pub observations:u32,pub raw:[[u32;4];LEVELS],pub weights:[u64;LEVELS],pub kernel:Kernel}
#[derive(Clone,Debug,PartialEq,Eq)]
pub struct Snapshot{visible:RawSnapshot,certified:RawSnapshot}
impl std::ops::Deref for Snapshot{type Target=RawSnapshot;fn deref(&self)->&RawSnapshot{&self.visible}}
impl std::ops::DerefMut for Snapshot{fn deref_mut(&mut self)->&mut RawSnapshot{&mut self.visible}}
impl Snapshot{
    fn seal(v:RawSnapshot)->Self{Self{certified:v.clone(),visible:v}}
    #[cfg(primitive_audit)] pub fn audit_rebase(&mut self,other:&Self){self.visible=other.visible.clone();}
    #[cfg(primitive_audit)] pub fn audit_sealed(&self)->bool{self.visible==self.certified}
}
pub fn node_count(depth:usize)->Result<usize>{
    if depth>=LEVELS{return Err("unsupported CTS depth");}let mut n=0usize;let mut width=1usize;
    for l in 0..=depth{n=n.checked_add(width).ok_or("CTS allocation shape")?;if l<depth{width=width.checked_mul(4).ok_or("CTS allocation shape")?;}}
    CLASSES.checked_mul(n).ok_or("CTS allocation shape")?;Ok(n)
}
#[derive(Clone,Debug,PartialEq,Eq)]
pub struct Cts{nodes:Vec<Node>,history:[u16;CLASSES],observations:[u32;CLASSES],depth:usize,node_count:usize}
impl Cts{
    pub fn new(depth:usize)->Result<Self>{let n=node_count(depth)?;let mut nodes=Vec::new();nodes.try_reserve_exact(CLASSES*n).map_err(|_|"CTS allocation failed")?;nodes.resize(CLASSES*n,Node{raw:[0;4],weight:Q/2});Ok(Self{nodes,history:[0;CLASSES],observations:[0;CLASSES],depth,node_count:n})}
    pub fn predict(&self,class:usize,k:usize)->Result<Snapshot>{
        prefix(k)?;if class>=CLASSES{return Err("invalid class");}if self.observations[class]>CAP{return Err("class observation cap");}
        let ids=path(self.history[class]);let mut raw=[[0;4];LEVELS];let mut w=[0;LEVELS];
        for l in 0..=self.depth{let n=self.nodes.get(class*self.node_count+ids[l]).ok_or("prediction node index")?;raw[l]=n.raw;w[l]=n.weight;}
        let kernel=predict_kernel(raw,w,k,self.depth)?;Ok(Snapshot::seal(RawSnapshot{class,prefix:k,ids,history:self.history[class],observations:self.observations[class],raw,weights:w,kernel}))
    }
    pub fn observe(&mut self,s:&Snapshot,child:usize)->Result<()>{
        prefix(s.prefix)?;if s.class>=CLASSES||child>=s.prefix{return Err("invalid observation");}
        if s.observations>=CAP||self.observations[s.class]>=CAP{return Err("class update cap");}
        let ids=path(self.history[s.class]);let mut raw=[[0;4];LEVELS];let mut w=[0;LEVELS];
        for l in 0..=self.depth{let n=self.nodes.get(s.class*self.node_count+ids[l]).ok_or("prediction node index")?;raw[l]=n.raw;w[l]=n.weight;}
        if w[self.depth]!=Q/2{return Err("invalid kernel depth/leaf");}
        for l in 0..=self.depth{if w[l]>Q{return Err("kernel weight");}let t=raw[l].iter().try_fold(0u64,|a,&b|a.checked_add(u64::from(b)).ok_or("raw total overflow"))?;if t>u64::from(CAP){return Err("raw observation cap");}}
        if s.kernel.depth!=self.depth||s.ids!=ids||s.history!=self.history[s.class]||s.observations!=self.observations[s.class]||s.raw!=raw||s.weights!=w{return Err("stale or modified snapshot");}
        if s.visible!=s.certified&&s.visible!=self.predict(s.class,s.prefix)?.visible{return Err("stale or modified snapshot");}
        let after=s.observations.checked_add(1).ok_or("observation overflow")?;let next=update_kernel(&s.kernel,s.weights,s.prefix,child,after)?;
        let mut prepared=[Node{raw:[0;4],weight:Q/2};LEVELS];
        for l in 0..=self.depth{let total=s.raw[l].iter().try_fold(0u64,|a,&b|a.checked_add(u64::from(b)).ok_or("node total overflow"))?;if total>=u64::from(CAP){return Err("node update cap");}prepared[l]=Node{raw:s.raw[l],weight:next[l]};prepared[l].raw[child]=prepared[l].raw[child].checked_add(1).ok_or("node count overflow")?;}
        let history=(s.history<<2)|child as u16;
        for l in 0..=self.depth{self.nodes[s.class*self.node_count+s.ids[l]]=prepared[l];}self.observations[s.class]=after;self.history[s.class]=history;Ok(())
    }
    pub fn depth(&self)->usize{self.depth}pub fn node_count(&self)->usize{self.node_count}
    pub fn nodes(&self)->&[Node]{&self.nodes}pub fn histories(&self)->[u16;CLASSES]{self.history}pub fn observations(&self)->[u32;CLASSES]{self.observations}
    #[cfg(primitive_audit)] pub fn audit_seed_class(&mut self,c:usize,h:u16,n:u32){self.history[c]=h;self.observations[c]=n;}
    #[cfg(primitive_audit)] pub fn audit_seed_node(&mut self,c:usize,id:usize,raw:[u32;4],weight:u64){self.nodes[c*self.node_count+id]=Node{raw,weight};}
}
