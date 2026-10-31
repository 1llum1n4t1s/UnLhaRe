//! 観測前Q15 component確率だけを使う、class独立の因果的Bayes診断。
use std::cell::RefCell;
use std::fmt::Write;

type Result<T> = super::Result<T>;
const CLASSES: usize = 7;
const TOLERANCE: f64 = 1e-4;

#[derive(Clone, Copy, Default)]
struct Class {
    bits: u64,
    primary: f64,
    cts: f64,
    raw: f64,
    q15: f64,
}

// loss差を保持し、exp2のunderflowでcomponentを不可逆に捨てない。
fn posterior(primary: f64, cts: f64) -> f64 {
    let small = (-(primary - cts).abs()).exp2();
    if primary <= cts {
        1.0 / (1.0 + small)
    } else {
        small / (1.0 + small)
    }
}

fn closed_form(class: Class) -> f64 {
    class.primary.min(class.cts) + 1.0 - (1.0 + (-(class.primary - class.cts).abs()).exp2()).log2()
}

struct Prediction {
    primary: f64,
    cts: f64,
    raw: f64,
    zero: u16,
}

impl Class {
    // 現bitを引数に持たない。component値はいずれも更新前に凍結済み。
    fn predict(&self, primary_zero: u16, cts_zero: u16) -> Result<Prediction> {
        if !(1..32768).contains(&primary_zero) || !(1..32768).contains(&cts_zero) {
            return Err("Bayes component Q15 outside bounds".into());
        }
        let primary = f64::from(primary_zero) / 32768.0;
        let cts = f64::from(cts_zero) / 32768.0;
        let weight = posterior(self.primary, self.cts);
        let raw = weight * primary + (1.0 - weight) * cts;
        if !raw.is_finite() || !(0.0..1.0).contains(&raw) {
            return Err("Bayes mixture probability outside bounds".into());
        }
        let zero = (raw * 32768.0 + 0.5).floor().clamp(1.0, 32767.0) as u16;
        Ok(Prediction {
            primary,
            cts,
            raw,
            zero,
        })
    }

    fn observe(&mut self, prediction: &Prediction, bit: bool) -> Result<()> {
        fn add(total: &mut f64, zero: f64, bit: bool) -> Result<()> {
            let observed = if bit { 1.0 - zero } else { zero };
            *total -= observed.log2();
            if !total.is_finite() || *total < 0.0 {
                return Err("Bayes loss not finite/nonnegative".into());
            }
            Ok(())
        }
        add(&mut self.primary, prediction.primary, bit)?;
        add(&mut self.cts, prediction.cts, bit)?;
        add(&mut self.raw, prediction.raw, bit)?;
        add(&mut self.q15, f64::from(prediction.zero) / 32768.0, bit)?;
        self.bits = self.bits.checked_add(1).ok_or("Bayes bit count overflow")?;
        Ok(())
    }
}

struct Checks {
    cases: usize,
    checks: usize,
    max_error: f64,
}

fn self_checks() -> Result<Checks> {
    let mut checks = Checks {
        cases: 0,
        checks: 0,
        max_error: 0.0,
    };
    // 各短列についてcomponent積を独立列挙。posterior実装や閉形式をoracleに使わない。
    for length in 0..=6 {
        for sequence in 0..1_usize << length {
            let mut class = Class::default();
            let mut products = [1.0_f64; 2];
            for index in 0..length {
                let zeros = [[1, 32767], [8192, 24576], [16384, 16384]][index % 3];
                let prediction = class.predict(zeros[0], zeros[1])?;
                let oracle = (products[0] * f64::from(zeros[0])
                    + products[1] * f64::from(zeros[1]))
                    / ((products[0] + products[1]) * 32768.0);
                let error = (oracle - prediction.raw).abs();
                checks.max_error = checks.max_error.max(error);
                if error > 1e-12 {
                    return Err("Bayes prequential independent product mismatch".into());
                }
                let bit = sequence & (1 << index) != 0;
                for (product, zero) in products.iter_mut().zip(zeros) {
                    *product *= f64::from(if bit { 32768 - zero } else { zero }) / 32768.0;
                }
                class.observe(&prediction, bit)?;
                let expected_loss = -((products[0] + products[1]) / 2.0).log2();
                let error = (expected_loss - class.raw).abs();
                checks.max_error = checks.max_error.max(error);
                if error > 1e-10 || (closed_form(class) - class.raw).abs() > 1e-10 {
                    return Err("Bayes independent product loss mismatch".into());
                }
                checks.checks += 3;
            }
            checks.cases += 1;
        }
    }
    let mut classes = [Class::default(); CLASSES];
    let prediction = classes[3].predict(8192, 24576)?;
    classes[3].observe(&prediction, false)?;
    for (index, class) in classes.iter().enumerate() {
        if index != 3 && (class.bits != 0 || posterior(class.primary, class.cts) != 0.5) {
            return Err("Bayes class isolation mismatch".into());
        }
        checks.checks += 1;
    }
    checks.cases += 1;
    let mut recovery = Class::default();
    for _ in 0..2000 {
        let prediction = recovery.predict(1, 32767)?;
        recovery.observe(&prediction, false)?;
    }
    if posterior(recovery.primary, recovery.cts) != 0.0 {
        return Err("Bayes underflow check did not reach underflow".into());
    }
    for _ in 0..4000 {
        let prediction = recovery.predict(1, 32767)?;
        recovery.observe(&prediction, true)?;
    }
    if posterior(recovery.primary, recovery.cts) != 1.0
        || (recovery.raw - closed_form(recovery)).abs() > TOLERANCE
    {
        return Err("Bayes posterior did not recover after underflow".into());
    }
    checks.checks += 3;
    checks.cases += 1;
    Ok(checks)
}

