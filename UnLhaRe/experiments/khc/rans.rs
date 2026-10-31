//! 適応binary model用のjournal付きrANS研究backend。

const SCALE_BITS: u32 = 15;
const TOTAL: u32 = 1 << SCALE_BITS;
const LOWER_BOUND: u32 = 1 << 23;
const UPPER_BOUND: u32 = LOWER_BOUND << 8;

pub(super) const MAX_EVENTS_PER_INPUT_BYTE: usize = 16;
pub(super) const SEGMENT_TARGET: usize = 512 * 1024;
const SEGMENT_MAGIC: &[u8; 4] = b"KRS1";
const SEGMENT_HEADER_BYTES: usize = 8;
pub(super) const MAX_SEGMENT_PLAIN: usize = SEGMENT_TARGET + 8 * 1024 + (1 << 16);

pub(super) struct Encoder {
    events: Vec<u16>,
    max_events: usize,
}

impl Encoder {
    pub(super) fn with_event_limit(max_events: usize) -> Result<Self, &'static str> {
        let mut events = Vec::new();
        events
            .try_reserve_exact(max_events)
            .map_err(|_| "rANS allocation failed")?;
        Ok(Self { events, max_events })
    }

    pub(super) fn bit(&mut self, zero_probability: u16, bit: bool) -> Result<(), &'static str> {
        if !(1..TOTAL as u16).contains(&zero_probability) {
            return Err("zero probability must be in 1..32768");
        }
        if self.events.len() == self.max_events {
            return Err("rANS event limit");
        }
        self.events.push(zero_probability | (u16::from(bit) << 15));
        Ok(())
    }

    fn finish_segment_with_check(
        &mut self,
        max_bytes: usize,
        mut cancelled: impl FnMut() -> bool,
    ) -> Result<Vec<u8>, &'static str> {
        let max_emitted_bytes = max_bytes.checked_sub(4).ok_or("range output limit")?;
        let mut emitted = Vec::new();
        let initial = (self.events.len() / 4 + 4).min(max_emitted_bytes);
        emitted
            .try_reserve_exact(initial)
            .map_err(|_| "rANS allocation failed")?;

        let mut state = u64::from(LOWER_BOUND);
        for (index, &event) in self.events.iter().enumerate().rev() {
            if index & 0xffff == 0 && cancelled() {
                return Err("rANS cancelled");
            }

            let bit = event & 0x8000 != 0;
            let zero_probability = u32::from(event & 0x7fff);
            let (start, frequency) = if bit {
                (zero_probability, TOTAL - zero_probability)
            } else {
                (0, zero_probability)
            };
            let maximum = u64::from((LOWER_BOUND >> SCALE_BITS) << 8) * u64::from(frequency);
            while state >= maximum {
                if emitted.len() == max_emitted_bytes {
                    return Err("range output limit");
                }
                if emitted.len() == emitted.capacity() {
                    let remaining = max_emitted_bytes - emitted.len();
                    let growth = emitted.capacity().max(4096).min(remaining);
                    emitted
                        .try_reserve_exact(growth)
                        .map_err(|_| "rANS allocation failed")?;
                }
                emitted.push(state as u8);
                state >>= 8;
            }
            state = ((state / u64::from(frequency)) << SCALE_BITS)
                + state % u64::from(frequency)
                + u64::from(start);
        }

        if !(u64::from(LOWER_BOUND)..u64::from(UPPER_BOUND)).contains(&state) {
            return Err("invalid rANS terminal state");
        }
        emitted
            .try_reserve_exact(4)
            .map_err(|_| "rANS allocation failed")?;
        emitted.reverse();
        emitted.extend_from_slice(&(state as u32).to_le_bytes());
        emitted.rotate_right(4);
        self.events.clear();
        Ok(emitted)
    }
}

/// rANS journalを完了済みparser planの境界で確定する研究用payload writer。
pub(super) struct SegmentedEncoder {
    coder: Encoder,
    payload: Vec<u8>,
    max_payload_bytes: usize,
    max_segment_plain: usize,
    current_plain: usize,
    total_plain: usize,
}

