# Tauri migration status

Updated 2026-11-04. **Migration is active, not complete.** macOS and Windows are
the initial targets; the user has prioritized macOS and deferred Windows GPU
hardware until later. The source baseline is Madi `c1390c7` / 0.4.1.

| Gate | Current evidence | Still required |
|---|---|---|
| G0 baseline | Source/state inventory; 28 actual AppKit color tokens in light/dark; original artwork hashes; native dark Korean first-run/setup captures; strict-asset Swift build and model downloads | Complete screenshot/action matrix, deployment-version match, fonts/SF Symbols and Windows exceptions |
| G1 feasibility | Rust parser differential; macOS Tauri host builds and starts; Windows Tauri debug host builds in CI; fixed-model Windows LLM runners pass Windows CPU/PTX CI | Full native interaction coverage, Windows ASR, GPU/model inference, audio/caption/calendar feasibility |
| G2 UI | Start-screen candidate with native Rust IPC exercised; native comparison corrected frame/spacing; ko/en/ja text; model guide and file transcript candidate connected to Rust | Complete native visual/UX comparison, full device/file/model interaction, complete transcript/settings/workspace/AI/overlays |
| G3 macOS core | Parsers, ordered delivery, lifecycle, typed file configuration, native decode/ASR, transcript/edit differentials, timed file workflow, verified model downloads and first-run admission | Native file-screen delivery/interaction evidence, live lifecycle executor, storage/migration, audio capture, complete model UI lifecycle, AI policy and product end-to-end |
| G4 Windows | SovereignLLM experimental PE executables exist | GPU numerical/quality/performance, ASR, WASAPI, decoding, full product integration and Windows 11 device validation |
| G5 release | Experimental host is isolated and release builds are disabled | Licensing/package audit, signing, installer/update migration, rollback and all earlier gates |

## Measured checks

- Archive foundation: Markdown/plain export and lossy reopen match unchanged
  Swift in 284 cases including 1,566 real fixture words. The session writer matches
  48 real-file sequences / 825 states; concurrency checks preserve 12 simultaneous
  writers. The optional workflow persistence now uses the production 30-second
  timer, final/failure checkpoints and generation-protected reopen. Local Rust
  checks pass 71 tests (11 core / 46 platform / 14 protocol). The Tauri host's
  workspace/settings boundary is still unconnected and persistence remains
  disabled there; no existing user preferences or archive data were migrated.
  See `runtime/TRANSCRIPT_ARCHIVE.md` for scope and remaining product work.
- Transcript reading/follow candidate: the production TypeScript model matches
  unchanged Swift in 287 cases / 13,294 intermediate states. File transcription
  now uses the original top anchor; recording-only follow remains distinct from
  processing. The DOM adapter, new-transcript pill, native arrow artwork, 700 pt
  reading width and fade/inset values are connected. Native wheel/scrollbar,
  geometry, animation and pixels remain unverified. Local frontend, clippy,
  native symbol comparison and debug package checks pass. Follow revision
  `109f712` passed CI `41732929922` on macOS 15 / Windows Server 2022, including
  65/58 Rust tests and the live Swift / pinned frontend follow gate. Downloaded
  binaries, package, inner runtime and 15 notices match their hashes; build trees
  and retained diffs are clean. See `runtime/TRANSCRIPT_FOLLOW.md`,
  `evidence/macos-transcript-follow-2026-11-04.json` and
  `evidence/desktop-ci-109f712-2026-11-04.json`.
