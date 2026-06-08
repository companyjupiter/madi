// transcribe.zig — Sovereign Whisper (Metal) full pipeline:
//   WAV → mel → Conv1D×2 → 32-layer encoder → cross-KV → 4-layer autoregressive
//   decoder → argmax → BPE decode.  Reads model.safetensors directly (F16→F32).
// Usage: transcribe <model.safetensors> <audio.wav> <WHISPER_BPE.bin> [weights for conv via same safetensors]
const std = @import("std");
const mtl = @import("metal_backend.zig");
const mel = @import("mel.zig");
const enc = @import("encoder.zig");
const dec = @import("decoder.zig");

const METALLIB = @embedFile("whisper.metallib");
const D = enc.D;
const MLP = enc.MLP;
const NH = enc.NH;
const ENC_SEQ = dec.ENC_SEQ; // 1500
const VOCAB = dec.VOCAB; // 51866
const MAX_TOK = dec.MAX_TOK; // 448
const EOT: u32 = 50257;
const SEED = [_]u32{ 50258, 50259, 50360, 50364 }; // sot, en, transcribe, notimestamps
const alloc = std.heap.page_allocator;

// ── safetensors ──────────────────────────────────────────────────────
const Sf = struct {
    data: []align(std.heap.page_size_min) const u8,
    off: usize, // data section start
    json: []const u8,

    fn open(path: []const u8) !Sf {
        const fd = try std.posix.open(path, .{}, 0);
        defer std.posix.close(fd);
        const sz: usize = @intCast((try std.posix.fstat(fd)).size);
        const m = try std.posix.mmap(null, sz, std.posix.PROT.READ, .{ .TYPE = .PRIVATE }, fd, 0);
        const n = std.mem.readInt(u64, m[0..8], .little);
        return .{ .data = m, .off = 8 + n, .json = m[8 .. 8 + n] };
    }
    /// Raw F16 bytes for a tensor key (null if absent).
    fn raw(self: Sf, key: []const u8) ?[]const u8 {
        var kbuf: [128]u8 = undefined;
        const q = std.fmt.bufPrint(&kbuf, "\"{s}\"", .{key}) catch return null;
        const ks = std.mem.indexOf(u8, self.json, q) orelse return null;
        const dp = std.mem.indexOfPos(u8, self.json, ks, "data_offsets") orelse return null;
        const lb = std.mem.indexOfPos(u8, self.json, dp, "[") orelse return null;
        const cm = std.mem.indexOfPos(u8, self.json, lb, ",") orelse return null;
        const rb = std.mem.indexOfPos(u8, self.json, cm, "]") orelse return null;
        const s = std.fmt.parseInt(usize, std.mem.trim(u8, self.json[lb + 1 .. cm], " "), 10) catch return null;
        const e = std.fmt.parseInt(usize, std.mem.trim(u8, self.json[cm + 1 .. rb], " "), 10) catch return null;
        return self.data[self.off + s .. self.off + e];
    }
};

inline fn h2f(u: u16) f32 {
    return @floatCast(@as(f16, @bitCast(u)));
}

/// Load a tensor as a flat F32 unified buffer (F16→F32, shape preserved).
fn upVec(sf: Sf, key: []const u8) ![*]f32 {
    const r = sf.raw(key) orelse {
        std.debug.print("MISSING tensor: {s}\n", .{key});
        return error.MissingTensor;
    };
    const n = r.len / 2;
    const u16s = @as([*]align(1) const u16, @ptrCast(r.ptr))[0..n];
    const dst = try mtl.allocSlice(f32, n);
    for (0..n) |i| dst[i] = h2f(u16s[i]);
    return dst.ptr;
}

/// Load a tensor as a flat F16 unified buffer (raw — safetensors is already F16).
fn upVecF16(sf: Sf, key: []const u8) ![*]f16 {
    const r = sf.raw(key) orelse {
        std.debug.print("MISSING tensor: {s}\n", .{key});
        return error.MissingTensor;
    };
    const dst = try mtl.allocSlice(f16, r.len / 2);
    @memcpy(std.mem.sliceAsBytes(dst), r);
    return dst.ptr;
}

/// Load a projection weight [out][in] → transposed [in][out] F32 unified.
fn upMatT(sf: Sf, key: []const u8, out_ch: usize, in_ch: usize) ![*]f32 {
    const r = sf.raw(key) orelse {
        std.debug.print("MISSING tensor: {s}\n", .{key});
        return error.MissingTensor;
    };
    const u16s = @as([*]align(1) const u16, @ptrCast(r.ptr))[0 .. out_ch * in_ch];
    const dst = try mtl.allocSlice(f32, out_ch * in_ch);
    for (0..out_ch) |o| {
        for (0..in_ch) |i| dst[i * out_ch + o] = h2f(u16s[o * in_ch + i]);
    }
    return dst.ptr;
}

fn upMatTInto(sf: Sf, key: []const u8, dst: [*]f32, out_ch: usize, in_ch: usize) !void {
    const r = sf.raw(key) orelse return error.MissingTensor;
    const u16s = @as([*]align(1) const u16, @ptrCast(r.ptr))[0 .. out_ch * in_ch];
    for (0..out_ch) |o| {
        for (0..in_ch) |i| dst[i * out_ch + o] = h2f(u16s[o * in_ch + i]);
    }
}

