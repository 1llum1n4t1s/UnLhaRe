//! コード前FAILURE_PLANで固定したstandalone E2E。timing/unit testではない。
use crate::{old_cts as old,new_cts as new,Result};
use old::{CAP,Q,CLASSES,LEVELS,NODES};
struct Pair {old:old::Cts,new:new::Cts}
struct Evidence {successes:usize,rejections:usize,failed_predictions:usize,digest:u64,reasons:[usize;8]}
const REASONS:[&str;8]=["stale or modified snapshot","invalid prefix","invalid observation","class update cap","node update cap","invalid kernel depth/leaf","kernel weight","raw observation cap"];
impl Evidence {
    fn new()->Self {Self{successes:0,rejections:0,failed_predictions:0,digest:0xcbf29ce484222325,reasons:[0;8]}}
    fn fold(&mut self,v:u64){self.digest=(self.digest^v).wrapping_mul(0x100000001b3);}
}
impl Pair {
    fn new()->Result<Self>{Ok(Self{old:old::Cts::new()?,new:new::Cts::new(8)?})}
    fn same(&self)->Result<()> {
        if self.old.nodes()!=self.new.nodes() || self.old.histories()!=self.new.histories()
            || self.old.observations()!=self.new.observations(){return Err("all CTS state differs".into());}Ok(())
    }
    fn predict(&self,class:usize,prefix:usize)->Result<(old::Snapshot,new::Snapshot)> {
        let o=self.old.predict(class,prefix)?;let n=self.new.predict(class,prefix)?;
        if std::ops::Deref::deref(&o)!=std::ops::Deref::deref(&n){return Err("prediction visible differs".into());}Ok((o,n))
    }
    fn seed_class(&mut self,class:usize,history:u16,observations:u32){
        self.old.audit_seed_class(class,history,observations);self.new.audit_seed_class(class,history,observations);
    }
    fn seed_node(&mut self,class:usize,id:usize,raw:[u32;4],weight:u64){
        self.old.audit_seed_node(class,id,raw,weight);self.new.audit_seed_node(class,id,raw,weight);
    }
    fn success(&mut self,o:&old::Snapshot,n:&new::Snapshot,child:usize,e:&mut Evidence)->Result<()> {
        self.old.observe(o,child).map_err(|v|format!("success {} old: {v}",e.successes))?;
        self.new.observe(n,child).map_err(|v|format!("success {} sealed: {v}",e.successes))?;
        self.same()?;e.successes+=1;e.fold(e.successes as u64);e.fold(o.class as u64);e.fold(child as u64);
        for x in self.old.histories(){e.fold(u64::from(x));}for x in self.old.observations(){e.fold(u64::from(x));}Ok(())
    }
    fn reject(&mut self,o:&old::Snapshot,n:&new::Snapshot,child:usize,expected:&str,e:&mut Evidence)->Result<()> {
        // cloneは固定223拒否probeだけ。成功sequence各stepでは全node cloneしない。
        let before_old=self.old.clone();let before_new=self.new.clone();
        let a=self.old.observe(o,child);let b=self.new.observe(n,child);
        if a!=Err(expected)||b!=Err(expected){return Err(format!("rejection {} expected {expected}, old {a:?}, sealed {b:?}",e.rejections));}
        if before_old!=self.old || before_new!=self.new{return Err(format!("rejection {} changed all state",e.rejections));}
        self.same()?;let slot=REASONS.iter().position(|&r|r==expected).ok_or("unplanned rejection reason")?;
        e.reasons[slot]+=1;e.rejections+=1;e.fold(e.rejections as u64);e.fold(slot as u64);Ok(())
    }
    fn failed_predict(&self,class:usize,prefix:usize,expected:&str,e:&mut Evidence)->Result<()> {
        let before_old=self.old.clone();let before_new=self.new.clone();
        let a=self.old.predict(class,prefix);let b=self.new.predict(class,prefix);
        if a.as_ref().err().copied()!=Some(expected)||b.as_ref().err().copied()!=Some(expected){
            return Err(format!("failed predict {} expected {expected}, old {:?}, sealed {:?}",e.failed_predictions,a.as_ref().err(),b.as_ref().err()));
        }
        if before_old!=self.old || before_new!=self.new{return Err("failed predict changed all state".into());}
        self.same()?;e.failed_predictions+=1;for v in expected.bytes(){e.fold(u64::from(v));}Ok(())
    }
}
fn lcg(seed:&mut u32)->u32{*seed=seed.wrapping_mul(1664525).wrapping_add(1013904223);*seed}
fn sequence(e:&mut Evidence)->Result<()> {
    let mut p=Pair::new()?;let mut seed=0x6d2b79f5u32;
    for class in 0..CLASSES {
        let history=(lcg(&mut seed)>>8) as u16;p.seed_class(class,history,0);
        for (l,id) in old::path(history).into_iter().enumerate(){
            let raw=std::array::from_fn(|_|lcg(&mut seed)%97);
            let weight=if l==LEVELS-1{Q/2}else{[0,Q/2,Q][l%3]};p.seed_node(class,id,raw,weight);
        }
    }
    for step in 0..384 {
        let class=step%CLASSES;let prefix=1+(step/CLASSES)%4;let child=lcg(&mut seed) as usize%prefix;
        let (o,n)=p.predict(class,prefix)?;p.success(&o,&n,child,e)?;
    }
    // 各visible fieldの全要素を改変し、現在stateも拒否後stateも直接比較する。
    let (o,n)=p.predict(0,4)?;
    for kind in 0..3 {for l in 0..LEVELS {for j in 0..4 {
        let mut a=o.clone();let mut b=n.clone();match kind {
            0=>{a.kernel.kt[l][j]^=1;b.kernel.kt[l][j]^=1;},
            1=>{a.kernel.mixed[l][j]^=1;b.kernel.mixed[l][j]^=1;},
            _=>{a.kernel.masses[l][j]^=1;b.kernel.masses[l][j]^=1;},
        }p.reject(&a,&b,0,"stale or modified snapshot",e)?;
    }}}
    let mut a=o.clone();let mut b=n.clone();a.kernel.depth^=1;b.kernel.depth^=1;p.reject(&a,&b,0,"stale or modified snapshot",e)?;
    for l in 0..LEVELS {for j in 0..4 {
        let mut a=o.clone();let mut b=n.clone();a.raw[l][j]^=1;b.raw[l][j]^=1;p.reject(&a,&b,0,"stale or modified snapshot",e)?;
    }}
    for l in 0..LEVELS {
        let mut a=o.clone();let mut b=n.clone();a.weights[l]^=1;b.weights[l]^=1;p.reject(&a,&b,0,"stale or modified snapshot",e)?;
        let mut a=o.clone();let mut b=n.clone();a.ids[l]^=1;b.ids[l]^=1;p.reject(&a,&b,0,"stale or modified snapshot",e)?;
    }
    for kind in 0..4 {
        let mut a=o.clone();let mut b=n.clone();let expected=match kind {
            0=>{a.history^=1;b.history^=1;"stale or modified snapshot"},
            1=>{a.observations^=1;b.observations^=1;"stale or modified snapshot"},
            2=>{a.class=CLASSES;b.class=CLASSES;"invalid observation"},
            _=>{a.prefix=0;b.prefix=0;"invalid prefix"},
        };p.reject(&a,&b,0,expected,e)?;
    }Ok(())
}
fn lifecycle(e:&mut Evidence)->Result<()> {
    {
        let mut p=Pair::new()?;let(o,n)=p.predict(0,4)?;p.success(&o.clone(),&n.clone(),2,e)?;
        p.reject(&o,&n,2,"stale or modified snapshot",e)?;
    }
    {
        let mut p=Pair::new()?;let(o,n)=p.predict(0,4)?;
        for prefix in 1..=4 {let _=p.predict(0,prefix)?;}p.success(&o,&n,3,e)?;
    }
    {
        let source=Pair::new()?;let before_old=source.old.clone();let before_new=source.new.clone();
        let(o,n)=source.predict(0,4)?;let mut destination=Pair::new()?;destination.success(&o,&n,1,e)?;
        if source.old!=before_old||source.new!=before_new{return Err("foreign source state changed".into());}
    }
    // 旧old::Snapshotはseal由来と無関係に、現在predictとexact一致する改変を受理する。
    {
        let mut p=Pair::new()?;let(mut o,mut n)=p.predict(0,4)?;o.class=1;n.class=1;p.success(&o,&n,2,e)?;
    }
    {
        let mut p=Pair::new()?;let(_,mut n)=p.predict(0,4)?;let(o,_)=p.predict(0,2)?;
        *n=(*o).clone();p.success(&o,&n,1,e)?;
    }
    {
        let mut p=Pair::new()?;let(o,mut n)=p.predict(0,4)?;let saved=n.clone();
        p.success(&o,&saved,3,e)?;let(o,_)=p.predict(0,4)?;*n=(*o).clone();p.success(&o,&n,2,e)?;
    }Ok(())
}
fn caps(e:&mut Evidence)->Result<()> {
    let mut p=Pair::new()?;p.seed_class(0,0,CAP-1);
    for id in old::path(0){p.seed_node(0,id,[CAP-1,0,0,0],Q/2);}
    let(o,n)=p.predict(0,4)?;p.success(&o,&n,0,e)?;
    if p.old.observations()[0]!=CAP || p.new.observations()[0]!=CAP{return Err("CAP exact transition".into());}
    let(o,n)=p.predict(0,4)?;p.reject(&o,&n,0,"class update cap",e)?;
    p.seed_class(0,0,CAP+1);p.failed_predict(0,4,"class observation cap",e)?;drop(p);
    let mut p=Pair::new()?;
    for id in old::path(0) {
        p.seed_node(0,id,[CAP,0,0,0],Q/2);let(o,n)=p.predict(0,4)?;p.reject(&o,&n,0,"node update cap",e)?;
        p.seed_node(0,id,[0;4],Q/2);
    }Ok(())
}
fn invalid_current(e:&mut Evidence)->Result<()> {
    let mut p=Pair::new()?;let(o,n)=p.predict(0,4)?;
    for case in 0..18 {
        let (level,raw,weight,expected)=if case==0{(8,[0;4],0,"invalid kernel depth/leaf")}
            else if case<=8{(case-1,[0;4],Q+1,"kernel weight")}
            else{(case-9,[CAP+1,0,0,0],Q/2,"raw observation cap")};
        p.seed_node(0,o.ids[level],raw,weight);p.failed_predict(0,4,expected,e)?;
        p.reject(&o,&n,0,expected,e)?;
        let mut a=o.clone();let mut b=n.clone();a.kernel.mixed[0][0]^=1;b.kernel.mixed[0][0]^=1;
        p.reject(&a,&b,0,expected,e)?;p.seed_node(0,o.ids[level],[0;4],Q/2);
    }
    for case in 0..3 {
        let mut a=o.clone();let mut b=n.clone();a.kernel.kt[0][0]^=1;b.kernel.kt[0][0]^=1;
        let expected=match case {
            0=>{p.seed_node(0,o.ids[0],[CAP+1,0,0,0],Q/2);p.seed_node(0,o.ids[8],[0;4],0);"invalid kernel depth/leaf"},
            1=>{p.seed_node(0,o.ids[0],[CAP+1,0,0,0],Q+1);"kernel weight"},
            _=>{p.seed_node(0,o.ids[1],[CAP+1,0,0,0],Q/2);p.seed_node(0,o.ids[2],[0;4],Q+1);"raw observation cap"},
        };p.reject(&a,&b,0,expected,e)?;for id in o.ids{p.seed_node(0,id,[0;4],Q/2);}
    }Ok(())
}
fn early_guards(e:&mut Evidence)->Result<()> {
    let mut p=Pair::new()?;let(o,n)=p.predict(0,4)?;
    p.failed_predict(0,0,"invalid prefix",e)?;p.failed_predict(0,5,"invalid prefix",e)?;p.failed_predict(CLASSES,4,"invalid class",e)?;
    for case in 0..6 {
        let mut a=o.clone();let mut b=n.clone();let mut child=0;
        let expected=match case {
            0=>{a.prefix=0;b.prefix=0;a.class=CLASSES;b.class=CLASSES;a.observations=CAP;b.observations=CAP;"invalid prefix"},
            1=>{a.class=CLASSES;b.class=CLASSES;a.observations=CAP;b.observations=CAP;child=4;"invalid observation"},
            2=>{a.observations=CAP;b.observations=CAP;child=4;"invalid observation"},
            3=>{a.observations=CAP;b.observations=CAP;"class update cap"},
            4=>{p.seed_class(0,0,CAP);"class update cap"},
            _=>{p.seed_class(0,0,CAP);p.seed_node(0,o.ids[8],[0;4],0);"class update cap"},
        };p.reject(&a,&b,child,expected,e)?;p.seed_class(0,0,0);p.seed_node(0,o.ids[8],[0;4],Q/2);
    }Ok(())
}
fn sealed_comparison()->Result<String> {
    let mut e=Evidence::new();sequence(&mut e)?;lifecycle(&mut e)?;caps(&mut e)?;invalid_current(&mut e)?;early_guards(&mut e)?;
    if (e.successes,e.rejections,e.failed_predictions)!=(392,223,22)||e.reasons!=[166,2,3,4,9,3,17,19]{return Err("FAILURE_PLAN fixed counts/reasons differ".into());}
    let reasons=REASONS.iter().zip(e.reasons).map(|(r,n)|format!("{{\"reason\":\"{r}\",\"cases\":{n}}}")).collect::<Vec<_>>().join(",");
    Ok(format!("{{\"status\":\"passed\",\"operation\":\"compare-snapshot\",\"LCG_seed\":1831565813,\"legal_sequence_steps\":384,\"lifecycle_successes\":3,\"valid_modified_successes\":3,\"modified_preparation_successes\":1,\"cap_exact_successes\":1,\"success_cases\":392,\"visible_tamper_rejections\":167,\"stale_rejections\":1,\"class_cap_rejections\":1,\"node_cap_rejections\":9,\"invalid_current_rejections\":18,\"dual_invalid_rejections\":18,\"early_guard_rejections\":6,\"current_guard_priority_rejections\":3,\"rejection_cases\":223,\"failed_prediction_cases\":22,\"success_all_state_comparisons\":392,\"rejection_before_after_comparisons\":446,\"failed_predict_before_after_comparisons\":44,\"old_snapshot_bytes\":{},\"new_snapshot_bytes\":{},\"node_storage_bytes_per_CTS\":{},\"proof_method\":\"full nodes/history/observations direct comparisons\",\"digest\":\"{:016x}\",\"reason_summary\":[{reasons}],\"diagnostic_only\":true,\"formal_speed_CPU_verified\":false,\"full_benchmark_allowed\":false,\"general_8MiB_input_supported\":false,\"local_timing_added\":false}}",std::mem::size_of::<old::Snapshot>(),std::mem::size_of::<new::Snapshot>(),CLASSES*NODES*std::mem::size_of::<old::Node>(),e.digest))
}

