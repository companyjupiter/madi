# Tauri migration status

Updated 2026-11-05. **Migration is active, not complete.** macOS and Windows are
the initial targets; the user has prioritized macOS and deferred Windows GPU
hardware until later. The source baseline is Madi `c1390c7` / 0.4.1.

| Gate | Current evidence | Still required |
|---|---|---|
| G0 baseline | Source/state inventory; 28 actual AppKit color tokens in light/dark; original artwork hashes; native dark Korean first-run/setup captures; strict-asset Swift build and model downloads | Complete screenshot/action matrix, deployment-version match, fonts/SF Symbols and Windows exceptions |
| G1 feasibility | Rust parser differential; macOS Tauri host builds and starts; Windows Tauri debug host builds in CI; fixed-model Windows LLM runners pass Windows CPU/PTX CI | Full native interaction coverage, Windows ASR, GPU/model inference, audio/caption/calendar feasibility |
| G2 UI | Start-screen candidate with native Rust IPC exercised; native comparison corrected frame/spacing; ko/en/ja text; model guide, file/live transcript, transport, workspace/export and five-tab Settings candidate connected to Rust | Complete native visual/UX comparison, full device/file/model interaction, native Settings toolbar/form match, complete transcript/workspace/AI/overlays |
| G3 macOS core | Parsers, lifecycle, typed file/live configuration, native decode/ASR, transcript/edit differentials, shared file/live workflow and provisional previews, native replay and real ASR, verified model downloads and first-run admission; actual file-picker/JFK transcript delivery exercised | Complete file-screen interaction matrix, complete live UI and preview visual acceptance, DNA admission/watchdog consumers, storage/migration, system/mixed audio and hardware matrix, complete model UI lifecycle, AI policy and product end-to-end |
| G4 Windows | SovereignLLM experimental PE executables exist | GPU numerical/quality/performance, ASR, WASAPI, decoding, full product integration and Windows 11 device validation |
| G5 release | Experimental host is isolated and release builds are disabled | Licensing/package audit, signing, installer/update migration, rollback and all earlier gates |

## Measured checks

- Native file-line playback is connected through a private source-path owner,
  generation-checked main-thread AVPlayer adapter and the original detail-row
  play/pause controls. The unchanged shipping LinePlayer supplies seek/toggle
  behavior; reset, archive opening, replacement and quit retire playback. The
  host reads a bounded source identity instead of copying the whole transcript
  for meter updates. Source/lifetime tests and three deliberate mutations pass.
  Local suites pass 179 Rust tests, strict clippy, five IPC/queue checks, 20 native
  artwork cases and the rebuilt app/package checks. Actual native automatic
  boundary tests FAIL on this Mac: an independent original and minimal AVPlayer
  reproduce a CoreAudio output-start timeout, error -66681. Explicit stop/drop
  and same-line toggle pass. Native UI comparison is NOT_RUN while locked.
  See `runtime/LINE_PLAYBACK.md` and
  `evidence/macos-line-playback-2026-11-05.json`. This is not playback acceptance.

- Caption window lifetime now follows the original controller: patient disable
  releases the patient window, while hiding the whole overlay preserves both.
  Re-enable waits for native destruction; fresh instance generations reject old
  snapshot/close/resize work. Eight desktop tests and two deliberate lifecycle
  mutations validate the ownership rules. Strict clippy, frontend build/contracts,
  18 native artwork cases, app build and relocated package checks pass locally.
  See `evidence/macos-caption-lifecycle-2026-11-05.json`.
  `cd0526f` CI passed 174 Mac and 147 Windows Rust tests, but the jobs failed:
  Windows found a callback reachable only through the macOS workflow, and macOS
  found the new caption symbols missing from the old 13-symbol oracle. The
  callback is now also bootstrapped from the common file snapshot; the artwork
  oracle covers all 18 symbols without removing old checks. The Mac 15 artifact's
  1,500 caption results match original Swift and their pinned bytes are verified.
  Both push and PR CI at `d1e5032` now report success on macOS 15 and Windows
  2022 (runs 41905723699 and 41905730555). This is the caption follow-up before
  line playback; native window interaction remains NOT_RUN.

- Staff/patient caption overlays now connect the shared file/live snapshots and
  preference owner to native windows and separate renderer capabilities. The
  original interim-translation-off decision is retained. A bounded two-line
  projection keeps the true tail age; stale callbacks and panel failures cannot
  automatically reopen disabled captions. Original Swift computations match
  1,500 cases, and deliberate source-pairing/age mutations are detected. Local
  validation passes 174 Rust tests (28 core, 127 platform, 14 protocol, 5 desktop),
  five frontend contract/queue tests, formatting, clippy and the rebuilt macOS
  app plus relocated package/native-capture replay (17 direct notices). See
  `runtime/CAPTION_OVERLAY.md` and
  `evidence/macos-caption-overlay-2026-11-05.json`. Native visual, focus, drag,
  Spaces/fullscreen and monitor acceptance remain NOT_RUN while the Mac is
  locked. The subsequent CI failure and follow-up are described above.

