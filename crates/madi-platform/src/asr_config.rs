//! Typed native file/live ASR launch configuration, derived from EngineProcess.
//! These resources/options are resolved by Rust, not deserialized from WebView IPC.
use crate::engine_process::Launch;
use madi_core::setup::SetupState;
use std::{
    collections::{BTreeMap, BTreeSet},
    ffi::OsString,
    io,
    path::{Path, PathBuf},
};

#[derive(Clone, Debug)]
pub struct Resources {
    pub executable: PathBuf,
    pub model: PathBuf,
    pub bpe: PathBuf,
    pub assets: PathBuf,
}

#[derive(Clone, Debug)]
pub struct FileSettings {
    pub diarize: bool,
    pub osd: bool,
    pub language_token: Option<i64>,
    pub max_speakers: u8,
    pub fixed_speakers: Option<u8>,
    pub vad_probability: Option<f64>,
    pub encoder_f16_cache: bool,
    pub bias_terms: Vec<String>,
}

impl Default for FileSettings {
    fn default() -> Self {
        Self {
            diarize: true,
            osd: true,
            language_token: None,
            max_speakers: 8,
            fixed_speakers: None,
            vad_probability: None,
            encoder_f16_cache: false,
            bias_terms: Vec::new(),
        }
    }
}

impl FileSettings {
    /// SpeakerCount and makeConfig policy from SessionController. Physical
    /// memory and glossary terms come from native services, not UI estimates.
    pub fn from_setup(
        setup: &SetupState,
        physical_memory: u64,
        bias_terms: Vec<String>,
    ) -> Result<Self, &'static str> {
        let (max_speakers, fixed_speakers, vad_probability) = match setup.speaker_count {
            0 => (8, None, 0.5),
            2 => (2, Some(2), 0.65),
            3 => (3, Some(3), 0.8),
            4 => (4, Some(4), 0.8),
            5 => (8, None, 0.8),
            _ => return Err("invalid setup speaker count"),
        };
        Ok(Self {
            diarize: setup.diarize,
            osd: setup.osd,
            language_token: setup.language_token(),
            max_speakers,
            fixed_speakers,
            vad_probability: Some(vad_probability),
            encoder_f16_cache: physical_memory >= 24 * (1 << 30),
            bias_terms,
        })
    }
}

// Clear mode/config keys first. Several engine flags test presence, not "1".
// This avoids a parent shell's STREAM/DIAR_K/PROMPT silently overriding the UI.
// Unrelated inherited environment remains available to the native loader.
const OWNED_KEYS: &[&str] = &[
    "CONF",
    "DIAR",
    "OSD",
    "ENC_F16_CACHE",
    "DIAR_MAXK",
    "DIAR_K",
    "VAD_PROB",
    "WHISPER_LANG_ID",
    "PROMPT",
    "APP_FILE",
    "STREAM",
    "AUDIO_CTX",
    "PARTIALS",
    "LANG_CANDIDATES",
    "DIAR_ANCHOR",
    "STREAM_WAV_ROOTS",
    "VOICEPRINTS",
];

#[derive(Clone, Debug)]
pub struct LiveSettings {
    pub common: FileSettings,
    pub language_candidates: Vec<i64>,
}
impl LiveSettings {
    pub fn from_setup(
        setup: &SetupState,
        physical_memory: u64,
        bias_terms: Vec<String>,
    ) -> Result<Self, &'static str> {
        let mut candidates: BTreeSet<_> = setup
            .translate_targets
            .iter()
            .filter_map(|name| match name.as_str() {
                "English" => Some(50259),
                "Chinese" => Some(50260),
                "Korean" => Some(50264),
                "Japanese" => Some(50266),
                _ => None,
            })
            .collect();
        if let Some(input) = setup.language_token() {
            candidates.insert(input);
        }
        Ok(Self {
            common: FileSettings::from_setup(setup, physical_memory, bias_terms)?,
            language_candidates: if candidates.len() >= 2 {
                candidates.into_iter().collect()
            } else {
                Vec::new()
            },
        })
    }
}

