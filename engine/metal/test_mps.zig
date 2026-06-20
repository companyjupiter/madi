// test_mps.zig — isolated MPS matmul check (no dispatch interaction).
const std = @import("std");
const mtl = @import("metal_backend.zig");
const METALLIB = @embedFile("whisper.metallib");

pub fn main() !void {
    const out = std.io.getStdOut().writer();
    try mtl.init();
    defer mtl.deinit();
    try mtl.loadLibrary(METALLIB);
    try out.print("[1] init ok\n", .{});

    // Mirror encoder dims/flow exactly: layer_norm dispatch → sync → matmul.
    const M: u32 = 5; // SEQ
    const K: u32 = 128; // D
    const N: u32 = 128; // D
    const d_x = try mtl.allocSlice(f32, M * K);
    const d_ln = try mtl.allocSlice(f32, M * K);
    const g = try mtl.allocSlice(f32, K);
    const bb = try mtl.allocSlice(f32, K);
    const a = d_ln; // matmul A
    const b = try mtl.allocSlice(f32, K * N);
    const c = try mtl.allocSlice(f32, M * N);
    for (0..M * K) |i| d_x[i] = @floatFromInt((i % 7) + 1);
    for (0..K) |i| {
        g[i] = 1.0;
        bb[i] = 0.0;
    }
    for (0..K * N) |i| b[i] = 0.001 * @as(f32, @floatFromInt(i % 13));
    @memset(c, 0);

    const f_ln = try mtl.getFunction("layer_norm");
    var a0 = d_x.ptr;
    var a1 = d_ln.ptr;
    var a2 = g.ptr;
    var a3 = bb.ptr;
    var nd: u32 = K;
    var ne: f32 = 1e-5;
    const lp = [_]?*const anyopaque{ @ptrCast(&a0), @ptrCast(&a1), @ptrCast(&a2), @ptrCast(&a3), @ptrCast(&nd), @ptrCast(&ne) };
    const ls = [_]usize{ @sizeOf(usize), @sizeOf(usize), @sizeOf(usize), @sizeOf(usize), @sizeOf(u32), @sizeOf(f32) };
    try mtl.beginCommandBuffer();
    try mtl.dispatch(f_ln, .{ M, 1, 1 }, .{ 256, 1, 1 }, &lp, &ls);
    try mtl.commitCommandBuffer();
    try mtl.sync();
    try out.print("[2] layer_norm+sync done, calling MPS matmul {d}×{d}×{d}...\n", .{ M, N, K });

    try mtl.matmul(a.ptr, b.ptr, c.ptr, M, N, K);
    try out.print("[3] matmul returned\n", .{});

    // CPU ref
    var bad: usize = 0;
    for (0..M) |i| for (0..N) |j| {
        var s: f32 = 0;
        for (0..K) |p| s += a[i * K + p] * b[p * N + j];
        if (@abs(s - c[i * N + j]) > 1e-4) bad += 1;
    };
    try out.print("[4] mismatches = {d}\n", .{bad});
    if (bad == 0) try out.print("✅ MPS OK\n", .{}) else try out.print("❌ MPS FAIL\n", .{});
}
