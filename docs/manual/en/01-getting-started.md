# Getting Started

Welcome to Madi. Madi is a Korean meeting-intelligence app that transcribes and understands your meetings **entirely on your Mac**. Live dictation, audio and video file transcription, speaker diarization, on-device translation, summaries, and Q&A — every bit of processing happens locally on your machine.

## What Madi does

- **Live transcription** — listens to your microphone or meeting audio and shows text on screen before you even finish speaking.
- **File and video transcription** — drag in a recording or video and Madi transcribes the whole conversation.
- **Speaker diarization** — separates who said what, and when.
- **On-device translation** — translates between Korean, English, Chinese, and Japanese.
- **Summary and Q&A** — distills key points, decisions, and action items, and lets you ask questions about the content.

### 100% on-device — your data never leaves the Mac

Madi's core promise is **sovereignty**. None of your audio, transcripts, translations, or summaries are ever sent to the cloud. It works even with the internet disconnected (once the models are downloaded). Your meeting content lives only on your device.

## About the models

Madi uses two kinds of AI model.

- **Whisper speech model** — handles transcription. It is **bundled with the app**, so there is nothing to download.
- **DNA3.0-4B language model (~2.6 GB)** — powers translation, summaries, Q&A, and title generation. To keep the app small, it is **downloaded the first time you use it.**
  - Where to get it: the “번역 모델 다운로드 (Download translation model)” button under **설정 → 모델 (Settings → Models)** or **설정 → 번역 (Settings → Translation)**.
  - The download is about **2.6 GB**, and it needs roughly that much disk space. (See **번역 / Translation** and **설정 / Settings** for details.)

## Memory guidance (the honest version)

- **8 GB Macs (e.g. the M1 MacBook Air)** — transcription and speaker diarization run smoothly.
- **16 GB or more recommended** — needed for features that run the language model **alongside** transcription. Examples: **라이브 액션 추출 (live action extraction)** — pulling out decisions, to-dos, and questions live while recording — or running **live translation and summary together with** transcription. You can still enable these on 8 GB, but memory will be tight.

## Permissions Madi may ask for

Madi does not ask for everything up front. It requests each permission **the first time the relevant feature needs it.**

- **Microphone** — for recording. Requested the first time you start a recording.
- **Screen Recording** — only when capturing system audio (sound playing on your Mac, e.g. Zoom, Teams, YouTube). macOS bundles audio capture under the Screen Recording permission; **Madi does not save the screen.**
- **Calendar** — optional. Used for meeting prep and attendee matching. You can skip it entirely.
- **Accessibility (손쉬운 사용)** — only needed for **system-wide dictation** (dictating into any app). It is required to insert dictated text into other apps. (See **받아쓰기 / Dictation**.)

If you declined a permission and want to grant it later, open **System Settings → Privacy & Security**, find the relevant item (Microphone / Screen Recording / Accessibility / Calendar), and switch Madi on.

## First-run quickstart

1. Open Madi.
2. (Optional) To use translation, summary, or Q&A, download the translation model (DNA3.0-4B, ~2.6 GB) from **설정 (Settings, ⌘,) → 모델 (Models)** or **번역 (Translation)**.
3. Press **녹음 시작 (Start recording)**, or drag an audio or video file into the window.
4. Watch the live transcript appear on screen.
5. When the meeting ends, press **요약 (Summary)** for an AI summary. (Summaries require the translation model to be installed.)

That's it. For more detail, see the other manual pages on recording, translation, dictation, and settings.
