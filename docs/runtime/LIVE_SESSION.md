# Native live-session executor

`madi-platform::live_session` now connects the verified session state machine,
linked macOS capture boundary, Rust PCM/WAV pipeline and resident ASR process.
The recording button and shared transcript/archive owner now connect through
`LIVE_WORKFLOW.md`. Preview admission, translation, retained audio and W1
coverage retry now have native consumers. W2 hang recovery is connected through
`HANG_WATCHDOG.md`; remaining live AI features still require integration.
See `COVERAGE_RETRY.md` for W1 behavior.

## Ownership and event order

- The native host supplies resources, a trusted scratch parent, typed settings
  and input selection. No renderer command accepts an executable or WAV path.
- A fresh pipeline allocates the only admitted `STREAM_WAV_ROOTS` directory.
  The engine starts first; READY starts capture. The pipeline is ready before
  native input opens because mic samples can precede combined-input readiness.
- A single executor owns session/engine/capture identities. Each PCM operation
  runs on a blocking task, with at most one operation in flight. While it runs,
  controls, engine output and deadlines remain serviced; the next native sample
  or marker waits in the bounded ingress queue.
- Pause/resume enqueue markers on the same main queue as native PCM callbacks.
  The Rust pipeline applies them in FIFO order. Devices remain running. Old
  run controls are ignored, and cancellation drains late callbacks through the
  old capture's Stopped acknowledgement before admitting a replacement.
- Stop enters Flushing, stops native input, drains accepted PCM through Stopped,
  writes/delivers the final tail, then queues FLUSH. A clean engine exit or
  FLUSH_END before that tail acknowledgement fails instead of reporting Done.
- A device fault during recording preserves the partial session via normal
  stop/flush and emits a separate interruption reason. Startup failure does not
  announce Recording. Teardown failures are reported after remaining cleanup;
  they cannot become Finished or a successful reset acknowledgement.
- The core's startup/flush deadlines are executed with token checks. Ordinary
  progress refreshes the flush deadline. Flush timeout remains a distinct
  update followed by the source-compatible partial completion behavior.
- Segment WAVs survive Done for correction work. Reset/shutdown reaps the engine
  before releasing this owner's directory. Explicit `OwnedWav` leases can keep
  individual jobs alive; only the last owner removes the directory. Original
  input media and model files are never transferred into that ownership.

## Live configuration

`LiveSettings::from_setup` shares the file mode speaker/VAD/glossary/memory policy,
then adds the source's language-candidate union. `Resources::live_launch` enables
STREAM, AUDIO_CTX=auto and PARTIALS, validates the canonical root and clears
unset engine-owned flags. The source's voiceprint gate remains false. Capture
windows use the existing multi-target policy, short first window and overlap.

`scripts/check_live_config_parity.py` compares 2,406 configurations against
unchanged extracted Swift policies and launch statements. macOS executes Swift;
Windows compares the pinned result. The root is validated on each host before
only its random temporary path is normalized for the differential.

## Verification and limits

Seven real-child-process regressions cover ordered pause/drop/tail delivery,
retained WAVs, startup failure, interrupted input, premature engine termination
and flush, replacement during suspended startup, teardown failure and startup
timeout. Scripted capture input avoids device permissions in these tests.
Disabling pause discard or sending FLUSH before the final WAV deliberately
fails the ordered-tail regression; restored code passes all 119 Rust tests.
Nine native replay/cancellation cases also exercise the actual Swift
pause/resume/stop marker order and concurrent endpoint isolation.

`live_session_smoke` additionally runs the linked native file converter and the
real Metal ASR engine through this executor. The public JFK fixture produces
three WAV jobs, 28 word events, a finalized transcript and exactly one Finished;
the source and model metadata remain unchanged and owned scratch is empty after
shutdown. Replay opens no microphone or system audio device.

Preview WAVs are surfaced as typed availability updates and admitted by the
product scheduler described in `LIVE_WORKFLOW.md`. Language lock, busy-lane
admission, forced-prefix agreement and preview ownership are checked before
feeding them. W1 retries share that committed-job priority; W2 now executes the
core's replacement-engine policy while preserving capture and pending audio.
The Windows capture adapter is not implemented; this executor is macOS-only.
A bounded microphone/UI observation is recorded in `LIVE_WORKFLOW.md`; full
device/TCC scenarios, UI/UX parity and recording acceptance remain incomplete.
Release builds remain disabled.
