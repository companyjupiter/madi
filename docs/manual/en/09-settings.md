# Settings

Open Settings with **⌘, (Command + comma)** — the gear button in the left panel does the same. This is where the **"set it once"** options live, rather than the things you touch every meeting. The tabs across the top are **녹음 · 저장 · 번역 · 단어장 · 모델 · 받아쓰기** (Recording · Save · Translation · Glossary · Model · Dictation).

> The app interface is in Korean. Korean UI labels are shown below with an English gloss in parentheses.

> **Per-meeting choices** (input/output language, meeting mode, speaker count) are **not** in Settings — they're on the first screen under **회의 정보** (Meeting info). See **Recording and transcription**.

> **Note:** The **녹음** (Recording) tab is locked while recording or paused. Stop the recording to change it.

---

## 녹음 (Recording)

How audio is captured, how live transcription behaves, and how things look.

### 입력 (Input)

- **음원** (Audio source) — what to listen to.
  - **마이크** (Microphone) — your voice / in-person meetings.
  - **시스템 오디오** (System audio) — sound playing on the Mac (Zoom, Teams, Slack, YouTube …). The first use asks for Screen Recording permission (audio only; the screen is never saved).
  - **마이크+시스템** (Mic + system) — best for online meetings (your voice plus the other side).
- **마이크** (Microphone) — which input device to use (when the source is 마이크 or 마이크+시스템). Default is "시스템 기본" (System default).
- **언어** (Language) — pin the transcription language or leave it automatic: **자동 감지** (Auto-detect) **/ 한국어 / English**. System dictation follows this setting too.

### 화자 (Speakers)

- **화자 분리** (Speaker separation) — tell apart who spoke.
- **중첩 발화 감지** (Overlapping speech detection) — detect where two people talk at once (the overlap markers in Detail view).

### 실시간 (Live)

- **반응 속도** (Response speed) — **빠름 (5초)** / **보통 (7초)** / **정확 (10초)** (Fast 5 s / Normal 7 s / Accurate 10 s). Fast puts text on screen more often and feels quicker; Accurate sees more context and reads better.
  - *With 2 or more output languages this drops to a floor of **보통 (7초)** — even if you picked Fast, it becomes 7 s. The bidirectional case (`한국어` plus exactly one other language) is exempt.*
- **실시간 프리뷰** (Live preview) — show interim text in gray before a window is finalized (no accuracy cost, ~830 MB more memory).

### 표시 (Appearance)

- **외관** (Appearance) — System / Light / Dark theme.

### 자막 오버레이 (진료실) (Caption overlay — clinic)

Sizing for the interpreting caption windows and the second (patient) display. See **Live translation**.

- **직원 자막 크기** (Staff caption size) — caption text on the main display (14–48 pt).
- **환자용 대형 자막 (별도 화면)** (Large patient captions — separate display) — puts a second panel in the patient's language at a size readable from across the room. Turning it on reveals:
  - **환자 자막 크기** (Patient caption size) — 24–96 pt.
  - **환자 화면** (Patient display) — which screen to use, when more than one is connected.
  - **환자 언어** (Patient language) — automatic (the other party's language) or pinned.

---

## 저장 (Save)

File saving and recognition thresholds.

### 자동 저장 (Auto-save)

- **완료 시 .md 자동저장** (Auto-save .md on finish) — write a Markdown file when transcription ends.
- **폴더 / 변경…** (Folder / Change…) — pick the save folder. This folder is the workspace shown in the explorer.

> The same setting also lives at the bottom of the workspace explorer.

### 음성 인식 (Speech recognition)

- **저신뢰 표시 기준 (VAD)** (Low-confidence threshold) — words recognized below this confidence (default 0.55) are flagged as **검토 필요** (needs review). Range 0.35–0.9; raising it flags more words. See **Review and correction**.

---

## 번역 (Translation)

Where on-device translation (Korean, English, Japanese, Chinese) is turned on and off.

> On builds without the translation engine this tab is hidden entirely.

### 번역 모델 (DNA3.0-4B · ~2.6 GB) — translation model

- **상태** (Status) — 설치됨 (Installed) / 검증 중 (Verifying) / download progress / 미설치 (Not installed).
- **번역 모델 다운로드** (Download translation model) — fetches the model. It isn't bundled; you download it when you want it (~3 GB more memory in use). While downloading you can **취소** (Cancel); once installed, **Finder에서 보기** (Show in Finder) opens its location.

### 실시간 번역 (다중 대상) — live translation, multi-target

- **한국어 / English / 日本語 / 中文** — toggle the target languages (up to 3). Every line is translated into all of them at once and shown under the original (the source language is excluded automatically).
- Requires the model first. With 2+ targets, response speed falls to a floor of "보통 (7초)" — see the Recording tab.

### 번역 반응 (실시간) — Live translation response

- **마지막 줄 대기 (초)** (Wait for last line, seconds) — waits this long (0.5–5.0 s, default 3) after the last spoken line stops changing before translating it. Shorter shows captions sooner but may translate an unfinished sentence. **Committed lines (once the next line starts) translate immediately regardless of this value**, and it is independent of the STT response-speed setting.

### AI 교정 (세션 종료 후) — AI correction (after session)

- **화자·언어 자동 교정** (Auto-correct speakers and language) — when recording ends, the on-device LLM reads the conversation and conservatively fixes obvious speaker mis-splits and wrong-language lines. Speaker corrections can be **undone in one click**.
- Requires the translation/summary model (DNA3.0-4B).

---

## 단어장 (Glossary)

Madi learns the corrections you make to frequently-misheard domain terms and names, and fixes similar errors automatically in later meetings. See **Review and correction**.

- **학습한 교정 자동 적용** (Auto-apply learned corrections) — controls whether learned corrections are actually applied. **Learning always happens**; this switch only controls applying. (Off by default — turn it on yourself.)
- **최소 확인 횟수** (Minimum hits) — how many times (1–5) the same correction must be seen before it's auto-applied. Higher is more conservative, so one accidental edit won't overwrite later transcripts.
- **Learned corrections list** — shows each rule (wrong word → right word, hit count). The trash button forgets one rule; **전체 지우기** (Clear all) wipes them all.

---

## 모델 (Model)

Status and management for the transcription (Whisper) model.

- **상태 / 위치** (Status / Location) — whether the model is installed, and its file path.
- **모델 재다운로드** (Re-download model) — fetch it again.
- **Finder에서 보기** (Show in Finder) — open the model's location.

> The translation model (DNA3.0-4B) is managed on the **번역** (Translation) tab.

---

## 받아쓰기 (Dictation)

Settings for system-wide push-to-talk dictation. See the **System dictation** page for full usage.

- **어디서나 받아쓰기 사용** (Enable dictation anywhere) — hold the right **⌥ (Option)** key, speak, release, and the text lands in the frontmost app's text field.
- **누르고 있는 동안 녹음** (Hold to record) — shows the hotkey (right ⌥ Option). Read-only.
- **손쉬운 사용 권한** (Accessibility permission) — whether it's granted, and the **시스템 설정에서 허용** (Allow in System Settings) button. Required to insert text into other apps; coming back to this window re-checks it automatically.
- **현재** (Current) — current dictation state (꺼짐 / 대기 중 / 듣는 중… / 변환 중… / 입력 중…).
