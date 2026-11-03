//! Start-screen selection rules from ContentView and SessionController.
//! Persistence and capture admission are separate migration steps.
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

#[derive(Clone, Copy, Debug, Deserialize, Serialize, PartialEq, Eq, PartialOrd, Ord)]
pub enum Language {
    Chinese,
    English,
    Japanese,
    Korean,
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

#[derive(Clone, Debug, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct SetupState {
    pub revision: u64,
    pub input_language: Option<Language>,
    pub translate_targets: BTreeSet<Language>,
    pub meeting_mode: MeetingMode,
    pub diarize: bool,
    /// Existing persistence values: 0 (auto), 2, 3, 4, 5 (five or more).
    pub speaker_count: u8,
    pub audio_source: AudioSource,
}

impl Default for SetupState {
    fn default() -> Self {
        Self {
            revision: 0,
            input_language: None,
            translate_targets: BTreeSet::new(),
            meeting_mode: MeetingMode::General,
            diarize: true,
            speaker_count: 0,
            audio_source: AudioSource::Mic,
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
}

impl SetupState {
    pub fn apply(&mut self, command: SetupCommand) -> Result<(), &'static str> {
        match command {
            SetupCommand::InputLanguage(language) => {
                self.input_language = language;
                if let Some(language) = language {
                    self.translate_targets.remove(&language);
                }
            }
            SetupCommand::ToggleTarget(language) => {
                if self.input_language == Some(language) {
                    return Err("input language cannot also be an output target");
                }
                if !self.translate_targets.remove(&language) && self.translate_targets.len() < 3 {
                    self.translate_targets.insert(language);
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
        }
        self.revision += 1;
        Ok(())
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
        assert!(!state.translate_targets.contains(&Language::Chinese));
        state
            .apply(SetupCommand::InputLanguage(Some(Language::Korean)))
            .unwrap();
        assert!(!state.translate_targets.contains(&Language::Korean));
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
        assert_eq!(
            state.translate_targets,
            BTreeSet::from([Language::Japanese])
        );
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
