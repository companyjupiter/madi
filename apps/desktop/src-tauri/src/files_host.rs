use crate::setup_host::SetupHost;
use madi_core::setup::SetupState;
use madi_platform::file_workflow::{Edit, FileWorkflow, LiveControl, Snapshot};
use std::sync::{
    Mutex,
    atomic::{AtomicBool, Ordering},
};
#[cfg(target_os = "macos")]
use tauri::Emitter;
use tauri::Manager;

#[derive(Default)]
pub struct FilesHost {
    service: Mutex<Option<FileWorkflow>>,
    closed: AtomicBool,
    dialog_open: AtomicBool,
    #[cfg(target_os = "macos")]
    artwork: std::sync::OnceLock<serde_json::Value>,
}

#[tauri::command]
pub async fn file_artwork(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
) -> Result<serde_json::Value, String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    #[cfg(target_os = "macos")]
    {
        if let Some(artwork) = app.state::<FilesHost>().artwork.get() {
            return Ok(artwork.clone());
        }
        let (sender, mut receiver) = tauri::async_runtime::channel(1);
        let owner = app.clone();
        app.run_on_main_thread(move || {
            let host = owner.state::<FilesHost>();
            let result = (|| {
                if let Some(artwork) = host.artwork.get() {
                    return Ok(artwork.clone());
                }
                let symbols = madi_platform::model_presentation::transcript_artwork()?;
                let value = serde_json::to_value(symbols).map_err(|error| error.to_string())?;
                let _ = host.artwork.set(value.clone());
                Ok(value)
            })();
            let _ = sender.try_send(result);
        })
        .map_err(|error| error.to_string())?;
        receiver.recv().await.ok_or("artwork worker stopped")?
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = app;
        Ok(serde_json::Value::Null)
    }
}

#[tauri::command]
pub async fn file_copy_line(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    generation: u64,
    id: String,
) -> Result<(), String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    let snapshot = app.state::<FilesHost>().snapshot();
    if snapshot.generation != generation {
        return Ok(());
    }
    let line = snapshot
        .lines
        .iter()
        .find(|line| line.line.id.to_string() == id)
        .ok_or("transcript line no longer exists")?;
    let mut parts = vec![line.text.clone()];
    parts.extend(line.line.translations.values().cloned()); // BTreeMap uses sorted language keys.
    let text = parts.join("\n");
    let (sender, mut receiver) = tauri::async_runtime::channel(1);
    app.run_on_main_thread(move || {
        let _ =
            sender.try_send(madi_platform::transcript_native::copy(&text).map_err(str::to_owned));
    })
    .map_err(|error| error.to_string())?;
    receiver
        .recv()
        .await
        .ok_or("clipboard closed without a result")?
}

#[tauri::command]
pub async fn file_rename_speaker(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    generation: u64,
    speaker: i64,
    labels: madi_platform::transcript_native::RenameLabels,
) -> Result<Snapshot, String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    let host = app.state::<FilesHost>();
    let snapshot = host.snapshot();
    if snapshot.generation != generation
        || speaker == 255
        || !snapshot
            .lines
            .iter()
            .any(|line| line.line.speaker == speaker)
        || host.dialog_open.swap(true, Ordering::AcqRel)
    {
        return Ok(snapshot);
    }
    let current = snapshot
        .speaker_names
        .get(&speaker)
        .cloned()
        .unwrap_or_default();
    let (sender, mut receiver) = tauri::async_runtime::channel(1);
    let callback_app = app.clone();
    if let Err(error) = app.run_on_main_thread(move || {
        let result =
            madi_platform::transcript_native::rename(&current, &labels).map_err(str::to_owned);
        callback_app
            .state::<FilesHost>()
            .dialog_open
            .store(false, Ordering::Release);
        // Keep a confirmed native edit owned if the invoking promise disappears.
        tauri::async_runtime::spawn(async move {
            let result = match result {
                Ok(Some(name)) => match service(&callback_app) {
                    Ok(worker) => worker
                        .edit(generation, Edit::SpeakerName { speaker, name })
                        .await
                        .map_err(|error| error.to_string()),
                    Err(error) => Err(error),
                },
                Ok(None) => Ok(callback_app.state::<FilesHost>().snapshot()),
                Err(error) => Err(error),
            };
            let _ = sender.try_send(result);
        });
    }) {
        host.dialog_open.store(false, Ordering::Release);
        return Err(error.to_string());
    }
    receiver
        .recv()
        .await
        .ok_or("speaker dialog closed without a result")?
}
impl FilesHost {
    #[cfg(target_os = "macos")]
    pub fn workspace_changed(
        &self,
        state: &madi_platform::workspace_service::Snapshot,
    ) -> Result<(), String> {
        let slot = self.service.lock().map_err(|_| "file state unavailable")?;
        if let Some(service) = slot.as_ref() {
            service
                .archive_settings_changed(madi_platform::file_workflow::ArchiveSettings {
                    enabled: state.auto_save,
                    folder: state.folder.clone(),
                })
                .map_err(|error| error.to_string())?;
        }
        Ok(())
    }

