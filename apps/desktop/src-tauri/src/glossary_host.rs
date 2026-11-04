use madi_platform::glossary_service::{self, GlossaryService, SettingsCommand, Snapshot, Store};
use std::sync::atomic::{AtomicBool, Ordering};
use tauri::{Emitter, Manager};

#[derive(Default)]
pub struct GlossaryHost {
    service: tauri::async_runtime::Mutex<Option<GlossaryService>>,
    closed: AtomicBool,
}
impl GlossaryHost {
    pub async fn shutdown(&self) -> Result<(), String> {
        self.closed.store(true, Ordering::Release);
        if let Some(service) = self.service.lock().await.clone() {
            service
                .shutdown()
                .await
                .map_err(|error| error.to_string())?;
        }
        Ok(())
    }
}
pub async fn service(app: &tauri::AppHandle) -> Result<GlossaryService, String> {
    let host = app.state::<GlossaryHost>();
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
        .join("glossary.json");
    let store = tauri::async_runtime::spawn_blocking(move || {
        Store::load(path, glossary_service::legacy()?)
    })
    .await
    .map_err(|error| error.to_string())?
    .map_err(|error| error.to_string())?;
    if host.closed.load(Ordering::Acquire) {
        return Err("application is closing".into());
    }
    let events = app.clone();
    let worker = GlossaryService::new(store, move |snapshot| {
        let _ = events.emit_to("main", "glossary-changed", snapshot);
    })
    .map_err(|error| error.to_string())?;
    *slot = Some(worker.clone());
    Ok(worker)
}
#[tauri::command]
pub async fn glossary_snapshot(window: tauri::WebviewWindow) -> Result<Snapshot, String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    service(window.app_handle())
        .await?
        .current()
        .await
        .map_err(|error| error.to_string())
}
#[tauri::command]
pub async fn glossary_command(
    window: tauri::WebviewWindow,
    command: SettingsCommand,
) -> Result<Snapshot, String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    service(window.app_handle())
        .await?
        .settings(command)
        .await
        .map_err(|error| error.to_string())
}
