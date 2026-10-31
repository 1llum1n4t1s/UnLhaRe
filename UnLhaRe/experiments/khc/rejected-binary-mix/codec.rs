//! 不採用screenの再現専用 BWT / next-use binary rank-run mixture。製品wireではない。
//! Frame: KHBRM001、LE u32 plain length / primary / alphabet length / payload length /
//! plain CRC / payload CRC / header CRC (offsets 8,12,16,20,24,28,32)。
//! offset36から初回run出現順unique LE u16 alphabet、続いてrange payload。
//! header CRCはoffset0..32とalphabetを連結したIEEE CRC。CRC欄は含めない。
//! 数式由来float tableの決定性は同一binary内の研究screenに限定する。

#[allow(dead_code)]
#[path = "../range.rs"]
mod range;

#[cfg(all(khc_site_probe, khc_identity_probe))]
#[path = "identity_probe.rs"]
mod identity_probe;

#[cfg(all(khc_site_probe, khc_exponent_probe))]
#[path = "exponent_probe.rs"]
mod exponent_probe;

#[cfg(all(khc_site_probe, khc_semantic_probe))]
#[path = "semantic_probe.rs"]
mod semantic_probe;

#[cfg(all(khc_site_probe, khc_cts_probe))]
#[path = "cts_probe.rs"]
mod cts_probe;

#[cfg(all(khc_bayes_probe, not(all(khc_site_probe, khc_cts_probe))))]
compile_error!("Bayes diagnostic requires khc_site_probe and khc_cts_probe");

#[cfg(all(khc_site_probe, khc_cts_probe, khc_bayes_probe))]
#[path = "bayes_probe.rs"]
mod bayes_probe;

#[cfg(all(khc_site_probe, khc_cts_probe, khc_bayes_probe))]
#[path = "packed_alphabet.rs"]
mod packed_alphabet;

#[cfg(all(khc_cts_probe, any(khc_identity_probe, khc_exponent_probe, khc_semantic_probe)))]
compile_error!("CTS diagnostic must run independently of identity/exponent/semantic shadows");

use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::Path;

const MAX_INPUT: usize = 8 * 1024 * 1024;
const MAX_PAYLOAD: usize = MAX_INPUT * 16 + 1024;
const MAX_FRAME: usize = MAX_PAYLOAD + 36 + 514;
const MAGIC: &[u8; 8] = b"KHBRM001";
type Result<T> = std::result::Result<T, String>;

// 診断cfgだけに存在する観測。符号器・modelの状態には触れない。
#[cfg(khc_site_probe)]
mod site_probe {
    use std::cell::RefCell;
    use std::fmt::Write;

    #[derive(Clone, Copy, Default)]
    struct SiteLoss {
        bits: u64,
        actual_q12_bits: f64,
        actual_q15_bits: f64,
        expert_bits: [f64; 4],
    }

    const ALPHABET: usize = 257;
    const PREVIOUS_EXPONENTS: usize = 9;

    struct RankEntropy {
        runs: u64,
        all: Vec<u32>,
        by_symbol: Vec<u32>,
        by_symbol_prev_exp: Vec<u32>,
        symbol_totals: Vec<u32>,
        symbol_prev_exp_totals: Vec<u32>,
        symbol_kt_prequential_bits: f64,
    }

    impl RankEntropy {
        fn new() -> super::Result<Self> {
            Ok(Self {
                runs: 0,
                all: super::filled(ALPHABET, 0)?,
                by_symbol: super::filled(ALPHABET * ALPHABET, 0)?,
                by_symbol_prev_exp: super::filled(ALPHABET * PREVIOUS_EXPONENTS * ALPHABET, 0)?,
                symbol_totals: super::filled(ALPHABET, 0)?,
                symbol_prev_exp_totals: super::filled(ALPHABET * PREVIOUS_EXPONENTS, 0)?,
                symbol_kt_prequential_bits: 0.0,
            })
        }

        fn record(&mut self, symbol: usize, rank: usize, previous_exp: usize) -> super::Result<()> {
            let symbol_index = symbol * ALPHABET + rank;
            let joint_context = symbol * PREVIOUS_EXPONENTS + previous_exp;
            let joint_index = joint_context * ALPHABET + rank;
            // KTはこのrunの観測を加える前の文字別countだけを使う。
            let numerator = 2.0 * f64::from(self.by_symbol[symbol_index]) + 1.0;
            let denominator = 2.0 * f64::from(self.symbol_totals[symbol]) + ALPHABET as f64;
            let kt_loss = -(numerator / denominator).log2();
            let kt_total = self.symbol_kt_prequential_bits + kt_loss;
            if !kt_total.is_finite() || kt_loss < 0.0 {
                return Err("diagnostic rank KT loss not finite/nonnegative".into());
            }
            let runs = self
                .runs
                .checked_add(1)
                .ok_or("diagnostic run count overflow")?;
            let all = self.all[rank]
                .checked_add(1)
                .ok_or("diagnostic global count overflow")?;
            let by_symbol = self.by_symbol[symbol_index]
                .checked_add(1)
                .ok_or("diagnostic symbol count overflow")?;
            let by_joint = self.by_symbol_prev_exp[joint_index]
                .checked_add(1)
                .ok_or("diagnostic joint count overflow")?;
            let symbol_total = self.symbol_totals[symbol]
                .checked_add(1)
                .ok_or("diagnostic symbol total overflow")?;
            let joint_total = self.symbol_prev_exp_totals[joint_context]
                .checked_add(1)
                .ok_or("diagnostic joint total overflow")?;
            self.runs = runs;
            self.all[rank] = all;
            self.by_symbol[symbol_index] = by_symbol;
            self.by_symbol_prev_exp[joint_index] = by_joint;
            self.symbol_totals[symbol] = symbol_total;
            self.symbol_prev_exp_totals[joint_context] = joint_total;
            self.symbol_kt_prequential_bits = kt_total;
            Ok(())
        }
    }

    #[derive(Default)]
    struct RankState {
        histogram: Option<RankEntropy>,
        error: Option<String>,
    }

    #[derive(Clone)]
    struct ShadowMixer {
        weights: [i32; 4],
        calibration: [super::Bernoulli; 129],
        bits: u64,
        ideal_bits: f64,
    }

