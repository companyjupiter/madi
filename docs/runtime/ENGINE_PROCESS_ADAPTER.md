# Native ASR process adapter

`crates/madi-platform/src/engine_process.rs` implements the real child-process
transport behind the Rust session contract. It is callable only from trusted
Rust code; no Tauri command grants arbitrary process execution. The desktop host
does not yet attach this adapter to its start/file buttons.

`Launch` takes executable, argument, working-directory and environment values
resolved by the host. It never runs a shell. macOS keeps the shipping engine's
separate process and relative runtime-asset lookup. Windows launches without a
console window. `None` environment values remove inherited variables: engine
switches such as `STREAM` test presence, so `STREAM=0` still enables streaming.
Typed model/config selection and full path admission remain executor work.

The supervisor tags every result with the core's original engine `Token`.
Replacement or cancellation addresses a specific process handle; it cannot kill
another generation through a shared global child pointer. Stdout and stdin are
handled in one async loop. Incremental stdin writes are cancellation-safe, so a
child that stops reading cannot prevent stdout drain or termination. Queued
protocol lines precede requested stdin EOF. Embedded newlines, CR and NUL are
rejected by the one-line transport API; caller-specific path/prompt normalization
still belongs to the typed engine command layer.

`EventStream` preserves JSONL-before-barrier delivery and unterminated stdout
tails. Only after stdout EOF and child exit does it emit `Terminated`. It does
not invent a final JSONL barrier. Capabilities are exposed separately; read/write
faults are internal diagnostics to be mapped by the future product executor.
Like Swift, a missing/unreadable JSONL file is non-fatal and its offset is not
advanced on failure.

Cleanup owns only a new `tempfile::TempDir` beneath the supplied scratch parent.
`EVENTS_FILE` is forced into that directory even if the launch environment tries
to override it. Neither the selected WAV, models nor the scratch parent can be
registered as cleanup targets. Handles close before the directory is removed,
including on Windows. `wait()` reports cleanup errors and can be cancelled and
awaited again without detaching completion.

Normal user Stop must send `FLUSH` after the capture tail. Resource teardown uses
SIGTERM on macOS as Foundation does, with a two-second escalation to SIGKILL if
ignored; Windows uses process termination. Dropping an owner asks the supervisor
to stop, reap and clean while the runtime remains alive. `kill_on_drop` is also
set for unexpected task/runtime teardown. Graceful application shutdown must
explicitly await all supervisors; merely dropping the runtime is not a verified
cleanup strategy.

After child exit, an inherited stdout pipe held open by a descendant gets a
two-second drain limit. Expiry emits an explicit IO failure; it is not successful
tail delivery. The adapter manages the direct engine child, not arbitrary process
trees. Current Madi engines do not require a child-process tree executor.

## Evidence and open integration

The differential driver now uses this adapter instead of its former standalone
pipe loop. `python3 scripts/check_stream_process_parity.py` still matches the
same pinned 20 real-child Swift scenarios and event hash without changing the
golden. Lifecycle tests cover blocked stdin, ignored SIGTERM escalation, drop,
replacement identities, cancelled waits, spawn failure, queued EOF and cleanup
that preserves an unrelated original file.

The `engine_file_smoke` example executed the original bundled Metal engine and
Whisper Q8 model on the public JFK clip: 22 word events, 26 structured events,
nonempty transcript, flush before exit 0, and owned scratch removed. It uses a
session token only as an identity; it does not execute the complete session
lifecycle. This local evidence does not close the production UI/audio gate.

Still required: effect executor, owned decoded-WAV registry, audio capture/tail
delivery, startup/flush watchdog wiring, typed ASR options, archive writes,
translation broker, full UI integration and long-session performance tests.