- Desktop CI at `d37d945` is green on macOS 15 and Windows 2022. Downloaded
  executable/package hashes, clean source manifests and reference result bytes
  were verified, including the native Swift cache result on macOS 15. That host
  has seven Unicode mapping differences from the portable baseline; its native
  result equals the original Swift result. Mac passes 169 Rust tests; Windows
  passes 142, the shared-reader replacement probe and all 50 archive repeats.
  Both standalone builds finish. See `evidence/desktop-ci-d37d945-2026-11-05.json`.
  This verdict covers the cache/archive fixes, before the caption integration.

- Windows `885317f` passes 142 Rust tests, the shared-reader replacement probe
  (legacy persist reproduces OS error 5), and 50 concurrent archive repetitions.
  Its cache result bytes also match the pinned reference. The job then fails a
  starter-file hash: Windows CRLF checkout changes the copied FAQ JSON bytes.
  An isolated autocrlf checkout reproduces the mismatch without changing JSON
  values; a file-specific LF rule restores the exact pinned hash. Failure reports
  now retain the differing fields. See
  `evidence/windows-cache-checkout-2026-11-05.json`. The later `d37d945` verdict
  above verifies the fix; Windows standalone build was not reached in `885317f`.

- Desktop CI for `6e90399` and `fb69224` exposed two remaining platform issues:
  macOS 15 Swift lowercase differs from Rust for some Unicode scalars, and the
  repeated Windows archive checkpoint test again returned OS error 5. The
  compatibility follow-up adds a small native Swift case-conversion bridge,
  Windows std::fs::rename checkpoint replacement with a shared-reader regression,
  and join-before-panic test cleanup. Local Mac 27 validation passes 169 tests,
  all 394 native/portable cache cases, formatting/clippy and rebuilt app/package
  checks. The later `d37d945` CI verdict above verifies both platforms. See
  `evidence/platform-cache-compatibility-2026-11-05.json` and
  `runtime/WINDOWS_ARCHIVE_REPLACEMENT.md`.

- The empty-cache backfill follow-up now closes consumed target keys even when
  the revision-guarded store rejects the empty text. A shed coalesced request
  followed by single-line cache reuse reproduced two remaining keys where only
  the uncached target should remain. The fix reaches zero after that target
  completes, without changing transcript content or suppressing the empty cache
  language. Its mutation is detected. The latest local source passes 169 Rust
  tests (28/127/14), formatting, clippy, macOS debug app build and relocated
  package/decoder/native-capture checks. See
  `evidence/macos-empty-cache-backfill-2026-11-05.json`.

- At `6e90399`, FAQ persistence and committed cache reuse connect to the native owner.
  Exact normalized hits populate revision-guarded transcript translations and
  the owned archive; partial hits queue only missing targets. A real engine
  crash previously left 14 shed backfill keys pending with an empty queue; the
  regression now reaches zero without fabricated translations or restart loops.
  Existing malformed FAQ bytes are preserved, and concurrent first use publishes
  one complete starter bank. Swift cache comparisons cover 394 cases, all
  1,112,064 Unicode scalars, 7,200 LRU operations and all 15 starter entries.
  A public JFK recording reaches an isolated preset FAQ translation and archive
  in about 1.5 seconds, preserving its input and bank. This checks actual ASR and
  cache integration, not DNA inference or translation quality. See
  `runtime/TRANSLATION_CACHE.md` and
  `evidence/macos-translation-cache-2026-11-05.json`. The original explicitly
  disables interim translation and committed token streaming in
  `LiveFeatureWiring.swift`; the candidate preserves those product decisions.
  Porting the dormant interim producer is future redesign work. Committed caption
  UI acceptance and ambiguous FAQ source-column matching remain open.
  Native GUI checking remains unavailable
  while the Mac is locked. The final local source passes 168 Rust tests
  (27/127/14), formatting, clippy, both cache comparisons and the existing
  committed/client comparisons. Three deliberate mutations fail the intended
  regressions and are restored. The rebuilt macOS debug app and relocated
  package/decoder/native-capture replay also pass.

