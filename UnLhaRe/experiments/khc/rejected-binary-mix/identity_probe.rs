//! 既存XOR済みu32 keyのslot aliasだけを除く反実仮想診断。
//! mapのseedや走査順は予測に使わず、各keyのlookupと観測bitだけで状態を更新する。

use std::cell::RefCell;
use std::collections::HashMap;
use std::fmt::Write;

const MAX_KEYS: usize = 2_000_000;
const SLOTS: [usize; 4] = [1 << 12, 1 << 18, 1 << 18, 1 << 18];

#[derive(Clone, Copy, Default)]
struct ClassLoss {
    bits: u64,
    ideal_bits: f64,
}

struct State {
    maps: [HashMap<u32, super::Bernoulli>; 4],
    occupied: [Vec<bool>; 4],
    occupied_counts: [usize; 4],
    total_keys: usize,
    weights: [i32; 4],
    calibration: [super::Bernoulli; 129],
    classes: [ClassLoss; 7],
    writer: Option<super::range::Encoder>,
}

impl State {
    fn new() -> super::Result<Self> {
        Ok(Self {
            maps: std::array::from_fn(|_| HashMap::new()),
            occupied: [
                super::filled(SLOTS[0], false)?,
                super::filled(SLOTS[1], false)?,
                super::filled(SLOTS[2], false)?,
                super::filled(SLOTS[3], false)?,
            ],
            occupied_counts: [0; 4],
            total_keys: 0,
            weights: [16384; 4],
            calibration: std::array::from_fn(|i| super::Bernoulli::fresh(i as i32 * 32)),
            classes: [ClassLoss::default(); 7],
            writer: Some(super::range::Encoder::with_limit(super::MAX_PAYLOAD)?),
        })
    }

    fn record(
        &mut self,
        keys: [u32; 4],
        class: usize,
        logit: &[i32],
        sigmoid: &[i32],
        bit: bool,
    ) -> super::Result<()> {
        if class >= self.classes.len() {
            return Err("identity diagnostic class outside bounds".into());
        }
        let missing = std::array::from_fn::<_, 4, _>(|i| !self.maps[i].contains_key(&keys[i]));
        let added = missing.iter().filter(|&&v| v).count();
        let new_total = self
            .total_keys
            .checked_add(added)
            .ok_or("identity diagnostic key count overflow")?;
        if new_total > MAX_KEYS {
            return Err("identity diagnostic distinct key limit exceeded".into());
        }
        // 全reserveの成功を確認後に新keyを登録する。確率はmapのcapacityに依存しない。
        for (map, &new_key) in self.maps.iter_mut().zip(&missing) {
            if new_key {
                map.try_reserve(1)
                    .map_err(|_| "identity diagnostic map allocation failed")?;
            }
        }
        for i in 0..4 {
            if missing[i] {
                self.maps[i].insert(keys[i], super::Bernoulli::fresh(2048));
                let slot = super::hash(keys[i]) & (SLOTS[i] - 1);
                if !self.occupied[i][slot] {
                    self.occupied[i][slot] = true;
                    self.occupied_counts[i] = self.occupied_counts[i]
                        .checked_add(1)
                        .ok_or("identity diagnostic slot count overflow")?;
                }
            }
        }
        self.total_keys = new_total;
        let mut stretch = [0_i32; 4];
        for i in 0..4 {
            let p = self.maps[i]
                .get(&keys[i])
                .ok_or("identity diagnostic key missing")?
                .p;
            if !(1..4096).contains(&p) {
                return Err("identity diagnostic expert probability outside bounds".into());
            }
            stretch[i] = *logit
                .get(p as usize)
                .ok_or("identity diagnostic logit table bounds")?;
        }
        let z = stretch
            .iter()
            .zip(self.weights)
            .map(|(&s, w)| i64::from(s) * i64::from(w))
            .sum::<i64>()
            >> 16;
        let raw = sigmoid
            .get((z.clamp(-4096, 4096) + 4096) as usize)
            .copied()
            .ok_or("identity diagnostic sigmoid table bounds")?
            .clamp(1, 4095);
        let bin = (raw / 32) as usize;
        let fraction = raw % 32;
        let calibrated = (self.calibration[bin].p * (32 - fraction)
            + self.calibration[bin + 1].p * fraction
            + 16)
            / 32;
        let p = ((raw + calibrated + 1) / 2).clamp(1, 4095);
        let zero = ((4096 - p) * 8) as u16;
        let observed = if bit {
            32768 - u32::from(zero)
        } else {
            u32::from(zero)
        };
        if !(1..32768).contains(&observed) {
            return Err("identity diagnostic observed probability outside bounds".into());
        }
        let loss = -(f64::from(observed) / 32768.0).log2();
        let ideal_bits = self.classes[class].ideal_bits + loss;
        if !ideal_bits.is_finite() || loss < 0.0 {
            return Err("identity diagnostic loss not finite/nonnegative".into());
        }
        let bits = self.classes[class]
            .bits
            .checked_add(1)
            .ok_or("identity diagnostic bit count overflow")?;
        // 元の実bit順でauxへ渡した後、独立したglobal混合器と4mapを更新する。
        self.writer
            .as_mut()
            .ok_or("identity diagnostic writer already finished")?
            .bit(zero, bit)?;
        self.classes[class] = ClassLoss { bits, ideal_bits };
        let target = if bit { 4096 } else { 0 };
        for (weight, s) in self.weights.iter_mut().zip(stretch) {
            let delta = (i64::from(target - p) * i64::from(s)) >> 16;
            *weight = (i64::from(*weight) + delta).clamp(0, 131072) as i32;
        }
        for i in 0..4 {
            self.maps[i]
                .get_mut(&keys[i])
                .ok_or("identity diagnostic update key missing")?
                .update(bit);
        }
        self.calibration[bin].update(bit);
        self.calibration[bin + 1].update(bit);
        Ok(())
    }

