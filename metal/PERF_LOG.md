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

## Speech-validation study (2026-06-11, 후속: VAD 거짓 경보)
재현: tucrg(26s 중 발화 4.5s) DER 919%, pqmho(138s 중 14.9s) 149% — 거짓
경보가 채점 발화의 수 배. diar VAD가 상대 임계(>0.4×median)라 음악/잡음만
있어도 절반가량 통과.
| # | idea | result | metric |
|---|------|--------|--------|
| SV-1 | 절대 RMS 하한 | ❌ data | pqmho 음악 RMS p25=0.154 > wife 실발화 med 0.052 > ES2004a far-field med 0.0067 — 에너지로 음악/발화 분리 불가 |
| SV-2 | no_speech_prob (모델측, OpenAI 공식) | ❌ data | **large-v3-turbo에서 <|nospeech|>는 죽어있음**: 순수 음악(pqmho)과 실발화(jfk) 모두 P≈1e-11~1e-10. 디지털 침묵 한정이 아니라 전면적 (증류 캘리브레이션 소실 추정). SOT 프로브는 lang-detect와 공용으로 유지 |
| SV-3 | 단어 스팬 게이팅 (Whisper 자체 = VAD) | 🔬 측정 중 | tucrg 전사가 정확히 희소 발화만 검출 — RTTM을 단어 스팬 합집합으로 게이트 |
| SV-3 | 단어 스팬 게이팅 (Whisper=VAD) | ❌ 역검증 | 양방향 실패: 음악 위 환각 단어가 DTW로 퍼져 마스크 미축소(tucrg 25s/26s), 회의 중첩 발화 잘림(ES2004a 31.9→47.8% 역회귀) |
| SV-4 | 임베딩 발화-방향 분리 (ResNet 코사인) | ❌ data | tucrg 진짜 발화가 음악보다 낮음 (-0.04 vs +0.03) — far-field 전이 실패 |
| SV-5 | 2-8Hz 음절 변조 비율 | ❌ data | 보컬 음악이 음절 대역 변조 보유 (pqmho 음악 0.582 ≈ 발화 0.578) |
| SV-6 | **Silero-VAD v6 소버린 포팅** (vad_silero.zig, wcpp ggml 가중치 + CLI 교차검증 ±1프레임) | ✅ commit | 윈도 게이트(crms 0화) + 청크 스킵 + RTTM 서브윈도 클리핑. tucrg 919→230%, pqmho 149→78%, **ES2004a 31.85→26.44%(-5.4pt)**, demo4 24.18→24.67, 픽스처 PASS, clova 99/99 + rescue 5 정상. diar 스레드풀과 병행 실행으로 벽시계 비용 ~0 |

## K=3 / 7+ 버킷 돌파 (2026-06-11, 진단 주도)
md-eval 성분 분해(/tmp/dg 하네스)로 두 버킷의 실패 모드 분리:
| # | 발견/아이디어 | 결과 | 근거 |
|---|------|--------|--------|
| B-1 | K=3 버킷: FA≈0인데 **miss 12-27%** — Silero 커버리지는 95-99% (mevkw: floor 0.9% vs 실측 miss 23.4%) → 손실은 우리 게이팅 | ✅ 진단 | 상대 RMS 게이트가 조용한 발화 윈도를 버림 + 클리핑 pad 30ms 과소 |
| B-2 | **silero 권위화**: 윈도 keep을 {0,1} 이진화 (RMS 게이트 자연 퇴화) | ✅ commit | 12-파일 서브셋 22.7→19.5% |
| B-3 | **클리핑 pad 30→200ms, min_speech 250→60ms** (env: VAD_PAD_MS/VAD_MIN_SPEECH_MS) | ✅ commit | 서브셋 19.5→17.5% (pad 250 동률, 300 반전); ES2004a 26.44→**18.83%** + auto-K가 진실 K=4 적중(이전 5), demo4 24.18 완전 복원 |
| B-4 | 7+ 버킷: **confusion 20-41% 지배** — DIAR_MAXK=6 캡 (최악 10중 5파일이 K=6 포화) | ✅ 진단 | maxK 스윕: 7+ 서브셋 31.6→22.0(K8)→**18.0(K10)**→18.1(K12, 포화) |
| B-5 | maxK=10 부작용: **K=1 파일 악화** (hqyok 57→77%, sil이 캡까지 상승) + K=3 서브셋 +1.5pt | ⚠️ 트레이드 | 전수 벤치로 판정 (진행 중) |
| B-6 | K=2↔3 추정기 잔여: 정화된 임베딩에서 일부 자가수정(bravd 2→3), 잔여는 마진 ±0.03 양방향 한계 케이스 (paibn sil2=0.65 vs sil3=0.62; mevkw 역방향 과분할) | ❌ 보류 | 안전한 레버 없음 — 재귀분할 재기각 |
| B-7 | 벤치 인프라: 동시 full_bench 레이스로 결과 오염 사고 → **flock 단일 인스턴스 가드 + 런별 전용 rttm 디렉토리** | ✅ commit | 오염 jsonl 폐기 후 클린 재실행 |
| B-8 | **윈도-퍼-화자 K 하한** `maxK_eff=clamp(m/8,2,maxK)` + maxK 6→10 (파일 모드) | ✅ commit | 손상/수혜 파일이 m으로 완벽 분리 (K1 손상 m=14-26 vs 7+ 수혜 m≥79). 혼합 서브셋 K6 40.7/K10 35.8 → **16.65**. 전수 216: **12.37→8.67%** (med 4.13), 전 버킷 개선: K1 14.8→5.2, K2 7.2→5.0, K3 17.7→14.8, K4 9.4→8.5, K5-6 9.6→7.9, K7+ 16.9→10.2. **pyannote 3.1(≈11.2%) 추월**. ES2004a 18.83%(auto-K=4 정답), demo4 24.18, 픽스처 PASS |

