use crate::features::FeatureState;
type Result<T>=std::result::Result<T,String>;
pub fn run()->Result<String>{
    let density=crate::density_adversarial::run()?;
    let mut s=FeatureState::new();s.commit(5,3,4)?;let before=s.clone();let mut rejects=0;
    for (context,symbol) in [(9,0),(0,257)]{
        if s.peek(context,symbol).is_ok() || s!=before{return Err("invalid peek changed whole feature state".into());}rejects+=1;
    }
    for (symbol,rank,length) in [(257,0,1),(5,257,1),(5,0,0),(5,0,8388610)]{
        if s.commit(symbol,rank,length).is_ok() || s!=before{return Err("invalid commit changed whole feature state".into());}rejects+=1;
    }
    let(named,assertions,cap)=crate::scope::model::rejection_checks(5)?;
    if named!=26 || assertions!=26 || cap!=1{return Err("frozen teacher rejection coverage".into());}
    Ok(format!("{{\"Density\":{density},\"Feature_rejections\":{rejects},\"whole_feature_state_unchanged\":true,\"teacher_named_rejections\":{named},\"teacher_whole_state_assertions\":{assertions},\"teacher_CAP_exact_successes\":{cap}}}"))
}
