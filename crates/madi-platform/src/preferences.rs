//! Isolated Tauri preferences; the original Swift domain is read-only.
pub use madi_core::preferences::{Legacy, Preferences};
use std::{
    fs,
    io::{self, Write},
    path::PathBuf,
};

pub struct Store {
    path: PathBuf,
    value: Preferences,
    persisted: bool,
}
impl Store {
    pub fn load(path: PathBuf, fallback: Preferences) -> io::Result<Self> {
        let (mut value, mut persisted) = match fs::read(&path) {
            Ok(bytes) => (
                serde_json::from_slice::<Preferences>(&bytes)
                    .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?,
                true,
            ),
            Err(error) if error.kind() == io::ErrorKind::NotFound => (fallback.clone(), false),
            Err(error) => return Err(error),
        };
        // Version 1 had only setup/presentation. Import newly supported keys
        // without changing the existing file until the user saves a setting.
        if value.schema == 1 {
            value.schema = 2;
            persisted = false;
            value.settings = fallback.settings;
        }
        value
            .validate()
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        Ok(Self {
            path,
            value,
            persisted,
        })
    }
    pub fn value(&self) -> &Preferences {
        &self.value
    }
    pub fn is_persisted(&self) -> bool {
        self.persisted
    }
    pub fn save(&mut self, value: Preferences) -> io::Result<()> {
        value
            .validate()
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidInput, error))?;
        let parent = self.path.parent().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "missing preferences directory")
        })?;
        fs::create_dir_all(parent)?;
        let mut pending = tempfile::Builder::new()
            .prefix(".madi-preferences-")
            .tempfile_in(parent)?;
        serde_json::to_writer_pretty(&mut pending, &value)?;
        pending.write_all(b"\n")?;
        pending.as_file().sync_all()?;
        pending
            .persist(&self.path)
            .map_err(|failure| failure.error)?;
        self.value = value;
        self.persisted = true;
        Ok(())
    }
}
#[cfg(target_os = "macos")]
pub fn read_legacy(defaults: &objc2_foundation::NSUserDefaults) -> Legacy {
    use objc2_foundation::NSString;
    let string = |name| {
        defaults
            .stringForKey(&NSString::from_str(name))
            .map(|value| value.to_string())
            .unwrap_or_default()
    };
    let boolean = |name| {
        let key = NSString::from_str(name);
        defaults
            .objectForKey(&key)
            .map(|_| defaults.boolForKey(&key))
    };
    let size = NSString::from_str("transcriptFontSize");
    Legacy {
        language_token_id: defaults.integerForKey(&NSString::from_str("languageTokenID")) as i64,
        translate_targets: defaults
            .stringArrayForKey(&NSString::from_str("translateTargets"))
            .map(|values| {
                (0..values.count())
                    .map(|index| values.objectAtIndex(index).to_string())
                    .collect()
            })
            .unwrap_or_default(),
        meeting_mode: string("meetingMode"),
        diarize_enabled: boolean("diarizeEnabled"),
        fixed_speaker_count: defaults.integerForKey(&NSString::from_str("fixedSpeakerCount"))
            as i64,
        audio_source: string("audioSource"),
        ui_language: string("uiLanguage"),
        appearance: string("appearance"),
        transcript_view_mode: boolean("transcriptViewMode"),
        transcript_font_size: defaults
            .objectForKey(&size)
            .map(|_| defaults.doubleForKey(&size)),
        settings: read_legacy_settings(defaults),
    }
}
#[cfg(target_os = "macos")]
pub fn read_legacy_settings(
    defaults: &objc2_foundation::NSUserDefaults,
) -> madi_core::settings::LegacySettings {
    use objc2_foundation::{NSNumber, NSString};
    let number = |name| {
        defaults
            .objectForKey(&NSString::from_str(name))
            .and_then(|value| value.downcast::<NSNumber>().ok())
            .map(|value| value.doubleValue())
    };
    let boolean = |name| {
        number(name).and_then(|value| match value {
            0.0 => Some(false),
            1.0 => Some(true),
            _ => None,
        })
    };
    let app_boolean = |name| {
        let key = NSString::from_str(name);
        defaults
            .objectForKey(&key)
            .map(|_| defaults.boolForKey(&key))
    };
    let app_double = |name| {
        let key = NSString::from_str(name);
        defaults
            .objectForKey(&key)
            .map(|_| defaults.doubleForKey(&key))
    };
    madi_core::settings::LegacySettings {
        live_window_seconds: number("liveWindowSeconds"),
        translate_tail_seconds: number("translateTailSeconds"),
        live_preview_enabled: boolean("livePreviewEnabled"),
        ai_reconcile_enabled: boolean("aiReconcileEnabled"),
        debug_capture: app_boolean("debugCapture"),
        vad_conf_threshold: app_double("vadConfThreshold"),
        caption: defaults
            .dataForKey(&NSString::from_str("captionSettings.v1"))
            .and_then(|data| serde_json::from_slice(&data.to_vec()).ok()),
    }
}
pub fn legacy() -> io::Result<Preferences> {
    #[cfg(target_os = "macos")]
    {
        use objc2::{AllocAnyThread, rc::autoreleasepool};
        use objc2_foundation::{NSString, NSUserDefaults};
        autoreleasepool(|_| {
            // Query only the listed setup/presentation/session keys, never enumerate or write
            // the shipping app's domain. The CLI oracle uses a volatile fixture.
            let defaults = NSUserDefaults::initWithSuiteName(
                NSUserDefaults::alloc(),
                Some(&NSString::from_str("com.companyjupiter.madi")),
            )
            .ok_or_else(|| io::Error::other("legacy preferences unavailable"))?;
            Ok(Preferences::from_legacy(read_legacy(&defaults)))
        })
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(Preferences::from_legacy(Legacy::default()))
    }
}

