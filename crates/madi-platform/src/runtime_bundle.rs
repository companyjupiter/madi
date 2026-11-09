//! The installed macOS inference layout. No checkout or PATH fallback.
use serde::Serialize;
use std::{io, os::unix::fs::PermissionsExt, path::PathBuf};

pub const ASSET_NAMES: [&str; 7] = [
    "WHISPER_BPE.bin",
    "mel_filters.bin",
    "resnet34_diar.bin",
    "kaldi_melbank.bin",
    "silero_vad.bin",
    "pyannote_osd.bin",
    "suppress_tokens.bin",
];

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeBundle {
    pub decoder: PathBuf,
    pub transcribe: PathBuf,
    pub translate_2b: PathBuf,
    pub translate_4b: PathBuf,
    pub assets_directory: PathBuf,
}

/// Resolve only regular, nonempty files within the installed bundle. This is a
/// layout check, not a replacement for package signatures/hash verification.
pub fn bundled() -> io::Result<RuntimeBundle> {
    let executable = std::env::current_exe()?.canonicalize()?;
    let binaries = executable
        .parent()
        .ok_or_else(|| io::Error::other("host has no executable directory"))?;
    let contents = binaries
        .parent()
        .ok_or_else(|| io::Error::other("host has no bundle contents"))?;
    if binaries.file_name().is_none_or(|name| name != "MacOS")
        || contents.file_name().is_none_or(|name| name != "Contents")
    {
        return Err(io::Error::other(
            "host is not inside a macOS application bundle",
        ));
    }
    let resources = contents.join("Resources");
    let assets = resources.join("assets-small");
    if resources.canonicalize()? != resources || assets.canonicalize()? != assets {
        return Err(io::Error::other(
            "runtime resources escape the bundle layout",
        ));
    }
    let checked = |path: PathBuf, executable: bool| -> io::Result<PathBuf> {
        let metadata = std::fs::symlink_metadata(&path)?;
        if !metadata.is_file()
            || metadata.len() == 0
            || path.canonicalize()? != path
            || (executable && metadata.permissions().mode() & 0o111 == 0)
        {
            return Err(io::Error::other(format!(
                "invalid bundled runtime file: {}",
                path.display()
            )));
        }
        Ok(path)
    };
    for name in ASSET_NAMES {
        checked(assets.join(name), false)?;
    }
    Ok(RuntimeBundle {
        decoder: checked(binaries.join("madi-audio-decode"), true)?,
        transcribe: checked(binaries.join("transcribe"), true)?,
        translate_2b: checked(binaries.join("translate-engine-2b"), true)?,
        translate_4b: checked(binaries.join("translate-engine-4b"), true)?,
        assets_directory: assets,
    })
}
