use std::{env, path::PathBuf, process::Command};

fn main() {
    println!("cargo:rerun-if-changed=native/AudioDecodeMain.swift");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() != Ok("macos") {
        return;
    }
    let root = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap()).join("../..");
    let audio = root.join("apps/macos/Sovereign/Audio");
    let sources: Vec<_> = ["WavWriter.swift", "Resampler.swift", "AudioDecode.swift"]
        .map(|name| audio.join(name))
        .into();
    for source in &sources {
        println!("cargo:rerun-if-changed={}", source.display());
    }
    let arch = match env::var("CARGO_CFG_TARGET_ARCH").as_deref() {
        Ok("aarch64") => "arm64",
        Ok("x86_64") => "x86_64",
        _ => panic!("unsupported macOS architecture"),
    };
    let output = PathBuf::from(env::var_os("OUT_DIR").unwrap()).join("madi-audio-decode");
    let result = Command::new("xcrun")
        .args([
            "swiftc",
            "-O",
            "-parse-as-library",
            "-target",
            &format!("{arch}-apple-macosx14.0"),
        ])
        .args(sources)
        .arg("native/AudioDecodeMain.swift")
        .arg("-o")
        .arg(&output)
        .output()
        .expect("Xcode Swift compiler is required for the macOS audio adapter");
    if !result.status.success() {
        panic!(
            "native audio decoder build failed: {}",
            String::from_utf8_lossy(&result.stderr)
        );
    }
    println!(
        "cargo:rustc-env=MADI_BUILT_AUDIO_DECODER={}",
        output.display()
    );
}