struct State {
    classes: [Class; CLASSES],
    writer: Option<super::range::Encoder>,
    total_bits: u64,
    checks: Checks,
}

impl State {
    fn new() -> Result<Self> {
        let checks = self_checks()?;
        Ok(Self {
            classes: [Class::default(); CLASSES],
            writer: Some(super::range::Encoder::with_limit(super::MAX_PAYLOAD)?),
            total_bits: 0,
            checks,
        })
    }

    fn record(&mut self, class: u32, primary: u16, cts: u16, bit: bool) -> Result<()> {
        let class = self
            .classes
            .get_mut(class as usize)
            .ok_or("Bayes class outside bounds")?;
        let prediction = class.predict(primary, cts)?;
        self.writer
            .as_mut()
            .ok_or("Bayes writer already finished")?
            .bit(prediction.zero, bit)?;
        class.observe(&prediction, bit)?;
        self.total_bits = self
            .total_bits
            .checked_add(1)
            .ok_or("Bayes total count overflow")?;
        Ok(())
    }

    fn finish_json(&mut self, order: &[u16]) -> Result<String> {
        let metadata = super::packed_alphabet::encode(order)?;
        if super::packed_alphabet::decode(&metadata)? != order {
            return Err("Bayes packed alphabet roundtrip mismatch".into());
        }
        let packed = super::packed_alphabet::report_json(order)?;
        let mut json = String::from("[");
        let mut totals = Class::default();
        let mut closed_total = 0.0;
        let mut max_error = 0.0_f64;
        for (index, class) in self.classes.iter().copied().enumerate() {
            let closed = closed_form(class);
            let error = (closed - class.raw).abs();
            if !closed.is_finite() || error > TOLERANCE {
                return Err("Bayes class closed form mismatch".into());
            }
            max_error = max_error.max(error);
            totals.bits = totals
                .bits
                .checked_add(class.bits)
                .ok_or("Bayes aggregate count overflow")?;
            totals.primary += class.primary;
            totals.cts += class.cts;
            totals.raw += class.raw;
            totals.q15 += class.q15;
            closed_total += closed;
            if index != 0 {
                json.push(',');
            }
            let primary = posterior(class.primary, class.cts);
            write!(json, "{{\"class\":{index},\"bits\":{},\"primary_q15_ideal_bits\":{:.12},\"cts_q15_ideal_bits\":{:.12},\"raw_ideal_bits\":{:.12},\"q15_ideal_bits\":{:.12},\"closed_form_ideal_bits\":{closed:.12},\"closed_form_abs_error\":{error:.12},\"posterior_primary\":{primary:.16},\"posterior_cts\":{:.16}}}", class.bits, class.primary, class.cts, class.raw, class.q15, 1.0-primary).map_err(|_| "Bayes JSON formatting failed")?;
        }
        json.push(']');
        let total_error = (totals.raw - closed_total).abs();
        if totals.bits != self.total_bits
            || total_error > TOLERANCE
            || ![
                totals.primary,
                totals.cts,
                totals.raw,
                totals.q15,
                closed_total,
            ]
            .iter()
            .all(|n| n.is_finite())
        {
            return Err("Bayes aggregate finite/count/closed form mismatch".into());
        }
        let payload_bytes = self
            .writer
            .take()
            .ok_or("Bayes writer already finished")?
            .finish()?
            .len();
        if payload_bytes > super::MAX_PAYLOAD {
            return Err("Bayes payload capacity exceeded".into());
        }
        let estimated_frame_bytes = payload_bytes
            .checked_add(36)
            .and_then(|n| n.checked_add(metadata.len()))
            .ok_or("Bayes frame length overflow")?;
        Ok(format!("{{\"prior_primary\":0.5,\"prior_cts\":0.5,\"state_class_capacity\":{CLASSES},\"total_bits_calls\":{},\"classes\":{json},\"primary_q15_ideal_bits_total\":{:.12},\"cts_q15_ideal_bits_total\":{:.12},\"raw_ideal_bits_total\":{:.12},\"q15_ideal_bits_total\":{:.12},\"closed_form_ideal_bits_total\":{closed_total:.12},\"closed_form_abs_error_total\":{total_error:.12},\"max_class_closed_form_abs_error\":{max_error:.12},\"payload_bytes\":{payload_bytes},\"estimated_frame_bytes\":{estimated_frame_bytes},\"payload_limit_bytes\":{},\"terminal\":true,\"flush_count\":1,\"finite_losses\":true,\"packed_alphabet\":{packed},\"self_checks\":{{\"passed\":true,\"cases\":{},\"checks\":{},\"max_abs_error\":{:.16},\"underflow_recovery\":true,\"class_isolation\":true}}}}", totals.bits, totals.primary, totals.cts, totals.raw, totals.q15, super::MAX_PAYLOAD, self.checks.cases, self.checks.checks, self.checks.max_error))
    }
}

thread_local! { static STATE: RefCell<Option<State>> = const { RefCell::new(None) }; }

pub(super) fn record(class: u32, primary: u16, cts: u16, bit: bool) -> Result<()> {
    STATE.with(|state| {
        let mut state = state.borrow_mut();
        if state.is_none() {
            *state = Some(State::new()?);
        }
        state
            .as_mut()
            .ok_or("Bayes state missing")?
            .record(class, primary, cts, bit)
    })
}

pub(super) fn finish_json(order: &[u16]) -> Result<String> {
    STATE.with(|state| {
        state
            .borrow_mut()
            .as_mut()
            .ok_or("Bayes state missing")?
            .finish_json(order)
    })
}
