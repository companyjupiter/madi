# Review and correction

Once a transcript is done you can read it clean, or go in close and fix it. Madi remembers the fixes you make and applies them automatically in later meetings.

> Madi's interface can be switched between 한국어 / English / 日本語 under **설정 (⌘,) → 표시 → 언어 / Language**. This manual writes the Korean label first, with the English UI label in parentheses.

## 내용 (Content) vs 상세 (Detail) view

The toggle at the top of the window switches between two views.

- **내용** (Content) — a clean read, no timecodes or markers.
- **상세** (Detail) — adds timecodes, low-confidence words (amber), and speaker-overlap markers (**⟨+name 겹침⟩**).

Reviewing and editing happen in the **상세** (Detail) view.

## Editing a line

1. **Double-click** the line you want to fix (or press the pencil button in **상세** view, tooltip **"이 문장 편집"** / Edit this line).
2. Double-clicking from **내용** view switches to **상세** automatically and opens the editor.
3. Fix the text and press **저장** (Save, ⌘↩). To back out, press **취소** (Cancel, Esc).
4. Edited lines are marked **편집됨** (Edited).

When you edit the source, any translation still being generated from the old text is discarded and re-run against your corrected text. Late-arriving AI results never overwrite your correction.

## Correcting translations

**Double-click** a finalized translation to open a **번역 교정** (Translation correction) field and fix that language's translation directly.

- Saved translations get a pencil mark, and the other languages in a multi-target translation are left alone.
- Corrected source text, translations and speaker names are saved into Markdown and JSON, and translations survive reopening a Markdown transcript.
- SRT/VTT always use the final corrected source text.

## 검토 필요 (Needs review) — sweep low-confidence words

The **상세** view highlights words recognized below the confidence threshold (default 0.55) in amber.

1. The bar at the top shows **검토 필요 N개** (N words need review) and your position (**N/total**).
2. Use **∧** (previous flagged word) and **∨** (next flagged word) to jump between them.
3. Check each one and fix it in place if needed.

Adjust the threshold under **설정 (⌘,) → 저장 → 음성 인식** (Settings → Save → Speech recognition), **저신뢰 표시 기준 (VAD)**. Raising it flags more words.

## Review by ear

On file transcriptions, Madi can play back the audio for each flagged word so you can check it by ear.

1. Press the play button in the review bar (tooltip **"저신뢰 단어 귀로 검토"** / Review low-confidence words by ear).
2. The flagged words play in order, advancing automatically — hands-free. Progress shows as **재생 N/total** (Playing N/total).
3. Press the same button again to stop (tooltip **"귀로 검토 멈춤"** / Stop review by ear).

> **Note:** Review by ear works **only on file transcriptions**, where the original media exists. Live mic recordings have no source file, so it doesn't appear.

## AI correction (after recording)

When recording ends, the on-device LLM reads the whole conversation and conservatively fixes **obvious speaker mis-splits** and **lines transcribed in the wrong language**.

- **Turn it on:** **설정 (⌘,) → 번역 → AI 교정 (세션 종료 후)** → **화자·언어 자동 교정**.
- When applied, a note appears above the transcript with a **화자 교정 되돌리기** (Undo speaker correction) button — **one click reverts all of it.**
- Requires the hardware-selected DNA3.0 translation model.

## Personal glossary — learning from your corrections

When you fix a line, Madi learns that correction. With the **단어장** (Glossary) switch on, it automatically fixes the same domain term or name in later meetings.

**Turn it on:** **설정 (⌘,) → 단어장** (Settings → Glossary), switch **학습한 교정 자동 적용** (Auto-apply learned corrections).

> **Note:** Learning happens **always**, regardless of the switch — the switch only controls *applying*. So turning it on immediately applies everything learned so far.

### Confidence threshold (minimum hits)

- The **최소 확인 횟수** (Minimum hits) slider sets how many times the same correction must be seen before it's trusted and auto-applied (1–5).
- Higher is more conservative — it stops one accidental edit from overwriting later transcripts.

### Managing learned corrections

Manage the learned rules in the list under **설정 → 단어장**.

- Each rule shows as `wrong word → right word` with its hit count.
- The trash button next to a rule forgets just that one.
- **전체 지우기** (Clear all) wipes them all.

## Selecting and copying text

You can drag-select across the whole transcript and copy with **⌘C**.
