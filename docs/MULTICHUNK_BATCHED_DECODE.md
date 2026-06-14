# Multi-chunk batched decode — design & staged plan

## STATUS (J COMPLETE — integration refuted on speed, primitives kept)

**Outcome:** the full integration was built and is **correct** (quality-equivalent
transcript, end-to-end), but the **speedup is refuted**: batched is 22% *slower*
at nb=2 and only ~7% faster at nb=8 (525 vs 492 tok/s; crossover ~nb=5-6). The
recon's 6–9× projection headroom does NOT carry to the whole decode because
**attention stays per-slot (B-loop, un-batched)** and the F32↔F16 conversions +
cross-KV setup overhead cancel the projection gain. Per the "default-ON only if
it's good" rule, the integration was **reverted** (`transcribe.zig` clean). The
real lever is a **batched attention kernel** (remove the per-slot B-loop) —
significant Metal work, deferred. **Kept** (merged): `decodeBlockBatched` +
`cvt_f32_f16` (`decoder.zig`) and the primitive/loop tests — a verified
foundation for a future batched-attention effort. See PERF_LOG `J`.

---

## (historical) Original staged plan

**Done + verified (merged):** recon (PR #35, decode is occupancy-bound 5.8× off
ceiling; batched GEMM 6–9×), spec (#36), quality-equivalence correction (#37),
implementation recipe (#38), and the **make-or-break primitive proof** (#39,
`metal/test_batchproj.zig`): `deqW16` (Q8→F16, once) + `matmulF16Batched` over B
slots is **correct** (CPU-F32 reverse-verify max|Δ|=4.35e-3) and **5.7–7.4×
cheaper/row at B=8** (deq amortized). Two traps caught: `mul_mm_q8` is slow (use
`matmulF16Batched`); deq-per-call dominates (amortize once/layer).

**`decodeBlockBatched` DONE + verified** (`decoder.zig`, `cvt_f32_f16` added):
the full block over B slots — fused-`kQkv` replicated in batched form (qkv split /
qb·vb bias / per-slot KV-store), per-slot self+cross attention, batched-GEMM
projections + F16 conversions — is quality-equivalent to `decodeBlock`×B at
**max|Δ|=2.0e-3, rel=4.6e-4** (`test_decblock_batch.zig`, gate <5e-3). Cross-attn
alignment-score capture is omitted in the block (added in the word-timestamp
integration). quark atoms: `fn__decodeBlockBatched`, `metal_kernel__cvt_f32_f16`.

**Next entry point — decode-loop integration (`transcribe.zig`):** promote the
per-slot decode buffers to B-major, deq the layer weights to `WF16` once per
decode, replace the per-token per-slot `decodeBlock` loop with a `decodeBlockBatched`
loop over the in-flight slots, then per-slot LN+logit+argmax/EOT. Stages: ragged-
EOT masking (slots finish at different counts), per-slot rescue/seek retire-to-
sequential, then the WER/CER A/B gate. `BATCHDEC=0` keeps the proven per-slot path.

---


**Goal.** Spend the measured occupancy headroom (J-recon: single-token decode runs
5.8× off the bandwidth ceiling; a batched GEMM is **6–9× cheaper per token** at
M=8 — `metal/test_specgemm.zig`) **without a draft model**, by decoding a long
file's independent 30 s chunks *together*: at decode step *t*, compute token-*t*
for all B in-flight chunks in **one batched forward** instead of B sequential
single-token forwards.

**Why it's safe — quality-equivalent, NOT bit-identical.** Chunks are fully
independent (chunk *i*'s token-*t* never depends on chunk *j*), so the batched
result is *mathematically* the same computation. BUT the speedup comes from a
**batched GEMM** whose FP arithmetic (accumulation order, F16 vs the per-token
Q8 GEMV) differs bit-for-bit from the per-slot `kGemvQ8` path — even the verified
Q8-direct GEMM is only `max|Δ|≈5e-4`, not bit-exact. So a borderline argmax can
flip and a token can differ. The bar is therefore **quality-equivalence**
(WER/CER A/B shows no regression), the same standard the engine's existing
run-to-run GPU nondeterminism already meets — NOT bit-identity. (Bit-identity is
the right bar for *speculative* decoding, where a verify step makes it exact;
multi-chunk batching has no verify, so it's quality-equivalent.) **File-mode
only** (live capture has one chunk in flight). Default-ON in file mode with ≥2
chunks; `BATCHDEC=0` disables (toggle).

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

1. **Quality-equivalence** is the contract (not bit-identity — see above):
   batched vs sequential must show **no WER/CER regression** on the standard
   bench (LibriSpeech test-other + FLEURS-ko), the same bar the engine's
   run-to-run nondeterminism already meets. jfk (1 chunk) takes the per-slot path
   unchanged.
2. **Speedup** measured as decode tok/s and end-to-end file wall-clock, batched
   vs `BATCHDEC=0`, same binary.
3. **No live regression:** live/stream path (B=1) is byte-identical and untouched
   (it never enters the batched path).

## Implementation recipe (worked out — NO new Metal kernels)

The batched step reuses every existing kernel; only the projections move to a
batched GEMM. Per decode (once, amortized over ~150 tokens): **pre-dequant** each
Q8 decoder weight to F16 (`deqW16`, the cross-attn path's template). Then a
`decodeBlockBatched(B)` per token-step:

| op | per-slot today | batched |
|---|---|---|
| LN / cross-LN / mlp-LN | `kLN(rows=1)` | `kLN(rows=B)` — already takes `rows`, **free** |
| qkv / out / cross-q / cross-o / mlp-up / mlp-down | fused Q8 `kGemvQ8*` | `matmulF16Batched(x[B×D], w_f16)` → `[B×N]` (the 6–9× win), then the **standalone** epilogue kernels (`bias_add`, `gelu_f32`, `gpu_residual`, `bias_res_ln`) over the `[B×N]` slab |
| KV-store (k/v → cache) | fused in `kQkv` | `gpu_kv_store` per slot (B-loop) at each slot's `pos` |
| self-attn / cross-attn | `kAttn`/`kCA` (NH heads, 1 tok) | B-loop `kAttn`/`kCA` per slot (per-slot KV) |
| logit | `kLogitGemv` (Q8) | `matmulF16Batched(xb[B×D], tok_emb_f16[D×VOCAB])` → `[B×VOCAB]` (9.5× win) |

`matmulF16Batched(a,b,c,m,n,k)` = `C[m×n]=A[m×k]·B[k×n]`; `deqW16` already emits
the `[k×n]` F16 layout it wants (cross-attn proves it). Attention stays per-slot
(cheap, and the projections carry the 86% layer cost + the 9.5× logit win).

Live path (B=1) never enters this — it keeps the proven fused Q8 GEMV kernels.

## Risks / fallbacks

- The decode kernels are hand-tuned single-token GEMVs; the batched path is a
  **parallel code path** (not a rewrite of the live path) — `BATCHDEC=0` always
  keeps the proven per-slot path. Lower risk, easy A/B.
- If batched attention is the bottleneck (per-slot KV), Stage 1 can batch only
  the **projections** (the 6–9× GEMM win) and keep attention per-slot — still a
  net win since projections dominate the 86% layer cost.