// 各depthの失敗はhashで代用せず、全Cts値を直接比較する。
fn refuse(m:&mut new::Cts,s:&new::Snapshot,child:usize,expected:&str,e:&mut Evidence)->Result<()> {
    let before=m.clone();let actual=m.observe(s,child);
    if actual!=Err(expected)||before!=*m{return Err(format!("depth {} refusal {} expected {expected}, got {actual:?}",m.depth(),e.rejections));}
    let slot=REASONS.iter().position(|&r|r==expected).ok_or("depth rejection reason")?;
    e.reasons[slot]+=1;e.rejections+=1;e.fold(e.rejections as u64);Ok(())
}
fn fail_prediction(m:&new::Cts,class:usize,prefix:usize,expected:&str,e:&mut Evidence)->Result<()> {
    let before=m.clone();let actual=m.predict(class,prefix);
    if actual.as_ref().err().copied()!=Some(expected)||before!=*m{return Err(format!("depth {} failed prediction {expected}",m.depth()));}
    e.failed_predictions+=1;Ok(())
}
fn succeed(m:&mut new::Cts,s:&new::Snapshot,child:usize,e:&mut Evidence)->Result<()> {
    m.observe(s,child)?;e.successes+=1;
    for node in m.nodes(){for v in node.raw{e.fold(u64::from(v));}e.fold(node.weight);}
    for v in m.histories(){e.fold(u64::from(v));}for v in m.observations(){e.fold(u64::from(v));}Ok(())
}
fn canonical(m:&new::Cts,s:&new::Snapshot)->Result<()> {
    if s.kernel.depth!=m.depth()||s.ids!=new::path(s.history)||s.weights[m.depth()]!=Q/2{return Err("depth/path/leaf canonical".into());}
    for l in 0..=m.depth(){
        if s.ids[l]>=m.node_count(){return Err("compact active ID bound".into());}
        let node=&m.nodes()[s.class*m.node_count()+s.ids[l]];
        if node.raw!=s.raw[l]||node.weight!=s.weights[l]{return Err("compact class base".into());}
    }
    for l in m.depth()+1..LEVELS {
        if s.raw[l]!=[0;4]||s.weights[l]!=0||s.kernel.kt[l]!=[0;4]||s.kernel.mixed[l]!=[0;4]||s.kernel.masses[l]!=[0;4]{return Err("unused arrays not canonical zero".into());}
    }Ok(())
}
fn compact_shapes()->Result<usize> {
    let mut checked=0;let zero=new::Node{raw:[0;4],weight:Q/2};
    for (depth,count,storage) in [(4,341,49104),(5,1365,196560),(6,5461,786384),(7,21845,3145680),(8,87381,12582864)] {
        let mut m=new::Cts::new(depth)?;
        if m.node_count()!=count||m.nodes().len()!=CLASSES*count||m.nodes().len()*std::mem::size_of::<new::Node>()!=storage{return Err("fixed compact shape".into());}
        for class in 0..CLASSES {for history in [0,65535] {
            m.audit_seed_class(class,history,0);let ids=new::path(history);
            for l in 0..=depth {m.audit_seed_node(class,ids[l],[class as u32+1,u32::from(history)+1,l as u32+1,0],Q/2);}
            let before=m.clone();let s=m.predict(class,4)?;canonical(&m,&s)?;
            if before!=m{return Err("compact pure prediction".into());}
            for (index,node) in m.nodes().iter().enumerate() {
                let c=index/count;let id=index%count;let level=ids[..=depth].iter().position(|&v|v==id);
                let expected=if c==class {level.map(|l|new::Node{raw:[class as u32+1,u32::from(history)+1,l as u32+1,0],weight:Q/2}).unwrap_or(zero)}else{zero};
                if *node!=expected{return Err("compact full node partition".into());}
            }
            for &id in &ids[..=depth]{m.audit_seed_node(class,id,[0;4],Q/2);}
            m.audit_seed_class(class,0,0);checked+=1;
        }}
    }
    if checked!=60{return Err("compact shape count".into());}Ok(checked)
}
fn depth_checks(depth:usize)->Result<String> {
    let mut e=Evidence::new();let mut m=new::Cts::new(depth)?;
    let before=m.clone();let s=m.predict(0,4)?;let again=m.predict(0,4)?;
    if before!=m||s!=again{return Err("depth pure prediction".into());}canonical(&m,&s)?;
    // 全9配列要素を改変。inactive derived/raw/weightも拒否対象。
    for kind in 0..3 {for l in 0..LEVELS {for j in 0..4 {
        let mut t=s.clone();match kind {0=>t.kernel.kt[l][j]^=1,1=>t.kernel.mixed[l][j]^=1,_=>t.kernel.masses[l][j]^=1}
        refuse(&mut m,&t,0,"stale or modified snapshot",&mut e)?;
    }}}
    let mut t=s.clone();t.kernel.depth^=1;refuse(&mut m,&t,0,"stale or modified snapshot",&mut e)?;
    for l in 0..LEVELS {for j in 0..4 {let mut t=s.clone();t.raw[l][j]^=1;refuse(&mut m,&t,0,"stale or modified snapshot",&mut e)?;}}
    for l in 0..LEVELS {
        let mut t=s.clone();t.weights[l]^=1;refuse(&mut m,&t,0,"stale or modified snapshot",&mut e)?;
        let mut t=s.clone();t.ids[l]^=1;refuse(&mut m,&t,0,"stale or modified snapshot",&mut e)?;
    }
    for kind in 0..4 {
        let mut t=s.clone();let expected=match kind{
            0=>{t.history^=1;"stale or modified snapshot"},1=>{t.observations^=1;"stale or modified snapshot"},
            2=>{t.class=CLASSES;"invalid observation"},_=>{t.prefix=0;"invalid prefix"}};
        refuse(&mut m,&t,0,expected,&mut e)?;
    }
    let foreign=new::Cts::new(if depth==8{0}else{8})?.predict(0,4)?;
    refuse(&mut m,&foreign,0,"stale or modified snapshot",&mut e)?;
    // 未改変cross-depthを拒否し、destination現行visibleへの合法交換は受理。
    let mut rebased=foreign;*rebased=(*m.predict(0,2)?).clone();
    succeed(&mut m,&rebased,1,&mut e)?;drop(m);
    let mut m=new::Cts::new(depth)?;let mut t=m.predict(0,4)?;t.class=1;succeed(&mut m,&t,2,&mut e)?;
    let stale=m.predict(0,4)?;succeed(&mut m,&stale,0,&mut e)?;
    refuse(&mut m,&stale,0,"stale or modified snapshot",&mut e)?;
    let mut revised=m.predict(0,4)?;let prepared=revised.clone();succeed(&mut m,&prepared,0,&mut e)?;
    *revised=(*m.predict(0,4)?).clone();succeed(&mut m,&revised,1,&mut e)?;drop(m);
    let mut m=new::Cts::new(depth)?;m.audit_seed_class(0,0,CAP-1);let ids=new::path(0);
    for &id in &ids[..=depth]{m.audit_seed_node(0,id,[CAP-1,0,0,0],Q/2);}
    let t=m.predict(0,4)?;succeed(&mut m,&t,0,&mut e)?;
    if m.observations()[0]!=CAP{return Err("depth CAP exact".into());}
    let t=m.predict(0,4)?;refuse(&mut m,&t,0,"class update cap",&mut e)?;
    m.audit_seed_class(0,0,CAP+1);fail_prediction(&m,0,4,"class observation cap",&mut e)?;drop(m);
    let mut m=new::Cts::new(depth)?;
    for &id in &ids[..=depth]{
        m.audit_seed_node(0,id,[CAP,0,0,0],Q/2);let t=m.predict(0,4)?;
        refuse(&mut m,&t,0,"node update cap",&mut e)?;m.audit_seed_node(0,id,[0;4],Q/2);
    }
    let s=m.predict(0,4)?;
    for case in 0..2*depth+2 {
        let (level,raw,weight,expected)=if case==0{(depth,[0;4],0,"invalid kernel depth/leaf")}
            else if case<=depth{(case-1,[0;4],Q+1,"kernel weight")}
            else{(case-depth-1,[CAP+1,0,0,0],Q/2,"raw observation cap")};
        m.audit_seed_node(0,s.ids[level],raw,weight);fail_prediction(&m,0,4,expected,&mut e)?;
        refuse(&mut m,&s,0,expected,&mut e)?;let mut t=s.clone();t.kernel.kt[0][0]^=1;
        refuse(&mut m,&t,0,expected,&mut e)?;m.audit_seed_node(0,s.ids[level],[0;4],Q/2);
    }
    let priorities=2+usize::from(depth>=2);
    for case in 0..priorities {
        let mut t=s.clone();t.kernel.kt[0][0]^=1;
        let expected=match case{
            0=>{m.audit_seed_node(0,s.ids[0],[CAP+1,0,0,0],Q/2);m.audit_seed_node(0,s.ids[depth],if depth==0{[CAP+1,0,0,0]}else{[0;4]},0);"invalid kernel depth/leaf"},
            1=>{m.audit_seed_node(0,s.ids[0],[CAP+1,0,0,0],Q+1);if depth==0{"invalid kernel depth/leaf"}else{"kernel weight"}},
            _=>{m.audit_seed_node(0,s.ids[0],[CAP+1,0,0,0],Q/2);m.audit_seed_node(0,s.ids[1],[0;4],Q+1);"raw observation cap"}};
        refuse(&mut m,&t,0,expected,&mut e)?;for &id in &s.ids[..=depth]{m.audit_seed_node(0,id,[0;4],Q/2);}
    }
    fail_prediction(&m,0,0,"invalid prefix",&mut e)?;fail_prediction(&m,0,5,"invalid prefix",&mut e)?;fail_prediction(&m,CLASSES,4,"invalid class",&mut e)?;
    for case in 0..6 {
        let mut t=s.clone();let mut child=0;
        let expected=match case{
            0=>{t.prefix=0;t.class=CLASSES;t.observations=CAP;"invalid prefix"},
            1=>{t.class=CLASSES;t.observations=CAP;child=4;"invalid observation"},
            2=>{t.observations=CAP;child=4;"invalid observation"},
            3=>{t.observations=CAP;"class update cap"},
            4=>{m.audit_seed_class(0,0,CAP);"class update cap"},
            _=>{m.audit_seed_class(0,0,CAP);m.audit_seed_node(0,s.ids[depth],[0;4],0);"class update cap"}};
        refuse(&mut m,&t,child,expected,&mut e)?;m.audit_seed_class(0,0,0);m.audit_seed_node(0,s.ids[depth],[0;4],Q/2);
    }
    let expected_refusals=183+5*depth+usize::from(depth>=2);
    if (e.successes,e.rejections,e.failed_predictions)!=(6,expected_refusals,2*depth+6){return Err("depth fixed counts".into());}
    let expected_reasons=[167,2,3,4,depth+1,if depth==0{4}else{3},if depth==0{0}else{2*depth+1},2*depth+2+usize::from(depth>=2)];
    if e.reasons!=expected_reasons{return Err("depth exact reason counts".into());}
    let reasons=REASONS.iter().zip(e.reasons).map(|(r,n)|format!("{{\"reason\":\"{r}\",\"cases\":{n}}}")).collect::<Vec<_>>().join(",");
    Ok(format!("{{\"depth\":{depth},\"success_cases\":{},\"rejection_cases\":{},\"failed_prediction_cases\":{},\"pure_prediction_cases\":1,\"visible_tamper_rejections\":167,\"foreign_depth_rejections\":1,\"legal_rebased_foreign_successes\":1,\"cap_exact_successes\":1,\"node_cap_rejections\":{},\"current_guard_priority_rejections\":{priorities},\"node_count\":{},\"node_storage_bytes\":{},\"rejection_before_after_comparisons\":{},\"digest\":\"{:016x}\",\"reason_summary\":[{reasons}]}}",e.successes,e.rejections,e.failed_predictions,depth+1,m.node_count(),m.nodes().len()*std::mem::size_of::<new::Node>(),e.rejections,e.digest))
}
pub(crate) fn run()->Result<()> {
    let mut constructors=0;for depth in [9,usize::MAX] {
        if new::Cts::new(depth).err()!=Some("unsupported CTS depth"){return Err("unsupported constructor depth".into());}constructors+=1;
    }
    let compact=compact_shapes()?;let sealed=sealed_comparison()?;let mut records=Vec::new();
    for depth in [4,5,6,7,8]{records.push(depth_checks(depth)?);}
    println!("{{\"status\":\"passed\",\"operation\":\"depth-compare\",\"constructor_rejections\":{constructors},\"compact_shape_cases\":{compact},\"depths\":[4,5,6,7,8],\"depth_success_cases\":30,\"depth_rejection_cases\":1070,\"depth_failed_prediction_cases\":90,\"pure_prediction_cases\":5,\"sealed\":{sealed},\"records\":[{}],\"proof_method\":\"full nodes/history/observations and RawSnapshot direct comparisons\"}}",records.join(","));Ok(())
}

