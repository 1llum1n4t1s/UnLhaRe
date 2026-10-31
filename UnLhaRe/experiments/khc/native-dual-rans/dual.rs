//! 二つの独立stateと共有byte列を使う研究用rANS。Cコードの移植ではない。
//! 方式の一次資料: Fabian Giesen, rans_byte.h (2014, public domain)。
//! https://github.com/rygorous/ryg_rans/blob/master/rans_byte.h
//! 実装前の有限失敗条件: lane/total/c/f/tag/state境界、空・片lane・同lane連続、
//! Q8/Q15混在と逆emit/init順序、全prefix切断・末尾追加・非正規終端、consume失敗時の
//! 両state/cursor不変、event cap直外を一度、旧cap+次capの事前支払と実cap確認。
//! 正常列は別のu64式oracleと全byteを比較して両decoderで往復する。文法のimplicit
//! step順序は呼出し側の検査責任。本fileのfinite()は(runs, rejected, rollback)を返す。
//! allocator内部の一時領域やRSSをこの論理capacity境界で保証したとは扱わない。
//! バックアップ台帳: 2026-10-08、同folderのdual-before-implementation.zipは実装前877B。
//! 対象絶対pathはC:/Users/IMT/dev/UnLhaRe/UnLhaRe/experiments/khc/native-dual-rans/dual.rs。
//! 復元はzip内dual.rsの内容を対象へ戻す。新規fileの失敗条件宣言だけを保存した。
//! 改稿前exactbackup: 同folder dual-before-compact.zip（初稿16698B、SHA照合済）。

