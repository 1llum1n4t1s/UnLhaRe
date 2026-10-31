use crate::contract::{Result,alphabet,reference_inverse};
fn recipe(n:usize,r:usize)->Vec<u8>{(0..n-1).map(|i|match r{0=>0,1=>255,2=>if i%2==0{0}else{255},_=>((73*i+19)%256)as u8}).collect()}
fn compare(plain:&[u8])->Result<(Vec<u16>,usize,Vec<u8>)>{
    let(old,p)=crate::old_bwt::bwt(plain)?;let symbols=alphabet(&old)?;let oldmeta=crate::anchored::generate(&old,p,&symbols)?;
    let(last,primary,metadata)=crate::bwt::bwt(plain)?;
    if old!=last||p!=primary||oldmeta.bytes!=metadata{return Err("BWT/metadata whole comparison".into());}
    let a=reference_inverse(&last,primary,&symbols)?;let b=crate::packed::inverse(&last,primary,&symbols)?;let c=crate::anchored::inverse(&last,primary,&symbols,&metadata)?;
    if a!=plain||b.plain!=plain||c.plain!=plain{return Err("three-way fullplain".into());}Ok((last,primary,metadata))
}
pub fn small()->Result<String>{
    let(mut cases,mut sa_checks,mut fallback,mut large)=(0usize,0usize,0usize,0usize);let mut rem=[false;8];
    for n in 1usize..=23{for r in 0..4{
        let plain=recipe(n,r);let(last,primary,metadata)=compare(&plain)?;
        let mut text:Vec<u16>=plain.iter().map(|&b|u16::from(b)+1).collect();text.push(0);let mut sa:Vec<usize>=(0..n).collect();sa.sort_by(|&a,&b|text[a..].cmp(&text[b..]));
        let expected:Vec<u16>=sa.iter().map(|&p|text[(p+n-1)%n]).collect();
        if last!=expected||sa[primary]!=0{return Err("independent suffix sort".into());}
        if n<8{if !metadata.is_empty(){return Err("fallback metadata".into());}fallback+=1;}else{let rows=crate::anchored::parse(&metadata,n,primary)?;for i in 0..8{if sa[rows[i]]!=(n-i*(n/8))%n{return Err("independent SA anchor".into());}sa_checks+=1;}large+=1;}
        rem[n%8]=true;cases+=1;
    }}
    if cases!=92||sa_checks!=512||fallback!=28||large!=64||rem.iter().any(|&v|!v){return Err("small census".into());}
    Ok(format!("{{\"plain_cases\":{cases},\"independent_suffix_sort_cases\":92,\"SA_anchor_comparisons\":{sa_checks},\"fallback_cases\":{fallback},\"anchored_cases\":{large},\"remainder_categories\":8,\"all_BWT_primary_metadata_bytes_equal\":true,\"all_three_way_plain_equal\":true}}"))
}
pub fn selector()->Result<String>{
    let(mut small_calls,mut target_calls,mut anchor_checks,mut large_cases)=(0usize,0usize,0usize,0usize);
    for n in 1usize..8{let mut rows=[None;8];for p in 0..n{crate::bwt::select(&mut rows,n,p,p)?;small_calls+=1;}if !crate::bwt::finish(rows,n,0)?.is_empty(){return Err("q0 fallback metadata".into());}}
    for n in (8usize..=23).chain([(1usize<<23)-1,1usize<<23,(1usize<<23)+1]){
        let mut rows=[None;8];let q=n/8;
        for i in 0..8{let p=if i==0{0}else{n-i*q};crate::bwt::select(&mut rows,n,i,p)?;target_calls+=1;}
        let m=crate::bwt::finish(rows,n,0)?;let parsed=crate::anchored::parse(&m,n,0)?;
        for(i,row)in parsed.iter().enumerate(){if *row!=i{return Err("synthetic target row".into());}anchor_checks+=1;}large_cases+=1;
    }
    let mut rows=[None;8];crate::bwt::select(&mut rows,16,0,1)?;if rows!=[None;8]{return Err("wrong suffix selected".into());}
    let(mut rejections,mut unchanged)=(0usize,0usize);
    for(n,row,p)in [(0usize,0usize,0usize),(crate::bwt::MAX_INPUT+2,0,0),(8,0,8),(8,8,0)]{let mut rows=[None;8];let before=rows;if crate::bwt::select(&mut rows,n,row,p).is_ok()||rows!=before{return Err("selector bounds accepted/mutated".into());}rejections+=1;unchanged+=1;}
    let mut rows=[None;8];crate::bwt::select(&mut rows,8,0,0)?;let before=rows;if crate::bwt::select(&mut rows,8,1,0).is_ok()||rows!=before{return Err("duplicate selector accepted/mutated".into());}rejections+=1;unchanged+=1;
    if crate::bwt::finish([None;8],8,0).is_ok(){return Err("missing selector accepted".into());}rejections+=1;
    let rows=std::array::from_fn(|i|Some(i));if crate::bwt::finish(rows,8,1).is_ok(){return Err("wrong primary accepted".into());}rejections+=1;
    let mut rows=std::array::from_fn(|i|Some(i));rows[1]=rows[0];if crate::bwt::finish(rows,8,0).is_ok(){return Err("duplicate row finish accepted".into());}rejections+=1;
    {let over=vec![0u8;crate::bwt::MAX_INPUT+1];if crate::old_bwt::bwt(&over).is_ok()||crate::bwt::bwt(&over).is_ok(){return Err("oversized BWT accepted".into());}}
    compare(&[0,255,1,255,0,17,255,3,7])?;
    if small_calls!=28||target_calls!=152||anchor_checks!=152||large_cases!=19||rejections!=8||unchanged!=5{return Err("selector census".into());}
    Ok(format!("{{\"q0_safe_select_calls\":{small_calls},\"target_select_calls\":{target_calls},\"synthetic_anchor_comparisons\":{anchor_checks},\"target_roundtrip_cases\":{large_cases},\"wrong_suffix_nonselection_cases\":1,\"selector_rejections\":{rejections},\"unchanged_stack_rejections\":{unchanged},\"oversized_BWT_rejections\":2,\"recovery_cases\":1,\"maximum_selector_n\":8388609,\"large_forward_BWT_calls\":0,\"OS_OOM_injected\":false}}"))
}
