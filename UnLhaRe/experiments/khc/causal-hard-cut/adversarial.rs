//! @adversarial @category state,boundary,resource @severity HIGH
//! private audit seedは人工state。実入力からの到達可能性を主張しない。
use crate::engine::{Cts,NodeState};
type Result<T>=std::result::Result<T,String>;
const CAP:u32=3825340;
fn state(raw:[u32;4],score:u64)->NodeState{NodeState{raw,own:score,best:score,split:false}}
fn ids(history:u16)->[usize;6]{let mut path=[0;6];let mut digits=usize::from(history);for d in 1..6{path[d]=4*path[d-1]+1+digits%4;digits/=4;}path}
fn rejected(cts:&mut Cts,action:impl FnOnce(&mut Cts)->bool)->Result<()>{
    let before=cts.audit_dump();let mirror=crate::happy::mirror(cts)?;
    if !action(cts){return Err("expected hard-cut rejection".into());}
    let after=cts.audit_dump();if before.nodes!=after.nodes || before.history!=after.history || before.observations!=after.observations || !cts.same(&mirror){return Err("rejection whole raw/own/best/split/history/observations".into());}Ok(())
}
pub fn run()->Result<String>{
    let mut depth_rejections=0;for depth in [0,4,6]{if Cts::new(depth).is_ok(){return Err("unsupported depth accepted".into());}depth_rejections+=1;}
    let mut rejects=0;let mut cts=Cts::new(5)?;
    for(c,k)in [(6,4),(0,0),(0,5)]{rejected(&mut cts,|m|m.predict(c,k).is_err())?;rejects+=1;}
    for(k,child)in [(4,4),(4,usize::MAX),(1,1)]{let s=cts.predict(0,k)?;rejected(&mut cts,|m|m.observe(&s,child).is_err())?;rejects+=1;}
    let s=cts.predict(0,4)?;cts.observe(&s,0)?;rejected(&mut cts,|m|m.observe(&s,0).is_err())?;rejects+=1;drop(cts);
    {
        let mut m=Cts::new(5)?;let s=m.predict(0,4)?;let last=ids(0)[5];m.audit_seed_node(0,last,state([0;4],1));rejected(&mut m,|m|m.observe(&s,0).is_err())?;rejects+=1;
    }
    // 最後のpath rawがCAPちょうどならpredict可、observe全preflightで拒否。
    {
        let mut m=Cts::new(5)?;m.audit_seed_node(0,ids(0)[5],state([CAP,0,0,0],0));let s=m.predict(0,4)?;rejected(&mut m,|m|m.observe(&s,0).is_err())?;rejects+=1;
    }
    {
        let mut m=Cts::new(5)?;m.audit_seed_node(0,ids(0)[5],state([CAP+1,0,0,0],0));rejected(&mut m,|m|m.predict(0,4).is_err())?;rejects+=1;
    }
    // prefix1価格0でもraw/class/history更新を行い、CAP exactは予測だけ許可。
    let cap_exact_successes;
    {
        let mut m=Cts::new(5)?;m.audit_seed_class(0,0,CAP-1);for id in ids(0){m.audit_seed_node(0,id,state([CAP-1,0,0,0],0));}
        let s=m.predict(0,1)?;m.observe(&s,0)?;let dump=m.audit_dump();if m.observations()[0]!=CAP || dump.history[0]!=0 || ids(0).iter().any(|&id|dump.nodes[id].raw!=[CAP,0,0,0] || dump.nodes[id].own!=0){return Err("CAP exact prefix1 success".into());}cap_exact_successes=1;
        let s=m.predict(0,1)?;rejected(&mut m,|m|m.observe(&s,0).is_err())?;rejects+=1;
    }
    {
        let mut m=Cts::new(5)?;m.audit_seed_class(0,0,CAP+1);rejected(&mut m,|m|m.predict(0,4).is_err())?;rejects+=1;
    }
    {
        let mut m=Cts::new(5)?;m.audit_seed_node(0,ids(0)[5],state([0;4],u64::MAX));let s=m.predict(0,4)?;rejected(&mut m,|m|m.observe(&s,0).is_err())?;rejects+=1;
    }
    // 更新path子以外のsiblingsもsum/penaltyをcheckedする。prefix1自体のpriceは0。
    {
        let mut m=Cts::new(5)?;m.audit_seed_node(0,2,state([0;4],u64::MAX));m.audit_seed_node(0,3,state([0;4],1));let s=m.predict(0,1)?;rejected(&mut m,|m|m.observe(&s,0).is_err())?;rejects+=1;
    }
    {
        let mut m=Cts::new(5)?;m.audit_seed_node(0,2,state([0;4],u64::MAX-255));let s=m.predict(0,1)?;rejected(&mut m,|m|m.observe(&s,0).is_err())?;rejects+=1;
    }
    if depth_rejections!=3 || rejects!=15{return Err("finite rejection census".into());}
    Ok(format!("{{\"depth_rejections\":{depth_rejections},\"state_rejections\":{rejects},\"whole_state_assertions\":{rejects},\"invalid_prediction_rejections\":3,\"invalid_child_rejections\":3,\"stale_rejections\":2,\"late_raw_CAP_rejections\":2,\"class_CAP_rejections\":2,\"score_overflow_rejections\":3,\"CAP_exact_successes\":{cap_exact_successes},\"artificial_seed_cases\":8,\"reachable_corruption_claimed\":false}}"))
}
