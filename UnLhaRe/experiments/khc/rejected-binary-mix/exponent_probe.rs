//! 復号済み指数だけを仮数nodeへ加える独立shadow。元Model実装を共用する。
use std::cell::RefCell;
use std::fmt::Write;

#[derive(Clone, Copy, Default)]
struct ClassLoss {
    bits: u64,
    ideal_bits: f64,
}

struct State {
    model: super::Model,
    writer: Option<super::range::Encoder>,
    classes: [ClassLoss; 7],
}

impl State {
    fn new() -> super::Result<Self> {
        Ok(Self {
            model: super::Model::new()?,
            writer: Some(super::range::Encoder::with_limit(super::MAX_PAYLOAD)?),
            classes: [ClassLoss::default(); 7],
        })
    }

    fn record(&mut self, symbol: u16, node: u32, known_e: usize, bit: bool) -> super::Result<()> {
        let class = (node >> 28) as usize;
        if symbol > 256 || class >= 7 {
            return Err("exponent diagnostic symbol/class outside bounds".into());
        }
        let added = if class == 3 || class == 6 {
            let max_e = if class == 3 { 8 } else { 23 };
            let position = ((node >> 12) & 31) as usize;
            if known_e == 0 || known_e > max_e || position >= known_e {
                return Err("exponent diagnostic mantissa exponent/position outside bounds".into());
            }
            if node & (0x0f00 | (1 << 17)) != 0 {
                return Err("exponent diagnostic exponent field overlaps node".into());
            }
            ((known_e as u32 & 15) << 8) | ((known_e as u32 & 16) << 13)
        } else {
            if known_e != 0 {
                return Err("exponent diagnostic non-mantissa exponent must be zero".into());
            }
            0
        };
        let prediction = self.model.predict(symbol, node | added);
        let zero = ((4096 - prediction.p) * 8) as u16;
        let observed = if bit {
            32768 - u32::from(zero)
        } else {
            u32::from(zero)
        };
        if !(1..32768).contains(&observed) {
            return Err("exponent diagnostic probability outside bounds".into());
        }
        let loss = -(f64::from(observed) / 32768.0).log2();
        let ideal_bits = self.classes[class].ideal_bits + loss;
        if !ideal_bits.is_finite() || loss < 0.0 {
            return Err("exponent diagnostic loss not finite/nonnegative".into());
        }
        let bits = self.classes[class]
            .bits
            .checked_add(1)
            .ok_or("exponent diagnostic count overflow")?;
        // 同じ実bitを符号化後、元と同じModel::updateでshadowだけを更新する。
        self.writer
            .as_mut()
            .ok_or("exponent diagnostic writer already finished")?
            .bit(zero, bit)?;
        self.classes[class] = ClassLoss { bits, ideal_bits };
        self.model.update(prediction, bit);
        Ok(())
    }

    fn run_done(&mut self, symbol: u16, rank: usize, length: usize) -> super::Result<()> {
        if symbol > 256 || rank > 256 || length == 0 || length > super::MAX_INPUT + 1 {
            return Err("exponent diagnostic run/history outside bounds".into());
        }
        // history-only共通methodなのでrank診断を二重に記録しない。
        self.model.history_done(symbol, rank, length);
        Ok(())
    }

    fn finish_json(&mut self, alphabet: usize) -> super::Result<String> {
        if !(1..=257).contains(&alphabet) {
            return Err("exponent diagnostic alphabet outside bounds".into());
        }
        let mut bits = 0_u64;
        let mut ideal = 0.0;
        let mut classes = String::from("[");
        for (class, loss) in self.classes.iter().enumerate() {
            bits = bits
                .checked_add(loss.bits)
                .ok_or("exponent diagnostic total count overflow")?;
            ideal += loss.ideal_bits;
            if class != 0 {
                classes.push(',');
            }
            let _ = write!(
                classes,
                "{{\"class\":{class},\"bits\":{},\"ideal_bits\":{:.12}}}",
                loss.bits, loss.ideal_bits
            );
        }
        if !ideal.is_finite() || ideal < 0.0 {
            return Err("exponent diagnostic total loss not finite/nonnegative".into());
        }
        classes.push(']');
        let payload_bytes = self
            .writer
            .take()
            .ok_or("exponent diagnostic writer already finished")?
            .finish()?
            .len();
        let header_bytes = 36_usize
            .checked_add(
                alphabet
                    .checked_mul(2)
                    .ok_or("exponent diagnostic alphabet overflow")?,
            )
            .ok_or("exponent diagnostic header overflow")?;
        let estimated_frame_bytes = payload_bytes
            .checked_add(header_bytes)
            .ok_or("exponent diagnostic frame overflow")?;
        Ok(format!(
            "{{\"classes\":{classes},\"total_bits_calls\":{bits},\"ideal_bits_total\":{ideal:.12},\"payload_bytes\":{payload_bytes},\"estimated_frame_bytes\":{estimated_frame_bytes}}}"
        ))
    }
}

thread_local! { static STATE: RefCell<Option<State>> = const { RefCell::new(None) }; }

pub(super) fn record(symbol: u16, node: u32, known_e: usize, bit: bool) -> super::Result<()> {
    STATE.with(|state| {
        let mut state = state.borrow_mut();
        if state.is_none() {
            *state = Some(State::new()?);
        }
        state
            .as_mut()
            .ok_or("exponent diagnostic state missing")?
            .record(symbol, node, known_e, bit)
    })
}

pub(super) fn run_done(symbol: u16, rank: usize, length: usize) -> super::Result<()> {
    STATE.with(|state| {
        state
            .borrow_mut()
            .as_mut()
            .ok_or("exponent diagnostic state missing")?
            .run_done(symbol, rank, length)
    })
}

pub(super) fn finish_json(alphabet: usize) -> super::Result<String> {
    STATE.with(|state| {
        state
            .borrow_mut()
            .as_mut()
            .ok_or("exponent diagnostic state missing")?
            .finish_json(alphabet)
    })
}
