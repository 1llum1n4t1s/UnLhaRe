// @happypath @category happy,boundary @severity HIGH
// @description escape/句/全byteを復元すること @expected 原本全byte一致、固定ID列。
pub fn run()->crate::lexeme::Result<usize> {
    for raw in [b"Abc def Abc def".to_vec(),(0..=255).collect(),vec![],b"Abc\0Abc\0".to_vec()] {
        let p=crate::lexeme::prepare(&raw)?;
        let (b,e)=crate::bwt::stream(&p.symbols,p.vocab)?;
        if crate::bwt::restore(&b,&p.front,p.vocab,e,raw.len())?!=raw { return Err("BWT happy bytes".into()); }
    }
    let (b,e)=crate::bwt::stream(&[256,32,256],1)?;
    if e!=0 || b!=[0,1,32,0,1] { return Err("BWT canonical known stream".into()); } Ok(5)
}
