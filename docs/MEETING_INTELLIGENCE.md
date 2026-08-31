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

## Shipped — cross-session speaker re-identification
The engine already had a voiceprint hook (`VOICEPRINTS=<dir>` of `<name>.vec`,
loaded live; on a centroid match it emits `SPKNAME <id> <name>`; at session end it
dumps `<dir>/.last/spk<id>.vec`). Wired the app side, fully on-device:
- `makeConfig` passes a persistent `voiceprintsDir` (App Support/Sovereign/voiceprints).
- **Enroll:** `renameSpeaker(id, name)` copies this session's `.last/spk<id>.vec`
  → `<name>.vec`. Name a speaker once.
- **Recognize:** next live session loads it; the engine emits `SPKNAME` on match →
  `EngineEvent.speakerName` → auto-labels that voice (user can still override).
- So "김부장" is recognized across meetings — and feeds speaker-aware summaries.
  (live/stream only; file-mode has no centroid dump.)

## Roadmap (the moat, deepened)
- Summary templates ×3 (회의/강의·발표/인터뷰·상담) — one spine, template-aware
  condense. Design finalized 2026-08-31: `SUMMARY_TEMPLATES.md`.
- 9B model A/B for summary/translation quality.
- 9B model A/B (already listed above).

## Shipped — long-meeting map-reduce
The engine context is ~1024 tokens and **silently truncates** past it (so a long
meeting would lose its tail). `SummaryEngine` now map-reduces: the transcript is
split into ~800-char chunks, each condensed (preserving names/decisions/to-dos),
then folded again until one fits → the final [요약]/[액션]/[결정] (or 화자별) format.
Recursive (handles 2-hr meetings), with a round cap as a non-convergence guard.
Short meetings still take the single-request path. CLI-verified the condense step
preserves per-speaker actions.

## Shipped — presentation HTML deck export
The summary exports as a self-contained, PPT-style **`summary-<date>-<n>.html`**
(into the auto-save folder): a title slide + one slide per [요약]/[액션]/[결정]
section (+ a 화자별 slide if generated). Inline CSS (Warm Focus palette, dark-mode
aware, Korean font stack), scroll-snap slides, arrow-key nav, print-to-PDF — zero
external assets, opens in any browser offline. `SummaryDeck` is pure + unit-tested
(parse → slides, HTML-escaping, filename). Button: 요약 시트의 "슬라이드(HTML)".