/// Load a projection weight [out][in] → transposed [in][out], kept F16 (raw
/// bit-copy of the half values — no precision loss vs the stored weights).
fn upMatTF16(sf: Sf, key: []const u8, out_ch: usize, in_ch: usize) ![*]f16 {
    const r = sf.raw(key) orelse return error.MissingTensor;
    const u16s = @as([*]align(1) const u16, @ptrCast(r.ptr))[0 .. out_ch * in_ch];
    const dst = try mtl.allocSlice(f16, out_ch * in_ch);
    const d16 = @as([*]u16, @ptrCast(dst.ptr));
    for (0..out_ch) |o| {
        for (0..in_ch) |i| d16[i * out_ch + o] = u16s[o * in_ch + i];
    }
    return dst.ptr;
}
fn upMatTIntoF16(sf: Sf, key: []const u8, dst: [*]f16, out_ch: usize, in_ch: usize) !void {
    const r = sf.raw(key) orelse return error.MissingTensor;
    const u16s = @as([*]align(1) const u16, @ptrCast(r.ptr))[0 .. out_ch * in_ch];
    const d16 = @as([*]u16, @ptrCast(dst));
    for (0..out_ch) |o| {
        for (0..in_ch) |i| d16[i * out_ch + o] = u16s[o * in_ch + i];
    }
}

// conv weight: safetensors [out][in][k] → [k][in][out]
fn upConvW(sf: Sf, key: []const u8, out_ch: usize, in_ch: usize, k: usize) ![*]f32 {
    const r = sf.raw(key) orelse return error.MissingTensor;
    const u16s = @as([*]align(1) const u16, @ptrCast(r.ptr))[0 .. out_ch * in_ch * k];
    const dst = try mtl.allocSlice(f32, out_ch * in_ch * k);
    for (0..out_ch) |o| for (0..in_ch) |i| for (0..k) |kk| {
        dst[(kk * in_ch + i) * out_ch + o] = h2f(u16s[(o * in_ch + i) * k + kk]);
    };
    return dst.ptr;
}

fn upConvWF16(sf: Sf, key: []const u8, out_ch: usize, in_ch: usize, k: usize) ![*]f16 {
    const r = sf.raw(key) orelse return error.MissingTensor;
    const u16s = @as([*]align(1) const u16, @ptrCast(r.ptr))[0 .. out_ch * in_ch * k];
    const dst = try mtl.allocSlice(f16, out_ch * in_ch * k);
    const d16 = @as([*]u16, @ptrCast(dst.ptr));
    for (0..out_ch) |o| for (0..in_ch) |i| for (0..k) |kk| {
        d16[(kk * in_ch + i) * out_ch + o] = u16s[(o * in_ch + i) * k + kk];
    };
    return dst.ptr;
}

// Stacked decoder QKV weight [D][3D] (q|k|v) for one batched GEMM (F32, [in][out]).
fn upQKV(sf: Sf, l: usize) ![*]f32 {
    const dst = try mtl.allocSlice(f32, 3 * @as(usize, D) * D);
    var kbuf: [128]u8 = undefined;
    const names = [_][]const u8{ "q_proj", "k_proj", "v_proj" };
    for (names, 0..) |nm, blk| {
        const key = std.fmt.bufPrint(&kbuf, "model.decoder.layers.{d}.self_attn.{s}.weight", .{ l, nm }) catch unreachable;
        const r = sf.raw(key) orelse return error.MissingTensor;
        const u16s = @as([*]align(1) const u16, @ptrCast(r.ptr))[0 .. @as(usize, D) * D];
        const co = blk * @as(usize, D);
        for (0..D) |o| for (0..D) |i| {
            dst[i * 3 * @as(usize, D) + co + o] = h2f(u16s[o * D + i]);
        };
    }
    return dst.ptr;
}

var g_zeros: [*]f32 = undefined; // shared zero bias [D]

fn keyL(buf: []u8, comptime fmt: []const u8, l: usize) []const u8 {
    return std.fmt.bufPrint(buf, fmt, .{l}) catch unreachable;
}