- Connected file workflow candidate: 65 local macOS Rust tests pass (11 core,
  14 protocol, 40 platform), including six new real-child workflow cases for
  stream/edit/fix delivery, cancellation/generation isolation, errors/retry and
  owned shutdown. Live Swift store comparison remains 309 cases / 5,947 exact
  snapshots. These are model/process checks; native file-screen interaction and
  visual parity remain unverified. See `runtime/TRANSCRIPT_MODEL.md`.
  The relocated app's actual decoder/Metal ASR also passes through this owner:
  22 expected JFK words at completion, timed edit publication with stable identity,
  reset/stale-edit rejection, preserved source hash/model metadata and clean scratch.
  The short real recording publishes its words at Done; pre-completion word/fix
  scheduling is separately verified with held real-child fixtures. The debug app
  and strict relocation/package checks pass. Local candidate evidence:
  `evidence/macos-file-workflow-2026-11-04.json`. Initial Windows CI at `fe0e71e`
  failed five workflow tests: Python fixture stdout used its host pipe code page,
  unlike the real engine's UTF-8 output. Forced ASCII locally reproduces the
  failure. Explicit fixture UTF-8 gives six passing workflow tests under the same
  restriction; production process behavior is unchanged. Corrected `acd4f5c`
  passed [CI 41731131476](https://github.com/companyjupiter/madi/actions/runs/41731131476)
  on both macOS 15 and Windows Server 2022: 65/58 tests, all references,
  clippy, frontend/standalone builds and macOS package checks. Downloaded binary,
  archive, inner runtime and all 15 notice hashes match; both source trees and
  retained diffs are clean (`evidence/desktop-ci-acd4f5c-2026-11-04.json`).
  See `evidence/file-workflow-fixture-encoding-2026-11-04.json`.
- `cd apps/macos && swift test`: 718 tests, **2 skipped**, 0 failures on this Mac.
  The two capture-fragmentation tests need `MADI_EVENTS_JSONL` and
  `MADI_CAPTURE_STDOUT`; they are not counted as capture/inference validation.
- `cargo test -p madi-core -p madi-protocol -p madi-platform`: 59 tests pass
  locally on macOS (11 core, 14 protocol, 34 platform tests), including ten
  model transfer/service tests. Download/UI revision `17c84fc` passed Windows tests but failed clippy on a
  Unix-only mutable binding; its macOS job passed in full with hash-verified
  artifacts (`evidence/desktop-ci-17c84fc-2026-11-04.json`). The correction also fixes interrupted-join ownership
  and explicit Unix lock release, with RED/GREEN regressions and three full local
  parallel passes. Corrected revision `cf259db` passed both CI jobs: 59 macOS /
  52 Windows tests, all reference checks, builds and macOS package verification.
  Both downloaded executables have verified hashes, clean source reports and
  empty source diffs; the macOS archive and inner runtime/notices are also verified
  (`evidence/desktop-ci-cf259db-2026-11-04.json`). These checks do not close native
  model UI interaction/visual gates.
- Transcript model: 301 word-merger cases / 1,974 snapshots and 309 store cases /
  5,947 snapshots match live unchanged Swift method bodies. Both include 1,566
  fixture word payloads. Exact identity, raw text, time/confidence, grouping,
  speaker changes/numbers, edits and translation provenance match. Explicit
  render delivery is compared; this model gate excludes timer scheduling and
  derived display caches. The timed workflow is tested separately above. The
  actual native JFK probe now feeds the store and produces the
  expected 22-word sentence with one completion and clean scratch. See
  `runtime/TRANSCRIPT_MODEL.md` and `evidence/macos-transcript-model-2026-11-04.json`.
  Committed revision `4f8e4de` also passed the complete desktop workflow on both
  platforms (59 macOS / 52 Windows tests, live Swift/pinned Windows comparisons,
  standalone executable builds and macOS relocation/package checks). Downloaded
  executable/archive/runtime hashes and all 15 direct notice files match, and
  both build source trees/diffs are clean. Evidence:
  `evidence/desktop-ci-4f8e4de-2026-11-04.json`. The clean local app package is
  separately recorded in `evidence/macos-transcript-package-2026-11-04.json`.
- The separate [dependency-review job](https://github.com/companyjupiter/madi/actions/runs/41725769189)
  fails for Tauri's Linux GTK dependency `glib 0.18.5`
  ([GHSA-wrw7-89jp-8q8g](https://github.com/advisories/GHSA-wrw7-89jp-8q8g)).
  Target-specific workspace dependency graphs select it on Linux and not on
  macOS arm64 or Windows x64. The advisory's fixed series is 0.20; 0.18.6 is
  unavailable in the registry. No allow-list or workflow bypass was added.
  This remains an unresolved PR check even if the desktop build jobs pass;
  see `evidence/dependency-review-4f8e4de-2026-11-04.json`.
- Model guide: 210 action-visibility cases match extracted unchanged Swift view
  rules. Nine byte-count cases and five native symbol dimensions match live
  Foundation/AppKit; generated owned PNGs contain visible/transparent pixels.
  These checks do not establish native UI pixel or interaction parity.
- `python3 scripts/check_translate_parser_parity.py`: **5,082** chunked input
  cases match the unmodified shipping Swift parser, in translation and summary
  modes. Unicode, malformed bytes, markers, forced-prefix/capability lines and
  empty turns are included. The corpus caught a leading BOM decoding difference,
  which was corrected. Event-stream SHA-256:
  `8c6f39fb05bf1701bd090fb244a42cfca7ba4ed112d9a8bf1b3083e9ae128d39`.
- `python3 scripts/check_transcribe_parser_parity.py`: **2,728 scenarios /
  10,424 events** match unmodified `EngineProtocol.swift`. Includes preview
  quarantine, both language lock versions, progress, speaker corrections,
  Unicode/grapheme boundaries and Swift-compatible hexadecimal/NaN parsing.
- `python3 scripts/check_structured_parser_parity.py`: **2,945** inputs match
  unmodified `EngineEvents.swift`, including **1,707** checked-in real transcript
  fixture lines, missing/wrong-type fields, defaults, Unicode, unknown events,
  trailing commas and duplicate keys. Arbitrary-precision `NSNumber` coercions
  outside the finite bounded engine contract are explicitly not reproduced.
- `python3 scripts/check_stream_process_parity.py`: **20** real-child-process
  scenarios match unmodified Swift `EngineProcess` delivery exactly: stdout
  fragmentation, UTF-8 splits, partial JSONL retained across barriers, JSONL
  before segment/flush callbacks, preview isolation and 1,000-segment immediate
  exit with an unterminated tail. The child is a fixture, not an inference
  engine. This differential now drives the real native supervisor instead of a
  standalone test pipe loop, retaining the unchanged pinned event hash.
- Session lifecycle: seven Rust regressions preserve the existing Swift tests'
  tail-before-FLUSH ordering, exactly-once finish, generation/engine identity,
  cancelled imports, startup/flush deadlines, countdown and elapsed time.
  [Effect executor contract](runtime/SESSION_PORT_CONTRACT.md) records the
  asynchronous capture-stop acknowledgment and owned-temp-file requirements.
  The native supervisor separately owns and removes its JSONL scratch directory;
  no selected-file deletion, microphone or complete effect executor is connected
  to this session core yet. Live Swift/Rust lifecycle comparison remains open.
- `cargo clippy --workspace --all-targets -- -D warnings`: passed with the explicit capability manifest. CI on the committed revision
  must confirm the other platform.
- `cd apps/desktop && npm run build`: TypeScript and Vite build pass.
- `cargo build --locked -p madi-desktop --features custom-protocol`: macOS
  standalone debug host builds. `npm run tauri dev -- --no-watch` also starts the
  native process. The packaged debug `.app` also builds and launches after adding
  the original ICNS. Native input-language and meeting-mode clicks exercised Rust
  IPC: Korean plus Lecture disables speaker separation/count controls as expected.
- Browser-only setup fixture was viewed at 1150×710 in light/dark. Local images:
  `out/desktop-parity/setup-{light,dark}-browser.jpg`. These are candidate renders,
  not the native golden images. Browser fixture selection does not emulate IPC.

## First CI result and compatibility correction

[Run 41690075166](https://github.com/companyjupiter/madi/actions/runs/41690075166)
at `957a537cb6eb5bc8f40ff198d0990f40ee32327f` is **overall failed**:
the Windows Server 2022 job passed unit tests, clippy and the standalone debug
Tauri executable build; macOS 15 passed those shared checks but failed the live
Swift translation-parser differential. This is not an all-platform green gate.

The failure exposed an OS/runtime difference: macOS 15 Foundation retains a
leading UTF-8 BOM, while the current macOS 27.2 reference consumes it. Rust now
has an explicit `Utf8BomPolicy`; the default remains the recorded 27.2 reference.
The live Swift comparison probes its actual runtime and selects the matching
compatibility policy. It never edits or filters the Swift events. A second,
independent check pins the canonical corpus and output hashes in
`design/parity/translate-reference.json` on **both** OSes, so the compatibility
check cannot silently change the cross-platform default. Any product selection
of the legacy policy and the supported native version baseline remain G0/G3
decisions; they are not silently inferred from the build host.

The stdout line corpus is also pinned in `transcribe-reference.json` and runs
on Windows without requiring Swift (`--rust-only`, explicitly reported as no
live Swift execution). The second run [41692423592](https://github.com/companyjupiter/madi/actions/runs/41692423592)
at `fe714b9` passed the translation comparison on macOS 15, then found a separate
stdout numeric syntax difference: its Swift runtime accepts uppercase `0X` and
symbolic `nan(foo)`, whereas Swift 6.4.2 on macOS 27.2 rejects them. The stdout
parser now exposes an explicit legacy float-syntax policy; its live comparison
probes that runtime and still checks the unchanged canonical default hash
independently.

[Run 41693205029](https://github.com/companyjupiter/madi/actions/runs/41693205029)
at `810ee299a4a28ec3f4d6e24c327382a44afc312d` passed **both macOS 15 and Windows
Server 2022**: formatting, 13 then-current Rust tests, clippy, frontend build,
translation/stdout reference checks and standalone debug Tauri builds. Windows
reported generated permission files changed during the build; provenance now
includes paths, and the next revision fixes their checkout line endings and
retains the exact build diff. Do not describe that historical tree as clean.
[Run 41694353597](https://github.com/companyjupiter/madi/actions/runs/41694353597)
at `689b897` passed both platforms with 17 tests and the JSONL/process comparisons.
[Run 41695232216](https://github.com/companyjupiter/madi/actions/runs/41695232216)
at `675ceec` passed both platforms with 24 tests, including the session lifecycle.
Downloaded executables match each report's size/hash; both revisions have clean
source trees and empty retained build diffs. The corresponding evidence JSON
files preserve these results. [Run 41698389122](https://github.com/companyjupiter/madi/actions/runs/41698389122)
at `3578632` also passed both platforms with verified clean-tree artifacts.
[Run 41700106422](https://github.com/companyjupiter/madi/actions/runs/41700106422)
at `5af3c19` passed macOS/Windows with 26/25 tests, read-only native discovery
comparison on macOS and clean verified build artifacts. [Run 41702228682](https://github.com/companyjupiter/madi/actions/runs/41702228682)
at `484bd23` passed both hosts with 34/33 tests, the supervisor Swift differential
and clean verified artifacts. [Run 41704044238](https://github.com/companyjupiter/madi/actions/runs/41704044238)
at `e5110db` passed both platforms with 39/33 tests and the extended Swift decode
tests; downloaded executable hashes and clean source trees are verified.
[Run 41705997661](https://github.com/companyjupiter/madi/actions/runs/41705997661)
at `cfdeecb` also passed both hosts with the macOS 39-case media staging differential
and clean hash-verified artifacts. No complete UI, audio or
inference gate is closed by these build results.

[Run 41706943657](https://github.com/companyjupiter/madi/actions/runs/41706943657)
at `2b5515a` failed the new Windows ASR configuration reference check: report source
keys used Windows backslashes, while the pinned reference uses repository-style
slashes. The report now serializes those keys with `as_posix()`. Reference hashes
and configuration behavior are unchanged. A corrected Windows CI run is still
required; the failed attempt is not counted as a green gate.
The correction passed [run 41707901563](https://github.com/companyjupiter/madi/actions/runs/41707901563)
at `8589468` on both hosts (40/34 tests and unchanged 601-case configuration hash).
[Run 41708512521](https://github.com/companyjupiter/madi/actions/runs/41708512521)
at `af3f203` then passed 46/40 tests including the six file-executor regressions.
Both revisions have downloaded, hash-verified artifacts and clean source trees.
[Run 41709809414](https://github.com/companyjupiter/madi/actions/runs/41709809414)
at `f829c20` passed both hosts, including the relocated macOS `.app`/decoder check.
Downloaded executables, the app archive and its inner decoder match their reported
hashes, with clean source trees and empty build diffs. See
`evidence/desktop-ci-f829c20-2026-11-04.json`.
[Run 41711822569](https://github.com/companyjupiter/madi/actions/runs/41711822569)
at `3954f46` passed the model manifest/integrity checks on both hosts with 49/43
tests; [run 41712443094](https://github.com/companyjupiter/madi/actions/runs/41712443094)
at `a882fbd` passed the 48-case first-run policy comparison too. Downloaded
executables match their reports, with clean source trees. Dedicated receipts
record the source/corpus/result hashes and limits.

[Run 41713919046](https://github.com/companyjupiter/madi/actions/runs/41713919046)
at `fb67b46` passed both hosts and the full relocated macOS inference package
check. Downloaded binaries/archive, inner decoder, three engines and seven assets
match their reports; clean trees and empty build diffs are verified in
`evidence/desktop-ci-fb67b46-2026-11-04.json`.

The macOS host now reads real model readiness and connects explicit first-run
downloads. Setup choices remain in memory. Native setup selection/drop stages a
file; file start now connects to the timed workflow and transcript candidate.
The recording start button still emits a harness intent only.
Meeting saving, preference/data migration and updater remain unconnected.

## SovereignLLM Windows engine

Implementation and private source remain in the separate SovereignLLM repo:
[draft PR #257](https://github.com/companyjupiter/sovereignLLM/pull/257).
The `DNA3.0-2B Q4_K_M` and `DNA3.0-4B Q4_K_M` forks each build one fixed-model
Windows x64 executable, with the current Madi protocol.

[Windows run 41686183745](https://github.com/companyjupiter/sovereignLLM/actions/runs/41686183745)
passed on engine commit `15a21711affa884a0b710d87f2effa06eed838ec`:
14 CPU unit tests, two invalid-startup process checks, both PE builds,
62 PTX partition/bounds contracts and six NVIDIA ptxas assemblies. Downloaded
PE sizes/hashes match the CI report; the engine repository records their
provenance in `docs/evidence/windows-dna3-2026-11-04.json`.

This establishes a Windows Server 2022 CPU build/test result. It does **not**
establish GPU inference, full-model tokenizer parity, numerical/translation/
summary quality, latency, VRAM usage, Windows 11 UI or concurrent ASR. No Windows
runner has been copied into Madi's release prebuilt directory.

## Native macOS baseline and next work

The user unlocked the Mac and completed Xcode authentication. First-launch setup
and the official Metal Toolchain 27B47 download succeeded. `make_app.sh` now
builds the original Metal engine and Swift app. The pinned runtime-asset archive
installed all seven files with checksum verification; `STRICT_ASSETS=1` produces
`out/parity-baseline-full/Madi.app`, and strict ad-hoc signature verification
passes. This is a local comparison build, not a signed/notarized release.

The original first-run UI downloaded and verified Whisper Q8 and DNA3.0-4B
Q4_K_M, then reached setup. Both native apps were captured in dark Korean mode.
The comparison exposed a 33-point extra Tauri titlebar height and inflated chip/
text spacing. The host now measures native chrome and sets the outer setup frame
to 1150×710 points, matching the observed Swift frame; CSS uses normal system
font metrics and non-layout inset chip outlines. Major block positions now align.
Titlebar appearance and glyph/width details still differ;
**this is not a pixel-parity pass**. Capture hashes, bundle/model provenance and
limits are in `evidence/macos-native-baseline-2026-11-04.json`.

Core Audio enumeration is now implemented in `madi-platform`: on this Mac its
five devices, their order/names and the default input exactly match unmodified
`AudioDevices.swift`. Rust selection preserves system-only-to-mic switching and
mixed-mode retention. The frontend resolves the real default name, refreshes on
focus/open, and flips a long microphone menu above the trigger. The packaged host
build and clippy pass, but the Mac locked again before the new menu could be
checked; this UI validation remains pending. No recording permission is requested.

The original strict-asset bundle also completed real Metal inference: the public
11-second whisper.cpp JFK clip transcribed successfully with diarization and
`FLUSH_END`, and DNA4B translated an authored Korean sentence to English. Captured
stdout/JSONL and the translated reply match original Swift vs Rust decoding,
including four translation chunk sizes. See
`evidence/macos-real-engine-smoke-2026-11-04.json`. This is a small engine smoke,
not a quality/performance benchmark or Tauri product integration.

The new Rust native process supervisor has also run the real Whisper engine on
that same clip: 22 word events, 26 JSONL events, flush before exit 0, no IO faults,
and its owned scratch directory removed. Eight process regressions cover tail and
JSONL ordering, FIFO stdin/EOF, blocked-input cancellation, SIGTERM escalation,
old/new process isolation, drop cleanup, cancellable waits, spawn failure and an
explicit inherited-pipe drain timeout. The full 20-scenario Swift differential
still matches the unchanged pinned hash. Details and limits are in
`runtime/ENGINE_PROCESS_ADAPTER.md` and
`evidence/macos-rust-supervisor-2026-11-04.json`.

Owned native file preparation is also implemented. A small AVFoundation helper
reuses the existing decoder/resampler; the Swift decoder gained an explicit
scratch-directory argument with the original default preserved. Five native Rust
tests and the extended Swift decode tests pass, including byte-identical PCM,
concurrent imports, cancellation/failure cleanup and original-file preservation.
The real JFK probe passed through decode → Rust ASR supervision → cleanup.
See `runtime/NATIVE_AUDIO_DECODE.md` and
`evidence/macos-owned-decode-2026-11-04.json`. Later revisions added the helper
bundle and file effect executor below; Tauri inference UI integration remains open.

Native file staging now uses the same AppKit chooser and UTType drop policy as
the original. Rust retains paths; the UI sees name/size and sends no arbitrary
filesystem paths. Selection clearing preserves originals. A 39-case live Swift
comparison passes, including Korean filename normalization and byte-size rounding.
The staged card, CTA state and middle truncation are implemented but their native
interaction/visual verification awaits Mac unlock. See
`runtime/NATIVE_FILE_STAGING.md`; this is not an end-to-end file transcription pass.

Typed file ASR configuration now matches the unchanged Swift launch construction
across 601 cases, with a pinned reference also checked on Windows. A real public
JFK decode/transcription/cleanup smoke passes even with conflicting engine options
in the parent shell. File-mode settings explicitly clear unset engine-owned flags;
this intentional isolation difference is documented in `runtime/FILE_ASR_CONFIGURATION.md`.
The file effect executor now connects native decoding, typed launch and ordered
engine/temporary-file teardown. Six real-process regressions pass locally, and
the real JFK clip produces Processing → Done with exactly one completion and no
owned scratch remaining. See `runtime/FILE_SESSION_EXECUTOR.md` and
`evidence/macos-file-session-2026-11-04.json`. Live capture effects, model admission,
storage/translation and desktop transcript UI remain open.

The native decoder is now bundled beside the Tauri executable and ad-hoc signed.
A copied `.app` outside the repository resolves and runs that helper with only
system tools on PATH, preserves the original synthetic input, and fails closed
when its copied helper is absent. Deep/strict signature verification passes.
The candidate is macOS arm64/14+ and is not notarized or released. See
`runtime/NATIVE_DECODER_PACKAGE.md` and `evidence/macos-desktop-package-2026-11-04.json`.
CI decoder packaging checks pass on `f829c20`; the later inference runtime bundle
is described below. Model admission and product UI wiring remain open.

The Rust model catalog now preserves all three asset pins, the 12 GiB model
recommendation and exact environment override behavior. Seventy selection and
27 integrity cases match unchanged Swift, plus ten actual-host override cases.
Full read-only Rust hashes verify the existing Whisper Q8 and DNA4B files without
downloads or model writes. Fast launch-size checks remain separate from full
install/reuse verification. See `runtime/MODEL_ASSET_INTEGRITY.md` and
`evidence/macos-model-integrity-2026-11-04.json`. Desktop admission and download
lifecycle are not connected by this layer.

The pure first-run policy is also ported: an existing Whisper installation enters
without a first-run choice; explicitly recommended setup waits for DNA only when
its engine is present. All 48 readiness/choice/variant combinations match the
unchanged Swift policy, including missing-only download totals. The original five
Swift policy tests pass. See `runtime/FIRST_RUN_MODEL_POLICY.md`; the native guide
and download service are now connected as described below.

The next local package now includes the original rebuilt ASR engine, verified
DNA2B/4B executables, seven pinned runtime assets and their notices. The relocated
app resolves all runtime files internally, rejects every missing/linked runtime
file, and passes strict ad-hoc signature checks. A real JFK probe through its
bundled decoder/ASR/assets produces 22 words and 26 JSONL events with one completion,
no failures and clean owned scratch; the original is preserved. See
`runtime/NATIVE_RUNTIME_PACKAGE.md`, `evidence/macos-runtime-package-2026-11-04.json`
and `evidence/macos-bundled-asr-2026-11-04.json`. This is local package/runtime
evidence, not connected desktop transcription or full UI parity. Its CI passed
on both platforms at `fb67b46`.

The macOS model guide now uses native readiness, byte-count formatting, lazily
generated SF Symbols and 26 original ko/en/ja string triples. Explicit actions
start pinned HTTPS downloads, verify complete size/SHA-256, preserve previous
files on failure, and atomically publish verified files. Cancel/retry, continuing
with Whisper while DNA downloads, duplicate starts and exit cleanup have real
HTTP/filesystem tests. The new `.app` builds, relocates and passes package checks;
it also retains all 12 direct-runtime notice files. See
`runtime/NATIVE_MODEL_SETUP.md` and `evidence/macos-model-setup-2026-11-04.json`.
Native click/visual validation is still waiting for Mac unlock; no actual user
model was re-downloaded or replaced for these tests. Network error text, exact
controls, settings model lifecycle and all product end-to-end gates remain open.
Follow-up ownership/lock fixes and failed-attempt context are recorded in
`evidence/macos-model-download-ownership-2026-11-04.json`.

The Rust transcript model preserves the original merge/group/edit policies with
live Swift differential evidence. The timed file owner now connects native
selection/start, progress, transcript/edit state, back/close cancellation and
AppKit copy/name commands to the file-screen candidate. Native click/visual
validation remains open; the candidate does not complete display caches,
native follow validation/low-confidence review, settings/glossary/AI policy, playback, workspace
or persistence. The recording start action still emits a harness intent.

1. Finish native setup behavior: verify real device selection/popup placement, keyboard
   behavior and file staging. Compare each with the original app.
2. Capture first-run/model lifecycle and remaining product screens, then implement
   them with the same state transitions and layout.
3. Connect the session effect executor and engine process supervisor, first using
   public file fixtures on this Mac; preserve the original user's data.
4. Validate light/dark, ko/en/ja, resizing, fonts and system dialogs on native
   windows. Keep visual gates open until measured.
5. Preserve the Windows CPU/PTX/build evidence; perform GPU/model and Windows 11
   device validation when the user provides the machine. Hardware is explicitly
   deferred, not a current macOS work blocker.

Madi work is in [draft PR #49](https://github.com/companyjupiter/madi/pull/49).
The working feature branches are `codex/tauri-ui-parity` (Madi) and
`codex/windows-dna3-engines` (SovereignLLM). Shipping macOS UI, data and the default
release channel remain the comparison and rollback baseline.