    pub fn snapshot(&self) -> Snapshot {
        self.service
            .lock()
            .ok()
            .and_then(|service| service.as_ref().map(FileWorkflow::snapshot))
            .unwrap_or_default()
    }
    pub async fn shutdown(&self) -> Result<(), String> {
        self.closed.store(true, Ordering::Release);
        let service = self
            .service
            .lock()
            .map_err(|_| "file state unavailable")?
            .clone();
        if let Some(service) = service {
            service
                .shutdown()
                .await
                .map_err(|error| error.to_string())?;
        }
        Ok(())
    }
}
pub(crate) fn service(app: &tauri::AppHandle) -> Result<FileWorkflow, String> {
    let host = app.state::<FilesHost>();
    let mut slot = host.service.lock().map_err(|_| "file state unavailable")?;
    if host.closed.load(Ordering::Acquire) {
        return Err("application is closing".into());
    }
    if let Some(service) = slot.as_ref() {
        return Ok(service.clone());
    }
    #[cfg(target_os = "macos")]
    {
        let runtime =
            madi_platform::runtime_bundle::bundled().map_err(|error| error.to_string())?;
        let locations = model_locations(app)?;
        let events = app.clone();
        let setup_mode = AtomicBool::new(true);
        let workspace = crate::workspace_host::service(app)?;
        let preferences = workspace.snapshot();
        let saved_revision = Mutex::new(None);
        let worker = FileWorkflow::with_translation(
            madi_platform::file_session::Configuration {
                resources: madi_platform::asr_config::Resources {
                    executable: runtime.transcribe,
                    model: locations.transcription_model(),
                    bpe: runtime.assets_directory.join("WHISPER_BPE.bin"),
                    assets: runtime.assets_directory,
                },
                decoder: runtime.decoder,
                scratch_parent: std::env::temp_dir(),
            },
            Some(madi_platform::file_workflow::ArchiveSettings {
                enabled: preferences.auto_save,
                folder: preferences.folder,
            }),
            Some(
                madi_platform::file_workflow::translation::Resources::new(
                    locations,
                    madi_core::assets::TranslationVariant::selected(
                        madi_platform::model_presentation::physical_memory(),
                        std::env::var("MADI_TRANSLATE_MODEL").ok().as_deref(),
                    ),
                )
                .with_faq_path(
                    app.path()
                        .data_dir()
                        .map_err(|e| e.to_string())?
                        .join("Sovereign/faq_translations.json"),
                ),
            ),
            move |snapshot| {
                if let Some(path) = &snapshot.archive.transcript {
                    let key = (snapshot.generation, snapshot.archive.write_revision);
                    if let Ok(mut previous) = saved_revision.lock()
                        && previous.as_ref() != Some(&key)
                    {
                        *previous = Some(key);
                        let _ = workspace.note_saved(path, snapshot.generation);
                    }
                }
                let setup = snapshot.phase == madi_platform::file_workflow::ViewPhase::Idle
                    && snapshot.lines.is_empty();
                if setup_mode.swap(setup, Ordering::AcqRel) != setup {
                    let resize = events.clone();
                    let _ = events.run_on_main_thread(move || {
                        if let Some(window) = resize.get_webview_window("main")
                            && let Err(error) = crate::configure_macos_window(&window, setup)
                        {
                            eprintln!("file window mode: {error}");
                        }
                    });
                }
                crate::caption_host::file_changed(&events, &snapshot);
                let _ = events.emit_to("main", "file-session-changed", snapshot);
            },
        )
        .map_err(|error| error.to_string())?;
        *slot = Some(worker.clone());
        Ok(worker)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = &mut slot;
        Err("native file transcription is not implemented on this platform".into())
    }
}
#[cfg(target_os = "macos")]
fn model_locations(
    app: &tauri::AppHandle,
) -> Result<madi_platform::model_assets::Locations, String> {
    Ok(madi_platform::model_assets::Locations {
        bundle_resources: app.path().resource_dir().map_err(|e| e.to_string())?,
        bundle_executables: std::env::current_exe()
            .map_err(|e| e.to_string())?
            .parent()
            .ok_or("missing executable directory")?
            .to_owned(),
        support: app
            .path()
            .data_dir()
            .map_err(|e| e.to_string())?
            .join("Madi"),
    })
}
pub async fn start_native(
    app: &tauri::AppHandle,
    path: std::path::PathBuf,
    setup: SetupState,
) -> Result<Snapshot, String> {
    let preferences = crate::setup_host::service(app).await?;
    let glossary = crate::glossary_host::service(app).await?;
    let worker = service(app)?;
    worker
        .set_preferences(preferences)
        .await
        .map_err(|error| error.to_string())?;
    worker
        .set_glossary(glossary.clone())
        .await
        .map_err(|error| error.to_string())?;
    #[cfg(target_os = "macos")]
    let memory = madi_platform::model_presentation::physical_memory();
    #[cfg(not(target_os = "macos"))]
    let memory = 0;
    let saved_glossary = glossary
        .current()
        .await
        .map_err(|error| error.to_string())?;
    let terms = madi_core::personal_vocabulary::bias_terms(&saved_glossary.glossary);
    let settings = madi_platform::asr_config::FileSettings::from_setup(&setup, memory, terms)
        .map_err(str::to_owned)?;
    #[cfg(target_os = "macos")]
    let admission_error = (!madi_platform::model_assets::fast_size_matches(
        &model_locations(app)?.transcription_model(),
        madi_core::assets::TRANSCRIPTION,
    ))
    .then(|| {
        "음성 인식 모델이 준비되지 않았어요. 설정(⌘,) → 모델에서 먼저 다운로드해주세요.".to_owned()
    });
    #[cfg(not(target_os = "macos"))]
    let admission_error = None;
    worker
        .start(path, settings, admission_error)
        .await
        .map_err(|e| e.to_string())
}
#[tauri::command]
pub fn file_snapshot(
    window: tauri::WebviewWindow,
    host: tauri::State<'_, FilesHost>,
) -> Result<Snapshot, String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    let snapshot = host.snapshot();
    // Bootstrap caption state from the same snapshot returned to the renderer,
    // including idle/restored state before a native workflow callback exists.
    crate::caption_host::file_changed(window.app_handle(), &snapshot);
    Ok(snapshot)
}
#[tauri::command]
pub async fn file_start(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
) -> Result<Snapshot, String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    // Once accepted, file admission remains owned even if the renderer drops
    // its reply while the settings queue commits the final selection.
    tauri::async_runtime::spawn(async move {
        if app
            .state::<SetupHost>()
            .picker_open
            .load(std::sync::atomic::Ordering::Acquire)
        {
            return Ok(app.state::<FilesHost>().snapshot());
        }
        let selected = crate::setup_host::service(&app)
            .await?
            .take_file()
            .await
            .map_err(|error| error.to_string())?;
        let Some((path, setup)) = selected else {
            return Ok(app.state::<FilesHost>().snapshot());
        };
        start_native(&app, path, setup).await
    })
    .await
    .map_err(|error| error.to_string())?
}
#[tauri::command]
pub async fn live_start(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
) -> Result<Snapshot, String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    #[cfg(target_os = "macos")]
    return tauri::async_runtime::spawn(async move {
        if app.state::<SetupHost>().picker_open.load(Ordering::Acquire) {
            return Ok(app.state::<FilesHost>().snapshot());
        }
        let preferences = crate::setup_host::service(&app).await?;
        let current = preferences.snapshot();
        if current.setup.staged_file.is_some() {
            return Ok(app.state::<FilesHost>().snapshot());
        }
        let glossary = crate::glossary_host::service(&app).await?;
        let terms = madi_core::personal_vocabulary::bias_terms(
            &glossary
                .current()
                .await
                .map_err(|e| e.to_string())?
                .glossary,
        );
        let worker = service(&app)?;
        worker
            .set_preferences(preferences)
            .await
            .map_err(|e| e.to_string())?;
        worker
            .set_glossary(glossary)
            .await
            .map_err(|e| e.to_string())?;
        let request = madi_platform::live_session::Request {
            settings: madi_platform::asr_config::LiveSettings::from_setup(
                &current.setup,
                madi_platform::model_presentation::physical_memory(),
                terms,
            )
            .map_err(str::to_owned)?,
            capture: madi_core::capture_stream::Configuration::from_settings(
                &current.settings,
                &current.setup,
            ),
            input: madi_platform::live_session::Input::Devices {
                device: madi_platform::audio_devices::capture_id(
                    current.setup.input_device_id.as_deref(),
                )
                .map_err(|e| e.to_string())?,
            },
        };
        let admission_error = (!madi_platform::model_assets::fast_size_matches(
            &model_locations(&app)?.transcription_model(),
            madi_core::assets::TRANSCRIPTION,
        ))
        .then(|| {
            "음성 인식 모델이 준비되지 않았어요. 설정(⌘,) → 모델에서 먼저 다운로드해주세요."
                .to_owned()
        });
        worker
            .start_live(request, admission_error)
            .await
            .map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?;
    #[cfg(not(target_os = "macos"))]
    {
        let _ = app;
        Err("native live capture is not implemented on this platform".into())
    }
}

#[tauri::command]
pub async fn live_control(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    generation: u64,
    command: LiveControl,
) -> Result<Snapshot, String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    #[cfg(target_os = "macos")]
    return tauri::async_runtime::spawn(async move {
        let worker = service(&app)?;
        let current = worker.snapshot();
        if current.generation != generation {
            return Ok(current);
        }
        if let LiveControl::InputDevice(device) = &command {
            if !current.phase.is_recording() {
                return Ok(current);
            }
            madi_platform::audio_devices::capture_id(device.as_deref())
                .map_err(|e| e.to_string())?;
            crate::setup_host::service(&app)
                .await?
                .setup(madi_core::setup::SetupCommand::InputDevice(device.clone()))
                .await
                .map_err(|e| e.to_string())?;
        }
        worker
            .live_control(generation, command)
            .await
            .map_err(|e| e.to_string())
    })
    .await
    .map_err(|e| e.to_string())?;
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (app, generation, command);
        Err("native live capture is not implemented on this platform".into())
    }
}

