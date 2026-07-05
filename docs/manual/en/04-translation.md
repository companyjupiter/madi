# Real-time translation & interpreting

Madi's translation runs 100% on your device — no cloud, no account. While a meeting is in progress, each spoken line is translated into Korean, English, Japanese, and/or Chinese and shown right beneath the original. Everything is handled by the bundled on-device LLM (DNA3.0-4B).

## First: download the translation model

Translation needs a separate model (DNA3.0-4B, ~2.6 GB) that is not bundled with the app. You download it once, on demand.

1. Open **설정 → 번역** (Settings → Translation) — or the **모델** (Model) tab.
2. Click **번역 모델 다운로드** (Download translation model).
3. When the download finishes, the real-time translation toggles become active.

While in use it needs roughly 3 GB of extra memory. Until the model is downloaded the translation toggles are disabled and you'll see the note "번역 모델을 먼저 다운로드하세요." (Download the translation model first).

## Turn on real-time translation (multi-target)

In **설정 → 번역 → 실시간 번역 (다중 대상)** (Settings → Translation → Real-time translation, multi-target), pick one or more target languages:

- **한국어** (Korean)
- **English**
- **日本語** (Japanese)
- **中文** (Chinese)

You can enable several at once. Madi translates each line into all chosen languages simultaneously and shows them directly below the original, each tagged with its language (한 / EN / 日 / 中). The original's own language is excluded automatically.

## Translation types itself out

You don't wait for the whole translation to be built. Madi fills it in word by word as it's generated (about one character every 19 milliseconds). A caret **▍** blinks at the end of a line that's still being written, so a half-arrived translation reads as "still typing," not a truncated sentence.

While you're still speaking, a provisional translation appears first, marked **진행 중** (in-progress). When the line commits, the provisional translation is smoothly replaced by the final one — and it stays on screen until the final translation arrives, so the translation never briefly disappears.

## Face-to-face interpreting — bidirectional languages

Madi is designed for a face-to-face conversation between two people who speak different languages (for example, Korean staff and a Japanese or Chinese patient).

Turn on **`한국어` plus exactly one other language** (e.g. Korean + 日本語) and you get bidirectional interpreting mode:

- **Direction is detected per line.** A line spoken in Japanese is translated only to Korean; a Korean line only to Japanese. No wasted translations, so it's faster.
- **Both sides transcribe correctly even when the two languages alternate.** Madi re-checks the language every segment, so one person speaking Korean and another speaking Japanese are both transcribed accurately.
- In this mode the response speed is not forced to slow down (see below).

## Frequent-phrase dictionary (instant translation)

For settings that repeat the same guidance (e.g. after-care instructions in a clinic), you can pre-save the translation of your common phrases. When a saved phrase is spoken, its translation appears **instantly (0 s)**, without going through the model.

A few phrases are included by default, and you can add or edit your own (stored at `~/Library/Application Support/Sovereign/faq_translations.json`). For safety it only matches exact phrases.

## Response speed & translation quality

Choosing **two or more** target languages (e.g. 日本語 + 中文 + English) locks the response speed to **정확 (10초)** — Accurate (10s), so an error in the original line boundary doesn't propagate into every translation.

> Exception: in **bidirectional interpreting** mode (`한국어` + one other language), each line has only a single real target, so it is not locked to 10 s — captions appear faster in face-to-face interpreting.

When translation falls behind, **"N줄 번역 대기"** (N lines waiting to translate) appears at the top. It means the work is queued, not stuck (the model translates one line at a time).

## Caption overlay (자막 오버레이)

The **자막 오버레이** (caption overlay) is a floating, always-on-top live-translation caption window. Place it over a Zoom/Teams call, or on a clinic display, to follow the other side's speech in real-time translation.

- Toggle it with the **자막 오버레이** button in the side panel.
- The window stays on top but never takes focus, so your clicks and typing keep going to the call app.
- It floats even over fullscreen apps, and you can drag it anywhere by its background.
- The large text is the translation; the small text below is the original.
- With more than one speaker, the caption shows a **speaker color dot and name** so you know who said it.
- While waiting for speech, a **mic level bar** moves to confirm the system is listening.
- The status text ("in-progress / translating… / waiting for speech") is shown **in the viewer's own language** — 「翻訳中…」 for a Japanese caption, 「翻译中…」 for a Chinese one.

### Staff caption + patient caption (dual screen)

For face-to-face clinic interpreting you can split the caption into **two** panels.

- **Staff caption** — small, on the main screen, in the staff's language (first translate target).
- **Patient caption** — large (for distance reading), on an external monitor, in the patient's language.

Turn it on in **설정 → 자막 오버레이(진료실)** (Settings → Caption overlay (Clinic)). You can set staff font (14–48pt), patient font (24–96pt), panel width, patient screen, and patient language separately — large type for a 1.5–2.5 m viewing distance between the chair and the display.

## Chat view

When exactly two people are talking, you can view the transcript **like a messenger, left and right**. The first speaker sits on the left, the other on the right — good for reading back-and-forth interpreting. The chat-view button appears in the control bar when two speakers are detected.

## Performance note — it depends on your memory

Live translation and the meeting-summary model share the same LLM, so behavior depends on how much memory your Mac has.

- **16 GB+ Macs**: live translation and features like **라이브 액션 추출** (live action extraction) run together. Translation captions never stall.
- **Under-16 GB Macs**: only one model fits in memory at a time. Turning on a feature like **라이브 액션 추출** pauses live translation while it runs.

If you want uninterrupted translation captions on an under-16 GB Mac, leave extra features like live action extraction off.
