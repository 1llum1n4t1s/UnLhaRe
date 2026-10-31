//! frozen kernelを結ぶprivate causalモデル。外部APIではない。
use super::{fixed_math::{Math},integer_pool,integer_cts::{Cts,Snapshot,CAP},Result};
pub(crate) fn digest(h:&mut u64,v:usize){*h=(*h^v as u64).wrapping_mul(0x100000001b3);}
pub(crate) fn exponent(v:usize)->usize {if v==0 {0}else {(usize::BITS-1-v.leading_zeros()) as usize}}
fn hash(mut x:u32)->usize {x^=x>>16;x=x.wrapping_mul(0x7feb352d);x^=x>>15;x=x.wrapping_mul(0x846ca68b);(x^(x>>16)) as usize}
fn row_ids(component:usize,context:usize,node:usize,symbol:usize,recent:u32,prev:(usize,usize)) -> Result<[usize;4]> {
    if component>1 || context>8 || (component==0 && context!=0) || node>=256 || symbol>=257 || recent>65535 || prev.0>8 || prev.1>31 {return Err("context".into());}
    let key=((component as u32)<<31)|((context as u32)<<20)|node as u32;
    let mask=(1<<18)-1;
    Ok([(component*9+context)*256+node,
        hash(key^(symbol as u32).wrapping_mul(0x9e3779b9))&mask,
        hash(key^recent.rotate_left(11))&mask,
        hash(key^(symbol as u32).wrapping_mul(0x85ebca6b)^((prev.0 as u32)<<24)^((prev.1 as u32)<<16))&mask])
}

