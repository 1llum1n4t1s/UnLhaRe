//! KTの全vector/拒否字面を直接比較するstandalone E2E。
use crate::{new_cts as old,optimized_cts as new};
type Result<T>=crate::Result<T>;
#[derive(Default)]
struct Counts {comparisons:usize,accepted:usize,rejected:usize,prefix:[usize;6]}
fn compare(raw:[u32;4],k:usize,expected_error:Option<&str>,counts:&mut Counts)->Result<()> {
    let a=old::kt(raw,k);let b=new::kt(raw,k);
    if a!=b{return Err(format!("KT all elements/error mismatch raw={raw:?} prefix={k} old={a:?} new={b:?}"));}
    if let Some(expected)=expected_error {
        if a!=Err(expected){return Err(format!("KT guard order raw={raw:?} prefix={k} expected={expected} actual={a:?}"));}
    }else if a.is_err(){return Err(format!("valid KT rejected raw={raw:?} prefix={k} result={a:?}"));}
    counts.comparisons+=1;counts.prefix[k]+=1;
    if a.is_ok(){counts.accepted+=1;}else{counts.rejected+=1;}Ok(())
}
fn all_prefixes(raw:[u32;4],counts:&mut Counts)->Result<()> {
    let error=if raw.iter().map(|&v|u64::from(v)).sum::<u64>()>u64::from(old::CAP){Some("raw observation cap")}else{None};
    for k in 1..=4 {compare(raw,k,error,counts)?;}Ok(())
}
fn permutations(raw:[u32;4],counts:&mut Counts)->Result<()> {
    // 24 index permutationsを全部比較する。同値による重複も固定件数に含む。
    for a in 0..4 {for b in 0..4 {if b==a{continue;}
        for c in 0..4 {if c==a||c==b{continue;}
            let d=6-a-b-c;all_prefixes([raw[a],raw[b],raw[c],raw[d]],counts)?;
        }
    }}Ok(())
}
#[derive(Default)]
struct MixtureCounts {comparisons:usize,accepted:usize,rejected:usize,left:[usize;4],left1_ties:usize}
fn mixture_case(weight:u64,own:[u64;4],child:[u64;4],k:usize,error:Option<&str>,c:&mut MixtureCounts)->Result<()> {
    let a=old::mixture(weight,own,child,k);let b=new::mixture(weight,own,child,k);
    if a!=b{return Err(format!("mixture all fields/error mismatch weight={weight} own={own:?} child={child:?} prefix={k} old={a:?} new={b:?}"));}
    c.comparisons+=1;
    match (a,error) {
        (Ok((vector,masses)),None)=>{
            c.accepted+=1;
            let left=(old::Q-masses[..k].iter().map(|m|(m>>32) as u64).sum::<u64>()) as usize;
            if left>=k{return Err("mixture coverage Hamilton count".into());}c.left[left]+=1;
            let remainder=masses.map(|m|m&u128::from(old::Q-1));
            if left==1 {let max=*remainder[..k].iter().max().unwrap();
                if remainder[..k].iter().filter(|&&r|r==max).count()>1 {c.left1_ties+=1;}}
            if vector[k..].iter().any(|&v|v!=0)||masses[k..].iter().any(|&v|v!=0){return Err("mixture inactive fields".into());}
        },
        (Err(actual),Some(expected)) if actual==expected=>{c.rejected+=1;},
        (actual,expected)=>return Err(format!("mixture guard/valid expectation actual={actual:?} expected={expected:?}")),
    }Ok(())
}
fn mixtures()->Result<MixtureCounts> {
    let mut c=MixtureCounts::default();let q=old::Q;
    for weight in [0,1,q/2,q-1,q] {mixture_case(weight,[q-3,1,1,1],[q/4;4],4,None,&mut c)?;}
    mixture_case(1,[1,q/2-1,q/2-1,1],[1,1,1,q-3],4,None,&mut c)?;
    if c.left.iter().any(|&n|n==0)||c.left1_ties==0{return Err("mixture directed left/tie coverage".into());}
    for k in 1..=4 {
        let own=old::kt([0,1,2,3],k).map_err(str::to_owned)?;
        let child=old::kt([3,2,1,0],k).map_err(str::to_owned)?;
        for weight in [0,1,q/4,q/2,q-1,q] {mixture_case(weight,own,child,k,None,&mut c)?;}
    }
    let valid=[q,0,0,0];
    for k in [0,5] {mixture_case(q+1,[0;4],[0;4],k,Some("weight outside Q"),&mut c)?;
        mixture_case(q,valid,valid,k,Some("invalid prefix"),&mut c)?;}
    mixture_case(q+1,[0;4],[0;4],4,Some("weight outside Q"),&mut c)?;
    mixture_case(1,[1;4],[0;4],4,Some("vector sum differs from Q"),&mut c)?;
    mixture_case(1,[0;4],[1;4],4,Some("invalid categorical vector"),&mut c)?;
    mixture_case(1,[q/4;4],[1;4],4,Some("vector sum differs from Q"),&mut c)?;
    mixture_case(1,[q/4;4],[0;4],4,Some("invalid categorical vector"),&mut c)?;
    mixture_case(1,[q+1,1,1,1],[q/4;4],4,Some("invalid categorical vector"),&mut c)?;
    mixture_case(1,[q-1,1,1,0],valid,2,Some("invalid categorical vector"),&mut c)?;
    let mut state=0x6a09e667f3bcc909u64;
    for index in 0..4096 {
        let k=1+index%4;let mut raws=[[0u32;4];2];
        for raw in &mut raws {let mut remaining=old::CAP;
            for value in raw {state=state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
                *value=((state>>32)%(u64::from(remaining)+1)) as u32;remaining-=*value;}}
        let own=old::kt(raws[0],k).map_err(str::to_owned)?;let child=old::kt(raws[1],k).map_err(str::to_owned)?;
        state=state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        mixture_case(state%(q+1),own,child,k,None,&mut c)?;
    }
    if c.comparisons!=4137||c.accepted!=4126||c.rejected!=11{return Err("mixture fixed count".into());}Ok(c)
}
fn cts_contract()->Result<(usize,usize)> {
    let mut accepted=0;let mut rejected=0;
    macro_rules! check {($module:ident)=>{{
        let mut current=$module::Cts::new(5)?;
        let first=current.predict(0,4)?;current.observe(&first,0)?;accepted+=1;
        let before=current.clone();if current.observe(&first,0).is_ok()||current!=before{return Err("CTS stale rejection/state".into());}rejected+=1;
        let mut foreign=$module::Cts::new(5)?;let s=foreign.predict(0,4)?;foreign.observe(&s,1)?;
        let mut repaired=foreign.predict(0,4)?;let now=current.predict(0,4)?;
        *std::ops::DerefMut::deref_mut(&mut repaired)=std::ops::Deref::deref(&now).clone();
        let mut expected=current.clone();expected.observe(&now,2)?;current.observe(&repaired,2)?;
        if current!=expected{return Err("CTS repaired visible acceptance/state".into());}accepted+=1;
        let mut changed=current.predict(0,4)?;changed.kernel.mixed[0][0]^=1;
        let before=current.clone();if current.observe(&changed,0).is_ok()||current!=before{return Err("CTS modified derived rejection/state".into());}rejected+=1;
        let mut tail=current.predict(0,4)?;tail.kernel.mixed[$module::LEVELS-1][3]^=1;
        let before=current.clone();if current.observe(&tail,0).is_ok()||current!=before{return Err("CTS tail rejection/state".into());}rejected+=1;
    }};}
    check!(old);check!(new);if accepted!=4||rejected!=6{return Err("CTS contract count".into());}Ok((accepted,rejected))
}
pub(crate) fn run()->Result<()> {
    let mut counts=Counts::default();
    let mixture=mixtures()?;let (cts_accepted,cts_rejected)=cts_contract()?;
    for raw in [[0;4],[1;4],[old::CAP/4;4]] {all_prefixes(raw,&mut counts)?;}
    for n in [1,7,old::CAP/2,old::CAP] {for position in 0..4 {
        let mut raw=[0;4];raw[position]=n;all_prefixes(raw,&mut counts)?;
    }}
    for raw in [[1,1,2,2],[0,1,1,2],[0,1,2,3],[1,2,1,2],
        [0,0,1,2],[3,3,3,7],[7,1,7,2],[1,2,3,4]] {permutations(raw,&mut counts)?;}
    for raw in [[old::CAP-1,1,0,0],[old::CAP/2,old::CAP/2,0,0],
        [old::CAP/4;4],[0,0,0,old::CAP],[old::CAP-3,1,1,1],
        [old::CAP/3,old::CAP/3,old::CAP-2*(old::CAP/3),0],
        [0,old::CAP/2,0,old::CAP/2],[1,0,0,old::CAP-1]] {all_prefixes(raw,&mut counts)?;}
    for position in 0..4 {
        let mut raw=[0;4];raw[position]=old::CAP+1;all_prefixes(raw,&mut counts)?;
        raw=[0;4];raw[position]=old::CAP;raw[(position+1)%4]=1;all_prefixes(raw,&mut counts)?;
        raw=[0;4];raw[position]=u32::MAX;all_prefixes(raw,&mut counts)?;
    }
    all_prefixes([u32::MAX;4],&mut counts)?;
    for raw in [[0;4],[old::CAP+1,0,0,0],[u32::MAX;4]] {
        for k in [0,5] {compare(raw,k,Some("invalid prefix"),&mut counts)?;}
    }
    // prefix3の全同値余りでHamilton child昇順tieを固定vectorでも確認。
    for raw in [[0;4],[1;4]] {
        compare(raw,3,None,&mut counts)?;
        if old::kt(raw,3)!=Ok([old::Q/3+1,old::Q/3,old::Q/3,0]) {return Err("prefix3 remainder tie fixture".into());}
    }
    let directed_comparisons=counts.comparisons;
    if directed_comparisons!=936{return Err("KT directed coverage count".into());}
    let mut state=0x9e3779b97f4a7c15u64;
    for index in 0..4096 {
        let mut raw=[0u32;4];let mut remaining=old::CAP;
        for value in &mut raw {
            state=state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
            *value=((state>>32)%(u64::from(remaining)+1)) as u32;remaining-=*value;
        }
        raw.rotate_left(index%4);
        if raw.iter().map(|&v|u64::from(v)).sum::<u64>()>u64::from(old::CAP){return Err("bounded raw generator CAP".into());}
        all_prefixes(raw,&mut counts)?;
    }
    if counts.comparisons!=17320||counts.accepted!=17262||counts.rejected!=58||counts.prefix!=[3,4328,4328,4330,4328,3] {
        return Err(format!("KT fixed coverage comparisons={} accepted={} rejected={} prefix={:?}",counts.comparisons,counts.accepted,counts.rejected,counts.prefix));
    }
    #[cfg(frame_audit)]
    {
        let old_rejections=crate::codec::model::rejection_checks(5)?;
        let new_rejections=crate::codec::optimized::model::rejection_checks(5)?;
        if old_rejections!=new_rejections||old_rejections!=(14,16,1){return Err("old/new rejection E2E tuple mismatch".into());}
        crate::emit(&format!("{{\"operation\":\"compare-kt\",\"status\":\"passed\",\"directed_comparisons\":{directed_comparisons},\"deterministic_raw_vectors\":4096,\"bounded_raw_all_four_sum_checked\":true,\"deterministic_comparisons\":16384,\"comparisons\":{},\"accepted\":{},\"rejected\":{},\"prefix_comparisons\":{:?},\"all_vector_elements_compared\":true,\"error_text_compared\":true,\"prefix_guard_order_checked\":true,\"prefix3_tie_fixtures\":2,\"old_rejection_calls\":1,\"new_rejection_calls\":1,\"old_rejection_tuple\":[14,16,1],\"new_rejection_tuple\":[14,16,1],\"rejection_assertions\":32,\"mixture_comparisons\":{},\"mixture_accepted\":{},\"mixture_rejected\":{},\"mixture_left_counts\":{:?},\"mixture_left1_max_ties\":{},\"mixture_deterministic_vectors\":4096,\"mixture_all_fields_errors_compared\":true,\"mixture_guard_order_checked\":true,\"cts_accepted\":{cts_accepted},\"cts_rejected\":{cts_rejected},\"repaired_current_visible_accepted_both\":true,\"cts_full_state_rejection_preserved\":true}}",counts.comparisons,counts.accepted,counts.rejected,counts.prefix,mixture.comparisons,mixture.accepted,mixture.rejected,mixture.left,mixture.left1_ties))
    }
    #[cfg(not(frame_audit))]
    {Err("compare-kt requires --cfg frame_audit --cfg primitive_audit for both existing rejection helpers".into())}
}
