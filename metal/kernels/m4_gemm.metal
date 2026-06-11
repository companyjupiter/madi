// m4_gemm.metal — Metal 4 tensor-ops GEMM kernels (requires -std=metal4.0;
// build.sh compiles m4_*.metal with that flag). In-shader tensor views over
// raw device pointers (NON-const — the mpp headers have no const overloads),
// so the existing buffer-based dispatch path needs no MTLTensor runtime.
//
// Why: the encoder is MPS-bound (~350 ms of a 548 ms chunk is MPS GEMM +
// dequant + the elementwise kernels between them). tensor_ops lets us
// (a) inline GEMM into our shaders → fuse bias/GELU, (b) consume Q8 weights
// directly (half × int8 → half is a supported combo), killing dequant.
#include <metal_stdlib>
#include <metal_tensor>
#include <MetalPerformancePrimitives/MetalPerformancePrimitives.h>
using namespace metal;
using namespace mpp;
using namespace mpp::tensor_ops;

// C[M,N] = A[M,K] · B[K,N]   (all f16 row-major, NN — the MPS replacement)
// Grid: (ceil(N/64), ceil(M/64)) threadgroups × 128 threads (4 simdgroups).
kernel void m4_gemm_nn(
    device half*  A [[buffer(0)]],
    device half*  B [[buffer(1)]],
    device half*  C [[buffer(2)]],
    constant uint& M [[buffer(3)]],
    constant uint& N [[buffer(4)]],
    constant uint& K [[buffer(5)]],
    uint2 tgid [[threadgroup_position_in_grid]])
{
    auto tA = tensor(A, dextents<int, 2>((int)K, (int)M));
    auto tB = tensor(B, dextents<int, 2>((int)N, (int)K));
    auto tC = tensor(C, dextents<int, 2>((int)N, (int)M));
    constexpr auto desc = matmul2d_descriptor(
        64, 64, static_cast<int>(dynamic_extent),
        false, false, false);
    matmul2d<desc, execution_simdgroups<4>> op;
    auto sA = tA.slice(0, (int)(tgid.y * 64));
    auto sB = tB.slice((int)(tgid.x * 64), 0);
    auto sC = tC.slice((int)(tgid.x * 64), (int)(tgid.y * 64));
    op.run(sA, sB, sC);
}

