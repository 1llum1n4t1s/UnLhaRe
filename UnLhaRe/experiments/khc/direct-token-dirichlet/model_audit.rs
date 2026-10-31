mod cdf_model;
mod mixture_math;
use mixture_math::MixtureScale;
use cdf_model::ContextModel;

// oracleはFenwickを使わず、生countsの逐次和・linear searchだけで計算する。
struct Oracle { root: Vec<u32>, locals: Vec<Vec<u32>>, rescales: (u64, u64) }
impl Oracle {
    fn new(alphabet: usize) -> Self {
        Self { root: vec![1; alphabet], locals: vec![vec![0; alphabet]; 13], rescales: (0, 0) }
    }
    fn masses(&self, key: usize, limit: usize) -> Vec<u32> {
        // 通常u32除算で全prefixを丸める。候補のscale/Fenwickは使用しない。
        let divisor: u32 = self.root.iter().sum();
        let local_total: u32 = self.locals[key].iter().sum();
        let (mut root_prefix, mut local_prefix, mut previous) = (0u32, 0u32, 0u32);
        (0..limit).map(|i| {
            root_prefix += self.root[i]; local_prefix += self.locals[key][i];
            let cumulative = (i + 1) as u32 + ((32768u128 * (64 * u128::from(root_prefix) + u128::from(divisor) * u128::from(local_prefix))) / (u128::from(divisor) * (64 + u128::from(local_total)))) as u32;
            let frequency = cumulative - previous; previous = cumulative;
            assert!(frequency > 0); frequency
        }).collect()
    }
    fn interval(&self, key: usize, token: usize, limit: usize) -> (u32, u32, u32) {
        let masses = self.masses(key, limit);
        (masses[..token].iter().sum(), masses[token], masses.iter().sum())
    }
    fn select(&self, key: usize, slot: u32, limit: usize) -> (usize, u32, u32, u32) {
        let masses = self.masses(key, limit);
        let total = masses.iter().sum();
        let mut prefix = 0;
        for (token, frequency) in masses.into_iter().enumerate() {
            if slot < prefix + frequency { return (token, prefix, frequency, total); }
            prefix += frequency;
        }
        panic!("oracle slot");
    }
    fn update(&mut self, key: usize, token: usize) {
        self.root[token] += 1;
        self.locals[key][token] += 1;
        if self.root.iter().sum::<u32>() == 16384 {
            for count in &mut self.root { *count = (*count + 1) / 2; }
            self.rescales.0 += 1;
        }
        if self.locals[key].iter().sum::<u32>() == 16384 {
            for count in &mut self.locals[key] { *count = (*count + 1) / 2; }
            self.rescales.1 += 1;
        }
    }
}

fn mix(hash: &mut u64, value: u64) { *hash = (*hash ^ value).wrapping_mul(0x100000001b3); }
fn random(state: &mut u64) -> u64 {
    *state ^= *state << 13; *state ^= *state >> 7; *state ^= *state << 17; *state
}
fn compare_state(model: &ContextModel, oracle: &Oracle, hash: &mut u64) -> usize {
    let mut checked = 0;
    for (key, counts) in std::iter::once((None, &oracle.root))
        .chain(oracle.locals.iter().enumerate().map(|(i, counts)| (Some(i), counts)))
    {
        let actual = model.audit_counts(key).unwrap();
        assert_eq!(actual.len(), counts.len());
        for (&actual, &expected) in actual.iter().zip(counts) {
            assert_eq!(u32::from(actual), expected);
            mix(hash, u64::from(actual)); checked += 1;
        }
    }
    assert_eq!(model.audit_rescales(), oracle.rescales);
    checked
}
fn snapshot(model: &ContextModel) -> Vec<u16> {
    (0..14).flat_map(|i| model.audit_counts(if i == 0 { None } else { Some(i - 1) })
        .unwrap().iter().copied()).collect()
}

