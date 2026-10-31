//! コード前固定したRAM input→frame→plain→全frameのstandalone E2E。unit testではない。
use super::*;
#[cfg(frame_audit)]
fn frame(n:usize,primary:usize,order:&[u16],payload:&[u8],depth:usize)->Result<Vec<u8>>{
    let metadata=packed_alphabet::encode(order)?;let mut f=MAGIC.to_vec();
    for x in [n-1,primary,order.len(),payload.len(),0,crc_parts(&[payload]) as usize,0]{f.extend_from_slice(&u32::try_from(x).map_err(|_|"forge field")?.to_le_bytes());}
    f.extend_from_slice(&(depth as u32).to_le_bytes());
    f.extend_from_slice(&metadata);f.extend_from_slice(payload);
    let h=40+metadata.len();let crc=crc_parts(&[&f[..32],&f[36..h]]);f[32..36].copy_from_slice(&crc.to_le_bytes());Ok(f)
}
#[cfg(frame_audit)]
fn repair_header(f:&mut [u8])->Result<()>{
    if f.len()<40{return Err("forge header".into());}let h=f.len().checked_sub(field(f,20)).ok_or("forge length")?;
    if h<40{return Err("forge header size".into());}let crc=crc_parts(&[&f[..32],&f[36..h]]);f[32..36].copy_from_slice(&crc.to_le_bytes());Ok(())
}
#[cfg(frame_audit)]
fn set(f:&mut [u8],at:usize,n:usize)->Result<()>{f[at..at+4].copy_from_slice(&u32::try_from(n).map_err(|_|"forge field")?.to_le_bytes());Ok(())}
#[cfg(frame_audit)]
fn replace_payload(f:&mut Vec<u8>,payload:&[u8])->Result<()>{
    let h=f.len()-field(f,20);f.truncate(h);f.extend_from_slice(payload);set(f,20,payload.len())?;set(f,28,crc_parts(&[payload]) as usize)?;repair_header(f)
}
#[cfg(frame_audit)]
fn scripted(n:usize,order:&[u16],steps:&[(usize,usize,&[u8])],depth:usize)->Result<Vec<u8>>{
    let mut active=order.to_vec();let mut stream=Stream::new(Coder::Encode(Encoder::with_limit(payload_limit(n)?)?),depth)?;let mut used=0;
    for &(rank,token,escapes) in steps{
        let symbol=*active.first().ok_or("forge active")?;stream.rank(symbol,rank,active.len())?;
        stream.token(1,exponent(rank+1),symbol,token,(n-used).min(256))?;
        for &b in escapes{stream.byte(b)?;}
        // 不正escapeのあとに後続runを作らない。正常tiny scriptはtoken<255。
        let length=token+1;stream.run_done(symbol,rank,length);used+=length;active.remove(0);if rank!=0{active.insert(rank,symbol);}
    }
    let Coder::Encode(e)=stream.coder else{unreachable!()};e.finish().map_err(Into::into)
}
#[cfg(frame_audit)]
fn forged(name:&str,depth:usize)->Result<(Vec<u8>,&'static str)>{
    let mut f=encode(&[],depth)?.0;
    let expected=match name{
        "short_header"=>{f.truncate(31);"bad frame magic/header"},
        "old_magic"=>{f[..8].copy_from_slice(b"KHQCIP01");"bad frame magic/header"},
        "bad_magic"=>{f[0]^=1;"bad frame magic/header"},
        "input_length"=>{set(&mut f,8,MAX_INPUT+1)?;"frame fields outside bounds"},
        "primary_field"=>{set(&mut f,12,1)?;"frame fields outside bounds"},
        "alphabet_zero"=>{set(&mut f,16,0)?;"frame fields outside bounds"},
        "alphabet_over"=>{set(&mut f,16,258)?;"frame fields outside bounds"},
        "payload_short"=>{set(&mut f,20,4)?;"frame fields outside bounds"},
        "payload_quota"=>{set(&mut f,20,MAX_PAYLOAD+1)?;"frame fields outside bounds"},
        "payload_derived_bound"=>{set(&mut f,20,39)?;"payload exceeds transformed bound"},
        "header_crc"=>{f[32]^=1;"header CRC mismatch"},
        "payload_crc"=>{f[73]^=1;"payload CRC mismatch"},
        "plain_crc"=>{set(&mut f,24,1)?;repair_header(&mut f)?;"plain length/CRC mismatch"},
        "metadata_padding"=>{f[72]|=2;repair_header(&mut f)?;"packed alphabet high bitmap padding nonzero"},
        "metadata_sentinel"=>{f[40]=2;repair_header(&mut f)?;"packed alphabet sentinel 0 missing"},
        "metadata_width"=>{f.insert(73,0);repair_header(&mut f)?;"packed alphabet rank byte width not canonical"},
        "metadata_rank"=>{f=frame(1,0,&[0,1],&[0;5],depth)?;f[73]=2;repair_header(&mut f)?;"packed alphabet rank outside factorial"},
        "range_prefix"=>{replace_payload(&mut f,&[1,0,0,0,0])?;"invalid range prefix"},
        "range_gap"=>{replace_payload(&mut f,&[0,255,255,255,255])?;"range rounding gap"},
        "range_truncated"=>{f=encode(&vec![0;16640],depth)?.0;let h=f.len()-field(&f,20);let p=f[h..h+5].to_vec();replace_payload(&mut f,&p)?;"truncated range stream"},
        "range_trailing"=>{replace_payload(&mut f,&[0;6])?;"trailing range bytes"},
        "range_termination"=>{replace_payload(&mut f,&[0,0,0,0,1])?;"noncanonical range termination"},
        "sentinel_count"=>{let p=scripted(2,&[0],&[(0,1,&[])],depth)?;f=frame(2,0,&[0],&p,depth)?;"sentinel count"},
        "primary_sentinel"=>{let(p,a,_,_)=encode_payload(&[0,1],depth)?;f=frame(2,1,&a,&p,depth)?;"invalid primary sentinel"},
        "lf_cycle"=>{let(p,a,_,_)=encode_payload(&[0,1],depth)?;f=frame(2,0,&a,&p,depth)?;"LF cycle inconsistent"},
        "active_early"=>{let p=scripted(2,&[0],&[(0,0,&[])],depth)?;f=frame(2,0,&[0],&p,depth)?;"active list exhausted before declared length"},
        "active_remaining"=>{let p=scripted(1,&[1,0],&[(1,0,&[])],depth)?;f=frame(1,0,&[1,0],&p,depth)?;"active list not empty at end"},
        "escape_noncanonical"|"escape_fourbytes"|"escape_remaining"=>{
            let bytes:&[u8]=match name{"escape_noncanonical"=>&[128,0],"escape_fourbytes"=>&[128;4],_=>&[1]};
            let p=scripted(256,&[0],&[(0,255,bytes)],depth)?;f=frame(256,0,&[0],&p,depth)?;
            match name{"escape_noncanonical"=>"noncanonical length escape","escape_fourbytes"=>"length escape exceeds four bytes",_=>"run length outside remaining bound"}
        },
        "unsupported_depth9"|"unsupported_depth_max"=>{set(&mut f,36,if name=="unsupported_depth9"{9}else{u32::MAX as usize})?;set(&mut f,8,MAX_INPUT+1)?;f[32]^=1;"unsupported CTS depth"},
        "depth_crc"=>{set(&mut f,36,if depth==8{0}else{8})?;"header CRC mismatch"},
        _=>return Err("unknown forged case".into()),
    };Ok((f,expected))
}
#[cfg(frame_audit)]
fn run_depth(depth:usize)->Result<String>{
    if crc_parts(&[b"123456789"])!=0xcbf43926{return Err("IEEE CRC32 known fixture".into());}
    let mut normal=vec![("empty".to_string(),Vec::new())];
    for n in [1,2,255,256,257,383,384,16639,16640]{normal.push((format!("constant0-{n}"),vec![0;n]));}
    normal.push(("all256".into(),(0..1024).map(|i|(i%256) as u8).collect()));
    normal.push(("sparse-high255".into(),(0..64).map(|i|[0,3,127,255][i%4]).collect()));
    let mut seed=0x6d2b79f5u32;let lcg=(0..4096).map(|_|{seed=seed.wrapping_mul(1664525).wrapping_add(1013904223);(seed>>24) as u8}).collect();
    normal.push(("lcg4096".into(),lcg));normal.push(("text128".into(),b"Kagayoi private integer CTS frame.\n".repeat(128)));
    let mut completed=0;let mut plain_checks=0;let mut canonical_checks=0;
    for(name,input)in &normal{
        let(f,es)=encode(input,depth).map_err(|e|format!("normal {name} encode: {e}"))?;
        let(plain,ds)=decode(&f).map_err(|e|format!("normal {name} decode: {e}"))?;
        if input!=&plain{return Err(format!("normal {name} byte mismatch"));}plain_checks+=1;
        let(again,_)=encode(&plain,depth)?;if f!=again{return Err(format!("normal {name} whole frame mismatch"));}canonical_checks+=1;
        if es.tokens.grammar!=ds.tokens.grammar||es.tokens.state_digest!=ds.tokens.state_digest||es.tokens.branches!=ds.tokens.branches||es.tokens.class_observations!=ds.tokens.class_observations||es.tokens.cdf_entropy.to_bits()!=ds.tokens.cdf_entropy.to_bits(){return Err(format!("normal {name} model divergence"));}completed+=1;
    }
    let names=["short_header","old_magic","bad_magic","input_length","primary_field","alphabet_zero","alphabet_over","payload_short","payload_quota","payload_derived_bound","header_crc","payload_crc","plain_crc","metadata_padding","metadata_sentinel","metadata_width","metadata_rank","range_prefix","range_gap","range_truncated","range_trailing","range_termination","sentinel_count","primary_sentinel","lf_cycle","active_early","active_remaining","escape_noncanonical","escape_fourbytes","escape_remaining","unsupported_depth9","unsupported_depth_max","depth_crc"];
    let mut malformed=0;let mut evidence=String::new();
    for name in names {let(f,expected)=forged(name,depth)?;match decode(&f){Err(e)if e==expected=>{},Err(e)=>return Err(format!("malformed {name}: expected {expected}, actual {e}")),Ok(_)=>return Err(format!("malformed {name} accepted"))};if malformed!=0{evidence.push(',');}evidence.push_str(&format!("{{\"name\":\"{name}\",\"reason\":\"{expected}\",\"frame_bytes\":{}}}",f.len()));malformed+=1;}
    let(named,assertions,cap)=model::rejection_checks(depth)?;
    if (completed,plain_checks,canonical_checks,malformed,named,assertions,cap)!=(14,14,14,33,14,16,1){return Err("E2E fixed counts".into());}
    let mut short_checks=0;
    for n in 36..40 {let(mut f,_)=encode(&[],depth)?;f.truncate(n);
        if decode(&f).err().as_deref()!=Some("bad frame magic/header"){return Err("short depth header guard".into());}short_checks+=1;}
    if short_checks!=4{return Err("short depth header count".into());}
    Ok(format!("{{\"depth\":{depth},\"short_depth_header_checks\":{short_checks},\"status\":\"passed\",\"operation\":\"selfcheck\",\"normal_cases\":{completed},\"byte_roundtrips\":{plain_checks},\"canonical_cases\":{canonical_checks},\"malformed_cases\":{malformed},\"model_rejection_named_cases\":{named},\"model_rejection_assertions\":{assertions},\"cap_exact_successes\":{cap},\"CRC32_known_fixture\":true,\"LCG_seed\":1831565813,\"model_state_comparison\":\"all base values and totals, pool weights, CTS raw and weights, histories, observations, serial and audit values directly\",\"malformed\":[{evidence}],\"general_8MiB_input_supported\":false,\"full_benchmark_allowed\":false,\"heap_write_sync_fault_injection\":false}}"))
}
#[cfg(frame_audit)]
pub(crate) fn run()->Result<()> {
    let mut records=Vec::new();for depth in [4,5,6,7,8] {records.push(run_depth(depth)?);}
    println!("{{\"status\":\"passed\",\"operation\":\"depth-selfcheck\",\"depths\":[4,5,6,7,8],\"normal_cases\":70,\"byte_roundtrips\":70,\"canonical_cases\":70,\"malformed_cases\":165,\"short_depth_header_checks\":20,\"model_rejection_named_cases\":70,\"model_rejection_assertions\":80,\"cap_exact_successes\":5,\"records\":[{}]}}",records.join(","));Ok(())
}
#[cfg(not(frame_audit))]
pub(crate) fn run()->Result<()>{Err("frame_audit is required for selfcheck".into())}

