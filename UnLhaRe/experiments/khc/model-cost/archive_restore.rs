//! 実公開APIの時刻復元オプションを明示する、全書庫診断用入口。
use std::path::Path;
fn execute() -> Result<(), String> {
    let args: Vec<_> = std::env::args().collect();
    if args.len() != 3 {
        return Err("archive and new destination required".into());
    }
    let options = unlhare::ExtractOptions {
        preserve_timestamps: true,
        ..Default::default()
    };
    let summary = unlhare::lhc::extract_archive_with_progress(
        Path::new(&args[1]),
        Path::new(&args[2]),
        &unlhare::Limits::default(),
        &options,
        &mut |_| true,
    )
    .map_err(|error| error.to_string())?;
    println!("{} files {} bytes", summary.files, summary.bytes);
    Ok(())
}
fn main() {
    if let Err(error) = execute() {
        eprintln!("archive_restore: {error}");
        std::process::exit(1);
    }
}
