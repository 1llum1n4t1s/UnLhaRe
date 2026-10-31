//! 有界LZ＋整数適応range。初段の独立試作を採用前の明示経路へ統合する。
//! LZMA等に近い既存技術の組合せであり、新圧縮原理ではない。
use super::{MAX_INPUT as MAX, Result, allocate as allocated, multi_range as range};
struct Models {
    p: Vec<u16>,
    base: usize,
    context: u8,
}
impl Models {
    fn new(context: u8) -> Result<Self> {
        if !matches!(context, 3 | 8) {
            return Err("literal context".into());
        }
        let base = (1usize << context) * 256;
        Ok(Self {
            p: allocated(base + 20 + 2 * 1056, 16384)?,
            base,
            context,
        })
    }
    fn update(&mut self, index: usize, bit: u32) {
        let p = u32::from(self.p[index]);
        self.p[index] = if bit == 0 {
            p + ((32768 - p) >> 5)
        } else {
            p - (p >> 5)
        } as u16;
    }
    fn write(&mut self, r: &mut range::Encoder, index: usize, bit: u32) -> Result<()> {
        let p = u32::from(self.p[index]);
        let (c, f) = if bit == 0 { (0, p) } else { (p, 32768 - p) };
        r.interval(c, f, 32768)?;
        self.update(index, bit);
        Ok(())
    }
    fn read(&mut self, r: &mut range::Decoder<'_>, index: usize) -> Result<u32> {
        let p = u32::from(self.p[index]);
        let bit = u32::from(r.slot(32768)? >= p);
        let (c, f) = if bit == 0 { (0, p) } else { (p, 32768 - p) };
        r.consume(c, f, 32768)?;
        self.update(index, bit);
        Ok(bit)
    }
    fn tree_write(
        &mut self,
        r: &mut range::Encoder,
        base: usize,
        value: u32,
        bits: usize,
    ) -> Result<()> {
        let mut prefix = 1;
        for b in (0..bits).rev() {
            let bit = (value >> b) & 1;
            self.write(r, base + prefix, bit)?;
            prefix = prefix * 2 + bit as usize;
        }
        Ok(())
    }
    fn tree_read(&mut self, r: &mut range::Decoder<'_>, base: usize, bits: usize) -> Result<u32> {
        let mut prefix = 1;
        for _ in 0..bits {
            let bit = self.read(r, base + prefix)?;
            prefix = prefix * 2 + bit as usize;
        }
        Ok((prefix - (1 << bits)) as u32)
    }
    fn number_write(&mut self, r: &mut range::Encoder, class: usize, value: usize) -> Result<()> {
        let log = usize::BITS as usize - 1 - value.leading_zeros() as usize;
        let base = self.base + 20 + class * 1056;
        self.tree_write(r, base, log as u32, 5)?;
        for b in (0..log).rev() {
            self.write(r, base + 32 + log * 32 + b, ((value >> b) & 1) as u32)?;
        }
        Ok(())
    }
    fn number_read(
        &mut self,
        r: &mut range::Decoder<'_>,
        class: usize,
        maximum: usize,
    ) -> Result<usize> {
        let base = self.base + 20 + class * 1056;
        let log = self.tree_read(r, base, 5)? as usize;
        if log > 20 {
            return Err("number log bound".into());
        }
        let mut value = 1usize << log;
        for b in (0..log).rev() {
            value |= (self.read(r, base + 32 + log * 32 + b)? as usize) << b;
        }
        if value > maximum {
            return Err("number value bound".into());
        }
        Ok(value)
    }
    fn literal_write(&mut self, r: &mut range::Encoder, previous: u8, byte: u8) -> Result<()> {
        let base = usize::from(previous >> (8 - self.context)) * 256;
        self.tree_write(r, base, u32::from(byte), 8)
    }
    fn literal_read(&mut self, r: &mut range::Decoder<'_>, previous: u8) -> Result<u8> {
        let base = usize::from(previous >> (8 - self.context)) * 256;
        Ok(self.tree_read(r, base, 8)? as u8)
    }
}
fn hash(raw: &[u8], i: usize) -> usize {
    let v = u32::from(raw[i]) | u32::from(raw[i + 1]) << 8 | u32::from(raw[i + 2]) << 16;
    (v.wrapping_mul(0x1e35a7bd) >> 16) as usize
}
fn remember(reps: &mut [usize; 4], distance: usize) {
    let index = reps.iter().position(|&v| v == distance).unwrap_or(3);
    reps.copy_within(0..index, 1);
    reps[0] = distance;
}