- Committed translation now reaches the shared file/live workflow, display
  snapshots and owned Markdown archive. It connects trusted model admission,
  source-language routing, stable/coalesced scheduling, source revision gates,
  tail deadlines, idle/stop backfill and reset/quit cleanup. DNA busy/aging now
  gates provisional preview admission. A real public JFK recording produces a
  Korean translation and persists it in about 5.5 seconds with no remaining
  queue/backlog, while preserving the original audio. Unchanged Swift grouping
  and routing match 360 cases / 8,005 rows; seven process-backed workflow tests
  cover stale replies, reset, setting changes, tail timing and final saving.
  Three deliberate revision/archive mutations are detected and restored. See
  `runtime/COMMITTED_TRANSLATION.md` and
  `evidence/macos-committed-translation-2026-11-05.json`. Cache integration is
  described above; committed caption overlay, complete backlog HUD and actual
  live/UI acceptance remain open.
  That source passes 161 Rust tests (26/121/14), formatting, clippy,
  both grouping/routing comparisons and a rebuilt standalone macOS debug app.
  Its relocated package/decoder/capture replay also passes. `c996b2c` desktop CI
  passes on macOS (161 tests) and Windows (133 tests plus 50 archive repeats),
  with downloaded binaries, packages and committed/client result bytes verified
  in `evidence/desktop-ci-c996b2c-2026-11-05.json`. The cache follow-up is verified
  by the later `d37d945` receipt above.

- The native translation client now executes the shipping queue/prompt/output
  state through the shared DNA broker. Its 165 Swift scenarios / 6,767 operations
  preserve request/callback order, partial throttling, prefix caches, retries,
  context reuse, forced prefixes and queue counts. Ten real process tests cover
  recovery, replacement, terminal draining and cleanup; a queued-attachment
  cancellation leak was reproduced and fixed. Two intentional mutations are
  detected. A real Metal DNA4B probe completes three public-text translations
  and a second client's request in one reaped process, with identical full
  before/after engine/model hashes. See `runtime/TRANSLATION_CLIENT.md` and
  `evidence/macos-translation-client-2026-11-05.json`. The file/live session's
  committed scheduling/revision/backfill follow-up is described above; committed
  caption overlay and complete product translation/UI acceptance remain open.
  The final local workspace passes 151 Rust tests (23/114/14), formatting,
  clippy and both client comparisons; the 3,574 output/queue and 760 broker
  policy comparisons also remain green.

- Pure translation scheduling, prompt and output policies now match 3,574 live
  Swift oracle cases, including 6,300 queue operations. Unicode grapheme boundaries,
  reserved interim admission, revision replacement, example reuse/echo/replay,
  retry scripts, runaway bounds and guarantee interval bits are preserved. Six
  intentional mutations are detected and restored. See
  `runtime/TRANSLATION_POLICY.md` and
  `evidence/macos-translation-policy-2026-11-05.json`. The translation client,
  broker connection, revision acceptance and stop-time backfill were connected
  in the later slices described above. Interim translation stays disabled as in
  the original; these isolated policy checks are not product acceptance.
  The final local snapshot passes 141 Rust tests (23/104/14), formatting,
  workspace clippy, the live Swift comparison and the pinned-reference comparison.
  Revision `138a741` now completes macOS/Windows Desktop CI successfully with
  141/113 Rust tests, the 3,574 policy cases and 50 Windows archive repeats.
  Downloaded binaries/package and translation result bytes are verified in
  `evidence/desktop-ci-138a741-2026-11-05.json`. That receipt precedes the client
  connection above and does not establish its CI result.

- The shared native DNA broker now has one resident process, caption-first/FIFO
  scheduling, caption-pressure admission, prefix registration, queued cancellation
  and bounded watchdog recovery. Its 760 policy cases match unchanged shipping
  Swift. Real child-process tests cover late-response quarantine, restart limits,
  callback resubmission, blocked stdin, closed stdout and reaping. See
  `runtime/DNA_BROKER.md`; product translation/AI consumers and live-preview DNA
  admission remain unconnected, so this is not product translation acceptance.
  The final local workspace passes 141 Rust tests (23/104/14), formatting and
  clippy. Two mutation trials are detected. The real Metal DNA3 4B probe serves
  two clients, a prefix registration and three turns in one reaped process;
  full before/after model and executable hashes match. Evidence:
  `evidence/macos-dna-broker-2026-11-05.json`.
  Its revision `672de1e` also completes macOS/Windows Desktop CI successfully:
  141/113 Rust tests, 50 Windows archive repetitions and all 760 DNA policy cases
  pass. Downloaded executable/package/runtime hashes and preview/DNA result bytes
  are verified against clean build manifests in
  `evidence/desktop-ci-672de1e-2026-11-05.json`. This receipt precedes the pure
  translation policies above; their CI must be assessed at their own revision.

