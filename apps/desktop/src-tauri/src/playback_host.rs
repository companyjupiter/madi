//! AVPlayer remains owned by the AppKit main thread. The WebView supplies a
//! displayed line/span, never a filesystem path or media URL.
use crate::files_host::FilesHost;
#[cfg(any(target_os = "macos", test))]
use madi_core::review::Span;
use madi_core::{
    review::{self, Command as ReviewCommand},
    transcript::Uuid,
};
use serde_json::{Value, json};
use std::sync::Mutex;
use tauri::{Emitter, Manager};

#[derive(Default)]
struct Status {
    revision: u64,
    generation: u64,
    playing_line: Option<Uuid>,
    has_source: bool,
    closed: bool,
    review: review::Controller,
    review_visible: bool,
    review_scroll_tick: u64,
    review_bar_index: usize,
    review_scroll_target: Option<Uuid>,
    #[cfg(any(target_os = "macos", test))]
    restarting: bool,
}
impl Status {
    // ContentView.jump changes the bar cursor, not ReviewController.index.
    fn jump_review_bar(&mut self, delta: i64, flagged: &[review::Span]) -> bool {
        if flagged.is_empty() {
            return false;
        }
        self.review.stop();
        let index = self.review_bar_index.min(flagged.len() - 1);
        self.review_bar_index = review::wrapped(index, delta, flagged.len());
        self.review_scroll_target = Some(flagged[self.review_bar_index].line_id);
        self.review_scroll_tick += 1;
        true
    }
    fn sync_review(&mut self) {
        if let Some(span) = self.review.current() {
            self.review_bar_index = self.review.index;
            self.review_scroll_target = Some(span.line_id);
            self.review_scroll_tick += 1;
        }
    }
    fn value(&self) -> Value {
        json!({"revision":self.revision, "generation":self.generation, "playingLine":self.playing_line,
            "review":{"visible":self.review_visible,"isListening":self.review.is_listening,"index":self.review.index,"count":self.review.queue.len(),
                "current":self.review.current(),"scrollTick":self.review_scroll_tick,"scrollTarget":self.review_scroll_target,"barIndex":self.review_bar_index}})
    }
    fn reconcile(&mut self, (generation, has_source): (u64, bool)) -> bool {
        if self.closed || (self.generation == generation && self.has_source == has_source) {
            return false;
        }
        self.generation = generation;
        self.has_source = has_source;
        self.playing_line = None;
        self.review.stop();
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
        self.review.stop();
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
    static PLAYER: std::cell::RefCell<Option<(std::path::PathBuf, madi_platform::line_playback::Player)>> = const { std::cell::RefCell::new(None) };
}

fn reconcile(app: &tauri::AppHandle) -> Result<(u64, bool), String> {
    // Read the current owner snapshot on main, not the potentially stale event
    // that queued this operation. Its watch value precedes its changed callback.
    let source = app.state::<FilesHost>().playback_identity();
    let host = app.state::<PlaybackHost>();
    let (changed, status, identity) = {
        let mut state = host.0.lock().map_err(|_| "playback state unavailable")?;
        {
            let changed = state.reconcile(source);
            (
                changed,
                changed.then(|| state.value()),
                (state.generation, state.has_source),
            )
        }
    };
    if changed {
        // Release without the status lock: destruction publishes a final stop.
        // That old generation is already invalid and cannot replace new state.
        #[cfg(target_os = "macos")]
        PLAYER.with(|slot| drop(slot.borrow_mut().take()));
        let _ = app.emit_to("main", "playback-changed", status.unwrap());
    }
    Ok(identity)
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
        let _ = sender.try_send(reconcile(&owner).and_then(|_| status_value(&owner)));
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
                if reconcile(&owner)? != (generation, true) {
                    return Ok(());
                }
                play(&owner, generation, &path, line, from, to, false)
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
fn status_value(app: &tauri::AppHandle) -> Result<Value, String> {
    app.state::<PlaybackHost>()
        .0
        .lock()
        .map(|s| s.value())
        .map_err(|_| "playback state unavailable".into())
}
#[cfg(target_os = "macos")]
fn native_changed(app: &tauri::AppHandle, generation: u64, line: Option<Uuid>) {
    let host = app.state::<PlaybackHost>();
    let (value, next) = {
        let Ok(mut state) = host.0.lock() else {
            return;
        };
        let Some(reaction) = state.playback_changed(generation, line) else {
            return;
        };
        reaction
    };
    let _ = app.emit_to("main", "playback-changed", value);
    if let Some((revision, span)) = next {
        let owner = app.clone();
        // Leave the current Swift callback/TLS borrow before starting the next
        // span. No timer drives review; only an observed currentLine -> nil does.
        tauri::async_runtime::spawn(async move {
            let events = owner.clone();
            let _ = owner.run_on_main_thread(move || {
                let result = (|| {
                    if reconcile(&events)? != (generation, true) {
                        return Ok(());
                    }
                    let valid = events
                        .state::<PlaybackHost>()
                        .0
                        .lock()
                        .map_err(|_| "playback state unavailable")?
                        .review_ticket_valid(revision, &span);
                    if !valid {
                        return Ok(());
                    }
                    let path = PLAYER.with(|p| p.borrow().as_ref().map(|(path, _)| path.clone()));
                    if let Some(path) = path {
                        play(
                            &events,
                            generation,
                            &path,
                            span.line_id,
                            span.t0,
                            span.t1,
                            true,
                        )?;
                    }
                    Ok::<(), String>(())
                })();
                if let Err(error) = result {
                    eprintln!("listen review: {error}");
                }
            });
        });
    }
}
impl Status {
    #[cfg(any(target_os = "macos", test))]
    fn playback_changed(
        &mut self,
        generation: u64,
        line: Option<Uuid>,
    ) -> Option<(Value, Option<(u64, Span)>)> {
        let ended = self.playing_line.is_some() && line.is_none();
        if !self.changed(generation, line) || self.restarting {
            return None;
        }
        let next = if ended && self.review_visible && self.review.is_listening {
            let span = self.review.advance();
            self.sync_review();
            span.map(|span| (self.revision, span))
        } else {
            None
        };
        Some((self.value(), next))
    }
    #[cfg(any(target_os = "macos", test))]
    fn review_ticket_valid(&self, revision: u64, span: &Span) -> bool {
        !self.closed
            && self.has_source
            && self.review_visible
            && self.review.is_listening
            && self.revision == revision
            && self.review.current() == Some(span)
    }
}
#[cfg(target_os = "macos")]
fn play(
    app: &tauri::AppHandle,
    generation: u64,
    path: &std::path::Path,
    line: Uuid,
    from: f64,
    to: f64,
    restart: bool,
) -> Result<(), String> {
    if restart {
        app.state::<PlaybackHost>()
            .0
            .lock()
            .map_err(|_| "playback state unavailable")?
            .restarting = true;
    }
    let result = PLAYER.with(|slot| {
        let mut slot = slot.borrow_mut();
        if slot.is_none() {
            let events = app.clone();
            *slot = Some((
                path.to_owned(),
                madi_platform::line_playback::Player::new(move |line| {
                    native_changed(&events, generation, line)
                })
                .map_err(str::to_owned)?,
            ));
        }
        let (_, player) = slot.as_mut().expect("player created");
        if restart {
            player.stop();
        }
        player.toggle(path, line, from, to).map_err(str::to_owned)
    });
    if restart {
        app.state::<PlaybackHost>()
            .0
            .lock()
            .map_err(|_| "playback state unavailable")?
            .restarting = false;
        let _ = app.emit_to("main", "playback-changed", status_value(app)?);
    }
    result
}

#[tauri::command]
pub async fn review_command(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    generation: u64,
    command: ReviewCommand,
) -> Result<(), String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    let needs_queue = matches!(
        command,
        ReviewCommand::Toggle
            | ReviewCommand::Jump { .. }
            | ReviewCommand::Visibility { visible: true }
    );
    let input = if needs_queue {
        let Some(input) = crate::files_host::service(&app)?
            .review_input(generation)
            .await
            .map_err(|e| e.to_string())?
        else {
            return Ok(());
        };
        Some(input)
    } else {
        None
    };
    let (sender, mut receiver) = tauri::async_runtime::channel(1);
    let owner = app.clone();
    app.run_on_main_thread(move || {
        let result = (|| {
            if reconcile(&owner)?.0 != generation {
                return Ok(());
            }
            let host = owner.state::<PlaybackHost>();
            let (span, stop, source) = {
                let mut state = host.0.lock().map_err(|_| "playback state unavailable")?;
                if state.closed {
                    return Ok(());
                }
                let mut span = None;
                let mut stop = false;
                let source = input.as_ref().and_then(|v| v.source.clone());
                match command {
                    ReviewCommand::Visibility { visible } => {
                        state.review_visible = visible;
                        if let Some(input) = input {
                            let before = state.review.index;
                            state.review.refresh(input.queue);
                            if state.review.index != before {
                                state.sync_review();
                            }
                        }
                    }
                    ReviewCommand::Toggle => {
                        state.review.refresh(input.expect("queue requested").queue);
                        let can_play = state.has_source && source.is_some();
                        span = state.review.toggle_listening(can_play);
                        if span.is_some() {
                            state.sync_review();
                        } else {
                            stop = true;
                        }
                    }
                    ReviewCommand::Jump { delta } => {
                        let flagged = input.expect("queue requested").flagged;
                        stop = state.jump_review_bar(delta, &flagged);
                    }
                    ReviewCommand::Stop => {
                        state.review.stop();
                        stop = true;
                    }
                }
                state.revision += 1;
                (span, stop, source)
            };
            let _ = owner.emit_to("main", "playback-changed", status_value(&owner)?);
            #[cfg(target_os = "macos")]
            {
                if stop {
                    PLAYER.with(|p| {
                        if let Some((_, p)) = p.borrow_mut().as_mut() {
                            p.stop();
                        }
                    });
                }
                if let (Some(span), Some(path)) = (span, source) {
                    play(
                        &owner,
                        generation,
                        &path,
                        span.line_id,
                        span.t0,
                        span.t1,
                        true,
                    )?;
                }
            }
            #[cfg(not(target_os = "macos"))]
            let _ = (span, stop, source);
            Ok(())
        })();
        let _ = sender.try_send(result);
    })
    .map_err(|e| e.to_string())?;
    receiver.recv().await.ok_or("review host stopped")?
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
    fn review_boundaries_advance_once_and_hidden_or_retired_work_never_autoplays() {
        let mut state = Status::default();
        state.reconcile((1, true));
        state.review_visible = true;
        let id = Uuid::from_u128(1);
        let spans: Vec<_> = (0..3)
            .map(|i| Span {
                line_id: id,
                word_index: i,
                text: format!("word {i}"),
                t0: i as f64,
                t1: i as f64 + 0.2,
            })
            .collect();
        state.review.refresh(spans.clone());
        assert_eq!(state.review.toggle_listening(true), Some(spans[0].clone()));
        assert!(state.playback_changed(1, Some(id)).unwrap().1.is_none());
        let (_, next) = state.playback_changed(1, None).unwrap();
        let (ticket, span) = next.unwrap();
        assert_eq!(span, spans[1]);
        assert_eq!(state.review_bar_index, 1);
        assert!(state.review_ticket_valid(ticket, &span));
        state.restarting = true;
        assert!(state.playback_changed(1, None).is_none());
        assert!(state.playback_changed(1, Some(id)).is_none());
        state.restarting = false;
        assert_eq!(state.review.index, 1); // stop/start of the same line is one review span
        state.restarting = true;
        assert!(state.playback_changed(1, None).is_none());
        assert!(state.playback_changed(1, Some(id)).is_none());
        state.restarting = false;
        assert_eq!(state.review.index, 1); // explicit stop of an active span is coalesced
        let (_, next) = state.playback_changed(1, None).unwrap();
        let (ticket, span) = next.unwrap();
        assert_eq!(span, spans[2]);
        state.review_visible = false;
        assert!(!state.review_ticket_valid(ticket, &span));
        state.playback_changed(1, Some(id));
        assert!(state.playback_changed(1, None).unwrap().1.is_none());
        assert!(state.review.is_listening); // disappeared SwiftUI observer does not advance
        state.review_visible = true;
        state.playback_changed(1, Some(id));
        assert!(state.playback_changed(1, None).unwrap().1.is_none());
        assert!(!state.review.is_listening); // final word stops without wrapping
        state.review.toggle_listening(true);
        state.reconcile((2, true));
        assert!(!state.review.is_listening);
        assert!(state.playback_changed(1, None).is_none());
        assert!(!state.review_ticket_valid(ticket, &span));
    }
    #[test]
    fn manual_bar_jump_preserves_the_separate_listening_cursor() {
        let flagged: Vec<_> = (0..3)
            .map(|i| Span {
                line_id: Uuid::from_u128(i + 1),
                word_index: 0,
                text: format!("word {i}"),
                t0: i as f64,
                t1: i as f64 + 0.2,
            })
            .collect();
        let mut state = Status::default();
        state.review.refresh(flagged.clone());
        state.review.toggle_listening(true);
        state.review.advance();
        state.sync_review();
        assert_eq!(state.review_bar_index, 1);
        assert!(state.jump_review_bar(1, &flagged));
        assert_eq!(state.review_bar_index, 2);
        assert_eq!(state.review.index, 1);
        assert!(!state.review.is_listening);
        assert_eq!(state.review_scroll_target, Some(flagged[2].line_id));
        assert!(state.jump_review_bar(1, &flagged));
        assert_eq!(state.review_bar_index, 0);
        assert_eq!(
            state.review.toggle_listening(true),
            Some(flagged[1].clone())
        );
        state.sync_review();
        assert_eq!(state.review_bar_index, 1);
        assert!(!state.jump_review_bar(-1, &[]));
        assert!(state.review.is_listening);
    }
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
