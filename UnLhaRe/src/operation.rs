use crate::{Error, Result};
use serde::Serialize;

/// Progress reported by long-running archive operations.
///
/// `total == 0` denotes an indeterminate amount of work. Phase values are
/// stable for application integrations: 1 prepares/scans, 2 reads/compresses,
/// 3 extracts/verifies, and 4 finalizes output.
/// In creation reports, phase 2 also counts bytes of entries skipped after scanning.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
pub struct Progress {
    pub phase: u32,
    pub completed: u64,
    pub total: u64,
}

/// Borrowed progress callback. Returning `false` cancels the operation.
pub type ProgressCallback<'a> = &'a mut dyn FnMut(Progress) -> bool;

pub(crate) fn checkpoint(
    callback: &mut dyn FnMut(Progress) -> bool,
    phase: u32,
    completed: u64,
    total: u64,
) -> Result<()> {
    if callback(Progress {
        phase,
        completed,
        total,
    }) {
        Ok(())
    } else {
        Err(Error::Cancelled)
    }
}
