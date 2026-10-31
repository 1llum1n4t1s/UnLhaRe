//! 新categorical Q32 primitiveの固定診断仕様。binary CTS wire互換ではない。
pub const Q:u64=1u64<<32;
pub const CLASSES:usize=6;
pub const LEVELS:usize=9;
pub const NODES:usize=87381;
pub const CAP:u32=3825340;
pub type Result<T>=std::result::Result<T,&'static str>;
fn prefix(k:usize)->Result<()> {if (1..=4).contains(&k) {Ok(())}else {Err("invalid prefix")}}
pub fn vector(values:[u64;4],k:usize)->Result<()> {
    prefix(k)?;
    if values[..k].iter().any(|&v|v==0 || v>Q) || values[k..].iter().any(|&v|v!=0) {return Err("invalid categorical vector");}
    let total=values.iter().try_fold(0u64,|n,&v|n.checked_add(v).ok_or("vector sum overflow"))?;
    if total!=Q {return Err("vector sum differs from Q");}Ok(())
}
// Hamilton: 余り降順、同値ならchild昇順。全算術はchecked u128。
pub fn normalize(masses:[u128;4],k:usize)->Result<[u64;4]> {
    prefix(k)?;
    let total=masses[..k].iter().try_fold(0u128,|n,&v|n.checked_add(v).ok_or("mass sum overflow"))?;
    if total==0 {return Err("zero mass total");}
    let mut quotient=[0u64;4];let mut remainder=[0u128;4];let mut sum=0u64;
    for j in 0..k {
        let product=masses[j].checked_mul(u128::from(Q)).ok_or("mass scale overflow")?;
        quotient[j]=u64::try_from(product/total).map_err(|_|"quotient conversion")?;
        remainder[j]=product%total;sum=sum.checked_add(quotient[j]).ok_or("quotient sum overflow")?;
    }
    let left=Q.checked_sub(sum).ok_or("Hamilton quotient exceeds Q")? as usize;
    if left>=k {return Err("Hamilton remainder count");}
    let mut order=[0usize,1,2,3];
    order[..k].sort_unstable_by(|&a,&b|remainder[b].cmp(&remainder[a]).then(a.cmp(&b)));
    for &j in &order[..left] {quotient[j]=quotient[j].checked_add(1).ok_or("Hamilton increment overflow")?;}
    if quotient.iter().sum::<u64>()!=Q {return Err("Hamilton normalization");}Ok(quotient)
}
pub fn kt(raw:[u32;4],k:usize)->Result<[u64;4]> {
    prefix(k)?;
    let total=raw.iter().try_fold(0u64,|n,&v|n.checked_add(u64::from(v)).ok_or("raw total overflow"))?;
    if total>u64::from(CAP) {return Err("raw observation cap");}
    let mut masses=[0u128;4];
    for j in 0..k {masses[j]=u128::from(raw[j]).checked_mul(2).and_then(|n|n.checked_add(1)).ok_or("KT mass overflow")?;}
    let result=normalize(masses,k)?;vector(result,k)?;Ok(result)
}
pub fn mixture(weight:u64,own:[u64;4],child:[u64;4],k:usize)->Result<([u64;4],[u128;4])> {
    if weight>Q {return Err("weight outside Q");}vector(own,k)?;vector(child,k)?;
    let complement=Q.checked_sub(weight).ok_or("weight complement")?;
    let mut masses=[0u128;4];
    for j in 0..k {
        let a=u128::from(weight).checked_mul(u128::from(own[j])).ok_or("own mass overflow")?;
        let b=u128::from(complement).checked_mul(u128::from(child[j])).ok_or("child mass overflow")?;
        masses[j]=a.checked_add(b).ok_or("mixture mass overflow")?;
    }
    let total=masses.iter().try_fold(0u128,|n,&v|n.checked_add(v).ok_or("mixture total overflow"))?;
    let expected=u128::from(Q).checked_mul(u128::from(Q)).ok_or("Q square overflow")?;
    if total!=expected {return Err("mixture mass sum");}
    let mixed=normalize(masses,k)?;vector(mixed,k)?;Ok((mixed,masses))
}
pub fn posterior_switch(weight:u64,own:u64,rawmass:u128,after:u32)->Result<(u64,u64,u64)> {
    if weight>Q || own==0 || own>Q || rawmass==0 || after==0 || after>CAP {return Err("invalid switch input");}
    let ownmass=u128::from(weight).checked_mul(u128::from(own)).ok_or("posterior mass overflow")?;
    if rawmass<ownmass || rawmass>u128::from(Q)*u128::from(Q) {return Err("posterior denominator outside mixture");}
    let numerator=ownmass.checked_mul(u128::from(Q)).ok_or("posterior scale overflow")?;
    let posterior=u64::try_from(numerator/rawmass).map_err(|_|"posterior conversion")?;
    if posterior>Q {return Err("posterior outside Q");}
    let denominator=u128::from(after).checked_add(1).ok_or("alpha denominator overflow")?;
    let alpha=u64::try_from(u128::from(Q)/denominator).map_err(|_|"alpha conversion")?;
    if alpha==0 {return Err("zero alpha");}
    let retained=Q.checked_sub(alpha.checked_mul(2).ok_or("alpha product overflow")?).ok_or("retained underflow")?;
    let product=u128::from(retained).checked_mul(u128::from(posterior)).ok_or("switch product overflow")?;
    let next=alpha.checked_add(u64::try_from(product/u128::from(Q)).map_err(|_|"switch conversion")?).ok_or("next weight overflow")?;
    if next<alpha || next>Q-alpha || next>Q {return Err("next weight bounds");}
    Ok((posterior,alpha,next))
}
pub fn path(history:u16)->[usize;LEVELS] {
    let mut result=[0usize;LEVELS];
    for l in 1..LEVELS {result[l]=4*result[l-1]+1+usize::from((history>>(2*(l-1)))&3);}
    result
}
#[derive(Clone,Copy,Debug,PartialEq,Eq)]
pub struct Node {pub raw:[u32;4],pub weight:u64}
#[derive(Clone,Debug,PartialEq,Eq)]
pub struct Kernel {pub kt:[[u64;4];LEVELS],pub mixed:[[u64;4];LEVELS],pub masses:[[u128;4];LEVELS],pub depth:usize}
pub fn predict_kernel(raw:[[u32;4];LEVELS],weights:[u64;LEVELS],k:usize,depth:usize)->Result<Kernel> {
    prefix(k)?;if depth>=LEVELS || weights[depth]!=Q/2 {return Err("invalid kernel depth/leaf");}
    let mut snapshot=Kernel{kt:[[0;4];LEVELS],mixed:[[0;4];LEVELS],masses:[[0;4];LEVELS],depth};
    for l in 0..=depth {if weights[l]>Q {return Err("kernel weight");}snapshot.kt[l]=kt(raw[l],k)?;}
    snapshot.mixed[depth]=snapshot.kt[depth];
    for l in (0..depth).rev() {
        (snapshot.mixed[l],snapshot.masses[l])=mixture(weights[l],snapshot.kt[l],snapshot.mixed[l+1],k)?;
    }Ok(snapshot)
}
pub fn update_kernel(s:&Kernel,weights:[u64;LEVELS],k:usize,child:usize,after:u32)->Result<[u64;LEVELS]> {
    prefix(k)?;if child>=k || s.depth>=LEVELS || after==0 || after>CAP || weights[s.depth]!=Q/2 {return Err("invalid kernel update");}
    let mut next=[Q/2;LEVELS];
    for l in 0..s.depth {next[l]=posterior_switch(weights[l],s.kt[l][child],s.masses[l][child],after)?.2;}
    Ok(next)
}
#[derive(Clone,Debug,PartialEq,Eq)]
pub struct Snapshot {
    pub class:usize,pub prefix:usize,pub ids:[usize;LEVELS],pub history:u16,pub observations:u32,
    pub raw:[[u32;4];LEVELS],pub weights:[u64;LEVELS],pub kernel:Kernel,
}
#[derive(Clone,Debug,PartialEq,Eq)]
pub struct Cts {nodes:Vec<Node>,history:[u16;CLASSES],observations:[u32;CLASSES]}
impl Cts {
    pub fn new()->Result<Self> {
        let length=CLASSES.checked_mul(NODES).ok_or("CTS allocation shape")?;
        let mut nodes=Vec::new();nodes.try_reserve_exact(length).map_err(|_|"CTS allocation failed")?;
        nodes.resize(length,Node{raw:[0;4],weight:Q/2});
        Ok(Self{nodes,history:[0;CLASSES],observations:[0;CLASSES]})
    }
    // observed childを受け取らず、class/prefixと過去stateだけから予測する。
    pub fn predict(&self,class:usize,k:usize)->Result<Snapshot> {
        prefix(k)?;if class>=CLASSES {return Err("invalid class");}
        if self.observations[class]>CAP {return Err("class observation cap");}
        let ids=path(self.history[class]);let mut raw=[[0;4];LEVELS];let mut weights=[0;LEVELS];
        for l in 0..LEVELS {
            let node=self.nodes.get(class*NODES+ids[l]).ok_or("prediction node index")?;
            raw[l]=node.raw;weights[l]=node.weight;
        }
        let kernel=predict_kernel(raw,weights,k,LEVELS-1)?;
        Ok(Snapshot{class,prefix:k,ids,history:self.history[class],observations:self.observations[class],raw,weights,kernel})
    }
    pub fn observe(&mut self,s:&Snapshot,child:usize)->Result<()> {
        prefix(s.prefix)?;if s.class>=CLASSES || child>=s.prefix {return Err("invalid observation");}
        if s.observations>=CAP || self.observations[s.class]>=CAP {return Err("class update cap");}
        // derived vectors/rawmassを含む現在snapshot全体と照合し、改変もcommit前に拒否する。
        if s!=&self.predict(s.class,s.prefix)? {return Err("stale or modified snapshot");}
        let after=s.observations.checked_add(1).ok_or("observation overflow")?;
        let next=update_kernel(&s.kernel,s.weights,s.prefix,child,after)?;
        let mut prepared=[Node{raw:[0;4],weight:Q/2};LEVELS];
        for l in 0..LEVELS {
            let total=s.raw[l].iter().try_fold(0u64,|n,&v|n.checked_add(u64::from(v)).ok_or("node total overflow"))?;
            if total>=u64::from(CAP) {return Err("node update cap");}
            prepared[l]=Node{raw:s.raw[l],weight:next[l]};
            prepared[l].raw[child]=prepared[l].raw[child].checked_add(1).ok_or("node count overflow")?;
        }
        let history=((s.history<<2)|child as u16)&0xffff;
        // allocationなし。全検査と全prepared nodeの完成後にだけcommitする。
        for l in 0..LEVELS {self.nodes[s.class*NODES+s.ids[l]]=prepared[l];}
        self.observations[s.class]=after;self.history[s.class]=history;Ok(())
    }
    pub fn nodes(&self)->&[Node] {&self.nodes}
    pub fn histories(&self)->[u16;CLASSES] {self.history}
    pub fn observations(&self)->[u32;CLASSES] {self.observations}
    #[cfg(primitive_audit)]
    pub fn audit_seed_class(&mut self,class:usize,history:u16,observations:u32) {self.history[class]=history;self.observations[class]=observations;}
    #[cfg(primitive_audit)]
    pub fn audit_seed_node(&mut self,class:usize,id:usize,raw:[u32;4],weight:u64) {self.nodes[class*NODES+id]=Node{raw,weight};}
}