    fn finish_json(&mut self, alphabet: usize) -> super::Result<String> {
        if !(1..=257).contains(&alphabet) {
            return Err("identity diagnostic alphabet outside bounds".into());
        }
        let mut bits = 0_u64;
        let mut ideal = 0.0;
        let mut classes = String::from("[");
        for (class, loss) in self.classes.iter().enumerate() {
            bits = bits
                .checked_add(loss.bits)
                .ok_or("identity diagnostic total bit overflow")?;
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
            return Err("identity diagnostic total loss not finite/nonnegative".into());
        }
        classes.push(']');
        let mut tables = String::from("[");
        let mut total_keys = 0_usize;
        for i in 0..4 {
            let distinct = self.maps[i].len();
            total_keys = total_keys
                .checked_add(distinct)
                .ok_or("identity diagnostic final key count overflow")?;
            let occupied = self.occupied[i].iter().filter(|&&b| b).count();
            if occupied != self.occupied_counts[i] {
                return Err("identity diagnostic occupied slot count mismatch".into());
            }
            let alias = distinct
                .checked_sub(occupied)
                .ok_or("identity diagnostic alias count inconsistent")?;
            if i != 0 {
                tables.push(',');
            }
            let _ = write!(
                tables,
                "{{\"table\":{i},\"distinct_keys\":{distinct},\"occupied_slots\":{occupied},\"alias_keys\":{alias}}}"
            );
        }
        if total_keys != self.total_keys || total_keys > MAX_KEYS {
            return Err("identity diagnostic final key total mismatch".into());
        }
        tables.push(']');
        let payload_bytes = self
            .writer
            .take()
            .ok_or("identity diagnostic writer already finished")?
            .finish()?
            .len();
        let header_bytes = 36_usize
            .checked_add(
                alphabet
                    .checked_mul(2)
                    .ok_or("identity diagnostic alphabet overflow")?,
            )
            .ok_or("identity diagnostic header overflow")?;
        let estimated_frame_bytes = payload_bytes
            .checked_add(header_bytes)
            .ok_or("identity diagnostic frame overflow")?;
        Ok(format!(
            "{{\"classes\":{classes},\"total_bits_calls\":{bits},\"ideal_bits_total\":{ideal:.12},\"payload_bytes\":{payload_bytes},\"estimated_frame_bytes\":{estimated_frame_bytes},\"tables\":{tables},\"total_distinct_keys\":{total_keys},\"max_distinct_keys\":{MAX_KEYS}}}"
        ))
    }
}

thread_local! { static STATE: RefCell<Option<State>> = const { RefCell::new(None) }; }

pub(super) fn record(
    symbol: u16,
    node: u32,
    recent: u32,
    previous: (u8, u8),
    logit: &[i32],
    sigmoid: &[i32],
    bit: bool,
) -> super::Result<()> {
    if symbol > 256 {
        return Err("identity diagnostic symbol outside bounds".into());
    }
    let s = u32::from(symbol);
    let (pr, pl) = previous;
    // 元Model::predictのhash入力XOR式をそのまま使う。意味tupleに拡張しない。
    let keys = [
        node,
        node ^ s.wrapping_mul(0x9e37_79b9),
        node ^ recent.rotate_left(11),
        node ^ s.wrapping_mul(0x85eb_ca6b) ^ (u32::from(pr) << 24) ^ (u32::from(pl) << 16),
    ];
    STATE.with(|state| {
        let mut state = state.borrow_mut();
        if state.is_none() {
            *state = Some(State::new()?);
        }
        state
            .as_mut()
            .ok_or("identity diagnostic state missing")?
            .record(keys, (node >> 28) as usize, logit, sigmoid, bit)
    })
}

pub(super) fn finish_json(alphabet: usize) -> super::Result<String> {
    STATE.with(|state| {
        state
            .borrow_mut()
            .as_mut()
            .ok_or("identity diagnostic state missing")?
            .finish_json(alphabet)
    })
}
