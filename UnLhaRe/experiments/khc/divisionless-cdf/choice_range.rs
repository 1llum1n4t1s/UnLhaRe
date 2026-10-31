const NORMALIZE: u32 = 1 << 24;
const MAX_TOTAL: u32 = 81_920;

fn valid(cumulative: u32, frequency: u32, total: u32) -> Result<(), &'static str> {
    if !(1..=MAX_TOTAL).contains(&total)
        || frequency == 0
        || cumulative
            .checked_add(frequency)
            .is_none_or(|end| end > total)
    {
        return Err("invalid range interval");
    }
    Ok(())
}

#[derive(Clone, Copy)]
struct State {
    low: u64,
    range: u32,
    cache: u8,
    pending: usize,
}
#[derive(Clone, Copy, Default)]
struct Group {
    first: u8,
    rest: u8,
    length: usize,
}

pub(crate) struct Encoder {
    state: State,
    output: Vec<u8>,
    limit: usize,
}

impl Encoder {
    pub(crate) fn with_limit(limit: usize) -> Result<Self, &'static str> {
        let mut output = Vec::new();
        output
            .try_reserve_exact(limit.min(1 << 20))
            .map_err(|_| "range allocation failed")?;
        Ok(Self {
            state: State {
                low: 0,
                range: u32::MAX,
                cache: 0,
                pending: 1,
            },
            output,
            limit,
        })
    }

    // scalar の仮状態で flush group を確定し、reserve 成功後だけ実状態を更新する。
    fn shift(state: &mut State) -> Result<Group, &'static str> {
        let low = state.low as u32;
        let carry = (state.low >> 32) as u8;
        let mut group = Group::default();
        if low < 0xff00_0000 || carry != 0 {
            group = Group {
                first: state.cache.wrapping_add(carry),
                rest: 255u8.wrapping_add(carry),
                length: state.pending,
            };
            state.pending = 0;
            state.cache = (low >> 24) as u8;
        }
        state.pending = state.pending.checked_add(1).ok_or("range output limit")?;
        state.low = u64::from((low & 0x00ff_ffff) << 8);
        Ok(group)
    }

    fn commit(&mut self, state: State, groups: &[Group]) -> Result<(), &'static str> {
        let extra = groups
            .iter()
            .try_fold(0usize, |sum, g| sum.checked_add(g.length))
            .ok_or("range output limit")?;
        let required = self
            .output
            .len()
            .checked_add(extra)
            .ok_or("range output limit")?;
        if required > self.limit {
            return Err("range output limit");
        }
        if required > self.output.capacity() {
            let target = required
                .max(self.output.capacity().saturating_mul(2))
                .min(self.limit);
            self.output
                .try_reserve_exact(target - self.output.len())
                .map_err(|_| "range allocation failed")?;
        }
        for g in groups {
            if g.length != 0 {
                self.output.push(g.first);
                self.output.resize(self.output.len() + g.length - 1, g.rest);
            }
        }
        self.state = state;
        Ok(())
    }

    pub(crate) fn interval(
        &mut self,
        cumulative: u32,
        frequency: u32,
        total: u32,
    ) -> Result<(), &'static str> {
        valid(cumulative, frequency, total)?;
        let mut state = self.state;
        let unit = state.range / total;
        state.low += u64::from(unit) * u64::from(cumulative);
        state.range = unit * frequency;
        let mut groups = [Group::default(); 3];
        let mut count = 0;
        while state.range < NORMALIZE {
            state.range <<= 8;
            groups[count] = Self::shift(&mut state)?;
            count += 1;
        }
        self.commit(state, &groups[..count])
    }

    pub(crate) fn finish(mut self) -> Result<Vec<u8>, &'static str> {
        let mut state = self.state;
        let mut groups = [Group::default(); 5];
        for g in &mut groups {
            *g = Self::shift(&mut state)?;
        }
        self.commit(state, &groups)?;
        Ok(self.output)
    }
}

pub(crate) struct Decoder<'a> {
    input: &'a [u8],
    position: usize,
    code: u32,
    range: u32,
}

impl<'a> Decoder<'a> {
    pub(crate) fn new(input: &'a [u8]) -> Result<Self, &'static str> {
        if input.len() < 5 || input[0] != 0 {
            return Err("invalid range prefix");
        }
        let code = u32::from_be_bytes(input[1..5].try_into().unwrap());
        Ok(Self {
            input,
            position: 5,
            code,
            range: u32::MAX,
        })
    }

    pub(crate) fn slot(&self, total: u32) -> Result<u32, &'static str> {
        if !(1..=MAX_TOTAL).contains(&total) {
            return Err("invalid range total");
        }
        let slot = self.code / (self.range / total);
        if slot >= total {
            return Err("range rounding gap");
        }
        Ok(slot)
    }

