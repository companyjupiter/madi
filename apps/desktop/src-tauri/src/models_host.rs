use madi_core::model_setup::ModelSetupCommand;
use madi_platform::model_setup_service::{ModelSetupService, ModelSnapshot};
use std::sync::atomic::{AtomicU8, Ordering};
#[cfg(target_os = "macos")]
use tauri::Emitter;
use tauri::Manager;

pub struct ModelsHost {
    service: Option<ModelSetupService>,
    #[cfg(target_os = "macos")]
    artwork: std::sync::OnceLock<serde_json::Value>,
    shutdown: AtomicU8,
}

pub fn install(app: &mut tauri::App) -> Result<(), Box<dyn std::error::Error>> {
    #[cfg(target_os = "macos")]
    let host = {
        use madi_platform::{model_assets::Locations, model_presentation};
        let executable = std::env::current_exe()?;
        let locations = Locations {
            bundle_resources: app.path().resource_dir()?,
            bundle_executables: executable
                .parent()
                .ok_or("host executable directory missing")?
                .to_owned(),
            support: app.path().data_dir()?.join("Madi"),
        };
        let events = app.handle().clone();
        let service = ModelSetupService::new(
            locations,
            model_presentation::physical_memory(),
            std::env::var("MADI_TRANSLATE_MODEL").ok().as_deref(),
            model_presentation::file_size,
            move |snapshot| {
                let _ = events.emit_to("main", "models-changed", snapshot);
            },
        );
        ModelsHost {
            service: Some(service),
            artwork: std::sync::OnceLock::new(),
            shutdown: AtomicU8::new(0),
        }
    };
    // Windows remains the explicit setup parity harness until its native model/
    // ASR integration exists. Do not start macOS model downloads on that host.
    #[cfg(not(target_os = "macos"))]
    let host = ModelsHost {
        service: None,
        shutdown: AtomicU8::new(0),
    };
    app.manage(host);
    Ok(())
}

#[tauri::command]
pub async fn models_snapshot(
    window: tauri::WebviewWindow,
    host: tauri::State<'_, ModelsHost>,
) -> Result<Option<ModelSnapshot>, String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    Ok(match &host.service {
        Some(service) => Some(service.snapshot().await),
        None => None,
    })
}

#[tauri::command]
pub async fn models_artwork(
    window: tauri::WebviewWindow,
    app: tauri::AppHandle,
    host: tauri::State<'_, ModelsHost>,
) -> Result<serde_json::Value, String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    #[cfg(target_os = "macos")]
    {
        if let Some(artwork) = host.artwork.get() {
            return Ok(artwork.clone());
        }
        let (sender, mut receiver) = tauri::async_runtime::channel(1);
        let owner = app.clone();
        app.run_on_main_thread(move || {
            let host = owner.state::<ModelsHost>();
            let result = (|| {
                if let Some(artwork) = host.artwork.get() {
                    return Ok(artwork.clone());
                }
                let symbols = madi_platform::model_presentation::artwork()?;
                let value = serde_json::to_value(symbols).map_err(|error| error.to_string())?;
                let _ = host.artwork.set(value.clone());
                Ok(value)
            })();
            let _ = sender.try_send(result);
        })
        .map_err(|error| error.to_string())?;
        receiver.recv().await.ok_or("artwork worker stopped")?
    }
    #[cfg(not(target_os = "macos"))]
    {
        let _ = (app, host);
        Ok(serde_json::Value::Null)
    }
}

#[tauri::command]
pub async fn models_command(
    window: tauri::WebviewWindow,
    host: tauri::State<'_, ModelsHost>,
    command: ModelSetupCommand,
) -> Result<ModelSnapshot, String> {
    if window.label() != "main" {
        return Err("unsupported window".into());
    }
    host.service
        .as_ref()
        .ok_or("native model setup is unsupported on this platform")?
        .command(command)
        .await
}

pub fn on_run_event(app: &tauri::AppHandle, event: &tauri::RunEvent) {
    let tauri::RunEvent::ExitRequested { api, code, .. } = event else {
        return;
    };
    let Some(host) = app.try_state::<ModelsHost>() else {
        return;
    };
    let Some(service) = &host.service else { return };
    match host
        .shutdown
        .compare_exchange(0, 1, Ordering::AcqRel, Ordering::Acquire)
    {
        Ok(_) => api.prevent_exit(),
        Err(2) => return,
        Err(_) => {
            api.prevent_exit();
            return;
        }
    }
    let service = service.clone();
    let app = app.clone();
    let code = code.unwrap_or(0);
    tauri::async_runtime::spawn(async move {
        if let Err(error) = app.state::<crate::files_host::FilesHost>().shutdown().await {
            eprintln!("file shutdown: {error}");
        }
        if let Err(error) = service.shutdown().await {
            eprintln!("model shutdown: {error}");
        }
        app.state::<ModelsHost>()
            .shutdown
            .store(2, Ordering::Release);
        app.exit(code);
    });
}