#[derive(Clone,Debug,PartialEq,Eq)]
pub(crate) struct Edge {pub lo:usize,pub hi:usize,pub node:Option<usize>}
#[derive(Clone)]
struct Node {edges:Vec<Edge>,class:usize}
pub(crate) struct Tree {alphabet:usize,nodes:Vec<Node>}
impl Tree {
    fn new(alphabet:usize)->Self {let mut t=Self{alphabet,nodes:Vec::new()};t.build(0,alphabet);t}
    fn build(&mut self,lo:usize,hi:usize)->usize {
        let id=self.nodes.len();let class=if lo==0 {0}else if (lo==4||lo==32)&&hi==self.alphabet {1}else {2};
        self.nodes.push(Node{edges:Vec::new(),class});
        let cuts=if lo==0 {vec![0,1,2,4,hi]}else if lo==4&&hi==self.alphabet {vec![4,8,16,32,hi]}else if lo==32&&hi==self.alphabet {vec![32,64,128,256,hi]}else {let n=(hi-lo).min(4);(0..=n).map(|i|lo+(hi-lo)*i/n).collect()};
        let mut edges=Vec::new();for p in cuts.windows(2){if p[0]<p[1]{let node=if p[1]-p[0]>1{Some(self.build(p[0],p[1]))}else{None};edges.push(Edge{lo:p[0],hi:p[1],node});}}
        self.nodes[id].edges=edges;id
    }
    pub fn prefix(&self,node:usize,limit:usize)->Result<usize> {
        if limit==0||limit>self.alphabet{return Err("token/limit".into());}
        let n=self.nodes.get(node).ok_or("tree node")?;let k=n.edges.iter().take_while(|e|e.lo<limit).count();if k==0{return Err("tree empty prefix".into());}Ok(k)
    }
    pub fn edge(&self,node:usize,child:usize,prefix:usize)->Result<Edge> {
        if child>=prefix{return Err("tree child".into());}self.nodes.get(node).and_then(|n|n.edges.get(child)).cloned().ok_or("tree edge".into())
    }
    pub fn known_child(&self,node:usize,token:usize,limit:usize)->Result<usize> {
        let k=self.prefix(node,limit)?;if token>=limit{return Err("token/limit".into());}
        self.nodes[node].edges[..k].iter().position(|e|e.lo<=token&&token<e.hi).ok_or("tree token".into())
    }
}
#[derive(Clone,Copy,Debug,PartialEq,Eq)]
struct Counts {values:[u16;4],total:u32}
impl Counts {
    // checked split専用。通常transactionは予測済みCountsだけをprepareする。
    #[cfg(frame_audit)]
    fn prepare(self,child:usize)->Result<(Self,bool)> {
        if child>=4||self.values.contains(&0)||self.total!=self.values.iter().map(|&v|u32::from(v)).sum::<u32>()||self.total>32768{return Err("count state".into());}
        self.prepare_fresh(child)
    }
    fn prepare_fresh(self,child:usize)->Result<(Self,bool)> {
        let mut n=self;n.values[child]=n.values[child].checked_add(2).ok_or("count overflow")?;n.total=n.total.checked_add(2).ok_or("count total overflow")?;
        let rescale=n.total>=32768;if rescale {n.total=0;for v in &mut n.values{*v=v.div_ceil(2);n.total+=u32::from(*v);}}Ok((n,rescale))
    }
}
#[derive(Clone,Copy,Default)]
struct Sum {value:f64,correction:f64}
impl Sum {fn add(&mut self,x:f64){let y=x-self.correction;let t=self.value+y;self.correction=(t-self.value)-y;self.value=t;}}
#[derive(Clone,Default)]
pub(crate) struct Audit {pub branches:[u64;2],pub prefixes:[[u64;4];2],pub rescales:[u64;4],pub cold:[u64;4],entropy:Sum}
impl Audit {pub fn entropy(&self)->f64{self.entropy.value}}
pub(crate) struct BranchPrediction {serial:u64,component:usize,ids:[usize;4],counts:[Counts;4],cts:Snapshot,pool:integer_pool::Prediction}
impl BranchPrediction {
    pub fn interval(&self,child:usize)->Result<(u32,u32,u32)>{if child>=self.pool.prefix{return Err("branch child".into());}Ok((self.pool.cumulative[child],self.pool.frequencies[child],32768))}
    pub fn select(&self,slot:u32)->Result<usize>{if slot>=32768{return Err("branch slot".into());}(0..self.pool.prefix).find(|&j|slot>=self.pool.cumulative[j]&&slot<self.pool.cumulative[j+1]).ok_or("branch slot".into())}
}
pub(crate) struct Model {tables:[Vec<Counts>;4],weights:Vec<[f64;5]>,math:Math,cts:Cts,serial:u64,pub trees:[Tree;2],pub audit:Audit}
impl Model {
    pub fn new(depth:usize)->Result<Self>{
        super::integer_cts::node_count(depth)?;
        let mut tables:[Vec<Counts>;4]=std::array::from_fn(|_|Vec::new());for(i,t)in tables.iter_mut().enumerate(){let n=if i==0{4608}else{1<<18};t.try_reserve_exact(n).map_err(|_|"count allocation")?;t.resize(n,Counts{values:[1;4],total:4});}
        let mut weights=Vec::new();weights.try_reserve_exact(4608).map_err(|_|"weight allocation")?;weights.resize(4608,[0.25,0.25,0.25,0.25,0.0]);
        Ok(Self{tables,weights,math:Math::new()?,cts:Cts::new(depth)?,serial:0,trees:[Tree::new(257),Tree::new(256)],audit:Audit::default()})
    }
    // observed childは引数に存在しない。prefixは現在node/limitで別に決まる。
    fn predict_branch(&self,component:usize,context:usize,node:usize,symbol:usize,recent:u32,previous:(usize,usize),prefix:usize)->Result<BranchPrediction>{
        if component>1||!(1..=4).contains(&prefix){return Err("branch component/prefix".into());}
        let n=self.trees[component].nodes.get(node).ok_or("tree node")?;if prefix>n.edges.len(){return Err("branch prefix".into());}
        let ids=row_ids(component,context,node,symbol,recent,previous)?;let mut counts=[Counts{values:[1;4],total:4};4];
        for i in 0..4{counts[i]=*self.tables[i].get(ids[i]).ok_or("branch row")?;if counts[i].total!=counts[i].values.iter().map(|&v|u32::from(v)).sum::<u32>(){return Err("count state".into());}}
        let cts=self.cts.predict(component*3+n.class,prefix)?;
        let pool=integer_pool::predict(&self.math,counts.map(|c|c.values),self.weights[ids[0]],cts.mixed(),prefix)?;
        Ok(BranchPrediction{serial:self.serial,component,ids,counts,cts,pool})
    }

