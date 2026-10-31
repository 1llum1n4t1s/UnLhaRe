//! 事前固定KT4128直接比較/商余り証明と局所paired probe。正式性能ではない。
use crate::{reference_cts as old,new_cts as new,Result};
use std::{hint::black_box,time::Instant};
const Q:u64=old::Q;const CAP:u32=old::CAP;
#[derive(Clone,Copy)]
struct Case {raw:[u32;4],prefix:usize}
fn next(state:&mut u32)->u32{*state=state.wrapping_mul(1664525).wrapping_add(1013904223);*state}
fn cases()->Result<Vec<Case>>{
    let mut result=Vec::new();result.try_reserve_exact(4128).map_err(|_|"KT cases allocation")?;
    let raw=[[0;4],[CAP,0,0,0],[0,CAP,0,0],[0,0,CAP,0],[0,0,0,CAP],[1;4],[CAP/4;4],[CAP-3,1,1,1]];
    for prefix in 1..=4{for &raw in &raw{result.push(Case{raw,prefix});}}
    let mut state=0x6d2b79f5u32;for index in 0..4096{let raw=std::array::from_fn(|_|next(&mut state)%(CAP/4+1));result.push(Case{raw,prefix:index%4+1});}Ok(result)
}
fn invalid()->Result<usize>{
    let input=[(0,[0;4],"invalid prefix"),(5,[0;4],"invalid prefix"),(4,[CAP+1,0,0,0],"raw observation cap"),(4,[u32::MAX,0,0,0],"raw observation cap"),(4,[u32::MAX;4],"raw observation cap"),(0,[u32::MAX;4],"invalid prefix"),(1,[0,0,0,CAP+1],"raw observation cap"),(4,[CAP,1,0,0],"raw observation cap")];
    let mut checked=0;for (prefix,raw,expected)in input{let a=old::kt(raw,prefix);let b=new::kt(raw,prefix);if a!=Err(expected)||b!=Err(expected){return Err(format!("KT illegal case {checked}: old {a:?}, new {b:?} expected {expected}"));}checked+=1;}Ok(checked)
}
fn quotients(c:Case)->Result<(u64,u64,u64,usize)>{
    let mut masses=[0u64;4];let mut d=0u64;let mut old_d=0u128;let mut max_mass=0;
    for j in 0..c.prefix{masses[j]=u64::from(c.raw[j]).checked_mul(2).and_then(|n|n.checked_add(1)).ok_or("comparison mass")?;d=d.checked_add(masses[j]).ok_or("comparison denominator")?;old_d=old_d.checked_add(u128::from(c.raw[j])*2+1).ok_or("old comparison denominator")?;max_mass=max_mass.max(masses[j]);}
    if u128::from(d)!=old_d||d==0||d>7650684||max_mass>7650681{return Err("KT mass/denominator bounds".into());}
    let mut max_product=0;let mut checked=0;for j in 0..c.prefix{
        let product=masses[j].checked_mul(Q).ok_or("comparison product u64 overflow")?;
        let old_product=(u128::from(c.raw[j])*2+1).checked_mul(u128::from(Q)).ok_or("comparison product u128 overflow")?;
        if u128::from(product)!=old_product||u128::from(product/d)!=old_product/old_d||u128::from(product%d)!=old_product%old_d||product>=1u64<<55{return Err(format!("KT quotient/remainder mismatch child {j}"));}
        max_product=max_product.max(product);checked+=1;
    }Ok((max_mass,d,max_product,checked))
}
fn digest(h:&mut u64,v:u64){*h=(*h^v).wrapping_mul(0x100000001b3);}
type Kt=fn([u32;4],usize)->old::Result<[u64;4]>;
fn measured(cases:&[Case],candidate:bool)->Result<(u128,u64,u64)>{
    let f:Kt=if candidate{new::kt}else{old::kt};let f=black_box(f);let mut h=0xcbf29ce484222325;let mut count=0u64;let begin=Instant::now();
    for _ in 0..16{for c in cases{let vector=black_box(f(black_box(c.raw),black_box(c.prefix))?);for value in vector{digest(&mut h,value);}count+=1;}}
    let elapsed=begin.elapsed().as_nanos();black_box(h);Ok((elapsed,h,count))
}
pub(crate) fn run()->Result<()>{
    let cases=cases()?;let mut compared=0;let mut qr=0;let mut max_mass=0;let mut max_d=0;let mut max_product=0;
    for (index,&c)in cases.iter().enumerate(){
        let old=old::kt(c.raw,c.prefix)?;let candidate=new::kt(c.raw,c.prefix)?;
        if old!=candidate{return Err(format!("KT direct vector mismatch {index}"));}
        let(m,d,p,n)=quotients(c)?;max_mass=max_mass.max(m);max_d=max_d.max(d);max_product=max_product.max(p);qr+=n;compared+=1;
    }
    if old::kt([CAP,0,0,0],1)?!=[Q,0,0,0]||new::kt([CAP,0,0,0],1)?!=[Q,0,0,0]{return Err("KT forced fixture".into());}
    let uniform=[1431655766,1431655765,1431655765,0];
    if Q/3!=1431655765||Q%3!=1||Q-3*(Q/3)!=1||old::kt([0;4],3)?!=uniform||new::kt([0;4],3)?!=uniform{return Err("KT uniform nonzero tie fixture".into());}
    for prefix in 1..=3{let raw=[0,0,0,CAP];if old::kt(raw,prefix)?!=new::kt(raw,prefix)?{return Err("KT prefix-external CAP fixture".into());}quotients(Case{raw,prefix})?;}
    let invalid=invalid()?;
    let mut old_times=[0u128;5];let mut new_times=[0u128;5];let mut old_digests=[0u64;5];let mut new_digests=[0u64;5];let mut old_counts=[0u64;5];let mut new_counts=[0u64;5];
    for round in 0..5{
        let(a,b)=if round%2==0{(measured(&cases,false)?,measured(&cases,true)?)}else{let new=measured(&cases,true)?;let old=measured(&cases,false)?;(old,new)};
        old_times[round]=a.0;new_times[round]=b.0;old_digests[round]=a.1;new_digests[round]=b.1;old_counts[round]=a.2;new_counts[round]=b.2;
        if a.1!=b.1||a.2!=66048||b.2!=66048{return Err(format!("KT paired count/digest {round}"));}
    }
    let mut a=old_times;let mut b=new_times;a.sort_unstable();b.sort_unstable();let old_median=a[2];let new_median=b[2];let improved=new_median<old_median;
    if compared!=4128||invalid!=8{return Err("KT fixed case counts".into());}
    println!("{{\"status\":\"passed\",\"operation\":\"compare-kt\",\"normal_cases\":{compared},\"invalid_cases\":{invalid},\"scalar_groups\":3,\"LCG_seed\":1831565813,\"quotient_remainder_children_checked\":{qr},\"max_mass\":{max_mass},\"max_denominator\":{max_d},\"max_product\":{max_product},\"product_u64_bounds_verified\":true,\"passes\":16,\"paired_rounds\":5,\"calls_per_round_side\":66048,\"total_calls_per_side\":330240,\"old_elapsed_ns\":{old_times:?},\"new_elapsed_ns\":{new_times:?},\"old_digests\":{old_digests:?},\"new_digests\":{new_digests:?},\"old_counts\":{old_counts:?},\"new_counts\":{new_counts:?},\"round_order\":[\"old-new\",\"new-old\",\"old-new\",\"new-old\",\"old-new\"],\"old_median_ns\":{old_median},\"new_median_ns\":{new_median},\"new_improved\":{improved},\"diagnostic_only\":true,\"formal_codec_speed_CPU_verified\":false,\"full_benchmark_allowed\":false,\"general_8MiB_input_supported\":false}}");Ok(())
}

