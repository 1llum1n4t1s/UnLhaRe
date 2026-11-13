//! 多値・単一state rANS研究実装。Cコードの移植ではない。
//! 数学的方式: Fabian Giesen, rans_byte.h (2014, public domain):
//! https://github.com/rygorous/ryg_rans/blob/master/rans_byte.h
const LOWER: u32 = 1 << 23;
const UPPER: u32 = LOWER << 8;
pub(crate) const MAX_EVENTS: usize = 2 * 1024 * 1024;
pub(crate) const MAX_RETAINED_BYTES: usize = MAX_EVENTS * 6;
pub(crate) const MAX_LIVE_BYTES: usize = MAX_RETAINED_BYTES + MAX_RETAINED_BYTES / 2;

#[derive(Clone, Copy)]
#[repr(C)]
struct Event {
    cumulative: u16,
    frequency: u16,
    scale: u8,
}
const _: () = assert!(std::mem::size_of::<Event>() == 6);
fn scale(total: u32) -> Result<u8, &'static str> {
    match total {
        256 => Ok(8),
        32768 => Ok(15),
        _ => Err("invalid ANS total"),
    }
}
fn valid(cumulative: u32, frequency: u32, total: u32) -> Result<u8, &'static str> {
    let bits = scale(total)?;
    if frequency == 0
        || cumulative
            .checked_add(frequency)
            .is_none_or(|end| end > total)
    {
        return Err("invalid ANS interval");
    }
    Ok(bits)
}
pub(crate) struct Encoder {
    events: Vec<Event>,
    limit: usize,
    old_capacity_peak: usize,
}
impl Encoder {
    pub(crate) fn with_limit(limit: usize) -> Result<Self, &'static str> {
        if limit > 1 << 20 {
            return Err("ANS output bound");
        }
        Ok(Self {
            events: Vec::new(),
            limit,
            old_capacity_peak: 0,
        })
    }
    pub(crate) fn interval(
        &mut self,
        cumulative: u32,
        frequency: u32,
        total: u32,
    ) -> Result<(), &'static str> {
        let bits = valid(cumulative, frequency, total)?;
        if self.events.len() == MAX_EVENTS {
            return Err("ANS journal limit");
        }
        if self.events.len() == self.events.capacity() {
            self.old_capacity_peak = self.old_capacity_peak.max(self.events.capacity());
            let target = self
                .events
                .capacity()
                .saturating_mul(2)
                .clamp(1024, MAX_EVENTS);
            self.events
                .try_reserve_exact(target - self.events.len())
                .map_err(|_| "ANS allocation failed")?;
            if self.events.capacity() > MAX_EVENTS {
                return Err("ANS journal capacity");
            }
        }
        self.events.push(Event {
            cumulative: cumulative as u16,
            frequency: frequency as u16,
            scale: bits,
        });
        Ok(())
    }
    pub(crate) fn capacity_bytes(&self) -> usize {
        self.events.capacity() * 6
    }
    pub(crate) fn transient_bytes(&self) -> usize {
        self.old_capacity_peak * 6
    }
    pub(crate) fn event_count(&self) -> usize {
        self.events.len()
    }
    pub(crate) fn finish(self) -> Result<Vec<u8>, &'static str> {
        if self.limit < 5 {
            return Err("range output limit");
        }
        let mut output = Vec::new();
        output
            .try_reserve_exact(self.limit)
            .map_err(|_| "ANS allocation failed")?;
        if output.capacity() > self.limit {
            return Err("ANS output capacity");
        }
        let length = self.finish_events(Some(&mut output))?;
        debug_assert_eq!(output.len(), length);
        Ok(output)
    }
    pub(crate) fn finish_len(self) -> Result<usize, &'static str> {
        if self.limit < 5 {
            return Err("range output limit");
        }
        self.finish_events(None)
    }
    fn finish_events(self, mut output: Option<&mut Vec<u8>>) -> Result<usize, &'static str> {
        let mut state = LOWER;
        let mut renormalized = 0usize;
        for event in self.events.iter().rev() {
            let frequency = u32::from(event.frequency);
            let maximum = ((LOWER >> event.scale) << 8) * frequency;
            while state >= maximum {
                if renormalized == self.limit - 5 {
                    return Err("range output limit");
                }
                if let Some(bytes) = output.as_deref_mut() {
                    bytes.push(state as u8);
                }
                renormalized += 1;
                state >>= 8;
            }
            let next = ((u64::from(state) / u64::from(frequency)) << event.scale)
                + u64::from(state) % u64::from(frequency)
                + u64::from(event.cumulative);
            if !(u64::from(LOWER)..u64::from(UPPER)).contains(&next) {
                return Err("ANS encoder state");
            }
            state = next as u32;
        }
        if let Some(bytes) = output {
            bytes.reverse();
            bytes.push(0);
            bytes.extend_from_slice(&state.to_le_bytes());
            bytes.rotate_right(5);
        }
        Ok(renormalized + 5)
    }
}
pub(crate) struct Decoder<'a> {
    input: &'a [u8],
    position: usize,
    state: u32,
}
impl<'a> Decoder<'a> {
    pub(crate) fn new(input: &'a [u8]) -> Result<Self, &'static str> {
        if input.len() < 5 || input[0] != 0 {
            return Err("invalid ANS prefix");
        }
        let state = u32::from_le_bytes(input[1..5].try_into().map_err(|_| "ANS initial state")?);
        if !(LOWER..UPPER).contains(&state) {
            return Err("invalid ANS initial state");
        }
        Ok(Self {
            input,
            position: 5,
            state,
        })
    }
    pub(crate) fn slot(&self, total: u32) -> Result<u32, &'static str> {
        scale(total)?;
        Ok(self.state & (total - 1))
    }
    pub(crate) fn consume(
        &mut self,
        cumulative: u32,
        frequency: u32,
        total: u32,
    ) -> Result<(), &'static str> {
        let bits = valid(cumulative, frequency, total)?;
        let slot = self.slot(total)?;
        if slot < cumulative || slot >= cumulative + frequency {
            return Err("ANS slot outside interval");
        }
        let mut state = frequency
            .checked_mul(self.state >> bits)
            .and_then(|x| x.checked_add(slot - cumulative))
            .ok_or("ANS state overflow")?;
        let mut position = self.position;
        while state < LOWER {
            let byte = *self.input.get(position).ok_or("truncated ANS stream")?;
            position = position.checked_add(1).ok_or("ANS input overflow")?;
            state = (state << 8) | u32::from(byte);
        }
        if state >= UPPER {
            return Err("ANS decoded state");
        }
        self.state = state;
        self.position = position;
        Ok(())
    }
    pub(crate) fn finish(&self) -> Result<(), &'static str> {
        if self.position != self.input.len() {
            return Err("trailing ANS bytes");
        }
        if self.state != LOWER {
            return Err("noncanonical ANS termination");
        }
        Ok(())
    }
}
