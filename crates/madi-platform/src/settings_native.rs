//! Settings-only AppKit presentation and fixed native destinations.
use objc2::MainThreadMarker;
use objc2_app_kit::{NSScreen, NSWorkspace};
use objc2_foundation::NSArray;
use serde_json::{Value, json};
use std::{io, path::Path};

pub fn metadata() -> Result<Value, String> {
    let main = MainThreadMarker::new().ok_or("settings metadata requires the main thread")?;
    let native_screens = NSScreen::screens(main);
    let screens: Vec<_> = (0..native_screens.count())
        .map(|index| {
            let frame = native_screens.objectAtIndex(index).frame();
            json!({"index":index,"width":frame.size.width as i64,"height":frame.size.height as i64})
        })
        .collect();
    Ok(json!({"artwork":crate::model_presentation::settings_artwork()?,"screens":screens}))
}

/// Only host-selected model/debug paths reach this function, never renderer paths.
pub fn reveal(path: &Path, select: bool) -> io::Result<()> {
    let _main = MainThreadMarker::new()
        .ok_or_else(|| io::Error::other("Finder requires the main thread"))?;
    let url = crate::workspace_scan::macos::url(path)?;
    let workspace = NSWorkspace::sharedWorkspace();
    if select {
        workspace.activateFileViewerSelectingURLs(&NSArray::from_slice(&[&*url]));
    } else if !workspace.openURL(&url) {
        return Err(io::Error::other("could not open the debug folder"));
    }
    Ok(())
}
