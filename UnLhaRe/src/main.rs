use clap::{Parser, Subcommand, ValueEnum};
use std::{path::PathBuf, process::ExitCode};
use unlhare::{
    CreateOptions, Limits, Method, create_from_directory, extract_archive, list_archive,
    verify_archive,
};

#[derive(Parser)]
#[command(version, about = "64-bit cross-platform LHA and LHC archiver (UTF-8)")]
struct Cli {
    /// Maximum number of archive entries.
    #[arg(long, global = true, default_value_t = 100_000)]
    max_entries: u64,
    /// Maximum uncompressed bytes per file.
    #[arg(long, global = true, default_value_t = 268_435_456)]
    max_entry_bytes: u64,
    /// Maximum total uncompressed bytes.
    #[arg(long, global = true, default_value_t = 2_147_483_648)]
    max_total_bytes: u64,
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Create an independent LHC1 archive (not an LHA method).
    LhcCreate {
        archive: PathBuf,
        #[arg(short, long)]
        source: PathBuf,
        /// Explicit revision-2 through revision-10 strategies; default preserves revision 1.
        #[arg(long, value_enum, default_value_t = LhcStrategy::Mdl)]
        strategy: LhcStrategy,
        /// Block-compression workers (output bytes are identical for every value).
        /// Each worker reserves the fixed LHC codec memory budget.
        #[arg(long, default_value_t = 1)]
        threads: usize,
        /// Do not fsync the archive before publishing it.
        #[arg(long)]
        no_fsync: bool,
    },
    /// List LHC metadata; use lhc-test for complete decoded CRC validation.
    LhcList {
        archive: PathBuf,
        #[arg(long)]
        json: bool,
    },
    /// Decode and validate every LHC file.
    LhcTest {
        archive: PathBuf,
        /// Block-decoding workers: 0 keeps the legacy choice, 1 is serial.
        #[arg(long, default_value_t = 0)]
        threads: usize,
    },
    /// Extract LHC entries after validation, without overwriting.
    LhcExtract {
        archive: PathBuf,
        #[arg(short, long)]
        output: PathBuf,
        /// Block-decoding workers: 0 keeps the legacy choice, 1 is serial.
        #[arg(long, default_value_t = 0)]
        threads: usize,
        /// Do not fsync each extracted file before publishing it.
        #[arg(long)]
        no_fsync: bool,
    },
    /// List entry metadata (use test for CRC verification).
    List {
        archive: PathBuf,
        #[arg(long)]
        json: bool,
    },
    /// Verify complete decoded lengths and CRCs.
    Test { archive: PathBuf },
    /// Extract files without overwriting existing destinations.
    Extract {
        archive: PathBuf,
        #[arg(short, long)]
        output: PathBuf,
    },
    /// Create a new archive recursively from a directory.
    Create {
        archive: PathBuf,
        #[arg(short, long)]
        source: PathBuf,
        #[arg(long, value_enum, default_value_t = Codec::Lh5)]
        method: Codec,
        /// Compare standard and high-compression output (slower, more memory).
        #[arg(long)]
        high_compression: bool,
    },
}

#[derive(Clone, Copy, ValueEnum)]
enum Codec {
    Stored,
    Lh4,
    Lh5,
    Lh6,
    Lh7,
}

#[derive(Clone, Copy, ValueEnum)]
enum LhcStrategy {
    Mdl,
    HybridTrial,
    BinaryAdaptive,
    RecordTrial,
    Gather32Trial,
    Delta16Trial,
    RecordFastTrial,
    SpatialBitsTrial,
    RecordAdaptiveTrial,
    #[value(name = "spatial-mdl-trial")]
    SpatialMdlTrial,
    #[value(name = "portfolio-trial")]
    PortfolioTrial,
    PortfolioPpmTrial,
}

