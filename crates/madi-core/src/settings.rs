//! SettingsView's session controls, distinct from the start-screen pickers.
use crate::setup::{Language, SetupState, sorted_targets};
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct CaptionSettings {
    pub staff_font_size: f64,
    pub patient_font_size: f64,
    pub panel_width: f64,
    pub min_scale_factor: f64,
    pub patient_panel_enabled: bool,
    pub patient_screen_index: Option<i64>,
    pub patient_lang_override: Option<String>,
}
impl Default for CaptionSettings {
    fn default() -> Self {
        Self {
            staff_font_size: 26.0,
            patient_font_size: 46.0,
            panel_width: 760.0,
            min_scale_factor: 0.9,
            patient_panel_enabled: false,
            patient_screen_index: None,
            patient_lang_override: None,
        }
    }
}
impl CaptionSettings {
    fn clamp(&mut self) {
        self.staff_font_size = self.staff_font_size.clamp(14.0, 48.0);
        self.patient_font_size = self.patient_font_size.clamp(24.0, 96.0);
        self.panel_width = self.panel_width.clamp(480.0, 1400.0);
        self.min_scale_factor = self.min_scale_factor.clamp(0.5, 1.0);
    }
    fn finite(&self) -> bool {
        [
            self.staff_font_size,
            self.patient_font_size,
            self.panel_width,
            self.min_scale_factor,
        ]
        .iter()
        .all(|value| value.is_finite())
    }
}
#[derive(Default, Debug, Deserialize, Serialize)]
#[serde(default, rename_all = "camelCase")]
pub struct LegacySettings {
    pub live_window_seconds: Option<f64>,
    pub translate_tail_seconds: Option<f64>,
    pub live_preview_enabled: Option<bool>,
    pub ai_reconcile_enabled: Option<bool>,
    pub debug_capture: Option<bool>,
    pub vad_conf_threshold: Option<f64>,
    pub caption: Option<CaptionSettings>,
}
#[derive(Clone, Debug, PartialEq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Settings {
    pub live_window_seconds: f64,
    pub translate_tail_seconds: f64,
    pub live_preview_enabled: bool,
    pub ai_reconcile_enabled: bool,
    pub debug_capture: bool,
    pub vad_conf_threshold: f64,
    pub caption: CaptionSettings,
}
impl Default for Settings {
    fn default() -> Self {
        Self::from_legacy(LegacySettings::default())
    }
}
impl Settings {
    pub fn from_legacy(value: LegacySettings) -> Self {
        Self {
            live_window_seconds: value.live_window_seconds.unwrap_or(10.0),
            translate_tail_seconds: value.translate_tail_seconds.unwrap_or(3.0),
            live_preview_enabled: value.live_preview_enabled.unwrap_or(true),
            ai_reconcile_enabled: value.ai_reconcile_enabled.unwrap_or(false),
            debug_capture: value.debug_capture.unwrap_or(false),
            vad_conf_threshold: value.vad_conf_threshold.unwrap_or(0.55),
            caption: value.caption.unwrap_or_default(),
        }
    }
    pub fn validate(&self) -> Result<(), &'static str> {
        if [
            self.live_window_seconds,
            self.translate_tail_seconds,
            self.vad_conf_threshold,
        ]
        .iter()
        .all(|value| value.is_finite())
            && self.caption.finite()
        {
            Ok(())
        } else {
            Err("non-finite session setting")
        }
    }
    pub fn multi_translate_forces_accurate(&self, setup: &SetupState) -> bool {
        setup.translate_targets.len() >= 2
            && !(setup.translate_targets.len() == 2
                && setup
                    .translate_targets
                    .iter()
                    .any(|value| value == "Korean"))
    }
    pub fn effective_window_seconds(&self, setup: &SetupState) -> f64 {
        if self.multi_translate_forces_accurate(setup) {
            self.live_window_seconds.max(7.0)
        } else {
            self.live_window_seconds
        }
    }
    /// Returns whether the action changes durable settings. The caller commits
    /// only the relevant keys; runtime-only language/OSD never leak into saves.
    pub fn apply(
        &mut self,
        setup: &mut SetupState,
        command: &SettingsCommand,
    ) -> Result<bool, &'static str> {
        let persistent = match command {
            SettingsCommand::InputLanguage(language) => {
                if language
                    .is_some_and(|value| !matches!(value, Language::English | Language::Korean))
                {
                    return Err("unsupported settings language choice");
                }
                setup.input_language = *language;
                setup.restored_language_token = None;
                false
            }
            SettingsCommand::InputDevice(id) => {
                setup.input_device_id = id.clone();
                false
            }
            SettingsCommand::OverlappingSpeech(value) => {
                setup.osd = *value;
                false
            }
            SettingsCommand::TranslationTarget { language, enabled } => {
                if *enabled {
                    setup.translate_targets.push(language.name().into());
                    setup.translate_targets =
                        sorted_targets(std::mem::take(&mut setup.translate_targets));
                } else {
                    setup
                        .translate_targets
                        .retain(|value| value != language.name());
                }
                true
            }
            SettingsCommand::LiveWindowSeconds(value) => {
                if ![5.0, 7.0, 10.0].contains(value) {
                    return Err("invalid response speed");
                }
                self.live_window_seconds = *value;
                true
            }
            SettingsCommand::TranslateTailSeconds(value) => {
                if !(0.5..=5.0).contains(value) {
                    return Err("invalid translation tail delay");
                }
                self.translate_tail_seconds = *value;
                true
            }
            SettingsCommand::LivePreview(value) => {
                self.live_preview_enabled = *value;
                true
            }
            SettingsCommand::AIReconcile(value) => {
                self.ai_reconcile_enabled = *value;
                true
            }
            SettingsCommand::DebugCapture(value) => {
                self.debug_capture = *value;
                true
            }
            SettingsCommand::VADThreshold(value) => {
                if !(0.35..=0.9).contains(value) {
                    return Err("invalid review threshold");
                }
                self.vad_conf_threshold = *value;
                true
            }
            SettingsCommand::StaffFontSize(value) => {
                if !value.is_finite() {
                    return Err("invalid caption size");
                }
                self.caption.staff_font_size = *value;
                self.caption.clamp();
                true
            }
            SettingsCommand::PatientFontSize(value) => {
                if !value.is_finite() {
                    return Err("invalid caption size");
                }
                self.caption.patient_font_size = *value;
                self.caption.clamp();
                true
            }
            SettingsCommand::PatientPanel(value) => {
                self.caption.patient_panel_enabled = *value;
                self.caption.clamp();
                true
            }
            SettingsCommand::PatientScreen(value) => {
                self.caption.patient_screen_index = *value;
                true
            }
            SettingsCommand::PatientLanguage(value) => {
                self.caption.patient_lang_override = value.clone();
                true
            }
        };
        setup.revision += 1;
        Ok(persistent)
    }
}
#[derive(Debug, Deserialize, Serialize)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub enum SettingsCommand {
    InputLanguage(Option<Language>),
    InputDevice(Option<String>),
    OverlappingSpeech(bool),
    TranslationTarget {
        language: Language,
        enabled: bool,
    },
    LiveWindowSeconds(f64),
    TranslateTailSeconds(f64),
    LivePreview(bool),
    #[serde(rename = "aiReconcile")]
    AIReconcile(bool),
    DebugCapture(bool),
    #[serde(rename = "vadThreshold")]
    VADThreshold(f64),
    StaffFontSize(f64),
    PatientFontSize(f64),
    PatientPanel(bool),
    PatientScreen(Option<i64>),
    PatientLanguage(Option<String>),
}
