# System-audio capture (online meetings: Teams / Slack / Zoom / YouTube)

Transcribe what's playing through the Mac, not just the mic — so online meetings
and videos are captured without a virtual-audio driver.

## Sources (Settings › 녹음 › 음원)
- **마이크** — the mic (existing path; pick the device).
- **시스템 오디오** — whatever's playing (Teams/Slack/Zoom remote audio, YouTube).
- **마이크+시스템** — both, mixed: your voice **and** the remote participants — the
  full online-meeting conversation in one transcript.

## How (sovereign — no driver)
`SystemAudioCapture` uses **ScreenCaptureKit** (built into macOS 13+): an audio-only
`SCStream` (`capturesAudio`, `excludesCurrentProcessAudio` so the app's own sounds
aren't captured; minimal 2×2 video, ignored). Each `CMSampleBuffer` → `AVAudioFormat`
→ the existing `Resampler` → 16 kHz mono Int16 — the **same** segment format the mic
produces, so the engine/diarization/translation pipeline is unchanged.

`AudioCapture` routes by source: single source → straight to the segmenter; `both`
→ a time-aligned mix (sum the overlapping prefix; a stalled/silent side counts as
silence after 2 s so it never blocks the other). No BlackHole/Loopback dependency.

## Permission
First use of system audio triggers the macOS **Screen-Recording** permission prompt
(audio-only still requires it; nothing is recorded to screen). Mic-only mode never
needs it. Denial surfaces as an error in system-only mode; in mix mode the mic keeps
working. All capture is local — audio never leaves the Mac.

## Verified (GUI-free)
Build + quark v9: 31/31 files wired; call-graph AudioCapture.start →
SystemAudioCapture, SettingsView 음원 → session.audioSource. Live audio behavior
(permission prompt, actual capture) is the user's to verify.
