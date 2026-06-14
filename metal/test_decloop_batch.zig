// test_decloop_batch.zig — Phase J: verify the batched per-token LOOP (KV growth).
// The single-block test (test_decblock_batch) covered pos=0. This runs N
// autoregressive steps (pos 0..N-1) with teacher-forced (fixed) inputs so the
// self-KV cache GROWS, and checks decodeBlockBatched's step-(N-1) hidden — which
// attends to all prior KV — matches decodeBlock per slot. Gate max|Δ| < 5e-3.
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
    var rng = std.Random.DefaultPrng.init(123);
    const r = rng.random();
    const B: u32 = 8; const N: u32 = 6; // 6 autoregressive steps

    var L: [NL]dec.Layer = undefined; var Wf: [NL]dec.WF16 = undefined;
    for (0..NL) |l| { L[l] = mkLayer(r); Wf[l] = try mkWF16(f_deq, L[l]); }

    // fixed per-step inputs (teacher-forced), same for ref and batched
    const xseq = rndF32(r, N * B * D, 1); // [N][B][D]

    // per-slot self-KV (per layer) + cross-KV (per layer); pos buffer
    var skc: [8][NL][*]f32 = undefined; var svc: [8][NL][*]f32 = undefined;
    var ckc: [8][NL][*]f16 = undefined; var cvc: [8][NL][*]f16 = undefined;
    for (0..B) |b| for (0..NL) |l| {
        skc[b][l] = (try mtl.allocSlice(f32, MAX_TOK * D)).ptr;
        svc[b][l] = (try mtl.allocSlice(f32, MAX_TOK * D)).ptr;
        const ck = try mtl.allocSlice(f16, ENC_SEQ * D); for (ck) |*v| v.* = @floatCast((r.float(f32) * 2 - 1) * 0.3); ckc[b][l] = ck.ptr;
        const cv = try mtl.allocSlice(f16, ENC_SEQ * D); for (cv) |*v| v.* = @floatCast((r.float(f32) * 2 - 1) * 0.3); cvc[b][l] = cv.ptr;
    };
    const posb = (try mtl.allocSlice(u32, 1)).ptr;

    const ss = dec.Scratch{
        .xb = (try mtl.allocSlice(f32, D)).ptr, .q = (try mtl.allocSlice(f32, D)).ptr,
        .k = (try mtl.allocSlice(f32, D)).ptr, .v = (try mtl.allocSlice(f32, D)).ptr,
        .ao = (try mtl.allocSlice(f32, D)).ptr, .mo = (try mtl.allocSlice(f32, D)).ptr,
        .mh = (try mtl.allocSlice(f32, MLP)).ptr, .ca_sc = (try mtl.allocSlice(f32, dec.NH * ENC_SEQ)).ptr,
    };
    const xref = try mtl.allocSlice(f32, B * D);
    for (0..B) |b| {
        const x = (try mtl.allocSlice(f32, D)).ptr;
        for (0..N) |t| {
            @memcpy(x[0..D], xseq[(t * B + b) * D ..][0..D]);
            posb[0] = @intCast(t);
            try mtl.beginCommandBuffer();
            for (0..NL) |l| try dec.decodeBlock(K, L[l], x, ss, skc[b][l], svc[b][l], ckc[b][l], cvc[b][l], posb, null);
            try mtl.commitCommandBuffer(); try mtl.sync();
        }
        @memcpy(xref.ptr[b * D ..][0..D], x[0..D]); // final-step hidden
    }

    // batched: same N steps, KV grows
    for (0..B) |b| for (0..NL) |l| { @memset(skc[b][l][0 .. MAX_TOK * D], 0); @memset(svc[b][l][0 .. MAX_TOK * D], 0); };
    const x_b = (try mtl.allocSlice(f32, B * D)).ptr;
    const sb = dec.BScratch{
        .xb = (try mtl.allocSlice(f32, B * D)).ptr, .qkv = (try mtl.allocSlice(f32, B * 3 * D)).ptr,
        .ao = (try mtl.allocSlice(f32, B * D)).ptr, .mo = (try mtl.allocSlice(f32, B * D)).ptr,
        .mh = (try mtl.allocSlice(f32, B * MLP)).ptr, .ca_sc = (try mtl.allocSlice(f32, dec.NH * ENC_SEQ)).ptr,
        .in16 = (try mtl.allocSlice(f16, B * MLP)).ptr, .out16 = (try mtl.allocSlice(f16, B * MLP)).ptr,
    };
    var posp: [8][*]u32 = undefined; for (0..B) |b| posp[b] = posb;
    for (0..N) |t| {
        @memcpy(x_b[0 .. B * D], xseq[t * B * D ..][0 .. B * D]);
        posb[0] = @intCast(t);
        try mtl.beginCommandBuffer();
        for (0..NL) |l| {
            var sk: [8][*]f32 = undefined; var sv: [8][*]f32 = undefined; var ck: [8][*]f16 = undefined; var cv: [8][*]f16 = undefined;
            for (0..B) |b| { sk[b] = skc[b][l]; sv[b] = svc[b][l]; ck[b] = ckc[b][l]; cv[b] = cvc[b][l]; }
            try dec.decodeBlockBatched(K, L[l], Wf[l], B, x_b, sb, sk[0..B], sv[0..B], ck[0..B], cv[0..B], posp[0..B]);
        }
        try mtl.commitCommandBuffer(); try mtl.sync();
    }

    var max_err: f32 = 0; var max_ref: f32 = 0;
    for (0..B * D) |i| { const e = @abs(xref.ptr[i] - x_b[i]); if (e > max_err) max_err = e; if (@abs(xref.ptr[i]) > max_ref) max_ref = @abs(xref.ptr[i]); }
    try out.print("{d}-step batched loop (KV grows) vs per-slot: max|Δ|={e:.3} rel={e:.3}\n", .{ N, max_err, max_err / max_ref });
    if (max_err / max_ref > 5e-3) { try out.print("❌ FAIL\n", .{}); return error.Mismatch; }
    try out.print("✅ PASS — batched per-token loop (multi-step KV growth) quality-equivalent\n", .{});
}
