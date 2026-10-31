//! 固定loopのstandalone E2E。全Result/全Snapshot/全stateを直接比較する。
use crate::{new_cts as c,oracle as o,integer_pool as p,fixed_math::Math};
use c::{Q,CAP,LEVELS};
use std::collections::BTreeMap;
type Result<T>=crate::Result<T>;
const EXPECTED:&[(&str,usize)]=&[
    ("V-valid",4),("V-invalid",16),("KT-heavy",40),("KT-tie",12),("KT-inactive",12),("KT-allraw",8),("KT-prefix",3),
    ("MIX-valid",50),("MIX-invalid",8),("SWITCH-valid",135),("SWITCH-invalid",9),("SWITCH-priority",3),("analytic-cts",7),
    ("K-normal",1350),("K-entry",225),("K-switch",240),("K-priority",20),("K-empty",50),
    ("CTS-constructor",11),("CTS-stream",1080),("CTS-token",2160),("CTS-foreign",216),("CTS-same-state",216),("CTS-rebased",216),
    ("CTS-CAP",162),("CTS-node-atomic",54),("CTS-current",216),("CTS-nonleaf",48),("CTS-inactive-raw",108),("CTS-level-priority",96),("CTS-class-prefix",27),
    ("POOL-predict",350),("POOL-learn",1000),("POOL-count-bad",32),("POOL-cts-bad",16),("POOL-weight-bad",40),("POOL-prefix-bad",3),
    ("POOL-normalize",12),("POOL-normalize-bad",27),("POOL-smooth-prefix",3),("POOL-score",80),("POOL-feature",200),("POOL-feature-inactive",30),("POOL-feature-huge",100),
    ("POOL-q0",20),("POOL-observe-priority",20),("MATH-connect",6),("EXP-domain",8),("SIGNED-golden",4),("analytic-pool",1),
];
#[derive(Default)] struct Audit{counts:BTreeMap<&'static str,usize>,pure:usize,snapshots:usize,stream_state:usize,reject:usize,success:usize,refusal_cross:usize,phase:&'static str,context:String}
impl Audit{
    fn case<T:PartialEq+std::fmt::Debug>(&mut self,id:&'static str,input:&str,a:std::result::Result<T,&'static str>,b:std::result::Result<T,&'static str>,reason:Option<&str>)->Result<()>{
        let n=*self.counts.get(id).unwrap_or(&0);
        self.context=format!("loop={id} index={n} recipe={input}");
        if a!=b||match reason{Some(e)=>a.as_ref().err().copied()!=Some(e),None=>a.is_err()}{let ca=format!("{a:?}");let ob=format!("{b:?}");let first=if ca!=ob{Some(ca.bytes().zip(ob.bytes()).position(|(x,y)|x!=y).unwrap_or(ca.len().min(ob.len())))}else{None};return Err(format!("loop={id} index={n} recipe={input} first_debug_byte={first:?} expected_error={reason:?} candidate={ca} oracle={ob}"));}
        *self.counts.entry(id).or_default()+=1;Ok(())
    }
    fn golden(&mut self,id:&'static str,ok:bool,input:&str)->Result<()>{let n=*self.counts.get(id).unwrap_or(&0);self.context=format!("loop={id} index={n} recipe={input}");if !ok{return Err(format!("loop={id} index={n} recipe={input} first_field=analytic_assertion expected=true actual=false"));}*self.counts.entry(id).or_default()+=1;Ok(())}
}
fn bal(k:usize)->[u64;4]{let mut v=[0;4];for j in 0..k{v[j]=Q/k as u64+u64::from(j<(Q%k as u64)as usize);}v}
fn spike(k:usize,h:usize)->[u64;4]{let mut v=[0;4];v[..k].fill(1);v[h]=Q-k as u64+1;v}
fn vk(s:&c::Kernel)->o::Kernel{o::Kernel{kt:s.kt,mixed:s.mixed,masses:s.masses.map(|r|r.map(u128::from)),depth:s.depth}}
fn vs(s:&c::Snapshot)->o::Snapshot{o::Snapshot{class:s.class,prefix:s.prefix,ids:s.ids,history:s.history,observations:s.observations,raw:s.raw,weights:s.weights,kernel:vk(&s.kernel)}}
fn vp(s:&p::Prediction)->o::Prediction{o::Prediction{prefix:s.prefix,weights:s.weights,features:s.features,scores:s.scores,q:s.q,p:s.p,frequencies:s.frequencies,cumulative:s.cumulative}}
fn vu(s:p::Update)->o::Update{o::Update{factor:s.factor,expected:s.expected,gradient:s.gradient,delta:s.delta,next:s.next}}
fn state(a:&c::Cts,b:&o::Cts)->Result<()>{
    macro_rules! field{($f:ident)=>{if a.$f()!=b.$f(){return Err(format!("full CTS field={} depth={} candidate={:?} oracle={:?}",stringify!($f),a.depth(),a.$f(),b.$f()));}}}
    field!(depth);field!(node_count);
    if a.nodes().len()!=b.nodes().len(){return Err(format!("full CTS field=nodes.len candidate={} oracle={}",a.nodes().len(),b.nodes().len()));}
    field!(histories);field!(observations);
    for (i,(x,y)) in a.nodes().iter().zip(b.nodes()).enumerate(){for j in 0..4{if x.raw[j]!=y.raw[j]{return Err(format!("full CTS node={i} child={j} field=raw candidate={} oracle={}",x.raw[j],y.raw[j]));}}if x.weight!=y.weight{return Err(format!("full CTS node={i} field=weight candidate={} oracle={}",x.weight,y.weight));}}Ok(())
}
fn snap(a:&c::Snapshot,b:&o::Snapshot)->Result<()>{
    macro_rules! field{($f:ident)=>{if a.$f!=b.$f{return Err(format!("Snapshot field={} class={} prefix={} candidate={:?} oracle={:?}",stringify!($f),a.class,a.prefix,a.$f,b.$f));}}}
    field!(class);field!(prefix);field!(ids);field!(history);field!(observations);field!(raw);field!(weights);
    if a.kernel.depth!=b.kernel.depth{return Err(format!("Snapshot kernel.depth candidate={} oracle={}",a.kernel.depth,b.kernel.depth));}
    for l in 0..LEVELS{for j in 0..4{if a.kernel.kt[l][j]!=b.kernel.kt[l][j]||a.kernel.mixed[l][j]!=b.kernel.mixed[l][j]||u128::from(a.kernel.masses[l][j])!=b.kernel.masses[l][j]{return Err(format!("Snapshot kernel level={l} child={j} candidate=(kt={},mixed={},mass={}) oracle=(kt={},mixed={},mass={})",a.kernel.kt[l][j],a.kernel.mixed[l][j],a.kernel.masses[l][j],b.kernel.kt[l][j],b.kernel.mixed[l][j],b.kernel.masses[l][j]));}}}Ok(())
}
fn kr(d:usize,k:usize,w:u64)->(c::Kernel,o::Kernel,[u64;LEVELS]){
    let raw=std::array::from_fn(|l|std::array::from_fn(|j|((l+3)*(j+5))as u32));let mut weights=[w;LEVELS];weights[d]=Q/2;
    (c::predict_kernel(raw,weights,k,d).expect("fixed legal kernel"),o::predict_kernel(raw,weights,k,d).expect("fixed legal reference kernel"),weights)
}
fn primitives(a:&mut Audit)->Result<()>{
    for k in 1..=4{
        a.case("V-valid",&format!("k={k}"),c::vector(bal(k),k),o::vector(bal(k),k),None)?;
        for t in 0..4{let mut v=bal(k);match t{0=>v[0]=0,1=>v[0]=Q+1,2=>v[0]-=1,_=>v[0]+=1};let e=if t<2||(k==1&&t==3){"invalid categorical vector"}else{"vector sum differs from Q"};a.case("V-invalid",&format!("k={k} v={v:?}"),c::vector(v,k),o::vector(v,k),Some(e))?;}
        for h in 0..k{for r in [Q-2,Q-1,Q,u64::from(CAP)]{let mut raw=[0;4];raw[h]=r as u32;a.case("KT-heavy",&format!("k={k} raw={raw:?}"),c::kt(raw,k),o::kt(raw,k),None)?;}}
        for t in [0,1,Q/8]{let raw=[t as u32;4];a.case("KT-tie",&format!("k={k} raw={raw:?}"),c::kt(raw,k),o::kt(raw,k),None)?;}
        for h in k..4{for r in [CAP,CAP+1]{let mut raw=[0;4];raw[h]=r;a.case("KT-inactive",&format!("k={k} raw={raw:?}"),c::kt(raw,k),o::kt(raw,k),if r>CAP{Some("raw observation cap")}else{None})?;}}
        for raw in [[CAP-3,1,1,1],[CAP-2,1,1,1]]{a.case("KT-allraw",&format!("k={k} raw={raw:?}"),c::kt(raw,k),o::kt(raw,k),if raw[0]==CAP-2{Some("raw observation cap")}else{None})?;}
        for h in 0..k{for w in [0,1,Q/2,Q-1,Q]{let x=bal(k);let y=spike(k,h);a.case("MIX-valid",&format!("k={k} h={h} w={w}"),c::mixture(w,x,y,k).map(|(v,m)|(v,m.map(u128::from))),o::mixture(w,x,y,k),None)?;}}
    }
    for k in [0,5,usize::MAX]{a.case("KT-prefix",&format!("k={k}"),c::kt([u32::MAX;4],k),o::kt([u32::MAX;4],k),Some("invalid prefix"))?;}
    for w in [Q+1,u64::MAX]{a.case("MIX-invalid",&format!("w={w} k=0"),c::mixture(w,[0;4],[0;4],0).map(|(v,m)|(v,m.map(u128::from))),o::mixture(w,[0;4],[0;4],0),Some("weight outside Q"))?;}
    for side in 0..2{for t in 0..3{let mut x=bal(2);match t{0=>x[0]=0,1=>x[2]=1,_=>x[0]-=1};let (own,child)=if side==0{(x,bal(2))}else{(bal(2),x)};a.case("MIX-invalid",&format!("side={side} t={t}"),c::mixture(Q/2,own,child,2).map(|(v,m)|(v,m.map(u128::from))),o::mixture(Q/2,own,child,2),Some(if t<2{"invalid categorical vector"}else{"vector sum differs from Q"}))?;}}
    for after in [1,Q as u32-1,Q as u32,Q as u32+1,CAP]{for w in [0,Q/2,Q]{for own in [1,Q/2,Q]{let lo=(w*own).max(1);for m in [lo,lo+(Q*Q-lo)/2,Q*Q]{a.case("SWITCH-valid",&format!("after={after} w={w} own={own} m={m}"),c::posterior_switch(w,own,m,after),o::posterior_switch(w,own,u128::from(m),after),None)?;}}}}
    let base=(Q/2,Q/2,Q*Q/2,1);let bad=[(base.0,base.1,base.2,0),(base.0,base.1,base.2,CAP+1),(base.0,base.1,base.2,u32::MAX),(Q+1,base.1,base.2,1),(base.0,0,base.2,1),(base.0,Q+1,base.2,1),(base.0,base.1,0,1),(base.0,base.1,Q*Q/4-1,1),(base.0,base.1,Q*Q+1,1)];
    for (i,(w,x,m,n)) in bad.into_iter().enumerate(){a.case("SWITCH-invalid",&format!("w={w} own={x} m={m} after={n}"),c::posterior_switch(w,x,m,n),o::posterior_switch(w,x,u128::from(m),n),Some(if i<7{"invalid switch input"}else{"posterior denominator outside mixture"}))?;}
    for (w,x,m,n) in [(Q+1,1,Q*Q+1,1),(1,0,1,0),(1,1,0,CAP+1)]{a.case("SWITCH-priority",&format!("{w},{x},{m},{n}"),c::posterior_switch(w,x,m,n),o::posterior_switch(w,x,u128::from(m),n),Some("invalid switch input"))?;}
    // 同じpolicyの共通誤りは独立に計算したgoldenで検出する。
    a.golden("analytic-cts",c::kt([Q as u32-1,0,0,0],2)==Ok([Q-1,1,0,0])&&c::vector([Q,0,0,0],2).is_err(),"naive KT zero / reserve1")?;
    a.golden("analytic-cts",c::kt([0;4],3)==Ok([699051,699051,699050,0]),"uniform tie3")?;
    a.golden("analytic-cts",c::kt([CAP,0,0,0],4)==Ok([2097148,2,1,1]),"CAP heavy4")?;
    a.golden("analytic-cts",Q/(Q+1)==0&&c::posterior_switch(Q,Q,Q*Q,Q as u32)==Ok((Q,1,Q-1)),"afterQ alpha1")?;
    a.golden("analytic-cts",c::posterior_switch(0,1,1,CAP)==Ok((0,1,1)),"afterCAP endpoint0")?;
    a.golden("analytic-cts",c::kt([CAP,0,0,0],1)==Ok([Q,0,0,0])&&c::mixture(0,[Q,0,0,0],[Q,0,0,0],1)==Ok(([Q,0,0,0],[Q*Q,0,0,0])),"prefix1")?;
    a.golden("analytic-cts",c::posterior_switch(0,1,1,1)==Ok((0,Q/2,Q/2))&&c::posterior_switch(Q,Q,Q*Q,1)==Ok((Q,Q/2,Q/2)),"after1 retained0")?;Ok(())
}
fn kernel_case(a:&mut Audit,id:&'static str,s:&c::Kernel,r:&o::Kernel,w:[u64;LEVELS],k:usize,j:usize,n:u32,e:Option<&str>)->Result<()>{a.case(id,&format!("depth={} k={k} child={j} after={n} weights={w:?} kt={:?} masses={:?}",s.depth,s.kt,s.masses),c::update_kernel(s,w,k,j,n),o::update_kernel(r,w,k,j,n),e)}
fn kernels(a:&mut Audit)->Result<()>{
    for d in 0..LEVELS{for k in 1..=4{for j in 0..k{for n in [1,Q as u32-1,Q as u32,Q as u32+1,CAP]{for w in [0,Q/2,Q]{let(s,r,ww)=kr(d,k,w);if vk(&s)!=r{return Err("predict_kernel all fields differ".into());}kernel_case(a,"K-normal",&s,&r,ww,k,j,n,None)?;}}}}}
    for d in [0,5,8]{
        for k in 1..=4{for j in 0..k{for n in [0,CAP+1,u32::MAX]{let(s,r,w)=kr(d,k,Q/2);kernel_case(a,"K-entry",&s,&r,w,k,j,n,Some("invalid kernel update"))?;}}}
        let(s,r,w)=kr(d,4,Q/2);for k in [0,5,usize::MAX]{for n in [0,1,CAP+1]{kernel_case(a,"K-entry",&s,&r,w,k,0,n,Some("invalid prefix"))?;}}
        for k in 1..=4{for n in [0,1,CAP+1]{let(s,r,w)=kr(d,k,Q/2);kernel_case(a,"K-entry",&s,&r,w,k,k,n,Some("invalid kernel update"))?;}}
        for k in 1..=4{for leaf in [Q/2-1,Q/2+1]{for n in [1,CAP]{let(s,r,mut w)=kr(d,k,Q/2);w[d]=leaf;kernel_case(a,"K-entry",&s,&r,w,k,0,n,Some("invalid kernel update"))?;}}}
    }
    for d in [LEVELS,usize::MAX]{for k in 1..=4{for n in [0,1,CAP+1]{let(mut s,mut r,w)=kr(8,k,Q/2);s.depth=d;r.depth=d;kernel_case(a,"K-entry",&s,&r,w,k,0,n,Some("invalid kernel update"))?;}}}
    for n in [1,Q as u32-1,Q as u32,Q as u32+1,CAP]{for l in 0..8{for t in 0..6{let(mut s,_,mut w)=kr(8,4,Q/2);let ownmass=w[l]*s.kt[l][0];match t{0=>w[l]=Q+1,1=>s.kt[l][0]=0,2=>s.kt[l][0]=Q+1,3=>s.masses[l][0]=0,4=>s.masses[l][0]=ownmass-1,_=>s.masses[l][0]=Q*Q+1};let r=vk(&s);kernel_case(a,"K-switch",&s,&r,w,4,0,n,Some(if t<4{"invalid switch input"}else{"posterior denominator outside mixture"}))?;}}
        for (first,second,invalid_first) in [(0,7,true),(0,7,false),(2,5,false),(2,5,true)]{let(mut s,_,mut w)=kr(8,4,Q/2);if invalid_first{w[first]=Q+1;s.masses[second][0]=w[second]*s.kt[second][0]-1;}else{s.masses[first][0]=w[first]*s.kt[first][0]-1;w[second]=Q+1;}let r=vk(&s);kernel_case(a,"K-priority",&s,&r,w,4,0,n,Some(if invalid_first{"invalid switch input"}else{"posterior denominator outside mixture"}))?;}
        for k in 1..=4{for j in 0..k{let(mut s,_,mut w)=kr(0,k,Q/2);s.kt=[[u64::MAX;4];LEVELS];s.mixed=s.kt;s.masses=s.kt;w[1..].fill(Q+1);let r=vk(&s);kernel_case(a,"K-empty",&s,&r,w,k,j,n,None)?;if c::update_kernel(&s,w,k,j,n)!=Ok([Q/2;LEVELS]){return Err("depth0 reads unused derived fields".into());}}}
    }Ok(())
}
fn pair(d:usize)->Result<(c::Cts,o::Cts)>{Ok((c::Cts::new(d).map_err(str::to_owned)?,o::Cts::new(d).map_err(str::to_owned)?))}
fn token(x:&c::Cts,y:&o::Cts,class:usize,k:usize)->Result<(c::Snapshot,o::Snapshot)>{let s=x.predict(class,k).map_err(str::to_owned)?;let r=y.predict(class,k).map_err(str::to_owned)?;snap(&s,&r)?;Ok((s,r))}
fn reject(a:&mut Audit,id:&'static str,x:&mut c::Cts,y:&mut o::Cts,s:&c::Snapshot,r:&o::Snapshot,j:usize,e:&str)->Result<()>{
    state(x,y)?;a.refusal_cross+=1;let before_x=x.clone();let before_y=y.clone();
    a.case(id,&format!("depth={} class={} prefix={} child={j} history={} obs={} token={:?}",x.depth(),s.class,s.prefix,s.history,s.observations,vs(s)),x.observe(s,j),y.observe(r,j),Some(e))?;
    state(x,&before_y).map_err(|e|format!("loop={id} candidate refusal before/after: {e}"))?;
    state(&before_x,y).map_err(|e|format!("loop={id} oracle refusal before/after: {e}"))?;
    if *x!=before_x||*y!=before_y{return Err(format!("loop={id} refusal changed an unreported state field"));}state(x,y)?;a.refusal_cross+=1;a.reject+=1;Ok(())
}
fn reject_predict(a:&mut Audit,id:&'static str,x:&c::Cts,y:&o::Cts,class:usize,k:usize,e:&str)->Result<()>{state(x,y)?;a.refusal_cross+=1;let bx=x.clone();let by=y.clone();a.case(id,&format!("depth={} class={class} k={k}",x.depth()),x.predict(class,k).map(|s|vs(&s)),y.predict(class,k),Some(e))?;state(x,&by).map_err(|e|format!("loop={id} candidate predict refusal before/after: {e}"))?;state(&bx,y).map_err(|e|format!("loop={id} oracle predict refusal before/after: {e}"))?;if *x!=bx||*y!=by{return Err("rejected predict changed an unreported state field".into());}state(x,y)?;a.refusal_cross+=1;a.reject+=1;Ok(())}
fn success(a:&mut Audit,id:&'static str,x:&mut c::Cts,y:&mut o::Cts,s:&c::Snapshot,r:&o::Snapshot,j:usize)->Result<()>{a.case(id,&format!("depth={} class={} k={} child={j} obs={}",x.depth(),s.class,s.prefix,s.observations),x.observe(s,j),y.observe(r,j),None)?;state(x,y)?;a.success+=1;Ok(())}
fn seeded(d:usize,class:usize,obs:u32,raw:[u32;4])->Result<(c::Cts,o::Cts)>{let(mut x,mut y)=pair(d)?;x.audit_seed_class(class,0,obs);y.audit_seed_class(class,0,obs);let ids=c::path(0);if ids!=o::path(0){return Err("independent path mismatch".into());}for &id in &ids[..=d]{x.audit_seed_node(class,id,raw,Q/2);y.audit_seed_node(class,id,raw,Q/2);}Ok((x,y))}
fn seed_node(x:&mut c::Cts,y:&mut o::Cts,class:usize,l:usize,raw:[u32;4],w:u64){let id=c::path(x.histories()[class])[l];x.audit_seed_node(class,id,raw,w);y.audit_seed_node(class,id,raw,w);}
fn states(a:&mut Audit)->Result<()>{
    for d in 0..LEVELS{let(x,y)=pair(d)?;state(&x,&y)?;let expected=(4usize.pow((d+1)as u32)-1)/3;a.golden("CTS-constructor",x.node_count()==expected&&x.nodes().len()==6*expected&&x.nodes().iter().all(|n|n.raw==[0;4]&&n.weight==Q/2)&&x.histories()==[0;6]&&x.observations()==[0;6],&format!("depth={d}"))?;}
    for d in [9,usize::MAX]{a.case("CTS-constructor",&format!("depth={d}"),c::Cts::new(d).map(|_|()),o::Cts::new(d).map(|_|()),Some("unsupported CTS depth"))?;}
    for d in 0..LEVELS{for class in 0..6{for k in 1..=4{
        let(mut x,mut y)=pair(d)?;state(&x,&y)?;a.stream_state+=1;let mut first=None;
        for _round in 0..2{for j in 0..k{let bx=x.clone();let by=y.clone();let(s,r)=token(&x,&y,class,k)?;let(s2,r2)=token(&x,&y,class,k)?;a.snapshots+=2;
            if s!=s2||r!=r2||x!=bx||y!=by||!s.audit_sealed(){return Err("pure prediction or full seal mismatch".into());}a.pure+=1;state(&x,&y)?;a.stream_state+=1;if first.is_none(){first=Some((s.clone(),r.clone()));}
            success(a,"CTS-stream",&mut x,&mut y,&s,&r,j)?;a.stream_state+=1;
        }}
        let(s,r)=token(&x,&y,class,k)?;let(stale,old)=first.ok_or("missing stale fixture")?;
        for t in 0..10{let(mut z,mut w)=(s.clone(),r.clone());let mut child=0;let e=match t{
            0=>{z.prefix=0;w.prefix=0;"invalid prefix"},1=>{child=k;"invalid observation"},2=>{z=stale.clone();w=old.clone();"stale or modified snapshot"},
            3=>{z.kernel.kt[0][0]^=1;w.kernel.kt[0][0]^=1;"stale or modified snapshot"},4=>{z.kernel.mixed[0][0]^=1;w.kernel.mixed[0][0]^=1;"stale or modified snapshot"},
            5=>{z.kernel.masses[0][0]^=1;w.kernel.masses[0][0]^=1;"stale or modified snapshot"},6=>{z.ids[0]^=1;w.ids[0]^=1;"stale or modified snapshot"},
            7=>{z.raw[0][0]^=1;w.raw[0][0]^=1;"stale or modified snapshot"},8=>{z.weights[0]^=1;w.weights[0]^=1;"stale or modified snapshot"},_=>{z.kernel.depth=9;w.kernel.depth=9;"stale or modified snapshot"}};
            reject(a,"CTS-token",&mut x,&mut y,&z,&w,child,e)?;
        }
        let(mut fx,mut fy)=(x.clone(),y.clone());success_unrecorded(&mut fx,&mut fy,&s,&r,0)?;let(fs,fr)=token(&fx,&fy,class,k)?;reject(a,"CTS-foreign",&mut x,&mut y,&fs,&fr,0,"stale or modified snapshot")?;
        let(mut sx,mut sy)=(x.clone(),y.clone());let(ss,sr)=token(&sx.clone(),&sy.clone(),class,k)?;success(a,"CTS-same-state",&mut sx,&mut sy,&ss,&sr,0)?;
        let(mut rx,mut ry)=(x.clone(),y.clone());let mut rs=stale.clone();rs.audit_rebase(&s);if rs.audit_sealed(){return Err("rebased fixture did not change certified relation".into());}snap(&rs,&r)?;success(a,"CTS-rebased",&mut rx,&mut ry,&rs,&r,0)?;
    }}
    for class in 0..6{
        let(mut x,mut y)=seeded(d,class,CAP-1,[CAP-1,0,0,0])?;let(s,r)=token(&x,&y,class,4)?;success(a,"CTS-CAP",&mut x,&mut y,&s,&r,0)?;if x.observations()[class]!=CAP{return Err("class CAP exact success missing".into());}let(s,r)=token(&x,&y,class,4)?;reject(a,"CTS-CAP",&mut x,&mut y,&s,&r,0,"class update cap")?;x.audit_seed_class(class,0,CAP+1);y.audit_seed_class(class,0,CAP+1);reject_predict(a,"CTS-CAP",&x,&y,class,4,"class observation cap")?;
        let(mut x,mut y)=seeded(d,class,0,[0;4])?;seed_node(&mut x,&mut y,class,d,[CAP,0,0,0],Q/2);let(s,r)=token(&x,&y,class,4)?;reject(a,"CTS-node-atomic",&mut x,&mut y,&s,&r,0,"node update cap")?;
        for t in 0..4{let(mut x,mut y)=seeded(d,class,0,[0;4])?;let(mut s,mut r)=token(&x,&y,class,4)?;s.kernel.kt[0][0]^=1;r.kernel.kt[0][0]^=1;
            let e=match t{0=>{seed_node(&mut x,&mut y,class,d,[0;4],Q/2+1);"invalid kernel depth/leaf"},1=>{seed_node(&mut x,&mut y,class,0,[CAP+1,0,0,0],Q/2);"raw observation cap"},2=>{x.audit_seed_class(class,0,CAP);y.audit_seed_class(class,0,CAP);"class update cap"},_=>{s.observations=CAP;r.observations=CAP;seed_node(&mut x,&mut y,class,d,[0;4],Q/2+1);"class update cap"}};reject(a,"CTS-current",&mut x,&mut y,&s,&r,0,e)?;
        }
        if d>0{let(mut x,mut y)=seeded(d,class,0,[0;4])?;let(s,r)=token(&x,&y,class,4)?;seed_node(&mut x,&mut y,class,0,[CAP+1,0,0,0],Q+1);reject(a,"CTS-nonleaf",&mut x,&mut y,&s,&r,0,"kernel weight")?;}
        let(mut x,mut y)=seeded(d,class,0,[0,0,CAP-1,0])?;let(s,r)=token(&x,&y,class,2)?;success(a,"CTS-inactive-raw",&mut x,&mut y,&s,&r,0)?;
        // historyでpathが変わるので次の全pathもCAPへseedし、最後だけでなく全raw和を検査する。
        for l in 0..=d{seed_node(&mut x,&mut y,class,l,[1,0,CAP-1,0],Q/2);}let(s,r)=token(&x,&y,class,2)?;reject(a,"CTS-inactive-raw",&mut x,&mut y,&s,&r,0,"node update cap")?;
        if d>0{for t in 0..2{let(mut x,mut y)=seeded(d,class,0,[0;4])?;let(s,r)=token(&x,&y,class,4)?;seed_node(&mut x,&mut y,class,0,[CAP+1,0,0,0],if t==0{Q/2}else{Q+1});seed_node(&mut x,&mut y,class,d,if t==0{[0;4]}else{[CAP+1,0,0,0]},if t==0{Q/2+1}else{Q/2});reject(a,"CTS-level-priority",&mut x,&mut y,&s,&r,0,if t==0{"invalid kernel depth/leaf"}else{"kernel weight"})?;}}
    }
    let(mut x,mut y)=pair(d)?;reject_predict(a,"CTS-class-prefix",&x,&y,6,0,"invalid prefix")?;reject_predict(a,"CTS-class-prefix",&x,&y,6,4,"invalid class")?;let(s,r)=token(&x,&y,0,4)?;reject(a,"CTS-class-prefix",&mut x,&mut y,&s,&r,4,"invalid observation")?;
    }
    if (a.pure,a.snapshots,a.stream_state,a.success,a.reject,a.refusal_cross)!=(1080,2160,2376,1620,2979,5958){return Err(format!("CTS fixed counters {:?}",(a.pure,a.snapshots,a.stream_state,a.success,a.reject,a.refusal_cross)));}Ok(())
}
fn success_unrecorded(x:&mut c::Cts,y:&mut o::Cts,s:&c::Snapshot,r:&o::Snapshot,j:usize)->Result<()>{let ax=x.observe(s,j);let by=y.observe(r,j);if ax!=by||ax.is_err(){return Err("foreign fixture setup failed".into());}state(x,y)}
fn weights()->[[u64;5];5]{[[0;5],[2*Q;5],[Q/4,Q/4,Q/4,Q/4,0],[2*Q,0,0,0,0],[0,0,0,0,2*Q]]}
fn pool_predict(a:&mut Audit,id:&'static str,math:&Math,counts:[[u16;4];4],w:[u64;5],cts:[u64;4],k:usize,e:Option<&str>)->Result<()>{a.case(id,&format!("k={k} counts={counts:?} w={w:?} cts={cts:?}"),p::predict(math,counts,w,cts,k).map(|s|vp(&s)),o::predict(math,counts,w,cts,k),e)}
fn learn(a:&mut Audit,id:&'static str,s:&p::Prediction,j:usize,e:Option<&str>)->Result<()>{a.case(id,&format!("child={j} prediction={s:?}"),p::observe(s,j).map(vu),o::observe(&vp(s),j),e)}
fn base_prediction(k:usize)->p::Prediction{let(pv,f,cdf)=p::smooth(bal(k),k).expect("fixed smoothing");p::Prediction{prefix:k,weights:[Q/4,Q/4,Q/4,Q/4,0],features:[[0;4];5],scores:[0;4],q:bal(k),p:pv,frequencies:f,cumulative:cdf}}
fn pool(a:&mut Audit)->Result<()>{
    let math=Math::new().map_err(str::to_owned)?;
    for k in 1..=4{
        let mut cts_shapes=vec![bal(k)];for h in 0..k{cts_shapes.push(spike(k,h));}
        let mut count_shapes=vec![[[1u16;4];4]];for h in 0..4{let mut row=[1;4];row[h]=32765;count_shapes.push([row;4]);}
        for &cts in &cts_shapes{for &counts in &count_shapes{for w in weights(){pool_predict(a,"POOL-predict",&math,counts,w,cts,k,None)?;let s=p::predict(&math,counts,w,cts,k).map_err(str::to_owned)?;for j in 0..k{learn(a,"POOL-learn",&s,j,None)?;}}}}
        for row in 0..4{for bad in [[0,1,1,1],[32768,1,1,1]]{let mut counts=[[1;4];4];counts[row]=bad;pool_predict(a,"POOL-count-bad",&math,counts,weights()[2],bal(k),k,Some("pool count row"))?;}}
        for t in 0..4{let mut v=bal(k);match t{0=>v[0]=0,1=>v[0]=Q+1,2=>v[0]-=1,_=>v[0]+=1};pool_predict(a,"POOL-cts-bad",&math,[[1;4];4],weights()[2],v,k,Some(if t<2||(k==1&&t==3){"invalid categorical vector"}else{"vector sum differs from Q"}))?;}
        for i in 0..5{for bad in [2*Q+1,u64::MAX]{let mut w=weights()[2];w[i]=bad;pool_predict(a,"POOL-weight-bad",&math,[[1;4];4],w,bal(k),k,Some("pool prefix/weight"))?;}}
        for t in 0..3{let mut m=[0;4];m[..k].fill(if t==2{1}else{16381*Q});if t==1{m[..k].fill(0);m[0]=16381*Q;}a.case("POOL-normalize",&format!("k={k} m={m:?}"),c::normalize(m,k),o::normalize(m.map(u128::from),k),None)?;}
        for j in 0..k{let mut m=[0;4];m[j]=16381*Q+1;a.case("POOL-normalize-bad",&format!("k={k} m={m:?}"),c::normalize(m,k),o::normalize(m.map(u128::from),k),Some("pool mass domain"))?;}
        for j in k..4{let mut m=[0;4];m[0]=1;m[j]=1;a.case("POOL-normalize-bad",&format!("k={k} m={m:?}"),c::normalize(m,k),o::normalize(m.map(u128::from),k),Some("pool mass domain"))?;}
        a.case("POOL-normalize-bad",&format!("k={k} mass0"),c::normalize([0;4],k),o::normalize([0;4],k),Some("zero mass total"))?;
        let mut huge=[0;4];huge[..k].fill(u64::MAX);a.case("POOL-normalize-bad",&format!("k={k} massMAX"),c::normalize(huge,k),o::normalize(huge.map(u128::from),k),Some("pool mass domain"))?;
        let mut sw=weights();sw[4]=[0,0,0,0,1];
        for pattern in 0..4{let mut f=[[0;4];5];for j in 0..k{match pattern{0=>{},1|2=>{let high=if pattern==1{j==0}else{j!=0};if high{for row in &mut f[..4]{row[j]=44655667077;}}else{f[4][j]=-62517933908;}},_=>{if j%2==0{for row in &mut f[..4]{row[j]=1;}}else{f[4][j]=-1;}}}}
            for (wi,w) in sw.into_iter().enumerate(){let x=p::audit_features(&math,f,w,k);let y=o::audit_features(&math,f,w,k);a.case("POOL-score",&format!("k={k} pattern={pattern} w={w:?} f={f:?}"),x.clone().map(|s|vp(&s)),y,None)?;let s=x.map_err(str::to_owned)?;let max=*s.scores[..k].iter().max().ok_or("empty scores")?;for j in 0..k{let diff=max.checked_sub(s.scores[j]).ok_or("score diff")?;if !(0..=482281204432).contains(&diff){return Err("score diff bounds".into());}if pattern==3&&wi==4&&j%2==1&&s.scores[j]!=0{return Err("score negative fraction did not truncate to zero".into());}}}
        }
        for j in 0..k{for row in 0..5{let(lo,hi)=if row<4{(0,44655667077)}else{(-62517933908,0)};for value in [lo,hi,lo-1,hi+1]{let mut s=base_prediction(k);s.features[row][j]=value;learn(a,"POOL-feature",&s,0,if value<lo||value>hi{Some("pool feature domain")}else{None})?;}for value in [i64::MIN,i64::MAX]{let mut s=base_prediction(k);s.features[row][j]=value;learn(a,"POOL-feature-huge",&s,0,Some("pool feature domain"))?;}}}
        for j in k..4{for row in 0..5{let mut s=base_prediction(k);s.features[row][j]=1;learn(a,"POOL-feature-inactive",&s,0,Some("pool feature domain"))?;}}
        if k>1{for h in 0..k{for j in 0..k{if j==h{continue;}let mut s=base_prediction(k);s.q=[0;4];s.q[h]=Q;(s.p,s.frequencies,s.cumulative)=p::smooth(s.q,k).map_err(str::to_owned)?;s.features[0][h]=1;learn(a,"POOL-q0",&s,j,None)?;let u=p::observe(&s,j).map_err(str::to_owned)?;if u.factor!=0||u.gradient!=[0;5]||u.delta!=[0;5]||u.next!=s.weights{return Err("q0 factor0 golden".into());}}}}
    }
    for k in [0,5,usize::MAX]{pool_predict(a,"POOL-prefix-bad",&math,[[0;4];4],[u64::MAX;5],[0;4],k,Some("pool prefix/weight"))?;a.case("POOL-normalize-bad",&format!("k={k}"),c::normalize([u64::MAX;4],k),o::normalize([u128::from(u64::MAX);4],k),Some("invalid prefix"))?;a.case("POOL-smooth-prefix",&format!("k={k} q=MAX"),p::smooth([u64::MAX;4],k),o::smooth([u64::MAX;4],k),Some("invalid prefix"))?;}
    for t in 0..20{let mut s=base_prediction(2);let mut j=0;
        let e=match t{
            0..=2=>{s.prefix=[0,5,usize::MAX][t];j=usize::MAX;s.weights=[u64::MAX;5];s.q=[0;4];s.p=[0;4];s.features=[[i64::MAX;4];5];Some("pool observed child/weights")},
            3=>{j=2;s.q=[0;4];s.p=[0;4];s.features=[[i64::MAX;4];5];Some("pool observed child/weights")},4=>{s.weights[0]=2*Q+1;s.q=[0;4];s.p=[0;4];s.features=[[i64::MAX;4];5];Some("pool observed child/weights")},
            5=>{s.q[0]=Q+1;Some("pool q snapshot")},6=>{s.q[0]-=1;Some("pool q snapshot")},7=>{s.q[0]+=1;Some("pool q snapshot")},8=>{s.q[2]=1;Some("pool q snapshot")},9=>{s.q=[u64::MAX;4];Some("pool q snapshot")},10=>{s.q=[0;4];s.p=[0;4];s.features=[[i64::MAX;4];5];Some("pool q snapshot")},
            11=>{s.p[0]=0;Some("invalid categorical vector")},12=>{s.p[0]=Q+1;Some("invalid categorical vector")},13=>{s.p[2]=1;Some("invalid categorical vector")},14=>{s.p[0]-=1;Some("vector sum differs from Q")},15=>{s.p[0]+=1;Some("vector sum differs from Q")},16=>{s.p=[0;4];s.features=[[i64::MAX;4];5];Some("invalid categorical vector")},
            17=>{s.features[0][0]=-1;Some("pool feature domain")},18=>{s.features[0][2]=1;Some("pool feature domain")},_=>{s.scores=[i64::MAX;4];s.frequencies=[u32::MAX;4];s.cumulative=[u32::MAX;5];None}
        };learn(a,"POOL-observe-priority",&s,j,e)?;if t==19&&p::observe(&s,j)!=p::observe(&base_prediction(2),j){return Err("observe used unused scores/CDF".into());}
    }
    for (n,scale) in [(1,0),(32768,0),(1,1),(Q,1)]{let x=if scale==0{math.ln_count(n)}else{math.ln_cts(n.checked_mul(2048).ok_or("log conversion")?)};let wide=if scale==0{math.ln_count(n)}else{math.ln_cts(u64::try_from(u128::from(n).checked_mul(2048).ok_or("wide log product")?).map_err(|_|"wide log conversion")?)};a.case("MATH-connect",&format!("n={n} scale={scale}"),x,wide,None)?;if (n==1&&scale==0)||(n==Q&&scale==1){if x!=Ok(0){return Err("Math zero endpoint".into());}}}
    for n in [0,Q+1]{a.case("MATH-connect",&format!("invalid CTS n={n}"),c::vector([n,0,0,0],1),o::vector([n,0,0,0],1),Some("invalid categorical vector"))?;}
    let cutoff=crate::fixed_math::EXP_CUTOFF;let logq=crate::fixed_math::Q as i64;for d in [0,1,cutoff-1,cutoff,cutoff+1,128*logq,-1,128*logq+1]{a.case("EXP-domain",&format!("d={d}"),math.exp_neg(d),math.exp_neg(d),if d<0||d>128*logq{Some("exp domain")}else{None})?;}
    for t in 0..4{let mut s=base_prediction(2);s.q=bal(2);s.p=bal(2);s.features[if t==3{4}else{0}][0]=match t{0|1=>1048577,2=>1,_=>-1};let j=if t==0||t==2{1}else{0};let u=p::observe(&s,j).map_err(str::to_owned)?;let v=o::observe(&vp(&s),j).map_err(str::to_owned)?;let i=if t==3{4}else{0};let (expected,gradient)=match t{0=>(524288,-524160),1=>(524288,524160),_=>(0,0)};a.golden("SIGNED-golden",vu(u.clone())==v&&u.factor==2096640&&u.expected[i]==expected&&u.gradient[i]==gradient&&u.delta==[0;5]&&u.next==s.weights,&format!("t={t} features={:?}",s.features))?;}
    let sparse=p::smooth([Q,0,0,0],4).map_err(str::to_owned)?;let wide=o::smooth([Q,0,0,0],4).map_err(str::to_owned)?;a.golden("analytic-pool",sparse==wide&&sparse==([2096768,128,128,128],[32762,2,2,2],[0,32762,32764,32766,32768]),"sparse q/p/CDF")?;Ok(())
}
pub(crate) fn run()->Result<()>{
    let mut a=Audit::default();let mut records=Vec::new();
    let outcome=(||->Result<()>{a.phase="primitives";primitives(&mut a)?;a.phase="kernels";kernels(&mut a)?;a.phase="states";states(&mut a)?;a.phase="pool";pool(&mut a)?;a.phase="counts";
        if a.counts.len()!=EXPECTED.len(){return Err("compare loop ID count".into());}for &(id,n) in EXPECTED{let actual=a.counts.get(id).copied().unwrap_or(0);if actual!=n{return Err(format!("loop={id} expected_count={n} actual_count={actual}"));}records.push(format!("{{\"id\":\"{id}\",\"cases\":{actual}}}"));}Ok(())})();
    if let Err(e)=outcome{let planned=EXPECTED.iter().map(|(id,n)|format!("{{\"id\":\"{id}\",\"cases\":{n}}}")).collect::<Vec<_>>().join(",");let done=a.counts.iter().map(|(id,n)|format!("{{\"id\":\"{id}\",\"result_checks\":{n}}}")).collect::<Vec<_>>().join(",");let failure=crate::error_json(&format!("phase={} first_failure={e}; fixture={}",a.phase,a.context));println!("{{\"status\":\"failed\",\"operation\":\"compare\",\"phase\":\"{}\",\"planned_loops\":[{planned}],\"completed_result_checks\":[{done}],\"pure_predictions\":{},\"stream_snapshot_comparisons\":{},\"stream_state_comparisons\":{},\"CTS_success_observes\":{},\"CTS_rejections\":{},\"refusal_cross_state_comparisons\":{},\"failure_evidence\":{failure}}}",a.phase,a.pure,a.snapshots,a.stream_state,a.success,a.reject,a.refusal_cross);return Err(e);}
    println!("{{\"status\":\"passed\",\"operation\":\"compare\",\"loops\":[{}],\"pure_predictions\":{},\"stream_snapshot_comparisons\":{},\"stream_state_comparisons\":{},\"CTS_success_observes\":{},\"CTS_rejections\":{},\"refusal_cross_state_comparisons\":{},\"candidate_mass_bits\":64,\"oracle_mass_bits\":128,\"all_snapshot_fields_direct\":true,\"all_nodes_direct\":true,\"refusal_before_after_direct\":true,\"Math_only_shared\":true,\"diagnostic_only\":true}}",records.join(","),a.pure,a.snapshots,a.stream_state,a.success,a.reject,a.refusal_cross);Ok(())
}
