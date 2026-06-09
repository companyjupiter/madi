// decoder_ops.metal — ports of the decoder PTX kernels:
//   gpu_ops_root_backup.ptx → gpu_residual, gpu_emb_lookup, gpu_kv_store,
//                             gpu_attention (dense autoregressive self-attn)
//   flash_cross_attn.ptx     → flash_cross_attn
//
// Decoder is single-token (B=1); the big projections (Q/K/V/out/FFN) are GEMVs
// done via MPS matmul with M=1 (see decoder.zig). These kernels cover the
// non-GEMM ops. All F32.
//
// NOTE on gpu_attention: the CUDA kernel has a "corridor sparse" branch that
// only activates for cross-attention (pos>=1500). The decoder uses this kernel
// ONLY for self-attention (pos<1500), where that branch is a no-op — so this
// port implements the dense path. Cross-attention uses flash_cross_attn.
#include <metal_stdlib>
using namespace metal;

// gpu_residual(x, y, dim): x[i] += y[i]
kernel void gpu_residual(
    device float*       x [[buffer(0)]],
    device const float* y [[buffer(1)]],
    constant uint& dim [[buffer(2)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= dim) return;
    x[gid] += y[gid];
}

// gpu_emb_lookup(out, emb, tok_ptr, dim): out[i] = emb[(*tok_ptr)*dim + i]
// 1 threadgroup, 256 threads. tok id is read from GPU memory.
kernel void gpu_emb_lookup(
    device float*        out_buf [[buffer(0)]],
    device const half*   emb     [[buffer(1)]],
    device const uint*   tok_ptr [[buffer(2)]],
    constant uint& dim [[buffer(3)]],
    uint ltid [[thread_position_in_threadgroup]])
{
    uint tok = tok_ptr[0];
    device const half* row = emb + (ulong)tok * dim;
    for (uint i = ltid; i < dim; i += 256) out_buf[i] = float(row[i]);
}

// gpu_kv_store(cache, src, kvd, pos_ptr): cache[(*pos)*kvd + i] = src[i]
kernel void gpu_kv_store(
    device float*        cache   [[buffer(0)]],
    device const float*  src     [[buffer(1)]],
    constant uint& kvd [[buffer(2)]],
    device const uint*   pos_ptr [[buffer(3)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= kvd) return;
    uint pos = pos_ptr[0];
    cache[(ulong)pos * kvd + gid] = src[gid];
}

// Block-wide reduction helpers (256 threads = 8 simdgroups of 32).
inline float block_max(threadgroup float* s8, float v, uint ltid) {
    v = max(v, simd_shuffle_xor(v, 16));
    v = max(v, simd_shuffle_xor(v, 8));
    v = max(v, simd_shuffle_xor(v, 4));
    v = max(v, simd_shuffle_xor(v, 2));
    v = max(v, simd_shuffle_xor(v, 1));
    if ((ltid & 31) == 0) s8[ltid >> 5] = v;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float r = s8[0];
    for (uint i = 1; i < 8; i++) r = max(r, s8[i]);
    return r;
}
inline float block_sum(threadgroup float* s8, float v, uint ltid) {
    v += simd_shuffle_xor(v, 16);
    v += simd_shuffle_xor(v, 8);
    v += simd_shuffle_xor(v, 4);
    v += simd_shuffle_xor(v, 2);
    v += simd_shuffle_xor(v, 1);
    if ((ltid & 31) == 0) s8[ltid >> 5] = v;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float r = 0.0f;
    for (uint i = 0; i < 8; i++) r += s8[i];
    return r;
}

// gpu_attention: dense autoregressive self-attention, query = 1 token.
// Grid=(nh,1,1) Block=(256,1,1). Attends positions 0..pos inclusive.
// kc/vc layout: [t][kvd], head h reads [t*kvd + kvh*hdd .. +hdd], kvh=h*nkv/nh.
// score scaled by rsqrt(hdd). MAX self-attn length = 448 (MAX_TOK).
kernel void gpu_attention(
    device float*       out_buf [[buffer(0)]],
    device const float* q_buf   [[buffer(1)]],
    device const float* kc      [[buffer(2)]],
    device const float* vc      [[buffer(3)]],
    device const uint*  pos_ptr [[buffer(4)]],
    constant uint& hdd [[buffer(5)]],
    constant uint& kvd [[buffer(6)]],
    constant uint& nkv [[buffer(7)]],
    constant uint& nh  [[buffer(8)]],
    uint tgid [[threadgroup_position_in_grid]],
    uint ltid [[thread_position_in_threadgroup]])
{
    threadgroup float scores[512];
    threadgroup float s8[8];
    threadgroup float s_part[256]; // output partials: 64 dims × 4 t-partitions
    const uint h = tgid;
    const uint pos = pos_ptr[0];
    const uint posP1 = pos + 1;
    const uint kvh = (h * nkv) / nh;
    const float rsq = rsqrt((float)hdd);
    const float LOG2E = 1.4426950408889634f;

    // Phase 1: scores[t] = dot(q_h, kc_t) * rsq
    for (uint t = ltid; t < posP1; t += 256) {
        float sum = 0.0f;
        for (uint d = 0; d < hdd; d++) {
            sum += q_buf[h * hdd + d] * kc[(ulong)t * kvd + kvh * hdd + d];
        }
        scores[t] = sum * rsq;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Phase 2: softmax over [0,posP1)
    float lmax = -INFINITY;
    for (uint t = ltid; t < posP1; t += 256) lmax = max(lmax, scores[t]);
    float mx = block_max(s8, lmax, ltid);
    threadgroup_barrier(mem_flags::mem_threadgroup);

    float lsum = 0.0f;
    for (uint t = ltid; t < posP1; t += 256) {
        float e = exp2((scores[t] - mx) * LOG2E);
        scores[t] = e;
        lsum += e;
    }
    float ssum = block_sum(s8, lsum, ltid);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float inv = 1.0f / ssum;
    for (uint t = ltid; t < posP1; t += 256) scores[t] *= inv;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    // Phase 3: out[h*hdd+d] = Σ_t scores[t]·vc_t[d]. All 256 threads = 64 dims ×
    // 4 t-partitions (integer-divided range covers any posP1), then reduce.
    const uint od = ltid & 63;
    const uint op = ltid >> 6;
    const uint t0 = (op * posP1) / 4;
    const uint t1 = ((op + 1) * posP1) / 4;
    float psum = 0.0f;
    for (uint t = t0; t < t1; t++)
        psum += scores[t] * vc[(ulong)t * kvd + kvh * hdd + od];
    s_part[op * 64 + od] = psum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (op == 0)
        out_buf[h * hdd + od] = (s_part[od] + s_part[64 + od]) + (s_part[128 + od] + s_part[192 + od]);
}

// extract_ca_head: recompute cross-attn softmax for ONE alignment head and
// accumulate the (inv_n-weighted) attention row into ca[tok][*]. Used to build
// the averaged alignment map for word-level timestamps.
// Grid=(1,1,1) Block=(256,1,1).
kernel void extract_ca_head(
    device const float* q       [[buffer(0)]], // cross Q [D]
    device const float* kc      [[buffer(1)]], // layer cross K [seqlen][kvd]
    device float*       ca      [[buffer(2)]], // [MAX_TOK][seqlen] accumulator
    device const uint*  tok_ptr [[buffer(3)]],
    constant uint&  head  [[buffer(4)]],
    constant float& inv_n [[buffer(5)]],
    constant uint&  seqlen[[buffer(6)]],
    constant uint&  hdd   [[buffer(7)]],
    constant uint&  kvd   [[buffer(8)]],
    uint ltid [[thread_position_in_threadgroup]])
{
    threadgroup float sc[1504];
    threadgroup float s8[8];
    const uint tok = tok_ptr[0];
    const float rsq = rsqrt((float)hdd);
    const float LOG2E = 1.4426950408889634f;
    for (uint t = ltid; t < seqlen; t += 256) {
        float d = 0.0f;
        for (uint e = 0; e < hdd; e++) d += q[head * hdd + e] * kc[(ulong)t * kvd + head * hdd + e];
        sc[t] = d * rsq;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float lmax = -INFINITY;
    for (uint t = ltid; t < seqlen; t += 256) lmax = max(lmax, sc[t]);
    float mx = block_max(s8, lmax, ltid);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float lsum = 0.0f;
    for (uint t = ltid; t < seqlen; t += 256) { float e = exp2((sc[t] - mx) * LOG2E); sc[t] = e; lsum += e; }
    float ssum = block_sum(s8, lsum, ltid);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float inv = inv_n / ssum;
    device float* row = ca + (ulong)tok * seqlen;
    for (uint t = ltid; t < seqlen; t += 256) row[t] += sc[t] * inv;
}

// flash_cross_attn: decoder cross-attention over `seqlen` encoder positions.
// Grid=(nh,1,1) Block=(256,1,1). Online softmax in shared memory.
// (The CUDA port hardcoded seqlen=1500; here it's an explicit param.)
kernel void flash_cross_attn(
    device float*       out_buf [[buffer(0)]],
    device const float* q_buf   [[buffer(1)]],
    device const float* kc      [[buffer(2)]],
    device const float* vc      [[buffer(3)]],
    constant uint& seqlen [[buffer(4)]],
    constant uint& hdd    [[buffer(5)]],
    constant uint& kvd    [[buffer(6)]],
    constant uint& nkv    [[buffer(7)]],
    constant uint& nh     [[buffer(8)]],
    uint tgid [[threadgroup_position_in_grid]],
    uint ltid [[thread_position_in_threadgroup]])
{
    threadgroup float scores[1504];
    threadgroup float s8[8];
    const uint h = tgid;
    const uint kvh = (h * nkv) / nh;
    const float rsq = rsqrt((float)hdd);
    const float LOG2E = 1.4426950408889634f;

    for (uint t = ltid; t < seqlen; t += 256) {
        float sum = 0.0f;
        for (uint d = 0; d < hdd; d++) {
            sum += q_buf[h * hdd + d] * kc[(ulong)t * kvd + kvh * hdd + d];
        }
        scores[t] = sum * rsq;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    float lmax = -INFINITY;
    for (uint t = ltid; t < seqlen; t += 256) lmax = max(lmax, scores[t]);
    float mx = block_max(s8, lmax, ltid);
    threadgroup_barrier(mem_flags::mem_threadgroup);

    float lsum = 0.0f;
    for (uint t = ltid; t < seqlen; t += 256) {
        float e = exp2((scores[t] - mx) * LOG2E);
        scores[t] = e;
        lsum += e;
    }
    float ssum = block_sum(s8, lsum, ltid);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float inv = 1.0f / ssum;
    for (uint t = ltid; t < seqlen; t += 256) scores[t] *= inv;
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint d = ltid; d < hdd; d += 256) {
        float sum = 0.0f;
        for (uint t = 0; t < seqlen; t++) {
            sum += scores[t] * vc[(ulong)t * kvd + kvh * hdd + d];
        }
        out_buf[h * hdd + d] = sum;
    }
}

// ── F16 K/V-cache variants (decoder cross-attention) ────────────────
// Query stays F32 (decoder activations are F32); K/V cache is F16 → halves the
// dominant read (1500 keys × 20 heads). Used only by the transcribe decoder;
// the F32 flash_cross_attn / extract_ca_head above stay for the tests.

kernel void flash_cross_attn_f16kv(
    device float*       out_buf [[buffer(0)]],
    device const float* q_buf   [[buffer(1)]],
    device const half*  kc      [[buffer(2)]],
    device const half*  vc      [[buffer(3)]],
    constant uint& seqlen [[buffer(4)]],
    constant uint& hdd    [[buffer(5)]],
    constant uint& kvd    [[buffer(6)]],
    constant uint& nkv    [[buffer(7)]],
    constant uint& nh     [[buffer(8)]],
    uint tgid [[threadgroup_position_in_grid]],
    uint ltid [[thread_position_in_threadgroup]])
{
    threadgroup float scores[1504];
    threadgroup float s8[8];
    threadgroup float s_part[256]; // output partials: 64 dims × 4 t-partitions
    threadgroup float s_qh[64];    // query head cached once (was re-read per t)
    const uint h = tgid;
    const uint kvh = (h * nkv) / nh;
    const float rsq = rsqrt((float)hdd);
    const float LOG2E = 1.4426950408889634f;

    // cache this head's query (64 floats) once, then vectorized half4 QK dot
    for (uint d = ltid; d < hdd; d += 256) s_qh[d] = q_buf[h * hdd + d];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    threadgroup const float4* q4 = (threadgroup const float4*)s_qh;
    const uint d4n = hdd >> 2;
    for (uint t = ltid; t < seqlen; t += 256) {
        device const half4* k4 = (device const half4*)(kc + (ulong)t * kvd + kvh * hdd);
        float sum = 0.0f;
        for (uint i = 0; i < d4n; i++) {
            const half4 kv = k4[i];
            const float4 qv = q4[i];
            sum += qv.x * (float)kv.x + qv.y * (float)kv.y + qv.z * (float)kv.z + qv.w * (float)kv.w;
        }
        scores[t] = sum * rsq;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float lmax = -INFINITY;
    for (uint t = ltid; t < seqlen; t += 256) lmax = max(lmax, scores[t]);
    float mx = block_max(s8, lmax, ltid);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float lsum = 0.0f;
    for (uint t = ltid; t < seqlen; t += 256) { float e = exp2((scores[t] - mx) * LOG2E); scores[t] = e; lsum += e; }
    float ssum = block_sum(s8, lsum, ltid);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float inv = 1.0f / ssum;
    for (uint t = ltid; t < seqlen; t += 256) scores[t] *= inv;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    // Output (scores·V): use ALL 256 threads = 64 dims × 4 t-partitions (was 64
    // active threads each summing all seqlen). Each (d,part) sums its quarter,
    // then partition 0 reduces the 4 partials. hdd=64, seqlen%4==0 (1500→375).
    const uint od = ltid & 63;        // head dim 0..63
    const uint op = ltid >> 6;        // partition 0..3
    const uint t0 = (op * seqlen) / 4;
    const uint t1 = ((op + 1) * seqlen) / 4;
    float psum = 0.0f;
    for (uint t = t0; t < t1; t++)
        psum += scores[t] * (float)vc[(ulong)t * kvd + kvh * hdd + od];
    s_part[op * 64 + od] = psum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (op == 0)
        out_buf[h * hdd + od] = (s_part[od] + s_part[64 + od]) + (s_part[128 + od] + s_part[192 + od]);
}

kernel void extract_ca_head_f16kv(
    device const float* q       [[buffer(0)]],
    device const half*  kc      [[buffer(1)]],
    device float*       ca      [[buffer(2)]],
    device const uint*  tok_ptr [[buffer(3)]],
    constant uint&  head  [[buffer(4)]],
    constant float& inv_n [[buffer(5)]],
    constant uint&  seqlen[[buffer(6)]],
    constant uint&  hdd   [[buffer(7)]],
    constant uint&  kvd   [[buffer(8)]],
    uint ltid [[thread_position_in_threadgroup]])
{
    threadgroup float sc[1504];
    threadgroup float s8[8];
    threadgroup float s_qh[64]; // query head cached once
    const uint tok = tok_ptr[0];
    const float rsq = rsqrt((float)hdd);
    const float LOG2E = 1.4426950408889634f;
    for (uint e = ltid; e < hdd; e += 256) s_qh[e] = q[head * hdd + e];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    threadgroup const float4* q4 = (threadgroup const float4*)s_qh;
    const uint d4n = hdd >> 2;
    for (uint t = ltid; t < seqlen; t += 256) {
        device const half4* k4 = (device const half4*)(kc + (ulong)t * kvd + head * hdd);
        float d = 0.0f;
        for (uint i = 0; i < d4n; i++) {
            const half4 kv = k4[i];
            const float4 qv = q4[i];
            d += qv.x * (float)kv.x + qv.y * (float)kv.y + qv.z * (float)kv.z + qv.w * (float)kv.w;
        }
        sc[t] = d * rsq;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float lmax = -INFINITY;
    for (uint t = ltid; t < seqlen; t += 256) lmax = max(lmax, sc[t]);
    float mx = block_max(s8, lmax, ltid);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float lsum = 0.0f;
    for (uint t = ltid; t < seqlen; t += 256) { float e = exp2((sc[t] - mx) * LOG2E); sc[t] = e; lsum += e; }
    float ssum = block_sum(s8, lsum, ltid);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float inv = inv_n / ssum;
    device float* row = ca + (ulong)tok * seqlen;
    for (uint t = ltid; t < seqlen; t += 256) row[t] += sc[t] * inv;
}
