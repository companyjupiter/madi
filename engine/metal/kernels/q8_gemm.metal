// q8_gemm.metal — F16×Q8_0 tiled simdgroup GEMM for the encoder.
//   C[M][N] = A[M][K] (half) @ deq(Bq[N][K])   (Bq out-major Q8_0: int8 + per-32 scale)
// i.e. C[m][n] = Σ_k A[m][k] · qs[n*K+k] · scales[n*(K/32)+k/32].
// 32×32 output tile / threadgroup (4 simdgroups × 16×16). BK=32 (= one Q8 block,
// so each B row has a single scale per K-tile). N,K are multiples of 32; M guarded.
#include <metal_stdlib>
using namespace metal;

// dequant_q8_f16 — Q8_0 weight (out-major [N][K], per-32 scale along K) → F16
// transposed to [K][N] (MPS B layout: A[M][K] @ B[K][N]). Out write-coalesced.
//   out[k*N + n] = qs[n*K + k] · scales[n*(K/32) + k/32]
kernel void dequant_q8_f16(
    device half*        out    [[buffer(0)]],   // [K][N] f16
    device const char*  qs     [[buffer(1)]],   // [N][K] int8
    device const half*  scales [[buffer(2)]],   // [N][K/32] f16
    constant uint& N [[buffer(3)]],
    constant uint& K [[buffer(4)]],
    uint gid [[thread_position_in_grid]])
{
    const uint total = N * K;
    if (gid >= total) return;
    const uint k = gid / N;
    const uint n = gid - k * N;
    const uint nb = K >> 5;
    const float sc = (float)scales[(ulong)n * nb + (k >> 5)];
    out[gid] = (half)((float)qs[(ulong)n * K + k] * sc);
}

kernel void mul_mm_q8(
    device half*         C      [[buffer(0)]],   // [M][N] f16
    device const half*   A      [[buffer(1)]],   // [M][K] f16
    device const char*   qs     [[buffer(2)]],   // [N][K] int8
    device const half*   scales [[buffer(3)]],   // [N][K/32] f16
    constant uint& M [[buffer(4)]],
    constant uint& N [[buffer(5)]],
    constant uint& K [[buffer(6)]],
    uint2 tgid  [[threadgroup_position_in_grid]],
    ushort tiitg [[thread_index_in_threadgroup]],
    ushort sgitg [[simdgroup_index_in_threadgroup]])
{
    threadgroup half sa[32 * 32];
    threadgroup half sb[32 * 32];

    const uint m0 = tgid.y * 32;
    const uint n0 = tgid.x * 32;
    const uint nb = K / 32;

    // this simdgroup owns a 16×16 sub-tile: (sgr,sgc) in {0,1}²
    const uint sgr = sgitg >> 1;   // 0,1  → rows  m0 + sgr*16
    const uint sgc = sgitg & 1;    // 0,1  → cols  n0 + sgc*16
    simdgroup_float8x8 mc[4];
    for (int i = 0; i < 4; i++) mc[i] = make_filled_simdgroup_matrix<float, 8>(0.0f);

    for (uint k0 = 0; k0 < K; k0 += 32) {
        // load A[32][32] tile → sa  (128 threads × 8 elems)
        for (uint e = tiitg; e < 32 * 32; e += 128) {
            const uint mr = e >> 5;        // 0..31 (row in tile)
            const uint kc = e & 31;        // 0..31 (k in tile)
            const uint m = m0 + mr;
            sa[mr * 32 + kc] = (m < M) ? A[(ulong)m * K + (k0 + kc)] : (half)0;
        }
        // dequant Bq[32 n][32 k] → sb  (one scale per n for this k-block)
        for (uint e = tiitg; e < 32 * 32; e += 128) {
            const uint nr = e >> 5;        // n in tile
            const uint kc = e & 31;
            const uint n = n0 + nr;
            const float sc = (float)scales[(ulong)n * nb + (k0 >> 5)];
            sb[nr * 32 + kc] = (half)((float)qs[(ulong)n * K + (k0 + kc)] * sc);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);

        // 16×16 += A_sub[16×32] @ B_sub[32×16]  (B stored n-major → load transposed)
        threadgroup const half* pa = sa + sgr * 16 * 32;   // [16][32]
        threadgroup const half* pb = sb + sgc * 16 * 32;   // [16(n)][32(k)]
        for (uint ik = 0; ik < 4; ik++) {
            simdgroup_half8x8 ma0, ma1, mb0, mb1;
            simdgroup_load(ma0, pa + 0 * 8 * 32 + ik * 8, 32);
            simdgroup_load(ma1, pa + 1 * 8 * 32 + ik * 8, 32);
            // pb is [n][k]; transposed load gives [k][n] (8k × 8n)
            simdgroup_load(mb0, pb + 0 * 8 * 32 + ik * 8, 32, 0, true);
            simdgroup_load(mb1, pb + 1 * 8 * 32 + ik * 8, 32, 0, true);
            simdgroup_multiply_accumulate(mc[0], ma0, mb0, mc[0]);
            simdgroup_multiply_accumulate(mc[1], ma0, mb1, mc[1]);
            simdgroup_multiply_accumulate(mc[2], ma1, mb0, mc[2]);
            simdgroup_multiply_accumulate(mc[3], ma1, mb1, mc[3]);
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
    }

    // store 16×16 (4 × 8×8) to C with M guard (via threadgroup staging)
    threadgroup float st[32 * 32];
    simdgroup_store(mc[0], st + (sgr * 16 + 0) * 32 + (sgc * 16 + 0), 32);
    simdgroup_store(mc[1], st + (sgr * 16 + 0) * 32 + (sgc * 16 + 8), 32);
    simdgroup_store(mc[2], st + (sgr * 16 + 8) * 32 + (sgc * 16 + 0), 32);
    simdgroup_store(mc[3], st + (sgr * 16 + 8) * 32 + (sgc * 16 + 8), 32);
    threadgroup_barrier(mem_flags::mem_threadgroup);
    for (uint e = tiitg; e < 32 * 32; e += 128) {
        const uint mr = e >> 5, nc = e & 31;
        const uint m = m0 + mr;
        if (m < M) C[(ulong)m * N + (n0 + nc)] = (half)st[mr * 32 + nc];
    }
}
