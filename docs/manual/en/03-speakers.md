# Speakers

Madi automatically works out who spoke during a meeting. All of this runs on this Mac.

> The app interface is in Korean. Korean UI labels are shown below with an English gloss in parentheses.

## Automatic speaker separation

While recording and transcribing, Madi splits speech by speaker automatically.

- Each speaker gets a distinct **color** and a **화자 N** (Speaker N) label.
- The **speaker bar** in the left panel shows, in one line, who spoke when across the meeting.

**Note**
- You can turn this off with the **화자 분리** (Speaker separation) switch in **설정 (⌘,) → 녹음 → 화자** (Settings → Recording → Speakers).

## Pinning the speaker count

If you know how many people are in the room, set it to improve accuracy.

1. On the first screen, go to **회의 정보 → 화자** (Meeting info → Speakers).
2. Choose **자동** (Auto) **/ 1명 / 2명 / 3명 / 4명 이상** (1 / 2 / 3 / 4+ people).

**Note**
- Pinning the count when you're sure gives cleaner speaker splits. If you're not sure, leave it on **자동** (Auto).
- Choose it **before** recording — it locks once recording starts.

### 미확인 (Unknown) speakers

When you **pin** the speaker count, any voice that clearly doesn't match one of the people you specified gets collected under **미확인** (Unknown). This stops a passer-by's one-liner or a burst of noise from being misattributed to one of your real speakers.

- **미확인** is not a person — it means "there's nowhere to put this." You cannot name it.
- It never appears when the count is left on Auto.

## Naming speakers

1. In the transcript, click a speaker label (e.g. **화자 1** / Speaker 1) or the speaker chip.
2. Type the real name into the **이름 (예: 김부장)** (Name, e.g. Manager Kim) field.
3. Press **저장** (Save). The name applies to **all of that speaker's lines and to exports**.

**Note**
- Names apply to **this transcript only**. Madi will not recognize the same person automatically in your next meeting — you name them again each time.
- **미확인** (Unknown) cannot be named.

## AI speaker correction (after recording)

When recording ends, the on-device LLM reads the conversation and conservatively fixes **obvious speaker mis-splits** — one person's speech broken across two speakers, or a line attributed to the wrong person.

- Toggle it under **설정 (⌘,) → 번역 → AI 교정 (세션 종료 후)** (Settings → Translation → AI correction (after session)), switch **화자·언어 자동 교정** (Auto-correct speakers and language).
- When a correction is applied, a note appears above the transcript with a **화자 교정 되돌리기** (Undo speaker correction) button — **one click reverts all of it.**
- Requires the translation model (DNA3.0-4B).

## Overlap markers

When two people talk at once, the **상세** (Detail) view shows a **⟨+name 겹침⟩** (overlap) marker naming the second speaker who cut in.

**Note**
- Overlap markers appear **only** in the **상세** (Detail) view. Switch from **내용 → 상세** at the top of the window.
- Requires **중첩 발화 감지** (Overlapping speech detection) in **설정 (⌘,) → 녹음 → 화자**.