## 라이브 페널티 + 중첩 발화 (2026-06-11)
새 하네스 `bench/live_der.py` (러너 동일 잡 구조 10s+3s 좌측컨텍스트, SPK/SPKFIX 채점):
| # | idea | result | metric |
|---|------|--------|--------|
| L-1 | 라이브 재측정 (현 바이너리): 스트리밍 44.65 / 저장본 37.54 vs 파일 18.83 — 갭 주범 = 파일만 받던 Silero 구간 클리핑 | ✅ 진단 | far-field 침묵이 1.5s 그리드 통짜 SPK로 FA화 |
| L-2 | **SPK/SPKFIX 소스 클리핑** (4번째 dur 필드, 러너 awk 하위호환) + 스트림에서도 g_vad_iv 누적 | ✅ commit | ES2004a 라이브: 스트리밍 44.65→**25.66%**, 저장본 37.54→**18.43%** (파일 18.83 동급). 픽스처 PASS, 파일 모드 18.83 불변 |
| O-1 | 중첩 정량화: ES2004a ref 중첩 추가화자시간 = 채점시간 14.7% = 단일라벨 miss 바닥. 우리 1화자 구간 miss는 7.2%뿐 — **miss의 본체가 중첩** | ✅ 진단 | 천장: ES2004a -13pt급 |
| O-2 | 중첩 탐지 #1: 센트로이드 모호도 cos2/cos1 | ❌ data | 재현 20%/오탐 6% (1.5s 풀링이 중첩 구조를 뭉갬) |
| O-3 | 중첩 탐지 #2: 화자 전환 인접 윈도 (±모호도 결합) | ❌ data | 최선 재현 35%/정밀 46% — 2차 화자 방출 손익분기 미달 |
| O-4 | 결론: 학습 OSD 필요 (pyannote segmentation급 포팅 = Silero급 이상 별도 프로젝트) | 📋 백로그 | 단일 라벨 구조 한계로 기록 |

## 학습 OSD 포팅: pyannote segmentation-3.0 (2026-06-11)
소버린 포팅 공식 재적용: sherpa-onnx ONNX → bench/convert_pyannote_seg.py →
osd_pyannote.zig (SincNet+BiLSTM×4+파워셋7), onnxruntime 심판 검증
max|Δlogp|=3.5e-5, argmax 불일치 0/589. Accelerate sgemm/sgemv로 413→90ms/10s.
| # | idea | result | metric |
|---|------|--------|--------|
| P-1 | 파워셋 argmax 중첩 검출 + 턴테이킹 prior 2차 화자 | ✅ 1차 | ES2004a 18.83→17.16% (miss 16.0→12.7) |
| P-2 | 확률 임계(P(ov)≥θ) 검출 | ✅ 미세 | θ 스윕 포화 ~17.1 |
| P-3 | 5s 슬라이딩+프레임 평균 집계 (pyannote식) | ❌ 무익 | 17.05 vs 17.12 — 디스조인트로 회귀 |
| P-4 | **로컬 트랙 정체성**: 파워셋 페어 + 로컬 솔로 프레임의 전역 투표 | ✅ commit | ES2004a **16.47%** (θ=0.25 포화; miss 12.5/fa 1.8/conf 2.2) |
| P-5 | OSD 행의 silero 클리핑 우회 → tucrg 232→462% 사고 | ✅ 수정 | emitOverlapRow가 g_vad_iv 교차로만 방출 + prim≥0 가드 (1차 화자 위에만 2차) |
| P-6 | 군중 가드 (중첩 런 ≥3s 차단) | ❌ 역검증 | tucrg 불변(런이 원래 짧음), ES만 16.49→16.92 손상 — 롤백 |
| P-7 | tucrg 잔차 (229.7→356%) | 📋 수용 | 군중 함성 = 진짜 다성인데 ref 미라벨 — 알려진 병리 파일 |

