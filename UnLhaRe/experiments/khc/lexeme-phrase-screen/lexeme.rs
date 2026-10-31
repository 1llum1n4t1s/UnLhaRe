// Failure-first: 入力上限、辞書境界/重複/不正 varint、頻度/ID/行の不正、
// capacity 超過、貪欲置換/unused-remap の byte 不一致、rANS 整数境界を拒否する。
// 既存の word/dense coding、front coding、static rANS の独立実装によるサイズ screen。
// codec_implemented=false / size_screen_only=true: entropy payload/decoder は作らない。
use std::collections::HashMap;
use std::mem::size_of;

pub const MAX_RAW: usize = 1 << 20;
pub const MAX_DICT: usize = 16384;
pub const TOTAL: usize = 1 << 18;
pub const LIBRARY_RESERVE: usize = 56 << 20;
pub type Result<T> = std::result::Result<T, String>;
const FRONT_LIMIT: usize = MAX_DICT * 133;
const LOW: u64 = 1 << 23;
const UPPER: u64 = 1 << 31;

#[derive(Debug)]
pub struct Analysis {
    pub vocab: usize,
    pub phrases: usize,
    pub symbols: usize,
    pub dict_raw_bytes: usize,
    pub dict_box_bytes: usize,
    pub model_bytes: usize,
    pub ans_bytes: usize,
    pub estimated_frame_bytes: usize,
    pub logical_bound: usize,
    pub frontend_exact: bool,
    pub dict_exact: bool,
}

pub struct Prepared {
    pub vocab: usize,
    pub phrases: usize,
    pub symbols: Vec<u16>,
    pub front: Vec<u8>,
    pub logical_bound: usize,
}

fn require(ok: bool, message: &str) -> Result<()> {
    if ok { Ok(()) } else { Err(message.into()) }
}

fn allocation<T>(count: usize) -> Result<Vec<T>> {
    let bytes = count.checked_mul(size_of::<T>()).ok_or("allocation overflow")?;
    require(bytes <= LIBRARY_RESERVE, "allocation exceeds library reserve")?;
    let mut out = Vec::new();
    out.try_reserve_exact(count).map_err(|_| "allocation failed")?;
    require(out.capacity() * size_of::<T>() <= LIBRARY_RESERVE, "actual capacity exceeds reserve")?;
    Ok(out)
}

fn cap<T>(items: &Vec<T>) -> usize {
    items.capacity() * size_of::<T>()
}

fn paid(bytes: usize) -> Result<usize> {
    require(bytes <= LIBRARY_RESERVE, "logical capacity exceeds library reserve")?;
    Ok(bytes)
}

fn buckets(capacity: usize) -> Result<usize> {
    if capacity == 0 {
        return Ok(0);
    }
    let need = capacity.checked_mul(8).and_then(|n| n.checked_add(6)).ok_or("bucket overflow")? / 7;
    need.checked_next_power_of_two().ok_or_else(|| "bucket overflow".into())
}

// 標準 HashMap の 7/8 load と 24B entry + control byte を課金する論理推定。
// allocator metadata、RSS、全 allocator に対する物理保証ではない。親が caller/peak を監視する。
fn hash_bytes(capacity: usize) -> Result<usize> {
    let slots = buckets(capacity)?;
    Ok(slots * (size_of::<(&[u8], u32)>() + 1) + if slots == 0 { 0 } else { 16 })
}

fn preflight(length: usize) -> Result<usize> {
    require(length <= MAX_RAW, "raw exceeds 1 MiB")?;
    // word_runs=n, eligible singles=e: raw >= 2n-1+2e;
    // unique singles <= e, phrases <= n-1, hence combined keys <= (raw-1)/2.
    let keys = length.saturating_sub(1) / 2;
    let slots = buckets(keys)?;
    let growing = (slots + slots / 2) * (size_of::<(&[u8], u32)>() + 1) + 32;
    let ranking = slots * (size_of::<(&[u8], u32)>() + 1) + 16 + keys * size_of::<(&[u8], u32)>();
    // 後段は hash/ranking の drop 後。parse の Vec headers/word bytes、front bytes、
    // symbols/remap/復元、counts/frequencies/CDF と Hamilton の sorting overlap を払う。
    let later = length * 3 + FRONT_LIMIT * 2 + MAX_DICT * 64 + (256 + MAX_DICT) * 80 + 65536;
    paid(growing.max(ranking).max(later))
}