    impl ShadowMixer {
        fn new() -> Self {
            Self {
                weights: [16384; 4],
                calibration: std::array::from_fn(|i| super::Bernoulli::fresh(i as i32 * 32)),
                bits: 0,
                ideal_bits: 0.0,
            }
        }

        fn predict(
            &self,
            experts: [i32; 4],
            logit: &[i32],
            sigmoid: &[i32],
        ) -> super::Result<([i32; 4], i32, i32)> {
            let mut stretch = [0; 4];
            for (out, p) in stretch.iter_mut().zip(experts) {
                if !(1..4096).contains(&p) {
                    return Err("diagnostic shadow expert outside bounds".into());
                }
                *out = *logit
                    .get(p as usize)
                    .ok_or("diagnostic shadow logit table bounds")?;
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
                .ok_or("diagnostic shadow sigmoid table bounds")?
                .clamp(1, 4095);
            let bin = (raw / 32) as usize;
            let fraction = raw % 32;
            let calibrated = (self.calibration[bin].p * (32 - fraction)
                + self.calibration[bin + 1].p * fraction
                + 16)
                / 32;
            let p = ((raw + calibrated + 1) / 2).clamp(1, 4095);
            Ok((stretch, raw, p))
        }

        fn update(&mut self, stretch: [i32; 4], raw: i32, p: i32, bit: bool) {
            let target = if bit { 4096 } else { 0 };
            for (weight, stretch) in self.weights.iter_mut().zip(stretch) {
                let delta = (i64::from(target - p) * i64::from(stretch)) >> 16;
                *weight = (i64::from(*weight) + delta).clamp(0, 131072) as i32;
            }
            let bin = (raw / 32) as usize;
            self.calibration[bin].update(bit);
            self.calibration[bin + 1].update(bit);
        }
    }

    struct ShadowState {
        mixers: Vec<ShadowMixer>,
        writer: Option<super::range::Encoder>,
    }

    impl ShadowState {
        fn new() -> super::Result<Self> {
            Ok(Self {
                mixers: super::filled(7, ShadowMixer::new())?,
                writer: Some(super::range::Encoder::with_limit(super::MAX_PAYLOAD)?),
            })
        }

        fn record(
            &mut self,
            class: u32,
            experts: [i32; 4],
            logit: &[i32],
            sigmoid: &[i32],
            bit: bool,
        ) -> super::Result<()> {
            let mixer = self
                .mixers
                .get_mut(class as usize)
                .ok_or("diagnostic shadow class outside bounds")?;
            let (stretch, raw, p) = mixer.predict(experts, logit, sigmoid)?;
            let zero = ((4096 - p) * 8) as u16;
            let ideal = mixer.ideal_bits + loss(32768 - i32::from(zero), 32768, bit)?;
            if !ideal.is_finite() || ideal < 0.0 {
                return Err("diagnostic shadow loss not finite/nonnegative".into());
            }
            let bits = mixer
                .bits
                .checked_add(1)
                .ok_or("diagnostic shadow bit count overflow")?;
            // 全class共通のwriterで元のbit順を保持する。観測後にshadowだけを更新。
            self.writer
                .as_mut()
                .ok_or("diagnostic shadow writer already finished")?
                .bit(zero, bit)?;
            mixer.bits = bits;
            mixer.ideal_bits = ideal;
            mixer.update(stretch, raw, p, bit);
            Ok(())
        }
    }

    thread_local! {
        static SITES: RefCell<[SiteLoss; 7]> = RefCell::new([SiteLoss::default(); 7]);
        static RANKS: RefCell<RankState> = RefCell::new(RankState::default());
        static SHADOW: RefCell<Option<ShadowState>> = const { RefCell::new(None) };
    }

    fn record_shadow(
        class: u32,
        experts: [i32; 4],
        logit: &[i32],
        sigmoid: &[i32],
        bit: bool,
    ) -> super::Result<()> {
        SHADOW.with(|state| {
            let mut state = state.borrow_mut();
            if state.is_none() {
                *state = Some(ShadowState::new()?);
            }
            state
                .as_mut()
                .ok_or("diagnostic shadow state missing")?
                .record(class, experts, logit, sigmoid, bit)
        })
    }

    pub(super) fn shadow_json(alphabet: usize) -> super::Result<String> {
        if !(1..=ALPHABET).contains(&alphabet) {
            return Err("diagnostic shadow alphabet outside bounds".into());
        }
        SHADOW.with(|state| {
            let mut state = state.borrow_mut();
            let state = state.as_mut().ok_or("diagnostic shadow state missing")?;
            let mut total_bits = 0_u64;
            let mut ideal_bits = 0.0;
            let mut classes = String::from("[");
            for (class, mixer) in state.mixers.iter().enumerate() {
                let control_bits = SITES.with(|sites| sites.borrow()[class].bits);
                if mixer.bits != control_bits { return Err("diagnostic shadow/control bit count mismatch".into()); }
                total_bits = total_bits.checked_add(mixer.bits).ok_or("diagnostic shadow total overflow")?;
                ideal_bits += mixer.ideal_bits;
                if class != 0 { classes.push(','); }
                let _ = write!(classes, "{{\"class\":{class},\"bits\":{},\"ideal_bits\":{:.12}}}", mixer.bits, mixer.ideal_bits);
            }
            if !ideal_bits.is_finite() || ideal_bits < 0.0 { return Err("diagnostic shadow total not finite/nonnegative".into()); }
            classes.push(']');
            let payload_bytes = state.writer.take().ok_or("diagnostic shadow writer already finished")?.finish()?.len();
            let header_bytes = 36_usize.checked_add(alphabet.checked_mul(2).ok_or("diagnostic shadow alphabet overflow")?).ok_or("diagnostic shadow header overflow")?;
            let estimated_frame_bytes = payload_bytes.checked_add(header_bytes).ok_or("diagnostic shadow frame overflow")?;
            Ok(format!("{{\"classes\":{classes},\"total_bits_calls\":{total_bits},\"ideal_bits_total\":{ideal_bits:.12},\"payload_bytes\":{payload_bytes},\"estimated_frame_bytes\":{estimated_frame_bytes}}}"))
        })
    }