// 有限検査は実装より先に宣言する。oracleは別のu64式と別の配置手順を使う。
type Row = (usize, u32, u32, u32);
pub(crate) fn finite() -> Result<(usize, usize, usize), &'static str> {
    let (mut runs, mut rejected, mut rollback) = (0, 0, 0);
    let mut trace = Vec::new();
    for n in [0, 1, 2, 7, 31, 257] {
        for mode in 0..6 {
            let mut rows = Vec::new();
            rows.try_reserve_exact(n).map_err(|_| "finite allocation")?;
            let mut seed = 0x67452301_u32;
            for i in 0..n {
                seed = seed.wrapping_mul(1664525).wrapping_add(1013904223);
                let lane = match mode { 0 => 0, 1 => 1, 2 => i % 2, 3 => (i / 9) % 2, 4 => usize::from(i % 5 != 0), _ => ((seed >> 30) & 1) as usize };
                let total = if i % 3 == 0 { 256 } else { 32768 };
                let f = match i % 4 { 0 => 1, 1 => total / 2, 2 => total - 1, _ => total };
                rows.push((lane, seed % (total - f + 1), f, total));
            }
            check_rows(&rows)?;
            runs += 1;
            if n == 257 && mode == 5 { trace = rows; }
        }
    }
    for limit in [0, 7, (1 << 20) + 1, usize::MAX] {
        need(Encoder::with_limit(limit).is_err(), "finite output limit")?;
        rejected += 1;
    }
    let bad = [(2, 0, 1, 256), (usize::MAX, 0, 1, 256), (0, 0, 0, 256), (1, 256, 1, 256),
        (0, 0, 257, 256), (1, u32::MAX, 1, 32768), (0, 1, u32::MAX, 32768),
        (0, 0, 1, 0), (0, 0, 1, 255), (1, 0, 1, 65536), (0, 32768, 1, 32768)];
    let wire = oracle_encode(&trace)?;
    let mut encoder = Encoder::with_limit(1 << 20)?;
    let mut decoder = Decoder::new(&wire)?;
    for &(lane, c, f, total) in &bad {
        let before = (encoder.event_count(), encoder.capacity_bytes());
        need(encoder.interval(lane, c, f, total).is_err(), "finite accepted invalid interval")?;
        need(before == (encoder.event_count(), encoder.capacity_bytes()), "finite encoder rollback")?;
        let before = (decoder.states, decoder.position);
        need(decoder.consume(lane, c, f, total).is_err(), "finite accepted invalid consume")?;
        need(before == (decoder.states, decoder.position), "finite consume rollback")?;
        rejected += 2;
        rollback += 2;
    }
    for (lane, total) in [(2, 256), (usize::MAX, 32768), (0, 0), (1, 255), (0, 65536)] {
        need(decoder.slot(lane, total).is_err(), "finite invalid slot")?;
        rejected += 1;
    }
    let slot = decoder.slot(0, 256)?;
    let before = (decoder.states, decoder.position);
    need(decoder.consume(0, (slot + 1) % 256, 1, 256).is_err(), "finite wrong interval")?;
    need(before == (decoder.states, decoder.position), "finite wrong interval rollback")?;
    rejected += 1;
    rollback += 1;
    for tag in [0, 7, 16, 0x208, 0xff0f] {
        let mut encoder = Encoder::with_limit(8)?;
        encoder.interval(0, 0, 256, 256)?;
        encoder.events[0].tag = tag;
        need(encoder.finish().is_err(), "finite invalid tag")?;
        rejected += 1;
    }
    for (c, f) in [(0, 0), (256, 1), (0, 257)] {
        let mut encoder = Encoder::with_limit(8)?;
        encoder.interval(0, 0, 256, 256)?;
        encoder.events[0].cumulative = c;
        encoder.events[0].frequency = f;
        need(encoder.finish().is_err(), "finite corrupted event")?;
        rejected += 1;
    }
    let empty = oracle_encode(&[])?;
    for lane in 0..2 {
        for state in [0, LOWER - 1, UPPER, u32::MAX] {
            let mut bytes = empty.clone();
            bytes[lane * 4..lane * 4 + 4].copy_from_slice(&state.to_le_bytes());
            need(Decoder::new(&bytes).is_err(), "finite initial state")?;
            rejected += 1;
        }
        let mut bytes = empty.clone();
        bytes[lane * 4..lane * 4 + 4].copy_from_slice(&(LOWER + 1).to_le_bytes());
        need(Decoder::new(&bytes)?.finish().is_err(), "finite noncanonical state")?;
        rejected += 1;
    }
    // 各切断prefixの初期化/consume/finishいずれかが拒否し、consume失敗は完全rollbackする。
    for end in 0..wire.len() {
        let mut failed = false;
        match Decoder::new(&wire[..end]) {
            Err(_) => failed = true,
            Ok(mut decoder) => {
                for &(lane, c, f, total) in &trace {
                    let before = (decoder.states, decoder.position);
                    if decoder.consume(lane, c, f, total).is_err() {
                        need(before == (decoder.states, decoder.position), "finite truncated rollback")?;
                        rollback += 1;
                        failed = true;
                        break;
                    }
                }
                if !failed { failed = decoder.finish().is_err(); }
            }
        }
        need(failed, "finite accepted truncated prefix")?;
        rejected += 1;
    }
    let mut trailing = wire.clone();
    trailing.push(0);
    let mut decoder = Decoder::new(&trailing)?;
    for &(lane, c, f, total) in &trace { decoder.consume(lane, c, f, total)?; }
    need(decoder.finish().is_err(), "finite trailing bytes")?;
    rejected += 1;
    let mut too_small = Encoder::with_limit(8)?;
    too_small.interval(1, 0, 1, 32768)?;
    need(too_small.finish().is_err(), "finite insufficient output")?;
    rejected += 1;
    need(live_bytes(MAX_EVENTS / 2, MAX_EVENTS)? == MAX_LIVE_BYTES, "finite overlap boundary")?;
    for (old, next) in [(MAX_EVENTS / 2 + 1, MAX_EVENTS), (0, MAX_EVENTS + 1), (usize::MAX, 1)] {
        need(live_bytes(old, next).is_err(), "finite overlap prepay")?;
        rejected += 1;
    }
    // 上限到達は一度だけ。全域intervalは恒等写像なので独立oracleの空列と全byte一致する。
    let mut cap = Encoder::with_limit(8)?;
    for i in 0..MAX_EVENTS { cap.interval(i % 2, 0, 32768, 32768)?; }
    let before = (cap.event_count(), cap.capacity_bytes(), cap.allocation_transient());
    need(cap.interval(0, 0, 1, 256).is_err(), "finite event cap")?;
    need(before == (cap.event_count(), cap.capacity_bytes(), cap.allocation_transient()), "finite cap rollback")?;
    need(before.1 + before.2 <= MAX_LIVE_BYTES, "finite actual capacity")?;
    need(cap.finish()? == empty, "finite full frequency identity")?;
    rejected += 1;
    rollback += 1;
    Ok((runs, rejected, rollback))
}

