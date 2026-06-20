// test_q8gemm.zig — correctness + timing for mul_mm_q8 (F16×Q8_0 GEMM).
// Correctness: GPU vs CPU on A @ deq(Bq) with a partial M tile.
// Timing: mul_mm_q8 at an encoder GEMM shape (1500×1280×1280) for a perf read.
const std = @import("std");
const mtl = @import("metal_backend.zig");
const METALLIB = @embedFile("whisper.metallib");
const alloc = std.heap.page_allocator;

fn quantB(b: []const f32, n: usize, k: usize, qs: []i8, sc: []f16) void {
    const nb = k / 32;
    for (0..n) |row| {
        for (0..nb) |bl| {
            var mx: f32 = 0;
            for (0..32) |i| { const w = @abs(b[row * k + bl * 32 + i]); if (w > mx) mx = w; }
            const scale: f32 = if (mx > 0) mx / 127.0 else 1.0;
            sc[row * nb + bl] = @floatCast(scale);
            const inv = 1.0 / scale;
            for (0..32) |i| {
                const q = std.math.clamp(@round(b[row * k + bl * 32 + i] * inv), -127.0, 127.0);
                qs[row * k + bl * 32 + i] = @intFromFloat(q);
            }
        }
    }
}

fn run(f: mtl.Function, c: [*]f16, a: [*]f16, qs: [*]i8, sc: [*]f16, m: u32, n: u32, k: u32) !void {
    var a0 = c; var a1 = a; var a2 = qs; var a3 = sc; var mm = m; var nn = n; var kk = k;
    const P = struct { fn p(x: anytype) ?*const anyopaque { return @ptrCast(x); } }.p;
    const ps = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&mm), P(&nn), P(&kk) };
    const sz = [_]usize{ @sizeOf(usize), @sizeOf(usize), @sizeOf(usize), @sizeOf(usize), @sizeOf(u32), @sizeOf(u32), @sizeOf(u32) };
    try mtl.dispatch(f, .{ (n + 31) / 32, (m + 31) / 32, 1 }, .{ 128, 1, 1 }, &ps, &sz);
}

pub fn main() !void {
    const out = std.io.getStdOut().writer();
    try mtl.init();
    defer mtl.deinit();
    try mtl.loadLibrary(METALLIB);
    const f = try mtl.getFunction("mul_mm_q8");

    // ── correctness: M=50 (partial tile), N=64, K=96 ──
    const M: u32 = 50; const N: u32 = 64; const K: u32 = 96;
    const nb = K / 32;
    const a = try mtl.allocSlice(f16, M * K);
    const bf = try alloc.alloc(f32, N * K);
    const qs = try mtl.allocSlice(i8, N * K);
    const sc = try mtl.allocSlice(f16, N * nb);
    const c = try mtl.allocSlice(f16, M * N);
    var rng = std.Random.DefaultPrng.init(7);
    const r = rng.random();
    for (a) |*v| v.* = @floatCast(r.float(f32) * 2 - 1);
    for (bf) |*v| v.* = r.float(f32) * 0.4 - 0.2;
    quantB(bf, N, K, qs, sc);
    @memset(c, 0);
    try mtl.beginCommandBuffer();
    try run(f, c.ptr, a.ptr, qs.ptr, sc.ptr, M, N, K);
    try mtl.commitCommandBuffer();
    try mtl.sync();
    // CPU ref against dequantized B
    var max_err: f32 = 0;
    for (0..M) |m| for (0..N) |n| {
        var acc: f32 = 0;
        for (0..K) |kk| {
            const deq = @as(f32, @floatFromInt(qs[n * K + kk])) * @as(f32, @floatCast(sc[n * nb + kk / 32]));
            acc += @as(f32, @floatCast(a[m * K + kk])) * deq;
        }
        const e = @abs(acc - @as(f32, @floatCast(c[m * N + n])));
        if (e > max_err) max_err = e;
    };
    try out.print("mul_mm_q8 correctness (M={d} N={d} K={d}): max_abs_err={e}\n", .{ M, N, K, max_err });
    if (max_err > 0.2) { try out.print("❌ Q8 GEMM FAIL\n", .{}); return error.Q8GemmMismatch; }
    try out.print("✅ Q8 GEMM OK\n", .{});

    // ── timing at encoder GEMM shape ──
    const TM: u32 = 1500; const TN: u32 = 1280; const TK: u32 = 1280;
    const ta = try mtl.allocSlice(f16, TM * TK);
    const tbf = try alloc.alloc(f32, TN * TK);
    const tqs = try mtl.allocSlice(i8, TN * TK);
    const tsc = try mtl.allocSlice(f16, TN * (TK / 32));
    const tc = try mtl.allocSlice(f16, TM * TN);
    for (ta) |*v| v.* = @floatCast(r.float(f32) * 2 - 1);
    for (tbf) |*v| v.* = r.float(f32) * 0.4 - 0.2;
    quantB(tbf, TN, TK, tqs, tsc);
    // warmup
    try mtl.beginCommandBuffer(); try run(f, tc.ptr, ta.ptr, tqs.ptr, tsc.ptr, TM, TN, TK); try mtl.commitCommandBuffer(); try mtl.sync();
    var timer = try std.time.Timer.start();
    const iters: u32 = 50;
    try mtl.beginCommandBuffer();
    for (0..iters) |_| try run(f, tc.ptr, ta.ptr, tqs.ptr, tsc.ptr, TM, TN, TK);
    try mtl.commitCommandBuffer(); try mtl.sync();
    const ms = @as(f64, @floatFromInt(timer.read())) / 1e6 / @as(f64, iters);
    try out.print("mul_mm_q8 @ {d}×{d}×{d}: {d:.3} ms/call\n", .{ TM, TN, TK, ms });

    // ── MPS F16 baseline at the same shape: A[M][K] @ B[K][N] ──
    const mb = try mtl.allocSlice(f16, TK * TN);
    for (mb) |*v| v.* = @floatCast(r.float(f32) * 0.4 - 0.2);
    try mtl.beginCommandBuffer(); try mtl.matmulF16Batched(ta.ptr, mb.ptr, tc.ptr, TM, TN, TK); try mtl.commitCommandBuffer(); try mtl.sync();
    timer.reset();
    try mtl.beginCommandBuffer();
    for (0..iters) |_| try mtl.matmulF16Batched(ta.ptr, mb.ptr, tc.ptr, TM, TN, TK);
    try mtl.commitCommandBuffer(); try mtl.sync();
    const mps_ms = @as(f64, @floatFromInt(timer.read())) / 1e6 / @as(f64, iters);
    try out.print("MPS  F16  @ {d}×{d}×{d}: {d:.3} ms/call\n", .{ TM, TN, TK, mps_ms });
    try out.print("→ Q8 is {d:.2}x {s} than MPS F16\n", .{ if (ms < mps_ms) mps_ms / ms else ms / mps_ms, if (ms < mps_ms) "FASTER" else "SLOWER" });
}
