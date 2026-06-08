# Metal perf optimization loop — log

Autonomous self-paced optimization on branch `feature/metal-perf-loop`.

## Protocol (per iteration)
1. Pick next idea (backlog below, or derive from quark `_perf__measured` bands).
2. Implement (kernel / host edit).
3. **Build** — fail → revert, log FAIL.
4. **Correctness gate** (hard): `test_encoder` + `test_decoder` stay green AND
   `transcribe assets/jfk.wav` text **exactly** == golden:
   `And so, my fellow Americans, ask not what your country can do for you, ask what you can do for your country.`
   Any mismatch → revert, log FAIL.
5. **Measure** encoder/decoder ms (≥3 runs, take min).
6. **Decide**: faster beyond noise (>3%) & correct → keep → regen quark → `git commit`.
   Else → `git revert`(working tree) → log as tried-and-failed (Data).
7. Append a row below. Regenerate quark after any committed `.metal`/`.zig` change.

## Baseline (M4 Pro, jfk 11s) — start of loop
encoder ~565 ms · decoder ~120 tok/s · flash_attention_enc_f16 4.88 ms/layer
front-end conv1d_gelu ~50 ms × 2.

## Idea backlog
- conv1d_gelu: F16 weights (bandwidth), or MPS/im2col GEMM, or better tiling.
- decoder: F16 weights for self/cross/MLP GEMVs (M=1, bandwidth-bound).
- decoder cross-attn (flash_cross_attn): F16 K/V cache.
- logit_gemv_f16: tune threadgroup / 2-row.
- encoder: fuse bias into LN/GEMM epilogue; reduce per-layer sync further.

## Results (newest first)
| # | idea | result | metric | commit |
|---|------|--------|--------|--------|
| 1 | conv1d_gelu F16 weights | ❌ revert | conv 23–47ms/call, no clear gain (weights cached across time axis → compute-bound, not bandwidth) | — |
| 2 | decoder cross-attn F16 K/V cache | ✅ commit (memory) | decode 120→123 tok/s (speed neutral, within noise); cross-KV cache 61→30 MB; correct | flash_cross_attn_f16kv + extract_ca_head_f16kv |
| 3 | decoder proj GEMVs → custom F16 GEMV (replace MPS M=1) | ❌ revert | decode 212→712ms (3.4× SLOWER); MPS M=1 GEMV is already well-optimized, naive 1-thread/col kernel far worse | — |
| 4 | logit_gemv F16 coalesced (warp/row + simd_sum) | ✅ commit | decode 118→128 tok/s (~8%); logit kernel 882→640us; correct | logit_gemv_f16_cg |
| 5 | flash_cross_attn phase1 warp-per-key (coalesced) | ❌ revert | decode 128→121 tok/s (slower); coalescing gained but parallelism dropped (256 threads→8 warps) for seq=1500 | — |
| 6 | conv1d → im2col + MPS F16 GEMM | ✅ commit | conv front-end ~95→22ms (~4×); total 3.22→3.15s; correct | im2col_f16, gelu_transpose, gelu_pos |
| 7 | MPS object caching (shape-keyed descriptors+op) | ✅ commit | decode 120→130 tok/s (~8%); encoder neutral; correct | backend mps_cache_get |
| 8 | decoder QKV 3→1 batched GEMM | ✅ commit | decode 130→134 tok/s (~3%); 8 fewer GEMM calls/token; correct | (stacked qkvw) |
| 9 | encoder all-layers single command buffer | ❌ revert | encoder 590→589ms (~0%); compute-bound, sync overhead negligible vs GPU work | — |

## Q8 quantization phase (memory + bandwidth)
| # | idea | result | metric | commit |
|---|------|--------|--------|--------|
| Q8-1 | embed_tokens → Q8_0 (int8 + per-32 fp16 scale); logit/emb lookups Q8 | ✅ commit | decode 134→140 tok/s; peak RSS 4.78→3.40GB; text exact | logit_gemv_q8, emb_lookup_indirect_q8, gpu_emb_lookup_q8 |
| Q8-2 | decoder proj GEMVs (q/k/v/o/cq/co/m0/m2) → Q8 warp-per-row GEMV | ✅ commit | decode 140→188 tok/s (~34%!); RSS 3.40→3.13GB; text exact. (iter3's custom GEMV lost only due to bad uncoalesced design; coalesced Q8 beats MPS M=1) | gemv_q8 |
| Q8-3a (de-risk) | direct custom Q8 tile GEMM (mul_mm_q8, 32×32 tile/4 simdgroups) vs MPS F16 @ encoder shape 1500×1280×1280 | ❌ data | correctness OK (max_abs_err 1e-3); **2.10ms vs MPS 0.88ms = 2.39x SLOWER**. compute-bound M=1500 ≠ decoder M=1 GEMV; vendor MPS GEMM unbeatable by hand-MSL here. ⇒ direct-Q8-GEMM rejected for encoder | mul_mm_q8 (test_q8gemm.zig) |
| Q8-3b | **encoder proj weights → Q8 (out-major) + JIT transposing dequant→F16 scratch + MPS F16 GEMM** (qkv/o/fc1/fc2, 32 layers) | ✅ commit (memory) | **peak RSS 3.13→2.54GB (−0.59GB!)**; encoder 587→627ms (+7%, dequant launches, acceptable: encoder is 1×/30s-chunk); decode unchanged 193 tok/s; jfk text **exact**. test_encoder/decoder green. Keeps MPS GEMM speed while dropping F16 weights 1.26GB→0.67GB | dequant_q8_f16 |
| Q8-3c | recover +7%: fuse q/k/v dequant 3→1 launch (dequant_q8_f16_qkv, 192→128 launches/forward) | ❌ revert | encoder 627→630ms (neutral, within noise). The +7% dequant cost is **bandwidth-bound** (F16 scratch round-trip ~1.9GB write + MPS read), NOT launch-bound — cutting 64 launches changed nothing (cf iter9: encoder sync overhead negligible). Irreducible w/ MPS: only fused dequant+GEMM avoids the round-trip, but that's the 2.39x-slower mul_mm_q8. +7% accepted as cost of memory win | — |
