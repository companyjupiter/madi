# AI reconciliation boundaries

The shared FileWorkflow now connects the optional AI setting to conservative
speaker/language plans, revision-checked forced-language ASR, the original result
card and speaker-only undo. Both file and live sessions use the existing DNA
broker. The shipping Swift app remains the behavior baseline. Calendar/voice
identity side effects and final summary/title producers are still separate
migration work; native screen/interaction acceptance remains unverified.

## Validated plan and shared DNA client

`madi_core::reconcile` preserves the unchanged `TranscriptReconciler` instruction,
numbered prompts, acoustic/decode-risk marks and 800-Character batches without
renumbering. Rust uses grapheme boundaries, including CRLF and attached combining
marks. The parser preserves directional merges, shared surviving targets,
chain/cycle rejection, first accepted relabel/language flag, correction limits,
allowed-speaker membership and the acoustic relabel gate. Fixed session language
only permits a flag toward that same language. Unknown-speaker exclusion remains
the controller's responsibility, exactly as in Swift.

`ReconcileClient` attaches to the session's existing `DnaBroker`. It submits
post-session turns with preserved newlines; caption work keeps priority and
pressure. Its owned client lease detaches without clearing caption pressure.
Only matching client/request identities may drain the batch counter. Queued
cancellation keeps the active turn; retired and duplicate completions cannot
finish a replacement request. Empty and failed parts preserve the original
SummaryEngine aggregation: if every part is empty or OK, the result is OK. This
means no corrections, not a claim that inference succeeded. No second DNA model
process is created by the client.

## Forced-language audio ownership

`CorrectionTask` accepts only an owned committed WAV lease and native resources.
The crop follows `WavWriter.crop16kMonoPCM`: canonical PCM16/mono/16kHz admission,
declared/available payload bounds, floor/ceil sample boundaries, 0.2-second pad
and an empty-crop error. It writes a new private clip and retains the input
lease until the child is reaped. It never edits or deletes selected user files.

The one-shot ASR launch preserves the original model/WAV/BPE arguments, asset
working directory, DIAR=0, AUDIO_CTX=auto and forced WHISPER_LANG_ID, with STREAM
and APP_FILE removed. Strict UTF-8 and the original TRANSCRIPTION section parser
control the result. The normal deadline is 45 seconds. Cancellation and deadline
first terminate the owned child and escalate after two seconds if necessary;
only then can the clip and its input directory retire. Cancelling a caller's
wait leaves its join handle owned. Dropping the adapter requests the same cleanup.
The bounded escalation is the native supervisor's existing teardown behavior;
it avoids waiting forever on a child that ignores termination.

## Evidence

- 360 unchanged Swift cases compare prompts, batches, grammar plans, language
  gates, part aggregation, WAV crop bytes/errors and one-shot output parsing.
- Three real-child broker tests cover a single shared process, caption pressure,
  multi-part ordering/newlines, queued cancellation, crash drain and retired
  callbacks. Three correction process tests cover forced launch settings,
  padded clip bytes, unchanged input, invalid/empty output, failed exits,
  cancelled wait, timeout, drop and process/file cleanup.
- Five deliberate mutations are detected: reversed merge direction, absent
  acoustic relabel gate, accepting retired replies, inherited STREAM and
  missing crop padding.
- The explicit installed-Metal probe uses the pinned public JFK input only. The
  Rust adapter and unchanged Swift WavWriter/SessionOneShotTranscriber return
  exactly the same text for seconds 2..5 with 0.2-second padding (3.4 seconds,
  108,844 WAV bytes). The input segment/source/model/engine remain unchanged;
  no microphone is opened. This is behavior parity, not ASR accuracy acceptance.

```sh
python3 scripts/check_reconcile_parity.py
python3 scripts/check_reconcile_parity.py --rust-only
cargo test --locked -p madi-platform reconcile_client
STREAM=1 APP_FILE=1 cargo test --locked -p madi-platform language_correction
cargo run --locked -p madi-platform --example language_correction_smoke -- \
  /absolute/engine /absolute/model /absolute/assets /absolute/public-jfk.wav /absolute/output
xcrun swiftc -parse-as-library apps/macos/Sovereign/Audio/WavWriter.swift \
  apps/macos/Sovereign/Session/SessionOneShotTranscriber.swift \
  tests/parity/LanguageCorrectionProbe.swift -o /absolute/output/swift-probe
/absolute/output/swift-probe /absolute/engine /absolute/model /absolute/assets \
  /absolute/output/reference-segment.wav
```

The public input SHA-256 is
`59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e`.
See `../evidence/macos-reconcile-boundaries-2026-11-05.json` for source pins and
results. Local probe output is in `out/language-correction-runtime`.

