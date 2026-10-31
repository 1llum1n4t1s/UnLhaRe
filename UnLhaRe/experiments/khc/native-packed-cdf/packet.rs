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
        bytes.try_reserve_exact(MAX_BUNDLE_BYTES).map_err(|_| "global packet allocation")?;
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
        if width > 31 || value >= 1u32 << width || self.bits.checked_add(width).ok_or("global writer overflow")? > MAX_BUNDLE_BITS {
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
            if (self.bytes[codebook::PREFIX + (start + i) / 8] >> (7 - (start + i) % 8)) & 1 != (local[i / 8] >> (7 - i % 8)) & 1 {
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
        self.bytes[1..5].copy_from_slice(&u32::try_from(self.bits).map_err(|_| "global field")?.to_le_bytes());
        self.bytes.truncate(codebook::PREFIX + self.bits.div_ceil(8));
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
    pub fn next_into(&mut self, frequencies: &mut [[u16; 4]]) -> Result<()> {
        if self.models >= MODELS {
            return Err("global extra model".into());
        }
        let defaults = model::parse_packet_node_into(&mut self.reader, &self.book, frequencies)?;
        self.models += 1;
        self.defaults += defaults;
        Ok(())
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
        let mut frequencies = Vec::new();
        let mut scratch = [[0u16; 4]; 3 * 1024];
        let mut old_capacity_peak = 0usize;
        let mut models = 0;
        let parse_reader_capacity = reader.codec_capacity_bytes() + std::mem::size_of::<Reader<'_>>();
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
                reader.next_into(&mut scratch)?;
                for group in 0..3 {
                    let rows = &scratch[group * 1024..(group + 1) * 1024];
                    let first = rows[0];
                    let descriptor = &mut descriptors[(c * 142 + node) * 3 + group];
                    if rows.iter().all(|&row| row == first) {
                        descriptor.frequency = first;
                    } else {
                        let required = frequencies.len().checked_add(1024).ok_or("Forest length overflow")?;
                        if required > ROWS {
                            return Err("Forest row bound".into());
                        }
                        if required > frequencies.capacity() {
                            old_capacity_peak = old_capacity_peak.max(frequencies.capacity());
                            let target = required.max(frequencies.capacity().saturating_mul(2)).min(ROWS);
                            frequencies.try_reserve_exact(target - frequencies.len()).map_err(|_| "Forest allocation")?;
                            if frequencies.capacity() > ROWS {
                                return Err("Forest capacity bound".into());
                            }
                        }
                        descriptor.offset = u32::try_from(frequencies.len()).map_err(|_| "Forest offset")?;
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
            frequencies,
            parse_dispatch_peak: std::mem::size_of_val(&scratch) + old_capacity_peak * std::mem::size_of::<[u16; 4]>(),
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
    word: &'a u64,
    k: usize,
}
impl Cdf<'_> {
    pub(crate) fn choose(&self, slot: u32) -> Result<(usize, u32, u32)> {
        // guardより前にslotを複製すると、16bit lane間のborrow証明が成立しない。
        if slot >= 32768 || !(2..=4).contains(&self.k) {
            return Err("range CDF child".into());
        }
        let word = *self.word;
        let active = 0x8000_8000_8000_8000u64 >> ((4 - self.k) * 16);
        // 全laneは32768以上、slotは32767以下なのでlane間のborrowはない。
        let matches = (word - u64::from(slot) * 0x0001_0001_0001_0001) & active;
        if matches == 0 {
            return Err("range CDF child".into());
        }
        let child = (matches.trailing_zeros() >> 4) as usize;
        let end = ((word >> (child * 16)) & 0x7fff) as u32 + 1;
        let cumulative = if child == 0 { 0 } else { ((word >> ((child - 1) * 16)) & 0x7fff) as u32 + 1 };
        Ok((child, cumulative, end - cumulative))
    }
}
#[derive(Clone, Copy)]
struct DecodeDescriptor {
    word: u64,
    offset: u32,
}
pub(crate) struct DecodeForest {
    descriptors: [DecodeDescriptor; ROOTS],
    words: Vec<u64>,
    construction_peak: usize,
}
const MODEL_BOUND: usize = 16 * 1024 * 1024;
// Vec manager/descriptorの重複と、変換ループ内の参照・scalar・row temporaryを支払う。
const CONVERSION_MANAGERS: usize = std::mem::size_of::<Forest>()
    + 2 * std::mem::size_of::<DecodeForest>()
    + std::mem::size_of::<Descriptor>()
    + std::mem::size_of::<DecodeDescriptor>()
    + std::mem::size_of::<[u16; 4]>()
    + 32 * std::mem::size_of::<usize>();
fn packed(row: &[u16; 4], k: usize) -> Result<u64> {
    if !(2..=4).contains(&k) || row[..k].iter().any(|&f| f < 2) || row[k..].iter().any(|&f| f != 0) || row.iter().map(|&f| u32::from(f)).sum::<u32>() != 32768 {
        return Err("wire CDF support/total/tail".into());
    }
    let mut word = 0x8000_8000_8000_8000u64;
    let mut sum = 0u32;
    for (child, &frequency) in row[..k].iter().enumerate() {
        sum += u32::from(frequency);
        word |= u64::from(sum - 1) << (child * 16);
    }
    Ok(word)
}
// 有限診断もdecodeと同じsupport検査・packing・slot guardを通す。
pub(crate) fn diagnostic_choose(row: [u16; 4], k: usize, slot: u32) -> Result<(usize, u32, u32)> {
    let word = packed(&row, k)?;
    Cdf { word: &word, k }.choose(slot)
}
impl Forest {
    pub(crate) fn into_decode(self) -> Result<DecodeForest> {
        if self.frequencies.capacity() > ROWS {
            return Err("Forest capacity bound".into());
        }
        let raw_bytes = self.frequencies.capacity() * std::mem::size_of::<[u16; 4]>();
        let word_bytes = self.frequencies.len() * std::mem::size_of::<u64>();
        let conversion_reserved = raw_bytes
            .checked_add(word_bytes)
            .and_then(|n| n.checked_add(CONVERSION_MANAGERS))
            .ok_or("compiled CDF capacity overflow")?;
        let parse_peak = self
            .capacity_bytes()
            .checked_add(std::mem::size_of::<Forest>())
            .and_then(|n| n.checked_add(self.parse_dispatch_peak))
            .and_then(|n| n.checked_add(self.parse_reader_capacity))
            .ok_or("compiled CDF parse capacity overflow")?;
        if conversion_reserved > MODEL_BOUND || parse_peak > MODEL_BOUND {
            return Err("compiled CDF model reservation".into());
        }
        // rawとnewの全同時容量を支払い終えてから一度だけ確保する。
        let mut words = Vec::new();
        words.try_reserve_exact(self.frequencies.len()).map_err(|_| "compiled CDF allocation")?;
        if words.capacity() > self.frequencies.len() || words.capacity() > ROWS {
            return Err("compiled CDF capacity bound".into());
        }
        let conversion_peak = raw_bytes
            .checked_add(words.capacity() * std::mem::size_of::<u64>())
            .and_then(|n| n.checked_add(CONVERSION_MANAGERS))
            .ok_or("compiled CDF capacity overflow")?;
        if conversion_peak > conversion_reserved || conversion_peak > MODEL_BOUND {
            return Err("compiled CDF model reservation".into());
        }
        let mut descriptors = [DecodeDescriptor { word: 0, offset: u32::MAX }; ROOTS];
        let mut consumed = 0usize;
        for (i, descriptor) in self.descriptors.iter().enumerate() {
            let k = i % 3 + 2;
            if descriptor.offset == u32::MAX {
                descriptors[i].word = packed(&descriptor.frequency, k)?;
            } else {
                let offset = descriptor.offset as usize;
                if offset != consumed {
                    return Err("compiled CDF offset order".into());
                }
                let rows = self.frequencies.get(offset..offset + 1024).ok_or("compiled CDF extent")?;
                descriptors[i].offset = u32::try_from(words.len()).map_err(|_| "Forest offset")?;
                for row in rows {
                    words.push(packed(row, k)?);
                }
                consumed += 1024;
            }
        }
        if consumed != self.frequencies.len() {
            return Err("compiled CDF unused rows".into());
        }
        if words.len() != consumed || words.capacity() * std::mem::size_of::<u64>() > word_bytes {
            return Err("compiled CDF capacity bound".into());
        }
        let construction_peak = parse_peak.max(conversion_peak);
        // 全descriptorとpoolの検証成功後、rawを解放してからdecode objectを公開する。
        drop(self);
        Ok(DecodeForest {
            descriptors,
            words,
            construction_peak,
        })
    }
}
impl DecodeForest {
    pub(crate) fn cdf(&self, c: usize, node: usize, k: usize, history: u16) -> Result<Cdf<'_>> {
        if c >= 2 || node >= 142 || !(2..=4).contains(&k) {
            return Err("Forest component/node/prefix".into());
        }
        let d = &self.descriptors[(c * 142 + node) * 3 + k - 2];
        let word = if d.offset == u32::MAX {
            &d.word
        } else {
            self.words.get(d.offset as usize + (history as usize & 1023)).ok_or("Forest index")?
        };
        Ok(Cdf { word, k })
    }
    pub(crate) fn capacity_bytes(&self) -> usize {
        self.words.capacity() * std::mem::size_of::<u64>() + std::mem::size_of::<Self>()
    }
    pub(crate) fn parse_transient(&self) -> usize {
        self.construction_peak - self.capacity_bytes()
    }
}
