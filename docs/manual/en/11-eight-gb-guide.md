# 8 GB Mac guide

> Madi opens this document once when it detects an 8 GB-class Mac. Reopen it any time from **Help → 8 GB Mac Guide**.

## The low-memory profile Madi applies automatically

No manual tuning is required.

- **DNA3.0-2B translation model** — Madi selects 2B instead of 4B. The download is about **1.31 GB** and the measured engine process footprint is about **2.4 GB** (53% below the measured 5.1 GB 4B process).
- **Committed captions first** — finalized transcript lines translate before disposable in-progress previews.
- **Queue coalescing** — when recognition revises a line, the stale translation request is replaced by the newest text.
- **Four-turn live horizon** — the screen follows current speech; shed committed lines are translated again after recording stops.
- **Low-memory Whisper path** — Madi does not retain the large encoder cache, reducing memory pressure and swap.

This profile does not hide the model tradeoff. The smaller 2B model can choose less accurate wording on difficult sentences. Madi detects source echoes, visibly wrong scripts, leaked `<think>` framing, and runaway repetition, retries once, and suppresses a still-invalid translation rather than displaying it as correct.

## Recommended live-interpreting setup

1. Select **one output language** whenever possible.
2. For face-to-face interpreting, enable **Korean plus one counterpart language**. Each line then has only one effective target.
3. Start with **Normal (7 s)**. Use **Accurate (10 s)** when clean source boundaries matter more than immediacy.
4. During long sessions, close memory-heavy browser tabs, large IDEs, and other local LLMs.
5. “Translating · N lines queued” does not mean the engine is stuck. Final captions are running first and stale preview work is being discarded.

## What to expect

- **Transcription and speaker separation alone** never download or launch the translation model.
- The first use of **translation, summary, or AI correction** downloads the 8 GB 2B model once.
- An older finalized line can appear late during live translation, but Madi retries deferred durable lines after recording stops.
- Under severe memory pressure, macOS swap can slow transcription and translation together. Reduce output languages and other apps' memory use first.

## If something looks wrong

- In **Settings (⌘,) → Translation**, confirm that `DNA3.0-2B · ~1.3 GB` is shown.
- If it is not installed, use **Download translation model** on that screen.
- Transcription and speaker separation should continue to work without translation.
- Use the Help manual and update screen to confirm the installed Madi version.
