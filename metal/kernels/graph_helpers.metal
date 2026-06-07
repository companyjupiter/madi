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
