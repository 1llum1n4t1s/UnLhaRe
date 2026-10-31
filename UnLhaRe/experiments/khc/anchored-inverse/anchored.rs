use crate::contract::{Result,validate};
pub use crate::packed::{INDEX_MASK,pack};
pub struct Metadata{pub bytes:Vec<u8>,pub scratch_capacity_words:usize}
pub struct Output{pub plain:Vec<u8>,pub route:&'static str,pub scratch_capacity_words:usize,pub result_capacity:usize}
fn build(last:&[u16],primary:usize,alphabet:&[u16])->Result<(Vec<u32>,usize)>{
    validate(last,alphabet)?;
    let n=last.len();
    if n-1>INDEX_MASK as usize{return Err("transform exceeds packed24 index".into());}
    if primary>=n || last[primary]!=0{return Err("invalid primary sentinel".into());}
    let mut counts=[0usize;257];
    for &s in last{
        if s>256{return Err("BWT symbol out of range".into());}
        counts[s as usize]=counts[s as usize].checked_add(1).ok_or("BWT count overflow")?;
    }
    if counts[0]!=1{return Err("sentinel count".into());}
    let mut seen=[false;257];
    for &s in alphabet{seen[s as usize]=true;}
    for (i,&count) in counts.iter().enumerate(){if (count!=0)!=seen[i]{return Err("alphabet mismatch".into());}}
    let mut starts=[0usize;257];let mut total=0usize;
    for (i,&count) in counts.iter().enumerate(){starts[i]=total;total=total.checked_add(count).ok_or("BWT starts overflow")?;}
    if total!=n{return Err("BWT total".into());}
    let mut occurrence=[0usize;257];
    let mut words=crate::reference::filled(n,0u32)?;
    let scratch_capacity_words=words.capacity();
    for (row,&symbol) in last.iter().enumerate(){
        let s=symbol as usize;
        if occurrence[s]>=counts[s]{return Err("LF occurrence outside symbol interval".into());}
        let next=starts[s].checked_add(occurrence[s]).ok_or("LF next overflow")?;
        if next>=n{return Err("LF next outside rows".into());}
        let byte=if row==primary{0}else{u8::try_from(symbol.checked_sub(1).ok_or("nonprimary sentinel")?).map_err(|_|"packed byte range")?};
        words[row]=pack(next,byte)?;
        occurrence[s]=occurrence[s].checked_add(1).ok_or("LF occurrence overflow")?;
    }
    // 各symbol区間をrank0..count-1で埋めるためLFは置換。walker以降はread-only。
    let words=words;
    Ok((words,scratch_capacity_words))
}
pub fn serialize(anchors:[usize;8])->Result<Vec<u8>>{
    let mut bytes=Vec::new();bytes.try_reserve_exact(32).map_err(|_|"anchor metadata allocation")?;
    for row in anchors{let row=u32::try_from(row).map_err(|_|"anchor row u32")?;bytes.extend_from_slice(&row.to_le_bytes());}
    Ok(bytes)
}
pub fn parse(bytes:&[u8],n:usize,primary:usize)->Result<[usize;8]>{
    if bytes.len()!=32{return Err("anchor metadata length".into());}
    let mut anchors=[0usize;8];
    for(i,row)in anchors.iter_mut().enumerate(){*row=u32::from_le_bytes(bytes[4*i..4*i+4].try_into().map_err(|_|"anchor u32 length")?) as usize;if *row>=n{return Err("anchor row range".into());}}
    if anchors[0]!=primary{return Err("anchor0 primary".into());}
    for i in 0..8{for j in 0..i{if anchors[i]==anchors[j]{return Err("duplicate anchor".into());}}}
    Ok(anchors)
}
#[inline(never)]
pub fn generate(last:&[u16],primary:usize,alphabet:&[u16])->Result<Metadata>{
    if last.len()<8{let result=crate::packed::inverse(last,primary,alphabet)?;return Ok(Metadata{bytes:Vec::new(),scratch_capacity_words:result.scratch_capacity_words});}
    let(words,scratch_capacity_words)=build(last,primary,alphabet)?;let n=last.len();let q=n/8;let mut anchors=[0usize;8];let mut row=primary;
    for step in 0..n{
        if row>=n{return Err("LF row outside bounds".into());}
        if step>0&&row==primary{return Err("LF early primary cycle".into());}
        if step%q==0&&step/q<8{anchors[step/q]=row;}
        let next=(words[row]&INDEX_MASK)as usize;if next>=n{return Err("packed next outside rows".into());}row=next;
    }
    if row!=primary{return Err("LF cycle/sentinel inconsistent".into());}
    let bytes=serialize(anchors)?;parse(&bytes,n,primary)?;drop(words);
    Ok(Metadata{bytes,scratch_capacity_words})
}
#[inline(never)]
pub fn inverse(last:&[u16],primary:usize,alphabet:&[u16],metadata:&[u8])->Result<Output>{
    if last.len()<8{
        if !metadata.is_empty(){return Err("fallback metadata must be empty".into());}
        let old=crate::packed::inverse(last,primary,alphabet)?;
        return Ok(Output{plain:old.plain,route:"packed24-fallback",scratch_capacity_words:old.scratch_capacity_words,result_capacity:old.result_capacity});
    }
    let(words,scratch_capacity_words)=build(last,primary,alphabet)?;let n=last.len();let anchors=parse(metadata,n,primary)?;let q=n/8;let remainder=n%8;
    let mut rows=anchors;let mut plain=crate::reference::filled(n-1,0u8)?;let result_capacity=plain.capacity();let mut visits=0usize;
    for local in 0..q+remainder{
        for lane in 0..8{
            let length=q+if lane==7{remainder}else{0};if local>=length{continue;}
            let step=lane*q+local;let row=rows[lane];
            if row>=n{return Err("LF row outside bounds".into());}
            // 必須反証n72。global offsetで判定し、load/writeより先に置く。
            if step>0&&row==primary{return Err("LF early primary cycle".into());}
            let word=words[row];let next=(word&INDEX_MASK)as usize;if next>=n{return Err("packed next outside rows".into());}
            if step>0{plain[n-1-step]=(word>>24)as u8;}rows[lane]=next;visits+=1;
        }
    }
    if visits!=n{return Err("anchor visit count".into());}
    for lane in 0..8{if rows[lane]!=anchors[(lane+1)%8]{return Err("anchor segment endpoint".into());}}
    Ok(Output{plain,route:"anchored8",scratch_capacity_words,result_capacity})
}
