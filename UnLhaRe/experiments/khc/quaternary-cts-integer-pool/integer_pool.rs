//! categorical 5feature Q32 pool。predictはobserved childを受け取らない。
use crate::fixed_math::{self as f,Math,Q,Result};
use crate::integer_cts;
#[derive(Clone,Debug,PartialEq,Eq)]
pub struct Prediction {
    pub prefix:usize,pub weights:[u64;5],pub features:[[i64;4];5],pub scores:[i64;4],
    pub q:[u64;4],pub p:[u64;4],pub frequencies:[u32;4],pub cumulative:[u32;5],
}
#[derive(Clone,Debug,PartialEq,Eq)]
pub struct Update {pub factor:u64,pub expected:[i64;5],pub gradient:[i64;5],pub delta:[i64;5],pub next:[u64;5]}
pub fn predict(math:&Math,counts:[[u16;4];4],weights:[u64;5],cts:[u64;4],prefix:usize)->Result<Prediction> {
    if !(1..=4).contains(&prefix) || weights.iter().any(|&w|w>2*Q) {return Err("pool prefix/weight");}
    integer_cts::vector(cts,prefix)?;
    for row in counts {if row.iter().any(|&v|v==0) || row.iter().map(|&v|u32::from(v)).sum::<u32>()>32768 {return Err("pool count row");}}
    let mut features=[[0i64;4];5];let mut scores=[0i64;4];
    for i in 0..4 {for j in 0..prefix {features[i][j]=math.ln_count(u64::from(counts[i][j]))?;}}
    for j in 0..prefix {features[4][j]=math.ln_cts(cts[j])?;}
    for j in 0..prefix {
        let mut sum=0i128;for i in 0..5 {sum=f::sadd(sum,f::smul(i128::from(weights[i]),i128::from(features[i][j]))?)?;}
        scores[j]=f::i64_value(f::sdiv(sum,i128::from(Q))?)?;
    }
    let max=*scores[..prefix].iter().max().ok_or("pool maximum")?;
    let mut mass=[0u128;4];
    for j in 0..prefix {let d=max.checked_sub(scores[j]).ok_or("score difference overflow")?;mass[j]=u128::from(math.exp_neg(d)?);}
    let q=integer_cts::normalize(mass,prefix)?;
    for j in 0..prefix {mass[j]=f::add(f::mul(f::mul(4095,prefix as u128)?,u128::from(q[j]))?,u128::from(Q))?;}
    let p=integer_cts::normalize(mass,prefix)?;integer_cts::vector(p,prefix)?;
    let minimum=Q/(4096*prefix as u64);if p[..prefix].iter().any(|&v|v<minimum) {return Err("uniform minimum");}
    let mut frequencies=[0u32;4];let mut remainders=[0u64;4];let mut assigned=0u32;
    for j in 0..prefix {
        let product=f::mul(u128::from(p[j]),32768)?;
        frequencies[j]=u32::try_from(product/u128::from(Q)).map_err(|_|"CDF conversion")?;remainders[j]=(product%u128::from(Q)) as u64;
        assigned=assigned.checked_add(frequencies[j]).ok_or("CDF sum")?;
    }
    let remaining=32768u32.checked_sub(assigned).ok_or("CDF excess")? as usize;if remaining>=prefix {return Err("CDF residual count");}
    let mut order=[0,1,2,3];order[..prefix].sort_unstable_by(|&a,&b|remainders[b].cmp(&remainders[a]).then(a.cmp(&b)));
    for &j in &order[..remaining] {frequencies[j]=frequencies[j].checked_add(1).ok_or("CDF increment")?;}
    if frequencies[..prefix].iter().any(|&v|v<2) || frequencies[prefix..].iter().any(|&v|v!=0) {return Err("CDF positive frequency");}
    let mut cumulative=[0u32;5];for j in 0..4 {cumulative[j+1]=cumulative[j].checked_add(frequencies[j]).ok_or("CDF cumulative")?;}
    if cumulative[4]!=32768 {return Err("CDF total");}
    Ok(Prediction{prefix,weights,features,scores,q,p,frequencies,cumulative})
}
pub fn observe(s:&Prediction,child:usize)->Result<Update> {
    if !(1..=4).contains(&s.prefix) || child>=s.prefix || s.weights.iter().any(|&w|w>2*Q) {return Err("pool observed child/weights");}
    if s.q[..s.prefix].iter().any(|&v|v>Q) || s.q[s.prefix..].iter().any(|&v|v!=0) || s.q.iter().sum::<u64>()!=Q {return Err("pool q snapshot");}
    integer_cts::vector(s.p,s.prefix)?;
    let mass=f::mul(f::mul(4095,s.prefix as u128)?,u128::from(s.q[child]))?;
    let factor=f::u64_value(f::div(f::mul(mass,u128::from(Q))?,f::add(mass,u128::from(Q))?)?)?;
    let mut expected=[0i64;5];let mut gradient=[0i64;5];let mut delta=[0i64;5];let mut next=[0u64;5];
    for i in 0..5 {
        let mut sum=0i128;for j in 0..s.prefix {sum=f::sadd(sum,f::smul(i128::from(s.q[j]),i128::from(s.features[i][j]))?)?;}
        expected[i]=f::i64_value(f::sdiv(sum,i128::from(Q))?)?;
        let difference=s.features[i][child].checked_sub(expected[i]).ok_or("gradient difference")?;
        gradient[i]=f::i64_value(f::sdiv(f::smul(i128::from(factor),i128::from(difference))?,i128::from(Q))?)?;
        delta[i]=gradient[i]/256;
        next[i]=f::sadd(i128::from(s.weights[i]),i128::from(delta[i]))?.clamp(0,2*i128::from(Q)) as u64;
    }Ok(Update{factor,expected,gradient,delta,next})
}

