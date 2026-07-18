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

## About the models

Madi uses two kinds of AI model.

- **Whisper speech model** — handles transcription. **Bundled with the app**, nothing to download.
- **DNA3.0-4B language model (~2.6 GB)** — powers **translation**, **AI correction**, and **summary / Q&A**. To keep the app small, it is **downloaded the first time you use it**.
  - Where: **Settings (⌘,) → Translation**, the "Download translation model" button.
  - About **2.6 GB** to download, and the same in disk space.

If you don't use translation, summary or Q&A you never need this model. Transcription and speaker separation run entirely on the bundled Whisper model.

## About memory (honestly)

- **8 GB Mac (e.g. M1 MacBook Air)** — transcription and speaker separation run comfortably.
- **Translation adds about 3 GB.** It works on an 8 GB Mac, but memory gets tight.
- **Live preview** adds roughly another 830 MB.

## Permissions Madi may ask for

Madi doesn't ask for everything up front — it requests each permission **the first time you use that feature**.

- **Microphone** — to record. Asked when you first start a recording.
- **Screen Recording** — only to capture system audio (sound playing on your Mac, e.g. Zoom, Teams, YouTube). macOS bundles audio capture into the Screen Recording permission; **Madi never records your screen.**
(The **Accessibility** permission is only for **system-wide dictation** (coming later), and the current beta doesn't request it.)

If you deny a permission and want it later, open **System Settings → Privacy & Security**, find the item (Microphone / Screen Recording) and enable Madi.

## First-run quick start

1. Open Madi. The first screen has two columns: **Meeting info** and **Get started**.
2. Under **Meeting info**, set up this meeting — input language, output language (if you translate), meeting mode, speaker count.
3. Under **Get started**, pick a mic and press **Start recording now**, or drop in an audio/video file.
4. Watch the live transcript appear in the middle of the window.
5. Press **Stop** to wrap up. If auto-save is on, the transcript is written to a file.

> To translate, first download the translation model (~2.6 GB) in **Settings (⌘,) → Translation**.

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
- **Install update…** — checks for and installs a new version.
- **About** — version and licenses.

You're ready. See the other pages for recording, speakers, translation, dictation and settings.
