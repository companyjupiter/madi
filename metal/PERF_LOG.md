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
| Q8-4 | cross-attn K/V proj weights (ckw/cvw, 4 layers) → Q8 + JIT dequant→MPS (per-chunk cross-KV is M=1500, same as encoder; reuses dequant_q8_f16) | ✅ commit (memory) | clean A/B same thermal window: encoder/decode **identical** (~658ms/~188 tok/s — perf-neutral); peak RSS 2.543→2.531GB (−12MB, F16 cross-KV weights 26→14MB); jfk text exact; test_encoder/decoder green | deqW16 (reuses dequant_q8_f16) |

## Accuracy / quality
Gate (in addition to jfk exact): silence must produce EMPTY output.
Repro: `python3 -c "import wave;w=wave.open('/tmp/sil.wav','w');w.setnchannels(1);w.setsampwidth(2);w.setframerate(16000);w.writeframes(b'\x00\x00'*16000*30)"` then transcribe /tmp/sil.wav.
| # | issue | result | metric | commit |
|---|------|--------|--------|--------|
| ACC-1a (data) | silence hallucination: 30s digital silence → "you. You. You."; tried <|nospeech|>(50363) prob gate at SOT & first-pred positions | ❌ data | P(nospeech)≈0 for silence at BOTH positions (logit_ns even *lower* for silence than jfk) — large-v3-turbo doesn't fire nospeech on OOD digital/near-silence. Token-prob gate unreliable here | — |
| ACC-1b | **energy VAD**: skip a chunk whose loudest 1s-window RMS < 0.01 (speech≈0.14, silence/ambient≲0.001). Skips mel+encode+decode entirely | ✅ commit | silence30 & lownoise30 → **empty** (was hallucinated text); jfk **exact**; jfk3 both chunks full (chunk2's 3s speech kept via max-1s-window metric). Bonus: silent chunks now ~free | hasSpeech VAD |

## Memory architecture
| # | idea | result | metric | commit |
|---|------|--------|--------|--------|
| MEM-1a (data) | reclaim mmap'd safetensors via madvise(MADV_DONTNEED, then FREE_REUSABLE) per-tensor after quantize | ❌ data | **no effect** on macOS: peak AND steady RSS flat at 2.53/2.40GB. macOS doesn't drop read-once clean file-backed pages from the resident set (DONTNEED is lazy/deactivate-only; FREE_REUSABLE is for anon malloc pages). ru_maxrss high-water never decreases. ⇒ madvise can't fix it | — |
| MEM-1b | **mmap → pread streaming loader**: never map the 1.6GB data section; pread each tensor into one reusable scratch buffer, consume, overwrite; free scratch+fd after load | ✅ commit (memory, **headline**) | **peak RSS 2.53→1.02GB (−1.5GB, −59%!)**; steady ~0.94GB; jfk text **exact**; encoder/decode unchanged (653ms/188 tok/s); load time unchanged (3.82 vs 3.90s, 2 chunks). Biggest single memory win — exceeds all Q8 work combined | Sf pread + g_rd scratch |
