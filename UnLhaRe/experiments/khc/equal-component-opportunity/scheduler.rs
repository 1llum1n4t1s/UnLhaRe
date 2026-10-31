//! 過去のlight gainによる停止・再開。未学習prefixだけをheavyへreplayする。
#[path = "../bayes-dominant-q15/bayes_model.rs"]
mod bayes_model;
#[path = "heavy.rs"]
mod heavy;
#[path = "../light-compact-path/light.rs"]
mod light;

type Result<T> = super::Result<T>;
fn filled<T: Clone>(length: usize, value: T) -> Result<Vec<T>> {
    super::filled(length, value)
}
const CLASSES: usize = 7;
const CONFIDENCE: f64 = 64.0;
#[cfg(not(khc_scheduler_small_journal))]
const MAX_RECORDS: usize = 8 * 1024 * 1024;
#[cfg(khc_scheduler_small_journal)]
const MAX_RECORDS: usize = 64;

#[derive(Clone, Copy)]
#[repr(C)]
struct Record {
    primary: u16,
    bit: bool,
}
const _: () = assert!(std::mem::size_of::<Record>() == 4);

pub(super) struct Prediction {
    class: u32,
    generation: u64,
    primary: u16,
    zero: u16,
    light: light::Prediction,
    light_mix: bayes_model::Prediction,
    heavy: Option<(heavy::Prediction, bayes_model::Prediction)>,
    #[cfg(khc_scheduler_reference)]
    reference: (heavy::Prediction, bayes_model::Prediction),
}
impl Prediction {
    pub(super) fn zero(&self) -> u16 {
        self.zero
    }
}

#[derive(Clone, Copy)]
pub(super) struct Audit {
    events: [u64; CLASSES],
    processed: [u64; CLASSES],
    replayed: [u64; CLASSES],
    active_events: [u64; CLASSES],
    activations: [u64; CLASSES],
    deactivations: [u64; CLASSES],
    forced: [u64; CLASSES],
    reference_checks: [u64; CLASSES],
    pending: [usize; CLASSES],
    reserved_records: usize,
    peak_reserved_records: usize,
}
impl Audit {
    pub(super) fn json(&self) -> String {
        format!(
            "{{\"events\":{:?},\"processed\":{:?},\"replayed\":{:?},\"active_events\":{:?},\"activations\":{:?},\"deactivations\":{:?},\"forced\":{:?},\"reference_checks\":{:?},\"pending\":{:?},\"reserved_records\":{},\"peak_reserved_records\":{},\"maximum_records\":{}}}",
            self.events,
            self.processed,
            self.replayed,
            self.active_events,
            self.activations,
            self.deactivations,
            self.forced,
            self.reference_checks,
            self.pending,
            self.reserved_records,
            self.peak_reserved_records,
            MAX_RECORDS
        )
    }
}

