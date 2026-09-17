use std::path::PathBuf;

/// All operations fail explicitly; unsupported archive features are not silently discarded.
#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("I/O error: {0}")]
    Io(#[from] std::io::Error),
    #[error("invalid archive: {0}")]
    Format(String),
    #[error("unsupported feature: {0}")]
    Unsupported(String),
    #[error("resource limit exceeded: {0}")]
    Limit(String),
    #[error("invalid portable entry name: {0}")]
    InvalidPath(String),
    #[error("destination already exists: {0}")]
    Exists(PathBuf),
    #[error("invalid argument: {0}")]
    InvalidArgument(String),
    #[error("operation cancelled")]
    Cancelled,
}

pub type Result<T> = std::result::Result<T, Error>;
