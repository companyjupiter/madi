//! Native adapters. Unsupported platforms are explicit, never simulated.
pub mod asr_config;
pub mod audio_devices;
pub mod engine_process;
pub mod file_session;
pub mod file_workflow;
pub mod media_file;
pub mod model_assets;
pub mod model_download;
#[cfg(target_os = "macos")]
pub mod model_presentation;
pub mod model_setup_service;
pub mod prepared_audio;
#[cfg(target_os = "macos")]
pub mod runtime_bundle;
pub mod transcript_native;
