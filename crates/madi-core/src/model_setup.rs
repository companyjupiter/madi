//! First-launch policy from FirstRunModelSetupPolicy.swift. No network or storage.
use crate::assets::{TRANSCRIPTION, TranslationVariant};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum ModelSetupChoice {
    TranscriptionOnly,
    Recommended,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
#[serde(tag = "state", content = "value", rename_all = "camelCase")]
pub enum ModelDownloadState {
    Idle,
    Checking,
    Downloading(f64),
    Verifying,
    Ready,
    Cancelled,
    Failed(String),
}

impl ModelDownloadState {
    pub fn is_downloading(&self) -> bool {
        matches!(self, Self::Downloading(_))
    }
    pub fn can_retry(&self) -> bool {
        matches!(self, Self::Idle | Self::Cancelled | Self::Failed(_))
    }
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ModelSetupState {
    pub revision: u64,
    pub required: ModelDownloadState,
    pub translation: ModelDownloadState,
    pub choice: Option<ModelSetupChoice>,
    pub variant: TranslationVariant,
    pub physical_memory: u64,
    pub translation_engine_available: bool,
}

impl ModelSetupState {
    pub fn readiness(&self) -> ModelReadiness {
        ModelReadiness {
            required_model_ready: self.required == ModelDownloadState::Ready,
            translation_model_ready: self.translation == ModelDownloadState::Ready,
            translation_engine_available: self.translation_engine_available,
        }
    }
    pub fn can_enter_app(&self) -> bool {
        self.readiness().can_enter_app(self.choice)
    }
    pub fn can_continue_transcription(&self) -> bool {
        self.choice == Some(ModelSetupChoice::Recommended)
            && self.required == ModelDownloadState::Ready
            && self.translation != ModelDownloadState::Ready
    }
    pub fn has_retryable_download(&self) -> bool {
        if self.required.can_retry() {
            return self.choice.is_some();
        }
        self.choice == Some(ModelSetupChoice::Recommended)
            && matches!(
                self.translation,
                ModelDownloadState::Idle | ModelDownloadState::Failed(_)
            )
    }
    pub fn is_downloading(&self) -> bool {
        self.required.is_downloading() || self.translation.is_downloading()
    }
}

#[derive(Clone, Copy, Debug, Deserialize)]
#[serde(tag = "type", content = "value", rename_all = "camelCase")]
pub enum ModelSetupCommand {
    Start(ModelSetupChoice),
    Retry,
    Cancel,
    ContinueTranscription,
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
