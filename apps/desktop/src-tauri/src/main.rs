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
use tauri::Manager;
mod files_host;
mod models_host;
mod setup_host;
mod workspace_host;
use files_host::{
    FilesHost, file_artwork, file_copy_line, file_edit, file_rename_speaker, file_reset,
    file_snapshot, file_start,
};
use models_host::{models_artwork, models_command, models_snapshot};
use setup_host::{
    SetupHost, choose_file, preferences_command, preferences_snapshot, settings_command,
};
use workspace_host::{
    WorkspaceHost, workspace_choose_folder, workspace_command, workspace_export, workspace_open,
    workspace_snapshot,
};

#[cfg(target_os = "macos")]
fn configure_macos_window(window: &tauri::WebviewWindow, setup: bool) -> tauri::Result<()> {
    // SwiftUI's reference window measures 1150x710 points including its titlebar.
    // Tauri Transparent uses a separate content rectangle. Measure the native
    // chrome instead of baking in this Mac's observed 33-point titlebar.
    let scale = window.scale_factor()?;
    let outer = window.outer_size()?;
    let inner = window.inner_size()?;
    let chrome_height = outer.height.saturating_sub(inner.height) as f64 / scale;
    let (width, height) = window
        .current_monitor()?
        .map(|monitor| {
            let visible = monitor
                .work_area()
                .size
                .to_logical::<f64>(monitor.scale_factor());
            (
                1150.0_f64.min(visible.width - 60.0),
                710.0_f64.min(visible.height - 60.0),
            )
        })
        .unwrap_or((1150.0, 710.0));
    let (min_width, min_height) = if setup {
        (980.0, 640.0)
    } else {
        (760.0, 520.0)
    };
    window.set_min_size(Some(tauri::LogicalSize::new(
        min_width,
        min_height - chrome_height,
    )))?;
    window.set_size(tauri::LogicalSize::new(width, height - chrome_height))?;
    window.center()?;
    set_macos_background(window, window.theme()?)?;
    Ok(())
}

#[cfg(target_os = "macos")]
fn set_macos_background(window: &tauri::WebviewWindow, theme: tauri::Theme) -> tauri::Result<()> {
    // AppKit controlBackgroundColor values captured by ThemeOracle.swift.
    let channel = if theme == tauri::Theme::Dark { 30 } else { 255 };
    window.set_background_color(Some(tauri::window::Color(channel, channel, channel, 255)))
}

#[tauri::command]
async fn setup_snapshot(window: tauri::WebviewWindow) -> Result<SetupState, String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    Ok(setup_host::service(window.app_handle())
        .await?
        .snapshot()
        .setup)
}
#[tauri::command]
async fn setup_command(
    window: tauri::WebviewWindow,
    command: SetupCommand,
) -> Result<SetupState, String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    setup_host::service(window.app_handle())
        .await?
        .setup(command)
        .await
        .map(|value| value.setup)
        .map_err(|error| error.to_string())
}

#[tauri::command]
fn audio_inputs(
    window: tauri::WebviewWindow,
) -> Result<madi_platform::audio_devices::InputDevices, String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    Ok(madi_platform::audio_devices::snapshot())
}

fn main() {
    #[cfg(target_os = "macos")]
    if std::env::args_os().skip(1).eq(["--runtime-layout"]) {
        match madi_platform::runtime_bundle::bundled() {
            Ok(layout) => println!(
                "{}",
                serde_json::to_string(&layout).expect("runtime path JSON")
            ),
            Err(error) => {
                eprintln!("{error}");
                std::process::exit(1);
            }
        }
        return;
    }
    // Headless package check: resolve exactly what the installed runtime will
    // launch, without creating an AppKit application or reading any user data.
    if std::env::args_os().skip(1).eq(["--native-helper-path"]) {
        match madi_platform::prepared_audio::bundled_helper() {
            Ok(path) => println!("{}", path.display()),
            Err(error) => {
                eprintln!("{error}");
                std::process::exit(1);
            }
        }
        return;
    }
    tauri::Builder::default()
        .manage(SetupHost::default())
        .manage(FilesHost::default())
        .manage(WorkspaceHost::default())
        .on_webview_event(setup_host::handle_drop)
        .setup(|app| {
            models_host::install(app)?;
            let window = app
                .get_webview_window("main")
                .ok_or("main window missing")?;
            #[cfg(target_os = "macos")]
            {
                madi_platform::prepared_audio::bundled_helper()?;
                configure_macos_window(&window, true)?;
                let themed = window.clone();
                window.on_window_event(move |event| {
                    if let tauri::WindowEvent::ThemeChanged(_) = event {
                        let update = || -> Result<(), String> {
                            // Window events run on the main thread. Respect a
                            // saved per-window override when macOS theme changes.
                            let dark = unsafe {
                                madi_platform::preferences::window_is_dark(
                                    themed.ns_window().map_err(|error| error.to_string())?,
                                )
                            }?;
                            set_macos_background(
                                &themed,
                                if dark {
                                    tauri::Theme::Dark
                                } else {
                                    tauri::Theme::Light
                                },
                            )
                            .map_err(|error| error.to_string())
                        };
                        if let Err(error) = update() {
                            eprintln!("failed to update window background: {error}");
                        }
                    }
                });
            }
            let handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                if let Err(error) = setup_host::service(&handle).await {
                    eprintln!("preferences: {error}");
                }
                // Initial native appearance was queued before this show. A bad
                // preference file still opens the window to expose the error.
                let _ = handle.run_on_main_thread(move || {
                    let _ = window.show();
                });
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            settings_command,
            preferences_snapshot,
            preferences_command,
            setup_snapshot,
            setup_command,
            audio_inputs,
            choose_file,
            models_snapshot,
            models_command,
            models_artwork,
            file_snapshot,
            file_artwork,
            file_start,
            file_reset,
            file_edit,
            file_copy_line,
            file_rename_speaker,
            workspace_snapshot,
            workspace_command,
            workspace_choose_folder,
            workspace_open,
            workspace_export
        ])
        .build(tauri::generate_context!())
        .expect("failed to build Madi parity harness")
        .run(|app, event| models_host::on_run_event(app, &event));
}
