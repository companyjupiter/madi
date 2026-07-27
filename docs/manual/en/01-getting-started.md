# Getting started

Welcome to Madi. Madi transcribes and translates your meetings **entirely on this Mac**. Live transcription, audio and video file transcription, speaker separation, on-device translation — every step happens inside your own machine.

## What Madi does

- **Live transcription** — listens to your mic or meeting audio and puts text on screen almost as fast as you speak.
- **File and video transcription** — drop in a recording and Madi writes out the whole conversation.
- **Speaker separation** — tells apart who spoke when, and lets you name them.
- **On-device translation** — renders Korean, English, Japanese and Chinese in real time, and can float them as captions over any window.
- **AI summary and Q&A** — distills the summary, decisions and actions when the meeting ends, and lets you ask about it in natural language.
- **Review and correction** — finds words it wasn't sure about, lets you fix them, and remembers your fixes for next time.
- **System-wide dictation** *(coming later)* — a planned feature: hold a key in any app, speak, and your words land in the text field.

### 100% on-device — your data never leaves this Mac

Madi's core promise is **sovereignty**. No audio, no transcript, no translation is ever sent to the cloud. Once the models are downloaded it works with the internet unplugged. Your meetings exist only on your device.

## System requirements

| Item | Minimum | Notes |
|---|---|---|
| Mac | **Apple Silicon (M1 or later)** | Intel Macs are not supported (arm64 only) |
| macOS | **14.0 (Sonoma) or later** | |
| Memory | **8 GB or more** | The baseline machine is an M1 MacBook Air with 8 GB |
| Disk | **~1 GB** (transcription only) | Add 1.31 GB on an 8 GB Mac, or 2.78 GB on 16 GB+, if you use translation |
| Internet | Only for the first model download | It runs offline afterwards |

8 GB Macs are fully supported — Madi applies a low-memory profile automatically. See the **8 GB Mac guide** chapter.

## About the models

Madi uses two kinds of AI model.

- **Whisper large-v3 Turbo Q8 (~867 MB, required)** — runs transcription, speaker separation, and live preview in Madi's native Zig/Metal engine. The standard DMG downloads it once on first launch.
- **DNA3.0 language model (optional)** — powers **translation**, **AI correction**, and **summary / Q&A**. Madi recommends 2B (~1.31 GB) on an 8 GB Mac and quality-first 4B (~2.78 GB) on 16 GB or more.
  - Where: **Settings (⌘,) → Translation**, the "Download translation model" button.
  - Only the selected model is downloaded, using the same amount of disk space.

If you don't use translation, summary or Q&A you never need this model. Transcription and speaker separation run entirely on the installed Whisper model.

## About memory (honestly)

- **8 GB Mac (e.g. M1 MacBook Air)** — Madi automatically uses DNA3.0-2B and a four-turn translation horizon. The measured translation-engine footprint is about 2.4 GB.
- **16 GB and above** — Madi uses quality-first DNA3.0-4B (measured at about 5.1 GB).
- **Live preview** shares the committed Whisper process; it no longer launches a second 830 MB model.

## Permissions Madi may ask for

Madi doesn't ask for everything up front — it requests each permission **the first time you use that feature**.

- **Microphone** — to record. Asked when you first start a recording.
- **Screen Recording** — only to capture system audio (sound playing on your Mac, e.g. Zoom, Teams, YouTube). macOS bundles audio capture into the Screen Recording permission; **Madi never records your screen.**
(The **Accessibility** permission is only for **system-wide dictation** (coming later), and the current beta doesn't request it.)

If you deny a permission and want it later, open **System Settings → Privacy & Security**, find the item (Microphone / Screen Recording) and enable Madi.

## First-run quick start

1. Open Madi. **Set up Madi for this Mac** appears before any download begins.
2. Choose **Download recommended setup** if you plan to use translation, correction, or summaries. Madi detects memory and downloads DNA3.0-2B on 8 GB or DNA3.0-4B on 16 GB and above alongside Whisper.
3. Choose **Set up transcription only** if you want transcription and speaker separation first. It downloads only the required Whisper Q8; DNA remains available later under **Settings (⌘,) → Translation**.
4. If Whisper finishes before DNA, you can choose **Start transcribing while DNA continues** and enter Madi immediately.
5. Once ready, set the input language, meeting mode, and speaker count under **Meeting info**, then press **Start recording now** or drop in an audio/video file.
6. Press **Stop** to wrap up. If auto-save is on, the transcript is written to a file.

> Existing users with Whisper Q8 installed bypass this onboarding after an update. On an 8 GB Mac, the detailed guide opens once on a later launch so it does not cover the model setup screen.

## The window

Once recording starts, the window splits into three columns.

- **Left — session panel**: transport buttons (pause / stop), total time, the speaker bar, and the energy-flow graph. The Settings gear lives here too.
- **Center — transcript**: what was said. You read and edit here.
- **Right — workspace explorer**: past meetings, the auto-save switch, save folder, and export.

## Keyboard shortcuts

| Shortcut | What it does |
|---|---|
| **⌘,** | Open Settings |
| **⌘K** | Command palette (see below) |
| **⌘F** | Find in transcript |
| **⌘R** | Start / stop recording |
| **⌘P** | Pause / resume |
| **⌘?** | Open this user manual |

### Command palette (⌘K)

Press **⌘K** for a search box. Run things by name instead of hunting through menus. (It's also in the View menu as **명령 팔레트**.)

- **Generate summary / by-speaker summary** — open the meeting-summary sheet (when a transcript exists).
- **New session** — clear the current transcript.
- **Change workspace folder** — pick where files are saved.
- **A speaker's name** — jump straight to that speaker in this meeting.
- **A past meeting's name** — reopen that saved transcript.

## Help menu

- **Madi User Manual (⌘?)** — opens this document. Works offline.
- **8 GB Mac Guide** — appears only on 8 GB-class Macs.
- **Install update…** — checks for and installs a new version.
- **About** — version and licenses.

You're ready. See the other pages for recording, speakers, translation, dictation and settings.