fn need(ok: bool, error: &'static str) -> Result<(), &'static str> { if ok { Ok(()) } else { Err(error) } }
fn check_rows(rows: &[Row]) -> Result<(), &'static str> {
    let mut encoder = Encoder::with_limit(1 << 20)?;
    for &(lane, c, f, total) in rows { encoder.interval(lane, c, f, total)?; }
    let bytes = encoder.finish()?;
    need(bytes == oracle_encode(rows)?, "finite oracle byte mismatch")?;
    oracle_decode(&bytes, rows)?;
    let mut decoder = Decoder::new(&bytes)?;
    for &(lane, c, f, total) in rows {
        let other = decoder.states[1 - lane];
        let slot = decoder.slot(lane, total)?;
        need((c..c + f).contains(&slot), "finite interval roundtrip")?;
        decoder.consume(lane, c, f, total)?;
        need(decoder.states[1 - lane] == other, "finite other lane changed")?;
    }
    decoder.finish()
}
fn oracle_encode(rows: &[Row]) -> Result<Vec<u8>, &'static str> {
    let mut states = [8388608_u64; 2];
    let mut emitted = Vec::new();
    emitted.try_reserve_exact(rows.len() * 2 + 8).map_err(|_| "oracle allocation")?;
    for &(lane, c, f, total) in rows.iter().rev() {
        let bits = match total { 256 => 8, 32768 => 15, _ => return Err("oracle total") };
        need(lane < 2 && f != 0 && u64::from(c) + u64::from(f) <= u64::from(total), "oracle interval")?;
        let x = &mut states[lane];
        let threshold = (1_u64 << (31 - bits)) * u64::from(f);
        while *x >= threshold { emitted.push((*x % 256) as u8); *x /= 256; }
        *x = u64::from(total) * (*x / u64::from(f)) + *x % u64::from(f) + u64::from(c);
        need((8388608..2147483648).contains(x), "oracle state")?;
    }
    // oracleは先頭state列を先に構成する。実装の全reverseとは異なる配置手順。
    let mut bytes = Vec::new();
    bytes.try_reserve_exact(8 + emitted.len()).map_err(|_| "oracle allocation")?;
    for state in states { bytes.extend_from_slice(&(state as u32).to_le_bytes()); }
    bytes.extend(emitted.into_iter().rev());
    Ok(bytes)
}
fn oracle_decode(bytes: &[u8], rows: &[Row]) -> Result<(), &'static str> {
    need(bytes.len() >= 8, "oracle prefix")?;
    let mut states = [0_u64; 2];
    for lane in 0..2 {
        for i in 0..4 { states[lane] += u64::from(bytes[4 * lane + i]) * (1_u64 << (8 * i)); }
    }
    let mut cursor = 8;
    for &(lane, c, f, total) in rows {
        let x = states[lane];
        let residue = x % u64::from(total);
        need(residue >= u64::from(c) && residue < u64::from(c) + u64::from(f), "oracle decode interval")?;
        let mut next = u64::from(f) * (x / u64::from(total)) + residue - u64::from(c);
        while next < 8388608 {
            next = next * 256 + u64::from(*bytes.get(cursor).ok_or("oracle truncated")?);
            cursor += 1;
        }
        need(next < 2147483648, "oracle decode state")?;
        states[lane] = next;
    }
    need(states == [8388608; 2] && cursor == bytes.len(), "oracle termination")
}

