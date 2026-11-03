//! Typed native file-mode ASR launch configuration, derived from EngineProcess.
//! These resources/options are resolved by Rust, not deserialized from WebView IPC.
use crate::engine_process::Launch;
use madi_core::setup::{Language, SetupState};
use std::{
    collections::BTreeMap,
    ffi::OsString,
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
    pub language_token: Option<u32>,
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
        osd: bool,
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
            osd,
            language_token: setup.input_language.map(|language| match language {
                Language::English => 50259,
                Language::Chinese => 50260,
                Language::Korean => 50264,
                Language::Japanese => 50266,
            }),
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

impl Resources {
    /// `wav` must be retained by an owned PreparedAudio guard for the entire
    /// engine lifetime. A session executor must enforce this ownership boundary.
    pub fn file_launch(&self, wav: &Path, settings: &FileSettings) -> Result<Launch, &'static str> {
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
        put("APP_FILE", "1".into());
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
}

#[cfg(test)]
mod tests {
    use super::*;
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