fn run(cli: Cli) -> unlhare::Result<()> {
    let limits = Limits {
        max_entries: cli.max_entries,
        max_entry_bytes: cli.max_entry_bytes,
        max_total_bytes: cli.max_total_bytes,
    };
    match cli.command {
        Command::LhcCreate {
            archive,
            source,
            strategy,
            threads,
            no_fsync,
        } => {
            // 並列作成は worker ごとに固定の codec 予約を課金する。
            let workers = threads.clamp(1, unlhare::lhc::MAX_CREATE_WORKERS) as u64;
            unlhare::lhc::create_from_directory(
                &source,
                &archive,
                &unlhare::lhc::CreateOptions {
                    limits,
                    block_strategy: match strategy {
                        LhcStrategy::Mdl => unlhare::lhc::BlockStrategy::Mdl,
                        LhcStrategy::HybridTrial => unlhare::lhc::BlockStrategy::HybridTrial,
                        LhcStrategy::BinaryAdaptive => unlhare::lhc::BlockStrategy::BinaryAdaptive,
                        LhcStrategy::RecordTrial => unlhare::lhc::BlockStrategy::RecordTrial,
                        LhcStrategy::Gather32Trial => unlhare::lhc::BlockStrategy::Gather32Trial,
                        LhcStrategy::Delta16Trial => unlhare::lhc::BlockStrategy::Delta16Trial,
                        LhcStrategy::RecordFastTrial => {
                            unlhare::lhc::BlockStrategy::RecordFastTrial
                        }
                        LhcStrategy::SpatialBitsTrial => {
                            unlhare::lhc::BlockStrategy::SpatialBitsTrial
                        }
                        LhcStrategy::RecordAdaptiveTrial => {
                            unlhare::lhc::BlockStrategy::RecordAdaptiveTrial
                        }
                        LhcStrategy::SpatialMdlTrial => {
                            unlhare::lhc::BlockStrategy::SpatialMdlTrial
                        }
                        LhcStrategy::PortfolioTrial => unlhare::lhc::BlockStrategy::PortfolioTrial,
                        LhcStrategy::PortfolioPpmTrial => {
                            unlhare::lhc::BlockStrategy::PortfolioPpmTrial
                        }
                    },
                    max_codec_memory_bytes: unlhare::lhc::CODEC_MEMORY_BYTES * workers,
                    threads,
                    skip_fsync: no_fsync,
                },
            )?;
            println!("Created LHC: {}", archive.display());
        }
        Command::LhcList { archive, json } => {
            let entries = unlhare::lhc::list_archive(&archive, &limits)?;
            if json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&entries)
                        .map_err(|e| unlhare::Error::Format(e.to_string()))?
                );
            } else {
                for entry in entries {
                    println!(
                        "LHC1\t{}\t{}\t{}",
                        entry.original_size, entry.compressed_size, entry.name
                    );
                }
            }
        }
        Command::LhcTest { archive, threads } => {
            let s = unlhare::lhc::verify_archive_with_options(
                &archive,
                &limits,
                &unlhare::ExtractOptions {
                    threads,
                    ..Default::default()
                },
            )?;
            println!(
                "OK LHC: {} files, {} entries, {} bytes",
                s.files, s.entries, s.bytes
            );
        }
        Command::LhcExtract {
            archive,
            output,
            threads,
            no_fsync,
        } => {
            let s = unlhare::lhc::extract_archive_with_options(
                &archive,
                &output,
                &limits,
                &unlhare::ExtractOptions {
                    threads,
                    skip_fsync: no_fsync,
                    ..Default::default()
                },
            )?;
            println!("Extracted LHC: {} files, {} bytes", s.files, s.bytes);
        }
        Command::List { archive, json } => {
            let entries = list_archive(&archive, &limits)?;
            if json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&entries)
                        .map_err(|e| unlhare::Error::Format(e.to_string()))?
                );
            } else {
                for entry in entries {
                    println!(
                        "{}\t{}\t{}\t{}",
                        entry.method, entry.original_size, entry.compressed_size, entry.name
                    );
                }
            }
        }
        Command::Test { archive } => {
            let summary = verify_archive(&archive, &limits)?;
            println!(
                "OK: {} files, {} entries, {} bytes",
                summary.files, summary.entries, summary.bytes
            );
        }
        Command::Extract { archive, output } => {
            let summary = extract_archive(&archive, &output, &limits)?;
            println!(
                "Extracted: {} files, {} bytes",
                summary.files, summary.bytes
            );
        }
        Command::Create {
            archive,
            source,
            method,
            high_compression,
        } => {
            let method = match method {
                Codec::Stored => Method::Stored,
                Codec::Lh4 => Method::Lh4,
                Codec::Lh5 => Method::Lh5,
                Codec::Lh6 => Method::Lh6,
                Codec::Lh7 => Method::Lh7,
            };
            let effort = if high_compression {
                unlhare::CompressionEffort::High
            } else {
                unlhare::CompressionEffort::Standard
            };
            create_from_directory(
                &source,
                &archive,
                &CreateOptions {
                    method,
                    limits,
                    effort,
                },
            )?;
            println!("Created: {}", archive.display());
        }
    }
    Ok(())
}

fn main() -> ExitCode {
    match run(Cli::parse()) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("unlhare: {error}");
            ExitCode::FAILURE
        }
    }
}
