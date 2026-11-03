//! First-launch policy from FirstRunModelSetupPolicy.swift. No network or storage.
use crate::assets::{TRANSCRIPTION, TranslationVariant};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ModelSetupChoice {
    TranscriptionOnly,
    Recommended,
}

#[derive(Clone, Copy, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelReadiness {
    pub required_model_ready: bool,
    pub translation_model_ready: bool,
    pub translation_engine_available: bool,
}

impl ModelReadiness {
    /// Existing installs have no choice and enter immediately with Whisper.
    /// Explicit recommended setup waits for DNA only when its engine exists.
    pub fn can_enter_app(self, choice: Option<ModelSetupChoice>) -> bool {
        self.required_model_ready
            && (choice != Some(ModelSetupChoice::Recommended)
                || !self.translation_engine_available
                || self.translation_model_ready)
    }

    /// Count only assets missing from this installation. Engine availability is
    /// deliberately not part of the total; the UI hides the recommended action
    /// when no engine is available, matching the original policy/view boundary.
    pub fn download_bytes(self, choice: ModelSetupChoice, variant: TranslationVariant) -> u64 {
        let required = if self.required_model_ready {
            0
        } else {
            TRANSCRIPTION.size_bytes
        };
        let optional = if choice == ModelSetupChoice::Recommended && !self.translation_model_ready {
            variant.asset().size_bytes
        } else {
            0
        };
        required + optional
    }
}
