# Madi — reproducible local-first demo

A short, developer-reproducible proof of Madi's core wedge: **local** transcription,
**speaker attribution**, **word timestamps**, mixed-language handling, and exports —
no cloud, no API key, no account on the core path.

Two demo paths are documented. Path A needs nothing but a clean checkout. Path B
adds the speech model + a local audio file to exercise the full engine.

---

## Path A — fixture replay (no model, no audio, offline)

Checked-in structured-event fixtures ARE the expected artifacts. They let anyone
inspect Madi's output shape without downloading a ~830 MB model or any audio.

| fixture (`web/fixtures/`) | language | scene |
|---|---|---|
| `jfk3.events.jsonl` | EN | single speaker (JFK inaugural clip) |
| `devops_ko.events.jsonl` | KO | announcer / monologue |
| `devops_ko_biased.events.jsonl` | KO | same audio, glossary-biased decode |

Each line is one event in the frozen contract documented in
[EVENTS.md](EVENTS.md) — `meta` / `word` (with `conf`, `spk`) / `seg` / `diar` /
`spk_seg`. Speaker attribution (`spk`) and word timestamps (`t0`/`t1`) are visible
directly in the file:

```sh
# what one attributed word + one speaker segment look like
grep -m1 '"t":"word"'    web/fixtures/jfk3.events.jsonl
grep -m1 '"t":"spk_seg"' web/fixtures/jfk3.events.jsonl
```

**Replay in the dashboard** (offline, no network):

```sh
cd web/dashboard && npm ci && npm run dev
# open the printed localhost URL; vite serves the fixtures from web/dashboard/public/fixtures/
# (a copy of web/fixtures/ — the canonical set the engine writes)
```

**Live bridge** (streams a fixture as SSE, same contract the app consumes):

```sh
node web/bridge/server.mjs           # prints a tokenized 127.0.0.1:5274 URL
```

### Shape is locked by tests, not just prose

The event/export contract these fixtures embody is guarded by the Swift core suite
(`cd apps/macos && swift test`):

- `Tests/EventContractTests.swift` — parses the exact `EVENTS_FILE` event shape.
- `Tests/EngineProtocolTests.swift` — the frozen stdout transcript contract.
- `Tests/SovereignCoreTests/RoundTripExportParseTests.swift` — renders a
  multi-speaker transcript to the saved-Markdown shape and round-trips it back
  through the real parser, asserting speaker ids, names, timecodes, text, and the
  low-confidence flag survive.

If a change breaks the attributed-transcript or export shape, these fail — so the
fixtures above stay a truthful reference.

---

## Path B — full engine run (needs speech model + a local WAV)

Reproduces a fixture end-to-end from audio. Audio blobs are intentionally **not**
committed (see `engine/metal/assets/*.wav`, gitignored) to keep the repo small;
bring your own 16 kHz mono WAV or drop in `jfk3.wav`.

```sh
# 1. build the engine (Zig 0.14.x + xcrun metal)
apps/macos/scripts/build_engine.sh          # → engine/metal/out/transcribe

# 2. run it, emitting the SAME structured events as the checked-in fixture
EVENTS_FILE=/tmp/jfk3.events.jsonl CONF=1 DIAR=1 \
  engine/metal/out/transcribe \
  engine/metal/assets/model.safetensors \
  engine/metal/assets/jfk3.wav \
  engine/metal/assets/WHISPER_BPE.bin

# 3. diff the shape against the reference fixture (values vary by model build;
#    the event TYPES and fields should match)
diff <(cut -c1-12 /tmp/jfk3.events.jsonl) <(cut -c1-12 web/fixtures/jfk3.events.jsonl) || true
```

Expected artifacts from a full run:

- **Speaker-attributed transcript** — `=== SPEAKER-ATTRIBUTED TRANSCRIPT ===`
  (`[t] Speaker N: …`) on stdout, or Markdown via the app / `live_transcribe.sh --md`.
- **Word timestamps** — `=== WORD TIMESTAMPS ===` and per-word `t0`/`t1` in events.
- **Subtitle export** — `.srt` via `live_transcribe.sh --srt notes.srt`.
- **Summary / action items** — only when the optional local LLM is installed
  (Settings › 번역), otherwise these features are gated (see
  [issue #166 wedge](../README.md)); transcription itself never depends on it.

---

## What this proves vs a generic meeting assistant

- Transcript, speaker labels, and timestamps are produced **on-device** — the
  fixtures are plain local files, not a cloud transcript export.
- Mixed KO/EN is handled by the same engine (`devops_ko` vs `jfk3`).
- Optional intelligence (translate/summary/Q&A) is a **separate** on-device model,
  so the core path has zero account/API/cloud dependency.
