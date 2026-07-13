# Editing & Review

Once a transcript is ready, you can read it cleanly or dig in and fix it. Madi remembers your corrections and auto-applies them to future meetings, and even points out parts you could cut.

## Content view vs Detailed view

Use the toggle at the top of the screen (tooltip **내용: 깨끗한 회의록 보기 · 상세: 시각·신뢰도·겹침 표시** / "Content: clean transcript · Detailed: timecodes, confidence, overlap") to switch views.

- **내용 (Content)** — the default clean reading view, with no markers.
- **상세 (Detailed)** — adds timecodes, low-confidence words (amber highlight), and overlap markers (⟨+name 겹침⟩, i.e. speakers overlapping).

## Inline editing

1. **Double-click** the line you want to fix (or, in **상세 (Detailed)** view, press the pencil button — tooltip **이 문장 편집** / "Edit this line").
2. Double-clicking in **내용 (Content)** view automatically flips to **상세 (Detailed)** view and opens the edit field.
3. Fix the text and finish typing.
4. Edited lines are marked **편집됨** (Edited).

Editing the source automatically discards translations still being generated from
the previous source and translates from the corrected text again. A late, stale AI
result cannot overwrite your correction.

## Correcting a translation

**Double-click** a completed translation to edit that language directly. A pencil
marks the saved translation, while other target languages remain intact. Corrected
source text, translations, and speaker names are stored together in Markdown and
JSON; translations survive reopening a Markdown transcript. SRT/VTT always use the
final corrected source.

## Review needed — confirm low-confidence words fast

The **상세 (Detailed)** view flags words below the confidence threshold (set in Settings, default 0.55) in amber.

1. A count appears at the top: **검토 필요 N개** ("N to review").
2. Use the **이전** (Previous — previous review word) / **다음** (Next — next review word) buttons to jump between the flagged words.
3. Confirm each word and fix it on the spot if needed.

## Listen-to-review — confirm by ear

For sessions transcribed from a file, Madi can auto-play each low-confidence word's audio span in sequence so you can confirm it by ear (this reuses click-to-play).

1. Press the play button in the review bar (tooltip **저신뢰 단어 귀로 검토** / "Review low-confidence words by ear").
2. The flagged words' audio plays in order, advancing to the next word automatically when one finishes (hands-free).
3. To stop, press the same button again (tooltip **귀로 검토 멈춤** / "Stop ear review").

> **Note:** Listen-to-review is only available in file-transcribed sessions where the original media is present.

## Personal vocabulary (glossary) — learning your corrections

When you correct a transcript line, Madi learns that correction. With the **단어장** (vocabulary) feature on, it auto-fixes the same domain-term and name mis-recognitions in future meetings.

**To turn it on:** open **설정 (Settings, ⌘,) → 단어장** (Vocabulary) tab and enable **학습한 교정 자동 적용** ("Auto-apply learned corrections").

> **Note:** Learning always happens regardless of the switch — the switch only turns on "apply." So flipping it on takes effect at once for everything learned so far.

### Trust threshold (minimum confirmations)

- The **최소 확인 횟수** (minHits, "minimum confirmations") slider sets how many times a correction must be confirmed before Madi trusts it enough to auto-apply (1–5).
- A higher value is more conservative — it keeps a single accidental edit from overwriting later transcripts.

### Managing & forgetting learned rules

Manage learned rules in the list under **설정 → 단어장** (Settings → Vocabulary).

- Each rule shows as `wrong → right` with its confirmation count.
- Forget a single rule with the trash button beside it (tooltip **이 교정을 잊기** / "Forget this correction").
- To remove them all, press **전체 지우기** ("Clear all").

## Tighten — find parts to cut

**타이튼 (Tighten)** detects filler words and silences you could cut.

1. The control panel shows **타이튼: N컷 · N초 절감 가능** ("Tighten: N cuts · N seconds saveable").
2. To get the cut list as a file, choose **내보내기 → 타이튼 컷 목록 (.csv)** (Export → Tighten cut list).

> **Note:** Tighten never touches the clean transcript body — it only tells you what could be cut.

### Editor aids

Turn the following analyses on or off in the **설정 → 편집·저장** (Settings → Edit & Save) tab (off by default — enable only when needed).

- **챕터 (Chapters)** — automatic chapter breaks.
- **리테이크 · 하이라이트 (Retake / Highlight)** — detect re-takes and mark highlights.

## Text selection & copy

You can drag-select text anywhere in the transcript and copy it with **⌘C**, across the whole transcript.
