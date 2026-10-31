//! FAILURE_PLAN保存後に実装した有限E2E。凍結元E2Eは直接参照。
use crate::{paid_model,packet};
#[path="../temporal-node-information/e2e.rs"] mod frozen;
type Result<T>=std::result::Result<T,String>;
fn parse_all(bytes:&[u8])->Result<()>{
    let mut r=packet::Reader::new(bytes)?;for _ in 0..284{let _=r.next()?;}r.finish()
}
fn expected_uniform(k:usize)->[u16;4]{
    // 元quantizeを呼ばない独立算術。
    let mut f=[0;4];let base=32768/k;let rem=32768%k;
    for i in 0..k{f[i]=(base+usize::from(i<rem)) as u16;}f
}
fn fixture(mode:usize)->Result<usize>{
    let mut hist=paid_model::Hist::new()?;let mut rows=vec![[0u32;4];3072];
    for k in 2..=4{for h in 0..1024u16{
        let mut row=[0;4];
        if mode==1{row[0]=23;row[k-1]=3;}
        if mode==2{row[(usize::from(h)>>8)%k]=256;}
        if mode==3{row[usize::from(h)%k]=2;row[0]+=29;}
        packet::ingest(&mut hist,k,h,row)?;rows[(k-2)*1024+usize::from(h)]=row;
    }}
    let fit=paid_model::Fit::build(&hist)?;let mut p=packet::Packet::new()?;
    let mut root_rejections=0;let mut oracle=0.0;
    for k in 2..=4{
        let (wire,bits)=fit.root_wire(k)?;let parsed=paid_model::parse_root(&wire,bits,k)?;
        for h in 0..1024u16{
            let f=parsed.lookup(0,k,h)?;if f!=fit.lookup(0,k,h)?{return Err("finite root CDF".into());}
            if mode==0 && f!=expected_uniform(k){return Err("independent default Hamilton".into());}
            let row=rows[(k-2)*1024+usize::from(h)];
            for i in 0..k{if row[i]!=0{oracle+=f64::from(row[i])*(15.0-f64::from(f[i]).log2());}}
        }
        if mode==0 && k==2{
            if paid_model::parse_root(&wire,bits,1).is_ok(){return Err("invalid root k accepted".into());}root_rejections+=1;
            if paid_model::parse_root(&wire,bits-1,k).is_ok(){return Err("truncated root accepted".into());}root_rejections+=1;
            let mut extra=wire.clone();extra.resize((bits+1).div_ceil(8),0);
            if paid_model::parse_root(&extra,bits+1,k).is_ok(){return Err("extra root bit accepted".into());}root_rejections+=1;
            let recovery=paid_model::parse_root(&wire,bits,k)?;
            if recovery.lookup(0,k,0)?!=expected_uniform(k){return Err("root rejection recovery".into());}
        }
        drop(wire);drop(parsed);p.root(&fit,k)?;
    }
    if !crate::tiles::close(oracle,fit.loss_bits()){return Err("independent weighted DP oracle".into());}
    if mode==2 && fit.selected_split_count()<5{return Err("depth5 split fixture did not split".into());}
    for _ in 3..packet::ROOTS{p.write(0,1)?;}
    let bytes=p.finish()?;let mut r=packet::Reader::new(&bytes)?;let mut actual=0.0;
    for n in 0..284{
        let d=r.next()?;
        for k in 2..=4{for h in 0..1024u16{
            let f=d.lookup(0,k,h)?;
            let expected=if n==0{fit.lookup(0,k,h)?}else{expected_uniform(k)};
            if f!=expected{return Err("finite completed packet allCDF".into());}
            if n==0{let row=rows[(k-2)*1024+usize::from(h)];for i in 0..k{if row[i]!=0{actual+=f64::from(row[i])*(15.0-f64::from(f[i]).log2());}}}
        }}
    }
    r.finish()?;
    if !crate::tiles::close(actual,oracle){return Err("finite packet weighted loss".into());}
    if mode==0 && (bytes.len()!=111 || r.defaults!=852){return Err("minimum packet extent".into());}
    Ok(root_rejections)
}
fn rejection_recovery()->Result<usize>{
    let mut p=packet::Packet::new()?;for _ in 0..852{p.write(0,1)?;}let good=p.finish()?;let mut rejected=0;
    // 各malformed packetは逐次生成・破棄。正常packet111Bだけ回復用に保持する。
    for case in 0..8{
        let mut bad=good.clone();
        match case{
            0=>bad.truncate(3),
            1=>bad[..4].copy_from_slice(&0u32.to_le_bytes()),
            2=>bad[..4].copy_from_slice(&((packet::MAX_PACKET_BITS+1) as u32).to_le_bytes()),
            3=>{bad.pop();},
            4=>bad.push(0),
            5=>{let last=bad.last_mut().ok_or("finite padding")?;*last|=1;},
            6|7=>{
                drop(bad);let mut malformed=packet::Packet::new()?;malformed.write(1,1)?;
                if case==6{malformed.write(0,1)?;malformed.write(2,2)?;malformed.write(1,15)?;}
                else{for _ in 0..6{malformed.write(1,1)?;}}
                for _ in 1..852{malformed.write(0,1)?;}bad=malformed.finish()?;
            },
            _=>return Err("fixture case".into()),
        }
        let expected=["packet bytes bound","packet exact bits/bytes","packet exact bits/bytes","packet exact bits/bytes","packet exact bits/bytes","packet zero padding","parsed frequency minimum","model split beyond depth5"][case];
        let reason=parse_all(&bad).err().ok_or_else(||format!("malformed packet case {case} accepted"))?;
        if reason!=expected{return Err(format!("malformed packet case {case} reason {reason}, expected {expected}"));}rejected+=1;
        drop(bad);parse_all(&good)?;
    }Ok(rejected)
}
fn weighted_rejections()->Result<usize>{
    let mut hist=paid_model::Hist::new()?;let mut rejected=0;
    for (k,row) in [(1,[0;4]),(2,[0,0,1,0]),(2,[paid_model::CAP,1,0,0])]{
        if packet::ingest(&mut hist,k,0,row).is_ok() || hist.counts.iter().any(|&r|r!=[0;4]){return Err("weighted rejection atomicity".into());}rejected+=1;
    }
    let mut broken=paid_model::Hist{counts:Vec::new()};
    if packet::ingest(&mut broken,2,0,[1,0,0,0]).is_ok(){return Err("weighted shape accepted".into());}rejected+=1;
    packet::ingest(&mut hist,2,0,[1,0,0,0])?;let _=paid_model::Fit::build(&hist)?;Ok(rejected)
}
fn bits_wire(fields:&[(u32,usize)])->(Vec<u8>,usize){
    let bits=fields.iter().map(|x|x.1).sum::<usize>();let mut bytes=vec![0u8;bits.div_ceil(8)];let mut p=0;
    for &(v,w) in fields{for s in (0..w).rev(){if v&(1<<s)!=0{bytes[p/8]|=1<<(7-p%8);}p+=1;}}(bytes,bits)
}
fn short_oracles()->Result<String>{
    let mut pure_cases=0;
    for k in 2..=4{for dominant in 0..k{
        let mut hist=paid_model::Hist::new()?;let mut row=[0;4];row[dominant]=17;packet::ingest(&mut hist,k,0,row)?;
        let fit=paid_model::Fit::build(&hist)?;let(wire,bits)=fit.root_wire(k)?;let expected_bits=if k==2{4}else{5};
        let mut expected=[0u16;4];expected[..k].fill(2);expected[dominant]=(32768-2*(k-1)) as u16;
        let d=paid_model::parse_root(&wire,bits,k)?;
        if bits!=expected_bits || fit.root_objective_bits(k)?!=expected_bits || fit.root_default(k)?{return Err("pure independent wire/DP bits".into());}
        for h in 0..1024u16{if d.lookup(0,k,h)?!=expected || fit.lookup(0,k,h)?!=expected{return Err("pure independent allCDF".into());}}
        let loss=17.0*(15.0-f64::from(expected[dominant]).log2());
        if !crate::tiles::close(loss,fit.root_loss(k)?){return Err("pure independent loss".into());}pure_cases+=1;
    }}
    // 手製内部uniform: split1 + four*(leaf split0 + mode00)=13bits。
    let mut fields=vec![(1,1)];for _ in 0..4{fields.push((0,1));fields.push((0,2));}
    let(wire,bits)=bits_wire(&fields);let d=paid_model::parse_root(&wire,bits,3)?;
    if bits!=13{return Err("internal uniform bit oracle".into());}
    for h in 0..1024u16{if d.lookup(0,3,h)?!=[10923,10923,10922,0]{return Err("internal uniform CDF".into());}}
    let mut raw_cases=0;
    for (k,f) in [(2,[9000u16,23768,0,0]),(3,[5000,5000,22768,0]),(4,[4000,5000,6000,17768])]{
        let mut fields=vec![(0,1),(2,2)];for &v in &f[..k-1]{fields.push((u32::from(v),15));}
        let(w,b)=bits_wire(&fields);let d=paid_model::parse_root(&w,b,k)?;
        if b!=[18,33,48][k-2]{return Err("raw independent bit oracle".into());}
        for h in 0..1024u16{if d.lookup(0,k,h)?!=f{return Err("raw independent CDF".into());}}raw_cases+=1;
    }
    let empty=paid_model::Hist::new()?;let fit=paid_model::Fit::build(&empty)?;let mut p=packet::Packet::new()?;
    for k in 2..=4{
        let(w,b)=fit.root_wire(k)?;
        if fit.root_objective_bits(k)?!=0 || b!=3 || !fit.root_default(k)?{return Err("default DP0/oracle3".into());}
        let d=paid_model::parse_root(&w,b,k)?;
        for h in 0..1024u16{if d.lookup(0,k,h)?!=expected_uniform(k){return Err("default independent CDF".into());}}
        let(default,checked)=p.root(&fit,k)?;if !default || checked!=0{return Err("default packet omitted oracle wire".into());}
    }
    for _ in 3..852{p.write(0,1)?;}let default_packet=p.finish()?;
    if u32::from_le_bytes(default_packet[..4].try_into().map_err(|_|"oracle field")?)!=852{return Err("default only outer bits".into());}
    parse_all(&default_packet)?;
    // 先行censusの空default費用0とdepth5全split実費を独立算術で照合。
    for high in [false,true]{
        let mut hist=paid_model::Hist::new()?;
        if high{for h in 0..1024u16{let mut row=[0;4];row[(usize::from(h)>>8)%2]=64;packet::ingest(&mut hist,2,h,row)?;}}
        let fit=paid_model::Fit::build(&hist)?;
        let expected_bits=if high{341+1024*4}else{0};let expected_loss=if high{65536.0*(15.0-32766.0f64.log2())}else{0.0};
        if fit.root_objective_bits(2)?!=expected_bits || !crate::tiles::close(fit.root_loss(2)?,expected_loss)
            || fit.selected_split_count()!=if high{341}else{0}{return Err("DP leaf/split fee boundary independent oracle".into());}
        let(w,b)=fit.root_wire(2)?;let d=paid_model::parse_root(&w,b,2)?;
        if b!=if high{4437}else{3}{return Err("DP boundary wire fee".into());}
        for h in 0..1024u16{if d.lookup(0,2,h)?!=fit.lookup(0,2,h)?{return Err("DP boundary parsed CDF".into());}}
    }
    let good=bits_wire(&[(0,1),(1,2),(0,2)]);let mut wire_rejections=0;
    for (fields,k,reason) in [
        (vec![(0,1),(3,2)],2,"reserved leaf mode"),
        (vec![(0,1),(1,2),(3,2)],3,"pure dominant index"),
        (vec![(0,1),(0,1)],2,"truncated model field"),
        (vec![(0,1),(1,2),(0,1)],3,"truncated model field"),
    ]{
        let(w,b)=bits_wire(&fields);let actual=paid_model::parse_root(&w,b,k).err().ok_or("short malformed wire accepted")?;
        if actual!=reason{return Err(format!("short wire reason {actual}, expected {reason}"));}
        let d=paid_model::parse_root(&good.0,good.1,3)?;if d.lookup(0,3,0)?!=[32764,2,2,0]{return Err("short rejected recovery".into());}wire_rejections+=1;
    }
    if pure_cases!=9 || raw_cases!=3 || wire_rejections!=4{return Err("short oracle census".into());}
    Ok(format!("{{\"pure_cases\":{pure_cases},\"pure_all_CDF_comparisons\":9216,\"internal_uniform_cases\":1,\"raw_cases\":{raw_cases},\"default_root_cases\":3,\"default_DP_zero_oracle_three\":true,\"DP_boundary_cases\":2,\"wire_rejections\":{wire_rejections},\"rejection_reasons_verified\":true}}"))
}
pub fn run()->Result<String>{
    let short=short_oracles()?;
    let old=frozen::run()?;let mut roots=0;for mode in 0..4{roots+=fixture(mode)?;}
    let malformed=rejection_recovery()?;let weighted=weighted_rejections()?;
    if roots!=3 || malformed!=8 || weighted!=4{return Err("finite E2E rejection census".into());}
    Ok(format!("{{\"short_leaf\":{short},\"frozen_temporal\":{old},\"packet_normal_cases\":4,\"packet_all_CDF_comparisons\":3489792,\"root_rejections\":{roots},\"packet_rejections\":{malformed},\"weighted_rejections\":{weighted},\"same_process_recovery\":true,\"independent_default_Hamilton\":true,\"independent_weighted_loss\":true,\"depth5_split\":true,\"packet_files_saved\":0}}"))
}
