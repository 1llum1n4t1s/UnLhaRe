type Result<T> = std::result::Result<T,String>;
// @adversarial @category type/state @severity HIGH
// @description 範囲外query/updateがnarrowの頻度表を変更しないことを全文比較する。
// @expected prefix2/observe2拒否、leaf/tree/total不変。読取統計は論理頻度と区別。
pub fn fenwick() -> Result<String> {
    let mut table=crate::fenwick::Table::new(1)?;
    let leaf=table.leaf.clone();let tree=table.tree.clone();let total=table.total.clone();
    let mut rejected=0;
    for (row,k) in [(1usize,0usize),(0,258)] {
        if table.prefix(row,k).is_ok() {return Err("invalid narrow prefix accepted".into());}
        rejected+=1;
    }
    for (row,token) in [(1usize,0usize),(0,257)] {
        if table.observe(row,token).is_ok() {return Err("invalid narrow observe accepted".into());}
        rejected+=1;
    }
    if table.leaf!=leaf || table.tree!=tree || table.total!=total {
        return Err("range rejection modified logical frequency state".into());
    }
    if crate::fenwick::Table::new(0).is_ok() {return Err("zero rows accepted".into());}
    Ok(format!("{{\"range_rejections\":{rejected},\"constructor_rejections\":1,\"whole_frequency_state_unchanged\":true}}"))
}
// @adversarial @category resource/state/type @severity HIGH
// @description 実RAMを枯渇させず、小容量mapの満杯・empty key・古い予約を拒否する。
// @expected 満杯/empty prepare/empty find/stale commitの4拒否で全配列不変。
pub fn dictionary() -> Result<String> {
    let mut full=crate::dictionary::ExactMap::new(4)?;
    for key in [0u32,1,18,21] {let plan=full.prepare(key)?;full.commit(plan)?;}
    let keys=full.keys.clone();let rows=full.rows.clone();let used=full.used;
    let mut rejected=0;
    if full.prepare(43).is_ok() {return Err("full map accepted new key".into());}rejected+=1;
    if full.prepare(u32::MAX).is_ok() {return Err("empty key prepare accepted".into());}rejected+=1;
    if full.find(u32::MAX).is_ok() {return Err("empty key find accepted".into());}rejected+=1;
    if full.keys!=keys || full.rows!=rows || full.used!=used {
        return Err("dictionary rejection modified full state".into());
    }
    let mut stale=crate::dictionary::ExactMap::new(2)?;
    let reserved=stale.prepare(0)?;
    let other=stale.prepare(1)?;stale.commit(other)?;
    let keys=stale.keys.clone();let rows=stale.rows.clone();let used=stale.used;
    if stale.commit(reserved).is_ok() {return Err("stale reservation accepted".into());}rejected+=1;
    if stale.keys!=keys || stale.rows!=rows || stale.used!=used {
        return Err("stale commit modified full dictionary state".into());
    }
    if crate::dictionary::ExactMap::new(0).is_ok()
        || crate::dictionary::ExactMap::new(65537).is_ok() {
        return Err("dictionary invalid capacity accepted".into());
    }
    Ok(format!("{{\"rejections\":{rejected},\"constructor_rejections\":2,\"whole_map_rejection_state_unchanged\":true}}"))
}
// @adversarial @category resource/state/type @severity HIGH
// @description small poolの満杯と不正予測・重み・自然なstaleを全論理状態比較で拒否する。
// @expected 満杯1/token3/key4/weights6/stale1を拒否。読取opsは別扱い。
pub fn mixture() -> Result<String> {
    // recentには空き1、jointだけ満杯。逐次登録してからjoint失敗する実装を検出する。
    let mut mix=crate::mixture::Mix::new_with_pool_rows(2,1)?;
    let keys=crate::mixture::four_keys(0,512,0)?;
    mix.predict(keys,0,5)?;
    let state=crate::happy::snapshot(&mix);
    let other=crate::mixture::four_keys(0,1024,1)?;
    if mix.predict(other,0,5).is_ok() || crate::happy::snapshot(&mix)!=state {
        return Err("full exact pools accepted or partially registered".into());
    }
    let mut token_rejections=0;
    for (token,limit) in [(0usize,0usize),(0,258),(5,5)] {
        if mix.predict(keys,token,limit).is_ok() || crate::happy::snapshot(&mix)!=state {
            return Err("invalid token/limit modified exact model".into());
        }
        token_rejections+=1;
    }
    let mut key_rejections=0;
    for bad in [[32,keys[1],keys[2],keys[3]],[keys[0],511,keys[2],keys[3]],
        [keys[0],keys[1],keys[2],keys[3]|256],[keys[0],keys[1],1<<20,keys[3]]] {
        if mix.predict(bad,0,5).is_ok() || crate::happy::snapshot(&mix)!=state {
            return Err("invalid key modified exact model".into());
        }
        key_rejections+=1;
    }
    drop(state);
    let saved=mix.weights[0];let mut weight_rejections=0;
    for invalid in [[f64::NAN,0.25,0.25,0.25],[f64::INFINITY,0.25,0.25,0.25],
        [0.0,0.25,0.25,0.5],[-0.25,0.25,0.5,0.5],[0.25,0.25,0.25,0.5],
        [1.25,0.25,0.25,0.25]] {
        mix.weights[0]=invalid;let state=crate::happy::snapshot(&mix);
        if mix.predict(keys,0,5).is_ok() || crate::happy::snapshot(&mix)!=state {
            return Err("invalid weights modified exact model".into());
        }
        weight_rejections+=1;
    }
    mix.weights[0]=saved;
    let rows=mix.predict(keys,0,5)?.rows;
    for i in 0..4 {for _ in 0..[8,4,2,1][i] {mix.banks[i].table.observe(rows[i],i)?;}}
    let first=mix.predict(keys,2,5)?;let stale=mix.predict(keys,2,5)?;
    let old_weights=mix.weights[0].map(f64::to_bits);
    mix.observe(first)?;
    if mix.weights[0].map(f64::to_bits)==old_weights {return Err("stale fixture did not change weights".into());}
    let state=crate::happy::snapshot(&mix);
    if mix.observe(stale).is_ok() || crate::happy::snapshot(&mix)!=state {
        return Err("stale prediction modified exact state".into());
    }
    Ok(format!("{{\"full_pool_rejections\":1,\"token_limit_rejections\":{token_rejections},\"key_rejections\":{key_rejections},\"weight_rejections\":{weight_rejections},\"nonstationary_stale_rejections\":1,\"whole_logical_rejection_state_unchanged\":true,\"stationary_stale_guarantee\":false}}"))
}