- Preview revision `a29470d` passed Windows Rust tests and 50 archive repeats,
  but its preview comparison stopped while Python decoded UTF-8 Swift source
  with the runner's default cp1252 encoding. Explicit UTF-8 reads/writes now
  pass the same 1,409 cases under simulated cp1252 defaults and against native
  Swift. CI treats implicit text encodings in this check as errors. This is a
  tooling fix. Corrected revision `cecb1f9` passes every macOS/Windows job step;
  downloaded executables, preview results and the macOS archive are verified.
  It has 127/104 Rust cases and 50 Windows archive repetitions, and the workflow
  is now complete with a successful conclusion. This result precedes the DNA
  broker changes above; see
  `evidence/desktop-ci-cecb1f9-2026-11-05.json`.
  See `evidence/preview-ci-encoding-2026-11-05.json`.

- Live previews now connect rotating capture WAVs, latest-only scheduling,
  language lock and committed-job priority to the shared workflow and gray
  transcript continuation. PreviewTrim, source agreement, seam deduplication
  and grapheme progression match 1,409 cases from unchanged shipping Swift.
  Process regressions cover stale/root/pause rejection and ensure preview text
  cannot enter the archive/export. A public-fixture Metal probe verifies two
  isolated previews (including forced-prefix echo removal), then committed
  transcription/FLUSH in the same process. See `runtime/LIVE_WORKFLOW.md`.
  The local suite passes 127 Rust tests (23/90/14), four IPC/queue tests,
  TypeScript/Vite and workspace clippy. Evidence is retained in
  `evidence/macos-live-preview-2026-11-05.json`.
  DNA caption admission and actual preview WebView/native comparison remain open.

- Workflow revision `8cb5f54` passed macOS and Windows Desktop checks. Downloaded
  executables, runtime assets and the macOS archive are hash-verified in
  `evidence/desktop-ci-8cb5f54-2026-11-05.json`: 123 macOS / 102 Windows Rust
  cases plus 50 Windows archive repetitions. Both manifests now report clean
  source state. These results precede the preview connection above; the Linux
  dependency-review finding and Windows archive-race root cause remain open.

- The macOS record button now connects permission preflight, 3/2/1 countdown,
  native live ASR, pause/resume/stop/mic controls, the lifecycle clock and shared
  transcript/archive presentation. Quit joins the final tail/ASR/archive before
  exiting; closing the last visible window no longer leaves the hidden Settings
  process alive. A real microphone observation reached pause, back confirmation, Done,
  saved-record close and setup return. It exposed an empty automatic filename,
  now corrected to the shipping Foundation timestamp title. The observed file
  was recovered without changing its bytes; no microphone content is committed.
  Three workflow regressions and the native callback-identity regression extend
  the local Rust suite to 123 cases (21/88/14). See `runtime/LIVE_WORKFLOW.md` and
  `evidence/macos-live-workflow-2026-11-04.json` for checks and explicit gaps.
  UI/UX equality and full live product acceptance remain incomplete.

- Live-executor revision `8ae884c` passed macOS/Windows Desktop checks, primary
  CI and CodeQL. Downloaded push artifacts are hash-verified in
  `evidence/desktop-ci-8ae884c-2026-11-04.json`: 119 macOS / 102 Windows Rust
  cases and 50 repeated Windows archive checks. Its build manifests explicitly
  record generated untracked `scripts/__pycache__/` with empty tracked source
  diffs; this is not clean-worktree provenance. New workflow CI disables Python
  bytecode generation. The separate Linux dependency-review finding remains
  open. These CI results precede the live UI/workflow changes above.

- The macOS live executor now connects native capture to Rust-owned WAVs and the
  resident ASR process. FIFO pause/resume markers preserve input ordering;
  Stopped acknowledgement and tail delivery precede FLUSH. Seven process-backed
  regressions cover startup, pause/tail retention, interruption, reset races,
  premature engine completion and teardown faults. The real native-replay/Metal
  probe yields three WAV jobs, 28 words, a finalized JFK transcript and exactly
  one completion, with preserved source/model data and clean owned scratch.
  2,406 live configurations match extracted shipping Swift. That executor revision passed 119 Rust cases (21/84/14) and clippy. Its
  subsequent recording UI/workflow and preview connections are described above;
  watchdog, AI and Windows native capture remain open. See
  `runtime/LIVE_SESSION.md` and `evidence/macos-live-session-2026-11-04.json`.

