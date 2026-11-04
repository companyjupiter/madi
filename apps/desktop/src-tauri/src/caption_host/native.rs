use madi_core::{caption::Audience, settings::CaptionSettings};
use serde_json::Value;
#[cfg(not(target_os = "macos"))]
use tauri::Manager;

#[cfg(target_os = "macos")]
use tauri_nspanel::{
    CollectionBehavior, ManagerExt, PanelBuilder, PanelLevel, StyleMask, tauri_panel,
};
#[cfg(target_os = "macos")]
tauri_panel! { panel!(MadiCaptionPanel { config: { can_become_key_window:false,can_become_main_window:false,is_floating_panel:true } }) }

pub fn artwork() -> Result<Option<Value>, String> {
    #[cfg(target_os = "macos")]
    {
        Ok(Some(
            serde_json::to_value(
                madi_platform::model_presentation::caption_artwork().map_err(str::to_string)?,
            )
            .map_err(|e| e.to_string())?,
        ))
    }
    #[cfg(not(target_os = "macos"))]
    {
        Ok(None)
    }
}
pub fn hide(app: &tauri::AppHandle, label: &str) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        tauri_nspanel::objc2::MainThreadMarker::new().ok_or("caption must run on main thread")?;
        if let Ok(panel) = app.get_webview_panel(label) {
            panel.hide();
        }
        Ok(())
    }
    #[cfg(not(target_os = "macos"))]
    {
        if let Some(window) = app.get_webview_window(label) {
            window.hide().map_err(|e| e.to_string())?;
        }
        Ok(())
    }
}
pub fn show(
    app: &tauri::AppHandle,
    label: &str,
    audience: Audience,
    settings: &CaptionSettings,
    layout: bool,
) -> Result<(), String> {
    let width = if audience == Audience::Patient {
        settings.panel_width.max(900.0)
    } else {
        settings.panel_width
    };
    let initial_height = if audience == Audience::Patient {
        220.0
    } else {
        150.0
    };
    #[cfg(target_os = "macos")]
    {
        use tauri_nspanel::{
            objc2::MainThreadMarker, objc2_app_kit::NSScreen, objc2_foundation::NSPoint,
        };
        let mtm = MainThreadMarker::new().ok_or("caption must run on main thread")?;
        let created = app.get_webview_panel(label).is_err();
        let panel = if let Ok(panel) = app.get_webview_panel(label) {
            panel
        } else {
            PanelBuilder::<_, MadiCaptionPanel>::new(app, label)
                .url(tauri::WebviewUrl::App(format!("index.html#{label}").into()))
                .title("Madi captions")
                .size(tauri::LogicalSize::new(width, initial_height).into())
                .level(PanelLevel::Status)
                .floating(true)
                .opaque(false)
                .transparent(true)
                .has_shadow(false)
                .hides_on_deactivate(false)
                .movable_by_window_background(true)
                .style_mask(
                    StyleMask::new()
                        .borderless()
                        .nonactivating_panel()
                        .full_size_content_view(),
                )
                .collection_behavior(
                    CollectionBehavior::new()
                        .can_join_all_spaces()
                        .full_screen_auxiliary()
                        .stationary(),
                )
                .no_activate(true)
                .released_when_closed(false)
                .with_window(|builder| {
                    builder
                        .visible(false)
                        .focused(false)
                        .focusable(false)
                        .decorations(false)
                        .skip_taskbar(true)
                })
                .build()
                .map_err(|e| e.to_string())?
        };
        if created || layout || !panel.as_panel().isVisible() {
            let height = panel.as_panel().frame().size.height;
            panel.set_content_size(width, height);
            let screens = NSScreen::screens(mtm);
            let selected = if audience == Audience::Patient {
                settings
                    .patient_screen_index
                    .and_then(|i| usize::try_from(i).ok())
                    .filter(|&i| i < screens.count())
            } else {
                None
            };
            let screen = selected
                .map(|i| screens.objectAtIndex(i))
                .or_else(|| NSScreen::mainScreen(mtm));
            if let Some(screen) = screen {
                let frame = screen.visibleFrame();
                panel.as_panel().setFrameOrigin(NSPoint::new(
                    frame.origin.x + (frame.size.width - width) / 2.0,
                    frame.origin.y + 90.0,
                ));
            }
        }
        if !panel.as_panel().isVisible() {
            panel.show();
        }
        Ok(())
    }
    #[cfg(not(target_os = "macos"))]
    {
        let created = app.get_webview_window(label).is_none();
        let window = if let Some(window) = app.get_webview_window(label) {
            window
        } else {
            tauri::WebviewWindowBuilder::new(
                app,
                label,
                tauri::WebviewUrl::App(format!("index.html#{label}").into()),
            )
            .title("Madi captions")
            .inner_size(width, initial_height)
            .transparent(true)
            .decorations(false)
            .shadow(false)
            .always_on_top(true)
            .visible_on_all_workspaces(true)
            .skip_taskbar(true)
            .focused(false)
            .focusable(false)
            .visible(false)
            .resizable(false)
            .build()
            .map_err(|e| e.to_string())?
        };
        if created || layout || !window.is_visible().unwrap_or(false) {
            let height = window
                .inner_size()
                .map_err(|e| e.to_string())?
                .to_logical::<f64>(window.scale_factor().map_err(|e| e.to_string())?)
                .height;
            window
                .set_size(tauri::LogicalSize::new(width, height))
                .map_err(|e| e.to_string())?;
            let monitors = window.available_monitors().map_err(|e| e.to_string())?;
            let chosen = if audience == Audience::Patient {
                settings
                    .patient_screen_index
                    .and_then(|i| usize::try_from(i).ok())
                    .and_then(|i| monitors.get(i))
                    .cloned()
            } else {
                None
            };
            if let Some(monitor) = chosen.or(window.primary_monitor().map_err(|e| e.to_string())?) {
                let frame = monitor.work_area();
                let scale = monitor.scale_factor();
                window
                    .set_position(tauri::PhysicalPosition::new(
                        (f64::from(frame.position.x)
                            + (f64::from(frame.size.width) - width * scale) / 2.0)
                            .round() as i32,
                        (f64::from(frame.position.y + frame.size.height as i32)
                            - (height + 90.0) * scale)
                            .round() as i32,
                    ))
                    .map_err(|e| e.to_string())?;
            }
        }
        if !window.is_visible().map_err(|e| e.to_string())? {
            window.show().map_err(|e| e.to_string())?;
        }
        Ok(())
    }
}
pub fn resize(app: &tauri::AppHandle, label: &str, height: f64) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    {
        tauri_nspanel::objc2::MainThreadMarker::new().ok_or("caption must run on main thread")?;
        if let Ok(panel) = app.get_webview_panel(label) {
            let frame = panel.as_panel().frame();
            if (frame.size.height - height).abs() > 0.5 {
                panel.set_content_size(frame.size.width, height);
                panel.as_panel().setFrameOrigin(frame.origin);
            }
        }
        Ok(())
    }
    #[cfg(not(target_os = "macos"))]
    {
        if let Some(window) = app.get_webview_window(label) {
            let old = window
                .inner_size()
                .map_err(|e| e.to_string())?
                .to_logical::<f64>(window.scale_factor().map_err(|e| e.to_string())?);
            if (old.height - height).abs() > 0.5 {
                window
                    .set_size(tauri::LogicalSize::new(old.width, height))
                    .map_err(|e| e.to_string())?;
            }
        }
        Ok(())
    }
}