#[tauri::command]
pub async fn file_leave(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    generation: u64,
    close: bool,
) -> Result<Snapshot, String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    tauri::async_runtime::spawn(async move {
        let worker = service(&app)?;
        let current = worker.snapshot();
        if current.generation != generation { return Ok(current); }
        let stop = current.phase.is_recording();
        let discard = !current.lines.is_empty() && current.archive.transcript.is_none() && current.file_name.is_empty()
            && !matches!(current.phase, madi_platform::file_workflow::ViewPhase::Processing | madi_platform::file_workflow::ViewPhase::Flushing | madi_platform::file_workflow::ViewPhase::CountingDown {..});
        if stop || discard {
            let ko = crate::setup_host::service(&app).await?.snapshot().presentation.ui_language == madi_core::preferences::UILanguage::Ko;
            let labels = if stop {
                if ko { ("녹음이 진행 중이에요", "정지하면 여기까지의 기록이 정리돼요. 자동저장이 켜져 있으면 파일로 저장됩니다.", "정지하기", "계속 녹음") }
                else { ("Recording in progress", "Stopping wraps up what's captured so far. If auto-save is on, it's written to a file.", "Stop", "Keep recording") }
            } else if close {
                if ko { ("저장되지 않은 기록이 있어요", "자동저장이 꺼져 있어 닫으면 이 기록은 사라져요. 내보내기로 먼저 저장할 수 있어요.", "삭제하고 닫기", "취소") }
                else { ("You have an unsaved transcript", "Auto-save is off, so closing discards this transcript. You can Export to save it first.", "Discard and close", "Cancel") }
            } else if ko { ("저장되지 않은 기록이 있어요", "자동저장이 꺼져 있어 나가면 이 기록은 사라져요. 내보내기로 먼저 저장할 수 있어요.", "삭제하고 나가기", "취소") }
            else { ("You have an unsaved transcript", "Auto-save is off, so leaving discards this transcript. You can Export to save it first.", "Discard and leave", "Cancel") };
            if app.state::<FilesHost>().dialog_open.swap(true, Ordering::AcqRel) { return Ok(worker.snapshot()); }
            let (sender, mut receiver) = tauri::async_runtime::channel(1);
            let dialog_app = app.clone();
            if let Err(error) = app.run_on_main_thread(move || {
                let result = madi_platform::transcript_native::confirm(labels.0, labels.1, labels.2, labels.3).map_err(str::to_owned);
                dialog_app.state::<FilesHost>().dialog_open.store(false, Ordering::Release);
                let _ = sender.try_send(result);
            }) {
                app.state::<FilesHost>().dialog_open.store(false, Ordering::Release);
                return Err(error.to_string());
            }
            if !receiver.recv().await.ok_or("confirmation closed without a result")?? { return Ok(worker.snapshot()); }
        }
        #[cfg(target_os = "macos")]
        if stop { return worker.live_control(generation, LiveControl::Stop).await.map_err(|e|e.to_string()); }
        worker.reset(generation).await.map_err(|e|e.to_string())
    }).await.map_err(|e|e.to_string())?
}