// ── epilogue helpers ─────────────────────────────────────────────────────
// erf-GELU, EXACTLY the gelu_f16 formula (Abramowitz-Stegun) for bit parity
inline float gelu_erf(float xv) {
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

// C = A·B + bias[n]  (replaces MPS GEMM + bias_add_f16 — one less full
// memory pass; the epilogue touches the tile while it is still cache-hot)
kernel void m4_gemm_bias(
    device half*  A [[buffer(0)]],
    device half*  B [[buffer(1)]],
    device half*  C [[buffer(2)]],
    device const float* bias [[buffer(3)]],
    constant uint& M [[buffer(4)]],
    constant uint& N [[buffer(5)]],
    constant uint& K [[buffer(6)]],
    uint2 tgid [[threadgroup_position_in_grid]],
    uint lid [[thread_index_in_threadgroup]])
{
    auto tA = tensor(A, dextents<int, 2>((int)K, (int)M));
    auto tB = tensor(B, dextents<int, 2>((int)N, (int)K));
    auto tC = tensor(C, dextents<int, 2>((int)N, (int)M));
    constexpr auto desc = matmul2d_descriptor(64, 64, static_cast<int>(dynamic_extent), false, false, false);
    matmul2d<desc, execution_simdgroups<4>> op;
    auto sA = tA.slice(0, (int)(tgid.y * 64));
    auto sB = tB.slice((int)(tgid.x * 64), 0);
    auto sC = tC.slice((int)(tgid.x * 64), (int)(tgid.y * 64));
    op.run(sA, sB, sC);
    threadgroup_barrier(mem_flags::mem_device);
    const uint r0 = tgid.y * 64, c0 = tgid.x * 64;
    for (uint i = lid; i < 64 * 64; i += 128) {
        const uint r = r0 + i / 64, c = c0 + i % 64;
        if (r < M && c < N) C[r * N + c] = (half)((float)C[r * N + c] + bias[c]);
    }
}

// C = GELU(A·B + bias[n])  (replaces MPS GEMM + bias_add_f16 + gelu_f16)
kernel void m4_gemm_bias_gelu(
    device half*  A [[buffer(0)]],
    device half*  B [[buffer(1)]],
    device half*  C [[buffer(2)]],
    device const float* bias [[buffer(3)]],
    constant uint& M [[buffer(4)]],
    constant uint& N [[buffer(5)]],
    constant uint& K [[buffer(6)]],
    uint2 tgid [[threadgroup_position_in_grid]],
    uint lid [[thread_index_in_threadgroup]])
{
    auto tA = tensor(A, dextents<int, 2>((int)K, (int)M));
    auto tB = tensor(B, dextents<int, 2>((int)N, (int)K));
    auto tC = tensor(C, dextents<int, 2>((int)N, (int)M));
    constexpr auto desc = matmul2d_descriptor(64, 64, static_cast<int>(dynamic_extent), false, false, false);
    matmul2d<desc, execution_simdgroups<4>> op;
    auto sA = tA.slice(0, (int)(tgid.y * 64));
    auto sB = tB.slice((int)(tgid.x * 64), 0);
    auto sC = tC.slice((int)(tgid.x * 64), (int)(tgid.y * 64));
    op.run(sA, sB, sC);
    threadgroup_barrier(mem_flags::mem_device);
    const uint r0 = tgid.y * 64, c0 = tgid.x * 64;
    for (uint i = lid; i < 64 * 64; i += 128) {
        const uint r = r0 + i / 64, c = c0 + i % 64;
        if (r < M && c < N) C[r * N + c] = (half)gelu_erf((float)C[r * N + c] + bias[c]);
    }
}

// ── Q8_0-direct GEMM (phase 2) — REFUTED on M4-class GPUs, kept for M5 ───
// Measured on M4 Pro (fc1 shape): design A (32-K cooperative scale pass)
// 0.57×, design B (TG-tile dequant, tilek=128) 0.84×, tilek=256 0.56×
// (occupancy collapse) vs dequant+f16-GEMM 4.3 ms. Root cause: every
// N-column has M/64 = 24 threadgroups re-dequanting the SAME weight tile,
// while the legacy layer-wide dequant runs once and its f16 round trip is
// SLC-resident. The half×int8 combo should flip this on M5's GPU neural
// accelerators (native int8 matmul) — kernels + harness kept ready.
// C[M,N] = A[M,K]f16 · dequant(Wq)[K,N], Wq = int8 [N][K] out-major with
// per-32 f16 scales [N][K/32] — EXACTLY our Q8 storage, consumed in place:
// no dequant pass, no f16 weight copy (fc1: 32.5 MB → 6.5 MB weight traffic
// per layer-GEMM). transpose_right reads the [N][K] rows as columns; the
// per-(n,kblock) scale is applied to each 32-K partial product in a
// cooperative accumulator before the next block accumulates.
kernel void m4_gemm_q8_bias_gelu(
    device half*  A      [[buffer(0)]],
    device int8_t* Wq     [[buffer(1)]],
    device half*  scales [[buffer(2)]],
    device half*  C      [[buffer(3)]],
    device const float* bias [[buffer(4)]],
    constant uint& M [[buffer(5)]],
    constant uint& N [[buffer(6)]],
    constant uint& K [[buffer(7)]],
    constant uint& act_gelu [[buffer(8)]],
    uint2 tgid [[threadgroup_position_in_grid]])
{
    auto tA = tensor(A,  dextents<int, 2>((int)K, (int)M));
    auto tB = tensor(Wq, dextents<int, 2>((int)K, (int)N)); // [N][K] rows, NT
    auto tC = tensor(C,  dextents<int, 2>((int)N, (int)M));
    constexpr auto desc = matmul2d_descriptor(64, 64, 32, false, true, false);
    matmul2d<desc, execution_simdgroups<4>> op;

    const int m0 = (int)(tgid.y * 64), c0 = (int)(tgid.x * 64);
    auto sC = tC.slice(c0, m0);
    auto acc = op.get_destination_cooperative_tensor<
        decltype(tA.slice(0, 0)), decltype(tB.slice(0, 0)), float>();
    auto part = op.get_destination_cooperative_tensor<
        decltype(tA.slice(0, 0)), decltype(tB.slice(0, 0)), float>();
#pragma unroll
    for (uint16_t i = 0; i < acc.get_capacity(); ++i) {
        if (acc.is_valid_element(i)) acc[i] = 0;
    }
    const uint KB = K / 32;
    for (uint kb = 0; kb < KB; ++kb) {
#pragma unroll
        for (uint16_t i = 0; i < part.get_capacity(); ++i) {
            if (part.is_valid_element(i)) part[i] = 0;
        }
        auto sA = tA.slice((int)(kb * 32), m0);
        auto sB = tB.slice((int)(kb * 32), c0);
        op.run(sA, sB, part);
#pragma unroll
        for (uint16_t i = 0; i < acc.get_capacity(); ++i) {
            if (acc.is_valid_element(i)) {
                auto ids = acc.get_multidimensional_index(i);
                const uint n = (uint)c0 + (uint)ids[0]; // ext0 = N
                if (n < N) acc[i] += part[i] * (float)scales[n * KB + kb];
            }
        }
    }
#pragma unroll
    for (uint16_t i = 0; i < acc.get_capacity(); ++i) {
        if (acc.is_valid_element(i)) {
            auto ids = acc.get_multidimensional_index(i);
            const uint n = (uint)c0 + (uint)ids[0];
            const uint m = (uint)m0 + (uint)ids[1];
            if (n < N && m < M) {
                float v = acc[i] + bias[n];
                C[m * N + n] = (half)(act_gelu != 0 ? gelu_erf(v) : v);
            }
        }
    }
}

// ── Q8-direct, design B: threadgroup-tile dequant + accumulate ───────────
// The per-32 scales are applied while loading the int8 weights into a
// threadgroup tile, so the k-tile size is FREE from the scale granularity
// (design A's 32-K cooperative scale pass ran 0.57× of legacy). tilek=128:
// 10 iterations for K=1280. Weight traffic stays int8-only.
kernel void m4_gemm_q8tg(
    device half*  A      [[buffer(0)]],
    device int8_t* Wq    [[buffer(1)]],
    device half*  scales [[buffer(2)]],
    device half*  C      [[buffer(3)]],
    device const float* bias [[buffer(4)]],
    constant uint& M [[buffer(5)]],
    constant uint& N [[buffer(6)]],
    constant uint& K [[buffer(7)]],
    constant uint& act_gelu [[buffer(8)]],
    uint2 tgid [[threadgroup_position_in_grid]],
    uint lid [[thread_index_in_threadgroup]])
{
    constexpr uint TK = 128;
    threadgroup half Bt[TK * 64]; // [TK rows of K][64 cols of N] — 16 KB
    auto tA = tensor(A, dextents<int, 2>((int)K, (int)M));
    auto tBt = tensor(&Bt[0], dextents<int, 2>(64, (int)TK));
    constexpr auto desc = matmul2d_descriptor(
        64, 64, TK, false, false, false,
        matmul2d_descriptor::mode::multiply_accumulate);
    matmul2d<desc, execution_simdgroups<4>> op;

    const int m0 = (int)(tgid.y * 64), c0 = (int)(tgid.x * 64);
    auto acc = op.get_destination_cooperative_tensor<
        decltype(tA.slice(0, 0)), decltype(tBt.slice(0, 0)), float>();
#pragma unroll
    for (uint16_t i = 0; i < acc.get_capacity(); ++i) {
        if (acc.is_valid_element(i)) acc[i] = 0;
    }
    const uint KB = K / 32;
    for (uint k0 = 0; k0 < K; k0 += TK) {
        // dequant the [TK][64] weight tile: Bt[kk][nn] = Wq[n][k] * scale[n][k/32]
        for (uint i = lid; i < TK * 64; i += 128) {
            const uint kk = i / 64, nn = i % 64;
            const uint n = (uint)c0 + nn, k = k0 + kk;
            Bt[i] = (n < N && k < K)
                ? (half)((float)Wq[n * K + k] * (float)scales[n * KB + k / 32])
                : (half)0.0h;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        auto sA = tA.slice((int)k0, m0);
        auto sB = tBt.slice(0, 0);
        op.run(sA, sB, acc);
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
#pragma unroll
    for (uint16_t i = 0; i < acc.get_capacity(); ++i) {
        if (acc.is_valid_element(i)) {
            auto ids = acc.get_multidimensional_index(i);
            const uint n = (uint)c0 + (uint)ids[0];
            const uint m = (uint)m0 + (uint)ids[1];
            if (n < N && m < M) {
                float v = acc[i] + bias[n];
                C[m * N + n] = (half)(act_gelu != 0 ? gelu_erf(v) : v);
            }
        }
    }
}

// ── Metal-4 flash attention (encoder, bidirectional) ─────────────────────
// Rewrite of flash_attention_enc_f16 with tensor-ops: 64-query tiles (the
// simdgroup version used 32 — halves whole-K/V streaming per element) and
// matmul2d for both QK^T and P·V. Q/K/V are consumed IN PLACE via strided
// device tensor views (row stride = nh*64) — no threadgroup staging copies.
// S goes cooperative → threadgroup for the online softmax (matmul operands
// cannot be cooperative); P·V accumulates in a cooperative tensor with
// coordinate-based row rescaling.
// REQUIREMENT: q/k/v buffers padded to ≥ ceil(seq/64)*64 rows (tail tiles
// read the padding; padded K rows are masked by kcur in the softmax, padded
// Q rows are dropped by the bounds-checked epilogue scatter).
// Layout identical to the original: packed [seq][nh*64], head offset h*64,
// scale 1/8. Grid: (nh, ceil(seq/64)) × 128 threads.
kernel void m4_flash_enc(
    device half*  out_buf [[buffer(0)]],
    device half*  q_buf   [[buffer(1)]],
    device half*  k_buf   [[buffer(2)]],
    device half*  v_buf   [[buffer(3)]],
    constant uint& seq_len [[buffer(4)]],
    constant uint& nh      [[buffer(5)]],
    uint2 tgid [[threadgroup_position_in_grid]],
    uint lid [[thread_index_in_threadgroup]])
{
    const uint h = tgid.x;
    const uint q0 = tgid.y * 64;
    if (q0 >= seq_len) return;
    const int qd = (int)(nh * 64);
    const float scale = 0.125f;
    const int rows_pad = (int)((seq_len + 63u) & ~63u);

    threadgroup float s_sc[64 * 64];  // S scores (f32, parity with referee)
    threadgroup half  s_p[64 * 64];   // P = exp(S - m)
    threadgroup float s_alpha[64];
    threadgroup float s_sum[64];
    threadgroup float s_m[64];
    threadgroup float s_red[2][64];   // 2-thread/row softmax partials

    if (lid < 64) {
        s_m[lid] = -INFINITY;
        s_sum[lid] = 0.0f;
    }

    // strided device views: rows = seq (padded), cols = 64 head dims
    auto tQ = tensor(q_buf + h * 64, dextents<int, 2>(64, rows_pad), array<int, 2>{1, qd});
    auto tK = tensor(k_buf + h * 64, dextents<int, 2>(64, rows_pad), array<int, 2>{1, qd});
    auto tV = tensor(v_buf + h * 64, dextents<int, 2>(64, rows_pad), array<int, 2>{1, qd});
    auto tP = tensor(&s_p[0], dextents<int, 2>(64, 64));

    constexpr auto dQK = matmul2d_descriptor(64, 64, 64, false, true, false);
    matmul2d<dQK, execution_simdgroups<4>> opQK;
    constexpr auto dPV = matmul2d_descriptor(
        64, 64, 64, false, false, false,
        matmul2d_descriptor::mode::multiply_accumulate);
    matmul2d<dPV, execution_simdgroups<4>> opPV;

    auto sQ = tQ.slice(0, (int)q0);
    auto sP = tP.slice(0, 0);
    auto sV0 = tV.slice(0, 0);
    auto accO = opPV.get_destination_cooperative_tensor<
        decltype(sP), decltype(sV0), float>();
#pragma unroll
    for (uint16_t i = 0; i < accO.get_capacity(); ++i) {
        if (accO.is_valid_element(i)) accO[i] = 0;
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);

    for (uint kv0 = 0; kv0 < seq_len; kv0 += 64) {
        const uint kcur = min(seq_len - kv0, 64u);
        auto sK = tK.slice(0, (int)kv0);
        auto accS = opQK.get_destination_cooperative_tensor<
            decltype(sQ), decltype(sK), float>();
        opQK.run(sQ, sK, accS);
#pragma unroll
        for (uint16_t i = 0; i < accS.get_capacity(); ++i) {
            if (accS.is_valid_element(i)) {
                auto ids = accS.get_multidimensional_index(i);
                s_sc[(uint)ids[1] * 64 + (uint)ids[0]] = accS[i];
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        // online softmax, 2 threads per query row (32 cols each), float4 reads
        {
            const uint qi = lid & 63u;
            const uint hf = lid >> 6;          // 0 or 1: column half
            const uint c0 = hf * 32u;
            threadgroup const float4* row4 =
                (threadgroup const float4*)(s_sc + qi * 64 + c0);
            float4 mx4 = float4(-INFINITY);
            for (uint k4 = 0; k4 < 8; k4++) {
                float4 v = row4[k4] * scale;
                // mask columns ≥ kcur (only the tail block has any)
                const uint kb = c0 + k4 * 4;
                if (kb + 4 > kcur) {
                    v.x = (kb + 0 < kcur) ? v.x : -INFINITY;
                    v.y = (kb + 1 < kcur) ? v.y : -INFINITY;
                    v.z = (kb + 2 < kcur) ? v.z : -INFINITY;
                    v.w = (kb + 3 < kcur) ? v.w : -INFINITY;
                }
                mx4 = max(mx4, v);
            }
            s_red[hf][qi] = max(max(mx4.x, mx4.y), max(mx4.z, mx4.w));
            threadgroup_barrier(mem_flags::mem_threadgroup);
            const float old_m = s_m[qi];
            const float new_m = max(old_m, max(s_red[0][qi], s_red[1][qi]));
            const float alpha = (old_m == -INFINITY) ? 0.0f : exp(old_m - new_m);
            float bs = 0.0f;
            threadgroup half4* prow4 = (threadgroup half4*)(s_p + qi * 64 + c0);
            for (uint k4 = 0; k4 < 8; k4++) {
                float4 v = row4[k4] * scale;
                const uint kb = c0 + k4 * 4;
                float4 e = exp(v - new_m);
                if (kb + 4 > kcur) {
                    e.x = (kb + 0 < kcur) ? e.x : 0.0f;
                    e.y = (kb + 1 < kcur) ? e.y : 0.0f;
                    e.z = (kb + 2 < kcur) ? e.z : 0.0f;
                    e.w = (kb + 3 < kcur) ? e.w : 0.0f;
                }
                bs += e.x + e.y + e.z + e.w;
                prow4[k4] = half4(e);
            }
            s_red[hf][qi] = bs;
            threadgroup_barrier(mem_flags::mem_threadgroup);
            if (hf == 0) {
                s_m[qi] = new_m;
                s_alpha[qi] = alpha;
                s_sum[qi] = s_sum[qi] * alpha + s_red[0][qi] + s_red[1][qi];
            }
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        // rescale accumulated O rows by alpha
#pragma unroll
        for (uint16_t i = 0; i < accO.get_capacity(); ++i) {
            if (accO.is_valid_element(i)) {
                auto ids = accO.get_multidimensional_index(i);
                accO[i] *= s_alpha[(uint)ids[1]];
            }
        }
        auto sV = tV.slice(0, (int)kv0);
        opPV.run(sP, sV, accO); // O += P·V
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }
    // epilogue: O / sum → out (bounds-checked: drops padded Q rows)
#pragma unroll
    for (uint16_t i = 0; i < accO.get_capacity(); ++i) {
        if (accO.is_valid_element(i)) {
            auto ids = accO.get_multidimensional_index(i);
            const uint qi = q0 + (uint)ids[1];
            if (qi < seq_len)
                out_buf[qi * (uint)qd + h * 64 + (uint)ids[0]] =
                    (half)(accO[i] / (s_sum[(uint)ids[1]] + 1e-6f));
        }
    }
}
