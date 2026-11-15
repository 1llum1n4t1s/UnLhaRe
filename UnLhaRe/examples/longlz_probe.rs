//! 長距離LZ候補の試作（LHC の形式・製品 API には未接続の開発用 example）。
//! LZMA と同じ記号の逐次 encoder（BT4＋最適parse）と復号器で、大きな窓のサイズと速度を測る。
//! 出力は `.lzma` 単体形式なので、xz でも独立に展開して正しさを確かめられる。
//!
//! 使い方:
//!   longlz_probe enc <input> <out> [--window-mib N] [--cut N] [--nice N] [--segment-kib N] [--wave N] [--threads N] [--near 0|1]
//!   longlz_probe dec <in> [--check <raw>] [--repeat N] [--threads N] [--write <out>]
//!   longlz_probe mf <input> [--window-mib N] [--cut N]
//! segment 長を指定すると、wave 単位で並列に復号できる segment 容器（`LLZSEG1`）を出す。
//! --near 1 は近傍距離符号つきの容器（`LLZSEG2`）で、segment 指定が必要（環境変数 LLZ_NEAR_PARSE=0 で
//! parse は従来の価格のまま、符号化だけが近傍を選ぶ）。
#[path = "longlz/lzma.rs"]
mod lzma;
#[path = "longlz/mf.rs"]
mod mf;
#[path = "longlz/par.rs"]
mod par;
#[path = "longlz/rc.rs"]
mod rc;
#[path = "longlz/shadow.rs"]
mod shadow;
#[path = "longlz/shadow2.rs"]
mod shadow2;

use std::time::Instant;

