//! 固定有料minor長を目的へ入れた木選択。数値処理は凍結実装を参照する。
use super::{
    codebook::{self, Decoder, Encoder, Reader, Writer},
    model as original,
};
pub use original::{
    GROUPS, HISTORIES, Hist, MAX_BITS, MAX_BYTES, MINOR_LUT, NODES, compact_frequency, floor_code,
    leaf_mode, quantize,
};
type Result<T> = std::result::Result<T, String>;
fn allocated<T: Clone>(len: usize, value: T) -> Result<Vec<T>> {
    let mut v = Vec::new();
    v.try_reserve_exact(len)
        .map_err(|_| "paid model allocation")?;
    v.resize(len, value);
    Ok(v)
}
fn group(class: usize, k: usize) -> Result<usize> {
    if class != 0 || !(2..=4).contains(&k) {
        return Err("model class/prefix".into());
    }
    Ok(k - 2)
}
fn valid_frequency(f: [u16; 4], k: usize) -> Result<()> {
    if !(2..=4).contains(&k)
        || f[..k].iter().any(|&v| v < 2)
        || f[k..].iter().any(|&v| v != 0)
        || f[..k].iter().map(|&v| u32::from(v)).sum::<u32>() != 32768
    {
        return Err("CDF support/total/tail".into());
    }
    Ok(())
}
fn leaf_bits(f: [u16; 4], k: usize) -> Result<usize> {
    let (mode, dominant) = leaf_mode(f, k)?;
    let width = if k == 2 { 1 } else { 2 };
    match mode {
        0 => Ok(3),
        1 => Ok(3 + width),
        2 => {
            let mut bits = 2 + width;
            for (i, &frequency) in f.iter().enumerate().take(k) {
                if i != dominant {
                    bits += codebook::fee(floor_code(frequency)?);
                }
            }
            Ok(bits)
        }
        _ => Err("leaf mode".into()),
    }
}
#[derive(Clone, Copy, Default)]
struct Node {
    frequency: [u16; 4],
    split: bool,
    loss: f64,
    bits: usize,
}
fn leaf(counts: [u32; 4], frequency: [u16; 4], k: usize, depth: usize) -> Result<Node> {
    valid_frequency(frequency, k)?;
    let mut loss = 0.0;
    for i in 0..k {
        if counts[i] != 0 {
            loss += f64::from(counts[i]) * (32768.0 / f64::from(frequency[i])).log2();
        }
    }
    if !loss.is_finite() || loss < 0.0 {
        return Err("fit leaf loss".into());
    }
    Ok(Node {
        frequency,
        split: false,
        loss,
        bits: if depth == 0 && frequency == uniform(k)? {
            0
        } else {
            leaf_bits(frequency, k)?
        },
    })
}
pub struct Fit {
    nodes: Vec<Node>,
    high: bool,
}
impl Fit {
    pub fn build(hist: &Hist) -> Result<Self> {
        Self::build_order(hist, false)
    }
    pub fn build_high(hist: &Hist) -> Result<Self> {
        Self::build_order(hist, true)
    }
    fn build_order(hist: &Hist, high: bool) -> Result<Self> {
        if hist.counts.len() != GROUPS * NODES || std::mem::size_of::<Node>() > 32 {
            return Err("fit shape/node extent".into());
        }
        let mut fit = Self {
            nodes: allocated(GROUPS * NODES, Node::default())?,
            high,
        };
        for g in 0..GROUPS {
            fit.build_node(hist, g, 0, 0, g % 3 + 2)?;
        }
        Ok(fit)
    }
    fn build_node(
        &mut self,
        hist: &Hist,
        g: usize,
        id: usize,
        depth: usize,
        k: usize,
    ) -> Result<()> {
        if id >= NODES || depth > 5 {
            return Err("fit node/depth".into());
        }
        let counts = hist.counts[g * NODES + id];
        if counts == [0; 4] {
            // 空親だけでは子を信用しない。全子孫を確認してから非分割leafで終える。
            Self::check_empty_branch(hist, g, id, depth)?;
            self.nodes[g * NODES + id] = leaf(counts, uniform(k)?, k, depth)?;
            return Ok(());
        }
        let frequency = compact_frequency(quantize(counts, k)?, k)?;
        let mut best = leaf(counts, frequency, k, depth)?;
        if counts[..k].iter().any(|&v| v != 0) {
            let mut dominant = 0;
            for i in 1..k {
                if counts[i] > counts[dominant] {
                    dominant = i;
                }
            }
            let mut pure = [0u16; 4];
            pure[..k].fill(2);
            pure[dominant] = 32768 - 2 * (k as u16 - 1);
            for candidate in [uniform(k)?, pure] {
                if candidate == best.frequency {
                    continue;
                }
                let next = leaf(counts, candidate, k, depth)?;
                if next.loss + (next.bits as f64) < best.loss + (best.bits as f64) {
                    best = next;
                }
            }
        }
        if depth < 5 {
            let mut sums = [0u64; 4];
            let mut split_loss = 0.0;
            let mut split_bits = if depth == 0 { 2usize } else { 1usize };
            for digit in 0..4 {
                let child = 4 * id + 1 + digit;
                for (sum, &count) in sums.iter_mut().zip(&hist.counts[g * NODES + child]) {
                    *sum = sum
                        .checked_add(u64::from(count))
                        .ok_or("hist child sum overflow")?;
                }
                self.build_node(hist, g, child, depth + 1, k)?;
                let n = self.nodes[g * NODES + child];
                split_loss += n.loss;
                split_bits = split_bits
                    .checked_add(n.bits)
                    .ok_or("fit bit count overflow")?;
            }
            if sums != counts.map(u64::from) {
                return Err("hist parent/children mismatch".into());
            }
            if split_loss + (split_bits as f64) < best.loss + (best.bits as f64) {
                best.split = true;
                best.loss = split_loss;
                best.bits = split_bits;
            }
        }
        self.nodes[g * NODES + id] = best;
        Ok(())
    }
    fn check_empty_branch(hist: &Hist, g: usize, id: usize, depth: usize) -> Result<()> {
        if id >= NODES || depth > 5 {
            return Err("fit node/depth".into());
        }
        if hist.counts[g * NODES + id] != [0; 4] {
            return Err("hist parent/children mismatch".into());
        }
        if depth < 5 {
            for digit in 0..4 {
                Self::check_empty_branch(hist, g, 4 * id + 1 + digit, depth + 1)?;
            }
        }
        Ok(())
    }
    pub fn lookup(&self, class: usize, k: usize, history: u16) -> Result<[u16; 4]> {
        let g = group(class, k)?;
        let history = if self.high {
            reverse_history(history)
        } else {
            history
        };
        let mut id = 0;
        for depth in 0..=5 {
            let node = self.nodes.get(g * NODES + id).ok_or("fit lookup node")?;
            if !node.split {
                return Ok(node.frequency);
            }
            if depth == 5 {
                return Err("fit split beyond depth".into());
            }
            id = 4 * id + 1 + ((history >> (2 * depth)) & 3) as usize;
        }
        Err("fit lookup terminal".into())
    }

