fn main() {
    let attributes = tauri_build::Attributes::new().app_manifest(
        tauri_build::AppManifest::new().commands(&["setup_snapshot", "setup_command"]),
    );
    tauri_build::try_build(attributes).expect("failed to build the parity host");
}
