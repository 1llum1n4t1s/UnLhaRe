use crate::contract::{Result,validate};
pub const INDEX_MASK:u32=(1<<24)-1;
pub struct Output {pub plain:Vec<u8>,pub route:&'static str,pub scratch_capacity_words:usize,pub result_capacity:usize}
pub fn pack(next:usize,byte:u8)->Result<u32>{
    if next>INDEX_MASK as usize{return Err("packed next index exceeds 24 bits".into());}
    Ok((next as u32)|((byte as u32)<<24))
}
#[inline(never)]
pub fn inverse(last:&[u16],primary:usize,alphabet:&[u16])->Result<Output>{
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
    let mut plain=crate::reference::filled(n-1,0u8)?;
    let result_capacity=plain.capacity();let mut row=primary;
    for step in 0..n{
        if row>=n{return Err("LF row outside bounds".into());}
        if step>0 && row==primary{return Err("LF early primary cycle".into());}
        let word=words[row];let next=(word&INDEX_MASK) as usize;
        if next>=n{return Err("packed next outside rows".into());}
        if step>0{plain[n-1-step]=(word>>24) as u8;}
        row=next;
    }
    if row!=primary{return Err("LF cycle/sentinel inconsistent".into());}
    Ok(Output{plain,route:"packed24",scratch_capacity_words,result_capacity})
}
