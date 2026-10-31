//! categorical 5feature Q32 pool。predictはobserved childを受け取らない。
use crate::fixed_math::{self as f,Math,Q,Result};
use crate::integer_cts;
pub use crate::integer_pool::{Prediction,Update,observe};
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
    let p=normalize_p(q,prefix)?;integer_cts::vector(p,prefix)?;
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

// 正常normalizeのqだけに適用。q0は正常でありvector(q)は使わない。
pub(crate) fn normalize_p(q:[u64;4],prefix:usize)->Result<[u64;4]> {
    if !(1..=4).contains(&prefix)||q[..prefix].iter().any(|&v|v>Q)||q[prefix..].iter().any(|&v|v!=0){return Err("pool p q domain");}
    let mut q_sum=0u64;for &v in &q {q_sum=q_sum.checked_add(v).ok_or("pool p q sum overflow")?;}
    if q_sum!=Q{return Err("pool p q sum");}
    let k=prefix as u64;let d=4096u64.checked_mul(k).ok_or("pool p denominator")?;
    let multiplier=4095u64.checked_mul(k).ok_or("pool p multiplier")?;
    let mut p=[0u64;4];let mut remainder=[0u64;4];let mut assigned=0u64;let mut sum=0u64;
    for j in 0..prefix {
        let mass=multiplier.checked_mul(q[j]).and_then(|v|v.checked_add(Q)).ok_or("pool p mass overflow")?;
        sum=sum.checked_add(mass).ok_or("pool p mass sum")?;
        p[j]=mass.checked_div(d).ok_or("pool p quotient")?;
        remainder[j]=mass.checked_rem(d).ok_or("pool p remainder")?;
        assigned=assigned.checked_add(p[j]).ok_or("pool p assigned")?;
    }
    if sum!=d.checked_mul(Q).ok_or("pool p expected sum")? {return Err("pool p mass total");}
    let residual=Q.checked_sub(assigned).ok_or("pool p excess")?;
    if residual>=k{return Err("pool p residual count");}
    let mut order=[0,1,2,3];order[..prefix].sort_unstable_by(|&a,&b|remainder[b].cmp(&remainder[a]).then(a.cmp(&b)));
    for &j in &order[..residual as usize] {p[j]=p[j].checked_add(1).ok_or("pool p increment")?;}
    let mut total=0u64;for &v in &p {total=total.checked_add(v).ok_or("pool p total overflow")?;}
    if total!=Q{return Err("pool p total");}Ok(p)
}
