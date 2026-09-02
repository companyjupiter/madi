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
    device float*       sc_out  [[buffer(9)]],  // [nh][seqlen] normalized scores (for ca_accumulate)
    constant uint&      write_sc [[buffer(10)]], // 1 → write sc_out (only layers w/ align heads)
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
    // publish this head's normalized scores so ca_accumulate can fold the
    // alignment heads into the word-timestamp map — no QK/softmax recompute.
    if (write_sc) {
        device float* sr = sc_out + (ulong)h * seqlen;
        for (uint t = ltid; t < seqlen; t += 256) sr[t] = scores[t];
    }
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

// ── SPLIT cross-attention (flash-decoding, 2026-07-05) ──────────────────────
// The monolithic kernel runs ONE threadgroup per head = 20 TGs — the GPU is
// ~19% occupied (measured 52 GB/s effective vs 273 peak; D1/D2 established the
// decode is occupancy/latency-bound, not bandwidth-bound). Split the seqlen
// into `nsplit` chunks — grid nh×nsplit TGs — each computing a PARTIAL flash
// (per-chunk max m, exp-sum s, unnormalized output o = Σe·v); a second tiny
// kernel recombines exactly via log-sum-exp. Same math, reassociated FP.
//
// Alignment layers (write_sc=1) write RAW scores in pass 1; pass 2 normalizes
// them in place with the global (m, s) so ca_accumulate sees identical
// normalized rows.
kernel void flash_cross_attn_split(
    device float*       part    [[buffer(0)]],  // [nh][nsplit][2+hdd]: m, s, o[hdd]
    device const float* q_buf   [[buffer(1)]],
    device const half*  kc      [[buffer(2)]],
    device const half*  vc      [[buffer(3)]],
    constant uint& seqlen [[buffer(4)]],
    constant uint& hdd    [[buffer(5)]],
    constant uint& kvd    [[buffer(6)]],
    constant uint& nkv    [[buffer(7)]],
    constant uint& nh     [[buffer(8)]],
    constant uint& nsplit [[buffer(9)]],
    device float*       sc_raw  [[buffer(10)]], // [nh][seqlen] RAW scores (write_sc)
    constant uint&      write_sc [[buffer(11)]],
    uint tgid [[threadgroup_position_in_grid]],
    uint ltid [[thread_position_in_threadgroup]])
{
    threadgroup float scores[192];  // chunk ≤ ceil(1500/8)=188
    threadgroup float s8[8];
    threadgroup float s_part[256];
    threadgroup float s_qh[64];
    const uint h = tgid / nsplit;
    const uint c = tgid % nsplit;
    const uint csz = (seqlen + nsplit - 1) / nsplit;
    const uint t0 = c * csz;
    const uint t1 = min(t0 + csz, seqlen);
    device float* my = part + ((ulong)h * nsplit + c) * (2 + hdd);
    if (t0 >= t1) {                       // empty tail chunk (tiny seqlen)
        if (ltid == 0) { my[0] = -INFINITY; my[1] = 0.0f; }
        for (uint d = ltid; d < hdd; d += 256) my[2 + d] = 0.0f;
        return;
    }
    const uint kvh = (h * nkv) / nh;
    const float rsq = rsqrt((float)hdd);
    const float LOG2E = 1.4426950408889634f;
    for (uint d = ltid; d < hdd; d += 256) s_qh[d] = q_buf[h * hdd + d];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    threadgroup const float4* q4 = (threadgroup const float4*)s_qh;
    const uint d4n = hdd >> 2;
    for (uint t = t0 + ltid; t < t1; t += 256) {
        device const half4* k4 = (device const half4*)(kc + (ulong)t * kvd + kvh * hdd);
        float sum = 0.0f;
        for (uint i = 0; i < d4n; i++) {
            const half4 kv = k4[i];
            const float4 qv = q4[i];
            sum += qv.x * (float)kv.x + qv.y * (float)kv.y + qv.z * (float)kv.z + qv.w * (float)kv.w;
        }
        const float sc = sum * rsq;
        scores[t - t0] = sc;
        if (write_sc) sc_raw[(ulong)h * seqlen + t] = sc;  // raw — pass 2 normalizes
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    const uint n = t1 - t0;
    float lmax = -INFINITY;
    for (uint t = ltid; t < n; t += 256) lmax = max(lmax, scores[t]);
    float mx = block_max(s8, lmax, ltid);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float lsum = 0.0f;
    for (uint t = ltid; t < n; t += 256) { float e = exp2((scores[t] - mx) * LOG2E); scores[t] = e; lsum += e; }
    float ssum = block_sum(s8, lsum, ltid);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    // unnormalized partial output: 64 dims × 4 t-partitions over the chunk
    const uint od = ltid & 63;
    const uint op = ltid >> 6;
    const uint p0 = (op * n) / 4;
    const uint p1 = ((op + 1) * n) / 4;
    float psum = 0.0f;
    for (uint t = p0; t < p1; t++)
        psum += scores[t] * (float)vc[(ulong)(t0 + t) * kvd + kvh * hdd + od];
    s_part[op * 64 + od] = psum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (op == 0) {
        my[2 + od] = (s_part[od] + s_part[64 + od]) + (s_part[128 + od] + s_part[192 + od]);
        if (od == 0) { my[0] = mx; my[1] = ssum; }
    }
}

// pass 2: log-sum-exp recombination of the partials (+ in-place score
// normalization for alignment layers). Grid = nh TGs.
kernel void flash_cross_attn_reduce(
    device float*       out_buf [[buffer(0)]],
    device const float* part    [[buffer(1)]],
    constant uint& hdd    [[buffer(2)]],
    constant uint& nsplit [[buffer(3)]],
    device float*       sc_out  [[buffer(4)]],  // raw in / normalized out
    constant uint& seqlen [[buffer(5)]],
    constant uint& write_sc [[buffer(6)]],
    uint tgid [[threadgroup_position_in_grid]],
    uint ltid [[thread_position_in_threadgroup]])
{
    threadgroup float g2[2];   // [gm, gs]
    const uint h = tgid;
    const float LOG2E = 1.4426950408889634f;
    device const float* hp = part + (ulong)h * nsplit * (2 + hdd);
    if (ltid == 0) {
        float gm = -INFINITY;
        for (uint c = 0; c < nsplit; c++) gm = max(gm, hp[c * (2 + hdd)]);
        float gs = 0.0f;
        for (uint c = 0; c < nsplit; c++) {
            const float m = hp[c * (2 + hdd)];
            if (m > -INFINITY) gs += hp[c * (2 + hdd) + 1] * exp2((m - gm) * LOG2E);
        }
        g2[0] = gm; g2[1] = gs;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    const float gm = g2[0];
    const float inv = 1.0f / g2[1];
    for (uint d = ltid; d < hdd; d += 256) {
        float acc = 0.0f;
        for (uint c = 0; c < nsplit; c++) {
            const float m = hp[c * (2 + hdd)];
            if (m > -INFINITY) acc += hp[c * (2 + hdd) + 2 + d] * exp2((m - gm) * LOG2E);
        }
        out_buf[h * hdd + d] = acc * inv;
    }
    if (write_sc) {
        device float* sr = sc_out + (ulong)h * seqlen;
        for (uint t = ltid; t < seqlen; t += 256)
            sr[t] = exp2((sr[t] - gm) * LOG2E) * inv;
    }
}

// ── BATCHED cross-attention (P5): B slots in ONE dispatch ───────────────────
// Multi-chunk batched decode runs B in-flight chunks; each attends to its OWN
// cross-KV. The per-slot kCA loop launches B low-occupancy dispatches (NH=20
// threadgroups each) — measured ~43% of batched-decode time, 6.8x off the KV
// bandwidth ceiling = occupancy-bound. This fills the GPU: grid = B*NH thread-
// groups, tgid → (slot b, head h). q/out contiguous [B][D]; kc/vc contiguous
// [B][seqlen][kvd]. No sc_out (batched path uses write_sc=0).
kernel void flash_cross_attn_f16kv_batched(
    device float*       out_buf [[buffer(0)]],   // [B][nh*hdd]
    device const float* q_buf   [[buffer(1)]],   // [B][nh*hdd]
    device const half*  kc      [[buffer(2)]],   // [B][seqlen][kvd]
    device const half*  vc      [[buffer(3)]],   // [B][seqlen][kvd]
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
    threadgroup float s_part[256];
    threadgroup float s_qh[64];
    const uint b = tgid / nh;
    const uint h = tgid % nh;
    const uint kvh = (h * nkv) / nh;
    const uint D = nh * hdd;
    const float rsq = rsqrt((float)hdd);
    const float LOG2E = 1.4426950408889634f;
    device const float* qb  = q_buf   + (ulong)b * D;
    device float*       ob  = out_buf + (ulong)b * D;
    device const half*  kcb = kc + (ulong)b * seqlen * kvd;
    device const half*  vcb = vc + (ulong)b * seqlen * kvd;

    for (uint d = ltid; d < hdd; d += 256) s_qh[d] = qb[h * hdd + d];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    threadgroup const float4* q4 = (threadgroup const float4*)s_qh;
    const uint d4n = hdd >> 2;
    for (uint t = ltid; t < seqlen; t += 256) {
        device const half4* k4 = (device const half4*)(kcb + (ulong)t * kvd + kvh * hdd);
        float sum = 0.0f;
        for (uint i = 0; i < d4n; i++) {
            const half4 kv = k4[i];
            const float4 qv = q4[i];
            sum += qv.x*(float)kv.x + qv.y*(float)kv.y + qv.z*(float)kv.z + qv.w*(float)kv.w;
        }
        scores[t] = sum * rsq;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float lmax = -INFINITY;
    for (uint t = ltid; t < seqlen; t += 256) lmax = max(lmax, scores[t]);
    float mx = block_max(s8, lmax, ltid);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float lsum = 0.0f;
    for (uint t = ltid; t < seqlen; t += 256) { float e = exp2((scores[t]-mx)*LOG2E); scores[t]=e; lsum+=e; }
    float ssum = block_sum(s8, lsum, ltid);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float inv = 1.0f / ssum;
    for (uint t = ltid; t < seqlen; t += 256) scores[t] *= inv;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    const uint od = ltid & 63;
    const uint op = ltid >> 6;
    const uint t0 = (op * seqlen) / 4;
    const uint t1 = ((op + 1) * seqlen) / 4;
    float psum = 0.0f;
    for (uint t = t0; t < t1; t++)
        psum += scores[t] * (float)vcb[(ulong)t * kvd + kvh * hdd + od];
    s_part[op * 64 + od] = psum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (op == 0)
        ob[h * hdd + od] = (s_part[od] + s_part[64+od]) + (s_part[128+od] + s_part[192+od]);
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

// ca_accumulate: copy this layer's alignment-head scores (from flash_cross_attn
// sc_out) into their PER-HEAD ca planes [NALIGN][MAX_TOK][seqlen]. Heads stay
// separate so wordTimestamps can z-normalize each head before averaging
// (OpenAI timing semantics). Scores come straight from the flash kernel — no
// QK/softmax recompute. One thread per t, one row per (plane, tok) → no race.
kernel void ca_accumulate(
    device float*       ca       [[buffer(0)]],  // [NALIGN][MAX_TOK][ca_stride] planes
    device const float* sc       [[buffer(1)]],  // [nh][seqlen] normalized scores
    device const uint*  tok_ptr  [[buffer(2)]],
    constant uint&  align_mask [[buffer(3)]],    // bit h set → head h is an alignment head
    constant uint&  plane_base [[buffer(4)]],    // plane index of this layer's first align head
    constant uint&  seqlen     [[buffer(5)]],    // valid cols this pass (AUDIO_CTX may shrink)
    constant uint&  nh         [[buffer(6)]],
    constant uint&  max_tok    [[buffer(7)]],
    constant uint&  ca_stride  [[buffer(8)]],    // ca plane row stride (ENC_SEQ, fixed alloc)
    uint ltid [[thread_position_in_threadgroup]])
{
    const uint tok = tok_ptr[0];
    uint plane = plane_base;
    for (uint h = 0; h < nh; h++) {
        if (!(align_mask & (1u << h))) continue;
        device float*       row = ca + ((ulong)plane * max_tok + tok) * ca_stride;
        device const float* src = sc + (ulong)h * seqlen;
        for (uint t = ltid; t < seqlen; t += 256) row[t] = src[t];
        plane++;
    }
}

// ── S1 sequence prefill — the seed prefix (<|startofprev|> prompt + sot/lang/
// task) as ONE batched causal pass over M rows instead of M sequential decoder
// steps. Projections run as M-row F16 GEMMs (MPS) on the host side; these
// kernels cover the row-wise pieces. Numerics per row mirror the single-token
// kernels above (same accumulation order inside a row).

// out[m][d] = deq(qs[tokens[m]][d]) + pe[(pos0+m)*dim + d]   (Q8 embedding rows)
kernel void emb_pe_rows_q8(
    device float*        out_buf [[buffer(0)]],
    device const char*   qs      [[buffer(1)]],
    device const half*   scales  [[buffer(2)]],
    device const uint*   tokens  [[buffer(3)]],
    device const float*  pe      [[buffer(4)]],
    constant uint& dim  [[buffer(5)]],
    constant uint& pos0 [[buffer(6)]],
    constant uint& M    [[buffer(7)]],
    uint gid [[thread_position_in_grid]])
{
    const uint total = M * dim;
    if (gid >= total) return;
    const uint m = gid / dim;
    const uint d = gid - m * dim;
    const uint tok = tokens[m];
    const uint nb = dim / 32;
    const float e = (float)qs[(ulong)tok * dim + d] * (float)scales[(ulong)tok * nb + d / 32];
    out_buf[gid] = e + pe[(ulong)(pos0 + m) * dim + d];
}

// slab[m] = [q|k|v] row from the fused qkv GEMM (f32, stride 3*dim).
// q_out[m][d] = q + qb[d]; kc[pos0+m][d] = k (no k bias); vc[pos0+m][d] = v + vb[d]
kernel void qkv_bias_store_rows(
    device float*        q_out [[buffer(0)]],
    device const float*  slab  [[buffer(1)]],
    device const float*  qb    [[buffer(2)]],
    device const float*  vb    [[buffer(3)]],
    device float*        kc    [[buffer(4)]],
    device float*        vc    [[buffer(5)]],
    constant uint& dim  [[buffer(6)]],
    constant uint& pos0 [[buffer(7)]],
    constant uint& M    [[buffer(8)]],
    uint gid [[thread_position_in_grid]])
{
    const uint total = M * dim;
    if (gid >= total) return;
    const uint m = gid / dim;
    const uint d = gid - m * dim;
    device const float* row = slab + (ulong)m * 3 * dim;
    q_out[gid] = row[d] + qb[d];
    kc[(ulong)(pos0 + m) * dim + d] = row[dim + d];
    vc[(ulong)(pos0 + m) * dim + d] = row[2 * dim + d] + vb[d];
}

// Causal self-attention over M query rows: row m (position pos0+m) attends keys
// [0, pos0+m]. Grid = M*nh threadgroups (tgid → row, head), 256 threads — the
// body is gpu_attention's with the row's own position, so each row's result is
// what the single-token kernel would have produced at that step.
kernel void causal_attention_rows(
    device float*       out_buf [[buffer(0)]],   // [M][nh*hdd]
    device const float* q_buf   [[buffer(1)]],   // [M][nh*hdd]
    device const float* kc      [[buffer(2)]],   // [MAX_TOK][kvd]
    device const float* vc      [[buffer(3)]],
    constant uint& pos0 [[buffer(4)]],
    constant uint& hdd  [[buffer(5)]],
    constant uint& kvd  [[buffer(6)]],
    constant uint& nkv  [[buffer(7)]],
    constant uint& nh   [[buffer(8)]],
    uint tgid [[threadgroup_position_in_grid]],
    uint ltid [[thread_position_in_threadgroup]])
{
    threadgroup float scores[512];
    threadgroup float s8[8];
    threadgroup float s_part[256];
    const uint m = tgid / nh;
    const uint h = tgid % nh;
    const uint pos = pos0 + m;
    const uint posP1 = pos + 1;
    const uint kvh = (h * nkv) / nh;
    const uint D = nh * hdd;
    const float rsq = rsqrt((float)hdd);
    const float LOG2E = 1.4426950408889634f;
    device const float* qm = q_buf + (ulong)m * D;
    device float*       om = out_buf + (ulong)m * D;

    for (uint t = ltid; t < posP1; t += 256) {
        float sum = 0.0f;
        for (uint d = 0; d < hdd; d++) {
            sum += qm[h * hdd + d] * kc[(ulong)t * kvd + kvh * hdd + d];
        }
        scores[t] = sum * rsq;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

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
        om[h * hdd + od] = (s_part[od] + s_part[64 + od]) + (s_part[128 + od] + s_part[192 + od]);
}

// Cross-attention for M query rows against ONE shared encoder KV (the prefix
// rows all belong to the same chunk). Grid = M*nh threadgroups. Body =
// flash_cross_attn_f16kv_batched with the per-slot KV stride removed.
kernel void flash_cross_attn_f16kv_rows(
    device float*       out_buf [[buffer(0)]],   // [M][nh*hdd]
    device const float* q_buf   [[buffer(1)]],   // [M][nh*hdd]
    device const half*  kc      [[buffer(2)]],   // [seqlen][kvd] (shared)
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
    threadgroup float s_part[256];
    threadgroup float s_qh[64];
    const uint m = tgid / nh;
    const uint h = tgid % nh;
    const uint kvh = (h * nkv) / nh;
    const uint D = nh * hdd;
    const float rsq = rsqrt((float)hdd);
    const float LOG2E = 1.4426950408889634f;
    device const float* qb = q_buf   + (ulong)m * D;
    device float*       ob = out_buf + (ulong)m * D;

    for (uint d = ltid; d < hdd; d += 256) s_qh[d] = qb[h * hdd + d];
    threadgroup_barrier(mem_flags::mem_threadgroup);
    threadgroup const float4* q4 = (threadgroup const float4*)s_qh;
    const uint d4n = hdd >> 2;
    for (uint t = ltid; t < seqlen; t += 256) {
        device const half4* k4 = (device const half4*)(kc + (ulong)t * kvd + kvh * hdd);
        float sum = 0.0f;
        for (uint i = 0; i < d4n; i++) {
            const half4 kv = k4[i];
            const float4 qv = q4[i];
            sum += qv.x*(float)kv.x + qv.y*(float)kv.y + qv.z*(float)kv.z + qv.w*(float)kv.w;
        }
        scores[t] = sum * rsq;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float lmax = -INFINITY;
    for (uint t = ltid; t < seqlen; t += 256) lmax = max(lmax, scores[t]);
    float mx = block_max(s8, lmax, ltid);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float lsum = 0.0f;
    for (uint t = ltid; t < seqlen; t += 256) { float e = exp2((scores[t]-mx)*LOG2E); scores[t]=e; lsum+=e; }
    float ssum = block_sum(s8, lsum, ltid);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    float inv = 1.0f / ssum;
    for (uint t = ltid; t < seqlen; t += 256) scores[t] *= inv;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    const uint od = ltid & 63;
    const uint op = ltid >> 6;
    const uint t0 = (op * seqlen) / 4;
    const uint t1 = ((op + 1) * seqlen) / 4;
    float psum = 0.0f;
    for (uint t = t0; t < t1; t++)
        psum += scores[t] * (float)vc[(ulong)t * kvd + kvh * hdd + od];
    s_part[op * 64 + od] = psum;
    threadgroup_barrier(mem_flags::mem_threadgroup);
    if (op == 0)
        ob[h * hdd + od] = (s_part[od] + s_part[64+od]) + (s_part[128+od] + s_part[192+od]);
}
