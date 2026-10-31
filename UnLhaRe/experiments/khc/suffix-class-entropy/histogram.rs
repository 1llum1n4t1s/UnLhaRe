//! 診断専用の整数件数。確率や学習モデルへ値を戻さない。
use std::path::Path;
use std::sync::Mutex;

const CLASSES: usize = 7;
const COMPONENTS: usize = 3;
const BINS: usize = 32768;
const COUNTS: usize = CLASSES * COMPONENTS * BINS;
static HISTOGRAM: Mutex<Option<Vec<u64>>> = Mutex::new(None);

fn aux_path(path: &Path) -> std::path::PathBuf {
    let mut name = path.as_os_str().to_os_string();
    name.push(".q15hist");
    name.into()
}
pub(super) fn initialize(output: &Path) -> super::Result<()> {
    for path in [output.to_path_buf(), aux_path(output)] {
        match std::fs::symlink_metadata(&path) {
            Ok(_) => return Err("diagnostic output already exists".into()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => return Err(format!("diagnostic output metadata: {e}")),
        }
    }
    let mut guard = HISTOGRAM.lock().map_err(|_| "histogram mutex poisoned")?;
    if guard.is_some() {
        return Err("histogram already initialized".into());
    }
    *guard = Some(super::filled(COUNTS, 0u64)?);
    Ok(())
}
pub(super) fn observe(class: u32, predictions: [u16; 3], bit: bool) -> super::Result<()> {
    if class as usize >= CLASSES || predictions.iter().any(|p| !(1..32768).contains(p)) {
        return Err("histogram class/probability outside bounds".into());
    }
    let mut guard = HISTOGRAM.lock().map_err(|_| "histogram mutex poisoned")?;
    let counts = guard.as_mut().ok_or("histogram uninitialized")?;
    for (component, zero) in predictions.into_iter().enumerate() {
        let observed = usize::from(if bit { 32768 - zero } else { zero });
        let index = (class as usize * COMPONENTS + component) * BINS + observed;
        let count = counts
            .get_mut(index)
            .ok_or("histogram index outside bounds")?;
        *count = count.checked_add(1).ok_or("histogram count overflow")?;
    }
    Ok(())
}
pub(super) fn publish(output: &Path) -> super::Result<()> {
    let guard = HISTOGRAM.lock().map_err(|_| "histogram mutex poisoned")?;
    let counts = guard.as_ref().ok_or("histogram uninitialized")?;
    let mut bytes = super::filled(20 + COUNTS * 8, 0u8)?;
    bytes[..8].copy_from_slice(b"KQHIST01");
    for (i, value) in [CLASSES, COMPONENTS, BINS].into_iter().enumerate() {
        bytes[8 + i * 4..12 + i * 4].copy_from_slice(&(value as u32).to_le_bytes());
    }
    for (i, count) in counts.iter().enumerate() {
        bytes[20 + i * 8..28 + i * 8].copy_from_slice(&count.to_le_bytes());
    }
    super::publish(&aux_path(output), &bytes)
}
