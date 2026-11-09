# Native inference runtime package

The debug macOS Tauri app now includes the original inference runtime:

- `Contents/MacOS`: the host, AVFoundation decoder, `transcribe`,
  `translate-engine-2b` and `translate-engine-4b`.
- `Contents/Resources/assets-small`: the same seven BPE/filter/VAD/diarization/
  overlap/suppression files as `make_app.sh`.
- `Contents/Resources`: the informational embedded metallib copy, Madi license,
  NOTICE, third-party notices and the separately licensed translation engines'
  binary license.

The large Whisper/DNA user models are not copied or downloaded by packaging.
This is still an isolated, ad-hoc signed debug harness, not a product release.
The package requires native Apple Silicon and macOS 14+. Intel/universal and
Windows inference packages are not implemented.

## Preparation and validation

`prepare_desktop_native.mjs` builds/stages the decoder, then invokes
`prepare_desktop_runtime.mjs`. Preparation checks Zig 0.14.1, verifies all seven
asset byte counts/hashes against the verified original native baseline and checks
DNA binaries against `engine/prebuilt/MANIFEST.json`. Missing inputs fail the
build. The original `build_engine.sh` is run afresh with deployment target 14.0;
an old `engine/metal/out/transcribe` is not accepted as source-build evidence.
Only generated `out/desktop-native/resources` staging is replaced; model/user
paths are never accessed. The bytes hashed are exactly the bytes staged.

CI fetches the original pinned runtime archive and verifies the Zig archive
against the SHA-256 from the [official download index](https://ziglang.org/download/index.json).
Developer builds fetch runtime assets explicitly using
`apps/macos/scripts/fetch_runtime_assets.sh`; preparation itself performs no
network download. Tauri uses its external binary convention and
[resource map](https://v2.tauri.app/develop/resources/) to retain the original
installed layout. Ad-hoc signing changes executable signatures; the staged
pre-sign hashes and installed hashes are recorded separately.

`runtime_bundle::bundled()` resolves the current executable's canonical bundle
layout, requires four nonempty executable files and seven regular assets, and
rejects links/non-executable files or resource directories outside that layout.
This checks layout, not immutable integrity; build-time pins and package signing
are separate checks. There is no checkout, PATH or development-artifact fallback.
The headless `--runtime-layout` diagnostic exits before native UI creation. It
adds no frontend filesystem/process-launch capability.

`check_desktop_package_parity.py` verifies asset hashes, notices, arm64/14.0
engine metadata and strict signatures. It relocates the app outside the
repository and uses an unrelated cwd/system-only PATH. All 11 required runtime
files are individually removed and then replaced with links to the original
bundle: both probes fail for every file. Restoring them restores signature
validity. The decoder still produces valid non-silent 16 kHz mono PCM16 from a
synthetic source while preserving the original.

## Real file probe and limits

The existing Rust `file_session_smoke` example accepts an optional final decoder
argument. A copied app's `--runtime-layout` supplies its decoder, ASR and assets;
the existing verified Whisper model stays in Application Support. On the public
11-second JFK fixture this path produces Processing → Done, 22 words, 26 JSONL
events and exactly one completion. No faults/timeouts or owned scratch remain;
the source WAV is unchanged. See
[`macos-bundled-asr-2026-11-04.json`](../evidence/macos-bundled-asr-2026-11-04.json).
The Rust probe executable is outside the app; this establishes the installed
runtime paths and execution, not a connected Tauri transcript screen.

The package receipt is
[`macos-runtime-package-2026-11-04.json`](../evidence/macos-runtime-package-2026-11-04.json).
DNA binaries are packaged and checked but this step does not perform a new full
DNA inference/quality test. No microphone, model installer, storage migration,
updater, native UI parity or notarization gate is closed by these checks.
