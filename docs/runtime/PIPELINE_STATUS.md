# Transcript-tail pipeline status candidate

The shared file/live owner now publishes the original derived pipeline state and
localized warning/activity text. The renderer displays one transcript-tail
status area after the blocks with a 30-point top gap, 8-point row gap and the
existing 60-point tail clearance. File transcription, translation waiting,
shed-backlog and post-stop backfill no longer compete with independent frontend
status rows. No activity label is emitted for idle, completed or error states.

The priority is copied from `SessionController.pipeline`: error, pending language
correction, speaker/language reconciliation, file transcription, shed translation
backlog, queued translation, recording, then post-stop backfill. Queue labels
count source lines, not model turns, preserving the original minimum-one rule.
A completed ASR phase can still show translating while DNA owns queued work.
Preference language changes update the projection without another ASR event.

The connected producers are file phase/progress, committed translation queue and
backfill, native live segment count, capture interruption and silence detection.
Native raw level strictly above 0.02 updates the audible timestamp; the original
3-second polling rule reports silence only after strictly more than 15 seconds.
As in Swift Date, elapsed silence uses wall time; the scheduler uses a monotonic
poll deadline. Paused polls reset the audible timestamp and clear silence. Stop/error/reset
retire the timer; no renderer timer or microphone sample is needed to publish a
silence warning. Peak-held meter levels do not feed the silence detector.

The complete presentation policy also preserves the original coverage timestamps,
recovery counts and correction/reconciliation priority. **Their production
coverage-retry, hang-recovery and AI-correction producers are not connected yet.**
Those inputs remain absent until the corresponding native owners are ported.
The gap-expansion UI therefore has policy/renderer implementation but no current
end-to-end coverage-recovery acceptance. This slice does not claim those engines
are implemented or declare their absence to be successful recovery.

The status visuals use the original warning SVG, three-color gradient, 14-point
text, fixed numeric widths and three 3-point loading dots separated by 3 points.
Dots begin dim, then select one every 320 ms with a 250 ms opacity transition.
The countdown shares these dots and original gradient colors. The gap box uses
the original labels, spacing and maximum width. Exact SwiftUI spring behavior,
font metrics, pixel geometry and assistive-technology behavior require native
comparison and remain NOT_RUN.

`check_pipeline_status_parity.py` extracts the unchanged `PipelineState` enum,
computed `pipeline`, `transcriptWarning`, `coverageGapTimes` and
`transcriptActivity` bodies into a Foundation-only Swift probe. Three thousand
cases compare all eleven state kinds and Korean/English/Japanese outputs,
including overlapping signals, empty/nonempty warnings, sorted duplicate gap
times, unknown file progress and line-versus-turn queue counts. Windows runs
against the same source-pinned reference; source checkout rules retain LF bytes.
`StatusLine.swift` is pinned for traceability but is not executed by that oracle.

```sh
python3 scripts/check_pipeline_status_parity.py
python3 scripts/check_pipeline_status_parity.py --rust-only
```

Native workflow regressions exercise held translation through done/edit/reset,
queue teardown when targets are disabled, committed segments versus preview-only
work, silence publication without samples and recovery after audible input.
The pure timer test covers exact boundaries and paused-time exclusion. Actual
microphone/device, native display and animation acceptance remain separate gates.
See `../evidence/macos-pipeline-status-2026-11-05.json` for the recorded validation.
