// Failure-first: canonical varint/ID/length、escape、native input/caller 上限と全byte復元。
use crate::lexeme::{self as l, Result, LIBRARY_RESERVE, MAX_DICT, MAX_RAW};
pub const LIMIT: usize = 512 << 10;
fn paid(caller: usize) -> Result<()> {
    if caller.checked_add(LIBRARY_RESERVE).ok_or("BWT caller overflow")? > 64 << 20 { return Err("BWT caller/library bound".into()); } Ok(())
}
fn var_len(mut n: usize) -> usize { let mut k=1; while n>=128 { n>>=7; k+=1; } k }
fn put(out: &mut Vec<u8>, mut n: usize) { while n>=128 { out.push((n as u8 &127)|128); n>>=7; } out.push(n as u8); }
fn get(bytes: &[u8], at: &mut usize) -> Result<usize> {
    let start=*at; let mut n=0usize;
    for shift in [0,7,14] { let b=*bytes.get(*at).ok_or("BWT truncated varint")?; *at+=1; n|=usize::from(b&127)<<shift;
        if b&128==0 { if *at-start!=var_len(n) { return Err("BWT noncanonical varint".into()); } return Ok(n); }
    } Err("BWT varint bound".into())
}
pub fn stream(symbols: &[u16], vocab: usize) -> Result<(Vec<u8>, u8)> {
    if symbols.len()>MAX_RAW || vocab>MAX_DICT || symbols.iter().any(|&s| usize::from(s)>=256+vocab) { return Err("BWT symbol/count limit".into()); }
    let mut counts=[0usize;256]; for &s in symbols { if s<256 { counts[usize::from(s)]+=1; } }
    let escape=(0..256).min_by_key(|&i|(counts[i],i)).ok_or("escape")? as u8;
    let n: usize=symbols.iter().map(|&s| if s<256 { 1+usize::from(s as u8==escape) } else { 1+var_len(usize::from(s)-255) }).sum();
    if n>LIMIT { return Err("BWT transform limit".into()); }
    let mut bytes=Vec::new(); bytes.try_reserve_exact(n).map_err(|_|"BWT stream allocation")?;
    if bytes.capacity()>LIMIT { return Err("BWT stream capacity".into()); }
    for &s in symbols { if s<256 { bytes.push(s as u8); if s as u8==escape { bytes.push(0); } } else { bytes.push(escape); put(&mut bytes,usize::from(s)-255); } }
    Ok((bytes,escape))
}
pub fn restore(bytes: &[u8], front: &[u8], vocab: usize, escape: u8, raw_len: usize) -> Result<Vec<u8>> {
    if bytes.len()>LIMIT || front.len()>LIMIT || raw_len>MAX_RAW { return Err("BWT restore limits".into()); }
    let words=l::front_decode(front,vocab)?;
    let mut raw=Vec::new(); raw.try_reserve_exact(raw_len).map_err(|_|"BWT restore allocation")?;
    if raw.capacity()>MAX_RAW { return Err("BWT restore capacity".into()); }
    let mut at=0;
    while at<bytes.len() { let b=bytes[at]; at+=1;
        if b!=escape { if raw.len()>=raw_len { return Err("BWT literal overrun".into()); } raw.push(b); }
        else { let id=get(bytes,&mut at)?; if id==0 { if raw.len()>=raw_len { return Err("BWT escape overrun".into()); } raw.push(escape); }
            else { let word=words.get(id-1).ok_or("BWT dictionary ID")?; if raw.len()+word.len()>raw_len { return Err("BWT word overrun".into()); } raw.extend_from_slice(word); }
        }
    }
    if raw.len()!=raw_len { return Err("BWT restored length".into()); } Ok(raw)
}
pub fn measure(raw: &[u8], caller: usize) -> Result<(Option<usize>, usize, serde_json::Value)> {
    paid(caller)?;
    let prep=l::prepare(raw)?; let bound=prep.logical_bound;
    if prep.vocab==0 || prep.front.len()>LIMIT { return Ok((None,bound,serde_json::json!({"fallback":"no vocabulary/front limit","frontend_exact":true,"dict_exact":true}))); }
    // 変換上限を予約前に計算。容量費は最大512KiBを先払いしてから実測値へ置換。
    paid(caller+prep.front.capacity()+prep.symbols.capacity()*2+LIMIT)?;
    let (bytes,escape)=match stream(&prep.symbols,prep.vocab) { Ok(x)=>x, Err(e) if e=="BWT transform limit"=>return Ok((None,bound,serde_json::json!({"fallback":"transform limit","frontend_exact":true,"dict_exact":true}))), Err(e)=>return Err(e) };
    let crate::lexeme::Prepared {vocab,phrases,front,symbols,..}=prep; let symbol_count=symbols.len(); drop(symbols);
    let retained=caller+front.capacity()+bytes.capacity(); paid(retained)?;
    if restore(&bytes,&front,vocab,escape,raw.len())?!=raw { return Err("BWT transform byte mismatch".into()); }
    paid(retained)?;
    let dict=unlhare::lhc::compress_block(&front).map_err(|e|e.to_string())?; paid(retained+dict.capacity())?;
    let dictionary_wire=front.len().min(dict.len()); let dict_frame=dict.len(); let dict_cap=dict.capacity();
    if unlhare::lhc::decompress_block(&dict).map_err(|e|e.to_string())?!=front { return Err("BWT dictionary native mismatch".into()); }
    drop(dict); paid(retained)?;
    let token=unlhare::lhc::compress_block(&bytes).map_err(|e|e.to_string())?; paid(retained+token.capacity())?;
    if unlhare::lhc::decompress_block(&token).map_err(|e|e.to_string())?!=bytes { return Err("BWT token native mismatch".into()); }
    let reserve_peak=LIBRARY_RESERVE+front.capacity()+bytes.capacity()+token.capacity().max(dict_cap);
    paid(caller+reserve_peak-LIBRARY_RESERVE)?;
    Ok((Some(48+dictionary_wire+token.len()),bound.max(reserve_peak),serde_json::json!({"vocab":vocab,"phrases":phrases,"symbols":symbol_count,
        "stream_bytes":bytes.len(),"front_bytes":front.len(),"dictionary_native_frame":dict_frame,"dictionary_wire":dictionary_wire,
        "token_native_frame":token.len(),"outer_header_fee":48,"escape":escape,"frontend_exact":true,"dict_exact":true})))
}
