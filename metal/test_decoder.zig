// test_decoder.zig — one full decoder block (self-attn + cross-attn + MLP) on
// the GPU vs an independent CPU reference. Exercises every new M3 kernel:
//   gpu_residual, gpu_kv_store, gpu_attention (self), flash_cross_attn,
//   plus reused layer_norm / bias_add / bias_res_ln / gelu_f32 and MPS GEMV.
// Asset-free, tiny dims.
const std = @import("std");
const mtl = @import("metal_backend.zig");

const METALLIB = @embedFile("whisper.metallib");
const NH: u32 = 2;
const HDD: u32 = 8;
const D: u32 = NH * HDD; // 16
const MLP: u32 = 32;
const ENC: u32 = 10; // cross-attn encoder seqlen
const POS: u32 = 3; // current token index (4 cached self positions: 0..3)
const EPS: f32 = 1e-5;
const alloc = std.heap.page_allocator;

var f_ln: mtl.Function = undefined;
var f_brln: mtl.Function = undefined;
var f_bias: mtl.Function = undefined;
var f_gelu: mtl.Function = undefined;
var f_res: mtl.Function = undefined;
var f_store: mtl.Function = undefined;
var f_attn: mtl.Function = undefined;
var f_ca: mtl.Function = undefined;

fn P(x: anytype) ?*const anyopaque {
    return @ptrCast(x);
}
const PS = @sizeOf(usize);
const U = @sizeOf(u32);
const F = @sizeOf(f32);

