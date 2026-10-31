//! 隣接二枝の成立範囲診断。時間・新frameの性能証明ではない。
#![allow(dead_code)]
#[path = "diagnostic_block.rs"]
mod block;
fn run() -> Result<(), String> {
    let geometry = block::pair_geometry()?;
    if geometry != 66049 {
        return Err("geometry extent".into());
    }
    let mut finite = 0;
    for size in [0, 1, 2, 3, 7, 31, 256, 4096] {
        for pattern in 0..4 {
            let raw: Vec<u8> = (0..size)
                .map(|i| match pattern {
                    0 => 0,
                    1 => b'A' + (i % 26) as u8,
                    2 => (i % 256) as u8,
                    _ => ((i * 173 + i / 7) % 256) as u8,
                })
                .collect();
            block::pair_diagnostic(&raw)?;
            finite += 1;
        }
    }
    let paths: Vec<_> = std::env::args().skip(1).collect();
    if paths.len() != 11 {
        return Err("corpus extent".into());
    }
    let mut rows = Vec::new();
    for (i, path) in paths.iter().enumerate() {
        let length = std::fs::metadata(path).map_err(|e| e.to_string())?.len();
        if length > block::MAX_INPUT as u64 {
            return Err("input file bound".into());
        }
        let raw = std::fs::read(path).map_err(|e| e.to_string())?;
        let d = block::pair_diagnostic(&raw)?;
        rows.push(format!("{{\"index\":{},\"raw\":{},\"method\":{},\"bytes\":{},\"explicit\":{},\"saved\":{},\"compound_calls\":{},\"old_loss\":{},\"new_loss\":{},\"full_byte_verified\":{}}}",i,raw.len(),d.method,d.bytes,d.explicit,d.saved,d.compound_calls,d.old_loss,d.new_loss,d.full_byte_verified));
    }
    println!(
        "{{\"geometry\":{},\"finite\":{},\"timing_evidence\":false,\"rows\":[{}]}}",
        geometry,
        finite,
        rows.join(",")
    );
    Ok(())
}
fn main() {
    if let Err(e) = run() {
        eprintln!("{e}");
        std::process::exit(1);
    }
}
