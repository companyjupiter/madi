fn main() {
    // madi-platform's in-process Swift capture bridge uses the OS Swift runtime.
    // Link arguments on an rlib do not propagate to this final executable.
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
    }
    let attributes =
        tauri_build::Attributes::new().app_manifest(tauri_build::AppManifest::new().commands(&[
            "playback_snapshot",
            "playback_toggle",
            "caption_status",
            "caption_toggle",
            "caption_snapshot",
            "caption_close",
            "caption_resize",
            "settings_open",
            "settings_metadata",
            "settings_model_locations",
            "settings_models_command",
            "settings_reveal",
            "preferences_snapshot",
            "preferences_command",
            "settings_command",
            "glossary_snapshot",
            "glossary_command",
            "setup_snapshot",
            "setup_command",
            "audio_inputs",
            "choose_file",
            "models_snapshot",
            "models_command",
            "models_artwork",
            "file_snapshot",
            "file_artwork",
            "file_start",
            "file_leave",
            "live_start",
            "live_control",
            "live_permission_action",
            "file_reset",
            "file_edit",
            "file_copy_line",
            "file_rename_speaker",
            "workspace_snapshot",
            "workspace_command",
            "workspace_choose_folder",
            "workspace_open",
            "workspace_export",
        ]));
    tauri_build::try_build(attributes).expect("failed to build the parity host");
}
