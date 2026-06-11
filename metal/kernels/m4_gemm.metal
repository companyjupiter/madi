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
