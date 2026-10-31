pub type Result<T> = std::result::Result<T,String>;
pub const MAX_N:usize=(8<<20)+1;
pub fn validate(last:&[u16],alphabet:&[u16])->Result<()>{
    if last.is_empty() || last.len()>MAX_N{return Err("transform length outside bounds".into());}
    if alphabet.iter().any(|&s|s>256){return Err("raw alphabet outside header bounds".into());}
    Ok(())
}
#[inline(never)]
pub fn reference_inverse(last:&[u16],primary:usize,alphabet:&[u16])->Result<Vec<u8>>{
    validate(last,alphabet)?;
    crate::reference::inverse_bwt(last,primary,alphabet)
}
pub fn alphabet(last:&[u16])->Result<Vec<u16>>{
    let mut seen=[false;257];
    for &s in last{if s>256{return Err("raw BWT symbol".into());}seen[s as usize]=true;}
    Ok(seen.iter().enumerate().filter_map(|(s,&yes)|yes.then_some(s as u16)).collect())
}
