use crate::files_host::FilesHost;
use madi_core::setup::{SetupCommand, SetupState};
use madi_platform::file_workflow::ViewPhase;
use madi_platform::media_file;
use std::{path::PathBuf, sync::Mutex};
use tauri::{Emitter, Manager};

#[derive(Default)]
pub struct SetupHost {
    pub snapshot: SetupState,
    // Native file authority is deliberately absent from serialized SetupState.
    selected: Option<PathBuf>,
    picker_open: bool,
}

impl SetupHost {
    pub fn take_staged_file(&mut self) -> Option<(PathBuf, SetupState)> {
        if self.picker_open {
            return None;
        }
        let path = self.selected.take()?;
        self.snapshot
            .apply(SetupCommand::ClearStagedFile)
            .expect("clear native selection");
        Some((path, self.snapshot.clone()))
    }
    pub fn apply(&mut self, command: SetupCommand) -> Result<(), &'static str> {
        self.snapshot.apply(command)?;
        if self.snapshot.staged_file.is_none() {
            self.selected = None;
        }
        Ok(())
    }

    fn stage(&mut self, path: PathBuf) {
        self.snapshot.staged_file = Some(media_file::summary(&path));
        self.selected = Some(path);
        self.snapshot.revision += 1;
    }
}

#[tauri::command]
pub async fn choose_file(window: tauri::WebviewWindow) -> Result<SetupState, String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    let app = window.app_handle().clone();
    {
        let managed = app.state::<Mutex<SetupHost>>();
        let mut host = managed.lock().map_err(|_| "setup state unavailable")?;
        if host.picker_open || app.state::<FilesHost>().snapshot().phase == ViewPhase::Processing {
            return Ok(host.snapshot.clone());
        }
        host.picker_open = true;
    }
    let (sender, mut receiver) = tauri::async_runtime::channel(1);
    let callback_app = app.clone();
    let dispatched = app.run_on_main_thread(move || {
        // AppKit runs its modal loop on the main thread. Never hold our state
        // lock across that loop, which can dispatch other application events.
        let picked = media_file::choose();
        let managed = callback_app.state::<Mutex<SetupHost>>();
        let result = managed
            .lock()
            .map_err(|_| "setup state unavailable".to_owned())
            .and_then(|mut host| {
                host.picker_open = false;
                picked.map_err(str::to_owned)
            });
        // Keep the selection/start operation owned even if the web request is
        // cancelled while AppKit's modal loop is open.
        tauri::async_runtime::spawn(async move {
            let result = match result {
                Ok(Some(path)) => route_selection(&callback_app, path).await,
                Ok(None) => callback_app
                    .state::<Mutex<SetupHost>>()
                    .lock()
                    .map(|host| host.snapshot.clone())
                    .map_err(|_| "setup state unavailable".into()),
                Err(error) => Err(error),
            };
            let _ = sender.try_send(result);
        });
    });
    if let Err(error) = dispatched {
        if let Ok(mut host) = app.state::<Mutex<SetupHost>>().lock() {
            host.picker_open = false;
        }
        return Err(error.to_string());
    }
    receiver
        .recv()
        .await
        .ok_or_else(|| "media picker closed without a result".to_owned())?
}

async fn route_selection(app: &tauri::AppHandle, path: PathBuf) -> Result<SetupState, String> {
    let file = app.state::<FilesHost>().snapshot();
    let setup = {
        let managed = app.state::<Mutex<SetupHost>>();
        let mut host = managed.lock().map_err(|_| "setup state unavailable")?;
        if host.picker_open || file.phase == ViewPhase::Processing {
            return Ok(host.snapshot.clone());
        }
        if file.phase == ViewPhase::Idle && file.lines.is_empty() {
            host.stage(path);
            let snapshot = host.snapshot.clone();
            let _ = app.emit_to("main", "setup-changed", &snapshot);
            return Ok(snapshot);
        }
        host.snapshot.clone()
    };
    // On the working screen Swift starts the selected file immediately. The
    // workflow serializes concurrent selections and ignores starts while busy.
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
