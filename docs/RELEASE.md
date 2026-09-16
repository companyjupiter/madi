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
  MacOS/translate-engine-4b      # optional quality-profile LLM runner
  MacOS/translate-engine-2b      # optional 8 GB realtime-profile LLM runner
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
| `DNA3.0-2B…gguf` (8 GB LLM) | ~1.3 GB | **downloaded** on demand, SHA-256 verified (`TranslateModelDownloader`) |
| `DNA3.0-4B…gguf` (16 GB+ LLM) | ~2.8 GB | **downloaded** on demand, SHA-256 verified (`TranslateModelDownloader`) |

Bundled `.bin` list is kept in sync between `make_app.sh` (`ASSETS[]`) and
`assemble_bundle.sh` (`SMALL[]`) — both are the files `transcribe.zig` opens via
`bpe_dir`. Weights/tokenizer JSON are `@embedFile`'d into the engine, not bundled.

## 2. Developer ID sign + notarize (distribution)

**Integrated into `madi_release.sh` (2026-09-01):** build/upload/publish
auto-detect signing. When BOTH a "Developer ID Application" identity (env
`SIGN_ID`, or the sole one in the keychain) AND notary credentials
(`NOTARY_PROFILE`, the `NOTARY_KEY`/`NOTARY_KEY_ID`/`NOTARY_ISSUER` API-key
triplet, or `APPLE_ID`+`TEAM_ID`+`APP_PW`) are present, the pipeline signs +
notarizes + staples the app (`sign_notarize.sh`) and then the DMG. Otherwise it
falls back to ad-hoc with a loud warning. Control with:

- `MADI_SIGNING=auto|adhoc|developer-id` (default auto; `developer-id` fails
  instead of falling back)
- `--require-notarized` — fail build/upload/publish unless notarization is
  available (recommended for real releases once credentials exist)

`plan --json` reports the resolved mode under `signing:{mode,reason}` and the
manifest records `signing` per artifact set; a cached artifact whose recorded
signing differs from the current environment is rebuilt, never reused.

One-time credential setup (owner-only — requires the Apple Developer account):

1. Apple Developer Program 가입 → Xcode/developer.apple.com에서 **Developer ID
   Application** 인증서 발급, 로그인 키체인에 설치.
2. App-specific password 발급(appleid.apple.com) 후:
   `xcrun notarytool store-credentials madi --apple-id <이메일> --team-id <TEAMID>`
   → 이후 릴리스는 `NOTARY_PROFILE=madi`만으로 동작.

Manual per-app invocation (what the pipeline calls internally):

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

## Local S3 release (canonical path)

Use `apps/macos/scripts/madi_release.sh` as the release entrypoint. It accepts
the exact subcommands below:

```sh
apps/macos/scripts/madi_release.sh plan 0.1.0 --json
apps/macos/scripts/madi_release.sh build 0.1.0 --json
apps/macos/scripts/madi_release.sh upload 0.1.0 --json
apps/macos/scripts/madi_release.sh publish 0.1.0 --json
apps/macos/scripts/madi_release.sh promote-github 0.1.0 --json
apps/macos/scripts/madi_release.sh prune 0.1.0 --dry-run --json
```

`plan` is read-only. `build` creates or reuses local artifacts. `upload`
publishes only the immutable versioned objects. `publish` is the one-command
local release path: it builds or reuses the local DMG, uploads the immutable S3
artifacts, and then advances `releases/index.json` and
`channels/<channel>/latest.json`. `promote-github` is the legacy path that
reuses an existing GitHub Release DMG asset before publishing to S3.