pub fn main() !void {
    const out = std.io.getStdOut().writer();
    var args = try std.process.argsWithAllocator(alloc);
    _ = args.next();
    const model_path = args.next() orelse "assets/model.safetensors";
    const wav_path = args.next() orelse "assets/jfk.wav";
    const bpe_path = args.next() orelse "assets/WHISPER_BPE.bin";

    try mtl.init();
    defer mtl.deinit();
    try mtl.loadLibrary(METALLIB);
    const f_im2col = try mtl.getFunction("im2col_f16");
    const f_geluT = try mtl.getFunction("gelu_transpose");
    const f_geluPos = try mtl.getFunction("gelu_pos");
    const Ke = try enc.Kernels.load();
    const Kd = try dec.Kernels.load();
    const f_emb = Kd.emb;
    // GPU-resident decode-loop kernels (sync-free replay; from the SHARE build)
    const f_emb_ind = try mtl.getFunction("emb_lookup_indirect");
    const f_pe_ind = try mtl.getFunction("pos_embed_add_indirect");
    const f_step = try mtl.getFunction("step_advance");
    const f_argmax = try mtl.getFunction("argmax_no_inc");
    const f_filt = try mtl.getFunction("logit_filter_indirect");
    const f_suppress = try mtl.getFunction("suppress_list");
    const f_logit = try mtl.getFunction("logit_gemv_f16_cg");
    const f_bias16 = try mtl.getFunction("bias_add_f16");
    try out.print("[1] Metal + kernels ready\n", .{});

    const sf = try Sf.open(model_path);
    try out.print("[2] model.safetensors mapped ({d} MB)\n", .{sf.data.len / 1048576});

    const zeros = try mtl.allocSlice(f32, D);
    @memset(zeros, 0);
    g_zeros = zeros.ptr;

    // ── one-time weights: conv front-end + positional ───────────────
    const mel_filters = try readBinF32(bpe_dir(bpe_path), "mel_filters.bin");
    const mel_buf = try mtl.allocSlice(f32, mel.N_MELS * mel.N_FRAMES);
    const c1w = try upConvWF16(sf, "model.encoder.conv1.weight", D, mel.N_MELS, 3);
    const c1b = try upVec(sf, "model.encoder.conv1.bias");
    const c2w = try upConvWF16(sf, "model.encoder.conv2.weight", D, D, 3);
    const c2b = try upVec(sf, "model.encoder.conv2.bias");
    const enc_pe = try upVec(sf, "model.encoder.embed_positions.weight"); // [1500][D]
    const conv1o = (try mtl.allocSlice(f32, D * mel.N_FRAMES)).ptr; // [D][3000] F32
    const col1 = (try mtl.allocSlice(f16, mel.N_FRAMES * (mel.N_MELS * 3))).ptr;
    const t1 = (try mtl.allocSlice(f16, mel.N_FRAMES * D)).ptr;
    const col2 = (try mtl.allocSlice(f16, ENC_SEQ * (D * 3))).ptr;
    const t2 = (try mtl.allocSlice(f16, ENC_SEQ * D)).ptr;
    const d_ex = (try mtl.allocSlice(f32, ENC_SEQ * D)).ptr;
    try out.print("[3] front-end weights loaded\n", .{});

    // ── load encoder weights (32 layers) ────────────────────────────
    var elayers: [enc.ENL]enc.Layer = undefined;
    var kb: [4][128]u8 = undefined;
    for (0..enc.ENL) |l| {
        const qkv = try mtl.allocSlice(f16, 3 * D * D);
        try upMatTIntoF16(sf, keyL(&kb[0], "model.encoder.layers.{d}.self_attn.q_proj.weight", l), qkv.ptr, D, D);
        try upMatTIntoF16(sf, keyL(&kb[0], "model.encoder.layers.{d}.self_attn.k_proj.weight", l), qkv.ptr + D * D, D, D);
        try upMatTIntoF16(sf, keyL(&kb[0], "model.encoder.layers.{d}.self_attn.v_proj.weight", l), qkv.ptr + 2 * D * D, D, D);
        elayers[l] = .{
            .aln_w = try upVec(sf, keyL(&kb[0], "model.encoder.layers.{d}.self_attn_layer_norm.weight", l)),
            .aln_b = try upVec(sf, keyL(&kb[0], "model.encoder.layers.{d}.self_attn_layer_norm.bias", l)),
            .qkv_w = qkv.ptr,
            .q_b = try upVec(sf, keyL(&kb[0], "model.encoder.layers.{d}.self_attn.q_proj.bias", l)),
            .k_b = g_zeros, // whisper k_proj has no bias
            .v_b = try upVec(sf, keyL(&kb[0], "model.encoder.layers.{d}.self_attn.v_proj.bias", l)),
            .o_w = try upMatTF16(sf, keyL(&kb[0], "model.encoder.layers.{d}.self_attn.out_proj.weight", l), D, D),
            .o_b = try upVec(sf, keyL(&kb[0], "model.encoder.layers.{d}.self_attn.out_proj.bias", l)),
            .mln_w = try upVec(sf, keyL(&kb[0], "model.encoder.layers.{d}.final_layer_norm.weight", l)),
            .mln_b = try upVec(sf, keyL(&kb[0], "model.encoder.layers.{d}.final_layer_norm.bias", l)),
            .m0_w = try upMatTF16(sf, keyL(&kb[0], "model.encoder.layers.{d}.fc1.weight", l), MLP, D),
            .m0_b = try upVec(sf, keyL(&kb[0], "model.encoder.layers.{d}.fc1.bias", l)),
            .m2_w = try upMatTF16(sf, keyL(&kb[0], "model.encoder.layers.{d}.fc2.weight", l), D, MLP),
            .m2_b = try upVec(sf, keyL(&kb[0], "model.encoder.layers.{d}.fc2.bias", l)),
        };
    }
    const elnp_w = try upVec(sf, "model.encoder.layer_norm.weight");
    const elnp_b = try upVec(sf, "model.encoder.layer_norm.bias");
    try out.print("[5] encoder weights loaded (32 layers)\n", .{});

    // ── encoder scratch (F16 activations, reused per chunk) ─────────
    const escr = enc.Scratch{
        .x_ln = (try mtl.allocSlice(f16, ENC_SEQ * D)).ptr,
        .qkv = (try mtl.allocSlice(f16, 3 * ENC_SEQ * D)).ptr,
        .ao = (try mtl.allocSlice(f16, ENC_SEQ * D)).ptr,
        .mo = (try mtl.allocSlice(f16, ENC_SEQ * D)).ptr,
        .mh = (try mtl.allocSlice(f16, ENC_SEQ * MLP)).ptr,
    };
    const out_f16 = (try mtl.allocSlice(f16, ENC_SEQ * D)).ptr;
    const enc_out = (try mtl.allocSlice(f32, ENC_SEQ * D)).ptr;

    // ── decoder weights (4 layers); cross-KV weights kept for per-chunk recompute ─
    var dlayers: [dec.NL]dec.Layer = undefined;
    const ckw = try alloc.alloc([*]f16, dec.NL);
    const cvw = try alloc.alloc([*]f16, dec.NL);
    const cvb = try alloc.alloc([*]f32, dec.NL);
    const ckc = try alloc.alloc([*]f16, dec.NL);
    const cvc = try alloc.alloc([*]f16, dec.NL);
    for (0..dec.NL) |l| {
        ckw[l] = try upMatTF16(sf, keyL(&kb[0], "model.decoder.layers.{d}.encoder_attn.k_proj.weight", l), D, D);
        cvw[l] = try upMatTF16(sf, keyL(&kb[0], "model.decoder.layers.{d}.encoder_attn.v_proj.weight", l), D, D);
        cvb[l] = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.encoder_attn.v_proj.bias", l));
        ckc[l] = (try mtl.allocSlice(f16, ENC_SEQ * D)).ptr;
        cvc[l] = (try mtl.allocSlice(f16, ENC_SEQ * D)).ptr;
        dlayers[l] = .{
            .aln_w = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.self_attn_layer_norm.weight", l)),
            .aln_b = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.self_attn_layer_norm.bias", l)),
            .qkvw = try upQKV(sf, l),
            .qb = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.self_attn.q_proj.bias", l)),
            .vb = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.self_attn.v_proj.bias", l)),
            .ow = try upMatT(sf, keyL(&kb[0], "model.decoder.layers.{d}.self_attn.out_proj.weight", l), D, D),
            .ob = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.self_attn.out_proj.bias", l)),
            .caln_w = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.encoder_attn_layer_norm.weight", l)),
            .caln_b = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.encoder_attn_layer_norm.bias", l)),
            .cqw = try upMatT(sf, keyL(&kb[0], "model.decoder.layers.{d}.encoder_attn.q_proj.weight", l), D, D),
            .cqb = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.encoder_attn.q_proj.bias", l)),
            .cow = try upMatT(sf, keyL(&kb[0], "model.decoder.layers.{d}.encoder_attn.out_proj.weight", l), D, D),
            .cob = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.encoder_attn.out_proj.bias", l)),
            .mln_w = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.final_layer_norm.weight", l)),
            .mln_b = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.final_layer_norm.bias", l)),
            .m0w = try upMatT(sf, keyL(&kb[0], "model.decoder.layers.{d}.fc1.weight", l), MLP, D),
            .m0b = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.fc1.bias", l)),
            .m2w = try upMatT(sf, keyL(&kb[0], "model.decoder.layers.{d}.fc2.weight", l), D, MLP),
            .m2b = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.fc2.bias", l)),
        };
    }
    const dln_w = try upVec(sf, "model.decoder.layer_norm.weight");
    const dln_b = try upVec(sf, "model.decoder.layer_norm.bias");
    const tok_emb = try upVecF16(sf, "model.decoder.embed_tokens.weight"); // [VOCAB][D] F16
    const dec_pe = try upVec(sf, "model.decoder.embed_positions.weight"); // [448][D]
    try out.print("[7] decoder weights + cross-KV ready\n", .{});

    // ── decoder scratch + KV caches ─────────────────────────────────
    const d_qkv3 = (try mtl.allocSlice(f32, 3 * D)).ptr; // contiguous q|k|v
    const dscr = dec.Scratch{
        .xb = (try mtl.allocSlice(f32, D)).ptr, .q = d_qkv3,
        .k = d_qkv3 + D, .v = d_qkv3 + 2 * D,
        .ao = (try mtl.allocSlice(f32, D)).ptr, .mo = (try mtl.allocSlice(f32, D)).ptr,
        .mh = (try mtl.allocSlice(f32, MLP)).ptr,
    };
    const skc = try alloc.alloc([*]f32, dec.NL);
    const svc = try alloc.alloc([*]f32, dec.NL);
    for (0..dec.NL) |l| {
        skc[l] = (try mtl.allocSlice(f32, MAX_TOK * D)).ptr;
        svc[l] = (try mtl.allocSlice(f32, MAX_TOK * D)).ptr;
    }
    const d_x = (try mtl.allocSlice(f32, D)).ptr;
    const d_tokens = try mtl.allocSlice(u32, MAX_TOK);
    const d_pos = (try mtl.allocSlice(u32, 1)).ptr;
    const d_logits = (try mtl.allocSlice(f32, VOCAB)).ptr;
    for (SEED, 0..) |s, i| d_tokens[i] = s;

    const suppress = try readBinU32(bpe_dir(bpe_path), "suppress_tokens.bin");
    const d_suppress = try mtl.allocSlice(u32, suppress.len);
    @memcpy(d_suppress, suppress);
    const n_suppress: u32 = @intCast(suppress.len);
    const out_tokens = try alloc.alloc(u32, MAX_TOK);
    for (SEED, 0..) |s, i| out_tokens[i] = s;

    // Word-timestamp alignment: heads per decoder layer (v3-turbo) + accumulator.
    // ALIGN = {2,4},{2,11},{3,3},{3,6},{3,11},{3,14}  → inv_n = 1/6.
    const heads_l2 = [_]u32{ 4, 11 };
    const heads_l3 = [_]u32{ 3, 6, 11, 14 };
    const layer_heads = [dec.NL][]const u32{ &.{}, &.{}, &heads_l2, &heads_l3 };
    const inv_n: f32 = 1.0 / 6.0;
    const d_ca = try mtl.allocSlice(f32, MAX_TOK * ENC_SEQ);
    @memset(d_ca, 0);

    // ── read audio, split into 30 s windows ─────────────────────────
    const wav = try std.fs.cwd().readFileAlloc(alloc, wav_path, 2 * 1024 * 1024 * 1024);
    const total = mel.wavTotalSamples(wav);
    const n_chunks: usize = if (total <= mel.CHUNK_SAMPLES) 1 else (total + mel.CHUNK_SAMPLES - 1) / mel.CHUNK_SAMPLES;
    const samples = try alloc.alloc(f32, mel.CHUNK_SAMPLES);
    try out.print("[8] audio: {d} samples ({d:.1}s) → {d} chunk(s) × 30s\n", .{ total, @as(f64, @floatFromInt(total)) / 16000.0, n_chunks });

    var full = std.ArrayList(u8).init(alloc);
    var timer = try std.time.Timer.start();
    var chunk: usize = 0;
    while (chunk < n_chunks) : (chunk += 1) {
        const got = mel.loadWavChunk(wav, chunk * mel.CHUNK_SAMPLES, samples);
        if (chunk > 0 and got == 0) break;
        const t_off: f32 = @as(f32, @floatFromInt(chunk)) * 30.0;

        // front-end: mel → Conv1D×2 → enc_input
        mel.melSpectrogram(samples, mel_filters, mel_buf);
        var ct = try std.time.Timer.start();
        try mtl.beginCommandBuffer();
        try imIm2col(f_im2col, col1, mel_buf.ptr, mel.N_MELS, mel.N_FRAMES, 1, 1, mel.N_FRAMES);
        try mtl.matmulF16Batched(col1, c1w, t1, mel.N_FRAMES, D, mel.N_MELS * 3);
        try geluTranspose(f_geluT, conv1o, t1, c1b, mel.N_FRAMES, D);
        try imIm2col(f_im2col, col2, conv1o, D, mel.N_FRAMES, 2, 1, ENC_SEQ);
        try mtl.matmulF16Batched(col2, c2w, t2, ENC_SEQ, D, D * 3);
        try geluPos(f_geluPos, d_ex, t2, c2b, enc_pe, ENC_SEQ * D, D);
        try mtl.commitCommandBuffer();
        try mtl.sync();
        const conv_ms = @as(f64, @floatFromInt(ct.read())) / 1e6;

        // encoder + per-chunk cross-KV
        var et = try std.time.Timer.start();
        try enc.forward(Ke, &elayers, elnp_w, elnp_b, d_ex, out_f16, enc_out, escr, 1);
        const enc_ms = @as(f64, @floatFromInt(et.read())) / 1e6;
        for (0..dec.NL) |l| {
            try mtl.beginCommandBuffer();
            try mtl.matmulF16Batched(out_f16, ckw[l], ckc[l], ENC_SEQ, D, D);
            try mtl.matmulF16Batched(out_f16, cvw[l], cvc[l], ENC_SEQ, D, D);
            try biasAdd16(f_bias16, cvc[l], cvb[l], ENC_SEQ * D, D);
            try mtl.commitCommandBuffer();
            try mtl.sync();
        }

        // reset decode state for this chunk
        for (SEED, 0..) |s, i| { d_tokens[i] = s; out_tokens[i] = s; }
        @memset(d_ca, 0);

        // GPU-resident autoregressive decode (idea from the SHARE build's CUDA
        // Graph replay): the whole step runs on-GPU — indirect embed, blocks,
        // logit GEMV, GPU logit-filter + argmax + step-advance — so NO CPU sits
        // between tokens. B steps are recorded into one command buffer; we sync
        // only once per batch (then read tokens to detect EOT).
        var dt2 = try std.time.Timer.start();
        const sample_begin: u32 = SEED.len;
        const DBATCH: u32 = 8;
        const max_gen: u32 = MAX_TOK - SEED.len - 1;
        // Seed phase: fill KV[0..SEED.len-1) without prediction.
        {
            var sp: u32 = 0;
            while (sp + 1 < SEED.len) : (sp += 1) {
                d_pos[0] = sp;
                try mtl.beginCommandBuffer();
                try embLookup(f_emb, d_x, tok_emb, &d_tokens[sp]);
                try residual(Kd, d_x, dec_pe + @as(usize, sp) * D, D);
                for (0..dec.NL) |l| {
                    const ca_ctx = dec.CaCtx{ .weights = d_ca.ptr, .tok = d_pos, .heads = layer_heads[l], .inv_n = inv_n };
                    try dec.decodeBlock(Kd, dlayers[l], d_x, dscr, skc[l], svc[l], ckc[l], cvc[l], d_pos, ca_ctx);
                }
                try mtl.commitCommandBuffer();
                try mtl.sync();
            }
        }
        d_pos[0] = SEED.len - 1; // first prediction step
        var n_text: u32 = 0;
        var done = false;
        while (n_text < max_gen and !done) {
            const this_b = @min(DBATCH, max_gen - n_text);
            try mtl.beginCommandBuffer();
            for (0..this_b) |_| {
                try kEmbInd(f_emb_ind, d_x, tok_emb, d_tokens.ptr, d_pos);
                try kPeInd(f_pe_ind, d_x, dec_pe, d_pos);
                for (0..dec.NL) |l| {
                    const ca_ctx = dec.CaCtx{ .weights = d_ca.ptr, .tok = d_pos, .heads = layer_heads[l], .inv_n = inv_n };
                    try dec.decodeBlock(Kd, dlayers[l], d_x, dscr, skc[l], svc[l], ckc[l], cvc[l], d_pos, ca_ctx);
                }
                try layerNorm(Kd, d_x, dscr.xb, dln_w, dln_b, D);
                try kLogitGemv(f_logit, d_logits, tok_emb, dscr.xb, VOCAB, D);
                try kSuppress(f_suppress, d_logits, d_suppress.ptr, n_suppress);
                try kFilt(f_filt, d_logits, d_tokens.ptr, d_pos, sample_begin);
                try kStep(f_step, d_pos); // pos += 1
                try kArgmax(f_argmax, d_logits, d_tokens.ptr, d_pos, MAX_TOK); // tokens[pos] = argmax
            }
            try mtl.commitCommandBuffer();
            try mtl.sync();
            // detect EOT among the this_b newly written tokens
            const base = SEED.len + n_text;
            var bi: u32 = 0;
            while (bi < this_b) : (bi += 1) {
                const tk = d_tokens[base + bi];
                out_tokens[base + bi] = tk;
                if (tk == EOT) { done = true; break; }
            }
            n_text += bi;
        }

        const dec_ms = @as(f64, @floatFromInt(dt2.read())) / 1e6;
        try out.print("[perf] chunk {d}: conv {d:.0}ms | encoder {d:.0}ms | decode {d} tok {d:.0}ms ({d:.1} tok/s)\n", .{ chunk + 1, conv_ms, enc_ms, n_text, dec_ms, @as(f64, @floatFromInt(n_text)) / (dec_ms / 1000.0) });
        const text = try bpeDecode(bpe_path, out_tokens[SEED.len .. SEED.len + n_text]);
        if (n_chunks > 1) try out.print("\n[chunk {d}/{d} @ {d:.0}s] {s}\n", .{ chunk + 1, n_chunks, t_off, text });
        try full.appendSlice(text);
        if (n_text > 0) try wordTimestamps(out, bpe_path, d_ca.ptr, out_tokens, n_text, t_off);
        if (got < mel.CHUNK_SAMPLES) break; // reached end of audio
    }
    const dt = @as(f64, @floatFromInt(timer.read())) / 1e9;
    try out.print("\n=== TRANSCRIPTION ({d:.2}s, {d} chunk(s)) ===\n{s}\n", .{ dt, n_chunks, full.items });

    if (n_chunks == 1) try diarize(out, enc_out); // single-window only
}

