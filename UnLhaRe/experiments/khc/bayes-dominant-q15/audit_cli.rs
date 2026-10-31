//! 外部CLI数値監査。全件を旧predictと逐次比較し、生レコードを保存しない。
type Result<T> = std::result::Result<T, String>;
#[allow(dead_code)]
#[path = "bayes_old.rs"]
mod old;
#[allow(dead_code)]
#[path = "bayes_model.rs"]
mod candidate;

#[derive(Default)]
struct Audit {
    records: u64,
    equal: u64,
    primary: u64,
    cts: u64,
    unchanged_path: u64,
    errors: u64,
    fingerprint: u64,
}
impl Audit {
    fn record(&mut self, lp: f64, lc: f64, p: u16, c: u16) -> Result<()> {
        let expected = old::audit_predict(lp, lc, p, c);
        let actual = candidate::audit_predict(lp, lc, p, c);
        if actual != expected {
            return Err(format!("first witness record={} loss_bits={:016x}/{:016x} components={}/{} old={:?} new={:?}", self.records, lp.to_bits(), lc.to_bits(), p, c, expected, actual));
        }
        self.records += 1;
        let diff = lp - lc;
        let valid = (1..32768).contains(&p) && (1..32768).contains(&c);
        let finite = lp.is_finite() && lc.is_finite() && diff.is_finite();
        if valid && finite && p == c {
            self.equal += 1;
        } else if valid && finite && diff >= 32.0 {
            self.cts += 1;
        } else if valid && finite && diff <= -32.0 {
            self.primary += 1;
        } else {
            self.unchanged_path += 1;
        }
        let encoded = match actual {
            Ok((primary, cts, zero)) => {
                if primary != p || cts != c { return Err("learning components changed".into()); }
                u64::from(zero)
            }
            Err(_) => { self.errors += 1; 65536 }
        };
        for value in [lp.to_bits(), lc.to_bits(), u64::from(p), u64::from(c), encoded] {
            self.fingerprint = (self.fingerprint ^ value).wrapping_mul(0x100000001b3);
        }
        Ok(())
    }
}
fn run() -> Result<()> {
    if std::env::args_os().len() != 1 { return Err("no arguments accepted".into()); }
    let mut audit = Audit { fingerprint: 0xcbf29ce484222325, ..Audit::default() };
    let below = f64::from_bits(32.0_f64.to_bits() - 1);
    let above = f64::from_bits(32.0_f64.to_bits() + 1);
    let losses = [(0.0, 0.0), (32.0, 0.0), (0.0, 32.0), (below, 0.0), (0.0, below),
        (above, 0.0), (0.0, above), (64.0, 0.0), (0.0, 64.0),
        (1_000_032.0, 1_000_000.0), (1_000_000.0, 1_000_032.0), (-32.0, 0.0),
        (0.0, -32.0), (1_000_000.0, 0.0), (0.0, 1_000_000.0)];
    // 全有効primaryとCTS端/中央/隣接。同componentも全域を横断する。
    for p in 1_u16..32768 {
        let components = [1, 2, 16383, 16384, 16385, 32766, 32767, p,
            p.saturating_sub(1).max(1), (p + 1).min(32767)];
        for c in components {
            for (lp, lc) in losses { audit.record(lp, lc, p, c)?; }
        }
    }
    // poison、差overflow、boundsはshortcut前の検査/旧経路を維持する。
    let specials = [0.0, -0.0, -32.0, 32.0, below, above, f64::MAX, -f64::MAX,
        f64::INFINITY, f64::NEG_INFINITY, f64::NAN];
    for lp in specials {
        for lc in specials {
            for p in [0, 1, 2, 16384, 32767, 32768, 65535] {
                for c in [0, 1, 2, 16384, 32767, 32768, 65535] {
                    audit.record(lp, lc, p, c)?;
                }
            }
        }
    }
    let mut seed = 0x971af03178d40265_u64;
    let next = |state: &mut u64| {
        *state = state.wrapping_mul(6364136223846793005).wrapping_add(1442695040888963407);
        *state
    };
    for _ in 0..1_000_000 {
        let p = (next(&mut seed) % 32767 + 1) as u16;
        let c = (next(&mut seed) % 32767 + 1) as u16;
        let lp = (next(&mut seed) >> 11) as f64 / 9007199254740992.0 * 256.0 - 128.0;
        let lc = (next(&mut seed) >> 11) as f64 / 9007199254740992.0 * 256.0 - 128.0;
        audit.record(lp, lc, p, c)?;
    }
    if audit.errors == 0 || audit.equal == 0 || audit.primary == 0 || audit.cts == 0 || audit.unchanged_path == 0 {
        return Err("coverage category missing".into());
    }
    println!("{{\"records\":{},\"equal_component\":{},\"primary_dominant\":{},\"cts_dominant\":{},\"unchanged_path\":{},\"errors\":{},\"fingerprint_fnv64\":\"{:016x}\"}}", audit.records, audit.equal, audit.primary, audit.cts, audit.unchanged_path, audit.errors, audit.fingerprint);
    Ok(())
}
fn main() {
    if let Err(error) = run() {
        eprintln!("{error}");
        std::process::exit(if std::env::args_os().len() != 1 { 2 } else { 1 });
    }
}