// BEAM HELPERS BEGIN
const WINDOW: usize = 16;
const WIDTH: usize = 4;
const OFFERS: usize = 8;
const PATCH: usize = 256;
#[derive(Clone, Copy)]
struct Entry {
    index: u32,
    probability: u16,
}
#[derive(Clone, Copy)]
struct Shadow {
    slots: [Entry; PATCH],
    used: usize,
}
impl Shadow {
    fn new() -> Self {
        Self {
            slots: [Entry {
                index: u32::MAX,
                probability: 0,
            }; PATCH],
            used: 0,
        }
    }
    fn slot(&self, index: usize) -> Result<usize> {
        let mut at = index.wrapping_mul(0x9e3779b1) & (PATCH - 1);
        for _ in 0..PATCH {
            let e = self.slots[at];
            if e.index == u32::MAX || e.index as usize == index {
                return Ok(at);
            }
            at = (at + 1) & (PATCH - 1);
        }
        Err("shadow full".into())
    }
    fn read(&self, model: &Models, index: usize) -> Result<u16> {
        let slot = self.slot(index)?;
        Ok(if self.slots[slot].index == u32::MAX {
            model.p[index]
        } else {
            self.slots[slot].probability
        })
    }
    fn bit(&mut self, model: &Models, index: usize, bit: u32) -> Result<u64> {
        let slot = self.slot(index)?;
        let p = if self.slots[slot].index == u32::MAX {
            if self.used >= 192 {
                return Err("shadow unique bound".into());
            }
            self.used += 1;
            u32::from(model.p[index])
        } else {
            u32::from(self.slots[slot].probability)
        };
        if p == 0 || p >= 32768 || bit > 1 {
            return Err("shadow probability".into());
        }
        let f = if bit == 0 { p } else { 32768 - p };
        let next = if bit == 0 {
            p + ((32768 - p) >> 5)
        } else {
            p - (p >> 5)
        };
        self.slots[slot] = Entry {
            index: index as u32,
            probability: next as u16,
        };
        Ok(u64::from(COST[f as usize]))
    }
    fn tree(&mut self, m: &Models, base: usize, value: usize, bits: usize) -> Result<u64> {
        let mut prefix = 1;
        let mut cost = 0;
        for b in (0..bits).rev() {
            let bit = ((value >> b) & 1) as u32;
            cost += self.bit(m, base + prefix, bit)?;
            prefix = prefix * 2 + bit as usize;
        }
        Ok(cost)
    }
    fn number(&mut self, m: &Models, class: usize, value: usize) -> Result<u64> {
        if value == 0 || value > MAX {
            return Err("shadow number".into());
        }
        let log = usize::BITS as usize - 1 - value.leading_zeros() as usize;
        let base = m.base + 20 + class * 1056;
        let mut cost = self.tree(m, base, log, 5)?;
        for b in (0..log).rev() {
            cost += self.bit(m, base + 32 + log * 32 + b, ((value >> b) & 1) as u32)?;
        }
        Ok(cost)
    }
}
const fn entropy_q8(f: u32) -> u16 {
    if f == 0 {
        return u16::MAX;
    }
    let exponent = 31 - f.leading_zeros();
    let mut x = (f as u64) << (31 - exponent);
    let mut fraction = 0;
    let mut b = 0;
    while b < 8 {
        x = (x * x) >> 31;
        fraction <<= 1;
        if x >= (1u64 << 32) {
            x >>= 1;
            fraction |= 1;
        }
        b += 1;
    }
    ((15 - exponent) * 256 - fraction) as u16
}
const fn costs() -> [u16; 32768] {
    let mut out = [0; 32768];
    let mut i = 0;
    while i < 32768 {
        out[i] = entropy_q8(i as u32);
        i += 1;
    }
    out
}
static COST: [u16; 32768] = costs();
#[derive(Clone, Copy, Default, PartialEq, Eq)]
struct Token {
    length: usize,
    distance: usize,
}
#[derive(Clone, Copy)]
struct State {
    cost: u64,
    shadow: Shadow,
    reps: [usize; 4],
    previous_match: bool,
    tokens: [Token; WINDOW],
    count: usize,
}
impl State {
    fn empty() -> Self {
        Self {
            cost: u64::MAX,
            shadow: Shadow::new(),
            reps: [1, 4, 8, 16],
            previous_match: false,
            tokens: [Token::default(); WINDOW],
            count: 0,
        }
    }
    fn next(mut self, m: &Models, raw: &[u8], at: usize, t: Token) -> Result<Self> {
        if self.count >= WINDOW || t.length == 0 || t.length > WINDOW || at + t.length > raw.len() {
            return Err("beam token extent".into());
        }
        let matched = t.length >= 3;
        if matched && (t.distance == 0 || t.distance > at) {
            return Err("beam distance".into());
        }
        if !matched && (t.length != 1 || t.distance != 0) {
            return Err("beam literal".into());
        }
        let flag = m.base + (at & 7) + usize::from(self.previous_match) * 8;
        self.cost += self.shadow.bit(m, flag, u32::from(matched))?;
        if matched {
            let rep = self.reps.iter().position(|&d| d == t.distance);
            self.cost += self.shadow.bit(m, m.base + 16, u32::from(rep.is_none()))?;
            if let Some(index) = rep {
                self.cost += self.shadow.tree(m, m.base + 16, index, 2)?;
            } else {
                self.cost += self.shadow.number(m, 1, t.distance)?;
            }
            self.cost += self.shadow.number(m, 0, t.length - 2)?;
            remember(&mut self.reps, t.distance);
        } else {
            let previous = if at == 0 { 0 } else { raw[at - 1] };
            let base = usize::from(previous >> (8 - m.context)) * 256;
            self.cost += self.shadow.tree(m, base, usize::from(raw[at]), 8)?;
        }
        self.previous_match = matched;
        self.tokens[self.count] = t;
        self.count += 1;
        Ok(self)
    }
}
pub(super) fn scratch_bound() -> usize {
    (WINDOW + 1) * WIDTH * std::mem::size_of::<State>()
        + std::mem::size_of_val(&COST)
        + WINDOW * OFFERS * std::mem::size_of::<Token>()
        + 4 * std::mem::size_of::<State>()
}
std::thread_local! { static TRACE: std::cell::Cell<[usize;7]> = const { std::cell::Cell::new([0;7]) }; }
pub(super) fn reset_trace() {
    TRACE.with(|t| t.set([0; 7]));
}
pub(super) fn trace() -> [usize; 7] {
    TRACE.with(|t| t.get())
}
fn offer(list: &mut [Token; OFFERS], token: Token) {
    if token.length < 3 {
        return;
    }
    if let Some(i) = list.iter().position(|t| t.distance == token.distance) {
        if list[i].length >= token.length {
            return;
        }
        list[i] = token;
    } else if token.length > list[OFFERS - 1].length
        || (token.length == list[OFFERS - 1].length && token.distance < list[OFFERS - 1].distance)
    {
        list[OFFERS - 1] = token;
    } else {
        return;
    }
    list.sort_by(|a, b| b.length.cmp(&a.length).then(a.distance.cmp(&b.distance)));
}
fn search(
    raw: &[u8],
    at: usize,
    root: usize,
    reps: &[usize; 4],
    heads: &[u32],
    chain: &[u32],
    cap: usize,
    limit: usize,
    comparisons: &mut usize,
) -> Result<(Token, [Token; OFFERS])> {
    let mut best = Token {
        length: 1,
        distance: 0,
    };
    let mut offers = [Token::default(); OFFERS];
    if at + 3 > raw.len() {
        return Ok((best, offers));
    }
    let mut positions = [u32::MAX; 52];
    let mut count = 0;
    for &d in reps {
        if d <= at {
            positions[count] = (at - d) as u32;
            count += 1;
        }
    }
    for p in (root..at).rev() {
        positions[count] = p as u32;
        count += 1;
    }
    let mut p = heads[hash(raw, at)];
    for _ in 0..32 {
        if p == u32::MAX {
            break;
        }
        if p as usize >= root {
            return Err("historical chain order".into());
        }
        positions[count] = p;
        count += 1;
        p = chain[p as usize];
    }
    for &p in &positions[..count] {
        let p = p as usize;
        if p >= at {
            return Err("match chain order".into());
        }
        let mut length = 0;
        while length < cap && *comparisons < limit {
            *comparisons += 1;
            if raw[p + length] != raw[at + length] {
                break;
            }
            length += 1;
        }
        if length >= 3 {
            let t = Token {
                length,
                distance: at - p,
            };
            offer(&mut offers, t);
            if length > best.length {
                best = t;
            }
        }
        if best.length == cap || *comparisons == limit {
            break;
        }
    }
    Ok((best, offers))
}
fn retain(row: &mut [State], state: State) {
    let mut insert = row.len();
    for (i, s) in row.iter().enumerate() {
        if state.cost < s.cost {
            insert = i;
            break;
        }
    }
    if insert < row.len() {
        row.copy_within(insert..row.len() - 1, insert + 1);
        row[insert] = state;
    }
}
fn emit(
    m: &mut Models,
    r: &mut range::Encoder,
    raw: &[u8],
    at: usize,
    t: Token,
    reps: &mut [usize; 4],
    previous_match: &mut bool,
) -> Result<()> {
    let flag = m.base + (at & 7) + usize::from(*previous_match) * 8;
    m.write(r, flag, u32::from(t.length >= 3))?;
    if t.length >= 3 {
        let rep = reps.iter().position(|&d| d == t.distance);
        m.write(r, m.base + 16, u32::from(rep.is_none()))?;
        if let Some(index) = rep {
            m.tree_write(r, m.base + 16, index as u32, 2)?;
        } else {
            m.number_write(r, 1, t.distance)?;
        }
        m.number_write(r, 0, t.length - 2)?;
        remember(reps, t.distance);
        *previous_match = true;
    } else {
        m.literal_write(r, if at == 0 { 0 } else { raw[at - 1] }, raw[at])?;
        *previous_match = false;
    }
    Ok(())
}
pub(super) fn contract() -> Result<usize> {
    if std::mem::size_of::<State>() * (WINDOW + 1) * WIDTH > 262144 || scratch_bound() > 393216 {
        return Err("beam allocation bound".into());
    }
    let mut checks = 0;
    if COST[0] != u16::MAX || COST[1] != 3840 || COST[16384] != 256 {
        return Err("entropy anchors".into());
    }
    for f in 1..32768 {
        let exact = -(f as f64 / 32768.0).log2() * 256.0;
        let difference = f64::from(COST[f]) - exact;
        if !(-0.000000001..1.000000001).contains(&difference) || (f > 1 && COST[f] > COST[f - 1]) {
            return Err("entropy oracle".into());
        }
        checks += 1;
    }
    for context in [3, 8] {
        let mut base = Models::new(context)?;
        for (i, p) in base.p.iter_mut().enumerate() {
            *p = (1 + (i * 7919 + 27) % 32767) as u16;
        }
        for byte in 0..256 {
            let raw = [0x96, byte as u8];
            let mut state = State::empty();
            state.cost = 0;
            let after = state.next(
                &base,
                &raw,
                1,
                Token {
                    length: 1,
                    distance: 0,
                },
            )?;
            let mut real = Models::new(context)?;
            real.p.clone_from(&base.p);
            let mut encoder = range::Encoder::with_limit(1024)?;
            let mut reps = state.reps;
            let mut flag = state.previous_match;
            emit(
                &mut real,
                &mut encoder,
                &raw,
                1,
                after.tokens[0],
                &mut reps,
                &mut flag,
            )?;
            for i in 0..base.p.len() {
                if real.p[i] != after.shadow.read(&base, i)? {
                    return Err("biased literal shadow drift".into());
                }
            }
            if base
                .p
                .iter()
                .enumerate()
                .any(|(i, p)| *p != (1 + (i * 7919 + 27) % 32767) as u16)
            {
                return Err("model exploration mutation".into());
            }
            checks += 1;
        }
        // 実入力の距離log19・rep移動・繰返し更新を同じwindow内で再現。
        for variant in 0..8 {
            let at = MAX - 16;
            let raw = vec![0x96; MAX];
            let sequence = [
                Token {
                    length: 3,
                    distance: at,
                },
                Token {
                    length: 3,
                    distance: at,
                },
                Token {
                    length: 3,
                    distance: 1,
                },
                Token {
                    length: 3,
                    distance: 4,
                },
                Token {
                    length: 3,
                    distance: 8,
                },
                Token {
                    length: 1,
                    distance: 0,
                },
            ];
            let mut state = State::empty();
            state.cost = 0;
            state.previous_match = variant & 1 != 0;
            if variant & 2 != 0 {
                state.reps = [at, 8, 4, 1];
            }
            let mut real = Models::new(context)?;
            real.p.clone_from(&base.p);
            let mut reps = state.reps;
            let mut flag = state.previous_match;
            let mut encoder = range::Encoder::with_limit(4096)?;
            let mut position = at;
            for token in sequence {
                state = state.next(&base, &raw, position, token)?;
                emit(
                    &mut real,
                    &mut encoder,
                    &raw,
                    position,
                    token,
                    &mut reps,
                    &mut flag,
                )?;
                position += token.length;
                for i in 0..base.p.len() {
                    if real.p[i] != state.shadow.read(&base, i)? {
                        return Err("sequence shadow drift".into());
                    }
                }
                if reps != state.reps || flag != state.previous_match {
                    return Err("shadow state drift".into());
                }
                checks += 1;
            }
        }
    }
    // 16 literal、length16、length15+literal1を非均等pで逐次実writeへ照合。
    for context in [3, 8] {
        let mut base = Models::new(context)?;
        for (i, p) in base.p.iter_mut().enumerate() {
            *p = (1 + (i * 7919 + 27) % 32767) as u16;
        }
        for pattern in 0..3 {
            let raw = vec![0x96; 48];
            let mut state = State::empty();
            state.cost = 0;
            let mut real = Models::new(context)?;
            real.p.clone_from(&base.p);
            let mut encoder = range::Encoder::with_limit(4096)?;
            let mut reps = state.reps;
            let mut flag = state.previous_match;
            let mut at = 32;
            let tokens = if pattern == 0 {
                vec![
                    Token {
                        length: 1,
                        distance: 0
                    };
                    16
                ]
            } else if pattern == 1 {
                vec![Token {
                    length: 16,
                    distance: 1,
                }]
            } else {
                vec![
                    Token {
                        length: 15,
                        distance: 1,
                    },
                    Token {
                        length: 1,
                        distance: 0,
                    },
                ]
            };
            for token in tokens {
                state = state.next(&base, &raw, at, token)?;
                emit(
                    &mut real,
                    &mut encoder,
                    &raw,
                    at,
                    token,
                    &mut reps,
                    &mut flag,
                )?;
                at += token.length;
                for i in 0..base.p.len() {
                    if real.p[i] != state.shadow.read(&base, i)? {
                        return Err("window boundary shadow drift".into());
                    }
                }
                if reps != state.reps || flag != state.previous_match {
                    return Err("window boundary rep drift".into());
                }
                checks += 1;
            }
            if at != 48 || state.shadow.used > 184 {
                return Err("window coverage/unique".into());
            }
        }
        // MAX/log20は実encoderのdistanceとして到達しないが、number helperの許容端を直接照合。
        for class in [0, 1] {
            for value in [1, 2, 14, 4094, MAX] {
                let mut shadow = Shadow::new();
                shadow.number(&base, class, value)?;
                let mut real = Models::new(context)?;
                real.p.clone_from(&base.p);
                let mut encoder = range::Encoder::with_limit(4096)?;
                real.number_write(&mut encoder, class, value)?;
                for i in 0..base.p.len() {
                    if real.p[i] != shadow.read(&base, i)? {
                        return Err("number helper boundary drift".into());
                    }
                }
                checks += 1;
            }
        }
    }
    // hash衝突、192 uniqueの許容と193個目の拒否、実model非変更。
    let model = Models::new(8)?;
    let mut shadow = Shadow::new();
    for i in 0..192 {
        shadow.bit(&model, i * 256, 0)?;
        checks += 1;
    }
    if shadow.bit(&model, 192 * 256, 0).is_ok() || model.p.iter().any(|p| *p != 16384) {
        return Err("shadow capacity isolation".into());
    }
    checks += 1;
    Ok(checks)
}
// BEAM HELPERS END
// PROFILE HELPERS BEGIN
std::thread_local! { static PROFILE: std::cell::Cell<[usize;20]> = const { std::cell::Cell::new([0;20]) }; }
pub(super) fn profile() -> [usize; 20] {
    PROFILE.with(|p| p.get())
}
fn observe(hist: &mut [usize; 20], t: Token) {
    let bucket = t.length.min(16);
    hist[bucket] += 1;
    if t.length >= 3 {
        hist[17] += t.length;
        if t.distance <= 16 {
            hist[18] += 1;
        }
    }
}
pub(super) fn greedy_profile(raw: &[u8]) -> Result<[usize; 20]> {
    if raw.len() > MAX {
        return Err("profile raw bound".into());
    }
    let mut heads = allocated(65536, u32::MAX)?;
    let mut chain = allocated(raw.len(), u32::MAX)?;
    let mut reps = [1, 4, 8, 16];
    let mut at = 0;
    let mut comparisons = 0;
    let mut hist = [0; 20];
    while at < raw.len() {
        let (token, _) = search(
            raw,
            at,
            at,
            &reps,
            &heads,
            &chain,
            (raw.len() - at).min(4096),
            raw.len() * 64,
            &mut comparisons,
        )?;
        observe(&mut hist, token);
        if token.length >= 3 {
            remember(&mut reps, token.distance);
        }
        for (i, previous) in chain.iter_mut().enumerate().skip(at).take(token.length) {
            if i + 3 <= raw.len() {
                let h = hash(raw, i);
                *previous = heads[h];
                heads[h] = i as u32;
            }
        }
        at += token.length;
    }
    hist[19] = comparisons;
    Ok(hist)
}
// PROFILE HELPERS END
// BEAM ENCODE BEGIN
pub(super) fn encode(raw: &[u8], context: u8) -> Result<Option<Vec<u8>>> {
    if raw.len() > MAX {
        return Err("raw bound".into());
    }
    let mut models = Models::new(context)?;
    let mut r = range::Encoder::with_limit(MAX * 2 + 64)?;
    let mut heads = allocated(65536, u32::MAX)?;
    let mut chain = allocated(raw.len(), u32::MAX)?;
    let mut grid = allocated((WINDOW + 1) * WIDTH, State::empty())?;
    let mut reps = [1, 4, 8, 16];
    let mut previous_match = false;
    let mut at = 0;
    let mut comparisons = 0;
    let budget = raw.len() * 64;
    let mut stats = [0usize; 7];
    stats[1] = raw.len();
    // PROFILE INIT BEGIN
    let mut histogram = [0usize; 20];
    // PROFILE INIT END
    let trial = (|| -> Result<Vec<u8>> {
        while at < raw.len() {
            let start = at;
            let before = comparisons;
            let span = (raw.len() - at).min(WINDOW);
            let (greedy, root_offers) = search(
                raw,
                at,
                at,
                &reps,
                &heads,
                &chain,
                (raw.len() - at).min(4096),
                budget,
                &mut comparisons,
            )?;
            let mut path = [Token::default(); WINDOW];
            let count;
            if greedy.length >= WINDOW {
                path[0] = greedy;
                count = 1;
            } else {
                let mut offers = [[Token::default(); OFFERS]; WINDOW];
                offers[0] = root_offers;
                let end_limit = budget.min(before + span * 64);
                if comparisons > end_limit {
                    return Err("root window budget".into());
                }
                for (position, row) in offers.iter_mut().enumerate().take(span).skip(1) {
                    let allowance = (end_limit - comparisons) / (span - position);
                    *row = search(
                        raw,
                        at + position,
                        at,
                        &reps,
                        &heads,
                        &chain,
                        span - position,
                        comparisons + allowance,
                        &mut comparisons,
                    )?
                    .1;
                }
                grid.fill(State::empty());
                let mut first = State::empty();
                first.cost = 0;
                first.reps = reps;
                first.previous_match = previous_match;
                grid[0] = first;
                for position in 0..span {
                    for slot in 0..WIDTH {
                        let source = grid[position * WIDTH + slot];
                        if source.cost == u64::MAX {
                            continue;
                        }
                        let literal = source.next(
                            &models,
                            raw,
                            at + position,
                            Token {
                                length: 1,
                                distance: 0,
                            },
                        )?;
                        stats[5] += 1;
                        retain(
                            &mut grid[(position + 1) * WIDTH..(position + 2) * WIDTH],
                            literal,
                        );
                        for mut token in offers[position] {
                            token.length = token.length.min(span - position);
                            if token.length < 3 {
                                continue;
                            }
                            let next = source.next(&models, raw, at + position, token)?;
                            stats[5] += 1;
                            let end = position + token.length;
                            retain(&mut grid[end * WIDTH..(end + 1) * WIDTH], next);
                        }
                    }
                }
                let selected = grid[span * WIDTH];
                if selected.cost == u64::MAX || selected.count == 0 {
                    return Err("beam no coverage".into());
                }
                path = selected.tokens;
                count = selected.count;
                stats[2] += 1;
                if path[0] != greedy {
                    stats[3] += 1;
                    if path[0].length < greedy.length {
                        stats[4] += 1;
                    }
                }
            }
            for &token in &path[..count] {
                // PROFILE TOKEN BEGIN
                observe(&mut histogram, token);
                // PROFILE TOKEN END
                if token.length >= 3 {
                    stats[6] += 1;
                }
                emit(
                    &mut models,
                    &mut r,
                    raw,
                    at,
                    token,
                    &mut reps,
                    &mut previous_match,
                )?;
                for (i, previous) in chain.iter_mut().enumerate().skip(at).take(token.length) {
                    if i + 3 <= raw.len() {
                        let h = hash(raw, i);
                        *previous = heads[h];
                        heads[h] = i as u32;
                    }
                }
                at += token.length;
            }
            if at <= start || at > raw.len() || (greedy.length < WINDOW && at - start != span) {
                return Err("beam commit extent".into());
            }
            if comparisons == budget && stats[1] == raw.len() {
                stats[1] = start;
            }
        }
        Ok(r.finish()?)
    })();
    // PROFILE STORE BEGIN
    histogram[19] = comparisons;
    PROFILE.with(|p| p.set(histogram));
    // PROFILE STORE END
    stats[0] = comparisons;
    TRACE.with(|t| t.set(stats));
    match trial {
        Ok(payload) if payload.len() < raw.len() => Ok(Some(payload)),
        Ok(_) => Ok(None),
        Err(e) if e == "range output limit" => Ok(None),
        Err(e) => Err(e),
    }
}
// BEAM ENCODE END

