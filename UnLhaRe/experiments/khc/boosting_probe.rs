//! 静的BWT区間coverの読み取り専用、楽観的サイズ診断。実payloadは作らない。
use std::{fs::File, io::Read, mem::size_of};
type R<T> = Result<T, String>;
const LIMIT: usize = 8 * 1024 * 1024;
const MEMORY: usize = 1024 * 1024 * 1024;
const NONE: u32 = u32::MAX;
const SPLIT: u32 = 1 << 31;
#[derive(Default)]
struct Memory {
    current: usize,
    peak: usize,
}
impl Memory {
    fn reserve<T>(&mut self, v: &mut Vec<T>, total: usize) -> R<()> {
        if total <= v.capacity() {
            return Ok(());
        }
        let wanted = total
            .checked_mul(size_of::<T>())
            .ok_or("capacity overflow")?;
        let old = v.capacity() * size_of::<T>();
        if self
            .current
            .checked_add(wanted - old)
            .ok_or("memory overflow")?
            > MEMORY
        {
            return Err("owned buffer cap".into());
        }
        v.try_reserve_exact(total - v.len())
            .map_err(|_| "allocation failed")?;
        self.current = self
            .current
            .checked_add(v.capacity() * size_of::<T>() - old)
            .ok_or("memory overflow")?;
        self.peak = self.peak.max(self.current);
        if self.current > MEMORY {
            return Err("owned buffer cap".into());
        }
        Ok(())
    }
    fn zeros<T: Default + Clone>(&mut self, n: usize) -> R<Vec<T>> {
        let mut v = Vec::new();
        self.reserve(&mut v, n)?;
        v.resize(n, T::default());
        Ok(v)
    }
    fn free<T>(&mut self, v: Vec<T>) {
        self.current -= v.capacity() * size_of::<T>();
        drop(v);
    }
    fn push<T>(&mut self, v: &mut Vec<T>, item: T) -> R<()> {
        if v.len() == v.capacity() {
            let wanted = v
                .capacity()
                .max(4)
                .checked_mul(2)
                .ok_or("length overflow")?;
            self.reserve(v, wanted)?;
        }
        v.push(item);
        Ok(())
    }
}
fn ensure(ok: bool, error: &str) -> R<()> {
    if ok { Ok(()) } else { Err(error.into()) }
}
fn add(a: u32, b: u32) -> R<u32> {
    a.checked_add(b).ok_or_else(|| "count overflow".into())
}
fn sa(text: &[u16], m: &mut Memory) -> R<Vec<u32>> {
    let n = text.len();
    let mut a = m.zeros::<u32>(n)?;
    let mut temp = m.zeros::<u32>(n)?;
    let mut rank = m.zeros::<u32>(n)?;
    let mut next = m.zeros::<u32>(n)?;
    for i in 0..n {
        a[i] = i as u32;
        rank[i] = text[i] as u32;
    }
    let mut count = m.zeros::<u32>(n.max(258) + 1)?;
    let mut classes = 257usize;
    let mut step = 1usize;
    loop {
        for second in [true, false] {
            count[..=classes].fill(0);
            let key = |p: usize| -> usize {
                if second {
                    if p + step < n {
                        rank[p + step] as usize + 1
                    } else {
                        0
                    }
                } else {
                    rank[p] as usize + 1
                }
            };
            for &p in &a {
                let k = key(p as usize);
                count[k] = add(count[k], 1)?;
            }
            let mut sum = 0;
            for c in &mut count[..=classes] {
                let old = *c;
                *c = sum;
                sum = add(sum, old)?;
            }
            ensure(sum as usize == n, "SA count total")?;
            for &p in &a {
                let k = key(p as usize);
                temp[count[k] as usize] = p;
                count[k] = add(count[k], 1)?;
            }
            std::mem::swap(&mut a, &mut temp);
        }
        let mut c = 0u32;
        next[a[0] as usize] = 0;
        for i in 1..n {
            let p = a[i - 1] as usize;
            let q = a[i] as usize;
            let second = |p: usize| if p + step < n { rank[p + step] + 1 } else { 0 };
            if rank[p] != rank[q] || second(p) != second(q) {
                c = add(c, 1)?;
            }
            next[q] = c;
        }
        std::mem::swap(&mut rank, &mut next);
        classes = c as usize + 1;
        if classes == n {
            break;
        }
        ensure(step < n, "SA failed to converge")?;
        step = step.checked_mul(2).ok_or("SA step overflow")?;
    }
    m.free(temp);
    m.free(rank);
    m.free(next);
    m.free(count);
    Ok(a)
}
#[derive(Default, Clone)]
struct Node {
    l: u32,
    r: u32,
    depth: u32,
    first: u32,
    next: u32,
    parent: u32,
    meta: u32,
    entropy: f64,
    best: f64,
}
fn node(l: u32, r: u32, depth: u32, parent: u32) -> Node {
    Node {
        l,
        r,
        depth,
        parent,
        first: NONE,
        next: NONE,
        ..Node::default()
    }
}
type Hist = Vec<(u16, u32)>;
struct Frame {
    id: u32,
    cursor: u32,
    hist: Hist,
    child_cost: f64,
}
fn uleb(mut x: u32) -> u32 {
    let mut n = 1;
    while x >= 128 {
        x >>= 7;
        n += 1;
    }
    n
}
fn cost(h: &Hist, len: u32, clamps: &mut u64) -> R<(f64, u32)> {
    ensure(!h.is_empty() && h.len() <= 257, "histogram cardinality")?;
    let mut sum = 0;
    let mut prev = None;
    let mut metadata = uleb(len) + uleb(h.len() as u32) + 4;
    let mut e = (len as f64) * (len as f64).log2();
    for (i, &(s, c)) in h.iter().enumerate() {
        ensure(
            s <= 256 && c > 0 && prev.is_none_or(|p| s > p),
            "histogram ordering",
        )?;
        sum = add(sum, c)?;
        metadata = add(metadata, uleb(prev.map_or(s, |p| s - p) as u32))?;
        if i + 1 < h.len() {
            metadata = add(metadata, uleb(c))?;
        }
        e -= (c as f64) * (c as f64).log2();
        prev = Some(s);
    }
    ensure(
        sum == len && e.is_finite() && e >= -1e-6,
        "histogram entropy/count",
    )?;
    if e < 0.0 {
        *clamps += 1;
        e = 0.0;
    }
    Ok((e, metadata))
}
fn run() -> R<()> {
    let mut args = std::env::args_os();
    args.next();
    let path = args.next().ok_or("expected one INPUT")?;
    ensure(args.next().is_none(), "expected one INPUT")?;
    let file = File::open(path).map_err(|_| "input open failed")?;
    let metadata = file.metadata().map_err(|_| "input metadata failed")?;
    ensure(
        metadata.is_file() && metadata.len() <= LIMIT as u64,
        "input must be regular file <=8 MiB",
    )?;
    let mut m = Memory::default();
    let mut input = Vec::new();
    m.reserve(&mut input, LIMIT + 1)?;
    let mut bounded = file.take((LIMIT + 1) as u64);
    let mut chunk = [0u8; 8192];
    loop {
        let amount = bounded.read(&mut chunk).map_err(|_| "input read failed")?;
        if amount == 0 {
            break;
        }
        ensure(
            input
                .len()
                .checked_add(amount)
                .is_some_and(|v| v <= LIMIT + 1),
            "bounded read overflow",
        )?;
        input.extend_from_slice(&chunk[..amount]);
    }
    ensure(input.len() <= LIMIT, "bounded input exceeded 8 MiB")?;
    let n = input.len() + 1;
    let mut text = m.zeros::<u16>(n)?;
    for i in 0..input.len() {
        text[i] = input[input.len() - 1 - i] as u16 + 1;
    }
    let a = sa(&text, &mut m)?;
    let mut rank = m.zeros::<u32>(n)?;
    let mut seen = m.zeros::<bool>(n)?;
    let mut bwt = m.zeros::<u16>(n)?;
    let mut primary = NONE;
    for (i, &p) in a.iter().enumerate() {
        let p = p as usize;
        ensure(p < n && !seen[p], "SA permutation")?;
        seen[p] = true;
        rank[p] = i as u32;
        bwt[i] = text[if p == 0 { n - 1 } else { p - 1 }];
        if p == 0 {
            primary = i as u32;
        }
    }
    ensure(
        a[0] as usize == n - 1
            && primary != NONE
            && bwt[primary as usize] == 0
            && bwt.iter().filter(|&&s| s == 0).count() == 1,
        "sentinel/primary",
    )?;
    m.free(seen);
    let mut lcp = m.zeros::<u32>(n)?;
    let mut h = 0usize;
    for p in 0..n {
        let r = rank[p] as usize;
        if r == 0 {
            h = 0;
            continue;
        }
        let q = a[r - 1] as usize;
        while p + h < n && q + h < n && text[p + h] == text[q + h] {
            h += 1;
        }
        lcp[r] = h as u32;
        h = h.saturating_sub(1);
    }
    let naive = n <= 4096;
    if naive {
        let mut reference = m.zeros::<u32>(n)?;
        for (i, p) in reference.iter_mut().enumerate() {
            *p = i as u32;
        }
        reference.sort_unstable_by(|&p, &q| text[p as usize..].cmp(&text[q as usize..]));
        ensure(reference == a, "naive SA mismatch")?;
        for i in 1..n {
            let p = a[i - 1] as usize;
            let q = a[i] as usize;
            let mut k = 0;
            while p + k < n && q + k < n && text[p + k] == text[q + k] {
                k += 1;
            }
            ensure(lcp[i] as usize == k, "naive LCP mismatch")?;
        }
        m.free(reference);
    }
    // LF逆変換を全byteへ照合する。一意sentinelにより全cycleも確認する。
    let mut counts = [0u32; 257];
    for &s in &bwt {
        counts[s as usize] = add(counts[s as usize], 1)?;
    }
    let mut starts = [0u32; 257];
    let mut sum = 0;
    for i in 0..257 {
        starts[i] = sum;
        sum = add(sum, counts[i])?;
    }
    let mut lf = m.zeros::<u32>(n)?;
    let mut used = [0u32; 257];
    for i in 0..n {
        let s = bwt[i] as usize;
        lf[i] = add(starts[s], used[s])?;
        used[s] = add(used[s], 1)?;
    }
    let mut visited = m.zeros::<bool>(n)?;
    let mut row = primary as usize;
    for pos in (0..n).rev() {
        ensure(
            row < n && !visited[row] && bwt[row] == text[pos],
            "inverse BWT",
        )?;
        visited[row] = true;
        row = lf[row] as usize;
    }
    ensure(
        row == primary as usize
            && (0..input.len()).all(|i| text[input.len() - 1 - i] == input[i] as u16 + 1),
        "inverse reverse input",
    )?;
    m.free(lf);
    m.free(visited);
    m.free(rank);
    let mut nodes = Vec::new();
    m.reserve(&mut nodes, n.checked_mul(2).ok_or("node cap overflow")?)?;
    nodes.push(node(0, n as u32, 0, NONE));
    let mut stack = Vec::new();
    m.push(&mut stack, 0u32)?;
    for i in 0..n {
        let depth = lcp[i];
        while nodes[*stack.last().ok_or("tree stack")? as usize].depth > depth {
            let id = stack.pop().ok_or("tree pop")?;
            nodes[id as usize].r = i as u32;
        }
        let mut parent = *stack.last().ok_or("tree parent")?;
        if nodes[parent as usize].depth < depth {
            let child = nodes[parent as usize].first;
            ensure(child != NONE, "LCP missing child")?;
            let id = nodes.len() as u32;
            let mut internal = node(nodes[child as usize].l, n as u32, depth, parent);
            internal.first = child;
            internal.next = nodes[child as usize].next;
            nodes[child as usize].next = NONE;
            nodes[child as usize].parent = id;
            nodes[parent as usize].first = id;
            ensure(
                nodes.len() < 2 * n && nodes.len() < nodes.capacity(),
                "node limit",
            )?;
            nodes.push(internal);
            m.push(&mut stack, id)?;
            parent = id;
        }
        let id = nodes.len() as u32;
        let mut leaf = node(i as u32, i as u32 + 1, (n - a[i] as usize) as u32, parent);
        leaf.next = nodes[parent as usize].first;
        nodes[parent as usize].first = id;
        ensure(
            nodes.len() < 2 * n && nodes.len() < nodes.capacity(),
            "node limit",
        )?;
        nodes.push(leaf);
        ensure(nodes.len() <= 2 * n, "node limit")?;
    }
    m.free(stack);
    m.free(a);
    m.free(lcp);
    m.free(text);
    for id in 0..nodes.len() {
        let p = &nodes[id];
        ensure(p.l < p.r && p.r <= n as u32, "node interval")?;
        if p.first == NONE {
            ensure(p.r - p.l == 1, "leaf width")?;
            continue;
        }
        let mut c = p.first;
        let mut end = p.r;
        let mut children = 0;
        let mut heavy = c;
        let mut previous = NONE;
        let mut heavy_previous = NONE;
        let mut maxlen = 0;
        while c != NONE {
            let child = &nodes[c as usize];
            ensure(
                child.parent == id as u32
                    && child.depth > p.depth
                    && child.r == end
                    && child.l >= p.l,
                "parent/child coverage/depth",
            )?;
            end = child.l;
            children += 1;
            if child.r - child.l > maxlen {
                maxlen = child.r - child.l;
                heavy = c;
                heavy_previous = previous;
            }
            previous = c;
            c = child.next;
        }
        ensure(
            end == p.l && (id == 0 || children >= 2),
            "root/child complete coverage",
        )?;
        // 最大子を先に処理して、未merge頻度表の同時保有を減らす。
        if heavy_previous != NONE {
            let old = nodes[id].first;
            nodes[heavy_previous as usize].next = nodes[heavy as usize].next;
            nodes[heavy as usize].next = old;
            nodes[id].first = heavy;
        }
    }
    let mut frames = Vec::new();
    m.push(
        &mut frames,
        Frame {
            id: 0,
            cursor: nodes[0].first,
            hist: Vec::new(),
            child_cost: 0.0,
        },
    )?;
    let mut merges = 0u64;
    let mut processed = 0u64;
    let mut clamps = 0u64;
    let mut whole = 0.0;
    while !frames.is_empty() {
        let frame = frames.last_mut().ok_or("DP frame")?;
        if frame.cursor != NONE {
            let child = frame.cursor;
            frame.cursor = nodes[child as usize].next;
            m.push(
                &mut frames,
                Frame {
                    id: child,
                    cursor: nodes[child as usize].first,
                    hist: Vec::new(),
                    child_cost: 0.0,
                },
            )?;
            continue;
        }
        let mut f = frames.pop().ok_or("DP pop")?;
        let id = f.id as usize;
        let len = nodes[id].r - nodes[id].l;
        if nodes[id].first == NONE {
            m.push(&mut f.hist, (bwt[nodes[id].l as usize], 1))?;
        }
        processed = processed
            .checked_add(f.hist.len() as u64)
            .ok_or("hist entry overflow")?;
        let (entropy, meta) = cost(&f.hist, len, &mut clamps)?;
        let own = entropy + 8.0 * meta as f64;
        ensure(
            own.is_finite() && f.child_cost.is_finite() && own >= 0.0 && f.child_cost >= 0.0,
            "finite DP",
        )?;
        nodes[id].entropy = entropy;
        nodes[id].meta = meta;
        nodes[id].best = if nodes[id].first != NONE && f.child_cost < own {
            nodes[id].meta |= SPLIT;
            f.child_cost
        } else {
            own
        };
        if id == 0 {
            whole = own;
            m.free(f.hist);
            break;
        }
        let parent = frames.last_mut().ok_or("DP missing parent")?;
        ensure(nodes[id].parent == parent.id, "DP parent")?;
        parent.child_cost += nodes[id].best;
        if parent.hist.len() < f.hist.len() {
            std::mem::swap(&mut parent.hist, &mut f.hist);
        }
        for (s, c) in f.hist.iter().copied() {
            merges = merges.checked_add(1).ok_or("merge overflow")?;
            match parent.hist.binary_search_by_key(&s, |&(s, _)| s) {
                Ok(i) => parent.hist[i].1 = add(parent.hist[i].1, c)?,
                Err(i) => {
                    let wanted = parent.hist.len() + 1;
                    m.reserve(&mut parent.hist, wanted)?;
                    parent.hist.insert(i, (s, c));
                }
            }
        }
        m.free(f.hist);
    }
    m.free(frames);
    m.free(bwt);
    let mut selected = Vec::new();
    let mut visit = Vec::new();
    m.push(&mut visit, 0u32)?;
    while let Some(id) = visit.pop() {
        let p = &nodes[id as usize];
        if p.meta & SPLIT == 0 {
            m.push(&mut selected, id)?;
        } else {
            let mut child = p.first;
            while child != NONE {
                m.push(&mut visit, child)?;
                child = nodes[child as usize].next;
            }
        }
    }
    m.free(visit);
    selected.sort_unstable_by_key(|&id| nodes[id as usize].l);
    let mut end = 0;
    let mut payload = 0.0;
    let mut metadata = 0u64;
    let mut digest = 0xcbf29ce484222325u64;
    let mut minlen = u32::MAX;
    let mut maxlen = 0;
    for &id in &selected {
        let p = &nodes[id as usize];
        ensure(p.l == end && p.meta & SPLIT == 0, "selected cover coverage")?;
        end = p.r;
        payload += p.entropy;
        metadata = metadata
            .checked_add(p.meta as u64)
            .ok_or("metadata overflow")?;
        let len = p.r - p.l;
        minlen = minlen.min(len);
        maxlen = maxlen.max(len);
        for value in [p.l, p.r, p.depth, p.meta] {
            for byte in value.to_le_bytes() {
                digest = (digest ^ byte as u64).wrapping_mul(0x100000001b3);
            }
        }
    }
    ensure(
        end == n as u32
            && payload.is_finite()
            && (payload + 8.0 * metadata as f64 - nodes[0].best).abs() <= 1e-6,
        "DP/global cost conservation",
    )?;
    let total = 36.0 + payload / 8.0 + metadata as f64;
    let whole = 36.0 + whole / 8.0;
    println!(
        "{{\"kind\":\"bwt_static_interval_cover_ideal_size_diagnostic\",\"input_bytes\":{},\"bwt_symbols\":{},\"primary\":{},\"sa_nodes\":{},\"selected_segment_count\":{},\"ideal_payload_bits\":{:.12},\"metadata_bytes\":{},\"header_bytes\":36,\"ideal_total_frame_bytes\":{:.12},\"whole_bwt_ideal_frame_bytes\":{:.12},\"threshold\":483599,\"estimated_threshold_passed\":{},\"histogram_merge_entries\":{},\"histogram_nonzero_entries_processed\":{},\"max_owned_buffer_bytes\":{},\"entropy_negative_clamps\":{},\"actual_coder_termination_quantization_bytes\":0,\"input_dependent_segment_tables_charged\":true,\"segment_summary\":{{\"min_symbols\":{},\"max_symbols\":{},\"fnv1a64_interval_depth_metadata\":\"{:016x}\"}},\"checks\":{{\"bounded_regular_input\":true,\"sa_permutation\":true,\"sentinel_primary\":true,\"inverse_bwt_reverse_full_input\":true,\"naive_sa_lcp_performed\":{},\"naive_sa_lcp\":{},\"tree_depth_interval_coverage\":true,\"histogram_count_entropy_metadata\":true,\"selected_sorted_full_coverage\":true,\"dp_global_cost_conservation\":true,\"owned_capacity_cap\":true}}}}",
        input.len(),
        n,
        primary,
        nodes.len(),
        selected.len(),
        payload,
        metadata,
        total,
        whole,
        total <= 483599.0,
        merges,
        processed,
        m.peak,
        clamps,
        minlen,
        maxlen,
        digest,
        naive,
        if naive { "true" } else { "null" }
    );
    Ok(())
}
fn main() {
    if let Err(e) = run() {
        eprintln!("rejected: {e}");
        std::process::exit(1);
    }
}