impl SegmentedEncoder {
    pub(super) fn new(max_payload_bytes: usize, input_size: usize) -> Result<Self, &'static str> {
        let max_segment_plain = input_size.min(MAX_SEGMENT_PLAIN);
        let max_events = max_segment_plain
            .checked_mul(MAX_EVENTS_PER_INPUT_BYTE)
            .ok_or("rANS event limit")?;
        let coder = Encoder::with_event_limit(max_events)?;
        let mut payload = Vec::new();
        if input_size != 0 {
            if max_payload_bytes < SEGMENT_MAGIC.len() {
                return Err("range output limit");
            }
            payload
                .try_reserve_exact(SEGMENT_MAGIC.len())
                .map_err(|_| "rANS allocation failed")?;
            payload.extend_from_slice(SEGMENT_MAGIC);
        }
        Ok(Self {
            coder,
            payload,
            max_payload_bytes,
            max_segment_plain,
            current_plain: 0,
            total_plain: 0,
        })
    }

    pub(super) fn bit(&mut self, zero_probability: u16, bit: bool) -> Result<(), &'static str> {
        self.coder.bit(zero_probability, bit)
    }

    pub(super) fn end_plan(
        &mut self,
        plain_bytes: usize,
        mut cancelled: impl FnMut() -> bool,
    ) -> Result<(), &'static str> {
        if plain_bytes == 0 {
            return Err("empty rANS parser plan");
        }
        self.current_plain = self
            .current_plain
            .checked_add(plain_bytes)
            .ok_or("rANS segment length overflow")?;
        self.total_plain = self
            .total_plain
            .checked_add(plain_bytes)
            .ok_or("rANS output length overflow")?;
        if self.current_plain > self.max_segment_plain {
            return Err("rANS segment plain limit");
        }
        if self.current_plain >= SEGMENT_TARGET {
            self.flush_segment(&mut cancelled)?;
        }
        Ok(())
    }

    fn flush_segment(&mut self, cancelled: &mut impl FnMut() -> bool) -> Result<(), &'static str> {
        if self.current_plain == 0 {
            return Err("empty rANS segment");
        }
        let output_budget = self
            .max_payload_bytes
            .checked_sub(self.payload.len())
            .and_then(|remaining| remaining.checked_sub(SEGMENT_HEADER_BYTES))
            .ok_or("range output limit")?;
        let stream = self
            .coder
            .finish_segment_with_check(output_budget, cancelled)?;
        let plain_len = u32::try_from(self.current_plain).map_err(|_| "rANS segment length")?;
        let compressed_len = u32::try_from(stream.len()).map_err(|_| "rANS segment length")?;
        let required = SEGMENT_HEADER_BYTES
            .checked_add(stream.len())
            .ok_or("rANS payload length overflow")?;
        if self
            .payload
            .len()
            .checked_add(required)
            .is_none_or(|length| length > self.max_payload_bytes)
        {
            return Err("range output limit");
        }
        self.payload
            .try_reserve_exact(required)
            .map_err(|_| "rANS allocation failed")?;
        self.payload.extend_from_slice(&plain_len.to_le_bytes());
        self.payload
            .extend_from_slice(&compressed_len.to_le_bytes());
        self.payload.extend_from_slice(&stream);
        self.current_plain = 0;
        Ok(())
    }

    pub(super) fn finish_with_check(
        mut self,
        expected_plain: usize,
        mut cancelled: impl FnMut() -> bool,
    ) -> Result<Vec<u8>, &'static str> {
        if self.total_plain != expected_plain {
            return Err("rANS output length mismatch");
        }
        if self.current_plain != 0 {
            self.flush_segment(&mut cancelled)?;
        }
        if expected_plain == 0 && self.payload.is_empty() {
            return Ok(self.payload);
        }
        if cancelled() {
            return Err("rANS cancelled");
        }
        Ok(self.payload)
    }
}

pub(super) struct Decoder<'a, const PROFILE: bool = false> {
    input: &'a [u8],
    position: usize,
    state: u32,
    bit_calls: u64,
}

