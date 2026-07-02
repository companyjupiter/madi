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
    cab: mtl.Function, // batched cross-attn (B slots, one dispatch) — P5
    emb: mtl.Function,
    extract: mtl.Function,
    cacc: mtl.Function,
    gemv: mtl.Function,
    gemv_bias: mtl.Function,
    gemv_bias_gelu: mtl.Function, // MLP up: gemv+bias+gelu fused (drops kGelu)
    gemv_bias_res: mtl.Function, // MLP down: gemv+bias+residual fused (drops kRes)
    qkv: mtl.Function, // self-attn qkv: gemv+bias×2+store×2 fused (drops 4 kernels)
    cvt32: mtl.Function, // f32→f16 (batched-decode projection inputs)
    cvt16: mtl.Function, // f16→f32 (batched-decode projection outputs)

    pub fn load() mtl.Error!Kernels {
        return .{
            .cvt32 = try mtl.getFunction("cvt_f32_f16"),
            .cvt16 = try mtl.getFunction("cvt_f16_f32"),
            .ln = try mtl.getFunction("layer_norm"),
            .brln = try mtl.getFunction("bias_res_ln"),
            .bias = try mtl.getFunction("bias_add"),
            .gelu = try mtl.getFunction("gelu_f32"),
            .res = try mtl.getFunction("gpu_residual"),
            .store = try mtl.getFunction("gpu_kv_store"),
            .attn = try mtl.getFunction("gpu_attention"),
            .ca = try mtl.getFunction("flash_cross_attn_f16kv"),
            .cab = try mtl.getFunction("flash_cross_attn_f16kv_batched"),
            .emb = try mtl.getFunction("gpu_emb_lookup"),
            .extract = try mtl.getFunction("extract_ca_head_f16kv"),
            .cacc = try mtl.getFunction("ca_accumulate"),
            .gemv = try mtl.getFunction("gemv_q8"),
            .gemv_bias = try mtl.getFunction("gemv_q8_bias"),
            .gemv_bias_gelu = try mtl.getFunction("gemv_q8_bias_gelu"),
            .gemv_bias_res = try mtl.getFunction("gemv_q8_bias_res"),
            .qkv = try mtl.getFunction("gemv_q8_qkv"),
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
    head_base: u32 = 0, // plane offset of this layer's heads in the per-head ca buffer
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
    ca_sc: [*]f32, // [NH][ENC_SEQ] normalized cross-attn scores (flash → ca_accumulate)
};

inline fn P(x: anytype) ?*const anyopaque {
    return @ptrCast(x);
}
const PS = @sizeOf(usize);
const U = @sizeOf(u32);
const Ff = @sizeOf(f32);

pub fn kLN(K: Kernels, x: [*]f32, y: [*]f32, g: [*]f32, b: [*]f32, d: u32, rows: u32) !void {
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
    try mtl.dispatch(K.gemv, .{ (n + 7) / 8, 1, 1 }, .{ 256, 1, 1 }, &p, &s); // NR0=4 → 32 rows/tg
}
// Q8 GEMV with fused bias epilogue — one dispatch instead of gemv + bias_add.
fn kGemvQ8Bias(K: Kernels, out: [*]f32, x: [*]f32, w: Q8w, bias: [*]f32, n: u32, k: u32) !void {
    var a0 = out; var a1 = w.qs; var a2 = w.scales; var a3 = x; var a4 = bias; var nn = n; var kk = k;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&a4), P(&nn), P(&kk) };
    const s = [_]usize{ PS, PS, PS, PS, PS, U, U };
    try mtl.dispatch(K.gemv_bias, .{ (n + 7) / 8, 1, 1 }, .{ 256, 1, 1 }, &p, &s); // NR0=4
}
// fused self-attn qkv: gemv(3D×D) + q/v bias + k/v store to cache. grid over 3D.
fn kQkv(K: Kernels, q_out: [*]f32, x: [*]f32, w: Q8w, qb: [*]f32, vb: [*]f32, kc: [*]f32, vc: [*]f32, pos: [*]u32) !void {
    var a0 = q_out; var a1 = w.qs; var a2 = w.scales; var a3 = x; var a4 = qb; var a5 = vb; var a6 = kc; var a7 = vc; var a8 = pos; var dd = D;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&a4), P(&a5), P(&a6), P(&a7), P(&a8), P(&dd) };
    const s = [_]usize{ PS, PS, PS, PS, PS, PS, PS, PS, PS, U };
    try mtl.dispatch(K.qkv, .{ (3 * D + 7) / 8, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
// gemv+bias with a fused epilogue (gelu or residual) — same args, drops a kernel.
fn kGemvQ8BiasEpi(f: mtl.Function, out: [*]f32, x: [*]f32, w: Q8w, bias: [*]f32, n: u32, k: u32) !void {
    var a0 = out; var a1 = w.qs; var a2 = w.scales; var a3 = x; var a4 = bias; var nn = n; var kk = k;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&a4), P(&nn), P(&kk) };
    const s = [_]usize{ PS, PS, PS, PS, PS, U, U };
    try mtl.dispatch(f, .{ (n + 7) / 8, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
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
fn kCA(K: Kernels, out: [*]f32, q: [*]f32, kc: [*]f16, vc: [*]f16, seqlen: u32, sc_out: [*]f32, write_sc: u32) !void {
    var a0 = out; var a1 = q; var a2 = kc; var a3 = vc; var sl = seqlen;
    var hd = HDD; var kvd = D; var nkv = NH; var nh = NH; var a9 = sc_out; var ws = write_sc;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&sl), P(&hd), P(&kvd), P(&nkv), P(&nh), P(&a9), P(&ws) };
    const s = [_]usize{ PS, PS, PS, PS, U, U, U, U, U, PS, U };
    try mtl.dispatch(K.ca, .{ NH, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
// batched cross-attn: B slots in one dispatch (grid B*NH). q/out contiguous
// [B][D]; kc/vc contiguous [B][seqlen][D]. No sc_out (write_sc=0 path). — P5
fn kCAbatched(K: Kernels, out: [*]f32, q: [*]f32, kc: [*]f16, vc: [*]f16, B: u32, seqlen: u32) !void {
    var a0 = out; var a1 = q; var a2 = kc; var a3 = vc; var sl = seqlen;
    var hd = HDD; var kvd = D; var nkv = NH; var nh = NH;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&sl), P(&hd), P(&kvd), P(&nkv), P(&nh) };
    const s = [_]usize{ PS, PS, PS, PS, U, U, U, U, U };
    try mtl.dispatch(K.cab, .{ B * NH, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
// copy this layer's alignment-head scores into their per-head ca planes.
// seqlen = valid cols this pass (AUDIO_CTX may shrink it); the ca planes stay
// allocated at [MAX_TOK][ENC_SEQ] so the row stride is fixed ENC_SEQ.
fn kAccumulate(K: Kernels, ca: [*]f32, sc: [*]f32, tok: [*]u32, align_mask: u32, plane_base: u32, seqlen: u32) !void {
    var a0 = ca; var a1 = sc; var a2 = tok; var am = align_mask; var pb = plane_base; var sl = seqlen; var nh = NH; var mt = MAX_TOK; var cs = ENC_SEQ;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&am), P(&pb), P(&sl), P(&nh), P(&mt), P(&cs) };
    const s = [_]usize{ PS, PS, PS, U, U, U, U, U, U };
    try mtl.dispatch(K.cacc, .{ 1, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kExtract(K: Kernels, q: [*]f32, kc: [*]f16, ca: [*]f32, tok: [*]u32, head: u32, inv_n: f32, seqlen: u32) !void {
    var a0 = q; var a1 = kc; var a2 = ca; var a3 = tok; var hh = head; var iv = inv_n; var sl = seqlen; var hd = HDD; var kvd = D;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&hh), P(&iv), P(&sl), P(&hd), P(&kvd) };
    const s = [_]usize{ PS, PS, PS, PS, U, Ff, U, U, U };
    try mtl.dispatch(K.extract, .{ 1, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}

/// One decoder block on the residual stream `x` (1 token, [D], modified in
/// place). `skc`/`svc` are this layer's self KV caches [MAX_TOK][D]; `ckc`/`cvc`
/// are this layer's precomputed cross KV [enc_ctx][D] (enc_ctx ≤ ENC_SEQ —
/// AUDIO_CTX truncation shrinks both the KV build AND this cross-attn read).
/// `pos` is a GPU u32 = the current token index. Synchronous per the
/// reference's per-op model.
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
    enc_ctx: u32,
) !void {
    // Fully batched onto the active command buffer (caller drives begin/commit/
    // sync). Metal preserves encoder order within a command buffer, so every
    // data dependency below (KV-store→attn, cross-Q→CA, etc.) stays correct.
    // self-attn
    try kLN(K, x, s.xb, L.aln_w, L.aln_b, D, 1);
    // fused: qkv gemv + q/v bias + k/v KV-store (drops kBias×2 + kStore×2)
    try kQkv(K, s.q, s.xb, L.qkvw, L.qb, L.vb, skc, svc, pos);
    try kAttn(K, s.ao, s.q, skc, svc, pos);
    // out proj + residual + cross LN
    try kGemvQ8(K, s.mo, s.ao, L.ow, D, D);
    try kBRLN(K, x, s.mo, L.ob, s.xb, L.caln_w, L.caln_b, D);
    // cross-attn
    try kGemvQ8Bias(K, s.q, s.xb, L.cqw, L.cqb, D, D); // fused cross-Q proj + bias
    // cross-attn + (for alignment layers) publish normalized scores, then fold
    // them into the timestamp map — no separate QK/softmax recompute (extract).
    var align_mask: u32 = 0;
    if (ca) |c| for (c.heads) |h| { align_mask |= (@as(u32, 1) << @as(u5, @intCast(h))); };
    try kCA(K, s.ao, s.q, ckc, cvc, enc_ctx, s.ca_sc, if (align_mask != 0) @as(u32, 1) else 0);
    if (ca) |c| {
        if (c.heads.len > 0) try kAccumulate(K, c.weights, s.ca_sc, c.tok, align_mask, c.head_base, enc_ctx);
    }
    try kGemvQ8(K, s.mo, s.ao, L.cow, D, D);
    try kBRLN(K, x, s.mo, L.cob, s.xb, L.mln_w, L.mln_b, D);
    // MLP — gelu folded into up-proj epilogue, residual folded into down-proj
    // epilogue (drops kGelu + kRes; bit-identical). x += down(gelu(up(xb))).
    try kGemvQ8BiasEpi(K.gemv_bias_gelu, s.mh, s.xb, L.m0w, L.m0b, MLP, D);
    try kGemvQ8BiasEpi(K.gemv_bias_res, x, s.mh, L.m2w, L.m2b, D, MLP);
}

// ── multi-chunk batched decode (Phase J) ─────────────────────────────────────
pub fn kCvt32(K: Kernels, dst: [*]f16, src: [*]f32, n: u32) !void {
    var a0 = dst; var a1 = src; var nn = n;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&nn) };
    const s = [_]usize{ PS, PS, U };
    try mtl.dispatch(K.cvt32, .{ (n + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
pub fn kCvt16(K: Kernels, dst: [*]f32, src: [*]f16, n: u32) !void {
    var a0 = dst; var a1 = src; var nn = n;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&nn) };
    const s = [_]usize{ PS, PS, U };
    try mtl.dispatch(K.cvt16, .{ (n + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}

/// Per-layer weights pre-dequantized to F16 in [K][N] (matmulF16Batched B-layout)
/// — done ONCE per decode (amortized over all tokens). qkvw is [D][3D], ow/cqw/
/// cow are [D][D], m0w is [D][MLP], m2w is [MLP][D].
pub const WF16 = struct { qkvw: [*]f16, ow: [*]f16, cqw: [*]f16, cow: [*]f16, m0w: [*]f16, m2w: [*]f16 };

/// Batched scratch. xb/ao/mo=[B·D], qkv=[B·3D], mh=[B·MLP], ca_sc=[NH·ENC_SEQ];
/// in16/out16 are F16 GEMM staging sized [B·MLP].
pub const BScratch = struct {
    xb: [*]f32, qkv: [*]f32, ao: [*]f32, mo: [*]f32, mh: [*]f32, ca_sc: [*]f32,
    in16: [*]f16, out16: [*]f16,
};

inline fn proj(K: Kernels, s: BScratch, in_f32: [*]f32, w16: [*]f16, out_f32: [*]f32, B: u32, N: u32, Kk: u32) !void {
    try kCvt32(K, s.in16, in_f32, B * Kk);
    try mtl.matmulF16Batched(s.in16, w16, s.out16, B, N, Kk);
    try kCvt16(K, out_f32, s.out16, B * N);
}

/// One decoder block over B independent token-streams (slots), residual stream
/// x_b[B][D]. Quality-EQUIVALENT to running decodeBlock per slot (projections via
/// batched GEMM; attention/KV-store per slot). Cross-attn alignment-score capture
/// is omitted here (handled in the integration's word-timestamp path). Each slot
/// has its own self-KV (skc/svc[b]), cross-KV (ckc/cvc[b]), and GPU pos (pos[b]).
pub fn decodeBlockBatched(
    K: Kernels, L: Layer, Wf: WF16, B: u32, x_b: [*]f32, s: BScratch,
    skc: []const [*]f32, svc: []const [*]f32, ckc: [*]f16, cvc: [*]f16, pos: []const [*]u32,
) !void {
    // self-attn LN (batched: rows=B)
    try kLN(K, x_b, s.xb, L.aln_w, L.aln_b, D, B);
    // qkv projection (batched GEMM) → [B][3D] = [b][q|k|v]
    try proj(K, s, s.xb, Wf.qkvw, s.qkv, B, 3 * D, D);
    var b: u32 = 0;
    while (b < B) : (b += 1) {
        const row = s.qkv + @as(usize, b) * 3 * D;
        try kBias(K, row, L.qb, D, D);             // q += qb
        try kBias(K, row + 2 * D, L.vb, D, D);     // v += vb
        try kStore(K, skc[b], row + D, D, pos[b]); // k → cache (no bias)
        try kStore(K, svc[b], row + 2 * D, D, pos[b]); // v → cache
        try kAttn(K, s.ao + @as(usize, b) * D, row, skc[b], svc[b], pos[b]);
    }
    // out proj + residual + cross-LN (per slot)
    try proj(K, s, s.ao, Wf.ow, s.mo, B, D, D);
    b = 0;
    while (b < B) : (b += 1) {
        const o = @as(usize, b) * D;
        try kBRLN(K, x_b + o, s.mo + o, L.ob, s.xb + o, L.caln_w, L.caln_b, D);
    }
    // cross-Q (batched) + bias (contiguous → batched) → BATCHED cross-attn (P5):
    // all B slots in one dispatch. q=s.ao [B][D], out=s.mo [B][D], cross-KV
    // contiguous [B][ENC_SEQ][D]. Was the per-slot kCA loop = ~43% of decode.
    try proj(K, s, s.xb, Wf.cqw, s.ao, B, D, D); // reuse s.ao as cross-Q out
    try kBias(K, s.ao, L.cqb, B * D, D);
    try kCAbatched(K, s.mo, s.ao, ckc, cvc, B, ENC_SEQ);
    // cross-out proj + residual + mlp-LN
    try proj(K, s, s.mo, Wf.cow, s.ao, B, D, D); // cross-out into s.ao
    b = 0;
    while (b < B) : (b += 1) {
        const o = @as(usize, b) * D;
        try kBRLN(K, x_b + o, s.ao + o, L.cob, s.xb + o, L.mln_w, L.mln_b, D);
    }
    // MLP: up (+bias+gelu, batched) → down (+bias, batched) → residual per slot
    try proj(K, s, s.xb, Wf.m0w, s.mh, B, MLP, D);
    try kBias(K, s.mh, L.m0b, B * MLP, MLP);
    try kGelu(K, s.mh, B * MLP);
    try proj(K, s, s.mh, Wf.m2w, s.mo, B, D, MLP);
    try kBias(K, s.mo, L.m2b, B * D, D);
    try kRes(K, x_b, s.mo, B * D); // x += down
}
