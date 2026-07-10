# Sovereign — editor & reader features

Post-processing features for editors (YouTube / long-meeting) and general users,
built **entirely on the existing per-word transcript** (`Word{t0,t1,text,conf}`,
`Line{speaker,start,end,words}`) — no engine change, no new model.

**Guiding principle — editor features never intrude on the general user.** The
clean reading view is the default; every editor signal (timecodes, confidence,
cut-lists, chapters, retakes, highlights) lives in the **상세 view**, the **export
menu**, or the **JSON export** — never in the default 내용 (content) view.

All cut/analysis logic lives in `apps/macos/Sovereign/Transcript/EditorCuts.swift`;
rendering/exports in `apps/macos/Sovereign/Transcript/Exporters.swift`. Unit tests:
`apps/macos/Tests/EditorCutsTests.swift` (15 cases) and `apps/macos/Tests/CaptionTests.swift`
(9 cases). Each feature below names its PR.

---

## 편집 도구 panel — toggle & tune everything  (PR #73)

A `DisclosureGroup` in the side panel (shown when a transcript exists) exposes
every editor feature as a toggle + threshold sliders, bound to the **persisted**
`SessionController.editorSettings` (`EditorSettings`, saved to UserDefaults). The
tighten stat and all exports (`.json` / tighten `.csv` / chapter `.txt`) react
live to these.

| Control | Field | Range / default |
|---|---|---|
| 필러 컷 | `fillers` | on |
| 무음 컷 | `silences` | on |
| 무음 최소초 | `silenceMinGap` | 0.2–3.0 / 0.6 |
| 자동 챕터 | `chapters` | on |
| 챕터 휴지초 | `chapterGap` | 1–10 / 2.5 |
| 챕터 최소간격 | `chapterMinLen` | 10–120 / 20 |
| 리테이크 | `retakes` | on |
| 유사도 | `retakeSim` | 0.5–0.95 / 0.7 |
| 하이라이트 | `highlights` | on |
| 최소 신뢰도 | `hlMinConf` | 0.5–0.99 / 0.8 |
| 최소 휴지초 | `hlMinPause` | 0.3–3.0 / 1.0 |

Disabling a feature omits it from the JSON export (and from the tighten cut-list
for fillers/silences). Dense by design — a UI/UX designer will restyle later. The
panel lives in the control panel, never in the clean 내용 transcript.

---

## View modes — 내용 / 상세  (PR #64)

A toggle above the transcript; choice persists via `@AppStorage("transcriptViewMode")`.

| Mode | What it shows | For |
|---|---|---|
| **내용** (Content, **default**) | Consecutive same-speaker lines collapsed into reading paragraphs. Speaker name shown only when >1 speaker. **No** timecode / **no** confidence highlight / **no** overlap markers. Selectable + copyable; speaker name click still renames. | General users — "just the content" |
| **상세** (Detailed) | Per-turn rows with timecode, amber low-confidence words (underlined), and overlap markers. | Review / editing |

The confidence differentiator + word timestamps remain available in 상세 and in
the Markdown / SRT / VTT exports.

---

## N2 — low-confidence review queue  (PR #65)

**What:** a navigator (상세 mode only) to step through every low-confidence word
so a reviewer doesn't scan a long transcript for the amber ones.

- **Signal:** `word.conf < Theme.confThreshold` (0.5).
- **UI:** a bar — `검토 필요 N개` + current flagged word + ▲ / ▼. Each jump scrolls
  that word's line into view (centered) and briefly tints it.
- **No intrusion:** only appears in 상세; the 내용 view is untouched.

---

## E1 — filler-word detection  (PR #66)

**What:** disfluency words flagged as removable cut ranges.

- **API:** `EditorCuts.fillers(_ lines) -> [CutRange]` (`kind = "filler"`).
- **Lexicon (conservative, precision over recall):**
  - EN: `um umm ummm uhm uh uhh uhhh er err erm hmm hm hmmm mm mmm mhm uh-huh huh`
  - KO: `음 으음 음음 어 어어 엄 에 흠`
  - **Excluded** (content-ambiguous → a wrong cut): `like, you know, 그, 저, 뭐, 이제, ah`.
- **Normalization:** lowercase + strip surrounding punctuation (`"Um," → um`).
- **Output:** JSON export `fillers: [{start,end,text}]` + `filler_seconds`.

---

## E2 — silence / dead-air detection  (PR #67)

**What:** inter-word gaps long enough to trim, as removable cut ranges.

- **API:** `EditorCuts.silences(_ lines, minGap = 0.6, pad = 0.1) -> [CutRange]`
  (`kind = "silence"`).
- **How:** words time-sorted across all lines; a gap `> minGap` becomes a cut of
  `[prev.t1 + pad, next.t0 - pad]`. `pad` leaves speech unclipped; overlapping
  words (negative gap) and over-padded (≤0-length) ranges are skipped.
- **Output:** JSON export `silences: [{start,end}]` + `silence_seconds`.

---

## N3 — one-click "tighten" cut-list  (PR #68) — headline

