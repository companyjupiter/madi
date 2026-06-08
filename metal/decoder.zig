// decoder.zig — Whisper decoder (4 layers, autoregressive) on Metal.
// Reusable module: kernel handles + per-layer weight struct + decodeBlock().
// Mirrors the CUDA reference decodeBlock (sovereign_whisper.zig). F32 + MPS
// GEMV (M=1) for projections; dedicated kernels for attn / kv-store / residual.
//
// The decode block is numerically verified (test_decoder.zig). The full
// autoregressive loop (embed → N×block → final LN → logit GEMV → argmax →
// append) and BPE/tokenizer/model-loader are wired in M3's main (need assets).
const std = @import("std");
const mtl = @import("metal_backend.zig");

pub const D: u32 = 1280;
pub const NL: u32 = 4;
pub const NH: u32 = 20;
pub const HDD: u32 = 64;
pub const MLP: u32 = 5120;
pub const ENC_SEQ: u32 = 1500; // cross-attn encoder positions
pub const MAX_TOK: u32 = 448;
pub const VOCAB: u32 = 51866;
const EPS: f32 = 1e-5;

pub const Q8w = struct { qs: [*]i8, scales: [*]f16 };

pub const Kernels = struct {
    ln: mtl.Function,
    brln: mtl.Function,
    bias: mtl.Function,
    gelu: mtl.Function,
    res: mtl.Function,
    store: mtl.Function,
    attn: mtl.Function,
    ca: mtl.Function,
    emb: mtl.Function,
    extract: mtl.Function,
    gemv: mtl.Function,

    pub fn load() mtl.Error!Kernels {
        return .{
            .ln = try mtl.getFunction("layer_norm"),
            .brln = try mtl.getFunction("bias_res_ln"),
            .bias = try mtl.getFunction("bias_add"),
            .gelu = try mtl.getFunction("gelu_f32"),
            .res = try mtl.getFunction("gpu_residual"),
            .store = try mtl.getFunction("gpu_kv_store"),
            .attn = try mtl.getFunction("gpu_attention"),
            .ca = try mtl.getFunction("flash_cross_attn_f16kv"),
            .emb = try mtl.getFunction("gpu_emb_lookup"),
            .extract = try mtl.getFunction("extract_ca_head_f16kv"),
            .gemv = try mtl.getFunction("gemv_q8"),
        };
    }
};

/// Cross-attention weight capture for word-level timestamps. `heads` lists the
/// alignment heads that belong to the CURRENT layer (empty = capture nothing).
pub const CaCtx = struct {
    weights: [*]f32, // [MAX_TOK][ENC_SEQ] accumulator
    tok: [*]u32, // GPU u32 = current token row index
    heads: []const u32,
    inv_n: f32, // 1 / total_alignment_heads
};

/// Per-layer decoder weights (device ptrs). Weights are [in][out] row-major.
/// Cross-attn K/V projections are precomputed per chunk into ckc/cvc, so the
/// block only needs cross Q/out here.
pub const Layer = struct {
    aln_w: [*]f32, aln_b: [*]f32,
    qkvw: Q8w, // stacked [3D][D] (q|k|v out-major) for one Q8 GEMV
    qb: [*]f32,
    vb: [*]f32,
    ow: Q8w, ob: [*]f32,
    caln_w: [*]f32, caln_b: [*]f32,
    cqw: Q8w, cqb: [*]f32,
    cow: Q8w, cob: [*]f32,
    mln_w: [*]f32, mln_b: [*]f32,
    m0w: Q8w, m0b: [*]f32,
    m2w: Q8w, m2b: [*]f32,
};

/// Per-step scratch (all [D] except mh=[MLP]).
pub const Scratch = struct {
    xb: [*]f32, q: [*]f32, k: [*]f32, v: [*]f32, ao: [*]f32, mo: [*]f32, mh: [*]f32,
};

inline fn P(x: anytype) ?*const anyopaque {
    return @ptrCast(x);
}
const PS = @sizeOf(usize);
const U = @sizeOf(u32);
const Ff = @sizeOf(f32);

