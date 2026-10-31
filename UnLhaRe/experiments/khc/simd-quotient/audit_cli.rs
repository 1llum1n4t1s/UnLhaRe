//! 生recordを保存せず、独立u128除算oracleへ逐次照合する数値CLI。
mod exact_div;
use exact_div::{Q, Backend, BatchEngine};
use std::hint::black_box;
type Result<T> = std::result::Result<T, String>;

#[derive(Default)]
struct Audit {
    records: u64,
    shifted: u64,
    estimated: u64,
    down: u64,
    up: u64,
    native: u64,
    certificate_fallback: u64,
    matched: u64,
    batches: u64,
    pending: [(u64, u64, u64); 4],
    used: usize,
    errors: u64,
    fingerprint: u64,
}

impl Audit {
    fn check(&mut self, table: &BatchEngine, a: u64, b: u64, d: u64) -> Result<()> {
        self.pending[self.used] = (a, b, d);
        self.used += 1;
        self.records += 1;
        if self.used == 4 { self.flush(table)?; }
        Ok(())
    }
    fn flush(&mut self, table: &BatchEngine) -> Result<()> {
        if self.used == 0 { return Ok(()); }
        let mut a = [0; 4];
        let mut b = [1; 4];
        let mut d = [1; 4];
        for lane in 0..self.used { (a[lane], b[lane], d[lane]) = self.pending[lane]; }
        let results = table.ratio4(black_box(a), black_box(b), black_box(d));
        for lane in 0..self.used { self.compare(a[lane], b[lane], d[lane], results[lane])?; }
        self.used = 0;
        self.batches += 1;
        Ok(())
    }
    fn compare(&mut self, a: u64, b: u64, d: u64, actual: exact_div::Ratio) -> Result<()> {
        // oracleはseed/refinement/浮動小数を共有せず、直接u128で計算する。
        let full_product = u128::from(a) * u128::from(b);
        let expected = if d == 0 {
            Err("zero denominator")
        } else if full_product > u128::from(u64::MAX) {
            Err("product overflow")
        } else {
            Ok((full_product / u128::from(d)) as u64)
        };
        let (quotient, flags, error) = match (expected, actual) {
            (Ok(expected), Ok((actual, flags))) if expected == actual => {
                let product = u128::from(actual) * u128::from(d);
                if product > full_product || full_product - product >= u128::from(d) {
                    return Err(format!("oracle residue: {a} {b} {d}"));
                }
                if flags == exact_div::SHIFT {
                    self.shifted += 1;
                } else if flags == exact_div::NATIVE {
                    self.native += 1;
                } else if flags & exact_div::ESTIMATED != 0 {
                    if flags & !(exact_div::ESTIMATED | exact_div::DOWN | exact_div::UP | exact_div::CERTIFICATE_FALLBACK) != 0 {
                        return Err(format!("unexpected estimate flags {flags}"));
                    }
                    self.estimated += 1;
                    self.down += u64::from(flags & exact_div::DOWN != 0);
                    self.up += u64::from(flags & exact_div::UP != 0);
                    self.certificate_fallback += u64::from(flags & exact_div::CERTIFICATE_FALLBACK != 0);
                } else {
                    return Err(format!("unexpected flags {flags}"));
                }
                (actual, flags, 0)
            }
            (Err(expected), Err(actual)) if expected == actual => {
                self.errors += 1;
                (0, 0, if expected == "zero denominator" { 1 } else { 2 })
            }
            (expected, actual) => {
                return Err(format!(
                    "case {a} {b} {d}: expected {expected:?}, actual {actual:?}"
                ));
            }
        };
        // 非暗号学的rolling fingerprint。実際の各record比較を省略するものではない。
        for value in [a, b, d, quotient, u64::from(flags), error] {
            self.fingerprint = (self.fingerprint ^ value).wrapping_mul(0x100000001b3);
        }
        self.matched += 1;
        Ok(())
    }

    fn boundary(&mut self, table: &BatchEngine, d: u64, q: u64) -> Result<()> {
        let center = u128::from(d) * u128::from(q);
        for delta in [-1_i128, 0, 1] {
            let n = center as i128 + delta;
            if (0..=i128::from(u64::MAX)).contains(&n) {
                self.check(table, n as u64, 1, d)?;
            }
        }
        Ok(())
    }
}

