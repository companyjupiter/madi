# Rust session lifecycle contract

Source: `apps/macos/Sovereign/Session/SessionCoordinator.swift` at Madi
`c1390c750f2506e556a277421e146d80195ab797`. The deterministic port lives in
`crates/madi-core/src/session.rs`; it is not connected to the desktop host yet.

The state machine owns phase, elapsed time and resource identities. A serialized
OS adapter executes returned effects in order and returns completions using the
original token. UI state changes cannot start recording or terminate a process
directly. Engine stdout/JSONL delivery uses `madi_protocol::stream::EventStream`.

| Trigger | State and required action |
|---|---|
| Live start | Invalidate old generation, release resources, assign capture/engine tokens, arm 45-second startup deadline, start engine |
| Engine READY | Only the current live engine in EngineStarting starts capture; keep the startup deadline until asynchronous capture startup completes |
| Capture starts | Cancel startup deadline, record start time, enter Recording, then notify product callbacks |
| Pause/resume | Preserve capture/engine; exclude paused duration from the displayed recording time |
| Stop | Freeze displayed duration, enter Flushing, arm 45-second deadline, request capture stop |
| Capture stop completes | After every final segment was delivered to the current engine, acknowledge with `capture_stopped`; only then issue FLUSH |
| Engine progress while flushing | Ordinary stdout events refresh the deadline; structured and diagnostic events do not |
| FLUSH_END or normal file/flush exit | Clear resource identities before termination, release resources, enter Done, notify exactly once |
| Timeout/failure | Startup timeout fails; flush timeout notifies and finishes. Late callbacks cannot restore the old session |
| Engine replacement | Allowed while Recording/Paused, retires old engine identity and preserves capture and phase; replacement READY does not restart capture |
| File preparation | Own a cancellable preparation token. A late successful result releases its temporary WAV instead of launching an engine |
| Countdown | Cancellation does not replace displayed transcript or post-session AI work. Actual start performs reset |

The capture stop acknowledgment is an intentional asynchronous boundary. The
shipping Swift capture's `stop()` synchronously emits its tail before returning;
a cross-platform async capture must uphold the same observable ordering rather
than sending FLUSH immediately after requesting stop. A second acknowledgment
or a late old capture acknowledgment has no effect.

The effect executor must provide these guarantees before product integration:

- Run all state transitions and effect dispatch on one serialized executor.
- Keep engines and captures in registries keyed by their tokens. Aborting a late
  old capture must never address the active capture through a global variable.
- Forward capture segment callbacks before feeding the current engine; allow
  final segments in Ready/Recording/Paused/Flushing. Preview/levels are delivered
  only while Recording; capture errors only during startup/Ready/Recording/Paused.
- Drain stdout completely before delivering exit. Preserve JSONL-before-barrier
  ordering using the protocol stream adapter.
- Treat `RemovePreparedFile` only as disposal of an adapter-owned temporary WAV.
  Never pass the user's original selected path to `file_prepared`; establish an
  ownership type and validate the temp root in the filesystem adapter before
  enabling any deletion effect. The current pure core performs no filesystem IO.
- Cancellation is advisory; generation/token checks remain necessary when a
  decoder, capture startup or deadline callback completes after cancellation.
- Map typed failures to the same existing localized product messages. Internal
  effect names, tokens and raw platform diagnostics must not become UI copy.

Seven Rust regression tests cover tail/FLUSH ordering, exactly-once completion,
late callbacks and replacement, suspended capture startup timeout, progress timer
refresh, cancelled imports, failures, countdown and paused elapsed time. They
port the observable expectations of the existing Swift coordinator tests. This
is not yet an independent live Swift/Rust lifecycle differential or a real audio
capture test; those remain necessary with the production adapters.

The [native process adapter](ENGINE_PROCESS_ADAPTER.md) now implements tagged
child supervision, ordered output, cancellation and owned JSONL cleanup. Its
20-scenario Swift differential and real Metal file smoke are separate evidence;
the session effect executor and capture/storage wiring are still open.
