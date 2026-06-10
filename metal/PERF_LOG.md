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
| ACC-2a (data) | diarization on Whisper **encoder** features (old k=2/≤30s stub, and a new global variable-K AHC) | ❌ data | DER measured on AMI ES2004a (4-spk, md-eval.pl, collar 0.25): all clustering ≥90% ≈ single-spk baseline. Direct proof: intra-speaker cosine 0.006 ≈ inter 0.001 → **encoder output is speaker-invariant** (ASR discards speaker id). Analysis of CUDA reference: it clusters **mel** features, not encoder; final stage is 2-way Fiedler bisection | — |
| ACC-3 | **language auto-detection** (arg-max over language tokens 50259..50358 at the SOT-position logits; env WHISPER_LANG_ID override) + verified Korean | ✅ commit | jfk→en(50259), Korean DevOps 7m42s→ko(50264); fluent Korean across all 16 chunks incl @450s; word timestamps monotonic/aligned; 462s in 36.5s (~12.7× RT); 2-spk timeline alternates with the dialogue. Records in bench/MULTILINGUAL_TEST.md | lang-detect probe |
| ACC-2b | **mel-feature diarization**: pool RAW (unnormalized) log-mel per 1.5s segment → energy VAD → per-dim z-score → k-means (K = CLI arg / DIAR_K, default 2) → global RTTM. mel carries timbre/pitch (intra−inter separation **0.22** vs encoder 0.007) | ✅ commit | **AMI DER 90%→65% (K=2)**; K param exposed (K=4 runs, 76% on hard far-field AMI, better on clean audio); jfk text exact; runs globally on any length (old stub was ≤30s/≤2spk). Oracle ceiling 24% (1.5s seg) — SOTA would need a dedicated speaker-embedding model | melSpectrogramRaw, diarizeMel; bench/ DER harness |

| ACC-4 | **WIN: sovereign ResNet34 speaker-embedding diarization** — hand-ported wespeaker ResNet34 (Apache-2.0) to Zig (kaldi 80-fbank + conv2d via Accelerate sgemm + stats pool + FC), 256-d embeddings per 1.5s window → L2-norm + k-means(K) | ✅ commit | **AMI ES2004a K=4 DER 32.5%** (was 90% encoder / 67% mel; oracle 28.8%). Verified bit-for-bit vs onnxruntime (cosine 1.000000) at every stage. jfk text exact; silence→no spurious speakers. K = CLI/DIAR_K (default 2). No runtime dep (onnxruntime only offline). +~34s/17min for embeds (CPU), RSS +~0.1GB | diar_resnet.zig, bench/ |

