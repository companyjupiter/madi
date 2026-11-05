# Transcript reading and follow state

The production frontend now uses `TranscriptFollow`, a direct port of
`apps/macos/Sovereign/Transcript/TranscriptFollowModel.swift`. Its state and
returned actions match the unchanged Swift implementation in 287 scenarios /
13,294 intermediate snapshots. This is state-machine evidence, not native
scrolling or visual certification.

The file screen passes `isLive = false`, matching `ContentView`'s
`isRecordingLike` binding. It opens at the top. Only recording/paused views use
the bottom anchor; file processing must not be treated as live recording just
because the engine is busy. The first transcript replaces the empty view with a
fresh initial anchor, and a session generation resets reading state.

| Native rule | Preserved value/behavior |
|---|---|
| Near-bottom zone | 120 pt |
| Corrective pin tolerance | 2 pt, only while following and live |
| Downward wheel rearm zone | 160 pt |
| Wheel intent deadband | Absolute delta at or below 2 is ignored |
| Geometry change | Updates bottom visibility; never releases following |
| New-line count | Count after the last seen UUID; if merged away, use end time greater than seen end + 0.001 s |
| Pill tap | Rearm, mark current lines seen, request tail pin |
| Jump timing | 250 ms ease-out candidate; exclude corrective pins for 400 ms |

`useTranscriptFollow` is the DOM adapter. It observes viewport and content sizes,
inverts DOM wheel direction for the native model, applies returned pin actions,
and publishes the pill state. The pill retains the original Korean/English/
Japanese labels and requests the native `arrow.down` SF Symbol at 11 pt semibold.
This bitmap is drawn into owned storage on macOS; no screen capture or Windows
redistribution of Apple symbol pixels is used. The new arrow dimensions and
nonempty transparent PNG are checked against live AppKit alongside the five
existing model-guide symbols.

The candidate also restores the original 700 pt maximum transcript width,
36 pt top fade after scrolling, 60 pt bottom fade, and the tail's combined 60 pt
clearance without adding a second bottom content inset.

## Verification

```sh
python3 scripts/check_transcript_follow_parity.py
python3 scripts/check_transcript_follow_parity.py --frontend-only
```

The first command compiles the unchanged Swift model plus a JSON-only wrapper,
then compares every state and action with the production TypeScript class. It
covers threshold boundaries, live/static geometry, wheel direction/intent,
late growth, merge identity removal, the time fallback, empty/reset, uppercase
UUID representation, pill taps and deterministic mixed sequences. The pinned
source/corpus/output reference lets Windows check the same contract without
claiming live Swift execution. CI retains the report on both platforms.

The React adapter, WebKit/WebView2 event scale, trackpad momentum, scrollbar and
keyboard interaction, focus, actual anchor/resize behavior, tween shape,
fade/pill stacking, typography and pixels still require comparison on native
windows. The current file workflow is wired; recording/capture, find/review
jumps, persistence, translation generation and full product behavior remain
separate unfinished migration work.
