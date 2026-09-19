# Madi — Apple Silicon (Metal) Port

Self-contained macOS/Metal port of the Windows+CUDA Madi V20.
Target: Apple Silicon (developed on M4 Pro, macOS 26).

## Why a full rewrite of the GPU layer
NVIDIA CUDA/PTX does not run on Apple Silicon. The host code was also
Windows-only (`nvcuda.dll`, `cublas64_*.dll`, `kernel32` mmap/QPC). So the
port replaces:

| CUDA / Windows | Metal / macOS |
|---|---|
| PTX kernels (`kernels/*.ptx`) | MSL kernels (`metal/kernels/*.metal`) |
| `cuLaunchKernel(grid,block,args)` | `mtl_dispatch(...)` (bridge) |
| `nvcuda.dll` dynamic load | `metal_backend.{h,m}` ObjC bridge, `-framework Metal` |
| `cuMemAlloc`/`cuMemcpyH2D`/`D2H` | unified memory — `mtl_alloc` + plain memcpy |
| cuBLAS GEMM | **MPS / MPSGraph** matmul (encoder/decoder) |
| CUDA Graph (decoder step capture) | Metal Indirect Command Buffer (later) |
| `kernel32` mmap, QPC timer | `std.fs`, `std.time` (portable) |

### PTX → MSL translation map (canonical)
| PTX | MSL |
|---|---|
| `%ctaid.x` (blockIdx) | `[[threadgroup_position_in_grid]]` |
| `%tid.x` (threadIdx) | `[[thread_position_in_threadgroup]]` |
| `%nctaid.x` (gridDim) | `[[threadgroups_per_grid]]` |
| `%ntid.x` (blockDim) | `[[threads_per_threadgroup]]` |
| `.shared` | `threadgroup` address space |
| `bar.sync 0` | `threadgroup_barrier(mem_flags::mem_threadgroup)` |
| `shfl.sync.bfly.b32` | `simd_shuffle_xor` (simd width = 32 on M-series = CUDA warp) |
| `ex2.approx.f32` | `exp2()` / `precise::exp2()` |
| `rsqrt.approx.f32` | `rsqrt()` |

## Layout
```
metal/
  metal_backend.h/.m   proven ObjC bridge (device, buffers, dispatch, sync; MPS later)
  metal_backend.zig    lean Zig wrapper (this port's API surface)
  kernels/*.metal      ported GPU kernels
  build.sh             kernels→whisper.metallib + link a Zig harness
  smoke.zig            Milestone 0 toolchain proof          [✅ passing]
  test_conv1d.zig      conv1d numerical correctness vs CPU  [✅ passing]
```
Build+run a harness: `bash build.sh test_conv1d.zig && ./out/test_conv1d`

## Milestones
- [x] **M0 — Backend + toolchain.** ObjC bridge in-repo, Zig wrapper, build
  system, vector-add smoke test green on M4 Pro.
- [x] **M1 — Front-end: WAV → mel → Conv1D.** `conv1d_gelu` + `transpose_2d`
  ported & numerically verified vs CPU (`test_conv1d`, err 3e-7). mel DSP
  (`mel.zig`: Hann/naive-DFT/filterbank/log10-norm) ported verbatim from the
  CUDA `wav_to_enc.zig`; rfft peak test exact (`test_mel`). Front-end binary
  `wav_to_enc.zig` builds & runs (WAV→mel→GPU conv1×2→transpose+pos_emb→
  enc_input.bin). Full numeric verify vs reference enc_input awaits assets.
- [x] **M2 — Encoder (32 layers).** Ported `layer_norm`, `bias_res_ln`,
  `flash_attention_enc`, `bias_add`, `gelu_f32`(erf) → `kernels/encoder_ops.metal`.
  Added MPS F32 GEMM to the bridge (`mtl_matmul_f32`, row-major, offset-aware).
  Reusable 32-layer driver `encoder.zig`. One full encoder layer verified vs CPU
  (`test_encoder`, max_abs_err 9e-8, max_rel 1e-5). F32 throughout, no f16.
  **Bug fixed:** the dispatch bridge bound mid-buffer (offset) pointers as
  scalar bytes → MPS/validation deadlock; now resolves containing buffer +
  offset (`resolve_buffer`). Essential for encoder & decoder (stacked QKV/KV).
  Full 32-layer numeric verify vs PyTorch awaits model assets (M3 loader).
