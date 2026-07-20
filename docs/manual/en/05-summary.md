# AI summary and Q&A

When a transcript is done, the on-device LLM distills the meeting into a structured summary, and you can ask questions about it in natural language. Summary and Q&A use the same hardware-selected model as translation (DNA3.0-2B on 8 GB, 4B on 16 GB or more), and **neither the transcript nor the summary ever leaves this Mac.**

> The app interface is in Korean. Korean UI labels are shown below with an English gloss in parentheses.

## First: the translation/summary model

Summary and Q&A use the same on-device model as translation. Without it, the **summary button doesn't appear**. See **Live translation** or **Settings** for how to download it.

## Generating a meeting summary

1. After transcription finishes (not while recording), press the **✦ (sparkles) button** in the top toolbar. Or pick **요약 생성** (Generate summary) from the **⌘K** command palette.
2. The **회의 요약** (Meeting summary) sheet opens and the local LLM generates the summary, with a note that "the transcript never leaves this Mac."
3. The **전체 / 화자별** (Overall / By speaker) toggle at the top switches the view.
   - **전체** (Overall) — summary, actions and decisions for the whole meeting.
   - **화자별** (By speaker) — what each speaker talked about (generated on first selection).

**Note**
- The ✦ button is only enabled when there's a transcript and you're not recording. It dims when the transcript is empty.

### Buttons in the summary sheet

- **복사** (Copy) — copy the summary text to the clipboard.
- **다시 생성** (Regenerate) — generate a fresh summary from the same transcript.
- **슬라이드(HTML)** (Slides, HTML) — export an offline HTML slide deck and reveal it in Finder.
- **리캡 카드** (Recap card) — open a shareable one-pager (see below).
- **내보내기…** (Export…) — save the summary as a `.md` file.

## Recap card

A one-page shareable summary of the meeting. Open it with **리캡 카드** in the summary sheet. It carries:

- Title + date
- TL;DR
- List of decisions
- Actions by owner
- Talk-time per speaker
- A one-line quote

Use **복사** (Copy) to copy it as Markdown, or **내보내기…** (Export…) to save it to a file.

## Ask the meeting (Q&A)

Ask about the meeting in natural language and the local LLM answers, grounded in the transcript. It sits at the bottom of the summary sheet.

1. Type your question into the **회의록에 물어보기** (Ask the transcript) field. E.g. "무엇을 결정했나요?" (What did we decide?), "김부장이 맡은 일은?" (What is Manager Kim responsible for?).
2. Press the paper-plane button or Enter.
3. The **이 회의 / 전체 워크스페이스** (This meeting / Whole workspace) toggle sets the scope.
   - **이 회의** (This meeting) — answer only from the currently open transcript.
   - **전체 워크스페이스** (Whole workspace) — search across **all** saved transcripts. E.g. "지난달 보안 결정은?" (What security decisions were made last month?).

**Note**
- While answering, "로컬 LLM이 답하는 중…" (the local LLM is answering…) is shown.

## Privacy

Both summary and Q&A run on this Mac. Neither the transcript nor the summary leaves the device.
