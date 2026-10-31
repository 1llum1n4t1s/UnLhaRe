//! 保存済failure-firstに対応する有限E2E。
use crate::{model,bundle,grammar};
type Result<T>=std::result::Result<T,String>;
fn near(a:f64,b:f64)->Result<()>{if !a.is_finite() || !b.is_finite() || (a-b).abs()>1e-6{return Err("finite loss oracle".into());}Ok(())}
fn wire(fields:&[(u32,usize)])->(Vec<u8>,usize){
    let bits=fields.iter().map(|x|x.1).sum::<usize>();let mut b=vec![0;bits.div_ceil(8)];let mut p=0;
    for &(v,w) in fields{for s in (0..w).rev(){if v&(1<<s)!=0{b[p/8]|=1<<(7-p%8);}p+=1;}}(b,bits)
}
fn uniform(k:usize)->[u16;4]{match k{2=>[16384,16384,0,0],3=>[10923,10923,10922,0],_=>[8192;4]}}
fn independent_lut()->[u16;256]{
    let mut lut=[0u16;256];for i in 0..64{lut[i]=(2+i) as u16;}
    for e in 6..=13{for j in 1..=24{let power=1u32<<e;let product=j*power;let ceil=product/24+u32::from(product%24!=0);lut[64+(e as usize-6)*24+j as usize-1]=(power+ceil).min(16383) as u16;}}lut
}
fn floor(lut:&[u16;256],n:u16)->(u8,u16){let mut code=0;for i in 0..256{if lut[i]<=n{code=i;}else{break;}}(code as u8,lut[code])}
fn lut_oracle()->Result<()>{
    let lut=independent_lut();model::validate_lut()?;
    if lut!=model::MINOR_LUT || lut[0]!=2 || lut[255]!=16383 || lut.windows(2).any(|v|v[0]>=v[1]){return Err("independent LUT256".into());}
    for n in 2..=16383u16{if model::floor_code(n)?!=floor(&lut,n).0{return Err("independent floor16382".into());}}
    for (code,&v) in lut.iter().enumerate(){let f=[32768-v,v,0,0];if model::compact_frequency(f,2)?!=f{return Err("LUT exact frequency roundtrip256".into());}
        let(b,bits)=wire(&[(0,1),(2,2),(0,1),(code as u32,8)]);let d=model::parse_root(&b,bits,2)?;
        for h in [0u16,1023]{if d.lookup(0,2,h)?!=f{return Err("LUT exact wire roundtrip256".into());}}
    }
    for (k,f) in [(2,[16384,16384,0,0]),(3,[12000,12000,8768,0]),(4,[10000,10000,10000,2768])]{
        let compact=model::compact_frequency(f,k)?;if compact[0]<f[0]{return Err("first dominant tie".into());}
        for i in 1..k{if compact[i]>f[i]{return Err("tie minor floor".into());}}
    }Ok(())
}
fn normal_roots()->Result<()>{
    let lut=independent_lut();
    for k in 2..=4{for dominant in 0..k{
        let mut hist=model::Hist::new()?;let mut row=[0;4];row[dominant]=17;bundle::ingest(&mut hist,k,0,row)?;
        let fit=model::Fit::build(&hist)?;let(b,bits)=fit.root_wire(k)?;let d=model::parse_root(&b,bits,k)?;
        let mut expected=[0u16;4];expected[..k].fill(2);expected[dominant]=(32768-2*(k-1)) as u16;
        if bits!=if k==2{4}else{5} || fit.root_objective_bits(k)?!=bits{return Err("pure wire fee oracle".into());}
        for h in 0..1024u16{if d.lookup(0,k,h)?!=expected || fit.lookup(0,k,h)?!=expected{return Err("pure9 allCDF".into());}}
        near(fit.root_loss(k)?,17.0*(15.0-f64::from(expected[dominant]).log2()))?;
        drop(d);drop(b);drop(fit);drop(hist);
        let mut hist=model::Hist::new()?;let mut row=[0u32;4];let mut left=2768u32;
        for i in 0..k{if i!=dominant{let n=left/((k-i-usize::from(dominant>=i)) as u32);row[i]=n;left-=n;}}
        row[dominant]=30000;bundle::ingest(&mut hist,k,0,row)?;
        let q=model::quantize(row,k)?;let mut expected=[0u16;4];let mut sum=0u32;let mut fields=vec![(0,1),(2,2),(dominant as u32,if k==2{1}else{2})];
        for i in 0..k{if i!=dominant{let(code,value)=floor(&lut,q[i]);expected[i]=value;sum+=u32::from(value);fields.push((u32::from(code),8));}}
        expected[dominant]=(32768-sum) as u16;
        let fit=model::Fit::build(&hist)?;let(b,bits)=fit.root_wire(k)?;let d=model::parse_root(&b,bits,k)?;let oracle=wire(&fields);
        if (b,bits)!=oracle || bits!=[12,21,29][k-2] || fit.root_objective_bits(k)?!=bits{return Err("compact9 independent wire".into());}
        for h in 0..1024u16{if d.lookup(0,k,h)?!=expected || fit.lookup(0,k,h)?!=expected{return Err("compact9 allCDF".into());}}
        let mut loss=0.0;let mut old=0.0;for i in 0..k{if row[i]!=0{loss+=f64::from(row[i])*(15.0-f64::from(expected[i]).log2());old+=f64::from(row[i])*(15.0-f64::from(q[i]).log2());}}
        near(fit.root_loss(k)?,loss)?;near(fit.original_selected_loss(&hist)?,old)?;
    }}
    let hist=model::Hist::new()?;let fit=model::Fit::build(&hist)?;
    for k in 2..=4{let(b,bits)=fit.root_wire(k)?;let d=model::parse_root(&b,bits,k)?;
        if bits!=3 || fit.root_objective_bits(k)?!=0 || !fit.root_default(k)?{return Err("root DP0/oracle3".into());}
        for h in 0..1024u16{if d.lookup(0,k,h)?!=uniform(k){return Err("default3 CDF".into());}}
    }
    let(b,bits)=fit.serialize()?;if bits!=9 || bits!=fit.selected_header_bits(){return Err("new canonical uniform oracle9, not old93".into());}let _=model::parse(&b,bits)?;
    drop(b);drop(fit);drop(hist);
    let mut fields=vec![(1,1)];for _ in 0..4{fields.extend([(0,1),(0,2)]);}let(b,bits)=wire(&fields);let d=model::parse_root(&b,bits,3)?;
    if bits!=13{return Err("internal split fee".into());}for h in 0..1024u16{if d.lookup(0,3,h)?!=uniform(3){return Err("internal split CDF".into());}}
    drop(d);drop(b);
    let mut deep=model::Hist::new()?;for h in 0..1024u16{let mut row=[0;4];row[(usize::from(h)>>8)%2]=64;bundle::ingest(&mut deep,2,h,row)?;}
    let f=model::Fit::build(&deep)?;if f.root_objective_bits(2)?!=4437 || f.selected_split_count()!=341{return Err("depth5 DP fee".into());}
    near(f.root_loss(2)?,65536.0*(15.0-32766.0f64.log2()))?;Ok(())
}
fn root_rejections()->Result<()>{
    let good=wire(&[(0,1),(0,2)]);
    let cases=[
        (vec![(0,1),(3,2)],2,"reserved leaf mode"),
        (vec![(0,1),(2,2),(3,2)],3,"compact dominant index"),
        (vec![(0,1),(0,1)],2,"truncated model field"),
        (vec![(0,1),(2,2),(0,1)],3,"truncated model field"),
        (vec![(0,1),(2,2),(0,1),(0,7)],2,"truncated model field"),
        (vec![(0,1),(2,2),(0,2),(255,8),(255,8)],3,"compact residual largest/minimum"),
        (vec![(0,1),(2,2),(0,2),(255,8),(255,8),(255,8)],4,"compact residual underflow"),
        (vec![(1,1);6],2,"model split beyond depth5"),
    ];
    for (fields,k,reason) in cases{let(b,bits)=wire(&fields);let actual=model::parse_root(&b,bits,k).err().ok_or("invalid root accepted")?;
        if actual!=reason{return Err(format!("root reason {actual}, expected {reason}"));}let _=model::parse_root(&good.0,good.1,2)?;}
    for case in 0..4{let(mut b,mut bits)=good.clone();let reason=match case{
        0=>{bits=0;"root exact extent"},1=>{bits=model::MAX_BITS+1;"root exact extent"},
        2=>{bits+=1;"root trailing bits"},_=>{b[0]|=1;"root padding"},
    };let actual=model::parse_root(&b,bits,2).err().ok_or("bad exact root accepted")?;
        if actual!=reason{return Err("exact root rejection reason".into());}let _=model::parse_root(&good.0,good.1,2)?;}
    Ok(())
}
fn weighted_rejections()->Result<()>{
    let mut hist=model::Hist::new()?;bundle::ingest(&mut hist,4,5,[0,10,0,0])?;let before=hist.counts.clone();
    for(k,row,reason)in [(1,[1,0,0,0],"weighted shape/prefix"),(5,[1,0,0,0],"weighted shape/prefix"),(2,[0,0,1,0],"weighted tail/CAP"),(4,[model::CAP+1,0,0,0],"weighted tail/CAP"),(4,[model::CAP,0,0,0],"weighted updated CAP")]{
        let actual=bundle::ingest(&mut hist,k,5,row).err().ok_or("weighted accepted")?;
        if actual!=reason || hist.counts!=before{return Err("weighted atomic rejection/reason".into());}
        let _=model::Fit::build(&hist)?;
    }
    let mut shape=model::Hist{counts:Vec::new()};if bundle::ingest(&mut shape,2,0,[1,0,0,0]).err().as_deref()!=Some("weighted shape/prefix"){return Err("weighted shape rejection reason".into());}
    let mut bad=model::Hist::new()?;bad.counts[0]=[1,0,0,0];if model::Fit::build(&bad).err().as_deref()!=Some("hist parent/children mismatch"){return Err("Hist inconsistent children rejection reason".into());}
    bundle::ingest(&mut hist,2,0,[1,0,0,0])?;let _=model::Fit::build(&hist)?;Ok(())
}
fn global_fixture(mixed:bool)->Result<usize>{
    let mut hist=model::Hist::new()?;if mixed{bundle::ingest(&mut hist,2,0,[100,0,0,0])?;bundle::ingest(&mut hist,2,1,[0,100,0,0])?;}
    let fit=model::Fit::build(&hist)?;let mut p=bundle::Packet::new()?;
    for _ in 0..278{for k in 2..=4{p.append_root(&fit,k)?;}}
    let expected=278*(fit.root_objective_bits(2)?+fit.root_objective_bits(3)?+fit.root_objective_bits(4)?)+834;
    let good=p.finish()?;if u32::from_le_bytes(good[..4].try_into().map_err(|_|"finite global field")?) as usize!=expected{return Err("global independent DP bits".into());}
    if !mixed && good.len()!=109{return Err("global minimum109".into());}
    let forest=bundle::Forest::parse(&good)?;let mut comparisons=0;
    for c in 0..2{let tree=grammar::Tree::new(if c==0{257}else{256});for n in 0..142{if tree.class(n)?==2{for k in 2..=4{for h in 0..1024u16{
        if fit.lookup(0,k,h)?!=forest.lookup(c,n,k,h)?{return Err("finite completed Forest/Fit CDF".into());}comparisons+=1;
    }}}}}
    drop(forest);
    if !mixed{for case in 0..6{
        let mut bad=good.clone();let reason=match case{
            0=>{bad.truncate(3);"global bytes bound"},1=>{bad[..4].copy_from_slice(&0u32.to_le_bytes());"global exact bits/bytes"},
            2=>{bad[..4].copy_from_slice(&((bundle::MAX_BUNDLE_BITS+1) as u32).to_le_bytes());"global exact bits/bytes"},
            3=>{bad.pop();"global exact bits/bytes"},4=>{bad.push(0);"global exact bits/bytes"},
            _=>{*bad.last_mut().ok_or("finite global pad")?|=1;"global zero padding"},
        };
        let actual=bundle::Forest::parse(&bad).err().ok_or("invalid global accepted")?;if actual!=reason{return Err("global rejection reason".into());}
        drop(bad);let _=bundle::Forest::parse(&good)?;
    }}
    Ok(comparisons)
}
pub fn run()->Result<String>{
    let density_happy=crate::density_happy::run()?;let density_adversarial=crate::density_adversarial::run()?;
    lut_oracle()?;normal_roots()?;root_rejections()?;weighted_rejections()?;
    let all=global_fixture(false)?+global_fixture(true)?;if all!=1708032{return Err("finite Forest census".into());}
    Ok(format!("{{\"Density_happy\":{density_happy},\"Density_adversarial\":{density_adversarial},\"LUT_values\":256,\"LUT_bytes\":512,\"floor_values_checked\":16382,\"exact_LUT_roundtrips\":256,\"dominant_tie_cases\":3,\"pure_cases\":9,\"compact_cases\":9,\"default_cases\":3,\"internal_split_cases\":1,\"DP_boundary_cases\":2,\"wire_rejections\":8,\"exact_root_rejections\":4,\"weighted_rejections\":7,\"global_rejections\":6,\"global_normal_cases\":2,\"global_Forest_CDF_comparisons\":{all},\"global_default_bytes\":109,\"rejection_reasons_verified\":true,\"same_process_recovery\":true,\"packet_files_saved\":0}}"))
}

