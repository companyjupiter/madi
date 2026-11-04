//! One native Settings window, backed by the same app-owned stores as main.
use madi_platform::model_setup_service::{ManagementCommand, ModelLocations, ModelSnapshot};
#[cfg(target_os = "macos")]
use tauri::Emitter;
use tauri::Manager;

pub fn known_window(window: &tauri::WebviewWindow) -> Result<(), String> {
    if matches!(window.label(), "main" | "settings") {
        Ok(())
    } else {
        Err("unsupported window".into())
    }
}
fn show(app: &tauri::AppHandle) -> Result<(), String> {
    let window = app
        .get_webview_window("settings")
        .ok_or("settings window unavailable")?;
    window
        .show()
        .and_then(|_| window.set_focus())
        .map_err(|error| error.to_string())
}
pub fn install(app: &mut tauri::App) -> tauri::Result<()> {
    let window = app
        .get_webview_window("settings")
        .expect("settings window configured");
    let hidden = window.clone();
    window.on_window_event(move |event| {
        if let tauri::WindowEvent::CloseRequested { api, .. } = event {
            api.prevent_close();
            let _ = hidden.hide();
        }
    });
    let menu = tauri::menu::Menu::default(app.handle())?;
    let item = tauri::menu::MenuItem::with_id(
        app,
        "madi-settings",
        "Settings…",
        true,
        Some("CmdOrCtrl+,"),
    )?;
    if let Some(tauri::menu::MenuItemKind::Submenu(first)) = menu.items()?.first() {
        first.insert(&item, 1)?;
    }
    app.set_menu(menu)?;
    app.on_menu_event(|app, event| {
        if event.id().as_ref() == "madi-settings"
            && let Err(error) = show(app)
        {
            eprintln!("settings: {error}");
        }
    });
    Ok(())
}
#[tauri::command]
pub async fn settings_open(window: tauri::WebviewWindow) -> Result<(), String> {
    known_window(&window)?;
    show(window.app_handle())
}
#[tauri::command]
pub async fn settings_metadata(window: tauri::WebviewWindow) -> Result<serde_json::Value, String> {
    known_window(&window)?;
    #[cfg(target_os = "macos")]
    {
        let translation = match &window.state::<crate::models_host::ModelsHost>().service {
            Some(service) => service.snapshot().await.state.translation_engine_available,
            None => false,
        };
        let preferences = crate::setup_host::service(window.app_handle())
            .await?
            .snapshot();
        let language = match preferences.presentation.ui_language {
            madi_core::preferences::UILanguage::Ko => "ko",
            madi_core::preferences::UILanguage::En => "en",
            madi_core::preferences::UILanguage::Ja => "ja",
        };
        let strings: serde_json::Value =
            serde_json::from_str(include_str!("../../src/settings-strings.generated.json"))
                .map_err(|error| error.to_string())?;
        let labels = ["Recording", "Save", "Translation", "Glossary", "Model"]
            .map(|key| strings[key][language].as_str().unwrap_or(key).to_owned());
        let (sender, mut receiver) = tauri::async_runtime::channel(1);
        let app = window.app_handle().clone();
        app.run_on_main_thread(move || {
            let result = (|| {
                let mut metadata = madi_platform::settings_native::metadata()?;
                if window.label() == "settings" {
                    let events = window.clone();
                    // The main-thread closure owns the live Tauri window.
                    unsafe {
                        madi_platform::settings_toolbar::configure(
                            window.ns_window().map_err(|error| error.to_string())?,
                            labels,
                            translation,
                            preferences.revision,
                            Box::new(move |tab| {
                                let _ = events.emit_to("settings", "settings-tab-changed", tab);
                            }),
                        )
                    }?;
                    metadata["nativeToolbar"] = true.into();
                }
                Ok::<_, String>(metadata)
            })();
            let _ = sender.try_send(result);
        })
        .map_err(|error| error.to_string())?;
        receiver
            .recv()
            .await
            .ok_or("settings metadata worker stopped")?
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(serde_json::json!({"screens":[],"artwork":null}))
    }
}
#[tauri::command]
pub async fn settings_model_locations(
    window: tauri::WebviewWindow,
) -> Result<Option<ModelLocations>, String> {
    known_window(&window)?;
    let host = window.state::<crate::models_host::ModelsHost>();
    match &host.service {
        Some(service) => Ok(Some(service.locations().await)),
        None => Ok(None),
    }
}
#[tauri::command]
pub async fn settings_models_command(
    window: tauri::WebviewWindow,
    command: ManagementCommand,
) -> Result<ModelSnapshot, String> {
    known_window(&window)?;
    window
        .state::<crate::models_host::ModelsHost>()
        .service
        .as_ref()
        .ok_or("native model management is unsupported on this platform")?
        .manage(command)
        .await
}
#[tauri::command]
pub async fn settings_reveal(
    window: tauri::WebviewWindow,
    destination: String,
) -> Result<(), String> {
    known_window(&window)?;
    #[cfg(target_os = "macos")]
    {
        let app = window.app_handle();
        let (path, select) = match destination.as_str() {
            "transcription" | "translation" => {
                let locations = settings_model_locations(window.clone())
                    .await?
                    .ok_or("native models unavailable")?;
                (
                    if destination == "translation" {
                        locations.translation
                    } else {
                        locations.transcription
                    },
                    true,
                )
            }
            "debug" => {
                let path = app
                    .path()
                    .data_dir()
                    .map_err(|error| error.to_string())?
                    .join("Madi/debug");
                std::fs::create_dir_all(&path).map_err(|error| error.to_string())?;
                (path, false)
            }
            _ => return Err("unknown settings destination".into()),
        };
        let (sender, mut receiver) = tauri::async_runtime::channel(1);
        app.run_on_main_thread(move || {
            let _ = sender.try_send(
                madi_platform::settings_native::reveal(&path, select)
                    .map_err(|error| error.to_string()),
            );
        })
        .map_err(|error| error.to_string())?;
        receiver.recv().await.ok_or("Finder worker stopped")?
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = destination;
        Err("native model reveal is unsupported on this platform".into())
    }
}
