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
  opening flow. Live summaries and the remaining analysis UI are open.

## Provisional transcription

The capture pipeline's rotating preview WAVs now feed the same resident engine
through a latest-only scheduler. Selected-language recording arms immediately;
auto-language recording waits for the committed lane's language lock. Both the
presentation owner and native executor enforce committed-job priority. The
executor also checks generation, Recording phase, one in-flight preview and the
owned WAV root before accepting a request. Rejected admissions retain the newest
snapshot for the next event, without marking an unsubmitted job in flight.

`PreviewTrim` and `InterimSourceGate` preserve the shipping forced-prefix and
agreement rules, including provisional first paint, the stall escape, Unicode
grapheme counting and the 512-character display bound. Only an agreed prefix can
extend displayed committed words. `preview-fp` capability gates the protocol
extension; invalid delimiter/control content falls back to an unforced request.
Preview words remain outside TranscriptStore, archives and all exports. Closed
segment partials also populate the live hypothesis after overlap-word trimming.

The transcript renders the hypothesis as a gray inline continuation of the last
committed row/block, or as a standalone paragraph before the first commit. The
frontend ports InterimDedupe's seam alignment and the original 24ms grapheme
progression, including immediate replacement and long-jump behavior. Swift
source comparisons cover both backend policy and frontend transitions; actual
WebView/native visual equality is still a separate acceptance gate.

The connected DNA translation owner now supplies busy/queue-depth signals.
Preview aging admits a slice after 2 seconds at depth up to six, or 4 seconds
above that depth, while preserving committed-job priority. W1 retries remain
committed jobs until they retire. See `COMMITTED_TRANSLATION.md` for this
admission integration and its separate validation; full concurrent ASR/DNA
device and native UI acceptance remain open.

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
- Preview policy and frontend progression match 1,409 native Swift cases. Two
  additional real-process tests cover latest-only scheduling, committed
  priority, language lock, pause, run/root validation, forced-prefix transport,
  preview control quarantine, export/archive exclusion and owned cleanup.
- `live_preview_smoke` feeds the public JFK fixture through the native converter
  and the actual Metal engine: unforced preview, forced-prefix preview, committed
  decode and FLUSH all run in one process. Both previews leave zero committed
  lines; the final decode creates the expected transcript. Source/model data
  remain unchanged and the owned scratch is empty after teardown.
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
  live-preview visual/timing acceptance, DNA admission, watchdog, audio retention,
  AI and Windows capture remain
  **NOT_RUN / incomplete**. This is an experimental debug candidate, not a
  completed migration or a distributable release.
