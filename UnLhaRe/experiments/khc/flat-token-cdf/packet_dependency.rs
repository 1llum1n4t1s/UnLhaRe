//! 実canonical global metadata。tableは常に134B支払う。
use super::{
    codebook::{self, Decoder, Encoder},
    grammar, paid_model as model,
};
type Result<T> = std::result::Result<T, String>;

pub const MODELS: usize = 284;
pub const ROOTS: usize = 852;
pub const MAX_BUNDLE_BITS: usize = MODELS * model::MAX_BITS + ROOTS;
pub const MAX_BUNDLE_BYTES: usize = codebook::PREFIX + MAX_BUNDLE_BITS.div_ceil(8);

const ROWS: usize = 2 * 142 * 3 * 1024;
pub struct Packet<'a> {
    bytes: Vec<u8>,
    book: &'a Encoder,
    pub bits: usize,
    pub roots: usize,
    pub defaults: usize,
    pub checked_bits: usize,
    pub objective_bits: usize,
}
impl<'a> Packet<'a> {
    pub fn new(book: &'a Encoder) -> Result<Self> {
        if book.lengths != codebook::LENGTHS {
            return Err("packet fixed table identity".into());
        }
        let mut bytes = Vec::new();
        bytes
            .try_reserve_exact(MAX_BUNDLE_BYTES)
            .map_err(|_| "global packet allocation")?;
        if bytes.capacity() > MAX_BUNDLE_BYTES {
            return Err("global packet capacity".into());
        }
        bytes.resize(MAX_BUNDLE_BYTES, 0);
        bytes[0] = 1;
        for (i, &n) in book.lengths.iter().enumerate() {
            bytes[5 + i / 2] |= n << if i % 2 == 0 { 4 } else { 0 };
        }
        Ok(Self {
            bytes,
            book,
            bits: 0,
            roots: 0,
            defaults: 0,
            checked_bits: 0,
            objective_bits: 0,
        })
    }
    pub fn write(&mut self, value: u32, width: usize) -> Result<()> {
        if width > 31
            || value >= 1u32 << width
            || self
                .bits
                .checked_add(width)
                .ok_or("global writer overflow")?
                > MAX_BUNDLE_BITS
        {
            return Err("global writer range".into());
        }
        for s in (0..width).rev() {
            if value & (1 << s) != 0 {
                self.bytes[codebook::PREFIX + self.bits / 8] |= 1 << (7 - self.bits % 8);
            }
            self.bits += 1;
        }
        Ok(())
    }
    pub fn append_root(&mut self, fit: &model::Selected<'_>, k: usize) -> Result<()> {
        if self.roots >= ROOTS {
            return Err("global extra root".into());
        }
        let default = fit.root_default(k)?;
        let objective = fit.root_objective_bits(k)?;
        if default != (objective == 0) {
            return Err("global root default/objective".into());
        }
        self.write(u32::from(!default), 1)?;
        self.roots += 1;
        self.defaults += usize::from(default);
        self.objective_bits += objective;
        if default {
            return Ok(());
        }
        let (local, bits) = fit.root_wire(k, self.book)?;
        if bits != objective {
            return Err("global root wire/objective".into());
        }
        let start = self.bits;
        for i in 0..bits {
            self.write(u32::from((local[i / 8] >> (7 - i % 8)) & 1), 1)?;
        }
        for i in 0..bits {
            if (self.bytes[codebook::PREFIX + (start + i) / 8] >> (7 - (start + i) % 8)) & 1
                != (local[i / 8] >> (7 - i % 8)) & 1
            {
                return Err("global root concatenation bit mismatch".into());
            }
        }
        self.checked_bits += bits;
        Ok(())
    }
    pub fn finish(mut self) -> Result<Vec<u8>> {
        if self.roots != ROOTS || self.bits != self.objective_bits + ROOTS {
            return Err("global actual DP bits plus root flags".into());
        }
        self.bytes[1..5].copy_from_slice(
            &u32::try_from(self.bits)
                .map_err(|_| "global field")?
                .to_le_bytes(),
        );
        self.bytes
            .truncate(codebook::PREFIX + self.bits.div_ceil(8));
        Ok(self.bytes)
    }
}
pub struct Reader<'a> {
    reader: codebook::Reader<'a>,
    book: Decoder,
    pub bits: usize,
    models: usize,
    pub defaults: usize,
}
impl<'a> Reader<'a> {
    pub fn new(bytes: &'a [u8]) -> Result<Self> {
        let (lengths, bits, payload) = codebook::read_header(bytes, MAX_BUNDLE_BITS)?;
        if bits < ROOTS {
            return Err("global root bit minimum".into());
        }
        let book = Decoder::new(lengths)?;
        Ok(Self {
            reader: codebook::Reader {
                bytes: payload,
                bits,
                position: 0,
            },
            book,
            bits,
            models: 0,
            defaults: 0,
        })
    }
    pub fn next_into(&mut self, frequencies: &mut [[u16; 4]]) -> Result<[u16; 3]> {
        if self.models >= MODELS {
            return Err("global extra model".into());
        }
        let (defaults, dependencies) =
            model::parse_packet_node_into(&mut self.reader, &self.book, frequencies)?;
        self.models += 1;
        self.defaults += defaults;
        Ok(dependencies)
    }
    pub fn finish(&self) -> Result<()> {
        if self.models != MODELS || self.reader.position != self.bits {
            return Err("global model count/trailing bits".into());
        }
        Ok(())
    }
    pub fn codec_capacity_bytes(&self) -> usize {
        self.book.capacity_bytes() + std::mem::size_of::<codebook::Reader<'_>>()
    }
}
#[derive(Clone, Copy)]
struct Descriptor {
    frequency: [u16; 4],
    offset: u32,
}
pub struct Forest {
    descriptors: [Descriptor; ROOTS],
    dependencies: [u16; ROOTS],
    frequencies: Vec<[u16; 4]>,
    pub parse_dispatch_peak: usize,
    pub parse_reader_capacity: usize,
}
impl Forest {
    pub fn parse(bytes: &[u8]) -> Result<Self> {
        let mut reader = Reader::new(bytes)?;
        let mut descriptors = [Descriptor {
            frequency: [0; 4],
            offset: u32::MAX,
        }; ROOTS];
        let mut dependencies = [0u16; ROOTS];
        let mut frequencies = Vec::new();
        let mut scratch = [[0u16; 4]; 3 * 1024];
        let mut old_capacity_peak = 0usize;
        let mut models = 0;
        let parse_reader_capacity =
            reader.codec_capacity_bytes() + std::mem::size_of::<Reader<'_>>();
        for c in 0..2 {
            let tree = grammar::Tree::new(if c == 0 { 257 } else { 256 });
            if tree.node_count() != 142 {
                return Err("Forest grammar nodes".into());
            }
            for node in 0..142 {
                if tree.class(node)? > 2 {
                    return Err("Forest class range".into());
                }
                models += 1;
                // 非defaultのparse_nodeはzero初期状態からの重複書込み検査を行う。
                scratch.fill([0; 4]);
                let model_dependencies = reader.next_into(&mut scratch)?;
                for group in 0..3 {
                    let rows = &scratch[group * 1024..(group + 1) * 1024];
                    let first = rows[0];
                    let descriptor = &mut descriptors[(c * 142 + node) * 3 + group];
                    if rows.iter().all(|&row| row == first) {
                        descriptor.frequency = first;
                        dependencies[(c * 142 + node) * 3 + group] = 0;
                    } else {
                        dependencies[(c * 142 + node) * 3 + group] = model_dependencies[group];
                        let required = frequencies
                            .len()
                            .checked_add(1024)
                            .ok_or("Forest length overflow")?;
                        if required > ROWS {
                            return Err("Forest row bound".into());
                        }
                        if required > frequencies.capacity() {
                            old_capacity_peak = old_capacity_peak.max(frequencies.capacity());
                            let target = required
                                .max(frequencies.capacity().saturating_mul(2))
                                .min(ROWS);
                            frequencies
                                .try_reserve_exact(target - frequencies.len())
                                .map_err(|_| "Forest allocation")?;
                            if frequencies.capacity() > ROWS {
                                return Err("Forest capacity bound".into());
                            }
                        }
                        descriptor.offset =
                            u32::try_from(frequencies.len()).map_err(|_| "Forest offset")?;
                        frequencies.extend_from_slice(rows);
                        if descriptor.offset as usize + 1024 != frequencies.len() {
                            return Err("Forest offset extent".into());
                        }
                    }
                }
            }
        }
        if models != MODELS {
            return Err("Forest selected node count".into());
        }
        reader.finish()?;
        Ok(Self {
            descriptors,
            dependencies,
            frequencies,
            parse_dispatch_peak: std::mem::size_of_val(&scratch)
                + old_capacity_peak * std::mem::size_of::<[u16; 4]>(),
            parse_reader_capacity,
        })
    }
    pub fn lookup(&self, c: usize, node: usize, k: usize, history: u16) -> Result<[u16; 4]> {
        if c >= 2 || node >= 142 || !(2..=4).contains(&k) {
            return Err("Forest component/node/prefix".into());
        }
        let descriptor = &self.descriptors[(c * 142 + node) * 3 + k - 2];
        if descriptor.offset == u32::MAX {
            Ok(descriptor.frequency)
        } else {
            self.frequencies
                .get(descriptor.offset as usize + (history as usize & 1023))
                .copied()
                .ok_or("Forest index".into())
        }
    }
    pub fn capacity_bytes(&self) -> usize {
        self.frequencies.capacity() * std::mem::size_of::<[u16; 4]>() + std::mem::size_of::<Self>()
    }
}