impl<'a, const PROFILE: bool> Decoder<'a, PROFILE> {
    pub(super) fn new(input: &'a [u8]) -> Result<Self, &'static str> {
        if input.len() < 4 {
            return Err("truncated rANS stream");
        }
        let state = u32::from_le_bytes(input[..4].try_into().map_err(|_| "truncated rANS stream")?);
        if !(LOWER_BOUND..UPPER_BOUND).contains(&state) {
            return Err("invalid rANS initial state");
        }
        Ok(Self {
            input,
            position: 4,
            state,
            bit_calls: 0,
        })
    }

    pub(super) fn bit_calls(&self) -> u64 {
        self.bit_calls
    }

    pub(super) fn input_remaining(&self) -> usize {
        debug_assert!(self.position <= self.input.len());
        self.input.len() - self.position
    }

    #[inline(always)]
    pub(super) fn bit_unchecked(&mut self, zero_probability: u16) -> Result<bool, &'static str> {
        debug_assert!((1..TOTAL as u16).contains(&zero_probability));
        if PROFILE {
            self.bit_calls = self.bit_calls.saturating_add(1);
        }

        let slot = self.state & (TOTAL - 1);
        let zero_probability = u32::from(zero_probability);
        let (bit, start, frequency) = if slot < zero_probability {
            (false, 0, zero_probability)
        } else {
            (true, zero_probability, TOTAL - zero_probability)
        };
        let next =
            u64::from(frequency) * u64::from(self.state >> SCALE_BITS) + u64::from(slot - start);
        if next >= u64::from(UPPER_BOUND) {
            return Err("invalid rANS state transition");
        }
        self.state = next as u32;
        while self.state < LOWER_BOUND {
            let byte = self
                .input
                .get(self.position)
                .copied()
                .ok_or("truncated rANS stream")?;
            self.position += 1;
            self.state = (self.state << 8) | u32::from(byte);
        }
        Ok(bit)
    }

    /// 呼び出し側がtoken単位の最大bit数と入力余裕を証明したfast path。
    ///
    /// # Safety
    /// probabilityが`1..32768`であり、token全体が55 bit以下、呼び出し開始時に
    /// 128 byte以上のrenormalization入力が残ること。遷移ごとの読取りは最大2 byte。
    #[inline(always)]
    pub(super) unsafe fn bit_unchecked_fast(&mut self, zero_probability: u16) -> bool {
        debug_assert!((1..TOTAL as u16).contains(&zero_probability));
        if PROFILE {
            self.bit_calls = self.bit_calls.saturating_add(1);
        }

        let slot = self.state & (TOTAL - 1);
        let zero_probability = u32::from(zero_probability);
        let (bit, start, frequency) = if slot < zero_probability {
            (false, 0, zero_probability)
        } else {
            (true, zero_probability, TOTAL - zero_probability)
        };
        let next = frequency * (self.state >> SCALE_BITS) + slot - start;
        debug_assert!(next < UPPER_BOUND);
        self.state = next;
        while self.state < LOWER_BOUND {
            // SAFETY: bitごとに最大2 byte、最大55 bitで110 byteを超えない。
            let byte = unsafe { *self.input.get_unchecked(self.position) };
            self.position += 1;
            self.state = (self.state << 8) | u32::from(byte);
        }
        bit
    }

    pub(super) fn finish(&self) -> Result<(), &'static str> {
        if self.position != self.input.len() {
            return Err("trailing bytes in rANS stream");
        }
        if self.state != LOWER_BOUND {
            return Err("non-canonical rANS termination");
        }
        Ok(())
    }
}

/// SegmentごとにrANS stateを初期化しつつ適応model順序を維持する研究decoder。
pub(super) struct SegmentedDecoder<'a, const PROFILE: bool = false> {
    input: &'a [u8],
    position: usize,
    total_plain: usize,
    produced_plain: usize,
    current_plain_remaining: usize,
    current: Option<Decoder<'a, PROFILE>>,
    completed_bit_calls: u64,
}

