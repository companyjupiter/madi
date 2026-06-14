# Multi-chunk batched decode — design & staged plan

**Goal.** Spend the measured occupancy headroom (J-recon: single-token decode runs
5.8× off the bandwidth ceiling; a batched GEMM is **6–9× cheaper per token** at
M=8 — `metal/test_specgemm.zig`) **without a draft model**, by decoding a long
file's independent 30 s chunks *together*: at decode step *t*, compute token-*t*
for all B in-flight chunks in **one batched forward** instead of B sequential
single-token forwards.

**Why it's safe.** Chunks are fully independent (chunk *i*'s token-*t* never
depends on chunk *j*). So the batched result is **byte-identical** to sequential
per-chunk decode by construction — same arithmetic, just packed B rows per GEMM.
**File-mode only** (live capture has one chunk in flight); exactly the stated
constraint. Default-ON in file mode when ≥2 chunks are batched; `BATCHDEC=0`
disables (toggle).

## Current shape (what we batch over)

The encoder **already** batches chunks: it gathers up to `enc_batch` speech
chunks into slots and runs `enc.forward(..., batch_count)` → `enc_out[EB·ENC_SEQ·D]`.
**Decode, however, is per-slot sequential** (`} // slot`). Each slot owns:
`d_x[D]`, `d_tokens[MAX_TOK]`, `d_pos`, self-KV `skc/svc[l][MAX_TOK·D]`, cross-KV
`ckc/cvc[l][ENC_SEQ·D]`, `d_logits[VOCAB]`. Multi-chunk batching makes all of
these carry a **slot dimension B**.

## Stages (each lands byte-identical + committed)

**Stage 1 — batched decode-step (plain mode, fixed B, no rescue/seek).**
- Promote buffers to B-major: `d_x[B·D]`, `d_pos[B]`, `skc/svc[l][B·MAX_TOK·D]`,
  `ckc/cvc[l][B·ENC_SEQ·D]`, `d_logits[B·VOCAB]`, `d_tokens[B·MAX_TOK]`.
- A `decodeStepBatched(B)` that runs one token-step for all B slots:
  - projections (qkv / out / cross-q / cross-o / MLP up·down / logit) via
    **dequant-once + `matmulF16Batched`** over B rows — the cross-attn path
    (`deqW16` → `matmulF16Batched`) is the existing template.
  - attention per slot (each slot attends to its own KV at its own `pos`):
    a B-loop over the existing `kAttn`/`kCA`, or a batched attn kernel later.
- **Gate:** on a 2-chunk file, the batched tokens (and the final transcript)
  must be **byte-identical** to sequential decode (WHASH-style token compare),
  and `[perf]` decode tok/s must rise. Plain-mode files only; if a chunk would
  collapse/seek, fall back to the per-slot path for that chunk.

**Stage 2 — independent EOT / ragged completion.** Slots finish at different
token counts. Mask finished slots out of the batched step (skip their KV writes,
freeze their tokens) and shrink B as slots retire; verify identical output.

**Stage 3 — rescue/seek per slot.** A slot that `tokenCollapse`s or trips the
logprob rescue (P1) must re-decode in ts-mode + seek **independently**. Simplest:
retire such a slot from the batch and finish it on the existing per-slot path
(correctness over peak batching). Verify the rescue files still match.

## Verification protocol (career-rigor)

1. **Byte-identity** is the contract: batched vs sequential transcript must be
   identical on jfk (1 chunk → no batching, unchanged), a 2-chunk file, and a
   long multi-chunk file (devops_ko). Token-level compare, not just text.
2. **Speedup** measured as decode tok/s and end-to-end file wall-clock, batched
   vs `BATCHDEC=0`, same binary.
3. **No live regression:** live/stream path (B=1) is byte-identical and untouched.

## Risks / fallbacks

- The decode kernels are hand-tuned single-token GEMVs; the batched path is a
  **parallel code path** (not a rewrite of the live path) — `BATCHDEC=0` always
  keeps the proven per-slot path. Lower risk, easy A/B.
- If batched attention is the bottleneck (per-slot KV), Stage 1 can batch only
  the **projections** (the 6–9× GEMM win) and keep attention per-slot — still a
  net win since projections dominate the 86% layer cost.