- Capture-pipeline CI revision `ab6a88a` passed macOS but failed the Windows
  pinned reference check. Windows checkout filtering reproduced six changed
  source hashes due to missing LF attributes. `9490c40` fixes those attributes
  and preserves mismatch details/results in CI artifacts; all nine source
  hashes match under the same filtering locally. Both push `41799517167` and
  PR `41799523899` reruns pass macOS and Windows, including the exact capture
  reference. The downloaded push artifacts are verified in
  `evidence/desktop-ci-9490c40-2026-11-04.json` (111/101 Rust tests plus 50
  Windows archive repetitions). These runs precede the live-executor additions.

- Rust post-converter capture and owned WAV pipeline now match the actual
  shipping AudioCapture methods over 113 sequences / 6,337 operations: 727
  committed segments, 519 previews and 3,164 bit-exact Float level events.
  Mixing/clamping, strict two-second stall, pause/drop, final tail versus abort,
  whole-input preview accounting, rotation and directory cleanup are covered.
  Native replay and the packaged debug probe use this pipeline. Real capture,
  full product live scheduling and the recording UI remain open; see
  `runtime/CAPTURE_PIPELINE.md` and `evidence/capture-pipeline-2026-11-04.json`.
  Local checks pass 111 Rust tests, four frontend tests, clippy and formatting;
  both deliberate arithmetic mutations fail their targeted regressions and pass
  after restoration. The rebuilt 96.20 MiB app passes strict relocation and
  native-to-owned-WAV cleanup checks. The CI repair and receipt are above.

- In-process macOS capture candidate: AVAudioEngine/ScreenCaptureKit and the
  original converter link into the Rust host with per-capture IDs, bounded PCM
  ingress, acknowledged stop and late-callback rejection. Eight native replay
  cases match 1,664,512 Swift PCM samples and 32 segments, with simultaneous
  cancellation/drop and missing-file cleanup. The copied app checks its linked
  replay, original usage strings and audio-input entitlement. Real devices,
  permissions and the recording UI remain open; see
  `runtime/NATIVE_CAPTURE_BRIDGE.md`.

  Revision `c2289f0` passes desktop push CI `41773521959` and PR CI
  `41773526449`: 103 macOS / 93 Windows Rust tests, four frontend tests,
  and 50 additional Windows archive repetitions in each run. The push artifacts
  have verified clean-source binary, package, runtime and notice hashes; the
  macOS native replay gate also passes. See
  `evidence/desktop-ci-c2289f0-2026-11-04.json`. After unlock, fresh local app
  launch, Cmd+, and native Save-tab switching passed with stored values intact.
  This smoke check does not establish full UI parity or hardware capture.

- Segmenter revision `9685cb4` passes desktop CI `41771408788`: 101 macOS /
  93 Windows Rust tests and four frontend tests, including live Swift and pinned
  segmenter gates. Downloaded clean-source executable/package/runtime/notice
  hashes are verified in `evidence/desktop-ci-9685cb4-2026-11-04.json`. This
  receipt precedes the new native capture bridge above.

  A duplicate PR run `41771414361` passed macOS but failed the Windows concurrent
  archive checkpoint regression (62/63 platform tests). Its boolean assertion
  did not retain the underlying file error. The separate passing push run does
  not close this intermittent failure. Error diagnostics and a 50-run Windows
  regression loop are added. Both `c2289f0` runs pass all 100 additional
  repetitions; the failure has not reproduced, and its cause and actual Windows
  fix remain open.

- Live PCM windowing foundation: the unchanged Swift segmenter and Rust match
  225 sequences / 24,347 snapshots / 2,676 segments, including exact PCM hashes,
  offset bits, speech flags, previews, mutable settings and final tails. Sixteen
  legacy fragmentation groups preserve identical PCM. Four regressions include
  RED→GREEN evidence for the source's retained adaptive peak. Native sample
  capture, resampling/mixing, WAV ownership, engine feeding and recording UI are
  **not connected by this change**; see `runtime/LIVE_SEGMENTATION.md`.

- Native-toolbar revision `44e2548` passes desktop CI `41769617691` with
  97 macOS / 89 Windows Rust tests, four frontend tests, all references and builds.
  Both downloaded artifact sets match clean source and recorded binary/package/
  runtime/notice hashes (`evidence/desktop-ci-44e2548-2026-11-04.json`). The form
  follow-up `1c1b969` also corrects the Save folder row and diagnostic-path line
  break in actual native captures; full UI parity remains open.

