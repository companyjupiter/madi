# Live speech coverage retry

The native live executor now implements SessionController's W1 rule. A completed
committed WAV that had speech but emitted no committed word is retried once,
using the same retained WAV bytes, path and offset. If another committed job is
already queued, the old job is marked as a suspected gap immediately: retrying
behind later words cannot repair a segment past the WordMerger watermark. A
second empty result also records a gap. Silent jobs never trigger recovery.

`madi-core::coverage::Coverage` owns the queue, per-job retry flag, committed-word
counter and gap offsets. Every committed Word event counts, as in the original;
preview words and preview-embedded control markers remain quarantined by the
protocol decoder. Every committed segment boundary resets the counter, including
a boundary with no queued job. Turnaround timestamps and W2 hang recovery are
separate work and are not simulated by this policy.

The native executor owns each queued `OwnedWav`. Refeeding creates neither a new
WAV nor a second capture/retention event. The queue publishes the authoritative
pending count to the shared workflow, so preview admission and transcript-tail
status cannot mistake an in-flight retry for an idle ASR lane. Gap offsets feed
the existing localized warning/timestamp projection. They survive completion
and failure for review, but reset/new-session clears them. They do not invent
words or insert warning labels into saved transcripts.

## Stop and lifetime

W1 also operates while flushing, matching the original unguarded segment-end
handler. Stop still drains capture and queues FLUSH independently. If FLUSH was
already queued, a later retry stays behind it; FLUSH_END retires the engine and
pending queue without waiting for that retry. This is preserved behavior, **not
a guarantee that a final retry finishes**. No FLUSH reordering, extra completion
delay or ignored transport failure is introduced.

Reset and shutdown reap the child before releasing owned audio. Completed
segments remain available to later native consumers; an external audio lease
can outlive the executor, and the last lease removes the private directory.
Retired child output is drained without reentering the transcript. Original
input files remain outside this ownership.

## Evidence

`check_coverage_parity.py` extracts the unchanged shipping `.segmentEnd` body
into a Foundation probe. Five hundred cases / 22,250 transitions compare queue
contents, counters, retry decisions and gaps. Input enqueue/word/reset scaffolding
and no-op diagnostics/preview admission are explicit; timestamps, native audio,
transport and rendering are outside that differential. Windows compares the
same source-pinned result and both jobs preserve their reports in CI.

```sh
python3 scripts/check_coverage_parity.py
python3 scripts/check_coverage_parity.py --rust-only
cargo test --locked -p madi-platform coverage_
```

Five native regressions use real child processes, owned WAV I/O and scripted
PCM. They cover retry success and second-empty failure, silence, preview/control
quarantine, backlog suppression, paused completion, stop/reset/crash during a
retry, retry behind an already queued FLUSH, late-output exclusion and directory
cleanup. A shared-workflow case verifies warning timestamps through completion,
archive exclusion and reset. Four deliberate mutations detect backlog retry,
unbounded retry, silent-job retry and counting preview words as committed words.

Actual microphone speech recovery, warning expansion interaction, pixel/font
comparison and full native UI/UX acceptance remain NOT_RUN. W2 engine-hang
recovery and AI correction/reconciliation remain unimplemented. The prior native
playback failure and Windows hardware/integration gates remain open. See
`../evidence/macos-coverage-retry-2026-11-05.json` for validation provenance.
