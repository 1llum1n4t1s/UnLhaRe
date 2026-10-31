use crate::contract::{Result, reference_inverse};
// @adversarial @category type/state/boundary @severity HIGH
// @description 不正header前提と短LF cycleを3方式で拒否する。
// @expected 内部11/約数cycle3の拒否1/共通wrapper3、24bit hand4/超過拒否1。
pub fn checks() -> Result<String> {
    let internal: Vec<(Vec<u16>,usize,Vec<u16>)> = vec![
        (vec![],0,vec![]),(vec![0],1,vec![0]),(vec![1,0],0,vec![0,1]),
        (vec![1,1],0,vec![1]),(vec![0,0],0,vec![0]),(vec![257,0],1,vec![0]),
        (vec![1,0],1,vec![0]),(vec![1,0],1,vec![0,1,2]),(vec![0],0,vec![]),
        (vec![0,1,1,1],0,vec![0,1]),(vec![1,0,1,1],1,vec![0,1])];
    for (last,primary,symbols) in &internal {
        // emptyはcandidate共通wrapper拒否、参照は元bodyへ直接渡す。
        if crate::reference::inverse_bwt(last,*primary,symbols).is_ok()
            || crate::packed23::inverse(last,*primary,symbols).is_ok()
            || crate::packed::inverse(last,*primary,symbols).is_ok() {
            return Err("invalid inverse accepted".into());
        }
    }
    // n6のLF=[3,0,4,1,5,2]はprimary1から長さ3で戻る。
    // 終端だけなら6歩後もprimaryであるため、早期帰還を必ず拒否する。
    if reference_inverse(&[2,0,2,1,2,1],1,&[0,1,2]).is_ok()
        || crate::packed23::inverse(&[2,0,2,1,2,1],1,&[0,1,2]).is_ok()
        || crate::packed::inverse(&[2,0,2,1,2,1],1,&[0,1,2]).is_ok() {
        return Err("divisor cycle3 accepted".into());
    }
    for symbols in [[257u16],[u16::MAX]] {
        if reference_inverse(&[0],0,&symbols).is_ok()
            || crate::packed23::inverse(&[0],0,&symbols).is_ok()
            || crate::packed::inverse(&[0],0,&symbols).is_ok() {
            return Err("alphabet wrapper accepted".into());
        }
    }
    {
        let mut oversized = crate::reference::filled(crate::contract::MAX_N+1,1u16)?;
        let primary = oversized.len()-1; oversized[primary]=0;
        if reference_inverse(&oversized,primary,&[0,1]).is_ok()
            || crate::packed23::inverse(&oversized,primary,&[0,1]).is_ok()
            || crate::packed::inverse(&oversized,primary,&[0,1]).is_ok() {
            return Err("length wrapper accepted".into());
        }
    }
    let mut bit_checks=0;
    for next in [0usize,crate::packed::INDEX_MASK as usize] {
        for byte in [0u8,255] {
            let word=crate::packed::pack(next,byte)?;
            if (word&crate::packed::INDEX_MASK) as usize!=next || (word>>24) as u8!=byte {
                return Err("packed24 bit roundtrip".into());
            }
            bit_checks+=1;
        }
    }
    if crate::packed::pack(1usize<<24,0).is_ok() {return Err("24bit overflow accepted".into());}
    let (cases,accepted,rejected)=enumeration()?;
    if cases!=1793 || accepted!=255 || rejected!=1538 || bit_checks!=4 {
        return Err("enumeration extent".into());
    }
    Ok(format!("{{\"internal_rejections\":{},\"divisor_cycle3_rejections\":1,\"common_wrapper_rejections\":3,\"alphabet_wrapper_rejections\":2,\"length_wrapper_rejections\":1,\"bit_roundtrip_checks\":{bit_checks},\"bit_rejections\":1,\"enumeration_cases\":{cases},\"enumeration_accepted\":{accepted},\"enumeration_rejected\":{rejected},\"three_way_acceptance_and_all_plain_equal\":true}}",internal.len()))
}
// @adversarial @category state @severity HIGH
// @description sentinel位置と残りbinary symbolを全列挙し、置換前提と短cycleを反証する。
// @expected n1..8の1793列で3方式の受理一致、受理時全plain一致。
fn enumeration() -> Result<(usize,usize,usize)> {
    let(mut cases,mut accepted,mut rejected)=(0,0,0);
    for n in 1usize..=8 {
        for primary in 0..n {
            for bits in 0usize..(1usize<<(n-1)) {
                let mut last=vec![0u16;n]; let mut pos=0;
                for (i,symbol) in last.iter_mut().enumerate() {
                    if i!=primary {*symbol=1+((bits>>pos)&1) as u16;pos+=1;}
                }
                let symbols=crate::contract::alphabet(&last)?;
                let reference=reference_inverse(&last,primary,&symbols);
                let previous=crate::packed23::inverse(&last,primary,&symbols);
                let candidate=crate::packed::inverse(&last,primary,&symbols);
                match (reference,previous,candidate) {
                    (Ok(a),Ok(b),Ok(c)) if a==b.plain && a==c.plain => accepted+=1,
                    (Err(_),Err(_),Err(_)) => rejected+=1,
                    _ => return Err(format!("cycle acceptance/plain mismatch n={n} primary={primary} bits={bits}")),
                }
                cases+=1;
            }
        }
    }
    Ok((cases,accepted,rejected))
}
