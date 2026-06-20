// encoder_ops.metal — ports of the encoder PTX kernels:
//   layer_norm.ptx        → layer_norm
//   bias_res_ln.ptx       → bias_res_ln
//   flash_attention_enc.ptx → flash_attention_enc
//   whisper_kernels.ptx   → gelu_f32 (erf-based), bias_add
//
// All F32 (the Metal port keeps the encoder in F32 and uses MPS for the big
// GEMMs, so no f16 conversion is needed — see PORT.md).
#include <metal_stdlib>
using namespace metal;

// ── layer_norm(X,Y,gamma,beta,D,eps) ────────────────────────────────
// Grid=(rows,1,1) Block=(256,1,1). One threadgroup normalizes one row of D.
kernel void layer_norm(
    device const float* X     [[buffer(0)]],
    device float*       Y     [[buffer(1)]],
    device const float* gamma [[buffer(2)]],
    device const float* beta  [[buffer(3)]],
    constant uint&  D   [[buffer(4)]],
    constant float& eps [[buffer(5)]],
    uint  row  [[threadgroup_position_in_grid]],
    uint  tid  [[thread_position_in_threadgroup]],
    uint  ntid [[threads_per_threadgroup]])
{
    threadgroup float sh[256];
    device const float* px = X + (ulong)row * D;
    device float*       py = Y + (ulong)row * D;

    // mean
    float acc = 0.0f;
    for (uint i = tid; i < D; i += ntid) acc += px[i];
    sh[tid] = acc;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid == 0) {
        float s = 0.0f;
        for (uint i = 0; i < ntid; i++) s += sh[i];
        sh[0] = s / (float)D;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float mean = sh[0];
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // variance
    acc = 0.0f;
    for (uint i = tid; i < D; i += ntid) {
        float d = px[i] - mean;
        acc += d * d;
    }
    sh[tid] = acc;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid == 0) {
        float s = 0.0f;
        for (uint i = 0; i < ntid; i++) s += sh[i];
        sh[0] = rsqrt(s / (float)D + eps);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float inv = sh[0];

    // normalize + affine
    for (uint i = tid; i < D; i += ntid) {
        float v = (px[i] - mean) * inv;
        py[i] = v * gamma[i] + beta[i];
    }
}