// Zero-shot speaker diarization: VAD by per-frame L2 energy, K-means(K=2) on
// active frames, temporal median smoothing, emit speaker timeline. CPU; reads
// the unified enc_out buffer directly. (Ported from the CUDA reference.)
fn diarize(out: anytype, enc_out: [*]f32) !void {
    const SEQ: usize = ENC_SEQ;
    const DE: usize = D;
    const f = enc_out[0 .. SEQ * DE];
    var energy = try alloc.alloc(f32, SEQ);
    defer alloc.free(energy);
    var total: f32 = 0;
    for (0..SEQ) |i| {
        var s: f32 = 0;
        for (0..DE) |j| { const v = f[i * DE + j]; s += v * v; }
        energy[i] = @sqrt(s);
        total += energy[i];
    }
    const thresh = (total / @as(f32, @floatFromInt(SEQ))) * 0.5;
    var is_speech = try alloc.alloc(bool, SEQ);
    defer alloc.free(is_speech);
    var active: usize = 0;
    for (0..SEQ) |i| { is_speech[i] = energy[i] > thresh; if (is_speech[i]) active += 1; }
    if (active < 2) return;

    var c0 = try alloc.alloc(f32, DE); defer alloc.free(c0);
    var c1 = try alloc.alloc(f32, DE); defer alloc.free(c1);
    var labels = try alloc.alloc(u8, SEQ); defer alloc.free(labels);
    @memset(labels, 0);
    var first: usize = 0; var last: usize = SEQ - 1;
    for (0..SEQ) |i| if (is_speech[i]) { first = i; break; };
    var ir: usize = SEQ; while (ir > 0) { ir -= 1; if (is_speech[ir]) { last = ir; break; } }
    for (0..DE) |j| { c0[j] = f[first * DE + j]; c1[j] = f[last * DE + j]; }

    for (0..5) |_| {
        var s0 = try alloc.alloc(f32, DE); defer alloc.free(s0);
        var s1 = try alloc.alloc(f32, DE); defer alloc.free(s1);
        @memset(s0, 0); @memset(s1, 0);
        var n0: usize = 0; var n1: usize = 0;
        for (0..SEQ) |i| {
            if (!is_speech[i]) continue;
            var d0: f32 = 0; var d1: f32 = 0;
            for (0..DE) |j| {
                const x = f[i * DE + j];
                d0 += (x - c0[j]) * (x - c0[j]);
                d1 += (x - c1[j]) * (x - c1[j]);
            }
            if (d0 < d1) { labels[i] = 0; n0 += 1; for (0..DE) |j| s0[j] += f[i * DE + j]; }
            else { labels[i] = 1; n1 += 1; for (0..DE) |j| s1[j] += f[i * DE + j]; }
        }
        if (n0 > 0) for (0..DE) |j| { c0[j] = s0[j] / @as(f32, @floatFromInt(n0)); };
        if (n1 > 0) for (0..DE) |j| { c1[j] = s1[j] / @as(f32, @floatFromInt(n1)); };
    }

    // temporal smoothing (window ±10)
    var sm = try alloc.alloc(u8, SEQ); defer alloc.free(sm);
    @memset(sm, 0);
    for (0..SEQ) |i| {
        if (!is_speech[i]) continue;
        var votes: i32 = 0;
        const lo = if (i > 10) i - 10 else 0;
        const hi = if (i + 10 < SEQ) i + 10 else SEQ - 1;
        for (lo..hi + 1) |w| if (is_speech[w]) { votes += if (labels[w] == 1) @as(i32, 1) else -1; };
        sm[i] = if (votes > 0) 1 else 0;
    }

    try out.print("\n=== SPEAKER TIMELINE (zero-shot) ===\n", .{});
    var seg = false; var start: usize = 0; var spk: u8 = 0; var n_spk: usize = 0;
    var distinct = [_]bool{ false, false };
    for (0..SEQ) |i| {
        if (is_speech[i]) {
            const sp = sm[i];
            if (!seg) { seg = true; start = i; spk = sp; }
            else if (spk != sp) {
                if (i - start > 15) { try emitSeg(out, start, i, spk); distinct[spk] = true; n_spk += 1; }
                start = i; spk = sp;
            }
        } else if (seg) {
            if (i - start > 15) { try emitSeg(out, start, i, spk); distinct[spk] = true; n_spk += 1; }
            seg = false;
        }
    }
    if (seg and SEQ - start > 15) { try emitSeg(out, start, SEQ, spk); distinct[spk] = true; }
    const nd: u32 = (if (distinct[0]) @as(u32, 1) else 0) + (if (distinct[1]) @as(u32, 1) else 0);
    try out.print("  → {d} speaker(s) detected\n", .{nd});
}

