# Live translation — design (sovereign DNA3.0-4B)

Translate the live/file transcript into a chosen language **on-device**, using the
project's OWN sovereign Metal LLM engine (no llama.cpp/MLX, no cloud). Core target
languages: **KO · ZH · JA · EN** (DNA3.0-4B = Qwen3.5-base + Korean post-training,
so CJK+EN is its strength zone).

## Assets (verified, on disk)
- Engine: `~/antigravity/sovereignLLM/out/metal-dna3-4b-q4km/sovereign-metal-dna3-4b-q4km` (1.1 MB Metal binary)
- Model: `~/antigravity/sovereignLLM/DNA3.0-4B.i1-Q4_K_M.gguf` (2.6 GB)
- Arch: DNA3.0-4B (qwen35) dim=2560, 32 layers, vocab=248320. Measured: prefill ~87 tok/s, gen ~45 tok/s.

## Engine I/O contract (verified from apps/metal-dna3-4b-q4km/main.zig)
- Launch: `sovereign-metal-dna3-4b-q4km <model.gguf>` → loads, prints `READY`.
- **Drive by stdin, one line = one chat turn. STATELESS** — each line is rebuilt as a
  fresh single-turn prompt; **no KV history accumulates across lines** (confirmed:
  it does not remember a prior turn). → no reset needed;每 segment is independent.
- Template (baked in, **thinking disabled**):
  `<|im_start|>system\nYou are a helpful assistant.<|im_end|>\n<|im_start|>user\n{line}<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n`
- System prompt is **fixed** ("helpful assistant") — so the translate instruction
  goes in the **user turn** (verified: "다음을 영어로 번역만 해줘…: 안녕하세요, 회의를 시작하겠습니다"
  → "Hello, let's begin the meeting." clean, no preamble).
- stdout per turn: `[chat] N tokens, prefilling...` → the reply TEXT → `[perf] generation: …` → `> `.
  Parser strips `[chat]`/`[perf]`/`> ` lines; the remainder is the translation.
- `SOV_RAW=1` bypasses the template (not used here).

## Architecture — mirror the streaming-preview pattern (low risk, engine untouched)
A new `TranslateEngine.swift` (sibling of `PreviewEngine.swift`) that spawns the
DNA3 process once and feeds it prompts. The Whisper engine is NOT modified.

```
committed segment text ──▶ TranslateEngine.feed(text, target)
        │                        │ writes: "Translate … into {target}. Output only the translation:\n{text}\n"
        │                        ▼
        │                   DNA3 engine (stdin→stdout, stateless)
        ▼                        │ reply text (strip [chat]/[perf]/>)
   TranscriptStore.lines    ◀────┘  → Line.translation = reply
        ▼
   TranscriptView renders original + translation (per line)
```

**What gets translated:** the **committed** segment (the finalized word section /
`Line`), NOT the gray streaming-preview interim — committed text is stable and
correct, and segments arrive every ~5–10 s, far slower than a ~1 s translation, so
latency is a non-issue (translate quality > speed here).

**Prompt (user turn):**
`Translate the following into {KO한국어|ZH中文|JA日本語|EN English}. Output only the translation, no notes:\n{segment text}`

**Output parse:** read stdout until the `[perf] generation` line (turn complete),
collect non-control lines → the translation. One in-flight turn at a time (queue
segments; they arrive slower than translation completes).

## UI
- **번역 target picker** in Settings → 녹음 (or a top-bar control): 끄기 / 한국어 / 中文 / 日本語 / English. Persisted.
- **Display**: each transcript line shows the translation beneath the original in a
  muted style (adaptive `textSecondary`), toggleable. In 내용 mode → original + translation
  paragraph pairs; in 상세 → under each row. A "번역" column/toggle on the transcript bar.
- Off by default (opt-in) — no model load until enabled.

## Lifecycle / resources
- **Lazy**: spawn the DNA3 engine only when translation is turned ON (and a model is
  present); tear down when off / session ends — same pattern as PreviewEngine.
- **RAM budget**: DNA3-4B Q4 resident ≈ ~3 GB. With Whisper (~0.8–1.6 GB) + optional
  streaming-preview 2nd Whisper (~0.8 GB) → up to ~5 GB. Fine on 16 GB; on 8 GB,
  recommend translate XOR preview. Surface the cost in the toggle's help.

## Packaging decision — LOCKED: optional download (NOT bundled)
The DNA3 model is **2.6 GB**. Options:
1. **Bundle in the DMG** → DMG ~3.4 GB. Simplest, fully offline, but heavy to send.
2. **Optional download on first enable** (like the original Whisper-model design):
   base DMG stays ~800 MB; translate model fetched + SHA-256-verified into App
   Support when the user first turns translation on. **Recommended** — keeps the
   base product light; translation is opt-in.
3. Separate "translate" build/DMG.
The engine binary itself (1.1 MB) bundles trivially in `Contents/MacOS/`.

## Risks / to-verify
- **Quality**: DNA3 (Korean-tuned Qwen3.5) is expected strong on KO/ZH/JA/EN, but
  measure on real meeting samples (KO↔ZH/JA A/B) before claiming — career-rigor.
- **Instruction-only output**: the fixed "helpful assistant" system prompt means we
  rely on the user-turn instruction to suppress preamble. Verified working, but add
  a light post-filter (strip leading "Sure,"/"번역:" if they ever appear).
- **Long segments**: a 10 s segment ≈ 30–60 words → well within context; fine.
- **Sovereign consistency**: own Metal engine → 100% local, matches the product
  philosophy (no cloud translate API).

## Build phases
- **P1**: TranslateEngine.swift (spawn + prompt + parse), Line.translation field,
  target picker, render under each line. Engine+model from a configured path
  (dev: the sovereignLLM paths; ship: bundled binary + downloaded model).
- **P2**: lazy lifecycle + RAM-aware (translate XOR preview on low RAM), persistence.
- **P3**: model download+verify flow (packaging option 2), export includes translation.
- **P4**: KO↔ZH/JA quality A/B; optional 9B upgrade path (DNA3.0-9B.gguf also on disk).