    // split snapshotの再利用はstandalone拒否試験専用。通常codecはtransaction一本。
    #[cfg(frame_audit)]
    pub fn predict(&self,component:usize,context:usize,node:usize,symbol:usize,recent:u32,previous:(usize,usize),prefix:usize)->Result<BranchPrediction>{
        self.predict_branch(component,context,node,symbol,recent,previous,prefix)
    }
    // callbackにはreadonly予測/treeだけ。selfの排他的borrowはcommitまで継続する。
    pub fn transaction<F>(&mut self,component:usize,context:usize,node:usize,symbol:usize,recent:u32,previous:(usize,usize),limit:usize,choose:F)->Result<Edge>
    where F:FnOnce(&BranchPrediction,&Tree)->Result<usize> {
        let tree=self.trees.get(component).ok_or("branch component/prefix")?;
        let prefix=tree.prefix(node,limit)?;
        let s=self.predict_branch(component,context,node,symbol,recent,previous,prefix)?;
        let child=choose(&s,&self.trees[component])?;
        if child>=s.pool.prefix{return Err("branch child".into());}
        let edge=self.trees[component].edge(node,child,prefix)?;
        let update=integer_pool::observe_fresh(&s.pool,child)?;
        let mut next=s.counts;let mut rescaled=[false;4];
        for i in 0..4{(next[i],rescaled[i])=s.counts[i].prepare_fresh(child)?;}
        let serial=self.serial.checked_add(1).ok_or("serial overflow")?;
        let mut audit=self.audit.clone();
        audit.branches[s.component]=audit.branches[s.component].checked_add(1).ok_or("branch count overflow")?;
        audit.prefixes[s.component][s.pool.prefix-1]=audit.prefixes[s.component][s.pool.prefix-1].checked_add(1).ok_or("prefix count overflow")?;
        for i in 0..4{
            audit.rescales[i]=audit.rescales[i].checked_add(u64::from(rescaled[i])).ok_or("rescale count overflow")?;
            audit.cold[i]=audit.cold[i].checked_add(u64::from(s.counts[i].total==4)).ok_or("cold count overflow")?;
        }
        audit.entropy.add(-(f64::from(s.pool.frequencies[child])/32768.0).log2());
        // pool/count/serial/auditは全prepare済み。CTSも全node prepare後に末尾commit。
        self.cts.observe_fresh(&s.cts,child)?;
        self.weights[s.ids[0]]=update.next;
        for i in 0..4{self.tables[i][s.ids[i]]=next[i];}
        self.serial=serial;self.audit=audit;Ok(edge)
    }
    // stale再照合付きsplit経路はstandalone拒否試験専用。
    #[cfg(frame_audit)]
    pub fn observe(&mut self,s:&BranchPrediction,child:usize)->Result<()>{
        if s.serial!=self.serial||s.component>1||child>=s.pool.prefix||s.pool.prefix!=s.cts.prefix(){return Err("stale branch/child".into());}
        for i in 0..4{if self.tables[i].get(s.ids[i])!=Some(&s.counts[i]){return Err("stale branch row".into());}}
        if self.weights.get(s.ids[0]).map(|w|w.map(f64::to_bits))!=Some(s.pool.weights.map(f64::to_bits)){return Err("stale branch weights".into());}
        let update=integer_pool::observe(&s.pool,child)?;
        let mut next=s.counts;let mut rescaled=[false;4];for i in 0..4{(next[i],rescaled[i])=s.counts[i].prepare(child)?;}
        let serial=self.serial.checked_add(1).ok_or("serial overflow")?;
        let mut audit=self.audit.clone();audit.branches[s.component]=audit.branches[s.component].checked_add(1).ok_or("branch count overflow")?;
        audit.prefixes[s.component][s.pool.prefix-1]+=1;for i in 0..4{audit.rescales[i]+=u64::from(rescaled[i]);audit.cold[i]+=u64::from(s.counts[i].total==4);}
        audit.entropy.add(-(f64::from(s.pool.frequencies[child])/32768.0).log2());
        // CTS拒否より前にbase/pool/statsを変更しない。以後は非fallible assignmentだけ。
        self.cts.observe(&s.cts,child)?;
        self.weights[s.ids[0]]=update.next;for i in 0..4{self.tables[i][s.ids[i]]=next[i];}self.serial=serial;self.audit=audit;Ok(())
    }
    pub fn class_observations(&self)->[u32;6]{self.cts.observations()}
    pub fn state_digest(&self)->u64{let mut h=0xcbf29ce484222325;for t in &self.tables{for c in t{for &v in &c.values{digest(&mut h,v as usize);}}}for w in &self.weights{for &v in w{digest(&mut h,v.to_bits() as usize);}}h}
    #[cfg(frame_audit)]
    fn state(&self)->State{State{tables:self.tables.clone(),weights:self.weights.clone(),cts:self.cts.clone(),serial:self.serial,audit:self.audit.clone()}}
}
#[cfg(frame_audit)]
struct State {tables:[Vec<Counts>;4],weights:Vec<[f64;5]>,cts:Cts,serial:u64,audit:Audit}
#[cfg(frame_audit)]
impl State {
    fn compare(&self,m:&Model)->Result<()>{
        if self.tables!=m.tables||!self.weights.iter().zip(&m.weights).all(|(a,b)|a.map(f64::to_bits)==b.map(f64::to_bits))||!self.cts.same(&m.cts)||self.serial!=m.serial||self.audit.branches!=m.audit.branches||self.audit.prefixes!=m.audit.prefixes||self.audit.rescales!=m.audit.rescales||self.audit.cold!=m.audit.cold||self.audit.entropy.value.to_bits()!=m.audit.entropy.value.to_bits()||self.audit.entropy.correction.to_bits()!=m.audit.entropy.correction.to_bits(){return Err("model rejection mutated state".into());}Ok(())
    }
}
#[cfg(frame_audit)]
pub(crate) fn rejection_checks(depth:usize)->Result<(usize,usize,usize)>{
    let mut m=Model::new(depth)?;let mut assertions=0;
    for case in 0..6{
        let before=m.state();let args=match case{0=>(0,0,0,0,0),1=>(0,0,0,0,5),2=>(2,0,0,0,4),3=>(1,9,0,0,4),4=>(0,0,256,0,4),_=>(0,0,0,257,4)};
        if m.predict(args.0,args.1,args.2,args.3,0,(0,0),args.4).is_ok(){return Err("invalid branch accepted".into());}before.compare(&m)?;assertions+=1;
    }
    let s=m.predict(0,0,0,0,0,(0,0),4)?;let before=m.state();if m.observe(&s,4).is_ok(){return Err("invalid child accepted".into());}before.compare(&m)?;assertions+=1;
    m.observe(&s,0)?;let before=m.state();if m.observe(&s,0).is_ok(){return Err("stale branch accepted".into());}before.compare(&m)?;assertions+=1;
    let mut s=m.predict(0,0,0,0,0,(0,0),4)?;s.ids[0]=usize::MAX;let before=m.state();if m.observe(&s,0).is_ok(){return Err("modified row accepted".into());}before.compare(&m)?;assertions+=1;
    for w in [-1.0,2.1,f64::NAN,f64::INFINITY]{
        m.weights[0][0]=w;let before=m.state();if m.predict(0,0,0,0,0,(0,0),4).is_ok(){return Err("invalid weight accepted".into());}before.compare(&m)?;assertions+=1;
    }m.weights[0][0]=0.25;
    for c in [Counts{values:[0,1,1,1],total:3},Counts{values:[32768,1,1,1],total:32771},Counts{values:[1;4],total:5}]{
        m.tables[0][0]=c;let before=m.state();if m.predict(0,0,0,0,0,(0,0),4).is_ok(){return Err("invalid count accepted".into());}before.compare(&m)?;assertions+=1;
    }m.tables[0][0]=Counts{values:[1;4],total:4};
    m.serial=u64::MAX;let s=m.predict(0,0,0,0,0,(0,0),4)?;let before=m.state();if m.observe(&s,0).is_ok(){return Err("serial overflow accepted".into());}before.compare(&m)?;assertions+=1;m.serial=0;
    let ids=super::integer_cts::path(0);
    m.cts.audit_seed_class(0,0,CAP-1);for &id in &ids{m.cts.audit_seed_node(0,id,[CAP-1,0,0,0],0.5);}
    let s=m.predict(0,0,0,0,0,(0,0),4)?;m.observe(&s,0)?;if m.class_observations()[0]!=CAP{return Err("CAP exact update".into());}
    let s=m.predict(0,0,0,0,0,(0,0),4)?;let before=m.state();if m.observe(&s,0).is_ok(){return Err("CAP update accepted".into());}before.compare(&m)?;assertions+=1;
    m.cts.audit_seed_class(0,0,CAP+1);let before=m.state();if m.predict(0,0,0,0,0,(0,0),4).is_ok(){return Err("class CAP over accepted".into());}before.compare(&m)?;assertions+=1;
    m.cts.audit_seed_class(0,0,0);
    for raw in [[CAP+1,0,0,0],[CAP,0,0,0]]{
        for &id in &ids{m.cts.audit_seed_node(0,id,raw,0.5);}
        let before=m.state();let result=m.predict(0,0,0,0,0,(0,0),4);
        if raw[0]>CAP{if result.is_ok(){return Err("raw cap accepted".into());}}else if m.observe(&result?,0).is_ok(){return Err("raw update cap accepted".into());}
        before.compare(&m)?;assertions+=1;
    }
    for &id in &ids{m.cts.audit_seed_node(0,id,[0;4],0.5);}
    for w in [-0.1,1.1,f64::NAN,f64::INFINITY]{
        m.cts.audit_seed_node(0,0,[0;4],w);let before=m.state();if m.predict(0,0,0,0,0,(0,0),4).is_ok(){return Err("CTS weight accepted".into());}before.compare(&m)?;assertions+=1;
    }m.cts.audit_seed_node(0,0,[0;4],0.5);
    m.cts.audit_seed_node(0,ids[5],[0;4],0.4);let before=m.state();if m.predict(0,0,0,0,0,(0,0),4).is_ok(){return Err("leaf weight accepted".into());}before.compare(&m)?;assertions+=1;
    if assertions!=26{return Err(format!("model rejection count {assertions}"));}Ok((assertions,assertions,1))
}

