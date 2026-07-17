# Live translation and interpreting

Madi's translation runs 100% on your device — no cloud, no account. While a meeting is in progress, each spoken line is translated into Korean, English, Japanese and/or Chinese and shown right beneath the original. Everything is handled by the on-device LLM (DNA3.0-4B).

> The app interface is in Korean. Korean UI labels are shown below with an English gloss in parentheses.

## First: download the translation model

Translation needs a separate model (DNA3.0-4B, ~2.6 GB) that isn't bundled with the app. You download it once.

1. Open **설정 (⌘,) → 번역** (Settings → Translation).
2. Press **번역 모델 다운로드** (Download translation model).
3. When it finishes, the translation options become available.

It needs about 3 GB of additional memory while in use. Before the model is installed the toggles are disabled and you'll see "번역 모델을 먼저 다운로드하세요." (Download the translation model first.)

> **If you don't see the 번역 tab** — your build doesn't include the translation engine, and translation isn't available at all.

## Choosing output languages

Two places, same setting — use whichever is handy.

- **First screen → 회의 정보 → 출력 언어** (Meeting info → Output language) — as you start a meeting.
- **설정 (⌘,) → 번역 → 실시간 번역 (다중 대상)** (Settings → Translation → Live translation, multi-target) — toggles for 한국어 / English / 日本語 / 中文.

Every line is translated into all the languages you pick and shown directly under the original, each tagged with its language. The source language is excluded automatically.

**Note**
- You can pick **up to 3** output languages.
- Without the translation model you can't pick output languages at all.

## Translations type themselves out

Madi doesn't wait for a translation to be finished. Words fill in on screen as they're generated. A cursor **▍** blinks at the end of a line still being written, so you know it's continuing rather than truncated.

While someone is still speaking, an interim translation appears first, marked **진행 중** (in progress). When the line is finalized the interim smoothly becomes the final translation — and the interim stays on screen until the final arrives, so translations never blink out.

## Face-to-face interpreting — bidirectional

Madi is designed for two people speaking different languages in the same room (for example, a Korean staff member and a Japanese or Chinese visitor).

Turn on **only `한국어` plus one other language** (e.g. 한국어 + 일본어) and it becomes a bidirectional interpreting mode.

- **Direction is detected per line.** A Japanese line is translated only into Korean; a Korean line only into Japanese. No wasted work, so it's faster.
- **Both sides transcribe correctly even when you alternate languages.** The language is re-checked per segment, so one person speaking Korean and the other Japanese both get accurate transcripts.
- This combination is exempt from the latency floor below.

## Frequent-phrase dictionary (instant translation)

For places that repeat the same guidance (say, post-procedure instructions in a clinic), you can pre-store translations of common phrases. When a stored phrase comes up, the translation appears **instantly (0 s)** without going through the model.

A few phrases ship by default, and you can add or edit your own.

- File: `~/Library/Application Support/Sovereign/faq_translations.json`
- For safety it only fires on an **exact match**.

## Latency and translation quality

With **2 or more** output languages, boundary errors in the source line would propagate into every language — so the response speed drops to a floor of **보통 (7초)** (Normal, 7 s). If you had picked **빠름 (5초)** (Fast, 5 s), it automatically becomes 7 s. **정확 (10초)** (Accurate, 10 s) still works.

> **Exception:** the **bidirectional** mode (`한국어` + exactly one other language) is not forced, because each line's effective target count drops to one. Captions appear faster in face-to-face interpreting.

When translation falls behind you'll see **"번역 중 · N줄 대기"** (Translating · N lines queued). It isn't stuck — it's working through them in order (the model translates one line at a time).

## AI language correction (after recording)

When recording ends, the on-device LLM reads the conversation and conservatively fixes **lines transcribed in the wrong language**. Toggle it under **설정 (⌘,) → 번역 → AI 교정 (세션 종료 후)** → **화자·언어 자동 교정**. See **Speakers**.

## Caption overlay

The **caption overlay** is a floating window of live translated captions that sits on top of everything. Park it over a Zoom or Teams call, or on a clinic display, and follow what the other person is saying in real time.

Toggle it with the **speech-bubble icon** in the top toolbar. **The button only appears once you've picked at least one output language.**

- The window always stays in front but never takes focus, so you can keep clicking and typing in your call app.
- It floats above full-screen apps, and you can drag it anywhere by its background.
- The largest text is the translation; the smaller text beneath it is the original.
- With multiple people, captions carry the **speaker's color and name** so you know who's talking.
- While waiting for speech, a **mic level bar** moves to confirm the system is listening.
- Status text ("진행 중 / 번역 중… / 음성을 기다리는 중…") is shown **in the viewer's language** — 「翻訳中…」 on Japanese captions, 「翻译中…」 on Chinese.

### Staff captions + patient captions (dual display)

For clinic interpreting you can split captions into **two** panels.

- **Staff captions** — small, on the main display, in the staff member's language.
- **Patient captions** — large, on an external monitor, for reading at a distance, in the patient's language.

Turn it on in **설정 (⌘,) → 녹음 → 자막 오버레이 (진료실)** (Settings → Recording → Caption overlay (clinic)). You can set staff text size (14–48 pt), patient text size (24–96 pt), which display to use, and the patient's language. The large sizes are meant to read well across the 1.5–2.5 m between a treatment chair and the display.