fn audit(table: &BatchEngine) -> Result<()> {
    let mut audit = Audit {
        fingerprint: 0xcbf29ce484222325,
        ..Audit::default()
    };
    for d in 1..=65536 {
        for q in [0, 1, 2, Q / 2, Q - 2, Q - 1] {
            audit.boundary(table, d, q)?;
        }
    }
    let small_records = audit.records;
    for i in 32768_u64..65536 {
        for offset in [0, 32767, 65535] {
            let normalized = (i << 16) + offset;
            for s in [0, 1, 4, 8, 12, 16, 24, 31] {
                let d = normalized >> s;
                for q in [1, Q / 2, Q - 1] {
                    audit.boundary(table, d, q)?;
                }
            }
        }
    }
    let bucket_records = audit.records - small_records;
    // D=Q-kの証明の特別範囲を全k1..80で確認する。
    let mut upper_records = 0;
    for k in 1..=80 {
        for s in 0..32 {
            for q in [1, 2, Q / 2, Q - 2, Q - 1] {
                let before = audit.records;
                audit.boundary(table, (Q - k) >> s, q)?;
                upper_records += audit.records - before;
            }
        }
    }
    let mut seed = 0x26_10_02_7a_5c_90_e3_1d_u64;
    for i in 0..1_000_000 {
        seed ^= seed << 13;
        seed ^= seed >> 7;
        seed ^= seed << 17;
        let d = (seed & (Q - 1)).max(1);
        let n = if i % 4 == 0 { seed } else { seed % (Q * d) };
        audit.check(table, n, 1, d)?;
        if i % 16 == 0 {
            audit.check(table, seed & (Q - 1), seed >> 32, d)?;
        }
    }
    let special_start = audit.records;
    let values = [0, 1, 2, 3, Q - 1, Q, Q + 1, i64::MAX as u64, u64::MAX];
    for a in values {
        for b in values {
            for d in values {
                audit.check(table, a, b, d)?;
            }
        }
    }
    audit.flush(table)?;
    if audit.records != audit.matched || audit.estimated == 0 || audit.down == 0 || audit.native == 0 || audit.errors == 0 {
        return Err("coverage/matched invariant".into());
    }
    println!(
        "{{\"status\":\"numeric_verified\",\"records\":{},\"matched\":{},\"batches\":{},\"small_records\":{},\"bucket_records\":{},\"upper_records\":{},\"special_records\":{},\"shifted\":{},\"estimated\":{},\"down\":{},\"up\":{},\"native\":{},\"errors\":{},\"certificate_fallback\":{},\"engine_bytes\":{},\"fingerprint_u64\":\"{:016x}\"}}",
        audit.records, audit.matched, audit.batches, small_records, bucket_records, upper_records,
        audit.records - special_start, audit.shifted, audit.estimated, audit.down, audit.up,
        audit.native, audit.errors, audit.certificate_fallback, std::mem::size_of::<BatchEngine>(), audit.fingerprint
    );
    Ok(())
}

fn small_audit(table: &BatchEngine, count: usize, rotations: usize) -> Result<()> {
    let mut audit = Audit { fingerprint: 0xcbf29ce484222325, ..Audit::default() };
    let cases = [(u64::MAX, u64::MAX, 0), (Q - 1, Q - 1, Q - 1), (u64::MAX, 2, 3),
        (u64::MAX, 1, Q - 1), (0, 1, 3), (i64::MAX as u64 + 1, 1, Q - 1),
        (12345, 1, 8), (Q - 1, Q - 2, Q - 1)];
    for rotate in 0..rotations {
        for index in 0..count { let (a, b, d) = cases[(rotate + index) % cases.len()]; audit.check(table, a, b, d)?; }
        audit.flush(table)?;
    }
    if audit.records != audit.matched || audit.records != (count * rotations) as u64 {
        return Err("tail/mixed matched count".into());
    }
    println!("{{\"records\":{},\"matched\":{},\"batches\":{},\"errors\":{},\"certificate_fallback\":{},\"fingerprint_u64\":\"{:016x}\"}}",
        audit.records, audit.matched, audit.batches, audit.errors, audit.certificate_fallback, audit.fingerprint);
    Ok(())
}

fn run() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    if args.get(1).map(String::as_str) == Some("features") && args.len() == 2 {
        println!("{{\"avx2_available\":{}}}", exact_div::avx2_available());
        return Ok(());
    }
    let backend = match args.get(2).map(String::as_str) {
        Some("scalar") => Backend::Scalar,
        Some("avx2") => Backend::Avx2,
        _ => return Err("backend must be scalar or avx2".into()),
    };
    let table = BatchEngine::new(backend).map_err(str::to_owned)?;
    match args.get(1).map(String::as_str) {
        Some("audit") if args.len() == 3 => audit(&table),
        Some("mixed") if args.len() == 3 => small_audit(&table, 4, 8),
        Some("tail") if args.len() == 4 => {
            let count: usize = args[3].parse().map_err(|_| "invalid tail count")?;
            if !(1..=3).contains(&count) { return Err("tail count outside bounds".into()); }
            small_audit(&table, count, 1)
        }
        Some("query") if args.len() == 6 => {
            let mut values = [0_u64; 3];
            for (value, argument) in values.iter_mut().zip(&args[3..]) {
                *value = argument.parse().map_err(|_| "invalid u64")?;
            }
            match table.ratio(values[0], values[1], values[2]) {
                Ok((q, flags)) => println!("{{\"quotient\":\"{q}\",\"flags\":{flags}}}"),
                Err(error) => println!("{{\"error\":\"{error}\"}}"),
            }
            Ok(())
        }
        _ => Err("usage: features | audit scalar|avx2 | query scalar|avx2 a b d".into()),
    }
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(2);
    }
}
