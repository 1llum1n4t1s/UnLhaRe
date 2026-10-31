//! Q² mixtureだけをbitshift Hamiltonへ同値専用化。一般KT/pool normalizeは凍結。
pub use crate::reference_cts::{Q,CLASSES,LEVELS,NODES,CAP,Result,Node,Kernel,Snapshot,vector,normalize,kt,posterior_switch,path,update_kernel};
fn prefix(k:usize)->Result<()> {if (1..=4).contains(&k){Ok(())}else{Err("invalid prefix")}}
fn normalize_q2(masses:[u128;4],k:usize)->Result<[u64;4]> {
    prefix(k)?;
    let total=masses[..k].iter().try_fold(0u128,|n,&v|n.checked_add(v).ok_or("mass sum overflow"))?;
    let expected=u128::from(Q).checked_mul(u128::from(Q)).ok_or("Q square overflow")?;
    if total!=expected{return Err("mixture mass sum");}
    let mut quotient=[0u64;4];let mut remainder=[0u128;4];let mut sum=0u64;
    for j in 0..k{
        quotient[j]=u64::try_from(masses[j]>>32).map_err(|_|"quotient conversion")?;
        remainder[j]=masses[j]&u128::from(Q-1);sum=sum.checked_add(quotient[j]).ok_or("quotient sum overflow")?;
    }
    let left=Q.checked_sub(sum).ok_or("Hamilton quotient exceeds Q")? as usize;
    if left>=k{return Err("Hamilton remainder count");}
    let mut order=[0usize,1,2,3];order[..k].sort_unstable_by(|&a,&b|remainder[b].cmp(&remainder[a]).then(a.cmp(&b)));
    for &j in &order[..left]{quotient[j]=quotient[j].checked_add(1).ok_or("Hamilton increment overflow")?;}
    if quotient.iter().sum::<u64>()!=Q{return Err("Hamilton normalization");}Ok(quotient)
}
pub fn mixture(weight:u64,own:[u64;4],child:[u64;4],k:usize)->Result<([u64;4],[u128;4])>{
    if weight>Q{return Err("weight outside Q");}vector(own,k)?;vector(child,k)?;
    let complement=Q.checked_sub(weight).ok_or("weight complement")?;let mut masses=[0u128;4];
    for j in 0..k{
        let a=u128::from(weight).checked_mul(u128::from(own[j])).ok_or("own mass overflow")?;
        let b=u128::from(complement).checked_mul(u128::from(child[j])).ok_or("child mass overflow")?;
        masses[j]=a.checked_add(b).ok_or("mixture mass overflow")?;
    }
    let total=masses.iter().try_fold(0u128,|n,&v|n.checked_add(v).ok_or("mixture total overflow"))?;
    let expected=u128::from(Q).checked_mul(u128::from(Q)).ok_or("Q square overflow")?;
    if total!=expected{return Err("mixture mass sum");}
    let mixed=normalize_q2(masses,k)?;vector(mixed,k)?;Ok((mixed,masses))
}
pub fn predict_kernel(raw:[[u32;4];LEVELS],weights:[u64;LEVELS],k:usize,depth:usize)->Result<Kernel> {
    prefix(k)?;if depth>=LEVELS || weights[depth]!=Q/2 {return Err("invalid kernel depth/leaf");}
    let mut snapshot=Kernel{kt:[[0;4];LEVELS],mixed:[[0;4];LEVELS],masses:[[0;4];LEVELS],depth};
    for l in 0..=depth {if weights[l]>Q {return Err("kernel weight");}snapshot.kt[l]=kt(raw[l],k)?;}
    snapshot.mixed[depth]=snapshot.kt[depth];
    for l in (0..depth).rev() {
        (snapshot.mixed[l],snapshot.masses[l])=mixture(weights[l],snapshot.kt[l],snapshot.mixed[l+1],k)?;
    }Ok(snapshot)
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



