mod cdf_model;
use cdf_model::ContextModel;

// oracleはFenwickを使わず、生countsの逐次和・linear searchだけで計算する。
struct Oracle { root: Vec<u32>, locals: Vec<Vec<u32>>, rescales: (u64, u64) }
impl Oracle {
    fn new(alphabet: usize) -> Self {
        Self { root: vec![1; alphabet], locals: vec![vec![0; alphabet]; 13], rescales: (0, 0) }
    }
    fn masses(&self, key: usize, limit: usize) -> Vec<u32> {
        (0..limit).map(|i| self.root[i] + 4 * self.locals[key][i]).collect()
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

fn run() {
    let mut refusals = 0usize;
    for (alphabet, keys) in [(0, 13), (258, 13), (usize::MAX, 13), (16, 0), (16, 4097), (16, usize::MAX)] {
        assert!(ContextModel::new(alphabet, keys).is_err()); refusals += 1;
    }
    // 実際のfactory境界も通すが、記録するのは件数のみ。
    assert!(ContextModel::new(1, 1).is_ok());
    assert!(ContextModel::new(257, 4096).is_ok());
    let mut fingerprint = 0xcbf29ce484222325;
    let mut events = 0;
    let mut state_values = 0;
    let mut prefix_queries = 0;
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
            let actual = model.interval(key, token, limit).unwrap();
            assert_eq!(actual, expected); prefix_queries += 1;
            let slot = (random(&mut seed) % u64::from(expected.2)) as u32;
            let expected_selection = oracle.select(key, slot, limit);
            assert_eq!(model.select(key, slot, limit).unwrap(), expected_selection);
            // 各token境界を定期的に照合し、CDF終点/切り詰めを網羅する。
            if i % 1024 == 0 {
                for token in 0..limit {
                    let interval = oracle.interval(key, token, limit);
                    assert_eq!(model.interval(key, token, limit).unwrap(), interval);
                    assert_eq!(model.select(key, interval.0, limit).unwrap().0, token);
                    assert_eq!(model.select(key, interval.0 + interval.1 - 1, limit).unwrap().0, token);
                    prefix_queries += 1;
                }
            }
            for value in [alphabet, key, limit, token, actual.0 as usize, actual.1 as usize,
                actual.2 as usize, slot as usize, expected_selection.0] { mix(&mut fingerprint, value as u64); }
            let previous_rescales = oracle.rescales;
            model.update(key, token).unwrap(); oracle.update(key, token);
            if i % 1024 == 0 || i == 131071 || previous_rescales != oracle.rescales {
                state_values += compare_state(&model, &oracle, &mut fingerprint);
            }
            if i % 8192 == 0 {
                let before = snapshot(&model);
                let before_rescales = model.audit_rescales();
                for bad in [13, usize::MAX] {
                    assert!(model.interval(bad, 0, 1).is_err());
                    assert!(model.select(bad, 0, 1).is_err());
                    assert!(model.update(bad, 0).is_err()); refusals += 3;
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
    println!("{{\"status\":\"passed\",\"events\":{events},\"prefix_queries\":{prefix_queries},\"state_values\":{state_values},\"refusals\":{refusals},\"root_rescales\":{root_rescales},\"local_rescales\":{local_rescales},\"fingerprint\":\"{fingerprint:016x}\"}}");
}

fn main() {
    if std::env::args().skip(1).next().is_some() {
        eprintln!("arguments are not accepted"); std::process::exit(2);
    }
    run();
}
