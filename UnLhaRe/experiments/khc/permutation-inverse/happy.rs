use crate::contract::{Result, alphabet, reference_inverse};
// @happypath @category happy @severity HIGH
// @description 元BWTを3方式で復元し、全byteを入力と直接比較する。
// @expected 正常9件、candidateはpacked24、結果とscratch容量が一致。
pub fn small() -> Result<usize> {
    let mut seed = 0x12345678u32;
    let deterministic: Vec<u8> = (0..4096).map(|_| {
        seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; seed as u8
    }).collect();
    let cases: Vec<Vec<u8>> = vec![vec![], vec![0], vec![255], vec![0,255,0,255,1,254],
        (0..=255).collect(), vec![7;4096],
        (0..4096).map(|i| if i%2==0 {0} else {255}).collect(),
        (0..4096).map(|i| ((i*73+19)%256) as u8).collect(), deterministic];
    for plain in &cases {
        let (last, primary) = crate::bwt::bwt(plain)?;
        let symbols = alphabet(&last)?;
        let reference = reference_inverse(&last, primary, &symbols)?;
        let previous = crate::packed23::inverse(&last, primary, &symbols)?;
        let candidate = crate::packed::inverse(&last, primary, &symbols)?;
        if reference != *plain || previous.plain != *plain || candidate.plain != *plain
            || candidate.route != "packed24" || candidate.scratch_capacity_words != last.len()
            || candidate.result_capacity != plain.len() {
            return Err("small three-way all-plain/route/capacity".into());
        }
    }
    Ok(cases.len())
}
// @happypath @category boundary/resource @severity HIGH
// @description 旧23bit境界3点で3方式の全plainを、巨大BWTなしで比較する。
// @expected candidateは全点packed24、上限一致で切詰めず全byte0を復元。
pub fn boundaries() -> Result<String> {
    let mut records = Vec::new();
    for n in [(1usize<<23)-1, 1usize<<23, (1usize<<23)+1] {
        let mut last = crate::reference::filled(n, 1u16)?;
        last[n-1] = 0;
        let reference = reference_inverse(&last, n-1, &[0,1])?;
        if reference.len()!=n-1 || reference.iter().any(|&b| b!=0) {
            return Err("boundary reference plain".into());
        }
        {
            let previous = crate::packed23::inverse(&last, n-1, &[0,1])?;
            let route = if n <= 1<<23 {"packed23"} else {"reference-fallback"};
            if previous.plain != reference || previous.route != route {
                return Err("boundary previous full plain/route".into());
            }
        } // 旧結果を破棄してからcandidateを作り、巨大結果を3つ保持しない。
        let candidate = crate::packed::inverse(&last, n-1, &[0,1])?;
        if candidate.plain != reference || candidate.route!="packed24"
            || candidate.scratch_capacity_words!=n || candidate.result_capacity!=n-1 {
            return Err("boundary candidate plain/route/capacity".into());
        }
        let estimate = last.capacity()*2 + reference.capacity() + 12*n-1 + (4<<20);
        if estimate>160<<20 {return Err("boundary RAM estimate".into());}
        records.push(format!("{{\"n\":{n},\"candidate_route\":\"packed24\",\"three_way_all_plain_equal\":true,\"all_expected_zero\":true,\"last_capacity\":{},\"reference_result_capacity\":{},\"candidate_result_capacity\":{},\"candidate_scratch_capacity_words\":{},\"same_phase_RAM_estimate_bytes\":{estimate}}}",last.capacity(),reference.capacity(),candidate.result_capacity,candidate.scratch_capacity_words));
    }
    Ok(format!("[{}]", records.join(",")))
}