fn main() -> Result<(), String> {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let flag = |name: &str| -> Option<&str> {
        args.iter()
            .position(|a| a == name)
            .and_then(|i| args.get(i + 1))
            .map(String::as_str)
    };
    let num = |name: &str, default: usize| -> Result<usize, String> {
        flag(name).map_or(Ok(default), |v| v.parse().map_err(|_| format!("{name} N")))
    };
    match args.first().map(String::as_str) {
        Some("enc") => {
            let input = args.get(1).ok_or("input")?;
            let output = args.get(2).ok_or("output")?;
            let data = std::fs::read(input).map_err(|e| e.to_string())?;
            let window = (num("--window-mib", 64)? << 20).min(data.len().max(1 << 16));
            let settings = lzma::Settings {
                window,
                cut: num("--cut", 152)? as u32,
                nice: num("--nice", lzma::NICE)?,
                // segment 長は KiB で指定（0 なら全体を1 segment）。
                segment: num("--segment-kib", 0)? << 10,
                wave: num("--wave", 4)?,
                near: num("--near", 0)? != 0,
            };
            if settings.near && settings.segment == 0 {
                return Err(
                    "--near needs --segment-kib (the .lzma form cannot hold near codes)".into(),
                );
            }
            // --threads が2以上かつ segment 指定時は、並列探索＋segment 並列 parse で作る。
            let threads = num("--threads", 1)?;
            let t = Instant::now();
            let out = if threads > 1 && settings.segment > 0 {
                let (out, timing) = par::encode_parallel(&data, &settings, threads);
                println!(
                    "parallel threads {threads}: find {:.1} s, parse {:.1} s, per-thread find {:?} s, owned {:?}",
                    timing.find_secs,
                    timing.parse_secs,
                    timing
                        .thread_secs
                        .iter()
                        .map(|v| (v * 10.0).round() / 10.0)
                        .collect::<Vec<_>>(),
                    timing.thread_owned
                );
                if std::env::var("LLZ_STATS").is_ok_and(|v| v == "1") {
                    println!(
                        "  finder work: node visits {:.2}/byte, compared {:.2} B/byte",
                        timing.visits as f64 / data.len().max(1) as f64,
                        timing.cmp_bytes as f64 / data.len().max(1) as f64
                    );
                }
                out
            } else {
                lzma::Encoder::new(&data, &settings).encode(window)
            };
            let secs = t.elapsed().as_secs_f64();
            std::fs::write(output, &out).map_err(|e| e.to_string())?;
            if std::env::var("LLZ_STATS").is_ok_and(|v| v == "1") {
                // 符号長の内訳（byte と割合）。
                let st = lzma::stats();
                let total: f64 = st.iter().sum();
                for (name, bits) in rc::CATS.iter().zip(st.iter()) {
                    println!(
                        "  {name:<18} {:>12.0} B {:>6.2}%",
                        bits / 8.0,
                        bits / total.max(1.0) * 100.0
                    );
                }
                let get =
                    |a: &std::sync::atomic::AtomicU64| a.load(std::sync::atomic::Ordering::Relaxed);
                println!(
                    "  parse work: optimum {} dp nodes {} ({:.2}/byte) length steps {} ({:.2}/byte)",
                    get(&lzma::OPTIMUM_CALLS),
                    get(&lzma::DP_NODES),
                    get(&lzma::DP_NODES) as f64 / data.len().max(1) as f64,
                    get(&lzma::LEN_STEPS),
                    get(&lzma::LEN_STEPS) as f64 / data.len().max(1) as f64
                );
                if settings.near {
                    let normal = get(&lzma::NORMAL_MATCHES);
                    let used = get(&lzma::NEAR_USED);
                    println!(
                        "  near: evaluated {} ({:.3}/byte), normal matches {}, used {} ({:.2}%)",
                        get(&lzma::NEAR_EVALS),
                        get(&lzma::NEAR_EVALS) as f64 / data.len().max(1) as f64,
                        normal,
                        used,
                        used as f64 / normal.max(1) as f64 * 100.0
                    );
                }
                let sh = lzma::shadow_bits();
                if sh > 0.0 {
                    let lit = st[1] + st[2];
                    println!(
                        "  shadow literal model {:>12.0} B (LZMA literal {:.0} B, saving {:.0} B = {:.2}% of total)",
                        sh / 8.0,
                        lit / 8.0,
                        (lit - sh) / 8.0,
                        (lit - sh) / total.max(1.0) * 100.0
                    );
                }
            }
            for (name, v) in lzma::shadow2_report() {
                println!("  s2 {name:<28} {:>14.1}", v);
            }
            println!(
                "in {} out {} ratio {:.4} encode {:.1} s ({:.2} MB/s) window {} MiB cut {} nice {}",
                data.len(),
                out.len(),
                out.len() as f64 / data.len().max(1) as f64,
                secs,
                data.len() as f64 / 1e6 / secs,
                window >> 20,
                settings.cut,
                settings.nice
            );
        }
        Some("mf") => {
            // 一致探索だけの時間（全位置で find）。parse の時間と切り分けるために使う。
            let input = args.get(1).ok_or("input")?;
            let data = std::fs::read(input).map_err(|e| e.to_string())?;
            let window = (num("--window-mib", 64)? << 20).min(data.len().max(1 << 16));
            let cut = num("--cut", 152)? as u32;
            let mut finder = mf::Bt4::new(window, cut);
            let scope = mf::Scope {
                end: data.len(),
                seg_start: 0,
                wave_start: 0,
            };
            let mut found = Vec::new();
            let mut pairs = 0usize;
            let t = Instant::now();
            for pos in 0..data.len() {
                finder.find(&data, pos, &scope, &mut found);
                pairs += found.len();
            }
            let secs = t.elapsed().as_secs_f64();
            println!(
                "finder only {:.1} s ({:.2} MB/s) pairs/pos {:.2} window {} MiB cut {}",
                secs,
                data.len() as f64 / 1e6 / secs,
                pairs as f64 / data.len().max(1) as f64,
                window >> 20,
                cut
            );
        }
        Some("scan") => {
            // 並列探索で全 thread が全位置に払う費用（hash 計算と 2/3byte 表の更新）だけを測る。
            let input = args.get(1).ok_or("input")?;
            let data = std::fs::read(input).map_err(|e| e.to_string())?;
            let mut head2 = vec![0u32; 1 << 16];
            let mut head3 = vec![0u32; 1 << mf::HASH3_BITS];
            let mut acc = 0u64;
            let t = Instant::now();
            for pos in 0..data.len().saturating_sub(3) {
                let w = u32::from_le_bytes(data[pos..pos + 4].try_into().unwrap());
                let h2 = (w & 0xFFFF) as usize;
                let h3 =
                    ((w & 0x00FF_FFFF).wrapping_mul(mf::MUL) >> (32 - mf::HASH3_BITS)) as usize;
                acc = acc.wrapping_add(head2[h2] as u64 ^ head3[h3] as u64);
                head2[h2] = pos as u32 + 1;
                head3[h3] = pos as u32 + 1;
            }
            println!("scan only {:.2} s (check {acc})", t.elapsed().as_secs_f64());
        }
        Some("dec") => {
            let input = args.get(1).ok_or("input")?;
            let stream = std::fs::read(input).map_err(|e| e.to_string())?;
            let repeat = num("--repeat", 3)?;
            let threads = num("--threads", 4)?;
            let mut best = f64::MAX;
            let mut last = Vec::new();
            for _ in 0..repeat.max(1) {
                let t = Instant::now();
                last = if lzma::is_container(&stream) {
                    lzma::decode_container(&stream, threads)?
                } else {
                    lzma::decode(&stream)?
                };
                best = best.min(t.elapsed().as_secs_f64());
            }
            // --write を付けると展開結果を file へ書く（7-Zip の展開と条件をそろえるため、時間に含める）。
            if let Some(path) = flag("--write") {
                let t = Instant::now();
                std::fs::write(path, &last).map_err(|e| e.to_string())?;
                println!("write {:.1} ms", t.elapsed().as_secs_f64() * 1e3);
            }
            if let Some(raw) = flag("--check") {
                let raw = std::fs::read(raw).map_err(|e| e.to_string())?;
                if raw != last {
                    return Err("decoded bytes differ from the reference".into());
                }
                println!("check ok");
            }
            println!(
                "bytes {} best {:.1} ms {:.1} MB/s",
                last.len(),
                best * 1e3,
                last.len() as f64 / 1e6 / best
            );
        }
        _ => return Err("usage: longlz_probe enc|dec ...".into()),
    }
    Ok(())
}
