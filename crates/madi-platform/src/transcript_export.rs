use madi_core::transcript::{
    Line, archive,
    export::{self, EditorSettings},
};
use serde::{Deserialize, Serialize};
use std::{
    collections::BTreeMap,
    io::{self, Write},
    path::{Path, PathBuf},
};
#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Format {
    Md,
    Srt,
    Vtt,
    Txt,
    Json,
}
impl Format {
    pub fn extension(self) -> &'static str {
        match self {
            Self::Md => "md",
            Self::Srt => "srt",
            Self::Vtt => "vtt",
            Self::Txt => "txt",
            Self::Json => "json",
        }
    }
}
pub fn render(
    format: Format,
    lines: &[Line],
    names: &BTreeMap<i64, String>,
    settings: &EditorSettings,
) -> io::Result<String> {
    Ok(match format {
        Format::Md => archive::markdown(lines, names, None),
        Format::Txt => archive::plain_text(lines, names),
        Format::Srt => export::srt(lines, names, &Default::default()),
        Format::Vtt => export::vtt(lines, names, &Default::default()),
        Format::Json => format_json(&export::json(lines, names, settings))?,
    })
}
pub fn format_json(value: &serde_json::Value) -> io::Result<String> {
    #[cfg(target_os = "macos")]
    {
        use objc2_foundation::{NSJSONSerialization, NSJSONWritingOptions};
        objc2::rc::autoreleasepool(|_| {
            // Bridge the numbers directly. Parsing a decimal intermediate in
            // Foundation can round a Double differently from Swift NSNumber.
            let object = native_json(value);
            // Only immutable Foundation JSON types are constructed below.
            let data = unsafe {
                NSJSONSerialization::dataWithJSONObject_options_error(
                    &object,
                    NSJSONWritingOptions::PrettyPrinted
                        | NSJSONWritingOptions::SortedKeys
                        | NSJSONWritingOptions::WithoutEscapingSlashes,
                )
            }
            .map_err(|error| io::Error::other(error.to_string()))?;
            String::from_utf8(data.to_vec()).map_err(io::Error::other)
        })
    }
    #[cfg(not(target_os = "macos"))]
    {
        serde_json::to_string_pretty(value).map_err(io::Error::other)
    }
}
#[cfg(target_os = "macos")]
fn native_json(value: &serde_json::Value) -> objc2::rc::Retained<objc2::runtime::AnyObject> {
    use objc2_foundation::{NSArray, NSDictionary, NSNull, NSNumber, NSString};
    match value {
        serde_json::Value::Null => NSNull::null().into_super().into_super(),
        serde_json::Value::Bool(value) => NSNumber::new_bool(*value)
            .into_super()
            .into_super()
            .into_super(),
        serde_json::Value::Number(value) => {
            let number = if value.is_f64() {
                NSNumber::new_f64(value.as_f64().unwrap())
            } else if let Some(value) = value.as_i64() {
                NSNumber::new_i64(value)
            } else {
                NSNumber::new_u64(value.as_u64().unwrap())
            };
            number.into_super().into_super().into_super()
        }
        serde_json::Value::String(value) => NSString::from_str(value).into_super().into_super(),
        serde_json::Value::Array(values) => {
            NSArray::from_retained_slice(&values.iter().map(native_json).collect::<Vec<_>>())
                .into_super()
                .into_super()
        }
        serde_json::Value::Object(values) => {
            let keys: Vec<_> = values.keys().map(|key| NSString::from_str(key)).collect();
            let objects: Vec<_> = values.values().map(native_json).collect();
            NSDictionary::from_retained_objects(
                &keys.iter().map(|key| &**key).collect::<Vec<_>>(),
                &objects,
            )
            .into_super()
            .into_super()
        }
    }
}
/// Destination must come from the native save panel, which owns overwrite
/// confirmation. The renderer is never granted an arbitrary filesystem path.
pub fn write_selected(path: &Path, content: &str) -> io::Result<()> {
    let folder = path
        .parent()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "missing export directory"))?;
    let mut file = tempfile::Builder::new()
        .prefix(".madi-export-")
        .tempfile_in(folder)?;
    file.write_all(content.as_bytes())?;
    file.as_file().sync_all()?;
    file.persist(path).map_err(|failure| failure.error)?;
    Ok(())
}
pub fn choose(format: Format) -> io::Result<Option<PathBuf>> {
    #[cfg(target_os = "macos")]
    {
        use objc2::MainThreadMarker;
        use objc2_app_kit::{NSModalResponseOK, NSSavePanel};
        use objc2_foundation::NSString;
        let mtm = MainThreadMarker::new()
            .ok_or_else(|| io::Error::other("export picker requires the main thread"))?;
        let panel = NSSavePanel::savePanel(mtm);
        panel.setNameFieldStringValue(&NSString::from_str(&format!(
            "transcript.{}",
            format.extension()
        )));
        if panel.runModal() != NSModalResponseOK {
            return Ok(None);
        }
        Ok(panel
            .URL()
            .map(|url| crate::workspace_scan::macos::path(&url)))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = format;
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "native export selection is not implemented on this platform",
        ))
    }
}
