// test_specgemm.zig — speculative-decoding make-or-break probe (Phase J recon).
// Times the two decoder-dominant GEMM shapes at batch M = 1,2,4,8,16,32. If the
// per-ROW cost drops sharply as M grows, single-token decode is occupancy-bound
// (the 5.8x-off-ceiling we measured) and a K-token batched VERIFY forward would
// be far cheaper than K sequential tokens → speculative decoding is a real win.
// If per-row cost is flat, decode is bandwidth-bound and batching buys nothing.
const std = @import("std");
const mtl = @import("metal_backend.zig");
const alloc = std.heap.page_allocator;
const METALLIB = @embedFile("whisper.metallib");

fn timeGemm(M: u32, N: u32, K: u32, A: []f16, B: []f16, C: []f16) !f64 {
    var t = try std.time.Timer.start();
    const iters: u32 = 30;
    for (0..iters + 1) |i| {
        if (i == 1) t.reset();
        try mtl.beginCommandBuffer();
        try mtl.matmulF16Batched(A.ptr, B.ptr, C.ptr, M, N, K);
        try mtl.commitCommandBuffer();
        try mtl.sync();
    }
    return @as(f64, @floatFromInt(t.read())) / 1e6 / @as(f64, @floatFromInt(iters));
}

pub fn main() !void {
    const out = std.io.getStdOut().writer();
    try mtl.init();
    try mtl.loadLibrary(METALLIB);
    const K: u32 = 1280;
    const shapes = [_]struct { name: []const u8, N: u32 }{
        .{ .name = "FFN up  (1280x5120)", .N = 5120 },
        .{ .name = "logit   (1280x51866)", .N = 51866 },
    };
    const Ms = [_]u32{ 1, 2, 4, 8, 16, 32 };
    const maxM = 32;
    var rng = std.Random.DefaultPrng.init(7);
    const r = rng.random();

    for (shapes) |sh| {
        const A = try mtl.allocSlice(f16, maxM * K);
        const B = try mtl.allocSlice(f16, K * sh.N);
        const C = try mtl.allocSlice(f16, maxM * sh.N);
        for (A) |*v| v.* = @floatCast((r.float(f32) - 0.5) * 0.5);
        for (B) |*v| v.* = @floatCast((r.float(f32) - 0.5) * 0.05);
        try out.print("\n=== {s} ===\n", .{sh.name});
        try out.print("{s:>5} {s:>10} {s:>12} {s:>10}\n", .{ "M", "ms", "us/row", "vs M=1" });
        var base_per_row: f64 = 0;
        for (Ms) |M| {
            const ms = try timeGemm(M, sh.N, K, A, B, C);
            const per_row = ms * 1000.0 / @as(f64, @floatFromInt(M));
            if (M == 1) base_per_row = per_row;
            try out.print("{d:>5} {d:>10.3} {d:>12.1} {d:>9.2}x\n", .{ M, ms, per_row, base_per_row / per_row });
        }
    }
    try out.print("\n해석: 'vs M=1'이 M=8서 ≫1 (예: 4x+)이면 occupancy-bound → 배치 verify 큰 승.\n", .{});
    try out.print("      ~1x면 bandwidth-bound → 추측 디코딩 무익 (반증).\n", .{});
}