    pub fn capacity_bytes(&self) -> usize {
        self.nodes.capacity() * std::mem::size_of::<Node>() + std::mem::size_of::<Self>()
    }

    fn write_node(
        &self,
        g: usize,
        id: usize,
        depth: usize,
        k: usize,
        w: &mut Writer,
        book: &Encoder,
    ) -> Result<()> {
        let n = self.nodes[g * NODES + id];
        w.write(u32::from(n.split), 1)?;
        if n.split {
            if depth == 0 {
                w.write(u32::from(self.high), 1)?;
            }
            if depth >= 5 {
                return Err("serialize split depth".into());
            }
            for d in 0..4 {
                self.write_node(g, 4 * id + 1 + d, depth + 1, k, w, book)?;
            }
        } else {
            valid_frequency(n.frequency, k)?;
            let (mode, dominant) = leaf_mode(n.frequency, k)?;
            match mode {
                0 => w.write(3, 2)?,
                1 => w.write(2, 2)?,
                2 => w.write(0, 1)?,
                _ => return Err("serialize mode".into()),
            }
            match mode {
                0 => (),
                1 => w.write(dominant as u32, if k == 2 { 1 } else { 2 })?,
                2 => {
                    w.write(dominant as u32, if k == 2 { 1 } else { 2 })?;
                    for i in 0..k {
                        if i != dominant {
                            let code = floor_code(n.frequency[i])?;
                            if MINOR_LUT[usize::from(code)] != n.frequency[i] {
                                return Err("compact writer off-grid".into());
                            }
                            book.write(code, w)?;
                        }
                    }
                }
                _ => return Err("serialize reserved mode".into()),
            }
        }
        Ok(())
    }
}
// 短いleaf root拡張：Hist/quantizeを保持し、DP費用0とoracle wire3bitを区別。
pub fn uniform(k: usize) -> Result<[u16; 4]> {
    quantize([0; 4], k)
}
impl Fit {
    pub fn root_loss(&self, k: usize) -> Result<f64> {
        Ok(self.nodes[group(0, k)? * NODES].loss)
    }
    pub fn root_default(&self, k: usize) -> Result<bool> {
        let n = self.nodes[group(0, k)? * NODES];
        Ok(!n.split && n.frequency == uniform(k)?)
    }
    pub fn root_wire(&self, k: usize, book: &Encoder) -> Result<(Vec<u8>, usize)> {
        let g = group(0, k)?;
        let objective = self.nodes[g * NODES].bits;
        let bits = if objective == 0 { 3 } else { objective };
        if bits == 0 || bits > MAX_BITS {
            return Err("root bit bound".into());
        }
        let mut w = Writer::new(bits)?;
        self.write_node(g, 0, 0, k, &mut w, book)?;
        if w.position != bits || w.bytes.capacity() > MAX_BYTES {
            return Err("root writer extent".into());
        }
        Ok((w.bytes, bits))
    }
}

