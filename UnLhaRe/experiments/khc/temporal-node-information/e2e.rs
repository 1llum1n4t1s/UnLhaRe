use crate::{counts, frontend, grammar, tiles::{self, Accumulator, Stat, Summary}};
type Result<T> = std::result::Result<T, String>;
fn noop(_: usize, _: usize, _: [u32; 4]) -> Result<()> { Ok(()) }

// Dense index/quantize/集計を呼ばない、小さい独立算術oracle。
fn oracle(row: [u32; 4], k: usize) -> Stat {
    let total: u64 = row.iter().map(|&v| u64::from(v)).sum();
    let mut result = Stat::default();
    result.count = total;
    result.active = u64::from(total != 0);
    result.cells = row.iter().filter(|&&v| v != 0).count() as u64;
    result.pure = u64::from(result.cells == 1);
    if total == 0 { return result; }
    let budget = 32768 - 2 * k as u64;
    let mut q = [0u64; 4];
    let mut rem = [0u64; 4];
    let mut used = 0;
    for i in 0..k { q[i] = 2 + budget * u64::from(row[i]) / total;
        rem[i] = budget * u64::from(row[i]) % total; used += q[i]; }
    let mut awarded = [false; 4];
    for _ in used..32768 {
        let mut winner = None;
        for i in 0..k {
            if !awarded[i] && winner.map_or(true, |old| rem[i] > rem[old]) { winner = Some(i); }
        }
        let i = winner.expect("bounded Hamilton remainder"); awarded[i] = true; q[i] += 1;
    }
    for i in 0..k {
        let n = row[i] as f64;
        if n != 0.0 {
            result.empirical.sum += n * ((total as f64).log2() - n.log2());
            result.quantized.sum += n * (15.0 - (q[i] as f64).log2());
        }
    }
    result
}
fn independent_add(target: &mut Stat, x: Stat) {
    target.count += x.count; target.active += x.active; target.pure += x.pure; target.cells += x.cells;
    target.empirical.sum += x.empirical.sum; target.quantized.sum += x.quantized.sum;
}
fn compare(actual: &Summary, expected: &Summary) -> Result<()> {
    for c in 0..2 {
        if !tiles::same(actual.components[c], expected.components[c]) || actual.implicit[c] != expected.implicit[c] {
            return Err("independent component/implicit oracle".into());
        }
        for n in 0..counts::NODE_COUNT {
            if !tiles::same(actual.nodes[c][n], expected.nodes[c][n]) { return Err("independent node oracle".into()); }
        }
    }
    if !tiles::same(actual.whole, expected.whole) { return Err("independent whole oracle".into()); }
    Ok(())
}
fn synthetic_boundary() -> Result<usize> {
    // 明示6rowsだけ。131079 eventsのtraceは保存しない。
    let sparse = [(0usize,433152usize,0usize,2usize,[2,1,0,0]),
        (0,869376,1,2,[2,1,0,0]), (0,434177,0,3,[1,0,0,0]),
        (0,870401,1,3,[0,0,1,0]), (1,435216,0,4,[0,0,0,1]),
        (1,871430,1,4,[1,0,0,0])];
    let mut expected = [Summary::default(); 2];
    expected[0].implicit = [65535,65534];
    for &(tile,_,c,k,row) in &sparse {
        let x = oracle(row,k);
        independent_add(&mut expected[tile].nodes[c][141],x);
        independent_add(&mut expected[tile].components[c],x);
        independent_add(&mut expected[tile].whole,x);
    }
    let mut scanned = [0usize; 2];
    let mut observe = |tile: usize, index: usize, row: [u32; 4]| -> Result<()> {
        if tile >= 2 || index != scanned[tile] { return Err("oracle flush row order/double".into()); }
        let want = sparse.iter().find(|&&(t,i,_,_,_)| t==tile && i==index).map(|x|x.4).unwrap_or([0;4]);
        for child in 0..4 { if row[child] != want[child] { return Err("independent all-row/child oracle".into()); } }
        scanned[tile] += 1;
        Ok(())
    };
    let mut a = Accumulator::new(65537)?;
    for run in 0..65537 {
        for c in 0..2 {
            let class = c*3+2;
            if run == 0 {
                for child in [0,0,1] { a.record(c,141,class,2,a.history[class],child,run,&mut observe)?; }
            } else if run == 65535 {
                a.record(c,141,class,3,a.history[class],if c==0 {0}else{2},run,&mut observe)?;
                if c==0 { a.record(c,141,class,1,a.history[class],0,run,&mut observe)?; }
            } else if run == 65536 {
                // 更新前history16/6は前tileのprefix1を含む。flushでresetされない。
                if a.history[class] != if c==0 {16}else{6} { return Err("cross-tile history/prefix1".into()); }
                a.record(c,141,class,4,a.history[class],if c==0 {3}else{0},run,&mut observe)?;
            } else { a.record(c,0,c*3,1,0,0,run,&mut observe)?; }
        }
    }
    a.finish(&mut observe)?;
    if scanned != [counts::ROWS;2] || a.flushes != 2 || a.scans != 2*counts::ROWS
        || a.coded != 10 || a.implicit != 131069 || a.history[2] != 67 || a.history[5] != 24
        || a.dense.rows.iter().any(|&r|r != [0;4]) { return Err("boundary flush/census/clear/history".into()); }
    for (t,want) in expected.iter().enumerate() { compare(&a.tiles[t],want)?; }
    let mut whole = Summary::default();
    for summary in expected {
        for c in 0..2 {
            independent_add(&mut whole.components[c],summary.components[c]);
            whole.implicit[c] += summary.implicit[c];
            for n in 0..counts::NODE_COUNT { independent_add(&mut whole.nodes[c][n],summary.nodes[c][n]); }
        }
        independent_add(&mut whole.whole,summary.whole);
    }
    compare(&a.whole,&whole)?;
    if a.finish(&mut noop).is_ok() || a.record(0,0,0,1,0,0,65536,&mut noop).is_ok() { return Err("post-finish rejection".into()); }
    Ok(a.scans)
}
fn exact_end() -> Result<usize> {
    let mut a = Accumulator::new(65536)?;
    for run in 0..65536 { for c in 0..2 { a.record(c,0,c*3,1,0,0,run,&mut noop)?; } }
    let mut rows = 0;
    a.finish(&mut |tile,index,row| {
        if tile!=0 || index!=rows || row!=[0;4] { return Err("exact-end implicit oracle".into()); }
        rows+=1; Ok(())
    })?;
    if a.flushes!=1 || rows!=counts::ROWS || a.coded!=0 || a.implicit!=131072
        || a.tiles[0].implicit!=[65536;2] || a.tiles[1].whole.count!=0 { return Err("exact-end empty extra tile".into()); }
    Ok(rows)
}
fn adversarial() -> Result<usize> {
    let mut a = Accumulator::new(1)?;
    let mut rejected = 0;
    for (c,node,class,k,h,child,run) in [(2,0,0,2,0,0,0),(0,142,0,2,0,0,0),
        (0,0,6,2,0,0,0),(0,0,3,2,0,0,0),(0,0,0,0,0,0,0),
        (0,0,0,5,0,0,0),(0,0,0,2,0,2,0),(0,0,0,1,0,1,0),
        (0,0,0,2,1024,0,0),(0,0,0,2,1,0,0),(0,0,0,2,0,0,1),(1,0,3,1,0,0,0)] {
        if a.record(c,node,class,k,h,child,run,&mut noop).is_ok()
            || a.coded!=0 || a.implicit!=0 || a.flushes!=0 || a.history!=[0;6]
            || a.dense.rows.iter().any(|&r|r!=[0;4]) { return Err("bad event rejection/state".into()); }
        rejected+=1;
    }
    if a.finish(&mut noop).is_ok() { return Err("missing runs accepted".into()); } rejected+=1;
    a.record(0,0,0,1,0,0,0,&mut noop)?;
    if a.finish(&mut noop).is_ok() { return Err("missing length accepted".into()); } rejected+=1;
    a.record(1,0,3,1,0,0,0,&mut noop)?;
    if a.record(0,0,0,1,0,0,0,&mut noop).is_ok() { return Err("component reversal accepted".into()); } rejected+=1;
    for bad in [[counts::CAP,1,0,0],[1,0,0,1]] {
        a.dense.rows[0]=bad;
        if a.finish(&mut noop).is_ok() || a.flushes!=0 || a.dense.rows[0]!=bad { return Err("malformed row rejection".into()); }
        rejected+=1; a.dense.rows[0]=[0;4];
    }
    a.finish(&mut noop)?;
    if a.flushes!=1 || a.implicit!=2 { return Err("same-process normal recovery".into()); }
    drop(a);
    let mut sequence = Accumulator::new(3)?;
    sequence.record(0,0,0,1,0,0,0,&mut noop)?;
    sequence.record(1,0,3,1,0,0,0,&mut noop)?;
    for run in [2usize,3,usize::MAX] {
        if sequence.record(0,0,0,1,0,0,run,&mut noop).is_ok() { return Err("run gap/range accepted".into()); } rejected+=1;
    }
    for run in 1..3 { for c in 0..2 { sequence.record(c,0,c*3,1,0,0,run,&mut noop)?; } }
    if sequence.record(0,0,0,1,0,0,0,&mut noop).is_ok() { return Err("run reversal accepted".into()); } rejected+=1;
    sequence.finish(&mut noop)?;
    let mut loss=tiles::Loss::default();
    for bad in [f64::NAN,f64::INFINITY,-1.0] {
        if loss.add(bad).is_ok() || loss.sum!=0.0 { return Err("loss rejection/state".into()); } rejected+=1;
    }
    loss.add(1.0)?;
    if loss.sum!=1.0 { return Err("loss recovery".into()); }
    Ok(rejected)
}
fn real_front() -> Result<(usize,usize)> {
    let mut cases=0;
    let mut rows=0;
    for plain in [&b""[..],&b"banana bandana"[..],&b"aaaaa"[..]] {
        let front=frontend::Front::new(plain)?;
        let mut a=Accumulator::new(front.runs.len())?;
        let meta=grammar::walk(&front,|c,n,class,k,h,child,run|a.record(c,n,class,k,h,child,run,&mut noop))?;
        // 実経路の有限oracleはDenseを独立全row算術で照合する。イベント再生はしない。
        let mut expected=Summary::default();
        expected.implicit=a.tiles[0].implicit;
        for c in 0..2 { for n in 0..142 { for k in 2..=4 { for h in 0..1024 {
            let index=c*436224+n*3072+(k-2)*1024+h;
            let stat=oracle(a.dense.rows[index],k);
            independent_add(&mut expected.nodes[c][n],stat);
            independent_add(&mut expected.components[c],stat);
            independent_add(&mut expected.whole,stat);
        } } } }
        // prefix1は入力eventカウントから取り出し、各componentの差で確認する。
        for c in 0..2 { expected.implicit[c]=meta.branches[c]-expected.components[c].count; }
        a.finish(&mut noop)?;
        compare(&a.whole,&expected)?;
        if meta.final_history!=a.history || meta.runs!=front.runs.len()
            || meta.branches.iter().sum::<u64>()!=a.coded+a.implicit || a.flushes!=1 { return Err("real Front Meta/history/count".into()); }
        cases+=1; rows+=a.scans;
    }
    Ok((cases,rows))
}
pub fn run() -> Result<String> {
    let boundary=synthetic_boundary()?;
    let exact=exact_end()?;
    let rejected=adversarial()?;
    let (real,real_rows)=real_front()?;
    Ok(format!("{{\"synthetic_boundary_runs\":65537,\"synthetic_boundary_events\":131079,\"boundary_all_row_child_comparisons\":{},\"exact_end_runs\":65536,\"exact_end_all_row_child_comparisons\":{},\"rejected_cases\":{rejected},\"same_process_recovery\":true,\"real_Front_cases\":{real},\"real_Front_all_row_arithmetic_checks\":{real_rows},\"real_Front_BWT_calls\":{real},\"real_Front_walks\":{real},\"full_event_trace_saved\":false}}",boundary*4,exact*4))
}
