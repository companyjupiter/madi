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

---

## GitHub Actions release

Two release workflows are maintained:

| workflow | current state | purpose |
|---|---|---|
| `.github/workflows/release-macos-free.yml` | active | Free-account build: ad-hoc signed, explicitly unnotarized DMG |
| `.github/workflows/release-macos-paid.yml.disabled` | disabled | Developer ID signing, notarization, stapled DMG |

Both paths run tests, build the engine/app, validate the bundle, create DMGs and
checksums, and upload a GitHub Release. Both paths use the customer-facing
`madi-<version>-arm64.dmg` filename convention; the free build remains clearly
marked as unnotarized in the GitHub Release title and notes. They use the
standard `macos-26` Apple-silicon runner rather than a billable larger runner.

After Developer ID and notarization credentials are ready, switch workflows:

```sh
mv .github/workflows/release-macos-free.yml \
   .github/workflows/release-macos-free.yml.disabled
mv .github/workflows/release-macos-paid.yml.disabled \
   .github/workflows/release-macos-paid.yml
```

It runs in either of these ways:

- push a `v*.*.*` tag to publish a standard DMG immediately;
- choose **Actions → Release macOS (free account) → Run workflow** to create a draft release,
  optionally including the self-contained offline DMG. Check `publish` only when
  the artifacts should become visible to the in-app updater immediately.

The runtime archive is a versioned build dependency created before an app release,
not an output of that same app build. Its URL and digest are public metadata, so
configure them as **GitHub Actions repository variables**, not secrets:

| repository variable | value |
|---|---|
| `MADI_RELEASE_ASSETS_URL` | HTTPS URL of the pinned small-assets tarball |
| `MADI_RELEASE_ASSETS_SHA256` | SHA-256 of that tarball |

Path: **Settings → Secrets and variables → Actions → Variables**.

For the paid workflow, create a GitHub environment named `release`, restrict it to
the release branch or tags, and add all Developer ID/notarization secrets:

| secret | value |
|---|---|
| `MACOS_SIGN_ID` | `Developer ID Application: … (TEAMID)` identity |
| `MACOS_CERTIFICATE_P12_BASE64` | base64-encoded Developer ID `.p12` |
| `MACOS_CERTIFICATE_PASSWORD` | password of that `.p12` |
| `APPLE_NOTARY_KEY_ID` | App Store Connect API key ID |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect API issuer ID |
| `APPLE_NOTARY_KEY_P8_BASE64` | base64-encoded `AuthKey_….p8` |

Translation is bundled when both optional secrets are present:
`MADI_TRANSLATE_ENGINE_URL` and `MADI_TRANSLATE_ENGINE_SHA256`.

Create the small-assets archive once from a validated engine workspace, upload it
to versioned immutable storage, and record its digest in the environment secret:

```sh
tar -czf madi-runtime-assets-v1.tar.gz -C engine/metal/assets \
  WHISPER_BPE.bin mel_filters.bin resnet34_diar.bin kaldi_melbank.bin \
  silero_vad.bin pyannote_osd.bin suppress_tokens.bin
shasum -a 256 madi-runtime-assets-v1.tar.gz
```

The workflow refuses to build if the archive hash is wrong, any runtime asset is
missing, the bundle version is wrong, or either executable is not arm64. Release
metadata is injected into the built bundle, so CI never edits the tracked
`Info.plist`.

### S3 binary storage

DMGs are stored only in S3. GitHub Releases contain version metadata and S3
download links, not duplicate binary attachments. Configure these repository
variables for both workflows:

| repository variable | example |
|---|---|
| `AWS_REGION` | `ap-northeast-2` |
| `AWS_ROLE_ARN` | `arn:aws:iam::123456789012:role/madi-github-release` |
| `MADI_RELEASE_BUCKET` | `devart-teamjupiter-downloads-artdapne2` |
| `MADI_RELEASE_PREFIX` | `madi` (optional; this is the default) |
| `MADI_DOWNLOAD_BASE_URL` | `https://madi.devart.tv` |

The resulting layout is:

```text
s3://devart-teamjupiter-downloads-artdapne2/madi/
  runtime-assets/v1/madi-runtime-assets-v1.tar.gz
  releases/index.json
  releases/0.9.1/
    madi-0.9.1-arm64.dmg
    madi-0.9.1-offline-arm64.dmg
    SHA256SUMS.txt
    release.json
  channels/beta/latest.json
  channels/stable/latest.json
```

Version paths are immutable: CI stores each object's SHA-256 in S3 metadata and
refuses to overwrite an existing key with different bytes. When `publish` is
enabled, the workflow uploads all versioned objects first and updates the small
channel `latest.json` and `releases/index.json` documents afterward. Draft runs
with `publish=false` upload versioned artifacts but do not expose them in either
mutable document.

`releases/index.json` is the download site's source of truth. The publisher adds
the standard `macos-arm64` DMG with its object key, SHA-256, byte size, and first
publication timestamp. Republishing the same version replaces its entry instead
of duplicating it. A stable publication advances `channels.stable`; beta and RC
publications are added to the version list while leaving the stable pointer
unchanged. The first indexed publication must therefore use the stable channel.

Keep the bucket private and expose downloads through CloudFront with Origin
Access Control. Set the CloudFront origin path to `/<MADI_RELEASE_PREFIX>` (for
this deployment, `/madi`). `MADI_DOWNLOAD_BASE_URL` is the custom domain without
that storage prefix. This keeps S3 keys under `madi/` while customer-facing URLs
start directly at `/releases/` or `/runtime-assets/`.
The runtime asset variables can then point to, for example:

```text
MADI_RELEASE_ASSETS_URL=https://madi.devart.tv/runtime-assets/v1/madi-runtime-assets-v1.tar.gz
MADI_RELEASE_ASSETS_SHA256=<archive sha256>
```

GitHub Actions authenticates to AWS through OIDC, so no AWS access key is stored
in GitHub. The workflow uses the `release` environment; scope the IAM role trust
policy to this exact subject:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {
      "Federated": "arn:aws:iam::123456789012:oidc-provider/token.actions.githubusercontent.com"
    },
    "Action": "sts:AssumeRoleWithWebIdentity",
    "Condition": {
      "StringEquals": {
        "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
        "token.actions.githubusercontent.com:sub": "repo:companyjupiter/madi:environment:release"
      }
    }
  }]
}
```

Attach only the S3 permissions needed by the release prefix:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["s3:GetObject", "s3:PutObject"],
    "Resource": "arn:aws:s3:::devart-teamjupiter-downloads-artdapne2/madi/*"
  }]
}
```
