# Meeting Intelligence

Madi's meeting intelligence turns a raw transcript into an organized meeting asset. Summaries, action items, Q&A, live coaching, and follow-up tracking are all produced by the local LLM (DNA3.0-4B) running on this Mac. **Your transcript and summaries never leave the device.**

> Different features have different requirements. Some need the summary model (LLM) installed; some need 16 GB or more of memory. Each section notes which.

> The app interface is in Korean. Korean UI labels are shown below with an English gloss in parentheses.

## A.I 요약 (AI Summary)

Turns the transcript into a structured summary plus action items and decisions.

1. Press **요약** (Summarize) at the top of the transcript (the sparkles button).
2. The local LLM opens the **회의 요약** (Meeting summary) sheet and generates the summary. A note reads "전사 내용은 이 Mac을 떠나지 않습니다" (Your transcript never leaves this Mac).
3. Use the **전체 / 화자별** (Whole / By speaker) toggle at the top of the sheet to switch views.
   - **전체** (Whole) — Summary, actions, and decisions for the entire meeting
   - **화자별** (By speaker) — What each speaker said, broken down per person (generated on the spot the first time you pick it)

Buttons at the bottom of the summary sheet:

- **복사** (Copy) — Copies the summary text to the clipboard
- **다시 생성** (Regenerate) — Generates a fresh summary from the same transcript
- **슬라이드(HTML)** (Slides — HTML) — Exports an offline HTML slide deck and reveals it in Finder
- **리캡 카드** (Recap card) — Opens a shareable summary card (see "Recap card" below)
- **내보내기…** (Export…) — Saves the summary as a `.md` file

**Requirements**
- The summary model (LLM) must be installed. If it isn't, the **요약** (Summarize) button does not appear.

## A.I 요약 as a separate file

Saves the summary as a **separate file** alongside the transcript when a session finishes.

1. In the right side panel, turn on the **A.I 요약** (AI Summary) checkbox.
2. When the meeting finishes, a `…요약.md` file is saved next to the transcript (e.g. `회의록.md` → `회의록 요약.md`).

**Requirements**
- The summary model (LLM) is required.
- Transcript auto-save must be on.

## 회의록에 물어보기 (Ask your meeting — Q&A)

Ask about the meeting in plain language, and the local LLM answers from the transcript. It lives at the bottom of the summary sheet.

1. Type a question in the **회의록에 물어보기** (Ask your meeting) field. For example: "무엇을 결정했나요?" (What did we decide?), "김부장이 맡은 일은?" (What is Manager Kim responsible for?)
2. Press the paper-plane button or hit Enter.
3. Use the **이 회의 / 전체 워크스페이스** (This meeting / Entire workspace) toggle to set the scope.
   - **이 회의** (This meeting) — Answers from the currently open transcript only
   - **전체 워크스페이스** (Entire workspace) — Searches across **all** your saved meetings. For example: "지난달 보안 결정은?" (What were last month's security decisions?), "지난 분기 가격 결정 찾아줘" (Find last quarter's pricing decision)

**Requirements**
- The summary model (LLM) is required.

## 라이브 액션 추출 (Live action extraction)

Pulls out decisions, to-dos, and questions **in real time** while you record, so the meeting is already organized the moment it ends. Extracted items stack up in the side **라이브 인텔리전스** (Live intelligence) area as [결정] (Decision) / [액션] (Action) / [질문] (Question) cards, each with an owner.

1. **Before** you start recording, turn on the **라이브 액션 추출** (Live action extraction) checkbox in the side panel.
2. Start recording, and the cards fill in live.

**Requirements**
- **16 GB or more of memory** is required. On machines with less, the toggle is disabled and shows "16GB 이상 메모리 필요" (16 GB or more of memory required).
- It runs the summary model (DNA3) alongside transcription, so memory use is high.

**Note**
- **Live translation**, which uses the same model, is paused while live action extraction is on.
- You cannot turn it on or off once recording has started. Always set it **before** recording.

