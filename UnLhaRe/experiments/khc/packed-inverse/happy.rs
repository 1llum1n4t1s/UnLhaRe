use crate::contract::{Result,alphabet,reference_inverse};
// @happypath @category happy @severity HIGH
// @description 空入力と全byte・反復・固定seed入力を両方式で復元する。
// @expected 全plainが元入力と一致し、通常サイズはpacked23経路になる。
pub fn small()->Result<usize>{
    let mut seed=0x12345678u32;
    let deterministic:Vec<u8>=(0..4096).map(|_|{seed^=seed<<13;seed^=seed>>17;seed^=seed<<5;seed as u8}).collect();
    let cases:Vec<Vec<u8>>=vec![vec![],vec![0],vec![255],vec![0,255,0,255,1,254],(0..=255).collect(),vec![7;4096],(0..4096).map(|i|if i%2==0{0}else{255}).collect(),(0..4096).map(|i|((i*73+19)%256) as u8).collect(),deterministic];
    for plain in &cases{
        let(last,primary)=crate::bwt::bwt(plain)?;let symbols=alphabet(&last)?;
        let reference=reference_inverse(&last,primary,&symbols)?;
        let packed=crate::packed::inverse(&last,primary,&symbols)?;
        if reference!=*plain || packed.plain!=*plain || reference!=packed.plain || packed.route!="packed23"{return Err("small all-plain comparison".into());}
        if packed.scratch_capacity_words!=last.len() || packed.result_capacity!=plain.len(){return Err("small capacity".into());}
    }
    Ok(cases.len())
}
// @happypath @category boundary @severity HIGH
// @description 23bit境界の直前・一致・直後をRAM合成fixtureで復元する。
// @expected 全byteが0で参照と一致し、直後だけ従来処理へfallbackする。
pub fn boundaries()->Result<String>{
    let mut records=Vec::new();
    for n in [(1usize<<23)-1,1usize<<23,(1usize<<23)+1]{
        let mut last=crate::reference::filled(n,1u16)?;last[n-1]=0;
        let reference=reference_inverse(&last,n-1,&[0,1])?;
        let candidate=crate::packed::inverse(&last,n-1,&[0,1])?;
        let route=if n<=crate::packed::PACKED_MAX_N{"packed23"}else{"reference-fallback"};
        if reference.len()!=n-1 || candidate.plain.len()!=n-1 || reference!=candidate.plain || reference.iter().any(|&b|b!=0) || candidate.route!=route{return Err("large boundary all-plain/route".into());}
        let reference_logical=12usize.checked_mul(n).and_then(|x|x.checked_sub(1)).ok_or("reference bound overflow")?;
        let same_phase=last.capacity().checked_mul(2).and_then(|x|x.checked_add(reference.capacity())).and_then(|x|x.checked_add(reference_logical)).and_then(|x|x.checked_add(4<<20)).ok_or("boundary RAM arithmetic")?;
        if same_phase>160<<20{return Err("boundary estimated RAM bound".into());}
        if candidate.result_capacity!=n-1 || (route=="packed23" && candidate.scratch_capacity_words!=n){return Err("boundary capacity".into());}
        records.push(format!("{{\"n\":{n},\"route\":\"{route}\",\"all_plain_equal\":true,\"all_expected_zero\":true,\"last_capacity\":{},\"reference_result_capacity\":{},\"candidate_result_capacity\":{},\"candidate_scratch_capacity_words\":{},\"reference_working_logical_bytes\":{reference_logical},\"same_phase_RAM_estimate_bytes\":{same_phase}}}",last.capacity(),reference.capacity(),candidate.result_capacity,candidate.scratch_capacity_words));
        // 大caseのVecはscope末尾で全部破棄し、次caseへ持ち越さない。
    }
    Ok(format!("[{}]",records.join(",")))
}
