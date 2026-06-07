// test_encoder.zig — one full Whisper encoder layer on the GPU vs an
// independent CPU reference. Exercises every M2 kernel + MPS matmul:
//   layer_norm, flash_attention_enc, bias_add, gelu_f32(erf), bias_res_ln,
//   and the MPS F32 GEMM (QKV / out / FFN-up / FFN-down).
// Asset-free (synthetic weights). hdd is fixed at 64 (flash kernel requirement).
const std = @import("std");
const mtl = @import("metal_backend.zig");

const METALLIB = @embedFile("whisper.metallib");

// Tiny but structurally faithful dims. hdd MUST be 64 (flash_attention_enc).
const NH: u32 = 2;
const HDD: u32 = 64;
const D: u32 = NH * HDD; // 128
const MLP: u32 = 256;
const SEQ: u32 = 5;
const EPS: f32 = 1e-5;

var f_ln: mtl.Function = undefined;
var f_brln: mtl.Function = undefined;
var f_bias: mtl.Function = undefined;
var f_gelu: mtl.Function = undefined;
var f_flash: mtl.Function = undefined;

fn P(x: anytype) ?*const anyopaque {
    return @ptrCast(x);
}

fn kLN(x: [*]f32, y: [*]f32, g: [*]f32, b: [*]f32, d: u32, rows: u32) !void {
    var a0 = x;
    var a1 = y;
    var a2 = g;
    var a3 = b;
    var nd = d;
    var ne = EPS;
    const ptrs = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&nd), P(&ne) };
    const sz = [_]usize{ @sizeOf(usize), @sizeOf(usize), @sizeOf(usize), @sizeOf(usize), @sizeOf(u32), @sizeOf(f32) };
    try mtl.dispatch(f_ln, .{ rows, 1, 1 }, .{ 256, 1, 1 }, &ptrs, &sz);
}

fn kBiasResLN(x: [*]f32, mo: [*]f32, bias: [*]f32, y: [*]f32, g: [*]f32, b: [*]f32, d: u32, rows: u32) !void {
    var a0 = x;
    var a1 = mo;
    var a2 = bias;
    var a3 = y;
    var a4 = g;
    var a5 = b;
    var nd = d;
    var ne = EPS;
    const ptrs = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&a4), P(&a5), P(&nd), P(&ne) };
    const sz = [_]usize{ @sizeOf(usize), @sizeOf(usize), @sizeOf(usize), @sizeOf(usize), @sizeOf(usize), @sizeOf(usize), @sizeOf(u32), @sizeOf(f32) };
    try mtl.dispatch(f_brln, .{ rows, 1, 1 }, .{ 256, 1, 1 }, &ptrs, &sz);
}

