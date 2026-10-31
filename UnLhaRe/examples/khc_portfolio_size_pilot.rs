//! Canterbury11で既存4 codecのblock-size portfolioを選別する固定pilot。
use std::{env, fs, path::Path};

use serde_json::json;
use unlhare::khc::{self, BlockStrategy};

const BLOCK_CAP: usize = 1 << 20;
const EXPECTED_INPUT_BYTES: u64 = 2_810_784;
const EXPECTED_FILE_COUNT: usize = 11;
const BASELINE_ARCHIVE_BYTES: u64 = 484_829;
const SEVEN_ZIP_ARCHIVE_BYTES: u64 = 483_599;
const REQUIRED_REDUCTION_PERCENT: u64 = 5;
const STRATEGIES: [(&str, BlockStrategy); 4] = [
    ("Mdl", BlockStrategy::Mdl),
    ("SpatialBitsTrial", BlockStrategy::SpatialBitsTrial),
    ("RecordFastTrial", BlockStrategy::RecordFastTrial),
    ("RecordAdaptiveTrial", BlockStrategy::RecordAdaptiveTrial),
];
const EXPECTED_FILES: [&str; EXPECTED_FILE_COUNT] = [
    "alice29.txt",
    "asyoulik.txt",
    "cp.html",
    "fields.c",
    "grammar.lsp",
    "kennedy.xls",
    "lcet10.txt",
    "plrabn12.txt",
    "ptt5",
    "sum",
    "xargs.1",
];

type PilotResult<T> = Result<T, String>;

fn checked_add(target: &mut u64, value: usize, label: &str) -> PilotResult<()> {
    let value = u64::try_from(value).map_err(|_| format!("{label} exceeds u64"))?;
    *target = target
        .checked_add(value)
        .ok_or_else(|| format!("{label} total overflow"))?;
    Ok(())
}

fn encode_and_verify(raw: &[u8], strategy: BlockStrategy) -> PilotResult<Vec<u8>> {
    let frame = khc::compress_block_with_strategy(raw, strategy)
        .map_err(|error| format!("encoder failed: {error}"))?;
    let restored = khc::decompress_block(&frame)
        .map_err(|error| format!("candidate frame rejected: {error}"))?;
    if restored != raw {
        return Err("candidate frame roundtrip mismatch".into());
    }
    Ok(frame)
}