    pub(super) fn record_run(symbol: u16, rank: usize, previous_exp: u8) -> super::Result<()> {
        if symbol as usize >= ALPHABET
            || rank >= ALPHABET
            || previous_exp as usize >= PREVIOUS_EXPONENTS
        {
            return Err("diagnostic rank/symbol/previous exponent outside bounds".into());
        }
        RANKS.with(|state| {
            let mut state = state.borrow_mut();
            if state.error.is_some() {
                return Ok(());
            }
            if state.histogram.is_none() {
                state.histogram = Some(RankEntropy::new()?);
            }
            state
                .histogram
                .as_mut()
                .ok_or("diagnostic rank histogram missing")?
                .record(symbol as usize, rank, previous_exp as usize)
        })
    }

    // run_doneの元のsignatureを維持し、観測失敗は公開前のResultで拒否する。
    pub(super) fn defer_error(error: String) {
        RANKS.with(|state| {
            let mut state = state.borrow_mut();
            if state.error.is_none() {
                state.error = Some(error);
            }
        });
    }

    fn shannon(counts: &[u32], totals: &[u32]) -> super::Result<(f64, u64)> {
        if counts.len() != totals.len() * ALPHABET {
            return Err("diagnostic histogram shape mismatch".into());
        }
        let mut bits = 0.0;
        let mut runs = 0_u64;
        for (row, &total) in counts.chunks_exact(ALPHABET).zip(totals) {
            let row_sum: u64 = row.iter().map(|&c| u64::from(c)).sum();
            if row_sum != u64::from(total) {
                return Err("diagnostic histogram context total mismatch".into());
            }
            runs = runs
                .checked_add(row_sum)
                .ok_or("diagnostic histogram total overflow")?;
            for &count in row.iter().filter(|&&count| count != 0) {
                bits += f64::from(count) * (f64::from(total) / f64::from(count)).log2();
            }
        }
        if !bits.is_finite() || bits < 0.0 {
            return Err("diagnostic Shannon loss not finite/nonnegative".into());
        }
        Ok((bits, runs))
    }

    pub(super) fn rank_json() -> super::Result<String> {
        RANKS.with(|state| {
            let state = state.borrow();
            if let Some(error) = &state.error { return Err(error.clone()); }
            let h = state.histogram.as_ref().ok_or("diagnostic rank histogram missing")?;
            let runs_u32 = u32::try_from(h.runs).map_err(|_| "diagnostic run count outside u32")?;
            let (global_bits, global_runs) = shannon(&h.all, &[runs_u32])?;
            let (symbol_bits, symbol_runs) = shannon(&h.by_symbol, &h.symbol_totals)?;
            let (joint_bits, joint_runs) = shannon(&h.by_symbol_prev_exp, &h.symbol_prev_exp_totals)?;
            let binary_rank_runs = SITES.with(|sites| sites.borrow()[0].bits);
            if [global_runs, symbol_runs, joint_runs, binary_rank_runs].iter().any(|&n| n != h.runs) {
                return Err("diagnostic rank/run total mismatch".into());
            }
            for rank in 0..ALPHABET {
                let symbol_count: u64 = h.by_symbol.chunks_exact(ALPHABET).map(|row| u64::from(row[rank])).sum();
                let joint_count: u64 = h.by_symbol_prev_exp.chunks_exact(ALPHABET).map(|row| u64::from(row[rank])).sum();
                if symbol_count != u64::from(h.all[rank]) || joint_count != symbol_count {
                    return Err("diagnostic rank histogram marginal mismatch".into());
                }
            }
            Ok(format!(
                "{{\"runs\":{},\"alphabet\":{ALPHABET},\"global_shannon_bits\":{:.12},\"symbol_shannon_bits\":{:.12},\"symbol_prev_rank_exp_shannon_bits\":{:.12},\"symbol_kt_prequential_bits\":{:.12},\"histogram_runs_global\":{global_runs},\"histogram_runs_symbol\":{symbol_runs},\"histogram_runs_symbol_prev_exp\":{joint_runs}}}",
                h.runs, global_bits, symbol_bits, joint_bits, h.symbol_kt_prequential_bits))
        })
    }

    fn loss(one: i32, total: i32, bit: bool) -> super::Result<f64> {
        let observed = if bit { one } else { total - one };
        if !(1..total).contains(&observed) {
            return Err("diagnostic probability outside bounds".into());
        }
        let result = -(f64::from(observed) / f64::from(total)).log2();
        if !result.is_finite() || result < 0.0 {
            return Err("diagnostic loss not finite/nonnegative".into());
        }
        Ok(result)
    }

    pub(super) fn record(
        class: u32,
        p_q12: i32,
        zero_q15: u16,
        experts: [i32; 4],
        bit: bool,
        logit: &[i32],
        sigmoid: &[i32],
    ) -> super::Result<()> {
        let actual_q12 = loss(p_q12, 4096, bit)?;
        let actual_q15 = loss(32768 - i32::from(zero_q15), 32768, bit)?;
        let mut expert_losses = [0.0; 4];
        for (out, p) in expert_losses.iter_mut().zip(experts) {
            *out = loss(p, 4096, bit)?;
        }
        SITES.with(|sites| -> super::Result<()> {
            let mut sites = sites.borrow_mut();
            let site = sites
                .get_mut(class as usize)
                .ok_or("diagnostic node class outside bounds")?;
            site.bits = site
                .bits
                .checked_add(1)
                .ok_or("diagnostic bit count overflow")?;
            site.actual_q12_bits += actual_q12;
            site.actual_q15_bits += actual_q15;
            for (out, loss) in site.expert_bits.iter_mut().zip(expert_losses) {
                *out += loss;
            }
            Ok(())
        })?;
        record_shadow(class, experts, logit, sigmoid, bit)
    }

