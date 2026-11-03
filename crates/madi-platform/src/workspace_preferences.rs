//! An isolated workspace preference file. The shipping Swift domain is a
//! read-only fallback; every later change belongs to the Tauri configuration.
use serde::{Deserialize, Serialize};
use std::{
    fs,
    io::{self, Write},
    path::{Path, PathBuf},
};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Preferences {
    pub schema: u32,
    pub auto_save: bool,
    pub folder: PathBuf,
    #[serde(default)]
    pub editor_settings: madi_core::transcript::export::EditorSettings,
}
impl Preferences {
    pub fn from_legacy(legacy: Legacy, default_folder: PathBuf) -> Self {
        Self {
            schema: 1,
            auto_save: legacy.auto_save.unwrap_or(true),
            folder: legacy.folder.unwrap_or(default_folder),
            editor_settings: legacy.editor_settings.unwrap_or_default(),
        }
    }
}
#[derive(Default)]
pub struct Legacy {
    pub auto_save: Option<bool>,
    pub folder: Option<PathBuf>,
    pub editor_settings: Option<madi_core::transcript::export::EditorSettings>,
}
pub struct Store {
    path: PathBuf,
    value: Preferences,
}
impl Store {
    pub fn load(path: PathBuf, fallback: Preferences) -> io::Result<Self> {
        let value = match fs::read(&path) {
            Ok(bytes) => serde_json::from_slice::<Preferences>(&bytes)
                .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?,
            Err(error) if error.kind() == io::ErrorKind::NotFound => fallback,
            Err(error) => return Err(error),
        };
        if value.schema != 1 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "unsupported workspace preferences version",
            ));
        }
        Ok(Self { path, value })
    }
    pub fn value(&self) -> &Preferences {
        &self.value
    }
    pub fn save(&mut self, value: Preferences) -> io::Result<()> {
        if value.schema != 1 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "unsupported workspace preferences version",
            ));
        }
        let parent = self.path.parent().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "missing preferences directory")
        })?;
        fs::create_dir_all(parent)?;
        let mut pending = tempfile::Builder::new()
            .prefix(".madi-workspace-")
            .tempfile_in(parent)?;
        serde_json::to_writer_pretty(&mut pending, &value)?;
        pending.write_all(b"\n")?;
        pending.as_file().sync_all()?;
        pending
            .persist(&self.path)
            .map_err(|failure| failure.error)?;
        self.value = value;
        Ok(())
    }
}

#[cfg(target_os = "macos")]
pub fn legacy_and_default() -> io::Result<(Legacy, PathBuf)> {
    use objc2::{AllocAnyThread, rc::autoreleasepool};
    use objc2_foundation::{
        NSFileManager, NSNumber, NSSearchPathDirectory, NSSearchPathDomainMask, NSString,
        NSUserDefaults,
    };
    autoreleasepool(|_| {
        // Only these three non-secret keys are queried. Never enumerate or
        // modify the original application's preference dictionary.
        let defaults = NSUserDefaults::initWithSuiteName(
            NSUserDefaults::alloc(),
            Some(&NSString::from_str("com.companyjupiter.madi")),
        )
        .ok_or_else(|| io::Error::other("workspace legacy preferences unavailable"))?;
        let enabled = defaults
            .objectForKey(&NSString::from_str("autoSaveEnabled"))
            .and_then(|value| value.downcast::<NSNumber>().ok())
            .and_then(|number| match number.doubleValue() {
                0.0 => Some(false),
                1.0 => Some(true),
                _ => None,
            });
        let folder = defaults
            .stringForKey(&NSString::from_str("autoSaveFolder"))
            .map(|path| {
                crate::workspace_scan::macos::path(&objc2_foundation::NSURL::fileURLWithPath(&path))
            });
        let editor_settings = defaults
            .dataForKey(&NSString::from_str("editorSettings"))
            .and_then(|data| serde_json::from_slice(&data.to_vec()).ok());
        let fm = NSFileManager::defaultManager();
        let documents = fm.URLsForDirectory_inDomains(
            NSSearchPathDirectory::DocumentDirectory,
            NSSearchPathDomainMask::UserDomainMask,
        );
        let root = if documents.count() > 0 {
            documents.objectAtIndex(0)
        } else {
            fm.homeDirectoryForCurrentUser()
        };
        let root = root
            .URLByAppendingPathComponent_isDirectory(&NSString::from_str("madi"), true)
            .ok_or_else(|| io::Error::other("default workspace directory unavailable"))?;
        Ok((
            Legacy {
                auto_save: enabled,
                folder,
                editor_settings,
            },
            crate::workspace_scan::macos::path(&root),
        ))
    })
}

/// Called after native selection/initialization, on a blocking worker. Failure
/// leaves scanning/saving to expose their usual empty/error behavior like Swift.
pub fn prepare_default_folder(folder: &Path) {
    let _ = fs::create_dir_all(folder);
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fallback_is_read_only_and_saved_tauri_values_win_on_relaunch() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("isolated/workspace.json");
        let defaults =
            Preferences::from_legacy(Legacy::default(), root.path().join("Documents/madi"));
        assert!(defaults.auto_save);
        let mut store = Store::load(path.clone(), defaults.clone()).unwrap();
        assert!(!path.exists());
        let customized = Preferences::from_legacy(
            Legacy {
                auto_save: Some(false),
                folder: Some(root.path().join("original")),
                ..Default::default()
            },
            root.path().join("ignored"),
        );
        store.save(customized.clone()).unwrap();
        assert_eq!(Store::load(path, defaults).unwrap().value(), &customized);
        assert!(!root.path().join("original").exists());
    }
    #[test]
    fn failed_save_and_invalid_existing_file_preserve_data_and_active_values() {
        let root = tempfile::tempdir().unwrap();
        let path = root.path().join("workspace.json");
        let original = Preferences::from_legacy(Legacy::default(), root.path().to_owned());
        let mut store = Store::load(path.clone(), original.clone()).unwrap();
        fs::create_dir(&path).unwrap();
        fs::write(path.join("keep"), "foreign").unwrap();
        let mut next = original.clone();
        next.auto_save = false;
        assert!(store.save(next).is_err());
        assert_eq!(store.value(), &original);
        assert_eq!(fs::read_to_string(path.join("keep")).unwrap(), "foreign");
        assert_eq!(fs::read_dir(root.path()).unwrap().count(), 1);
        fs::remove_dir_all(&path).unwrap();
        fs::write(&path, "corrupt but retained").unwrap();
        assert!(Store::load(path.clone(), original).is_err());
        assert_eq!(fs::read_to_string(path).unwrap(), "corrupt but retained");
    }
}
