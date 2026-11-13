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

pub(crate) struct Encoder<const COUNT_ONLY: bool = false> {
    state: State,
    output: Vec<u8>,
    // 計数時も同じcommitで、確定したflush groupの長さだけを加算する。
    output_len: usize,
    limit: usize,
}

impl<const COUNT_ONLY: bool> Encoder<COUNT_ONLY> {
    pub(crate) fn allocated_bytes(&self) -> usize {
        self.output.capacity()
    }

    pub(crate) fn with_limit(limit: usize) -> Result<Self, &'static str> {
        let mut output = Vec::new();
        if !COUNT_ONLY {
            output
                .try_reserve_exact(limit.min(1 << 20))
                .map_err(|_| "range allocation failed")?;
        }
        Ok(Self {
            state: State {
                low: 0,
                range: u32::MAX,
                cache: 0,
                pending: 1,
            },
            output,
            output_len: 0,
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
            .output_len
            .checked_add(extra)
            .ok_or("range output limit")?;
        if required > self.limit {
            return Err("range output limit");
        }
        if !COUNT_ONLY && required > self.output.capacity() {
            let target = required
                .max(self.output.capacity().saturating_mul(2))
                .min(self.limit);
            self.output
                .try_reserve_exact(target - self.output.len())
                .map_err(|_| "range allocation failed")?;
        }
        if !COUNT_ONLY {
            for g in groups {
                if g.length != 0 {
                    self.output.push(g.first);
                    self.output.resize(self.output.len() + g.length - 1, g.rest);
                }
            }
        }
        self.output_len = required;
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

    pub(crate) fn finish_with_length(mut self) -> Result<(Vec<u8>, usize), &'static str> {
        let mut state = self.state;
        let mut groups = [Group::default(); 5];
        for g in &mut groups {
            *g = Self::shift(&mut state)?;
        }
        self.commit(state, &groups)?;
        Ok((self.output, self.output_len))
    }
}

impl Encoder {
    pub(crate) fn finish(self) -> Result<Vec<u8>, &'static str> {
        self.finish_with_length().map(|(output, _)| output)
    }
}

pub(crate) struct Decoder<'a> {
    input: &'a [u8],
    position: usize,
    code: u32,
    range: u32,
}

#[derive(Clone, Copy)]
pub(crate) struct RangeSlot {
    value: u32,
    unit: u32,
    total: u32,
    code: u32,
    range: u32,
}

impl RangeSlot {
    pub(crate) fn value(&self) -> u32 {
        self.value
    }
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

    pub(crate) fn slot(&self, total: u32) -> Result<RangeSlot, &'static str> {
        if !(1..=MAX_TOTAL).contains(&total) {
            return Err("invalid range total");
        }
        let unit = self.range / total;
        let value = self.code / unit;
        if value >= total {
            return Err("range rounding gap");
        }
        Ok(RangeSlot {
            value,
            unit,
            total,
            code: self.code,
            range: self.range,
        })
    }

    pub(crate) fn consume(
        &mut self,
        slot: RangeSlot,
        cumulative: u32,
        frequency: u32,
        total: u32,
    ) -> Result<(), &'static str> {
        valid(cumulative, frequency, total)?;
        if slot.total != total || slot.code != self.code || slot.range != self.range {
            return Err("stale range slot");
        }
        if slot.value < cumulative || slot.value >= cumulative + frequency {
            return Err("range slot outside interval");
        }
        let unit = slot.unit;
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