    pub(super) fn emit(
        rank_json: &str,
        shadow_json: &str,
        #[cfg(khc_identity_probe)] identity_json: &str,
        #[cfg(khc_exponent_probe)] exponent_json: &str,
        #[cfg(khc_semantic_probe)] semantic_json: &str,
        #[cfg(khc_cts_probe)] cts_json: &str,
        #[cfg(khc_bayes_probe)] bayes_json: &str,
    ) {
        SITES.with(|sites| {
            let sites = sites.borrow();
            let mut json = String::from("{\"kind\":\"site_loss_diagnostic\",\"sites\":[");
            for (class, site) in sites.iter().enumerate() {
                if class != 0 { json.push(','); }
                let _ = write!(json,
                    "{{\"class\":{class},\"bits\":{},\"actual_q12_bits\":{:.12},\"actual_q15_bits\":{:.12},\"expert_bits\":[{:.12},{:.12},{:.12},{:.12}]}}",
                    site.bits, site.actual_q12_bits, site.actual_q15_bits,
                    site.expert_bits[0], site.expert_bits[1], site.expert_bits[2], site.expert_bits[3]);
            }
            json.push_str("],\"rank_entropy\":");
            json.push_str(rank_json);
            json.push_str(",\"class_mixer_shadow\":");
            json.push_str(shadow_json);
            #[cfg(khc_identity_probe)]
            {
                json.push_str(",\"identity_shadow\":");
                json.push_str(identity_json);
            }
            #[cfg(khc_exponent_probe)]
            {
                json.push_str(",\"exponent_shadow\":");
                json.push_str(exponent_json);
            }
            #[cfg(khc_semantic_probe)]
            {
                json.push_str(",\"semantic_shadow\":");
                json.push_str(semantic_json);
            }
            #[cfg(khc_cts_probe)]
            {
                json.push_str(",\"cts_shadow\":");
                json.push_str(cts_json);
            }
            #[cfg(khc_bayes_probe)]
            {
                json.push_str(",\"bayes_shadow\":");
                json.push_str(bayes_json);
            }
            json.push('}');
            println!("{json}");
        });
    }
}

fn filled<T: Clone>(length: usize, value: T) -> Result<Vec<T>> {
    let mut v = Vec::new();
    v.try_reserve_exact(length)
        .map_err(|_| "allocation failed")?;
    v.resize(length, value);
    Ok(v)
}

fn crc_table() -> [u32; 256] {
    std::array::from_fn(|i| {
        let mut c = i as u32;
        for _ in 0..8 {
            c = (c >> 1) ^ if c & 1 != 0 { 0xedb8_8320 } else { 0 };
        }
        c
    })
}

fn crc_parts(parts: &[&[u8]]) -> u32 {
    let table = crc_table();
    let mut c = u32::MAX;
    for part in parts {
        for &b in *part {
            c = (c >> 8) ^ table[((c as u8) ^ b) as usize];
        }
    }
    !c
}

fn read_bounded(path: &Path, limit: usize) -> Result<Vec<u8>> {
    let f = File::open(path).map_err(|e| format!("input open: {e}"))?;
    let meta = f.metadata().map_err(|e| format!("input metadata: {e}"))?;
    if !meta.is_file() || meta.len() > limit as u64 {
        return Err("input is not a regular file within limit".into());
    }
    let mut bytes = Vec::new();
    bytes
        .try_reserve_exact(meta.len() as usize)
        .map_err(|_| "input allocation failed")?;
    f.take(limit as u64 + 1)
        .read_to_end(&mut bytes)
        .map_err(|e| format!("input read: {e}"))?;
    if bytes.len() > limit {
        return Err("input exceeds limit".into());
    }
    Ok(bytes)
}

fn publish(path: &Path, bytes: &[u8]) -> Result<()> {
    let mut f = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(path)
        .map_err(|e| format!("output create_new: {e}"))?;
    if let Err(e) = f.write_all(bytes).and_then(|()| f.sync_all()) {
        drop(f);
        // 今回create_newで作った出力だけを、I/O失敗時に清掃する。
        let _ = std::fs::remove_file(path);
        return Err(format!("output write: {e}"));
    }
    Ok(())
}

// 一意sentinelを含む非循環suffixの独立prefix-doubling。各roundは二段count sort。
fn bwt(input: &[u8]) -> Result<(Vec<u16>, usize)> {
    let n = input.len().checked_add(1).ok_or("length overflow")?;
    let mut symbols = filled(n, 0_u16)?;
    for (s, &b) in symbols.iter_mut().zip(input) {
        *s = u16::from(b) + 1;
    }
    let mut sa = filled(n, 0_usize)?;
    for (i, s) in sa.iter_mut().enumerate() {
        *s = i;
    }
    let mut ranks: Vec<usize> = filled(n, 0)?;
    for (r, &s) in ranks.iter_mut().zip(&symbols) {
        *r = s as usize;
    }
    let mut scratch = filled(n, 0_usize)?;
    let mut new_ranks = filled(n, 0_usize)?;
    let mut counts = filled(n.max(258) + 1, 0_usize)?;
    let mut classes = 257;
    let mut step = 1_usize;
    loop {
        for second in [true, false] {
            counts[..classes + 1].fill(0);
            for &i in &sa {
                let key = if second {
                    if i + step < n { ranks[i + step] + 1 } else { 0 }
                } else {
                    ranks[i] + 1
                };
                counts[key] += 1;
            }
            let mut sum = 0;
            for c in &mut counts[..classes + 1] {
                let old = *c;
                *c = sum;
                sum += old;
            }
            for &i in &sa {
                let key = if second {
                    if i + step < n { ranks[i + step] + 1 } else { 0 }
                } else {
                    ranks[i] + 1
                };
                scratch[counts[key]] = i;
                counts[key] += 1;
            }
            std::mem::swap(&mut sa, &mut scratch);
        }
        let mut class = 0;
        new_ranks[sa[0]] = 0;
        for pair in sa.windows(2) {
            let a = pair[0];
            let b = pair[1];
            let second_a = if a + step < n {
                Some(ranks[a + step])
            } else {
                None
            };
            let second_b = if b + step < n {
                Some(ranks[b + step])
            } else {
                None
            };
            if ranks[a] != ranks[b] || second_a != second_b {
                class += 1;
            }
            new_ranks[b] = class;
        }
        std::mem::swap(&mut ranks, &mut new_ranks);
        classes = class + 1;
        if classes == n {
            break;
        }
        step = step.checked_mul(2).ok_or("suffix step overflow")?;
        if step >= n {
            return Err("suffix classes inconsistent".into());
        }
    }
    if sa[0] != n - 1 {
        return Err("sentinel suffix order".into());
    }
    let mut transformed = filled(n, 0_u16)?;
    let mut primary = None;
    for (row, &start) in sa.iter().enumerate() {
        if start == 0 {
            if primary.replace(row).is_some() {
                return Err("duplicate primary".into());
            }
        }
        transformed[row] = symbols[if start == 0 { n - 1 } else { start - 1 }];
    }
    Ok((transformed, primary.ok_or("missing primary")?))
}

fn inverse_bwt(last: &[u16], primary: usize, alphabet: &[u16]) -> Result<Vec<u8>> {
    let n = last.len();
    if primary >= n || last[primary] != 0 {
        return Err("invalid primary sentinel".into());
    }
    let mut counts = [0_usize; 257];
    for &s in last {
        if s > 256 {
            return Err("BWT symbol out of range".into());
        }
        counts[s as usize] += 1;
    }
    if counts[0] != 1 {
        return Err("sentinel count".into());
    }
    let mut seen = [false; 257];
    for &s in alphabet {
        seen[s as usize] = true;
    }
    for (i, &c) in counts.iter().enumerate() {
        if (c != 0) != seen[i] {
            return Err("alphabet mismatch".into());
        }
    }
    let mut starts = [0_usize; 257];
    let mut total = 0;
    for (i, &c) in counts.iter().enumerate() {
        starts[i] = total;
        total += c;
    }
    let mut occurrence = [0_usize; 257];
    let mut lf = filled(n, 0_usize)?;
    for (i, &s) in last.iter().enumerate() {
        let s = s as usize;
        lf[i] = starts[s] + occurrence[s];
        occurrence[s] += 1;
    }
    let mut visited = filled(n, false)?;
    let mut text = filled(n, 0_u16)?;
    let mut row = primary;
    for out in text.iter_mut().rev() {
        if row >= n || visited[row] {
            return Err("LF cycle inconsistent".into());
        }
        visited[row] = true;
        *out = last[row];
        row = lf[row];
    }
    if row != primary
        || !visited.iter().all(|&v| v)
        || text[n - 1] != 0
        || text[..n - 1].contains(&0)
    {
        return Err("LF cycle/sentinel inconsistent".into());
    }
    let mut result = filled(n - 1, 0_u8)?;
    for (out, &s) in result.iter_mut().zip(&text) {
        *out = (s - 1) as u8;
    }
    Ok(result)
}

#[derive(Clone, Copy)]
struct Bernoulli {
    p: i32,
    count: u16,
}
impl Bernoulli {
    fn fresh(p: i32) -> Self {
        Self { p, count: 0 }
    }
    fn update(&mut self, bit: bool) {
        let shift = match self.count {
            0..=15 => 2,
            16..=63 => 3,
            64..=255 => 4,
            256..=1023 => 5,
            _ => 6,
        };
        self.p = (self.p + (((if bit { 4096 } else { 0 }) - self.p) >> shift)).clamp(1, 4095);
        self.count = self.count.saturating_add(1);
    }
}

fn hash(mut x: u32) -> usize {
    x ^= x >> 16;
    x = x.wrapping_mul(0x7feb_352d);
    x ^= x >> 15;
    x = x.wrapping_mul(0x846c_a68b);
    (x ^ (x >> 16)) as usize
}

struct Model {
    global: Vec<Bernoulli>,
    symbol: Vec<Bernoulli>,
    history: Vec<Bernoulli>,
    joint: Vec<Bernoulli>,
    logit: Vec<i32>,
    sigmoid: Vec<i32>,
    weights: [i32; 4],
    calibration: [Bernoulli; 129],
    recent: u32,
    previous: [(u8, u8); 257],
}
struct Prediction {
    indexes: [usize; 4],
    stretch: [i32; 4],
    raw: i32,
    p: i32,
    #[cfg(khc_site_probe)]
    ps: [i32; 4],
}
impl Model {
    fn new() -> Result<Self> {
        let mut logit = filled(4096, 0)?;
        for (p, v) in logit.iter_mut().enumerate() {
            let p = p.clamp(1, 4095) as f64 / 4096.0;
            *v = ((p / (1.0 - p)).ln() * 256.0).round() as i32;
        }
        let mut sigmoid = filled(8193, 0)?;
        for (i, v) in sigmoid.iter_mut().enumerate() {
            *v = (4096.0 / (1.0 + (-((i as f64 - 4096.0) / 256.0)).exp())).round() as i32;
        }
        Ok(Self {
            global: filled(1 << 12, Bernoulli::fresh(2048))?,
            symbol: filled(1 << 18, Bernoulli::fresh(2048))?,
            history: filled(1 << 18, Bernoulli::fresh(2048))?,
            joint: filled(1 << 18, Bernoulli::fresh(2048))?,
            logit,
            sigmoid,
            weights: [16384; 4],
            calibration: std::array::from_fn(|i| Bernoulli::fresh(i as i32 * 32)),
            recent: 0,
            previous: [(0, 0); 257],
        })
    }
    fn predict(&self, symbol: u16, node: u32) -> Prediction {
        let s = symbol as u32;
        let (pr, pl) = self.previous[symbol as usize];
        let indexes = [
            hash(node) & ((1 << 12) - 1),
            hash(node ^ s.wrapping_mul(0x9e37_79b9)) & ((1 << 18) - 1),
            hash(node ^ self.recent.rotate_left(11)) & ((1 << 18) - 1),
            hash(
                node ^ s.wrapping_mul(0x85eb_ca6b) ^ (u32::from(pr) << 24) ^ (u32::from(pl) << 16),
            ) & ((1 << 18) - 1),
        ];
        let ps = [
            self.global[indexes[0]].p,
            self.symbol[indexes[1]].p,
            self.history[indexes[2]].p,
            self.joint[indexes[3]].p,
        ];
        let stretch = ps.map(|p| self.logit[p as usize]);
        let z = stretch
            .iter()
            .zip(self.weights)
            .map(|(&s, w)| i64::from(s) * i64::from(w))
            .sum::<i64>()
            >> 16;
        let raw = self.sigmoid[(z.clamp(-4096, 4096) + 4096) as usize].clamp(1, 4095);
        let bin = (raw / 32) as usize;
        let fraction = raw % 32;
        let calibrated = (self.calibration[bin].p * (32 - fraction)
            + self.calibration[bin + 1].p * fraction
            + 16)
            / 32;
        let p = ((raw + calibrated + 1) / 2).clamp(1, 4095);
        Prediction {
            indexes,
            stretch,
            raw,
            p,
            #[cfg(khc_site_probe)]
            ps,
        }
    }
    fn update(&mut self, prediction: Prediction, bit: bool) {
        let target = if bit { 4096 } else { 0 };
        for (weight, stretch) in self.weights.iter_mut().zip(prediction.stretch) {
            let delta = (i64::from(target - prediction.p) * i64::from(stretch)) >> 16;
            *weight = (i64::from(*weight) + delta).clamp(0, 131072) as i32;
        }
        let i = prediction.indexes;
        self.global[i[0]].update(bit);
        self.symbol[i[1]].update(bit);
        self.history[i[2]].update(bit);
        self.joint[i[3]].update(bit);
        let bin = (prediction.raw / 32) as usize;
        self.calibration[bin].update(bit);
        self.calibration[bin + 1].update(bit);
    }
    fn run_done(&mut self, symbol: u16, rank: usize, length: usize) {
        #[cfg(khc_site_probe)]
        site_probe::record_run(symbol, rank, self.previous[symbol as usize].0)
            .unwrap_or_else(site_probe::defer_error);
        self.history_done(symbol, rank, length);
        #[cfg(all(khc_site_probe, khc_exponent_probe))]
        exponent_probe::run_done(symbol, rank, length).unwrap_or_else(site_probe::defer_error);
    }
    // 主経路とshadowの両方で同じ履歴更新を使う。診断のrun記録は主経路だけ。
    fn history_done(&mut self, symbol: u16, rank: usize, length: usize) {
        let r = exponent(rank.saturating_sub(1));
        let l = exponent(length - 1);
        self.previous[symbol as usize] = (r as u8, l as u8);
        // 直近4runだけを保持し、同じ履歴は同じcontextへ戻る。
        let rank_class = rank.min(3) as u32;
        let length_class = match length {
            1 => 0,
            2 => 1,
            3..=4 => 2,
            _ => 3,
        };
        self.recent = ((self.recent << 4) | rank_class | (length_class << 2)) & 0xffff;
    }
}

fn exponent(v: usize) -> usize {
    if v == 0 {
        0
    } else {
        (usize::BITS - 1 - v.leading_zeros()) as usize
    }
}
// node: class / bit position / low 8 preceding bits / current rank exponent for length。
fn node(class: u32, position: usize, prefix: u32, rank_context: usize) -> u32 {
    (class << 28) | ((rank_context as u32) << 20) | ((position as u32) << 12) | (prefix & 255)
}

enum Coder<'a> {
    Encode(range::Encoder),
    Decode(range::Decoder<'a>),
}
struct Stream<'a> {
    coder: Coder<'a>,
    model: Model,
    #[cfg(all(khc_site_probe, khc_exponent_probe))]
    known_exponent: usize,
}
impl Stream<'_> {
    fn bit(&mut self, symbol: u16, node: u32, expected: bool) -> Result<bool> {
        let p = self.model.predict(symbol, node);
        let zero = ((4096 - p.p) * 8) as u16;
        let bit = match &mut self.coder {
            Coder::Encode(e) => {
                e.bit(zero, expected)?;
                expected
            }
            Coder::Decode(d) => d.bit(zero)?,
        };
        #[cfg(khc_site_probe)]
        site_probe::record(
            node >> 28,
            p.p,
            zero,
            p.ps,
            bit,
            &self.model.logit,
            &self.model.sigmoid,
        )?;
        #[cfg(all(khc_site_probe, khc_identity_probe))]
        identity_probe::record(
            symbol,
            node,
            self.model.recent,
            self.model.previous[symbol as usize],
            &self.model.logit,
            &self.model.sigmoid,
            bit,
        )?;
        #[cfg(all(khc_site_probe, khc_exponent_probe))]
        exponent_probe::record(symbol, node, self.known_exponent, bit)?;
        #[cfg(all(khc_site_probe, khc_semantic_probe))]
        semantic_probe::record(
            symbol,
            node,
            self.model.recent,
            self.model.previous[symbol as usize],
            &self.model.logit,
            &self.model.sigmoid,
            bit,
        )?;
        #[cfg(all(khc_site_probe, khc_cts_probe))]
        let _cts_zero = cts_probe::record(node >> 28, bit)?;
        #[cfg(all(khc_site_probe, khc_cts_probe, khc_bayes_probe))]
        bayes_probe::record(node >> 28, zero, _cts_zero, bit)?;
        self.model.update(p, bit);
        Ok(bit)
    }
    fn integer(
        &mut self,
        symbol: u16,
        value: usize,
        exp_class: u32,
        mant_class: u32,
        max_exp: usize,
        rank_context: usize,
    ) -> Result<usize> {
        let desired_exp = exponent(value);
        let mut e = 0;
        while self.bit(symbol, node(exp_class, e, 0, rank_context), e < desired_exp)? {
            e += 1;
            if e > max_exp {
                return Err("integer exponent exceeds bounds".into());
            }
        }
        let mut decoded = 1_usize;
        let mut prefix = 1;
        // encodeのdesired_expではなく、指数bit列から確定したeだけを渡す。
        #[cfg(all(khc_site_probe, khc_exponent_probe))]
        {
            self.known_exponent = e;
        }
        for position in 0..e {
            let desired = (value >> (e - position - 1)) & 1 != 0;
            let b = self.bit(
                symbol,
                node(mant_class, position, prefix, rank_context),
                desired,
            )?;
            decoded = (decoded << 1) | usize::from(b);
            prefix = (prefix << 1) | u32::from(b);
        }
        #[cfg(all(khc_site_probe, khc_exponent_probe))]
        {
            self.known_exponent = 0;
        }
        Ok(decoded)
    }
    fn rank(&mut self, symbol: u16, desired: usize, active: usize) -> Result<usize> {
        if self.bit(symbol, node(0, 0, 0, 0), desired == 0)? {
            return Ok(0);
        }
        let rank = if self.bit(symbol, node(1, 0, 0, 0), desired == 1)? {
            1
        } else {
            self.integer(symbol, desired.saturating_sub(1), 2, 3, 8, 0)?
                .checked_add(1)
                .ok_or("rank overflow")?
        };
        if rank >= active {
            return Err("rank outside active list".into());
        }
        Ok(rank)
    }
    fn length(
        &mut self,
        symbol: u16,
        desired: usize,
        rank: usize,
        remaining: usize,
    ) -> Result<usize> {
        let context = exponent(rank.saturating_add(1));
        let length = if self.bit(symbol, node(4, 0, 0, context), desired == 1)? {
            1
        } else {
            self.integer(symbol, desired.saturating_sub(1), 5, 6, 23, context)?
                .checked_add(1)
                .ok_or("run length overflow")?
        };
        if length > remaining {
            return Err("run length exceeds declared length".into());
        }
        Ok(length)
    }
}