impl FileSettings {
    fn environment(&self) -> Result<BTreeMap<OsString, Option<OsString>>, &'static str> {
        let settings = self;
        if settings.max_speakers == 0
            || settings.max_speakers > 8
            || settings
                .fixed_speakers
                .is_some_and(|n| n == 0 || n > settings.max_speakers)
        {
            return Err("invalid ASR speaker configuration");
        }
        if settings
            .vad_probability
            .is_some_and(|p| !p.is_finite() || !(0.0..=1.0).contains(&p))
        {
            return Err("invalid ASR VAD probability");
        }
        if settings.bias_terms.iter().any(|term| term.contains('\0')) {
            return Err("ASR vocabulary contains a NUL byte");
        }
        let mut environment: BTreeMap<OsString, Option<OsString>> = OWNED_KEYS
            .iter()
            .map(|key| (OsString::from(key), None))
            .collect();
        let mut put = |key: &str, value: String| {
            environment.insert(key.into(), Some(value.into()));
        };
        put("CONF", "1".into());
        put("DIAR", if settings.diarize { "1" } else { "0" }.into());
        put("OSD", if settings.osd { "1" } else { "0" }.into());
        put("DIAR_MAXK", settings.max_speakers.to_string());
        if settings.encoder_f16_cache {
            put("ENC_F16_CACHE", "1".into());
        }
        if let Some(count) = settings.fixed_speakers {
            put("DIAR_K", count.to_string());
        }
        if let Some(probability) = settings.vad_probability {
            put("VAD_PROB", format!("{probability:.2}"));
        }
        if let Some(language) = settings.language_token {
            put("WHISPER_LANG_ID", language.to_string());
        }
        if !settings.bias_terms.is_empty() {
            put("PROMPT", settings.bias_terms.join(" "));
        }
        Ok(environment)
    }
}