- Native macOS Settings toolbar candidate: actual AppKit buttons now replace
  the web tabs, with original SF Symbols, centered title and a 492×500 pt frame.
  All five native callbacks, selection highlight, close/reopen and ko/en/ja
  labels are exercised. Original/candidate captures both measure 984×1000 at 2×.
  Native body/caption font measurements, picker artwork, grouped note/button
  rows and the bottom inset improve the form match. Fine row metrics and text
  wrapping still differ; full UI parity remains **NOT_PASS**. Local checks and
  the relocated Metal/export probe pass for the 95.72 MiB candidate; see
  `evidence/macos-settings-toolbar-2026-11-04.json`.

- Settings integration `50ce8a4` passes desktop CI `41767977083` on both hosts:
  97 macOS / 89 Windows Rust tests, four frontend tests, all differential gates
  and builds. Both downloaded artifact sets match clean source, binary, package,
  runtime and 16-notice hashes in `evidence/desktop-ci-50ce8a4-2026-11-04.json`.
  This precedes the native-toolbar follow-up above.

- Settings UI candidate: five localized tabs connect the shared native owners
  with an explicit Settings-only command capability. Actual macOS checks pass
  menu/Cmd+, open, close/reopen with selected-tab retention, cross-window language
  propagation, auto-save toggling, localized folder-panel cancellation, glossary
  application/threshold changes, restored values after relaunch and model Finder
  selection. Native ordered glossary rows preserve exact Int64 labels. All 97
  Rust and four frontend tests, clippy, frontend/debug app and strict package
  checks pass; the 95.38 MiB relocated app produces 22 Metal words and five exports.
  Initial window height/accessibility-name gaps were corrected. This revision's
  web tab bar is superseded by the native follow-up above; form spacing, full
  control coverage, populated glossary and transfer/cancel UI remain open.
  Live/translation/AI/caption consumers are still incomplete. See
  `runtime/SETTINGS_CONTRACT.md` and `evidence/macos-settings-ui-2026-11-04.json`.

- Actual desktop CI reruns now pass both hosts: `da3b146` / `41764627797`
  (93 macOS / 85 Windows Rust tests) and `b68cbd6` / `41765167553`
  (96 / 88), each with three frontend tests, all references and standalone builds.
  Downloaded executables, macOS package/runtime and 16 notices match clean source
  provenance and hashes in the corresponding `desktop-ci-*` evidence receipts.
  This closes the earlier cp1252 failure and model-management owner CI gap;
  these runs predate the new Settings renderer. The separate Linux glib
  dependency-review failure remains unresolved.

- Settings model-management owner: explicit re-download, translation-only cancel
  and source-compatible presence refresh preserve first-run choice and installed
  bytes. Three new loopback transfer tests cover failure/retry, independent
  cancellation and dropped callers; repeated-cancel cleanup has RED→GREEN
  mutation evidence. All eight model service tests and 96 local Rust tests pass,
  along with formatting/clippy. The Settings integration above adds controls. See
  `runtime/MODEL_MANAGEMENT.md` and `evidence/model-management-owner-2026-11-04.json`.

- The text-pass revision `a6f4ba2` passed Windows Rust/frontend checks but its
  Korean-number reference script failed to decode UTF-8 source with Python's
  Windows cp1252 default. `da3b146` makes both new gates' text I/O explicitly
  UTF-8. A local cp1252-default reproduction fails before the fix and both
  portable gates pass after it; the actual rerun passes both hosts as recorded above. The original macOS job
  passes all gates and builds with clean, hash-verified artifacts in
  `evidence/desktop-ci-a6f4ba2-2026-11-04.json`. Windows completed 85 Rust tests,
  clippy and three frontend tests; its standalone build was not reached.

- Combined text-pass candidate: Korean number formatting matches 5,839 Swift
  inputs; combined glossary/number correction and the original stable scan match
  137 sequences / 4,679 snapshots. Target changes during file processing,
  32-row scans, held-word preview gating, manual same-text protection, final
  tail formatting, word identity and saved Markdown are covered. Local Rust
  tests pass 93 (12/67/14), and both live/pinned gates pass. Translation dispatch
  and live capture remain open; see `runtime/TEXT_PASSES.md`.

- Native UI verification resumed after the user unlocked the Mac. An actual
  fresh launch exposed `preferences_snapshot not allowed. Command not found`:
  five implemented commands lacked build-manifest/capability entries. The
  native registry/manifest/generated-permission/renderer contract test fails
  before the fix and passes after it. Fresh startup, current device labels and
  the upward device menu now work. The original five Settings tabs were captured
  for comparison; the Settings candidate and its actual checks are recorded above.