fn kBias(x: [*]f32, b: [*]f32, n: u32, d: u32) !void {
    var a0 = x;
    var a1 = b;
    var nn = n;
    var nd = d;
    const ptrs = [_]?*const anyopaque{ P(&a0), P(&a1), P(&nn), P(&nd) };
    const sz = [_]usize{ @sizeOf(usize), @sizeOf(usize), @sizeOf(u32), @sizeOf(u32) };
    try mtl.dispatch(f_bias, .{ (n + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &ptrs, &sz);
}

fn kGelu(x: [*]f32, n: u32) !void {
    var a0 = x;
    var nn = n;
    const ptrs = [_]?*const anyopaque{ P(&a0), P(&nn) };
    const sz = [_]usize{ @sizeOf(usize), @sizeOf(u32) };
    try mtl.dispatch(f_gelu, .{ (n + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &ptrs, &sz);
}

fn kFlash(out: [*]f32, q: [*]f32, k: [*]f32, v: [*]f32, seq: u32, hdd: u32, nh: u32) !void {
    var a0 = out;
    var a1 = q;
    var a2 = k;
    var a3 = v;
    var s = seq;
    var hd = hdd;
    var n = nh;
    const ptrs = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&s), P(&hd), P(&n) };
    const sz = [_]usize{ @sizeOf(usize), @sizeOf(usize), @sizeOf(usize), @sizeOf(usize), @sizeOf(u32), @sizeOf(u32), @sizeOf(u32) };
    try mtl.dispatch(f_flash, .{ nh, (seq + 31) / 32, 1 }, .{ 128, 1, 1 }, &ptrs, &sz);
}

// ── CPU reference for one encoder layer ──────────────────────────────
const alloc = std.heap.page_allocator;

fn cpuLayerNorm(x: []const f32, g: []const f32, b: []const f32, y: []f32, d: usize, rows: usize) void {
    for (0..rows) |r| {
        const row = x[r * d .. r * d + d];
        var mean: f32 = 0;
        for (row) |v| mean += v;
        mean /= @floatFromInt(d);
        var va: f32 = 0;
        for (row) |v| va += (v - mean) * (v - mean);
        const inv = 1.0 / @sqrt(va / @as(f32, @floatFromInt(d)) + EPS);
        for (0..d) |i| y[r * d + i] = (row[i] - mean) * inv * g[i] + b[i];
    }
}

fn cpuMatmul(a: []const f32, w: []const f32, c: []f32, m: usize, n: usize, k: usize) void {
    for (0..m) |i| {
        for (0..n) |j| {
            var s: f32 = 0;
            for (0..k) |p| s += a[i * k + p] * w[p * n + j];
            c[i * n + j] = s;
        }
    }
}

fn erfGelu(x: f32) f32 {
    const z = x * 0.7071067811865476;
    const az = @abs(z);
    const sign: f32 = if (z < 0) -1.0 else 1.0;
    const t = 1.0 / (1.0 + 0.3275911 * az);
    var poly: f32 = 1.061405429 * t - 1.453152027;
    poly = poly * t + 1.421413741;
    poly = poly * t - 0.284496736;
    poly = poly * t + 0.254829592;
    poly = poly * t;
    const ex = @exp2(@max(-az * az * 1.4426950408889634, -80.0));
    const erf = sign * (1.0 - poly * ex);
    return 0.5 * x * (1.0 + erf);
}

fn cpuFlash(q: []const f32, k: []const f32, v: []const f32, out: []f32) void {
    const scale: f32 = 0.125;
    for (0..NH) |h| {
        for (0..SEQ) |i| {
            var mi: f32 = -std.math.inf(f32);
            var li: f32 = 0;
            var acc = [_]f32{0} ** HDD;
            for (0..SEQ) |j| {
                var dot: f32 = 0;
                for (0..HDD) |d| dot += q[(i * NH + h) * HDD + d] * k[(j * NH + h) * HDD + d];
                const s = dot * scale;
                const m_new = @max(mi, s);
                const ep = @exp2((mi - m_new) * 1.4426950408889634);
                const ec = @exp2((s - m_new) * 1.4426950408889634);
                li = li * ep + ec;
                for (0..HDD) |d| acc[d] = acc[d] * ep + v[(j * NH + h) * HDD + d] * ec;
                mi = m_new;
            }
            for (0..HDD) |d| out[(i * NH + h) * HDD + d] = acc[d] / li;
        }
    }
}

pub fn main() !void {
    const out = std.io.getStdOut().writer();
    try mtl.init();
    defer mtl.deinit();
    try mtl.loadLibrary(METALLIB);
    f_ln = try mtl.getFunction("layer_norm");
    f_brln = try mtl.getFunction("bias_res_ln");
    f_bias = try mtl.getFunction("bias_add");
    f_gelu = try mtl.getFunction("gelu_f32");
    f_flash = try mtl.getFunction("flash_attention_enc");
    try out.print("[1] encoder kernels loaded\n", .{});

    var rng = std.Random.DefaultPrng.init(123);
    const r = rng.random();
    const mk = struct {
        fn f(rr: std.Random, n: usize, scale: f32) []f32 {
            const s = alloc.alloc(f32, n) catch unreachable;
            for (s) |*v| v.* = (rr.float(f32) * 2 - 1) * scale;
            return s;
        }
    }.f;

    // Host weights (CPU reference uses these directly; GPU gets copies in
    // unified buffers). Weight matrices are [in][out] row-major (== reference).
    const x0 = mk(r, SEQ * D, 1.0);
    const aln_w = mk(r, D, 0.3);
    const aln_b = mk(r, D, 0.1);
    const qkv_w = mk(r, 3 * D * D, 0.05); // stacked Q,K,V each [D][D]
    const q_b = mk(r, D, 0.1);
    const k_b = mk(r, D, 0.1);
    const v_b = mk(r, D, 0.1);
    const o_w = mk(r, D * D, 0.05);
    const o_b = mk(r, D, 0.1);
    const mln_w = mk(r, D, 0.3);
    const mln_b = mk(r, D, 0.1);
    const m0_w = mk(r, D * MLP, 0.04);
    const m0_b = mk(r, MLP, 0.1);
    const m2_w = mk(r, MLP * D, 0.04);
    const m2_b = mk(r, D, 0.1);
    const lnp_w = mk(r, D, 0.3);
    const lnp_b = mk(r, D, 0.1);

    // ── CPU reference ────────────────────────────────────────────────
    const cx = try alloc.dupe(f32, x0);
    const c_ln = try alloc.alloc(f32, SEQ * D);
    cpuLayerNorm(cx, aln_w, aln_b, c_ln, D, SEQ);
    const c_q = try alloc.alloc(f32, SEQ * D);
    const c_k = try alloc.alloc(f32, SEQ * D);
    const c_v = try alloc.alloc(f32, SEQ * D);
    cpuMatmul(c_ln, qkv_w[0 .. D * D], c_q, SEQ, D, D);
    cpuMatmul(c_ln, qkv_w[D * D .. 2 * D * D], c_k, SEQ, D, D);
    cpuMatmul(c_ln, qkv_w[2 * D * D .. 3 * D * D], c_v, SEQ, D, D);
    for (0..SEQ) |i| for (0..D) |j| {
        c_q[i * D + j] += q_b[j];
        c_k[i * D + j] += k_b[j];
        c_v[i * D + j] += v_b[j];
    };
    const c_ao = try alloc.alloc(f32, SEQ * D);
    cpuFlash(c_q, c_k, c_v, c_ao);
    const c_mo = try alloc.alloc(f32, SEQ * D);
    cpuMatmul(c_ao, o_w, c_mo, SEQ, D, D);
    // residual + bias into cx, then LN(mln) → c_ln2
    for (0..SEQ) |i| for (0..D) |j| {
        cx[i * D + j] += c_mo[i * D + j] + o_b[j];
    };
    const c_ln2 = try alloc.alloc(f32, SEQ * D);
    cpuLayerNorm(cx, mln_w, mln_b, c_ln2, D, SEQ);
    const c_mh = try alloc.alloc(f32, SEQ * MLP);
    cpuMatmul(c_ln2, m0_w, c_mh, SEQ, MLP, D);
    for (0..SEQ) |i| for (0..MLP) |j| {
        c_mh[i * MLP + j] = erfGelu(c_mh[i * MLP + j] + m0_b[j]);
    };
    const c_mo2 = try alloc.alloc(f32, SEQ * D);
    cpuMatmul(c_mh, m2_w, c_mo2, SEQ, D, MLP);
    for (0..SEQ) |i| for (0..D) |j| {
        cx[i * D + j] += c_mo2[i * D + j] + m2_b[j];
    };
    const c_out = try alloc.alloc(f32, SEQ * D);
    cpuLayerNorm(cx, lnp_w, lnp_b, c_out, D, SEQ); // final ln_post

    // ── GPU ──────────────────────────────────────────────────────────
    const g = struct {
        fn up(src: []const f32) [*]f32 {
            const b = mtl.allocSlice(f32, src.len) catch unreachable;
            @memcpy(b, src);
            return b.ptr;
        }
    }.up;
    const d_x = g(x0);
    const d_alnw = g(aln_w);
    const d_alnb = g(aln_b);
    const d_qkvw = g(qkv_w);
    const d_qb = g(q_b);
    const d_kb = g(k_b);
    const d_vb = g(v_b);
    const d_ow = g(o_w);
    const d_ob = g(o_b);
    const d_mlnw = g(mln_w);
    const d_mlnb = g(mln_b);
    const d_m0w = g(m0_w);
    const d_m0b = g(m0_b);
    const d_m2w = g(m2_w);
    const d_m2b = g(m2_b);
    const d_lnpw = g(lnp_w);
    const d_lnpb = g(lnp_b);
    const d_ln = (try mtl.allocSlice(f32, SEQ * D)).ptr;
    const d_qkv = (try mtl.allocSlice(f32, 3 * SEQ * D)).ptr;
    const d_ao = (try mtl.allocSlice(f32, SEQ * D)).ptr;
    const d_mo = (try mtl.allocSlice(f32, SEQ * D)).ptr;
    const d_mh = (try mtl.allocSlice(f32, SEQ * MLP)).ptr;
    const d_out = (try mtl.allocSlice(f32, SEQ * D)).ptr;
    const d_q = d_qkv;
    const d_k = d_qkv + SEQ * D;
    const d_v = d_qkv + 2 * SEQ * D;

    // 1. initial attn LN
    try mtl.beginCommandBuffer();
    try kLN(d_x, d_ln, d_alnw, d_alnb, D, SEQ);
    try mtl.commitCommandBuffer();
    try mtl.sync();
    // 2. QKV matmuls (MPS)
    try mtl.matmul(d_ln, d_qkvw, d_q, SEQ, D, D);
    try mtl.matmul(d_ln, d_qkvw + D * D, d_k, SEQ, D, D);
    try mtl.matmul(d_ln, d_qkvw + 2 * D * D, d_v, SEQ, D, D);
    // 3. bias + flash attn
    try mtl.beginCommandBuffer();
    try kBias(d_q, d_qb, SEQ * D, D);
    try kBias(d_k, d_kb, SEQ * D, D);
    try kBias(d_v, d_vb, SEQ * D, D);
    try kFlash(d_ao, d_q, d_k, d_v, SEQ, HDD, NH);
    try mtl.commitCommandBuffer();
    try mtl.sync();
    // 4. out proj
    try mtl.matmul(d_ao, d_ow, d_mo, SEQ, D, D);
    // 5. residual+bias+LN(mln)
    try mtl.beginCommandBuffer();
    try kBiasResLN(d_x, d_mo, d_ob, d_ln, d_mlnw, d_mlnb, D, SEQ);
    try mtl.commitCommandBuffer();
    try mtl.sync();
    // 6. FFN up
    try mtl.matmul(d_ln, d_m0w, d_mh, SEQ, MLP, D);
    try mtl.beginCommandBuffer();
    try kBias(d_mh, d_m0b, SEQ * MLP, MLP);
    try kGelu(d_mh, SEQ * MLP);
    try mtl.commitCommandBuffer();
    try mtl.sync();
    // 7. FFN down
    try mtl.matmul(d_mh, d_m2w, d_mo, SEQ, D, MLP);
    // 8. residual+bias+final ln_post → d_out
    try mtl.beginCommandBuffer();
    try kBiasResLN(d_x, d_mo, d_m2b, d_out, d_lnpw, d_lnpb, D, SEQ);
    try mtl.commitCommandBuffer();
    try mtl.sync();

    // ── compare ──────────────────────────────────────────────────────
    var max_err: f32 = 0;
    var max_rel: f32 = 0;
    for (0..SEQ * D) |i| {
        const e = @abs(d_out[i] - c_out[i]);
        if (e > max_err) max_err = e;
        const denom = @max(@abs(c_out[i]), 1e-3);
        const rel = e / denom;
        if (rel > max_rel) max_rel = rel;
    }
    try out.print("encoder 1-layer ({d}×{d}, {d} heads, MLP {d}): max_abs_err={e}, max_rel_err={e}\n", .{ SEQ, D, NH, MLP, max_err, max_rel });
    if (max_err < 1e-3 and max_rel < 1e-3) {
        try out.print("✅ ENCODER LAYER OK — GPU(MPS+kernels) matches CPU reference\n", .{});
    } else {
        try out.print("❌ ENCODER LAYER FAIL\n", .{});
        return error.EncoderMismatch;
    }
}
