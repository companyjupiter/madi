# AI reconciliation boundaries

The original controller has three distinct steps: ask the shared DNA model for
conservative speaker/language corrections; validate and apply its plan to the
captured line IDs; optionally crop retained audio and force a language for that
line's ASR. The first and third native boundaries, and the validation grammar,
are now available in Rust. **The FileWorkflow controller and result/undo UI are
not connected yet.** The existing AI setting does not establish an end-to-end
feature in the experimental host.

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

## Next controller integration

Preserve the opt-in/model/four-line admission, the 120-second stable-prefix timer
and caption-pressure gate, snapshot line identities and current acoustic margins.
Do not overwrite a mid-session request with a final snapshot: defer final work
until that cycle completes. Mid-session merges stay deferred. Apply explicit
speaker-name conflict protection and reversible identity changes before replacing
revision-matched line text. Retain ordered committed segments for audio selection;
file sessions have no such audio and keep their text with the original note.

Connect correcting/reconciling status, original result/undo presentation, archive
checkpoints and deferred final summary/title. Reset, replacement and shutdown
must cancel/join correction work before releasing audio or applying another
session's replies. Calendar, voice enrollment, summary/rail clients and native
UI acceptance remain separate unfinished dependencies. These boundaries alone
do not enable or accept the complete AI workflow.
