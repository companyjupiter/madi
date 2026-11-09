//! Native media selection. Paths enter through the OS, never through a web command.
use std::path::{Path, PathBuf};

#[cfg(target_os = "macos")]
mod macos;

/// Must be called on AppKit's main thread. Cancellation preserves the old selection.
pub fn choose() -> Result<Option<PathBuf>, &'static str> {
    #[cfg(target_os = "macos")]
    return macos::choose();
    #[cfg(not(target_os = "macos"))]
    Err("native media selection is not implemented on this platform")
}

/// Matches ContentView.isMediaFile, including its unknown-extension behavior.
/// This is only staging, not a promise that AVFoundation can decode the file.
pub fn accepts_drop(path: &Path) -> bool {
    #[cfg(target_os = "macos")]
    return macos::accepts_drop(path);
    #[cfg(not(target_os = "macos"))]
    {
        let _ = path;
        false
    }
}

pub fn summary(path: &Path) -> madi_core::setup::StagedFile {
    let bytes = std::fs::symlink_metadata(path)
        .map(|m| m.len())
        .unwrap_or(0);
    #[cfg(target_os = "macos")]
    let name = macos::display_name(path);
    #[cfg(not(target_os = "macos"))]
    let name = path
        .file_name()
        .unwrap_or_default()
        .to_string_lossy()
        .into_owned();
    madi_core::setup::StagedFile {
        name,
        size_label: size_label(bytes),
    }
}

/// Compact label used by the shipping Swift view (not localized byte units).
pub fn size_label(bytes: u64) -> String {
    if bytes < 1024 {
        format!("{bytes}B")
    } else if bytes < 1024 * 1024 {
        format!("{}k", bytes / 1024)
    } else {
        format!("{:.1}M", bytes as f64 / (1024.0 * 1024.0))
    }
}