impl Fit {
    pub fn root_objective_bits(&self, k: usize) -> Result<usize> {
        Ok(self.nodes[group(0, k)? * NODES].bits)
    }
}

// 固定5digit反転。grammar履歴やDense indexは変更しない。
pub fn reverse_history(history: u16) -> u16 {
    let mut result = 0;
    for d in 0..5 {
        result |= ((history >> (2 * d)) & 3) << (2 * (4 - d));
    }
    result
}

pub struct Selected<'a> {
    low: &'a Fit,
    high: &'a Fit,
    high_roots: [bool; 3],
}
impl<'a> Selected<'a> {
    pub fn new(low: &'a Fit, high: &'a Fit) -> Result<Self> {
        if low.high || !high.high {
            return Err("selection low/high identity".into());
        }
        let mut high_roots = [false; 3];
        for k in 2..=4 {
            let low_cost = low.root_loss(k)? + low.root_objective_bits(k)? as f64;
            let high_cost = high.root_loss(k)? + high.root_objective_bits(k)? as f64;
            high_roots[k - 2] = high_cost < low_cost;
        }
        Ok(Self {
            low,
            high,
            high_roots,
        })
    }
    // ablationは選択のみ低固定。wire/decoderは同じ、high Fitの構築を省く。
    pub fn low_only(low: &'a Fit) -> Result<Self> {
        if low.high {
            return Err("selection low identity".into());
        }
        Ok(Self {
            low,
            high: low,
            high_roots: [false; 3],
        })
    }
    fn chosen(&self, k: usize) -> Result<&Fit> {
        let g = group(0, k)?;
        Ok(if self.high_roots[g] {
            self.high
        } else {
            self.low
        })
    }

    pub fn root_default(&self, k: usize) -> Result<bool> {
        self.chosen(k)?.root_default(k)
    }
    pub fn root_objective_bits(&self, k: usize) -> Result<usize> {
        self.chosen(k)?.root_objective_bits(k)
    }
    pub fn root_wire(&self, k: usize, book: &Encoder) -> Result<(Vec<u8>, usize)> {
        self.chosen(k)?.root_wire(k, book)
    }
    pub fn lookup(&self, class: usize, k: usize, history: u16) -> Result<[u16; 4]> {
        self.chosen(k)?.lookup(class, k, history)
    }
}

