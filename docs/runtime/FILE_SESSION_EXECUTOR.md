# File session effect executor

`madi_platform::file_session::FileSession` now connects the deterministic Rust
session core, owned native decoding, typed file ASR configuration and native
process supervisor. It handles file transcription only. Live capture, storage,
translation, model admission and Tauri transcript UI remain separate work.

A single Tokio worker serializes starts, reset/shutdown, decode completions and
engine output. `start` returns a run identity, or None while busy. Callers reset
before replacing an active file. Each update carries a per-executor `RunId`;
the host must retain its executor and ignore queued old-run updates after a new
start. Independent executor instances have independent event channels and IDs.
Core resource tokens additionally reject old engine/preparation callbacks.

The worker executes only file effects. Successful decoding transfers an actual
`PreparedAudio` guard into its registry before calling `core.file_prepared`.
An engine receives that owned WAV, never the original user's file as a cleanup
target. File-mode stdin closes after launch. JSONL/stdout ordering is inherited
from the tested process supervisor. READY does not start capture in file mode;
ordinary output, structured events and diagnostic lines are forwarded only while
the core accepts that engine identity. FLUSH_END or a normal file-mode exit
finishes the session as in the original Swift coordinator.

Termination is awaited before `RemovePreparedFile`, including reset, failure,
normal completion and owner drop. A cancelled decode is awaited; a successful
result that won the race is disposed without launching an engine. Reset replies
only after cleanup. Dropping the API sends shutdown and leaves its worker alive
to perform ordered cleanup; application exit must explicitly await `shutdown`
before destroying the Tokio runtime. Cancelling a shutdown wait retains its
join handle for the next await.

The Finished/Failed notification follows phase transition and resource cleanup.
The normal terminal sequence is Processing → Done → Finished. A teardown or
transport-drain failure suppresses Finished, cleans remaining owned resources,
retains an error phase and returns an internal Fault plus shutdown error. Raw
failure strings are not approved product UI copy; a localized mapper is still
required. File processing has no new product timeout (matching the original);
the standalone smoke uses a separate 120-second test deadline.

Six real-child-process regressions cover JSONL tail before completion, exactly
one completion and restart, busy admission, reset/replacement identity isolation,
prepared-WAV survival until child termination, preparation cancellation and
owner drop, running-owner drop, spawn/nonzero-exit failure, and a descendant-held
stdout timeout that must not be reported as success. They use synthetic audio
and Python fixture executables on macOS/Windows; they are not inference tests.

Separately, `file_session_smoke` completed native AVFoundation preparation and
the actual bundled Metal Whisper engine on the public JFK clip: Processing →
Done, 22 words, 26 JSONL events, one Finished, zero failures, and both scratch
directories empty when completion was received. This proves the file runtime
path independently of the desktop view. It does not close complete UI/UX parity,
live-session execution, archive/translation or Windows ASR gates.
