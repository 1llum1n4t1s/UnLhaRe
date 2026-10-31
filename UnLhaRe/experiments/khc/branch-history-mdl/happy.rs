use crate::model::{quantize,Hist,Fit,parse};
type Result<T>=std::result::Result<T,String>;
// 親がコード前契約から用意する有限診断。製品のunit testではない。
pub fn run()->Result<String>{
    let cases=[([0,0,0,0],2,[16384,16384,0,0]),([0,0,0,0],3,[10923,10923,10922,0]),([0,0,0,0],4,[8192;4]),([7,0,0,0],4,[32762,2,2,2]),([1,1,1,0],3,[10923,10923,10922,0])];
    for (counts,k,expected) in cases {if quantize(counts,k)?!=expected{return Err("independent Hamilton fixture".into());}}
    let mut hist=Hist::new()?;if hist.counts.len()!=18*1365{return Err("hist shape".into());}
    let mut comparisons=0;
    check(&Fit::build(&hist)?,558,70,&mut comparisons)?;
    for _ in 0..100{hist.record(0,2,0,0)?;}
    let fit=Fit::build(&hist)?;check(&fit,558,70,&mut comparisons)?;
    if fit.lookup(0,2,0)?!=[32766,2,0,0]{return Err("pure root CDF".into());}
    let mut hist=Hist::new()?;
    for _ in 0..10000{hist.record(0,2,0,0)?;hist.record(0,2,1,1)?;}
    let fit=Fit::build(&hist)?;check(&fit,607,76,&mut comparisons)?;
    for h in 0..1024u16 {let expected=match h&3{0=>[32766,2,0,0],1=>[2,32766,0,0],_=>[16384,16384,0,0]};if fit.lookup(0,2,h)?!=expected{return Err("one-level MDL split fixture".into());}}
    Ok(format!("{{\"Hamilton_fixtures\":5,\"model_fixtures\":3,\"full_CDF_comparisons\":{comparisons},\"split_histories\":1024,\"empty_model_bits\":558,\"split_model_bits\":607}}"))
}
fn check(fit:&Fit,bits:usize,bytes:usize,comparisons:&mut usize)->Result<()> {
    let (data,used)=fit.serialize()?;if used!=bits||data.len()!=bytes{return Err("independent serialized model expense".into());}
    let parsed=parse(&data,used)?;
    for class in 0..6 {for k in 2..=4 {for history in 0..1024u16 {
        let a=fit.lookup(class,k,history)?;let b=parsed.lookup(class,k,history)?;
        if a!=b||a[..k].iter().map(|&x|x as u32).sum::<u32>()!=32768||a[..k].iter().any(|&x|x<2)||a[k..].iter().any(|&x|x!=0){return Err("whole parsed CDF model fixture".into());}
        *comparisons+=1;
    }}}
    Ok(())
}