// ── bias_res_ln(X,MO,bias,Y,gamma,beta,D,eps) ───────────────────────
// X[i] += MO[i] + bias[i]  (in place), then layer-norm(X) → Y.
// Grid=(rows,1,1) Block=(256,1,1). bias is 1D (no row offset).
kernel void bias_res_ln(
    device float*       X     [[buffer(0)]],
    device const float* MO    [[buffer(1)]],
    device const float* bias  [[buffer(2)]],
    device float*       Y     [[buffer(3)]],
    device const float* gamma [[buffer(4)]],
    device const float* beta  [[buffer(5)]],
    constant uint&  D   [[buffer(6)]],
    constant float& eps [[buffer(7)]],
    uint  row  [[threadgroup_position_in_grid]],
    uint  tid  [[thread_position_in_threadgroup]],
    uint  ntid [[threads_per_threadgroup]])
{
    threadgroup float sh[256];
    device float*       px  = X  + (ulong)row * D;
    device const float* pmo = MO + (ulong)row * D;
    device float*       py  = Y  + (ulong)row * D;

    // residual + bias, in place into X
    for (uint i = tid; i < D; i += ntid) {
        px[i] = px[i] + pmo[i] + bias[i];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    float acc = 0.0f;
    for (uint i = tid; i < D; i += ntid) acc += px[i];
    sh[tid] = acc;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid == 0) {
        float s = 0.0f;
        for (uint i = 0; i < ntid; i++) s += sh[i];
        sh[0] = s / (float)D;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float mean = sh[0];
    threadgroup_barrier(mem_flags::mem_threadgroup);

    acc = 0.0f;
    for (uint i = tid; i < D; i += ntid) {
        float d = px[i] - mean;
        acc += d * d;
    }
    sh[tid] = acc;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid == 0) {
        float s = 0.0f;
        for (uint i = 0; i < ntid; i++) s += sh[i];
        sh[0] = rsqrt(s / (float)D + eps);
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float inv = sh[0];

    for (uint i = tid; i < D; i += ntid) {
        float v = (px[i] - mean) * inv;
        py[i] = v * gamma[i] + beta[i];
    }
}

// ── bias_add(x, b, N, D): x[i] += b[i % D] ──────────────────────────
// Grid=ceil(N/256) Block=256.
kernel void bias_add(
    device float*       x [[buffer(0)]],
    device const float* b [[buffer(1)]],
    constant uint& N [[buffer(2)]],
    constant uint& D [[buffer(3)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= N) return;
    x[gid] += b[gid % D];
}

// ── gelu_f32(x, N): erf-based GELU, matches whisper_kernels.ptx ──────
// y = 0.5 x (1 + erf(x/sqrt2)) using the Abramowitz-Stegun erf poly.
kernel void gelu_f32(
    device float* x [[buffer(0)]],
    constant uint& N [[buffer(1)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= N) return;
    float xv = x[gid];
    float z = xv * 0.7071067811865476f; // 1/sqrt(2)
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
    x[gid] = 0.5f * xv * (1.0f + erf);
}

// ── flash_attention_enc (simdgroup-matrix / Apple "tensor" cores) ───
// Grid=(NH, ceil(seq/32), 1) Block=(128,1,1) = 4 simdgroups × 8 queries = 32
// queries/threadgroup. Adapted from the sovereign LLM flash_attn_prefill.metal
// (simdgroup_multiply_accumulate) for the Whisper encoder: hdd=64, F32,
// BIDIRECTIONAL (no causal mask), layout [seq][nh*64] (head stride = nh*64).
// QK^T and S·V run on the matrix coprocessor (8×8 tiles) instead of per-key
// warp-shuffle reductions. Online softmax with layout-agnostic diagonal rescale.
kernel void flash_attention_enc(
    device float*       out_buf [[buffer(0)]],
    device const float* q_buf   [[buffer(1)]],
    device const float* k_buf   [[buffer(2)]],
    device const float* v_buf   [[buffer(3)]],
    constant uint& seq_len [[buffer(4)]],
    constant uint& hdd     [[buffer(5)]],
    constant uint& nh      [[buffer(6)]],
    uint3 tgpig [[threadgroup_position_in_grid]],
    ushort tiitg [[thread_index_in_threadgroup]],
    ushort sgitg [[simdgroup_index_in_threadgroup]],
    ushort tiisg [[thread_index_in_simdgroup]])
{
    const uint h = tgpig.x;
    const uint q_start = tgpig.y * 32;
    if (q_start >= seq_len) return;
    const uint cur = min(seq_len, q_start + 32) - q_start; // valid queries
    const uint qd = nh * 64;          // row stride of q/k/v/out
    const uint hoff = h * 64;         // head column offset
    const float scale = 0.125f;       // 1/sqrt(64)

    threadgroup float s_q[32 * 64];      // 8KB
    threadgroup float s_sc[32 * 32];     // 4KB raw scores
    threadgroup float s_ex[32 * 32];     // 4KB exp(scores)
    threadgroup float s_O[32 * 64];      // 8KB output
    threadgroup float s_alpha[32];
    threadgroup float s_sum[32];

    // load Q tile [32][64] (zero-pad invalid query rows)
    for (uint e = tiitg; e < 32 * 64; e += 128) {
        const uint qr = e / 64, qc = e % 64;
        s_q[e] = (qr < cur) ? q_buf[(q_start + qr) * qd + hoff + qc] : 0.0f;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    const uint my_q = sgitg * 8; // this simdgroup's first query (0/8/16/24)
    simdgroup_float8x8 m_O[8];
    for (int i = 0; i < 8; i++) m_O[i] = make_filled_simdgroup_matrix<float, 8>(0.0f);
    float local_m[8], local_s[8];
    for (int i = 0; i < 8; i++) { local_m[i] = -INFINITY; local_s[i] = 0.0f; }

    for (uint kv0 = 0; kv0 < seq_len; kv0 += 32) {
        // QK^T → scores[8q][32k] via matrix units
        device const float* kbase = k_buf + (ulong)kv0 * qd + hoff;
        simdgroup_float8x8 mqk[4];
        for (int i = 0; i < 4; i++) mqk[i] = make_filled_simdgroup_matrix<float, 8>(0.0f);
        for (uint d = 0; d < 64; d += 8) {
            simdgroup_float8x8 mq;
            simdgroup_load(mq, s_q + my_q * 64 + d, 64);
            simdgroup_float8x8 mk;
            mk = simdgroup_float8x8(); simdgroup_load(mk, kbase + 0 * 8 * qd + d, qd, 0, true); simdgroup_multiply_accumulate(mqk[0], mq, mk, mqk[0]);
            mk = simdgroup_float8x8(); simdgroup_load(mk, kbase + 1 * 8 * qd + d, qd, 0, true); simdgroup_multiply_accumulate(mqk[1], mq, mk, mqk[1]);
            mk = simdgroup_float8x8(); simdgroup_load(mk, kbase + 2 * 8 * qd + d, qd, 0, true); simdgroup_multiply_accumulate(mqk[2], mq, mk, mqk[2]);
            mk = simdgroup_float8x8(); simdgroup_load(mk, kbase + 3 * 8 * qd + d, qd, 0, true); simdgroup_multiply_accumulate(mqk[3], mq, mk, mqk[3]);
        }
        simdgroup_store(mqk[0], s_sc + my_q * 32 + 0 * 8, 32);
        simdgroup_store(mqk[1], s_sc + my_q * 32 + 1 * 8, 32);
        simdgroup_store(mqk[2], s_sc + my_q * 32 + 2 * 8, 32);
        simdgroup_store(mqk[3], s_sc + my_q * 32 + 3 * 8, 32);
        threadgroup_barrier(mem_flags::mem_threadgroup);

        // online softmax (1 thread per query), bidirectional (mask only k>=seq)
        if (tiisg < 8) {
            const uint qi = my_q + tiisg;
            float bm = -INFINITY;
            float ev[32];
            for (int k = 0; k < 32; k++) {
                float s = -INFINITY;
                if (kv0 + (uint)k < seq_len) s = s_sc[qi * 32 + k] * scale;
                ev[k] = s; bm = max(bm, s);
            }
            const float old_m = local_m[tiisg];
            local_m[tiisg] = max(old_m, bm);
            const float alpha = (old_m == -INFINITY) ? 0.0f : exp(old_m - local_m[tiisg]);
            s_alpha[qi] = alpha;
            float bs = 0.0f;
            for (int k = 0; k < 32; k++) {
                float e = (ev[k] > -INFINITY) ? exp(ev[k] - local_m[tiisg]) : 0.0f;
                ev[k] = e; bs += e;
                s_ex[qi * 32 + k] = e;
            }
            local_s[tiisg] = local_s[tiisg] * alpha + bs;
            s_sum[qi] = local_s[tiisg];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        // rescale m_O by per-query alpha via diagonal matrix (layout-agnostic)
        threadgroup float* s_diag = s_sc; // free now
        if (tiisg < 8)
            for (int c = 0; c < 8; c++)
                s_diag[sgitg * 64 + tiisg * 8 + c] = (c == (int)tiisg) ? s_alpha[my_q + tiisg] : 0.0f;
        simdgroup_barrier(mem_flags::mem_threadgroup);
        simdgroup_float8x8 m_diag;
        simdgroup_load(m_diag, s_diag + sgitg * 64, 8);
        for (int i = 0; i < 8; i++) {
            simdgroup_float8x8 sc = make_filled_simdgroup_matrix<float, 8>(0.0f);
            simdgroup_multiply_accumulate(sc, m_diag, m_O[i], sc);
            m_O[i] = sc;
        }
        simdgroup_barrier(mem_flags::mem_threadgroup);

        // S·V → accumulate into m_O (8 dim-tiles of 8 = 64)
        device const float* vbase = v_buf + (ulong)kv0 * qd + hoff;
        for (int kb = 0; kb < 4; kb++) {
            simdgroup_float8x8 m_att;
            simdgroup_load(m_att, s_ex + my_q * 32 + kb * 8, 32);
            for (int vb = 0; vb < 8; vb++) {
                simdgroup_float8x8 mv;
                simdgroup_load(mv, vbase + kb * 8 * qd + vb * 8, qd);
                simdgroup_multiply_accumulate(m_O[vb], m_att, mv, m_O[vb]);
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    // write output: O / sum
    for (int i = 0; i < 8; i++) simdgroup_store(m_O[i], s_O + my_q * 64 + i * 8, 64);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint e = tiitg; e < 32 * 64; e += 128) {
        const uint qr = e / 64, qc = e % 64;
        if (qr < cur) {
            const float inv = 1.0f / (s_sum[qr] + 1e-6f);
            out_buf[(q_start + qr) * qd + hoff + qc] = s_O[e] * inv;
        }
    }
}

// ════════════════════════════════════════════════════════════════════
// F16 encoder variants — activations carried as half (GEMMs in F16 via MPS,
// attention via simdgroup_half8x8). Residual stream X stays F32 for stability;
// all reductions accumulate in float. Only the encoder uses these; the decoder
// and the CPU-verified F32 tests keep the F32 kernels above.
// ════════════════════════════════════════════════════════════════════

// layer_norm: X(f32) → Y(f16), affine f32. Grid=(rows) Block=256.
kernel void layer_norm_f16(
    device const float* X     [[buffer(0)]],
    device half*        Y     [[buffer(1)]],
    device const float* gamma [[buffer(2)]],
    device const float* beta  [[buffer(3)]],
    constant uint&  D   [[buffer(4)]],
    constant float& eps [[buffer(5)]],
    uint row [[threadgroup_position_in_grid]], uint tid [[thread_position_in_threadgroup]], uint ntid [[threads_per_threadgroup]])
{
    threadgroup float sh[256];
    device const float* px = X + (ulong)row * D;
    device half* py = Y + (ulong)row * D;
    float acc = 0.0f;
    for (uint i = tid; i < D; i += ntid) acc += px[i];
    sh[tid] = acc; threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid == 0) { float s = 0; for (uint i = 0; i < ntid; i++) s += sh[i]; sh[0] = s / (float)D; }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float mean = sh[0]; threadgroup_barrier(mem_flags::mem_threadgroup);
    acc = 0.0f;
    for (uint i = tid; i < D; i += ntid) { float d = px[i] - mean; acc += d * d; }
    sh[tid] = acc; threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid == 0) { float s = 0; for (uint i = 0; i < ntid; i++) s += sh[i]; sh[0] = rsqrt(s / (float)D + eps); }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float inv = sh[0];
    for (uint i = tid; i < D; i += ntid) py[i] = (half)((px[i] - mean) * inv * gamma[i] + beta[i]);
}

// bias_res_ln: X(f32) += MO(f16)+bias(f32) in place; then LN(X) → Y(f16).
kernel void bias_res_ln_f16(
    device float*       X     [[buffer(0)]],
    device const half*  MO    [[buffer(1)]],
    device const float* bias  [[buffer(2)]],
    device half*        Y     [[buffer(3)]],
    device const float* gamma [[buffer(4)]],
    device const float* beta  [[buffer(5)]],
    constant uint&  D   [[buffer(6)]],
    constant float& eps [[buffer(7)]],
    uint row [[threadgroup_position_in_grid]], uint tid [[thread_position_in_threadgroup]], uint ntid [[threads_per_threadgroup]])
{
    threadgroup float sh[256];
    device float*       px  = X  + (ulong)row * D;
    device const half*  pmo = MO + (ulong)row * D;
    device half*        py  = Y  + (ulong)row * D;
    for (uint i = tid; i < D; i += ntid) px[i] = px[i] + (float)pmo[i] + bias[i];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float acc = 0.0f;
    for (uint i = tid; i < D; i += ntid) acc += px[i];
    sh[tid] = acc; threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid == 0) { float s = 0; for (uint i = 0; i < ntid; i++) s += sh[i]; sh[0] = s / (float)D; }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float mean = sh[0]; threadgroup_barrier(mem_flags::mem_threadgroup);
    acc = 0.0f;
    for (uint i = tid; i < D; i += ntid) { float d = px[i] - mean; acc += d * d; }
    sh[tid] = acc; threadgroup_barrier(mem_flags::mem_threadgroup);
    if (tid == 0) { float s = 0; for (uint i = 0; i < ntid; i++) s += sh[i]; sh[0] = rsqrt(s / (float)D + eps); }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float inv = sh[0];
    for (uint i = tid; i < D; i += ntid) py[i] = (half)((px[i] - mean) * inv * gamma[i] + beta[i]);
}

// bias_add on f16 buffer with f32 bias.
kernel void bias_add_f16(
    device half*        x [[buffer(0)]],
    device const float* b [[buffer(1)]],
    constant uint& N [[buffer(2)]], constant uint& D [[buffer(3)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= N) return;
    x[gid] = (half)((float)x[gid] + b[gid % D]);
}

// erf-GELU on f16 buffer (compute in float).
kernel void gelu_f16(
    device half* x [[buffer(0)]], constant uint& N [[buffer(1)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= N) return;
    float xv = (float)x[gid];
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
    x[gid] = (half)(0.5f * xv * (1.0f + erf));
}

// flash_attention_enc F16: simdgroup_half8x8 inputs, float8x8 accumulators.
kernel void flash_attention_enc_f16(
    device half*        out_buf [[buffer(0)]],
    device const half*  q_buf   [[buffer(1)]],
    device const half*  k_buf   [[buffer(2)]],
    device const half*  v_buf   [[buffer(3)]],
    constant uint& seq_len [[buffer(4)]],
    constant uint& hdd     [[buffer(5)]],
    constant uint& nh      [[buffer(6)]],
    uint3 tgpig [[threadgroup_position_in_grid]],
    ushort tiitg [[thread_index_in_threadgroup]],
    ushort sgitg [[simdgroup_index_in_threadgroup]],
    ushort tiisg [[thread_index_in_simdgroup]])
{
    const uint h = tgpig.x;
    const uint q_start = tgpig.y * 32;
    if (q_start >= seq_len) return;
    const uint cur = min(seq_len, q_start + 32) - q_start;
    const uint qd = nh * 64;
    const uint hoff = h * 64;
    const float scale = 0.125f;

    threadgroup half  s_q[32 * 64];
    threadgroup float s_sc[32 * 32];
    threadgroup half  s_ex[32 * 32];
    threadgroup float s_O[32 * 64];
    threadgroup float s_alpha[32];
    threadgroup float s_sum[32];

    for (uint e = tiitg; e < 32 * 64; e += 128) {
        const uint qr = e / 64, qc = e % 64;
        s_q[e] = (qr < cur) ? q_buf[(q_start + qr) * qd + hoff + qc] : (half)0;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    const uint my_q = sgitg * 8;
    simdgroup_float8x8 m_O[8];
    for (int i = 0; i < 8; i++) m_O[i] = make_filled_simdgroup_matrix<float, 8>(0.0f);
    float local_m[8], local_s[8];
    for (int i = 0; i < 8; i++) { local_m[i] = -INFINITY; local_s[i] = 0.0f; }

    for (uint kv0 = 0; kv0 < seq_len; kv0 += 32) {
        device const half* kbase = k_buf + (ulong)kv0 * qd + hoff;
        simdgroup_float8x8 mqk[4];
        for (int i = 0; i < 4; i++) mqk[i] = make_filled_simdgroup_matrix<float, 8>(0.0f);
        for (uint d = 0; d < 64; d += 8) {
            simdgroup_half8x8 mq; simdgroup_load(mq, s_q + my_q * 64 + d, 64);
            simdgroup_half8x8 mk;
            mk = simdgroup_half8x8(); simdgroup_load(mk, kbase + 0 * 8 * qd + d, qd, 0, true); simdgroup_multiply_accumulate(mqk[0], mq, mk, mqk[0]);
            mk = simdgroup_half8x8(); simdgroup_load(mk, kbase + 1 * 8 * qd + d, qd, 0, true); simdgroup_multiply_accumulate(mqk[1], mq, mk, mqk[1]);
            mk = simdgroup_half8x8(); simdgroup_load(mk, kbase + 2 * 8 * qd + d, qd, 0, true); simdgroup_multiply_accumulate(mqk[2], mq, mk, mqk[2]);
            mk = simdgroup_half8x8(); simdgroup_load(mk, kbase + 3 * 8 * qd + d, qd, 0, true); simdgroup_multiply_accumulate(mqk[3], mq, mk, mqk[3]);
        }
        simdgroup_store(mqk[0], s_sc + my_q * 32 + 0 * 8, 32);
        simdgroup_store(mqk[1], s_sc + my_q * 32 + 1 * 8, 32);
        simdgroup_store(mqk[2], s_sc + my_q * 32 + 2 * 8, 32);
        simdgroup_store(mqk[3], s_sc + my_q * 32 + 3 * 8, 32);
        threadgroup_barrier(mem_flags::mem_threadgroup);

        if (tiisg < 8) {
            const uint qi = my_q + tiisg;
            float bm = -INFINITY; float ev[32];
            for (int k = 0; k < 32; k++) {
                float s = -INFINITY;
                if (kv0 + (uint)k < seq_len) s = s_sc[qi * 32 + k] * scale;
                ev[k] = s; bm = max(bm, s);
            }
            const float old_m = local_m[tiisg];
            local_m[tiisg] = max(old_m, bm);
            const float alpha = (old_m == -INFINITY) ? 0.0f : exp(old_m - local_m[tiisg]);
            s_alpha[qi] = alpha;
            float bs = 0.0f;
            for (int k = 0; k < 32; k++) {
                float e = (ev[k] > -INFINITY) ? exp(ev[k] - local_m[tiisg]) : 0.0f;
                bs += e; s_ex[qi * 32 + k] = (half)e;
            }
            local_s[tiisg] = local_s[tiisg] * alpha + bs;
            s_sum[qi] = local_s[tiisg];
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        threadgroup float* s_diag = s_sc;
        if (tiisg < 8)
            for (int c = 0; c < 8; c++)
                s_diag[sgitg * 64 + tiisg * 8 + c] = (c == (int)tiisg) ? s_alpha[my_q + tiisg] : 0.0f;
        simdgroup_barrier(mem_flags::mem_threadgroup);
        simdgroup_float8x8 m_diag; simdgroup_load(m_diag, s_diag + sgitg * 64, 8);
        for (int i = 0; i < 8; i++) {
            simdgroup_float8x8 sc = make_filled_simdgroup_matrix<float, 8>(0.0f);
            simdgroup_multiply_accumulate(sc, m_diag, m_O[i], sc);
            m_O[i] = sc;
        }
        simdgroup_barrier(mem_flags::mem_threadgroup);

        device const half* vbase = v_buf + (ulong)kv0 * qd + hoff;
        for (int kb = 0; kb < 4; kb++) {
            simdgroup_half8x8 m_att; simdgroup_load(m_att, s_ex + my_q * 32 + kb * 8, 32);
            for (int vb = 0; vb < 8; vb++) {
                simdgroup_half8x8 mv; simdgroup_load(mv, vbase + kb * 8 * qd + vb * 8, qd);
                simdgroup_multiply_accumulate(m_O[vb], m_att, mv, m_O[vb]);
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    for (int i = 0; i < 8; i++) simdgroup_store(m_O[i], s_O + my_q * 64 + i * 8, 64);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint e = tiitg; e < 32 * 64; e += 128) {
        const uint qr = e / 64, qc = e % 64;
        if (qr < cur) {
            const float inv = 1.0f / (s_sum[qr] + 1e-6f);
            out_buf[(q_start + qr) * qd + hoff + qc] = (half)(s_O[e] * inv);
        }
    }
}

// f16 → f32 elementwise copy (encoder F16 output → F32 enc_out for the F32 decoder).
kernel void cvt_f16_f32(
    device float*      dst [[buffer(0)]],
    device const half* src [[buffer(1)]],
    constant uint& n [[buffer(2)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= n) return;
    dst[gid] = (float)src[gid];
}

// f32 → f16 elementwise copy (multi-chunk batched decode: F32 residual stream →
// F16 for the batched projection GEMMs (matmulF16Batched takes half activations)).
kernel void cvt_f32_f16(
    device half*        dst [[buffer(0)]],
    device const float* src [[buffer(1)]],
    constant uint& n [[buffer(2)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= n) return;
    dst[gid] = (half)src[gid];
}