- [x] **M3 — Decoder + full pipeline. WORKS END-TO-END ✅.**
  `transcribe.zig` ties it together: safetensors loader (F16→F32, weights
  transposed to [in][out]) → WAV→mel→Conv1D×2 → 32-layer encoder → per-layer
  cross-KV precompute → 4-layer autoregressive decoder (embed→block×4→final
  LN→logit GEMV→CPU argmax+suppress→BPE). Verified on `jfk.wav`:
  > "And so, my fellow Americans, ask not what your country can do for you,
  >  ask what you can do for your country."
  encoder 1.23 s, decoder 26 tok @ ~30 tok/s on M4 Pro. SEED for v3-turbo =
  [50258 sot, 50259 en, 50360 transcribe, 50364 notimestamps].
  Run: `./out/transcribe assets/model.safetensors assets/jfk.wav assets/WHISPER_BPE.bin`

<details><summary>M3 kernel detail</summary>

  Ported `gpu_residual`,
  `gpu_emb_lookup`, `gpu_kv_store`, `gpu_attention` (dense self-attn),
  `flash_cross_attn` → `kernels/decoder_ops.metal`. Reusable `decoder.zig`
  (decodeBlock). One full decode block (self-attn + cross-attn + MLP) verified
  vs CPU (`test_decoder`, max_abs_err 6e-8, max_rel 3e-6). GEMVs via MPS (M=1).
  Note: `gpu_attention`'s corridor-sparse branch is a no-op for self-attn
  (pos<1500), so the port is dense; cross uses `flash_cross_attn`.
  TODO: autoregressive loop (embed→N×block→final LN→logit GEMV→argmax→append),
  logit_filter + argmax kernels, BPE tokenizer, safetensors model loader →
  full transcription. (CUDA-Graph step → plain dispatch loop first; Metal ICB
  later.) End-to-end + vs-PyTorch verification needs model assets.
