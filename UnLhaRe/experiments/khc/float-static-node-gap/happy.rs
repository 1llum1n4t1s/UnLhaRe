use crate::features::{Feature,FeatureState};
use crate::scope::model::Model;
type Result<T>=std::result::Result<T,String>;
pub fn run()->Result<String>{
    let density=crate::density_happy::run()?;
    let mut state=FeatureState::new();
    check(&state,0,5,0,(0,0))?;
    state.commit(5,3,4)?;check(&state,2,5,11,(1,1))?;
    state.commit(7,0,1)?;check(&state,2,5,176,(1,1))?;check(&state,0,7,176,(0,0))?;
    state.commit(5,256,256)?;check(&state,8,5,2831,(7,7))?;
    state.commit(5,0,1)?;check(&state,0,5,45296,(0,0))?;
    state.commit(256,256,8388609)?;check(&state,8,256,3855,(7,23))?;
    let before=state.clone();let _=state.peek(0,256)?;let _=state.peek(8,256)?;
    if state!=before{return Err("peek mutated whole feature state".into());}
    let teacher=Model::new(5)?;let mut intervals=0;
    for (k,expected) in [(1,[32768,0,0,0]),(2,[16384,16384,0,0]),(3,[10923,10923,10922,0]),(4,[8192;4])]{
        let p=teacher.predict(0,0,0,5,0,(0,0),k)?;let mut cumulative=0;
        for (j,&want) in expected.iter().enumerate().take(k){let(c,f,t)=p.interval(j)?;
            if c!=cumulative || f!=want || t!=32768 || p.select(c)?!=j || p.select(c+f-1)?!=j{return Err("fresh teacher CDF fixture".into());}
            cumulative+=f;intervals+=1;
        }
        if cumulative!=32768{return Err("teacher CDF extent".into());}
    }
    Ok(format!("{{\"Density\":{density},\"Feature_fixtures\":7,\"readonly_peeks\":2,\"whole_feature_state_unchanged\":true,\"teacher_root_CDF_fixtures\":4,\"teacher_intervals\":{intervals}}}"))
}
fn check(s:&FeatureState,context:usize,symbol:usize,recent:u32,previous:(usize,usize))->Result<()>{
    if s.peek(context,symbol)?!= (Feature{symbol,context,recent,previous}){return Err("parent run_done feature fixture".into());}Ok(())
}
