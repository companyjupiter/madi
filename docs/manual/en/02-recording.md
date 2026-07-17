# Recording and transcription

Madi transcribes meetings live as people speak, and it can also transcribe audio and video files you already have. Everything runs on this Mac — your transcript never leaves the device.

> The app interface is in Korean. Korean UI labels are shown below with an English gloss in parentheses.

## The first screen — meeting info and getting started

When you open the app the first screen splits in two. On the left you tell Madi **what kind of meeting this is**; on the right you **start** it.

### 회의 정보 (Meeting info) — left

Setting these before you record improves the result. **They lock while recording.**

- **입력 언어** (Input language) — the language being spoken. Auto-detect, or pin a specific language.
- **출력 언어** (Output language) — the languages to translate into (you can pick several). Requires the translation model. See **Live translation**.
- **회의 모드** (Meeting mode) — the shape of the meeting. See below.
- **화자** (Speakers) — how many people are in the room. See below.

### 시작하기 (Get started) — right

- **파일로 시작하기** (Start from file) — press after picking or dropping a file.
- **지금 녹음 시작** (Start recording now) — pick a mic and record immediately.

## Live mic recording

1. In **시작하기** (Get started), choose your mic (default is "시스템 기본" / System default).
2. Press **지금 녹음 시작** (Start recording now). A short countdown runs before recording begins — you can **cancel** during it.
3. As people speak, the transcript streams live in the center of the window.
4. In the left panel, press **일시 정지** (Pause, ⌘P) to pause, or **정지** (Stop, ⌘R) to end.

**Note**
- Stopping wraps up everything captured so far. If auto-save is on, it's written to a file.
- If auto-save is off, Madi warns you before you leave — you can save first with **내보내기** (Export).

### 에너지 흐름 (Energy flow)

The **에너지 흐름** graph at the bottom of the left panel shows the meeting's texture in a single line — a composite of **speaking pace, overlap and silence**.

- **Click a point on the graph to jump to that moment.** Handy for finding the liveliest stretch of a meeting.
- Before enough speech accumulates it says "발언이 쌓이면 흐름이 표시됩니다" (the flow appears once speech accumulates).

### Swapping mics mid-recording

During a live recording, the **입력 마이크** (Input mic) row in the left panel lets you switch microphones **without interrupting the recording** — handy when you plug in a headset mid-meeting.

### Captions appear as soon as you stop talking

Madi doesn't wait for a window to fill up. When you **pause and go quiet for a moment**, it closes that window early and emits the transcript right away — cutting the wait noticeably in short back-and-forth conversations (like a consultation). Quiet, far-field voices aren't clipped: the threshold adapts automatically.

## System audio capture (Zoom / Teams / video)

You can transcribe whatever is playing through your Mac — online meetings, videos, and so on.

1. Go to **설정 → 녹음 → 입력** (Settings → Recording → Input).
2. Under **음원** (Audio source), pick how to capture sound:
   - **마이크** (Microphone) — only the sound in front of you
   - **시스템 오디오** (System audio) — what's playing on the Mac: Zoom, Teams, Slack, YouTube, etc.
   - **마이크+시스템** (Mic + system) — for online meetings: your voice plus the other side
3. Start recording as usual.

**Note**
- The first time you use system audio, macOS asks for **Screen Recording** permission. Only audio is used; the screen is never saved.

## File and video transcription

1. **Drop** a file onto the window, or click the **파일 선택 or 드래그 앤 드롭** (Choose file or drag and drop) area to pick one. While dragging, **드롭하여 전사** (Drop to transcribe) appears.
2. Press **파일로 시작하기** (Start from file).
3. Progress shows as **전사 중 · N%** (Transcribing · N%).
4. When it finishes, the result appears on screen.

**Note**
- Dropping a file does **not** start transcription by itself — you must press **파일로 시작하기**. That gap is your chance to adjust the meeting info first.
- Audio is extracted from video (mp4, mov, m4v, mkv, webm, avi …) automatically. No conversion needed.
- Two features work **only** on file transcriptions: per-line **audio playback** and **review by ear**. See **Review and correction** and **Workspace and export**.

## 회의 모드 (Meeting mode)

A preset that tunes speaker count and emphasis to the shape of the meeting. Pick it on the first screen under **회의 정보 → 회의 모드**.

| Mode | What it tunes |
|---|---|
| **일반** (General) | Default · auto-detect speakers |
| **1:1** | 2 speakers · emphasize decisions and follow-ups |
| **스탠드업** (Standup) | Auto speakers · emphasize actions and blockers |
| **인터뷰** (Interview) | 2 speakers · preserve question–answer flow |
| **강의** (Lecture) | 1 speaker · organize around key points |

**Note**
- Choose the meeting mode **before** you start recording. It locks while recording.

## 화자 (Speaker count)

If you know how many people are in the room, set it to improve speaker separation. On the first screen under **회의 정보 → 화자**, choose **자동** (Auto) **/ 1명 / 2명 / 3명 / 4명 이상** (1 / 2 / 3 / 4+ people).

Pinning the count when you're sure gives cleaner speaker splits. If you're not sure, leave it on **자동** (Auto). See the **Speakers** page for details.

## Switching transcript views

The toggle at the top of the window switches between two views.

- **내용** (Content) — a clean, readable transcript. The default; best for reading.
- **상세** (Detail) — adds timecodes, low-confidence words (highlighted amber), and speaker-overlap markers. Best for reviewing and fixing.

Adjust text size with the **A− / A+** buttons at the top.

## Privacy

Every transcript in Madi is processed on this Mac. Your transcript never leaves the device.
