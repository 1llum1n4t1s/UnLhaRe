//! standalone E2Eの独立合成数値検証。std ln/expはoracle内だけ。
use crate::{Result,float_math::Math,float_cts as cts,float_pool as pool};
fn near(a:f64,b:f64,tolerance:f64,scope:&str)->Result<()>{if !a.is_finite()||!b.is_finite()||(a-b).abs()>tolerance{return Err(format!("numeric {scope}: {a} vs {b}"));}Ok(())}
pub fn run()->Result<()>{
    let math=Math::new()?;let mut ln_cases=0;let mut exp_cases=0;let mut rejected=0;
    let mut values=vec![1.0,0.5,0.25,0.75,1.0/(cts::CAP as f64*2.0+4.0),f64::MIN_POSITIVE,f64::from_bits(1)];
    for i in [0,1,37,2048,4095]{values.push((1.0+i as f64/4096.0)/2.0);values.push((1.0+(i as f64+0.5)/4096.0)/2.0);}
    for v in values{near(math.ln_cts(v)?,v.ln(),2e-7,"ln")?;ln_cases+=1;}
    let ln2=crate::fixed_math::LN2 as f64/crate::fixed_math::S as f64;
    for d in [0.0,ln2/4096.0,ln2/2.0,ln2,ln2*3.0,31.999999*ln2,32.0*ln2,32.000001*ln2,128.0]{near(math.exp_neg(d)?,(-d).exp(),2e-7,"exp")?;exp_cases+=1;}
    if math.exp_neg(32.0*ln2)?.to_bits()!=0{return Err("exp cutoff exact".into());}
    for m in 1..=32{let endpoint=m as f64*ln2;for bits in [endpoint.to_bits()-1,endpoint.to_bits(),endpoint.to_bits()+1]{let d=f64::from_bits(bits);near(math.exp_neg(d)?,(-d).exp(),2e-7,"exp exponent boundary")?;exp_cases+=1;}}
    for n in [0.0,-0.1,1.1,f64::NAN,f64::INFINITY]{if math.ln_cts(n).is_ok(){return Err("ln domain accepted".into());}rejected+=1;}
    for d in [-0.1,128.1,f64::NAN,f64::INFINITY]{if math.exp_neg(d).is_ok(){return Err("exp domain accepted".into());}rejected+=1;}
    let raw=std::array::from_fn(|l|[3+l as u32,17+2*l as u32,7+3*l as u32,11+5*l as u32]);let weights=[0.31,0.73,0.17,0.61,0.42,0.5];
    let kernel=cts::predict_kernel(raw,weights,4)?;let mut independent=[[0.0;4];6];
    for l in (0..6).rev(){let denominator=raw[l].iter().map(|&v|v as f64).sum::<f64>()+2.0;for j in 0..4{let own=(raw[l][j] as f64+0.5)/denominator;near(kernel.kt[l][j],own,1e-12,"KT")?;independent[l][j]=if l==5{own}else{own*weights[l]+independent[l+1][j]*(1.0-weights[l])};near(kernel.mixed[l][j],independent[l][j],1e-12,"CTS")?;}}
    let mut tree=cts::Cts::new(5)?;let ids=cts::path(0);tree.audit_seed_class(0,0,13);for l in 0..6{tree.audit_seed_node(0,ids[l],raw[l],weights[l]);}
    let prediction=tree.predict(0,4)?;tree.observe(&prediction,2)?;
    for l in 0..6{let node=tree.audit_node(0,ids[l]);if node.raw[2]!=raw[l][2]+1{return Err("CTS raw update".into());}let expected=if l==5{0.5}else{let denominator=raw[l].iter().map(|&v|v as f64).sum::<f64>()+2.0;let own=(raw[l][2] as f64+0.5)/denominator;let posterior=weights[l]*own/independent[l][2];let alpha=1.0/15.0;alpha+(1.0-2.0*alpha)*posterior};near(node.weight,expected,1e-12,"CTS posterior")?;}
    let before=tree.clone();if tree.observe(&prediction,2).is_ok()||!tree.same(&before){return Err("CTS stale mutation".into());}rejected+=1;
    let counts=[[3,5,7,11],[13,17,19,23],[29,31,37,41],[43,47,53,59]];let w=[0.3,0.2,0.4,0.1,0.7];let pcts=[8.5/21.0,1.5/21.0,6.5/21.0,4.5/21.0];
    let prediction=pool::predict(&math,counts,w,pcts,4)?;let (_,q,p)=pool::audit_values(&prediction);let update=pool::observe(&prediction,2)?;
    let mut features=[[0.0;4];5];let mut scores=[0.0;4];for j in 0..4{for i in 0..4{features[i][j]=(counts[i][j] as f64).ln();}features[4][j]=pcts[j].ln();for i in 0..5{scores[j]+=w[i]*features[i][j];}}
    let max=scores.into_iter().fold(f64::NEG_INFINITY,f64::max);let exp=scores.map(|v|(v-max).exp());let total=exp.iter().sum::<f64>();let oracle=exp.map(|v|v/total);
    for j in 0..4{near(q[j],oracle[j],1e-6,"pool q")?;near(p[j],(4095.0*oracle[j]+0.25)/4096.0,1e-6,"pool p")?;}
    for i in 0..5{let expected=(0..4).map(|j|oracle[j]*features[i][j]).sum::<f64>();let mass=4095.0*4.0*oracle[2];let gradient=(mass/(mass+1.0))*(features[i][2]-expected);near(update.gradient[i],gradient,1e-6,"gradient")?;near(update.next[i],(w[i]+gradient/256.0).clamp(0.0,2.0),1e-6,"next coefficient")?;}
    if prediction.frequencies!=[8331,3154,10811,10472]{return Err("synthetic CDF oracle mismatch".into());}
    for k in 1..=4{let mut v=[0.0;4];for x in &mut v[..k]{*x=1.0/k as f64;}let s=pool::predict(&math,counts,w,v,k)?;if s.cumulative[4]!=32768||s.frequencies[k..].iter().any(|&f|f!=0){return Err("CDF prefix/tail".into());}}
    for v in [[-0.1,0.4,0.4,0.3],[f64::NAN,0.0,0.0,0.0],[f64::INFINITY,0.0,0.0,0.0],[0.0,0.3,0.3,0.4]]{if pool::predict(&math,counts,w,v,4).is_ok(){return Err("pool probability domain accepted".into());}rejected+=1;}
    println!("{{\"status\":\"passed\",\"operation\":\"numeric\",\"ln_cases\":{ln_cases},\"exp_cases\":{exp_cases},\"numeric_domain_rejections\":{rejected},\"independent_KT_CTS\":true,\"independent_posterior\":true,\"independent_pool_gradient\":true,\"ln_exp_absolute_tolerance\":0.0000002,\"pool_absolute_tolerance\":0.000001,\"CDF\":[8331,3154,10811,10472],\"old_integer_equivalence_claimed\":false}}");Ok(())
}
