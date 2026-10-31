//! 固定順の跨file packing。全復元・sizeだけを調べ、native速度を主張しない。
use std::{fs::File, io::Read};
use unlhare::khc::{BLOCK_BYTES, BlockStrategy, compress_block_with_strategy, decompress_block};
fn check(raw: &[u8], strategy: BlockStrategy) -> Result<(usize, u8), String> {
    let frame = compress_block_with_strategy(raw, strategy).map_err(|e| e.to_string())?;
    if frame.len() > raw.len() + 40 || frame.len() < 40 {
        return Err("frame extent".into());
    }
    let declared = u32::from_le_bytes(frame[12..16].try_into().map_err(|_| "header raw")?);
    if declared as usize != raw.len() || frame[10] > 3 {
        return Err("frame raw/method".into());
    }
    let restored = decompress_block(&frame).map_err(|e| e.to_string())?;
    if restored != raw {
        return Err("whole-byte restoration".into());
    }
    Ok((frame.len(), frame[10]))
}
fn execute() -> Result<(), String> {
    let paths: Vec<_> = std::env::args().skip(1).collect();
    if paths.len() != 11 {
        return Err("11 fixed inputs required".into());
    }
    let strategies = [BlockStrategy::Mdl, BlockStrategy::BinaryAdaptive];
    let tiny = [vec![], vec![165], (0..=255).collect::<Vec<u8>>()];
    for raw in &tiny {
        for strategy in strategies {
            check(raw, strategy)?;
        }
    }
    let mut chunk = Vec::new();
    chunk
        .try_reserve_exact(BLOCK_BYTES)
        .map_err(|_| "raw allocation")?;
    chunk.resize(BLOCK_BYTES, 0);
    let mut groups: [Vec<&String>; 2] = [Vec::new(), Vec::new()];
    let mut classifier_checks = 0;
    for path in &paths {
        let mut file = File::open(path).map_err(|e| e.to_string())?;
        let extent = usize::try_from(file.metadata().map_err(|e| e.to_string())?.len())
            .map_err(|_| "classifier extent")?;
        if extent == 0 || extent > BLOCK_BYTES {
            return Err("classifier bound".into());
        }
        file.read_exact(&mut chunk[..extent])
            .map_err(|e| e.to_string())?;
        let mut tail = [0];
        if file.read(&mut tail).map_err(|e| e.to_string())? != 0 {
            return Err("classifier source grew".into());
        }
        let count = chunk[..extent]
            .iter()
            .filter(|&&b| matches!(b, 9 | 10 | 13 | 32..=126))
            .count();
        let class = usize::from(count * 10 < extent * 9);
        groups[class].push(path);
        classifier_checks += 1;
    }
    let mut filled = 0;
    let mut total = 0usize;
    let mut rows = Vec::new();
    rows.try_reserve_exact(4).map_err(|_| "rows allocation")?;
    for group in &groups {
        for path in group {
            let mut file = File::open(path).map_err(|e| e.to_string())?;
            let declared = usize::try_from(file.metadata().map_err(|e| e.to_string())?.len())
                .map_err(|_| "source extent")?;
            if declared == 0 || declared > BLOCK_BYTES {
                return Err("source bound".into());
            }
            let mut received = 0usize;
            loop {
                let count = file.read(&mut chunk[filled..]).map_err(|e| e.to_string())?;
                if count == 0 {
                    break;
                }
                received = received.checked_add(count).ok_or("file overflow")?;
                total = total.checked_add(count).ok_or("total overflow")?;
                filled += count;
                if received > declared || total > 2_810_784 {
                    return Err("source grew/total bound".into());
                }
                if filled == BLOCK_BYTES {
                    if rows.len() >= 4 {
                        return Err("block bound".into());
                    }
                    rows.push((
                        filled,
                        check(&chunk[..filled], strategies[0])?,
                        check(&chunk[..filled], strategies[1])?,
                    ));
                    filled = 0;
                }
            }
            if received != declared {
                return Err("source shrank".into());
            }
        }
        if filled != 0 {
            rows.push((
                filled,
                check(&chunk[..filled], strategies[0])?,
                check(&chunk[..filled], strategies[1])?,
            ));
        }
        filled = 0;
    }
    if total != 2_810_784 || rows.len() != 4 || rows.iter().map(|r| r.0).sum::<usize>() != total {
        return Err("total/block coverage".into());
    }
    let text: Vec<_> = rows.iter().map(|(raw, mdl, adaptive)| format!(
        "{{\"raw\":{raw},\"mdl_bytes\":{},\"mdl_method\":{},\"adaptive_bytes\":{},\"adaptive_method\":{}}}",
        mdl.0, mdl.1, adaptive.0, adaptive.1)).collect();
    println!(
        "{{\"byte_exact\":true,\"small_roundtrips\":6,\"classified_files\":{classifier_checks},\"text_files\":{},\"binary_files\":{},\"raw_bytes\":{total},\"files\":11,\"blocks\":[{}],\"mdl_frames\":{},\"adaptive_frames\":{},\"timing_evidence\":false}}",
        groups[0].len(),
        groups[1].len(),
        text.join(","),
        rows.iter().map(|r| r.1.0).sum::<usize>(),
        rows.iter().map(|r| r.2.0).sum::<usize>()
    );
    Ok(())
}
fn main() {
    if let Err(e) = execute() {
        eprintln!("{e}");
        std::process::exit(1);
    }
}
