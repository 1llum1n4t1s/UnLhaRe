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
pub(crate) fn run()->Result<()> {
    let mut counts=Counts::default();
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
        crate::emit(&format!("{{\"operation\":\"compare-kt\",\"status\":\"passed\",\"directed_comparisons\":{directed_comparisons},\"deterministic_raw_vectors\":4096,\"bounded_raw_all_four_sum_checked\":true,\"deterministic_comparisons\":16384,\"comparisons\":{},\"accepted\":{},\"rejected\":{},\"prefix_comparisons\":{:?},\"all_vector_elements_compared\":true,\"error_text_compared\":true,\"prefix_guard_order_checked\":true,\"prefix3_tie_fixtures\":2,\"old_rejection_calls\":1,\"new_rejection_calls\":1,\"old_rejection_tuple\":[14,16,1],\"new_rejection_tuple\":[14,16,1],\"rejection_assertions\":32}}",counts.comparisons,counts.accepted,counts.rejected,counts.prefix))
    }
    #[cfg(not(frame_audit))]
    {Err("compare-kt requires --cfg frame_audit --cfg primitive_audit for both existing rejection helpers".into())}
}