pub(crate) struct Cdf<'a> {
    ends: &'a [u16; 4],
    k: usize,
}
impl Cdf<'_> {
    pub(crate) fn choose(&self, slot: u32) -> Result<(usize, u32, u32)> {
        let mut cumulative = 0;
        for (child, &end) in self.ends.iter().enumerate().take(self.k) {
            let end = u32::from(end);
            if slot < end {
                return Ok((child, cumulative, end - cumulative));
            }
            cumulative = end;
        }
        Err("range CDF child".into())
    }
}
pub(crate) struct DecodeForest {
    inner: Forest,
}
fn cumulative(row: &mut [u16; 4], k: usize) -> Result<()> {
    if !(2..=4).contains(&k)
        || row[..k].iter().any(|&f| f < 2)
        || row[k..].iter().any(|&f| f != 0)
        || row.iter().map(|&f| u32::from(f)).sum::<u32>() != 32768
    {
        return Err("wire CDF support/total/tail".into());
    }
    let mut sum = 0u32;
    for value in &mut row[..k] {
        sum += u32::from(*value);
        *value = sum as u16;
    }
    Ok(())
}
impl Forest {
    pub(crate) fn into_decode(mut self) -> Result<DecodeForest> {
        let mut consumed = 0usize;
        for (i, descriptor) in self.descriptors.iter_mut().enumerate() {
            let k = i % 3 + 2;
            if descriptor.offset == u32::MAX {
                cumulative(&mut descriptor.frequency, k)?;
            } else {
                let offset = descriptor.offset as usize;
                if offset != consumed {
                    return Err("compiled CDF offset order".into());
                }
                let rows = self
                    .frequencies
                    .get_mut(offset..offset + 1024)
                    .ok_or("compiled CDF extent")?;
                for row in rows {
                    cumulative(row, k)?;
                }
                consumed += 1024;
            }
        }
        if consumed != self.frequencies.len() {
            return Err("compiled CDF unused rows".into());
        }
        Ok(DecodeForest { inner: self })
    }
}
impl DecodeForest {
    pub(crate) fn cdf(&self, c: usize, node: usize, k: usize, history: u16) -> Result<Cdf<'_>> {
        if c >= 2 || node >= 142 || !(2..=4).contains(&k) {
            return Err("Forest component/node/prefix".into());
        }
        let d = &self.inner.descriptors[(c * 142 + node) * 3 + k - 2];
        let ends = if d.offset == u32::MAX {
            &d.frequency
        } else {
            self.inner
                .frequencies
                .get(d.offset as usize + (history as usize & 1023))
                .ok_or("Forest index")?
        };
        Ok(Cdf { ends, k })
    }
    pub(crate) fn capacity_bytes(&self) -> usize {
        self.inner.capacity_bytes()
    }
    pub(crate) fn parse_transient(&self) -> usize {
        self.inner.parse_dispatch_peak + self.inner.parse_reader_capacity
    }
}
pub type MaskTable = [[[u16; 3]; 258]; 2];
impl DecodeForest {
    pub fn sufficient_masks(&self) -> Result<MaskTable> {
        let mut table = [[[0u16; 3]; 258]; 2];
        for c in 0..2 {
            let alphabet = if c == 0 { 257 } else { 256 };
            let tree = grammar::Tree::new(alphabet);
            for node in 0..142 {
                let all = tree.prefix(node, alphabet)?;
                let lo = tree.edge(node, 0, all)?.lo;
                let class = tree.class(node)?;
                for n in 1..=alphabet {
                    if lo >= n {
                        continue;
                    }
                    let k = tree.prefix(node, n)?;
                    if k >= 2 {
                        table[c][n][class] |= self.inner.dependencies[(c * 142 + node) * 3 + k - 2];
                    }
                }
            }
            for n in 1..=alphabet {
                let middle = table[c][n][1];
                table[c][n][1] |= middle >> 2;
                let deep = table[c][n][2];
                table[c][n][2] |= (deep >> 2) | (deep >> 4) | (deep >> 6) | (deep >> 8);
            }
        }
        Ok(table)
    }
    /// censusだけの検証費用。mask生成にdense行の追加探索は使わない。
    pub fn validate_dependencies(&self) -> Result<usize> {
        let mut checks = 0;
        for (i, d) in self.inner.descriptors.iter().enumerate() {
            let mask = self.inner.dependencies[i];
            if mask > 1023 {
                return Err("dependency bits".into());
            }
            if d.offset == u32::MAX {
                if mask != 0 {
                    return Err("constant dependency".into());
                }
                continue;
            }
            let rows = &self.inner.frequencies[d.offset as usize..d.offset as usize + 1024];
            for h in 0..1024 {
                if rows[h] != rows[h & usize::from(mask)] {
                    return Err("sufficient mask/CDF mismatch".into());
                }
                checks += 1;
            }
        }
        Ok(checks)
    }
}
