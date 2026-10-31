//! 固定契約の診断f64 CTS。binary Q32 wire互換を主張しない。
pub const CLASSES: usize = 6;
pub const LEVELS: usize = 9;
pub const NODES: usize = 87381;
pub const CAP: u32 = 3825340;
const TOL: f64 = 2e-10;
fn checked_unit(x:f64)->Result<f64,&'static str> {
    if !x.is_finite() || x < -TOL || x > 1.0+TOL {Err("CTS weight range")} else {Ok(x.clamp(0.0,1.0))}
}
fn close(a:f64,b:f64) {assert!(a.is_finite() && b.is_finite() && (a-b).abs()<=TOL*(1.0+a.abs()+b.abs()),"CTS mismatch {a} {b}");}
fn vector(v:&[f64;4],k:usize) {
    assert!(v[..k].iter().all(|&p|p.is_finite() && p>0.0));
    close(v[..k].iter().sum(),1.0);
    assert!(v[k..].iter().all(|&p|p==0.0));
}
// 本体と小depth診断が同じsnapshot混合・更新kernelを通る。
fn mix_levels(kt:&[[f64;4];LEVELS],weights:&[f64;LEVELS],prefix:usize,depth:usize)->[[f64;4];LEVELS] {
    assert!(depth<LEVELS && (1..=4).contains(&prefix));
    let mut mixed=[[0.0;4];LEVELS];mixed[depth]=kt[depth];vector(&mixed[depth],prefix);
    for l in (0..depth).rev() {
        for j in 0..prefix {mixed[l][j]=weights[l]*kt[l][j]+(1.0-weights[l])*mixed[l+1][j];}
        vector(&mixed[l],prefix);
    }
    mixed
}
fn posterior_weight(weight:f64,kt:f64,mixed:f64,after:u32)->Result<f64,&'static str> {
    if !kt.is_finite() || !mixed.is_finite() || kt<=0.0 || mixed<=0.0 || after==0 || after>CAP {return Err("CTS probability/after");}
    checked_unit(weight)?;
    let posterior=checked_unit(weight*kt/mixed)?;
    let alpha=1.0/f64::from(after+1);let retained=1.0-2.0*alpha;
    checked_unit(alpha+retained*posterior)
}
fn path(history:u16)->[usize;LEVELS] {
    let mut ids=[0;LEVELS];
    for l in 1..LEVELS {ids[l]=4*ids[l-1]+1+usize::from((history>>(2*(l-1)))&3);}
    ids
}
fn reference_path(history:u64)->[usize;LEVELS] {
    let mut result=[0;LEVELS];let mut remaining=history;let mut current=0;
    for item in result.iter_mut().skip(1) {current=current*4+remaining%4+1;*item=current as usize;remaining/=4;}
    result
}
#[derive(Clone,Copy)]
struct Node {raw:[u32;4],weight:f64}
#[derive(Clone)]
pub struct Cts {nodes:Vec<Node>,history:[u16;CLASSES],observations:[u32;CLASSES]}
#[derive(Clone)]
pub struct Snapshot {
    pub class:usize,pub prefix:usize,pub ids:[usize;LEVELS],
    history:u16,observations:u32,raw:[[u32;4];LEVELS],weights:[f64;LEVELS],
    pub kt:[[f64;4];LEVELS],pub mixed:[[f64;4];LEVELS],
}
impl Cts {
    pub fn new()->Self {Self{nodes:vec![Node{raw:[0;4],weight:0.5};CLASSES*NODES],history:[0;CLASSES],observations:[0;CLASSES]}}
    // 観測childは予測APIに渡さない。
    pub fn predict(&self,class:usize,prefix:usize)->Result<Snapshot,&'static str> {
        if class>=CLASSES || !(1..=4).contains(&prefix) {return Err("CTS class/prefix");}
        let ids=path(self.history[class]);let mut raw=[[0;4];LEVELS];let mut weights=[0.0;LEVELS];let mut kt=[[0.0;4];LEVELS];
        for l in 0..LEVELS {
            let node=self.nodes[class*NODES+ids[l]];raw[l]=node.raw;weights[l]=node.weight;
            checked_unit(node.weight)?;
            if node.raw.iter().map(|&v|u64::from(v)).sum::<u64>()>u64::from(CAP) {return Err("CTS raw cap");}
            let total=node.raw[..prefix].iter().map(|&v|f64::from(v)).sum::<f64>()+0.5*prefix as f64;
            for j in 0..prefix {kt[l][j]=(f64::from(node.raw[j])+0.5)/total;}
            vector(&kt[l],prefix);
        }
        if weights[8]!=0.5 {return Err("CTS leaf weight");}
        let mixed=mix_levels(&kt,&weights,prefix,8);
        Ok(Snapshot{class,prefix,ids,history:self.history[class],observations:self.observations[class],raw,weights,kt,mixed})
    }
    pub fn observe(&mut self,s:&Snapshot,child:usize)->Result<(),&'static str> {
        if s.class>=CLASSES || !(1..=4).contains(&s.prefix) || child>=s.prefix {return Err("CTS observed child");}
        if s.observations>=CAP || s.history!=self.history[s.class] || s.observations!=self.observations[s.class] || s.ids!=path(self.history[s.class]) {return Err("CTS cap/stale snapshot");}
        let after=s.observations+1;
        let mut next=[0.5;LEVELS];
        for l in 0..LEVELS {
            let node=self.nodes[s.class*NODES+s.ids[l]];
            if node.raw!=s.raw[l] || node.weight.to_bits()!=s.weights[l].to_bits() || node.raw.iter().map(|&v|u64::from(v)).sum::<u64>()>=u64::from(CAP) {return Err("CTS stale/count cap");}
            if l<8 {
                next[l]=posterior_weight(s.weights[l],s.kt[l][child],s.mixed[l][child],after)?;
            }
        }
        // 全拒否条件と全次weightを検査した後だけcommitする。
        for l in 0..LEVELS {let node=&mut self.nodes[s.class*NODES+s.ids[l]];node.raw[child]+=1;node.weight=next[l];}
        self.observations[s.class]=after;self.history[s.class]=((s.history<<2)|child as u16)&0xffff;Ok(())
    }
}
struct Oracle {
    halves:Vec<[u64;4]>,mass_weights:Vec<f64>,histories:[u64;CLASSES],seen:[u64;CLASSES],
}
pub struct OracleSnapshot {
    class:usize,prefix:usize,ids:[usize;LEVELS],history:u64,seen:u64,
    halves:[[u64;4];LEVELS],weights:[f64;LEVELS],kt:[[f64;4];LEVELS],mixed:[[f64;4];LEVELS],
}
impl Oracle {
    fn new()->Self {Self{halves:vec![[1;4];CLASSES*NODES],mass_weights:vec![0.5;CLASSES*NODES],histories:[0;CLASSES],seen:[0;CLASSES]}}
    fn predict(&self,class:usize,prefix:usize)->OracleSnapshot {
        assert!(class<6 && (1..=4).contains(&prefix));
        let ids=reference_path(self.histories[class]);let mut halves=[[0;4];LEVELS];let mut weights=[0.0;LEVELS];let mut kt=[[0.0;4];LEVELS];
        for l in 0..LEVELS {
            halves[l]=self.halves[class*NODES+ids[l]];weights[l]=self.mass_weights[class*NODES+ids[l]];
            let total=halves[l][..prefix].iter().sum::<u64>();
            for j in 0..prefix {kt[l][j]=halves[l][j] as f64/total as f64;}
        }
        let mut mixed=[[0.0;4];LEVELS];mixed[8]=kt[8];
        for l in (0..8).rev() {for j in 0..prefix {let own=kt[l][j]*weights[l];let child=mixed[l+1][j]*(1.0-weights[l]);mixed[l][j]=own+child;}}
        OracleSnapshot{class,prefix,ids,history:self.histories[class],seen:self.seen[class],halves,weights,kt,mixed}
    }
    fn observe(&mut self,s:&OracleSnapshot,child:usize) {
        assert!(child<s.prefix && s.seen<u64::from(CAP));
        assert_eq!(self.seen[s.class],s.seen);assert_eq!(self.histories[s.class],s.history);
        let denominator=(s.seen+2) as f64;let mut next=[0.5;LEVELS];
        for l in 0..8 {
            let own_mass=s.weights[l]*s.kt[l][child];let child_mass=(1.0-s.weights[l])*s.mixed[l+1][child];
            let posterior=checked_unit(own_mass/(own_mass+child_mass)).unwrap();
            next[l]=checked_unit(((denominator-1.0)*posterior+(1.0-posterior))/denominator).unwrap();
        }
        for l in 0..LEVELS {
            let id=s.class*NODES+s.ids[l];assert_eq!(self.halves[id],s.halves[l]);close(self.mass_weights[id],s.weights[l]);
            self.halves[id][child]+=2;self.mass_weights[id]=next[l];
        }
        self.seen[s.class]+=1;self.histories[s.class]=(s.history*4+child as u64)%65536;
    }
}
pub struct Query {pub primary:Snapshot,reference:OracleSnapshot}
pub struct Audit {
    main:Cts,oracle:Oracle,
    pub checked:u64,pub queries:[[u64;LEVELS];CLASSES],pub cold:[[u64;LEVELS];CLASSES],
    pub class_loss:[f64;CLASSES],correction:[f64;CLASSES],
    pub max_kt:f64,pub max_mixed:f64,pub max_weight:f64,
}
impl Audit {
    pub fn new()->Self {Self{main:Cts::new(),oracle:Oracle::new(),checked:0,queries:[[0;LEVELS];CLASSES],cold:[[0;LEVELS];CLASSES],class_loss:[0.0;CLASSES],correction:[0.0;CLASSES],max_kt:0.0,max_mixed:0.0,max_weight:0.0}}
    pub fn predict(&mut self,class:usize,prefix:usize)->Query {
        assert!(class<CLASSES && (1..=4).contains(&prefix));
        assert!(self.main.observations[class]<CAP);
        let primary=self.main.predict(class,prefix).unwrap();let reference=self.oracle.predict(class,prefix);
        assert_eq!(primary.ids,reference.ids);assert_eq!(u64::from(primary.history),reference.history);assert_eq!(u64::from(primary.observations),reference.seen);
        for l in 0..LEVELS {
            self.queries[class][l]+=1;self.cold[class][l]+=u64::from(primary.raw[l].iter().all(|&n|n==0));
            for j in 0..4 {
                assert_eq!(u64::from(primary.raw[l][j])*2+1,reference.halves[l][j]);
                close(primary.kt[l][j],reference.kt[l][j]);close(primary.mixed[l][j],reference.mixed[l][j]);
                self.max_kt=self.max_kt.max((primary.kt[l][j]-reference.kt[l][j]).abs());self.max_mixed=self.max_mixed.max((primary.mixed[l][j]-reference.mixed[l][j]).abs());
            }
            close(primary.weights[l],reference.weights[l]);
        }
        Query{primary,reference}
    }
    pub fn probabilities(query:&Query)->([f64;4],[f64;4]) {(query.primary.mixed[0],query.reference.mixed[0])}
    pub fn observe(&mut self,query:Query,child:usize) {
        let s=&query.primary;let class=s.class;
        assert!(child<s.prefix);
        self.main.observe(s,child).unwrap();self.oracle.observe(&query.reference,child);
        let loss=-s.mixed[0][child].log2();let y=loss-self.correction[class];let next=self.class_loss[class]+y;self.correction[class]=(next-self.class_loss[class])-y;self.class_loss[class]=next;
        assert_eq!(u64::from(self.main.history[class]),self.oracle.histories[class]);assert_eq!(u64::from(self.main.observations[class]),self.oracle.seen[class]);
        for &local in &s.ids {
            let id=class*NODES+local;let m=self.main.nodes[id];
            for j in 0..4 {assert_eq!(u64::from(m.raw[j])*2+1,self.oracle.halves[id][j]);}
            close(m.weight,self.oracle.mass_weights[id]);self.max_weight=self.max_weight.max((m.weight-self.oracle.mass_weights[id]).abs());
        }
        self.checked+=1;
    }
    pub fn observations(&self)->[u32;CLASSES] {self.main.observations}
    pub fn finish(&self)->u64 {
        let mut values=0;
        assert_eq!(self.main.nodes.len(),self.oracle.halves.len());assert_eq!(self.main.nodes.len(),self.oracle.mass_weights.len());
        for (id,node) in self.main.nodes.iter().enumerate() {
            for j in 0..4 {assert_eq!(u64::from(node.raw[j])*2+1,self.oracle.halves[id][j]);values+=1;}
            checked_unit(node.weight).unwrap();close(node.weight,self.oracle.mass_weights[id]);values+=1;
        }
        for c in 0..CLASSES {assert_eq!(u64::from(self.main.history[c]),self.oracle.histories[c]);assert_eq!(u64::from(self.main.observations[c]),self.oracle.seen[c]);values+=2;}
        assert_eq!(values,(self.main.nodes.len()*5+2*self.main.history.len()) as u64);assert_eq!(values,2621442);values
    }
}
fn fingerprint(m:&Cts)->u64 {
    let mut h=0xcbf29ce484222325u64;let mut add=|n:u64|{h=(h^n).wrapping_mul(0x100000001b3);};
    for node in &m.nodes {for &c in &node.raw {add(u64::from(c));}add(node.weight.to_bits());}
    for c in 0..CLASSES {add(u64::from(m.history[c]));add(u64::from(m.observations[c]));}h
}
fn assert_same(before:&Cts,after:&Cts) {
    assert_eq!(before.nodes.len(),after.nodes.len());
    for (a,b) in before.nodes.iter().zip(&after.nodes) {assert_eq!(a.raw,b.raw);assert_eq!(a.weight.to_bits(),b.weight.to_bits());}
    assert_eq!(before.history,after.history);assert_eq!(before.observations,after.observations);
    assert_eq!(fingerprint(before),fingerprint(after));
}
pub fn validation()->u64 {
    // 小depth全history・合法prefix・観測childを独立再帰式で検査。
    fn recurse(kt:&[[f64;4]],weights:&[f64],l:usize,j:usize)->f64 {
        if l+1==kt.len() {kt[l][j]} else {weights[l]*kt[l][j]+(1.0-weights[l])*recurse(kt,weights,l+1,j)}
    }
    let mut cases=0;
    for depth in 0..=2 {
        for history in 0..4usize.pow(depth as u32) {
            let p=path(history as u16);assert_eq!(p,reference_path(history as u64));
            for prefix in 1..=4 {
                let mut kt=[[0.0;4];LEVELS];let mut weights=[0.5;LEVELS];let mut reference_kt=vec![[0.0;4];depth+1];
                let reference_weights:Vec<_>=(0..=depth).map(|l|0.17+0.21*l as f64).collect();
                for l in 0..=depth {
                    weights[l]=0.17+0.21*l as f64;
                    let raw=std::array::from_fn::<_,4,_>(|j|(p[l]+3*l+5*j)%19);
                    let total=raw[..prefix].iter().sum::<usize>();
                    for j in 0..prefix {kt[l][j]=(raw[j] as f64+0.5)/(total as f64+0.5*prefix as f64);}
                    let halves=raw.map(|v|v as u64*2+1);let denominator=halves[..prefix].iter().sum::<u64>();
                    for j in 0..prefix {reference_kt[l][j]=halves[j] as f64/denominator as f64;close(kt[l][j],reference_kt[l][j]);}
                }
                let mixed=mix_levels(&kt,&weights,prefix,depth);
                for child in 0..prefix {
                    for l in 0..=depth {close(mixed[l][child],recurse(&reference_kt,&reference_weights,l,child));}
                    // half-count massによるposteriorとswitchを全内部depthで比較。
                    for l in 0..depth {
                        let child_mass=(1.0-reference_weights[l])*recurse(&reference_kt,&reference_weights,l+1,child);
                        let own=reference_weights[l]*reference_kt[l][child];let posterior=own/(own+child_mass);
                        let updated=posterior_weight(weights[l],kt[l][child],mixed[l][child],6).unwrap();
                        close(updated,(6.0*posterior+1.0-posterior)/7.0);
                    }
                    cases+=1;
                }
            }
        }
    }
    assert_eq!(path(65535)[8],NODES-1);assert_eq!(path(0),reference_path(0));
    // 独立したdepth1の固定kernel。futureやfull木の履歴を捏造しない。
    for (prefix,expected_p,expected_posterior,expected_weight) in [(4,13.0/64.0,7.0/13.0,55.0/104.0),(2,0.55,7.0/22.0,4.0/11.0)] {
        let root_half=[7u64,3,5,1];let child_half=[1u64,1,5,1];
        let own=root_half[0] as f64/root_half[..prefix].iter().sum::<u64>() as f64;
        let child=child_half[0] as f64/child_half[..prefix].iter().sum::<u64>() as f64;
        let mixed=0.25*own+0.75*child;let posterior=0.25*own/mixed;
        close(mixed,expected_p);close(posterior,expected_posterior);
        close(posterior_weight(0.25,own,mixed,7).unwrap(),expected_weight);
        close(((7.0*posterior)+(1.0-posterior))/8.0,expected_weight);
    }
    let mut audit=Audit::new();
    for c in 0..6 {for t in 0..40 {
        let prefix=t%4+1;let child=match c%3 {0=>0,1=>prefix-1,_=>t%prefix};
        let q=audit.predict(c,prefix);audit.observe(q,child);cases+=1;
        if t==0 {for l in 0..8 {close(audit.main.nodes[c*NODES+path(0)[l]].weight,0.5);}}
    }}
    // prefix4で固定childと交互childを、履歴wrapを越えて観測する。
    let mut series=Audit::new();
    for t in 0..40 {
        for (class,child) in [(0,3),(1,if t%2==0 {0}else {3}),(2,0)] {
            let q=series.predict(class,4);series.observe(q,child);cases+=1;
        }
        assert_eq!(series.main.observations[3..],[0;3]);
        assert_eq!(series.main.history[3..],[0;3]);
    }
    assert_eq!(series.main.history[0],65535);assert_eq!(series.main.history[2],0);
    series.finish();
    audit.finish();assert!(audit.main.history.iter().any(|&h|h!=0));
    let mut m=Cts::new();
    for prefix in 1..=4 {
        for l in path(0) {m.nodes[l].raw=[1,23,5,9];}
        let s=m.predict(0,prefix).unwrap();for l in 0..9 {vector(&s.kt[l],prefix);vector(&s.mixed[l],prefix);}
    }
    let before=m.clone();assert!(m.predict(6,4).is_err());assert_same(&before,&m);
    assert!(m.predict(0,0).is_err());assert_same(&before,&m);assert!(m.predict(0,5).is_err());assert_same(&before,&m);
    let s=m.predict(0,1).unwrap();assert!(m.observe(&s,1).is_err());assert_same(&before,&m);
    let mut invalid=s.clone();invalid.class=6;assert!(m.observe(&invalid,0).is_err());assert_same(&before,&m);
    let mut invalid=s.clone();invalid.prefix=0;assert!(m.observe(&invalid,0).is_err());assert_same(&before,&m);
    let mut invalid=s.clone();invalid.prefix=5;assert!(m.observe(&invalid,0).is_err());assert_same(&before,&m);
    let mut invalid=s.clone();invalid.ids[8]=usize::MAX;assert!(m.observe(&invalid,0).is_err());assert_same(&before,&m);
    m.observe(&s,0).unwrap();let after=m.clone();assert!(m.observe(&s,0).is_err());assert_same(&after,&m);
    let mut cap=Cts::new();cap.observations[0]=CAP;let s=cap.predict(0,4).unwrap();let before=cap.clone();assert!(cap.observe(&s,0).is_err());assert_same(&before,&cap);
    cap.observations[0]=0;cap.nodes[0].raw=[CAP,0,0,0];let s=cap.predict(0,4).unwrap();let before=cap.clone();assert!(cap.observe(&s,0).is_err());assert_same(&before,&cap);
    for value in [-TOL*0.5,1.0+TOL*0.5,0.0,1.0] {assert!(checked_unit(value).is_ok());}
    for value in [-TOL*2.0,1.0+TOL*2.0,f64::NAN,f64::INFINITY] {assert!(checked_unit(value).is_err());}
    let mut invalid=m.predict(0,4).unwrap();invalid.kt[0][0]=f64::NAN;let before=m.clone();assert!(m.observe(&invalid,0).is_err());assert_same(&before,&m);
    cases
}

