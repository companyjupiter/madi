#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

#[cfg(not(debug_assertions))]
compile_error!(
    "The parity harness is not a product release. Complete the migration gates before enabling release builds."
);
#[cfg(not(feature = "parity-harness"))]
compile_error!(
    "The product runtime is not implemented yet; use the isolated parity-harness feature."
);

use madi_core::setup::{SetupCommand, SetupState};
use std::sync::Mutex;

#[tauri::command]
fn setup_snapshot(
    window: tauri::WebviewWindow,
    state: tauri::State<'_, Mutex<SetupState>>,
) -> Result<SetupState, String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    state
        .lock()
        .map(|state| state.clone())
        .map_err(|_| "setup state unavailable".into())
}

#[tauri::command]
fn setup_command(
    window: tauri::WebviewWindow,
    command: SetupCommand,
    state: tauri::State<'_, Mutex<SetupState>>,
) -> Result<SetupState, String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    let mut state = state
        .lock()
        .map_err(|_| "setup state unavailable".to_owned())?;
    state.apply(command)?;
    Ok(state.clone())
}

fn main() {
    tauri::Builder::default()
        .manage(Mutex::new(SetupState::default()))
        .invoke_handler(tauri::generate_handler![setup_snapshot, setup_command])
        .run(tauri::generate_context!())
        .expect("failed to run Madi parity harness");
}
