// smoke.metal — minimal kernel to prove the Zig→ObjC→Metal toolchain works.
// Demonstrates the CUDA→Metal launch-arg mapping the port relies on:
//   buffer(0..)  = pointer args (MTLBuffers, bound by the bridge)
//   buffer(N)    = trailing scalar args (set as bytes by the bridge)
//   tid          = thread_position_in_grid (global thread index)
#include <metal_stdlib>
using namespace metal;

// c[i] = a[i] + b[i],  for i < n
kernel void vadd(
    device float*       c   [[buffer(0)]],
    device const float* a   [[buffer(1)]],
    device const float* b   [[buffer(2)]],
    constant uint&      n   [[buffer(3)]],
    uint tid [[thread_position_in_grid]])
{
    if (tid >= n) return;
    c[tid] = a[tid] + b[tid];
}
