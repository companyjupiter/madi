# Workspace and export

Madi shows your entire save folder as a single workspace. The **workspace explorer** on the right of the window lets you reopen past meetings, change where things are saved, and export in the format you need.

> Madi's interface can be switched between 한국어 / English / 日本語 under **설정 (⌘,) → 표시 → 언어 / Language**. This manual writes the Korean label first, with the English UI label in parentheses.

## The workspace explorer

The explorer is **always visible** on the right side of the window. The top is your meeting list; the bottom holds the auto-save, folder and export controls.

### Meeting list

- The **파일** (Files) tab stacks the transcripts in your save folder, most recent first.
- Click a transcript to reopen that meeting.

## Auto-save

- With the **자동저장** (Auto-save) switch on, a transcript is saved as **Markdown (.md)** when transcription finishes.
- The **폴더** (Folder) row shows the current save location. Press **변경** (Change) to pick another.
- The folder you pick is the default location for both **saving** and **exporting**.

> The same setting also lives in **설정 (⌘,) → 저장** (Settings → Save). Use whichever is handier.

**Tip** — press **⌘K** and type **작업 폴더 변경** (Change workspace folder) to pick a folder straight away.

## Export

Press **내보내기** (Export) at the bottom of the explorer and Madi asks for the **내보내기 형식** (Export format). Pick one and you choose where to save.

| Format | Use |
|---|---|
| **Markdown (.md)** | Markdown transcript. Speaker names, translations and corrections are included |
| **Subtitles (.srt)** | SRT subtitles |
| **Subtitles (.vtt)** | VTT subtitles |
| **Plain text (.txt)** | Plain text |
| **JSON (.json)** | JSON data |

**Note**
- The **내보내기** button dims when the transcript is empty.
- SRT/VTT always use the final corrected source text. See **Review and correction**.

## Click to hear that moment

On sessions transcribed **from an audio or video file** (where the original file is still on disk), each line gets a play button.

1. Press the play button on the line you want to hear (tooltip **"이 구간 오디오 재생"** / Play this segment's audio).
2. The original media plays from the exact moment that line was spoken.

> **Note:** Live mic sessions have no source file, so per-line play buttons don't appear.

## Finding past meetings fast

Type a meeting's name into the **⌘K** command palette to jump straight to that saved transcript. You can search by speaker name too.
