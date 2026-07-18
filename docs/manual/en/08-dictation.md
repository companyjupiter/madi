# System dictation (coming later)

> **In the works — not included in the current beta.** The following describes a planned feature. In this version there is **no 받아쓰기 (Dictation) tab** in Settings and the hotkey does nothing.

System dictation is a planned voice-input feature for anywhere in macOS. The goal: hold a global hotkey, speak, release — and what you said is turned into text **on-device** and inserted into whatever app is frontmost (Notes, Mail, Slack, your code editor). Like meeting transcription and translation, it's designed to run 100% on-device.

## Planned behavior

- **Push-to-talk** — records only while the global hotkey is held; releasing inserts the text.
- **Light and fast** — no large language model; a short dictation-only recognition pass that shuts down when done, so it stays light even on low-memory Macs.
- **Clipboard preserved** — saves your clipboard before inserting and restores it right after.
- **Disabled while recording a meeting** — dictation and meeting recording share the mic, so it's off during recording to avoid conflicts.

## For now

What you can use today is **meeting transcription, speaker separation, on-device translation, review & correction, and AI summary**. System dictation is planned for a later update. Check for updates via **Madi menu → 업데이트 설치… (Install update…)**.
