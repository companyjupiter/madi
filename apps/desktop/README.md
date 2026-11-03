# Madi desktop migration

This is an **isolated, debug-only UI parity harness**, not the Madi product.
The existing `apps/macos` app remains the shipping implementation.
The host has its own `tv.devart.madi.parity` identifier and only in-memory setup
state. It does not read or migrate the user's settings, models or meetings.

## Run

Install the Rust toolchain pinned at the repository root and Node 24 or newer.
The native host also needs the platform's Tauri build prerequisites.
The current macOS inference package is Apple Silicon/macOS 14+ only. It also
requires Zig 0.14.1 on PATH and Xcode's Metal compiler. Before the first macOS
build, fetch the same verified runtime assets as the original app:

```sh
apps/macos/scripts/fetch_runtime_assets.sh
```

The build checks the seven asset pins and rebuilds the original ASR engine;
it never downloads user models. Windows still builds the isolated host without
macOS inference executables or a native audio decoder.

```sh
cd apps/desktop
npm ci
npm run tauri dev -- --no-watch
```

For an executable with embedded frontend assets (no Vite server):

```sh
npm run build
npm run prepare-native
cd ../..
cargo build --locked -p madi-desktop --features custom-protocol
```

Release builds deliberately fail until product runtime and migration gates are
implemented. The debug executable has no recording, transcription,
model downloader, saving or updater. Start buttons currently emit a
`madi-parity-intent` DOM event for the visual harness only; they do not pretend to
start an inference session. Do not distribute this as a working Madi release.

macOS dev/build hooks stage the Cargo-built decoder, original ASR engine,
checksum-verified DNA2B/4B engines, seven runtime assets and their notices.
The debug `.app` is ad-hoc signed and requires macOS 14+. Installed lookup has
no checkout/PATH fallback. Headless relocation/package checks are documented in
`docs/runtime/NATIVE_RUNTIME_PACKAGE.md` and `NATIVE_DECODER_PACKAGE.md`.

Language, translation-target, meeting-mode, diarization and capture-source and microphone-device
selection commands go through the real Rust `madi-core` state in the native host.
The main local WebView has setup commands plus read-only native device discovery.
On macOS, Core Audio supplies the original device order, names and system default;
picking a microphone leaves system-only mode but preserves mixed mode. Discovery
refreshes on focus and when opening the picker, and never opens an audio stream or
requests permission. The Windows discovery adapter is explicitly unsupported.
There are no
shell/filesystem/remote-origin capability grants or production mock fallbacks.

The macOS file chooser uses the original NSOpenPanel/UTType behavior. Native
drop events and the chooser stage a path in Rust; the UI receives only name and
size. Clearing selection does not delete the original file. The staged card and
CTA availability are implemented, with native interaction/visual validation
pending. Windows selection is not implemented. See
`docs/runtime/NATIVE_FILE_STAGING.md` for scope and the live Swift comparison.

## Visual reference and limits

The start screen is derived from `ContentView.setToStartCard` at `c1390c7`.
It reuses the original wordmark and SVG files; it is not based on the analytics
dashboard or old design mockups. AppKit-resolved colors are recorded in
`design/parity/theme-reference.json`. On macOS, refresh them with:

```sh
python3 scripts/capture_theme_reference.py
python3 scripts/sync_desktop_resources.py
```

The old `design/gen_theme.py` must not be run: it overwrites adaptive colors.
Generated CSS is a reference for the captured OS, not a claim that Windows or
another macOS version renders identically.

A read-only browser fixture is available only in the Vite dev server at
`/?fixture=setup&theme=light` (or `dark`, with `lang=ko|en|ja`). It does not emulate
Rust command behavior. Native WebView checks remain required.

Open differences: fonts and SF Symbols, native window chrome, exact line
metrics, native validation of microphone selection/overflow, translation availability
and keyboard focus, staged file interaction/geometry, model gate and all working screens.
The current start fixture assumes the models are ready; it does not infer that
from this machine. These are migration tasks, not approved parity exceptions.

See `docs/TAURI_MIGRATION_PLAN.md`, `docs/TAURI_MIGRATION_STATUS.md` and
`design/parity/README.md` at the repository root for gates and evidence.