fn kLN(x: [*]f32, y: [*]f32, g: [*]f32, b: [*]f32, d: u32, rows: u32) !void {
    var a0 = x; var a1 = y; var a2 = g; var a3 = b; var nd = d; var ne = EPS;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&nd), P(&ne) };
    const s = [_]usize{ PS, PS, PS, PS, U, F };
    try mtl.dispatch(f_ln, .{ rows, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kBRLN(x: [*]f32, mo: [*]f32, bias: [*]f32, y: [*]f32, g: [*]f32, b: [*]f32, d: u32, rows: u32) !void {
    var a0 = x; var a1 = mo; var a2 = bias; var a3 = y; var a4 = g; var a5 = b; var nd = d; var ne = EPS;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&a4), P(&a5), P(&nd), P(&ne) };
    const s = [_]usize{ PS, PS, PS, PS, PS, PS, U, F };
    try mtl.dispatch(f_brln, .{ rows, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kBias(x: [*]f32, b: [*]f32, n: u32, d: u32) !void {
    var a0 = x; var a1 = b; var nn = n; var nd = d;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&nn), P(&nd) };
    const s = [_]usize{ PS, PS, U, U };
    try mtl.dispatch(f_bias, .{ (n + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kGelu(x: [*]f32, n: u32) !void {
    var a0 = x; var nn = n;
    const p = [_]?*const anyopaque{ P(&a0), P(&nn) };
    const s = [_]usize{ PS, U };
    try mtl.dispatch(f_gelu, .{ (n + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kRes(x: [*]f32, y: [*]f32, n: u32) !void {
    var a0 = x; var a1 = y; var nn = n;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&nn) };
    const s = [_]usize{ PS, PS, U };
    try mtl.dispatch(f_res, .{ (n + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kStore(cache: [*]f32, src: [*]f32, kvd: u32, pos: [*]u32) !void {
    var a0 = cache; var a1 = src; var nk = kvd; var a3 = pos;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&nk), P(&a3) };
    const s = [_]usize{ PS, PS, U, PS };
    try mtl.dispatch(f_store, .{ (kvd + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kAttn(out: [*]f32, q: [*]f32, kc: [*]f32, vc: [*]f32, pos: [*]u32) !void {
    var a0 = out; var a1 = q; var a2 = kc; var a3 = vc; var a4 = pos;
    var hd = HDD; var kvd = D; var nkv = NH; var nh = NH;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&a4), P(&hd), P(&kvd), P(&nkv), P(&nh) };
    const s = [_]usize{ PS, PS, PS, PS, PS, U, U, U, U };
    try mtl.dispatch(f_attn, .{ NH, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kFlashCA(out: [*]f32, q: [*]f32, kc: [*]f32, vc: [*]f32, seqlen: u32) !void {
    var a0 = out; var a1 = q; var a2 = kc; var a3 = vc; var sl = seqlen;
    var hd = HDD; var kvd = D; var nkv = NH; var nh = NH;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&sl), P(&hd), P(&kvd), P(&nkv), P(&nh) };
    const s = [_]usize{ PS, PS, PS, PS, U, U, U, U, U };
    try mtl.dispatch(f_ca, .{ NH, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}

// ── CPU reference ────────────────────────────────────────────────────
fn cpuLN(x: []const f32, g: []const f32, b: []const f32, y: []f32) void {
    var mean: f32 = 0;
    for (x) |v| mean += v;
    mean /= @floatFromInt(D);
    var va: f32 = 0;
    for (x) |v| va += (v - mean) * (v - mean);
    const inv = 1.0 / @sqrt(va / @as(f32, D) + EPS);
    for (0..D) |i| y[i] = (x[i] - mean) * inv * g[i] + b[i];
}
fn cpuGemv(x: []const f32, w: []const f32, y: []f32, k: usize, n: usize) void {
    for (0..n) |j| {
        var s: f32 = 0;
        for (0..k) |p| s += x[p] * w[p * n + j];
        y[j] = s;
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
    return 0.5 * x * (1.0 + sign * (1.0 - poly * ex));
}
fn cpuAttn(q: []const f32, kc: []const f32, vc: []const f32, npos: usize, out: []f32) void {
    const rsq = 1.0 / @sqrt(@as(f32, HDD));
    for (0..NH) |h| {
        var sc = alloc.alloc(f32, npos) catch unreachable;
        defer alloc.free(sc);
        var mx: f32 = -std.math.inf(f32);
        for (0..npos) |t| {
            var d: f32 = 0;
            for (0..HDD) |e| d += q[h * HDD + e] * kc[t * D + h * HDD + e];
            sc[t] = d * rsq;
            if (sc[t] > mx) mx = sc[t];
        }
        var sum: f32 = 0;
        for (0..npos) |t| {
            sc[t] = @exp2((sc[t] - mx) * 1.4426950408889634);
            sum += sc[t];
        }
        for (0..HDD) |e| {
            var acc: f32 = 0;
            for (0..npos) |t| acc += (sc[t] / sum) * vc[t * D + h * HDD + e];
            out[h * HDD + e] = acc;
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
    f_res = try mtl.getFunction("gpu_residual");
    f_store = try mtl.getFunction("gpu_kv_store");
    f_attn = try mtl.getFunction("gpu_attention");
    f_ca = try mtl.getFunction("flash_cross_attn");
    try out.print("[1] decoder kernels loaded\n", .{});

    var rng = std.Random.DefaultPrng.init(99);
    const r = rng.random();
    const mk = struct {
        fn f(rr: std.Random, n: usize, sc: f32) []f32 {
            const s = alloc.alloc(f32, n) catch unreachable;
            for (s) |*v| v.* = (rr.float(f32) * 2 - 1) * sc;
            return s;
        }
    }.f;

    const x0 = mk(r, D, 1.0);
    const aln_w = mk(r, D, 0.3); const aln_b = mk(r, D, 0.1);
    const qw = mk(r, D * D, 0.2); const qb = mk(r, D, 0.1);
    const kw = mk(r, D * D, 0.2);
    const vw = mk(r, D * D, 0.2); const vb = mk(r, D, 0.1);
    const ow = mk(r, D * D, 0.2); const ob = mk(r, D, 0.1);
    const caln_w = mk(r, D, 0.3); const caln_b = mk(r, D, 0.1);
    const cqw = mk(r, D * D, 0.2); const cqb = mk(r, D, 0.1);
    const cow = mk(r, D * D, 0.2); const cob = mk(r, D, 0.1);
    const mln_w = mk(r, D, 0.3); const mln_b = mk(r, D, 0.1);
    const m0w = mk(r, D * MLP, 0.15); const m0b = mk(r, MLP, 0.1);
    const m2w = mk(r, MLP * D, 0.15); const m2b = mk(r, D, 0.1);
    // pre-cached self K/V for positions 0..POS-1, cross K/V for ENC positions
    const skc0 = mk(r, POS * D, 0.5); const svc0 = mk(r, POS * D, 0.5);
    const ckc = mk(r, ENC * D, 0.5); const cvc = mk(r, ENC * D, 0.5);

    // ── CPU reference ────────────────────────────────────────────────
    const cx = try alloc.dupe(f32, x0);
    const xb = try alloc.alloc(f32, D);
    cpuLN(cx, aln_w, aln_b, xb);
    const cq = try alloc.alloc(f32, D);
    const ck = try alloc.alloc(f32, D);
    const cv = try alloc.alloc(f32, D);
    cpuGemv(xb, qw, cq, D, D);
    cpuGemv(xb, kw, ck, D, D);
    cpuGemv(xb, vw, cv, D, D);
    for (0..D) |i| { cq[i] += qb[i]; cv[i] += vb[i]; }
    // build self KV cache: [0..POS) pre-cached, [POS] = current
    const skc = try alloc.alloc(f32, (POS + 1) * D);
    const svc = try alloc.alloc(f32, (POS + 1) * D);
    @memcpy(skc[0 .. POS * D], skc0);
    @memcpy(svc[0 .. POS * D], svc0);
    @memcpy(skc[POS * D ..], ck);
    @memcpy(svc[POS * D ..], cv);
    const cao = try alloc.alloc(f32, D);
    cpuAttn(cq, skc, svc, POS + 1, cao);
    const cmo = try alloc.alloc(f32, D);
    cpuGemv(cao, ow, cmo, D, D);
    for (0..D) |i| cx[i] += cmo[i] + ob[i];
    cpuLN(cx, caln_w, caln_b, xb);
    // cross-attn
    cpuGemv(xb, cqw, cq, D, D);
    for (0..D) |i| cq[i] += cqb[i];
    cpuAttn(cq, ckc, cvc, ENC, cao);
    cpuGemv(cao, cow, cmo, D, D);
    for (0..D) |i| cx[i] += cmo[i] + cob[i];
    cpuLN(cx, mln_w, mln_b, xb);
    // MLP
    const cmh = try alloc.alloc(f32, MLP);
    cpuGemv(xb, m0w, cmh, D, MLP);
    for (0..MLP) |i| cmh[i] = erfGelu(cmh[i] + m0b[i]);
    cpuGemv(cmh, m2w, cmo, MLP, D);
    for (0..D) |i| cx[i] += cmo[i] + m2b[i];

    // ── GPU ──────────────────────────────────────────────────────────
    const g = struct {
        fn up(src: []const f32) [*]f32 {
            const b = mtl.allocSlice(f32, src.len) catch unreachable;
            @memcpy(b, src);
            return b.ptr;
        }
    }.up;
    const d_x = g(x0);
    const d_alnw = g(aln_w); const d_alnb = g(aln_b);
    const d_qw = g(qw); const d_qb = g(qb);
    const d_kw = g(kw);
    const d_vw = g(vw); const d_vb = g(vb);
    const d_ow = g(ow); const d_ob = g(ob);
    const d_calnw = g(caln_w); const d_calnb = g(caln_b);
    const d_cqw = g(cqw); const d_cqb = g(cqb);
    const d_cow = g(cow); const d_cob = g(cob);
    const d_mlnw = g(mln_w); const d_mlnb = g(mln_b);
    const d_m0w = g(m0w); const d_m0b = g(m0b);
    const d_m2w = g(m2w); const d_m2b = g(m2b);
    const d_ckc = g(ckc); const d_cvc = g(cvc);
    // self KV cache buffers sized (POS+1)*D, prefill 0..POS
    const d_skc = mtl.allocSlice(f32, (POS + 1) * D) catch unreachable;
    const d_svc = mtl.allocSlice(f32, (POS + 1) * D) catch unreachable;
    @memcpy(d_skc[0 .. POS * D], skc0);
    @memcpy(d_svc[0 .. POS * D], svc0);
    const d_xb = (try mtl.allocSlice(f32, D)).ptr;
    const d_q = (try mtl.allocSlice(f32, D)).ptr;
    const d_k = (try mtl.allocSlice(f32, D)).ptr;
    const d_v = (try mtl.allocSlice(f32, D)).ptr;
    const d_ao = (try mtl.allocSlice(f32, D)).ptr;
    const d_mo = (try mtl.allocSlice(f32, D)).ptr;
    const d_mh = (try mtl.allocSlice(f32, MLP)).ptr;
    const d_pos = (try mtl.allocSlice(u32, 1)).ptr;
    d_pos[0] = POS;

    // self-attn LN
    try mtl.beginCommandBuffer();
    try kLN(d_x, d_xb, d_alnw, d_alnb, D, 1);
    try mtl.commitCommandBuffer();
    try mtl.sync();
    // Q,K,V (MPS GEMV M=1)
    try mtl.matmul(d_xb, d_qw, d_q, 1, D, D);
    try mtl.matmul(d_xb, d_kw, d_k, 1, D, D);
    try mtl.matmul(d_xb, d_vw, d_v, 1, D, D);
    try mtl.beginCommandBuffer();
    try kBias(d_q, d_qb, D, D);
    try kBias(d_v, d_vb, D, D);
    try kStore(d_skc.ptr, d_k, D, d_pos);
    try kStore(d_svc.ptr, d_v, D, d_pos);
    try kAttn(d_ao, d_q, d_skc.ptr, d_svc.ptr, d_pos);
    try mtl.commitCommandBuffer();
    try mtl.sync();
    // out proj + residual + cross LN
    try mtl.matmul(d_ao, d_ow, d_mo, 1, D, D);
    try mtl.beginCommandBuffer();
    try kBRLN(d_x, d_mo, d_ob, d_xb, d_calnw, d_calnb, D, 1);
    try mtl.commitCommandBuffer();
    try mtl.sync();
    // cross-attn
    try mtl.matmul(d_xb, d_cqw, d_q, 1, D, D);
    try mtl.beginCommandBuffer();
    try kBias(d_q, d_cqb, D, D);
    try kFlashCA(d_ao, d_q, d_ckc, d_cvc, ENC);
    try mtl.commitCommandBuffer();
    try mtl.sync();
    try mtl.matmul(d_ao, d_cow, d_mo, 1, D, D);
    try mtl.beginCommandBuffer();
    try kBRLN(d_x, d_mo, d_cob, d_xb, d_mlnw, d_mlnb, D, 1);
    try mtl.commitCommandBuffer();
    try mtl.sync();
    // MLP
    try mtl.matmul(d_xb, d_m0w, d_mh, 1, MLP, D);
    try mtl.beginCommandBuffer();
    try kBias(d_mh, d_m0b, MLP, MLP);
    try kGelu(d_mh, MLP);
    try mtl.commitCommandBuffer();
    try mtl.sync();
    try mtl.matmul(d_mh, d_m2w, d_mo, 1, D, MLP);
    try mtl.beginCommandBuffer();
    try kBias(d_mo, d_m2b, D, D);
    try kRes(d_x, d_mo, D);
    try mtl.commitCommandBuffer();
    try mtl.sync();

    // compare
    var max_err: f32 = 0;
    var max_rel: f32 = 0;
    for (0..D) |i| {
        const e = @abs(d_x[i] - cx[i]);
        if (e > max_err) max_err = e;
        const rel = e / @max(@abs(cx[i]), 1e-3);
        if (rel > max_rel) max_rel = rel;
    }
    try out.print("decoder block (D={d}, {d} heads, hdd={d}, self_pos={d}, cross_seq={d}): max_abs_err={e}, max_rel_err={e}\n", .{ D, NH, HDD, POS + 1, ENC, max_err, max_rel });
    if (max_err < 1e-3 and max_rel < 1e-3) {
        try out.print("✅ DECODER BLOCK OK — GPU matches CPU reference\n", .{});
    } else {
        try out.print("❌ DECODER BLOCK FAIL\n", .{});
        return error.DecoderMismatch;
    }
}
