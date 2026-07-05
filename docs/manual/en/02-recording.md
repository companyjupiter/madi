# Recording & Transcription

Madi transcribes meetings live as people speak, and it can also transcribe audio and video files you already have. Everything runs on this Mac — your transcript never leaves the device.

> The app interface is in Korean. Korean UI labels are shown below with an English gloss in parentheses.

## Live mic recording

1. Press **녹음 시작** (Start recording) at the bottom of the window.
2. As people speak, the transcript streams live in the center of the window.
3. Press **일시정지** (Pause) to pause, or **정지** (Stop) to end the recording.

**Note**
- Set **회의 모드** (Meeting mode) and **화자 수** (Speaker count) *before* you start — see below. They lock while recording is in progress.
- The **input level bar** at the top shows your mic level; it drops to 0 while paused.

### Captions appear as soon as you stop talking

Madi doesn't wait for a window to fill up. When you **pause and go quiet for a moment**, it closes that window early and emits the transcript right away — cutting the wait noticeably in short back-and-forth conversations (like a consultation). Quiet, far-field voices aren't clipped: the threshold adapts automatically.

## System audio capture (Zoom / Teams / video)

You can transcribe whatever is playing through your Mac — online meetings, videos, and so on.

1. Go to **설정 → 녹음 → 입력** (Settings → Recording → Input).
2. Under **음원** (Audio source), pick how to capture sound:
   - **마이크** (Microphone) — only the sound in front of you
   - **시스템 오디오** (System audio) — what's playing on the Mac: Zoom, Teams, Slack, YouTube, etc.
   - **마이크+시스템** (Mic + system) — for online meetings: your voice plus the other side
3. Press **녹음 시작** (Start recording) as usual.

**Note**
- The first time you use system audio, macOS asks for **Screen Recording permission**. Madi uses audio only and never saves your screen. Please allow it.

## File & video transcription

Drop an audio or video file you already have to transcribe it.

1. **Drag an audio or video file** (mp4, mov, m4v, mkv, webm, avi, and more) onto the Madi window. The drop area shows **드롭하여 전사** (Drop to transcribe).
2. Progress appears as **(N / total chunks · %)**.
3. When transcription finishes, the result appears on screen.

**Note**
- Audio from video files is decoded automatically — no conversion needed.

## Fixed speaker count

If you know how many people are in the room, set it in advance to improve speaker separation (diarization).

1. Go to **설정 → 녹음 → 화자 수** (Settings → Recording → Speaker count).
2. Choose **자동 (자동 감지 / Auto-detect) / 1 / 2 / 3 / 4명 이상** (4 or more).

**Note**
- Fixing the count when you're sure of it produces cleaner speaker separation. If you're unsure, leave it on **자동 감지** (Auto-detect).

## Meeting modes (회의 모드)

A one-pick preset that sets speaker count, summary style, and emphasis to match the shape of your meeting. Choose it in **설정 → 녹음 → 회의 모드** (Settings → Recording → Meeting mode).

- **일반** (General) — Default settings, automatic speaker detection
- **1:1** (One-on-one) — 2 speakers, emphasizes decisions and follow-ups
- **스탠드업** (Standup) — Automatic speakers, emphasizes actions and blockers
- **인터뷰** (Interview) — 2 speakers, preserves the question-and-answer flow
- **강의** (Lecture) — 1 speaker, organizes around key points

**Note**
- Pick a meeting mode *before* you start recording. It locks while recording is in progress.

## Transcript views

Use the toggle at the top of the window to switch between two views.

- **내용** (Content) — A clean, minutes-style reading view (the default). Best for reading.
- **상세** (Detailed) — Shows timecodes, low-confidence words (highlighted in amber), and overlap markers when two people talk at once. Best for reviewing and editing.
- **대화** (Chat) — Appears only when exactly two people are present. Puts the first speaker on the left and the other on the right in message bubbles — good for reading back-and-forth interpreting or a consultation.

Adjust the font size with the **+ / −** buttons.

## Privacy

All of Madi's transcription happens on this Mac. Your transcript never leaves the device.
