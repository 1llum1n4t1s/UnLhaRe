//! 凍結bayes_probe.rsのcomponent累積尤度・安定exp2・Q15式を抽出。
//! classごとにprior1/2。混合自体の診断lossやauxwriterは持たない。
type Result<T> = super::Result<T>;
const CLASSES: usize = 7;

#[derive(Clone, Copy, Default)]
struct Class {
    primary: f64,
    cts: f64,
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

pub(super) struct Prediction {
    primary: u16,
    cts: u16,
    zero: u16,
}
impl Prediction {
    pub(super) fn zero(&self) -> u16 {
        self.zero
    }
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
            primary: primary_zero,
            cts: cts_zero,
            zero,
        })
    }
    fn observe(&mut self, prediction: &Prediction, bit: bool, log2: &[f64]) -> Result<()> {
        fn add(total: &mut f64, zero: u16, bit: bool, log2: &[f64]) -> Result<()> {
            let observed = if bit { 32768 - zero } else { zero };
            *total -= log2[usize::from(observed)];
            if !total.is_finite() || *total < 0.0 {
                return Err("Bayes loss not finite/nonnegative".into());
            }
            Ok(())
        }
        add(&mut self.primary, prediction.primary, bit, log2)?;
        add(&mut self.cts, prediction.cts, bit, log2)?;
        Ok(())
    }
}

pub(super) struct Model {
    classes: [Class; CLASSES],
    log2: Vec<f64>,
}
impl Model {
    pub(super) fn new() -> Result<Self> {
        let mut log2 = Vec::new();
        log2.try_reserve_exact(32768)
            .map_err(|_| "Bayes log2 allocation failed")?;
        log2.resize(32768, 0.0);
        for q in 1_u16..32768 {
            log2[usize::from(q)] = (f64::from(q) / 32768.0).log2();
        }
        Ok(Self {
            classes: [Class::default(); CLASSES],
            log2,
        })
    }
    // 数値監査だけで実際のcomponent表値を取得する。
    #[cfg(khc_bayes_lut_audit)]
    pub(super) fn component_log2(&self, prediction: &Prediction, bit: bool) -> (f64, f64) {
        let index = |q: u16| usize::from(if bit { 32768 - q } else { q });
        (
            self.log2[index(prediction.primary)],
            self.log2[index(prediction.cts)],
        )
    }

    pub(super) fn gain(&self, class: u32) -> Result<f64> {
        let state = self.classes.get(class as usize).ok_or("Bayes class outside bounds")?;
        let gain = state.primary - state.cts;
        if !gain.is_finite() {
            return Err("Bayes gain not finite".into());
        }
        Ok(gain)
    }

    pub(super) fn predict(&self, class: u32, primary: u16, cts: u16) -> Result<Prediction> {
        self.classes
            .get(class as usize)
            .ok_or("Bayes class outside bounds")?
            .predict(primary, cts)
    }
    pub(super) fn update(&mut self, class: u32, prediction: &Prediction, bit: bool) -> Result<()> {
        self.classes
            .get_mut(class as usize)
            .ok_or("Bayes class outside bounds")?
            .observe(prediction, bit, &self.log2)
    }
}