pub(super) struct Model {
    light: light::Model,
    light_mix: bayes_model::Model,
    heavy: Option<heavy::Model>,
    heavy_mix: bayes_model::Model,
    journals: [Vec<Record>; CLASSES],
    active: [bool; CLASSES],
    generation: u64,
    poisoned: bool,
    ready: bool,
    audit: Audit,
    #[cfg(khc_scheduler_reference)]
    reference: heavy::Model,
    #[cfg(khc_scheduler_reference)]
    reference_mix: bayes_model::Model,
}
impl Model {
    pub(super) fn new() -> Result<Self> {
        Ok(Self {
            light: light::Model::new()?,
            light_mix: bayes_model::Model::new()?,
            heavy: None,
            heavy_mix: bayes_model::Model::new()?,
            journals: std::array::from_fn(|_| Vec::new()),
            active: [false; CLASSES],
            generation: 0,
            poisoned: false,
            ready: false,
            audit: Audit {
                events: [0; CLASSES],
                processed: [0; CLASSES],
                replayed: [0; CLASSES],
                active_events: [0; CLASSES],
                activations: [0; CLASSES],
                deactivations: [0; CLASSES],
                forced: [0; CLASSES],
                reference_checks: [0; CLASSES],
                pending: [0; CLASSES],
                reserved_records: 0,
                peak_reserved_records: 0,
            },
            #[cfg(khc_scheduler_reference)]
            reference: heavy::Model::new()?,
            #[cfg(khc_scheduler_reference)]
            reference_mix: bayes_model::Model::new()?,
        })
    }
    pub(super) fn audit(&self) -> Audit {
        let mut result = self.audit;
        result.pending = std::array::from_fn(|i| self.journals[i].len());
        result
    }
    fn validate(&self, class: usize) -> Result<()> {
        let pending = self.journals[class].len() as u64;
        if self.audit.processed[class].checked_add(pending) != Some(self.audit.events[class])
            || self.audit.replayed[class].checked_add(self.audit.active_events[class])
                != Some(self.audit.processed[class])
            || (self.active[class] && pending != 0)
            || self.audit.reserved_records > MAX_RECORDS
        {
            return Err("scheduler prefix/accounting mismatch".into());
        }
        Ok(())
    }
    fn next_capacity(&self, class: usize) -> Result<usize> {
        let capacity = self.journals[class].capacity();
        if capacity == 0 {
            Ok(1024.min(MAX_RECORDS))
        } else {
            capacity
                .checked_mul(2)
                .ok_or("journal growth overflow".into())
        }
    }
    fn needs_force(&self, class: usize) -> Result<bool> {
        let journal = &self.journals[class];
        if journal.len() != journal.capacity() {
            return Ok(false);
        }
        let extra = self.next_capacity(class)? - journal.capacity();
        Ok(self
            .audit
            .reserved_records
            .checked_add(extra)
            .ok_or("journal budget overflow")?
            > MAX_RECORDS)
    }
    fn reserve_record(&mut self, class: usize) -> Result<()> {
        if self.journals[class].len() != self.journals[class].capacity() {
            return Ok(());
        }
        let target = self.next_capacity(class)?;
        let journal = &mut self.journals[class];
        if journal.len() == journal.capacity() {
            let old = journal.capacity();
            if self
                .audit
                .reserved_records
                .checked_add(target - old)
                .ok_or("journal capacity overflow")?
                > MAX_RECORDS
            {
                return Err("journal capacity outside budget".into());
            }
            journal
                .try_reserve_exact(target - journal.len())
                .map_err(|_| "journal allocation failed")?;
            if journal.capacity() != target {
                return Err(
                    "journal allocator capacity differs from deterministic schedule".into(),
                );
            }
            self.audit.reserved_records += target - old;
            self.audit.peak_reserved_records = self
                .audit
                .peak_reserved_records
                .max(self.audit.reserved_records);
        }
        Ok(())
    }
    fn activate(&mut self, class: usize) -> Result<()> {
        if self.heavy.is_none() {
            self.heavy = Some(heavy::Model::new()?);
        }
        let records = std::mem::take(&mut self.journals[class]);
        self.audit.reserved_records = self
            .audit
            .reserved_records
            .checked_sub(records.capacity())
            .ok_or("journal release underflow")?;
        let model = self.heavy.as_mut().ok_or("heavy model absent")?;
        for record in &records {
            let p = model.predict(class as u32)?;
            let mixture = self
                .heavy_mix
                .predict(class as u32, record.primary, p.zero())?;
            self.heavy_mix.update(class as u32, &mixture, record.bit)?;
            model.update(class as u32, &p, record.bit)?;
            self.audit.processed[class] += 1;
            self.audit.replayed[class] += 1;
        }
        drop(records);
        self.active[class] = true;
        self.audit.activations[class] += 1;
        self.validate(class)
    }
    pub(super) fn predict(&mut self, class: u32, primary: u16) -> Result<Prediction> {
        if self.poisoned {
            return Err("scheduler poisoned".into());
        }
        let result = self.predict_impl(class, primary);
        self.ready = result.is_ok();
        if result.is_err() {
            self.poisoned = true;
        }
        result
    }
    fn predict_impl(&mut self, class: u32, primary: u16) -> Result<Prediction> {
        let c = class as usize;
        if c >= CLASSES || !(1..32768).contains(&primary) {
            return Err("scheduler class/probability outside bounds".into());
        }
        self.validate(c)?;
        self.generation = self
            .generation
            .checked_add(1)
            .ok_or("scheduler generation overflow")?;
        let gain = self.light_mix.gain(class)?;
        if self.active[c] && gain <= -CONFIDENCE {
            self.active[c] = false;
            self.audit.deactivations[c] += 1;
        }
        let forced = !self.active[c] && self.needs_force(c)?;
        if !self.active[c] && (gain >= CONFIDENCE || forced) {
            if forced {
                self.audit.forced[c] += 1;
            }
            self.activate(c)?;
        }
        if !self.active[c] {
            self.reserve_record(c)?;
        }
        let light = self.light.predict(class)?;
        let light_mix = self.light_mix.predict(class, primary, light.zero())?;
        let heavy = if self.active[c] {
            let p = self
                .heavy
                .as_ref()
                .ok_or("heavy model absent")?
                .predict(class)?;
            let mix = self.heavy_mix.predict(class, primary, p.zero())?;
            Some((p, mix))
        } else {
            None
        };
        #[cfg(khc_scheduler_reference)]
        let reference = {
            let p = self.reference.predict(class)?;
            let mix = self.reference_mix.predict(class, primary, p.zero())?;
            if let Some((hp, hm)) = &heavy {
                if hp.zero() != p.zero() || hm.zero() != mix.zero() {
                    return Err("heavy replay differs from continuous reference".into());
                }
                self.audit.reference_checks[c] += 1;
            }
            (p, mix)
        };
        let zero = heavy
            .as_ref()
            .map_or_else(|| light_mix.zero(), |(_, mix)| mix.zero());
        Ok(Prediction {
            class,
            generation: self.generation,
            primary,
            zero,
            light,
            light_mix,
            heavy,
            #[cfg(khc_scheduler_reference)]
            reference,
        })
    }
    pub(super) fn update(&mut self, class: u32, prediction: &Prediction, bit: bool) -> Result<()> {
        if self.poisoned {
            return Err("scheduler poisoned".into());
        }
        let result = self.update_impl(class, prediction, bit);
        if result.is_err() {
            self.poisoned = true;
        }
        result
    }
    fn update_impl(&mut self, class: u32, p: &Prediction, bit: bool) -> Result<()> {
        if !self.ready
            || class as usize >= CLASSES
            || p.class != class
            || p.generation != self.generation
        {
            return Err("scheduler stale/class prediction".into());
        }
        let c = class as usize;
        self.validate(c)?;
        if self.active[c] != p.heavy.is_some() {
            return Err("scheduler prediction mode mismatch".into());
        }
        self.ready = false;
        self.light_mix.update(class, &p.light_mix, bit)?;
        self.light.update(class, &p.light, bit)?;
        if let Some((prediction, mixture)) = &p.heavy {
            self.heavy_mix.update(class, mixture, bit)?;
            self.heavy
                .as_mut()
                .ok_or("heavy model absent")?
                .update(class, prediction, bit)?;
            self.audit.processed[c] += 1;
            self.audit.active_events[c] += 1;
        } else {
            if self.journals[c].len() == self.journals[c].capacity() {
                return Err("journal slot not reserved before coding".into());
            }
            self.journals[c].push(Record {
                primary: p.primary,
                bit,
            });
        }
        #[cfg(khc_scheduler_reference)]
        {
            self.reference_mix.update(class, &p.reference.1, bit)?;
            self.reference.update(class, &p.reference.0, bit)?;
        }
        self.audit.events[c] = self.audit.events[c]
            .checked_add(1)
            .ok_or("scheduler event overflow")?;
        self.validate(c)
    }
}

#[cfg(khc_compact_counts)]
pub(super) fn compact_counts_json() -> String {
    let counts = heavy::compact_counts_json();
    let prefix = counts.strip_suffix('}').expect("compact diagnostic JSON suffix");
    format!("{},\"light_prediction_bytes\":{},\"scheduler_prediction_bytes\":{}}}",
        prefix, std::mem::size_of::<light::Prediction>(), std::mem::size_of::<Prediction>())
}

#[cfg(khc_equal_component_counts)]
pub(super) fn equal_counts_json() -> String {
    heavy::equal_component_counts_json()
}