## Metal-4 tensor-ops 인코더 — Phase 1 (2026-06-11)
quark atoms: `metal_kernel__m4_gemm_nn`, `metal_kernel__m4_gemm_bias`,
`metal_kernel__m4_gemm_bias_gelu`, `fn__forward`(encoder dual-path).
toolchain: Xcode 26.5, -std=metal4.0 (m4_*.metal만), MPP tensor_ops.
| # | idea | result | metric |
|---|------|--------|--------|
| M4-1 | 셰이더 내 raw 포인터 tensor 뷰 (런타임 MTLTensor 불필요) | ✅ 검증 | **비-const 필수** (mpp 헤더에 const 오버로드 없음 — "Unsupported type" 정적 단언의 정체) |
| M4-2 | 순수 tensor-ops GEMM vs MPS (fc1 형상 1500×5120×1280, 64×64타일/4SG/동적K) | ✅ data | **3.64ms vs 3.83ms (1.05×)**, max|Δ|=0 — 미튜닝으로 MPS 동급+ |
| M4-3 | mode::multiply가 기본(덮어쓰기) — zero-init 패스 불필요 | ✅ 확인 | descriptor 7번째 인자 |
| M4-4 | **융합 에필로그**: GEMM+bias, GEMM+bias+erf-GELU (타일 cache-hot 상태서 적용; bias_add_f16/gelu_f16 전체 패스 제거) | ✅ commit | run()은 lvalue 슬라이스 요구 |
| M4-5 | 인코더 6 GEMM 전부 교체 (ENC_M4=0 = MPS 폴백 이중 경로) | ✅ commit | **배치4 569→511ms(-10.1%), 배치1 647→588ms**; jfk 단어·스팬 바이트 동일; wcpp 571ms 최초 추월 |
| M4-roadmap | Phase 2: Q8 직행 GEMM (half×int8 네이티브 — dequant 77ms+가중치 트래픽 ½ 제거, k-loop+coop tensor로 블록 스케일), Phase 3: flash_attention_enc tensor-ops 재작성 (160ms), int4 경로 (모델 Q4 시) | 📋 | 지원표: half×int8→half/float, int4b_format까지 1급 |
| M4-6 | **Q8 직행 GEMM (Phase 2)** — A: 32-K coop 스케일 패스, B: TG 타일 dequant(tilek 128/256) | ❌ 기각 (M4급) | A 0.57× / B(128) 0.84× / B(256) 0.56× vs dequant+f16GEMM 4.3ms. 원인: 열당 24 TG가 동일 가중치 타일 중복 dequant — legacy의 레이어 단위 1회 dequant+SLC 상주 왕복이 사실상 최적. 정확성은 검증(max|Δ|=0.0005). **M5 GPU neural accelerator(네이티브 int8 matmul)에서 뒤집힐 후보** — 커널·하네스 보존 |
| W-1 | **WER 표준 벤치 — 절대 ASR 품질 (최종)** (resident STREAM 잡피드 + 공식 Whisper 정규화기 + jiwer, 영구 bench/wer_runs/) | ✅ **확정** | **test-clean WER 2.17%** (2620발화/53k단어), **test-other WER 4.19%** (2939발화/52.9k단어), **FLEURS-ko CER 3.99% / WER(공백토큰) 13.32%** (382발화, 빈hyp 0). 공표 large-v3(clean 2.0 / other 3.9) 사실상 동급 — **Q8 양자화 + 자체 Metal 파이프라인이 레퍼런스급 절대 품질**임을 입증. 한국어 CER 3.99%는 강력(read-speech). 게이트-프리(VAD_THRESH=0)+피크정규화(-1dBFS) 측정 |
| W-2 | **발화 게이트의 절대 진폭 민감성** — FLEURS-ko(피크 −33 dBFS)에서 222/382 청크 무음 스킵 (에너지 게이트 + silero 둘 다 저게인서 침묵) | ✅ 진단 | 제품 함의: 저게인 마이크면 제품 전체 침묵 가능. +20dB 부스트 → 완벽 전사로 진폭 원인 확정 |
| W-2b | **AGC 구현 + 자기수정** (transcribe.zig) — 1차: 게이트 전용(인코더 불변) → **CER 5.54%/5빈값으로 역검증 실패**. 진단: 빈값 5파일 peak 0.11~0.23(중간게인)인데도 빈전사 = **인코더도 저게인서 실패** (앞선 3.99%는 외부 부스트값이었지 raw 아님 — 전제 정정). 2차: peak<0.30일 때만 타깃 0.9(−1dBFS)로 **in-place 정규화(게이트+인코더 동시)**, 정상(peak≥0.30) 불변. AGC=0 롤백 | ✅ commit | **제품경로 FLEURS-ko 0빈값 CER 4.05%**(외부정규화 3.99%와 동일, 핵 없이). 회귀: jfk **바이트동일**, ES2004a DER **16.49→15.57 개선**(조용한 발화 4개 복구, 무음청크 40× 부스트해도 게이트가 헛전사 차단). devops 타임스탬프 흔들림은 AGC 무관(AGC=0 2회도 다름=기존 비결정성, 백로그). 벤치는 제품경로로 단순화(게이트우회·외부정규화 제거) |
| T-1 | **라이브 번역 (Whisper translate 토큰)** — SEED 태스크 토큰 transcribe(50360)↔translate(50359) 런타임 분기(TRANSLATE=1), 파일/스트림/seek 전 경로 | ✅ 배선 / ❌ turbo 불가 | 토큰 배선 정확·무해(기본 transcribe 회귀 클린). **그러나 large-v3-turbo는 번역 못 함** — 지피지기: wcpp turbo `--translate`도 KO 입력에 KO 출력(동일). OpenAI가 turbo 파인튜닝서 번역 데이터 제외(공표). 배선은 번역가능 모델(full v3 / 텍스트 MT) 물리면 즉시 작동 — **미래 대비 보존**. 번역 기능은 보류 |
| W-3 | **엔진 wav 파서 강건화** (mel.zig wavFmt/loadWavChunk + transcribe.zig 가드) | ✅ commit | **float32(tag 3/0xFFFE, 32bit) 네이티브 지원** — FLEURS 원본 무변환 전사 확인. 빈/미지원 파일은 **segfault→명시 스킵**("empty or truncated"/"unsupported WAV format", stream은 빈 SEG_END 후 continue). 회귀: jfk PCM16 경로 산술 불변, devops 멀티청크 정상. 4케이스(PCM16/빈/float32/8bit) 검증 |
| M4-7 | **flash attention tensor-ops 재작성 (Phase 3)** — 64-q 타일(기존 32), strided device tensor 뷰로 Q/K/V 제자리 소비(TG 스테이징 0), QK^T/P·V matmul2d + coop 누산, S는 coop→TG f32 | ✅ commit | 격리 5.19→**3.84ms (1.25×)**, max|Δ|=6e-5 bad=0; 인코더 배치4 494→**462ms (flash 단독 -32ms)**, 배치1 570→545ms; MPS 대비 전체 M4 스택 548→462 = **-15.7%**; devops_ko/jfk 전사·단어 바이트 동일, KO+EN 픽스처 PASS. ENC_M4F=0 = flash 단독 롤백 |
| M4-8 | 진단: 1-thread/row 소프트맥스가 병목 (스테이지 프로브: QK만 1.65ms / +scatter 1.80 / +softmax 4.61 / full 6.35) | ✅ data | 2-thread/row + float4 벡터화로 6.31→3.84ms. 교훈: tensor-ops 도입 시 matmul 바닥(1.65×2)이 빨라져 비-matmul 직렬 구간이 즉시 지배 |
| M4-9 | strided tensor 생성자 발견: tensor(ptr, dextents, array<int,2>{1, row_stride}) — mpp matmul2d와 호환 | ✅ 검증 | TG 복사 불필요 → TG 25KB로 한도(32KB) 통과; 단 64-타일 꼬리가 seq 너머를 읽으므로 버퍼 +64행 패딩 필수 (qkv 스크래치) |
| L-3 | **라이브 경로 OSD** (스트림 기본 ON, FLUSH에서 SPKOV 행 — relabel 윈도 기반 로컬트랙 정체성 + silero 클리핑) + 러너 끼어들기 마커 "⟨+Speaker N 겹침⟩" | ✅ commit | ES2004a 라이브 저장본 18.43→**17.41%** (116 겹침 행); 지연 +26ms/세그먼트(+2.4%, 2분 리플레이 A/B); ES 2분 양성대조 .md 마커 2건 확인; wife(무중첩) 마커 0 ✓; 픽스처 PASS |