fn letter(byte: u8) -> bool {
    byte.is_ascii_alphabetic()
}

fn end_word(raw: &[u8], mut position: usize) -> usize {
    while position < raw.len() && letter(raw[position]) {
        position += 1;
    }
    position
}

fn valid_word(word: &[u8]) -> bool {
    if (3..=64).contains(&word.len()) && word.iter().all(|&b| letter(b)) {
        return true;
    }
    let Some(space) = word.iter().position(|&b| b == b' ') else {
        return false;
    };
    (1..=64).contains(&space)
        && (1..=64).contains(&word.len().saturating_sub(space + 1))
        && word[..space].iter().all(|&b| letter(b))
        && word[space + 1..].iter().all(|&b| letter(b))
}

fn lcp(left: &[u8], right: &[u8]) -> usize {
    left.iter().zip(right).take_while(|(a, b)| a == b).count()
}

fn var_len(mut value: usize) -> usize {
    let mut length = 1;
    while value >= 128 {
        value >>= 7;
        length += 1;
    }
    length
}

fn put_var(out: &mut Vec<u8>, mut value: usize) {
    while value >= 128 {
        out.push((value as u8 & 127) | 128);
        value >>= 7;
    }
    out.push(value as u8);
}

fn get_var(bytes: &[u8], position: &mut usize) -> Result<usize> {
    let start = *position;
    let mut value = 0usize;
    let mut shift = 0;
    loop {
        let byte = *bytes.get(*position).ok_or("truncated varint")?;
        *position += 1;
        let part = usize::from(byte & 127);
        require(shift < usize::BITS && part <= (usize::MAX >> shift), "varint overflow")?;
        value |= part << shift;
        if byte & 128 == 0 {
            require(*position - start == var_len(value), "noncanonical varint")?;
            return Ok(value);
        }
        shift += 7;
    }
}

pub fn front_encode(words: &[&[u8]]) -> Result<Vec<u8>> {
    require(words.len() <= MAX_DICT, "dictionary too large")?;
    let mut bound = 0usize;
    let mut previous: &[u8] = &[];
    for &word in words {
        require(valid_word(word), "illegal dictionary word")?;
        require(previous.is_empty() || previous < word, "dictionary not strictly byte sorted")?;
        bound += word.len() + 4;
        previous = word;
    }
    let mut out = allocation(bound)?;
    previous = &[];
    for &word in words {
        let prefix = lcp(previous, word);
        put_var(&mut out, prefix);
        put_var(&mut out, word.len() - prefix);
        out.extend_from_slice(&word[prefix..]);
        previous = word;
    }
    require(out.len() <= FRONT_LIMIT, "front-coded dictionary exceeds bound")?;
    Ok(out)
}

pub fn front_decode(bytes: &[u8], count: usize) -> Result<Vec<Vec<u8>>> {
    require(count <= MAX_DICT && bytes.len() <= FRONT_LIMIT, "dictionary input exceeds bound")?;
    let mut words: Vec<Vec<u8>> = allocation(count)?;
    let mut position = 0usize;
    let mut used = cap(&words);
    for _ in 0..count {
        let prefix = get_var(bytes, &mut position)?;
        let suffix = get_var(bytes, &mut position)?;
        let previous = words.last().map_or(&[][..], |w| w.as_slice());
        require(prefix <= previous.len(), "dictionary prefix exceeds previous word")?;
        let length = prefix.checked_add(suffix).ok_or("word length overflow")?;
        require(length <= 129, "dictionary word exceeds 129 bytes")?;
        let end = position.checked_add(suffix).ok_or("suffix length overflow")?;
        let tail = bytes.get(position..end).ok_or("truncated dictionary suffix")?;
        let mut word = allocation(length)?;
        word.extend_from_slice(&previous[..prefix]);
        word.extend_from_slice(tail);
        require(valid_word(&word), "illegal dictionary word")?;
        require(previous.is_empty() || previous < word.as_slice(), "dictionary duplicate or unsorted")?;
        require(prefix == lcp(previous, &word), "dictionary prefix is not actual LCP")?;
        used = paid(used + cap(&word))?;
        words.push(word);
        position = end;
    }
    require(position == bytes.len(), "dictionary trailing bytes")?;
    Ok(words)
}