**What:** fillers + silences merged into a single ripple-delete list — "2 hr raw
→ tightened timeline" in one export.

- **API:** `EditorCuts.tighten(_ lines, minGap = 0.6, pad = 0.1) -> [CutRange]`
  = `merge(fillers + silences)`, sorted + non-overlapping; fused ranges of mixed
  kinds are labelled `"mixed"`.
- **Export:** menu **타이튼 컷 목록 (.csv)** →
  ```
  # tighten cut-list — N cuts, X.Xs removable
  start_sec,end_sec,duration_sec,kind,label
  2.210,3.193,0.983,silence,
  ```
  Seconds-based so it feeds ffmpeg / Resolve / Premiere scripts and opens in any
  spreadsheet.
- **UI stat:** side panel — `타이튼: N컷 · M초 절감 가능` (only when cuts exist).
- **JSON:** `tighten: {cuts, total_seconds}`.

---

## N4 — auto-chapters  (PR #69)

**What:** chapter markers for long content (YouTube chapters).

- **API:** `EditorCuts.chapters(_ lines, gap = 2.5, minLen = 20) -> [Chapter{start,title}]`.
- **How:** a new chapter at a pause `> gap`, but only once `minLen` has elapsed
  since the previous chapter (so continuous speech stays one chapter). **First
  chapter pinned to 0:00** (YouTube requirement). Title = the boundary line's
  opening ~7 words (≤40 chars).
- **Export:** menu **유튜브 챕터 (.txt)** → `m:ss Title` (`h:mm:ss` past an hour).
- **JSON:** `chapters: [{start,title}]`.
- **Note:** conservative — content with no ≥`gap` pauses yields a single chapter.

---

## N1 — retake detection  (PR #70)

**What:** adjacent near-duplicate takes (a creator redoing a line); suggests
keeping the best take.

- **API:** `EditorCuts.retakes(_ lines, simThreshold = 0.7, minTokens = 3) -> [RetakeGroup]`.
- **How:** a run of consecutive lines whose word-set **Jaccard ≥ simThreshold** is
  a retake group; keep the **highest avg-confidence** take, drop the rest (as
  removable `kind = "retake"` ranges). Both lines must have `≥ minTokens` words
  (short back-channels like "네"/"yeah" don't match).
- **Output:** JSON `retakes: [{keep_start, keep_text, drops:[{start,end}]}]`.
- **Note:** a **suggestion** the creator confirms — never auto-applied, and not
  folded into the tighten cut-list (more aggressive than fillers/silence).

---

## N5 — highlight candidates  (PR #71) — speculative

**What:** heuristic "moments worth clipping" for shorts.

- **API:** `EditorCuts.highlights(_ lines, minWords = 5, minPause = 1.0, minConf = 0.8) -> [Highlight{start,end,text,score}]`.
- **How:** the original idea keyed on loudness, but **per-word RMS isn't in the
  app model**, so this uses emphasis proxies — a line **preceded by a pause**
  (`≥ minPause`), delivered **clearly** (avg conf `≥ minConf`), and **substantial**
  (`≥ minWords`). All three gate; `score = pauseBefore × avgConf`, sorted desc.
- **Output:** JSON `highlights: [{start,end,text,score}]`.
- **Note:** heuristic **candidates** for review, not guaranteed highlights.

---

## E3 — caption-spec SRT / VTT  (PR #63)

**What:** subtitle-grade cues (replaces the old one-block-per-turn SRT).

- **API:** `Exporters.captionCues(_ lines, spec) -> [CaptionCue]`, rendered by
  `Exporters.srt(...)` / `Exporters.vtt(...)`.
- **Spec (`Exporters.CaptionSpec`, Netflix/BBC/YouTube norms):**
  - `maxCharsPerLine = 42`, `maxLines = 2`
  - `maxCPS = 17` (reading speed; short cues extended to `minDur`)
  - `minDur = 1.0`, `maxDur = 7.0`
  - `gapBreak = 1.0` — a longer silence starts a fresh cue
  - new cue also at a speaker change; never breaks mid-word; never overlaps next
  - `speakerLabels` auto (label on speaker change only when >1 speaker)
- **Export:** menu **Subtitles (.srt)** and **Subtitles (.vtt)**. SRT uses `,` ms;
  VTT uses `.` ms + `WEBVTT` header.

---

## Export menu summary

| Item | Format | Audience |
|---|---|---|
| Markdown (.md) | low-conf words italic | general |
| Plain text (.txt) | `[mm:ss] Speaker: text` | general |
| Subtitles (.srt / .vtt) | caption-spec cues (E3) | editor / captioner |
| JSON (.json) | segments + speakers + **fillers / silences / tighten / chapters / retakes / highlights** | programmatic |
| 타이튼 컷 목록 (.csv) | merged removable ranges (N3) | editor |
| 유튜브 챕터 (.txt) | `m:ss Title` (N4) | editor |

The JSON export is the single machine surface carrying every analysis signal;
the `.csv` / chapter `.txt` are editor-direct conveniences. None of these affect
the clean 내용 reading view.
