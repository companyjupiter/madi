// test_p5probe.zig — P5 GO/NO-GO: how much of batched decode (B=8) is the
// per-slot attention B-loop (kAttn+kCA) vs everything else? Run twice:
//   ./out/test_p5probe          → full block (with attention)
//   SKIP_ATTN=1 ./out/test_p5probe → attention skipped (timing only)
// attention fraction = (full − skip) / full. If small, batching attention (P5)
// can't move the needle → NO-GO. Mirrors test_decloop_batch's setup.
const std = @import("std");
const mtl = @import("metal_backend.zig");
const dec = @import("decoder.zig");
const alloc = std.heap.page_allocator;
const METALLIB = @embedFile("whisper.metallib");
const D = dec.D;
const MLP = dec.MLP;
const ENC_SEQ = dec.ENC_SEQ;
const MAX_TOK = dec.MAX_TOK;
const NL = dec.NL;

fn P(x: anytype) ?*const anyopaque { return @ptrCast(x); }
const PS = @sizeOf(usize);
const U = @sizeOf(u32);

fn rndF32(r: std.Random, n: usize, scale: f32) [*]f32 {
    const s = mtl.allocSlice(f32, n) catch unreachable;
    for (s) |*v| v.* = (r.float(f32) * 2 - 1) * scale;
    return s.ptr;
}
fn rndQ8(r: std.Random, N: u32, Kk: u32) dec.Q8w {
    const nb = Kk / 32;
    const qs = mtl.allocSlice(i8, N * Kk) catch unreachable;
    const sc = mtl.allocSlice(f16, N * nb) catch unreachable;
    for (0..N) |row| for (0..nb) |bl| {
        var mx: f32 = 0; var w: [32]f32 = undefined;
        for (0..32) |i| { w[i] = (r.float(f32) * 2 - 1) * 0.05; const a = @abs(w[i]); if (a > mx) mx = a; }
        const scale = if (mx > 0) mx / 127.0 else 1.0;
        sc[row * nb + bl] = @floatCast(scale);
        for (0..32) |i| qs[row * Kk + bl * 32 + i] = @intFromFloat(std.math.clamp(std.math.round(w[i] / scale), -127, 127));
    };
    return .{ .qs = qs.ptr, .scales = sc.ptr };
}
fn deq(f: mtl.Function, wdq: [*]f16, w: dec.Q8w, N: u32, Kk: u32) !void {
    var a0 = wdq; var a1 = w.qs; var a2 = w.scales; var nn = N; var kk = Kk;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&nn), P(&kk) };
    const sz = [_]usize{ PS, PS, PS, U, U };
    try mtl.dispatch(f, .{ (N * Kk + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &p, &sz);
}
fn mkLayer(r: std.Random) dec.Layer {
    return .{
        .aln_w = rndF32(r, D, 1), .aln_b = rndF32(r, D, 0.1),
        .qkvw = rndQ8(r, 3 * D, D), .qb = rndF32(r, D, 0.1), .vb = rndF32(r, D, 0.1),
        .ow = rndQ8(r, D, D), .ob = rndF32(r, D, 0.1),
        .caln_w = rndF32(r, D, 1), .caln_b = rndF32(r, D, 0.1),
        .cqw = rndQ8(r, D, D), .cqb = rndF32(r, D, 0.1),
        .cow = rndQ8(r, D, D), .cob = rndF32(r, D, 0.1),
        .mln_w = rndF32(r, D, 1), .mln_b = rndF32(r, D, 0.1),
        .m0w = rndQ8(r, MLP, D), .m0b = rndF32(r, MLP, 0.1),
        .m2w = rndQ8(r, D, MLP), .m2b = rndF32(r, D, 0.1),
    };
}
fn mkWF16(f: mtl.Function, L: dec.Layer) !dec.WF16 {
    const W = dec.WF16{
        .qkvw = (try mtl.allocSlice(f16, D * 3 * D)).ptr, .ow = (try mtl.allocSlice(f16, D * D)).ptr,
        .cqw = (try mtl.allocSlice(f16, D * D)).ptr, .cow = (try mtl.allocSlice(f16, D * D)).ptr,
        .m0w = (try mtl.allocSlice(f16, D * MLP)).ptr, .m2w = (try mtl.allocSlice(f16, MLP * D)).ptr,
    };
    try mtl.beginCommandBuffer();
    try deq(f, W.qkvw, L.qkvw, 3 * D, D); try deq(f, W.ow, L.ow, D, D);
    try deq(f, W.cqw, L.cqw, D, D); try deq(f, W.cow, L.cow, D, D);
    try deq(f, W.m0w, L.m0w, MLP, D); try deq(f, W.m2w, L.m2w, D, MLP);
    try mtl.commitCommandBuffer(); try mtl.sync();
    return W;
}

pub fn main() !void {
    const out = std.io.getStdOut().writer();
    try mtl.init();
    try mtl.loadLibrary(METALLIB);
    const K = try dec.Kernels.load();
    const f_deq = try mtl.getFunction("dequant_q8_f16");
    var rng = std.Random.DefaultPrng.init(7);
    const r = rng.random();
    const B: u32 = 8; const N: u32 = 150; // 150 autoregressive steps (typical segment len)

    var L: [NL]dec.Layer = undefined; var Wf: [NL]dec.WF16 = undefined;
    for (0..NL) |l| { L[l] = mkLayer(r); Wf[l] = try mkWF16(f_deq, L[l]); }
    const xseq = rndF32(r, N * B * D, 1);

    var skc: [8][NL][*]f32 = undefined; var svc: [8][NL][*]f32 = undefined;
    var ckc: [NL][*]f16 = undefined; var cvc: [NL][*]f16 = undefined; // contiguous [B][ENC_SEQ][D]
    for (0..NL) |l| {
        const ck = try mtl.allocSlice(f16, B * ENC_SEQ * D); for (ck) |*v| v.* = @floatCast((r.float(f32) * 2 - 1) * 0.3); ckc[l] = ck.ptr;
        const cv = try mtl.allocSlice(f16, B * ENC_SEQ * D); for (cv) |*v| v.* = @floatCast((r.float(f32) * 2 - 1) * 0.3); cvc[l] = cv.ptr;
    }
    for (0..B) |bb| for (0..NL) |l| {
        skc[bb][l] = (try mtl.allocSlice(f32, MAX_TOK * D)).ptr;
        svc[bb][l] = (try mtl.allocSlice(f32, MAX_TOK * D)).ptr;
    };
    const posb = (try mtl.allocSlice(u32, 1)).ptr;
    var posp: [8][*]u32 = undefined; for (0..B) |bb| posp[bb] = posb;
    const x_b = (try mtl.allocSlice(f32, B * D)).ptr;
    const sb = dec.BScratch{
        .xb = (try mtl.allocSlice(f32, B * D)).ptr, .qkv = (try mtl.allocSlice(f32, B * 3 * D)).ptr,
        .ao = (try mtl.allocSlice(f32, B * D)).ptr, .mo = (try mtl.allocSlice(f32, B * D)).ptr,
        .mh = (try mtl.allocSlice(f32, B * MLP)).ptr, .ca_sc = (try mtl.allocSlice(f32, dec.NH * ENC_SEQ)).ptr,
        .in16 = (try mtl.allocSlice(f16, B * MLP)).ptr, .out16 = (try mtl.allocSlice(f16, B * MLP)).ptr,
    };

    const skip = std.posix.getenv("SKIP_ATTN") != null;
    // warmup 10 steps (PSO compile, clocks)
    for (0..10) |t| {
        @memcpy(x_b[0 .. B * D], xseq[(t % N) * B * D ..][0 .. B * D]); posb[0] = @intCast(t);
        try mtl.beginCommandBuffer();
        for (0..NL) |l| {
            var sk: [8][*]f32 = undefined; var sv: [8][*]f32 = undefined;
            for (0..B) |bb| { sk[bb] = skc[bb][l]; sv[bb] = svc[bb][l]; }
            try dec.decodeBlockBatched(K, L[l], Wf[l], B, x_b, sb, sk[0..B], sv[0..B], ckc[l], cvc[l], posp[0..B]);
        }
        try mtl.commitCommandBuffer(); try mtl.sync();
    }
    // timed: N steps × NL layers
    var timer = try std.time.Timer.start();
    for (0..N) |t| {
        @memcpy(x_b[0 .. B * D], xseq[t * B * D ..][0 .. B * D]); posb[0] = @intCast(t);
        try mtl.beginCommandBuffer();
        for (0..NL) |l| {
            var sk: [8][*]f32 = undefined; var sv: [8][*]f32 = undefined;
            for (0..B) |bb| { sk[bb] = skc[bb][l]; sv[bb] = svc[bb][l]; }
            try dec.decodeBlockBatched(K, L[l], Wf[l], B, x_b, sb, sk[0..B], sv[0..B], ckc[l], cvc[l], posp[0..B]);
        }
        try mtl.commitCommandBuffer(); try mtl.sync();
    }
    const ns = timer.read();
    const ms = @as(f64, @floatFromInt(ns)) / 1e6;
    const per_step = ms / @as(f64, @floatFromInt(N));
    try out.print("[{s}] B={d} N={d} NL={d}: {d:.1}ms total, {d:.3}ms/step, {d:.0} tok/s (B-batched)\n", .{
        if (skip) "SKIP_ATTN" else "FULL    ", B, N, NL, ms, per_step,
        @as(f64, @floatFromInt(N * B)) / (ms / 1000.0),
    });
}
