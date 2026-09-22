# Madi macOS app

Native SwiftUI application for Apple Silicon, built directly with `swiftc` and
Swift Package Manager. There is no Xcode project to generate or maintain.

The app launches the Zig/Metal transcription engine as a child process and talks
to it over stdin/stdout. Microphone and system audio capture use Apple frameworks;
the speech model downloads on first run and is verified by SHA-256.

## Build

Requirements: Apple Silicon, macOS 14+, Xcode command-line tools, and Zig 0.14.x.

```sh
cd ../..
apps/macos/scripts/fetch_runtime_assets.sh
apps/macos/scripts/make_app.sh
open apps/macos/build/Madi.app
```

The default product bundle includes the two separately licensed prebuilt translate
engines in `engine/prebuilt/`. Build the AGPL/source-only variant without them:

```sh
MADI_BUNDLE_TRANSLATE_ENGINES=0 apps/macos/scripts/make_app.sh
```

The source-only variant keeps transcription and export; translation, summaries,
Q&A, and AI titles are unavailable because their runners are absent. See
[`../../docs/PROVENANCE.md`](../../docs/PROVENANCE.md).

`VERSION` at the repository root is canonical. An ordinary source build gets a
`<version>-dev.<git-sha>` full version; release tooling supplies the exact release
SemVer and verifies it against `VERSION`.

## Test

```sh
cd apps/macos
swift test
scripts/check_version_consistency.sh
```

`Package.swift` exposes the Foundation-only `SovereignCore` target so most product
logic runs headlessly. `scripts/make_app.sh` is the authoritative application
source list; add every new app `.swift` file there as well as to the package target
when appropriate.

## Layout

```text
Sovereign/
  AppInfo/       version, update, and first-run policy
  Audio/         microphone/system capture, decode, segmentation, WAV IO
  Dictation/     dictation controller and formatting
  Engine/        child-process protocols and local LLM lanes
  Model/         model manifests, downloaders, workspace tree
  Transcript/    transcript state, export, retrieval, summaries, voiceprints
  UI/            SwiftUI application views
scripts/         build, verification, signing, DMG, and release tooling
Tests/           SovereignCore and integration-style headless tests
```

Architecture and release details live in [DESIGN.md](DESIGN.md) and
[`../../docs/RELEASE.md`](../../docs/RELEASE.md). Signing and notarization are a
separate release step; local builds are ad-hoc signed.