fn kLN(K: Kernels, x: [*]f32, y: [*]f32, g: [*]f32, b: [*]f32, d: u32, rows: u32) !void {
    var a0 = x; var a1 = y; var a2 = g; var a3 = b; var nd = d; var ne = EPS;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&nd), P(&ne) };
    const s = [_]usize{ PS, PS, PS, PS, U, Ff };
    try mtl.dispatch(K.ln, .{ rows, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kBRLN(K: Kernels, x: [*]f32, mo: [*]f32, bias: [*]f32, y: [*]f32, g: [*]f32, b: [*]f32, d: u32) !void {
    var a0 = x; var a1 = mo; var a2 = bias; var a3 = y; var a4 = g; var a5 = b; var nd = d; var ne = EPS;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&a4), P(&a5), P(&nd), P(&ne) };
    const s = [_]usize{ PS, PS, PS, PS, PS, PS, U, Ff };
    try mtl.dispatch(K.brln, .{ 1, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kBias(K: Kernels, x: [*]f32, b: [*]f32, n: u32, d: u32) !void {
    var a0 = x; var a1 = b; var nn = n; var nd = d;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&nn), P(&nd) };
    const s = [_]usize{ PS, PS, U, U };
    try mtl.dispatch(K.bias, .{ (n + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kGemvQ8(K: Kernels, out: [*]f32, x: [*]f32, w: Q8w, n: u32, k: u32) !void {
    var a0 = out; var a1 = w.qs; var a2 = w.scales; var a3 = x; var nn = n; var kk = k;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&nn), P(&kk) };
    const s = [_]usize{ PS, PS, PS, PS, U, U };
    try mtl.dispatch(K.gemv, .{ (n + 7) / 8, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kGelu(K: Kernels, x: [*]f32, n: u32) !void {
    var a0 = x; var nn = n;
    const p = [_]?*const anyopaque{ P(&a0), P(&nn) };
    const s = [_]usize{ PS, U };
    try mtl.dispatch(K.gelu, .{ (n + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kRes(K: Kernels, x: [*]f32, y: [*]f32, n: u32) !void {
    var a0 = x; var a1 = y; var nn = n;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&nn) };
    const s = [_]usize{ PS, PS, U };
    try mtl.dispatch(K.res, .{ (n + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kStore(K: Kernels, cache: [*]f32, src: [*]f32, kvd: u32, pos: [*]u32) !void {
    var a0 = cache; var a1 = src; var nk = kvd; var a3 = pos;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&nk), P(&a3) };
    const s = [_]usize{ PS, PS, U, PS };
    try mtl.dispatch(K.store, .{ (kvd + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kAttn(K: Kernels, out: [*]f32, q: [*]f32, kc: [*]f32, vc: [*]f32, pos: [*]u32) !void {
    var a0 = out; var a1 = q; var a2 = kc; var a3 = vc; var a4 = pos;
    var hd = HDD; var kvd = D; var nkv = NH; var nh = NH;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&a4), P(&hd), P(&kvd), P(&nkv), P(&nh) };
    const s = [_]usize{ PS, PS, PS, PS, PS, U, U, U, U };
    try mtl.dispatch(K.attn, .{ NH, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kCA(K: Kernels, out: [*]f32, q: [*]f32, kc: [*]f16, vc: [*]f16, seqlen: u32) !void {
    var a0 = out; var a1 = q; var a2 = kc; var a3 = vc; var sl = seqlen;
    var hd = HDD; var kvd = D; var nkv = NH; var nh = NH;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&sl), P(&hd), P(&kvd), P(&nkv), P(&nh) };
    const s = [_]usize{ PS, PS, PS, PS, U, U, U, U, U };
    try mtl.dispatch(K.ca, .{ NH, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kExtract(K: Kernels, q: [*]f32, kc: [*]f16, ca: [*]f32, tok: [*]u32, head: u32, inv_n: f32, seqlen: u32) !void {
    var a0 = q; var a1 = kc; var a2 = ca; var a3 = tok; var hh = head; var iv = inv_n; var sl = seqlen; var hd = HDD; var kvd = D;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&hh), P(&iv), P(&sl), P(&hd), P(&kvd) };
    const s = [_]usize{ PS, PS, PS, PS, U, Ff, U, U, U };
    try mtl.dispatch(K.extract, .{ 1, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}

/// One decoder block on the residual stream `x` (1 token, [D], modified in
/// place). `skc`/`svc` are this layer's self KV caches [MAX_TOK][D]; `ckc`/`cvc`
/// are this layer's precomputed cross KV [ENC_SEQ][D]. `pos` is a GPU u32 = the
/// current token index. Synchronous per the reference's per-op model.
pub fn decodeBlock(
    K: Kernels,
    L: Layer,
    x: [*]f32,
    s: Scratch,
    skc: [*]f32,
    svc: [*]f32,
    ckc: [*]f16,
    cvc: [*]f16,
    pos: [*]u32,
    ca: ?CaCtx,
) !void {
    // Fully batched onto the active command buffer (caller drives begin/commit/
    // sync). Metal preserves encoder order within a command buffer, so every
    // data dependency below (KV-store→attn, cross-Q→CA, etc.) stays correct.
    // self-attn
    try kLN(K, x, s.xb, L.aln_w, L.aln_b, D, 1);
    try kGemvQ8(K, s.q, s.xb, L.qkvw, 3 * D, D); // q|k|v contiguous (s.k=s.q+D, s.v=s.q+2D)
    try kBias(K, s.q, L.qb, D, D);
    try kBias(K, s.v, L.vb, D, D);
    try kStore(K, skc, s.k, D, pos);
    try kStore(K, svc, s.v, D, pos);
    try kAttn(K, s.ao, s.q, skc, svc, pos);
    // out proj + residual + cross LN
    try kGemvQ8(K, s.mo, s.ao, L.ow, D, D);
    try kBRLN(K, x, s.mo, L.ob, s.xb, L.caln_w, L.caln_b, D);
    // cross-attn
    try kGemvQ8(K, s.q, s.xb, L.cqw, D, D);
    try kBias(K, s.q, L.cqb, D, D);
    if (ca) |c| {
        for (c.heads) |h| try kExtract(K, s.q, ckc, c.weights, c.tok, h, c.inv_n, ENC_SEQ);
    }
    try kCA(K, s.ao, s.q, ckc, cvc, ENC_SEQ);
    try kGemvQ8(K, s.mo, s.ao, L.cow, D, D);
    try kBRLN(K, x, s.mo, L.cob, s.xb, L.mln_w, L.mln_b, D);
    // MLP
    try kGemvQ8(K, s.mh, s.xb, L.m0w, MLP, D);
    try kBias(K, s.mh, L.m0b, MLP, MLP);
    try kGelu(K, s.mh, MLP);
    try kGemvQ8(K, s.mo, s.mh, L.m2w, D, MLP);
    try kBias(K, s.mo, L.m2b, D, D);
    try kRes(K, x, s.mo, D);
}
