use crate::setup_host::SetupHost;
use madi_core::setup::SetupState;
use madi_platform::file_workflow::{Edit, FileWorkflow, Snapshot};
use std::sync::{
    Mutex,
    atomic::{AtomicBool, Ordering},
};
use tauri::{Emitter, Manager};

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
fn service(app: &tauri::AppHandle) -> Result<FileWorkflow, String> {
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
        let worker = FileWorkflow::new(
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
            move |snapshot| {
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
    let worker = service(app)?;
    #[cfg(target_os = "macos")]
    let memory = madi_platform::model_presentation::physical_memory();
    #[cfg(not(target_os = "macos"))]
    let memory = 0;
    // OSD/default vocabulary/settings persistence are separate migration work.
    let settings =
        madi_platform::asr_config::FileSettings::from_setup(&setup, true, memory, Vec::new())
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
    Ok(host.snapshot())
}
#[tauri::command]
pub async fn file_start(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
) -> Result<Snapshot, String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    let selected = {
        let managed = app.state::<Mutex<SetupHost>>();
        let mut setup = managed.lock().map_err(|_| "setup state unavailable")?;
        setup.take_staged_file()
    };
    let Some((path, setup)) = selected else {
        return Ok(app.state::<FilesHost>().snapshot());
    };
    let _ = app.emit_to("main", "setup-changed", &setup);
    start_native(&app, path, setup).await
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
    worker
        .edit(generation, edit)
        .await
        .map_err(|e| e.to_string())
}