## 라이브 코치 (Live coach / teleprompter)

A side panel that helps you run the meeting while recording. It works on any Mac and needs no model.

1. Turn on the **라이브 코치** (Live coach) checkbox in the side panel (off by default).
2. While recording, the coach panel shows the following in real time.
   - **Agenda checklist** — Surfaces prior decisions and open action items as agenda items, and ticks them off (with a strikethrough) when the live transcript covers them. A "N / M 다룸" (N / M covered) progress count appears at the top.
   - **미답변 질문** (Unanswered questions) — Questions raised in the meeting that haven't been answered yet
   - **지금 흐름** (Current pace) — The meeting's momentum, estimated from recent speaking speed, overlap, and silence, shown as **가열 / 안정 / 저조** (Heating up / Steady / Quiet), with a small bar sparkline

**Requirements**
- None — no model required, works on every Mac.

**Note**
- The agenda is richer when a calendar event is detected (prior decisions and actions are gathered). If there's no prepared agenda, the panel says so.

## 열린 항목 (Open loops — follow-up tracking)

Aggregates every unresolved action item and open question across **all** your saved meetings in one place. Find it in the **열린 항목** (Open loops) tab of the workspace explorer (next to 파일 / Files and 사람 / People).

Each row shows:

- **Kind badge** — [결정] (Decision) / [액션] (Action) / [질문] (Question)
- **Owner** (for action items)
- **Source meeting** name
- **Age** — "12일째 후속 없음" (12 days with no follow-up) if unresolved, or "12일 경과" (12 days elapsed) if resolved
- **Follow-up** — if a later meeting re-mentioned it, "5일 후 ○○회의에서 언급됨" (mentioned in meeting ○○ 5 days later)

Rows are split into two groups: **후속 필요** (Needs follow-up, oldest first) and **후속됨** (Followed up). Tapping a row opens the source transcript.

**Requirements**
- An item is tracked only if [결정]/[액션]/[질문] were recorded in the meeting summary — that is, transcripts organized by the summary model.

## 회의 준비 브리핑 (Meeting prep brief)

Before a meeting (or when a calendar event is detected), it surfaces prior context for these attendees on a single page. It combines calendar + people + past-meeting search.

The brief includes:

- **회의 참석자** (Attendees) — Each attendee's past-meeting history
- **지난 결정** (Prior decisions) — Decisions made previously involving these attendees
- **미해결 액션** (Open action items) — Action items that aren't finished yet
- **관련 논의** (Related discussions) — A list of related past meetings

Use the **복사** (Copy) / **내보내기…** (Export…) buttons at the bottom to save the brief to the clipboard or a `.md` file.

**Note**
- The base brief (attendees, prior decisions, open items) is built from saved transcripts alone and needs no summary model.
- Turning on the **워크스페이스에서 더 찾기** (Search the workspace for more) toggle has the local LLM search the entire workspace and add extra context under "관련 논의" (Related discussions). This search requires the summary model and is off by default (loading the summary model briefly evicts the translation engine).

## 제목 자동 생성 (Auto title) · 리캡 카드 (Recap card)

**Auto title** — In a live session with A.I 요약 (AI Summary) auto-save on, the local LLM names the meeting when it ends and renames the file to that title (so it matches the summary file's name). This only happens when you didn't type a file name yourself.

**Recap card** — A one-page summary card for the meeting. Open it with the **리캡 카드** (Recap card) button in the summary sheet. The shareable card includes:

- Title and date
- TL;DR (the key takeaways)
- A list of decisions
- Actions by owner
- Talk time per speaker (bars)
- A one-line quote

Use **복사** (Copy) to copy the one-page card as Markdown, or **내보내기…** (Export…) to save the same content to a file.

**Requirements**
- Both the auto title and the recap card's summary content require the summary model (LLM).

## Privacy

All of this runs on this Mac. Your transcript, your summaries, and your Q&A answers never leave the device.
