use crate::fenwick::{A, Table};
type Result<T> = std::result::Result<T, String>;
// @happypath @category happy/boundary @severity HIGH
// @description narrow Fenwickと凍結u32版をdense前置和へ、rescale直前直後も比較する。
// @expected 3rows、16256更新、rescale1、total32767に到達し全prefix/leaf一致。
pub fn fenwick() -> Result<String> {
    let mut candidate=Table::new(3)?;
    let mut original=crate::old_fenwick::Table::new(3)?;
    let mut dense=[[1u16;A];3];
    let mut prefixes=0usize;
    let mut maximum_total=0u32;
    for row in 0..3 {check(&mut candidate,&mut original,row,&dense[row],&mut prefixes)?;}
    for n in 0..16256usize {
        let token=if n<A {n} else {2};
        let sum=dense[0].iter().map(|&x| x as u32).sum::<u32>();
        if sum+2>=32768 {for value in &mut dense[0] {*value=((*value as u32+1)/2) as u16;}}
        dense[0][token]+=2;
        candidate.observe(0,token)?;original.observe(0,token)?;
        maximum_total=maximum_total.max(candidate.total[0]);
        check(&mut candidate,&mut original,0,&dense[0],&mut prefixes)?;
    }
    if prefixes!=4194822 || maximum_total!=32767 || candidate.ops.rescales!=1
        || original.ops.rescales!=1 || candidate.ops.updates!=16256
        || candidate.verify_all()?!=771 || original.verify_all()?!=771
        || candidate.leaf!=original.leaf || candidate.total!=original.total {
        return Err("narrow Fenwick boundary/terminal extent".into());
    }
    Ok(format!("{{\"rows\":3,\"updates\":16256,\"rescales\":1,\"maximum_total\":{maximum_total},\"dense_and_old_prefix_checks\":{prefixes},\"terminal_nodes\":771,\"all_leaf_total_equal\":true}}"))
}
fn check(candidate:&mut Table,original:&mut crate::old_fenwick::Table,row:usize,dense:&[u16;A],checks:&mut usize)->Result<()> {
    let mut sum=0u32;
    for k in 0..=A {
        if k>0 {sum+=dense[k-1] as u32;}
        if candidate.prefix(row,k)?!=sum || original.prefix(row,k)?!=sum {
            return Err(format!("dense/old prefix mismatch row={row} k={k}"));
        }
        *checks+=1;
    }
    if candidate.total[row]!=sum || original.total[row]!=sum
        || candidate.leaf[row*A..(row+1)*A]!=*dense
        || original.leaf[row*A..(row+1)*A]!=*dense {
        return Err("dense/old leaf total mismatch".into());
    }
    Ok(())
}
// @happypath @category happy/state @severity HIGH
// @description 同hash slotの4keyを別rowへ登録し、同順の第二mapと全文比較する。
// @expected [0,1,18,21]はslot0から線形探索、row0..3。同key再登録で変更なし。
pub fn dictionary() -> Result<String> {
    let mut a=crate::dictionary::ExactMap::new(4)?;
    let mut b=crate::dictionary::ExactMap::new(4)?;
    let keys=[0u32,1,18,21];
    for (row,&key) in keys.iter().enumerate() {
        let pa=a.prepare(key)?;let pb=b.prepare(key)?;
        if a.commit(pa)?!=row || b.commit(pb)?!=row
            || a.find(key)?!=Some(row) || b.find(key)?!=Some(row) {
            return Err("exact collision distinct row".into());
        }
        if a.keys!=b.keys || a.rows!=b.rows || a.used!=b.used {
            return Err("deterministic dictionary registration state".into());
        }
    }
    if a.keys.len()!=8 || a.rows.len()!=8 || a.capacity!=4 || a.used!=4
        || a.keys[..4]!=keys || a.rows[..4]!=[0u32,1,2,3] {
        return Err("fixed same-slot dictionary fixture".into());
    }
    let old_keys=a.keys.clone();let old_rows=a.rows.clone();
    for (row,&key) in keys.iter().enumerate() {
        let plan=a.prepare(key)?;
        if a.commit(plan)?!=row {return Err("existing key row changed".into());}
    }
    if a.keys!=old_keys || a.rows!=old_rows || a.used!=4 || a.find(43)?!=None {
        return Err("existing dictionary registration mutated state".into());
    }
    Ok("{\"collision_keys\":4,\"deterministic_maps\":2,\"existing_key_reregistrations\":4,\"whole_map_equal\":true}".into())
}
type BankState=(Vec<u16>,Vec<u16>,Vec<u32>,Vec<u32>,Option<(Vec<u32>,Vec<u32>,usize,usize)>,u64);
#[derive(PartialEq,Eq)]
pub struct LogicalState {banks:Vec<BankState>,weights:[[u64;4];32],observations:u64}
pub fn snapshot(mix:&crate::mixture::Mix)->LogicalState {
    LogicalState {
        banks:mix.banks.iter().map(|b| (b.table.leaf.clone(),b.table.tree.clone(),
            b.table.total.clone(),b.first_key.clone(),b.map.as_ref().map(|m|
                (m.keys.clone(),m.rows.clone(),m.used,m.capacity)),b.active_rows)).collect(),
        weights:mix.weights.map(|w| w.map(f64::to_bits)),observations:mix.observations,
    }
}
// @happypath @category happy/state @severity HIGH
// @description exact rowとdense scalarの全CDFを比較し、非一様seed後のposteriorを確認する。
// @expected CDF524区間、4重み、4bankの更新全leaf一致、endpoint32768。
pub fn mixture() -> Result<String> {
    let mut mix=crate::mixture::Mix::new_with_pool_rows(1,1)?;
    let keys=crate::mixture::four_keys(0,512,0)?;
    let registration=mix.predict(keys,0,5)?;
    let rows=registration.rows;
    let mut dense=[[1u16;A];4];
    // 私有E2Eだけの非一様seed。API経由の通常観測履歴とは区別する。
    for i in 0..4 {for _ in 0..[8,4,2,1][i] {
        mix.banks[i].table.observe(rows[i],i)?;dense[i][i]+=2;
    }}
    let mut intervals=0;
    for limit in [1usize,5,256,257] {cdf(&mut mix,&dense,keys,limit,&mut intervals)?;}
    let prediction=mix.predict(keys,2,5)?;
    let weights=mix.weights[0];let mut probabilities=[0f64;4];let mut denominator=0f64;
    for i in 0..4 {
        let total=dense[i][..5].iter().map(|&x| x as u32).sum::<u32>();
        probabilities[i]=dense[i][2] as f64/total as f64;
        denominator+=weights[i]*probabilities[i];
        if (prediction.probabilities[i]-probabilities[i]).abs()>1e-15 {
            return Err("dense exact expert probability".into());
        }
    }
    mix.observe(prediction)?;
    for i in 0..4 {
        let expected=(255.0/256.0)*(weights[i]*probabilities[i]/denominator)+1.0/1024.0;
        if (mix.weights[0][i]-expected).abs()>1e-15 {return Err("dense exact posterior".into());}
        dense[i][2]+=2;
        if mix.banks[i].table.leaf[rows[i]*A..(rows[i]+1)*A]!=dense[i] {
            return Err("exact bank whole observed leaf".into());
        }
    }
    cdf(&mut mix,&dense,keys,5,&mut intervals)?;
    if intervals!=524 || mix.observations!=1 {return Err("exact mixture E2E extent".into());}
    mix.verify_terminal()?;
    Ok(format!("{{\"full_CDF_interval_checks\":{intervals},\"posterior_weights\":4,\"whole_observed_banks\":4,\"observations\":1,\"dense_oracle_equal\":true}}"))
}
fn scalar(dense:&[[u16;A];4],weights:&[f64;4],k:usize,limit:usize)->u32 {
    if k==0 {return 0;}if k==limit {return 32768;}
    let mut sum=0f64;
    for i in 0..4 {
        let prefix=dense[i][..k].iter().map(|&x| x as u32).sum::<u32>();
        let total=dense[i][..limit].iter().map(|&x| x as u32).sum::<u32>();
        sum+=weights[i]*(prefix as f64/total as f64);
    }
    k as u32+((32768-limit) as f64*sum).floor() as u32
}
fn cdf(mix:&mut crate::mixture::Mix,dense:&[[u16;A];4],keys:[u32;4],limit:usize,checks:&mut usize)->Result<()> {
    let weights=mix.weights[keys[0] as usize];let mut last=0;
    for token in 0..limit {
        let p=mix.predict(keys,token,limit)?;
        let low=scalar(dense,&weights,token,limit);let high=scalar(dense,&weights,token+1,limit);
        if p.low!=low || p.high!=high || low!=last || low>=high {
            return Err("independent exact full CDF".into());
        }
        last=high;*checks+=1;
    }
    if last!=32768 {return Err("exact CDF endpoint".into());}Ok(())
}
