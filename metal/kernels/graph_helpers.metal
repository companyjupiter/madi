// graph_helpers.metal — GPU-resident decode-loop primitives (port of
// graph_helpers.ptx). With these the whole decode step runs on the GPU with NO
// CPU between tokens, so many tokens can be recorded into one command buffer
// (Metal's equivalent of CUDA Graph replay). Idea extracted from the optimized
// PTX/CUDA SHARE build.
#include <metal_stdlib>
using namespace metal;

constant uint VOCAB = 51866;

// out[i] = emb[tokens[*pos] * dim + i]   (F16 embedding → F32 stream)
kernel void emb_lookup_indirect(
    device float*        out_buf [[buffer(0)]],
    device const half*   emb     [[buffer(1)]],
    device const uint*   tokens  [[buffer(2)]],
    device const uint*   pos_ptr [[buffer(3)]],
    constant uint& dim [[buffer(4)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= dim) return;
    uint tok = tokens[pos_ptr[0]];
    out_buf[gid] = float(emb[(ulong)tok * dim + gid]);
}

// logit projection GEMV: logits[v] = Σ_d emb_f16[v*dim+d] · x[d].
// One thread per vocab row; x cached in threadgroup (reused by the 256 lanes).
// Replaces the F32 MPS logit matmul — halves embedding memory + read traffic.
kernel void logit_gemv_f16(
    device float*        logits [[buffer(0)]],
    device const half*   emb    [[buffer(1)]],
    device const float*  x      [[buffer(2)]],
    constant uint& vocab [[buffer(3)]],
    constant uint& dim   [[buffer(4)]],
    uint gid [[thread_position_in_grid]],
    uint lt  [[thread_position_in_threadgroup]])
{
    threadgroup float xs[1280];
    for (uint d = lt; d < dim; d += 256) xs[d] = x[d];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (gid >= vocab) return;
    device const half* row = emb + (ulong)gid * dim;
    float acc = 0.0f;
    for (uint d = 0; d < dim; d++) acc += float(row[d]) * xs[d];
    logits[gid] = acc;
}

// out[i] += pos_emb[*pos * dim + i]
kernel void pos_embed_add_indirect(
    device float*        out_buf  [[buffer(0)]],
    device const float*  pos_emb  [[buffer(1)]],
    device const uint*   pos_ptr  [[buffer(2)]],
    constant uint& dim [[buffer(3)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= dim) return;
    out_buf[gid] += pos_emb[(ulong)pos_ptr[0] * dim + gid];
}

// *pos_ptr += 1   (single thread)
kernel void step_advance(device uint* pos_ptr [[buffer(0)]]) {
    pos_ptr[0] = pos_ptr[0] + 1;
}

// argmax over logits[0..VOCAB) → tokens[*pos] (no pos increment).
// Grid=(1,1,1) Block=(1024,1,1).
kernel void argmax_no_inc(
    device const float* logits  [[buffer(0)]],
    device uint*        tokens   [[buffer(1)]],
    device const uint*  pos_ptr  [[buffer(2)]],
    constant uint& max_len [[buffer(3)]],
    uint t_id [[thread_position_in_threadgroup]])
{
    threadgroup float sv[1024];
    threadgroup uint  si[1024];
    float local_max = -INFINITY;
    uint local_idx = 0;
    for (uint i = t_id; i < VOCAB; i += 1024) {
        float v = logits[i];
        if (v > local_max) { local_max = v; local_idx = i; }
    }
    sv[t_id] = local_max;
    si[t_id] = local_idx;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = 512; s > 0; s >>= 1) {
        if (t_id < s) {
            if (sv[t_id + s] > sv[t_id]) { sv[t_id] = sv[t_id + s]; si[t_id] = si[t_id + s]; }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (t_id == 0) {
        uint cur = pos_ptr[0];
        if (cur < max_len) tokens[cur] = si[0];
    }
}

// suppress an explicit list of token ids (non-speech symbols).
kernel void suppress_list(
    device float*       logits   [[buffer(0)]],
    device const uint*  ids      [[buffer(1)]],
    constant uint& n [[buffer(2)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= n) return;
    uint t = ids[gid];
    if (t < VOCAB) logits[t] = -3.4e38f;
}

// logit_filter_indirect: GPU-side logit masking that reads `step` from a GPU
// pointer. Bans special/timestamp tokens (≥50258), an anti-repeat-loop rule
// (if last 3 tokens equal, ban that token), and a begin-suppress window that
// bans EOT(50257) and space(220) for the first few generated steps.
// Grid=(1,1,1) Block=(256,1,1).
kernel void logit_filter_indirect(
    device float*       logits        [[buffer(0)]],
    device const uint*  past_tokens   [[buffer(1)]],
    constant uint& num_suppress       [[buffer(2)]],
    device const uint*  step_ptr      [[buffer(3)]],
    constant uint& sample_begin       [[buffer(4)]],
    uint i [[thread_position_in_grid]])
{
    (void)num_suppress;
    const float NEG = -3.4e38f;
    const uint step = step_ptr[0];

    // anti-loop (thread 0): if tokens[step-1]==tokens[step-2]==tokens[step-3], ban it
    if (i == 0 && step >= 3) {
        uint t1 = past_tokens[step - 1];
        uint t2 = past_tokens[step - 2];
        uint t3 = past_tokens[step - 3];
        if (t1 == t2 && t2 == t3) logits[t1] = NEG;
    }
    // ban specials/timestamps ≥ 50258 (strided by 256)
    for (uint t = i + 50258; t < VOCAB; t += 256) logits[t] = NEG;

    // begin-suppress window: ban EOT + space for the first 4 generated steps
    if (step < sample_begin + 4) {
        if (i == 0) logits[220] = NEG;   // space
        if (i == 1) logits[50257] = NEG; // EOT
    }
}

// logit_gemv_f16_cg — coalesced variant: one SIMD-group (warp) per vocab row,
// 32 lanes split `dim` and read emb CONTIGUOUSLY (coalesced), then simd_sum.
// Block=256 (8 warps → 8 rows/threadgroup). Replaces the 1-thread/row version
// whose adjacent threads read `dim`-apart (uncoalesced).
kernel void logit_gemv_f16_cg(
    device float*        logits [[buffer(0)]],
    device const half*   emb    [[buffer(1)]],
    device const float*  x      [[buffer(2)]],
    constant uint& vocab [[buffer(3)]],
    constant uint& dim   [[buffer(4)]],
    uint  tgid  [[threadgroup_position_in_grid]],
    uint  tiitg [[thread_position_in_threadgroup]],
    ushort sgitg [[simdgroup_index_in_threadgroup]],
    ushort tiisg [[thread_index_in_simdgroup]])
{
    threadgroup float xs[1280];
    for (uint d = tiitg; d < dim; d += 256) xs[d] = x[d];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    const uint v = tgid * 8 + sgitg;
    if (v >= vocab) return;
    device const half* row = emb + (ulong)v * dim;
    float acc = 0.0f;
    for (uint i = tiisg; i < dim; i += 32) acc += xs[i] * (float)row[i];
    acc = simd_sum(acc);
    if (tiisg == 0) logits[v] = acc;
}

// ── Q8_0 embedding (int8 weights + fp16 per-32-block scale) ─────────
// Halves embed_tokens memory (132→~70MB) vs F16; logit/lookup are our own
// kernels (no MPS), so Q8 bandwidth helps directly. Block = 32 (= one warp).
//   dequant w[v][d] = qs[v*dim + d] * scales[v*(dim/32) + d/32]

// logit GEMV (Q8): one simdgroup per vocab row, 32 lanes = one 32-block.
kernel void logit_gemv_q8(
    device float*        logits [[buffer(0)]],
    device const char*   qs     [[buffer(1)]],
    device const half*   scales [[buffer(2)]],
    device const float*  x      [[buffer(3)]],
    constant uint& vocab [[buffer(4)]],
    constant uint& dim   [[buffer(5)]],
    uint  tgid  [[threadgroup_position_in_grid]],
    uint  tiitg [[thread_position_in_threadgroup]],
    ushort sgitg [[simdgroup_index_in_threadgroup]],
    ushort tiisg [[thread_index_in_simdgroup]])
{
    threadgroup float xs[1280];
    for (uint d = tiitg; d < dim; d += 256) xs[d] = x[d];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    const uint v = tgid * 8 + sgitg;
    if (v >= vocab) return;
    const uint nb = dim / 32;
    device const char* qrow = qs + (ulong)v * dim;
    device const half* srow = scales + (ulong)v * nb;
    float acc = 0.0f;
    for (uint b = 0; b < nb; b++) {
        const uint d = b * 32 + tiisg;
        acc += xs[d] * ((float)qrow[d] * (float)srow[b]);
    }
    acc = simd_sum(acc);
    if (tiisg == 0) logits[v] = acc;
}

// emb lookup (Q8), indirect: out[d] = dequant(qs[tokens[*pos]][d])
kernel void emb_lookup_indirect_q8(
    device float*        out_buf [[buffer(0)]],
    device const char*   qs      [[buffer(1)]],
    device const half*   scales  [[buffer(2)]],
    device const uint*   tokens  [[buffer(3)]],
    device const uint*   pos_ptr [[buffer(4)]],
    constant uint& dim [[buffer(5)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= dim) return;
    const uint tok = tokens[pos_ptr[0]];
    const uint nb = dim / 32;
    out_buf[gid] = (float)qs[(ulong)tok * dim + gid] * (float)scales[(ulong)tok * nb + gid / 32];
}

// emb lookup (Q8), direct token pointer (seed phase).
kernel void gpu_emb_lookup_q8(
    device float*        out_buf [[buffer(0)]],
    device const char*   qs      [[buffer(1)]],
    device const half*   scales  [[buffer(2)]],
    device const uint*   tok_ptr [[buffer(3)]],
    constant uint& dim [[buffer(4)]],
    uint ltid [[thread_position_in_threadgroup]])
{
    const uint tok = tok_ptr[0];
    const uint nb = dim / 32;
    device const char* qrow = qs + (ulong)tok * dim;
    device const half* srow = scales + (ulong)tok * nb;
    for (uint d = ltid; d < dim; d += 256) out_buf[d] = (float)qrow[d] * (float)srow[d / 32];
}

// gemv_q8 — general single-token GEMV with Q8_0 weights stored [N][K] (out-major,
// = original safetensors [out][in], NOT transposed). out[n] = Σ_k x[k]·deq(w[n][k]).
// One simdgroup per output row n; 32 lanes split K in 32-blocks (coalesced int8),
// simd_sum. int8 weights → 1/4 the F32 weight bandwidth. (No x cache: x is tiny
// for M=1 and broadcast-cached.)
kernel void gemv_q8(
    device float*        out_buf [[buffer(0)]],
    device const char*   qs      [[buffer(1)]],
    device const half*   scales  [[buffer(2)]],
    device const float*  x       [[buffer(3)]],
    constant uint& N [[buffer(4)]],
    constant uint& K [[buffer(5)]],
    uint  tgid  [[threadgroup_position_in_grid]],
    ushort sgitg [[simdgroup_index_in_threadgroup]],
    ushort tiisg [[thread_index_in_simdgroup]])
{
    const uint n = tgid * 8 + sgitg;
    if (n >= N) return;
    const uint nb = K / 32;
    device const char* qrow = qs + (ulong)n * K;
    device const half* srow = scales + (ulong)n * nb;
    float acc = 0.0f;
    for (uint b = 0; b < nb; b++) {
        const uint d = b * 32 + tiisg;
        acc += x[d] * ((float)qrow[d] * (float)srow[b]);
    }
    acc = simd_sum(acc);
    if (tiisg == 0) out_buf[n] = acc;
}
