use crate::contract::{Result,reference_inverse,alphabet};
fn supplied(n:usize,primary:usize)->Result<Vec<u8>>{if n<8{Ok(Vec::new())}else{let mut anchors=[0usize;8];for(i,row)in anchors.iter_mut().enumerate(){*row=i;}anchors[0]=primary;crate::anchored::serialize(anchors)}}
fn rejected(last:&[u16],primary:usize,symbols:&[u16])->Result<()>{
    if reference_inverse(last,primary,symbols).is_ok()||crate::packed::inverse(last,primary,symbols).is_ok(){return Err("frozen inverse invalid input accepted".into());}
    if crate::anchored::generate(last,primary,symbols).is_ok()||crate::anchored::inverse(last,primary,symbols,&supplied(last.len(),primary)?).is_ok(){return Err("generator/decoder invalid input accepted".into());}Ok(())
}
fn recovery()->Result<()>{let plain=[0u8,255,17,0,255,1,9,4,3];let(last,p)=crate::bwt::bwt(&plain)?;let symbols=alphabet(&last)?;let m=crate::anchored::generate(&last,p,&symbols)?;if crate::anchored::inverse(&last,p,&symbols,&m.bytes)?.plain!=plain{return Err("reject recovery".into());}Ok(())}
pub fn checks()->Result<String>{
    let internal:Vec<(Vec<u16>,usize,Vec<u16>)>=vec![
        (vec![],0,vec![]),(vec![0],1,vec![0]),(vec![1,0],0,vec![0,1]),
        (vec![1,1],0,vec![1]),(vec![0,0],0,vec![0]),(vec![257,0],1,vec![0]),
        (vec![1,0],1,vec![0]),(vec![1,0],1,vec![0,1,2]),(vec![0],0,vec![]),
        (vec![0,1,1,1],0,vec![0,1]),(vec![1,0,1,1],1,vec![0,1])];
    for(last,p,s)in &internal{rejected(last,*p,s)?;}
    rejected(&[2,0,2,1,2,1],1,&[0,1,2])?;
    let mut cycle16=vec![1u16;16];cycle16[7]=0;rejected(&cycle16,7,&[0,1])?;
    let mut cycle72=vec![1u16;72];cycle72[7]=0;rejected(&cycle72,7,&[0,1])?;
    for symbols in [[257u16],[u16::MAX]]{rejected(&[0],0,&symbols)?;}
    {let mut last=crate::reference::filled(crate::contract::MAX_N+1,1u16)?;let p=last.len()-1;last[p]=0;rejected(&last,p,&[0,1])?;}
    let plain:Vec<u8>=(0..23).map(|i|((i*73+19)%256)as u8).collect();let(last,p)=crate::bwt::bwt(&plain)?;let symbols=alphabet(&last)?;let good=crate::anchored::generate(&last,p,&symbols)?;let anchors=crate::anchored::parse(&good.bytes,last.len(),p)?;
    let mut bad=Vec::new();bad.push(good.bytes[..31].to_vec());let mut longer=good.bytes.clone();longer.push(0);bad.push(longer);
    let mut rows=anchors;rows[1]=last.len();bad.push(crate::anchored::serialize(rows)?);
    let mut rows=anchors;rows[0]=(p+1)%last.len();bad.push(crate::anchored::serialize(rows)?);
    let mut rows=anchors;rows[1]=rows[0];bad.push(crate::anchored::serialize(rows)?);
    let mut rows=anchors;rows[1]=(0..last.len()).find(|r|!anchors.contains(r)).ok_or("unused tiny row")?;bad.push(crate::anchored::serialize(rows)?);
    let mut rows=anchors;rows.swap(1,2);bad.push(crate::anchored::serialize(rows)?);
    for bytes in &bad{if crate::anchored::inverse(&last,p,&symbols,bytes).is_ok(){return Err("bad metadata accepted".into());}recovery()?;}
    let misleading=crate::anchored::serialize([7,0,1,2,3,4,5,6])?;
    if crate::anchored::inverse(&cycle16,7,&[0,1],&misleading).is_ok(){return Err("separate cycle metadata accepted".into());}recovery()?;
    // 独立LF配列でunique/全終端一致を確認。nativeの最初の拒否globalstepは固定しない。
    let mut lf=[0usize;72];let mut rank=0;
    for(i,&s)in cycle72.iter().enumerate(){lf[i]=if s==0{0}else{rank+=1;rank};}
    let anchors=[7usize,0,1,2,3,4,5,6];
    for i in 0..8{let mut row=anchors[i];for _ in 0..9{row=lf[row];}if row!=anchors[(i+1)%8]{return Err("72 counterexample endpoints".into());}}
    let mut row=7;for step in 1..=8{row=lf[row];if (row==7)!=(step==8){return Err("72 counterexample primary return".into());}}
    if crate::anchored::inverse(&cycle72,7,&[0,1],&misleading).is_ok(){return Err("72 global primary counterexample accepted".into());}recovery()?;
    if crate::anchored::inverse(&[0],0,&[0],&[0]).is_ok(){return Err("noncanonical fallback metadata accepted".into());}recovery()?;
    let mut bit_checks=0;for next in [0usize,crate::packed::INDEX_MASK as usize]{for byte in [0u8,255]{let word=crate::anchored::pack(next,byte)?;if (word&crate::anchored::INDEX_MASK)as usize!=next||(word>>24)as u8!=byte{return Err("pack bits".into());}bit_checks+=1;}}
    if crate::anchored::pack(1usize<<24,0).is_ok(){return Err("pack overflow accepted".into());}
    let(mut cases,mut accepted,mut rejected_count)=(0usize,0usize,0usize);
    for n in 1usize..=8{for primary in 0..n{for bits in 0usize..1usize<<(n-1){
        let mut last=vec![0u16;n];let mut pos=0;for(i,s)in last.iter_mut().enumerate(){if i!=primary{*s=1+((bits>>pos)&1)as u16;pos+=1;}}
        let symbols=alphabet(&last)?;let reference=reference_inverse(&last,primary,&symbols);let old=crate::packed::inverse(&last,primary,&symbols);let generated=crate::anchored::generate(&last,primary,&symbols);
        match(reference,old,generated){
            (Ok(a),Ok(b),Ok(m))=>{let c=crate::anchored::inverse(&last,primary,&symbols,&m.bytes)?;if a!=b.plain||a!=c.plain{return Err("enumeration full plain".into());}accepted+=1;}
            (Err(_),Err(_),Err(_))=>{if crate::anchored::inverse(&last,primary,&symbols,&supplied(n,primary)?).is_ok(){return Err("enumeration decoder accepted".into());}rejected_count+=1;}
            _=>return Err(format!("enumeration acceptance n={n} primary={primary} bits={bits}"))
        }cases+=1;
    }}}
    if cases!=1793||accepted!=255||rejected_count!=1538||bit_checks!=4||bad.len()!=7{return Err("adversarial census".into());}
    Ok(format!("{{\"generator_input_rejections\":17,\"decoder_input_rejections\":17,\"metadata_rejections\":9,\"fallback_metadata_rejections\":1,\"recovery_cases\":10,\"counterexample72_endpoint_checks\":8,\"counterexample72_primary_first_return\":8,\"bit_roundtrip_checks\":4,\"bit_rejections\":1,\"enumeration_cases\":{cases},\"enumeration_accepted\":{accepted},\"enumeration_generator_rejections\":{rejected_count},\"enumeration_decoder_rejections\":{rejected_count},\"all_plain_directly_compared\":true}}"))
}
