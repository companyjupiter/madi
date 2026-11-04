# Shared DNA engine broker

`madi-platform::dna_broker` provides the native resident process required by
translation, the action rail, summaries and Q&A. It is not connected to those
product consumers yet. It does not expose arbitrary process launching through
Tauri commands, and passing its tests does not establish translation or UI parity.

The host owns one `DnaBroker`. Clients attach with the resolved engine/model
paths; subsequent clients must select the same pair. A client ID remains unique
when the owner is replaced. Each request carries its client and request ID;
streaming events also identify the process generation. The host must retain its
own session/line/revision checks when forwarding these events to a transcript.

## Scheduling and protocol

The process receives `SOV_NSTEPS=512`, with inherited `SOV_DEBUG` removed. One
request is in flight. Committed captions (100) precede interim captions (80),
live rail (30) and post-session work (10), with FIFO order within a priority.
This FIFO is the shared broker policy; TranslateEngine's separate newest-first
caption queue is still to be ported and connected.

Reported caption pressure holds background requests until pressure clears or
their waiting time reaches 90 seconds at a pump opportunity. Caption-busy events
exclude background work, preserving the input needed by ASR preview admission.
Busy events are emitted on changes; the initial state is false.

Requests normalize CR/LF to spaces and trim Foundation whitespace, then write
one protocol line incrementally. Prefix registration uses `%%PFX <slot> <text>`;
only a matching `PFX_OK` completes that registration. Ordinary turns complete
at `[perf] generation`, with empty replies reported as failure. The parser is
reset per turn and preserves embedded newlines only when requested. Capability
sets are replaced on every process launch/READY. The future translation client
must gate `%%FP` and `%%MAX` as the shipping TranslateEngine does.

Cancelling pending requests completes each queued request with no result. It
does not cancel an active turn. Detaching a client suppresses its later output;
if another client remains, the active turn still drains before the next request.
The final detach waits for process reaping before acknowledging completion.

## Failure and ownership

The watchdog budget matches `DNATurnBudget`: prompt byte length, 512 generation
steps, model throughput floors, contention factor, overhead and 20–180 second
clamps. Positive finite `MADI_DNA_TIMEOUT_MS` overrides are supported. Invalid,
nonfinite or unrepresentable timer durations cannot panic the native owner.

On expiry, the broker quarantines output, sends SIGTERM on Unix and escalates
after two seconds; Windows uses the child process termination API. It reaps the
old child before creating a replacement, clears the parser and capabilities,
then fails the old active and queued requests. Reset/relaunch precedes failure
events so a consumer's next request is not erased by teardown. At most two
consecutive watchdog restarts are allowed. A successful turn or prefix resets
that allowance. Ordinary crashes do not automatically restart.

Shutdown is visible even while the owner is reaping a timed-out process; it
cannot accidentally launch another model. Dropping the owner requests shutdown
and leaves its supervisor alive to reap the child. Cancelling `wait()` retains
the completion handle. A blocked stdin cannot prevent reads, timeout or shutdown.

Native ownership additions beyond the Swift callback implementation are explicit:
NUL-containing protocol input is rejected; submissions with detached clients or
no live process fail immediately; half-closed child/pipe states are bounded;
IDs cannot cross broker instances; final detach waits for reaping. These prevent
stranded requests and overlapping model allocations without changing normal
request priority or text output. Nonfinite timeout overrides are rejected rather
than being converted into an invalid timer.

## Verification and remaining integration

- `scripts/check_dna_broker_parity.py` compiles the complete, unchanged shipping
  broker, budget and parser with a no-op diagnostic sink. The 760 cases compare
  priority/pressure/FIFO decisions, wire normalization and exact floating-point
  watchdog budgets. Windows compares the same pinned reference and source hashes.
- `dna_broker::tests` drives real Python child processes speaking the DNA wire
  protocol. Cases cover shared clients, mismatched models, prefix slots, Unicode,
  newline policy, cancellation, late output, crash, repeated wedges, successful
  recovery, pressure, a full stdin pipe, closed stdout and owner replacement.
  Unix tests additionally prove reaping, ignored SIGTERM escalation and shutdown
  during timeout termination. Test fixtures do not load a model or record audio.
- `dna_broker_smoke ENGINE MODEL` drives public sample text through an installed
  DNA model: prefix registration, translation, forced-prefix translation and a
  second client's background request. It checks one resident process and full
  before/after input hashes. This is transport execution evidence, not a
  translation quality assessment.

The pure turn queue, prompt and output policies now have their own Swift
differential in `TRANSLATION_POLICY.md`. Next integration work includes their
TranslateEngine client owner, repair retries, prefix registration, interim/committed
revision guards, caption pressure and busy signals, stop-time backfill, and all other
DNA clients.
Actual WebView/native screen comparison and Windows GPU execution remain open.
