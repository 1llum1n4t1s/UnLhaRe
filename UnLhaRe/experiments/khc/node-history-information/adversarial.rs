use crate::counts::{Dense,CAP};
type Result<T>=std::result::Result<T,String>;
pub fn run()->Result<String>{
    let mut dense=Dense::new()?;let before=dense.rows.clone();let mut rejects=0;
    for (c,node,k,child) in [(2,0,2,0),(0,142,2,0),(0,0,1,0),(0,0,5,0),(0,0,2,2),(1,141,4,4)]{
        if dense.record(c,node,k,0,child).is_ok() || dense.rows!=before{return Err("invalid key changed whole dense state".into());}rejects+=1;
    }
    drop(before);
    for (bad,child) in [([CAP,0,0,0],0),([1,0,0,1],0)]{
        dense.rows[0]=bad;let before=dense.rows.clone();
        if dense.record(0,0,2,0,child).is_ok() || dense.rows!=before{return Err("corrupt row changed whole dense state".into());}rejects+=1;
    }
    Ok(format!("{{\"record_rejections\":{rejects},\"whole_dense_unchanged\":true,\"malformed_rows\":2}}"))
}
