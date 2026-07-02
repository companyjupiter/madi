// test_decblock_batch.zig — Phase J Stage-1 gate: decodeBlockBatched(B slots) must
// be quality-EQUIVALENT to decodeBlock run per slot. Random layer + B random token
// inputs at pos=0, each slot its own self/cross KV. Gate: max|Δ| < 5e-3 (F16 GEMM
// vs F32 GEMV — the same bar as the verified projection primitive).
const std = @import("std");
const mtl = @import("metal_backend.zig");
const dec = @import("decoder.zig");
const alloc = std.heap.page_allocator;
const METALLIB = @embedFile("whisper.metallib");
const D = dec.D;
const MLP = dec.MLP;
const ENC_SEQ = dec.ENC_SEQ;
const MAX_TOK = dec.MAX_TOK;

fn P(x: anytype) ?*const anyopaque { return @ptrCast(x); }
const PS = @sizeOf(usize);
const U = @sizeOf(u32);

fn rndF32(r: std.Random, n: usize, scale: f32) [*]f32 {
    const s = mtl.allocSlice(f32, n) catch unreachable;
    for (s) |*v| v.* = (r.float(f32) * 2 - 1) * scale;
    return s.ptr;
}
// quantize a random [N][K] F32 weight → Q8 (qs int8 + scales f16), return Q8w
fn rndQ8(r: std.Random, N: u32, Kk: u32) dec.Q8w {
    const nb = Kk / 32;
    const qs = mtl.allocSlice(i8, N * Kk) catch unreachable;
    const sc = mtl.allocSlice(f16, N * nb) catch unreachable;
    for (0..N) |row| for (0..nb) |bl| {
        var mx: f32 = 0;
        var w: [32]f32 = undefined;
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

pub fn main() !void {
    const out = std.io.getStdOut().writer();
    try mtl.init();
    try mtl.loadLibrary(METALLIB);
    const K = try dec.Kernels.load();
    const f_deq = try mtl.getFunction("dequant_q8_f16");
    var rng = std.Random.DefaultPrng.init(99);
    const r = rng.random();
    const B: u32 = 8;

    // random layer
    const L = dec.Layer{
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
    // pre-deq to F16
    const Wf = dec.WF16{
        .qkvw = (try mtl.allocSlice(f16, D * 3 * D)).ptr, .ow = (try mtl.allocSlice(f16, D * D)).ptr,
        .cqw = (try mtl.allocSlice(f16, D * D)).ptr, .cow = (try mtl.allocSlice(f16, D * D)).ptr,
        .m0w = (try mtl.allocSlice(f16, D * MLP)).ptr, .m2w = (try mtl.allocSlice(f16, MLP * D)).ptr,
    };
    try mtl.beginCommandBuffer();
    try deq(f_deq, Wf.qkvw, L.qkvw, 3 * D, D); try deq(f_deq, Wf.ow, L.ow, D, D);
    try deq(f_deq, Wf.cqw, L.cqw, D, D); try deq(f_deq, Wf.cow, L.cow, D, D);
    try deq(f_deq, Wf.m0w, L.m0w, MLP, D); try deq(f_deq, Wf.m2w, L.m2w, D, MLP);
    try mtl.commitCommandBuffer(); try mtl.sync();

    // shared random input + per-slot KV; pos=0 for all
    const x0 = rndF32(r, B * D, 1);
    const pos0 = (try mtl.allocSlice(u32, 1)).ptr; pos0[0] = 0;
    var skc: [8][*]f32 = undefined; var svc: [8][*]f32 = undefined;
    // cross-KV CONTIGUOUS [B][ENC_SEQ][D] (batched cross-attn)
    const ckc = (try mtl.allocSlice(f16, B * ENC_SEQ * D)).ptr; for (ckc[0 .. B * ENC_SEQ * D]) |*v| v.* = @floatCast((r.float(f32) * 2 - 1) * 0.3);
    const cvc = (try mtl.allocSlice(f16, B * ENC_SEQ * D)).ptr; for (cvc[0 .. B * ENC_SEQ * D]) |*v| v.* = @floatCast((r.float(f32) * 2 - 1) * 0.3);
    for (0..B) |b| {
        skc[b] = (try mtl.allocSlice(f32, MAX_TOK * D)).ptr;
        svc[b] = (try mtl.allocSlice(f32, MAX_TOK * D)).ptr;
    }

    // ── reference: decodeBlock per slot ──
    const xref = try mtl.allocSlice(f32, B * D);
    const ss = dec.Scratch{
        .xb = (try mtl.allocSlice(f32, D)).ptr, .q = (try mtl.allocSlice(f32, D)).ptr,
        .k = (try mtl.allocSlice(f32, D)).ptr, .v = (try mtl.allocSlice(f32, D)).ptr,
        .ao = (try mtl.allocSlice(f32, D)).ptr, .mo = (try mtl.allocSlice(f32, D)).ptr,
        .mh = (try mtl.allocSlice(f32, MLP)).ptr, .ca_sc = (try mtl.allocSlice(f32, dec.NH * ENC_SEQ)).ptr,
    };
    for (0..B) |b| {
        @memcpy(ss.xb[0..0], x0[0..0]); // noop, keep allocator warm
        const xb = (try mtl.allocSlice(f32, D)).ptr;
        @memcpy(xb[0..D], x0[b * D .. b * D + D]);
        try mtl.beginCommandBuffer();
        try dec.decodeBlock(K, L, xb, ss, skc[b], svc[b], ckc + b * ENC_SEQ * D, cvc + b * ENC_SEQ * D, pos0, null, ENC_SEQ);
        try mtl.commitCommandBuffer(); try mtl.sync();
        @memcpy(xref.ptr[b * D .. b * D + D], xb[0..D]);
        // reset KV so batched run starts identical
        @memset(skc[b][0 .. MAX_TOK * D], 0); @memset(svc[b][0 .. MAX_TOK * D], 0);
    }

    // ── batched: decodeBlockBatched(B) ──
    const xb_b = (try mtl.allocSlice(f32, B * D)).ptr;
    @memcpy(xb_b[0 .. B * D], x0[0 .. B * D]);
    const sb = dec.BScratch{
        .xb = (try mtl.allocSlice(f32, B * D)).ptr, .qkv = (try mtl.allocSlice(f32, B * 3 * D)).ptr,
        .ao = (try mtl.allocSlice(f32, B * D)).ptr, .mo = (try mtl.allocSlice(f32, B * D)).ptr,
        .mh = (try mtl.allocSlice(f32, B * MLP)).ptr, .ca_sc = (try mtl.allocSlice(f32, dec.NH * ENC_SEQ)).ptr,
        .in16 = (try mtl.allocSlice(f16, B * MLP)).ptr, .out16 = (try mtl.allocSlice(f16, B * MLP)).ptr,
    };
    var posb: [8][*]u32 = undefined; for (0..B) |b| posb[b] = pos0;
    try mtl.beginCommandBuffer();
    try dec.decodeBlockBatched(K, L, Wf, B, xb_b, sb, skc[0..B], svc[0..B], ckc, cvc, posb[0..B]);
    try mtl.commitCommandBuffer(); try mtl.sync();

    var max_err: f32 = 0; var max_ref: f32 = 0;
    for (0..B * D) |i| {
        const e = @abs(xref.ptr[i] - xb_b[i]); if (e > max_err) max_err = e;
        if (@abs(xref.ptr[i]) > max_ref) max_ref = @abs(xref.ptr[i]);
    }
    try out.print("decodeBlock×{d} vs decodeBlockBatched: max|Δ|={e:.3}  (|x|max {d:.2})  rel={e:.3}\n",
        .{ B, max_err, max_ref, max_err / max_ref });
    if (max_err / max_ref > 5e-3) { try out.print("❌ FAIL (rel > 5e-3)\n", .{}); return error.Mismatch; }
    try out.print("✅ PASS — batched block quality-equivalent\n", .{});
}
