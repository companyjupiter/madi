# Settings

Open Settings with **⌘, (Command + comma)**. This is where the "set once" controls live — the things you configure rather than touch every session. The tabs across the top are **녹음 (Recording) · 편집·저장 (Editing·Save) · 번역 (Translation) · 단어장 (Personal Vocabulary) · 모델 (Models) · 받아쓰기 (Dictation)**.

> Note: the controls on the **녹음 (Recording)** tab are locked while recording or paused. Stop the recording first, then adjust them.

---

## 녹음 (Recording)

Sets how audio is captured, how live transcription behaves, and how things are displayed.

### 입력 (Input)

- **음원 (Source)** — choose what Madi listens to.
  - **마이크 (Microphone)** — your own voice / in-person meetings.
  - **시스템 오디오 (System audio)** — sound playing on your Mac (Zoom, Teams, Slack, YouTube, etc.). Requests Screen Recording permission on first use (audio only — the screen is not saved).
  - **마이크+시스템 (Mic + system)** — best for online meetings (your voice plus the other party).
- **마이크 (Microphone)** — when using mic or mic+system, pick the input device. Defaults to "시스템 기본 (System default)".
- **언어 (Language)** — **자동 감지 (Auto-detect) / 한국어 (Korean) / English** — pin the transcription language or leave it automatic.

### 화자 (Speakers)

- **화자 분리 (Speaker diarization)** — separates who said what.
- **중첩 발화 감지 (Overlapping speech detection)** — detects stretches where two people talk at once.

### 실시간 (Live)

- **반응 속도 (Responsiveness)** — **빠름 (Fast, 5s) / 보통 (Normal, 7s) / 정확 (Accurate, 10s)**. Fast paints text more often (feels snappier); Accurate uses longer context (better quality). *With two or more translation targets, this is automatically pinned to 정확 (Accurate, 10s).*
- **실시간 프리뷰 (Live preview)** — shows interim text in gray before a window is finalized (no accuracy loss; ~830 MB extra memory).

### 표시 (Display)

- **외관 (Appearance)** — pick the System / Light / Dark theme.

### Auto-save

The auto-save folder setting lives on the **편집·저장 (Editing·Save)** tab (below).

---

## 편집·저장 (Editing·Save)

Controls post-transcription analysis (tighten, chapters, etc.) and how files are saved.

### 자동 저장 (Auto-save)

- **완료 시 .md 자동저장 (Auto-save .md when finished)** — saves a Markdown file automatically when transcription completes.
- **폴더 / 변경… (Folder / Change…)** — choose the save folder.
- **내보내기 시 개인정보 마스킹 (Redact PII on export)** — masks emails, phone numbers, and ID numbers as `[tags]`, but only in shareable files made via "내보내기 (Export)". The auto-saved original and the on-screen transcript are left intact.

### 음성 인식 (Speech recognition)

- **저신뢰 표시 기준 (VAD) (Low-confidence threshold)** — words recognized below this confidence (default 0.55) are flagged as "needs review".

### 편집 기능 (Editing features)

- **편집 기능 사용 (Enable editing features)** — turns on filler/silence tighten, chapters, retakes, and highlight analysis. **Off by default** — turn it on only when needed. (When off, the sections below are disabled.)

### 필러 · 무음 (타이튼) (Fillers · Silence — Tighten)

- **필러 컷 (Filler cut)** — detects filler words ("um…", "uh…").
- **무음 컷 (Silence cut)** — detects long silent gaps.
- **무음 최소초 (Min silence seconds)** — the minimum length to count as silence.

### 챕터 (Chapters)

- **자동 챕터 (Auto chapters)** — splits the conversation into chapters automatically.
- **휴지 경계초 / 최소 간격초 (Pause boundary / Min gap seconds)** — tune the pause length that triggers a chapter break and the minimum chapter spacing.

### 리테이크 · 하이라이트 (Retakes · Highlights)

- **리테이크 감지 (Retake detection)** — finds "second take" passages where something was re-said. The **유사도 (Similarity)** slider tunes sensitivity.
- **하이라이트 (Highlights)** — emphasizes important passages. **최소 신뢰도 (Min confidence)** sets the bar.

---

## 번역 (Translation)

Where you turn on-device translation (Korean, Chinese, Japanese, English) on and off.

### 번역 모델 (DNA3.0-4B · ~2.6 GB) (Translation model)

- **상태 (Status)** — shows Installed / download progress / Not installed.
- **번역 모델 다운로드 (Download translation model)** — fetches the model. It is not bundled with the app and is downloaded when you enable it (~3 GB extra memory). Once installed, **Finder에서 보기 (Reveal in Finder)** opens the file location.

### 실시간 번역 (다중 대상) (Live translation — multi-target)

- **한국어 (Korean) / English / 日本語 (Japanese) / 中文 (Chinese)** — toggle the target languages. Each line is translated into every selected language simultaneously and shown under the original (the source language is excluded automatically).
- The model must be downloaded first. With two or more targets, recording responsiveness is pinned to 정확 (Accurate, 10s) — see the Recording tab.

---

## 단어장 (Personal Vocabulary)

Madi learns the corrections you make to frequently-misheard domain terms and names, then fixes similar mis-recognitions automatically in later meetings.

### 개인 단어장 (Personal vocabulary)

- **학습한 교정 자동 적용 (Auto-apply learned corrections)** — the switch that decides whether learned corrections are actually applied. **Learning always runs**; this switch only enables "apply". (Off by default — turn it on yourself.)

### 적용 기준 (Application threshold)

- **최소 확인 횟수 (Minimum confirmations)** — a correction must be confirmed at least this many times (1–5) before it auto-applies. Higher is more conservative, so a single accidental edit won't overwrite later transcripts.

### Learned corrections list

- Shows each learned rule (wrong word → right word, with a hit count). Use the trash button on a row to "잊기 (Forget)" a single rule, or **전체 지우기 (Clear all)** to empty the list.

---

## 모델 (Models)

Check and manage the status of the speech and language models.

- **상태 / 위치 (Status / Location)** — whether the model is installed and its file path.
- **모델 재다운로드 (Re-download model)** — fetches the model again.
- **Finder에서 보기 (Reveal in Finder)** — opens the model file location.

You can also download the translation model (DNA3.0-4B) from the **번역 (Translation)** tab.

---

## 받아쓰기 (Dictation)

System-wide push-to-talk dictation settings that work in any app. For full usage, see the **받아쓰기 / Dictation** manual page.

### 시스템 받아쓰기 (System dictation)

- **어디서나 받아쓰기 사용 (Enable dictation everywhere)** — hold the right **⌥ (Option)** key while you speak, then release, and the dictated text lands in the frontmost input field of any app. All processing happens on-device.

### 단축키 (Hotkey)

- **누르고 있는 동안 녹음 (Hold to record)** — the default is the right **⌥ Option** key (chosen so it doesn't clash with the command palette, ⌘K).

### 손쉬운 사용 권한 (Accessibility permission)

- **상태 (Status)** — shows whether Accessibility (손쉬운 사용) permission is granted.
- **시스템 설정에서 허용 (Grant in System Settings)** — if it isn't granted, this button opens System Settings. The permission is required to insert text into other apps; once granted, returning to this window recognizes it automatically.

### 상태 (Status)

- **현재 (Current)** — shows dictation's current state (idle / listening / transcribing / inserting, etc.).
