use std::{env, path::PathBuf, process::Command};

fn main() {
    println!("cargo:rerun-if-changed=native/AudioDecodeMain.swift");
    println!("cargo:rerun-if-changed=native/AudioCaptureBridge.swift");
    println!("cargo:rerun-if-changed=native/UnicodeBridge.swift");
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

    // Keep capture in the app process: ScreenCaptureKit's own-audio exclusion
    // must refer to Madi, not a helper. Swift emits Mach-O autolink directives
    // for its system frameworks/runtime; no external capture dylib is shipped.
    let out = PathBuf::from(env::var_os("OUT_DIR").unwrap());
    let mut command = Command::new("xcrun");
    command.args([
        "swiftc",
        "-O",
        "-parse-as-library",
        "-emit-library",
        "-static",
        "-module-name",
        "MadiAudioCapture",
        "-target",
        &format!("{arch}-apple-macosx14.0"),
    ]);
    if env::var("PROFILE").as_deref() == Ok("debug") {
        command.args(["-D", "MADI_CAPTURE_REPLAY"]);
    }
    for name in ["Resampler.swift", "WavWriter.swift", "AudioDevices.swift"] {
        let source = audio.join(name);
        println!("cargo:rerun-if-changed={}", source.display());
        command.arg(source);
    }
    let result = command
        .arg("native/AudioCaptureBridge.swift")
        .arg("native/UnicodeBridge.swift")
        .arg("-o")
        .arg(out.join("libMadiAudioCapture.a"))
        .output()
        .expect("Xcode Swift compiler is required for native capture");
    assert!(
        result.status.success(),
        "native audio capture build failed: {}",
        String::from_utf8_lossy(&result.stderr)
    );
    println!("cargo:rustc-link-search=native={}", out.display());
    println!("cargo:rustc-link-lib=static=MadiAudioCapture");
    println!("cargo:rustc-link-arg=-Wl,-rpath,/usr/lib/swift");
    let swiftc = Command::new("xcrun")
        .args(["--find", "swiftc"])
        .output()
        .unwrap();
    assert!(swiftc.status.success());
    let compiler = PathBuf::from(String::from_utf8(swiftc.stdout).unwrap().trim());
    println!(
        "cargo:rustc-link-search=native={}",
        compiler
            .parent()
            .unwrap()
            .join("../lib/swift/macosx")
            .display()
    );
    let sdk = Command::new("xcrun")
        .args(["--sdk", "macosx", "--show-sdk-path"])
        .output()
        .unwrap();
    assert!(sdk.status.success());
    println!(
        "cargo:rustc-link-search=native={}/usr/lib/swift",
        String::from_utf8(sdk.stdout).unwrap().trim()
    );
}