fn emitSeg(out: anytype, a: usize, b: usize, spk: u8) !void {
    try out.print("  [{d:.2}s - {d:.2}s] Speaker {d}\n", .{ @as(f32, @floatFromInt(a)) * 0.02, @as(f32, @floatFromInt(b)) * 0.02, spk });
}

// Median-filter (size 3) each text token's alignment row, argmax → encoder
// frame → time (each frame = 20 ms). Group into words at space-prefixed tokens.
fn wordTimestamps(out: anytype, bpe_path: []const u8, ca: [*]f32, out_tokens: []const u32, n_text: u32, t_off: f32) !void {
    const toks = try loadBpe(bpe_path);
    var word = std.ArrayList(u8).init(alloc);
    var word_start: f32 = -1;
    try out.print("\n=== WORD TIMESTAMPS ===\n", .{});
    for (0..n_text) |i| {
        const ti = SEED.len + i; // ca row index == sequence position
        const row = ca[ti * ENC_SEQ ..][0..ENC_SEQ];
        // median-3 + argmax
        var best_j: u32 = 0;
        var best_v: f32 = -1;
        for (0..ENC_SEQ) |j| {
            const lo = if (j > 0) row[j - 1] else row[j];
            const md = row[j];
            const hi = if (j + 1 < ENC_SEQ) row[j + 1] else row[j];
            var a = lo; var b = md; const c = hi;
            if (a > b) { const t = a; a = b; b = t; }
            if (b > c) { b = c; }
            if (a > b) { b = a; }
            if (b > best_v) { best_v = b; best_j = @intCast(j); }
        }
        const ts: f32 = t_off + @as(f32, @floatFromInt(best_j)) * 0.02; // 20 ms/frame + chunk offset
        const tok_bytes = if (out_tokens[ti] < toks.len) toks[out_tokens[ti]] else "";
        const starts_word = tok_bytes.len > 0 and tok_bytes[0] == ' ';
        if (starts_word and word.items.len > 0) {
            try out.print("  [{d:.2}s] {s}\n", .{ word_start, word.items });
            word.clearRetainingCapacity();
        }
        if (word.items.len == 0) word_start = ts;
        try word.appendSlice(tok_bytes);
    }
    if (word.items.len > 0) try out.print("  [{d:.2}s] {s}\n", .{ word_start, word.items });
}

