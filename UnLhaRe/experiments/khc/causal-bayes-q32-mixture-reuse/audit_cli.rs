//! 56byte LE numeric record -> 40byte LE floor/remainder/denominator/posterior/weight。
#[allow(dead_code)]
mod cts_model;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::Path;
#[cfg(not(khc_mixture_reuse_audit))]
const RECORD: usize = 56;
#[cfg(khc_mixture_reuse_audit)]
const RECORD: usize = 2;
#[cfg(not(khc_mixture_reuse_audit))]
const MAX: usize = 65536 * RECORD;
#[cfg(khc_mixture_reuse_audit)]
const MAX: usize = 4096 * RECORD;
#[cfg(not(khc_mixture_reuse_audit))]
const OUTPUT_RECORD: usize = 40;
#[cfg(khc_mixture_reuse_audit)]
const OUTPUT_RECORD: usize = 17 * 5 * 8;
#[cfg(not(khc_mixture_reuse_audit))]
const Q: u64 = 1 << 32;
#[cfg(not(khc_mixture_reuse_audit))]
const CAP: u64 = 562_036_803;
#[cfg(not(khc_mixture_reuse_audit))]
const OPERATION: &str = "q32-mixture-reuse-audit";
#[cfg(khc_mixture_reuse_audit)]
const OPERATION: &str = "q32-mixture-reuse-model-audit";
type Result<T> = std::result::Result<T, String>;

#[allow(dead_code)]
fn filled<T: Clone>(length: usize, value: T) -> Result<Vec<T>> {
    let mut values = Vec::new();
    values
        .try_reserve_exact(length)
        .map_err(|_| "allocation failed")?;
    values.resize(length, value);
    Ok(values)
}

fn run() -> Result<()> {
    let args: Vec<_> = std::env::args_os().collect();
    if args.len() != 3 {
        return Err("usage: audit input output".into());
    }
    let file = File::open(Path::new(&args[1])).map_err(|e| format!("input open: {e}"))?;
    let meta = file.metadata().map_err(|e| e.to_string())?;
    if !meta.is_file() || meta.len() > MAX as u64 {
        return Err("regular input within cap required".into());
    }
    let mut input = Vec::new();
    input
        .try_reserve_exact(MAX + 1)
        .map_err(|_| "input allocation")?;
    file.take((MAX + 1) as u64)
        .read_to_end(&mut input)
        .map_err(|e| e.to_string())?;
    if input.len() > MAX || input.len() % RECORD != 0 {
        return Err("cap or incomplete record".into());
    }
    let mut output = Vec::new();
    output
        .try_reserve_exact(input.len() / RECORD * OUTPUT_RECORD)
        .map_err(|_| "output allocation")?;
    // 全入力を評価・拒否し終えるまで出力ファイルを作らない。
    // LE: snapshot/live weight, zero KT/child, bit, after-count, ceiling override.
    // u64::MAX override selects the real cached/fallback denominator.
    #[cfg(not(khc_mixture_reuse_audit))]
    for r in input.chunks_exact(RECORD) {
        let mut fields = [0_u64; 7];
        for (field, raw) in fields.iter_mut().zip(r.chunks_exact(8)) {
            *field = u64::from_le_bytes(raw.try_into().map_err(|_| "record")?);
        }
        let [
            snapshot,
            live,
            kt,
            child_zero,
            bit_raw,
            after,
            override_ceiling,
        ] = fields;
        if bit_raw > 1 || !(1..=CAP).contains(&after) {
            return Err("bit or observation count outside bounds".into());
        }
        let bit = bit_raw != 0;
        let (zero, remainder) = cts_model::mixture_snapshot(snapshot, kt, child_zero)?;
        let pk = if bit {
            Q.checked_sub(kt).ok_or("KT complement underflow")?
        } else {
            kt
        };
        let child = if bit {
            Q.checked_sub(child_zero)
                .ok_or("child complement underflow")?
        } else {
            child_zero
        };
        let denominator =
            cts_model::cached_ceiling(live, snapshot, pk, child, zero, remainder, bit)?;
        let ceiling = if override_ceiling == u64::MAX {
            denominator
        } else {
            override_ceiling
        };
        let posterior = cts_model::posterior_ratio(live, pk, ceiling)?;
        let alpha = Q / after.checked_add(1).ok_or("switch denominator overflow")?;
        let retained = Q
            .checked_sub(alpha.checked_mul(2).ok_or("switch overflow")?)
            .ok_or("switch outside bounds")?;
        let weight = cts_model::next_weight(alpha, retained, posterior)?;
        for value in [zero, u64::from(remainder), denominator, posterior, weight] {
            output.extend_from_slice(&value.to_le_bytes());
        }
    }
    #[cfg(khc_mixture_reuse_audit)]
    {
        for r in input.chunks_exact(RECORD) {
            if r[0] >= 7 || r[1] > 1 {
                return Err("record class/bit outside bounds".into());
            }
        }
        let mut model = cts_model::Model::new()?;
        for r in input.chunks_exact(RECORD) {
            let raw = model.audit_step(u32::from(r[0]), r[1] != 0)?;
            for value in raw {
                output.extend_from_slice(&value.to_le_bytes());
            }
        }
    }
    let final_path = Path::new(&args[2]);
    let parent = final_path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_nanos();
    let temp = parent.join(format!(".quotient-{}-{nonce}.tmp", std::process::id()));
    // CreateNewで獲得した一時ファイルのみを後始末する。既存finalは削除しない。
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temp)
        .map_err(|e| format!("temporary create_new: {e}"))?;
    let write_result = file.write_all(&output).and_then(|()| file.sync_all());
    drop(file);
    let publication = write_result.and_then(|()| std::fs::hard_link(&temp, final_path));
    let cleanup = std::fs::remove_file(&temp);
    if let Err(e) = cleanup {
        return Err(format!(
            "owned temporary cleanup: {e}; retained {}",
            temp.display()
        ));
    }
    publication.map_err(|e| format!("output create_new publication: {e}"))?;
    #[cfg(khc_mixture_reuse_audit)]
    let layout = {
        let (prediction_bytes, node_bytes) = cts_model::Model::audit_layout();
        format!(",\"prediction_bytes\":{prediction_bytes},\"node_bytes\":{node_bytes}")
    };
    #[cfg(not(khc_mixture_reuse_audit))]
    let layout = "";
    println!(
        "{{\"operation\":\"{OPERATION}\",\"records\":{}{layout}}}",
        input.len() / RECORD
    );
    Ok(())
}
fn main() {
    if let Err(e) = run() {
        eprintln!("{e}");
        std::process::exit(1);
    }
}
