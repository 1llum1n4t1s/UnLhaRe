//! Q21 weight/probabilityと凍結Q32 logを接続するchecked64 pool。
use crate::{fixed_math::Math,new_cts as c};
pub use c::{Q,Result};
#[derive(Clone,Debug,PartialEq,Eq)]
pub struct Prediction{pub prefix:usize,pub weights:[u64;5],pub features:[[i64;4];5],pub scores:[i64;4],pub q:[u64;4],pub p:[u64;4],pub frequencies:[u32;4],pub cumulative:[u32;5]}
#[derive(Clone,Debug,PartialEq,Eq)]
pub struct Update{pub factor:u64,pub expected:[i64;5],pub gradient:[i64;5],pub delta:[i64;5],pub next:[u64;5]}
fn feature_domain(f:[[i64;4];5],k:usize)->Result<()>{
    for (i,row) in f.iter().enumerate(){let (lo,hi)=if i<4{(0,44655667077)}else{(-62517933908,0)};if row[..k].iter().any(|&x|x<lo||x>hi)||row[k..].iter().any(|&x|x!=0){return Err("pool feature domain");}}Ok(())
}
pub fn smooth(q:[u64;4],k:usize)->Result<([u64;4],[u32;4],[u32;5])>{
    if !(1..=4).contains(&k){return Err("invalid prefix");}
    let mut mass=[0;4];for j in 0..k{mass[j]=(4095*k as u64).checked_mul(q[j]).and_then(|x|x.checked_add(Q)).ok_or("unsigned product overflow")?;}
    let p=c::normalize(mass,k)?;c::vector(p,k)?;
    if p[..k].iter().any(|&x|x<Q/(4096*k as u64)){return Err("uniform minimum");}
    let mut frequencies=[0u32;4];let mut remainders=[0u64;4];let mut assigned=0u32;
    for j in 0..k{let x=p[j].checked_mul(32768).ok_or("unsigned product overflow")?;frequencies[j]=u32::try_from(x/Q).map_err(|_|"CDF conversion")?;remainders[j]=x%Q;assigned=assigned.checked_add(frequencies[j]).ok_or("CDF sum")?;}
    let left=32768u32.checked_sub(assigned).ok_or("CDF excess")? as usize;if left>=k{return Err("CDF residual count");}
    let mut order=[0,1,2,3];order[..k].sort_unstable_by(|&a,&b|remainders[b].cmp(&remainders[a]).then(a.cmp(&b)));
    for &j in &order[..left]{frequencies[j]=frequencies[j].checked_add(1).ok_or("CDF increment")?;}
    if frequencies[..k].iter().any(|&x|x<2)||frequencies[k..].iter().any(|&x|x!=0){return Err("CDF positive frequency");}
    let mut cumulative=[0u32;5];for j in 0..4{cumulative[j+1]=cumulative[j].checked_add(frequencies[j]).ok_or("CDF cumulative")?;}if cumulative[4]!=32768{return Err("CDF total");}Ok((p,frequencies,cumulative))
}
fn from_features(math:&Math,f:[[i64;4];5],w:[u64;5],k:usize)->Result<Prediction>{
    if !(1..=4).contains(&k)||w.iter().any(|&x|x>2*Q){return Err("pool prefix/weight");}feature_domain(f,k)?;
    let mut scores=[0i64;4];for j in 0..k{let mut total=0i64;for i in 0..5{let x=i64::try_from(w[i]).map_err(|_|"signed conversion")?.checked_mul(f[i][j]).ok_or("signed product overflow")?;total=total.checked_add(x).ok_or("signed sum overflow")?;}scores[j]=total.checked_div(Q as i64).ok_or("signed division domain")?;}
    let maximum=*scores[..k].iter().max().ok_or("pool maximum")?;let mut mass=[0;4];for j in 0..k{mass[j]=math.exp_neg(maximum.checked_sub(scores[j]).ok_or("score difference overflow")?)?;}
    let q=c::normalize(mass,k)?;let(p,frequencies,cumulative)=smooth(q,k)?;Ok(Prediction{prefix:k,weights:w,features:f,scores,q,p,frequencies,cumulative})
}
#[cfg(primitive_audit)] pub fn audit_features(math:&Math,f:[[i64;4];5],w:[u64;5],k:usize)->Result<Prediction>{from_features(math,f,w,k)}
pub fn predict(math:&Math,counts:[[u16;4];4],weights:[u64;5],cts:[u64;4],prefix:usize)->Result<Prediction>{
    if !(1..=4).contains(&prefix)||weights.iter().any(|&w|w>2*Q){return Err("pool prefix/weight");}c::vector(cts,prefix)?;
    for row in counts{if row.contains(&0)||row.iter().map(|&v|u32::from(v)).sum::<u32>()>32768{return Err("pool count row");}}
    let mut features=[[0;4];5];for i in 0..4{for j in 0..prefix{features[i][j]=math.ln_count(u64::from(counts[i][j]))?;}}
    for j in 0..prefix{features[4][j]=math.ln_cts(cts[j].checked_mul(2048).ok_or("CTS log conversion overflow")?)?;}
    from_features(math,features,weights,prefix)
}
pub fn observe(s:&Prediction,child:usize)->Result<Update>{
    if !(1..=4).contains(&s.prefix)||child>=s.prefix||s.weights.iter().any(|&x|x>2*Q){return Err("pool observed child/weights");}
    if s.q[..s.prefix].iter().any(|&x|x>Q)||s.q[s.prefix..].iter().any(|&x|x!=0){return Err("pool q snapshot");}
    let total=s.q.iter().try_fold(0u64,|a,&b|a.checked_add(b).ok_or("pool q snapshot"))?;if total!=Q{return Err("pool q snapshot");}c::vector(s.p,s.prefix)?;feature_domain(s.features,s.prefix)?;
    let mass=(4095*s.prefix as u64).checked_mul(s.q[child]).ok_or("unsigned product overflow")?;
    let factor=mass.checked_mul(Q).ok_or("unsigned product overflow")?/mass.checked_add(Q).ok_or("unsigned sum overflow")?;
    let mut expected=[0;5];let mut gradient=[0;5];let mut delta=[0;5];let mut next=[0;5];
    for i in 0..5{let mut sum=0i64;for j in 0..s.prefix{let x=(s.q[j] as i64).checked_mul(s.features[i][j]).ok_or("signed product overflow")?;sum=sum.checked_add(x).ok_or("signed sum overflow")?;}expected[i]=sum.checked_div(Q as i64).ok_or("signed division domain")?;
        let difference=s.features[i][child].checked_sub(expected[i]).ok_or("gradient difference")?;gradient[i]=(factor as i64).checked_mul(difference).ok_or("signed product overflow")?.checked_div(Q as i64).ok_or("signed division domain")?;delta[i]=gradient[i]/524288;
        next[i]=(s.weights[i] as i64).checked_add(delta[i]).ok_or("signed sum overflow")?.clamp(0,2*Q as i64) as u64;
    }Ok(Update{factor,expected,gradient,delta,next})
}
