//! after共通のalpha/retainedだけloop外へ。旧q32は独立oracleとして凍結。
use crate::reference_cts::{Kernel,Result,Q,CAP,LEVELS};
pub fn update_kernel(s:&Kernel,weights:[u64;LEVELS],k:usize,child:usize,after:u32)->Result<[u64;LEVELS]> {
    if !(1..=4).contains(&k) {return Err("invalid prefix");}if child>=k || s.depth>=LEVELS || after==0 || after>CAP || weights[s.depth]!=Q/2 {return Err("invalid kernel update");}
    let mut next=[Q/2;LEVELS];
    if s.depth==0 {return Ok(next);}
    let denominator=u128::from(after).checked_add(1).ok_or("alpha denominator overflow")?;
    let alpha=u64::try_from(u128::from(Q)/denominator).map_err(|_|"alpha conversion")?;
    if alpha==0 {return Err("zero alpha");}
    let retained=Q.checked_sub(alpha.checked_mul(2).ok_or("alpha product overflow")?).ok_or("retained underflow")?;
    for l in 0..s.depth {next[l]=posterior_switch_cached(weights[l],s.kt[l][child],s.masses[l][child],after,alpha,retained)?.2;}
    Ok(next)
}
fn posterior_switch_cached(weight:u64,own:u64,rawmass:u128,after:u32,alpha:u64,retained:u64)->Result<(u64,u64,u64)> {
    if weight>Q || own==0 || own>Q || rawmass==0 || after==0 || after>CAP {return Err("invalid switch input");}
    let ownmass=u128::from(weight).checked_mul(u128::from(own)).ok_or("posterior mass overflow")?;
    if rawmass<ownmass || rawmass>u128::from(Q)*u128::from(Q) {return Err("posterior denominator outside mixture");}
    let numerator=ownmass.checked_mul(u128::from(Q)).ok_or("posterior scale overflow")?;
    let posterior=u64::try_from(numerator/rawmass).map_err(|_|"posterior conversion")?;
    if posterior>Q {return Err("posterior outside Q");}
    let product=u128::from(retained).checked_mul(u128::from(posterior)).ok_or("switch product overflow")?;
    let next=alpha.checked_add(u64::try_from(product/u128::from(Q)).map_err(|_|"switch conversion")?).ok_or("next weight overflow")?;
    if next<alpha || next>Q-alpha || next>Q {return Err("next weight bounds");}
    Ok((posterior,alpha,next))
}
