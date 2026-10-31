//! 生recordを保存せず、独立u128除算oracleへ逐次照合する数値CLI。
mod exact_div;
use exact_div::{Q, RatioTable};
use std::hint::black_box;
type Result<T> = std::result::Result<T, String>;

#[derive(Default)]
struct Audit {
    records: u64,
    shifted: u64,
    refined: u64,
    corrected: u64,
    fallback: u64,
    errors: u64,
    fingerprint: u64,
}

impl Audit {
    fn check(&mut self, table: &RatioTable, a: u64, b: u64, d: u64) -> Result<()> {
        // oracleはseed/refinement/浮動小数を共有せず、直接u128で計算する。
        let full_product = u128::from(a) * u128::from(b);
        let expected = if d == 0 {
            Err("zero denominator")
        } else if full_product > u128::from(u64::MAX) {
            Err("product overflow")
        } else {
            Ok((full_product / u128::from(d)) as u64)
        };
        let actual = table.ratio(black_box(a), black_box(b), black_box(d));
        let (quotient, flags, error) = match (expected, actual) {
            (Ok(expected), Ok((actual, flags))) if expected == actual => {
                let product = u128::from(actual) * u128::from(d);
                if product > full_product || full_product - product >= u128::from(d) {
                    return Err(format!("oracle residue: {a} {b} {d}"));
                }
                if flags & exact_div::CERTIFICATE_FALLBACK != 0 {
                    return Err(format!("normal-domain certificate failed: {a} {b} {d}"));
                }
                match flags {
                    exact_div::SHIFT => self.shifted += 1,
                    exact_div::FALLBACK => self.fallback += 1,
                    exact_div::REFINED => self.refined += 1,
                    x if x == exact_div::REFINED | exact_div::UP => {
                        self.refined += 1;
                        self.corrected += 1;
                    }
                    _ => return Err(format!("unexpected flags {flags}")),
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
        self.records += 1;
        Ok(())
    }

    fn boundary(&mut self, table: &RatioTable, d: u64, q: u64) -> Result<()> {
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

fn audit(table: &RatioTable) -> Result<()> {
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
    if table.bytes() != 262144
        || audit.refined == 0
        || audit.corrected == 0
        || audit.fallback == 0
        || audit.errors == 0
    {
        return Err("coverage/table invariant".into());
    }
    println!(
        "{{\"status\":\"numeric_verified\",\"records\":{},\"small_records\":{},\"bucket_records\":{},\"upper_records\":{},\"special_records\":{},\"shifted\":{},\"refined\":{},\"corrected\":{},\"fallback\":{},\"errors\":{},\"certificate_fallback\":0,\"table_bytes\":{},\"fingerprint_u64\":\"{:016x}\"}}",
        audit.records,
        small_records,
        bucket_records,
        upper_records,
        audit.records - special_start,
        audit.shifted,
        audit.refined,
        audit.corrected,
        audit.fallback,
        audit.errors,
        table.bytes(),
        audit.fingerprint
    );
    Ok(())
}

fn run() -> Result<()> {
    let args: Vec<String> = std::env::args().collect();
    let table = RatioTable::new().map_err(str::to_owned)?;
    match args.get(1).map(String::as_str) {
        Some("audit") if args.len() == 2 => audit(&table),
        Some("query") if args.len() == 5 => {
            let mut values = [0_u64; 3];
            for (value, argument) in values.iter_mut().zip(&args[2..]) {
                *value = argument.parse().map_err(|_| "invalid u64")?;
            }
            match table.ratio(values[0], values[1], values[2]) {
                Ok((q, flags)) => println!("{{\"quotient\":\"{q}\",\"flags\":{flags}}}"),
                Err(error) => println!("{{\"error\":\"{error}\"}}"),
            }
            Ok(())
        }
        _ => Err("usage: audit | query a b d".into()),
    }
}

fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(2);
    }
}
