# Sovereign Whisper — macOS app

Standalone window app that wraps the bit-validated `metal/` engine into a
signed, notarized `.dmg` for Apple Silicon (M1+). See [DESIGN.md](DESIGN.md)
for the full architecture; this README is the build/run quickstart.

## What this is

The app **spawns** `metal/out/transcribe` (STREAM mode) as a child process and
talks to it over stdin/stdout — it never links the engine. Native
`AVAudioEngine` replaces the old `ffmpeg` mic capture. The 1.5 GB model is
downloaded on first run; small assets ship in the bundle.

```
Sovereign/
  SovereignApp.swift        app entry (WindowGroup + Settings)
  SessionController.swift    state machine: capture → engine → transcript
  Engine/
    EngineProtocol.swift     stdout line → EngineEvent (pure, unit-tested)
    EngineProcess.swift      spawn + stdin jobs + stdout framing
  Audio/
    AudioCapture.swift       AVAudioEngine → 16k mono WAV segmenter (SEG/OVERLAP)
    WavWriter.swift          16-bit PCM WAV
  Model/
    AssetManifest.swift      URLs + SHA-256 + paths   ← FILL IN hosting/hash
    ModelDownloader.swift    first-run download + verify
  Transcript/
    TranscriptStore.swift    events → live lines → FLUSH relabel + overlap markers
    Exporters.swift          .md / .srt
  UI/                        ContentView, TranscriptView, ModelGate, Settings
  Info.plist                 NSMicrophoneUsageDescription, min OS 13, arm64
  Sovereign.entitlements     audio-input (hardened runtime via codesign)
scripts/
  build_engine.sh            metal/build.sh → out/transcribe
  assemble_bundle.sh         copy engine + curated small assets into .app
  sign_notarize.sh           Developer ID sign (inner→outer) + notarize + staple
  make_dmg.sh                create-dmg / hdiutil + staple
```

## Build (once you have an Xcode project)

This scaffold provides the Swift sources, Info.plist, entitlements, and the
packaging scripts. To turn it into a buildable product:

1. **Create an Xcode app target** (SwiftUI, macOS, arm64) and add `Sovereign/`
   sources, `Info.plist`, and `Sovereign.entitlements`. Enable **Hardened
   Runtime**; add the **Microphone** capability.
2. Build the engine: `app/scripts/build_engine.sh`.
3. Archive the app, then:
   ```bash
   app/scripts/assemble_bundle.sh  /path/to/Sovereign.app
   SIGN_ID="Developer ID Application: … (TEAMID)" \
   APPLE_ID=… TEAM_ID=… APP_PW=… \
     app/scripts/sign_notarize.sh /path/to/Sovereign.app
   app/scripts/make_dmg.sh        /path/to/Sovereign.app 1.0
   ```

## Before shipping — fill these in

- `AssetManifest.swift`: real model **URL + SHA-256 + size** (host on R2/S3/CDN).
- `SettingsView.swift` `WhisperLang`: confirm language token ids vs the BPE table.
- App icon (`Assets.xcassets`), bundle id, signing team.

## Tests

`Tests/EngineProtocolTests.swift` covers the stdout parser (the load-bearing,
Xcode-independent part). Run via the Xcode test target or `swift test` if you
add a Package.swift.
