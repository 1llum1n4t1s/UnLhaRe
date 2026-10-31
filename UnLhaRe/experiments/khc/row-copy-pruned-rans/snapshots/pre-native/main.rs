use clap::{Parser, Subcommand, ValueEnum};
use std::{path::PathBuf, process::ExitCode};
use unlhare::{
    CreateOptions, Limits, Method, create_from_directory, extract_archive, list_archive,
    verify_archive,
};

#[derive(Parser)]
#[command(version, about = "64-bit cross-platform LHA and KHC archiver (UTF-8)")]
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
    /// Create an independent KHC1 archive (not an LHA method).
    KhcCreate {
        archive: PathBuf,
        #[arg(short, long)]
        source: PathBuf,
        /// Explicit revision-2 experimental strategies; default preserves revision 1.
        #[arg(long, value_enum, default_value_t = KhcStrategy::Mdl)]
        strategy: KhcStrategy,
    },
    /// List KHC metadata; use khc-test for complete decoded CRC validation.
    KhcList {
        archive: PathBuf,
        #[arg(long)]
        json: bool,
    },
    /// Decode and validate every KHC file.
    KhcTest { archive: PathBuf },
    /// Extract KHC entries after validation, without overwriting.
    KhcExtract {
        archive: PathBuf,
        #[arg(short, long)]
        output: PathBuf,
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
enum KhcStrategy {
    Mdl,
    HybridTrial,
    BinaryAdaptive,
}

fn run(cli: Cli) -> unlhare::Result<()> {
    let limits = Limits {
        max_entries: cli.max_entries,
        max_entry_bytes: cli.max_entry_bytes,
        max_total_bytes: cli.max_total_bytes,
    };
    match cli.command {
        Command::KhcCreate {
            archive,
            source,
            strategy,
        } => {
            unlhare::khc::create_from_directory(
                &source,
                &archive,
                &unlhare::khc::CreateOptions {
                    limits,
                    block_strategy: match strategy {
                        KhcStrategy::Mdl => unlhare::khc::BlockStrategy::Mdl,
                        KhcStrategy::HybridTrial => unlhare::khc::BlockStrategy::HybridTrial,
                        KhcStrategy::BinaryAdaptive => unlhare::khc::BlockStrategy::BinaryAdaptive,
                    },
                    ..Default::default()
                },
            )?;
            println!("Created KHC: {}", archive.display());
        }
        Command::KhcList { archive, json } => {
            let entries = unlhare::khc::list_archive(&archive, &limits)?;
            if json {
                println!(
                    "{}",
                    serde_json::to_string_pretty(&entries)
                        .map_err(|e| unlhare::Error::Format(e.to_string()))?
                );
            } else {
                for entry in entries {
                    println!(
                        "KHC1\t{}\t{}\t{}",
                        entry.original_size, entry.compressed_size, entry.name
                    );
                }
            }
        }
        Command::KhcTest { archive } => {
            let s = unlhare::khc::verify_archive(&archive, &limits)?;
            println!(
                "OK KHC: {} files, {} entries, {} bytes",
                s.files, s.entries, s.bytes
            );
        }
        Command::KhcExtract { archive, output } => {
            let s = unlhare::khc::extract_archive(&archive, &output, &limits)?;
            println!("Extracted KHC: {} files, {} bytes", s.files, s.bytes);
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
