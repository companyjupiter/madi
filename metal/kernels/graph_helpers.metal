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

// ts_rules_indirect — OpenAI timestamp-token decoding rules (whisper.cpp
// whisper_process_logits parity). <|notimestamps|> decoding collapses into
// repeat loops on hard audio (measured: clova 5/99 chunks "Q. Q. Q."×55, and
// whisper-cli -nt reproduces the identical collapse) — the <|t0|>…<|t1|>
// segment structure is the regularizer that prevents it. Rules:
//   R0 specials 50258..50364 never sampled; anti-loop ×3 ban; begin window
//   R1 first generated token must be a timestamp ≤ <|1.00|> (max_initial_ts)
//   R2 pairing: ts ts → next is text; (text) ts → next is ts or EOT
//   R3 non-decreasing: ban ts below the last sampled ts (+1 if pair closed)
//   R4 probability: if logsumexp(ts) > max(text) on the masked logits, the
//      segment boundary is more likely than any word → force a timestamp
//      (log-normalizer cancels, so raw logits compare directly)
// ONE threadgroup, Block=(256,1,1), Grid=(1,1,1).
kernel void ts_rules_indirect(
    device float*       logits        [[buffer(0)]],
    device const uint*  past_tokens   [[buffer(1)]],
    constant uint& num_suppress       [[buffer(2)]],
    device const uint*  step_ptr      [[buffer(3)]],
    constant uint& sample_begin       [[buffer(4)]],
    uint i [[thread_position_in_threadgroup]])
{
    (void)num_suppress;
    const float NEG = -3.4e38f;
    const uint EOT = 50257, TS0 = 50365;
    const uint step = step_ptr[0];

    // R0a: specials (sot/lang/task/notimestamps) are never sampled
    for (uint t = i + 50258; t < TS0; t += 256) logits[t] = NEG;
    // R0b: anti-loop — if the last 3 sampled tokens are equal, ban a 4th
    if (i == 0 && step >= sample_begin + 3) {
        uint t1 = past_tokens[step - 1];
        uint t2 = past_tokens[step - 2];
        uint t3 = past_tokens[step - 3];
        if (t1 == t2 && t2 == t3) logits[t1] = NEG;
    }
    // R0c: begin window — ban EOT + space for the first 4 generated steps
    if (step < sample_begin + 4) {
        if (i == 0) logits[220] = NEG;
        if (i == 1) logits[EOT] = NEG;
    }

    // R1-R3 flags — every thread derives them from the same uniform inputs
    bool last_ts  = step > sample_begin     && past_tokens[step - 1] >= TS0;
    bool pen_ts   = step > sample_begin + 1 && past_tokens[step - 2] >= TS0;
    uint last_val = 0;
    for (uint p = step; p > sample_begin; p--) {
        uint tk = past_tokens[p - 1];
        if (tk >= TS0) { last_val = tk; break; }
    }
    bool ban_text = false, ban_ts = false;
    uint ts_floor = TS0, ts_ceil = VOCAB;
    if (step == sample_begin) {
        ban_text = true;          // R1: first token is a timestamp…
        ts_ceil  = TS0 + 51;      // …no later than <|1.00|> (max_initial)
    } else if (last_ts && pen_ts) {
        ban_ts = true;            // R2: pair closed → text next
    } else if (last_ts) {
        ban_text = true;          // R2: close the pair (or EOT)
    }
    if (last_val >= TS0)
        ts_floor = (last_ts && !pen_ts) ? last_val : last_val + 1; // R3
    threadgroup_barrier(mem_flags::mem_device);
    if (ban_text) for (uint t = i; t < EOT; t += 256) logits[t] = NEG; // EOT stays legal
    if (ban_ts) {
        for (uint t = i + TS0; t < VOCAB; t += 256) logits[t] = NEG;
    } else {
        for (uint t = i + TS0; t < ts_floor; t += 256) logits[t] = NEG;
        for (uint t = i + ts_ceil; t < VOCAB; t += 256) logits[t] = NEG;
    }
    threadgroup_barrier(mem_flags::mem_device);

    // R4: timestamp-mass rule on the masked logits
    threadgroup float r_text[256], r_ts[256], r_sum[256];
    float mt = -INFINITY, ms = -INFINITY;
    for (uint t = i; t < TS0; t += 256) mt = max(mt, logits[t]);
    for (uint t = i + TS0; t < VOCAB; t += 256) ms = max(ms, logits[t]);
    r_text[i] = mt; r_ts[i] = ms;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = 128; s > 0; s >>= 1) {
        if (i < s) {
            r_text[i] = max(r_text[i], r_text[i + s]);
            r_ts[i]   = max(r_ts[i],   r_ts[i + s]);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    const float max_text = r_text[0], max_ts = r_ts[0];
    float se = 0.0f;
    if (max_ts > NEG * 0.5f) {
        for (uint t = i + TS0; t < VOCAB; t += 256) {
            float v = logits[t];
            if (v > NEG * 0.5f) se += exp(v - max_ts);
        }
    }
    r_sum[i] = se;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = 128; s > 0; s >>= 1) {
        if (i < s) r_sum[i] += r_sum[i + s];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    const float lse_ts = max_ts + log(r_sum[0] + 1e-30f);
    if (lse_ts > max_text) // OpenAI bans everything below TS0 here, EOT included
        for (uint t = i; t < TS0; t += 256) logits[t] = NEG;
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
    // vectorized char4/float4 (see gemv_q8). x cached in threadgroup → float4.
    const uint v = tgid * 8 + sgitg;
    if (v >= vocab) return;
    const uint kv = dim / 4;
    device const char4* q4 = (device const char4*)(qs + (ulong)v * dim);
    threadgroup const float4* xs4 = (threadgroup const float4*)xs;
    device const half* srow = scales + (ulong)v * (dim / 32);
    float acc = 0.0f;
    for (uint p = tiisg; p < kv; p += 32) {
        const char4  qv = q4[p];
        const float4 xv = xs4[p];
        const float  sc = (float)srow[p >> 3];
        acc += (xv.x * (float)qv.x + xv.y * (float)qv.y + xv.z * (float)qv.z + xv.w * (float)qv.w) * sc;
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
    // Vectorized (ggml mul_mv style): char4/float4 loads → 4-wide coalesced memory
    // transactions instead of 1 byte/thread. char4 at vec p covers elements
    // [p*4 .. p*4+3] (always within one 32-block since 32%4==0) → scale srow[p/8].
    const uint n = tgid * 8 + sgitg;
    if (n >= N) return;
    const uint kv = K / 4; // # of char4 / float4 along K
    device const char4*  q4 = (device const char4*)(qs + (ulong)n * K);
    device const float4* x4 = (device const float4*)x;
    device const half*   srow = scales + (ulong)n * (K / 32);
    float acc = 0.0f;
    for (uint p = tiisg; p < kv; p += 32) {
        const char4  qv = q4[p];
        const float4 xv = x4[p];
        const float  sc = (float)srow[p >> 3]; // 8 char4 per 32-block
        acc += (xv.x * (float)qv.x + xv.y * (float)qv.y + xv.z * (float)qv.z + xv.w * (float)qv.w) * sc;
    }
    acc = simd_sum(acc);
    if (tiisg == 0) out_buf[n] = acc;
}

// gemv_q8 with a fused bias epilogue (out[n] = Σ + bias[n]). Folds the separate
// bias_add dispatch into the GEMV — bit-exact (same single add), one fewer
// dispatch per projection. Used by the decode loop's cross-q / MLP GEMVs.
kernel void gemv_q8_bias(
    device float*        out_buf [[buffer(0)]],
    device const char*   qs      [[buffer(1)]],
    device const half*   scales  [[buffer(2)]],
    device const float*  x       [[buffer(3)]],
    device const float*  bias    [[buffer(4)]],
    constant uint& N [[buffer(5)]],
    constant uint& K [[buffer(6)]],
    uint  tgid  [[threadgroup_position_in_grid]],
    ushort sgitg [[simdgroup_index_in_threadgroup]],
    ushort tiisg [[thread_index_in_simdgroup]])
{
    const uint n = tgid * 8 + sgitg; // vectorized char4/float4 (see gemv_q8)
    if (n >= N) return;
    const uint kv = K / 4;
    device const char4*  q4 = (device const char4*)(qs + (ulong)n * K);
    device const float4* x4 = (device const float4*)x;
    device const half*   srow = scales + (ulong)n * (K / 32);
    float acc = 0.0f;
    for (uint p = tiisg; p < kv; p += 32) {
        const char4  qv = q4[p];
        const float4 xv = x4[p];
        const float  sc = (float)srow[p >> 3];
        acc += (xv.x * (float)qv.x + xv.y * (float)qv.y + xv.z * (float)qv.z + xv.w * (float)qv.w) * sc;
    }
    acc = simd_sum(acc);
    if (tiisg == 0) out_buf[n] = acc + bias[n];
}

// ── decode-path GEMV epilogue fusions (dispatch reduction) ───────────────
// Fold the per-output elementwise tail (gelu / residual) into the gemv's
// thread-0 write while the result is register-hot — removes a separate tiny
// full-grid kernel launch per layer (the decode is GPU-launch-latency-bound,
// ~80 kernels/token; gpu-sync is GPU exec, not CPU sync — measured). Output is
// BIT-IDENTICAL: (acc+bias) is the same f32, gelu input identical, residual is
// the same x + (acc+bias) add.
inline float gelu_erf32(float xv) { // EXACT copy of gelu_f32 (Abramowitz-Stegun)
    float z = xv * 0.7071067811865476f;
    float az = fabs(z);
    float sign = (z < 0.0f) ? -1.0f : 1.0f;
    float t = 1.0f / fma(az, 0.3275911f, 1.0f);
    float poly = fma(1.061405429f, t, -1.453152027f);
    poly = fma(poly, t, 1.421413741f);
    poly = fma(poly, t, -0.284496736f);
    poly = fma(poly, t, 0.254829592f);
    poly = poly * t;
    float ex = exp2(max(-az * az * 1.4426950408889634f, -80.0f));
    float erf = sign * (1.0f - poly * ex);
    return 0.5f * xv * (1.0f + erf);
}

kernel void gemv_q8_bias_gelu(
    device float* out_buf [[buffer(0)]], device const char* qs [[buffer(1)]],
    device const half* scales [[buffer(2)]], device const float* x [[buffer(3)]],
    device const float* bias [[buffer(4)]],
    constant uint& N [[buffer(5)]], constant uint& K [[buffer(6)]],
    uint tgid [[threadgroup_position_in_grid]], ushort sgitg [[simdgroup_index_in_threadgroup]],
    ushort tiisg [[thread_index_in_simdgroup]])
{
    const uint n = tgid * 8 + sgitg;
    if (n >= N) return;
    const uint kv = K / 4;
    device const char4* q4 = (device const char4*)(qs + (ulong)n * K);
    device const float4* x4 = (device const float4*)x;
    device const half* srow = scales + (ulong)n * (K / 32);
    float acc = 0.0f;
    for (uint p = tiisg; p < kv; p += 32) {
        const char4 qv = q4[p]; const float4 xv = x4[p]; const float sc = (float)srow[p >> 3];
        acc += (xv.x * (float)qv.x + xv.y * (float)qv.y + xv.z * (float)qv.z + xv.w * (float)qv.w) * sc;
    }
    acc = simd_sum(acc);
    if (tiisg == 0) out_buf[n] = gelu_erf32(acc + bias[n]);
}

kernel void gemv_q8_bias_res(
    device float* out_buf [[buffer(0)]], device const char* qs [[buffer(1)]],
    device const half* scales [[buffer(2)]], device const float* x [[buffer(3)]],
    device const float* bias [[buffer(4)]],
    constant uint& N [[buffer(5)]], constant uint& K [[buffer(6)]],
    uint tgid [[threadgroup_position_in_grid]], ushort sgitg [[simdgroup_index_in_threadgroup]],
    ushort tiisg [[thread_index_in_simdgroup]])
{
    const uint n = tgid * 8 + sgitg;
    if (n >= N) return;
    const uint kv = K / 4;
    device const char4* q4 = (device const char4*)(qs + (ulong)n * K);
    device const float4* x4 = (device const float4*)x;
    device const half* srow = scales + (ulong)n * (K / 32);
    float acc = 0.0f;
    for (uint p = tiisg; p < kv; p += 32) {
        const char4 qv = q4[p]; const float4 xv = x4[p]; const float sc = (float)srow[p >> 3];
        acc += (xv.x * (float)qv.x + xv.y * (float)qv.y + xv.z * (float)qv.z + xv.w * (float)qv.w) * sc;
    }
    acc = simd_sum(acc);
    if (tiisg == 0) out_buf[n] = out_buf[n] + acc + bias[n]; // residual fold
}

// ── fused decoder qkv: gemv + per-section bias + KV-store (5 kernels → 1) ──
// Self-attn projects xb→[q|k|v] (stacked [3D][D]), then q+=qb, v+=vb (k has no
// bias), and k,v are stored to the KV cache at pos. Folds gemv + kBias×2 +
// kStore×2 into one full-grid launch. BIT-IDENTICAL: q=acc+qb, k=acc (cache,
// no bias), v=acc+vb (cache) — identical to the unfused arithmetic. kAttn reads
// q from q_out and k,v from the cache, so the k|v stage buffer is never needed.
kernel void gemv_q8_qkv(
    device float*        q_out  [[buffer(0)]],  // s.q[0..D] (query + bias)
    device const char*   qs     [[buffer(1)]],
    device const half*   scales [[buffer(2)]],
    device const float*  x      [[buffer(3)]],  // xb
    device const float*  qb     [[buffer(4)]],  // q bias [D]
    device const float*  vb     [[buffer(5)]],  // v bias [D]
    device float*        kc     [[buffer(6)]],  // k cache
    device float*        vc     [[buffer(7)]],  // v cache
    device const uint*   pos_ptr[[buffer(8)]],
    constant uint& D [[buffer(9)]],             // head total dim (= gemv in-dim K)
    uint tgid [[threadgroup_position_in_grid]], ushort sgitg [[simdgroup_index_in_threadgroup]],
    ushort tiisg [[thread_index_in_simdgroup]])
{
    const uint n = tgid * 8 + sgitg;            // output index in [0, 3D)
    if (n >= 3 * D) return;
    const uint kv = D / 4;
    device const char4*  q4 = (device const char4*)(qs + (ulong)n * D);
    device const float4* x4 = (device const float4*)x;
    device const half*   srow = scales + (ulong)n * (D / 32);
    float acc = 0.0f;
    for (uint p = tiisg; p < kv; p += 32) {
        const char4 qv = q4[p]; const float4 xv = x4[p]; const float sc = (float)srow[p >> 3];
        acc += (xv.x * (float)qv.x + xv.y * (float)qv.y + xv.z * (float)qv.z + xv.w * (float)qv.w) * sc;
    }
    acc = simd_sum(acc);
    if (tiisg != 0) return;
    const uint pos = pos_ptr[0];
    if (n < D)          q_out[n] = acc + qb[n];                       // q + bias
    else if (n < 2 * D) kc[(ulong)pos * D + (n - D)] = acc;           // k → cache (no bias)
    else                vc[(ulong)pos * D + (n - 2 * D)] = acc + vb[n - 2 * D]; // v + bias → cache
}

// argmax + confidence (softmax prob of the chosen token) — token output is
// IDENTICAL to argmax_no_inc; conf[pos] = 1/Σexp(z_i − z_max) is added nearly
// free (one extra VOCAB pass; logits are 207KB vs the 66MB logit gemv that made
// them). Suppressed/filtered tokens are already −inf so they don't contribute.
kernel void argmax_conf(
    device const float* logits  [[buffer(0)]],
    device uint*        tokens   [[buffer(1)]],
    device float*       conf     [[buffer(2)]],
    device const uint*  pos_ptr  [[buffer(3)]],
    constant uint& max_len [[buffer(4)]],
    uint t_id [[thread_position_in_threadgroup]])
{
    threadgroup float sv[1024];
    threadgroup uint  si[1024];
    float local_max = -INFINITY; uint local_idx = 0;
    for (uint i = t_id; i < VOCAB; i += 1024) {
        float v = logits[i];
        if (v > local_max) { local_max = v; local_idx = i; }
    }
    sv[t_id] = local_max; si[t_id] = local_idx;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = 512; s > 0; s >>= 1) {
        if (t_id < s && sv[t_id + s] > sv[t_id]) { sv[t_id] = sv[t_id + s]; si[t_id] = si[t_id + s]; }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    const float zmax = sv[0];
    const uint  amax = si[0];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float lsum = 0.0f;
    for (uint i = t_id; i < VOCAB; i += 1024) lsum += exp(logits[i] - zmax);
    sv[t_id] = lsum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint s = 512; s > 0; s >>= 1) {
        if (t_id < s) sv[t_id] += sv[t_id + s];
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    if (t_id == 0) {
        uint cur = pos_ptr[0];
        if (cur < max_len) { tokens[cur] = amax; conf[cur] = 1.0f / sv[0]; }
    }
}