</details>
- [~] **M4 — Polish.** **Word-level timestamps DONE ✅** — `extract_ca_head`
  kernel recomputes the cross-attn softmax for the 6 v3-turbo alignment heads
  ({2,4},{2,11},{3,3},{3,6},{3,11},{3,14}), averaged into a [MAX_TOK][1500]
  map; median-3 + argmax → encoder frame → time (20 ms/frame), grouped into
  words. Verified on jfk.wav ("And" 0.64s … "your" 10.24s; final-token end
  artifact as in the reference). quark metal config live (whisper-turbo-v3,
  14 kernels). **Zero-shot diarization DONE ✅** — CPU VAD(L2 energy) +
  K-means(K=2) + temporal smoothing on enc_out → speaker timeline (ported from
  the reference; single-speaker clips show the reference's silence-frame
  artifact). **Long-audio (>30 s) chunking DONE ✅** — weights loaded once, then
  a 30 s-window loop (mel→conv→encoder→per-chunk cross-KV→decode), text
  concatenated and word timestamps offset by chunk start. Verified on a 33 s
  clip (2 windows; global word times to 32 s). Non-overlapping windows can split
  a phrase at the 30 s boundary (reference uses 2 s overlap — future refinement).
  **Perf pass DONE ✅** (accuracy-neutral, output bit-identical):
  - **Command-buffer batching** — added `mtl_matmul_f32_enc` (MPS encodes onto
    the shared active command buffer) + `matmulBatched`; decoder runs one command
    buffer per token, encoder one per layer (Metal preserves encoder order, so
    data deps stay correct). Collapsed ~12 GPU round-trips/token → 1.
    Decoder **~470 ms → ~254 ms for 26 tok (~100 tok/s, ~1.8×)**; encoder
    **~1.39 s → ~1.18 s** (M4 Pro, jfk).
  - **Profiled with `SOV_METAL_PROFILE=1`** → measured kernel times embedded in
    quark (`_perf__measured/`, 8 kernels). Finding: `flash_attention_enc` is the
    encoder's #1 cost (~71% of custom-kernel GPU time, ~16 ms/layer), and it is
    **memory-bound** — naive re-parallelizations of it REGRESS (documented in the
    kernel). Next real win = query-tiled FlashAttention (K/V reuse).
  - **GPU-resident decode loop** (idea extracted from the optimized PTX/CUDA
    SHARE build — its speed came from CUDA Graph replay, NOT better kernels;
    the kernels are byte-identical). Ported `graph_helpers.metal`:
    `emb_lookup_indirect`, `pos_embed_add_indirect`, `step_advance`,
    `argmax_no_inc`, `logit_filter_indirect` (+ `suppress_list`). The full
    decode step now runs on-GPU (indirect embed → blocks → logit GEMV → GPU
    filter+argmax+step-advance) with NO CPU between tokens; B=8 steps recorded
    per command buffer, sync once per batch (Metal's CUDA-Graph-replay
    equivalent). Also gained the SHARE anti-repeat-loop heuristic. Decoder
    **~100 → ~110 tok/s**; jfk decode ~234 ms; 33 s clip 6.9 s → 5.2 s.
  - **F16 logit embedding** — `embed_tokens` kept as raw F16 (no F16→F32
    expand): 265 MB → 132 MB, faster load. New `logit_gemv_f16` kernel + F16
    `emb_lookup`. Output bit-identical; decode ~neutral (logit is a small slice
    of the step). The win is **memory** (peak RSS down ~130 MB) + load time.
  - **simdgroup-matrix flash_attention_enc** — the encoder was compute-bound on
    the per-key warp-shuffle reduction (query-tiling alone gave only ~5%). So
    rewrote QK^T and S·V to run on the **Apple matrix coprocessor**
    (`simdgroup_float8x8` + `simdgroup_multiply_accumulate`, 8×8 tiles), adapted
    from the sovereign LLM `flash_attn_prefill.metal` (hdd=64, F32,
    bidirectional, online softmax with diagonal-matrix rescale). 32 queries ×
    4 simdgroups/threadgroup. **flash_attention_enc 16.2 ms → 6.76 ms/layer
    (2.4×); encoder ~1090 ms → ~686 ms (−37%).** Output bit-identical
    (test_encoder err 9e-8). This is the canonical CLAUDE.md pattern: cross-
    referenced the llama.cpp/sovereign metal mma kernel before designing.
  - **F16 encoder (GEMM + simdgroup flash)** — converted the encoder activation
    path to F16: projection GEMMs via **MPS F16** (`mtl_matmul_f16_enc`), weights
    kept raw F16 (also halves encoder weight memory), attention via
    `flash_attention_enc_f16` (`simdgroup_half8x8` in, float accumulate — the
    quark llama.cpp `*_mul_mm` pattern). Residual stream X + final enc_out stay
    F32 (decoder untouched); `cvt_f16_f32` bridges the last layer. New F16
    kernels: layer_norm/bias_res_ln/bias_add/gelu/flash/cvt. **flash 6.76 →
    4.88 ms (F16 mma); encoder ~686 → ~565 ms.** Output bit-identical on jfk;
    test_encoder (F32) still green.
  TODO (optional): 2 s-overlap merge for long audio; streaming/mic front-end for
  real-time meetings (see assessment).

## Quark (kernel topology analysis)
This port has its own quark tree, isolated from the LLM trees (no folder
overlap): config `quark/configs/sovereign_metal_whisper.mjs` → output
`quark/sovereign_llm/metal/whisper-turbo-v3/`.
Regenerate after any `.metal`/`.zig` change (mandatory per global CLAUDE.md):
```
cd ~/antigravity/quark && node quarkify_v7_metal.mjs configs/sovereign_metal_whisper.mjs
```
Browse a kernel atom, e.g.:
`tree -L 2 sovereign_llm/metal/whisper-turbo-v3/quark/file__kernels_conv1d.metal/`

## Assets — PREPARED ✅ (see `assets/README.md`)
Downloaded/generated locally (git-ignored): `model.safetensors` (1.5 GB,
large-v3-turbo), tokenizer/configs, `mel_filters.bin`, `suppress_tokens.bin`
(88), `WHISPER_BPE.bin` (vocab 51866), encoder front-end weights
(`conv1/2_w/b.bin`, `pos_emb.bin`), and `jfk.wav` (16 kHz test clip).
Aux binaries generated by pure-stdlib scripts (`gen_assets.py`,
`export_enc_weights.py`) — no torch/numpy.

**M1 validated on real data:** `wav_to_enc assets/jfk.wav` → `enc_input.bin`
[1500×1280], finite, range ~[-1.2, 3.4] — real mel filterbank + conv weights +
conv kernels + positional embedding all working end-to-end.
