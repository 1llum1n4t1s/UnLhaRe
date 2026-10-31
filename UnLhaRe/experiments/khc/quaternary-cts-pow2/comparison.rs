//! 事前固定のRAM直接比較＋局所paired probe。正式codec性能の証拠ではない。
use crate::{integer_cts as fast,reference_cts as old,Result};
use std::{hint::black_box,time::Instant};
const Q:u64=old::Q;
const PASSES:usize=16;
const ROUNDS:usize=5;
#[derive(Clone,Copy)]
struct Case {weight:u64,own:[u64;4],child:[u64;4],prefix:usize}
fn next(state:&mut u32)->u32{*state=state.wrapping_mul(1664525).wrapping_add(1013904223);*state}
fn cases()->Result<Vec<Case>>{
    let mut result=Vec::new();result.try_reserve_exact(4116).map_err(|_|"comparison allocation")?;
    for prefix in 1..=4{let mut mass=[0u128;4];for v in &mut mass[..prefix]{*v=1;}let uniform=old::normalize(mass,prefix)?;
        for weight in [0,1,Q/2,Q-1,Q]{result.push(Case{weight,own:uniform,child:uniform,prefix});}}
    let mut state=0x6d2b79f5u32;for index in 0..4096{
        let prefix=index%4+1;let mut own=[0u128;4];let mut child=[0u128;4];
        for v in &mut own[..prefix]{*v=u128::from(next(&mut state)&0xfffff)+1;}
        for v in &mut child[..prefix]{*v=u128::from(next(&mut state)&0xfffff)+1;}
        result.push(Case{weight:u64::from(next(&mut state)),own:old::normalize(own,prefix)?,child:old::normalize(child,prefix)?,prefix});
    }Ok(result)
}
fn invalid()->Result<usize>{
    let u2=[Q/2,Q/2,0,0];let u4=[Q/4;4];let one=[Q,0,0,0];
    let cases=[
        ("weight_over",Case{weight:Q+1,own:u4,child:u4,prefix:4},"weight outside Q"),
        ("prefix_zero",Case{weight:Q/2,own:u4,child:u4,prefix:0},"invalid prefix"),
        ("prefix_five",Case{weight:Q/2,own:u4,child:u4,prefix:5},"invalid prefix"),
        ("own_zero",Case{weight:Q/2,own:[0,Q,0,0],child:u2,prefix:2},"invalid categorical vector"),
        ("own_over",Case{weight:Q/2,own:[Q+1,1,0,0],child:u2,prefix:2},"invalid categorical vector"),
        ("own_outside",Case{weight:Q/2,own:[Q,1,0,0],child:one,prefix:1},"invalid categorical vector"),
        ("own_sum",Case{weight:Q/2,own:[1,1,0,0],child:u2,prefix:2},"vector sum differs from Q"),
        ("child_zero",Case{weight:Q/2,own:u2,child:[0,Q,0,0],prefix:2},"invalid categorical vector"),
        ("child_over",Case{weight:Q/2,own:u2,child:[Q+1,1,0,0],prefix:2},"invalid categorical vector"),
        ("child_outside",Case{weight:Q/2,own:one,child:[Q,1,0,0],prefix:1},"invalid categorical vector"),
        ("child_sum",Case{weight:Q/2,own:u2,child:[1,1,0,0],prefix:2},"vector sum differs from Q"),
        ("weight_precedence",Case{weight:Q+1,own:[0;4],child:[0;4],prefix:0},"weight outside Q"),
    ];
    let mut checked=0;for(name,c,expected)in cases{
        let a=old::mixture(c.weight,c.own,c.child,c.prefix);let b=fast::mixture(c.weight,c.own,c.child,c.prefix);
        if a!=Err(expected)||b!=Err(expected){return Err(format!("invalid comparison {name}: old {a:?}, fast {b:?}, expected {expected}"));}
        checked+=1;
    }Ok(checked)
}
fn digest(h:&mut u64,v:u64){*h=(*h^v).wrapping_mul(0x100000001b3);}
type Mixture=fn(u64,[u64;4],[u64;4],usize)->old::Result<([u64;4],[u128;4])>;
fn measured(cases:&[Case],fast_side:bool)->Result<(u128,u64,u64)>{
    let function:Mixture=if fast_side{fast::mixture}else{old::mixture};
    let function=black_box(function);let mut h=0xcbf29ce484222325u64;let mut count=0;
    let begin=Instant::now();
    for _ in 0..PASSES{for c in cases{
        let(mixed,mass)=black_box(function(black_box(c.weight),black_box(c.own),black_box(c.child),black_box(c.prefix))?);
        for j in 0..4{digest(&mut h,mixed[j]);digest(&mut h,mass[j] as u64);digest(&mut h,(mass[j]>>64) as u64);}count+=1;
    }}
    let elapsed=begin.elapsed().as_nanos();black_box(h);Ok((elapsed,h,count))
}
pub(crate) fn run()->Result<()>{
    let cases=cases()?;let mut compared=0;for(index,c)in cases.iter().enumerate(){
        let a=old::mixture(c.weight,c.own,c.child,c.prefix)?;let b=fast::mixture(c.weight,c.own,c.child,c.prefix)?;
        if a.0!=b.0||a.1!=b.1{return Err(format!("direct mixture mismatch at {index}"));}
        for j in 0..c.prefix{
            let remainder=a.1[j].checked_mul(u128::from(Q)).ok_or("comparison mass scale")?%(u128::from(Q)*u128::from(Q));
            if remainder!=(a.1[j]&u128::from(Q-1))*u128::from(Q){return Err(format!("remainder relation at {index}/{j}"));}
        }compared+=1;
    }
    // scalar3 groups。4116/timed入力とは別にtie groupの非zero余りも固定検査する。
    let forced=fast::mixture(0,[Q,0,0,0],[Q,0,0,0],1)?;
    if forced.0!=[Q,0,0,0]||forced.1!=[u128::from(Q)*u128::from(Q),0,0,0]{return Err("forced Q squared fixture".into());}
    let uniform3=old::normalize([1,1,1,0],3)?;
    if uniform3!=[1431655766,1431655765,1431655765,0]||fast::mixture(Q/2,uniform3,uniform3,3)?.0!=uniform3{return Err("uniform tie fixture".into());}
    let tie_old=old::mixture(Q/2,[1,1,Q-2,0],[2,2,Q-4,0],3)?;
    let tie_fast=fast::mixture(Q/2,[1,1,Q-2,0],[2,2,Q-4,0],3)?;
    if tie_old!=tie_fast||tie_fast.0!=[2,1,Q-3,0]||tie_fast.1[0]&u128::from(Q-1)!=u128::from(Q/2)||tie_fast.1[1]&u128::from(Q-1)!=u128::from(Q/2){return Err("nonzero remainder child tie fixture".into());}
    let zero=cases[15];let full=cases[19];
    if fast::mixture(zero.weight,zero.own,zero.child,zero.prefix)?.0!=zero.child||fast::mixture(full.weight,full.own,full.child,full.prefix)?.0!=full.own{return Err("weight boundary fixture".into());}
    let invalid=invalid()?;let mut old_times=[0u128;ROUNDS];let mut fast_times=[0u128;ROUNDS];let mut old_digests=[0u64;ROUNDS];let mut fast_digests=[0u64;ROUNDS];let mut old_counts=[0u64;ROUNDS];let mut fast_counts=[0u64;ROUNDS];
    for round in 0..ROUNDS{
        let(a,b)=if round%2==0{(measured(&cases,false)?,measured(&cases,true)?)}else{let fast=measured(&cases,true)?;let old=measured(&cases,false)?;(old,fast)};
        old_times[round]=a.0;fast_times[round]=b.0;old_digests[round]=a.1;fast_digests[round]=b.1;old_counts[round]=a.2;fast_counts[round]=b.2;
        if a.1!=b.1||a.2!=b.2||a.2!=65856{return Err(format!("paired probe digest/count mismatch {round}"));}
    }
    let mut a=old_times;let mut b=fast_times;a.sort_unstable();b.sort_unstable();let old_median=a[ROUNDS/2];let fast_median=b[ROUNDS/2];let improved=fast_median<old_median;
    if compared!=4116||invalid!=12{return Err("fixed comparison counts".into());}
    println!("{{\"status\":\"passed\",\"operation\":\"compare-mixture\",\"normal_cases\":{compared},\"invalid_cases\":{invalid},\"scalar_fixtures\":3,\"LCG_seed\":1831565813,\"passes\":{PASSES},\"paired_rounds\":{ROUNDS},\"calls_per_round_side\":65856,\"total_calls_per_side\":329280,\"old_elapsed_ns\":{old_times:?},\"fast_elapsed_ns\":{fast_times:?},\"old_digests\":{old_digests:?},\"fast_digests\":{fast_digests:?},\"old_counts\":{old_counts:?},\"fast_counts\":{fast_counts:?},\"round_order\":[\"old-fast\",\"fast-old\",\"old-fast\",\"fast-old\",\"old-fast\"],\"old_median_ns\":{old_median},\"fast_median_ns\":{fast_median},\"fast_improved\":{improved},\"diagnostic_only\":true,\"formal_codec_speed_CPU_verified\":false,\"general_8MiB_input_supported\":false,\"full_benchmark_allowed\":false}}");Ok(())
}