impl Resources {
    /// `wav` must be retained by an owned PreparedAudio guard for the entire
    /// engine lifetime. A session executor must enforce this ownership boundary.
    pub fn file_launch(&self, wav: &Path, settings: &FileSettings) -> Result<Launch, &'static str> {
        let mut environment = settings.environment()?;
        environment.insert("APP_FILE".into(), Some("1".into()));
        Ok(Launch {
            executable: self.executable.clone(),
            working_directory: self.assets.clone(),
            arguments: vec![
                self.model.as_os_str().to_owned(),
                wav.as_os_str().to_owned(),
                self.bpe.as_os_str().to_owned(),
            ],
            environment,
        })
    }

    /// The live owner retains its CapturePipeline/OwnedWav directory through
    /// engine teardown. This is native configuration, never a renderer path.
    pub fn live_launch(
        &self,
        stream_directory: &Path,
        settings: &LiveSettings,
    ) -> io::Result<Launch> {
        let root = stream_directory.canonicalize()?;
        if !root.is_dir() {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "stream WAV root is not a directory",
            ));
        }
        let path = root.to_str().ok_or_else(|| {
            io::Error::new(io::ErrorKind::InvalidInput, "stream WAV root is not UTF-8")
        })?;
        // Zig parses a platform-delimited path list and one-line stdin jobs.
        let separator = if cfg!(windows) { ';' } else { ':' };
        if path.contains(['\n', '\r', '\0', separator]) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "stream WAV root cannot be represented by the engine protocol",
            ));
        }
        let mut environment = settings.common.environment().map_err(io::Error::other)?;
        for (key, value) in [
            ("STREAM", "1"),
            ("AUDIO_CTX", "auto"),
            ("PARTIALS", "1"),
            ("STREAM_WAV_ROOTS", path),
        ] {
            environment.insert(key.into(), Some(value.into()));
        }
        if settings.language_candidates.len() >= 2 {
            environment.insert(
                "LANG_CANDIDATES".into(),
                Some(
                    settings
                        .language_candidates
                        .iter()
                        .map(ToString::to_string)
                        .collect::<Vec<_>>()
                        .join(",")
                        .into(),
                ),
            );
        }
        // SessionController.voiceprintsEnabled is false. Both VOICEPRINTS and
        // DIAR_ANCHOR remain removed even if the parent shell provided them.
        Ok(Launch {
            executable: self.executable.clone(),
            working_directory: self.assets.clone(),
            // STREAM ignores the file operand; preserve the shipping placeholder.
            arguments: vec![
                self.model.as_os_str().to_owned(),
                "/dev/null".into(),
                self.bpe.as_os_str().to_owned(),
            ],
            environment,
        })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn live_mode_uses_current_owned_root_and_clears_file_and_voiceprint_flags() {
        let scratch = tempfile::tempdir().unwrap();
        let resources = Resources {
            executable: "engine".into(),
            model: "model".into(),
            bpe: "bpe".into(),
            assets: "assets".into(),
        };
        let settings = LiveSettings::from_setup(
            &SetupState {
                input_language: Some(madi_core::setup::Language::English),
                translate_targets: vec!["Korean".into(), "Japanese".into(), "Korean".into()],
                ..SetupState::default()
            },
            24 << 30,
            vec!["마디".into()],
        )
        .unwrap();
        let launch = resources.live_launch(scratch.path(), &settings).unwrap();
        for key in ["APP_FILE", "VOICEPRINTS", "DIAR_ANCHOR"] {
            assert_eq!(
                launch.environment.get(std::ffi::OsStr::new(key)),
                Some(&None)
            );
        }
        assert_eq!(
            launch
                .environment
                .get(std::ffi::OsStr::new("LANG_CANDIDATES")),
            Some(&Some("50259,50264,50266".into()))
        );
        assert_eq!(
            launch
                .environment
                .get(std::ffi::OsStr::new("STREAM_WAV_ROOTS")),
            Some(&Some(
                scratch.path().canonicalize().unwrap().into_os_string()
            ))
        );
        let bad = scratch.path().join(if cfg!(windows) {
            "bad;root"
        } else {
            "bad:root"
        });
        std::fs::create_dir(&bad).unwrap();
        assert_eq!(
            resources.live_launch(&bad, &settings).err().unwrap().kind(),
            io::ErrorKind::InvalidInput
        );
    }
    #[test]
    fn file_mode_removes_all_unset_mode_keys_and_rejects_invalid_options() {
        let resources = Resources {
            executable: "/engine".into(),
            model: "/model".into(),
            bpe: "/bpe".into(),
            assets: "/assets".into(),
        };
        let settings = FileSettings::default();
        let launch = resources
            .file_launch(Path::new("/owned/input.wav"), &settings)
            .unwrap();
        for key in [
            "STREAM",
            "PARTIALS",
            "DIAR_K",
            "WHISPER_LANG_ID",
            "PROMPT",
            "ENC_F16_CACHE",
            "VOICEPRINTS",
        ] {
            assert_eq!(
                launch.environment.get(std::ffi::OsStr::new(key)),
                Some(&None)
            );
        }
        for probability in [f64::NAN, f64::INFINITY, -0.01, 1.01] {
            assert!(
                resources
                    .file_launch(
                        Path::new("/owned/input.wav"),
                        &FileSettings {
                            vad_probability: Some(probability),
                            ..settings.clone()
                        }
                    )
                    .is_err()
            );
        }
        assert!(
            resources
                .file_launch(
                    Path::new("/owned/input.wav"),
                    &FileSettings {
                        fixed_speakers: Some(9),
                        ..settings.clone()
                    }
                )
                .is_err()
        );
        assert!(
            resources
                .file_launch(
                    Path::new("/owned/input.wav"),
                    &FileSettings {
                        bias_terms: vec!["bad\0term".into()],
                        ..settings
                    }
                )
                .is_err()
        );
    }
}
