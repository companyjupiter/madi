//! Persistent projections of SessionController and the root AppStorage values.
//! Restoring a meeting mode must not run its didSet preset a second time.
use crate::setup::{AudioSource, Language, MeetingMode, SetupCommand, SetupState, sorted_targets};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum UILanguage {
    #[default]
    Ko,
    En,
    Ja,
}
#[derive(Clone, Copy, Debug, Default, Deserialize, Serialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum Appearance {
    #[default]
    System,
    Light,
    Dark,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Presentation {
    pub ui_language: UILanguage,
    pub appearance: Appearance,
    pub content_mode: bool,
    pub font_size: f64,
}
impl Default for Presentation {
    fn default() -> Self {
        Self {
            ui_language: UILanguage::Ko,
            appearance: Appearance::System,
            content_mode: true,
            font_size: 16.0,
        }
    }
}
#[derive(Debug, Deserialize, Serialize)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub enum PresentationCommand {
    #[serde(rename = "uiLanguage")]
    UILanguage(UILanguage),
    Appearance(Appearance),
    ContentMode(bool),
    SmallerText,
    LargerText,
}
impl Presentation {
    pub fn apply(&mut self, command: PresentationCommand) {
        match command {
            PresentationCommand::UILanguage(value) => self.ui_language = value,
            PresentationCommand::Appearance(value) => self.appearance = value,
            PresentationCommand::ContentMode(value) => self.content_mode = value,
            PresentationCommand::SmallerText => self.font_size = (self.font_size - 2.0).max(12.0),
            PresentationCommand::LargerText => self.font_size = (self.font_size + 2.0).min(34.0),
        }
    }
}
/// Values after the native UserDefaults getters have applied Foundation's
/// conversions. Absence is distinct from an explicitly stored false/zero.
#[derive(Default, Debug, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct Legacy {
    pub language_token_id: i64,
    pub translate_targets: Vec<String>,
    pub meeting_mode: String,
    pub diarize_enabled: Option<bool>,
    pub fixed_speaker_count: i64,
    pub audio_source: String,
    pub ui_language: String,
    pub appearance: String,
    pub transcript_view_mode: Option<bool>,
    pub transcript_font_size: Option<f64>,
    pub settings: crate::settings::LegacySettings,
}
#[derive(Clone, Debug, Deserialize, Serialize, PartialEq)]
#[serde(rename_all = "camelCase")]
pub struct Preferences {
    pub schema: u32,
    pub language_token_id: Option<i64>,
    pub translate_targets: Vec<String>,
    pub meeting_mode: MeetingMode,
    pub diarize: bool,
    pub speaker_count: u8,
    pub audio_source: AudioSource,
    pub presentation: Presentation,
    #[serde(default)]
    pub settings: crate::settings::Settings,
}
impl Preferences {
    pub fn from_legacy(value: Legacy) -> Self {
        let mut setup = SetupState {
            meeting_mode: match value.meeting_mode.as_str() {
                "oneOnOne" => MeetingMode::OneOnOne,
                "standup" => MeetingMode::Standup,
                "interview" => MeetingMode::Interview,
                "lecture" => MeetingMode::Lecture,
                _ => MeetingMode::General,
            },
            audio_source: match value.audio_source.as_str() {
                "system" => AudioSource::System,
                "both" => AudioSource::Both,
                _ => AudioSource::Mic,
            },
            restored_language_token: (value.language_token_id > 0)
                .then_some(value.language_token_id),
            translate_targets: sorted_targets(value.translate_targets),
            ..SetupState::default()
        };
        setup.restore_speaker_settings(value.fixed_speaker_count, value.diarize_enabled);
        let mut preferences = Self::project(
            &setup,
            Presentation {
                ui_language: match value.ui_language.as_str() {
                    "en" => UILanguage::En,
                    "ja" => UILanguage::Ja,
                    _ => UILanguage::Ko,
                },
                appearance: match value.appearance.as_str() {
                    "light" => Appearance::Light,
                    "dark" => Appearance::Dark,
                    _ => Appearance::System,
                },
                content_mode: value.transcript_view_mode.unwrap_or(true),
                font_size: value.transcript_font_size.unwrap_or(16.0),
            },
        );
        preferences.settings = crate::settings::Settings::from_legacy(value.settings);
        preferences
    }
    pub fn project(setup: &SetupState, presentation: Presentation) -> Self {
        Self {
            schema: 2,
            language_token_id: setup.language_token(),
            translate_targets: setup.translate_targets.clone(),
            meeting_mode: setup.meeting_mode,
            diarize: setup.diarize,
            speaker_count: setup.speaker_count,
            audio_source: setup.audio_source,
            presentation,
            settings: Default::default(),
        }
    }
    /// Swift writes individual keys in property observers. In particular, the
    /// Settings language binding is transient even if another preference saves.
    pub fn apply_setup(
        &mut self,
        setup: &mut SetupState,
        command: SetupCommand,
    ) -> Result<bool, &'static str> {
        setup.apply(command.clone())?;
        match command {
            SetupCommand::InputLanguage(_) => {
                self.language_token_id = setup.language_token();
                self.translate_targets = setup.translate_targets.clone();
            }
            SetupCommand::ToggleTarget(_) | SetupCommand::ClearTargets => {
                self.translate_targets = setup.translate_targets.clone()
            }
            SetupCommand::MeetingMode(_) => {
                self.meeting_mode = setup.meeting_mode;
                self.diarize = setup.diarize;
                self.speaker_count = setup.speaker_count;
            }
            SetupCommand::Diarize(_) => self.diarize = setup.diarize,
            SetupCommand::SpeakerCount(_) => self.speaker_count = setup.speaker_count,
            SetupCommand::AudioSource(_) => self.audio_source = setup.audio_source,
            SetupCommand::InputDevice(_) => {
                self.audio_source = setup.audio_source;
                return Ok(false);
            }
            SetupCommand::ClearStagedFile => return Ok(false),
        }
        Ok(true)
    }
    pub fn validate(&self) -> Result<(), &'static str> {
        if self.schema != 2 {
            return Err("unsupported preferences version");
        }
        if self.language_token_id.is_some_and(|value| value <= 0) {
            return Err("invalid persisted language token");
        }
        if ![0, 2, 3, 4, 5].contains(&self.speaker_count) {
            return Err("invalid persisted speaker count");
        }
        if !self.presentation.font_size.is_finite() {
            return Err("non-finite transcript font size");
        }
        self.settings.validate()
    }
    pub fn setup(&self) -> SetupState {
        let language = self.language_token_id.and_then(Language::from_token);
        SetupState {
            input_language: language,
            restored_language_token: if language.is_none() {
                self.language_token_id
            } else {
                None
            },
            translate_targets: sorted_targets(self.translate_targets.clone()),
            meeting_mode: self.meeting_mode,
            diarize: self.diarize,
            speaker_count: self.speaker_count,
            audio_source: self.audio_source,
            ..SetupState::default()
        }
    }
}
