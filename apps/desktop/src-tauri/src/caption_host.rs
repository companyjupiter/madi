//! Minimal caption projections; transcript edits, paths and model controls stay
//! in their existing owners. AppKit panel operations run only on the main thread.
use madi_core::{
    caption::{self, Audience},
    transcript::Line,
};
use madi_platform::{
    file_workflow::Snapshot as FileSnapshot, preferences_service::Snapshot as Preferences,
};
use serde_json::{Value, json};
use std::{collections::BTreeMap, sync::Mutex};
use tauri::{Emitter, Manager};
mod native;

#[derive(Default)]
struct State {
    revision: u64,
    enabled: bool,
    failed: bool,
    layout_dirty: bool,
    preferences: Option<Preferences>,
    file: Option<Source>,
    artwork: Option<Value>,
}
impl State {
    fn preferences_changed(&mut self, value: &Preferences) -> bool {
        if self
            .preferences
            .as_ref()
            .is_some_and(|p| p.revision > value.revision)
        {
            return false;
        }
        self.layout_dirty |= self
            .preferences
            .as_ref()
            .is_none_or(|p| p.settings.caption != value.settings.caption);
        if value.setup.translate_targets.is_empty() {
            self.enabled = false;
        }
        self.preferences = Some(value.clone());
        self.revision += 1;
        true
    }
    fn file_changed(&mut self, value: &FileSnapshot) -> bool {
        if self
            .file
            .as_ref()
            .is_some_and(|p| p.revision > value.revision)
        {
            return false;
        }
        self.file = Some(Source::from_snapshot(value));
        self.revision += 1;
        self.enabled
    }
    fn toggle(&mut self, preferences: &Preferences) {
        // A preference callback can arrive between snapshot() and this lock.
        // Keep the newest owner revision, including a newly disabled target.
        self.preferences_changed(preferences);
        self.enabled = !self.enabled
            && self
                .preferences
                .as_ref()
                .is_some_and(|p| !p.setup.translate_targets.is_empty());
        self.layout_dirty = true;
        self.failed = false;
        self.revision += 1;
    }
    fn fail(&mut self) {
        self.enabled = false;
        self.failed = true;
        self.layout_dirty = true;
        self.revision += 1;
    }
}
#[derive(Default)]
pub struct CaptionHost(Mutex<State>);
struct Source {
    revision: u64,
    lines: Vec<Line>,
    partial: String,
    names: BTreeMap<i64, String>,
    numbers: BTreeMap<i64, u64>,
    level: f32,
}
impl Source {
    fn from_snapshot(value: &FileSnapshot) -> Self {
        // CaptionOverlay consults only the newest translated line and real tail.
        // Retain that bounded projection instead of duplicating the full archive.
        let mut lines = Vec::new();
        if let Some(latest) = value
            .lines
            .iter()
            .rev()
            .find(|l| !l.line.translations.is_empty())
            && value
                .lines
                .last()
                .is_some_and(|last| last.line.id != latest.line.id)
        {
            lines.push(latest.line.clone());
        }
        if let Some(last) = value.lines.last() {
            lines.push(last.line.clone());
        }
        Self {
            revision: value.revision,
            lines,
            partial: value.partial.clone(),
            names: value.speaker_names.clone(),
            numbers: value.speaker_numbers.numbers.clone(),
            level: value.live.as_ref().map_or(0.0, |s| s.meter),
        }
    }
}
fn main_window(window: &tauri::WebviewWindow) -> Result<(), String> {
    if window.label() == "main" {
        Ok(())
    } else {
        Err("unsupported window".into())
    }
}
fn audience(label: &str) -> Result<Audience, String> {
    match label {
        "caption-staff" => Ok(Audience::Staff),
        "caption-patient" => Ok(Audience::Patient),
        _ => Err("unsupported caption window".into()),
    }
}
fn status(state: &State) -> Value {
    json!({"revision":state.revision,"enabled":state.enabled,"failed":state.failed})
}
fn payload(state: &State, audience: Audience) -> Option<Value> {
    let preferences = state.preferences.as_ref()?;
    let empty_names = Default::default();
    let empty_numbers = Default::default();
    let empty_interim = Default::default();
    let context = caption::Context {
        audience,
        targets: &preferences.setup.translate_targets,
        settings: &preferences.settings.caption,
        ui_language: preferences.presentation.ui_language,
        partial: state.file.as_ref().map_or("", |s| s.partial.as_str()),
        interim_translations: &empty_interim,
        interim_source: "",
        names: state.file.as_ref().map_or(&empty_names, |s| &s.names),
        numbers: state.file.as_ref().map_or(&empty_numbers, |s| &s.numbers),
        level: state.file.as_ref().map_or(0.0, |s| s.level),
    };
    let lines = state.file.as_ref().map_or(&[][..], |s| s.lines.as_slice());
    Some(json!({
        "revision":state.revision, "enabled":state.enabled, "audience":audience,
        "uiLanguage":preferences.presentation.ui_language,
        "settings":preferences.settings.caption, "projection":caption::project(&context, lines.iter()),
        "artwork":state.artwork,
    }))
}
fn dispatch(app: &tauri::AppHandle) {
    let events = app.clone();
    if let Err(error) = app.run_on_main_thread(move || {
        if let Err(error) = refresh(&events) {
            eprintln!("caption panel: {error}");
        }
    }) {
        eprintln!("caption dispatch: {error}");
    }
}
pub fn preferences_changed(app: &tauri::AppHandle, value: &Preferences) {
    let host = app.state::<CaptionHost>();
    if !host
        .0
        .lock()
        .is_ok_and(|mut state| state.preferences_changed(value))
    {
        return;
    }
    dispatch(app);
}
pub fn file_changed(app: &tauri::AppHandle, value: &FileSnapshot) {
    let host = app.state::<CaptionHost>();
    if !host
        .0
        .lock()
        .is_ok_and(|mut state| state.file_changed(value))
    {
        return;
    }
    dispatch(app);
}
fn refresh(app: &tauri::AppHandle) -> Result<(), String> {
    let result = refresh_panels(app);
    if result.is_err() {
        // A failed patient-panel creation must not leave the staff button on
        // or retry creation on every microphone/translation callback.
        let summary = {
            let host = app.state::<CaptionHost>();
            let mut state = host.0.lock().map_err(|_| "caption state unavailable")?;
            state.fail();
            status(&state)
        };
        for label in ["caption-staff", "caption-patient"] {
            let _ = native::hide(app, label);
        }
        let _ = app.emit_to("main", "caption-status-changed", summary);
    }
    result
}
fn refresh_panels(app: &tauri::AppHandle) -> Result<(), String> {
    let (enabled, layout, settings, staff, patient, summary) = {
        let host = app.state::<CaptionHost>();
        let mut state = host.0.lock().map_err(|_| "caption state unavailable")?;
        if state.artwork.is_none() {
            state.artwork = native::artwork()?;
        }
        let layout = std::mem::take(&mut state.layout_dirty);
        (
            state.enabled,
            layout,
            state
                .preferences
                .as_ref()
                .map(|p| p.settings.caption.clone()),
            payload(&state, Audience::Staff),
            payload(&state, Audience::Patient),
            status(&state),
        )
    };
    app.emit_to("main", "caption-status-changed", summary)
        .map_err(|e| e.to_string())?;
    for (label, audience, value) in [
        ("caption-staff", Audience::Staff, staff),
        ("caption-patient", Audience::Patient, patient),
    ] {
        let show = enabled
            && settings
                .as_ref()
                .is_some_and(|s| audience == Audience::Staff || s.patient_panel_enabled);
        if !show {
            native::hide(app, label)?;
            continue;
        }
        native::show(app, label, audience, settings.as_ref().unwrap(), layout)?;
        if let Some(value) = value {
            app.emit_to(label, "caption-changed", value)
                .map_err(|e| e.to_string())?;
        }
    }
    Ok(())
}
#[tauri::command]
pub async fn caption_status(window: tauri::WebviewWindow) -> Result<Value, String> {
    main_window(&window)?;
    let host = window.state::<CaptionHost>();
    let state = host.0.lock().map_err(|_| "caption state unavailable")?;
    Ok(status(&state))
}
#[tauri::command]
pub async fn caption_toggle(window: tauri::WebviewWindow) -> Result<Value, String> {
    main_window(&window)?;
    let preferences = crate::setup_host::service(window.app_handle())
        .await?
        .snapshot();
    {
        let host = window.state::<CaptionHost>();
        let mut state = host.0.lock().map_err(|_| "caption state unavailable")?;
        state.toggle(&preferences);
    }
    let (sender, mut receiver) = tauri::async_runtime::channel(1);
    let app = window.app_handle().clone();
    window
        .app_handle()
        .run_on_main_thread(move || {
            let result = refresh(&app);
            let _ = sender.try_send(result);
        })
        .map_err(|e| e.to_string())?;
    receiver.recv().await.ok_or("caption refresh ended")??;
    caption_status(window).await
}
#[tauri::command]
pub async fn caption_snapshot(window: tauri::WebviewWindow) -> Result<Value, String> {
    let audience = audience(window.label())?;
    let host = window.state::<CaptionHost>();
    let state = host.0.lock().map_err(|_| "caption state unavailable")?;
    payload(&state, audience).ok_or("caption preferences unavailable".into())
}
#[tauri::command]
pub async fn caption_close(window: tauri::WebviewWindow) -> Result<(), String> {
    if window.label() != "caption-staff" {
        return Err("unsupported caption close".into());
    }
    {
        let host = window.state::<CaptionHost>();
        let mut state = host.0.lock().map_err(|_| "caption state unavailable")?;
        state.enabled = false;
        state.revision += 1;
    }
    dispatch(window.app_handle());
    Ok(())
}
#[tauri::command]
pub async fn caption_resize(window: tauri::WebviewWindow, height: f64) -> Result<(), String> {
    audience(window.label())?;
    if !height.is_finite() || !(80.0..=600.0).contains(&height) {
        return Err("invalid caption height".into());
    }
    let app = window.app_handle().clone();
    let label = window.label().to_owned();
    window
        .app_handle()
        .run_on_main_thread(move || {
            if let Err(error) = native::resize(&app, &label, height) {
                eprintln!("caption size: {error}");
            }
        })
        .map_err(|e| e.to_string())
}

