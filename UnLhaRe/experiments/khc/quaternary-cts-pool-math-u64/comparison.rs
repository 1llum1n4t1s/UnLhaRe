//! Math位置u64全method/table・旧opportunity pool全field比較。
use crate::{fixed_math::{Math,Q,LN2,EXP_CUTOFF},new_math,integer_pool as old,new_pool as new,integer_cts};
use std::collections::BTreeSet;
type Result<T>=crate::Result<T>;
fn prediction(math:&Math,new_math:&new_math::Math,counts:[[u16;4];4],weights:[u64;5],cts:[u64;4],prefix:usize)->Result<old::Prediction>{
    let a=old::predict(math,counts,weights,cts,prefix).map_err(str::to_owned)?;
    let b=new::predict(new_math,counts,weights,cts,prefix).map_err(str::to_owned)?;
    if a!=b{return Err("pool Prediction all fields mismatch".into());}Ok(a)
}
fn update(s:&old::Prediction,child:usize)->Result<old::Update>{
    let a=old::observe(s,child).map_err(str::to_owned)?;
    let b=new::observe(s,child).map_err(str::to_owned)?;
    if a!=b{return Err("pool Update all fields mismatch".into());}Ok(a)
}

fn same<T:Eq>(a:std::result::Result<T,&'static str>,b:std::result::Result<T,&'static str>,scope:&str,errors:&mut usize)->Result<()> {
    if a!=b{return Err(format!("Math result/Err mismatch: {scope}"));}
    if a.is_err(){*errors+=1;}Ok(())
}
fn tables(a:&Math,b:&new_math::Math)->Result<usize>{
    if a.l().len()!=4097||b.l().len()!=4097||a.e().len()!=4097||b.e().len()!=4097||a.counts().len()!=32769||b.counts().len()!=32769{return Err("Math table shape".into());}
    let mut compared=0;
    for (&x,&y) in a.l().iter().zip(b.l()) {if x!=y{return Err("Math L entry mismatch".into());}compared+=1;}
    for (&x,&y) in a.e().iter().zip(b.e()) {if x!=y{return Err("Math E entry mismatch".into());}compared+=1;}
    for (&x,&y) in a.counts().iter().zip(b.counts()) {if x!=y{return Err("Math count entry mismatch".into());}compared+=1;}
    if compared!=40963{return Err("Math table entry count".into());}Ok(compared)
}
fn ceil_fixture(n:u128,d:u128)->Result<i64>{
    if d==0{return Err("fixture zero denominator".into());}
    let v=n.checked_add(d-1).ok_or("fixture ceil overflow")?/d;
    i64::try_from(v).map_err(|_|"fixture signed conversion".into())
}
fn math_comparison(a:&Math,b:&new_math::Math)->Result<(usize,usize,usize,usize,usize,usize,usize)>{
    let mut ns=BTreeSet::from([0,1,Q-1,Q,Q+1,u64::MAX]);
    for e in 0..=32 {let base=1u64<<e;ns.extend([base-1,base,base+1]);}
    if ns.len()!=97{return Err("ln fixture unique count".into());}
    let mut ln_cases=0;let mut ln_errors=0;
    for n in ns {for scale in [0,32,u32::MAX] {same(a.ln_scaled(n,scale),b.ln_scaled(n,scale),"ln_scaled",&mut ln_errors)?;ln_cases+=1;}}
    let mut count_cases=0;let mut count_errors=0;
    for n in [0,1,2,32767,32768,32769,Q,u64::MAX] {same(a.ln_count(n),b.ln_count(n),"ln_count",&mut count_errors)?;count_cases+=1;}
    let mut ds=BTreeSet::from([i64::MIN,-1,0,1,EXP_CUTOFF-1,EXP_CUTOFF,EXP_CUTOFF+1,128*Q as i64,128*Q as i64+1,i64::MAX]);
    for e in 0..=32u128 {
        let n=e.checked_mul(u128::from(LN2)).ok_or("fixture exponent product")?;
        let center=ceil_fixture(n,65536)?;for delta in [-1,0,1] {ds.insert(center.checked_add(delta).ok_or("fixture exponent boundary")?);}
    }
    for e in [0,1,31u128] {for g in 0..=4096u128 {
        let n=e.checked_mul(4096).and_then(|v|v.checked_add(g)).and_then(|v|v.checked_mul(u128::from(LN2))).ok_or("fixture grid product")?;
        let denominator=4096u128.checked_mul(65536).ok_or("fixture grid denominator")?;
        let center=ceil_fixture(n,denominator)?;for delta in [-1,0,1] {ds.insert(center.checked_add(delta).ok_or("fixture grid boundary")?);}
    }}
    if ds.len()!=36958{return Err("exp fixture unique count".into());}
    let mut exp_cases=0;let mut exp_errors=0;
    for d in ds {same(a.exp_neg(d),b.exp_neg(d),"exp_neg",&mut exp_errors)?;exp_cases+=1;}
    let total=ln_cases+count_cases+exp_cases;let errors=ln_errors+count_errors+exp_errors;
    if ln_cases!=291||ln_errors!=103||count_cases!=8||count_errors!=4||exp_cases!=36958||exp_errors!=4||total!=37257||errors!=111{return Err("Math fixed method counts".into());}
    Ok((ln_cases,ln_errors,count_cases,count_errors,exp_cases,exp_errors,total))
}
pub(crate) fn run()->Result<()> {
    let math=Math::new().map_err(str::to_owned)?;let new_math=new_math::Math::new().map_err(str::to_owned)?;
    let before=tables(&math,&new_math)?;
    let (ln_cases,ln_errors,count_cases,count_errors,exp_cases,exp_errors,total)=math_comparison(&math,&new_math)?;
    let counts=[[1,23,7,5],[8,1,37,2],[31,13,1,9],[3,17,5,41]];let raw=[7u128,31,2,11];
    let interior=[13*Q/100,7*Q/10,14*Q/10,3*Q/10,61*Q/100];
    let mut predictions=0;let mut updates=0;
    for prefix in 1..=4 {
        let cts=integer_cts::normalize(raw,prefix).map_err(str::to_owned)?;
        let s=prediction(&math,&new_math,counts,interior,cts,prefix)?;predictions+=1;
        for child in 0..prefix {update(&s,child)?;updates+=1;}
        for weights in [[0;5],[2*Q;5],[Q/4,Q/4,Q/4,Q/4,0]] {for variant in 0..8 {
            let mut changed=counts;let mut c=cts;
            match variant {0=>changed=[[1;4];4],1..=4=>changed[variant-1][0]=30000,
                5=>c=integer_cts::normalize([1,1,1,u128::from(Q)],prefix).map_err(str::to_owned)?,
                6=>c=integer_cts::normalize([u128::from(Q),1,1,1],prefix).map_err(str::to_owned)?,_=>{}}
            let s=prediction(&math,&new_math,changed,weights,c,prefix)?;predictions+=1;
            for child in 0..prefix {let u=update(&s,child)?;updates+=1;
                if prefix==1&&(s.q!=[Q,0,0,0]||s.p!=s.q||u.gradient!=[0;5]||u.next!=weights){return Err("prefix1 invariants".into());}}
        }}
    }
    // 専用4predict/7update（negative専用predictも元と同じ入力、全childを追加しない）。
    let cts=integer_cts::normalize(raw,4).map_err(str::to_owned)?;let weights=[Q/4,Q/4,Q/4,Q/4,0];
    let s=prediction(&math,&new_math,counts,weights,cts,4)?;predictions+=1;let u=update(&s,1)?;updates+=1;
    if cts!=[589505315,2610666396,168430090,926365495]||s.scores!=[7099625000,9162944343,7694719498,8819051486]
        ||s.q!=[816896114,1320698313,938298535,1219074334]||s.p!=[816958821,1320638021,938331602,1219038852]
        ||s.frequencies!=[6233,10076,7159,9300]||u.gradient!=[5536834830,-5930627186,2144632635,1491736668,5049401124]
        ||u.next!=[1095370085,1050575312,1082119295,1079568920,19724223]||u.next[4]==0{return Err("BigInt positive fixture".into());}
    let negative=update(&prediction(&math,&new_math,counts,weights,cts,4)?,2)?;predictions+=1;updates+=1;
    if negative.gradient[4]>=0||negative.next[4]!=0{return Err("BigInt negative fixture".into());}
    let uniform=prediction(&math,&new_math,[[1;4];4],[0;5],integer_cts::normalize([1;4],4).map_err(str::to_owned)?,4)?;predictions+=1;
    if uniform.q!=[Q/4;4]||uniform.p!=[Q/4;4]||uniform.frequencies!=[8192;4]{return Err("uniform fixture".into());}
    update(&uniform,0)?;updates+=1;
    let rare=prediction(&math,&new_math,[[1,32765,1,1];4],[2*Q;5],[1,Q-3,1,1],4)?;predictions+=1;
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
        let a=old::predict(&math,c,w,t,k);let b=new::predict(&new_math,c,w,t,k);
        let (Err(a),Err(b))=(a,b)else{return Err("pool rejection unexpectedly accepted".into());};
        if a!=b{return Err("pool rejection reason mismatch".into());}
        if s!=snapshot||prediction(&math,&new_math,counts,weights,cts,4)?!=snapshot{return Err("pool state after rejection".into());}
        reasons.push(format!("{{\"name\":\"{name}\",\"reason\":\"{a}\"}}"));rejects+=1;
    }
    let a=old::observe(&s,4);let b=new::observe(&s,4);
    let (Err(a),Err(b))=(a,b)else{return Err("pool child rejection accepted".into());};
    if a!=b||s!=snapshot||prediction(&math,&new_math,counts,weights,cts,4)?!=snapshot{return Err("pool child rejection/state".into());}
    reasons.push(format!("{{\"name\":\"child\",\"reason\":\"{a}\"}}"));rejects+=1;
    if predictions!=104||updates!=257||rejects!=12{return Err("pool fixed case counts".into());}

    let after=tables(&math,&new_math)?;if before+after!=81926{return Err("Math tables before/after count".into());}
    println!("{{\"status\":\"passed\",\"operation\":\"compare-math\",\"old_math_constructions\":1,\"new_math_constructions\":1,\"ln_n_unique\":97,\"ln_cases\":{ln_cases},\"ln_errors\":{ln_errors},\"ln_normal\":188,\"count_cases\":{count_cases},\"count_errors\":{count_errors},\"count_normal\":4,\"exp_unique\":36958,\"exp_cases\":{exp_cases},\"exp_errors\":{exp_errors},\"exp_normal\":36954,\"method_cases\":{total},\"method_errors\":111,\"method_normal\":37146,\"table_entries_per_pass\":40963,\"table_passes\":2,\"table_entry_comparisons\":81926,\"table_l_entries\":4097,\"table_e_entries\":4097,\"table_count_entries\":32769,\"tables_after_methods_equal\":true,\"prediction_all_field_comparisons\":104,\"primary_prediction_all_field_comparisons\":104,\"post_rejection_prediction_all_field_comparisons\":12,\"total_prediction_all_field_comparisons\":116,\"update_all_field_comparisons\":257,\"rejection_cases\":12,\"rejection_after_prediction_comparisons\":12,\"rare_q_zero\":true,\"rare_factor_gradient_zero_next_unchanged\":true,\"proof_method\":\"Math every table entry and method Result/Err; Prediction/Update all fields Eq\",\"reasons\":[{}],\"diagnostic_only\":true,\"local_timing_added\":false}}",reasons.join(","));
    Ok(())
}
