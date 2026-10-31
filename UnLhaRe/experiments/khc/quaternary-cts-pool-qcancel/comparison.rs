//! pool Q-cancel全field比較。旧opportunityの入力/専用childを維持。
use crate::{fixed_math::{Math,Q},integer_pool as old,new_pool as new,integer_cts};
type Result<T>=crate::Result<T>;
fn prediction(math:&Math,counts:[[u16;4];4],weights:[u64;5],cts:[u64;4],prefix:usize)->Result<old::Prediction>{
    let a=old::predict(math,counts,weights,cts,prefix).map_err(str::to_owned)?;
    let b=new::predict(math,counts,weights,cts,prefix).map_err(str::to_owned)?;
    if a!=b{return Err("pool Prediction all fields mismatch".into());}Ok(a)
}
fn update(s:&old::Prediction,child:usize)->Result<old::Update>{
    let a=old::observe(s,child).map_err(str::to_owned)?;
    let b=new::observe(s,child).map_err(str::to_owned)?;
    if a!=b{return Err("pool Update all fields mismatch".into());}Ok(a)
}
pub(crate) fn run()->Result<()> {
    let math=Math::new().map_err(str::to_owned)?;let mut fixture_count=0;let mut active_components=0;
    let mut masks=[0u64;4];let mut maxmass=0u64;let mut maxsum=0u64;
    let mut fixtures=Vec::new();
    for k in 1..=4 {for child in 0..k {let mut q=[0;4];q[child]=Q;fixtures.push((k,q));}}
    for k in 2..=4 {fixtures.push((k,integer_cts::normalize([1;4],k).map_err(str::to_owned)?));}
    fixtures.extend([(2,[1,Q-1,0,0]),(2,[2048,Q-2048,0,0]),(3,[2048,2048,Q-4096,0]),
        (4,[1,Q-1,0,0]),(4,[1,1,Q-2,0]),(4,[1,1,1,Q-3]),(4,[2048,2048,2048,Q-6144])]);
    for (k,q) in fixtures {
        let mut mass=[0u128;4];let mut quotient_sum=0u64;let mut total=0u64;let d=4096*k as u64;
        for j in 0..k {let m=(4095*k as u64).checked_mul(q[j]).and_then(|v|v.checked_add(Q)).ok_or("fixture mass overflow")?;
            mass[j]=u128::from(m);quotient_sum=quotient_sum.checked_add(m/d).ok_or("fixture quotient sum")?;
            total=total.checked_add(m).ok_or("fixture mass sum")?;maxmass=maxmass.max(m);}
        if total!=d*Q{return Err("fixture total DQ".into());}maxsum=maxsum.max(total);
        let residual=Q.checked_sub(quotient_sum).ok_or("fixture residual")?;if residual>=k as u64{return Err("fixture residual count".into());}
        masks[k-1]|=1<<residual;
        let a=integer_cts::normalize(mass,k).map_err(str::to_owned)?;let b=new::normalize_p(q,k).map_err(str::to_owned)?;
        if a!=b{return Err("q fixture p all elements mismatch".into());}fixture_count+=1;active_components+=k;
    }
    if fixture_count!=20||active_components!=62||masks!=[1,3,6,15]||maxmass!=70355859275776||maxsum!=70368744177664{return Err("fixture fixed coverage".into());}
    let counts=[[1,23,7,5],[8,1,37,2],[31,13,1,9],[3,17,5,41]];let raw=[7u128,31,2,11];
    let interior=[13*Q/100,7*Q/10,14*Q/10,3*Q/10,61*Q/100];
    let mut predictions=0;let mut updates=0;
    for prefix in 1..=4 {
        let cts=integer_cts::normalize(raw,prefix).map_err(str::to_owned)?;
        let s=prediction(&math,counts,interior,cts,prefix)?;predictions+=1;
        for child in 0..prefix {update(&s,child)?;updates+=1;}
        for weights in [[0;5],[2*Q;5],[Q/4,Q/4,Q/4,Q/4,0]] {for variant in 0..8 {
            let mut changed=counts;let mut c=cts;
            match variant {0=>changed=[[1;4];4],1..=4=>changed[variant-1][0]=30000,
                5=>c=integer_cts::normalize([1,1,1,u128::from(Q)],prefix).map_err(str::to_owned)?,
                6=>c=integer_cts::normalize([u128::from(Q),1,1,1],prefix).map_err(str::to_owned)?,_=>{}}
            let s=prediction(&math,changed,weights,c,prefix)?;predictions+=1;
            for child in 0..prefix {let u=update(&s,child)?;updates+=1;
                if prefix==1&&(s.q!=[Q,0,0,0]||s.p!=s.q||u.gradient!=[0;5]||u.next!=weights){return Err("prefix1 invariants".into());}}
        }}
    }
    // 専用4predict/7update（negative専用predictも元と同じ入力、全childを追加しない）。
    let cts=integer_cts::normalize(raw,4).map_err(str::to_owned)?;let weights=[Q/4,Q/4,Q/4,Q/4,0];
    let s=prediction(&math,counts,weights,cts,4)?;predictions+=1;let u=update(&s,1)?;updates+=1;
    if cts!=[589505315,2610666396,168430090,926365495]||s.scores!=[7099625000,9162944343,7694719498,8819051486]
        ||s.q!=[816896114,1320698313,938298535,1219074334]||s.p!=[816958821,1320638021,938331602,1219038852]
        ||s.frequencies!=[6233,10076,7159,9300]||u.gradient!=[5536834830,-5930627186,2144632635,1491736668,5049401124]
        ||u.next!=[1095370085,1050575312,1082119295,1079568920,19724223]||u.next[4]==0{return Err("BigInt positive fixture".into());}
    let negative=update(&prediction(&math,counts,weights,cts,4)?,2)?;predictions+=1;updates+=1;
    if negative.gradient[4]>=0||negative.next[4]!=0{return Err("BigInt negative fixture".into());}
    let uniform=prediction(&math,[[1;4];4],[0;5],integer_cts::normalize([1;4],4).map_err(str::to_owned)?,4)?;predictions+=1;
    if uniform.q!=[Q/4;4]||uniform.p!=[Q/4;4]||uniform.frequencies!=[8192;4]{return Err("uniform fixture".into());}
    update(&uniform,0)?;updates+=1;
    let rare=prediction(&math,[[1,32765,1,1];4],[2*Q;5],[1,Q-3,1,1],4)?;predictions+=1;
    if rare.q[0]!=0||rare.frequencies.iter().any(|&v|v<2){return Err("rare q0 fixture".into());}
    for child in 0..4 {let u=update(&rare,child)?;updates+=1;
        if rare.q[child]==0&&(u.factor!=0||u.gradient!=[0;5]||u.next!=[2*Q;5]){return Err("rare zero factor/gradient/next".into());}}
    let snapshot=s.clone();let mut rejects=0;
    let invalid=[
        ("prefix0",counts,weights,cts,0),("prefix5",counts,weights,cts,5),
        ("countzero",[[0;4];4],weights,cts,4),("countsum",[[32768;4];4],weights,cts,4),
        ("weight",counts,[2*Q+1;5],cts,4),("CTSzero",counts,weights,[0;4],4),
        ("CTSinactive",counts,weights,[Q,1,0,0],1),
        ("prefix-before-CTS",counts,weights,[0;4],0),("weight-before-CTS",counts,[2*Q+1;5],[0;4],4),
        ("CTS-before-count",[[0;4];4],weights,[0;4],4),
        ("CTSsum-before-count",[[0;4];4],weights,[1;4],4)];
    let mut reasons=Vec::new();
    for (name,c,w,t,k) in invalid {
        let a=old::predict(&math,c,w,t,k);let b=new::predict(&math,c,w,t,k);
        let (Err(a),Err(b))=(a,b)else{return Err("pool rejection unexpectedly accepted".into());};
        if a!=b{return Err("pool rejection reason mismatch".into());}
        if s!=snapshot||prediction(&math,counts,weights,cts,4)?!=snapshot{return Err("pool state after rejection".into());}
        reasons.push(format!("{{\"name\":\"{name}\",\"reason\":\"{a}\"}}"));rejects+=1;
    }
    let a=old::observe(&s,4);let b=new::observe(&s,4);
    let (Err(a),Err(b))=(a,b)else{return Err("pool child rejection accepted".into());};
    if a!=b||s!=snapshot||prediction(&math,counts,weights,cts,4)?!=snapshot{return Err("pool child rejection/state".into());}
    reasons.push(format!("{{\"name\":\"child\",\"reason\":\"{a}\"}}"));rejects+=1;
    if predictions!=104||updates!=257||rejects!=12{return Err("pool fixed case counts".into());}
    println!("{{\"status\":\"passed\",\"operation\":\"compare-pool\",\"q_fixture_cases\":20,\"active_components\":62,\"residual_coverage_masks\":[1,3,6,15],\"max_mass\":70355859275776,\"max_mass_sum\":70368744177664,\"prediction_all_field_comparisons\":104,\"primary_prediction_all_field_comparisons\":104,\"post_rejection_prediction_all_field_comparisons\":12,\"total_prediction_all_field_comparisons\":116,\"update_all_field_comparisons\":257,\"rejection_cases\":12,\"rejection_after_prediction_comparisons\":12,\"rare_q_zero\":true,\"rare_factor_gradient_zero_next_unchanged\":true,\"proof_method\":\"Prediction/Update all fields Eq and every p element direct comparison\",\"reasons\":[{}],\"diagnostic_only\":true,\"local_timing_added\":false}}",reasons.join(","));
    Ok(())
}
