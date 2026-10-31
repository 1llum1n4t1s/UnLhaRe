//! 単一ブロック実験。登録storage入口専用。
#![allow(dead_code, unused_imports)]
#[path = "../root-history-order/bundle.rs"]
mod bundle;
#[path = "../causal-bayes-sais/bwt.rs"]
mod bwt;
#[path = "../paid-code-tree/codebook.rs"]
mod codebook;
#[path = "../node-history-information/counts.rs"]
mod counts;
#[path = "../static-direct-mdl/frontend.rs"]
mod frontend;
#[path = "../node-history-information/grammar.rs"]
mod grammar;
#[path = "../static-direct-mdl/histogram.rs"]
mod histogram;
#[path = "../root-history-order/model.rs"]
mod model;
mod packet;
#[path = "../paid-code-tree/model.rs"]
mod paid_model;
#[path = "../../../src/khc/block/multi_range.rs"]
mod range;
#[path = "../packed-inverse/reference.rs"]
mod reference;
use std::{fs::File, io::Read};
type Result<T> = std::result::Result<T, String>;
const MAX: usize = 1 << 20;
const FRAME_MAX: usize = 8 << 20;
const HEADER: usize = 40;
const MAGIC: &[u8; 8] = b"ACSF\x15\x10\x26\0";
const TOTAL: u32 = 32768;
fn need(ok: bool, why: &str) -> Result<()> {
    if ok { Ok(()) } else { Err(why.into()) }
}
fn bytes(n: usize) -> Result<Vec<u8>> {
    reference::filled(n, 0)
}
fn field(b: &[u8], p: usize) -> usize {
    u32::from_le_bytes(b[p..p + 4].try_into().unwrap()) as usize
}
fn put(b: &mut [u8], p: usize, n: usize) -> Result<()> {
    b[p..p + 4].copy_from_slice(&u32::try_from(n).map_err(|_| "u32 field")?.to_le_bytes());
    Ok(())
}
fn crc(data: &[u8]) -> u32 {
    let mut c = !0u32;
    for &b in data {
        c ^= u32::from(b);
        for _ in 0..8 {
            c = (c >> 1) ^ (0xedb88320 & 0u32.wrapping_sub(c & 1));
        }
    }
    !c
}
fn sha(data: &[u8]) -> String {
    const K: [u32; 64] = [
        0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5, 0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
        0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da, 0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
        0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85, 0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
        0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3, 0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
    ];
    let mut h = [0x6a09e667u32, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19];
    let blocks = (data.len() + 9).div_ceil(64);
    for block in 0..blocks {
        let mut chunk = [0u8; 64];
        for (i, b) in chunk.iter_mut().enumerate() {
            let p = block * 64 + i;
            *b = if p < data.len() {
                data[p]
            } else if p == data.len() {
                128
            } else {
                0
            };
        }
        if block + 1 == blocks {
            chunk[56..].copy_from_slice(&(data.len() as u64 * 8).to_be_bytes());
        }
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes(chunk[i * 4..i * 4 + 4].try_into().unwrap());
        }
        for i in 16..64 {
            let a = w[i - 15].rotate_right(7) ^ w[i - 15].rotate_right(18) ^ (w[i - 15] >> 3);
            let b = w[i - 2].rotate_right(17) ^ w[i - 2].rotate_right(19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16].wrapping_add(a).wrapping_add(w[i - 7]).wrapping_add(b);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut q] = h;
        for i in 0..64 {
            let s = e.rotate_right(6) ^ e.rotate_right(11) ^ e.rotate_right(25);
            let t = q.wrapping_add(s).wrapping_add((e & f) ^ (!e & g)).wrapping_add(K[i]).wrapping_add(w[i]);
            let u = (a.rotate_right(2) ^ a.rotate_right(13) ^ a.rotate_right(22)).wrapping_add((a & b) ^ (a & c) ^ (b & c));
            q = g;
            g = f;
            f = e;
            e = d.wrapping_add(t);
            d = c;
            c = b;
            b = a;
            a = t.wrapping_add(u);
        }
        for (v, x) in h.iter_mut().zip([a, b, c, d, e, f, g, q]) {
            *v = v.wrapping_add(x);
        }
    }
    h.iter().map(|x| format!("{x:08x}")).collect()
}
#[derive(Default)]
struct Budget {
    model: usize,
    phase: usize,
}
impl Budget {
    fn observe(&mut self, model: usize, phase: usize) -> Result<()> {
        self.model = self.model.max(model);
        self.phase = self.phase.max(phase);
        need(model <= 32 << 20 && phase <= 64 << 20, "model capacity")
    }
}
fn metadata(front: &frontend::Front, retained: usize, budget: &mut Budget) -> Result<Vec<u8>> {
    let mut dense = counts::Dense::new()?;
    grammar::walk(front, |c, n, _, k, h, child| {
        if k > 1 {
            dense.record(c, n, k, h, child)?;
        }
        Ok(())
    })?;
    codebook::validate_fixed()?;
    let book = codebook::Encoder::new(codebook::LENGTHS)?;
    let mut packet = packet::Packet::new(&book)?;
    for c in 0..2 {
        for n in 0..142 {
            let mut low = model::Hist::new()?;
            let mut high = model::Hist::new()?;
            for k in 2..=4 {
                for h in 0..1024u16 {
                    let row = dense.row(c, n, k, h)?;
                    bundle::ingest(&mut low, k, h, row)?;
                    bundle::ingest(&mut high, k, model::reverse_history(h), row)?;
                }
            }
            let l = paid_model::Fit::build(&low)?;
            let r = paid_model::Fit::build_high(&high)?;
            let selected = paid_model::Selected::new(&l, &r)?;
            let m = dense.capacity_bytes()
                + packet::MAX_BUNDLE_BYTES
                + book.capacity_bytes()
                + low.capacity_bytes()
                + high.capacity_bytes()
                + l.capacity_bytes()
                + r.capacity_bytes()
                + paid_model::MAX_BYTES
                + 16384;
            budget.observe(m, retained + m)?;
            for k in 2..=4 {
                packet.append_root(&selected, k)?;
            }
        }
    }
    packet.finish()
}
fn forest(data: &[u8]) -> Result<packet::Forest> {
    let (table, _, _) = codebook::read_header(data, packet::MAX_BUNDLE_BITS)?;
    need(table == codebook::LENGTHS, "model table")?;
    packet::Forest::parse(data)
}
fn cdf(f: [u16; 4], k: usize) -> Result<()> {
    need((2..=4).contains(&k) && f[..k].iter().all(|&x| x >= 2) && f[k..].iter().all(|&x| x == 0) && f[..k].iter().map(|&x| u32::from(x)).sum::<u32>() == TOTAL, "CDF support/total/tail")
}
fn initial_meta() -> grammar::Meta {
    grammar::Meta { grammar: 0xcbf29ce484222325, ..grammar::Meta::default() }
}
fn token(
    c: usize,
    limit: usize,
    known: Option<usize>,
    tree: &grammar::Tree,
    forest: &packet::Forest,
    meta: &mut grammar::Meta,
    enc: &mut Option<&mut range::Encoder>,
    dec: &mut Option<&mut range::Decoder<'_>>,
) -> Result<usize> {
    let mut n = 0;
    loop {
        let k = tree.prefix(n, limit)?;
        let class = c * 3 + tree.class(n)?;
        let h = meta.final_history[class];
        let f = if k == 1 {
            [0; 4]
        } else {
            let f = forest.lookup(c, n, k, h)?;
            cdf(f, k)?;
            f
        };
        let mut rs=None;
        let child = if let Some(t) = known {
            tree.known_child(n, t, limit)?
        } else if k == 1 {
            0
        } else {
            let slot = dec.as_mut().ok_or("missing decoder")?.slot(TOTAL)?;
            let mut sum = 0;
            let mut found = None;
            for (i, &v) in f[..k].iter().enumerate() {
                sum += u32::from(v);
                if slot.value() < sum {
                    found = Some(i);
                    break;
                }
            }
            rs=Some(slot);
            found.ok_or("CDF slot")?
        };
        if k > 1 {
            let start = f[..child].iter().map(|&x| u32::from(x)).sum();
            if let Some(e) = enc.as_mut() {
                e.interval(start, u32::from(f[child]), TOTAL)?;
            }
            if let Some(d) = dec.as_mut() {
                d.consume(rs.ok_or("range slot")?,start,u32::from(f[child]),TOTAL)?;
            }
        }
        meta.branches[c] += 1;
        meta.classes[class] += 1;
        meta.prefixes[class][k - 1] += 1;
        meta.final_history[class] = ((h << 2) | child as u16) & 1023;
        let edge = tree.edge(n, child, k)?;
        if let Some(next) = edge.node {
            n = next;
        } else {
            need(edge.lo < limit && known.is_none_or(|v| v == edge.lo), "terminal token")?;
            return Ok(edge.lo);
        }
    }
}
fn token_meta(meta: &mut grammar::Meta, c: usize, key: usize, t: usize, limit: usize) {
    for v in [c, key, t, limit] {
        meta.grammar = (meta.grammar ^ v as u64).wrapping_mul(0x100000001b3);
    }
    meta.tokens[c] += 1;
    meta.history_checks += 1;
}
fn escape_encode(mut v: usize, e: &mut range::Encoder, meta: &mut grammar::Meta) -> Result<()> {
    loop {
        let b = (v & 127) | if v >= 128 { 128 } else { 0 };
        v >>= 7;
        e.interval(b as u32, 1, 256)?;
        meta.escapes += 1;
        if v == 0 {
            return Ok(());
        }
    }
}
fn escape_decode(d: &mut range::Decoder<'_>, meta: &mut grammar::Meta) -> Result<usize> {
    let mut v = 0;
    for i in 0..3 {
        let s=d.slot(256)?;let b=s.value() as usize;d.consume(s,b as u32,1,256)?;
        meta.escapes += 1;
        v |= (b & 127) << (i * 7);
        if b < 128 {
            need(i == 0 || b != 0, "nonminimal escape")?;
            return Ok(v);
        }
    }
    Err("overlong escape".into())
}
fn payload(front: &frontend::Front, f: &packet::Forest, limit: usize) -> Result<(Vec<u8>, grammar::Meta)> {
    let trees = [grammar::Tree::new(257), grammar::Tree::new(256)];
    let mut e = range::Encoder::with_limit(limit)?;
    let mut meta = initial_meta();
    front.walk(|c, s, x, _, t, l, old| {
        token(c, l, Some(t), &trees[c], f, &mut meta, &mut Some(&mut e), &mut None)?;
        token_meta(&mut meta, c, if c == 0 { s * 4 + old.min(3) } else { s * 9 + x }, t, l);
        if c == 1 {
            let length = front.runs[meta.runs].length as usize;
            if length >= 256 {
                escape_encode(length - 256, &mut e, &mut meta)?;
            }
            meta.runs += 1;
        }
        Ok(())
    })?;
    let expected = grammar::walk(front, |_, _, _, _, _, _| Ok(()))?;
    need(meta == expected, "encoded whole Meta")?;
    Ok((e.finish()?, meta))
}
struct Candidate {
    frame: Vec<u8>,
    meta: grammar::Meta,
    budget: Budget,
}
fn candidate(plain: &[u8], retained: usize) -> Result<Candidate> {
    need(plain.len() <= MAX, "input limit")?;
    let mut budget = Budget::default();
    budget.observe(0, retained + plain.len() + 48 * (plain.len() + 1) + 131072)?;
    let front = frontend::Front::new(plain)?;
    let front_bytes = front.runs.capacity() * std::mem::size_of::<frontend::Run>();
    let data = metadata(&front, retained + plain.len() + front_bytes, &mut budget)?;
    let mut order = Vec::new();
    order.try_reserve_exact(257).map_err(|_| "order allocation")?;
    let mut seen = [false; 257];
    for r in &front.runs {
        let s = r.symbol as usize;
        if !seen[s] {
            order.push(s as u16);
            seen[s] = true;
        }
    }
    let f = forest(&data)?;
    let fixed = HEADER + order.len() * 2 + data.len();
    need(fixed + 5 <= FRAME_MAX, "frame fixed extent")?;
    let (coded, meta) = payload(&front, &f, FRAME_MAX - fixed)?;
    let phase = retained + plain.len() + front_bytes + data.capacity() + f.capacity_bytes() + coded.capacity() + fixed + coded.len() + 16384;
    budget.observe(f.capacity_bytes() + data.capacity() + f.parse_dispatch_peak + f.parse_reader_capacity + 16384, phase)?;
    let mut out = bytes(fixed + coded.len())?;
    header(&mut out, 1, plain, front.primary, order.len(), data.len(), coded.len())?;
    for (i, &s) in order.iter().enumerate() {
        out[HEADER + i * 2..HEADER + i * 2 + 2].copy_from_slice(&s.to_le_bytes());
    }
    let start = HEADER + order.len() * 2;
    out[start..start + data.len()].copy_from_slice(&data);
    out[start + data.len()..].copy_from_slice(&coded);
    Ok(Candidate { frame: out, meta, budget })
}
fn header(out: &mut [u8], mode: u8, plain: &[u8], primary: usize, alphabet: usize, models: usize, payload: usize) -> Result<()> {
    out[..8].copy_from_slice(MAGIC);
    out[8] = 1;
    out[9] = mode;
    let extent = out.len();
    put(out, 12, extent)?;
    put(out, 16, plain.len())?;
    put(out, 20, crc(plain) as usize)?;
    put(out, 24, primary)?;
    out[28..30].copy_from_slice(&(alphabet as u16).to_le_bytes());
    put(out, 32, models)?;
    put(out, 36, payload)
}
fn stored(plain: &[u8]) -> Result<Vec<u8>> {
    need(plain.len() <= MAX, "input limit")?;
    let mut out = bytes(HEADER + plain.len())?;
    header(&mut out, 0, plain, 0, 0, 0, plain.len())?;
    out[HEADER..].copy_from_slice(plain);
    Ok(out)
}
fn use_range(range_len: usize, plain_len: usize) -> bool {
    range_len < HEADER + plain_len
}
fn select(plain: &[u8], candidate: &[u8]) -> Result<Vec<u8>> {
    if use_range(candidate.len(), plain.len()) { Ok(candidate.to_vec()) } else { stored(plain) }
}
fn order_parse(raw: &[u8]) -> Result<Vec<u16>> {
    need(!raw.is_empty() && raw.len() <= 514 && raw.len() % 2 == 0, "alphabet extent")?;
    let mut order = Vec::new();
    order.try_reserve_exact(raw.len() / 2).map_err(|_| "alphabet allocation")?;
    let mut seen = [false; 257];
    for pair in raw.chunks_exact(2) {
        let s = u16::from_le_bytes(pair.try_into().unwrap()) as usize;
        need(s <= 256 && !seen[s], "alphabet symbol")?;
        seen[s] = true;
        order.push(s as u16);
    }
    need(seen[0], "alphabet sentinel")?;
    Ok(order)
}
fn restore(coded: &[u8], f: &packet::Forest, mut queue: Vec<u16>, n: usize, primary: usize) -> Result<(Vec<u8>, grammar::Meta)> {
    need(n <= MAX && primary <= n, "inverse bound")?;
    let alphabet = queue.clone();
    let mut d = range::Decoder::new(coded)?;
    let mut meta = initial_meta();
    let trees = [grammar::Tree::new(257), grammar::Tree::new(256)];
    let mut old_rank = [0usize; 257];
    let mut last = reference::filled(n + 1, 0u16)?;
    let mut runs = Vec::new();
    runs.try_reserve_exact(n + 1).map_err(|_| "inverse runs allocation")?;
    let mut consumed = 0;
    let mut previous = None;
    while consumed < n + 1 {
        let active = queue.len();
        let s = *queue.first().ok_or("empty next-use queue")? as usize;
        need(previous != Some(s), "adjacent repeated run")?;
        previous = Some(s);
        let rank = token(0, active, None, &trees[0], f, &mut meta, &mut None, &mut Some(&mut d))?;
        token_meta(&mut meta, 0, s * 4 + old_rank[s].min(3), rank, active);
        let remaining = n + 1 - consumed;
        let limit = remaining.min(256);
        let t = token(1, limit, None, &trees[1], f, &mut meta, &mut None, &mut Some(&mut d))?;
        token_meta(&mut meta, 1, s * 9 + histogram::exponent(rank + 1), t, limit);
        let length = if t == 255 { 256usize.checked_add(escape_decode(&mut d, &mut meta)?).ok_or("escape overflow")? } else { t + 1 };
        need(length <= remaining, "run exceeds remaining")?;
        last[consumed..consumed + length].fill(s as u16);
        consumed += length;
        runs.push(frontend::Run { symbol: s as u32, length: length as u32, next: u32::MAX });
        meta.runs += 1;
        queue.remove(0);
        if rank != 0 {
            need(rank <= queue.len(), "next-use rank")?;
            queue.insert(rank, s as u16);
        }
        old_rank[s] = rank;
    }
    need(queue.is_empty(), "unretired alphabet")?;
    d.finish()?;
    let mut next = [u32::MAX; 257];
    for i in (0..runs.len()).rev() {
        let s = runs[i].symbol as usize;
        runs[i].next = next[s];
        next[s] = i as u32;
    }
    let front = frontend::Front { runs, primary, last_len: n + 1 };
    let expected = grammar::walk(&front, |_, _, _, _, _, _| Ok(()))?;
    need(meta == expected, "decoded Meta")?;
    let out = reference::inverse_bwt(&last, primary, &alphabet)?;
    Ok((out, meta))
}
fn decode(frame: &[u8], output_limit: usize) -> Result<(Vec<u8>, Option<grammar::Meta>)> {
    need(frame.len() >= HEADER && frame.len() <= FRAME_MAX, "frame extent")?;
    need(&frame[..8] == MAGIC && frame[8] == 1, "magic/version")?;
    need(frame[9] <= 1 && frame[10..12] == [0, 0] && frame[30..32] == [0, 0], "mode/reserved")?;
    let n = field(frame, 16);
    let primary = field(frame, 24);
    let a = u16::from_le_bytes(frame[28..30].try_into().unwrap()) as usize;
    let m = field(frame, 32);
    let p = field(frame, 36);
    need(n <= MAX && n <= output_limit && a <= 257 && m <= packet::MAX_BUNDLE_BYTES, "output/model limit")?;
    let extent = HEADER.checked_add(a * 2).and_then(|x| x.checked_add(m)).and_then(|x| x.checked_add(p)).ok_or("frame length overflow")?;
    need(field(frame, 12) == frame.len() && extent == frame.len(), "frame length")?;
    let (plain, meta) = if frame[9] == 0 {
        need(primary == 0 && a == 0 && m == 0 && p == n, "stored shape")?;
        (frame[HEADER..].to_vec(), None)
    } else {
        need(primary <= n && a != 0 && m >= codebook::PREFIX && p >= 5, "range shape")?;
        let order = order_parse(&frame[HEADER..HEADER + a * 2])?;
        let start = HEADER + a * 2;
        let f = forest(&frame[start..start + m])?;
        need(frame.len() + f.capacity_bytes() + f.parse_dispatch_peak + f.parse_reader_capacity + 28 * (n + 1) + 32768 <= 64 << 20, "decode phase budget")?;
        let (out, meta) = restore(&frame[start + m..], &f, order, n, primary)?;
        (out, Some(meta))
    };
    need(crc(&plain) as usize == field(frame, 20), "plain CRC32")?;
    Ok((plain, meta))
}
fn equal(frame: &[u8], plain: &[u8]) -> Result<()> {
    let (out, _) = decode(frame, MAX)?;
    need(out == plain && sha(&out) == sha(plain), "restore mismatch")
}
fn reject(bad: &[u8], good: &[u8], plain: &[u8], count: &mut usize) -> Result<()> {
    need(decode(bad, MAX).is_err(), "malformed accepted")?;
    equal(good, plain)?;
    *count += 1;
    Ok(())
}
fn bad_field(good: &[u8], plain: &[u8], at: usize, value: usize, count: &mut usize) -> Result<()> {
    let mut bad = good.to_vec();
    put(&mut bad, at, value)?;
    reject(&bad, good, plain, count)
}
fn malformed(good: &[u8], plain: &[u8]) -> Result<usize> {
    let mut count = 0;
    for n in [0, 1, HEADER - 1, HEADER, good.len() - 1] {
        reject(&good[..n], good, plain, &mut count)?;
    }
    for (p, v) in [(0, 0), (8, 2), (9, 2), (10, 1), (30, 1)] {
        let mut bad = good.to_vec();
        bad[p] = v;
        reject(&bad, good, plain, &mut count)?;
    }
    for (p, v) in [(12, usize::MAX >> 32), (16, MAX + 1), (20, field(good, 20) ^ 1), (24, plain.len() + 1), (32, packet::MAX_BUNDLE_BYTES + 1), (36, 0)] {
        bad_field(good, plain, p, v, &mut count)?;
    }
    let mut bad = good.to_vec();
    bad.push(0);
    reject(&bad, good, plain, &mut count)?;
    let a = u16::from_le_bytes(good[28..30].try_into().unwrap()) as usize;
    let start = HEADER + a * 2;
    let end = start + field(good, 32);
    let mut bad = good.to_vec();
    bad[HEADER..HEADER + 2].copy_from_slice(&257u16.to_le_bytes());
    reject(&bad, good, plain, &mut count)?;
    if a > 1 {
        let mut bad = good.to_vec();
        bad[HEADER + 2..HEADER + 4].copy_from_slice(&good[HEADER..HEADER + 2]);
        reject(&bad, good, plain, &mut count)?;
    }
    for (pos, xor) in [(start, 255), (start + 1, 128), (start + 5, 255), (end, 1), (good.len() - 1, 1)] {
        let mut bad = good.to_vec();
        bad[pos] ^= xor;
        reject(&bad, good, plain, &mut count)?;
    }
    let mut bad = good.to_vec();
    bad.pop();
    let len = bad.len();
    put(&mut bad, 12, len)?;
    put(&mut bad, 36, field(good, 36) - 1)?;
    reject(&bad, good, plain, &mut count)?;
    let mut bad = good.to_vec();
    bad.push(0);
    let len = bad.len();
    put(&mut bad, 12, len)?;
    put(&mut bad, 36, field(good, 36) + 1)?;
    reject(&bad, good, plain, &mut count)?;
    if !plain.is_empty() {
        need(decode(good, plain.len() - 1).is_err(), "caller output limit")?;
        equal(good, plain)?;
        count += 1;
    }
    let mut raw = stored(plain)?;
    raw[20] ^= 1;
    reject(&raw, good, plain, &mut count)?;
    Ok(count)
}
fn primitive_failures() -> Result<()> {
    need(crc(b"123456789") == 0xcbf43926, "CRC known vector")?;
    for (input, digest) in [(&b""[..], "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"), (&b"abc"[..], "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")] {
        need(sha(input) == digest, "SHA known vector")?;
    }
    need(!use_range(HEADER + 256, 256) && use_range(HEADER + 255, 256), "stored equality boundary")?;
    for (f, k) in [([0, 32768, 0, 0], 2), ([2, 2, 0, 0], 2), ([16384, 16384, 2, 0], 2)] {
        need(cdf(f, k).is_err(), "bad CDF accepted")?;
    }
    need(order_parse(&[0, 0, 0, 0]).is_err() && order_parse(&[1, 0]).is_err(), "bad alphabet accepted")?;
    need(reference::inverse_bwt(&[0, 1, 1], 0, &[0, 1]).is_err(), "LF cycle")?;
    need(reference::inverse_bwt(&[1, 0], 0, &[0, 1]).is_err(), "sentinel")?;
    let tree = grammar::Tree::new(257);
    need(tree.known_child(0, 1, 1).is_err() && tree.prefix(0, 0).is_err(), "token prefix accepted")?;
    let mut e = range::Encoder::with_limit(32)?;
    need(e.interval(0, 0, 2).is_err() && e.interval(u32::MAX, 2, 2).is_err(), "bad interval")?;
    for bytes in [&[128u8, 0][..], &[128, 128, 128][..]] {
        let mut e = range::Encoder::with_limit(32)?;
        for &b in bytes {
            e.interval(u32::from(b), 1, 256)?;
        }
        let data = e.finish()?;
        let mut d = range::Decoder::new(&data)?;
        need(escape_decode(&mut d, &mut initial_meta()).is_err(), "bad escape accepted")?;
    }
    Ok(())
}
fn run() -> Result<()> {
    primitive_failures()?;
    let args: Vec<String> = std::env::args().collect();
    need(args.len() == 3 && args[2].len() == 64 && args[2].bytes().all(|b| b.is_ascii_hexdigit()), "usage: frame_e2e fixed-source expected-sha256")?;
    let file = File::open(&args[1]).map_err(|e| format!("fixed source: {e}"))?;
    let n = file.metadata().map_err(|e| e.to_string())?.len();
    need(n > 0 && n <= MAX as u64, "fixed source 1..1MiB")?;
    let mut fixed = Vec::new();
    fixed.try_reserve_exact(n as usize).map_err(|_| "fixed allocation")?;
    file.take(MAX as u64 + 1).read_to_end(&mut fixed).map_err(|e| e.to_string())?;
    need(fixed.len() == n as usize && fixed.capacity() <= MAX && sha(&fixed) == args[2].to_ascii_lowercase(), "fixed source")?;
    let mut classes = [0u64; 6];
    let mut prefixes = [0u64; 4];
    let mut rejects = 0;
    println!("{{\"format\":\"ACSF-1\",\"complete_frame\":true,\"measured_performance\":false,\"borrowed_overhead_bytes\":0,\"cases\":[");
    for i in 0..9 {
        let mut seed = 0x6d2b79f5u32;
        let plain = match i {
            0 => Vec::new(),
            1 => vec![165],
            2 => (0..=255u8).collect(),
            3 => vec![7; 65536],
            4 => (0..16384)
                .map(|_| {
                    seed ^= seed << 13;
                    seed ^= seed >> 17;
                    seed ^= seed << 5;
                    seed as u8
                })
                .collect(),
            5 => vec![19; 255],
            6 => vec![19; 256],
            7 => vec![19; 257],
            _ => std::mem::take(&mut fixed),
        };
        let retained = fixed.capacity();
        let c = candidate(&plain, retained)?;
        let (out, meta) = decode(&c.frame, MAX)?;
        need(out == plain && sha(&out) == sha(&plain) && meta.as_ref() == Some(&c.meta), "candidate mismatch")?;
        drop(out);
        drop(meta);
        let again = candidate(&plain, retained + c.frame.capacity())?;
        need(c.frame == again.frame, "frame determinism")?;
        let phase_peak = c.budget.phase.max(again.budget.phase);
        drop(again);
        let selected = select(&plain, &c.frame)?;
        equal(&selected, &plain)?;
        need(selected.len() <= HEADER + plain.len() && (selected[9] == 1) == use_range(c.frame.len(), plain.len()), "stored selection")?;
        if i <= 2 {
            need(selected[9] == 0, "small input stored")?;
        }
        if i == 3 {
            need(selected[9] == 1, "repeated range selected")?;
            rejects += malformed(&c.frame, &plain)?;
        }
        for j in 0..6 {
            classes[j] += c.meta.classes[j];
            for k in 0..4 {
                prefixes[k] += c.meta.prefixes[j][k];
            }
        }
        let a = u16::from_le_bytes(c.frame[28..30].try_into().unwrap()) as usize;
        need(HEADER + a * 2 + field(&c.frame, 32) + field(&c.frame, 36) == c.frame.len(), "full charged accounting")?;
        println!(
            "{}{{\"case\":{},\"input\":{},\"input_sha256\":\"{}\",\"candidate_sha256\":\"{}\",\"header\":40,\"initial_order\":{},\"model\":{},\"range_payload_with_termination\":{},\"candidate_total\":{},\"stored_total\":{},\"selected_total\":{},\"selected_mode\":{},\"runs\":{},\"escape_bytes\":{},\"model_capacity_bound\":{},\"phase_capacity_bound\":{}}}",
            if i == 0 { "" } else { "," },
            i,
            plain.len(),
            sha(&plain),
            sha(&c.frame),
            a * 2,
            field(&c.frame, 32),
            field(&c.frame, 36),
            c.frame.len(),
            HEADER + plain.len(),
            selected.len(),
            selected[9],
            c.meta.runs,
            c.meta.escapes,
            c.budget.model,
            phase_peak
        );
    }
    need(classes.iter().all(|&x| x > 0) && prefixes.iter().all(|&x| x > 0), "class coverage")?;
    println!(
        "],\"rejections\":{rejects},\"same_process_recoveries\":{rejects},\"byte_and_sha_verified\":true,\"whole_meta_verified\":true,\"scratch_static_bound\":32768,\"os_highwater_measured_by_native\":false}}"
    );
    Ok(())
}
fn main() {
    if let Err(e) = run() {
        eprintln!("frame E2E failed: {e}");
        std::process::exit(1);
    }
}