## Connected controller

Finalization first saves the uncorrected transcript for durability, then admits
AI only when enabled, at least four lines exist and native DNA resources are
available. Failed sessions do not launch correction. Recording on a Mac with at
least 16 GiB arms the original 120-second timer. A mid pass needs four stable
lines after excluding the last two, no committed ASR in flight and no caption
queue/backlog. It may relabel uncertain lines but defers speaker merges to the
final pass. An in-flight mid snapshot cannot be overwritten by finalization;
the final request is admitted only when that cycle completes.

Plans resolve captured UUIDs against current transcript lines and current
acoustic margins. Unknown speaker 255 is excluded from model corrections. Two
distinct explicit names prevent a merge; surviving names and transcript labels
change together. Undo restores speaker overlays and saved names while preserving
language/manual text edits. It uses the original note and undo labels, native
12-point wand symbol, card padding and color tokens. Native visual comparison is
still required.

Committed live WAV leases remain ordered by session offset. Each language job
selects the last retained segment beginning no later than line start + 0.05 s
(or the first segment), and captures the line revision before queuing. Jobs run
serially, crop with the existing padding, and apply nonempty output only to that
same revision and generation. Accepted changes use the shared translation
invalidation/retranslation path without learning AI text as personal vocabulary.
Unavailable file-mode audio keeps the original text and the original diagnostic
note. Progress drives the existing Correcting pipeline status. Final correction
results checkpoint the owned archive. Reset/replacement/failure cancel and join
owned ASR work; normal shutdown drains final AI and translation work before
retiring the broker and audio.

Native process/workflow tests cover immediate and final saves; opt-in/model/line
admission; failure exclusion; acoustic and Unknown guards; name conflict and undo;
stale replies; shutdown; mid/final ordering and ASR pressure; selecting two
separate audio segments; manual edits during correction; stale translations;
and reset during a real held child. These scripted engines prove controller
ownership and ordering, not model quality or microphone/UI acceptance.

The opt-in installed-engine workflow probe also passes with public JFK PCM:
the packaged Metal ASR produces four lines, the shared DNA4B process returns
`MERGE 1 2 / MERGE 3 4`, and current speaker validation rejects these nonexistent
IDs. The immediate archive is present before AI admission and the final archive
matches the current store. Source/model/engine hashes remain unchanged and reset
releases all owned audio. This exercises real engine transport and finalization;
it does not establish correction quality or an applied real-model language job.
Use explicit resource paths to run it without opening an audio device:

```sh
MADI_PROBE_BIN=/absolute/app/Contents/MacOS \
MADI_PROBE_ASSETS=/absolute/app/Contents/Resources/assets-small \
MADI_PROBE_MODELS=/absolute/existing/model/folder \
MADI_PROBE_SOURCE=/absolute/public-jfk.wav \
MADI_PROBE_OUTPUT=/absolute/probe-output \
cargo test --locked -p madi-platform \
  file_workflow::reconciliation::tests::metal_probe::actual_metal_asr_and_dna_reconciliation_preserve_public_audio_and_final_archive \
  -- --ignored --exact --nocapture
```

See `../evidence/macos-reconcile-workflow-2026-11-05.json` for the 210 default
Rust checks, installed-engine result, five detected mutations, native/portable
name comparison, app/package checks and Windows checkout fix.

## Name comparison compatibility

macOS uses the original Foundation `caseInsensitiveCompare`. The portable Rust
comparison retains its conditional UTF-16 folding, canonical decomposition,
combining-mark collection and 64-scalar buffer boundary. A single normalized
case-fold key is insufficient: it changes Greek combining-mark and shared-high-
surrogate cases. The oracle retains those counterexamples. A generated table
pins 1,552 fold mappings and 2,237 grapheme-extend scalars from Foundation; native
validation checks the host's unchanged comparison, and portable validation checks
the captured baseline. Host Unicode version differences are reported separately.
The CoreFoundation implementation used as algorithm reference is
[CFString.c](https://github.com/swiftlang/swift-corelibs-foundation/blob/main/Sources/CoreFoundation/CFString.c).

```sh
cargo test --locked -p madi-platform file_workflow::reconciliation
python3 scripts/check_reconcile_names_parity.py
python3 scripts/check_reconcile_names_parity.py --rust-only
```

Calendar attendee matching, voice enrollment/auto-recognition, coach refresh,
and deferred final summary/title execution must be connected at the same cycle
boundary. They are not implemented by this slice. Exact native UI/UX and actual
simultaneous ASR/DNA acceptance also remain open.
