//! AppKit interactions used by TranscriptView. Call only on the main thread.
use serde::Deserialize;

#[derive(Deserialize)]
pub struct RenameLabels {
    pub title: String,
    pub message: String,
    pub placeholder: String,
    pub save: String,
    pub cancel: String,
}

pub fn copy(text: &str) -> Result<(), &'static str> {
    #[cfg(target_os = "macos")]
    {
        use objc2_app_kit::{NSPasteboard, NSPasteboardTypeString};
        use objc2_foundation::NSString;
        let _ = objc2::MainThreadMarker::new().ok_or("clipboard requires main thread")?;
        let board = NSPasteboard::generalPasteboard();
        board.clearContents();
        // The exported AppKit constant is immutable and valid for this process.
        if board.setString_forType(&NSString::from_str(text), unsafe { NSPasteboardTypeString }) {
            Ok(())
        } else {
            Err("native clipboard rejected text")
        }
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = text;
        Err("native clipboard is not implemented on this platform")
    }
}

pub fn rename(current: &str, labels: &RenameLabels) -> Result<Option<String>, &'static str> {
    #[cfg(target_os = "macos")]
    {
        use objc2_app_kit::{NSAlert, NSAlertFirstButtonReturn, NSTextField};
        use objc2_foundation::{NSPoint, NSRect, NSSize, NSString};
        let main = objc2::MainThreadMarker::new().ok_or("speaker dialog requires main thread")?;
        let alert = NSAlert::new(main);
        alert.setMessageText(&NSString::from_str(&labels.title));
        alert.setInformativeText(&NSString::from_str(&labels.message));
        alert.addButtonWithTitle(&NSString::from_str(&labels.save));
        alert
            .addButtonWithTitle(&NSString::from_str(&labels.cancel))
            .setKeyEquivalent(&NSString::from_str("\u{1b}"));
        let input = NSTextField::textFieldWithString(&NSString::from_str(current), main);
        input.setPlaceholderString(Some(&NSString::from_str(&labels.placeholder)));
        input.setFrame(NSRect::new(
            NSPoint::new(0.0, 0.0),
            NSSize::new(240.0, 24.0),
        ));
        alert.setAccessoryView(Some(&input));
        alert.window().makeFirstResponder(Some(&input));
        Ok((alert.runModal() == NSAlertFirstButtonReturn).then(|| input.stringValue().to_string()))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (current, labels);
        Err("native speaker dialog is not implemented on this platform")
    }
}