`prune <version>` retires every other published version. It refuses to run unless
the live `channels.stable` already is `<version>` (publish first), then rewrites
`releases/index.json` down to the versions a channel pointer still names
(stable/beta/rc) **before** deleting the other `releases/<v>/` prefixes —
including orphan directories that never made it into the index — and finally
invalidates the deleted objects' exact CDN paths, listed before deletion
(versioned objects are served `immutable`, so without it retired DMGs would stay
downloadable from the edge; wildcard invalidations are capped at 15 in progress
per distribution — the first real prune of 16 versions hit that — while exact
paths allow 3000). The distribution is found by the base URL's alias, or pinned with
`MADI_CLOUDFRONT_DISTRIBUTION_ID`; an invalidation failure is reported in the JSON
(`cdn.note`), never fatal. `--dry-run` emits the same JSON (`deleted`, `kept`,
`skipped` non-SemVer directories, index counts) without uploading, deleting, or
invalidating. The bucket is versioned, so deleted objects become non-current
versions that the owner can still restore; their public URLs answer 403.
`prune` skips the build gates. Every run keeps its own evidence directory,
`build/local-release/<version>/prune/<UTC stamp>-<apply|dry-run>-<pid>/`
(`prune.json`, `release-index.before.json` / `release-index.after.json`,
`deleted-keys.json`; the JSON's `runDir` names it), so a later dry run never
overwrites the record of an applied one.
The S3 work lives in `apps/macos/scripts/prune_s3_releases.sh`
(`tests/prune_s3_releases_test.sh`).

`apps/macos/scripts/release_local_free.sh` now acts as a compatibility wrapper:
default = `build`, `--upload` = `upload`, `--publish-local` = `publish`, and
`--publish` = `promote-github`.

The CLI accepts `--offline`, `--skip-tests`, `--beta-expiry YYYY-MM-DD`, and
`--json`. `--json` makes the command emit a single JSON object; all other logs
go to stderr. Build output lives under `build/local-release/<version>/`, and
the manifest is written to `build/local-release/<version>/manifest.json`.

The build flow validates shell files, runs the S3 publisher tests and Swift
tests, builds and checks the app bundle, creates lowercase
`madi-<version>-arm64.dmg` artifacts, and writes `SHA256SUMS.txt`. The script
records the current git SHA and dirty state in the manifest and reuses existing
artifacts only when the version, git SHA, offline flag, and checksums still
match. A dirty working tree forces a rebuild.

Local uploads use the credentials already available to the AWS CLI
(`aws configure`, AWS SSO, or environment credentials). The GitHub OIDC
`AWS_ROLE_ARN` path is used only by CI, not by local releases. Production
defaults are built in and can be overridden through environment variables:

```sh
MADI_RELEASE_BUCKET=devart-teamjupiter-downloads-artdapne2
MADI_RELEASE_PREFIX=madi
MADI_DOWNLOAD_BASE_URL=https://madi.devart.tv
```

The script always refreshes and verifies the seven runtime assets from the
pinned `runtime-assets/v1` archive before a new build. Set both
`MADI_RELEASE_ASSETS_URL` and `MADI_RELEASE_ASSETS_SHA256` only when
intentionally moving to a different immutable archive. An offline build
downloads and verifies the Q8 speech model only when it is not already present.

The engine build pins the app and transcription engine to the declared macOS
14.0 minimum, independent of the macOS/Xcode version on the build machine.
Bundle verification checks those executables and the optional translation
engine, rejecting a release if any of them targets a newer OS. This prevents
host-runner defaults from leaking into customer binaries.

Completed artifacts are retained. If an S3 or metadata update fails, rerun the
same command. `build` and `upload` reuse matching artifacts when the manifest is
still valid. `publish` keeps the lower-case S3 naming convention and refuses to
overwrite an existing version with different bytes. When reusing a standard-only
release root, the CLI prunes any stale offline DMG before upload so a previous
offline build cannot leak into a later standard release. GitHub promotion
remains available only as the legacy `promote-github` path.

The in-app updater reads `channels/<MADIChannel>/latest.json` through CloudFront,
requires the schema-1 channel/version contract, pins DMG URLs to
`https://madi.devart.tv/releases/<version>/`, and verifies both byte size and
SHA-256 before opening a downloaded image. GitHub remains the human-facing
release/support page, not the binary update feed.

Madi also ships Sparkle 2 for one-click self-update. `make_app.sh` fetches the
pinned Sparkle binary distribution, links `Sparkle.framework`, embeds
`SUFeedURL=https://madi.devart.tv/channels/<channel>/appcast.xml`, and copies the
framework into `Contents/Frameworks`. `SUPublicEDKey` is already pinned in the
source plist; override it with `SPARKLE_PUBLIC_ED_KEY` only when intentionally
rotating the Sparkle EdDSA key. During publish, `publish_s3_release.sh` writes
and uploads `channels/<channel>/appcast.xml`; pass `SPARKLE_PRIVATE_KEY_FILE` or
`SPARKLE_PRIVATE_KEY` so `sign_update` can add `sparkle:edSignature`. Set
`SPARKLE_ALLOW_UNSIGNED_APPCAST=1` only for local/mock tests; real `publish`
runs fail if Sparkle signing is unavailable. The legacy `latest.json`/manual-DMG
window remains as a fallback and integrity diagnostic path.

Normal versioned releases do not need CloudFront invalidation because the
versioned object paths are immutable and the metadata documents are served with
no-cache headers. This CLI refuses same-version replacement with different
bytes; any exceptional manual replacement would also require explicit cache
invalidation.

Treat `releases/index.json` and `channels/<channel>/latest.json` as single-writer
mutable metadata. The publisher uses read-modify-write semantics without a
lock, so run one publisher at a time.

### Git tags

`publish` never touches GitHub, so it does not create the git tag. Tag
separately, as an annotated `v<version>` tag on the exact `gitSha` recorded in
`build/local-release/<version>/manifest.json`, and record the artifact sha256 in
the annotation so a released binary can be traced back to its source.

The tag sequence is therefore allowed to have gaps. `v0.1.3` does not exist and
should not be created: 0.1.3 and 0.1.4 were both built from `450e527`, so
`v0.1.4` already tags that tree and a second tag on the same commit would only
make `git describe` ambiguous.

### Retention: only the current stable stays published

Since 2026-09-16 a release supersedes its predecessors completely: after a
stable publish, `madi_release.sh prune <version>` removes every other version
from S3 and the index, and the older GitHub Releases are deleted together with
their tags (`gh release delete <tag> --cleanup-tag`, plus `git push origin
--delete <tag>` for tags that had no Release). Only one `v<version>` tag and one
GitHub Release exist at a time. The commits themselves stay in history; the
retired tags are recorded here so a released binary can still be traced:

| version | published | tag | commit | DMG sha256 (prefix) |
|---|---|---|---|---|
| 0.3.21 | 2026-09-08 | `v0.3.21` | `d43c1327d035` | `83b63b5d5cd2…` |
| 0.3.7 | 2026-09-03 | — | — | `47a94c2484df…` |
| 0.3.1 | 2026-09-02 | — | — | `2ca81846097b…` |
| 0.3.0 | 2026-08-31 | — | — | `b94cea410f8a…` |
| 0.2.0 | 2026-08-30 | `v0.2.0` | `8a921ea865a6` | `c9d566a2f557…` |
| 0.1.9 | 2026-08-11 | `v0.1.9` | `c0f4634d4714` | `6094da37690e…` |
| 0.1.8 | 2026-08-10 | `v0.1.8` | `1abc087f318f` | `15ceb2121119…` |
| 0.1.7 | 2026-08-04 | `v0.1.7` | `92b0dba892b1` | `1522671cece7…` |
| 0.1.6 | 2026-07-31 | `v0.1.6` | `f8f3dec5c53f` | `0c07417e325c…` |
| 0.1.5 | 2026-07-26 | `v0.1.5` | `6bd587e65628` | `ecffd72fcdc9…` |
| 0.1.4 | 2026-07-22 | `v0.1.4` | `450e5272637f` | `695e1b1c9b06…` |
| 0.1.3 | 2026-07-22 | — | — | `fb6f60651522…` |
| 0.1.2 | 2026-07-20 | `v0.1.2` | `f05397bafb1c` | `b45eb0fd34fa…` |
| 0.1.1 | 2026-07-20 | `v0.1.1` | `17f107c9e875` | `467d162d5abe…` |
| 0.1.0 | 2026-07-19 | `v0.1.0` | `ead0084e4b9e` | `1ebfb40a6934…` |

0.9.0 was an orphan S3 directory from the abandoned beta line (never indexed);
its release and tag had already been deleted on 2026-07-19.

---

## Release-candidate smoke checklist

Build a fresh bundle, then verify each item on a clean machine / clean App Support.

**Pre-flight (automated)**
- [ ] `cd apps/macos && swift test` — core suite green (this is the CI release gate).
- [ ] `bash -n apps/macos/scripts/*.sh` — all packaging scripts parse.
- [ ] `make_app.sh` completes and prints `✅`; translation-enabled bundles have `MacOS/{Madi,transcribe,translate-engine-2b,translate-engine-4b}` and `Resources/assets-small/` with 7 `.bin` files.

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
- [ ] `Help → 업데이트 설치…` opens the Sparkle update flow; `appcast.xml` exists
      beside `latest.json` for the build channel and has a Sparkle EdDSA signature
      on production releases.

See [DEMO.md](DEMO.md) for a reproducible transcript/export proof to attach to a release.

---

## GitHub Actions release definitions (automatic runs paused)

Two release workflows are maintained:

| workflow | current state | purpose |
|---|---|---|
| `.github/workflows/release-macos-free.yml` | manual only | Free-account build: ad-hoc signed, explicitly unnotarized DMG |
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

The free workflow is retained for later use, but its PR and tag triggers are
disabled. After Actions billing is restored, it can still be invoked manually
through **Actions → Release macOS (free account) → Run workflow**. The local
script above is the source of truth until automatic runs are explicitly restored.

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

Translation is bundled only as a complete engine pair. Configure
`MADI_TRANSLATE_ENGINE_{2B,4B}_{URL,SHA256}`. The legacy unsuffixed URL/SHA pair
remains a 4B fallback, but the 2B pair is still required before translation can be
included in a release.

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

DMGs are stored only in S3. GitHub Releases are optional legacy metadata and
S3 download links, not duplicate binary attachments. Configure these repository
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
The macOS updater checks `/channels/<channel>/latest.json`; the release index is
for catalog/download-site consumers and is not the updater endpoint.
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
