//! 24byte LE u64 triples -> 9byte LE quotient + flags。
mod exact_div;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::Path;
const MAX: usize = 65536 * 24;
type Result<T> = std::result::Result<T, String>;
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
    if input.len() > MAX || input.len() % 24 != 0 {
        return Err("cap or incomplete record".into());
    }
    let mut output = Vec::new();
    output
        .try_reserve_exact(input.len() / 24 * 9)
        .map_err(|_| "output allocation")?;
    // 全入力を評価・拒否し終えるまで出力ファイルを作らない。
    for r in input.chunks_exact(24) {
        let a = u64::from_le_bytes(r[0..8].try_into().map_err(|_| "record")?);
        let b = u64::from_le_bytes(r[8..16].try_into().map_err(|_| "record")?);
        let d = u64::from_le_bytes(r[16..24].try_into().map_err(|_| "record")?);
        let (q, flags) = exact_div::ratio(a, b, d)?;
        output.extend_from_slice(&q.to_le_bytes());
        output.push(flags);
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
    println!(
        "{{\"operation\":\"signed-estimate-quotient\",\"records\":{}}}",
        input.len() / 24
    );
    Ok(())
}
fn main() {
    if let Err(e) = run() {
        eprintln!("{e}");
        std::process::exit(1);
    }
}
