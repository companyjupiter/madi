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

/// Q8_0 weight: int8 quants [out][in] + per-32 fp16 scale [out][in/32].
pub const Q8 = struct { qs: [*]i8, scales: [*]f16 };

pub const Kernels = struct {
    ln: mtl.Function,
    brln: mtl.Function,
    bias: mtl.Function,
    gelu: mtl.Function,
    flash: mtl.Function,
    cvt: mtl.Function,
    deq: mtl.Function,
    // Metal 4 tensor-ops GEMMs (ENC_M4=0 falls back to MPS)
    m4_nn: ?mtl.Function,
    m4_bias: ?mtl.Function,
    m4_bias_gelu: ?mtl.Function,
    m4_flash: ?mtl.Function,

    pub fn load() mtl.Error!Kernels {
        const m4_off = if (std.posix.getenv("ENC_M4")) |v| v[0] == '0' else false;
        const m4f_off = if (std.posix.getenv("ENC_M4F")) |v| v[0] == '0' else false; // flash-only rollback
        return .{
            .ln = try mtl.getFunction("layer_norm_f16"),
            .brln = try mtl.getFunction("bias_res_ln_f16"),
            .bias = try mtl.getFunction("bias_add_f16"),
            .gelu = try mtl.getFunction("gelu_f16"),
            .flash = try mtl.getFunction("flash_attention_enc_f16"),
            .cvt = try mtl.getFunction("cvt_f16_f32"),
            .deq = try mtl.getFunction("dequant_q8_f16"),
            .m4_nn = if (m4_off) null else mtl.getFunction("m4_gemm_nn") catch null,
            .m4_bias = if (m4_off) null else mtl.getFunction("m4_gemm_bias") catch null,
            .m4_bias_gelu = if (m4_off) null else mtl.getFunction("m4_gemm_bias_gelu") catch null,
            .m4_flash = if (m4_off or m4f_off) null else mtl.getFunction("m4_flash_enc") catch null,
        };
    }
};

/// Per-layer weights: projection matrices Q8 (`*_w`, out-major), JIT-dequanted to
/// an F16 scratch right before each MPS GEMM; biases + LN weights F32.
pub const Layer = struct {
    aln_w: [*]f32,
    aln_b: [*]f32,
    qkv_w: Q8, // stacked [3D][D] out-major (q|k|v)
    q_b: [*]f32,
    k_b: [*]f32,
    v_b: [*]f32,
    o_w: Q8, // [D][D]
    o_b: [*]f32,
    mln_w: [*]f32,
    mln_b: [*]f32,
    m0_w: Q8, // [MLP][D]
    m0_b: [*]f32,
    m2_w: Q8, // [D][MLP]
    m2_b: [*]f32,
    // Optional high-memory performance cache in Metal GEMM [K][N] layout.
    q_f16: ?[*]f16 = null,
    k_f16: ?[*]f16 = null,
    v_f16: ?[*]f16 = null,
    o_f16: ?[*]f16 = null,
    m0_f16: ?[*]f16 = null,
    m2_f16: ?[*]f16 = null,
};

/// Scratch (F16 activations), sized for M = batch_count * ENC_SEQ.
/// `wdq` holds one JIT-dequanted weight tile [K][N] f16 (max MLP*D).
pub const Scratch = struct {
    x_ln: [*]f16,
    qkv: [*]f16, // [3][M][D]
    ao: [*]f16,
    mo: [*]f16,
    mh: [*]f16,
    wdq: [*]f16, // weight dequant scratch, size >= MLP*D
    wdq2: [*]f16, // second tile — lets the next dequant overlap the previous GEMM
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
fn kM4(f: mtl.Function, a: [*]f16, b: [*]f16, c: [*]f16, m: u32, n: u32, k: u32) !void {
    var a0 = a; var a1 = b; var a2 = c; var mm = m; var nn = n; var kk = k;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&mm), P(&nn), P(&kk) };
    const sz = [_]usize{ PS, PS, PS, U, U, U };
    try mtl.dispatch(f, .{ (n + 63) / 64, (m + 63) / 64, 1 }, .{ 128, 1, 1 }, &p, &sz);
}
fn kM4Bias(f: mtl.Function, a: [*]f16, b: [*]f16, c: [*]f16, bias: [*]f32, m: u32, n: u32, k: u32) !void {
    var a0 = a; var a1 = b; var a2 = c; var a3 = bias; var mm = m; var nn = n; var kk = k;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&mm), P(&nn), P(&kk) };
    const sz = [_]usize{ PS, PS, PS, PS, U, U, U };
    try mtl.dispatch(f, .{ (n + 63) / 64, (m + 63) / 64, 1 }, .{ 128, 1, 1 }, &p, &sz);
}

