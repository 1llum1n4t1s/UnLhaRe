//! 非公開研究sealed snapshot。旧RawSnapshot aliasとのRust source互換性はない。
//! KT64の数値bodyは凍結し、未改変tokenのobserve再predictだけを除く。
pub use crate::reference_cts::{Q,CLASSES,LEVELS,NODES,CAP,Result,Node,Kernel,vector,normalize,posterior_switch,path,update_kernel};
use crate::reference_cts::Snapshot as RawSnapshot;
#[derive(Clone,Debug,PartialEq,Eq)]
pub struct Snapshot {visible:RawSnapshot,certified:RawSnapshot}
impl Snapshot {
    // 成功したpredictだけが呼ぶ。certifiedを公開するAPIは設けない。
    fn seal(visible:RawSnapshot)->Self {Self{certified:visible.clone(),visible}}
}
impl std::ops::Deref for Snapshot {
    type Target=RawSnapshot;
    fn deref(&self)->&RawSnapshot {&self.visible}
}
impl std::ops::DerefMut for Snapshot {
    fn deref_mut(&mut self)->&mut RawSnapshot {&mut self.visible}
}
fn prefix(k:usize)->Result<()> {if (1..=4).contains(&k){Ok(())}else{Err("invalid prefix")}}
// CAPの全4raw和を先に維持する。合法mass*Q<2^55なのでchecked u64商/余りは旧u128とexact。
pub fn kt(raw:[u32;4],k:usize)->Result<[u64;4]> {
    prefix(k)?;
    let raw_total=raw.iter().try_fold(0u64,|n,&v|n.checked_add(u64::from(v)).ok_or("raw total overflow"))?;
    if raw_total>u64::from(CAP){return Err("raw observation cap");}
    let mut masses=[0u64;4];let mut total=0u64;
    for j in 0..k{
        masses[j]=u64::from(raw[j]).checked_mul(2).and_then(|n|n.checked_add(1)).ok_or("KT mass overflow")?;
        total=total.checked_add(masses[j]).ok_or("mass sum overflow")?;
    }
    if total==0{return Err("zero mass total");}
    let mut quotient=[0u64;4];let mut remainder=[0u64;4];let mut sum=0u64;
    for j in 0..k{
        let product=masses[j].checked_mul(Q).ok_or("mass scale overflow")?;
        quotient[j]=product/total;remainder[j]=product%total;
        sum=sum.checked_add(quotient[j]).ok_or("quotient sum overflow")?;
    }
    let left=Q.checked_sub(sum).ok_or("Hamilton quotient exceeds Q")? as usize;
    if left>=k{return Err("Hamilton remainder count");}
    let mut order=[0usize,1,2,3];order[..k].sort_unstable_by(|&a,&b|remainder[b].cmp(&remainder[a]).then(a.cmp(&b)));
    for &j in &order[..left]{quotient[j]=quotient[j].checked_add(1).ok_or("Hamilton increment overflow")?;}
    if quotient.iter().sum::<u64>()!=Q{return Err("Hamilton normalization");}
    vector(quotient,k)?;Ok(quotient)
}
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
// 範囲検査は重いモデル/BWT確保にも先行させる。
pub fn node_count(depth:usize)->Result<usize> {
    if depth>=LEVELS {return Err("unsupported CTS depth");}
    let mut total=0usize;let mut width=1usize;
    for level in 0..=depth {total=total.checked_add(width).ok_or("CTS allocation shape")?;
        if level<depth {width=width.checked_mul(4).ok_or("CTS allocation shape")?;}}
    CLASSES.checked_mul(total).ok_or("CTS allocation shape")?;Ok(total)
}
#[derive(Clone,Debug,PartialEq,Eq)]
pub struct Cts {nodes:Vec<Node>,history:[u16;CLASSES],observations:[u32;CLASSES],depth:usize,node_count:usize}
impl Cts {
    pub fn new(depth:usize)->Result<Self> {
        let node_count=node_count(depth)?;
        let length=CLASSES.checked_mul(node_count).ok_or("CTS allocation shape")?;
        let mut nodes=Vec::new();nodes.try_reserve_exact(length).map_err(|_|"CTS allocation failed")?;
        nodes.resize(length,Node{raw:[0;4],weight:Q/2});
        Ok(Self{nodes,history:[0;CLASSES],observations:[0;CLASSES],depth,node_count})
    }
    // observed childを受け取らず、class/prefixと過去stateだけから予測する。
    pub fn predict(&self,class:usize,k:usize)->Result<Snapshot> {
        prefix(k)?;if class>=CLASSES {return Err("invalid class");}
        if self.observations[class]>CAP {return Err("class observation cap");}
        let ids=path(self.history[class]);let mut raw=[[0;4];LEVELS];let mut weights=[0;LEVELS];
        for l in 0..=self.depth {
            let node=self.nodes.get(class*self.node_count+ids[l]).ok_or("prediction node index")?;
            raw[l]=node.raw;weights[l]=node.weight;
        }
        let kernel=predict_kernel(raw,weights,k,self.depth)?;
        Ok(Snapshot::seal(RawSnapshot{class,prefix:k,ids,history:self.history[class],observations:self.observations[class],raw,weights,kernel}))
    }
    // 数値bodyはpredictと完全一致。sample以外は時計を読まない。
    pub fn predict_profiled(&self,class:usize,k:usize,sampled:bool)->Result<(Snapshot,Option<[u64;3]>)> {
        let begin=sampled.then(std::time::Instant::now);
        prefix(k)?;if class>=CLASSES {return Err("invalid class");}
        if self.observations[class]>CAP {return Err("class observation cap");}
        let ids=path(self.history[class]);let mut raw=[[0;4];LEVELS];let mut weights=[0;LEVELS];
        for l in 0..=self.depth {
            let node=self.nodes.get(class*self.node_count+ids[l]).ok_or("prediction node index")?;
            raw[l]=node.raw;weights[l]=node.weight;
        }
        let gathered=sampled.then(std::time::Instant::now);
        let kernel=predict_kernel(raw,weights,k,self.depth)?;
        let computed=sampled.then(std::time::Instant::now);
        let snapshot=Snapshot::seal(RawSnapshot{class,prefix:k,ids,history:self.history[class],observations:self.observations[class],raw,weights,kernel});
        let sealed=sampled.then(std::time::Instant::now);
        let times=match (begin,gathered,computed,sealed) {
            (Some(a),Some(b),Some(c),Some(d))=>Some([
                u64::try_from(b.duration_since(a).as_nanos()).map_err(|_|"inner gather timer overflow")?,
                u64::try_from(c.duration_since(b).as_nanos()).map_err(|_|"inner kernel timer overflow")?,
                u64::try_from(d.duration_since(c).as_nanos()).map_err(|_|"inner seal timer overflow")?]),
            (None,None,None,None)=>None,
            _=>return Err("inner timer selection"),
        };
        Ok((snapshot,times))
    }
    pub fn observe(&mut self,s:&Snapshot,child:usize)->Result<()> {
        prefix(s.prefix)?;if s.class>=CLASSES || child>=s.prefix {return Err("invalid observation");}
        if s.observations>=CAP || self.observations[s.class]>=CAP {return Err("class update cap");}
        // 旧predictと同じcurrent guard順を保つ。token不一致は全guardの後。
        if self.observations[s.class]>CAP {return Err("class observation cap");}
        let ids=path(self.history[s.class]);let mut raw=[[0;4];LEVELS];let mut weights=[0;LEVELS];
        for l in 0..=self.depth {
            let node=self.nodes.get(s.class*self.node_count+ids[l]).ok_or("prediction node index")?;
            raw[l]=node.raw;weights[l]=node.weight;
        }
        if weights[self.depth]!=Q/2 {return Err("invalid kernel depth/leaf");}
        for l in 0..=self.depth {
            if weights[l]>Q {return Err("kernel weight");}
            let total=raw[l].iter().try_fold(0u64,|n,&v|n.checked_add(u64::from(v)).ok_or("raw total overflow"))?;
            if total>u64::from(CAP) {return Err("raw observation cap");}
        }
        // class/prefixは既に範囲検査済みで、gatherはvisible.classの現在state。
        if s.kernel.depth!=self.depth || s.ids!=ids || s.history!=self.history[s.class] || s.observations!=self.observations[s.class]
            || s.raw!=raw || s.weights!=weights {return Err("stale or modified snapshot");}
        // 改変後でも旧predictとexact一致すれば受理する既存の契約を維持する。
        // 通常の未改変tokenはsealの完全比較だけでderivedの再計算を避ける。
        if s.visible!=s.certified && s.visible!=self.predict(s.class,s.prefix)?.visible {
            return Err("stale or modified snapshot");
        }
        let after=s.observations.checked_add(1).ok_or("observation overflow")?;
        let next=update_kernel(&s.kernel,s.weights,s.prefix,child,after)?;
        let mut prepared=[Node{raw:[0;4],weight:Q/2};LEVELS];
        for l in 0..=self.depth {
            let total=s.raw[l].iter().try_fold(0u64,|n,&v|n.checked_add(u64::from(v)).ok_or("node total overflow"))?;
            if total>=u64::from(CAP) {return Err("node update cap");}
            prepared[l]=Node{raw:s.raw[l],weight:next[l]};
            prepared[l].raw[child]=prepared[l].raw[child].checked_add(1).ok_or("node count overflow")?;
        }
        let history=((s.history<<2)|child as u16)&0xffff;
        // allocationなし。全検査と全prepared nodeの完成後にだけcommitする。
        for l in 0..=self.depth {self.nodes[s.class*self.node_count+s.ids[l]]=prepared[l];}
        self.observations[s.class]=after;self.history[s.class]=history;Ok(())
    }
    pub fn depth(&self)->usize {self.depth}
    pub fn node_count(&self)->usize {self.node_count}
    pub fn nodes(&self)->&[Node] {&self.nodes}
    pub fn histories(&self)->[u16;CLASSES] {self.history}
    pub fn observations(&self)->[u32;CLASSES] {self.observations}
    #[cfg(primitive_audit)]
    pub fn audit_seed_class(&mut self,class:usize,history:u16,observations:u32) {self.history[class]=history;self.observations[class]=observations;}
    #[cfg(primitive_audit)]
    pub fn audit_seed_node(&mut self,class:usize,id:usize,raw:[u32;4],weight:u64) {self.nodes[class*self.node_count+id]=Node{raw,weight};}
}

