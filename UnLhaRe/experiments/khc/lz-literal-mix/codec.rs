//! 一案だけのLazy LZ＋literal expertを検証する研究CLI。製品形式へ接続しない。
// 元研究moduleの診断exportはこの最小CLIから利用しない。
#[allow(dead_code, unused_imports)]
#[path = "mod.rs"]
mod khc;
use std::fs::{File, OpenOptions};
use std::io::{Read, Write};
use std::path::Path;
type Result<T> = std::result::Result<T, String>;

fn no_reparse(path: &Path) -> Result<()> {
    for part in std::path::absolute(path)
        .map_err(|e| e.to_string())?
        .ancestors()
    {
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
    if args.len() != 4 {
        return Err("usage: codec encode|decode|encode-cancel|decode-cancel input output".into());
    }
    let operation = args[1].to_str().ok_or("operation must be UTF-8")?;
    if !matches!(
        operation,
        "encode" | "decode" | "encode-cancel" | "decode-cancel"
    ) {
        return Err("unsupported operation".into());
    }
    let input_path = Path::new(&args[2]);
    let output_path = Path::new(&args[3]);
    no_reparse(input_path)?;
    no_reparse(output_path)?;
    let file = File::open(input_path).map_err(|e| format!("input open: {e}"))?;
    let cap = khc::MAX_INPUT + khc::HEADER;
    let meta = file.metadata().map_err(|e| e.to_string())?;
    if !meta.is_file() || meta.len() > cap as u64 {
        return Err("regular input within cap required".into());
    }
    let mut input = Vec::new();
    input
        .try_reserve_exact(meta.len() as usize)
        .map_err(|_| "input allocation failed")?;
    file.take((cap + 1) as u64)
        .read_to_end(&mut input)
        .map_err(|e| e.to_string())?;
    if input.len() > cap {
        return Err("input cap exceeded".into());
    }
    let options = khc::Options {
        dictionary: khc::MAX_INPUT,
        ..Default::default()
    };
    let mut cancel = || operation.ends_with("-cancel");
    let output = if operation.starts_with("encode") {
        khc::encode(&input, options, &mut cancel)
    } else {
        khc::decode(&input, options, &mut cancel)
    }
    .map_err(|e| format!("rejected: {e}"))?;
    let parent = output_path
        .parent()
        .filter(|p| !p.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    let nonce = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map_err(|e| e.to_string())?
        .as_nanos();
    let temp = parent.join(format!(".literal-mix-{}-{nonce}.tmp", std::process::id()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temp)
        .map_err(|e| format!("temporary create_new: {e}"))?;
    let written = file.write_all(&output).and_then(|()| file.sync_all());
    drop(file);
    let publication = written.and_then(|()| std::fs::hard_link(&temp, output_path));
    std::fs::remove_file(&temp).map_err(|e| format!("owned temporary cleanup: {e}"))?;
    publication.map_err(|e| format!("output create_new publication: {e}"))?;
    let variant = if cfg!(khc_literal_mix) {
        "mixed"
    } else {
        "control"
    };
    let extra = if cfg!(khc_literal_mix) { 524288 } else { 0 };
    println!(
        "{{\"operation\":\"{operation}\",\"variant\":\"{variant}\",\"input_bytes\":{},\"output_bytes\":{},\"additional_model_bytes\":{extra}}}",
        input.len(),
        output.len()
    );
    Ok(())
}
fn main() {
    if let Err(e) = run() {
        eprintln!("{e}");
        std::process::exit(1);
    }
}