fn kFlash(K: Kernels, out: [*]f16, q: [*]f16, k: [*]f16, v: [*]f16, seq: u32) !void {
    var a0 = out; var a1 = q; var a2 = k; var a3 = v; var sq = seq; var n = NH;
    if (K.m4_flash) |m4f| {
        // tensor-ops 64-q-tile kernel; q/k/v come from the padded qkv scratch
        // (tail tiles read ≤ 36 rows past seq — see Scratch alloc)
        const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&sq), P(&n) };
        const s = [_]usize{ PS, PS, PS, PS, U, U };
        try mtl.dispatch(m4f, .{ NH, (seq + 63) / 64, 1 }, .{ 128, 1, 1 }, &p, &s);
        return;
    }
    var hd = HDD;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&sq), P(&hd), P(&n) };
    const s = [_]usize{ PS, PS, PS, PS, U, U, U };
    try mtl.dispatch(K.flash, .{ NH, (seq + 31) / 32, 1 }, .{ 128, 1, 1 }, &p, &s);
}
/// Dequant Q8 weight [out=N][in=K] → F16 wdq [K][N] (MPS B layout).
fn kDeq(K: Kernels, wdq: [*]f16, w: Q8, n: u32, k: u32) !void {
    var a0 = wdq; var a1 = w.qs; var a2 = w.scales; var nn = n; var kk = k;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&nn), P(&kk) };
    const s = [_]usize{ PS, PS, PS, U, U };
    try mtl.dispatch(K.deq, .{ (n * k + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kCvt(K: Kernels, dst: [*]f32, src: [*]f16, n: u32) !void {
    var a0 = dst; var a1 = src; var nn = n;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&nn) };
    const s = [_]usize{ PS, PS, U };
    try mtl.dispatch(K.cvt, .{ (n + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}

/// Expand encoder Q8 weights once for the 24GB+ performance mode (~1.25GB).
pub fn cacheWeights(K: Kernels, layers: []Layer) !void {
    const d2 = @as(usize, D) * D;
    const dnb = @as(usize, D) / 32;
    for (layers) |*L| {
        L.q_f16 = (try mtl.allocSlice(f16, d2)).ptr;
        L.k_f16 = (try mtl.allocSlice(f16, d2)).ptr;
        L.v_f16 = (try mtl.allocSlice(f16, d2)).ptr;
        L.o_f16 = (try mtl.allocSlice(f16, d2)).ptr;
        L.m0_f16 = (try mtl.allocSlice(f16, @as(usize, MLP) * D)).ptr;
        L.m2_f16 = (try mtl.allocSlice(f16, @as(usize, MLP) * D)).ptr;
        try mtl.beginCommandBuffer();
        try kDeq(K, L.q_f16.?, L.qkv_w, D, D);
        try kDeq(K, L.k_f16.?, .{ .qs = L.qkv_w.qs + d2, .scales = L.qkv_w.scales + @as(usize, D) * dnb }, D, D);
        try kDeq(K, L.v_f16.?, .{ .qs = L.qkv_w.qs + 2 * d2, .scales = L.qkv_w.scales + 2 * @as(usize, D) * dnb }, D, D);
        try kDeq(K, L.o_f16.?, L.o_w, D, D);
        try kDeq(K, L.m0_f16.?, L.m0_w, MLP, D);
        try kDeq(K, L.m2_f16.?, L.m2_w, D, MLP);
        try mtl.commitCommandBuffer();
        try mtl.sync();
    }
}

/// Run the encoder. `x` (F32 residual, pos-emb already added) in/out; final
/// ln_post written F16 into `out_f16` then converted to F32 `enc_out`.
/// One batched command buffer per layer, single sync at the layer boundary.
///
/// `seq` — encoder positions per batch slot (≤ ENC_SEQ). The whisper.cpp
/// `audio_ctx` pattern: a short live segment only occupies its leading rows
/// (row r = t·0.02 s), so running the layers on `seq` rows skips the zero-pad
/// tail entirely. Callers pass ENC_SEQ for the exact full-window path; with
/// batch_count > 1 the d_ex slot stride is ENC_SEQ so seq MUST be ENC_SEQ.
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
    seq: u32,
) !void {
    std.debug.assert(seq == ENC_SEQ or batch_count == 1);
    const M = batch_count * seq;
    const q = s.qkv;
    const k = s.qkv + @as(usize, M) * D;
    const v = s.qkv + 2 * @as(usize, M) * D;

    try mtl.beginCommandBuffer();
    try kLN(K, x, s.x_ln, layers[0].aln_w, layers[0].aln_b, D, M);

    const dnb = @as(usize, D) / 32; // scale blocks per D-length row
    for (layers, 0..) |L, li| {
        // q/k/v: dequant Q8 slice of stacked qkv_w → wdq, then GEMM(+bias).
        // Metal4 tensor-ops path fuses the bias epilogue into the GEMM tile
        // while it is cache-hot (MPS + separate bias_add_f16 = an extra full
        // M×D memory pass each); ENC_M4=0 reverts to MPS.
        if (K.m4_bias) |m4b| {
            if (L.q_f16 == null) try kDeq(K, s.wdq, L.qkv_w, D, D);
            try kM4Bias(m4b, s.x_ln, L.q_f16 orelse s.wdq, q, L.q_b, M, D, D);
            if (L.k_f16 == null) try kDeq(K, s.wdq2, .{ .qs = L.qkv_w.qs + @as(usize, D) * D, .scales = L.qkv_w.scales + @as(usize, D) * dnb }, D, D);
            try kM4Bias(m4b, s.x_ln, L.k_f16 orelse s.wdq2, k, L.k_b, M, D, D);
            if (L.v_f16 == null) try kDeq(K, s.wdq, .{ .qs = L.qkv_w.qs + 2 * @as(usize, D) * D, .scales = L.qkv_w.scales + 2 * @as(usize, D) * dnb }, D, D);
            try kM4Bias(m4b, s.x_ln, L.v_f16 orelse s.wdq, v, L.v_b, M, D, D);
        } else {
            if (L.q_f16 == null) try kDeq(K, s.wdq, L.qkv_w, D, D);
            try mtl.matmulF16Batched(s.x_ln, L.q_f16 orelse s.wdq, q, M, D, D);
            if (L.k_f16 == null) try kDeq(K, s.wdq, .{ .qs = L.qkv_w.qs + @as(usize, D) * D, .scales = L.qkv_w.scales + @as(usize, D) * dnb }, D, D);
            try mtl.matmulF16Batched(s.x_ln, L.k_f16 orelse s.wdq, k, M, D, D);
            if (L.v_f16 == null) try kDeq(K, s.wdq, .{ .qs = L.qkv_w.qs + 2 * @as(usize, D) * D, .scales = L.qkv_w.scales + 2 * @as(usize, D) * dnb }, D, D);
            try mtl.matmulF16Batched(s.x_ln, L.v_f16 orelse s.wdq, v, M, D, D);
            try kBias(K, q, L.q_b, M * D, D);
            try kBias(K, k, L.k_b, M * D, D);
            try kBias(K, v, L.v_b, M * D, D);
        }
        for (0..batch_count) |bi| {
            const off = bi * seq * D;
            try kFlash(K, s.ao + off, q + off, k + off, v + off, seq);
        }
        if (L.o_f16 == null) try kDeq(K, s.wdq, L.o_w, D, D);
        if (K.m4_nn) |m4| {
            try kM4(m4, s.ao, L.o_f16 orelse s.wdq, s.mo, M, D, D);
        } else {
            try mtl.matmulF16Batched(s.ao, L.o_f16 orelse s.wdq, s.mo, M, D, D);
        }
        try kBRLN(K, x, s.mo, L.o_b, s.x_ln, L.mln_w, L.mln_b, D, M);
        if (L.m0_f16 == null) try kDeq(K, s.wdq, L.m0_w, MLP, D);
        if (K.m4_bias_gelu) |m4bg| {
            try kM4Bias(m4bg, s.x_ln, L.m0_f16 orelse s.wdq, s.mh, L.m0_b, M, MLP, D);
        } else {
            try mtl.matmulF16Batched(s.x_ln, L.m0_f16 orelse s.wdq, s.mh, M, MLP, D);
            try kBias(K, s.mh, L.m0_b, M * MLP, MLP);
            try kGelu(K, s.mh, M * MLP);
        }
        if (L.m2_f16 == null) try kDeq(K, s.wdq2, L.m2_w, D, MLP);
        if (K.m4_nn) |m4| {
            try kM4(m4, s.mh, L.m2_f16 orelse s.wdq2, s.mo, M, D, MLP);
        } else {
            try mtl.matmulF16Batched(s.mh, L.m2_f16 orelse s.wdq2, s.mo, M, D, MLP);
        }
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