use madi_platform::audio_permissions::Action as PermissionAction;

#[tauri::command]
pub async fn live_permission_action(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    generation: u64,
    action: PermissionAction,
) -> Result<(), String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    let current = app.state::<FilesHost>().snapshot();
    if current.generation != generation {
        return Ok(());
    }
    let Some(issue) = current.permission_issue else {
        return Ok(());
    };
    match action {
        PermissionAction::Restart
            if issue != madi_platform::audio_permissions::Issue::MicrophoneDenied =>
        {
            app.request_restart()
        }
        PermissionAction::OpenSettings => {
            let (sender, mut receiver) = tauri::async_runtime::channel(1);
            app.run_on_main_thread(move || {
                let _ = sender.try_send(
                    madi_platform::transcript_native::audio_permission_settings(issue)
                        .map_err(str::to_owned),
                );
            })
            .map_err(|e| e.to_string())?;
            return receiver
                .recv()
                .await
                .ok_or("permission settings worker stopped")?;
        }
        _ => (),
    }
    Ok(())
}

#[tauri::command]
pub async fn file_reset(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    generation: u64,
) -> Result<Snapshot, String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    let worker = app
        .state::<FilesHost>()
        .service
        .lock()
        .map_err(|_| "file state unavailable")?
        .clone();
    match worker {
        Some(worker) => worker.reset(generation).await.map_err(|e| e.to_string()),
        None => Ok(Snapshot::default()),
    }
}
#[tauri::command]
pub async fn file_edit(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    generation: u64,
    edit: Edit,
) -> Result<Snapshot, String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    let worker = app
        .state::<FilesHost>()
        .service
        .lock()
        .map_err(|_| "file state unavailable")?
        .clone()
        .ok_or("no file session")?;
    tauri::async_runtime::spawn(async move {
        let glossary = crate::glossary_host::service(&app).await?;
        worker
            .set_glossary(glossary)
            .await
            .map_err(|error| error.to_string())?;
        worker
            .edit(generation, edit)
            .await
            .map_err(|error| error.to_string())
    })
    .await
    .map_err(|error| error.to_string())?
}
