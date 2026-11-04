use crate::files_host::FilesHost;
use madi_core::{
    preferences::{Appearance, PresentationCommand},
    settings::SettingsCommand,
    setup::SetupState,
};
use madi_platform::{
    file_workflow::ViewPhase,
    media_file, preferences,
    preferences_service::{PreferencesService, Snapshot},
};
use std::{
    path::PathBuf,
    sync::atomic::{AtomicBool, Ordering},
};
use tauri::{Emitter, Manager};

#[derive(Default)]
pub struct SetupHost {
    service: tauri::async_runtime::Mutex<Option<PreferencesService>>,
    closed: AtomicBool,
    pub picker_open: AtomicBool,
}
impl SetupHost {
    pub async fn shutdown(&self) -> Result<(), String> {
        self.closed.store(true, Ordering::Release);
        let service = self.service.lock().await.clone();
        if let Some(service) = service {
            service
                .shutdown()
                .await
                .map_err(|error| error.to_string())?;
        }
        Ok(())
    }
}
pub async fn service(app: &tauri::AppHandle) -> Result<PreferencesService, String> {
    let host = app.state::<SetupHost>();
    let mut slot = host.service.lock().await;
    if host.closed.load(Ordering::Acquire) {
        return Err("application is closing".into());
    }
    if let Some(service) = slot.as_ref() {
        return Ok(service.clone());
    }
    let path = app
        .path()
        .app_config_dir()
        .map_err(|error| error.to_string())?
        .join("preferences.json");
    let store = tauri::async_runtime::spawn_blocking(move || {
        preferences::Store::load(path, preferences::legacy()?)
    })
    .await
    .map_err(|error| error.to_string())?
    .map_err(|error| error.to_string())?;
    if host.closed.load(Ordering::Acquire) {
        return Err("application is closing".into());
    }
    let events = app.clone();
    let appearance = store.value().presentation.appearance;
    // The callback is serialized by the owner; only changed appearance values
    // dispatch a main-thread update. Disk commits precede every publication.
    let theme = std::sync::Mutex::new(appearance);
    let worker = PreferencesService::new(store, move |snapshot| {
        if let Ok(mut previous) = theme.lock()
            && *previous != snapshot.presentation.appearance
        {
            *previous = snapshot.presentation.appearance;
            let appearance = *previous;
            let app = events.clone();
            let _ = events.run_on_main_thread(move || {
                if let Err(error) = apply_appearance(&app, appearance) {
                    eprintln!("appearance: {error}");
                }
            });
        }
        let _ = events.emit_to("main", "setup-changed", &snapshot.setup);
        for label in ["main", "settings"] {
            let _ = events.emit_to(label, "preferences-changed", &snapshot);
        }
    })
    .map_err(|error| error.to_string())?;
    let initial = app.clone();
    app.run_on_main_thread(move || {
        if let Err(error) = apply_appearance(&initial, appearance) {
            eprintln!("appearance: {error}");
        }
    })
    .map_err(|error| error.to_string())?;
    *slot = Some(worker.clone());
    Ok(worker)
}
fn apply_appearance(app: &tauri::AppHandle, appearance: Appearance) -> Result<(), String> {
    if let Some(window) = app.get_webview_window("main") {
        #[cfg(target_os = "macos")]
        {
            // The callback runs on the main thread and the handle keeps its
            // NSWindow alive. Never use Tauri's app-wide macOS set_theme here.
            let dark = unsafe {
                preferences::set_window_appearance(
                    window.ns_window().map_err(|error| error.to_string())?,
                    appearance,
                )
            }?;
            crate::set_macos_background(
                &window,
                if dark {
                    tauri::Theme::Dark
                } else {
                    tauri::Theme::Light
                },
            )
            .map_err(|error| error.to_string())?;
        }
        #[cfg(not(target_os = "macos"))]
        window
            .set_theme(match appearance {
                Appearance::System => None,
                Appearance::Light => Some(tauri::Theme::Light),
                Appearance::Dark => Some(tauri::Theme::Dark),
            })
            .map_err(|error| error.to_string())?;
    }
    Ok(())
}
#[tauri::command]
pub async fn preferences_snapshot(window: tauri::WebviewWindow) -> Result<Snapshot, String> {
    crate::settings_host::known_window(&window)?;
    Ok(service(window.app_handle()).await?.snapshot())
}
#[tauri::command]
pub async fn preferences_command(
    window: tauri::WebviewWindow,
    command: PresentationCommand,
) -> Result<Snapshot, String> {
    crate::settings_host::known_window(&window)?;
    service(window.app_handle())
        .await?
        .presentation(command)
        .await
        .map_err(|error| error.to_string())
}
#[tauri::command]
pub async fn settings_command(
    window: tauri::WebviewWindow,
    command: SettingsCommand,
) -> Result<Snapshot, String> {
    crate::settings_host::known_window(&window)?;
    service(window.app_handle())
        .await?
        .settings(command)
        .await
        .map_err(|error| error.to_string())
}
#[tauri::command]
pub async fn choose_file(window: tauri::WebviewWindow) -> Result<SetupState, String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    let app = window.app_handle().clone();
    let worker = service(&app).await?;
    let host = app.state::<SetupHost>();
    if app.state::<FilesHost>().snapshot().phase == ViewPhase::Processing
        || host.picker_open.swap(true, Ordering::AcqRel)
    {
        return Ok(worker.snapshot().setup);
    }
    let (sender, mut receiver) = tauri::async_runtime::channel(1);
    let callback_app = app.clone();
    if let Err(error) = app.run_on_main_thread(move || {
        let picked = media_file::choose();
        callback_app
            .state::<SetupHost>()
            .picker_open
            .store(false, Ordering::Release);
        tauri::async_runtime::spawn(async move {
            let result = match picked {
                Ok(Some(path)) => route_selection(&callback_app, path).await,
                Ok(None) => Ok(worker.snapshot().setup),
                Err(error) => Err(error.to_owned()),
            };
            let _ = sender.try_send(result);
        });
    }) {
        host.picker_open.store(false, Ordering::Release);
        return Err(error.to_string());
    }
    receiver
        .recv()
        .await
        .ok_or_else(|| "media picker closed without a result".to_owned())?
}
async fn route_selection(app: &tauri::AppHandle, path: PathBuf) -> Result<SetupState, String> {
    let worker = service(app).await?;
    let file = app.state::<FilesHost>().snapshot();
    if app.state::<SetupHost>().picker_open.load(Ordering::Acquire)
        || file.phase == ViewPhase::Processing
    {
        return Ok(worker.snapshot().setup);
    }
    if file.phase == ViewPhase::Idle && file.lines.is_empty() {
        return worker
            .stage(path)
            .await
            .map(|value| value.setup)
            .map_err(|error| error.to_string());
    }
    let setup = worker.snapshot().setup;
    crate::files_host::start_native(app, path, setup.clone()).await?;
    Ok(setup)
}

pub fn handle_drop(webview: &tauri::Webview, event: &tauri::WebviewEvent) {
    if webview.label() != "main" {
        return;
    }
    let tauri::WebviewEvent::DragDrop(event) = event else {
        return;
    };
    match event {
        tauri::DragDropEvent::Enter { .. } => {
            let allowed = webview.state::<FilesHost>().snapshot().phase != ViewPhase::Processing;
            let _ = webview.emit_to("main", "media-drag-target", allowed);
        }
        tauri::DragDropEvent::Drop { paths, .. } => {
            let _ = webview.emit_to("main", "media-drag-target", false);
            // Match the Swift root drop destination: select the first accepted
            // URL in order, including replacement of an already staged file.
            if let Some(path) = paths.iter().find(|path| media_file::accepts_drop(path)) {
                let app = webview.app_handle().clone();
                let path = path.clone();
                tauri::async_runtime::spawn(async move {
                    if let Err(error) = route_selection(&app, path).await {
                        eprintln!("native file selection: {error}");
                    }
                });
            }
        }
        tauri::DragDropEvent::Leave => {
            let _ = webview.emit_to("main", "media-drag-target", false);
        }
        _ => {}
    }
}
