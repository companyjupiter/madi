// conv1d.metal — port of kernels/conv1d.ptx
// 1D convolution + tanh-approx GELU, and a 2D transpose helper.
//
// PTX→Metal mapping used throughout this port:
//   %ctaid.x  (blockIdx.x)  → tgid   [[threadgroup_position_in_grid]]
//   %tid.x    (threadIdx.x) → ltid   [[thread_position_in_threadgroup]]
//   %nctaid.x (gridDim.x)   → ngrid  [[threadgroups_per_grid]]
//   pointer params          → device buffers
//   scalar params           → constant& scalars (bound as bytes by the bridge)
//
// conv1d_gelu layout (matches the original quark weight layout):
//   input  [C_in][L_in]            F32
//   weight [K][C_in][C_out]        F32  (host pre-transposes F16→F32)
//   bias   [C_out]                 F32
//   output [C_out][L_out]          F32
//   Grid = (L_out, 1, 1)  Block = (256, 1, 1)
//   threadgroup t = output time index; each thread strides C_out by 256.
#include <metal_stdlib>
using namespace metal;

inline float gelu_tanh(float x) {
    // GELU(x) = 0.5 x (1 + tanh( sqrt(2/pi) (x + 0.044715 x^3) ))
    const float k0 = 0.7978845608028654f; // sqrt(2/pi)
    const float k1 = 0.044715f;
    float inner = k0 * (x + k1 * x * x * x);
    return 0.5f * x * (1.0f + precise::tanh(inner));
}

kernel void conv1d_gelu(
    device float*        out_buf [[buffer(0)]],
    device const float*  in_buf  [[buffer(1)]],
    device const float*  w_buf   [[buffer(2)]],
    device const float*  b_buf   [[buffer(3)]],
    constant uint& C_in    [[buffer(4)]],
    constant uint& C_out   [[buffer(5)]],
    constant uint& L_in    [[buffer(6)]],
    constant uint& K       [[buffer(7)]],
    constant uint& stride  [[buffer(8)]],
    constant uint& padding [[buffer(9)]],
    uint tgid  [[threadgroup_position_in_grid]],
    uint ltid  [[thread_position_in_threadgroup]],
    uint ngrid [[threadgroups_per_grid]])
{
    const uint t = tgid;       // output time index
    const uint L_out = ngrid;  // number of output time steps == grid size

    for (uint c_out = ltid; c_out < C_out; c_out += 256) {
        float sum = b_buf[c_out];
        for (uint c_in = 0; c_in < C_in; c_in++) {
            for (uint k = 0; k < K; k++) {
                uint t_in = t * stride + k;
                if (t_in < padding) continue;
                t_in -= padding;
                if (t_in >= L_in) continue;
                float val = in_buf[c_in * L_in + t_in];
                float wf  = w_buf[((k * C_in) + c_in) * C_out + c_out];
                sum = fma(val, wf, sum);
            }
        }
        out_buf[c_out * L_out + t] = gelu_tanh(sum);
    }
}

// transpose_2d: in[R][C] → out[C][R]
// Grid = (ceil(C/16), ceil(R/16), 1)  Block = (16,16,1)
kernel void transpose_2d(
    device float*       out_buf [[buffer(0)]],
    device const float* in_buf  [[buffer(1)]],
    constant uint& R [[buffer(2)]],
    constant uint& C [[buffer(3)]],
    uint2 tgid [[threadgroup_position_in_grid]],
    uint2 ltid [[thread_position_in_threadgroup]])
{
    uint c = tgid.x * 16 + ltid.x;
    uint r = tgid.y * 16 + ltid.y;
    if (r >= R || c >= C) return;
    out_buf[c * R + r] = in_buf[r * C + c];
}

// ── conv1d as im2col + GEMM (MPS) ───────────────────────────────────
// im2col: build col[L_out][C_in*K] (F16) from in[C_in][L_in] (F32).
//   col[t][k*C_in + c] = in[c][t*stride + k - pad]  (0 if out of range)
// Then MPS F16 GEMM: out[L_out][C_out] = col @ W[C_in*K][C_out] (W = upConvWF16).
kernel void im2col_f16(
    device half*        col    [[buffer(0)]],
    device const float* in_buf [[buffer(1)]],
    constant uint& C_in   [[buffer(2)]],
    constant uint& L_in   [[buffer(3)]],
    constant uint& K      [[buffer(4)]],
    constant uint& stride [[buffer(5)]],
    constant uint& pad    [[buffer(6)]],
    constant uint& L_out  [[buffer(7)]],
    uint gid [[thread_position_in_grid]])
{
    const uint CK = C_in * K;
    if (gid >= L_out * CK) return;
    const uint t = gid / CK;
    const uint kc = gid % CK;
    const uint k = kc / C_in;
    const uint c = kc % C_in;
    const int ti = (int)(t * stride + k) - (int)pad;
    float v = 0.0f;
    if (ti >= 0 && ti < (int)L_in) v = in_buf[(ulong)c * L_in + (uint)ti];
    col[gid] = (half)v;
}

// bias + gelu(tanh) + transpose [L_out][C_out](F16) -> [C_out][L_out](F32). conv1.
kernel void gelu_transpose(
    device float*       out_ct [[buffer(0)]],
    device const half*  in_tc  [[buffer(1)]],
    device const float* bias   [[buffer(2)]],
    constant uint& L_out [[buffer(3)]],
    constant uint& C_out [[buffer(4)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= L_out * C_out) return;
    const uint t = gid / C_out, c = gid % C_out;
    out_ct[(ulong)c * L_out + t] = gelu_tanh((float)in_tc[gid] + bias[c]);
}

// bias + gelu(tanh) + positional add: d_ex[i] = gelu(in[i]+bias[c]) + pos[i]. conv2.
kernel void gelu_pos(
    device float*       d_ex   [[buffer(0)]],
    device const half*  in_tc  [[buffer(1)]],
    device const float* bias   [[buffer(2)]],
    device const float* pos    [[buffer(3)]],
    constant uint& n     [[buffer(4)]],
    constant uint& C_out [[buffer(5)]],
    uint gid [[thread_position_in_grid]])
{
    if (gid >= n) return;
    d_ex[gid] = gelu_tanh((float)in_tc[gid] + bias[gid % C_out]) + pos[gid];
}
