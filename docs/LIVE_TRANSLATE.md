# Live translation — sovereign DNA3.0-4B / DNA3.0-2B

Translate the live/file transcript into a chosen language **on-device**, using the
project's OWN sovereign Metal LLM engine (no llama.cpp/MLX, no cloud). Core target
languages: **KO · ZH · JA · EN**. Madi selects a model by physical memory: 2B on
8 GB Macs, quality-default 4B on 16 GB and larger systems. Both use independent
model-specific sovereign Metal binaries; no llama.cpp/MLX/cloud fallback exists.

## Assets and measured profiles (2026-07-21)

| profile | selection | GGUF bytes | process phys footprint | median prefill | median decode |
|---|---:|---:|---:|---:|---:|
| DNA3.0-4B Q4_K_M | 16 GB+ | 2,783,447,424 | 5,119 MB | 414.8 tok/s | 67.3 tok/s |
| DNA3.0-2B Q4_K_M | 8 GB | 1,312,165,344 | 2,405 MB | 998.7 tok/s | 132.8 tok/s |

The 2B process saves **2,714 MB / 53.0%**, with **2.41× prefill** and **1.97×
decode** on the same 12-turn KO→JA/ZH/EN translation run. Exact 2B model SHA-256:
`9270db053b27f1ec127e37ad7aaec0efa05dc89fbd158f3c4724e33e478da7a3`.
The app's `MADI_TRANSLATE_MODEL=2b|4b` override is validation-only; product policy
is automatic (<12 GiB → 2B, otherwise 4B).

## Engine I/O contract (verified from both model-specific runtimes)
- Launch: `sovereign-metal-dna3-{2b|4b}-q4km <matching-model.gguf>` → loads, prints `READY`.
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

## Architecture

`TranslateEngine.swift` attaches to the single shared `DNAEngineBroker` process
and feeds stateless turns. The Whisper engine is not modified.

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

Both gray interim previews and committed `Line`s can translate. They are not equal
work: committed output is durable product state; interim output is disposable UX.

### Queue policy (8 GB critical path)

- committed=100, interim=80 at the shared broker;
- a committed enqueue evicts all pending interim turns;
- interim admission is blocked while committed work is queued or in flight;
- a newer `(line id, target language)` revision replaces its older pending turn;
- within a priority lane, newest live-caption work runs first;
- the 2B profile retains at most 4 pending turns (4B: 30); capacity-shed committed
  lines are backfilled after stop, while superseded interim work is never backfilled.

An already-generating interim cannot be interrupted by the line-oriented engine;
committed work therefore waits for at most the current turn, then runs before every
pending interim. Unit tests cover eviction, revision coalescing, priority, stale
retry rejection, and the four-turn low-memory horizon.

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
- **Lazy**: spawn the selected DNA engine only when local intelligence is enabled
  and the matching GGUF is present; all DNA consumers share one resident process.
- **8 GB**: 2B's measured 2,405 MB replaces the 4B process's 5,119 MB. The short
  queue horizon and coalescing keep memory/latency bounded instead of accumulating
  translations behind speech.

## Packaging decision — optional model download

Both tiny engine binaries are bundled as an inseparable pair:
`translate-engine-{2b,4b}`. Only the hardware-selected GGUF (1.31 GB or 2.78 GB)
is downloaded on first enable, SHA-256 verified, and stored in App Support. Release
bundle verification rejects a one-engine-only package so an 8 GB Mac cannot
silently receive a 4B-only build.

## Quality gate and remaining risk

The same 12-turn clinic/meeting set measured chrF++ **51.56 (4B)** vs **51.78
(2B)**, but raw 2B had one exact source echo plus wrong-script mixing and one
`</think>` leak. Therefore chrF alone is not the ship gate. Madi now:

1. preserves the existing anchored prompt for the normal path;
2. suppresses partials that are still source echoes or observably in a forbidden
   target script;
3. strips leaked think framing and collapses exact consecutive sentence loops;
4. retries once with an explicit `source-language→target-language` prompt;
5. suppresses a still-invalid result instead of showing it as a translation.

The three observed 2B boundary failures were replayed through the repair prompt and
returned clean target-script JA/ZH at ~130 tok/s. Broader COMET/human evaluation on
real meetings remains required before claiming 4B-equivalent semantic quality.

- **Instruction-only output**: the fixed "helpful assistant" system prompt means
  the user turn still controls output format; the guard handles observed structural
  failures, not semantic mistranslation.
- **Long segments**: a 10 s segment ≈ 30–60 words → well within context; fine.
- **Sovereign consistency**: own Metal engine → 100% local, matches the product
  philosophy (no cloud translate API).

## Build phases
- **P1 (DONE)**: TranslateEngine.swift (spawn + prompt + parse), Line.translation field,
  target picker, render under each line. Engine+model from a configured path
  (dev: the sovereignLLM paths; ship: bundled binary + downloaded model).
- **P2**: lazy lifecycle + RAM-aware (translate XOR preview on low RAM), persistence.
- **P3**: model download+verify flow (packaging option 2), export includes translation.
- **P4**: KO↔ZH/JA quality A/B; optional 9B upgrade path (DNA3.0-9B.gguf also on disk).

## Multi-target (KO→JA/EN/中, EN→KO/JA/中) + echo finding

Each committed segment is translated into a SET of target languages at once (UI:
multi-select; source language auto-excluded). Perf: 3 targets ≈ ~4.5s GPU/segment
→ ~45% duty at the 10s window (recovers in pauses); use 보통/정확 (빠름 5s × 3 can
backlog). Translation shown per-language under each line (한/EN/日/中 tag).

**Echo finding (P4) — RESOLVED at the engine:** the 4B occasionally outputs the SOURCE verbatim instead of
translating — reproducible for a 3rd heterogeneous target (e.g. CH after JA,EN),
and the same KO→CH alone/repeated is correct + varies per run → a cross-turn
SAMPLING-state effect, not prompt/order-of-text. Mitigation shipped: TranslateEngine
detects output==source (normalized), retries up to 2×, then SUPPRESSES (never shows
the source masquerading as a translation). Real fix is engine-side (sovereignLLM):
greedy/temp-0 decode for translation, or reset the sampler RNG / KV per turn, or
use DNA3.0-9B. To verify in P4 quality A/B.

### Echo root cause RESOLVED (engine fix)

Diagnosed: the engine decodes GREEDY (deterministic) and resets attention KV
(pos=0) per turn, but NOT the **GDN/SSM recurrent state** (d_ssm_state/d_conv_state)
— a separate cache. So each turn was conditioned on the prior turn's recurrent
history → identical prompts gave different output, and KO→中 (after KO→JA/EN)
echoed the source. Fix (sovereignLLM `apps/metal-dna3-4b-q4km`,
`fn__resetGDNState`): zero ssm+conv state + ssm_pos=0 at each turn. Verified:
KO→中 ×3 now byte-identical; JA→EN→CH all translate; app multi-target 3/3 clean.
The app-side retry+suppress guard stays as harmless defense-in-depth.
