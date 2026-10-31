//! 固定順f64 5feature log-linear pool。
use crate::{Result,scaled_math::Math,float_cts::vector};
#[derive(Clone,Debug)]
pub struct Prediction {pub(crate) prefix:usize,pub(crate) weights:[f64;5],features:[[f64;4];5],q:[f64;4],p:[f64;4],pub(crate) frequencies:[u32;4],pub(crate) cumulative:[u32;5]}
pub struct Update {pub next:[f64;5],pub gradient:[f64;5]}
pub fn predict(math:&Math,counts:[[u16;4];4],weights:[f64;5],cts:[f64;4],prefix:usize)->Result<Prediction>{
    if !(1..=4).contains(&prefix)||weights.iter().any(|&w|!w.is_finite()||!(0.0..=2.0).contains(&w)){return Err("pool prefix/weight".into());}vector(cts,prefix)?;
    let mut features=[[0.0;4];5];let mut scores=[0.0;4];
    for i in 0..4{if counts[i].contains(&0)||counts[i].iter().map(|&v|u32::from(v)).sum::<u32>()>32768{return Err("pool count row".into());}for j in 0..prefix{features[i][j]=math.ln_count(u64::from(counts[i][j]))?;}}
    for j in 0..prefix{features[4][j]=math.ln_cts(cts[j])?;for i in 0..5{scores[j]+=weights[i]*features[i][j];}if !scores[j].is_finite(){return Err("pool score".into());}}
    let mut maximum=scores[0];for &s in &scores[1..prefix]{maximum=maximum.max(s);}
    let mut q=[0.0;4];let mut sum=0.0;for j in 0..prefix{q[j]=math.exp_neg(maximum-scores[j])?;sum+=q[j];}
    if !sum.is_finite()||sum<=0.0{return Err("pool sum".into());}let reciprocal=1.0/sum;
    let mut p=[0.0;4];for j in 0..prefix{q[j]*=reciprocal;p[j]=(4095.0/4096.0)*q[j]+1.0/(4096.0*prefix as f64);}
    // qはcutoffにより0を許す。pの合法childは必ず正。
    if q[..prefix].iter().any(|&v|!v.is_finite()||!(0.0..=1.0).contains(&v)){return Err("pool q".into());}vector(p,prefix)?;
    let mut p_sum=0.0;for &v in &p[..prefix]{p_sum+=v;}let reciprocal=1.0/p_sum;
    let mut frequencies=[0u32;4];let mut fractions=[0.0;4];let mut assigned=0u32;
    for j in 0..prefix{let scaled=(p[j]*reciprocal)*32768.0;let floor=scaled.floor();frequencies[j]=floor as u32;fractions[j]=scaled-floor;assigned=assigned.checked_add(frequencies[j]).ok_or("CDF sum")?;}
    let left=32768u32.checked_sub(assigned).ok_or("CDF excess")? as usize;if left>=prefix{return Err("CDF residual count".into());}
    let mut order=[0,1,2,3];order[..prefix].sort_unstable_by(|&a,&b|fractions[b].total_cmp(&fractions[a]).then(a.cmp(&b)));for &j in &order[..left]{frequencies[j]+=1;}
    if frequencies[..prefix].iter().any(|&v|v<2)||frequencies[prefix..].iter().any(|&v|v!=0){return Err("CDF positive frequency".into());}
    let mut cumulative=[0;5];for j in 0..4{cumulative[j+1]=cumulative[j]+frequencies[j];}if cumulative[4]!=32768{return Err("CDF total".into());}
    Ok(Prediction{prefix,weights,features,q,p,frequencies,cumulative})
}
pub fn observe(s:&Prediction,child:usize)->Result<Update>{
    if child>=s.prefix||!(1..=4).contains(&s.prefix){return Err("pool observed child".into());}vector(s.p,s.prefix)?;
    let mass=4095.0*s.prefix as f64*s.q[child];let factor=mass/(mass+1.0);let mut gradient=[0.0;5];let mut next=[0.0;5];
    for i in 0..5{let mut expected=0.0;for j in 0..s.prefix{expected+=s.q[j]*s.features[i][j];}gradient[i]=factor*(s.features[i][child]-expected);next[i]=(s.weights[i]+gradient[i]/256.0).clamp(0.0,2.0);if !gradient[i].is_finite()||!next[i].is_finite(){return Err("pool gradient".into());}}
    Ok(Update{next,gradient})
}
#[cfg(frame_audit)]
pub(crate) fn audit_values(s:&Prediction)->([[f64;4];5],[f64;4],[f64;4]){(s.features,s.q,s.p)}
