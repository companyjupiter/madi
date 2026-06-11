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
