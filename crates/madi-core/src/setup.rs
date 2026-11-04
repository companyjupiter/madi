//! Start-screen selection rules from ContentView and SessionController.
//! Native preference storage and capture admission live in the platform layer.
use serde::{Deserialize, Serialize};
use std::collections::BTreeMap;
use unicode_normalization::UnicodeNormalization;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, PartialOrd, Ord)]
pub enum Language {
    Chinese,
    English,
    Japanese,
    Korean,
}

impl Language {
    pub fn name(self) -> &'static str {
        match self {
            Self::Chinese => "Chinese",
            Self::English => "English",
            Self::Japanese => "Japanese",
            Self::Korean => "Korean",
        }
    }
    pub fn token(self) -> i64 {
        match self {
            Self::Chinese => 50260,
            Self::English => 50259,
            Self::Japanese => 50266,
            Self::Korean => 50264,
        }
    }
    pub fn from_token(token: i64) -> Option<Self> {
        match token {
            50260 => Some(Self::Chinese),
            50259 => Some(Self::English),
            50266 => Some(Self::Japanese),
            50264 => Some(Self::Korean),
            _ => None,
        }
    }
}
/// Swift Set<String> keeps the first spelling of canonically equal strings;
/// its sorted projection is the start screen's collapsed output label order.
pub fn sorted_targets(values: impl IntoIterator<Item = String>) -> Vec<String> {
    let mut unique = BTreeMap::new();
    for value in values {
        unique
            .entry(value.nfc().collect::<String>())
            .or_insert(value);
    }
    unique.into_values().collect()
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum MeetingMode {
    #[default]
    General,
    OneOnOne,
    Standup,
    Interview,
    Lecture,
}

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum AudioSource {
    #[default]
    Mic,
    System,
    Both,
}

/// Display metadata only; the selected filesystem path stays in the native host.
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct StagedFile {
    pub name: String,
    pub size_label: String,
}

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SetupState {
    pub revision: u64,
    pub input_language: Option<Language>,
    /// Preserve a positive legacy token that the four-choice UI cannot label.
    /// It stays native-owned and is cleared by an explicit language selection.
    #[serde(skip)]
    pub restored_language_token: Option<i64>,
    pub translate_targets: Vec<String>,
    pub meeting_mode: MeetingMode,
    pub diarize: bool,
    /// Existing persistence values: 0 (auto), 2, 3, 4, 5 (five or more).
    pub speaker_count: u8,
    pub audio_source: AudioSource,
    /// Transient native adapter identity; None follows the system default.
    /// Not persisted: Core Audio IDs can change when a device reconnects.
    pub input_device_id: Option<String>,
    pub staged_file: Option<StagedFile>,
}

impl Default for SetupState {
    fn default() -> Self {
        Self {
            revision: 0,
            input_language: None,
            restored_language_token: None,
            translate_targets: Vec::new(),
            meeting_mode: MeetingMode::General,
            diarize: true,
            speaker_count: 0,
            audio_source: AudioSource::Mic,
            input_device_id: None,
            staged_file: None,
        }
    }
}

#[derive(Debug, Deserialize, Serialize)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub enum SetupCommand {
    InputLanguage(Option<Language>),
    ToggleTarget(Language),
    ClearTargets,
    MeetingMode(MeetingMode),
    Diarize(bool),
    SpeakerCount(u8),
    AudioSource(AudioSource),
    InputDevice(Option<String>),
    ClearStagedFile,
}

