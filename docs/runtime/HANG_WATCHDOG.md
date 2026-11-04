# Live ASR hang recovery

The native executor now connects SessionController's W2 watchdog to the existing
generation-checked engine replacement lifecycle. Every five seconds it checks
recording or paused sessions with pending committed audio. A restart requires
strictly more than 45 seconds since the newer of the oldest pending job's feed
time and the last accepted engine event. The elapsed comparison uses wall time,
as Swift Date does; Tokio's monotonic clock only schedules the polls.

Words, segment boundaries, progress, speaker/language events and preview events
refresh activity. READY, FLUSH_END, diagnostic/unknown lines, capabilities,
structured JSONL and termination take separate callbacks in the shipping app;
they do not refresh this heartbeat. A healthy engine cannot be restarted merely
because its backlog is old. Empty queues, startup, flushing and completed/error
phases do not trigger replacement. Finalization/failure/reset retire the timer.

## Replacement and retained data

The recovery count advances for each attempt. The presentation owner marks the
speaker namespace as broken before ingesting replacement output, preserving
the original finalization rule: replacement FLUSH labels must not replace the
pre-restart live speaker namespace. Current native settings and glossary are
read again for the new launch; the original speaker-island/weak-label feature
flags are refreshed from that language selection.

The old process is terminated and reaped, including its output tail, before a
new process is installed. Existing run/capture identities, recording clock and
paused state remain intact. Old process messages cannot update the transcript
or refresh the new engine's heartbeat. New capabilities start undeclared.
If a PCM task temporarily owns the capture pipeline, retained audio leases still
supply the validated private root for the replacement process.

After a successful replacement, every pending job receives a new feed time and
is queued in its original order using the same retained WAV, offset and bytes.
W1 retry flags and the committed-word counter remain unchanged. No audio is
recaptured or rewritten. Refeeding may be queued before READY, as with the
shipping EngineProcess. A failed launch retires capture and pending work and
reports failure; it does not report a successful session or recovered words.
There is no new restart budget or backoff policy.

Recovery counts feed the existing localized transcript warning and survive
completion for review. Reset/new-session clears the count; warnings are not
inserted into saved transcript text. The other AI correction/reconciliation
producers remain separate migration work.

## Verification scope

`check_hang_watchdog_parity.py` executes the unchanged shipping `tickWatchdog`
and W1 segment-end bodies with an injected Date clock and explicit replacement
result scaffolding. Six hundred cases / 36,000 transitions compare recovery
counts, namespace-break signals, pending timestamps, retry flags, word counters
and ordered feeds. They include clock rollback, exact thresholds, partial
progress, paused work and failed replacement. The original W1 reference remains
unchanged and is checked independently.

Native tests use real child processes and owned WAV files with scripted PCM and
an injected wall clock. They advance the actual five-second poll timer, verify
heartbeat and diagnostic distinctions, preserve recording/paused capture, read
the refreshed launch language, compare original/refed WAV hashes and order,
exclude retired output and exercise replacement spawn failure. A shared-workflow
case verifies recovery warning, old speaker-label preservation at FLUSH, archive
contents and reset cleanup. These tests do not run a real stuck Metal model.

```sh
python3 scripts/check_hang_watchdog_parity.py
python3 scripts/check_hang_watchdog_parity.py --rust-only
cargo test --locked -p madi-platform hang_watchdog_
```

### Opt-in installed Metal probe

The ignored macOS test `actual_metal_hang_recovery_matches_baseline_and_preserves_archive`
uses the installed ASR executable/model and the pinned public JFK WAV. It first
runs a normal baseline, then suspends only its verified ASR child with SIGSTOP.
The production watchdog uses the real wall clock and normal replacement path;
there is no injected clock or accelerated timeout in this probe. It compares
the final words, confidence values, times, speakers, retained WAV hashes and
saved Markdown exactly, then checks reopening, warning reset and child/audio
cleanup. The capture source is scripted PCM; no microphone is opened.

Provide explicit absolute paths; model and engine downloads are not performed:

```sh
export MADI_PROBE_ENGINE='/absolute/path/to/Madi UI Parity.app/Contents/MacOS/transcribe'
export MADI_PROBE_ASSETS='/absolute/path/to/Madi UI Parity.app/Contents/Resources/assets-small'
export MADI_PROBE_MODEL='/absolute/path/to/model.q8.safetensors'
export MADI_PROBE_SOURCE='/absolute/path/to/public/jfk.wav'
export MADI_PROBE_OUTPUT='/absolute/path/to/probe-output'
cargo test --locked -p madi-platform \
  file_workflow::live_tests::metal_recovery_probe::actual_metal_hang_recovery_matches_baseline_and_preserves_archive \
  -- --exact --ignored --nocapture
```

Only the JFK input with SHA-256
`59dfb9a4acb36fe2a2affc14bacbee2920ff435cb13cc314a08c13f66ba7860e`
is admitted. `report.json`, `baseline.md` and `recovered.md` are local evidence.
The source/model/engine hashes are rechecked after both scenarios. Because the
fixture supplies audio once, the ordinary silence watch can suppress the
listening indicator during the stall. The probe waits for resumed words and
Stop/FLUSH completion, not that indicator. This does not accept naturally
occurring GPU hangs, real microphone recovery, inference quality or native UI.

The 2026-11-05 run passed with a replacement after 49.828 seconds: 24 words in
four lines, three retained WAVs and the Markdown archive matched the baseline.
Reopen/reset and process/audio cleanup also passed. Initial path-alias and
silence-indicator harness failures are preserved in
`../evidence/macos-metal-hang-recovery-2026-11-05.json`. The production runtime
was not changed for the probe.

Native microphone and naturally occurring model hang recovery, exact warning rendering/interaction,
audible output and the Windows device/GPU matrix remain separate acceptance
gates. Release builds remain disabled. See
`../evidence/macos-hang-watchdog-2026-11-05.json` for recorded validation.