impl<'a, const PROFILE: bool> SegmentedDecoder<'a, PROFILE> {
    pub(super) fn new(input: &'a [u8], total_plain: usize) -> Result<Self, &'static str> {
        if total_plain == 0 {
            if !input.is_empty() {
                return Err("trailing bytes in empty segmented rANS stream");
            }
            return Ok(Self {
                input,
                position: 0,
                total_plain,
                produced_plain: 0,
                current_plain_remaining: 0,
                current: None,
                completed_bit_calls: 0,
            });
        }
        if input.get(..SEGMENT_MAGIC.len()) != Some(SEGMENT_MAGIC.as_slice()) {
            return Err("invalid segmented rANS marker");
        }
        let mut decoder = Self {
            input,
            position: SEGMENT_MAGIC.len(),
            total_plain,
            produced_plain: 0,
            current_plain_remaining: 0,
            current: None,
            completed_bit_calls: 0,
        };
        decoder.load_segment()?;
        Ok(decoder)
    }

    fn load_segment(&mut self) -> Result<(), &'static str> {
        if self.current.is_some() || self.produced_plain >= self.total_plain {
            return Err("invalid rANS segment transition");
        }
        let header_end = self
            .position
            .checked_add(SEGMENT_HEADER_BYTES)
            .ok_or("rANS segment offset overflow")?;
        let header = self
            .input
            .get(self.position..header_end)
            .ok_or("truncated rANS segment header")?;
        let plain_len = u32::from_le_bytes(
            header[..4]
                .try_into()
                .map_err(|_| "truncated rANS segment header")?,
        ) as usize;
        let compressed_len = u32::from_le_bytes(
            header[4..]
                .try_into()
                .map_err(|_| "truncated rANS segment header")?,
        ) as usize;
        if plain_len == 0
            || plain_len > MAX_SEGMENT_PLAIN
            || plain_len > self.total_plain - self.produced_plain
            || compressed_len < 4
        {
            return Err("invalid rANS segment length");
        }
        self.position = header_end;
        let stream_end = self
            .position
            .checked_add(compressed_len)
            .ok_or("rANS segment offset overflow")?;
        let stream = self
            .input
            .get(self.position..stream_end)
            .ok_or("truncated rANS segment")?;
        self.current = Some(Decoder::new(stream)?);
        self.current_plain_remaining = plain_len;
        self.position = stream_end;
        Ok(())
    }

    pub(super) fn advance_output(&mut self, plain_bytes: usize) -> Result<(), &'static str> {
        if plain_bytes == 0 || plain_bytes > self.current_plain_remaining {
            return Err("token crosses rANS segment boundary");
        }
        self.current_plain_remaining -= plain_bytes;
        self.produced_plain = self
            .produced_plain
            .checked_add(plain_bytes)
            .ok_or("rANS output length overflow")?;
        if self.current_plain_remaining == 0 {
            let current = self.current.take().ok_or("missing rANS segment state")?;
            current.finish()?;
            self.completed_bit_calls = self.completed_bit_calls.saturating_add(current.bit_calls());
            if self.produced_plain == self.total_plain {
                if self.position != self.input.len() {
                    return Err("trailing bytes in segmented rANS stream");
                }
            } else {
                self.load_segment()?;
            }
        }
        Ok(())
    }

    pub(super) fn bit_calls(&self) -> u64 {
        self.completed_bit_calls.saturating_add(
            self.current
                .as_ref()
                .map_or(0, |decoder| decoder.bit_calls()),
        )
    }

    pub(super) fn input_remaining(&self) -> usize {
        self.current
            .as_ref()
            .map_or(0, |decoder| decoder.input_remaining())
    }

    pub(super) fn bit(&mut self, zero_probability: u16) -> Result<bool, &'static str> {
        self.current
            .as_mut()
            .ok_or("missing rANS segment state")?
            .bit_unchecked(zero_probability)
    }

    /// 呼び出し側のtoken最大長と入力余裕の証明は、現在のsegment内で満たすこと。
    ///
    /// # Safety
    /// probabilityは1..32768、tokenは55 bit以下、開始時に同じsegmentの入力が128 byte以上残る。
    pub(super) unsafe fn bit_unchecked_fast(&mut self, zero_probability: u16) -> bool {
        // SAFETY: DecoderSourceは現在のsegment内の入力余裕を返す。
        unsafe {
            self.current
                .as_mut()
                .expect("missing rANS segment state")
                .bit_unchecked_fast(zero_probability)
        }
    }

    pub(super) fn finish(&self) -> Result<(), &'static str> {
        if self.produced_plain != self.total_plain
            || self.current.is_some()
            || self.current_plain_remaining != 0
            || self.position != self.input.len()
        {
            return Err("incomplete segmented rANS stream");
        }
        Ok(())
    }
}
