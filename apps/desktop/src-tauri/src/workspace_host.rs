//! Native-owned workspace paths, isolated preferences, and confirmed exports.
use madi_platform::{
    transcript_export::Format,
    workspace_service::{Action, Change, Snapshot, Workspace},
};
use std::sync::{
    Mutex,
    atomic::{AtomicBool, Ordering},
};
#[cfg(target_os = "macos")]
use tauri::Emitter;
use tauri::Manager;

#[derive(Default)]
pub struct WorkspaceHost {
    service: Mutex<Option<Workspace>>,
    closed: AtomicBool,
    dialog_open: AtomicBool,
}
impl WorkspaceHost {
    pub async fn shutdown(&self) -> Result<(), String> {
        self.closed.store(true, Ordering::Release);
        let service = self
            .service
            .lock()
            .map_err(|_| "workspace unavailable")?
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
pub(crate) fn service(app: &tauri::AppHandle) -> Result<Workspace, String> {
    let host = app.state::<WorkspaceHost>();
    let mut slot = host.service.lock().map_err(|_| "workspace unavailable")?;
    if host.closed.load(Ordering::Acquire) {
        return Err("application is closing".into());
    }
    if let Some(service) = slot.as_ref() {
        return Ok(service.clone());
    }
    #[cfg(target_os = "macos")]
    {
        use madi_platform::workspace_preferences::{self, Preferences, Store};
        let (legacy, default_folder) =
            workspace_preferences::legacy_and_default().map_err(|error| error.to_string())?;
        let fallback = Preferences::from_legacy(legacy, default_folder.clone());
        let path = app
            .path()
            .app_config_dir()
            .map_err(|error| error.to_string())?
            .join("workspace.json");
        let store = Store::load(path, fallback).map_err(|error| error.to_string())?;
        if store.value().folder == default_folder {
            workspace_preferences::prepare_default_folder(&default_folder);
        }
        let events = app.clone();
        let worker = Workspace::new(store, move |snapshot| {
            // Update the existing file owner synchronously at publication time.
            // Independent IPC completions cannot reorder persisted settings.
            if let Err(error) = events
                .state::<crate::files_host::FilesHost>()
                .workspace_changed(&snapshot)
            {
                eprintln!("workspace archive settings: {error}");
            }
            let _ = events.emit_to("main", "workspace-changed", snapshot);
        });
        *slot = Some(worker.clone());
        Ok(worker)
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = &mut slot;
        Err("native workspace is not implemented on this platform".into())
    }
}
fn main_window(window: &tauri::WebviewWindow) -> Result<(), String> {
    if window.label() == "main" {
        Ok(())
    } else {
        Err("unsupported window".into())
    }
}
#[tauri::command]
pub async fn workspace_snapshot(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
) -> Result<Option<Snapshot>, String> {
    main_window(&window)?;
    #[cfg(target_os = "macos")]
    {
        Ok(Some(service(&app)?.snapshot()))
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = app;
        Ok(None)
    }
}
#[tauri::command]
pub async fn workspace_command(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    command: Action,
) -> Result<Snapshot, String> {
    main_window(&window)?;
    let worker = service(&app)?;
    match command {
        Action::AutoSave(enabled) => worker
            .change(
                None,
                Change {
                    auto_save: Some(enabled),
                    ..Default::default()
                },
            )
            .await
            .map_err(|error| error.to_string()),
        Action::ShowStats(visible) => {
            worker
                .show_stats(visible)
                .map_err(|error| error.to_string())?;
            Ok(worker.snapshot())
        }
    }
}
#[tauri::command]
pub async fn workspace_choose_folder(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
) -> Result<Snapshot, String> {
    main_window(&window)?;
    let worker = service(&app)?;
    let current = worker.snapshot();
    let host = app.state::<WorkspaceHost>();
    if host.dialog_open.swap(true, Ordering::AcqRel) {
        return Ok(current);
    }
    let (sender, mut receiver) = tauri::async_runtime::channel(1);
    let owner = app.clone();
    if let Err(error) = app.run_on_main_thread(move || {
        #[cfg(target_os = "macos")]
        let result = madi_platform::workspace_scan::macos::choose_folder(&current.folder);
        #[cfg(not(target_os = "macos"))]
        let result: std::io::Result<Option<std::path::PathBuf>> = Err(std::io::Error::new(
            std::io::ErrorKind::Unsupported,
            "native folder picker is not implemented on this platform",
        ));
        owner
            .state::<WorkspaceHost>()
            .dialog_open
            .store(false, Ordering::Release);
        // A confirmed native selection stays owned if its invoking JS promise goes away.
        tauri::async_runtime::spawn(async move {
            let result = match result {
                Ok(Some(folder)) => worker
                    .change(
                        Some(current.root_revision),
                        Change {
                            folder: Some(folder),
                            ..Default::default()
                        },
                    )
                    .await
                    .map_err(|error| error.to_string()),
                Ok(None) => Ok(worker.snapshot()),
                Err(error) => Err(error.to_string()),
            };
            let _ = sender.try_send(result);
        });
    }) {
        host.dialog_open.store(false, Ordering::Release);
        return Err(error.to_string());
    }
    receiver.recv().await.ok_or("folder picker stopped")?
}
#[tauri::command]
pub async fn workspace_open(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    generation: u64,
    id: String,
    file_generation: u64,
) -> Result<madi_platform::file_workflow::Snapshot, String> {
    main_window(&window)?;
    let Some(path) = service(&app)?.resolve(generation, &id) else {
        return Ok(app.state::<crate::files_host::FilesHost>().snapshot());
    };
    crate::files_host::service(&app)?
        .open_archive(file_generation, path)
        .await
        .map_err(|error| error.to_string())
}
#[tauri::command]
pub async fn workspace_export(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    format: Format,
    file_generation: u64,
) -> Result<(), String> {
    main_window(&window)?;
    let files = crate::files_host::service(&app)?;
    let current = files.snapshot();
    if current.generation != file_generation || current.lines.is_empty() {
        return Ok(());
    }
    let settings = service(&app)?.snapshot().editor_settings;
    let host = app.state::<WorkspaceHost>();
    if host.dialog_open.swap(true, Ordering::AcqRel) {
        return Ok(());
    }
    let (sender, mut receiver) = tauri::async_runtime::channel(1);
    let owner = app.clone();
    if let Err(error) = app.run_on_main_thread(move || {
        let result = madi_platform::transcript_export::choose(format);
        owner
            .state::<WorkspaceHost>()
            .dialog_open
            .store(false, Ordering::Release);
        tauri::async_runtime::spawn(async move {
            let result = async {
                let Some(path) = result.map_err(|error| error.to_string())? else {
                    return Ok(());
                };
                // Use current authoritative lines after confirmation. A reset
                // during the dialog invalidates the generation and writes nothing.
                files
                    .export_to(file_generation, path, format, settings)
                    .await
                    .map_err(|error| error.to_string())
            }
            .await;
            let _ = sender.try_send(result);
        });
    }) {
        host.dialog_open.store(false, Ordering::Release);
        return Err(error.to_string());
    }
    receiver.recv().await.ok_or("export picker stopped")?
}