// Positive Hamilton: 全 ID に 1、残り TOTAL-n を整数比で配る。全 zero は一様。
// floor 後の余りは remainder 降順、同値は ID 昇順。float/探索は使わない。
pub fn normalize(counts: &[u32]) -> Result<Vec<u32>> {
    require(!counts.is_empty() && counts.len() <= TOTAL, "invalid normalization alphabet")?;
    let sum: u64 = counts.iter().map(|&n| u64::from(n)).sum();
    let denominator = if sum == 0 { counts.len() as u64 } else { sum };
    let available = (TOTAL - counts.len()) as u64;
    let mut frequencies = allocation(counts.len())?;
    let mut residuals = allocation(counts.len())?;
    let mut assigned = counts.len();
    for (id, &count) in counts.iter().enumerate() {
        let weight = if sum == 0 { 1 } else { u64::from(count) };
        let numerator = weight * available;
        let floor = (numerator / denominator) as u32;
        frequencies.push(1 + floor);
        assigned += floor as usize;
        residuals.push((numerator % denominator, id));
    }
    residuals.sort_unstable_by(|a, b| b.0.cmp(&a.0).then_with(|| a.1.cmp(&b.1)));
    let remaining = TOTAL - assigned;
    require(remaining <= residuals.len(), "Hamilton remainder exceeds alphabet")?;
    for &(_, id) in &residuals[..remaining] {
        frequencies[id] += 1;
    }
    paid(cap(&frequencies) + cap(&residuals))?;
    Ok(frequencies)
}

fn cdf(frequencies: &[u32]) -> Result<Vec<u32>> {
    require(!frequencies.is_empty() && frequencies.len() <= TOTAL, "invalid frequency alphabet")?;
    let mut cumulative = allocation(frequencies.len())?;
    let mut sum = 0u64;
    for &frequency in frequencies {
        require(frequency > 0, "zero frequency")?;
        cumulative.push(u32::try_from(sum).map_err(|_| "CDF overflow")?);
        sum += u64::from(frequency);
        require(sum <= TOTAL as u64, "frequency sum exceeds TOTAL")?;
    }
    require(sum == TOTAL as u64, "frequency sum differs from TOTAL")?;
    Ok(cumulative)
}

fn step(state: &mut u64, frequency: u32, cumulative: u32, count: &mut usize) -> Result<()> {
    let frequency = u64::from(frequency);
    let threshold = ((LOW >> 18) << 8) * frequency;
    while *state >= threshold {
        *state >>= 8;
        *count += 1;
    }
    *state = ((*state / frequency) << 18) + *state % frequency + u64::from(cumulative);
    require((LOW..UPPER).contains(state), "rANS state outside u32 bounds")
}

pub fn ans_count(symbols: &[u16], row0: &[u32], row1: &[u32]) -> Result<usize> {
    require(symbols.len() <= MAX_RAW, "too many symbols")?;
    require((256..=256 + MAX_DICT).contains(&row0.len()), "invalid token row0 alphabet")?;
    require(row1.is_empty() || row1.len() == 256, "invalid token row1 alphabet")?;
    let cumulative0 = cdf(row0)?;
    let cumulative1 = if row1.is_empty() { Vec::new() } else { cdf(row1)? };
    for (index, &symbol) in symbols.iter().enumerate() {
        require(usize::from(symbol) < row0.len(), "token ID outside row0")?;
        if symbol >= 256 {
            require(!row1.is_empty(), "dictionary ID without row1")?;
        }
        if index > 0 && symbols[index - 1] >= 256 {
            require(symbol < 256, "dictionary followed by dictionary")?;
        }
    }
    let mut state = LOW;
    let mut bytes = 4usize;
    for (index, &symbol) in symbols.iter().enumerate().rev() {
        let id = usize::from(symbol);
        let (frequencies, cumulative) = if index > 0 && symbols[index - 1] >= 256 {
            (row1, cumulative1.as_slice())
        } else {
            (row0, cumulative0.as_slice())
        };
        step(&mut state, frequencies[id], cumulative[id], &mut bytes)?;
    }
    Ok(bytes)
}

