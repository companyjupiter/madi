# Real-time translation

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

> Note: choosing two or more target languages locks the live response speed to **정확 (10초)** — Accurate (10s). This uses the longest context so that an error in the original line boundary doesn't propagate into every translation.

## Interim (in-progress) translation

You don't have to wait for a sentence to finish. While you're still speaking, a provisional translation of the in-progress line appears, marked **진행 중** (in-progress). When that line commits, the provisional translation is replaced by the final one.

Madi reuses the interim translation for the committed line, so it appears fast and the same sentence is never re-translated.

## Caption overlay (자막 오버레이)

The **자막 오버레이** (caption overlay) is a floating, always-on-top live-translation caption window. Place it over a Zoom/Teams call to follow the other side's speech in real-time translation.

- Toggle it with the **자막 오버레이** button in the side panel.
- The window stays on top but never takes focus, so your clicks and typing keep going to the call app.
- It floats even over fullscreen apps, and you can drag it anywhere by its background.
- The large text is the translation; the small text below is the original. While a translation is still in flight it's marked **진행 중** (in-progress).

The caption uses the first of your chosen target languages. If you turn off all translation targets, the overlay closes too (there's nothing left to show).

## Performance note — it depends on your memory

Live translation and the meeting-summary model share the same LLM, so behavior depends on how much memory your Mac has.

- **16 GB+ Macs**: live translation and features like **라이브 액션 추출** (live action extraction) run together. Translation captions never stall.
- **Under-16 GB Macs**: only one model fits in memory at a time. Turning on a feature like **라이브 액션 추출** pauses live translation while it runs.

If you want uninterrupted translation captions on an under-16 GB Mac, leave extra features like live action extraction off.