#[derive(Clone, Copy)]
struct Run {
    symbol: u16,
    length: usize,
    next: usize,
}

fn encode_payload(last: &[u16]) -> Result<(Vec<u8>, Vec<u16>, usize)> {
    let mut runs: Vec<Run> = Vec::new();
    runs.try_reserve_exact(last.len())
        .map_err(|_| "run allocation failed")?;
    for &s in last {
        if let Some(r) = runs.last_mut().filter(|r| r.symbol == s) {
            r.length += 1;
        } else {
            runs.push(Run {
                symbol: s,
                length: 1,
                next: usize::MAX,
            });
        }
    }
    let mut next = [usize::MAX; 257];
    for (i, run) in runs.iter_mut().enumerate().rev() {
        run.next = next[run.symbol as usize];
        next[run.symbol as usize] = i;
    }
    let mut alphabet = Vec::new();
    alphabet
        .try_reserve_exact(257)
        .map_err(|_| "alphabet allocation failed")?;
    for run in &runs {
        if !alphabet.contains(&run.symbol) {
            alphabet.push(run.symbol);
        }
    }
    let mut active = filled(alphabet.len(), 0_u16)?;
    active.copy_from_slice(&alphabet);
    let mut stream = Stream {
        coder: Coder::Encode(range::Encoder::with_limit(MAX_PAYLOAD)?),
        model: Model::new()?,
        #[cfg(all(khc_site_probe, khc_exponent_probe))]
        known_exponent: 0,
    };
    for (i, run) in runs.iter().enumerate() {
        if active.first() != Some(&run.symbol) || next[run.symbol as usize] != i {
            return Err("next-use head inconsistent".into());
        }
        let symbol = active.remove(0);
        next[symbol as usize] = run.next;
        let rank = if run.next == usize::MAX {
            0
        } else {
            let index = active
                .iter()
                .position(|&s| next[s as usize] > run.next)
                .unwrap_or(active.len());
            if index == 0 {
                return Err("adjacent run symbol".into());
            }
            index
        };
        stream.rank(symbol, rank, active.len() + 1)?;
        stream.length(symbol, run.length, rank, last.len())?;
        stream.model.run_done(symbol, rank, run.length);
        if rank != 0 {
            active.insert(rank, symbol);
        }
    }
    if !active.is_empty() {
        return Err("remaining next-use symbols".into());
    }
    let Coder::Encode(e) = stream.coder else {
        unreachable!()
    };
    Ok((e.finish()?, alphabet, runs.len()))
}

