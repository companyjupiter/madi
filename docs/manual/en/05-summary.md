# AI summary and Q&A

When a transcript is done, the on-device LLM distills the meeting into a structured summary, and you can ask questions about it in natural language. Summary and Q&A use the same hardware-selected model as translation (DNA3.0-2B on 8 GB, 4B on 16 GB or more), and **neither the transcript nor the summary ever leaves this Mac.**

> Madi's interface can be switched between 한국어 / English / 日本語 under **설정 (⌘,) → 표시 → 언어 / Language**. This manual writes the Korean label first, with the English UI label in parentheses.

## First: the translation/summary model

Summary and Q&A use the same on-device model as translation. Without it, the **summary button doesn't appear**. See **Live translation** or **Settings** for how to download it.

## Generating a meeting summary

1. After transcription finishes (not while recording), press the **✦ (sparkles) button** in the top toolbar. Or pick **요약 생성** (Generate summary) from the **⌘K** command palette.
2. The **회의 요약** (Meeting summary) sheet opens and the local LLM generates the summary, with a note that "the transcript never leaves this Mac."
3. The **전체 / 화자별** (Overall / By speaker) toggle at the top switches the view.
   - **전체** (Overall) — the whole meeting written up in one pass (which sections you get follows the template below).
   - **화자별** (By speaker) — what each speaker talked about (generated on first selection).
4. The **회의 / 강의 / 인터뷰** (Meeting / Lecture / Interview) toggle to its right picks the **summary template**. The line just under it shows the sections that template produces — pick **회의** (Meeting) and it reads "Summary · actions · decisions". The default is set for you from the meeting mode you chose on the first screen, so most of the time you can leave it alone. See **Summary templates** below.

**Note**
- The ✦ button is only enabled when there's a transcript and you're not recording. It dims when the transcript is empty.

### Buttons in the summary sheet

- **복사** (Copy) — copy the summary text to the clipboard.
- **다시 생성** (Regenerate) — generate a fresh summary from the same transcript.
- **슬라이드(HTML)** (Slides, HTML) — export an offline HTML slide deck and reveal it in Finder. You get one slide per section, and **액션 아이템** (Action items) and **후속 조치** (Follow-ups) come out as checkboxes.
- **리캡 카드** (Recap card) — open a shareable one-pager (see below).
- **내보내기…** (Export…) — save the summary as a `.md` file.

## Summary templates

The same transcript needs different things kept depending on whether it was a meeting, a lecture or an interview. The **회의 / 강의 / 인터뷰** (Meeting / Lecture / Interview) toggle at the top of the summary sheet decides what gets pulled out.

| Template | What it pulls out | Good for |
|---|---|---|
| **회의** (Meeting) | 요약 (Summary) · 액션 아이템 (Action items) · 결정 사항 (Decisions) | Regular meetings, 1:1s, standups |
| **강의** (Lecture) | 요약 (Summary) · 핵심 요점 (Key points) · 용어·개념 (Terms and concepts) | Lectures, talks, seminars |
| **인터뷰** (Interview) | 요약 (Summary) · 문답 (Q&A) · 후속 조치 (Follow-ups) | Interviews, consultations, clinic visits |

All three open with a **2–4 sentence summary**, and the sections below it are written one item per line. The **문답** (Q&A) section of the interview template comes out as a question line (`Q:`) with the answer line (`A:`) directly beneath it.

**Note**
- The **회의** (Meeting) template produces exactly what it always has. Summaries you saved or exported earlier still open unchanged.
- All three templates were verified on both models — DNA3.0-2B on 8 GB, 4B on 16 GB or more.

### The default comes from the meeting mode

The template is chosen for you to match the **회의 모드** (Meeting mode) you picked on the first screen. Normally there's nothing to select.

| Meeting mode | Template used automatically |
|---|---|
| **일반** (General) · **1:1** · **스탠드업** (Standup) | 회의 (Meeting) |
| **강의** (Lecture) | 강의 (Lecture) |
| **인터뷰** (Interview) | 인터뷰 (Interview) |

For how to pick the meeting mode, see **Recording and transcription → 회의 모드** (Meeting mode).

### Changing it in the sheet regenerates on the spot

- Switching the template **discards the summaries made so far — both 전체 (Overall) and 화자별 (By speaker)**. The side you're looking at is regenerated right away; the other one is made when you switch to that tab. (The 화자별 breakdown's own format doesn't depend on the template.)
- While a summary is being generated the toggle is dimmed and can't be used. It becomes available again once generation finishes.
- A template you switch to in the sheet is a **temporary change for this session only**. It isn't saved anywhere, and changing the meeting mode puts it back to what the mode calls for. To keep using that template from now on, change the meeting mode on the first screen instead.

### Follow-ups carry over as actions

**후속 조치** (Follow-ups) from the interview template are treated as actions. They join the action list on the recap card.

The lecture template has neither decisions nor actions, so both of those lists on the recap card come out empty. In their place you get **핵심 요점** (Key points) and **용어·개념** (Terms and concepts). That's intended — a lecture is there to leave you the key points and the terms.

### Long meetings and lectures

A transcript too long to read in one pass is split, folded down and then merged into a single summary. **What is kept while folding** depends on the template — the lecture template preserves key points and terms first, the interview template preserves question–answer pairs and follow-ups.

## Recap card

A one-page shareable summary of the meeting. Open it with **리캡 카드** in the summary sheet. It carries:

- Title + date
- TL;DR
- Template-specific sections — **핵심 요점** (Key points) and **용어·개념** (Terms and concepts) from a lecture, **문답** (Q&A) from an interview, carried straight through just under the TL;DR (a meeting summary has none of these)
- List of decisions
- Actions by owner — **후속 조치** (Follow-ups) from an interview go here too
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
