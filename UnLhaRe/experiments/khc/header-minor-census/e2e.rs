//! 先行failure-firstで固定した有限census。entropy decoderは未実装。
use crate::{census,model,bundle};
type Result<T>=std::result::Result<T,String>;
fn huffman_cases()->Result<()>{
    let mut hist=[0u32;256];let empty=census::estimate(&hist,0,0)?;
    if empty.huffman_valid || empty.chosen_bytes!=5 || empty.fallback_reason!="empty" || empty.lengths!=[0;256]{return Err("empty raw oracle".into());}
    hist[7]=2100;let singleton=census::estimate(&hist,23405,993)?;
    if singleton.lengths[7]!=1 || singleton.max_depth!=1 || singleton.weighted_code_bits!=2100 || singleton.chosen_bytes!=1097
        || !singleton.huffman_chosen || !singleton.kraft_valid{return Err("singleton paid1097 oracle".into());}
    hist.fill(8);let uniform=census::estimate(&hist,23405,993)?;
    if uniform.lengths!=[8;256] || uniform.weighted_code_bits!=16384 || uniform.huffman_bytes!=Some(2935)
        || uniform.raw_bytes!=2807 || uniform.chosen_bytes!=2807 || uniform.huffman_chosen{return Err("uniform paid raw2807 oracle".into());}
    hist.fill(0);hist[0]=20;hist[1]=3;hist[2]=1;let biased=census::estimate(&hist,300,1)?;
    if biased.lengths[..3]!=[1,2,2] || biased.weighted_code_bits!=28 || !biased.kraft_valid{return Err("biased independent Huffman oracle".into());}
    hist.fill(0);let mut a=1u32;let mut b=1u32;
    for i in 0..18{hist[i]=a;let next=a.checked_add(b).ok_or("finite Fibonacci")?;a=b;b=next;}
    let n=hist.iter().map(|&v|v as usize).sum::<usize>();let deep=census::estimate(&hist,n*8+100,0)?;
    if deep.max_depth<=15 || deep.huffman_valid || deep.huffman_bytes.is_some() || deep.fallback_reason!="max_depth_exceeds_15"{return Err("length>15 raw fallback oracle".into());}
    let again=census::estimate(&hist,n*8+100,0)?;
    if again.lengths!=deep.lengths || again.weighted_code_bits!=deep.weighted_code_bits{return Err("deterministic Huffman repeated oracle".into());}
    for (first,second,reason) in [
        (census::MAX_MINOR+1,0,"Huffman maximum weight"),
        (census::MAX_MINOR,1,"Huffman maximum total"),
        (u32::MAX,1,"Huffman histogram sum overflow"),
    ]{
        hist.fill(0);hist[0]=first;hist[1]=second;let actual=census::estimate(&hist,usize::MAX/2,0).err().ok_or("invalid weights accepted")?;
        if actual!=reason{return Err("histogram rejection reason".into());}
        hist.fill(0);hist[7]=2100;let recovery=census::estimate(&hist,23405,993)?;
        if recovery.chosen_bytes!=1097{return Err("Huffman rejection recovery".into());}
    }Ok(())
}
fn wire(fields:&[(u32,usize)],bits_override:Option<usize>)->Vec<u8>{
    let bits=fields.iter().map(|x|x.1).sum::<usize>();let mut out=vec![0u8;4+bits.div_ceil(8)];let mut p=0;
    for &(v,width) in fields{for s in (0..width).rev(){if v&(1<<s)!=0{out[4+p/8]|=1<<(7-p%8);}p+=1;}}
    out[..4].copy_from_slice(&(bits_override.unwrap_or(bits) as u32).to_le_bytes());out
}
fn hand_fixture()->Result<Vec<u8>>{
    let mut f=vec![(1,1),(0,1),(0,2),(1,1),(0,1),(1,2),(2,2),(1,1),(0,1),(2,2),(0,2),(0,8),(1,8),(2,8)];
    for order in [0,1]{f.extend([(1,1),(1,1),(order,1)]);for _ in 0..4{f.extend([(0,1),(0,2)]);}}
    f.push((0,1));for _ in 6..834{f.push((0,1));}let bytes=wire(&f,None);let c=census::scan(&bytes)?;
    let mut hist=[0u32;256];hist[0]=1;hist[1]=1;hist[2]=1;
    if c.payload_bits!=899 || c.packet_bytes!=117 || c.defaults!=829 || c.splits!=2
        || c.uniform!=9 || c.pure!=1 || c.compact!=1 || c.low_orders!=1 || c.high_orders!=1
        || c.histogram!=hist || c.estimate.total!=3 || c.split_field_bits!=13 || c.mode_field_bits!=22
        || c.dominant_field_bits!=4 || c.minor_field_bits!=24 || c.prefix_payload_bits!=898
        || c.estimate.raw_bytes!=118 || c.estimate.weighted_code_bits!=5 || c.estimate.lengths[..3]!=[2,2,1]{return Err("independent typed raw packet899 fields/tie".into());}
    Ok(bytes)
}
fn selected_packet()->Result<()>{
    let mut low=model::Hist::new()?;let mut high=model::Hist::new()?;
    for (k,h,row) in [(2,0u16,[100,0,0,0]),(2,1,[0,100,0,0]),(3,0,[60,30,10,0])]{
        bundle::ingest(&mut low,k,h,row)?;bundle::ingest(&mut high,k,model::reverse_history(h),row)?;
    }
    let l=model::Fit::build(&low)?;let h=model::Fit::build_high(&high)?;let selected=model::Selected::new(&l,&h)?;
    let mut p=bundle::Packet::new()?;for _ in 0..278{for k in 2..=4{p.append_root(&selected,k)?;}}let bytes=p.finish()?;let c=census::scan(&bytes)?;
    let modes=selected.selected_mode_counts()?;let mut low_order=0;let mut high_order=0;
    for k in 2..=4{if selected.root_split(k)?{if selected.root_high(k)?{high_order+=278;}else{low_order+=278;}}}
    let defaults=(2..=4).map(|k|selected.root_default(k).map(usize::from)).collect::<Result<Vec<_>>>()?.iter().sum::<usize>()*278;
    c.verify_existing(u32::from_le_bytes(bytes[..4].try_into().map_err(|_|"finite selected field")?) as usize,
        defaults,selected.selected_leaf_count()?*278,selected.selected_split_count()?*278,low_order,high_order,modes.map(|n|n*278))?;
    Ok(())
}
fn parser_cases()->Result<()>{
    let default=wire(&vec![(0,1);834],None);let c=census::scan(&default)?;
    if c.defaults!=834 || c.payload_bits!=834 || c.packet_bytes!=109 || c.estimate.chosen_bytes!=110 || c.estimate.total!=0{return Err("all default109/raw110 oracle".into());}
    let good=hand_fixture()?;selected_packet()?;
    for case in 0..12{
        let mut bad=default.clone();let reason=match case{
            0=>{bad.truncate(3);"census bytes bound"},
            1=>{bad[..4].copy_from_slice(&0u32.to_le_bytes());"census exact bytes/bits"},
            2=>{bad[..4].copy_from_slice(&((bundle::MAX_BUNDLE_BITS+1) as u32).to_le_bytes());"census exact bytes/bits"},
            3=>{bad.pop();"census exact bytes/bits"},
            4=>{bad.push(0);"census exact bytes/bits"},
            5=>{*bad.last_mut().ok_or("finite pad")?|=1;"census zero padding"},
            6=>{let mut f=vec![(1,1),(0,1),(3,2)];for _ in 1..834{f.push((0,1));}bad=wire(&f,None);"census reserved mode"},
            7=>{let mut f=vec![(0,1),(1,1),(0,1),(2,2),(3,2)];for _ in 2..834{f.push((0,1));}bad=wire(&f,None);"census compact dominant index"},
            8=>{let mut f=vec![(1,1),(1,1),(1,1),(1,1),(1,1),(1,1),(1,1),(1,1)];for _ in 1..834{f.push((0,1));}bad=wire(&f,None);"census depth exceeds 5"},
            9=>{
                // 前833default、最後k4 explicit splitでbit終端。order fieldがない。
                let mut f=vec![(0,1);833];f.extend([(1,1),(1,1)]);bad=wire(&f,None);"census truncated field"
            },
            10=>{let mut f=vec![(0,1),(0,1),(1,1),(0,1),(2,2),(0,2),(255,8),(255,8),(255,8)];for _ in 3..834{f.push((0,1));}bad=wire(&f,None);"census residual underflow"},
            _=>{let mut f=vec![(0,1),(1,1),(0,1),(2,2),(0,2),(255,8),(255,8)];for _ in 2..834{f.push((0,1));}bad=wire(&f,None);"census residual largest/minimum"},
        };
        let actual=census::scan(&bad).err().ok_or_else(||format!("census malformed {case} accepted"))?;
        if actual!=reason{return Err(format!("census malformed {case}: {actual}, expected {reason}"));}
        let recovery=census::scan(&good)?;if recovery.estimate.total!=3{return Err("census rejection recovery".into());}
    }Ok(())
}
pub fn run()->Result<String>{
    huffman_cases()?;parser_cases()?;
    Ok("{\"Huffman_normal_cases\":5,\"Huffman_weight_rejections\":3,\"parser_normal_cases\":3,\"parser_rejections\":12,\"independent_typed_payload_bits\":899,\"independent_typed_minor_count\":3,\"singleton_paid_metadata_bytes\":1097,\"uniform_raw_metadata_bytes\":2807,\"Kraft_verified\":true,\"deterministic_tie_verified\":true,\"rejection_reasons_verified\":true,\"same_process_recovery\":true,\"entropy_encoder_implemented\":false,\"entropy_decoder_verified\":false}".into())
}

