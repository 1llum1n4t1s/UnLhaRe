use crate::contract::{Result,reference_inverse};
// @adversarial @category type/state/boundary @severity HIGH
// @description 不正なprimary・symbol・循環を拒否し、呼出前提の拒否と区別する。
// @expected 本体11件、wrapper3件、bit往復8件、bit拒否2件を満たす。
pub fn rejection_checks()->Result<(usize,usize,usize,usize)>{
    let internal:Vec<(Vec<u16>,usize,Vec<u16>)>=vec![
        (vec![],0,vec![]),(vec![0],1,vec![0]),(vec![1,0],0,vec![0,1]),
        (vec![1,1],0,vec![1]),(vec![0,0],0,vec![0]),(vec![257,0],1,vec![0]),
        (vec![1,0],1,vec![0]),(vec![1,0],1,vec![0,1,2]),(vec![0],0,vec![]),
        (vec![0,1,1,1],0,vec![0,1]),(vec![1,0,1,1],1,vec![0,1])];
    for(last,primary,alphabet) in &internal{
        // empty-lastのみ共通length wrapperでも拒否。元bodyにも直接渡し拒否を確認。
        if crate::reference::inverse_bwt(last,*primary,alphabet).is_ok() || crate::packed::inverse(last,*primary,alphabet).is_ok(){return Err("invalid inverse accepted".into());}
    }
    for alphabet in [[257u16],[u16::MAX]]{
        if reference_inverse(&[0],0,&alphabet).is_ok() || crate::packed::inverse(&[0],0,&alphabet).is_ok(){return Err("alphabet wrapper accepted".into());}
    }
    // 上限+1はpacked容量ではなくprivate codecの入力契約で先に拒否する。
    {
        let mut oversized=crate::reference::filled(crate::contract::MAX_N+1,1u16)?;
        let primary=oversized.len()-1;oversized[primary]=0;
        if reference_inverse(&oversized,primary,&[0,1]).is_ok()
            || crate::packed::inverse(&oversized,primary,&[0,1]).is_ok(){
            return Err("maximum transform length wrapper accepted".into());
        }
    }
    let mut bits=0;
    for next in [0usize,crate::packed::INDEX_MASK as usize]{for byte in [0u8,255]{for visited in [false,true]{
        let mut word=crate::packed::pack(next,byte)?;
        if visited{crate::packed::mark(&mut word)?;}
        if (word&crate::packed::INDEX_MASK) as usize!=next || ((word>>23)&255) as u8!=byte || (word&crate::packed::VISITED!=0)!=visited{return Err("packing roundtrip".into());}
        bits+=1;
    }}}
    if crate::packed::pack(1usize<<23,0).is_ok(){return Err("23bit overflow accepted".into());}
    let mut word=crate::packed::pack(crate::packed::INDEX_MASK as usize,255)?;crate::packed::mark(&mut word)?;
    if crate::packed::mark(&mut word).is_ok(){return Err("visited duplicate accepted".into());}
    Ok((internal.len(),3,bits,2))
}
