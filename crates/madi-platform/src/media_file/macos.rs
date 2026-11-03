use objc2::MainThreadMarker;
use objc2_app_kit::{NSModalResponseOK, NSOpenPanel};
use objc2_foundation::{NSArray, NSString, NSURL};
use objc2_uniform_type_identifiers::{
    UTType, UTTypeAudio, UTTypeAudiovisualContent, UTTypeMovie, UTTypeVideo,
};
use std::{
    ffi::CStr,
    os::unix::ffi::OsStrExt,
    path::{Path, PathBuf},
};

fn media_types() -> [&'static UTType; 4] {
    // These non-null framework constants are available since macOS 11; our
    // minimum deployment is macOS 14. They are immutable and process-lived.
    unsafe {
        [
            UTTypeAudio,
            UTTypeAudiovisualContent,
            UTTypeMovie,
            UTTypeVideo,
        ]
    }
}

pub fn choose() -> Result<Option<PathBuf>, &'static str> {
    let mtm = MainThreadMarker::new().ok_or("media picker requires the main thread")?;
    let panel = NSOpenPanel::openPanel(mtm);
    panel.setAllowsMultipleSelection(false);
    panel.setCanChooseDirectories(false);
    panel.setAllowedContentTypes(&NSArray::from_slice(&media_types()));
    if panel.runModal() != NSModalResponseOK {
        return Ok(None);
    }
    let Some(url) = panel.URL() else {
        return Ok(None);
    };
    // NSURL owns the representation until this URL is released. Copy its bytes
    // now, avoiding lossy conversion of a filesystem path through a UI string.
    let bytes = unsafe { CStr::from_ptr(url.fileSystemRepresentation().as_ptr()) }.to_bytes();
    Ok(Some(PathBuf::from(std::ffi::OsStr::from_bytes(bytes))))
}

pub fn accepts_drop(path: &Path) -> bool {
    let extension = path
        .extension()
        .unwrap_or_default()
        .to_string_lossy()
        .to_lowercase();
    let Some(kind) = UTType::typeWithFilenameExtension(&NSString::from_str(&extension)) else {
        return true;
    };
    media_types()
        .into_iter()
        .any(|media| kind.conformsToType(media))
}

pub fn display_name(path: &Path) -> String {
    // Foundation's file URL bridges filesystem Unicode normalization (notably
    // decomposed Hangul) before lastPathComponent. Preserve its exact UI value.
    NSURL::fileURLWithPath(&NSString::from_str(&path.to_string_lossy()))
        .lastPathComponent()
        .map(|name| name.to_string())
        .unwrap_or_default()
}