const LOWER: u32 = 1 << 23;
const UPPER: u32 = 1 << 31;
pub(crate) const MAX_EVENTS: usize = 2 * 1024 * 1024;
pub(crate) const MAX_LIVE_BYTES: usize = 18 * 1048576;
#[derive(Clone, Copy)]
#[repr(C)]
struct Event { cumulative: u16, frequency: u16, tag: u16 }
const _: () = assert!(std::mem::size_of::<Event>() == 6);
fn valid(lane: usize, c: u32, f: u32, total: u32) -> Result<u8, &'static str> {
    if lane >= 2 { return Err("invalid ANS lane"); }
    let bits = match total { 256 => 8, 32768 => 15, _ => return Err("invalid ANS total") };
    if f == 0 || c.checked_add(f).is_none_or(|end| end > total) { return Err("invalid ANS interval"); }
    Ok(bits)
}
fn live_bytes(old: usize, next: usize) -> Result<usize, &'static str> {
    let bytes = old.checked_add(next).and_then(|n| n.checked_mul(6)).ok_or("ANS allocation overflow")?;
    if next > MAX_EVENTS || bytes > MAX_LIVE_BYTES { return Err("ANS allocation overlap"); }
    Ok(bytes)
}
pub(crate) struct Encoder { events: Vec<Event>, limit: usize, old_capacity_peak: usize, poisoned: bool }
impl Encoder {
    pub(crate) fn with_limit(limit: usize) -> Result<Self, &'static str> {
        if !(8..=1 << 20).contains(&limit) { return Err("ANS output bound"); }
        Ok(Self { events: Vec::new(), limit, old_capacity_peak: 0, poisoned: false })
    }
    pub(crate) fn interval(&mut self, lane: usize, c: u32, f: u32, total: u32) -> Result<(), &'static str> {
        let bits = valid(lane, c, f, total)?;
        if self.poisoned { return Err("ANS invalid allocation capacity"); }
        if self.events.len() >= MAX_EVENTS { return Err("ANS journal limit"); }
        if self.events.len() == self.events.capacity() {
            let old = self.events.capacity();
            let next = old.checked_mul(2).ok_or("ANS capacity overflow")?.max(1024).min(MAX_EVENTS);
            live_bytes(old, next)?;
            self.events.try_reserve_exact(next - self.events.len()).map_err(|_| "ANS allocation failed")?;
            self.old_capacity_peak = self.old_capacity_peak.max(old);
            if live_bytes(old, self.events.capacity()).is_err() {
                self.poisoned = true;
                return Err("ANS actual allocation capacity");
            }
        }
        self.events.push(Event { cumulative: c as u16, frequency: f as u16, tag: ((lane as u16) << 8) | u16::from(bits) });
        Ok(())
    }
    pub(crate) fn capacity_bytes(&self) -> usize { self.events.capacity() * 6 }
    // 実装が記録する旧journal容量ピーク。現容量との和を論理live上限と照合する。
    pub(crate) fn allocation_transient(&self) -> usize { self.old_capacity_peak * 6 }
    pub(crate) fn event_count(&self) -> usize { self.events.len() }
    pub(crate) fn finish(self) -> Result<Vec<u8>, &'static str> {
        if self.poisoned { return Err("ANS invalid allocation capacity"); }
        if self.capacity_bytes().checked_add(self.limit).is_none_or(|bytes| bytes > MAX_LIVE_BYTES) { return Err("ANS output prepay"); }
        let mut output = Vec::new();
        output.try_reserve_exact(self.limit).map_err(|_| "ANS output allocation failed")?;
        if output.capacity() > self.limit { return Err("ANS output capacity"); }
        let mut states = [LOWER; 2];
        for event in self.events.iter().rev() {
            let lane = usize::from(event.tag >> 8);
            let total = match event.tag & 255 { 8 => 256, 15 => 32768, _ => return Err("invalid ANS tag") };
            let c = u32::from(event.cumulative);
            let f = u32::from(event.frequency);
            let bits = valid(lane, c, f, total)?;
            let mut state = states[lane];
            let maximum = ((LOWER >> bits) << 8) * f;
            while state >= maximum {
                if output.len() >= self.limit - 8 { return Err("ANS output limit"); }
                output.push(state as u8);
                state >>= 8;
            }
            let next = (state / f).checked_mul(total).and_then(|x| x.checked_add(state % f)).and_then(|x| x.checked_add(c))
                .ok_or("ANS encode overflow")?;
            if !(LOWER..UPPER).contains(&next) { return Err("ANS encoded state"); }
            states[lane] = next;
        }
        for lane in [1, 0] { output.extend(states[lane].to_le_bytes().into_iter().rev()); }
        output.reverse();
        Ok(output)
    }
}
pub(crate) struct Decoder<'a> { input: &'a [u8], position: usize, states: [u32; 2] }
impl<'a> Decoder<'a> {
    pub(crate) fn new(input: &'a [u8]) -> Result<Self, &'static str> {
        if input.len() < 8 { return Err("truncated ANS prefix"); }
        let mut states = [0; 2];
        for lane in 0..2 {
            states[lane] = u32::from_le_bytes(input[lane * 4..lane * 4 + 4].try_into().map_err(|_| "ANS initial state")?);
            if !(LOWER..UPPER).contains(&states[lane]) { return Err("invalid ANS initial state"); }
        }
        Ok(Self { input, position: 8, states })
    }
    pub(crate) fn slot(&self, lane: usize, total: u32) -> Result<u32, &'static str> {
        valid(lane, 0, 1, total)?;
        Ok(self.states[lane] & (total - 1))
    }
    pub(crate) fn consume(&mut self, lane: usize, c: u32, f: u32, total: u32) -> Result<(), &'static str> {
        let bits = valid(lane, c, f, total)?;
        let slot = self.states[lane] & (total - 1);
        if slot < c || slot >= c + f { return Err("ANS slot outside interval"); }
        let mut state = f.checked_mul(self.states[lane] >> bits).and_then(|x| x.checked_add(slot - c)).ok_or("ANS decode overflow")?;
        let mut position = self.position;
        while state < LOWER {
            let byte = *self.input.get(position).ok_or("truncated ANS stream")?;
            position = position.checked_add(1).ok_or("ANS cursor overflow")?;
            state = (state << 8) | u32::from(byte);
        }
        if state >= UPPER { return Err("ANS decoded state"); }
        // 選択laneと共有cursorの変更は成功時にのみcommitする。他laneは触れない。
        self.states[lane] = state;
        self.position = position;
        Ok(())
    }
    pub(crate) fn finish(&self) -> Result<(), &'static str> {
        if self.position != self.input.len() { return Err("trailing ANS bytes"); }
        if self.states != [LOWER; 2] { return Err("noncanonical ANS termination"); }
        Ok(())
    }
}