#[cfg(test)]
mod tests {
    use super::*;
    use madi_core::{
        preferences::Presentation, settings::Settings, setup::SetupState, transcript::Uuid,
    };
    use madi_platform::file_workflow::DisplayLine;

    fn preferences(revision: u64, targets: &[&str]) -> Preferences {
        Preferences {
            revision,
            setup: SetupState {
                translate_targets: targets.iter().map(|s| (*s).into()).collect(),
                ..Default::default()
            },
            presentation: Presentation::default(),
            settings: Settings::default(),
            effective_window_seconds: 8.0,
            multi_translate_forces_accurate: false,
        }
    }
    fn line(index: u128, translated: bool) -> DisplayLine {
        let text = format!("source {index}");
        DisplayLine {
            text: text.clone(),
            source_revision: "unused".into(),
            line: Line {
                id: Uuid::from_u128(index),
                speaker: 7,
                start: index as f64,
                end: index as f64 + 1.0,
                words: vec![],
                overlap_speakers: vec![],
                speaker_margin: 0.2,
                translations: if translated {
                    BTreeMap::from([
                        ("English".into(), format!("translation {index}")),
                        ("Japanese".into(), format!("日本語 {index}")),
                    ])
                } else {
                    Default::default()
                },
                stale_translations: Default::default(),
                edited_translations: Default::default(),
                suppressed_translations: Default::default(),
                edited_text: Some(text),
            },
        }
    }
    #[test]
    fn projection_retains_real_tail_age_and_viewer_language_without_archive_paths() {
        let mut snapshot = FileSnapshot {
            revision: 8,
            lines: (0..500).map(|i| line(i, i == 4 || i == 80)).collect(),
            speaker_names: BTreeMap::from([(3, "other".into())]),
            partial: "new audio".into(),
            ..Default::default()
        };
        snapshot.archive.transcript = Some("private/archive.md".into());
        let mut p = preferences(1, &["Korean", "English", "Japanese"]);
        p.settings.caption.patient_lang_override = Some("Japanese".into());
        let mut state = State {
            preferences: Some(p),
            file: Some(Source::from_snapshot(&snapshot)),
            ..Default::default()
        };
        assert_eq!(state.file.as_ref().unwrap().lines.len(), 2);
        let staff = payload(&state, Audience::Staff).unwrap();
        assert_eq!(
            staff["projection"]["caption"]["translation"],
            "translation 80"
        );
        assert_eq!(staff["projection"]["caption"]["age"], 419.0);
        assert_eq!(staff["projection"]["speakerLabel"], "화자 7");
        assert_eq!(
            payload(&state, Audience::Patient).unwrap()["projection"]["caption"]["translation"],
            "日本語 80"
        );
        assert!(!staff.to_string().contains("private/archive.md"));
        state.file.as_mut().unwrap().lines = snapshot.lines.into_iter().map(|l| l.line).collect();
        assert_eq!(
            staff,
            payload(&state, Audience::Staff).unwrap(),
            "bounded projection must equal full history"
        );
    }
    #[test]
    fn late_callbacks_cannot_restore_hidden_captions_or_old_translation() {
        let mut state = State::default();
        let earlier = preferences(1, &["English"]);
        state.toggle(&earlier);
        assert!(state.enabled);
        state.preferences_changed(&preferences(2, &[]));
        assert!(!state.enabled);
        state.toggle(&earlier);
        assert!(
            !state.enabled,
            "stale toggle snapshot cannot resurrect disabled targets"
        );
        assert_eq!(state.preferences.as_ref().unwrap().revision, 2);
        let fresh = FileSnapshot {
            revision: 10,
            lines: vec![line(10, true)],
            ..Default::default()
        };
        assert!(
            !state.file_changed(&fresh),
            "hidden panels update their source without scheduling a show"
        );
        let old = FileSnapshot {
            revision: 9,
            lines: vec![line(9, true)],
            ..Default::default()
        };
        assert!(!state.file_changed(&old));
        state.toggle(&preferences(3, &["English"]));
        assert!(state.enabled);
        assert_eq!(
            payload(&state, Audience::Staff).unwrap()["projection"]["caption"]["translation"],
            "translation 10"
        );
    }
    #[test]
    fn projection_has_no_interim_producer_and_empty_selected_value_stays_empty() {
        let mut snapshot = FileSnapshot {
            lines: vec![line(1, true), line(2, true)],
            partial: "live preview".into(),
            ..Default::default()
        };
        snapshot.lines[1]
            .line
            .translations
            .insert("English".into(), String::new());
        let state = State {
            preferences: Some(preferences(1, &["English"])),
            file: Some(Source::from_snapshot(&snapshot)),
            ..Default::default()
        };
        let value = payload(&state, Audience::Staff).unwrap();
        assert_eq!(value["projection"]["caption"], Value::Null);
        assert_eq!(value["projection"]["preview"], "live preview");
        assert_eq!(value["projection"]["status"], "translating");
        assert_eq!(state.file.as_ref().unwrap().lines.len(), 1);
    }
    #[test]
    fn audience_is_owned_by_the_calling_window() {
        assert_eq!(audience("caption-staff").unwrap(), Audience::Staff);
        assert_eq!(audience("caption-patient").unwrap(), Audience::Patient);
        for label in ["main", "settings", "caption", "caption-patient-1", ""] {
            assert!(audience(label).is_err());
        }
    }
    #[test]
    fn panel_failure_stops_automatic_reopening_until_explicit_toggle() {
        let mut state = State::default();
        let p = preferences(1, &["English"]);
        state.toggle(&p);
        state.fail();
        assert_eq!(status(&state)["failed"], true);
        assert!(!state.file_changed(&FileSnapshot::default()));
        state.preferences_changed(&preferences(2, &["Japanese"]));
        assert!(!state.enabled);
        state.toggle(&preferences(2, &["Japanese"]));
        assert!(state.enabled);
        assert!(!state.failed);
    }
}
