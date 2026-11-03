//! Read-only model lookup and integrity checks. No installer or user-data writes.
use madi_core::assets::{RemoteAsset, TRANSCRIPTION, TranslationVariant};
use sha2::{Digest, Sha256};
use std::{
    fs::{File, OpenOptions},
    io::{self, Read},
    path::{Path, PathBuf},
};

pub struct Locations {
    /// Native host resolves this to Contents/Resources on macOS.
    pub bundle_resources: PathBuf,
    /// Native host resolves this to Contents/MacOS on macOS.
    pub bundle_executables: PathBuf,
    /// Existing Madi data root, not Tauri's distinct parity bundle-ID directory.
    /// Merely constructing a catalog never creates this directory.
    pub support: PathBuf,
}
impl Locations {
    pub fn transcription_model(&self) -> PathBuf {
        let bundled = self.bundle_resources.join(TRANSCRIPTION.name);
        if bundled.exists() {
            bundled
        } else {
            self.support.join(TRANSCRIPTION.name)
        }
    }
    pub fn translation_model(&self, variant: TranslationVariant) -> PathBuf {
        self.support.join(variant.asset().name)
    }
    pub fn translation_engine(&self, variant: TranslationVariant) -> Option<PathBuf> {
        let path = self.bundle_executables.join(format!(
            "{}{}",
            variant.engine_name(),
            std::env::consts::EXE_SUFFIX
        ));
        path.exists().then_some(path)
    }
    pub fn translation_available(&self, variant: TranslationVariant) -> bool {
        self.translation_engine(variant).is_some()
            && fast_size_matches(&self.translation_model(variant), variant.asset())
    }
}

/// The shipping fast launch gate follows dev-seed links and checks size only.
/// It is NOT an integrity receipt; migration/install must use full validation.
pub fn fast_size_matches(path: &Path, asset: RemoteAsset) -> bool {
    path.metadata()
        .is_ok_and(|metadata| metadata.len() == asset.size_bytes)
}

/// SHA-256 over one open regular file, with bounded memory. This low-level hash
/// operation follows links like AssetManifest.sha256; installer validation below
/// separately rejects a symlink as the supplied download path.
pub fn sha256(path: &Path) -> io::Result<String> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NONBLOCK);
    }
    let file = options.open(path)?;
    if !file.metadata()?.is_file() {
        return Err(io::Error::other("asset is not a regular file"));
    }
    hash(file)
}

fn hash(mut file: File) -> io::Result<String> {
    let mut hasher = Sha256::new();
    let mut buffer = vec![0; 8 * 1024 * 1024];
    loop {
        let count = file.read(&mut buffer)?;
        if count == 0 {
            break;
        }
        hasher.update(&buffer[..count]);
    }
    Ok(format!("{:x}", hasher.finalize()))
}

/// Full install/reuse verification: no writes, no unlink, no final-component
/// symlink traversal. Size and hash are read from the same opened file.
/// This verifies the bytes read now, not an immutable promise about future paths.
pub fn file_is_valid(path: &Path, expected_size: u64, expected_sha256: &str) -> bool {
    let validate = || -> io::Result<bool> {
        if !std::fs::symlink_metadata(path)?.is_file() {
            return Ok(false);
        }
        let mut options = OpenOptions::new();
        options.read(true);
        #[cfg(unix)]
        {
            use std::os::unix::fs::OpenOptionsExt;
            options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
        }
        #[cfg(windows)]
        {
            use std::os::windows::fs::OpenOptionsExt;
            options.custom_flags(0x00200000); // FILE_FLAG_OPEN_REPARSE_POINT
        }
        let file = options.open(path)?;
        let before = file.metadata()?;
        #[cfg(windows)]
        {
            use std::os::windows::fs::MetadataExt;
            if before.file_attributes() & 0x400 != 0 {
                return Ok(false);
            } // reparse point
        }
        if !before.is_file() || before.len() != expected_size {
            return Ok(false);
        }
        // Hashing a clone shares the opened file identity, rather than reopening
        // a path that could have been replaced after the size check.
        let digest = hash(file.try_clone()?)?;
        let after = file.metadata()?;
        Ok(after.len() == before.len()
            && after.modified()? == before.modified()?
            && digest == expected_sha256)
    };
    validate().unwrap_or(false)
}

#[cfg(test)]
mod tests;
