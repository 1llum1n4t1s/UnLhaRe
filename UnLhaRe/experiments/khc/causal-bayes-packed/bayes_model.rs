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
    primary: f64,
    cts: f64,
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
        Ok(Prediction { primary, cts, zero })
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
        Ok(())
    }
}

pub(super) struct Model {
    classes: [Class; CLASSES],
}
impl Model {
    pub(super) fn new() -> Self {
        Self {
            classes: [Class::default(); CLASSES],
        }
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
            .observe(prediction, bit)
    }
}
