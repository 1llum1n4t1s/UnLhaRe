//! standalone numerical diagnostic。encoder/decoder/pool/frameではない。
#[path="integer_cts.rs"] mod integer_cts;
use integer_cts::{Cts,Snapshot,CLASSES,LEVELS,NODES,CAP,Q};
const SCALE:u64=4294967296;
type R<T>=Result<T,&'static str>;
// 128step binary long division。129bitの一時remainderはcarry+u128で表す。
fn divrem(n:u128,d:u128)->R<(u128,u128)> {
    if d==0 {return Err("oracle zero divisor");}
    let mut quotient=0u128;let mut remainder=0u128;
    for bit in (0..128).rev() {
        let carry=remainder>>(127)!=0;
        remainder=(remainder<<1)|((n>>bit)&1);
        if carry || remainder>=d {remainder=remainder.wrapping_sub(d);quotient|=1u128<<bit;}
    }
    assert!(remainder<d);assert_eq!(quotient.checked_mul(d).and_then(|v|v.checked_add(remainder)),Some(n));
    Ok((quotient,remainder))
}
fn normalize_reference(mass:[u128;4],prefix:usize)->R<[u64;4]> {
    if !(1..=4).contains(&prefix) {return Err("oracle prefix");}
    let denominator=mass[..prefix].iter().try_fold(0u128,|sum,&v|sum.checked_add(v).ok_or("oracle sum overflow"))?;
    if denominator==0 {return Err("oracle zero total");}
    let mut q=[0u64;4];let mut residue=[0u128;4];let mut allocated=0;
    for child in 0..prefix {
        let numerator=mass[child].checked_mul(u128::from(SCALE)).ok_or("oracle product overflow")?;
        let (value,rest)=divrem(numerator,denominator)?;q[child]=u64::try_from(value).map_err(|_|"oracle conversion")?;
        residue[child]=rest;allocated+=q[child];
    }
    let extra=(SCALE-allocated) as usize;if extra>=prefix {return Err("oracle remainder count");}
    // sortを呼ばず、余りが先行するchildの個数で各childの順位を決める。
    for child in 0..prefix {
        let rank=(0..prefix).filter(|&other|residue[other]>residue[child] || (residue[other]==residue[child] && other<child)).count();
        if rank<extra {q[child]+=1;}
    }assert_eq!(q.iter().sum::<u64>(),SCALE);Ok(q)
}
fn half_kt(half:[u64;4],prefix:usize)->[u64;4] {
    assert!((1..=4).contains(&prefix));
    normalize_reference(half.map(u128::from),prefix).unwrap()
}
fn independent_path(mut history:u64)->[usize;LEVELS] {
    let mut indexes=[0;LEVELS];let mut parent=0u64;
    for entry in indexes.iter_mut().skip(1) {parent=parent*4+history%4+1;*entry=parent as usize;history/=4;}
    indexes
}
fn mixture_reference(weight:u64,own:[u64;4],child:[u64;4],prefix:usize)->([u64;4],[u128;4]) {
    let mut own_mass=[0u128;4];
    for j in 0..prefix {own_mass[j]=u128::from(own[j])*u128::from(weight)+u128::from(child[j])*u128::from(SCALE-weight);}
    assert_eq!(own_mass.iter().sum::<u128>(),u128::from(SCALE)*u128::from(SCALE));
    (normalize_reference(own_mass,prefix).unwrap(),own_mass)
}
fn switch_reference(weight:u64,own:u64,child:u64,after:u32)->(u64,u64,u64) {
    let retained_own=u128::from(own)*u128::from(weight);let childmass=u128::from(child)*u128::from(SCALE-weight);
    let post=divrem(retained_own*u128::from(SCALE),retained_own+childmass).unwrap().0 as u64;
    let alpha=divrem(u128::from(SCALE),u128::from(after)+1).unwrap().0 as u64;
    // 一つの分子へalphaを持ち上げた別更新式。
    let numerator=u128::from(alpha)*u128::from(SCALE)+u128::from(SCALE-2*alpha)*u128::from(post);
    let next=divrem(numerator,u128::from(SCALE)).unwrap().0 as u64;
    assert!(post<=SCALE && next>=alpha && next<=SCALE-alpha);(post,alpha,next)
}
#[derive(Clone)]
struct ReferencePrediction {
    class:usize,prefix:usize,ids:[usize;LEVELS],history:u64,seen:u64,
    halves:[[u64;4];LEVELS],weights:[u64;LEVELS],kt:[[u64;4];LEVELS],mixed:[[u64;4];LEVELS],masses:[[u128;4];LEVELS],
}
fn recursive_reference(kt:&[[u64;4];LEVELS],weights:&[u64;LEVELS],prefix:usize,level:usize,depth:usize,mixed:&mut [[u64;4];LEVELS],masses:&mut [[u128;4];LEVELS])->[u64;4] {
    let value=if level==depth {kt[level]}else {
        let child=recursive_reference(kt,weights,prefix,level+1,depth,mixed,masses);
        let (value,raw)=mixture_reference(weights[level],kt[level],child,prefix);masses[level]=raw;value
    };mixed[level]=value;value
}
struct Reference {
    halves:Vec<[u64;4]>,weights:Vec<u64>,histories:[u64;CLASSES],seen:[u64;CLASSES],
}
impl Reference {
    fn new()->Self {Self{halves:vec![[1;4];CLASSES*NODES],weights:vec![SCALE/2;CLASSES*NODES],histories:[0;CLASSES],seen:[0;CLASSES]}}
    fn predict(&self,class:usize,prefix:usize)->ReferencePrediction {
        let ids=independent_path(self.histories[class]);
        let mut halves=[[0;4];LEVELS];let mut weights=[0;LEVELS];let mut kt=[[0;4];LEVELS];
        for level in 0..LEVELS {
            halves[level]=self.halves[class*NODES+ids[level]];weights[level]=self.weights[class*NODES+ids[level]];
            kt[level]=half_kt(halves[level],prefix);
        }
        let mut mixed=[[0;4];LEVELS];let mut masses=[[0;4];LEVELS];
        recursive_reference(&kt,&weights,prefix,0,LEVELS-1,&mut mixed,&mut masses);
        ReferencePrediction{class,prefix,ids,history:self.histories[class],seen:self.seen[class],halves,weights,kt,mixed,masses}
    }
    fn observe(&mut self,s:&ReferencePrediction,child:usize) {
        assert!(child<s.prefix && s.seen<u64::from(CAP));assert_eq!(self.histories[s.class],s.history);assert_eq!(self.seen[s.class],s.seen);
        let after=(s.seen+1) as u32;let mut next=[SCALE/2;LEVELS];
        for level in 0..LEVELS-1 {next[level]=switch_reference(s.weights[level],s.kt[level][child],s.mixed[level+1][child],after).2;}
        for level in 0..LEVELS {
            let id=s.class*NODES+s.ids[level];assert_eq!(self.halves[id],s.halves[level]);assert_eq!(self.weights[id],s.weights[level]);
            self.halves[id][child]+=2;self.weights[id]=next[level];
        }
        self.histories[s.class]=(s.history*4+child as u64)%65536;self.seen[s.class]=u64::from(after);
    }
}
fn compare_snapshot(a:&Snapshot,b:&ReferencePrediction) {
    assert_eq!(a.class,b.class);assert_eq!(a.prefix,b.prefix);assert_eq!(a.ids,b.ids);assert_eq!(u64::from(a.history),b.history);assert_eq!(u64::from(a.observations),b.seen);
    for level in 0..LEVELS {
        assert_eq!(a.raw[level].map(|v|u64::from(v)*2+1),b.halves[level]);assert_eq!(a.weights[level],b.weights[level]);
        assert_eq!(a.kernel.kt[level],b.kt[level]);assert_eq!(a.kernel.mixed[level],b.mixed[level]);assert_eq!(a.kernel.masses[level],b.masses[level]);
    }
}
#[derive(Default)]
struct ErrorAudit {kt:f64,mixed:f64,posterior:f64,switch:f64,kt_comparisons:u64,mixed_comparisons:u64,update_comparisons:u64}
impl ErrorAudit {
    fn local_kernel(&mut self,raw:[[u32;4];LEVELS],weights:[u64;LEVELS],prefix:usize,depth:usize,s:&integer_cts::Kernel) {
        // 同じrawとQ32 weightを実数で再帰。別f64連続stateは保持しない。
        let mut ideal_kt=[[0.0;4];LEVELS];let mut ideal_mixed=[[0.0;4];LEVELS];
        for level in 0..=depth {
            let sum=raw[level][..prefix].iter().map(|&v|f64::from(v)).sum::<f64>()+0.5*prefix as f64;
            for j in 0..prefix {
                ideal_kt[level][j]=(f64::from(raw[level][j])+0.5)/sum;
                let error=(s.kt[level][j] as f64/Q as f64-ideal_kt[level][j]).abs();assert!(error<=2.0/Q as f64,"local KT bound {error}");
                self.kt=self.kt.max(error);self.kt_comparisons+=1;
            }
        }
        ideal_mixed[depth]=ideal_kt[depth];
        for level in (0..depth).rev() {let w=weights[level] as f64/Q as f64;for j in 0..prefix {ideal_mixed[level][j]=w*ideal_kt[level][j]+(1.0-w)*ideal_mixed[level+1][j];}}
        for level in 0..=depth {for j in 0..prefix {
            let error=(s.mixed[level][j] as f64/Q as f64-ideal_mixed[level][j]).abs();
            let bound=2.0*(depth-level+1) as f64/Q as f64;assert!(error<=bound,"local mixed bound {level} {error} {bound}");
            self.mixed=self.mixed.max(error);self.mixed_comparisons+=1;
        }}
    }
    fn local_update(&mut self,weight:u64,own:u64,child:u64,after:u32,actual:(u64,u64,u64)) {
        // 4/Qは既Q32 KT/child/同weightのrawmass一更新だけに適用。
        let w=weight as f64/Q as f64;let k=own as f64/Q as f64;let c=child as f64/Q as f64;
        let mass=w*k;let other=(1.0-w)*c;let posterior=mass/(mass+other);
        let alpha=1.0/(f64::from(after)+1.0);let next=alpha+(1.0-2.0*alpha)*posterior;
        let pe=(actual.0 as f64/Q as f64-posterior).abs();let we=(actual.2 as f64/Q as f64-next).abs();
        assert!(pe<=4.0/Q as f64 && we<=4.0/Q as f64,"local rawmass update bounds {pe} {we}");
        self.posterior=self.posterior.max(pe);self.switch=self.switch.max(we);self.update_comparisons+=1;
    }
}
fn all_paths()->u64 {
    for history in 0..65536u64 {
        let a=integer_cts::path(history as u16);assert_eq!(a,independent_path(history));assert_eq!(a[0],0);
        for &id in &a {assert!(id<NODES);}
    }
    assert_eq!(integer_cts::path(65535)[8],87380);65536
}
fn all_kt(errors:&mut ErrorAudit)->(u64,u64) {
    let mut checked=0;
    for a in 0..6u32 {for b in 0..6 {for c in 0..6 {for d in 0..6 {
        let raw=[a,b,c,d];let half=raw.map(|v|u64::from(v)*2+1);
        for prefix in 1..=4 {
            let actual=integer_cts::kt(raw,prefix).unwrap();assert_eq!(actual,half_kt(half,prefix));integer_cts::vector(actual,prefix).unwrap();checked+=1;
            let total=raw[..prefix].iter().map(|&v|f64::from(v)).sum::<f64>()+0.5*prefix as f64;
            for j in 0..prefix {let e=(actual[j] as f64/Q as f64-(f64::from(raw[j])+0.5)/total).abs();assert!(e<=2.0/Q as f64);errors.kt=errors.kt.max(e);errors.kt_comparisons+=1;}
            if prefix<4 {let mut changed=raw;changed[prefix]=CAP-raw[..prefix].iter().sum::<u32>();for item in &mut changed[prefix+1..] {*item=0;}assert_eq!(integer_cts::kt(changed,prefix).unwrap(),actual);}
        }
    }}}}
    assert_eq!(checked,5184);
    assert_eq!(integer_cts::kt([0;4],3).unwrap(),[1431655766,1431655765,1431655765,0]);
    assert_eq!(integer_cts::kt([CAP,0,0,0],4).unwrap(),[4294965612,562,561,561]);
    let mut caps=0;
    for prefix in 1..=4 {
        assert_eq!(integer_cts::kt([CAP,0,0,0],prefix).unwrap(),half_kt([u64::from(CAP)*2+1,1,1,1],prefix));caps+=1;
        assert!(integer_cts::kt([CAP,1,0,0],prefix).is_err());caps+=1;
    }(checked,caps)
}
fn fixtures()->u64 {
    for (prefix,expected_kt,expected_child,expected_mix,expected_post,expected_next) in [
        (4,[1879048192,805306368,1342177280,268435456],[536870912,536870912,2684354560,536870912],[872415232,603979776,2348810240,469762048],2312674697,2271376934),
        (2,[3006477107,1288490189,0,0],[2147483648,2147483648,0,0],[2362232013,1932735283,0,0],1366580503,1561806289),
    ] {
        let own=integer_cts::kt([3,1,2,0],prefix).unwrap();let child=integer_cts::kt([0,0,2,0],prefix).unwrap();
        let (mixed,mass)=integer_cts::mixture(Q/4,own,child,prefix).unwrap();
        assert_eq!(own,expected_kt);assert_eq!(child,expected_child);assert_eq!(mixed,expected_mix);
        assert_eq!(integer_cts::posterior_switch(Q/4,own[0],mass[0],7).unwrap(),(expected_post,536870912,expected_next));
        assert_eq!(switch_reference(SCALE/4,own[0],child[0],7),(expected_post,536870912,expected_next));
    }2
}
fn mixture_matrix(errors:&mut ErrorAudit)->(u64,u64) {
    let raw_cases=[[0;4],[3,1,2,0],[CAP-3,1,1,1]];let mut predictions=0;let mut updates=0;
    for weight in [0,1,Q/2,Q-1,Q] {for (index,&raw) in raw_cases.iter().enumerate() {
        let childraw=raw_cases[(index+1)%raw_cases.len()];
        for prefix in 1..=4 {
            let own=integer_cts::kt(raw,prefix).unwrap();let child=integer_cts::kt(childraw,prefix).unwrap();
            let (mixed,mass)=integer_cts::mixture(weight,own,child,prefix).unwrap();assert_eq!((mixed,mass),mixture_reference(weight,half_kt(raw.map(|v|u64::from(v)*2+1),prefix),half_kt(childraw.map(|v|u64::from(v)*2+1),prefix),prefix));predictions+=1;
            let mut kernel_raw=[[0;4];LEVELS];kernel_raw[0]=raw;kernel_raw[1]=childraw;
            let mut kernel_weights=[Q/2;LEVELS];kernel_weights[0]=weight;
            let kernel=integer_cts::predict_kernel(kernel_raw,kernel_weights,prefix,1).unwrap();
            assert_eq!(kernel.mixed[0],mixed);assert_eq!(kernel.masses[0],mass);
            errors.local_kernel(kernel_raw,kernel_weights,prefix,1,&kernel);
            for observed in 0..prefix {for after in [1,7,CAP] {
                let actual=integer_cts::posterior_switch(weight,own[observed],mass[observed],after).unwrap();
                assert_eq!(actual,switch_reference(weight,own[observed],child[observed],after));
                if after==1 {assert_eq!(actual.1,Q/2);assert_eq!(actual.2,Q/2);}
                errors.local_update(weight,own[observed],child[observed],after,actual);updates+=1;
            }}
        }
    }}assert_eq!(predictions,60);assert_eq!(updates,450);(predictions,updates)
}
fn small_depth_matrix(errors:&mut ErrorAudit)->(u64,u64) {
    let mut predictions=0;let mut updates=0;
    for depth in 0..=2 {for history in 0..4usize.pow(depth as u32) {
        let ids=integer_cts::path(history as u16);let reference_ids=independent_path(history as u64);assert_eq!(ids,reference_ids);
        let mut raw=[[0u32;4];LEVELS];let mut weights=[Q/2;LEVELS];let mut reference_half=[[1u64;4];LEVELS];let mut reference_weights=[SCALE/2;LEVELS];
        for level in 0..=depth {
            raw[level]=std::array::from_fn(|j|((ids[level]+level*3+j*5)%19) as u32);
            // oracle用fixtureも別pathから独立に生成する。
            reference_half[level]=std::array::from_fn(|j|(((reference_ids[level]+level*3+j*5)%19) as u64)*2+1);
            if level<depth {weights[level]=[0,1,Q/2,Q-1,Q][(history+level)%5];reference_weights[level]=[0,1,SCALE/2,SCALE-1,SCALE][(history+level)%5];}
        }
        for prefix in 1..=4 {
            let main=integer_cts::predict_kernel(raw,weights,prefix,depth).unwrap();
            let mut kt=[[0;4];LEVELS];for level in 0..=depth {kt[level]=half_kt(reference_half[level],prefix);}
            let mut mixed=[[0;4];LEVELS];let mut masses=[[0;4];LEVELS];recursive_reference(&kt,&reference_weights,prefix,0,depth,&mut mixed,&mut masses);
            assert_eq!(main.kt,kt);assert_eq!(main.mixed,mixed);assert_eq!(main.masses,masses);errors.local_kernel(raw,weights,prefix,depth,&main);predictions+=1;
            for observed in 0..prefix {
                let after=7;let next=integer_cts::update_kernel(&main,weights,prefix,observed,after).unwrap();let mut reference_next=[SCALE/2;LEVELS];
                for level in 0..depth {
                    reference_next[level]=switch_reference(reference_weights[level],kt[level][observed],mixed[level+1][observed],after).2;
                    let actual=integer_cts::posterior_switch(weights[level],main.kt[level][observed],main.masses[level][observed],after).unwrap();
                    errors.local_update(weights[level],main.kt[level][observed],main.mixed[level+1][observed],after,actual);
                }
                assert_eq!(next,reference_next);updates+=1;
            }
        }
    }}assert_eq!(predictions,84);assert_eq!(updates,210);(predictions,updates)
}
fn assert_same(a:&Cts,b:&Cts) {
    assert_eq!(a.nodes().len(),b.nodes().len());
    for (before,after) in a.nodes().iter().zip(b.nodes()) {assert_eq!(before.raw,after.raw);assert_eq!(before.weight,after.weight);}
    assert_eq!(a.histories(),b.histories());assert_eq!(a.observations(),b.observations());
}
fn rejection_cases()->(u64,u64) {
    let mut scalar=0;let mut state=0;
    for (mass,k) in [([0u128;4],4),([u128::MAX,1,0,0],2),([u128::MAX,0,0,0],1),([1,1,1,1],0),([1,1,1,1],5)] {
        assert!(integer_cts::normalize(mass,k).is_err());assert!(normalize_reference(mass,k).is_err());scalar+=1;
    }
    assert_eq!(integer_cts::normalize([1,0,0,0],4).unwrap(),[Q,0,0,0]);assert!(integer_cts::vector([Q,0,0,0],4).is_err());scalar+=1;
    for (own,child,w,k) in [([Q,0,0,0],[Q,0,0,0],Q+1,1),([0;4],[Q,0,0,0],Q/2,1),([Q,0,0,1],[Q,0,0,0],Q/2,1),([Q,0,0,0],[Q,0,0,0],Q/2,0)] {assert!(integer_cts::mixture(w,own,child,k).is_err());scalar+=1;}
    for (w,own,mass,after) in [(Q+1,1,1,1),(1,0,1,1),(1,Q+1,1,1),(1,1,0,1),(1,1,u128::MAX,1),(Q,Q,1,1),(1,1,1,0),(1,1,1,CAP+1)] {assert!(integer_cts::posterior_switch(w,own,mass,after).is_err());scalar+=1;}
    let mut model=Cts::new().unwrap();let before=model.clone();
    for (class,k) in [(6,4),(0,0),(0,5)] {assert!(model.predict(class,k).is_err());assert_same(&before,&model);state+=1;}
    let s=model.predict(0,4).unwrap();
    assert!(model.observe(&s,4).is_err());assert_same(&before,&model);state+=1;
    for mode in 0..9 {
        let mut changed=s.clone();
        match mode {
            0=>changed.class=6,1=>changed.prefix=0,2=>changed.prefix=5,3=>changed.ids[8]=usize::MAX,
            4=>changed.history=1,5=>changed.observations=1,6=>changed.raw[3][0]=1,
            7=>changed.weights[0]=Q+1,_=>changed.kernel.masses[0][0]=u128::MAX,
        }
        assert!(model.observe(&changed,0).is_err());assert_same(&before,&model);state+=1;
    }
    model.observe(&s,3).unwrap();let before=model.clone();assert!(model.observe(&s,3).is_err());assert_same(&before,&model);state+=1;
    model.audit_seed_class(0,0,CAP);let s=model.predict(0,4).unwrap();let before=model.clone();
    assert!(model.observe(&s,0).is_err());assert_same(&before,&model);state+=1;
    model.audit_seed_class(0,0,CAP+1);let before=model.clone();assert!(model.predict(0,4).is_err());assert!(model.observe(&s,0).is_err());assert_same(&before,&model);state+=1;
    model.audit_seed_class(0,0,0);model.audit_seed_node(0,0,[CAP,0,0,0],Q/2);let s=model.predict(0,4).unwrap();let before=model.clone();
    assert!(model.observe(&s,0).is_err());assert_same(&before,&model);state+=1;
    model.audit_seed_node(0,0,[CAP,1,0,0],Q/2);let before=model.clone();assert!(model.predict(0,1).is_err());assert!(model.observe(&s,0).is_err());assert_same(&before,&model);state+=1;
    model.audit_seed_node(0,0,[u32::MAX;4],Q/2);let before=model.clone();assert!(model.predict(0,4).is_err());assert!(model.observe(&s,0).is_err());assert_same(&before,&model);state+=1;
    model.audit_seed_node(0,0,[0;4],u64::MAX);let before=model.clone();assert!(model.predict(0,4).is_err());assert!(model.observe(&s,0).is_err());assert_same(&before,&model);state+=1;
    model.audit_seed_node(0,0,[0;4],Q/2);model.audit_seed_node(0,integer_cts::path(0)[8],[0;4],0);let before=model.clone();assert!(model.predict(0,4).is_err());assert!(model.observe(&s,0).is_err());assert_same(&before,&model);state+=1;
    // class cap直前の成功と、その次の拒否を実入口で確認。
    let mut boundary=Cts::new().unwrap();boundary.audit_seed_class(0,65535,CAP-1);
    for &id in &integer_cts::path(65535) {boundary.audit_seed_node(0,id,[CAP-1,0,0,0],Q/2);}
    let s=boundary.predict(0,1).unwrap();boundary.observe(&s,0).unwrap();assert_eq!(boundary.observations()[0],CAP);assert_eq!(boundary.histories()[0],65532);
    let next=boundary.predict(0,1).unwrap();let before=boundary.clone();assert!(boundary.observe(&next,0).is_err());assert_same(&before,&boundary);state+=1;
    assert_eq!(scalar,18);assert_eq!(state,22);(scalar,state)
}
fn series(errors:&mut ErrorAudit)->(u64,u64,[u32;CLASSES]) {
    let mut main=Cts::new().unwrap();let mut oracle=Reference::new();let mut checked=0;
    for step in 0..64 {
        for class in 0..CLASSES {
            let prefix=if class==4 {1}else if class==5 {step%4+1}else {4};
            let child=match class {0=>0,1=>3,2=>if step%2==0 {0}else {3},3=>step%4,4=>0,_=>(step/4)%prefix};
            let a=main.predict(class,prefix).unwrap();let b=oracle.predict(class,prefix);compare_snapshot(&a,&b);
            errors.local_kernel(a.raw,a.weights,prefix,8,&a.kernel);
            for level in 0..8 {
                let actual=integer_cts::posterior_switch(a.weights[level],a.kernel.kt[level][child],a.kernel.masses[level][child],a.observations+1).unwrap();
                errors.local_update(a.weights[level],a.kernel.kt[level][child],a.kernel.mixed[level+1][child],a.observations+1,actual);
            }
            let other_history=main.histories();let other_seen=main.observations();
            main.observe(&a,child).unwrap();oracle.observe(&b,child);
            for c in 0..CLASSES {
                assert_eq!(u64::from(main.histories()[c]),oracle.histories[c]);assert_eq!(u64::from(main.observations()[c]),oracle.seen[c]);
                if c!=class {assert_eq!(main.histories()[c],other_history[c]);assert_eq!(main.observations()[c],other_seen[c]);}
            }
            for &id in &a.ids {
                let n=main.nodes()[class*NODES+id];assert_eq!(n.raw.map(|v|u64::from(v)*2+1),oracle.halves[class*NODES+id]);assert_eq!(n.weight,oracle.weights[class*NODES+id]);
            }checked+=1;
        }
    }
    assert_eq!(checked,384);assert_eq!(main.observations(),[64;CLASSES]);assert_eq!(main.histories()[1],65535);
    let mut values=0;
    assert_eq!(main.nodes().len(),oracle.halves.len());assert_eq!(main.nodes().len(),oracle.weights.len());
    for (id,node) in main.nodes().iter().enumerate() {
        for j in 0..4 {assert_eq!(u64::from(node.raw[j])*2+1,oracle.halves[id][j]);values+=1;}
        assert_eq!(node.weight,oracle.weights[id]);assert!(node.weight<=Q);values+=1;
    }
    for c in 0..CLASSES {assert_eq!(u64::from(main.histories()[c]),oracle.histories[c]);assert_eq!(u64::from(main.observations()[c]),oracle.seen[c]);values+=2;}
    assert_eq!(values,(main.nodes().len()*5+main.histories().len()+main.observations().len()) as u64);assert_eq!(values,2621442);
    (checked,values,main.observations())
}
fn main() {
    if std::env::args_os().len()!=1 {eprintln!("usage: primitive-audit");std::process::exit(2);}
    assert_eq!(Q,SCALE);assert_eq!(CLASSES,6);assert_eq!(LEVELS,9);assert_eq!(NODES,87381);
    let mut errors=ErrorAudit::default();let path_cases=all_paths();let (kt_cases,kt_cap_cases)=all_kt(&mut errors);let biginteger_fixtures=fixtures();
    let (mixture_predictions,mixture_updates)=mixture_matrix(&mut errors);let (small_depth_predictions,small_depth_updates)=small_depth_matrix(&mut errors);
    let (scalar_rejections,state_rejections)=rejection_cases();let (series_branches,state_values_checked,class_observations)=series(&mut errors);
    println!("{{\"status\":\"passed\",\"diagnostic_only\":true,\"integer_primitive_only\":true,\"wire_size_speed_verified\":false,\"integer_pool_verified\":false,\"opportunity_gate_evaluated\":false,\"full_benchmark_allowed\":false,\"f64_continuous_trajectory_verified\":false,\"Q\":{Q},\"classes\":{CLASSES},\"levels\":{LEVELS},\"nodes_per_class\":{NODES},\"observation_cap\":{CAP},\"path_cases\":{path_cases},\"path_levels_checked\":{},\"maximum_heap_index\":87380,\"kt_cases\":{kt_cases},\"kt_cap_cases\":{kt_cap_cases},\"bigint_fixtures\":{biginteger_fixtures},\"mixture_predictions\":{mixture_predictions},\"mixture_updates\":{mixture_updates},\"small_depth_predictions\":{small_depth_predictions},\"small_depth_updates\":{small_depth_updates},\"scalar_rejections\":{scalar_rejections},\"state_rejections\":{state_rejections},\"rejection_state_direct_comparison\":true,\"series_branches\":{series_branches},\"series_node_updates\":{},\"class_observations\":{:?},\"state_values_checked\":{state_values_checked},\"max_local_kt_error\":{},\"max_local_recursive_mix_error\":{},\"max_local_q32_rawmass_posterior_error\":{},\"max_local_q32_rawmass_switch_error\":{},\"kt_error_comparisons\":{},\"recursive_mix_error_comparisons\":{},\"q32_rawmass_update_error_comparisons\":{},\"local_kt_bound\":{},\"local_max_depth_mix_bound\":{},\"local_q32_rawmass_update_bound\":{},\"legacy_f64_tolerance\":2e-10,\"local_error_scope\":\"KT and recursive mix use same raw counts and Q32 weights; posterior and switch use already quantized KT and child mixed for one update only\"}}",path_cases*9,series_branches*9,class_observations,errors.kt,errors.mixed,errors.posterior,errors.switch,errors.kt_comparisons,errors.mixed_comparisons,errors.update_comparisons,2.0/Q as f64,18.0/Q as f64,4.0/Q as f64);
}