fn decode_payload(payload: &[u8], alphabet: &[u16], n: usize) -> Result<(Vec<u16>, usize)> {
    let mut active = filled(alphabet.len(), 0_u16)?;
    active.copy_from_slice(alphabet);
    let mut last = Vec::new();
    last.try_reserve_exact(n)
        .map_err(|_| "BWT allocation failed")?;
    let mut stream = Stream {
        coder: Coder::Decode(range::Decoder::<false>::new(payload)?),
        model: Model::new()?,
        #[cfg(all(khc_site_probe, khc_exponent_probe))]
        known_exponent: 0,
    };
    let mut runs = 0;
    while last.len() < n {
        let symbol = *active
            .first()
            .ok_or("active list exhausted before declared length")?;
        let rank = stream.rank(symbol, 0, active.len())?;
        let length = stream.length(symbol, 1, rank, n - last.len())?;
        if last.last() == Some(&symbol) {
            return Err("non-maximal adjacent run".into());
        }
        last.resize(
            last.len().checked_add(length).ok_or("run sum overflow")?,
            symbol,
        );
        active.remove(0);
        if rank != 0 {
            active.insert(rank, symbol);
        }
        stream.model.run_done(symbol, rank, length);
        runs += 1;
    }
    if !active.is_empty() {
        return Err("active list not empty at end".into());
    }
    let Coder::Decode(d) = stream.coder else {
        unreachable!()
    };
    d.finish()?;
    Ok((last, runs))
}