pub fn ans_byte_count(bytes: &[u8], frequencies: &[u32]) -> Result<usize> {
    require(bytes.len() <= FRONT_LIMIT && frequencies.len() == 256, "invalid dictionary byte model")?;
    let cumulative = cdf(frequencies)?;
    let mut state = LOW;
    let mut length = 4;
    for &byte in bytes.iter().rev() {
        let id = usize::from(byte);
        step(&mut state, frequencies[id], cumulative[id], &mut length)?;
    }
    Ok(length)
}

fn learn<'a>(map: &mut HashMap<&'a [u8], u32>, word: &'a [u8], peak: &mut usize, max_keys: usize) -> Result<()> {
    if let Some(count) = map.get_mut(word) {
        *count = count.checked_add(1).ok_or("occurrence count overflow")?;
        return Ok(());
    }
    require(map.len() < max_keys, "distinct-key bound violated")?;
    if map.len() == map.capacity() {
        let old = hash_bytes(map.capacity())?;
        // preflight は最大新旧 overlap を確保済み。実 capacity は予約後にも確認。
        map.try_reserve(1).map_err(|_| "dictionary hash allocation failed")?;
        *peak = (*peak).max(paid(old + hash_bytes(map.capacity())?)?);
    }
    map.insert(word, 1);
    Ok(())
}

fn model_cost(frequencies: &[u32]) -> usize {
    frequencies.iter().map(|&f| var_len(f as usize)).sum()
}

pub fn prepare(raw: &[u8]) -> Result<Prepared> {
    let planned_bound = preflight(raw.len())?;
    let max_keys = raw.len().saturating_sub(1) / 2;
    let mut logical_bound = planned_bound;
    let mut occurrences = HashMap::new();
    let mut position = 0;
    let mut previous: Option<(usize, usize)> = None;
    while position < raw.len() {
        if !letter(raw[position]) {
            position += 1;
            continue;
        }
        let start = position;
        let end = end_word(raw, start);
        let length = end - start;
        if (3..=64).contains(&length) {
            learn(&mut occurrences, &raw[start..end], &mut logical_bound, max_keys)?;
        }
        if let Some((old_start, old_end)) = previous {
            if old_end + 1 == start && raw[old_end] == b' ' && old_end - old_start <= 64 && length <= 64 {
                learn(&mut occurrences, &raw[old_start..end], &mut logical_bound, max_keys)?;
            }
        }
        previous = Some((start, end));
        position = end;
    }
    let mut ranked = allocation(occurrences.len())?;
    logical_bound = logical_bound.max(paid(hash_bytes(occurrences.capacity())? + cap(&ranked))?);
    ranked.extend(occurrences.iter().filter(|(_, count)| **count >= 2).map(|(&word, &count)| (word, count)));
    drop(occurrences);
    ranked.sort_unstable_by(|a, b| b.1.cmp(&a.1).then_with(|| b.0.len().cmp(&a.0.len())).then_with(|| a.0.cmp(b.0)));
    let mut words = allocation(ranked.len().min(MAX_DICT))?;
    words.extend(ranked.iter().take(MAX_DICT).map(|&(word, _)| word));
    logical_bound = logical_bound.max(paid(cap(&ranked) + cap(&words))?);
    drop(ranked);
    words.sort_unstable();
    let mut usage = allocation(words.len())?;
    usage.resize(words.len(), 0u32);
    let mut symbols = allocation(raw.len())?;
    position = 0;
    while position < raw.len() {
        if !letter(raw[position]) {
            symbols.push(u16::from(raw[position]));
            position += 1;
            continue;
        }
        let end = end_word(raw, position);
        let mut selected = None;
        if end - position <= 64 && raw.get(end) == Some(&b' ') && raw.get(end + 1).is_some_and(|&b| letter(b)) {
            let phrase_end = end_word(raw, end + 1);
            if phrase_end - end - 1 <= 64 {
                if let Ok(id) = words.binary_search(&&raw[position..phrase_end]) {
                    selected = Some((id, phrase_end));
                }
            }
        }
        if selected.is_none() {
            if let Ok(id) = words.binary_search(&&raw[position..end]) {
                selected = Some((id, end));
            }
        }
        if let Some((id, next)) = selected {
            symbols.push((256 + id) as u16);
            usage[id] += 1;
            position = next;
        } else {
            symbols.extend(raw[position..end].iter().map(|&b| u16::from(b)));
            position = end;
        }
    }
    let mut remap = allocation(words.len())?;
    let mut next = 0usize;
    for &used in &usage {
        remap.push(next as u16);
        if used != 0 {
            next += 1;
        }
    }
    let mut old_id = 0;
    words.retain(|_| {
        let keep = usage[old_id] != 0;
        old_id += 1;
        keep
    });
    for symbol in &mut symbols {
        if *symbol >= 256 {
            *symbol = 256 + remap[usize::from(*symbol) - 256];
        }
    }
    let frontend_live = cap(&words) + cap(&symbols) + cap(&usage) + cap(&remap);
    let mut restored = allocation(raw.len())?;
    for &symbol in &symbols {
        if symbol < 256 {
            require(restored.len() < raw.len(), "frontend literal exceeds reconstructed bound")?;
            restored.push(symbol as u8);
        } else {
            let word = words[usize::from(symbol) - 256];
            require(restored.len() + word.len() <= raw.len(), "frontend reconstructed length exceeds raw")?;
            restored.extend_from_slice(word);
        }
    }
    require(restored.as_slice() == raw, "frontend byte roundtrip mismatch")?;
    logical_bound = logical_bound.max(paid(frontend_live + cap(&restored))?);
    drop(restored);
    drop(usage);
    drop(remap);
    let front = front_encode(&words)?;
    let decoded = front_decode(&front, words.len())?;
    require(
        decoded.iter().zip(&words).all(|(parsed, original)| parsed.as_slice() == *original),
        "dictionary byte roundtrip mismatch",
    )?;
    let decoded_bytes = cap(&decoded) + decoded.iter().map(cap).sum::<usize>();
    let live = cap(&words) + cap(&symbols) + cap(&front);
    logical_bound = logical_bound.max(paid(live + decoded_bytes)?);
    drop(decoded);
    Ok(Prepared { vocab: words.len(), phrases: words.iter().filter(|word| word.contains(&b' ')).count(), symbols, front, logical_bound })
}

