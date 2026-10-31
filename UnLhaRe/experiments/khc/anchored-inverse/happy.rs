use crate::contract::{Result,alphabet,reference_inverse};
// 有限tiny独立suffix-sort：旧BWT/metadata対応と全plainを直接比較する。
pub fn small()->Result<String>{
    let(mut cases,mut sa_checks,mut fallback,mut anchored_cases)=(0usize,0usize,0usize,0usize);let mut remainders=[false;8];
    for n in 1usize..=23{for recipe in 0..4{
        let plain:Vec<u8>=(0..n-1).map(|i|match recipe{0=>0,1=>255,2=>if i%2==0{0}else{255},_=>((73*i+19)%256)as u8}).collect();
        let(last,primary)=crate::bwt::bwt(&plain)?;let symbols=alphabet(&last)?;
        let mut text:Vec<u16>=plain.iter().map(|&b|u16::from(b)+1).collect();text.push(0);
        let mut sa:Vec<usize>=(0..n).collect();sa.sort_by(|&a,&b|text[a..].cmp(&text[b..]));
        let expected:Vec<u16>=sa.iter().map(|&s|text[(s+n-1)%n]).collect();let expected_primary=sa.iter().position(|&s|s==0).ok_or("tiny primary")?;
        if last!=expected||primary!=expected_primary{return Err("independent suffix-sort BWT/SA".into());}
        let reference=reference_inverse(&last,primary,&symbols)?;let old=crate::packed::inverse(&last,primary,&symbols)?;
        let metadata=crate::anchored::generate(&last,primary,&symbols)?;let candidate=crate::anchored::inverse(&last,primary,&symbols,&metadata.bytes)?;
        if reference!=plain||old.plain!=plain||candidate.plain!=plain||candidate.scratch_capacity_words!=n||candidate.result_capacity!=n-1{return Err("tiny all plain/capacity".into());}
        if n<8{if !metadata.bytes.is_empty()||candidate.route!="packed24-fallback"{return Err("tiny fallback metadata".into());}fallback+=1;}else{
            let anchors=crate::anchored::parse(&metadata.bytes,n,primary)?;
            if metadata.bytes.len()!=32||crate::anchored::serialize(anchors)?!=metadata.bytes||candidate.route!="anchored8"{return Err("tiny metadata roundtrip".into());}
            for i in 0..8{if sa[anchors[i]]!=(n-i*(n/8))%n{return Err("anchor SA correspondence".into());}sa_checks+=1;}anchored_cases+=1;
        }
        remainders[n%8]=true;cases+=1;
    }}
    if cases!=92||sa_checks!=512||fallback!=28||anchored_cases!=64||remainders.iter().any(|&b|!b){return Err("tiny census".into());}
    Ok(format!("{{\"plain_cases\":{cases},\"BWT_calls\":{cases},\"independent_suffix_sort_cases\":{cases},\"SA_anchor_comparisons\":{sa_checks},\"fallback_cases\":{fallback},\"anchored_cases\":{anchored_cases},\"remainder_categories\":8,\"all_three_way_plain_equal\":true}}"))
}
pub fn boundaries()->Result<String>{
    let mut records=Vec::new();
    for n in [(1usize<<23)-1,1usize<<23,(1usize<<23)+1]{
        let mut last=crate::reference::filled(n,1u16)?;last[n-1]=0;
        let reference=reference_inverse(&last,n-1,&[0,1])?;
        if reference.len()!=n-1||reference.iter().any(|&b|b!=0){return Err("boundary reference zero".into());}
        {let old=crate::packed::inverse(&last,n-1,&[0,1])?;if old.plain!=reference||old.scratch_capacity_words!=n||old.result_capacity!=n-1{return Err("boundary old24 all plain".into());}}
        let metadata=crate::anchored::generate(&last,n-1,&[0,1])?;
        let candidate=crate::anchored::inverse(&last,n-1,&[0,1],&metadata.bytes)?;
        if candidate.plain!=reference||candidate.route!="anchored8"||candidate.scratch_capacity_words!=n||candidate.result_capacity!=n-1||metadata.bytes.len()!=32||metadata.scratch_capacity_words!=n{return Err("boundary candidate all plain/metadata/capacity".into());}
        let reference_estimate=15*n-2+(4<<20);let candidate_estimate=last.capacity()*2+reference.capacity()+4*candidate.scratch_capacity_words+candidate.result_capacity+metadata.bytes.capacity()+(4<<20);
        if reference_estimate>160<<20||candidate_estimate>160<<20{return Err("boundary RAM estimate".into());}
        records.push(format!("{{\"n\":{n},\"route\":\"anchored8\",\"three_way_all_plain_equal\":true,\"all_expected_zero\":true,\"metadata_bytes\":32,\"metadata_capacity\":{},\"last_capacity\":{},\"reference_result_capacity\":{},\"candidate_result_capacity\":{},\"candidate_scratch_capacity_words\":{},\"generation_scratch_capacity_words\":{},\"reference_phase_RAM_estimate_bytes\":{reference_estimate},\"candidate_phase_RAM_estimate_bytes\":{candidate_estimate}}}",metadata.bytes.capacity(),last.capacity(),reference.capacity(),candidate.result_capacity,candidate.scratch_capacity_words,metadata.scratch_capacity_words));
    }
    Ok(format!("[{}]",records.join(",")))
}
