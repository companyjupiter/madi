# System dictation

Dictation is Madi's voice input for anywhere in macOS. Hold a global hotkey, speak, release — and what you said is turned into text on-device and inserted into whatever app is frontmost (Notes, Mail, Slack, your code editor). 100% on-device — no cloud, no account.

> The app interface is in Korean. Korean UI labels are shown below with an English gloss in parentheses.

## How to use it

1. Turn on **어디서나 받아쓰기 사용** (Enable dictation anywhere) in **설정 (⌘,) → 받아쓰기** (Settings → Dictation).
2. The first time, it asks for **Accessibility** permission (see below).
3. Put your cursor wherever you want the text — any app.
4. Hold the **right ⌥ (Option)** key and speak (it only records while held).
5. Release the key and the dictated text is inserted.

### The hotkey: right ⌥ Option

The hotkey is the **right Option** key. It's push-to-talk — recording only while held, so releasing completes the insert. Right Option is rarely used on its own and doesn't collide with ⌘K (the command palette), which is why it's the default.

> The hotkey can't be changed in this version.

### Your clipboard is preserved

Madi saves your current clipboard, pastes the dictated text, then immediately restores what was there. Anything you had copied is still there afterwards. (If another app changed the clipboard mid-paste, Madi leaves that content alone rather than clobbering it.)

## Required permission — Accessibility

To paste text into other apps, dictation needs the macOS **Accessibility** permission.

1. Turn on dictation in **설정 (⌘,) → 받아쓰기**.
2. Check the **손쉬운 사용 권한** (Accessibility permission) row.
   - **허용됨** (Granted): ready to use.
   - **권한 필요** (Permission needed): press **시스템 설정에서 허용** (Allow in System Settings).
3. That button opens *System Settings → Privacy & Security → Accessibility*. Enable Madi there.
4. Come back to this window and the status flips to **허용됨** automatically.

Without the permission dictation won't work — but it won't fail silently either: it tells you "손쉬운 사용 권한이 필요합니다" (Accessibility permission required).

## Disabled while recording a meeting

The dictation hotkey is disabled while a meeting is recording, because dictation and meeting recording use the same physical microphone. Pressing right Option then shows a brief "회의 녹음 중에는 받아쓰기를 사용할 수 없습니다" (Dictation is unavailable while recording a meeting). Stop the recording and it works again.

## Fast and light

Dictation inserts what you said verbatim, with no rewriting. It never loads a large language model — it runs a short, dictation-only speech pass and shuts down when you're done. So it stays light and fast even on a Mac with little memory, and even if you never downloaded the translation model.

> Dictation language follows the meeting language you picked in **설정 → 녹음 → 언어** (Settings → Recording → Language); the default is Korean. Auto-detect can miss on very short utterances, so unless you chose Auto, Madi pins recognition to the language you selected.

## Settings reference (설정 → 받아쓰기)

- **어디서나 받아쓰기 사용** (Enable dictation anywhere) — turn dictation on/off.
- **누르고 있는 동안 녹음** (Hold to record) — shows the hotkey (right ⌥ Option). Read-only.
- **손쉬운 사용 권한** (Accessibility permission) — current status (허용됨 / 권한 필요) and the **시스템 설정에서 허용** button.
- **현재** (Current) — current dictation state: 꺼짐 (Off) / 대기 중 (Idle) / 듣는 중… (Listening) / 변환 중… (Transcribing) / 입력 중… (Inserting).