// 新freshの拒否を全table/weight/CTS/history/serial/auditのfloat bitsまで直接照合する。
#[cfg(frame_audit)]
pub(crate) fn fresh_rejection_checks()->Result<String>{
    let cases=[
        ("callback-error","fresh callback error",1),
        ("invalid-child","branch child",1),
        ("callback-readonly-tree-edge-error","tree child",1),
        ("callback-invalid-slot","branch slot",1),
        ("callback-invalid-interval-child","branch child",1),
        ("pre-callback-tree-node-error","tree node",0),
        ("serial-overflow","serial overflow",1),
        ("audit-branch-overflow","branch count overflow",1),
        ("audit-prefix-overflow","prefix count overflow",1),
        ("audit-rescale-overflow","rescale count overflow",1),
        ("audit-cold-overflow","cold count overflow",1),
        ("class-cap-exact-update","class update cap",1),
        ("class-cap-over-predict","class observation cap",0),
        ("raw-root-cap-exact-update","raw update cap",1),
        ("raw-leaf-cap-exact-update","raw update cap",1),
        ("raw-cap-over-predict","raw observation cap",0),
        ("pool-NaN-weight-predict","pool prefix/weight",0),
        ("CTS-NaN-weight-predict","kernel weight",0),
        ("CTS-leaf-weight-predict","invalid kernel leaf",0),
    ];
    let mut records=Vec::new();let mut callback_total=0;
    let ids=super::integer_cts::path(0);
    for (name,expected,expected_calls) in cases{
        let mut m=Model::new(5)?;
        match name{
            "serial-overflow"=>m.serial=u64::MAX,
            "audit-branch-overflow"=>m.audit.branches[0]=u64::MAX,
            "audit-prefix-overflow"=>m.audit.prefixes[0][3]=u64::MAX,
            "audit-rescale-overflow"=>{m.audit.rescales[0]=u64::MAX;m.tables[0][0]=Counts{values:[8192;4],total:32768};},
            "audit-cold-overflow"=>m.audit.cold[0]=u64::MAX,
            "class-cap-exact-update"=>m.cts.audit_seed_class(0,0,CAP),
            "class-cap-over-predict"=>m.cts.audit_seed_class(0,0,CAP+1),
            "raw-root-cap-exact-update"=>m.cts.audit_seed_node(0,ids[0],[CAP,0,0,0],0.5),
            "raw-leaf-cap-exact-update"=>m.cts.audit_seed_node(0,ids[5],[CAP,0,0,0],0.5),
            "raw-cap-over-predict"=>m.cts.audit_seed_node(0,ids[0],[CAP+1,0,0,0],0.5),
            "pool-NaN-weight-predict"=>m.weights[0][0]=f64::NAN,
            "CTS-NaN-weight-predict"=>m.cts.audit_seed_node(0,ids[0],[0;4],f64::NAN),
            "CTS-leaf-weight-predict"=>m.cts.audit_seed_node(0,ids[5],[0;4],0.4),
            _=>{},
        }
        let node=if name=="pre-callback-tree-node-error"{256}else{0};
        let before=m.state();let mut callback_calls=0;
        let result=m.transaction(0,0,node,0,0,(0,0),257,|prediction,tree|{
            callback_calls+=1;
            match name{
                "callback-error"=>Err("fresh callback error".into()),
                "invalid-child"=>Ok(4),
                "callback-readonly-tree-edge-error"=>{tree.edge(0,4,4)?;Ok(0)},
                "callback-invalid-slot"=>prediction.select(32768),
                "callback-invalid-interval-child"=>{prediction.interval(4)?;Ok(0)},
                _=>Ok(0),
            }
        });
        let actual=match result{Err(error)=>error,Ok(_)=>return Err(format!("fresh {name} accepted"))};
        if actual!=expected||callback_calls!=expected_calls{return Err(format!("fresh {name}: expected {expected}/{expected_calls}, actual {actual}/{callback_calls}"));}
        before.compare(&m)?;callback_total+=callback_calls;
        records.push(format!("{{\"case\":\"{name}\",\"expected_reason\":\"{expected}\",\"actual_reason\":\"{actual}\",\"callback_calls\":{callback_calls},\"all_state_direct_bits_compared\":true}}"));
    }
    // CAP-1から一回だけ成功しCAPちょうどのpredict後にupdateを拒否する。
    let mut m=Model::new(5)?;m.cts.audit_seed_class(0,0,CAP-1);
    for &id in &ids{m.cts.audit_seed_node(0,id,[CAP-1,0,0,0],0.5);}
    m.transaction(0,0,0,0,0,(0,0),257,|_,_|Ok(0))?;
    if m.class_observations()[0]!=CAP||m.serial!=1||m.audit.branches!=[1,0]||ids.iter().any(|&id|m.cts.audit_node(0,id).raw!=[CAP,0,0,0]){return Err("fresh CAP exact success".into());}
    let before=m.state();let mut cap_callback=0;
    let result=m.transaction(0,0,0,0,0,(0,0),257,|_,_|{cap_callback+=1;Ok(0)});
    if result.err().as_deref()!=Some("class update cap")||cap_callback!=1{return Err("fresh post-CAP rejection".into());}
    before.compare(&m)?;callback_total+=cap_callback;
    records.push("{\"case\":\"CAP-minus1-success-then-cap-update-rejected\",\"actual_reason\":\"class update cap\",\"callback_calls\":1,\"all_state_direct_bits_compared\":true}".into());
    Ok(format!("{{\"status\":\"passed\",\"operation\":\"fresh-rejections\",\"fresh_named_rejections\":20,\"all_state_comparisons\":20,\"CAP_exact_successes\":1,\"rejected_callback_calls\":{callback_total},\"checked_split_is_auxiliary_only\":true,\"edge_error_location\":\"callback readonly Tree::edge; internal edge failure after immutable validated tree and valid child is unreachable\",\"audit_MAX_change\":\"artificial prefix/rescale/cold overflow now Err instead of old checked-overflow panic\",\"records\":[{}]}}",records.join(",")))
}


