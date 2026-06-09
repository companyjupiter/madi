// transcribe.zig — Sovereign Whisper (Metal) full pipeline:
//   WAV → mel → Conv1D×2 → 32-layer encoder → cross-KV → 4-layer autoregressive
//   decoder → argmax → BPE decode.  Reads model.safetensors directly (F16→F32).
// Usage: transcribe <model.safetensors> <audio.wav> <WHISPER_BPE.bin> [weights for conv via same safetensors]
const std = @import("std");
const mtl = @import("metal_backend.zig");
const mel = @import("mel.zig");
const enc = @import("encoder.zig");
const dec = @import("decoder.zig");
const diar = @import("diar_resnet.zig");
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

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
// pread-based loader: the 1.6GB data section is NEVER mmap'd/resident. Each
// tensor is pread into a single reusable scratch buffer, consumed (copied or
// quantized into a unified GPU buffer), then overwritten by the next read.
// Peak RSS ≈ GPU weight buffers + one tensor's bytes (vs +1.6GB with mmap;
// macOS won't reclaim read-once mmap pages via madvise, so mmap is avoided).
var g_rd: []u8 = &.{}; // reusable per-tensor read buffer (grows as needed)

const Sf = struct {
    fd: std.posix.fd_t,
    off: usize, // data section start
    size: usize, // total file size (for reporting)
    json: []u8, // heap-allocated header

    fn open(path: []const u8) !Sf {
        const fd = try std.posix.open(path, .{}, 0);
        const sz: usize = @intCast((try std.posix.fstat(fd)).size);
        var hdr: [8]u8 = undefined;
        if (try std.posix.pread(fd, &hdr, 0) != 8) return error.BadHeader;
        const n = std.mem.readInt(u64, &hdr, .little);
        const json = try alloc.alloc(u8, n);
        if (try std.posix.pread(fd, json, 8) != n) return error.BadHeader;
        return .{ .fd = fd, .off = 8 + n, .size = sz, .json = json };
    }
    /// Raw F16 bytes for a tensor key (null if absent). Valid until the next
    /// raw() call — the returned slice aliases the shared scratch buffer.
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
        const len = e - s;
        if (g_rd.len < len) {
            if (g_rd.len > 0) alloc.free(g_rd);
            g_rd = alloc.alloc(u8, len) catch return null;
        }
        const buf = g_rd[0..len];
        var got: usize = 0;
        while (got < len) {
            const m = std.posix.pread(self.fd, buf[got..], self.off + s + got) catch return null;
            if (m == 0) return null;
            got += m;
        }
        return buf;
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
const Q8 = dec.Q8w;
/// Quantize an F16 [rows][dim] tensor to Q8_0 (int8 + per-32-block fp16 scale).
fn upVecQ8(sf: Sf, key: []const u8, rows: usize, dim: usize) !Q8 {
    const r = sf.raw(key) orelse return error.MissingTensor;
    const u16s = @as([*]align(1) const u16, @ptrCast(r.ptr))[0 .. rows * dim];
    const nb = dim / 32;
    const qs = try mtl.allocSlice(i8, rows * dim);
    const sc = try mtl.allocSlice(f16, rows * nb);
    for (0..rows) |v| {
        for (0..nb) |b| {
            var mx: f32 = 0;
            for (0..32) |i| { const w = @abs(h2f(u16s[v * dim + b * 32 + i])); if (w > mx) mx = w; }
            const scale: f32 = if (mx > 0) mx / 127.0 else 1.0;
            sc[v * nb + b] = @floatCast(scale);
            const inv = 1.0 / scale;
            for (0..32) |i| {
                const q = std.math.clamp(@round(h2f(u16s[v * dim + b * 32 + i]) * inv), -127.0, 127.0);
                qs[v * dim + b * 32 + i] = @intFromFloat(q);
            }
        }
    }
    return .{ .qs = qs.ptr, .scales = sc.ptr };
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

// Quantize a safetensors [out][in] f16 matrix → Q8_0 natural [out][in] layout
// (per output row, blocks of 32 along `in`). Feeds encoder JIT-dequant→MPS.
fn quantInto(u16s: [*]align(1) const u16, qs: [*]i8, sc: [*]f16, out_ch: usize, in_ch: usize, row0: usize) void {
    const nb = in_ch / 32;
    for (0..out_ch) |o| {
        const row = row0 + o;
        for (0..nb) |b| {
            var mx: f32 = 0;
            for (0..32) |i| { const w = @abs(h2f(u16s[o * in_ch + b * 32 + i])); if (w > mx) mx = w; }
            const scale: f32 = if (mx > 0) mx / 127.0 else 1.0;
            sc[row * nb + b] = @floatCast(scale);
            const inv = 1.0 / scale;
            for (0..32) |i| {
                const q = std.math.clamp(@round(h2f(u16s[o * in_ch + b * 32 + i]) * inv), -127.0, 127.0);
                qs[row * in_ch + b * 32 + i] = @intFromFloat(q);
            }
        }
    }
}
fn upMatQ8(sf: Sf, key: []const u8, out_ch: usize, in_ch: usize) !enc.Q8 {
    const r = sf.raw(key) orelse return error.MissingTensor;
    const u16s = @as([*]align(1) const u16, @ptrCast(r.ptr));
    const qs = try mtl.allocSlice(i8, out_ch * in_ch);
    const sc = try mtl.allocSlice(f16, out_ch * (in_ch / 32));
    quantInto(u16s, qs.ptr, sc.ptr, out_ch, in_ch, 0);
    return .{ .qs = qs.ptr, .scales = sc.ptr };
}
// Encoder qkv stacked [3D][D] Q8 (q|k|v out-major), for JIT-dequant→MPS.
fn upQKVQ8enc(sf: Sf, l: usize) !enc.Q8 {
    const nb = @as(usize, D) / 32;
    const qs = try mtl.allocSlice(i8, 3 * @as(usize, D) * D);
    const sc = try mtl.allocSlice(f16, 3 * @as(usize, D) * nb);
    var kbuf: [128]u8 = undefined;
    const names = [_][]const u8{ "q_proj", "k_proj", "v_proj" };
    for (names, 0..) |nm, blk| {
        const key = std.fmt.bufPrint(&kbuf, "model.encoder.layers.{d}.self_attn.{s}.weight", .{ l, nm }) catch unreachable;
        const r = sf.raw(key) orelse return error.MissingTensor;
        const u16s = @as([*]align(1) const u16, @ptrCast(r.ptr));
        quantInto(u16s, qs.ptr, sc.ptr, D, D, blk * @as(usize, D));
    }
    return .{ .qs = qs.ptr, .scales = sc.ptr };
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
fn upQKVQ8(sf: Sf, l: usize) !Q8 {
    const nb = @as(usize, D) / 32;
    const qs = try mtl.allocSlice(i8, 3 * @as(usize, D) * D);
    const sc = try mtl.allocSlice(f16, 3 * @as(usize, D) * nb);
    var kbuf: [128]u8 = undefined;
    const names = [_][]const u8{ "q_proj", "k_proj", "v_proj" };
    for (names, 0..) |nm, blk| {
        const key = std.fmt.bufPrint(&kbuf, "model.decoder.layers.{d}.self_attn.{s}.weight", .{ l, nm }) catch unreachable;
        const r = sf.raw(key) orelse return error.MissingTensor;
        const u16s = @as([*]align(1) const u16, @ptrCast(r.ptr))[0 .. @as(usize, D) * D];
        const ro = blk * @as(usize, D);
        for (0..D) |o| {
            const row = ro + o;
            for (0..nb) |b| {
                var mx: f32 = 0;
                for (0..32) |i| { const w = @abs(h2f(u16s[o * @as(usize, D) + b * 32 + i])); if (w > mx) mx = w; }
                const scale: f32 = if (mx > 0) mx / 127.0 else 1.0;
                sc[row * nb + b] = @floatCast(scale);
                const inv = 1.0 / scale;
                for (0..32) |i| {
                    const q = std.math.clamp(@round(h2f(u16s[o * @as(usize, D) + b * 32 + i]) * inv), -127.0, 127.0);
                    qs[row * @as(usize, D) + b * 32 + i] = @intFromFloat(q);
                }
            }
        }
    }
    return .{ .qs = qs.ptr, .scales = sc.ptr };
}

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
// speaker-attributed transcript: words (global time + text) ⨝ speaker segments
const Word = struct { t: f32, txt: []const u8 };
const SpkSeg = struct { a: f32, b: f32, spk: i32 };
var g_words = std.ArrayList(Word).init(alloc);
var g_segs = std.ArrayList(SpkSeg).init(alloc);

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
    const rttm_out = args.next(); // optional 4th arg: write system RTTM here (DER scoring)
    const spk_arg = args.next(); // optional 5th arg: number of speakers (0/absent = 2)
    // file-id for RTTM = wav basename without extension
    const wav_base = std.fs.path.basename(wav_path);
    const file_id = if (std.mem.lastIndexOfScalar(u8, wav_base, '.')) |dot| wav_base[0..dot] else wav_base;
    // target speaker count for diarization (CLI 5th arg or env DIAR_K; default 2).
    // NOTE: reliable only up to ~2 on hard far-field audio (mel features); higher K
    // works on cleaner, well-separated voices — see PERF_LOG ACC-2.
    const n_speakers: u32 = blk: {
        if (spk_arg) |s| break :blk std.fmt.parseInt(u32, s, 10) catch 0;
        if (std.posix.getenv("DIAR_K")) |s| break :blk std.fmt.parseInt(u32, s, 10) catch 0;
        break :blk 0;
    };
    const diar_k: u32 = n_speakers; // 0 = auto-estimate K (silhouette); ≥1 = fixed

    try mtl.init();
    defer mtl.deinit();
    try mtl.loadLibrary(METALLIB);
    const f_im2col = try mtl.getFunction("im2col_f16");
    const f_geluT = try mtl.getFunction("gelu_transpose");
    const f_geluPos = try mtl.getFunction("gelu_pos");
    const Ke = try enc.Kernels.load();
    const Kd = try dec.Kernels.load();
    const f_emb = try mtl.getFunction("gpu_emb_lookup_q8");
    // GPU-resident decode-loop kernels (sync-free replay; from the SHARE build)
    const f_emb_ind = try mtl.getFunction("emb_lookup_indirect_q8");
    const f_pe_ind = try mtl.getFunction("pos_embed_add_indirect");
    const f_step = try mtl.getFunction("step_advance");
    const f_argmax = try mtl.getFunction("argmax_no_inc");
    const f_filt = try mtl.getFunction("logit_filter_indirect");
    const f_suppress = try mtl.getFunction("suppress_list");
    const f_logit = try mtl.getFunction("logit_gemv_q8");
    const f_bias16 = try mtl.getFunction("bias_add_f16");
    const f_deq = try mtl.getFunction("dequant_q8_f16");
    try out.print("[1] Metal + kernels ready\n", .{});

    const sf = try Sf.open(model_path);
    try out.print("[2] model.safetensors opened ({d} MB, pread streaming)\n", .{sf.size / 1048576});

    const zeros = try mtl.allocSlice(f32, D);
    @memset(zeros, 0);
    g_zeros = zeros.ptr;

    // ── one-time weights: conv front-end + positional ───────────────
    const mel_filters = try readBinF32(bpe_dir(bpe_path), "mel_filters.bin");
    const mel_buf = try mtl.allocSlice(f32, mel.N_MELS * mel.N_FRAMES);
    // diarization speaker-embedding model (sovereign ResNet34, CPU)
    var kb_d: [256]u8 = undefined;
    const diar_w = std.fmt.bufPrint(&kb_d, "{s}/resnet34_diar.bin", .{bpe_dir(bpe_path)}) catch unreachable;
    var kb_d2: [256]u8 = undefined;
    const diar_mb = std.fmt.bufPrint(&kb_d2, "{s}/kaldi_melbank.bin", .{bpe_dir(bpe_path)}) catch unreachable;
    var diar_model = try diar.Model.load(alloc, diar_w, diar_mb);
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
        elayers[l] = .{
            .aln_w = try upVec(sf, keyL(&kb[0], "model.encoder.layers.{d}.self_attn_layer_norm.weight", l)),
            .aln_b = try upVec(sf, keyL(&kb[0], "model.encoder.layers.{d}.self_attn_layer_norm.bias", l)),
            .qkv_w = try upQKVQ8enc(sf, l),
            .q_b = try upVec(sf, keyL(&kb[0], "model.encoder.layers.{d}.self_attn.q_proj.bias", l)),
            .k_b = g_zeros, // whisper k_proj has no bias
            .v_b = try upVec(sf, keyL(&kb[0], "model.encoder.layers.{d}.self_attn.v_proj.bias", l)),
            .o_w = try upMatQ8(sf, keyL(&kb[0], "model.encoder.layers.{d}.self_attn.out_proj.weight", l), D, D),
            .o_b = try upVec(sf, keyL(&kb[0], "model.encoder.layers.{d}.self_attn.out_proj.bias", l)),
            .mln_w = try upVec(sf, keyL(&kb[0], "model.encoder.layers.{d}.final_layer_norm.weight", l)),
            .mln_b = try upVec(sf, keyL(&kb[0], "model.encoder.layers.{d}.final_layer_norm.bias", l)),
            .m0_w = try upMatQ8(sf, keyL(&kb[0], "model.encoder.layers.{d}.fc1.weight", l), MLP, D),
            .m0_b = try upVec(sf, keyL(&kb[0], "model.encoder.layers.{d}.fc1.bias", l)),
            .m2_w = try upMatQ8(sf, keyL(&kb[0], "model.encoder.layers.{d}.fc2.weight", l), D, MLP),
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
        .wdq = (try mtl.allocSlice(f16, MLP * D)).ptr,
    };
    const out_f16 = (try mtl.allocSlice(f16, ENC_SEQ * D)).ptr;
    const enc_out = (try mtl.allocSlice(f32, ENC_SEQ * D)).ptr;

    // ── decoder weights (4 layers); cross-KV weights kept for per-chunk recompute ─
    var dlayers: [dec.NL]dec.Layer = undefined;
    const ckw = try alloc.alloc(enc.Q8, dec.NL); // Q8, JIT-dequanted per chunk → MPS
    const cvw = try alloc.alloc(enc.Q8, dec.NL);
    const cvb = try alloc.alloc([*]f32, dec.NL);
    const ckc = try alloc.alloc([*]f16, dec.NL);
    const cvc = try alloc.alloc([*]f16, dec.NL);
    const cross_wdq = (try mtl.allocSlice(f16, D * D)).ptr; // dequant scratch [in][out]
    for (0..dec.NL) |l| {
        ckw[l] = try upMatQ8(sf, keyL(&kb[0], "model.decoder.layers.{d}.encoder_attn.k_proj.weight", l), D, D);
        cvw[l] = try upMatQ8(sf, keyL(&kb[0], "model.decoder.layers.{d}.encoder_attn.v_proj.weight", l), D, D);
        cvb[l] = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.encoder_attn.v_proj.bias", l));
        ckc[l] = (try mtl.allocSlice(f16, ENC_SEQ * D)).ptr;
        cvc[l] = (try mtl.allocSlice(f16, ENC_SEQ * D)).ptr;
        dlayers[l] = .{
            .aln_w = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.self_attn_layer_norm.weight", l)),
            .aln_b = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.self_attn_layer_norm.bias", l)),
            .qkvw = try upQKVQ8(sf, l),
            .qb = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.self_attn.q_proj.bias", l)),
            .vb = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.self_attn.v_proj.bias", l)),
            .ow = try upVecQ8(sf, keyL(&kb[0], "model.decoder.layers.{d}.self_attn.out_proj.weight", l), D, D),
            .ob = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.self_attn.out_proj.bias", l)),
            .caln_w = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.encoder_attn_layer_norm.weight", l)),
            .caln_b = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.encoder_attn_layer_norm.bias", l)),
            .cqw = try upVecQ8(sf, keyL(&kb[0], "model.decoder.layers.{d}.encoder_attn.q_proj.weight", l), D, D),
            .cqb = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.encoder_attn.q_proj.bias", l)),
            .cow = try upVecQ8(sf, keyL(&kb[0], "model.decoder.layers.{d}.encoder_attn.out_proj.weight", l), D, D),
            .cob = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.encoder_attn.out_proj.bias", l)),
            .mln_w = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.final_layer_norm.weight", l)),
            .mln_b = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.final_layer_norm.bias", l)),
            .m0w = try upVecQ8(sf, keyL(&kb[0], "model.decoder.layers.{d}.fc1.weight", l), MLP, D),
            .m0b = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.fc1.bias", l)),
            .m2w = try upVecQ8(sf, keyL(&kb[0], "model.decoder.layers.{d}.fc2.weight", l), D, MLP),
            .m2b = try upVec(sf, keyL(&kb[0], "model.decoder.layers.{d}.fc2.bias", l)),
        };
    }
    const dln_w = try upVec(sf, "model.decoder.layer_norm.weight");
    const dln_b = try upVec(sf, "model.decoder.layer_norm.bias");
    const tok_emb = try upVecQ8(sf, "model.decoder.embed_tokens.weight", VOCAB, D); // Q8_0
    const dec_pe = try upVec(sf, "model.decoder.embed_positions.weight"); // [448][D]
    // all weights now in unified GPU buffers — release the read scratch + fd
    if (g_rd.len > 0) { alloc.free(g_rd); g_rd = &.{}; }
    alloc.free(sf.json);
    std.posix.close(sf.fd);
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
    // Global diarization accumulator: 256-d ResNet34 speaker embeddings over
    // 1.5 s waveform windows (real speaker timbre — AMI K=4 DER 31.7% vs 67% mel).
    // Clustered after the loop (L2-norm + k-means, K = diar_k) → global RTTM.
    const SEG_SAMP: usize = 24000; // 1.5 s @ 16 kHz
    const SEG_SEC: f32 = 1.5;
    const SEGD: usize = diar.EMB; // 256
    var diar_emb = std.ArrayList(f32).init(alloc); // n × 256
    var diar_bm = std.ArrayList(f32).init(alloc); // per-window RMS (for VAD)
    var diar_t0 = std.ArrayList(f32).init(alloc);
    var diar_n: usize = 0;
    // diar threading: 1 sgemm thread per worker (avoid Accelerate oversubscription)
    _ = setenv("VECLIB_MAXIMUM_THREADS", "1", 1);
    const diar_nthreads: usize = @min(std.Thread.getCpuCount() catch 4, 16);
    const max_win: usize = mel.CHUNK_SAMPLES / SEG_SAMP; // 20
    const cemb = try alloc.alloc(f32, max_win * diar.EMB);
    const crms = try alloc.alloc(f32, max_win);
    // language token for the SEED: env WHISPER_LANG_ID overrides; else 0 = auto
    // (detected once from the SOT-position logits on the first speech chunk).
    var lang_tok: u32 = blk: {
        if (std.posix.getenv("WHISPER_LANG_ID")) |s| break :blk std.fmt.parseInt(u32, s, 10) catch 0;
        break :blk 0;
    };
    var timer = try std.time.Timer.start();
    var chunk: usize = 0;
    while (chunk < n_chunks) : (chunk += 1) {
        const got = mel.loadWavChunk(wav, chunk * mel.CHUNK_SAMPLES, samples);
        if (chunk > 0 and got == 0) break;
        const t_off: f32 = @as(f32, @floatFromInt(chunk)) * 30.0;

        // diarization: 256-d ResNet34 speaker embedding per 1.5 s window over the
        // whole audio (independent of the transcription chunk-VAD so sparse speech
        // in quiet chunks is kept; relative energy VAD applied at clustering time).
        {
            const nwin = got / SEG_SAMP;
            if (nwin > 0) {
                const nt = @min(diar_nthreads, nwin);
                const per = (nwin + nt - 1) / nt;
                var jobs: [16]DiarJob = undefined;
                var threads: [16]std.Thread = undefined;
                var spawned: usize = 0;
                for (0..nt) |ti| {
                    const lo = ti * per;
                    if (lo >= nwin) break;
                    jobs[ti] = .{ .m = &diar_model, .samples = samples[0 .. nwin * SEG_SAMP], .emb = cemb, .rms = crms, .lo = lo, .hi = @min(lo + per, nwin) };
                    threads[ti] = try std.Thread.spawn(.{}, diarWorker, .{&jobs[ti]});
                    spawned += 1;
                }
                for (0..spawned) |ti| threads[ti].join();
                for (0..nwin) |wsg| {
                    try diar_emb.appendSlice(cemb[wsg * diar.EMB ..][0 .. diar.EMB]);
                    try diar_bm.append(crms[wsg]);
                    try diar_t0.append(t_off + @as(f32, @floatFromInt(wsg)) * SEG_SEC);
                    diar_n += 1;
                }
            }
        }

        // VAD: skip silent chunks entirely (no mel/encode/decode) — avoids the
        // silence-hallucination junk and saves compute on quiet meeting stretches.
        if (!hasSpeech(samples, got)) {
            if (n_chunks > 1) try out.print("\n[chunk {d}/{d} @ {d:.0}s] (silence — skipped)\n", .{ chunk + 1, n_chunks, t_off });
            if (got < mel.CHUNK_SAMPLES) break;
            continue;
        }

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
            try deqW16(f_deq, cross_wdq, ckw[l], D, D);
            try mtl.matmulF16Batched(out_f16, cross_wdq, ckc[l], ENC_SEQ, D, D);
            try deqW16(f_deq, cross_wdq, cvw[l], D, D);
            try mtl.matmulF16Batched(out_f16, cross_wdq, cvc[l], ENC_SEQ, D, D);
            try biasAdd16(f_bias16, cvc[l], cvb[l], ENC_SEQ * D, D);
            try mtl.commitCommandBuffer();
            try mtl.sync();
        }

        // reset decode state for this chunk
        for (SEED, 0..) |s, i| { d_tokens[i] = s; out_tokens[i] = s; }
        @memset(d_ca, 0);

        // language detection (Whisper-style): the prediction at the <|sot|>
        // position is the language token. Detect once (constant per file) by
        // arg-max over the language-token range [50259..50358]; env override skips.
        if (lang_tok == 0) {
            d_pos[0] = 0;
            try mtl.beginCommandBuffer();
            try embLookup(f_emb, d_x, tok_emb.qs, tok_emb.scales, &d_tokens[0]);
            try residual(Kd, d_x, dec_pe, D); // pos-0 positional embedding
            for (0..dec.NL) |l| {
                const ca_ctx = dec.CaCtx{ .weights = d_ca.ptr, .tok = d_pos, .heads = layer_heads[l], .inv_n = inv_n };
                try dec.decodeBlock(Kd, dlayers[l], d_x, dscr, skc[l], svc[l], ckc[l], cvc[l], d_pos, ca_ctx);
            }
            try layerNorm(Kd, d_x, dscr.xb, dln_w, dln_b, D);
            try kLogitGemv(f_logit, d_logits, tok_emb.qs, tok_emb.scales, dscr.xb, VOCAB, D);
            try mtl.commitCommandBuffer();
            try mtl.sync();
            var bl: u32 = 50259; var bv: f32 = d_logits[50259];
            var lt: u32 = 50259;
            while (lt <= 50358) : (lt += 1) { if (d_logits[lt] > bv) { bv = d_logits[lt]; bl = lt; } }
            lang_tok = bl;
            try out.print("[lang] detected token {d} (en=50259 ko=50264)\n", .{lang_tok});
        }
        d_tokens[1] = lang_tok;
        out_tokens[1] = lang_tok;

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
                try embLookup(f_emb, d_x, tok_emb.qs, tok_emb.scales, &d_tokens[sp]);
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
                try kEmbInd(f_emb_ind, d_x, tok_emb.qs, tok_emb.scales, d_tokens.ptr, d_pos);
                try kPeInd(f_pe_ind, d_x, dec_pe, d_pos);
                for (0..dec.NL) |l| {
                    const ca_ctx = dec.CaCtx{ .weights = d_ca.ptr, .tok = d_pos, .heads = layer_heads[l], .inv_n = inv_n };
                    try dec.decodeBlock(Kd, dlayers[l], d_x, dscr, skc[l], svc[l], ckc[l], cvc[l], d_pos, ca_ctx);
                }
                try layerNorm(Kd, d_x, dscr.xb, dln_w, dln_b, D);
                try kLogitGemv(f_logit, d_logits, tok_emb.qs, tok_emb.scales, dscr.xb, VOCAB, D);
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

    // optional: dump raw pooled segment embeddings for offline clustering sweeps
    if (std.posix.getenv("DIAR_DUMP")) |dp| {
        var df = try std.fs.cwd().createFile(dp, .{});
        defer df.close();
        const hdr = [_]u32{ @intCast(diar_n), @intCast(SEGD) };
        try df.writeAll(std.mem.sliceAsBytes(hdr[0..]));
        try df.writeAll(std.mem.sliceAsBytes(diar_t0.items[0..diar_n]));
        try df.writeAll(std.mem.sliceAsBytes(diar_emb.items[0 .. diar_n * SEGD]));
        try out.print("  [diar dump → {s}: {d} segs × {d}]\n", .{ dp, diar_n, SEGD });
    }
    try diarizeEmb(out, diar_emb.items, diar_bm.items, diar_t0.items, diar_n, SEGD, SEG_SEC, diar_k, rttm_out, file_id);
    try attributeTranscript(out);
}

fn envU(name: [:0]const u8, dflt: usize) usize {
    if (std.posix.getenv(name)) |s| return std.fmt.parseInt(usize, s, 10) catch dflt;
    return dflt;
}
fn envF(name: [:0]const u8, dflt: f32) f32 {
    if (std.posix.getenv(name)) |s| return std.fmt.parseFloat(f32, s) catch dflt;
    return dflt;
}
fn d2(a: []const f32, b: []const f32) f32 {
    var s: f32 = 0;
    for (0..a.len) |j| { const t = a[j] - b[j]; s += t * t; }
    return s;
}
// k-means (cosine via L2-normed X) with deterministic farthest-point init.
fn kmeansFit(X: []const f32, m: usize, segd: usize, K: usize, asg: []usize) !void {
    if (K <= 1) { @memset(asg, 0); return; }
    const cent = try alloc.alloc(f32, K * segd); defer alloc.free(cent);
    @memcpy(cent[0..segd], X[0..segd]);
    const dmin = try alloc.alloc(f32, m); defer alloc.free(dmin);
    for (0..m) |i| dmin[i] = d2(X[i * segd ..][0..segd], cent[0..segd]);
    for (1..K) |c| {
        var far: usize = 0; var fv: f32 = -1;
        for (0..m) |i| if (dmin[i] > fv) { fv = dmin[i]; far = i; };
        @memcpy(cent[c * segd ..][0..segd], X[far * segd ..][0..segd]);
        for (0..m) |i| { const dd = d2(X[i * segd ..][0..segd], cent[c * segd ..][0..segd]); if (dd < dmin[i]) dmin[i] = dd; }
    }
    const csum = try alloc.alloc(f32, K * segd); defer alloc.free(csum);
    const ccnt = try alloc.alloc(usize, K); defer alloc.free(ccnt);
    for (0..25) |_| {
        for (0..m) |i| {
            var bc: usize = 0; var bv: f32 = d2(X[i * segd ..][0..segd], cent[0..segd]);
            for (1..K) |c| { const dd = d2(X[i * segd ..][0..segd], cent[c * segd ..][0..segd]); if (dd < bv) { bv = dd; bc = c; } }
            asg[i] = bc;
        }
        @memset(csum, 0); @memset(ccnt, 0);
        for (0..m) |i| { ccnt[asg[i]] += 1; for (0..segd) |j| csum[asg[i] * segd + j] += X[i * segd + j]; }
        for (0..K) |c| if (ccnt[c] > 0) for (0..segd) |j| { cent[c * segd + j] = csum[c * segd + j] / @as(f32, @floatFromInt(ccnt[c])); };
    }
}
// Simplified silhouette (centroid distance, O(m·K·segd)) for auto-K selection.
fn silhouetteSimplified(X: []const f32, m: usize, segd: usize, asg: []const usize, K: usize) !f32 {
    if (K < 2) return -2;
    const mu = try alloc.alloc(f32, K * segd); defer alloc.free(mu);
    const cnt = try alloc.alloc(usize, K); defer alloc.free(cnt);
    @memset(mu, 0); @memset(cnt, 0);
    for (0..m) |i| { cnt[asg[i]] += 1; for (0..segd) |j| mu[asg[i] * segd + j] += X[i * segd + j]; }
    for (0..K) |c| if (cnt[c] > 0) for (0..segd) |j| { mu[c * segd + j] /= @as(f32, @floatFromInt(cnt[c])); };
    var sil: f64 = 0;
    for (0..m) |i| {
        const xi = X[i * segd ..][0..segd];
        const a = d2(xi, mu[asg[i] * segd ..][0..segd]);
        var b: f32 = 1e30;
        for (0..K) |c| { if (c == asg[i] or cnt[c] == 0) continue; const dd = d2(xi, mu[c * segd ..][0..segd]); if (dd < b) b = dd; }
        const mx = @max(a, b);
        if (mx > 1e-9) sil += @as(f64, (b - a) / mx);
    }
    return @floatCast(sil / @as(f64, @floatFromInt(m)));
}

// Global speaker diarization on 256-d ResNet34 speaker embeddings. Pipeline:
// relative energy VAD → L2-normalize → k-means (K = `diar_k`, deterministic
// farthest-point init) → merge consecutive same-speaker segments → timeline +
// optional RTTM. AMI ES2004a K=4 DER 31.7% (vs 67% mel, 90% encoder).
fn diarizeEmb(out: anytype, emb: []f32, bm: []const f32, t0: []const f32, n: usize, segd: usize, seg_sec: f32, diar_k: u32, rttm_path: ?[]const u8, file_id: []const u8) !void {
    try out.print("\n=== SPEAKER TIMELINE (ResNet34 embeddings, K={d}) ===\n", .{diar_k});
    if (n < 2) { try out.print("  (insufficient speech: {d} segs)\n", .{n}); return; }

    // relative energy VAD: keep windows with RMS > 0.3 × median RMS
    const rs = try alloc.dupe(f32, bm[0..n]); defer alloc.free(rs);
    std.mem.sort(f32, rs, {}, std.sort.asc(f32));
    const eth = rs[n / 2] * envF("DIAR_VAD", 0.4); // tuned on VoxConverse dev
    const keep = try alloc.alloc(usize, n); defer alloc.free(keep);
    var m: usize = 0;
    for (0..n) |i| if (bm[i] > eth) { keep[m] = i; m += 1; };
    if (m < 2) { try out.print("  (insufficient speech after VAD: {d})\n", .{m}); return; }

    // gather kept embeddings, L2-normalize (cosine k-means)
    const X = try alloc.alloc(f32, m * segd); defer alloc.free(X);
    for (0..m) |i| {
        const src = emb[keep[i] * segd ..][0..segd];
        var s: f32 = 0;
        for (src) |v| s += v * v;
        const inv = 1.0 / (@sqrt(s) + 1e-8);
        for (0..segd) |j| X[i * segd + j] = src[j] * inv;
    }

    // Choose K: fixed (diar_k≥1) or auto via simplified-silhouette over 2..maxK.
    const asg = try alloc.alloc(usize, m); defer alloc.free(asg);
    var K: usize = undefined;
    if (diar_k >= 1) {
        K = @min(@as(usize, diar_k), m);
        try kmeansFit(X, m, segd, K, asg);
    } else {
        const maxK: usize = @min(envU("DIAR_MAXK", 6), m); // tuned: 6 minimizes over-clustering (VoxConverse dev)
        const tau: f32 = envF("DIAR_SIL_TAU", 0.10); // below this → single speaker
        const tmp = try alloc.alloc(usize, m); defer alloc.free(tmp);
        var bestK: usize = 2; var bestSil: f32 = -2;
        var kk: usize = 2;
        while (kk <= maxK) : (kk += 1) {
            try kmeansFit(X, m, segd, kk, tmp);
            const sil = try silhouetteSimplified(X, m, segd, tmp, kk);
            if (sil > bestSil) { bestSil = sil; bestK = kk; @memcpy(asg, tmp); }
        }
        if (bestSil < tau) { K = 1; @memset(asg, 0); } else K = bestK;
        try out.print("  [auto-K] K={d} (silhouette {d:.3}, tau {d:.2})\n", .{ K, bestSil, tau });
    }

    // per-segment speaker label (kept segments only), relabel by first appearance
    const spk = try alloc.alloc(i32, n); defer alloc.free(spk);
    for (0..n) |i| spk[i] = -1;
    const remap = try alloc.alloc(i32, K); defer alloc.free(remap);
    for (0..K) |i| remap[i] = -1;
    var nspk: i32 = 0;
    for (0..m) |i| {
        const c = asg[i];
        if (remap[c] < 0) { remap[c] = nspk; nspk += 1; }
        spk[keep[i]] = remap[c];
    }

    // merge temporally-consecutive same-speaker speech segments → RTTM + timeline
    var rttm = std.ArrayList(u8).init(alloc);
    defer rttm.deinit();
    const flush = struct {
        fn f(o: anytype, r: *std.ArrayList(u8), fid: []const u8, a: f32, b: f32, sp: i32) !void {
            try o.print("  [{d:.2}s - {d:.2}s] Speaker {d}\n", .{ a, b, sp });
            try r.writer().print("SPEAKER {s} 1 {d:.3} {d:.3} <NA> <NA> spk{d} <NA> <NA>\n", .{ fid, a, b - a, sp });
            g_segs.append(.{ .a = a, .b = b, .spk = sp }) catch {};
        }
    }.f;
    var open_seg = false;
    var s_start: f32 = 0; var s_end: f32 = 0; var s_spk: i32 = -1;
    for (0..n) |i| {
        if (spk[i] < 0) continue; // non-speech segment → breaks any run
        if (open_seg and spk[i] == s_spk and t0[i] - s_end < seg_sec + 0.01) {
            s_end = t0[i] + seg_sec;
        } else {
            if (open_seg) try flush(out, &rttm, file_id, s_start, s_end, s_spk);
            open_seg = true; s_start = t0[i]; s_spk = spk[i]; s_end = t0[i] + seg_sec;
        }
    }
    if (open_seg) try flush(out, &rttm, file_id, s_start, s_end, s_spk);
    try out.print("  → {d} speaker(s) ({d}/{d} speech segments)\n", .{ nspk, m, n });

    if (rttm_path) |p| {
        try std.fs.cwd().writeFile(.{ .sub_path = p, .data = rttm.items });
        try out.print("  RTTM → {s}\n", .{p});
    }
}

// Median-filter (size 3) each text token's alignment row, argmax → encoder
// frame → time (each frame = 20 ms). Group into words at space-prefixed tokens.
// Speaker-attributed transcript: join each word (by global time) to the speaker
// segment covering it (nearest if in a gap), group consecutive same-speaker
// words → "Speaker N: …". Needs g_words (from wordTimestamps) + g_segs (diarize).
fn speakerAt(t: f32) i32 {
    var best: i32 = -1;
    var bestd: f32 = 1e30;
    for (g_segs.items) |s| {
        if (t >= s.a and t < s.b) return s.spk;
        const d = if (t < s.a) s.a - t else t - s.b;
        if (d < bestd) { bestd = d; best = s.spk; }
    }
    return best;
}
fn attributeTranscript(out: anytype) !void {
    if (g_words.items.len == 0 or g_segs.items.len == 0) return;
    try out.print("\n=== SPEAKER-ATTRIBUTED TRANSCRIPT ===\n", .{});
    var line = std.ArrayList(u8).init(alloc);
    defer line.deinit();
    var cur: i32 = -2;
    var cur_t: f32 = 0;
    for (g_words.items) |w| {
        const sp = speakerAt(w.t);
        if (sp != cur) {
            if (line.items.len > 0) try out.print("  [{d:.2}s] Speaker {d}:{s}\n", .{ cur_t, cur, line.items });
            line.clearRetainingCapacity();
            cur = sp; cur_t = w.t;
        }
        try line.appendSlice(w.txt); // txt already has a leading space for word starts
    }
    if (line.items.len > 0) try out.print("  [{d:.2}s] Speaker {d}:{s}\n", .{ cur_t, cur, line.items });
}
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
            try g_words.append(.{ .t = word_start, .txt = try alloc.dupe(u8, word.items) });
            word.clearRetainingCapacity();
        }
        if (word.items.len == 0) word_start = ts;
        try word.appendSlice(tok_bytes);
    }
    if (word.items.len > 0) {
        try out.print("  [{d:.2}s] {s}\n", .{ word_start, word.items });
        try g_words.append(.{ .t = word_start, .txt = try alloc.dupe(u8, word.items) });
    }
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
fn embLookup(f: mtl.Function, o: [*]f32, qs: [*]i8, sc: [*]f16, tok: *u32) !void {
    var a0 = o; var a1 = qs; var a2 = sc; var a3 = tok; var nd = D;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&nd) };
    const s = [_]usize{ PS, PS, PS, PS, U };
    try mtl.dispatch(f, .{ 1, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
fn kLogitGemv(f: mtl.Function, logits: [*]f32, qs: [*]i8, sc: [*]f16, x: [*]f32, vocab: u32, dim: u32) !void {
    var a0 = logits; var a1 = qs; var a2 = sc; var a3 = x; var v = vocab; var d = dim;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&v), P(&d) };
    const s = [_]usize{ PS, PS, PS, PS, U, U };
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
// Dequant Q8 weight [out=N][in=K] → F16 [K][N] (MPS B layout) via dequant_q8_f16.
fn deqW16(f: mtl.Function, wdq: [*]f16, w: enc.Q8, n: u32, k: u32) !void {
    var a0 = wdq; var a1 = w.qs; var a2 = w.scales; var nn = n; var kk = k;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&nn), P(&kk) };
    const s = [_]usize{ PS, PS, PS, U, U };
    try mtl.dispatch(f, .{ (n * k + 255) / 256, 1, 1 }, .{ 256, 1, 1 }, &p, &s);
}
// Energy VAD: is there speech in this chunk? Uses the loudest 1-second window's
// RMS so a chunk with only a brief utterance is still transcribed, while truly
// silent / ambient-only chunks are skipped. Whisper's <|nospeech|> token does
// NOT fire on (out-of-distribution) digital silence in large-v3-turbo, so this
// input-energy gate is the robust defense against silence hallucination
// ("you. You. You." on a quiet chunk) — essential for meeting audio.
fn hasSpeech(samples: []const f32, got: usize) bool {
    const VAD_RMS: f32 = 0.01; // normalized [-1,1]; speech≈0.14, silence/ambient≲0.001
    const win: usize = 16000; // 1 s @ 16 kHz
    var i: usize = 0;
    while (i < got) : (i += win) {
        const end = @min(i + win, got);
        var s: f64 = 0;
        for (samples[i..end]) |x| s += @as(f64, x) * @as(f64, x);
        const r = @sqrt(s / @as(f64, @floatFromInt(end - i)));
        if (r > VAD_RMS) return true;
    }
    return false;
}
// Parallel diarization embedding: each 1.5 s window is independent, so a pool
// of threads embeds them concurrently (~Ncore×). Model is read-only/shared;
// each diar.embed uses its own arena over the (thread-safe) page allocator.
const DIAR_WIN: usize = 24000; // 1.5 s
const DiarJob = struct {
    m: *const diar.Model,
    samples: []const f32, // chunk PCM
    emb: []f32, // [nwin][256] out
    rms: []f32, // [nwin] out
    lo: usize,
    hi: usize,
};
fn diarWorker(j: *const DiarJob) void {
    var w = j.lo;
    while (w < j.hi) : (w += 1) {
        const win = j.samples[w * DIAR_WIN ..][0..DIAR_WIN];
        var e: f64 = 0;
        for (win) |v| e += @as(f64, v) * v;
        j.rms[w] = @floatCast(@sqrt(e / @as(f64, DIAR_WIN)));
        const emb = diar.embed(j.m, win) catch {
            @memset(j.emb[w * diar.EMB ..][0 .. diar.EMB], 0);
            continue;
        };
        @memcpy(j.emb[w * diar.EMB ..][0 .. diar.EMB], emb[0..]);
    }
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
fn kEmbInd(f: mtl.Function, o: [*]f32, qs: [*]i8, sc: [*]f16, toks: [*]u32, pos: [*]u32) !void {
    var a0 = o; var a1 = qs; var a2 = sc; var a3 = toks; var a4 = pos; var nd = D;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&a4), P(&nd) };
    const s = [_]usize{ PS, PS, PS, PS, PS, U };
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
