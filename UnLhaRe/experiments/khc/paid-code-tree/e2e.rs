//! 先行failure planに固定した有限RAM E2E。ディスク入出力なし。
use crate::{codebook::{self,Encoder,Decoder,Writer,Reader},paid_model as model,paid_bundle as bundle};
type Result<T>=std::result::Result<T,String>;
fn near(a:f64,b:f64)->Result<()>{if !a.is_finite() || !b.is_finite() || (a-b).abs()>1e-6{return Err("finite paid loss oracle".into());}Ok(())}
fn reject<T>(r:Result<T>,reason:&str)->Result<()>{let actual=r.err().ok_or_else(||format!("accepted {reason}"))?;if actual!=reason{return Err(format!("rejection {actual}, expected {reason}"));}Ok(())}
fn finish(w:Writer)->Result<(Vec<u8>,usize)>{if w.position!=w.limit{return Err("finite exact writer".into());}Ok((w.bytes,w.position))}
fn fields(fields:&[(u32,usize)])->Result<(Vec<u8>,usize)>{let mut w=Writer::new(fields.iter().map(|x|x.1).sum())?;for &(v,n) in fields{w.write(v,n)?;}finish(w)}
fn book_cases(enc:&Encoder,dec:&Decoder)->Result<()> {
    let mut known=0;let mut unknown=0;
    // 全短長のKraft contribution + 同長symbol rank。sort/count実装とは独立の直接式。
    for s in 0..257{let n=codebook::LENGTHS[s];if n==0{if enc.codes[s]!=0{return Err("unused canonical code must zero".into());}continue;}
        let mut expected=0u32;
        for t in 0..257{let m=codebook::LENGTHS[t];if m>0 && m<n{expected+=1u32<<(n-m);}else if m==n && t<s{expected+=1;}}
        if u32::from(enc.codes[s])!=expected{return Err("independent canonical257".into());}
    }
    for code in 0..=255u8{let fee=codebook::fee(code);let mut w=Writer::new(fee)?;enc.write(code,&mut w)?;let(bytes,bits)=finish(w)?;
        let mut r=Reader{bytes:&bytes,bits,position:0};if dec.read(&mut r)?!=code || r.position!=bits{return Err("minor256 exact code fee roundtrip".into());}
        if codebook::LENGTHS[usize::from(code)]==0{unknown+=1;if bits!=19{return Err("unknown ESC11raw8 fee".into());}}else{known+=1;}
    }
    if known!=183 || unknown!=73 || dec.nodes()>513{return Err("fixed known/unknown/trie extent".into());}
    let mut redundant=Writer::new(19)?;redundant.write(u32::from(enc.codes[256]),11)?;redundant.write(0,8)?;let(bytes,bits)=finish(redundant)?;
    reject(dec.read(&mut Reader{bytes:&bytes,bits,position:0}),"redundant ESC known symbol")?;
    for bits in [0,10,11,18]{let mut w=Writer::new(19)?;enc.write(1,&mut w)?;reject(dec.read(&mut Reader{bytes:&w.bytes,bits,position:0}),"truncated paid field/code/raw")?;}
    let mut table=codebook::LENGTHS;table[256]=0;reject(Decoder::new(table),"table ESC absent")?;
    table=codebook::LENGTHS;table[1]=12;reject(Decoder::new(table),"table length exceeds11")?;
    table=codebook::LENGTHS;table[1]=1;reject(Decoder::new(table),"table Kraft oversubscribed")?;
    table=codebook::LENGTHS;table[0]=0;reject(Decoder::new(table),"table Kraft incomplete")?;
    let mut full=[8u8;257];full[255]=9;full[256]=9;let max_dec=Decoder::new(full)?;let max_enc=Encoder::new(full)?;
    if max_dec.nodes()!=513{return Err("maximum trie513 boundary".into());}
    let mut w=Writer::new(9)?;max_enc.write(255,&mut w)?;let(bytes,bits)=finish(w)?;
    if max_dec.read(&mut Reader{bytes:&bytes,bits,position:0})?!=255{return Err("maximum trie final symbol".into());}
    Ok(())
}
fn leaf_wire(k:usize,mode:usize,dominant:usize,codes:&[u8],enc:&Encoder)->Result<(Vec<u8>,usize)> {
    let width=if k==2{1}else{2};let bits=match mode{0=>3,1=>3+width,_=>2+width+codes.iter().map(|&c|codebook::fee(c)).sum::<usize>()};
    let mut w=Writer::new(bits)?;w.write(0,1)?;match mode{0=>w.write(3,2)?,1=>{w.write(2,2)?;w.write(dominant as u32,width)?;},_=>{w.write(0,1)?;w.write(dominant as u32,width)?;for &c in codes{enc.write(c,&mut w)?;}}}finish(w)
}
fn roots(enc:&Encoder,dec:&Decoder)->Result<usize>{
    let mut comparisons=0;
    for k in 2..=4{for mode in 0..3{let dominant_range=if mode==0{1}else{k};for dominant in 0..dominant_range{
        let codes=(0..k-1).map(|i|if i%2==0{0u8}else{1u8}).collect::<Vec<_>>();let(bytes,bits)=leaf_wire(k,mode,dominant,&codes,enc)?;
        let parsed=model::parse_root(&bytes,bits,k,dec)?;let mut expected=[0u16;4];
        match mode{0=>expected=model::uniform(k)?,1=>{expected[..k].fill(2);expected[dominant]=32768-2*(k as u16-1);},_=>{let mut j=0;let mut used=0;for i in 0..k{if i!=dominant{expected[i]=model::MINOR_LUT[usize::from(codes[j])];used+=expected[i];j+=1;}}expected[dominant]=32768-used;}}
        for h in 0..1024u16{if parsed.lookup(0,k,h)?!=expected{return Err("allk mode/dominant exact CDF".into());}comparisons+=1;}
    }}}
    // 元history low/high順をdepth5まで独立に期待する。
    fn deep(w:&mut Writer,depth:usize,k:usize)->Result<()>{if depth<5{w.write(1,1)?;for _ in 0..4{deep(w,depth+1,k)?;}}else{w.write(0,1)?;w.write(2,2)?;w.write(0,if k==2{1}else{2})?;}Ok(())}
    for high in [false,true]{let bits=341+1+1024*4;let mut w=Writer::new(bits)?;w.write(1,1)?;w.write(u32::from(high),1)?;for _ in 0..4{deep(&mut w,1,2)?;}let(bytes,bits)=finish(w)?;let p=model::parse_root(&bytes,bits,2,dec)?;
        for h in 0..1024u16{if p.lookup(0,2,h)?!=[32766,2,0,0]{return Err("depth5 order pure allCDF".into());}comparisons+=1;}
    }
    let hist=model::Hist::new()?;let low=model::Fit::build(&hist)?;let high=model::Fit::build_high(&hist)?;let selected=model::Selected::new(&low,&high)?;
    for k in 2..=4{let(bytes,bits)=selected.root_wire(k,enc)?;if bits!=3 || selected.root_objective_bits(k)?!=0 || !selected.root_default(k)? || selected.root_high(k)?{return Err("default internal0/oracle3/order0".into());}let _=model::parse_root(&bytes,bits,k,dec)?;}
    Ok(comparisons)
}
fn malformed_roots(enc:&Encoder,dec:&Decoder)->Result<usize>{
    let good=leaf_wire(2,2,0,&[1],enc)?;let mut count=0;
    let cases=[(fields(&[(0,1),(2,2),(3,2)])?,3,"pure dominant index"),
        (fields(&[(0,1),(0,1),(3,2)])?,3,"compact dominant index"),
        (fields(&[(1,1),(1,1),(1,1),(1,1),(1,1),(1,1),(1,1),(1,1)])?,2,"paid split beyond depth5"),
        (fields(&[(1,1)])?,2,"truncated paid field/code/raw")];
    for((bytes,bits),k,reason)in cases{reject(model::parse_root(&bytes,bits,k,dec),reason)?;let _=model::parse_root(&good.0,good.1,2,dec)?;count+=1;}
    for(k,codes,reason)in [(4,vec![255,255,255],"compact residual underflow"),(3,vec![255,255],"compact residual largest/minimum")]{let(bytes,bits)=leaf_wire(k,2,0,&codes,enc)?;reject(model::parse_root(&bytes,bits,k,dec),reason)?;let _=model::parse_root(&good.0,good.1,2,dec)?;count+=1;}
    for bits in [1,2,3,good.1-1]{let len=bits.div_ceil(8);let mut bytes=good.0[..len].to_vec();if bits%8!=0{*bytes.last_mut().ok_or("finite trunc")?&=255<<(8-bits%8);}reject(model::parse_root(&bytes,bits,2,dec),"truncated paid field/code/raw")?;let _=model::parse_root(&good.0,good.1,2,dec)?;count+=1;}
    let(mut b,bits)=good.clone();*b.last_mut().ok_or("finite pad")?|=1;reject(model::parse_root(&b,bits,2,dec),"root padding")?;count+=1;
    let mut w=Writer::new(good.1+1)?;for i in 0..good.1{w.write(u32::from((good.0[i/8]>>(7-i%8))&1),1)?;}w.write(0,1)?;let(b,bits)=finish(w)?;reject(model::parse_root(&b,bits,2,dec),"root trailing bits")?;count+=1;
    let _=model::parse_root(&good.0,good.1,2,dec)?;Ok(count)
}
fn paid_boundary(enc:&Encoder,dec:&Decoder)->Result<()> {
    let mut hist=model::Hist::new()?;for(h,row)in [(0,[50,1,0,0]),(1,[50,1,0,0]),(2,[50,29,0,0]),(3,[50,29,0,0])]{bundle::ingest(&mut hist,2,h,row)?;}
    let old=crate::model::Fit::build(&hist)?;let new=model::Fit::build(&hist)?;
    if !old.root_split(2)? || new.root_split(2)? || old.root_objective_bits(2)?!=50 || new.root_objective_bits(2)?!=9{return Err("actual paid boundary old split50/new leaf9".into());}
    let repriced=new.reprice_old(&old,&hist,2)?;if repriced.bits!=48{return Err("boundary selected old reprice48".into());}
    let(b,bits)=new.root_wire(2,enc)?;let p=model::parse_root(&b,bits,2,dec)?;let expected=[25258,7510,0,0];for h in 0..1024u16{if p.lookup(0,2,h)?!=expected{return Err("boundary leaf actual CDF".into());}}
    near(new.root_loss(2)?,200.0*(32768.0/25258.0f64).log2()+60.0*(32768.0/7510.0f64).log2())?;
    // splitのorder bit2/internal bit1、最大深さと履歴反転を実DPから確認する。
    for oldest in [false,true]{let mut low=model::Hist::new()?;let mut high=model::Hist::new()?;
        for h in 0..1024u16{let mut row=[0;4];row[if oldest{(usize::from(h)>>8)%2}else{usize::from(h)%2}]=64;bundle::ingest(&mut low,2,h,row)?;bundle::ingest(&mut high,2,model::reverse_history(h),row)?;}
        let l=model::Fit::build(&low)?;let r=model::Fit::build_high(&high)?;let s=model::Selected::new(&l,&r)?;
        if l.root_objective_bits(2)?!=if oldest{4438}else{18} || r.root_objective_bits(2)?!=if oldest{18}else{4438} || s.root_high(2)?!=oldest || s.root_order_bits(2)?!=1{return Err("paid symmetric root fee/order".into());}
        let(b,bits)=s.root_wire(2,enc)?;let p=model::parse_root(&b,bits,2,dec)?;
        for h in 0..1024u16{if p.lookup(0,2,h)?!=s.lookup(0,2,h)?{return Err("paid symmetric original history CDF".into());}}
    }Ok(())
}
fn globals(enc:&Encoder)->Result<(usize,usize)> {
    let hist=model::Hist::new()?;let low=model::Fit::build(&hist)?;let high=model::Fit::build_high(&hist)?;let selected=model::Selected::new(&low,&high)?;
    let mut packet=bundle::Packet::new(enc)?;for _ in 0..278{for k in 2..=4{packet.append_root(&selected,k)?;}}
    let good=packet.finish()?;if good.len()!=239{return Err("all default paid table239".into());}
    let mut comparisons=0;let forest=bundle::Forest::parse(&good)?;
    for c in 0..2{let tree=crate::grammar::Tree::new(if c==0{257}else{256});for n in 0..142{if tree.class(n)?==2{for k in 2..=4{for h in 0..1024u16{if forest.lookup(c,n,k,h)?!=model::uniform(k)?{return Err("finite paid all default Forest".into());}comparisons+=1;}}}}}drop(forest);
    let mut rejects=0;
    for case in 0..12{let mut bad=good.clone();let reason=match case{
        0=>{bad.truncate(133);"header bytes bound"},1=>{bad[0]=0;"header codec flag"},2=>{bad[133]|=1;"table nibble padding"},
        3=>{bad[1..5].copy_from_slice(&0u32.to_le_bytes());"header exact bits/bytes"},4=>{bad[1..5].copy_from_slice(&((bundle::MAX_BUNDLE_BITS+1) as u32).to_le_bytes());"header exact bits/bytes"},
        5=>{bad.pop();"header exact bits/bytes"},6=>{bad.push(0);"header exact bits/bytes"},7=>{*bad.last_mut().ok_or("finite pad")?|=1;"header zero padding"},
        8=>{bad[5]=(bad[5]&240)|12;"table length exceeds11"},9=>{bad[133]=0;"table ESC absent"},10=>{bad[5]=(bad[5]&240)|1;"table Kraft oversubscribed"},_=>{bad[5]&=15;"table Kraft incomplete"}
    };reject(bundle::Forest::parse(&bad),reason)?;let _=bundle::Forest::parse(&good)?;rejects+=1;}
    // complete table変更をdecoderが実際に使うことを、known0とunknown1の位置交換で確認する。
    let mut swapped=codebook::LENGTHS;swapped.swap(0,1);let alt=Encoder::new(swapped)?;let mut w=Writer::new(7)?;alt.write(1,&mut w)?;let(payload,bits)=finish(w)?;
    let header=codebook::header(&payload,bits,&swapped)?;let(table,bits,payload)=codebook::read_header(&header,19)?;let alt_dec=Decoder::new(table)?;
    if alt_dec.read(&mut Reader{bytes:payload,bits,position:0})?!=1{return Err("decoder uses actual wire table".into());}
    // 全834flags後の余分なbitはReader::finishで拒否する。
    let mut w=Writer::new(835)?;for _ in 0..835{w.write(0,1)?;}let(payload,bits)=finish(w)?;let bad=codebook::header(&payload,bits,&codebook::LENGTHS)?;
    reject(bundle::Forest::parse(&bad),"global model count/trailing bits")?;let _=bundle::Forest::parse(&good)?;rejects+=1;
    drop(good);drop(selected);drop(low);drop(high);drop(hist);
    let mut low=model::Hist::new()?;let mut high=model::Hist::new()?;
    for(k,h,row)in [(2,0,[1000,0,0,0]),(2,1,[0,1000,0,0]),(3,0,[30000,1700,1068,0]),(4,0,[30000,1000,1000,768])]{bundle::ingest(&mut low,k,h,row)?;bundle::ingest(&mut high,k,model::reverse_history(h),row)?;}
    let l=model::Fit::build(&low)?;let r=model::Fit::build_high(&high)?;let fit=model::Selected::new(&l,&r)?;
    let mut packet=bundle::Packet::new(enc)?;for _ in 0..278{for k in 2..=4{packet.append_root(&fit,k)?;}}let mixed=packet.finish()?;
    let forest=bundle::Forest::parse(&mixed)?;
    for c in 0..2{let tree=crate::grammar::Tree::new(if c==0{257}else{256});for n in 0..142{if tree.class(n)?==2{for k in 2..=4{for h in 0..1024u16{if forest.lookup(c,n,k,h)?!=fit.lookup(0,k,h)?{return Err("finite mixed paid global Forest/Fit CDF".into());}comparisons+=1;}}}}}
    Ok((comparisons,rejects))
}
pub fn run()->Result<String>{
    codebook::validate_fixed()?;let enc=Encoder::new(codebook::LENGTHS)?;let dec=Decoder::new(codebook::LENGTHS)?;
    book_cases(&enc,&dec)?;let leaf_cdfs=roots(&enc,&dec)?;let root_rejections=malformed_roots(&enc,&dec)?;paid_boundary(&enc,&dec)?;let(forest_cdfs,header_rejections)=globals(&enc)?;
    Ok(format!("{{\"canonical_symbol_comparisons\":257,\"minor_roundtrips\":256,\"known_symbols\":183,\"unknown_symbols\":73,\"ESC_length\":11,\"unknown_fee_bits\":19,\"all_mode_dominant_root_cases\":21,\"finite_root_CDF_comparisons\":{leaf_cdfs},\"root_rejections\":{root_rejections},\"table_header_rejections\":{header_rejections},\"finite_Forest_CDF_comparisons\":{forest_cdfs},\"paid_Fit_builds\":11,\"baseline_Fit_builds\":1,\"baseline_repricing_passes\":1,\"baseline_root_scans\":1,\"baseline_CDF_comparisons\":1024,\"book_redundant_ESC_rejections\":1,\"book_truncation_rejections\":4,\"book_table_rejections\":4,\"paid_boundary_old_split_bits\":50,\"paid_boundary_repriced_split_bits\":48,\"paid_boundary_new_leaf_bits\":9,\"rejection_reasons_verified\":true,\"same_process_recovery\":true,\"wire_table_used\":true,\"entropy_encoder_implemented\":true,\"entropy_decoder_verified\":true,\"RAM_only\":true}}"))
}
