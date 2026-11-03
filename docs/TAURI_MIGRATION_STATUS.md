# Tauri migration status

Updated 2026-11-04. **Migration is active, not complete.** macOS and Windows are
the initial targets; the user has prioritized macOS and deferred Windows GPU
hardware until later. The source baseline is Madi `c1390c7` / 0.4.1.

| Gate | Current evidence | Still required |
|---|---|---|
| G0 baseline | Source/state inventory; 28 actual AppKit color tokens in light/dark; original artwork hashes; native dark Korean first-run/setup captures; strict-asset Swift build and model downloads | Complete screenshot/action matrix, deployment-version match, fonts/SF Symbols and Windows exceptions |
| G1 feasibility | Rust parser differential; macOS Tauri host builds and starts; Windows Tauri debug host builds in CI; fixed-model Windows LLM runners pass Windows CPU/PTX CI | Full native interaction coverage, Windows ASR, GPU/model inference, audio/caption/calendar feasibility |
| G2 UI | Start-screen candidate with native Rust IPC exercised; native comparison corrected frame/spacing; ko/en/ja static text, two themes | Complete native visual/UX comparison, full native device interaction/models, file staging, model gate, transcript/settings/workspace/AI/overlays |
| G3 macOS core | Translation/stdout/JSONL parsers, ordered delivery, deterministic lifecycle, typed file configuration, file effect executor with real native decode/ASR smoke, initial setup rules | Live lifecycle executor, storage/migration, audio capture, model admission, AI policy and product end-to-end |
| G4 Windows | SovereignLLM experimental PE executables exist | GPU numerical/quality/performance, ASR, WASAPI, decoding, full product integration and Windows 11 device validation |
| G5 release | Experimental host is isolated and release builds are disabled | Licensing/package audit, signing, installer/update migration, rollback and all earlier gates |

## Measured checks

- `cd apps/macos && swift test`: 718 tests, **2 skipped**, 0 failures on this Mac.
  The two capture-fragmentation tests need `MADI_EVENTS_JSONL` and
  `MADI_CAPTURE_STDOUT`; they are not counted as capture/inference validation.
- `cargo test -p madi-core -p madi-protocol -p madi-platform`: 49 tests pass
  locally on macOS (11 core, 14 protocol, 24 platform tests). The last committed
  model revision `3954f46` passed 49/43 macOS/Windows tests and package checks.
  First-run policy revision `a882fbd` also passed both platforms. The later
  inference runtime package still requires its own CI result.
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

The host currently assumes a ready-model setup fixture and holds choices in
memory. Native macOS file selection/drop now stages a file; start buttons still
emit a harness intent only. No recording, model
download, inference, file writing, data migration or updater is connected yet.

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
Swift policy tests pass. See `runtime/FIRST_RUN_MODEL_POLICY.md`; this does not
yet connect the native installer, first-run UI or app entry gate.

The next local package now includes the original rebuilt ASR engine, verified
DNA2B/4B executables, seven pinned runtime assets and their notices. The relocated
app resolves all runtime files internally, rejects every missing/linked runtime
file, and passes strict ad-hoc signature checks. A real JFK probe through its
bundled decoder/ASR/assets produces 22 words and 26 JSONL events with one completion,
no failures and clean owned scratch; the original is preserved. See
`runtime/NATIVE_RUNTIME_PACKAGE.md`, `evidence/macos-runtime-package-2026-11-04.json`
and `evidence/macos-bundled-asr-2026-11-04.json`. This is local package/runtime
evidence, not connected desktop transcription or full UI parity; its CI is pending.

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
