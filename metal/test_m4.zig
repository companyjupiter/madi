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
    try q8Section();
}

// Q8-direct section appended by phase 2 (run as: out/test_m4 — both sections execute)
pub fn q8Section() !void {
    const out = std.io.getStdOut().writer();
    const M: u32 = 1500;
    const K: u32 = 1280;
    const N: u32 = 5120;
    const KB = K / 32;
    const A = try mtl.allocSlice(f16, M * K);
    const Wq = try mtl.allocSlice(i8, N * K);
    const Sc = try mtl.allocSlice(f16, N * KB);
    const Bias = try mtl.allocSlice(f32, N);
    const C = try mtl.allocSlice(f16, M * N);
    const Wdq = try mtl.allocSlice(f16, K * N); // for the legacy-path timing
    var rng = std.Random.DefaultPrng.init(11);
    const r = rng.random();
    for (A) |*v| v.* = @floatCast((r.float(f32) - 0.5) * 0.5);
    for (Bias) |*v| v.* = (r.float(f32) - 0.5) * 0.1;
    // quantize a random W[N][K] to Q8_0
    for (0..N) |n| {
        for (0..KB) |kb| {
            var mx: f32 = 1e-9;
            var tmp: [32]f32 = undefined;
            for (0..32) |j| {
                tmp[j] = (r.float(f32) - 0.5) * 0.08;
                mx = @max(mx, @abs(tmp[j]));
            }
            const sc = mx / 127.0;
            Sc[n * KB + kb] = @floatCast(sc);
            for (0..32) |j| Wq[n * K + kb * 32 + j] = @intFromFloat(@round(tmp[j] / sc));
        }
    }
    const f_q8 = try mtl.getFunction("m4_gemm_q8_bias_gelu");
    const f_deq = try mtl.getFunction("dequant_q8_f16");
    const f_bias = try mtl.getFunction("m4_gemm_bias");
    var mm = M; var nn = N; var kk = K; var gelu_off: u32 = 0;
    var a0 = A.ptr; var a1 = Wq.ptr; var a2 = Sc.ptr; var a3 = C.ptr; var a4 = Bias.ptr;
    const Pf = struct { fn p(x: anytype) ?*const anyopaque { return @ptrCast(x); } }.p;
    const ps = @sizeOf(usize); const u = @sizeOf(u32);
    var t = try std.time.Timer.start();
    for (0..11) |i| {
        if (i == 1) t.reset();
        try mtl.beginCommandBuffer();
        const params = [_]?*const anyopaque{ Pf(&a0), Pf(&a1), Pf(&a2), Pf(&a3), Pf(&a4), Pf(&mm), Pf(&nn), Pf(&kk), Pf(&gelu_off) };
        const sizes = [_]usize{ ps, ps, ps, ps, ps, u, u, u, u };
        try mtl.dispatch(f_q8, .{ (N + 63) / 64, (M + 63) / 64, 1 }, .{ 128, 1, 1 }, &params, &sizes);
        try mtl.commitCommandBuffer();
        try mtl.sync();
    }
    const q8_ms = @as(f64, @floatFromInt(t.read())) / 1e6 / 10.0;

    const f_q8tg = try mtl.getFunction("m4_gemm_q8tg");
    const C3 = try mtl.allocSlice(f16, M * N);
    var c3 = C3.ptr;
    for (0..11) |i| {
        if (i == 1) t.reset();
        try mtl.beginCommandBuffer();
        const params = [_]?*const anyopaque{ Pf(&a0), Pf(&a1), Pf(&a2), Pf(&c3), Pf(&a4), Pf(&mm), Pf(&nn), Pf(&kk), Pf(&gelu_off) };
        const sizes = [_]usize{ ps, ps, ps, ps, ps, u, u, u, u };
        try mtl.dispatch(f_q8tg, .{ (N + 63) / 64, (M + 63) / 64, 1 }, .{ 128, 1, 1 }, &params, &sizes);
        try mtl.commitCommandBuffer();
        try mtl.sync();
    }
    const q8tg_ms = @as(f64, @floatFromInt(t.read())) / 1e6 / 10.0;

    // legacy path timing: dequant + f16 gemm+bias
    var d0 = Wdq.ptr; var d1 = Wq.ptr; var d2 = Sc.ptr;
    const C2 = try mtl.allocSlice(f16, M * N);
    var c2 = C2.ptr;
    for (0..11) |i| {
        if (i == 1) t.reset();
        try mtl.beginCommandBuffer();
        {
            const params = [_]?*const anyopaque{ Pf(&d0), Pf(&d1), Pf(&d2), Pf(&nn), Pf(&kk) };
            const sizes = [_]usize{ ps, ps, ps, u, u };
            try mtl.dispatch(f_deq, .{ (N * K + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &params, &sizes);
        }
        {
            const params = [_]?*const anyopaque{ Pf(&a0), Pf(&d0), Pf(&c2), Pf(&a4), Pf(&mm), Pf(&nn), Pf(&kk) };
            const sizes = [_]usize{ ps, ps, ps, ps, u, u, u };
            try mtl.dispatch(f_bias, .{ (N + 63) / 64, (M + 63) / 64, 1 }, .{ 128, 1, 1 }, &params, &sizes);
        }
        try mtl.commitCommandBuffer();
        try mtl.sync();
    }
    const legacy_ms = @as(f64, @floatFromInt(t.read())) / 1e6 / 10.0;

    var max_err: f32 = 0;
    for (0..M * N) |i| {
        const e = @abs(@as(f32, @floatCast(C[i])) - @as(f32, @floatCast(C2[i])));
        if (e > max_err) max_err = e;
    }
    var max_err3: f32 = 0;
    for (0..M * N) |i| {
        const e = @abs(@as(f32, @floatCast(C3[i])) - @as(f32, @floatCast(C2[i])));
        if (e > max_err3) max_err3 = e;
    }
    try out.print("Q8-A(coop32): {d:.2}ms  Q8-B(tg128): {d:.2}ms  vs dequant+f16gemm: {d:.2}ms  (B={d:.2}x)  max|Δ| A={d:.4} B={d:.4}\n", .{ q8_ms, q8tg_ms, legacy_ms, legacy_ms / q8tg_ms, max_err, max_err3 });
}