fn run() -> PilotResult<String> {
    let args: Vec<_> = env::args_os().collect();
    if args.len() != 3 {
        return Err(
            "usage: khc_portfolio_size_pilot <input-directory> <revision-9-archive>".into(),
        );
    }
    let input_root = Path::new(&args[1]);
    let baseline_archive = Path::new(&args[2]);
    let baseline_metadata = fs::metadata(baseline_archive)
        .map_err(|error| format!("baseline archive metadata: {error}"))?;
    if baseline_metadata.len() != BASELINE_ARCHIVE_BYTES {
        return Err(format!(
            "revision-9 archive length mismatch: {} != {BASELINE_ARCHIVE_BYTES}",
            baseline_metadata.len()
        ));
    }

    let mut files = Vec::new();
    for item in
        fs::read_dir(input_root).map_err(|error| format!("read input directory: {error}"))?
    {
        let item = item.map_err(|error| format!("read input entry: {error}"))?;
        let file_type = item
            .file_type()
            .map_err(|error| format!("input entry type: {error}"))?;
        if !file_type.is_file() {
            return Err("input tree must contain only regular top-level files".into());
        }
        let name = item
            .file_name()
            .into_string()
            .map_err(|_| "input filename is not UTF-8".to_string())?;
        files.push((name, item.path()));
    }
    files.sort_by(|left, right| left.0.cmp(&right.0));
    if files.len() != EXPECTED_FILE_COUNT
        || files
            .iter()
            .map(|(name, _)| name.as_str())
            .ne(EXPECTED_FILES.into_iter())
    {
        return Err("Canterbury11 filename set mismatch".into());
    }

    let mut source_bytes = 0u64;
    let mut block_count = 0u64;
    let mut baseline_record_bytes = 0u64;
    let mut portfolio_record_bytes = 0u64;
    let mut strategy_frame_bytes = [0u64; STRATEGIES.len()];
    let mut selected_blocks = [0u64; STRATEGIES.len()];
    let mut file_reports = Vec::with_capacity(files.len());

    for (name, path) in files {
        let input = fs::read(&path).map_err(|error| format!("read {name}: {error}"))?;
        checked_add(&mut source_bytes, input.len(), "source bytes")?;
        let mut file_baseline_records = 0u64;
        let mut file_portfolio_records = 0u64;
        let mut file_blocks = 0u64;

        for raw in input.chunks(BLOCK_CAP) {
            let mut baseline_best = usize::MAX;
            let mut portfolio_best = usize::MAX;
            let mut portfolio_choice = usize::MAX;

            for (index, (_, strategy)) in STRATEGIES.iter().enumerate() {
                let first = encode_and_verify(raw, *strategy).map_err(|error| {
                    format!(
                        "{name} block {file_blocks} strategy {}: {error}",
                        STRATEGIES[index].0
                    )
                })?;
                let second = encode_and_verify(raw, *strategy).map_err(|error| {
                    format!(
                        "{name} block {file_blocks} repeat {}: {error}",
                        STRATEGIES[index].0
                    )
                })?;
                if first != second {
                    return Err(format!(
                        "nondeterministic frame: {name} block {file_blocks} strategy {}",
                        STRATEGIES[index].0
                    ));
                }

                checked_add(
                    &mut strategy_frame_bytes[index],
                    first.len(),
                    "strategy frame bytes",
                )?;
                if index < 2 && first.len() < baseline_best {
                    baseline_best = first.len();
                }
                if first.len() < portfolio_best {
                    portfolio_best = first.len();
                    portfolio_choice = index;
                }
            }

            if baseline_best == usize::MAX || portfolio_best == usize::MAX {
                return Err("no complete candidate frame for block".into());
            }
            if portfolio_best > baseline_best {
                return Err("portfolio frame exceeded revision-9 baseline".into());
            }
            checked_add(
                &mut file_baseline_records,
                baseline_best + 4,
                "baseline records",
            )?;
            checked_add(
                &mut file_portfolio_records,
                portfolio_best + 4,
                "portfolio records",
            )?;
            selected_blocks[portfolio_choice] = selected_blocks[portfolio_choice]
                .checked_add(1)
                .ok_or_else(|| "selected block count overflow".to_string())?;
            file_blocks += 1;
            block_count += 1;
        }

        checked_add(
            &mut baseline_record_bytes,
            usize::try_from(file_baseline_records)
                .map_err(|_| "baseline records exceed usize".to_string())?,
            "baseline record total",
        )?;
        checked_add(
            &mut portfolio_record_bytes,
            usize::try_from(file_portfolio_records)
                .map_err(|_| "portfolio records exceed usize".to_string())?,
            "portfolio record total",
        )?;
        file_reports.push(json!({
            "name": name,
            "input_bytes": input.len(),
            "blocks": file_blocks,
            "revision9_record_bytes": file_baseline_records,
            "portfolio_record_bytes": file_portfolio_records,
        }));
    }

    if source_bytes != EXPECTED_INPUT_BYTES || block_count == 0 {
        return Err(format!(
            "Canterbury11 input length mismatch: {source_bytes} != {EXPECTED_INPUT_BYTES}"
        ));
    }
    let candidate_archive_bytes = BASELINE_ARCHIVE_BYTES
        .checked_sub(baseline_record_bytes)
        .and_then(|fixed| fixed.checked_add(portfolio_record_bytes))
        .ok_or_else(|| "archive-size delta underflow/overflow".to_string())?;
    if candidate_archive_bytes > BASELINE_ARCHIVE_BYTES {
        return Err("portfolio archive estimate exceeded revision-9 archive".into());
    }
    let size_gate_passed = u128::from(candidate_archive_bytes) * 100
        <= u128::from(SEVEN_ZIP_ARCHIVE_BYTES) * (100u128 - u128::from(REQUIRED_REDUCTION_PERCENT));

    let strategy_totals: Vec<_> = STRATEGIES
        .iter()
        .enumerate()
        .map(|(index, (name, _))| {
            json!({
                "strategy": name,
                "frame_bytes": strategy_frame_bytes[index],
                "selected_blocks": selected_blocks[index],
            })
        })
        .collect();

    serde_json::to_string(&json!({
        "schema": 1,
        "scope": "Canterbury11 exact per-block frame-size pilot only; no archive revision, speed, memory, holdout, or general-superiority claim",
        "candidate_order": STRATEGIES.iter().map(|(name, _)| *name).collect::<Vec<_>>(),
        "rounds": 2,
        "input_files": EXPECTED_FILE_COUNT,
        "input_bytes": source_bytes,
        "blocks": block_count,
        "revision9_archive_bytes": BASELINE_ARCHIVE_BYTES,
        "revision9_frame_record_bytes": baseline_record_bytes,
        "portfolio_frame_record_bytes": portfolio_record_bytes,
        "seven_zip_archive_bytes": SEVEN_ZIP_ARCHIVE_BYTES,
        "candidate_archive_bytes": candidate_archive_bytes,
        "minimum_reduction_percent": REQUIRED_REDUCTION_PERCENT,
        "size_gate_passed": size_gate_passed,
        "revision9_size_invariant_passed": true,
        "determinism_verified": true,
        "candidate_roundtrip_verified": true,
        "strategy_totals": strategy_totals,
        "files": file_reports,
    }))
    .map_err(|error| format!("serialize pilot report: {error}"))
}

fn main() {
    match run() {
        Ok(report) => println!("{report}"),
        Err(error) => {
            eprintln!("portfolio pilot failed: {error}");
            std::process::exit(2);
        }
    }
}
