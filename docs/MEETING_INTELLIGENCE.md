# On-device meeting intelligence (summary + action items)

The product moat: whisper.cpp is ASR-only; cloud meeting tools (Otter, Fireflies,
Granola) summarize but **upload your meeting to a server**. Sovereign runs the
summary on the **same bundled DNA3.0-4B local LLM** used for translation — the
transcript never leaves the Mac. Speed is at parity with whisper.cpp; this layer
is where we're *differentiated*, not faster.

## What it does (v1)
Post-session, one click ("요약" in the transcript bar) produces a structured,
speaker-aware block from the diarized transcript:

```
[요약]   2–4 sentence gist
[액션]   - 담당자: 할 일      (per assignee; omitted if none)
[결정]   - 결정사항          (omitted if none)
```

Reply is in the transcript's own language (Korean meeting → Korean; English → English).

## How it works
- `SummaryEngine.swift` — forked from `TranslateEngine` (same spawn / stdin-line /
  stdout-parse contract). Differences: ONE request, the transcript joined to a
  single chat turn ("화자: 발언 / …"), and the reply preserved **multi-line** so the
  `[요약]/[액션]` structure survives (translation collapses to one line).
- `SessionController.summarize()` — builds the speaker-attributed lines, **stops the
  translate engine first** so only one 2.6 GB model is resident at a time (summary
  is post-session; live translation has already finished), spawns SummaryEngine,
  streams the result into `meetingSummary`.
- UI: `summarySheet` shows a spinner while the local LLM generates, then the result
  with 복사 / 다시 생성 / 내보내기(.md). Gated on `AssetManifest.translateAvailable`
  (the DNA3 model must be downloaded — same model as translation).

## Verification (GUI-free, per the project rule)
- Capability: engine CLI fed a 4-speaker transcript → correct structured KO summary
  + per-assignee action items.
- Wiring: quark v9 (`configs/sovereign_whisper_app.mjs`) — 28/28 files wired;
  call-graph: `ContentView.viewModeBar → SessionController.summarize →
  SummaryEngine.summarize`, all reachable from `@main`.

## Shipped since v1
- **Summary folded into the auto-saved `.md`** — when generated, the saved file is
  rewritten to open with a `## 회의 요약` section; manual `.md` export includes it too.
- **Transcript Q&A** ("회의록에 물어보기") — `SummaryEngine.ask` answers grounded
  ONLY in the transcript (says "회의록에 해당 내용이 없습니다" rather than hallucinating;
  CLI-verified). The engine is now resident across summary + follow-up questions
  (no 2.6 GB reload per question), tag-routed (summary/qa).

## Roadmap (the moat, deepened)
- Speaker re-identification across sessions (engine `voiceprintsDir` hook) →
  speaker-aware summaries that persist who-said-what across meetings.
- 9B model A/B for summary/translation quality.
- Map-reduce summarization for very long meetings (beyond one context window).
