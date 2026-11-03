use madi_core::setup::{SetupCommand, SetupState};
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
        if host.picker_open {
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
                if let Some(path) = picked.map_err(str::to_owned)? {
                    host.stage(path);
                }
                Ok(host.snapshot.clone())
            });
        let _ = sender.try_send(result);
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

pub fn handle_drop(webview: &tauri::Webview, event: &tauri::WebviewEvent) {
    if webview.label() != "main" {
        return;
    }
    let tauri::WebviewEvent::DragDrop(event) = event else {
        return;
    };
    match event {
        tauri::DragDropEvent::Enter { .. } => {
            let _ = webview.emit_to("main", "media-drag-target", true);
        }
        tauri::DragDropEvent::Drop { paths, .. } => {
            let _ = webview.emit_to("main", "media-drag-target", false);
            // Match the Swift root drop destination: select the first accepted
            // URL in order, including replacement of an already staged file.
            if let Some(path) = paths.iter().find(|path| media_file::accepts_drop(path)) {
                let managed = webview.state::<Mutex<SetupHost>>();
                if let Ok(mut host) = managed.lock()
                    && !host.picker_open
                {
                    host.stage(path.clone());
                    let snapshot = host.snapshot.clone();
                    drop(host);
                    let _ = webview.emit_to("main", "setup-changed", snapshot);
                }
            }
        }
        tauri::DragDropEvent::Leave => {
            let _ = webview.emit_to("main", "media-drag-target", false);
        }
        _ => {}
    }
}
