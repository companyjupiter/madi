// encoder.zig — Whisper encoder (32 layers) on Metal, F16 fast path.
// Activations carried as F16 (projection GEMMs via MPS F16, attention via
// simdgroup_half8x8); the residual stream X and the final enc_out stay F32 for
// numerical stability (and so the F32 decoder is untouched). Reductions inside
// the kernels accumulate in float.
//
// Layout (row-major, == reference): residual x[M][D] F32; x_ln/qkv/ao/mo/mh F16;
// projection weights [in][out] F16; biases + LN weights F32.
const std = @import("std");
const mtl = @import("metal_backend.zig");

pub const D: u32 = 1280;
pub const NH: u32 = 20;
pub const HDD: u32 = 64;
pub const MLP: u32 = 5120;
pub const ENC_SEQ: u32 = 1500;
pub const ENL: u32 = 32;
const EPS: f32 = 1e-5;

pub const Kernels = struct {
    ln: mtl.Function,
    brln: mtl.Function,
    bias: mtl.Function,
    gelu: mtl.Function,
    flash: mtl.Function,
    cvt: mtl.Function,

    pub fn load() mtl.Error!Kernels {
        return .{
            .ln = try mtl.getFunction("layer_norm_f16"),
            .brln = try mtl.getFunction("bias_res_ln_f16"),
            .bias = try mtl.getFunction("bias_add_f16"),
            .gelu = try mtl.getFunction("gelu_f16"),
            .flash = try mtl.getFunction("flash_attention_enc_f16"),
            .cvt = try mtl.getFunction("cvt_f16_f32"),
        };
    }
};

/// Per-layer weights: projection matrices F16 (`*_w`), biases + LN weights F32.
pub const Layer = struct {
    aln_w: [*]f32,
    aln_b: [*]f32,
    qkv_w: [*]f16,
    q_b: [*]f32,
    k_b: [*]f32,
    v_b: [*]f32,
    o_w: [*]f16,
    o_b: [*]f32,
    mln_w: [*]f32,
    mln_b: [*]f32,
    m0_w: [*]f16,
    m0_b: [*]f32,
    m2_w: [*]f16,
    m2_b: [*]f32,
};

/// Scratch (F16 activations), sized for M = batch_count * ENC_SEQ.
pub const Scratch = struct {
    x_ln: [*]f16,
    qkv: [*]f16, // [3][M][D]
    ao: [*]f16,
    mo: [*]f16,
    mh: [*]f16,
};

inline fn P(x: anytype) ?*const anyopaque {
    return @ptrCast(x);
}
const PS = @sizeOf(usize);
const U = @sizeOf(u32);
const Ff = @sizeOf(f32);

