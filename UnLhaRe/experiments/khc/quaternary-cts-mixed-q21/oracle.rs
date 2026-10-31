//! 新policyを独立wide算術で記述する。候補helperと旧Q32 primitiveは呼ばない。
use crate::fixed_math::Math;
pub const Q:u64=2097152;
pub const CAP:u32=3825340;
pub const LEVELS:usize=9;
pub const CLASSES:usize=6;
pub type Result<T>=std::result::Result<T,&'static str>;
fn mul(a:u128,b:u128)->Result<u128>{a.checked_mul(b).ok_or("unsigned product overflow")}
fn add(a:u128,b:u128)->Result<u128>{a.checked_add(b).ok_or("unsigned sum overflow")}
fn smul(a:i128,b:i128)->Result<i128>{a.checked_mul(b).ok_or("signed product overflow")}
fn sadd(a:i128,b:i128)->Result<i128>{a.checked_add(b).ok_or("signed sum overflow")}
fn si(n:i128)->Result<i64>{i64::try_from(n).map_err(|_|"signed conversion")}
fn ui(n:u128)->Result<u64>{u64::try_from(n).map_err(|_|"unsigned conversion")}
fn prefix(k:usize)->Result<()>{if k==0||k>4{Err("invalid prefix")}else{Ok(())}}
pub fn vector(v:[u64;4],k:usize)->Result<()>{prefix(k)?;for j in 0..4{if (j<k&&(v[j]==0||v[j]>Q))||(j>=k&&v[j]!=0){return Err("invalid categorical vector");}}let mut total=0u128;for n in v{total=add(total,u128::from(n))?;}if total!=u128::from(Q){return Err("vector sum differs from Q");}Ok(())}
// 余り順位を繰り返し選ぶ独立実装。候補のsort helperを共有しない。
fn hamilton(m:[u128;4],k:usize,target:u128,reserve:u64)->Result<[u64;4]>{
    prefix(k)?;let mut total=0u128;for &x in &m[..k]{total=add(total,x)?;}if total==0{return Err("zero mass total");}
    let mut out=[0u64;4];let mut rem=[0u128;4];let mut assigned=0u128;
    for j in 0..k{let n=mul(m[j],target)?;out[j]=ui(n/total)?;rem[j]=n%total;assigned=add(assigned,u128::from(out[j]))?;}
    let left=target.checked_sub(assigned).ok_or("Hamilton quotient exceeds Q")?;
    if left>=k as u128{return Err("Hamilton remainder count");}let mut picked=[false;4];
    for _ in 0..left{let mut best=None;for j in 0..k{if !picked[j]&&best.is_none_or(|b|rem[j]>rem[b]){best=Some(j);}}let j=best.ok_or("Hamilton remainder count")?;picked[j]=true;out[j]=out[j].checked_add(1).ok_or("Hamilton increment overflow")?;}
    for x in &mut out[..k]{*x=x.checked_add(reserve).ok_or("Hamilton increment overflow")?;}if out.iter().map(|&x|u128::from(x)).sum::<u128>()!=u128::from(Q){return Err("Hamilton normalization");}Ok(out)
}
pub fn normalize(m:[u128;4],k:usize)->Result<[u64;4]>{prefix(k)?;if m[..k].iter().any(|&x|x>16381*u128::from(Q))||m[k..].iter().any(|&x|x!=0){return Err("pool mass domain");}hamilton(m,k,u128::from(Q),0)}
pub fn kt(raw:[u32;4],k:usize)->Result<[u64;4]>{prefix(k)?;let mut total=0u128;for x in raw{total=add(total,u128::from(x))?;}if total>u128::from(CAP){return Err("raw observation cap");}let mut m=[0;4];for j in 0..k{m[j]=add(mul(2,u128::from(raw[j]))?,1)?;}let v=hamilton(m,k,u128::from(Q)-k as u128,1)?;vector(v,k)?;Ok(v)}
pub fn mixture(w:u64,a:[u64;4],b:[u64;4],k:usize)->Result<([u64;4],[u128;4])>{if w>Q{return Err("weight outside Q");}vector(a,k)?;vector(b,k)?;let mut m=[0;4];for j in 0..k{m[j]=add(mul(u128::from(w),u128::from(a[j]))?,mul(u128::from(Q-w),u128::from(b[j]))?)?;}if m.iter().sum::<u128>()!=mul(u128::from(Q),u128::from(Q))?{return Err("mixture mass sum");}let v=hamilton(m,k,u128::from(Q),0)?;vector(v,k)?;Ok((v,m))}
pub fn posterior_switch(w:u64,own:u64,m:u128,after:u32)->Result<(u64,u64,u64)>{
    if w>Q||own==0||own>Q||m==0||after==0||after>CAP{return Err("invalid switch input");}
    let ownmass=mul(u128::from(w),u128::from(own))?;if m<ownmass.max(1)||m>mul(u128::from(Q),u128::from(Q))?{return Err("posterior denominator outside mixture");}
    let p=ui(mul(ownmass,u128::from(Q))?/m)?;if p>Q{return Err("posterior outside Q");}
    let alpha=ui(u128::from(Q)/add(u128::from(after),1)?)?.max(1);let retained=u128::from(Q).checked_sub(mul(2,u128::from(alpha))?).ok_or("retained underflow")?;
    let next=ui(add(u128::from(alpha),mul(retained,u128::from(p))?/u128::from(Q))?)?;if next<alpha||next>Q-alpha{return Err("next weight bounds");}Ok((p,alpha,next))
}
pub fn path(h:u16)->[usize;LEVELS]{let mut v=[0;LEVELS];let mut bits=h;for l in 1..LEVELS{v[l]=v[l-1]*4+1+usize::from(bits&3);bits>>=2;}v}
#[derive(Clone,Copy,Debug,PartialEq,Eq)] pub struct Node{pub raw:[u32;4],pub weight:u64}
#[derive(Clone,Debug,PartialEq,Eq)] pub struct Kernel{pub kt:[[u64;4];LEVELS],pub mixed:[[u64;4];LEVELS],pub masses:[[u128;4];LEVELS],pub depth:usize}
pub fn predict_kernel(raw:[[u32;4];LEVELS],w:[u64;LEVELS],k:usize,d:usize)->Result<Kernel>{prefix(k)?;if d>=LEVELS||w[d]!=Q/2{return Err("invalid kernel depth/leaf");}let mut s=Kernel{kt:[[0;4];LEVELS],mixed:[[0;4];LEVELS],masses:[[0;4];LEVELS],depth:d};for l in 0..=d{if w[l]>Q{return Err("kernel weight");}s.kt[l]=kt(raw[l],k)?;}s.mixed[d]=s.kt[d];let mut l=d;while l>0{l-=1;(s.mixed[l],s.masses[l])=mixture(w[l],s.kt[l],s.mixed[l+1],k)?;}Ok(s)}
pub fn update_kernel(s:&Kernel,w:[u64;LEVELS],k:usize,j:usize,after:u32)->Result<[u64;LEVELS]>{prefix(k)?;if j>=k||s.depth>=LEVELS||after==0||after>CAP||w[s.depth]!=Q/2{return Err("invalid kernel update");}let mut out=[Q/2;LEVELS];for l in 0..s.depth{out[l]=posterior_switch(w[l],s.kt[l][j],s.masses[l][j],after)?.2;}Ok(out)}
#[derive(Clone,Debug,PartialEq,Eq)] pub struct Snapshot{pub class:usize,pub prefix:usize,pub ids:[usize;LEVELS],pub history:u16,pub observations:u32,pub raw:[[u32;4];LEVELS],pub weights:[u64;LEVELS],pub kernel:Kernel}
pub fn node_count(d:usize)->Result<usize>{if d>=LEVELS{return Err("unsupported CTS depth");}let mut n=1usize;let mut total=1usize;for _ in 0..d{n=n.checked_mul(4).ok_or("CTS allocation shape")?;total=total.checked_add(n).ok_or("CTS allocation shape")?;}CLASSES.checked_mul(total).ok_or("CTS allocation shape")?;Ok(total)}
#[derive(Clone,Debug,PartialEq,Eq)] pub struct Cts{nodes:Vec<Node>,history:[u16;CLASSES],observations:[u32;CLASSES],depth:usize,node_count:usize}
impl Cts{
    pub fn new(depth:usize)->Result<Self>{let n=node_count(depth)?;let mut nodes=Vec::new();nodes.try_reserve_exact(CLASSES*n).map_err(|_|"CTS allocation failed")?;nodes.resize(CLASSES*n,Node{raw:[0;4],weight:Q/2});Ok(Self{nodes,history:[0;CLASSES],observations:[0;CLASSES],depth,node_count:n})}
    pub fn predict(&self,c:usize,k:usize)->Result<Snapshot>{prefix(k)?;if c>=CLASSES{return Err("invalid class");}if self.observations[c]>CAP{return Err("class observation cap");}let ids=path(self.history[c]);let mut raw=[[0;4];LEVELS];let mut weights=[0;LEVELS];for l in 0..=self.depth{let node=self.nodes.get(c*self.node_count+ids[l]).ok_or("prediction node index")?;raw[l]=node.raw;weights[l]=node.weight;}let kernel=predict_kernel(raw,weights,k,self.depth)?;Ok(Snapshot{class:c,prefix:k,ids,history:self.history[c],observations:self.observations[c],raw,weights,kernel})}
    pub fn observe(&mut self,s:&Snapshot,j:usize)->Result<()>{prefix(s.prefix)?;if s.class>=CLASSES||j>=s.prefix{return Err("invalid observation");}if s.observations>=CAP||self.observations[s.class]>=CAP{return Err("class update cap");}let current=self.predict(s.class,s.prefix)?;if s!=&current{return Err("stale or modified snapshot");}let after=s.observations.checked_add(1).ok_or("observation overflow")?;let w=update_kernel(&s.kernel,s.weights,s.prefix,j,after)?;let mut pending=[Node{raw:[0;4],weight:Q/2};LEVELS];for l in 0..=self.depth{let total=s.raw[l].iter().map(|&x|u128::from(x)).sum::<u128>();if total>=u128::from(CAP){return Err("node update cap");}let mut raw=s.raw[l];raw[j]=raw[j].checked_add(1).ok_or("node count overflow")?;pending[l]=Node{raw,weight:w[l]};}for l in 0..=self.depth{self.nodes[s.class*self.node_count+s.ids[l]]=pending[l];}self.observations[s.class]=after;self.history[s.class]=(s.history<<2)|j as u16;Ok(())}
    pub fn depth(&self)->usize{self.depth}pub fn node_count(&self)->usize{self.node_count}pub fn nodes(&self)->&[Node]{&self.nodes}pub fn histories(&self)->[u16;CLASSES]{self.history}pub fn observations(&self)->[u32;CLASSES]{self.observations}
    #[cfg(primitive_audit)] pub fn audit_seed_class(&mut self,c:usize,h:u16,n:u32){self.history[c]=h;self.observations[c]=n;}
    #[cfg(primitive_audit)] pub fn audit_seed_node(&mut self,c:usize,id:usize,raw:[u32;4],w:u64){self.nodes[c*self.node_count+id]=Node{raw,weight:w};}
}
#[derive(Clone,Debug,PartialEq,Eq)] pub struct Prediction{pub prefix:usize,pub weights:[u64;5],pub features:[[i64;4];5],pub scores:[i64;4],pub q:[u64;4],pub p:[u64;4],pub frequencies:[u32;4],pub cumulative:[u32;5]}
#[derive(Clone,Debug,PartialEq,Eq)] pub struct Update{pub factor:u64,pub expected:[i64;5],pub gradient:[i64;5],pub delta:[i64;5],pub next:[u64;5]}
fn feature_domain(f:[[i64;4];5],k:usize)->Result<()>{for i in 0..5{for j in 0..4{let range=if i==4{-62517933908..=0}else{0..=44655667077};if (j<k&&!range.contains(&f[i][j]))||(j>=k&&f[i][j]!=0){return Err("pool feature domain");}}}Ok(())}
pub fn smooth(q:[u64;4],k:usize)->Result<([u64;4],[u32;4],[u32;5])>{
    if k==0||k>4{return Err("invalid prefix");}
    let mut m=[0;4];for j in 0..k{m[j]=add(mul(mul(4095,k as u128)?,u128::from(q[j]))?,u128::from(Q))?;}
    let p=normalize(m,k)?;vector(p,k)?;if p[..k].iter().any(|&n|n<Q/(4096*k as u64)){return Err("uniform minimum");}
    let mut f=[0u32;4];let mut r=[0u128;4];let mut total=0u32;for j in 0..k{let n=mul(u128::from(p[j]),32768)?;f[j]=u32::try_from(n/u128::from(Q)).map_err(|_|"CDF conversion")?;r[j]=n%u128::from(Q);total=total.checked_add(f[j]).ok_or("CDF sum")?;}
    let left=32768u32.checked_sub(total).ok_or("CDF excess")?;if left as usize>=k{return Err("CDF residual count");}let mut used=[false;4];for _ in 0..left{let mut best=None;for j in 0..k{if !used[j]&&best.is_none_or(|b|r[j]>r[b]){best=Some(j);}}let j=best.ok_or("CDF residual count")?;used[j]=true;f[j]=f[j].checked_add(1).ok_or("CDF increment")?;}if f[..k].iter().any(|&n|n<2)||f[k..].iter().any(|&n|n!=0){return Err("CDF positive frequency");}let mut c=[0u32;5];for j in 0..4{c[j+1]=c[j].checked_add(f[j]).ok_or("CDF cumulative")?;}if c[4]!=32768{return Err("CDF total");}Ok((p,f,c))
}
pub fn audit_features(math:&Math,f:[[i64;4];5],w:[u64;5],k:usize)->Result<Prediction>{if k==0||k>4||w.iter().any(|&n|n>2*Q){return Err("pool prefix/weight");}feature_domain(f,k)?;let mut scores=[0;4];for j in 0..k{let mut n=0i128;for i in 0..5{n=sadd(n,smul(i128::from(w[i]),i128::from(f[i][j]))?)?;}scores[j]=si(n.checked_div(i128::from(Q)).ok_or("signed division domain")?)?;}let max=*scores[..k].iter().max().ok_or("pool maximum")?;let mut m=[0;4];for j in 0..k{m[j]=u128::from(math.exp_neg(max.checked_sub(scores[j]).ok_or("score difference overflow")?)?);}let q=normalize(m,k)?;let(p,frequencies,cumulative)=smooth(q,k)?;Ok(Prediction{prefix:k,weights:w,features:f,scores,q,p,frequencies,cumulative})}
pub fn predict(math:&Math,counts:[[u16;4];4],w:[u64;5],cts:[u64;4],k:usize)->Result<Prediction>{if k==0||k>4||w.iter().any(|&n|n>2*Q){return Err("pool prefix/weight");}vector(cts,k)?;for row in counts{if row.contains(&0)||row.iter().map(|&x|u128::from(x)).sum::<u128>()>32768{return Err("pool count row");}}let mut f=[[0;4];5];for i in 0..4{for j in 0..k{f[i][j]=math.ln_count(u64::from(counts[i][j]))?;}}for j in 0..k{f[4][j]=math.ln_cts(ui(mul(u128::from(cts[j]),2048)?)?)?;}audit_features(math,f,w,k)}
pub fn observe(s:&Prediction,j:usize)->Result<Update>{if s.prefix==0||s.prefix>4||j>=s.prefix||s.weights.iter().any(|&n|n>2*Q){return Err("pool observed child/weights");}if s.q[..s.prefix].iter().any(|&n|n>Q)||s.q[s.prefix..].iter().any(|&n|n!=0)||s.q.iter().map(|&n|u128::from(n)).sum::<u128>()!=u128::from(Q){return Err("pool q snapshot");}vector(s.p,s.prefix)?;feature_domain(s.features,s.prefix)?;let mass=mul(mul(4095,s.prefix as u128)?,u128::from(s.q[j]))?;let factor=ui(mul(mass,u128::from(Q))?/add(mass,u128::from(Q))?)?;let mut expected=[0;5];let mut gradient=[0;5];let mut delta=[0;5];let mut next=[0;5];for i in 0..5{let mut sum=0i128;for child in 0..s.prefix{sum=sadd(sum,smul(i128::from(s.q[child]),i128::from(s.features[i][child]))?)?;}expected[i]=si(sum.checked_div(i128::from(Q)).ok_or("signed division domain")?)?;let difference=s.features[i][j].checked_sub(expected[i]).ok_or("gradient difference")?;gradient[i]=si(smul(i128::from(factor),i128::from(difference))?.checked_div(i128::from(Q)).ok_or("signed division domain")?)?;delta[i]=gradient[i]/524288;next[i]=ui(u128::try_from(sadd(i128::from(s.weights[i]),i128::from(delta[i]))?.clamp(0,2*i128::from(Q))).map_err(|_|"unsigned conversion")?)?;}Ok(Update{factor,expected,gradient,delta,next})}
