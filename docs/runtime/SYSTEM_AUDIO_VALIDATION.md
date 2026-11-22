# Native YouTube system-audio validation

The 2026-11-22 check exercises playback in native Google Chrome, macOS
ScreenCaptureKit, the Tauri capture/workflow owner and the bundled Metal
transcriber. It passes live Korean text, pause/resume, stop, automatic Markdown
storage and reopening from the workspace list. This is an ad-hoc debug build,
not full migration or release acceptance.

The source was the public [EBS quantum-mechanics discussion](https://www.youtube.com/watch?v=rKTpAeYJjJE),
opened at 120 seconds. The player was observed unmuted and advancing. Madi used
System input, automatic language and no translation. The native System enum
maps to source 1, which skips `startMic`; audio arrives through ScreenCaptureKit
and is converted to mono 16 kHz PCM. No downloaded source, subtitle import,
virtual microphone or prerecorded injection substituted for this live check.

## Observed behavior

- The user-granted screen/system-audio permission was on. Start was already in
  progress when the agent's stale start click was rejected after an external UI
  change; the start initiator and countdown are not claimed.
- Korean text appeared in the live view. Pause held elapsed time at 1:02 while
  playback continued. Resume produced new Korean text and advanced to 1:59.
- Stop at 2:16 reached finishing and then the archived, non-recording view.
  The saved Markdown contains 33 transcript rows, valid UTF-8 and no replacement
  characters. The workspace entry reopened the Korean body. Its displayed
  duration was 2:15: Markdown stores coarse timestamps and cannot restore all
  original timing, confidence or speaker-display state.
- Normal Quit retired the test app and capture engine. Recording-time Quit was
  not tested. Preferences, workspace and glossary bytes were restored from the
  pre-test backup after exit; the user-granted OS permission remains enabled.
- Closing the dedicated Chrome test tab was attempted, but subsequent Chrome
  AX/screenshot calls timed out. Browser closure is unconfirmed.

## Evidence boundary

The metadata-only [receipt](../evidence/macos-youtube-system-audio-2026-11-22.json)
pins application, engine, model and output hashes. Raw speech, Markdown,
preferences and events remain in ignored local `out/system-audio-20261122`.

The existing Tauri `debugCapture` preference does not yet feed a diagnostic
session sink. A read-only observer instead retained the active session's
immutable WAVs and snapshots of its engine events. It started after recording
began. The final retained snapshot contains 347 events, including 16 nonempty
Korean segments and 74 partials, all valid UTF-8. Seventeen non-silent mono
16 kHz signed-16-bit WAVs were retained. Segment durations include overlap and
must not be added to infer recording time. Normal scratch cleanup may have
raced the last event copy: final-tail event coverage is not certified.

Korean text matched the selected discussion topic, but recognition errors were
visible. No reference transcript, CER, diarization score or human listening
acceptance was measured for this video.

## Follow-on translation and open gates

A separate 13-second WAV from the same capture was opened through the native
media picker with English as the translation target. Korean recognition and
four English translations reached the main view, the backlog retired and a
manual Markdown export preserved all four translations. Caption toggling and
detail/content switching worked after restart. The separate nonactivating
caption panel was not exposed by the tool, so its pixels and close/recreate
behavior remain unaccepted. A preceding minimize/restore attempt stopped
responding to content clicks; the clean restart without minimization did not
reproduce that state. This file check is not sustained concurrent live ASR/DNA
acceptance.

Selecting the saved `.md` from the setup media picker reached the unsupported
media error; opening it from the workspace list passed. Both original and
candidate configure the setup picker for audiovisual types. This check does
not establish generic Markdown import through setup.

Remaining gates include physical microphone/mixed capture after the language
fix, fresh-install denied/granted/restart permissions, hot-swap/disconnect,
self-audio exclusion on hardware, recording-time Quit, long-run latency and
ASR/DNA load, diagnostic bundles, caption/patient panel focus and monitor
behavior, the complete UI/UX matrix and remaining AI workflows. Windows GPU
and device validation remains explicitly deferred by the user.