- Actual macOS file-panel selection of the public JFK fixture reaches completed
  transcription and non-overwriting Markdown autosaves. Font changes (16→18→16)
  and content/detail switching work through IPC. Native inspection also exposed
  feedback-driven shortening of `jfk.wav`/`madi`; preserving the full intrinsic
  text width fixes it in the relaunched app. Export selection revealed generic
  filename/folder defaults; the native panel now receives the saved meeting name,
  workspace folder and selected content type. A fresh run confirms `jfk 3.txt`
  in the `madi` folder and a successful native TXT save. The final 94.90 MiB
  candidate also passes strict package relocation and actual Metal inference
  (22 words), all five headless exports and source/model/cleanup checks. Full
  visual parity is **not passed**. See
  `evidence/macos-text-passes-and-ui-2026-11-04.json`; local screenshots are
  retained under `out/native-ui-2026-11-04/`.

- Personal vocabulary integration candidate: successful file line/word edits
  now learn through one isolated persistent owner, including when auto-apply is
  disabled. Incoming words, final display overlays and native file prompt terms
  use the same current glossary. Exact Swift matching/prompt comparison passes
  193 cases / 5,390 queries / 4,063 edit/similarity pairs; a single nondeterministic
  canonical prompt tie is explicitly bounded to the original surface spellings.
  Native Foundation restore matches all 254 storage cases. Local tests pass 92
  Rust tests (12/66/14), both portable references, clippy, frontend/debug app and
  strict relocation/package checks with 16 notices. The relocated Metal probe
  restores a synthetic glossary, admits its prompt, produces 22 words, durably
  learns an actual native-word edit and passes all five exports with preserved
  source/model/archive data and cleanup. Revision `c44dc26` passes desktop CI
  `41755961248` with 92/84 tests and clean hash-verified artifacts; its actual UI
  startup gap and the subsequent text-pass work are recorded above. Settings
  controls are now connected as described above; live capture and full real-user/native-UI acceptance remain open.
  See `runtime/GLOSSARY.md` and
  `evidence/macos-vocabulary-integration-2026-11-04.json`.

- The preceding personal glossary value revision: unchanged Swift storage and the original
  Settings row ordering match 254 decode/mutation cases / 4,799 states. Schema
  migration, canonical Unicode keys, disabled learning, retargeting, removals
  and numeric limits are covered. Core tests (12), portable reference, formatting
  and workspace clippy pass. Revision `8ddd3c3` passes desktop CI `41752275613`
  with 88/80 Rust tests and clean hash-verified binaries/package/runtime/notices.
  Its glossary report was retained in CI logs but omitted from artifact upload;
  the verified receipt records that distinction and the upload manifest is fixed.
  The integrations above were not part of that revision. See
  `runtime/GLOSSARY.md` and `evidence/macos-glossary-value-2026-11-04.json`.

- Settings contract candidate: schema-2 migration adds the original live/translation,
  diagnostics/review and caption preferences. Settings language, device and OSD
  changes remain transient; unrelated durable writes preserve the saved token.
  The uncapped four-target settings intent and response-speed floor match Swift.
  Live comparison passes 725 cases / 5,075 font steps / 105 caption blobs, including
  optional decoding and exact floating-point bits. Local checks pass 87 Rust
  tests (11/62/14), 601 ASR configuration cases, clippy, frontend/debug app and
  strict package validation. The relocated decoder/Metal probe receives OSD off,
  produces 22 words and completes all five exports with preserved source/model
  data and cleanup. Settings-window UI, live/translation/caption consumers and
  real-user migration acceptance remain incomplete. See `runtime/SETTINGS_CONTRACT.md`
  and `evidence/macos-settings-contract-2026-11-04.json`.
  Two frontend regressions also verify commit-before-start ordering and prevent
  queued file admission after a failed preference save; the previous queue
  fails the error regression.
  Revision `d12687b` passes desktop CI `41751342797` on macOS 15 / Windows Server
  2022 with 87/79 Rust tests, two frontend queue tests, all references and builds.
  Downloaded binaries/package/runtime/notices match clean provenance in
  `evidence/desktop-ci-d12687b-2026-11-04.json`.

