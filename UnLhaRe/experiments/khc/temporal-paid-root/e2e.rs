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
                if case==6{malformed.write(0,1)?;malformed.write(1,15)?;}
                else{for _ in 0..6{malformed.write(1,1)?;}}
                for _ in 1..852{malformed.write(0,1)?;}bad=malformed.finish()?;
            },
            _=>return Err("fixture case".into()),
        }
        if parse_all(&bad).is_ok(){return Err(format!("malformed packet case {case} accepted"));}rejected+=1;
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
pub fn run()->Result<String>{
    let old=frozen::run()?;let mut roots=0;for mode in 0..4{roots+=fixture(mode)?;}
    let malformed=rejection_recovery()?;let weighted=weighted_rejections()?;
    if roots!=3 || malformed!=8 || weighted!=4{return Err("finite E2E rejection census".into());}
    Ok(format!("{{\"frozen_temporal\":{old},\"packet_normal_cases\":4,\"packet_all_CDF_comparisons\":3489792,\"root_rejections\":{roots},\"packet_rejections\":{malformed},\"weighted_rejections\":{weighted},\"same_process_recovery\":true,\"independent_default_Hamilton\":true,\"independent_weighted_loss\":true,\"depth5_split\":true,\"packet_files_saved\":0}}"))
}