impl SetupState {
    pub fn apply(&mut self, command: SetupCommand) -> Result<(), &'static str> {
        match command {
            SetupCommand::ClearStagedFile => self.staged_file = None,
            SetupCommand::InputLanguage(language) => {
                self.input_language = language;
                self.restored_language_token = None;
                if let Some(language) = language {
                    self.translate_targets
                        .retain(|value| value != language.name());
                }
            }
            SetupCommand::ToggleTarget(language) => {
                if self.input_language == Some(language) {
                    return Err("input language cannot also be an output target");
                }
                if let Some(index) = self
                    .translate_targets
                    .iter()
                    .position(|value| value == language.name())
                {
                    self.translate_targets.remove(index);
                } else if self.translate_targets.len() < 3 {
                    self.translate_targets.push(language.name().into());
                    self.translate_targets =
                        sorted_targets(std::mem::take(&mut self.translate_targets));
                }
            }
            SetupCommand::ClearTargets => self.translate_targets.clear(),
            SetupCommand::MeetingMode(mode) => {
                self.meeting_mode = mode;
                self.diarize = mode != MeetingMode::Lecture;
                self.speaker_count = match mode {
                    MeetingMode::OneOnOne | MeetingMode::Interview => 2,
                    _ => 0,
                };
            }
            SetupCommand::Diarize(value) => self.diarize = value,
            SetupCommand::SpeakerCount(count) => {
                if ![0, 2, 3, 4, 5].contains(&count) {
                    return Err("invalid speaker count");
                }
                self.speaker_count = count;
            }
            SetupCommand::AudioSource(source) => self.audio_source = source,
            SetupCommand::InputDevice(id) => {
                self.input_device_id = id;
                // Selecting a mic exits system-only, but keeps mixed capture.
                if self.audio_source == AudioSource::System {
                    self.audio_source = AudioSource::Mic;
                }
            }
        }
        self.revision += 1;
        Ok(())
    }

    pub fn language_token(&self) -> Option<i64> {
        self.input_language
            .map(Language::token)
            .or(self.restored_language_token)
    }

    /// The removed 1-speaker option migrated to separation off, unless the
    /// newer diarizeEnabled setting was explicitly saved (Swift init contract).
    pub fn restore_speaker_settings(&mut self, count: i64, diarize: Option<bool>) {
        self.diarize = diarize.unwrap_or(count != 1);
        self.speaker_count = match count {
            2..=5 => count as u8,
            _ => 0,
        };
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mic_selection_exits_system_only_but_preserves_mixed_capture() {
        let mut state = SetupState::default();
        state
            .apply(SetupCommand::AudioSource(AudioSource::System))
            .unwrap();
        state
            .apply(SetupCommand::InputDevice(Some("coreaudio:83".into())))
            .unwrap();
        assert_eq!(state.audio_source, AudioSource::Mic);
        assert_eq!(state.input_device_id.as_deref(), Some("coreaudio:83"));
        state
            .apply(SetupCommand::AudioSource(AudioSource::Both))
            .unwrap();
        state.apply(SetupCommand::InputDevice(None)).unwrap();
        assert_eq!(state.audio_source, AudioSource::Both);
        assert_eq!(state.input_device_id, None);
        state
            .apply(SetupCommand::AudioSource(AudioSource::System))
            .unwrap();
        state.apply(SetupCommand::InputDevice(None)).unwrap();
        assert_eq!(state.audio_source, AudioSource::Mic);
    }

    #[test]
    fn language_change_removes_self_translation_and_cap_is_three() {
        let mut state = SetupState::default();
        for language in [
            Language::English,
            Language::Japanese,
            Language::Korean,
            Language::Chinese,
        ] {
            state.apply(SetupCommand::ToggleTarget(language)).unwrap();
        }
        assert_eq!(state.translate_targets.len(), 3);
        assert!(!state.translate_targets.contains(&"Chinese".to_owned()));
        state
            .apply(SetupCommand::InputLanguage(Some(Language::Korean)))
            .unwrap();
        assert!(!state.translate_targets.contains(&"Korean".to_owned()));
        let snapshot = state.clone();
        assert!(
            state
                .apply(SetupCommand::ToggleTarget(Language::Korean))
                .is_err()
        );
        assert_eq!(state, snapshot);
        state
            .apply(SetupCommand::ToggleTarget(Language::English))
            .unwrap();
        assert_eq!(state.translate_targets, vec!["Japanese".to_owned()]);
    }

    #[test]
    fn presets_are_defaults_and_users_can_override_them() {
        let mut state = SetupState::default();
        state
            .apply(SetupCommand::MeetingMode(MeetingMode::Interview))
            .unwrap();
        assert!(state.diarize);
        assert_eq!(state.speaker_count, 2);
        state
            .apply(SetupCommand::MeetingMode(MeetingMode::Lecture))
            .unwrap();
        assert!(!state.diarize);
        assert_eq!(state.speaker_count, 0);
        state.apply(SetupCommand::Diarize(true)).unwrap();
        state.apply(SetupCommand::SpeakerCount(4)).unwrap();
        assert_eq!(state.meeting_mode, MeetingMode::Lecture);
        assert_eq!(state.speaker_count, 4);
        let snapshot = state.clone();
        assert!(state.apply(SetupCommand::SpeakerCount(1)).is_err());
        assert_eq!(state, snapshot);
    }

    #[test]
    fn removed_one_speaker_setting_migrates_without_overwriting_explicit_toggle() {
        let mut state = SetupState::default();
        state.restore_speaker_settings(1, None);
        assert!(!state.diarize);
        assert_eq!(state.speaker_count, 0);
        state.restore_speaker_settings(1, Some(true));
        assert!(state.diarize);
        state.restore_speaker_settings(99, None);
        assert_eq!(state.speaker_count, 0);
    }
}