- Setup/presentation candidate: the start-screen selections, language/appearance,
  transcript mode and font size now restore through a native serialized store.
  The Swift preference domain is read-only; transient paths and device IDs are
  excluded. Actual Swift initializers/AppStorage getters match 432 cases / 3,024
  font steps, including legacy coercions, preset overrides, four targets and
  unknown positive tokens. Atomic failure, equal-value first save, canceled IPC,
  owned shutdown and isolated relaunch have tests. Local checks pass 84 Rust
  tests (11/59/14), clippy, frontend and ASR configuration parity. Per-window
  AppKit appearance avoids Tauri's app-wide macOS theme override. Native visual,
  first-paint and real-user preference migration acceptance remain **NOT_RUN**.
  The 93.50 MiB debug app passes strict relocation/package checks with 16 notices.
  Synthetic settings survive an owner restart and feed the actual bundled
  decoder/Metal engine: 22 JFK words, workspace/archive and five exports pass;
  original source/model data and temporary cleanup are preserved. See
  `runtime/PREFERENCES.md` and `evidence/macos-preferences-2026-11-04.json`;
  the full Settings UI remains open. Revision `ec5b8d2` passed macOS CI but
  failed Windows clippy on a macOS-only import; `eb6b2e4` fixed that and passed
  Windows build checks before failing preference source-reference comparison.
  Downloaded macOS artifacts for both revisions have verified binary/package/
  runtime/notice hashes and clean provenance (`evidence/desktop-ci-ec5b8d2-2026-11-04.json`,
  `evidence/desktop-ci-eb6b2e4-2026-11-04.json`). `e3096ad` fixes reference path and
  source-ending portability; CI `41749413499` passes on both hosts with 84/76
  Rust tests, all references, standalone debug builds and macOS package checks.
  Downloaded binaries/package/runtime/notices match their reports with clean
  provenance (`evidence/desktop-ci-e3096ad-2026-11-04.json`).

- Workspace/export candidate: the macOS file screen now connects the fixed right
  panel, native folder selection, generation-bound saved meeting opening,
  isolated auto-save preferences and five manual export formats. Live Swift
  comparison passes 610 export cases / 3,502 cues, including 373 exact native
  JSON formatting cases; workspace comparison covers 2,017 nodes / 57 calendar
  cases. Actual native interaction/pixels and the export-format popover remain
  unverified. Local checks pass 78 Rust tests (11/53/14), clippy, frontend build,
  eight-symbol native metadata, debug app and strict relocated-package checks.
  The actual decoder/Metal engine yields 22 JFK words, then passes temporary
  workspace/statistics, isolated preference persistence and all five exports;
  source/model data and owned temporary cleanup are verified. The local receipt
  is `evidence/macos-workspace-exports-2026-11-04.json`. Revision `3fea691`
  passed desktop CI `41742398830` on macOS 15 / Windows Server 2022 with 78/70
  tests, all live/pinned references, builds and macOS package checks. Downloaded
  executables, archive, internal runtime and 16 notices match the hashes; both
  build trees and retained diffs are clean (`evidence/desktop-ci-3fea691-2026-11-04.json`).
  A follow-up restores Swift's rescan on same-folder selection and
  first-checkpoint refresh when a new session reuses a removed filename. The
  folder regression fails before the fix (one entry instead of two), then all
  seven workspace tests, clippy and the rebuilt/relocated package pass. CI for
  that follow-up passed at `caf062c` in desktop CI `41744113022`: 79 macOS /
  71 Windows tests, all gates and builds. Downloaded executable, archive, runtime
  and 16 notice hashes match clean build provenance
  (`evidence/desktop-ci-caf062c-2026-11-04.json`). See
  `evidence/macos-workspace-refresh-2026-11-04.json` and
  `runtime/WORKSPACE_AND_EXPORTS.md`.
- Archive foundation: Markdown/plain export and lossy reopen match unchanged
  Swift in 284 cases including 1,566 real fixture words. The session writer matches
  48 real-file sequences / 825 states; concurrency checks preserve 12 simultaneous
  writers. The optional workflow persistence now uses the production 30-second
  timer, final/failure checkpoints and generation-protected reopen. Local Rust
  checks passed 71 tests (11 core / 46 platform / 14 protocol) at `fd7c20e`.
  That revision passed desktop CI `41736625183` on macOS 15 / Windows Server
  2022 with 71/64 tests. Downloaded binaries, package, inner runtime and all 16
  direct notices match their recorded hashes; both source trees/diffs are clean.
  The separate dependency-review check still fails for Linux glib 0.18.5.
  The new workspace candidate connects persistence; actual user settings/archive
  migration acceptance is still open. See `runtime/TRANSCRIPT_ARCHIVE.md` and
  `evidence/desktop-ci-fd7c20e-2026-11-04.json`.
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
downloads. Setup choices restore through the isolated preference owner. Native setup selection/drop stages a
file; file start now connects to the timed workflow and transcript candidate.
The recording start button still emits a harness intent only.
Meeting saving and preference migration have the candidates described above;
real-user migration acceptance and the updater remain open.

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
native follow validation/low-confidence review, settings/glossary/AI policy, playback
or real-user migration acceptance. Workspace, exports and setup preferences now
have connected candidates and synthetic/native CLI evidence above. The recording start action still emits a harness intent.

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
