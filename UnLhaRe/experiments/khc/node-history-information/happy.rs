use crate::counts::{Dense,ROWS};
use crate::model::quantize;
type Result<T>=std::result::Result<T,String>;
// 実装前契約から親が所有する有限入力診断。製品のunit testではない。
pub fn run()->Result<String>{
    for (counts,k,expected) in [([0,0,0,0],2,[16384,16384,0,0]),([0,0,0,0],3,[10923,10923,10922,0]),([0,0,0,0],4,[8192;4]),([7,0,0,0],4,[32762,2,2,2]),([1,1,1,0],3,[10923,10923,10922,0])] {
        if quantize(counts,k)?!=expected{return Err("parent Hamilton CDF".into());}
    }
    let mut dense=Dense::new()?;
    if ROWS!=872448 || dense.rows.len()!=ROWS || dense.rows.iter().any(|v|*v!=[0;4]){return Err("dense zero shape".into());}
    for (c,node,k,h,child) in [(0,0,2,0,0),(0,0,2,0,0),(0,0,2,0,1),(0,0,2,1024,1),(1,0,2,0,0),(0,1,2,0,0),(0,0,3,0,2),(0,0,2,1,1),(1,141,4,1023,3),(1,141,4,65535,3)] {
        dense.record(c,node,k,h,child)?;
    }
    let expected=[(0usize,[2,2,0,0]),(142*3*1024,[1,0,0,0]),(3*1024,[1,0,0,0]),(1024,[0,0,1,0]),(1,[0,1,0,0]),(ROWS-1,[0,0,0,2])];
    let mut total=0u64;let mut active=0;
    for (index,row) in dense.rows.iter().enumerate(){
        let want=expected.iter().find(|(id,_)|*id==index).map(|(_,v)|*v).unwrap_or([0;4]);
        let k=(index/1024)%3+2;
        if *row!=want || row[k..].iter().any(|&n|n!=0){return Err("all-row key separation fixture".into());}
        let n=row.iter().map(|&n|u64::from(n)).sum::<u64>();total+=n;active+=usize::from(n!=0);
    }
    if total!=10 || active!=6 || dense.row(0,0,2,1024)?!=[2,2,0,0] || dense.row(1,141,4,65535)?!=[0,0,0,2]{return Err("last10bit lookup/count fixture".into());}
    Ok(format!("{{\"Hamilton_fixtures\":5,\"record_events\":10,\"active_rows\":6,\"whole_row_comparisons\":{ROWS},\"history_alias_checks\":2}}"))
}
