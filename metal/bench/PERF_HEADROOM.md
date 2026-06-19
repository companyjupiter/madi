# Whisper perf headroom — quark per-kernel map (remeasured 2026-06-19)

Method: `SOV_METAL_PROFILE=1 ./out/transcribe model.q8 jfk.wav WHISPER_BPE.bin`
→ `/tmp/metal_kern_sum.txt` (per-kernel GPU sums), M4 Pro, large-v3-turbo Q8.
Mirrored into quark: `configs/sovereign_metal_whisper.mjs` `perfData` →
`sovereign_llm/metal/whisper-turbo-v3/.../_perf__measured/`.

## Stale-data correction
The previous `perfData` snapshot was wrong about the front end: it claimed
`conv1d_gelu` = 59 ms × 2 = 118 ms (the #2 cost). That kernel **no longer runs** —
the conv front end is now the Metal-4 `im2col_f16` + `gelu_transpose` path totalling
**~4 ms** (negligible). The old `flash_attention_enc_f16` is the **M4-off fallback**
(`encoder.zig:45`); the live kernel is `m4_flash_enc` (`encoder.zig:51`).

## Where the time is — ENCODER (the headroom)
The encoder is deterministic (32 layers, one pass per 30 s chunk, ~623 ms wall) and
is the product-relevant target. Custom-kernel GPU per chunk:

| kernel | per-call | inst | total | band |
|---|---|---|---|---|
| `m4_gemm_nn` | 2.08 ms | 64 | **133 ms** | tensor GEMM (no bias) |
| `m4_flash_enc` | 3.87 ms | 32 | **124 ms** | self-attention |
| `m4_gemm_bias_gelu` | 3.33 ms | 32 | **107 ms** | FFN up + gelu |
| `m4_gemm_bias` | 0.85 ms | 96 | 81 ms | GEMM + bias |
| `bias_res_ln_f16` | 0.24 ms | 64 | 15 ms | norm |
| conv front end (im2col+transpose+pos) | — | — | ~4 ms | negligible |

- The `m4_gemm_*` matmuls (~321 ms, ~52% of encoder custom GPU) are **MPS / Metal-4
  tensor-unit GEMMs** — already at the Metal-4 ceiling per the perf-target triage
  (bandwidth-reduction plays were refuted; the path is occupancy/tensor-unit bound).
- `m4_flash_enc` (124 ms) is the one custom kernel with possible algorithmic
  headroom. quark atom `metal_kernel__m4_flash_enc` shows **5 `threadgroup_barrier`
  + 6 `simdgroup_multiply_accumulate` + 14 `for`** per call → **occupancy-bound**.
  This **corroborates the triage and contradicts** the old note ("memory-bound,
  query-tiled attention next"). The real lever is reducing barrier serialization /
  raising simdgroup occupancy — a kernel rewrite, not a bandwidth trim.

## DECODER — not headroom (and a measurement caveat)
Per-token decoder kernels are tiny in normal use (`gpu_attention` ~9–33 µs/call).
**Caveat:** under `SOV_METAL_PROFILE` the jfk decode reproducibly takes the
collapse-rescue path (444 tok, 2 passes, ~69 tok/s) instead of the normal 26-tok
~402 tok/s — so the decoder instance counts in this profile are inflated and
unrepresentative. The profiling sync appears to perturb decode numerics into a
collapse; re-measure decoder kernels on a clean (non-rescue) run before treating
any as headroom. (Decode-collapse-under-profiling is itself worth a look, but it's
a profiling artifact, not a production path — profiling is off in shipping builds.)

## Verdict
No free win surfaced: the encoder GEMMs are at the tensor-unit ceiling and the
bandwidth lever was already refuted. The single time-boxed candidate is an
occupancy-oriented rewrite of `m4_flash_enc` (fewer threadgroup barriers / larger
tiles). Everything else (conv, norms, decoder) is already negligible. Logged here
rather than chased blind, per the autonomous-pursuit policy.
