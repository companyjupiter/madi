# Madi — macOS release-candidate build & smoke checklist

The repeatable path to build a local `Madi.app`, and the smoke checklist a release
candidate must pass before distribution. All scripts live in `apps/macos/scripts/`
and resolve the repo root from their own location, so they run from anywhere.

Product identity (from `apps/macos/Sovereign/Info.plist`): name **Madi**, bundle id
**`com.companyjupiter.madi`**, executable **Madi**.

---

## 1. Local build (unsigned / ad-hoc)

No Xcode project — the app is built entirely with `swiftc`.

```sh
apps/macos/scripts/make_app.sh [outdir]     # default → apps/macos/build/Madi.app
SEED_MODEL=1 apps/macos/scripts/make_app.sh  # also symlink the repo Q8 model into App Support
```

`make_app.sh` will build the engine first if `engine/metal/out/transcribe` is
missing (`build_engine.sh`, needs Zig 0.14.x + `xcrun metal`), then compile the
SwiftUI sources, assemble the bundle, and **ad-hoc** codesign it for local dev.

Canonical bundle layout it produces:

```
Madi.app/Contents/
  MacOS/Madi                     # the app
  MacOS/transcribe               # Zig/Metal speech engine
  MacOS/translate-engine         # optional local LLM runner (~1.4 MB; model is downloaded)
  Resources/whisper.metallib     # sealed by the bundle signature
  Resources/assets-small/*.bin   # the 7 files the engine opens at runtime
  Resources/manual/index.html    # offline user manual (Help menu)
  Info.plist, AppIcon.icns, logo, *.svg
```

The large `model.safetensors` (speech) and the optional translate GGUF are **not**
bundled — they download on first run / on demand into Application Support.

### Asset policy (bundled vs downloaded)

| asset | size | policy |
|---|---|---|
| engine + metallib + 7 `.bin` assets | small | **bundled** (`assemble_bundle.sh` / `make_app.sh`, same 7-file list) |
| `model.q8.safetensors` (speech) | ~830 MB | **downloaded** first run, SHA-256 verified (`ModelDownloader`) |
| `DNA3.0-4B…gguf` (optional LLM) | ~2.6 GB | **downloaded** on demand, SHA-256 verified (`TranslateModelDownloader`) |

Bundled `.bin` list is kept in sync between `make_app.sh` (`ASSETS[]`) and
`assemble_bundle.sh` (`SMALL[]`) — both are the files `transcribe.zig` opens via
`bpe_dir`. Weights/tokenizer JSON are `@embedFile`'d into the engine, not bundled.

## 2. Developer ID sign + notarize (distribution)

Secrets are passed as env vars — never commit them.

```sh
SIGN_ID="Developer ID Application: NAME (TEAMID)" \
APPLE_ID="you@example.com" TEAM_ID="XXXXXXXXXX" APP_PW="app-specific-pw" \
  apps/macos/scripts/sign_notarize.sh path/to/Madi.app
# or, with a stored notarytool profile:
SIGN_ID="Developer ID Application: NAME (TEAMID)" NOTARY_PROFILE="madi" \
  apps/macos/scripts/sign_notarize.sh path/to/Madi.app
```

Required env: `SIGN_ID` always; then either `NOTARY_PROFILE`, or all of
`APPLE_ID` + `TEAM_ID` + `APP_PW`. Signs inner executables first, then the bundle,
verifies `--deep --strict`, notarizes, and staples.

## 3. DMG

```sh
apps/macos/scripts/make_dmg.sh path/to/Madi.app 1.0   # → Madi-1.0.dmg
```

Uses `create-dmg` if installed, else `hdiutil`. Staples the DMG too.

---

## Release-candidate smoke checklist

Build a fresh bundle, then verify each item on a clean machine / clean App Support.

**Pre-flight (automated)**
- [ ] `cd apps/macos && swift test` — core suite green (this is the CI release gate).
- [ ] `bash -n apps/macos/scripts/*.sh` — all packaging scripts parse.
- [ ] `make_app.sh` completes and prints `✅`; bundle has `MacOS/{Madi,transcribe,translate-engine}` and `Resources/assets-small/` with 7 `.bin` files.

**First launch (clean App Support: no `~/Library/Application Support/Madi/`)**
- [ ] App launches; **model setup gate** appears before any recording control is usable.
- [ ] Speech model downloads with visible progress; **cancel** leaves a recoverable
      "다운로드 시작" state (not a dead spinner); **retry** / re-download work.
- [ ] On a corrupt/size-mismatch model, the gate shows a SHA-256 failure and recovers on retry.
- [ ] After the model is ready, recording controls unlock.

**Core session**
- [ ] Microphone permission prompt appears on first capture; granting it works.
- [ ] Record (or drag-drop / replay a WAV) → live speaker-attributed transcript with timestamps.
- [ ] Export produces a `.md` with speaker labels + timecodes (and `.srt` where offered).
- [ ] Quit and relaunch → model is NOT re-downloaded (validity gate passes), prior data intact.

**Optional local intelligence (separate gate)**
- [ ] With the speech model ready but the optional LLM absent: transcription works;
      translate / summary / Q&A / AI-title are gated with a local-first "download the
      model in Settings" message (no account / API key / cloud).
- [ ] Install the optional model (Settings › 번역) → dependent actions become available.

**Signed build (if distributing)**
- [ ] `sign_notarize.sh` succeeds; `spctl -a -vvv --type exec Madi.app` accepts it.
- [ ] `make_dmg.sh` produces a stapled DMG that opens without a Gatekeeper warning.

See [DEMO.md](DEMO.md) for a reproducible transcript/export proof to attach to a release.