pub fn analyze(raw: &[u8]) -> Result<Analysis> {
    let Prepared { vocab, phrases, symbols, front, mut logical_bound } = prepare(raw)?;
    let live = cap(&symbols) + cap(&front);
    let dict_raw_bytes = front.len();
    let dict_box_bytes = if vocab == 0 {
        0
    } else {
        let mut counts = [0u32; 256];
        for &byte in &front {
            counts[usize::from(byte)] += 1;
        }
        let frequencies = normalize(&counts)?;
        logical_bound = logical_bound.max(paid(live + cap(&frequencies) + 256 * 24 + 1024)?);
        let packed = model_cost(&frequencies) + ans_byte_count(&front, &frequencies)?;
        16 + front.len().min(packed)
    };
    let mut counts0 = allocation(256 + vocab)?;
    counts0.resize(256 + vocab, 0u32);
    let mut counts1 = allocation(if vocab == 0 { 0 } else { 256 })?;
    counts1.resize(if vocab == 0 { 0 } else { 256 }, 0u32);
    for (index, &symbol) in symbols.iter().enumerate() {
        if index > 0 && symbols[index - 1] >= 256 {
            require(symbol < 256, "frontend row1 is not literal")?;
            counts1[usize::from(symbol)] += 1;
        } else {
            counts0[usize::from(symbol)] += 1;
        }
    }
    let frequencies0 = normalize(&counts0)?;
    let frequencies1 = if counts1.is_empty() { Vec::new() } else { normalize(&counts1)? };
    // normalize の residual sorting と ans_count の両 CDF が同時に生存する上限を含める。
    let model_live = cap(&counts0) + cap(&counts1) + cap(&frequencies0) + cap(&frequencies1);
    logical_bound = logical_bound.max(paid(live + model_live + (counts0.len() + counts1.len()) * 24 + 4096)?);
    let model_bytes = model_cost(&frequencies0) + model_cost(&frequencies1);
    let ans_bytes = ans_count(&symbols, &frequencies0, &frequencies1)?;
    let coded = 40 + dict_box_bytes + model_bytes + ans_bytes;
    Ok(Analysis {
        vocab,
        phrases,
        symbols: symbols.len(),
        dict_raw_bytes,
        dict_box_bytes,
        model_bytes,
        ans_bytes,
        estimated_frame_bytes: coded.min(raw.len() + 40),
        logical_bound,
        frontend_exact: true,
        dict_exact: true,
    })
}