fn kLN(K: Kernels, x: [*]f32, y: [*]f16, g: [*]f32, b: [*]f32, d: u32, rows: u32) !void {
    var a0 = x; var a1 = y; var a2 = g; var a3 = b; var nd = d; var ne = EPS;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&nd), P(&ne) };
    const s = [_]usize{ PS, PS, PS, PS, U, Ff };
    try mtl.dispatch(K.ln, .{ rows, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kBRLN(K: Kernels, x: [*]f32, mo: [*]f16, bias: [*]f32, y: [*]f16, g: [*]f32, b: [*]f32, d: u32, rows: u32) !void {
    var a0 = x; var a1 = mo; var a2 = bias; var a3 = y; var a4 = g; var a5 = b; var nd = d; var ne = EPS;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&a4), P(&a5), P(&nd), P(&ne) };
    const s = [_]usize{ PS, PS, PS, PS, PS, PS, U, Ff };
    try mtl.dispatch(K.brln, .{ rows, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kBias(K: Kernels, x: [*]f16, b: [*]f32, n: u32, d: u32) !void {
    var a0 = x; var a1 = b; var nn = n; var nd = d;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&nn), P(&nd) };
    const s = [_]usize{ PS, PS, U, U };
    try mtl.dispatch(K.bias, .{ (n + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kGelu(K: Kernels, x: [*]f16, n: u32) !void {
    var a0 = x; var nn = n;
    const p = [_]?*const anyopaque{ P(&a0), P(&nn) };
    const s = [_]usize{ PS, U };
    try mtl.dispatch(K.gelu, .{ (n + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kFlash(K: Kernels, out: [*]f16, q: [*]f16, k: [*]f16, v: [*]f16, seq: u32) !void {
    var a0 = out; var a1 = q; var a2 = k; var a3 = v; var sq = seq; var hd = HDD; var n = NH;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&sq), P(&hd), P(&n) };
    const s = [_]usize{ PS, PS, PS, PS, U, U, U };
    try mtl.dispatch(K.flash, .{ NH, (seq + 31) / 32, 1 }, .{ 128, 1, 1 }, &p, &s);
}
fn kCvt(K: Kernels, dst: [*]f32, src: [*]f16, n: u32) !void {
    var a0 = dst; var a1 = src; var nn = n;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&nn) };
    const s = [_]usize{ PS, PS, U };
    try mtl.dispatch(K.cvt, .{ (n + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}

/// Run the encoder. `x` (F32 residual, pos-emb already added) in/out; final
/// ln_post written F16 into `out_f16` then converted to F32 `enc_out`.
/// One batched command buffer per layer, single sync at the layer boundary.
pub fn forward(
    K: Kernels,
    layers: []const Layer,
    lnp_w: [*]f32,
    lnp_b: [*]f32,
    x: [*]f32,
    out_f16: [*]f16,
    enc_out: [*]f32,
    s: Scratch,
    batch_count: u32,
) !void {
    const M = batch_count * ENC_SEQ;
    const q = s.qkv;
    const k = s.qkv + @as(usize, M) * D;
    const v = s.qkv + 2 * @as(usize, M) * D;

    try mtl.beginCommandBuffer();
    try kLN(K, x, s.x_ln, layers[0].aln_w, layers[0].aln_b, D, M);

    for (layers, 0..) |L, li| {
        try mtl.matmulF16Batched(s.x_ln, L.qkv_w, q, M, D, D);
        try mtl.matmulF16Batched(s.x_ln, L.qkv_w + @as(usize, D) * D, k, M, D, D);
        try mtl.matmulF16Batched(s.x_ln, L.qkv_w + 2 * @as(usize, D) * D, v, M, D, D);
        try kBias(K, q, L.q_b, M * D, D);
        try kBias(K, k, L.k_b, M * D, D);
        try kBias(K, v, L.v_b, M * D, D);
        for (0..batch_count) |bi| {
            const off = bi * ENC_SEQ * D;
            try kFlash(K, s.ao + off, q + off, k + off, v + off, ENC_SEQ);
        }
        try mtl.matmulF16Batched(s.ao, L.o_w, s.mo, M, D, D);
        try kBRLN(K, x, s.mo, L.o_b, s.x_ln, L.mln_w, L.mln_b, D, M);
        try mtl.matmulF16Batched(s.x_ln, L.m0_w, s.mh, M, MLP, D);
        try kBias(K, s.mh, L.m0_b, M * MLP, MLP);
        try kGelu(K, s.mh, M * MLP);
        try mtl.matmulF16Batched(s.mh, L.m2_w, s.mo, M, D, MLP);
        if (li + 1 < layers.len) {
            try kBRLN(K, x, s.mo, L.m2_b, s.x_ln, layers[li + 1].aln_w, layers[li + 1].aln_b, D, M);
        } else {
            try kBRLN(K, x, s.mo, L.m2_b, out_f16, lnp_w, lnp_b, D, M);
            try kCvt(K, enc_out, out_f16, M * D);
        }
        try mtl.commitCommandBuffer();
        try mtl.sync();
        if (li + 1 < layers.len) try mtl.beginCommandBuffer();
    }
}