fn field(frame: &[u8], offset: usize) -> usize {
    u32::from_le_bytes(frame[offset..offset + 4].try_into().unwrap()) as usize
}
struct Stats {
    runs: usize,
    primary: usize,
    alphabet: usize,
    payload: usize,
    plain_crc: u32,
    payload_crc: u32,
}

fn encode(input: &[u8]) -> Result<(Vec<u8>, Stats)> {
    let (last, primary) = bwt(input)?;
    let (payload, alphabet, runs) = encode_payload(&last)?;
    let plain_crc = crc_parts(&[input]);
    let payload_crc = crc_parts(&[&payload]);
    let header_len = 36_usize
        .checked_add(alphabet.len().checked_mul(2).ok_or("alphabet overflow")?)
        .ok_or("header overflow")?;
    let frame_len = header_len
        .checked_add(payload.len())
        .ok_or("frame overflow")?;
    let mut frame = Vec::new();
    frame
        .try_reserve_exact(frame_len)
        .map_err(|_| "frame allocation failed")?;
    frame.extend_from_slice(MAGIC);
    for value in [
        input.len(),
        primary,
        alphabet.len(),
        payload.len(),
        plain_crc as usize,
        payload_crc as usize,
        0,
    ] {
        frame.extend_from_slice(
            &u32::try_from(value)
                .map_err(|_| "frame field overflow")?
                .to_le_bytes(),
        );
    }
    for &s in &alphabet {
        frame.extend_from_slice(&s.to_le_bytes());
    }
    let header_crc = crc_parts(&[&frame[..32], &frame[36..header_len]]);
    frame[32..36].copy_from_slice(&header_crc.to_le_bytes());
    frame.extend_from_slice(&payload);
    Ok((
        frame,
        Stats {
            runs,
            primary,
            alphabet: alphabet.len(),
            payload: payload.len(),
            plain_crc,
            payload_crc,
        },
    ))
}