pub(super) fn decode(payload: &[u8], raw: usize, context: u8) -> Result<Vec<u8>> {
    if raw > MAX || payload.len() < 5 || payload.len() >= raw {
        return Err("LZ payload/raw extent".into());
    }
    let mut out = Vec::new();
    out.try_reserve_exact(raw)
        .map_err(|_| "LZ output allocation")?;
    let mut m = Models::new(context)?;
    let mut r = range::Decoder::new(payload)?;
    let mut reps = [1, 4, 8, 16];
    let mut previous_match = false;
    while out.len() < raw {
        let flag = m.base + (out.len() & 7) + usize::from(previous_match) * 8;
        if m.read(&mut r, flag)? == 1 {
            let distance = if m.read(&mut r, m.base + 16)? == 0 {
                let index = m.tree_read(&mut r, m.base + 16, 2)? as usize;
                reps[index]
            } else {
                m.number_read(&mut r, 1, MAX)?
            };
            let length = m.number_read(&mut r, 0, 4094)? + 2;
            if distance == 0 || distance > out.len() || length > raw - out.len() {
                return Err("match offset/extent".into());
            }
            for _ in 0..length {
                let byte = out[out.len() - distance];
                out.push(byte);
            }
            remember(&mut reps, distance);
            previous_match = true;
        } else {
            let byte = m.literal_read(&mut r, out.last().copied().unwrap_or(0))?;
            out.push(byte);
            previous_match = false;
        }
    }
    r.finish()?;
    Ok(out)
}