    pub(crate) fn consume(
        &mut self,
        cumulative: u32,
        frequency: u32,
        total: u32,
    ) -> Result<(), &'static str> {
        valid(cumulative, frequency, total)?;
        let slot = self.slot(total)?;
        if slot < cumulative || slot >= cumulative + frequency {
            return Err("range slot outside interval");
        }
        let unit = self.range / total;
        let mut code = self.code - unit * cumulative;
        let mut range = unit * frequency;
        let mut position = self.position;
        while range < NORMALIZE {
            let byte = *self.input.get(position).ok_or("truncated range stream")?;
            position += 1;
            code = (code << 8) | u32::from(byte);
            range <<= 8;
        }
        self.code = code;
        self.range = range;
        self.position = position;
        Ok(())
    }

    // CHOICE METHOD BEGIN
    pub(crate) fn choose_32768(&mut self, f: [u16; 4], k: usize) -> Result<usize, &'static str> {
        if !(2..=4).contains(&k)
            || f[..k].iter().any(|&v| v < 2)
            || f[k..].iter().any(|&v| v != 0)
            || f.iter().map(|&v| u32::from(v)).sum::<u32>() != 32768
        {
            return Err("wire CDF support/total/tail");
        }
        let unit = self.range >> 15;
        if self.code >= unit * 32768 {
            return Err("range rounding gap");
        }
        let mut cumulative = 0;
        for (child, &frequency) in f.iter().enumerate().take(k) {
            let frequency = u32::from(frequency);
            let end = cumulative + frequency;
            if self.code < unit * end {
                let mut code = self.code - unit * cumulative;
                let mut range = unit * frequency;
                let mut position = self.position;
                while range < NORMALIZE {
                    let byte = *self.input.get(position).ok_or("truncated range stream")?;
                    position += 1;
                    code = (code << 8) | u32::from(byte);
                    range <<= 8;
                }
                self.code = code;
                self.range = range;
                self.position = position;
                return Ok(child);
            }
            cumulative = end;
        }
        Err("range CDF child")
    }
    // CHOICE METHOD END
    pub(crate) fn finish(&self) -> Result<(), &'static str> {
        if self.position != self.input.len() {
            return Err("trailing range bytes");
        }
        if self.code != 0 {
            return Err("noncanonical range termination");
        }
        Ok(())
    }
}

// CHOICE CONTRACT BEGIN
fn reference(dec: &mut Decoder<'_>, f: [u16; 4], k: usize) -> Result<usize, &'static str> {
    if !(2..=4).contains(&k)
        || f[..k].iter().any(|&v| v < 2)
        || f[k..].iter().any(|&v| v != 0)
        || f.iter().map(|&v| u32::from(v)).sum::<u32>() != 32768
    {
        return Err("wire CDF support/total/tail");
    }
    let slot = dec.slot(32768)?;
    let mut cumulative = 0;
    for (i, &frequency) in f.iter().enumerate().take(k) {
        let frequency = u32::from(frequency);
        if slot < cumulative + frequency {
            dec.consume(cumulative, frequency, 32768)?;
            return Ok(i);
        }
        cumulative += frequency;
    }
    Err("range CDF child")
}
fn state(dec: &Decoder<'_>) -> (u32, u32, usize) {
    (dec.code, dec.range, dec.position)
}
fn compare_case(
    input: &[u8],
    code: u32,
    range: u32,
    f: [u16; 4],
    k: usize,
) -> Result<(), &'static str> {
    let mut a = Decoder {
        input,
        position: 5,
        code,
        range,
    };
    let mut b = Decoder {
        input,
        position: 5,
        code,
        range,
    };
    let before = state(&a);
    let old = reference(&mut a, f, k);
    let new = b.choose_32768(f, k);
    if old != new || state(&a) != state(&b) {
        return Err("divisionless reference state drift");
    }
    if old.is_err() && state(&a) != before {
        return Err("divisionless error commit");
    }
    Ok(())
}
pub(crate) fn contract() -> Result<usize, &'static str> {
    let mut cdfs = Vec::new();
    for k in 2..=4 {
        let mut uniform = [0u16; 4];
        uniform[..k].fill((32768 / k) as u16);
        uniform[k - 1] += (32768 % k) as u16;
        cdfs.push((uniform, k));
        for child in 0..k {
            let mut f = [0; 4];
            f[..k].fill(2);
            f[child] = (32768 - 2 * (k - 1)) as u16;
            cdfs.push((f, k));
        }
    }
    if cdfs.len() != 12 {
        return Err("CDF witness count");
    }
    let ranges = [NORMALIZE, NORMALIZE + 32767, 0x7fffffff, u32::MAX];
    let input = [0u8; 8];
    let mut checks = 0usize;
    for &(f, k) in &cdfs {
        for range in ranges {
            let unit = range / 32768;
            for slot in 0..32768 {
                for offset in [0, unit - 1] {
                    compare_case(&input, unit * slot + offset, range, f, k)?;
                    checks += 1;
                }
            }
        }
    }
    if checks != 3145728 {
        return Err("decision coverage");
    }
    for &(f, k) in &cdfs {
        for range in ranges {
            let used = (range / 32768) * 32768;
            for code in [used, range - 1, u32::MAX] {
                compare_case(&input, code, range, f, k)?;
                checks += 1;
            }
            for end in 5..8 {
                compare_case(&input[..end], 0, range, f, k)?;
                checks += 1;
            }
        }
    }
    for f in [
        [0, 32768, 0, 0],
        [1, 32767, 0, 0],
        [16384, 16383, 0, 0],
        [16384, 16384, 2, 0],
        [8192; 4],
    ] {
        for k in [0, 1, 2, 3, 5] {
            compare_case(&input, 0, u32::MAX, f, k)?;
            checks += 1;
        }
    }
    for &(f, k) in &cdfs {
        for length in [0, 1, 2, 31, 256, 1024] {
            let mut encoder = Encoder::with_limit(32768)?;
            for i in 0..length {
                let child = (i * 7 + 1) % k;
                let cumulative = f[..child].iter().map(|&v| u32::from(v)).sum();
                encoder.interval(cumulative, u32::from(f[child]), 32768)?;
            }
            let bytes = encoder.finish()?;
            let mut a = Decoder::new(&bytes)?;
            let mut b = Decoder::new(&bytes)?;
            for i in 0..length {
                let old = reference(&mut a, f, k)?;
                let new = b.choose_32768(f, k)?;
                if old != (i * 7 + 1) % k || new != old || state(&a) != state(&b) {
                    return Err("stream symbol/state drift");
                }
                checks += 1;
            }
            a.finish()?;
            b.finish()?;
            checks += 1;
        }
    }
    Ok(checks)
}
// CHOICE CONTRACT END
