# System dictation (받아쓰기)

Dictation (받아쓰기) is Madi's system-wide voice-to-text. Hold a global hotkey anywhere in macOS, speak, then release — your speech is transcribed on-device and inserted into whatever app is frontmost (Notes, Mail, Slack, a code editor, and so on). It's 100% on-device: no cloud, no account.

## How to use it

1. In **설정 → 받아쓰기** (Settings → Dictation), turn on **어디서나 받아쓰기 사용** (Use dictation anywhere).
2. The first time you enable it, macOS asks for **손쉬운 사용** (Accessibility) permission — see below.
3. Put your cursor wherever you want the text — in any app.
4. Hold **Right-Option (오른쪽 ⌥)** and speak (it records only while held).
5. Release the key, and the transcribed text is inserted.

### Default hotkey: Right-Option

The default hotkey is the **Right-Option** key. It's push-to-talk — recording happens only while you hold it, and releasing completes the insert. Right-Option is the default because you almost never press it alone and it never collides with ⌘K (the command palette).

### Your clipboard is preserved

When inserting text, Madi first saves your current clipboard, pastes the transcribed text, then immediately restores your original clipboard. So anything you'd copied is left intact.

## Required permission — Accessibility

To paste text into other apps, dictation needs macOS **손쉬운 사용** (Accessibility) permission.

1. Turn on dictation in **설정 → 받아쓰기** (Settings → Dictation).
2. Check the status under **손쉬운 사용 권한** (Accessibility permission):
   - **허용됨** (Granted): you're ready to go.
   - **권한 필요** (Permission needed): click **시스템 설정에서 허용** (Allow in System Settings).
3. That button opens System Settings → *Privacy & Security → Accessibility*. Allow Madi there.
4. When you return to this window, the status updates to **허용됨** (Granted) automatically.

Without this permission dictation won't work — but it won't fail silently. Madi tells you with "손쉬운 사용 권한이 필요합니다" (Accessibility permission is required).

## Disabled while a meeting is recording

While a meeting is being recorded, the dictation hotkey is turned off. Dictation and meeting recording share the same physical microphone, so this guards against a conflict. If you press Right-Option during recording you'll see a brief notice — "회의 녹음 중에는 받아쓰기를 사용할 수 없습니다" (Dictation isn't available while a meeting is recording) — and it works again once you stop recording.

## Fast, lightweight dictation

Dictation inserts your words as-is, with no rewriting. It does not keep a large LLM in memory: it runs a short, dictation-only speech recognizer and shuts it down when done. So it stays light and fast even on Macs with little memory, and even when the meeting summary/translation model isn't loaded.

> The dictation language follows the language setting you chose for meeting recording (Korean by default). Auto-detect can misfire on short clips, so unless you picked auto, dictation is locked to your chosen language.

## Settings reference (설정 → 받아쓰기)

- **어디서나 받아쓰기 사용** (Use dictation anywhere) — turn dictation on/off.
- **단축키** (Hotkey) — shows the default (Right-Option, hold to record).
- **손쉬운 사용 권한** (Accessibility permission) — current status plus the **시스템 설정에서 허용** (Allow in System Settings) button.
- **상태** (Status) — the current dictation state (idle / listening / transcribing / inserting).