pub struct Dispatch {
    frequencies: Vec<[u16; 4]>,
}
impl Dispatch {
    pub fn lookup(&self, class: usize, k: usize, h: u16) -> Result<[u16; 4]> {
        let g = group(class, k)?;
        self.frequencies
            .get(g * HISTORIES + (h as usize & 1023))
            .copied()
            .ok_or("dispatch range".into())
    }
    pub fn capacity_bytes(&self) -> usize {
        std::mem::size_of::<Self>() + self.frequencies.capacity() * std::mem::size_of::<[u16; 4]>()
    }
}
fn parse_node(
    r: &mut Reader<'_>,
    frequencies: &mut [[u16; 4]],
    depth: usize,
    path: usize,
    k: usize,
    book: &Decoder,
) -> Result<()> {
    if r.read(1)? == 1 {
        if depth >= 5 {
            return Err("paid split beyond depth5".into());
        }
        let high = depth == 0 && r.read(1)? == 1;
        for digit in 0..4 {
            parse_node(
                r,
                frequencies,
                depth + 1,
                path | (digit << (2 * depth)),
                k,
                book,
            )?;
        }
        if high {
            for h in 0..HISTORIES {
                let reversed = usize::from(reverse_history(h as u16));
                if h < reversed {
                    frequencies.swap(h, reversed);
                }
            }
        }
    } else {
        let mode = if r.read(1)? == 0 {
            2
        } else if r.read(1)? == 0 {
            1
        } else {
            0
        };
        let mut f = [0u16; 4];
        match mode {
            0 => f = uniform(k)?,
            1 => {
                let dominant = r.read(if k == 2 { 1 } else { 2 })? as usize;
                if dominant >= k {
                    return Err("pure dominant index".into());
                }
                f[..k].fill(2);
                f[dominant] = 32768 - 2 * (k as u16 - 1);
            }
            _ => {
                let dominant = r.read(if k == 2 { 1 } else { 2 })? as usize;
                if dominant >= k {
                    return Err("compact dominant index".into());
                }
                let mut used = 0u32;
                for (i, frequency) in f.iter_mut().enumerate().take(k) {
                    if i != dominant {
                        *frequency = MINOR_LUT[usize::from(book.read(r)?)];
                        used = used
                            .checked_add(u32::from(*frequency))
                            .ok_or("compact minor sum")?;
                    }
                }
                f[dominant] = u16::try_from(
                    32768u32
                        .checked_sub(used)
                        .ok_or("compact residual underflow")?,
                )
                .map_err(|_| "compact residual range")?;
                if f[dominant] < 2 || f[..k].iter().any(|&v| v > f[dominant]) {
                    return Err("compact residual largest/minimum".into());
                }
            }
        }
        valid_frequency(f, k)?;
        // 対応する履歴だけを訪ねる。全分割木でもrootあたり1024代入。
        for h in (path..HISTORIES).step_by(1usize << (2 * depth)) {
            let slot = &mut frequencies[h];
            if *slot != [0; 4] {
                return Err("parsed duplicate dispatch".into());
            }
            *slot = f;
        }
    }
    Ok(())
}
pub fn parse_root(bytes: &[u8], bits: usize, k: usize, book: &Decoder) -> Result<Dispatch> {
    let g = group(0, k)?;
    if bits == 0 || bits > MAX_BITS || bytes.len() != bits.div_ceil(8) || bytes.len() > MAX_BYTES {
        return Err("root exact extent".into());
    }
    if !bits.is_multiple_of(8)
        && bytes.last().copied().ok_or("root empty")? & ((1u8 << (8 - bits % 8)) - 1) != 0
    {
        return Err("root padding".into());
    }
    let mut r = Reader {
        bytes,
        bits,
        position: 0,
    };
    let mut d = Dispatch {
        frequencies: allocated(GROUPS * HISTORIES, [0; 4])?,
    };
    parse_node(
        &mut r,
        &mut d.frequencies[g * HISTORIES..(g + 1) * HISTORIES],
        0,
        0,
        k,
        book,
    )?;
    if r.position != bits {
        return Err("root trailing bits".into());
    }
    Ok(d)
}
pub fn parse_packet_node_into(
    r: &mut Reader<'_>,
    book: &Decoder,
    frequencies: &mut [[u16; 4]],
) -> Result<usize> {
    if frequencies.len() != GROUPS * HISTORIES {
        return Err("packet dispatch extent".into());
    }
    let mut defaults = 0;
    for k in 2..=4 {
        let g = k - 2;
        if r.read(1)? == 0 {
            let frequency = uniform(k)?;
            frequencies[g * HISTORIES..(g + 1) * HISTORIES].fill(frequency);
            defaults += 1;
        } else {
            parse_node(
                r,
                &mut frequencies[g * HISTORIES..(g + 1) * HISTORIES],
                0,
                0,
                k,
                book,
            )?;
        }
    }
    Ok(defaults)
}

// LOG PROBE BEGIN
pub(crate) fn probe_coefficients(k: usize, pure: bool, dominant: usize) -> Result<[u64; 4]> {
    let mut frequency = uniform(k)?;
    if pure {
        frequency[..k].fill(2);
        frequency[dominant] = 32768 - 2 * (k as u16 - 1);
    }
    let mut result = [0u64; 4];
    for i in 0..k {
        result[i] = (32768.0 / f64::from(frequency[i])).log2().to_bits();
    }
    Ok(result)
}
pub(crate) fn probe_leaf(
    counts: [u32; 4],
    frequency: [u16; 4],
    k: usize,
    depth: usize,
) -> Result<([u16; 4], bool, u64, usize)> {
    let node = leaf(counts, frequency, k, depth)?;
    Ok((node.frequency, node.split, node.loss.to_bits(), node.bits))
}
pub(crate) fn probe_fit(
    rows: &[[u32; 4]],
    high: bool,
) -> Result<Vec<([u16; 4], bool, u64, usize)>> {
    let hist = Hist {
        counts: rows.to_vec(),
    };
    let fit = if high {
        Fit::build_high(&hist)?
    } else {
        Fit::build(&hist)?
    };
    Ok(fit
        .nodes
        .iter()
        .map(|n| (n.frequency, n.split, n.loss.to_bits(), n.bits))
        .collect())
}
pub(crate) fn probe_cost_capacity() -> usize {
    0
}
// LOG PROBE END