/// Apply the Swift scene's appearance to its own window. Tauri's macOS
/// set_theme mutates NSApp, which would also recolor unrelated native panels.
///
/// # Safety
/// `window` must be a live NSWindow owned by the caller on the main thread.
#[cfg(target_os = "macos")]
pub unsafe fn set_window_appearance(
    window: *mut std::ffi::c_void,
    appearance: madi_core::preferences::Appearance,
) -> Result<bool, &'static str> {
    use madi_core::preferences::Appearance;
    use objc2_app_kit::{
        NSAppearance, NSAppearanceCustomization, NSAppearanceNameAqua, NSAppearanceNameDarkAqua,
        NSWindow,
    };
    objc2::MainThreadMarker::new().ok_or("appearance requires the main thread")?;
    let window = unsafe { window.cast::<NSWindow>().as_ref() }.ok_or("window unavailable")?;
    let appearance = match appearance {
        Appearance::System => None,
        Appearance::Light => Some(
            NSAppearance::appearanceNamed(unsafe { NSAppearanceNameAqua })
                .ok_or("Aqua appearance unavailable")?,
        ),
        Appearance::Dark => Some(
            NSAppearance::appearanceNamed(unsafe { NSAppearanceNameDarkAqua })
                .ok_or("Dark Aqua appearance unavailable")?,
        ),
    };
    window.setAppearance(appearance.as_deref());
    Ok(is_dark(window))
}
/// Query the effective window appearance after a system theme notification.
///
/// # Safety
/// `window` must be a live NSWindow owned by the caller on the main thread.
#[cfg(target_os = "macos")]
pub unsafe fn window_is_dark(window: *mut std::ffi::c_void) -> Result<bool, &'static str> {
    objc2::MainThreadMarker::new().ok_or("appearance requires the main thread")?;
    let window =
        unsafe { window.cast::<objc2_app_kit::NSWindow>().as_ref() }.ok_or("window unavailable")?;
    Ok(is_dark(window))
}
#[cfg(target_os = "macos")]
fn is_dark(window: &objc2_app_kit::NSWindow) -> bool {
    use objc2_app_kit::{
        NSAppearanceCustomization, NSAppearanceNameAqua, NSAppearanceNameDarkAqua,
    };
    let choices =
        objc2_foundation::NSArray::from_slice(&[unsafe { NSAppearanceNameAqua }, unsafe {
            NSAppearanceNameDarkAqua
        }]);
    window
        .effectiveAppearance()
        .bestMatchFromAppearancesWithNames(&choices)
        .as_deref()
        == Some(unsafe { NSAppearanceNameDarkAqua })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn version_one_migration_preserves_existing_choices_and_imports_new_keys_only() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("preferences.json");
        let baseline = Preferences::from_legacy(Legacy::default());
        let mut old = serde_json::to_value(&baseline).unwrap();
        old["schema"] = 1.into();
        old["languageTokenId"] = 50266.into();
        old["diarize"] = false.into();
        old.as_object_mut().unwrap().remove("settings");
        let original = serde_json::to_vec(&old).unwrap();
        fs::write(&path, &original).unwrap();
        let mut fallback = baseline.clone();
        fallback.settings.live_window_seconds = 5.0;
        let mut store = Store::load(path.clone(), fallback).unwrap();
        assert_eq!(store.value().schema, 2);
        assert!(!store.is_persisted());
        assert_eq!(store.value().language_token_id, Some(50266));
        assert!(!store.value().diarize);
        assert_eq!(store.value().settings.live_window_seconds, 5.0);
        assert_eq!(fs::read(&path).unwrap(), original);
        store.save(store.value().clone()).unwrap();
        assert_eq!(
            Store::load(path, baseline)
                .unwrap()
                .value()
                .settings
                .live_window_seconds,
            5.0
        );
    }
    #[test]
    fn corrupt_or_future_file_is_retained_and_invalid_values_cannot_be_saved() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("preferences.json");
        let baseline = Preferences::from_legacy(Legacy::default());
        for bytes in [
            b"broken".to_vec(),
            serde_json::to_vec(&Preferences {
                schema: 3,
                ..baseline.clone()
            })
            .unwrap(),
        ] {
            fs::write(&path, &bytes).unwrap();
            assert!(Store::load(path.clone(), baseline.clone()).is_err());
            assert_eq!(fs::read(&path).unwrap(), bytes);
        }
        fs::remove_file(&path).unwrap();
        let mut store = Store::load(path.clone(), baseline.clone()).unwrap();
        assert!(!path.exists());
        let mut invalid = baseline.clone();
        invalid.presentation.font_size = f64::NAN;
        assert!(store.save(invalid).is_err());
        assert_eq!(store.value(), &baseline);
        assert!(!path.exists());
    }
}
