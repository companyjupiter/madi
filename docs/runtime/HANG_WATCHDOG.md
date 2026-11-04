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

Native microphone/model hang recovery, exact warning rendering/interaction,
audible output and the Windows device/GPU matrix remain separate acceptance
gates. Release builds remain disabled. See
`../evidence/macos-hang-watchdog-2026-11-05.json` for recorded validation.
