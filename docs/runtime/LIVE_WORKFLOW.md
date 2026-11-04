# Live recording through the desktop workflow

The macOS recording button now reaches the same native transcript/archive owner
as file transcription. `FileWorkflow` holds a tagged file/live driver and joins
the previous executor before switching modes. A busy live admission, countdown,
recording or flush rejects a competing file selection/admission.

## Admission and presentation

- Model availability is checked before native audio permissions. Microphone
  authorization precedes system-audio authorization for mixed input, matching
  `SessionController.startCountdown`. A newly granted system-audio permission
  reports the original restart-required state instead of starting capture.
- Permission callbacks hold a unique native request identity. Cancelling its
  Rust future removes eligibility; late callbacks cannot advance another
  request. Each accepted admission also advances the UI generation, so a late
  countdown-cancel command cannot cancel a replacement countdown.
- After permission success the owner publishes 3, 2, 1 at one-second intervals.
  At actual start it reads the current native settings, glossary and mic choice.
  The public renderer accepts no replay, executable, scratch or arbitrary URL.
- Main-window commands connect pause/resume, stop, cancellation and mic changes.
  The mic picker persists its native CoreAudio identity before switching the
  active capture. Cmd+R/Cmd+P/Escape follow the source's start/transport/countdown
  actions. Settings has no live admission/control capability.
- Recording time comes from the Rust lifecycle clock and freezes on pause/stop.
  Native level events use the original half-second peak release. The workspace
  pane hides while recording/paused; the last transcript line is not editable.
  Completed live sessions use the shared transcript edits, exports and archive
  opening flow. Live summaries, previews and the remaining analysis UI are open.

## Finish, preservation and close

Normal stop drains native input through Stopped, delivers the final WAV, waits
for engine completion, finalizes the transcript, then atomically writes the
archive. Quit during recording/paused/flushing follows that same path. Closing the last visible window enters the joined exit hook and leaves the native run
loop alive until capture and disk work finish. This also fixes a windowless
process left behind by the hidden Settings window.

Back while recording opens the original stop/keep-recording confirmation.
Leaving an unsaved live transcript requires the original discard confirmation.
A dialog reply still targets the generation for which it was opened. Permission
errors expose fixed System Settings destinations and a restart through Tauri's
ExitRequested path, preserving the ordinary shutdown join.

Live automatic filenames use the original `TitleGenerator.fallbackTitle`:
`회의 yyyy-MM-dd HHmm` in the current Foundation locale/calendar/timezone. The
archive writer keeps its first allocated path and never replaces another
session's file. A real-device check exposed an empty-name `.md` file before this
fallback was connected; its content was preserved while recovering the name.
No real microphone transcript or audio is included in repository evidence.

## Verification and remaining gates

- Three process-backed workflow tests exercise cancelled/replaced countdowns,
  file/live exclusion, stale controls, pause time and samples, mic routing,
  final-tail archiving, edits/reopen and shutdown cleanup. The native permission
  test verifies cancelled/late/duplicate callback isolation without OS prompts.
- Mutations that retain the cancelled admission identity, bypass graceful quit,
  or omit the fallback title each fail their targeted workflow regression.
- `live_workflow_smoke` uses the public JFK fixture, native AVAudioFile conversion
  and real Metal ASR through this owner. It checks 3/2/1 and live phases, final
  archive serialization and independent reopen, line edits in five export
  formats, untouched source/model metadata and empty owned scratch at shutdown.
- Native UI observation reached real microphone recording, pause, the back
  confirmation, completed archive, setup return and main-window process exit.
  A user interaction occurred while the stop confirmation was open: the final
  Done state is observed, but cancellation/stop action attribution is not
  claimed. A later four-second take verified Cmd+R start/stop, and another
  admission verified the visible countdown followed by Escape cancellation.
  Main close with Settings visible kept Settings open; closing that last window
  exited the app. No new OS permission was granted by the agent.
- Fresh-install denied/granted/restart TCC scenarios, system/mixed hardware,
  deterministic native resume/hot-swap/quit-during-recording, full pixel parity,
  preview admission, watchdog, audio retention, AI and Windows capture remain
  **NOT_RUN / incomplete**. This is an experimental debug candidate, not a
  completed migration or a distributable release.
