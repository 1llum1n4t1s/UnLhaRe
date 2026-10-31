//! 8B LE zero,one -> 32B LE probability,error_code,method,reciprocal。
mod exact_kt;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::Path;
const MAX: usize = 524288 * 8;
type Result<T> = std::result::Result<T, String>;

fn no_reparse(path: &Path) -> Result<()> {
    let full = std::path::absolute(path).map_err(|e| e.to_string())?;
    for part in full.ancestors() {
        match std::fs::symlink_metadata(part) {
            Ok(meta) => {
                #[cfg(windows)]
                {
                    use std::os::windows::fs::MetadataExt;
                    if meta.file_attributes() & 0x400 != 0 {
                        return Err("reparse rejected".into());
                    }
                }
                #[cfg(not(windows))]
                if meta.file_type().is_symlink() {
                    return Err("reparse rejected".into());
                }
            }
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(e.to_string()),
        }
    }
    Ok(())
}

fn run() -> Result<()> {
    let args: Vec<_> = std::env::args_os().collect();
    if args.len() != 3 {
        return Err("usage: audit input output".into());
    }
    no_reparse(Path::new(&args[1]))?;
    no_reparse(Path::new(&args[2]))?;
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
    if input.len() > MAX || input.len() % 8 != 0 {
        return Err("cap or incomplete record".into());
    }
    let mut output = Vec::new();
    output
        .try_reserve_exact(input.len() / 8 * 32)
        .map_err(|_| "output allocation")?;
    let table = exact_kt::KtTable::new()?;
    for record in input.chunks_exact(8) {
        let zero = u32::from_le_bytes(record[..4].try_into().map_err(|_| "record")?);
        let one = u32::from_le_bytes(record[4..].try_into().map_err(|_| "record")?);
        for value in table.audit(zero, one)? {
            output.extend_from_slice(&value.to_le_bytes());
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
    let temp = parent.join(format!(".kt-reciprocal-{}-{nonce}.tmp", std::process::id()));
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
        "{{\"operation\":\"kt-reciprocal-audit\",\"records\":{},\"table_bytes\":{}}}",
        input.len() / 8,
        table.audit_bytes()
    );
    Ok(())
}
fn main() {
    if let Err(e) = run() {
        eprintln!("{e}");
        std::process::exit(1);
    }
}
