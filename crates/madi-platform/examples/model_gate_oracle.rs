use madi_core::{
    assets::TranslationVariant,
    model_setup::{ModelDownloadState, ModelSetupChoice, ModelSetupState},
};
use serde::Deserialize;
use std::io::Read;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Case {
    required: String,
    translation: String,
    choice: Option<ModelSetupChoice>,
    engine: bool,
}
fn state(value: &str) -> ModelDownloadState {
    match value {
        "idle" => ModelDownloadState::Idle,
        "checking" => ModelDownloadState::Checking,
        "downloading" => ModelDownloadState::Downloading(0.35),
        "verifying" => ModelDownloadState::Verifying,
        "ready" => ModelDownloadState::Ready,
        "cancelled" => ModelDownloadState::Cancelled,
        "failed" => ModelDownloadState::Failed("fixture".into()),
        _ => panic!("unknown state"),
    }
}
fn main() {
    let mut payload = String::new();
    std::io::stdin().read_to_string(&mut payload).unwrap();
    let cases: Vec<Case> = serde_json::from_str(&payload).unwrap();
    let results: Vec<_> = cases.into_iter().map(|c| {
        let s = ModelSetupState { revision: 0, required: state(&c.required), translation: state(&c.translation), choice: c.choice, variant: TranslationVariant::Quality4B, physical_memory: 48 << 30, translation_engine_available: c.engine };
        serde_json::json!({"isDownloading":s.is_downloading(), "hasRetryableDownload":s.has_retryable_download(), "canContinueTranscription":s.can_continue_transcription()})
    }).collect();
    println!("{}", serde_json::to_string(&results).unwrap());
}
