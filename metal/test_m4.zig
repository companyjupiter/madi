// test_m4.zig — Metal4 tensor-ops GEMM vs MPS: correctness + A/B timing on
// the encoder FFN fc1 shape (M=1500, K=1280, N=5120).
const std = @import("std");
const mtl = @import("metal_backend.zig");
const alloc = std.heap.page_allocator;
const METALLIB = @embedFile("whisper.metallib");

pub fn main() !void {
    const out = std.io.getStdOut().writer();
    try mtl.init();
    try mtl.loadLibrary(METALLIB);
    const M: u32 = 1500;
    const K: u32 = 1280;
    const N: u32 = 5120;
    const A = try mtl.allocSlice(f16, M * K);
    const B = try mtl.allocSlice(f16, K * N);
    const C0 = try mtl.allocSlice(f16, M * N);
    const C1 = try mtl.allocSlice(f16, M * N);
    var rng = std.Random.DefaultPrng.init(7);
    const r = rng.random();
    for (A) |*v| v.* = @floatCast((r.float(f32) - 0.5) * 0.5);
    for (B) |*v| v.* = @floatCast((r.float(f32) - 0.5) * 0.05);

    const f_m4 = try mtl.getFunction("m4_gemm_nn");

    // MPS reference + timing (warm + 10 iters)
    var t = try std.time.Timer.start();
    for (0..11) |i| {
        if (i == 1) t.reset();
        try mtl.beginCommandBuffer();
        try mtl.matmulF16Batched(A.ptr, B.ptr, C0.ptr, M, N, K);
        try mtl.commitCommandBuffer();
        try mtl.sync();
    }
    const mps_ms = @as(f64, @floatFromInt(t.read())) / 1e6 / 10.0;

    // M4 tensor-ops timing (accumulating op → zero C each iter OUTSIDE timing? include memset for honesty: production will fuse store)
    var mm = M;
    var nn = N;
    var kk = K;
    var a0 = A.ptr;
    var a1 = B.ptr;
    var a2 = C1.ptr;
    const P = struct {
        fn p(x: anytype) ?*const anyopaque {
            return @ptrCast(x);
        }
    }.p;
    const ps = @sizeOf(usize);
    const u = @sizeOf(u32);
    var m4_ms: f64 = 0;
    for (0..11) |i| {
        @memset(C1, 0);
        if (i == 1) t.reset();
        try mtl.beginCommandBuffer();
        const params = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&mm), P(&nn), P(&kk) };
        const sizes = [_]usize{ ps, ps, ps, u, u, u };
        try mtl.dispatch(f_m4, .{ (N + 63) / 64, (M + 63) / 64, 1 }, .{ 128, 1, 1 }, &params, &sizes);
        try mtl.commitCommandBuffer();
        try mtl.sync();
    }
    m4_ms = @as(f64, @floatFromInt(t.read())) / 1e6 / 10.0;

    var max_err: f32 = 0;
    var nbad: usize = 0;
    for (0..M * N) |i| {
        const e = @abs(@as(f32, @floatCast(C0[i])) - @as(f32, @floatCast(C1[i])));
        if (e > max_err) max_err = e;
        if (e > 0.05) nbad += 1;
    }
    try out.print("MPS: {d:.2}ms  M4: {d:.2}ms  ({d:.2}x)  max|Δ|={d:.4} bad={d}\n", .{ mps_ms, m4_ms, mps_ms / m4_ms, max_err, nbad });
}