## Diarization perf (quark-decomposed, measured)
quark atoms: `file__diar_resnet.zig/{fn__embed,conv2d,fbank,fft512,relu}`.
Per-stage profile (608 AMI embeds) revealed the bottleneck is NOT matmul FLOP:
| stage | share | | conv internal | share |
|---|---|---|---|---|
| stage1 (80×150, 32ch) | 40% | | **im2col** | **77%** |
| stage2 | 26% | | sgemm (Accelerate) | 23% |
| stage3 | 21% | | | |
| stage4 / fbank / pool+gemm | 13% | | | |
| # | idea | result | metric | commit |
|---|------|--------|--------|--------|
| DIAR-OPT1 | im2col: element-by-element strided copy + full @memset → @memcpy of contiguous valid spans (stride-1 path) | ✅ commit | **68→28 ms/embed (2.4×)**; AMI 17min total 100→83s; DER unchanged 32.49% (cosine 1.0 preserved); im2col 15.9s→7.6s | conv2d im2col |
| DIAR-OPT2 | multithread embeds across segments (std.Thread pool over a chunk's ~20 windows; Accelerate pinned to 1 thread/worker via VECLIB_MAXIMUM_THREADS=1 to avoid oversubscription) | ✅ commit | AMI 17min total 83→71s; diar embed ~2.4× (12 cores). NOT Ncore× — im2col is memory-bandwidth-bound, threads share bandwidth → sublinear. DER unchanged 32.49%; jfk exact; silence safe | DiarJob/diarWorker |
| (next) | F16 convs or MPS GPU (compute, not bandwidth) for true scaling; or fuse im2col into a direct conv to cut data movement | backlog | total now transcription-bound (diar ~7s of 71s) | — |

## Memory architecture
| # | idea | result | metric | commit |
|---|------|--------|--------|--------|
| MEM-1a (data) | reclaim mmap'd safetensors via madvise(MADV_DONTNEED, then FREE_REUSABLE) per-tensor after quantize | ❌ data | **no effect** on macOS: peak AND steady RSS flat at 2.53/2.40GB. macOS doesn't drop read-once clean file-backed pages from the resident set (DONTNEED is lazy/deactivate-only; FREE_REUSABLE is for anon malloc pages). ru_maxrss high-water never decreases. ⇒ madvise can't fix it | — |
| MEM-1b | **mmap → pread streaming loader**: never map the 1.6GB data section; pread each tensor into one reusable scratch buffer, consume, overwrite; free scratch+fd after load | ✅ commit (memory, **headline**) | **peak RSS 2.53→1.02GB (−1.5GB, −59%!)**; steady ~0.94GB; jfk text **exact**; encoder/decode unchanged (653ms/188 tok/s); load time unchanged (3.82 vs 3.90s, 2 chunks). Biggest single memory win — exceeds all Q8 work combined | Sf pread + g_rd scratch |

## Auto-K estimator study (2026-06-11, VoxConverse-dev offline)
Harness: `bench/k_study_vox.py` + `bench/k_sweep_vox.py` on `diar_embed_wav`
embedding dumps (215 files, gt speaker counts from ref RTTM). Goal: fix the
demo4 K=2 under-estimate (true 4) without breaking the rest.
| # | idea | result | metric |
|---|------|--------|--------|
| K-EST1 | eigengap (normalized-Laplacian, cosine affinity) | ❌ data | exact 27% vs sil 63% (51-file prelim) — under-estimates far-field badly |
| K-EST2 | BIC elbow (spherical k-means) | ❌ data | demo4 K=3, es K=6 — no better than sil anywhere |
| K-EST3 | raw-pairwise AHC (cosine threshold sweep 0.30-0.60) | ❌ data | far-field explodes (es: 81-469 clusters) — pairwise cosine too noisy without affinity refinement |
| K-EST4 | NME-SC (p-binarized affinity eigengap, simplified Park et al.) | ❌ data | exact 51% vs sil 63%; under-estimates K≥5 |
| K-EST5 | recursive 2-way split (split cluster when its sub-silhouette ≥ sub_tau) — fixes demo4 at sub_tau=0.5 (sub-sils: true-pair 0.55/0.59 vs noise 0.39-0.41) | ❌ data | VoxConverse over-split at EVERY sub_tau (0.45-0.80): best case = no-op, worst exact 50.6% vs 55.1% baseline. demo4's crisp TTS sub-structure is common in real single speakers |
| K-EST6 | silhouette tau bump 0.10→0.25-0.40 (K=1 gate) | 🔬 candidate | K1-recall 0→14% with 0 false positives (89-file prelim) — pending full-set + DER check |
Conclusion: shipped silhouette remains the best estimator measured; demo4
stays a `DIAR_K` hint case. Claimed-voiceprint count now feeds auto-K as a
lower bound in live reclusters (product safety net, no estimator change).

## Hybrid collapse-rescue decode (2026-06-11, quark 품질 후보 발굴)
quark atoms: `metal_kernel__ts_rules_indirect`, `fn__tokenCollapse`,
`fn__main` (seek loop). 교차 대조 트리: `whisper_cpp/quality/large-v3-turbo`
(신규 config, src/whisper.cpp 호스트 품질 로직 taxonomy).
| # | idea | result | metric |
|---|------|--------|--------|
| Q-1 | temperature fallback 사다리 (wcpp entropy/logprob) | ❌ 불필요 | wcpp greedy -nf 도 clova 붕괴 청크를 완벽 전사 — 구원자는 fallback이 아님 |
| Q-2 | **ts-토큰 디코딩이 루프 붕괴의 결정 변수** | ✅ 증명 | wcpp -nt 가 우리와 동일한 "Q. Q. Q." 붕괴 재현 (엔진 독립) |
| Q-3 | EOT 게이트 (유성 잔여 시 EOT 금지) | ❌ 역검증 | 모델이 junk 텍스트로 채움 (wife ". . . ~~") |
| Q-4 | 재인코드 없는 seek (forced initial ts ± startofprev 프롬프트) | ❌ 역검증 | 분포 밖 — 윈도 시작부 재전사 (jfk "and so," 중복) |
| Q-5 | 순수 ts-모드 상시 적용 | ❌ data | 코드스위치 음차("아키텍츄럴", wcpp도 동일) + 다른 11/99 청크 꼬리 붕괴 ("네."×22) |
| Q-6 | **하이브리드: plain 기본 + 토큰 주기성 감지 시 ts+재인코드 seek 재디코드** | ✅ commit | clova 5/99→0/99 (정확히 그 5청크만 구조), 픽스처 PASS, 클린 자산 텍스트 bit-identical, tok/s 495-511(=기준), 오발동 0 |
