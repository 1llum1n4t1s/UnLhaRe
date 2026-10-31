use crate::model::{quantize,Hist,Fit,parse};
type Result<T>=std::result::Result<T,String>;
pub fn run()->Result<String>{
    let mut quant_rejections=0;
    for (counts,k) in [([0,0,0,0],0),([0,0,0,0],1),([0,0,0,0],5),([1,1,0,1],2),([3825341,0,0,0],2)]{
        if quantize(counts,k).is_ok(){return Err("invalid Hamilton accepted".into());}quant_rejections+=1;
    }
    let mut hist=Hist::new()?;let before=hist.counts.clone();let mut record_rejections=0;
    for (class,k,child) in [(6,2,0),(0,1,0),(0,5,0),(0,2,2)]{
        if hist.record(class,k,0,child).is_ok()||hist.counts!=before{return Err("invalid record mutated whole histogram".into());}record_rejections+=1;
    }
    let fit=Fit::build(&hist)?;let (data,bits)=fit.serialize()?;let mut parse_rejections=0;
    let mut extra=data.clone();extra.push(0);let mut padding=data.clone();*padding.last_mut().ok_or("fixture length")?|=1;
    let invalid=[(Vec::new(),0),(data.clone(),bits-1),(extra,bits),(padding,bits),(vec![0u8;data.len()],bits),(vec![255u8;106752],854010)];
    for (packet,used) in invalid {if parse(&packet,used).is_ok(){return Err("malformed model accepted".into());}parse_rejections+=1;}
    // 正規recordでは生成できない親/children不一致を、公開private配列へ故意に作る。
    hist.counts[0][0]=1;
    if Fit::build(&hist).is_ok(){return Err("inconsistent histogram accepted".into());}
    Ok(format!("{{\"Hamilton_rejections\":{quant_rejections},\"record_rejections\":{record_rejections},\"whole_histogram_unchanged\":true,\"parse_rejections\":{parse_rejections},\"inconsistent_histogram_rejections\":1}}"))
}
