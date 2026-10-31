//! 先行失敗計画に基づく逐次Math契約比較。数値列は保存しない。
use crate::{fixed_math as old,new_math as new};
type Result<T>=std::result::Result<T,String>;
fn equal<T:std::fmt::Debug+PartialEq>(a:T,b:T,scope:&str,index:u64)->Result<()> {
    if a!=b {return Err(format!("{scope} mismatch at {index}: old={a:?}, new={b:?}"));}Ok(())
}
fn entries<T:std::fmt::Debug+PartialEq>(a:&[T],b:&[T],scope:&str)->Result<usize> {
    if a.len()!=b.len(){return Err(format!("{scope} length mismatch"));}
    for (index,(a,b)) in a.iter().zip(b).enumerate(){equal(a,b,scope,index as u64)?;}Ok(a.len())
}
pub fn run()->Result<()> {
    let a=old::Math::new().map_err(str::to_owned)?;
    let b=new::Math::new().map_err(str::to_owned)?;
    equal((old::Q,old::S,old::GRID,old::LN2,old::EXP_CUTOFF),
          (new::Q,new::S,new::GRID,new::LN2,new::EXP_CUTOFF),"constants",0)?;
    let l_entries=entries(a.l(),b.l(),"ln LUT")?;
    let e_entries=entries(a.e(),b.e(),"exp LUT")?;
    let count_entries=entries(a.counts(),b.counts(),"counts")?;
    let q=old::Q as i64;
    let fixed=[-1,0,1,q-1,q,q+1,32*q-1,32*q,128*q,128*q+1,i64::MIN,i64::MAX];
    for (index,d) in fixed.into_iter().enumerate(){equal(a.exp_neg(d),b.exp_neg(d),"exp fixed",index as u64)?;}
    equal(a.exp_neg(0),Ok(old::Q),"old exp zero fixture",0)?;
    equal(b.exp_neg(0),Ok(new::Q),"new exp zero fixture",0)?;
    for d in [-1,128*q+1,i64::MIN,i64::MAX] {
        equal(a.exp_neg(d),Err("exp domain"),"old exp domain",d as u64)?;
        equal(b.exp_neg(d),Err("exp domain"),"new exp domain",d as u64)?;
    }
    let mut exp_grid_cases=0u64;
    // 各LN2区間と全grid境界の丸め前後。cutoffを越えたゼロ領域も含む。
    for exponent in 0..=32u128 {for grid in 0..=old::GRID {
        let boundary=((exponent*u128::from(old::LN2)+grid as u128*u128::from(old::LN2)/old::GRID as u128)>>16) as i64;
        for delta in [-1,0,1] {
            let d=boundary+delta;
            equal(a.exp_neg(d),b.exp_neg(d),"exp grid",exp_grid_cases)?;exp_grid_cases+=1;
        }
    }}
    let ln_fixed=[0,1,2,old::Q-1,old::Q,old::Q+1,u64::MAX];
    let mut ln_fixed_cases=0u64;
    for n in ln_fixed {
        equal(a.ln_cts(n),b.ln_cts(n),"ln CTS fixed",n)?;ln_fixed_cases+=1;
        for scale in [0,32,1,31,33,u32::MAX] {
            equal(a.ln_scaled(n,scale),b.ln_scaled(n,scale),"ln scaled fixed",n)?;ln_fixed_cases+=1;
            if n==0||n>old::Q||![0,32].contains(&scale) {
                equal(a.ln_scaled(n,scale),Err("ln domain"),"old ln domain",n)?;
                equal(b.ln_scaled(n,scale),Err("ln domain"),"new ln domain",n)?;
            }
        }
    }
    for n in [0,1,32768,32769,u64::MAX] {
        equal(a.ln_count(n),b.ln_count(n),"count domain",n)?;
        if n==0||n>32768 {
            equal(a.ln_count(n),Err("count ln domain"),"old count domain",n)?;
            equal(b.ln_count(n),Err("count ln domain"),"new count domain",n)?;
        }
    }
    let mut ln_grid_cases=0u64;
    // lnの各2乗区間の全grid境界を整数化した近傍。
    for exponent in 0..=32 {let base=1u64<<exponent;for grid in 0..=old::GRID {
        let boundary=base+(grid as u64*base/old::GRID as u64);
        for n in [boundary-1,boundary,boundary+1] {
            equal(a.ln_cts(n),b.ln_cts(n),"ln CTS grid",ln_grid_cases)?;
            for scale in [0,32] {equal(a.ln_scaled(n,scale),b.ln_scaled(n,scale),"ln scaled grid",ln_grid_cases)?;}
            ln_grid_cases+=1;
        }
    }}
    let mut state=0x4b48514349443031u64;
    for index in 0..4096u64 {
        state^=state<<13;state^=state>>7;state^=state<<17;
        let n=1+state%old::Q;let d=(1+state%(128*old::Q)) as i64;
        equal(a.exp_neg(d),b.exp_neg(d),"exp deterministic positive",index)?;
        equal(a.ln_cts(n),b.ln_cts(n),"ln CTS deterministic positive",index)?;
        for scale in [0,32] {equal(a.ln_scaled(n,scale),b.ln_scaled(n,scale),"ln scaled deterministic positive",index)?;}
    }
    crate::emit(&format!("{{\"operation\":\"compare-math\",\"status\":\"passed\",\"l_entries\":{l_entries},\"e_entries\":{e_entries},\"count_entries\":{count_entries},\"exp_fixed_cases\":12,\"exp_grid_cases\":{exp_grid_cases},\"ln_fixed_comparisons\":{ln_fixed_cases},\"ln_count_fixed_cases\":5,\"ln_grid_cases\":{ln_grid_cases},\"deterministic_positive_cases\":4096,\"direct_equal\":true,\"numeric_trace_saved\":false}}"))
}
