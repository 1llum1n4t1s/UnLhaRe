// @adversarial @category type,boundary,resource @severity HIGH
// @description 不正varint/ID/length/上限を拒否すること @expected Err、その後正常復元。
pub fn run()->crate::lexeme::Result<usize> {
    let front=crate::lexeme::front_encode(&[b"Abc def"])?;
    for bad in [vec![0],vec![0,0x80,0],vec![0,0xff,0xff,0xff],vec![0,2],vec![0,1,0,1]] {
        if crate::bwt::restore(&bad,&front,1,0,7).is_ok() { return Err("BWT invalid accepted".into()); }
    }
    if crate::bwt::stream(&[257],1).is_ok() || crate::bwt::stream(&vec![0;crate::bwt::LIMIT+1],0).is_ok()
        || crate::bwt::restore(&[],&[],0,0,crate::lexeme::MAX_RAW+1).is_ok() { return Err("BWT limit accepted".into()); }
    if crate::bwt::restore(&[0,1],&front,1,0,7)?!=b"Abc def" { return Err("BWT recovery".into()); } Ok(8)
}