fn loadBpe(path: []const u8) ![][]const u8 {
    const bytes = try std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024 * 1024);
    var off: usize = 4;
    const vs = std.mem.readInt(u32, bytes[0..4], .little);
    const toks = try alloc.alloc([]const u8, vs);
    for (0..vs) |i| {
        const l = std.mem.readInt(u32, bytes[off..][0..4], .little);
        off += 4;
        toks[i] = bytes[off .. off + l];
        off += l;
    }
    return toks;
}

// ── small launch helpers (single-buffer kernels) ─────────────────────
fn P(x: anytype) ?*const anyopaque {
    return @ptrCast(x);
}
const PS = @sizeOf(usize);
const U = @sizeOf(u32);
const Ff = @sizeOf(f32);

fn imIm2col(f: mtl.Function, col: [*]f16, in: [*]f32, cin: u32, lin: u32, stride: u32, pad: u32, lout: u32) !void {
    var a0 = col; var a1 = in; var c = cin; var l = lin; var k: u32 = 3; var st = stride; var pd = pad; var lo = lout;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&c), P(&l), P(&k), P(&st), P(&pd), P(&lo) };
    const sz = [_]usize{ PS, PS, U, U, U, U, U, U };
    try mtl.dispatch(f, .{ (lout * cin * 3 + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &p, &sz);
}
fn geluTranspose(f: mtl.Function, o: [*]f32, in: [*]f16, bias: [*]f32, lout: u32, cout: u32) !void {
    var a0 = o; var a1 = in; var a2 = bias; var l = lout; var c = cout;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&l), P(&c) };
    const sz = [_]usize{ PS, PS, PS, U, U };
    try mtl.dispatch(f, .{ (lout * cout + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &p, &sz);
}
fn geluPos(f: mtl.Function, o: [*]f32, in: [*]f16, bias: [*]f32, pos: [*]f32, n: u32, cout: u32) !void {
    var a0 = o; var a1 = in; var a2 = bias; var a3 = pos; var nn = n; var c = cout;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&nn), P(&c) };
    const sz = [_]usize{ PS, PS, PS, PS, U, U };
    try mtl.dispatch(f, .{ (n + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &p, &sz);
}
fn conv1d(f: mtl.Function, o: [*]f32, i: [*]f32, w: [*]f32, b: [*]f32, cin: u32, cout: u32, lin: u32, stride: u32, lout: u32) !void {
    var a0 = o; var a1 = i; var a2 = w; var a3 = b; var c0 = cin; var c1 = cout; var l0 = lin; var k: u32 = 3; var st = stride; var pd: u32 = 1;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&c0), P(&c1), P(&l0), P(&k), P(&st), P(&pd) };
    const s = [_]usize{ PS, PS, PS, PS, U, U, U, U, U, U };
    try mtl.dispatch(f, .{ lout, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn embLookup(f: mtl.Function, o: [*]f32, emb: [*]f16, tok: *u32) !void {
    var a0 = o; var a1 = emb; var a2 = tok; var nd = D;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&nd) };
    const s = [_]usize{ PS, PS, PS, U };
    try mtl.dispatch(f, .{ 1, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kLogitGemv(f: mtl.Function, logits: [*]f32, emb: [*]f16, x: [*]f32, vocab: u32, dim: u32) !void {
    var a0 = logits; var a1 = emb; var a2 = x; var v = vocab; var d = dim;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&v), P(&d) };
    const s = [_]usize{ PS, PS, PS, U, U };
    try mtl.dispatch(f, .{ (vocab + 7) / 8, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn residual(K: dec.Kernels, x: [*]f32, y: [*]f32, n: u32) !void {
    var a0 = x; var a1 = y; var nn = n;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&nn) };
    const s = [_]usize{ PS, PS, U };
    try mtl.dispatch(K.res, .{ (n + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn biasAdd(K: dec.Kernels, x: [*]f32, b: [*]f32, n: u32, d: u32) !void {
    var a0 = x; var a1 = b; var nn = n; var nd = d;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&nn), P(&nd) };
    const s = [_]usize{ PS, PS, U, U };
    try mtl.dispatch(K.bias, .{ (n + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn biasAdd16(f: mtl.Function, x: [*]f16, b: [*]f32, n: u32, d: u32) !void {
    var a0 = x; var a1 = b; var nn = n; var nd = d;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&nn), P(&nd) };
    const s = [_]usize{ PS, PS, U, U };
    try mtl.dispatch(f, .{ (n + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn layerNorm(K: dec.Kernels, x: [*]f32, y: [*]f32, g: [*]f32, b: [*]f32, d: u32) !void {
    var a0 = x; var a1 = y; var a2 = g; var a3 = b; var nd = d; var ne: f32 = 1e-5;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&nd), P(&ne) };
    const s = [_]usize{ PS, PS, PS, PS, U, Ff };
    try mtl.dispatch(K.ln, .{ 1, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}

// ── GPU-resident decode-loop launchers (sync-free replay) ────────────
fn kEmbInd(f: mtl.Function, o: [*]f32, emb: [*]f16, toks: [*]u32, pos: [*]u32) !void {
    var a0 = o; var a1 = emb; var a2 = toks; var a3 = pos; var nd = D;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&nd) };
    const s = [_]usize{ PS, PS, PS, PS, U };
    try mtl.dispatch(f, .{ (D + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kPeInd(f: mtl.Function, o: [*]f32, pe: [*]f32, pos: [*]u32) !void {
    var a0 = o; var a1 = pe; var a2 = pos; var nd = D;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&nd) };
    const s = [_]usize{ PS, PS, PS, U };
    try mtl.dispatch(f, .{ (D + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kStep(f: mtl.Function, pos: [*]u32) !void {
    var a0 = pos;
    const p = [_]?*const anyopaque{P(&a0)};
    const s = [_]usize{PS};
    try mtl.dispatch(f, .{ 1, 1, 1 }, .{ 1, 1, 1 }, &p, &s);
}
fn kArgmax(f: mtl.Function, logits: [*]f32, toks: [*]u32, pos: [*]u32, max_len: u32) !void {
    var a0 = logits; var a1 = toks; var a2 = pos; var ml = max_len;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&ml) };
    const s = [_]usize{ PS, PS, PS, U };
    try mtl.dispatch(f, .{ 1, 1, 1 }, .{ 1024, 1, 1 }, &p, &s);
}
fn kFilt(f: mtl.Function, logits: [*]f32, toks: [*]u32, pos: [*]u32, sample_begin: u32) !void {
    var a0 = logits; var a1 = toks; var ns: u32 = 0; var a3 = pos; var sb = sample_begin;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&ns), P(&a3), P(&sb) };
    const s = [_]usize{ PS, PS, U, PS, U };
    try mtl.dispatch(f, .{ 1, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kSuppress(f: mtl.Function, logits: [*]f32, ids: [*]u32, n: u32) !void {
    var a0 = logits; var a1 = ids; var nn = n;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&nn) };
    const s = [_]usize{ PS, PS, U };
    try mtl.dispatch(f, .{ (n + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}

// ── asset file helpers ───────────────────────────────────────────────
fn bpe_dir(bpe_path: []const u8) []const u8 {
    return std.fs.path.dirname(bpe_path) orelse ".";
}
fn readBinF32(dir: []const u8, name: []const u8) ![]f32 {
    var pb: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, name });
    const bytes = try std.fs.cwd().readFileAllocOptions(alloc, path, 256 * 1024 * 1024, null, @alignOf(f32), null);
    return std.mem.bytesAsSlice(f32, bytes);
}
fn readBinU32(dir: []const u8, name: []const u8) ![]u32 {
    var pb: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, name });
    const bytes = try std.fs.cwd().readFileAllocOptions(alloc, path, 64 * 1024 * 1024, null, @alignOf(u32), null);
    return std.mem.bytesAsSlice(u32, bytes);
}

// WHISPER_BPE.bin: u32 vocab_size, then per-id (u32 len + raw bytes).
fn bpeDecode(path: []const u8, ids: []const u32) ![]u8 {
    const bytes = try std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024 * 1024);
    var off: usize = 4;
    const vs = std.mem.readInt(u32, bytes[0..4], .little);
    var toks = try alloc.alloc([]const u8, vs);
    for (0..vs) |i| {
        const l = std.mem.readInt(u32, bytes[off..][0..4], .little);
        off += 4;
        toks[i] = bytes[off .. off + l];
        off += l;
    }
    var buf = std.ArrayList(u8).init(alloc);
    for (ids) |id| {
        if (id < vs) try buf.appendSlice(toks[id]);
    }
    return buf.items;
}
