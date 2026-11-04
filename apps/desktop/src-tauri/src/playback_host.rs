//! AVPlayer remains owned by the AppKit main thread. The WebView supplies a
//! displayed line/span, never a filesystem path or media URL.
use crate::files_host::FilesHost;
use madi_core::transcript::Uuid;
use serde_json::{Value, json};
use std::sync::Mutex;
use tauri::{Emitter, Manager};

#[derive(Clone, Default)]
struct Status {
    revision: u64,
    generation: u64,
    playing_line: Option<Uuid>,
    has_source: bool,
    closed: bool,
}
impl Status {
    fn value(&self) -> Value {
        json!({"revision":self.revision, "generation":self.generation, "playingLine":self.playing_line})
    }
    fn reconcile(&mut self, (generation, has_source): (u64, bool)) -> bool {
        if self.closed || (self.generation == generation && self.has_source == has_source) {
            return false;
        }
        self.generation = generation;
        self.has_source = has_source;
        self.playing_line = None;
        self.revision += 1;
        true
    }
    fn close(&mut self) -> bool {
        if self.closed {
            return false;
        }
        self.closed = true;
        self.has_source = false;
        self.playing_line = None;
        self.revision += 1;
        true
    }
    #[cfg(any(target_os = "macos", test))]
    fn changed(&mut self, generation: u64, line: Option<Uuid>) -> bool {
        if generation != self.generation || !self.has_source || self.playing_line == line {
            return false;
        }
        self.playing_line = line;
        self.revision += 1;
        true
    }
}
#[derive(Default)]
pub struct PlaybackHost(Mutex<Status>);

#[cfg(target_os = "macos")]
thread_local! {
    static PLAYER: std::cell::RefCell<Option<madi_platform::line_playback::Player>> = const { std::cell::RefCell::new(None) };
}

fn reconcile(app: &tauri::AppHandle) -> Result<Status, String> {
    // Read the current owner snapshot on main, not the potentially stale event
    // that queued this operation. Its watch value precedes its changed callback.
    let source = app.state::<FilesHost>().playback_identity();
    let host = app.state::<PlaybackHost>();
    let (changed, status) = {
        let mut state = host.0.lock().map_err(|_| "playback state unavailable")?;
        (state.reconcile(source), state.clone())
    };
    if changed {
        // Release without the status lock: destruction publishes a final stop.
        // That old generation is already invalid and cannot replace new state.
        #[cfg(target_os = "macos")]
        PLAYER.with(|slot| drop(slot.borrow_mut().take()));
        let _ = app.emit_to("main", "playback-changed", status.value());
    }
    Ok(status)
}
pub fn file_changed(app: &tauri::AppHandle) {
    let owner = app.clone();
    let _ = app.run_on_main_thread(move || {
        if let Err(error) = reconcile(&owner) {
            eprintln!("line playback: {error}");
        }
    });
}
#[tauri::command]
pub async fn playback_snapshot(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
) -> Result<Value, String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    let (sender, mut receiver) = tauri::async_runtime::channel(1);
    let owner = app.clone();
    app.run_on_main_thread(move || {
        let _ = sender.try_send(reconcile(&owner).map(|s| s.value()));
    })
    .map_err(|e| e.to_string())?;
    receiver.recv().await.ok_or("playback host stopped")?
}
#[tauri::command]
pub async fn playback_toggle(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    generation: u64,
    id: String,
    from: f64,
    to: f64,
) -> Result<(), String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    let line = Uuid::parse_str(&id).map_err(|_| "invalid transcript line")?;
    if !from.is_finite() || !to.is_finite() {
        return Err("invalid playback span".into());
    }
    #[cfg(target_os = "macos")]
    {
        let worker = crate::files_host::service(&app)?;
        let Some(path) = worker
            .playback_source(generation)
            .await
            .map_err(|e| e.to_string())?
        else {
            return Ok(());
        };
        let (sender, mut receiver) = tauri::async_runtime::channel(1);
        let owner = app.clone();
        app.run_on_main_thread(move || {
            let result = (|| {
                let status = reconcile(&owner)?;
                if status.generation != generation || !status.has_source {
                    return Ok(());
                }
                PLAYER.with(|slot| {
                    let mut slot = slot.borrow_mut();
                    if slot.is_none() {
                        let events = owner.clone();
                        *slot = Some(
                            madi_platform::line_playback::Player::new(move |line| {
                                let host = events.state::<PlaybackHost>();
                                let next = host.0.lock().ok().and_then(|mut state| {
                                    state.changed(generation, line).then(|| state.clone())
                                });
                                if let Some(next) = next {
                                    let _ =
                                        events.emit_to("main", "playback-changed", next.value());
                                }
                            })
                            .map_err(str::to_owned)?,
                        );
                    }
                    slot.as_mut()
                        .expect("player created")
                        .toggle(&path, line, from, to)
                        .map_err(str::to_owned)
                })
            })();
            let _ = sender.try_send(result);
        })
        .map_err(|e| e.to_string())?;
        receiver.recv().await.ok_or("playback host stopped")?
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (app, generation, line);
        Err("native line playback is not available on this platform yet".into())
    }
}
pub fn shutdown(app: &tauri::AppHandle) {
    let host = app.state::<PlaybackHost>();
    let next = host
        .0
        .lock()
        .ok()
        .and_then(|mut state| state.close().then(|| state.value()));
    #[cfg(target_os = "macos")]
    PLAYER.with(|slot| drop(slot.borrow_mut().take()));
    if let Some(next) = next {
        let _ = app.emit_to("main", "playback-changed", next);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn old_native_callbacks_cannot_revive_reset_or_replaced_session() {
        let mut state = Status::default();
        let mut source = (1, true);
        let line = Some(Uuid::from_u128(1));
        assert!(state.reconcile(source));
        assert!(state.changed(1, line));
        assert!(!state.reconcile(source)); // ordinary transcript updates keep playback
        assert_eq!(state.playing_line, line);
        source.0 = 2;
        assert!(state.reconcile(source));
        assert!(state.changed(2, line));
        assert!(!state.changed(1, None)); // retiring player cannot clear its replacement
        assert_eq!(state.playing_line, line);
        source.1 = false;
        assert!(state.reconcile(source));
        assert!(!state.changed(2, line));
        assert_eq!(state.playing_line, None);
        assert!(state.close());
        assert!(!state.reconcile((3, true))); // callbacks/commands while engines drain
        assert!(!state.changed(3, line));
        assert!(!state.close());
    }
}
