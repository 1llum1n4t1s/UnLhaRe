//! 凍結旧q32 kernel/depth CTSを独立oracleにしたAlpha全Result/全state比較。
use crate::{reference_cts as old,alpha_kernel as new,baseline_cts as baseline,new_cts as candidate};
use old::{Q,CAP,LEVELS,Kernel};
type Result<T>=crate::Result<T>;
#[derive(Default)]
struct Counts {normal:usize,entry:usize,switch:usize,multilevel:usize,pairs:usize,success:usize,reject:usize,snapshots:usize,state:usize,pure:usize}
fn compare(s:&Kernel,weights:[u64;LEVELS],k:usize,child:usize,after:u32,expected:Option<&str>)->Result<()>{
    let a=old::update_kernel(s,weights,k,child,after);let b=new::update_kernel(s,weights,k,child,after);
    if a!=b{return Err("Alpha Kernel all Result/Err mismatch".into());}
    match expected {None=>if a.is_err(){return Err("Alpha legal Kernel rejected".into());},
        Some(reason)=>if a.err()!=Some(reason){return Err(format!("Alpha rejection exact reason: {reason}"));}}
    Ok(())
}
fn legal(depth:usize,k:usize,weight:u64)->Result<(Kernel,[u64;LEVELS])>{
    let raw=std::array::from_fn(|l|std::array::from_fn(|j|((l+3)*(j+5)) as u32));
    let mut weights=[weight;LEVELS];weights[depth]=Q/2;
    let kernel=old::predict_kernel(raw,weights,k,depth).map_err(str::to_owned)?;Ok((kernel,weights))
}
fn kernels(c:&mut Counts)->Result<()> {
    for depth in 0..LEVELS {for k in 1..=4 {for child in 0..k {for after in [1,CAP] {for weight in [0,Q/2,Q] {
        let(s,w)=legal(depth,k,weight)?;compare(&s,w,k,child,after,None)?;c.normal+=1;
    }}}}}
    for depth in [0,5,8] {
        for k in 1..=4 {for child in 0..k {for after in [0,CAP+1,u32::MAX] {
            let(s,w)=legal(depth,k,Q/2)?;compare(&s,w,k,child,after,Some("invalid kernel update"))?;c.entry+=1;
        }}}
        let(s,w)=legal(depth,4,Q/2)?;
        for k in [0,5,usize::MAX] {for after in [0,1,CAP+1] {compare(&s,w,k,0,after,Some("invalid prefix"))?;c.entry+=1;}}
        for k in 1..=4 {for after in [0,1,CAP+1] {
            let(s,w)=legal(depth,k,Q/2)?;compare(&s,w,k,k,after,Some("invalid kernel update"))?;c.entry+=1;
        }}
        for k in 1..=4 {for leaf in [Q/2-1,Q/2+1] {for after in [1,CAP] {
            let(s,mut w)=legal(depth,k,Q/2)?;w[depth]=leaf;compare(&s,w,k,0,after,Some("invalid kernel update"))?;c.entry+=1;
        }}}
    }
    for depth in [LEVELS,usize::MAX] {for k in 1..=4 {for after in [0,1,CAP+1] {
        let(mut s,w)=legal(8,k,Q/2)?;s.depth=depth;compare(&s,w,k,0,after,Some("invalid kernel update"))?;c.entry+=1;
    }}}
    for after in [1,CAP] {for level in 0..8 {for tamper in 0..6 {
        let(mut s,mut w)=legal(8,4,Q/2)?;let ownmass=u128::from(w[level])*u128::from(s.kt[level][0]);
        match tamper {0=>w[level]=Q+1,1=>s.kt[level][0]=0,2=>s.kt[level][0]=Q+1,
            3=>s.masses[level][0]=0,4=>s.masses[level][0]=ownmass-1,
            _=>s.masses[level][0]=u128::from(Q)*u128::from(Q)+1}
        compare(&s,w,4,0,after,Some(if tamper<4{"invalid switch input"}else{"posterior denominator outside mixture"}))?;c.switch+=1;
    }}}
    for after in [1,CAP] {for (first,second,invalid_first) in [(0,7,true),(0,7,false),(2,5,false),(2,5,true)] {
        let(mut s,mut w)=legal(8,4,Q/2)?;
        if invalid_first {w[first]=Q+1;s.masses[second][0]=u128::from(w[second])*u128::from(s.kt[second][0])-1;}
        else {s.masses[first][0]=u128::from(w[first])*u128::from(s.kt[first][0])-1;w[second]=Q+1;}
        compare(&s,w,4,0,after,Some(if invalid_first{"invalid switch input"}else{"posterior denominator outside mixture"}))?;c.multilevel+=1;
    }}
    if c.normal!=540||c.entry!=225||c.switch!=96||c.multilevel!=8{return Err("Alpha kernel fixed counts".into());}Ok(())
}
fn state(a:&baseline::Cts,b:&candidate::Cts,c:&mut Counts)->Result<()> {
    if a.depth()!=b.depth()||a.node_count()!=b.node_count()||a.nodes()!=b.nodes()||a.histories()!=b.histories()||a.observations()!=b.observations(){return Err("Alpha all CTS state mismatch".into());}c.state+=1;Ok(())
}
fn snapshot(a:&baseline::Snapshot,b:&candidate::Snapshot,c:&mut Counts)->Result<()> {
    if a.class!=b.class||a.prefix!=b.prefix||a.ids!=b.ids||a.history!=b.history||a.observations!=b.observations||a.raw!=b.raw||a.weights!=b.weights||a.kernel!=b.kernel{return Err("Alpha public Snapshot all fields mismatch".into());}c.snapshots+=1;Ok(())
}
fn reject(a:&mut baseline::Cts,b:&mut candidate::Cts,sa:&baseline::Snapshot,sb:&candidate::Snapshot,child:usize,reason:&str,c:&mut Counts)->Result<()> {
    state(a,b,c)?;let before_a=a.clone();let before_b=b.clone();
    let ra=a.observe(sa,child);let rb=b.observe(sb,child);
    if ra!=rb||ra.err()!=Some(reason){return Err(format!("Alpha depth0 refusal reason {reason}"));}
    if *a!=before_a||*b!=before_b{return Err("Alpha refusal changed full state".into());}
    state(a,b,c)?;c.reject+=1;Ok(())
}
fn depth_zero(c:&mut Counts)->Result<()> {
    for class in 0..6 {for k in 1..=4 {
        let mut a=baseline::Cts::new(0).map_err(str::to_owned)?;let mut b=candidate::Cts::new(0).map_err(str::to_owned)?;c.pairs+=1;
        state(&a,&b,c)?;
        let mut stale=None;
        for _ in 0..2 {for child in 0..k {
            let before_a=a.clone();let before_b=b.clone();
            let sa=a.predict(class,k).map_err(str::to_owned)?;let sb=b.predict(class,k).map_err(str::to_owned)?;snapshot(&sa,&sb,c)?;
            let pa=a.predict(class,k).map_err(str::to_owned)?;let pb=b.predict(class,k).map_err(str::to_owned)?;snapshot(&pa,&pb,c)?;
            if sa!=pa||sb!=pb||a!=before_a||b!=before_b{return Err("Alpha pure predict/state changed".into());}c.pure+=1;state(&a,&b,c)?;
            if stale.is_none(){stale=Some((sa.clone(),sb.clone()));}
            let ra=a.observe(&sa,child);let rb=b.observe(&sb,child);
            if ra!=rb||ra.is_err(){return Err("Alpha depth0 legal observe mismatch".into());}c.success+=1;state(&a,&b,c)?;
        }}
        let sa=a.predict(class,k).map_err(str::to_owned)?;let sb=b.predict(class,k).map_err(str::to_owned)?;snapshot(&sa,&sb,c)?;
        reject(&mut a,&mut b,&sa,&sb,k,"invalid observation",c)?;
        let(mut ta,mut tb)=(sa.clone(),sb.clone());ta.prefix=0;tb.prefix=0;reject(&mut a,&mut b,&ta,&tb,0,"invalid prefix",c)?;
        let(ta,tb)=stale.ok_or("Alpha missing stale token")?;reject(&mut a,&mut b,&ta,&tb,0,"stale or modified snapshot",c)?;
        let(mut ta,mut tb)=(sa.clone(),sb.clone());ta.kernel.kt[0][0]^=1;tb.kernel.kt[0][0]^=1;
        reject(&mut a,&mut b,&ta,&tb,0,"stale or modified snapshot",c)?;
        // audit専用seedで後段node capを作る。depth0小stateだけcloneする。
        a.audit_seed_class(class,0,0);b.audit_seed_class(class,0,0);
        a.audit_seed_node(class,0,[CAP,0,0,0],Q/2);b.audit_seed_node(class,0,[CAP,0,0,0],Q/2);
        let ta=a.predict(class,k).map_err(str::to_owned)?;let tb=b.predict(class,k).map_err(str::to_owned)?;snapshot(&ta,&tb,c)?;
        reject(&mut a,&mut b,&ta,&tb,0,"node update cap",c)?;
        a.audit_seed_class(class,0,CAP);b.audit_seed_class(class,0,CAP);
        let ta=a.predict(class,k).map_err(str::to_owned)?;let tb=b.predict(class,k).map_err(str::to_owned)?;snapshot(&ta,&tb,c)?;
        reject(&mut a,&mut b,&ta,&tb,0,"class update cap",c)?;
    }}
    if c.pairs!=24||c.success!=120||c.reject!=144||c.pure!=120||c.snapshots!=312||c.state!=552{return Err("Alpha depth0 fixed counts".into());}Ok(())
}
pub(crate) fn run()->Result<()> {
    let mut c=Counts::default();kernels(&mut c)?;depth_zero(&mut c)?;
    println!("{{\"status\":\"passed\",\"operation\":\"compare-alpha\",\"kernel_cases\":869,\"kernel_normal_cases\":540,\"kernel_rejection_cases\":329,\"kernel_entry_rejections\":225,\"kernel_switch_rejections\":96,\"kernel_multilevel_rejections\":8,\"depth0_pairs\":24,\"depth0_success_observes\":120,\"depth0_rejections\":144,\"pure_prediction_cases\":120,\"public_snapshot_comparisons\":312,\"all_state_comparisons\":552,\"refusal_before_after_state_comparisons\":288,\"proof_method\":\"independent frozen kernel Result/Err; all public Snapshot fields and full nodes/history/observations\",\"diagnostic_only\":true,\"local_timing_added\":false}}");Ok(())
}