fn scale_audit(hash: &mut u64) -> (u64, u64, u64) {
    let (mut comparisons, mut corrections, mut refusals) = (0u64, 0u64, 0u64);
    for (d,t) in [(0,0),(16384,0),(u32::MAX,0),(1,16384),(1,u32::MAX)] {
        assert!(MixtureScale::new(d,t).is_err()); refusals += 1;
    }
    let mut seed = 0x471925ac786deb13u64;
    let mut pairs = Vec::new();
    for d in [1,2,63,64,65,8191,8192,16382,16383] {
        for t in [0,1,63,64,65,8191,8192,16382,16383] { pairs.push((d,t)); }
    }
    for _ in 0..32 { pairs.push((1 + (random(&mut seed)%16383) as u32,(random(&mut seed)%16384) as u32)); }
    for (d,t) in pairs {
        let scale = MixtureScale::new(d,t).unwrap();
        let den = u64::from(d) * (64 + u64::from(t));
        let reciprocal = ((1u128 << 64) / u128::from(den)) as u64;
        assert_eq!(scale.audit_parameters(), (d,t,den,reciprocal));
        let mut check = |mass: u64| {
            let n = 32768 * u128::from(mass);
            let expected = (n / u128::from(den)) as u32;
            let actual = scale.audit_floor_mass(mass).unwrap();
            assert_eq!(actual, expected, "D={d} T={t} mass={mass}");
            let guess = (n * u128::from(reciprocal)) >> 64;
            assert!(u128::from(expected) == guess || u128::from(expected) == guess + 1);
            if u128::from(expected) == guess + 1 { corrections += 1; }
            assert!(u128::from(actual)*u128::from(den) <= n);
            assert!(n < (u128::from(actual)+1)*u128::from(den));
            assert!(actual <= 32768);
            for value in [u64::from(d),u64::from(t),mass,u64::from(actual)] { mix(hash,value); }
            comparisons += 1;
        };
        check(0); check(den);
        // 出力境界は候補の商を使わず通常u128除算で構築する。
        for q in 0..=32768u128 {
            let boundary = ((q*u128::from(den)+32767)/32768) as u64;
            for mass in [boundary.saturating_sub(1),boundary,boundary.saturating_add(1)] {
                if mass <= den { check(mass); }
            }
        }
        for (r,l) in [(0,0),(d,0),(0,t),(d,t)] {
            let expected = (32768u128*(64*u128::from(r)+u128::from(d)*u128::from(l))/u128::from(den)) as u32;
            assert_eq!(scale.floor(r,l).unwrap(),expected); comparisons += 1;
        }
        for _ in 0..64 {
            let r=(random(&mut seed)%u64::from(d+1)) as u32;
            let l=(random(&mut seed)%u64::from(t+1)) as u32;
            let expected=(32768u128*(64*u128::from(r)+u128::from(d)*u128::from(l))/u128::from(den)) as u32;
            assert_eq!(scale.floor(r,l).unwrap(),expected); comparisons += 1;
        }
        for mass in [den+1,u64::MAX] {
            let before=scale.audit_parameters();
            assert!(scale.audit_floor_mass(mass).is_err()); refusals += 1;
            assert_eq!(scale.audit_parameters(),before);
        }
        for (r,l) in [(d+1,0),(u32::MAX,0),(0,t+1),(0,u32::MAX)] {
            assert!(scale.floor(r,l).is_err()); refusals += 1;
        }
        assert_eq!(scale.floor(d,t).unwrap(),32768);
    }
    assert!(comparisons >= 8_000_000 && corrections > 0);
    (comparisons,corrections,refusals)
}
fn run() {
    let mut witness_model = ContextModel::new(256, 2).unwrap();
    for _ in 0..8192 { witness_model.update(0,0).unwrap(); }
    let cold_hot_expected = 1 + (32768u128 * 8193 / 8448) as u32;
    let cold_hot_actual = witness_model.prepare(1,256).unwrap().interval(0).unwrap();
    assert_eq!(cold_hot_actual,(0,cold_hot_expected,33024));
    assert!(witness_model.audit_counts(Some(1)).unwrap().iter().all(|&v| v == 0));
    let mut refusals = 0usize;
    for (alphabet, keys) in [(0, 13), (258, 13), (usize::MAX, 13), (16, 0), (16, 4097), (16, usize::MAX)] {
        assert!(ContextModel::new(alphabet, keys).is_err()); refusals += 1;
    }
    // 実際のfactory境界も通すが、記録するのは件数のみ。
    assert!(ContextModel::new(1, 1).is_ok());
    assert!(ContextModel::new(257, 4096).is_ok());
    for alphabet in [1,16,256,257] {
        let model=ContextModel::new(alphabet,13).unwrap();
        let oracle=Oracle::new(alphabet);
        for limit in [1,alphabet] {
            let distribution=model.prepare(12,limit).unwrap();
            for token in 0..limit {
                let expected=oracle.interval(12,token,limit);
                assert_eq!(distribution.interval(token).unwrap(),expected);
                assert_eq!(distribution.total(),expected.2);
                for slot in [expected.0,expected.0+expected.1-1] {
                    assert_eq!(distribution.select(slot).unwrap(),oracle.select(12,slot,limit));
                }
            }
            assert!(distribution.select(distribution.total()).is_err());
        }
    }
    let mut fingerprint = 0xcbf29ce484222325;
    let (scale_comparisons, correction_witnesses, scale_refusals) = scale_audit(&mut fingerprint);
    let mut cold_hot_witnesses = 0;
    let mut events = 0;
    let mut state_values = 0;
    let mut prefix_queries = 0;
    let mut selection_queries = 0;
    let mut root_rescales = 0;
    let mut local_rescales = 0;
    for alphabet in [16, 256, 257] {
        let mut model = ContextModel::new(alphabet, 13).unwrap();
        let mut oracle = Oracle::new(alphabet);
        let mut seed = 0x913725ca5d3eab1d ^ alphabet as u64;
        for i in 0..131072 {
            let key = if i < 65536 { 0 } else { random(&mut seed) as usize % 13 };
            let limit = match i % 17 { 0 => 1, 1 => alphabet, _ => 1 + random(&mut seed) as usize % alphabet };
            let token = if i < 8192 { 0 } else if i < 16384 {
                if i % 2 == 0 { 0 } else { limit - 1 }
            } else { random(&mut seed) as usize % limit };
            let expected = oracle.interval(key, token, limit);
            let distribution = model.prepare(key,limit).unwrap();
            let actual = distribution.interval(token).unwrap();
            assert_eq!(actual,model.interval(key,token,limit).unwrap());
            assert_eq!(distribution.total(),expected.2);
            assert_eq!(actual, expected, "interval alphabet={alphabet} event={i} key={key} token={token} limit={limit}");
            assert!(actual.1 > 0 && actual.2 <= 33025); prefix_queries += 1;
            let slot = (random(&mut seed) % u64::from(expected.2)) as u32;
            let expected_selection = oracle.select(key, slot, limit);
            assert_eq!(distribution.select(slot).unwrap(), expected_selection, "select alphabet={alphabet} event={i} key={key} slot={slot} limit={limit}"); selection_queries += 1;
            // 各token境界を定期的に照合し、CDF終点/切り詰めを網羅する。
            if i % 1024 == 0 {
                for token in 0..limit {
                    let interval = oracle.interval(key, token, limit);
                    assert_eq!(model.interval(key, token, limit).unwrap(), interval);
                    assert_eq!(model.select(key, interval.0, limit).unwrap().0, token);
                    assert_eq!(model.select(key, interval.0 + interval.1 - 1, limit).unwrap().0, token);
                    prefix_queries += 1; selection_queries += 2;
                }
            }
            for value in [alphabet, key, limit, token, actual.0 as usize, actual.1 as usize,
                actual.2 as usize, slot as usize, expected_selection.0] { mix(&mut fingerprint, value as u64); }
            drop(distribution);
            if i == 8191 {
                let cold = model.prepare(12,alphabet).unwrap();
                assert_eq!(cold.interval(0).unwrap(),oracle.interval(12,0,alphabet));
                assert!(cold.interval(0).unwrap().1 > 30000);
                assert!(model.audit_counts(Some(12)).unwrap().iter().all(|&v| v == 0));
                cold_hot_witnesses += 1;
            }
            let previous_rescales = oracle.rescales;
            model.update(key, token).unwrap(); oracle.update(key, token);
            if i % 1024 == 0 || i == 131071 || previous_rescales != oracle.rescales {
                state_values += compare_state(&model, &oracle, &mut fingerprint);
            }
            if i % 8192 == 0 {
                let before = snapshot(&model);
                for bad in [13,usize::MAX] { assert!(model.prepare(bad,1).is_err()); }
                for bad in [0,alphabet+1,usize::MAX] { assert!(model.prepare(0,bad).is_err()); }
                let prepared=model.prepare(0,1).unwrap();
                assert!(prepared.interval(1).is_err());
                assert!(prepared.select(prepared.total()).is_err());
                assert!(prepared.select(u32::MAX).is_err());
                let before_rescales = model.audit_rescales();
                for bad in [13, usize::MAX] {
                    assert!(model.interval(bad, 0, 1).is_err());
                    assert!(model.select(bad, 0, 1).is_err());
                    assert!(model.update(bad, 0).is_err());
                    assert!(model.audit_counts(Some(bad)).is_err()); refusals += 4;
                }
                for bad in [alphabet, usize::MAX] {
                    assert!(model.interval(0, bad, alphabet).is_err());
                    assert!(model.update(0, bad).is_err()); refusals += 2;
                }
                assert!(model.interval(0, 1, 1).is_err()); refusals += 1;
                for bad in [0, alphabet + 1, usize::MAX] {
                    assert!(model.interval(0, 0, bad).is_err());
                    assert!(model.select(0, 0, bad).is_err()); refusals += 2;
                }
                let total = model.interval(0, 0, alphabet).unwrap().2;
                for bad in [total, u32::MAX] {
                    assert!(model.select(0, bad, alphabet).is_err()); refusals += 1;
                }
                assert_eq!(snapshot(&model), before);
                assert_eq!(model.audit_rescales(), before_rescales);
                assert_eq!(model.interval(key, token, limit).unwrap(), oracle.interval(key, token, limit));
            }
            events += 1;
        }
        assert!(oracle.rescales.0 > 0 && oracle.rescales.1 > 0);
        root_rescales += oracle.rescales.0; local_rescales += oracle.rescales.1;
    }
    println!("{{\"status\":\"passed\",\"events\":{events},\"prefix_queries\":{prefix_queries},\"selection_queries\":{selection_queries},\"scale_comparisons\":{scale_comparisons},\"correction_witnesses\":{correction_witnesses},\"scale_refusals\":{scale_refusals},\"state_values\":{state_values},\"refusals\":{refusals},\"root_rescales\":{root_rescales},\"local_rescales\":{local_rescales},\"cold_hot_witnesses\":{cold_hot_witnesses},\"cold_hot_frequency\":{cold_hot_expected},\"fingerprint\":\"{fingerprint:016x}\"}}");
}

fn main() {
    if std::env::args().skip(1).next().is_some() {
        eprintln!("arguments are not accepted"); std::process::exit(2);
    }
    run();
}