fn decode(frame: &[u8]) -> Result<(Vec<u8>, Stats)> {
    if frame.len() < 36 || &frame[..8] != MAGIC {
        return Err("bad frame magic/header".into());
    }
    let length = field(frame, 8);
    let primary = field(frame, 12);
    let alphabet_len = field(frame, 16);
    let payload_len = field(frame, 20);
    let plain_crc = field(frame, 24) as u32;
    let payload_crc = field(frame, 28) as u32;
    if length > MAX_INPUT
        || primary > length
        || !(1..=257).contains(&alphabet_len)
        || !(5..=MAX_PAYLOAD).contains(&payload_len)
    {
        return Err("frame fields outside bounds".into());
    }
    let header_len = 36_usize
        .checked_add(alphabet_len.checked_mul(2).ok_or("alphabet overflow")?)
        .ok_or("header overflow")?;
    let full_len = header_len
        .checked_add(payload_len)
        .ok_or("frame overflow")?;
    if full_len != frame.len() {
        return Err("frame length mismatch".into());
    }
    if crc_parts(&[&frame[..32], &frame[36..header_len]]) != field(frame, 32) as u32 {
        return Err("header CRC mismatch".into());
    }
    let mut alphabet = Vec::new();
    alphabet
        .try_reserve_exact(alphabet_len)
        .map_err(|_| "alphabet allocation failed")?;
    let mut seen = [false; 257];
    for pair in frame[36..header_len].chunks_exact(2) {
        let s = u16::from_le_bytes([pair[0], pair[1]]);
        if s > 256 || seen[s as usize] {
            return Err("invalid/duplicate alphabet symbol".into());
        }
        seen[s as usize] = true;
        alphabet.push(s);
    }
    if !seen[0] {
        return Err("alphabet lacks sentinel".into());
    }
    let payload = &frame[header_len..];
    if crc_parts(&[payload]) != payload_crc {
        return Err("payload CRC mismatch".into());
    }
    let (last, runs) = decode_payload(
        payload,
        &alphabet,
        length.checked_add(1).ok_or("transform length overflow")?,
    )?;
    let plain = inverse_bwt(&last, primary, &alphabet)?;
    if plain.len() != length || crc_parts(&[&plain]) != plain_crc {
        return Err("plain length/CRC mismatch".into());
    }
    Ok((
        plain,
        Stats {
            runs,
            primary,
            alphabet: alphabet_len,
            payload: payload_len,
            plain_crc,
            payload_crc,
        },
    ))
}

fn main_run() -> Result<()> {
    let args: Vec<_> = std::env::args_os().collect();
    if args.len() != 4 {
        return Err("usage: khc_bwt_binary_mix_lab encode|decode input output".into());
    }
    let operation = args[1].to_str().ok_or("invalid operation")?;
    let limit = match operation {
        "encode" => MAX_INPUT,
        "decode" => MAX_FRAME,
        _ => return Err("unknown operation".into()),
    };
    let input = read_bounded(Path::new(&args[2]), limit)?;
    let (output, s) = if operation == "encode" {
        encode(&input)?
    } else {
        decode(&input)?
    };
    #[cfg(khc_site_probe)]
    let diagnostic_rank_json = site_probe::rank_json()?;
    #[cfg(khc_site_probe)]
    let diagnostic_shadow_json = site_probe::shadow_json(s.alphabet)?;
    #[cfg(all(khc_site_probe, khc_identity_probe))]
    let diagnostic_identity_json = identity_probe::finish_json(s.alphabet)?;
    #[cfg(all(khc_site_probe, khc_exponent_probe))]
    let diagnostic_exponent_json = exponent_probe::finish_json(s.alphabet)?;
    #[cfg(all(khc_site_probe, khc_semantic_probe))]
    let diagnostic_semantic_json = semantic_probe::finish_json(s.alphabet)?;
    #[cfg(all(khc_site_probe, khc_cts_probe))]
    let diagnostic_cts_json = cts_probe::finish_json(s.alphabet)?;
    #[cfg(all(khc_site_probe, khc_cts_probe, khc_bayes_probe))]
    let diagnostic_bayes_json = {
        let frame = if operation == "encode" { &output } else { &input };
        let alphabet_bytes = frame.get(36..36 + 2 * s.alphabet)
            .ok_or("Bayes original alphabet truncated")?;
        let alphabet: Vec<u16> = alphabet_bytes.chunks_exact(2)
            .map(|pair| u16::from_le_bytes([pair[0], pair[1]])).collect();
        bayes_probe::finish_json(&alphabet)?
    };
    publish(Path::new(&args[3]), &output)?;
    println!(
        "{{\"operation\":\"{operation}\",\"input_bytes\":{},\"output_bytes\":{},\"runs\":{},\"primary\":{},\"alphabet_symbols\":{},\"payload_bytes\":{},\"plain_crc\":{},\"payload_crc\":{}}}",
        input.len(),
        output.len(),
        s.runs,
        s.primary,
        s.alphabet,
        s.payload,
        s.plain_crc,
        s.payload_crc
    );
    #[cfg(khc_site_probe)]
    if operation == "encode" {
        site_probe::emit(
            &diagnostic_rank_json,
            &diagnostic_shadow_json,
            #[cfg(khc_identity_probe)]
            &diagnostic_identity_json,
            #[cfg(khc_exponent_probe)]
            &diagnostic_exponent_json,
            #[cfg(khc_semantic_probe)]
            &diagnostic_semantic_json,
            #[cfg(khc_cts_probe)]
            &diagnostic_cts_json,
            #[cfg(khc_bayes_probe)]
            &diagnostic_bayes_json,
        );
    }
    Ok(())
}

fn main() {
    if let Err(error) = main_run() {
        eprintln!("rejected: {error}");
        std::process::exit(1);
    }
}
