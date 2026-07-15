// transcribe.zig — Sovereign Whisper (Metal) full pipeline:
//   WAV → mel → Conv1D×2 → 32-layer encoder → cross-KV → 4-layer autoregressive
//   decoder → argmax → BPE decode.  Reads model.safetensors directly (F16→F32).
// Usage: transcribe <model.safetensors> <audio.wav> <WHISPER_BPE.bin> [weights for conv via same safetensors]
//
// ───────────────────────────────────────────────────────────────────────────
// THIRD-PARTY ATTRIBUTION — MIT License
//   Speech-recognition model = OpenAI Whisper (large-v3-turbo) architecture and
//   weights:  https://github.com/openai/whisper
//   Copyright (c) 2022 OpenAI. Licensed under the MIT License. This is an
//   independent Zig/Metal reimplementation of the inference path; the weights
//   are format-converted, not modified in substance.
//   Speaker diarization uses WeSpeaker ResNet34 (Apache-2.0) — see
//   diar_resnet.zig. Full license texts: ../NOTICE, ../THIRD_PARTY_LICENSES.md
// ───────────────────────────────────────────────────────────────────────────
const std = @import("std");
const mtl = @import("metal_backend.zig");
const mel = @import("mel.zig");
const enc = @import("encoder.zig");
const dec = @import("decoder.zig");
const diar = @import("diar_resnet.zig");
const vad = @import("vad_silero.zig");
const osd = @import("osd_pyannote.zig");
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const METALLIB = @embedFile("whisper.metallib");
const D = enc.D;
const MLP = enc.MLP;
const NH = enc.NH;
const ENC_SEQ = dec.ENC_SEQ; // 1500
const VOCAB = dec.VOCAB; // 51866
const MAX_TOK = dec.MAX_TOK; // 448
const EOT: u32 = 50257;
// sot, lang, transcribe — NO <|notimestamps|>: timestamp-token decoding is a
// QUALITY device, not a feature toggle. Greedy no-ts decode collapses into
// repeat loops on hard audio (clova 5/99 chunks "Q. Q. Q."×55; whisper-cli
// -nt reproduces the identical collapse) — the <|t0|>…<|t1|> structure
// regularizes the decode. ts tokens are consumed by ts_rules_indirect and
// stripped from output/word-timestamps.
const SEED = [_]u32{ 50258, 50259, 50360 };
const TS0: u32 = 50365; // <|0.00|>; ids ≥ TS0 are timestamp tokens

// int4 quality probe: when set (env Q4=1), every Q8-quantized weight is first
// rounded to 4-bit (symmetric per-32-block, 15 levels) BEFORE the existing Q8
// quant — measures the WER cost of int4 with NO kernel/format change, so we can
// reject Q4 cheaply if it tanks quality before building the real Q4 pipeline.
var g_q4: bool = false;
var g_qmax: f32 = 7.0; // clamp level: 4bit→7, 5bit→15, 6bit→31 (env QBITS)
// AUDIO_CTX — whisper.cpp `audio_ctx` pattern (exp_n_audio_ctx; the stream
// example ships it as -ac): run the encoder + cross-attn on only the leading
// `actx` positions instead of the full zero-padded 1500. A live 10 s segment
// occupies 500 rows — the other 1000 are silence padding the 32-layer encoder
// grinds through for nothing (encoder cost is ~linear in rows; cross-KV
// re-read per decoded token shrinks the same way). env:
//   AUDIO_CTX unset/0 → off (full 1500, bit-exact legacy path)
//   AUDIO_CTX=auto    → fit to this window's audio (+64-frame margin, ×64 round)
//   AUDIO_CTX=N       → fixed clamp (whisper.cpp -ac N equivalent)
// Only single-slot encodes shrink (stream mode is always nb=1; the batched
// file path keeps ENC_SEQ — its slot stride is fixed).
var g_actx_auto: bool = false;
var g_actx_fixed: u32 = 0;
// DEC_INT4 — in-memory int4 decode weights (see repackQ4 / gemv_q4 kernels).
// 1 = decoder-block GEMVs only (~92 MB/tok → ½; logit head stays Q8 — Q4 noise
//     on the tied head can flip argmax, see keep_head note at tok_emb load).
// 2 = blocks + logit/emb head (~158 MB/tok → ½; the INT4-1 full-model curve).
var g_dec_int4: u8 = 0;
// T12 bidirectional language re-probe — LANG_CANDIDATES="50264,50266" (comma
// token ids). The session-wide language LOCK exists to stop per-segment
// flapping across 100 languages, but it makes a two-language conversation
// (KO staff ↔ JA/ZH patient) impossible: the later language decodes with the
// wrong seed token and collapses into transliteration. With a candidate
// whitelist the SOT probe (1-token forward, ~2-4 ms — cross-KV is built per
// chunk anyway) runs EVERY segment and picks the argmax among candidates
// only, so flapping is structurally limited to the session's language pair.
// Unset → legacy single-lock behavior, bit-exact.
var g_lang_cands: [4]u32 = undefined;
var g_lang_ncands: usize = 0;
fn audioCtx(got_samples: usize) u32 {
    if (g_actx_fixed > 0) return @max(192, @min(ENC_SEQ, (g_actx_fixed + 63) / 64 * 64));
    if (!g_actx_auto) return ENC_SEQ;
    const frames: u32 = @intCast(@min((got_samples + 319) / 320, ENC_SEQ));
    // Post-speech margin: audio that ends RIGHT at a speech boundary (VAD-cut
    // live segments, TTS fixtures) needs silent tail context or the decode
    // repeat-loops instead of emitting EOT. Measured on ko2 (768 audio frames):
    // +64 → phrase ×9, +128 → ×3, +160 → clean. 224 (4.48 s) carries margin.
    const padded: u32 = frames + 224;
    // Floor 576: very short clips need proportionally MORE tail — a 4.0 s JA
    // utterance repeated its last phrase at ctx 448/512 and cleaned up at 576
    // (t1 sweep, 2026-07-05). 576 keeps short-segment encodes at ~38% of full.
    return @max(576, @min(ENC_SEQ, (padded + 63) / 64 * 64));
}
// term biasing: <|startofprev|> + these tokens seed the decoder toward domain
// vocabulary (names, jargon). Encoded once from env PROMPT. g_bias_words holds
// the space-split prompt words for the seg event's bias_hits.
var g_prompt: []u32 = &.{};
var g_bias_words = std.ArrayList([]const u8).init(alloc);
const STARTOFPREV: u32 = 50362; // large-v3 special (sot 50258 · translate 50359 · transcribe 50360 · startoflm 50361 · startofprev 50362)
inline fn q4r(w: f32, blk_max: f32) f32 {
    if (!g_q4 or blk_max <= 0) return w;
    const s = blk_max / g_qmax;
    return std.math.clamp(@round(w / s), -g_qmax, g_qmax) * s;
}
const alloc = std.heap.page_allocator;

// FNV-1a over raw bytes / a Q8 weight (qs+scales) — for the WHASH bit-identity
// proof (Q8-file load == F16-quantize at the weight level).
fn fnvBytes(seed: u64, bytes: []const u8) u64 {
    var x = seed;
    for (bytes) |b| { x ^= b; x *%= 0x100000001b3; }
    return x;
}
fn fnvQ8(seed: u64, w: anytype, nq: usize, nsc: usize) u64 {
    var x = fnvBytes(seed, @as([*]const u8, @ptrCast(w.qs))[0..nq]);
    x = fnvBytes(x, @as([*]const u8, @ptrCast(w.scales))[0 .. nsc * 2]);
    return x;
}

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
    /// True if a tensor key is present in the header (no data read). Used to
    /// detect a pre-quantized Q8 model (K.qs present) vs an F16 model.
    fn has(self: Sf, key: []const u8) bool {
        var kbuf: [160]u8 = undefined;
        const q = std.fmt.bufPrint(&kbuf, "\"{s}\"", .{key}) catch return false;
        return std.mem.indexOf(u8, self.json, q) != null;
    }
    fn has2(self: Sf, key: []const u8, suffix: []const u8) bool {
        var kbuf: [180]u8 = undefined;
        const q = std.fmt.bufPrint(&kbuf, "\"{s}{s}\"", .{ key, suffix }) catch return false;
        return std.mem.indexOf(u8, self.json, q) != null;
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
    if (sf.has2(key, ".qs")) {
        const qs = try mtl.allocSlice(i8, rows * dim);
        const sc = try mtl.allocSlice(f16, rows * (dim / 32));
        try readQ8(sf, key, qs.ptr, sc.ptr, 0, 0, rows, dim);
        return .{ .qs = qs.ptr, .scales = sc.ptr };
    }
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
                const w = q4r(h2f(u16s[v * dim + b * 32 + i]), mx);
                const q = std.math.clamp(@round(w * inv), -127.0, 127.0);
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
                const w = q4r(h2f(u16s[o * in_ch + b * 32 + i]), mx);
                const q = std.math.clamp(@round(w * inv), -127.0, 127.0);
                qs[row * in_ch + b * 32 + i] = @intFromFloat(q);
            }
        }
    }
}
// Read a pre-quantized weight's qs(int8 [out][in]) + scales(f16 [out][in/32])
// straight into the dest buffers at element offsets. Copies qs out before
// reading scales (raw() aliases one shared scratch buffer). Used when the model
// file is the Q8 build (K.qs present) — bit-identical to in-load quantInto.
fn readQ8(sf: Sf, key: []const u8, qs: [*]i8, sc: [*]f16, q_off: usize, s_off: usize, out_ch: usize, in_ch: usize) !void {
    var kb: [180]u8 = undefined;
    const kq = std.fmt.bufPrint(&kb, "{s}.qs", .{key}) catch unreachable;
    const rq = sf.raw(kq) orelse return error.MissingTensor;
    const nq = out_ch * in_ch; // i8 bytes
    @memcpy(@as([*]u8, @ptrCast(qs + q_off))[0..nq], rq[0..nq]);
    const ksc = std.fmt.bufPrint(&kb, "{s}.scales", .{key}) catch unreachable;
    const rs = sf.raw(ksc) orelse return error.MissingTensor;
    const ns = out_ch * (in_ch / 32) * 2; // f16 bytes
    @memcpy(@as([*]u8, @ptrCast(sc + s_off))[0..ns], rs[0..ns]);
}

/// DEC_INT4: repack a loaded Q8 weight into packed int4 nibbles (levels ±7,
/// per-32 f16 scale — the INT4-1 measured quality curve; double-rounding
/// through Q8 is negligible, the Q8 grid is 36× finer than int4). Row layout
/// [rows][dim/2]: byte j = elements 2j (low nibble) | 2j+1 (high), signed.
/// Frees the Q8 buffers — decode GEMV weight traffic halves.
fn repackQ4(w: Q8, rows: usize, dim: usize) !Q8 {
    const nb = dim / 32;
    const p = try mtl.allocSlice(i8, rows * dim / 2);
    const sc = try mtl.allocSlice(f16, rows * nb);
    for (0..rows) |o| {
        for (0..nb) |b| {
            var mq: i32 = 0;
            for (0..32) |i| {
                const q: i32 = w.qs[o * dim + b * 32 + i];
                const a = if (q < 0) -q else q;
                if (a > mq) mq = a;
            }
            const s8: f32 = @floatCast(w.scales[o * nb + b]);
            const s4: f32 = if (mq > 0) s8 * @as(f32, @floatFromInt(mq)) / 7.0 else 1.0;
            sc[o * nb + b] = @floatCast(s4);
            const r = s8 / s4; // q4 = clamp(round(q8·s8/s4))
            var i: usize = 0;
            while (i < 32) : (i += 2) {
                const q0: i32 = @intFromFloat(std.math.clamp(@round(@as(f32, @floatFromInt(w.qs[o * dim + b * 32 + i])) * r), -7.0, 7.0));
                const q1: i32 = @intFromFloat(std.math.clamp(@round(@as(f32, @floatFromInt(w.qs[o * dim + b * 32 + i + 1])) * r), -7.0, 7.0));
                p[(o * dim + b * 32 + i) / 2] = @bitCast(@as(u8, @intCast(((q1 & 0xF) << 4) | (q0 & 0xF))));
            }
        }
    }
    mtl.free(w.qs);
    mtl.free(w.scales);
    return .{ .qs = p.ptr, .scales = sc.ptr };
}

fn upMatQ8(sf: Sf, key: []const u8, out_ch: usize, in_ch: usize) !enc.Q8 {
    if (sf.has2(key, ".qs")) {
        const qs = try mtl.allocSlice(i8, out_ch * in_ch);
        const sc = try mtl.allocSlice(f16, out_ch * (in_ch / 32));
        try readQ8(sf, key, qs.ptr, sc.ptr, 0, 0, out_ch, in_ch);
        return .{ .qs = qs.ptr, .scales = sc.ptr };
    }
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
        if (sf.has2(key, ".qs")) {
            try readQ8(sf, key, qs.ptr, sc.ptr, blk * @as(usize, D) * D, blk * @as(usize, D) * nb, D, D);
            continue;
        }
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
        if (sf.has2(key, ".qs")) {
            try readQ8(sf, key, qs.ptr, sc.ptr, blk * @as(usize, D) * D, blk * @as(usize, D) * nb, D, D);
            continue;
        }
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
// AUDIT: full wall-clock attribution (PROF=1) — [perf] only times GPU, which hid
// the mel CPU bottleneck. These accumulate every phase for a complete breakdown.
var g_t_mel: u64 = 0;
var g_t_conv: u64 = 0;
var g_t_enc: u64 = 0;
var g_t_ckv: u64 = 0;
var g_t_dec: u64 = 0;
var g_t_dtw: u64 = 0;
var g_t_diar: u64 = 0;
var g_words = std.ArrayList(Word).init(alloc);
var g_segs = std.ArrayList(SpkSeg).init(alloc);
var g_vad_iv = std.ArrayList([2]f32).init(alloc); // silero speech intervals (global s) — clips diar segments to speech
var g_osd_iv = std.ArrayList([2]f32).init(alloc); // pyannote OSD overlap intervals (global s) — 2nd-speaker emission
const OsdWin = struct { t: f32, nf: u32, cls: [600]u8, pov: [600]f32 }; // one 10s model window: argmax class + P(overlap) per frame
var g_osd_win = std.ArrayList(OsdWin).init(alloc);

// ── structured event stream (opt-in EVENTS_FILE) ─────────────────────────────
// A MACHINE contract emitted ALONGSIDE the frozen stdout text contract (the
// Swift parser + its unit tests stay byte-for-byte valid). One JSON object per
// line, each tagged with "t"; the stream is versioned by the leading
// {"t":"meta","v":1}. Web dashboard / future consumers tail this file. The
// authority is docs/EVENTS.md. Reserved fields (fallback/temp/bias_hits) are
// emitted as defaults now so downstream UI can bind to them before P1/P3 land —
// the data model is stable from day one (see ui-ux-scaffold-contract).
var g_ev: ?std.fs.File = null;
fn evOpen() void {
    if (std.posix.getenv("EVENTS_FILE")) |p| g_ev = std.fs.cwd().createFile(p, .{}) catch null;
}
fn evLine(s: []const u8) void {
    const f = g_ev orelse return;
    f.writeAll(s) catch {};
    f.writeAll("\n") catch {};
}
// JSON-escape a string value (incl. surrounding quotes). Raw UTF-8 ≥0x80 passes
// through unescaped — valid JSON — so Korean text stays human-readable.
fn evStr(wr: anytype, s: []const u8) !void {
    try wr.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try wr.writeAll("\\\""),
        '\\' => try wr.writeAll("\\\\"),
        '\n' => try wr.writeAll("\\n"),
        '\r' => try wr.writeAll("\\r"),
        '\t' => try wr.writeAll("\\t"),
        0...8, 11, 12, 14...31 => try wr.print("\\u{x:0>4}", .{c}),
        else => try wr.writeByte(c),
    };
    try wr.writeByte('"');
}
fn evMeta(model: []const u8, lang: u32, sr: u32) void {
    if (g_ev == null) return;
    var b: [512]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&b);
    const w = fbs.writer();
    w.writeAll("{\"t\":\"meta\",\"v\":1,\"model\":") catch return;
    evStr(w, model) catch return;
    w.print(",\"lang\":{d},\"sr\":{d}}}", .{ lang, sr }) catch return;
    evLine(fbs.getWritten());
}
fn evReady() void {
    evLine("{\"t\":\"ready\"}");
}
// streaming partial hypothesis: the in-progress text after each decode batch.
// Live consumers render it immediately and replace it when the final seg lands.
var g_partials = false;
// no_repeat_ngram: bans the token that would repeat an already-seen n-gram during
// decode (env NO_REPEAT_NGRAM). The in-decode ×3 single-token rule missed multi-
// token phrase loops ("A B A B"); this catches them BEFORE they stream to screen.
// n=3 (default) leaves genuine short repeats — backchannel "네 네", "very very" —
// untouched (they aren't 3-grams). 0 = off (kernel path bit-identical).
var g_no_repeat_ngram: u32 = 3;
fn evPartial(t0: f32, text: []const u8) void {
    if (g_ev == null) return;
    var b: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&b);
    const w = fbs.writer();
    w.print("{{\"t\":\"partial\",\"t0\":{d:.2},\"text\":", .{t0}) catch return;
    evStr(w, std.mem.trim(u8, text, " \n")) catch return;
    w.writeByte('}') catch return;
    evLine(fbs.getWritten());
}
fn evWord(t0: f32, t1: f32, text: []const u8, conf: f32, spk: i32) void {
    if (g_ev == null) return;
    var b: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&b);
    const w = fbs.writer();
    w.print("{{\"t\":\"word\",\"t0\":{d:.3},\"t1\":{d:.3},\"conf\":{d:.4},\"spk\":{d},\"text\":", .{ t0, t1, conf, spk }) catch return;
    evStr(w, std.mem.trim(u8, text, " ")) catch return;
    w.writeByte('}') catch return;
    evLine(fbs.getWritten());
}
fn evSeg(idx: u32, t0: f32, t1: f32, text: []const u8, tok_s: f32, enc_ms: f32, dec_ms: f32, passes: u32, dropped: bool, avg_lp: f32, fallback: []const u8) void {
    if (g_ev == null) return;
    var b: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&b);
    const w = fbs.writer();
    // avg_logprob + fallback now real (fallback: none/collapse/logprob); temp
    // stays reserved (only a stochastic temperature sweep would set it — deferred)
    w.print("{{\"t\":\"seg\",\"idx\":{d},\"t0\":{d:.2},\"t1\":{d:.2},\"dropped\":{},\"avg_logprob\":{d:.3},\"fallback\":\"{s}\",\"temp\":0.0,\"tok_s\":{d:.1},\"enc_ms\":{d:.0},\"dec_ms\":{d:.0},\"passes\":{d},\"text\":", .{ idx, t0, t1, dropped, avg_lp, fallback, tok_s, enc_ms, dec_ms, passes }) catch return;
    evStr(w, std.mem.trim(u8, text, " \n")) catch return;
    // bias_hits: which biasing terms actually surfaced in this segment's text
    if (g_bias_words.items.len > 0) {
        w.writeAll(",\"bias_hits\":[") catch return;
        var first = true;
        for (g_bias_words.items) |bw| {
            if (std.mem.indexOf(u8, text, bw) != null) {
                if (!first) w.writeByte(',') catch return;
                evStr(w, bw) catch return;
                first = false;
            }
        }
        w.writeByte(']') catch return;
    }
    w.writeByte('}') catch return;
    evLine(fbs.getWritten());
}
fn evSpeakerSeg(t: f32, spk: i32, text: []const u8) void {
    if (g_ev == null) return;
    var b: [8192]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&b);
    const w = fbs.writer();
    w.print("{{\"t\":\"spk_seg\",\"t0\":{d:.2},\"spk\":{d},\"text\":", .{ t, spk }) catch return;
    evStr(w, std.mem.trim(u8, text, " ")) catch return;
    w.writeByte('}') catch return;
    evLine(fbs.getWritten());
}
fn evDiar(speakers: usize, sil: f32, sep: f32, tau: f32, segs: usize) void {
    if (g_ev == null) return;
    var b: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&b);
    const w = fbs.writer();
    w.print("{{\"t\":\"diar\",\"speakers\":{d},\"silhouette\":{d:.3},\"sep\":{d:.3},\"tau\":{d:.2},\"segments\":{d}}}", .{ speakers, sil, sep, tau, segs }) catch return;
    evLine(fbs.getWritten());
}
fn evEnd(tag: []const u8) void {
    if (g_ev == null) return;
    var b: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&b);
    const w = fbs.writer();
    w.print("{{\"t\":\"{s}\"}}", .{tag}) catch return;
    evLine(fbs.getWritten());
}

fn keyL(buf: []u8, comptime fmt: []const u8, l: usize) []const u8 {
    return std.fmt.bufPrint(buf, fmt, .{l}) catch unreachable;
}

// ── in-process online speaker clustering (resident; folds in online_diar) ────
// A persistent centroid set kept in memory across stream segments, so the SAME
// voice keeps the SAME id for the whole session without an external process or
// state file. centroid direction = normalize(sum of L2-normalized embeddings).
const DiarCentroid = struct { count: u32, sum: [diar.EMB]f32 };
/// Online assignment result: the id AND the cosine MARGIN (best − second-best
/// similarity). The margin is the app's acoustic-confidence signal — a low
/// margin means "this window could be either speaker", which is exactly where
/// the LLM's dialogue-context correction is allowed to override (S2/S3 fusion).
const DiarAssign = struct { id: usize, fallback: usize, margin: f32 };

// Delay exposing a newly-born auto speaker until it has repeated acoustic
// evidence. Internally the raw id keeps learning; externally its first windows
// stay folded into the nearest existing visible speaker. On confirmation,
// repair those earlier windows through the already-shipped SPKFIX contract.
fn liveVisibleSpeaker(out: anytype, spk: usize, fallback: usize, count: u32, enabled: bool, confirm_win: usize, raw_ids: []const u8, visible_ids: []u8, pending: []bool, times: []const f32, margins: []const f32) !usize {
    if (!enabled or confirm_win <= 1) return spk;
    const need: u32 = @intCast(@min(confirm_win, std.math.maxInt(u32)));
    if (count < need) {
        // A fallback centroid may itself still be tentative. Resolve through
        // its most recent visible id so hidden prototype chains never leak.
        var visible_fallback = fallback;
        var i = raw_ids.len;
        while (i > 0) {
            i -= 1;
            if (raw_ids[i] == fallback) { visible_fallback = visible_ids[i]; break; }
        }
        return visible_fallback;
    }
    if (count == need) {
        for (raw_ids, 0..) |raw, i| {
            if (raw != spk or !pending[i]) continue;
            visible_ids[i] = @intCast(spk);
            pending[i] = false;
            try emitClippedSpk(out, "SPKFIX", times[i], @intCast(spk), margins[i]);
        }
    }
    return spk;
}

fn diarAssign(cents: *std.ArrayList(DiarCentroid), v: []f32, sim_thr: f32, max_k: u32, anchor_n: usize, anchor_sim: f32) !DiarAssign {
    var s: f64 = 0;
    for (v) |x| s += @as(f64, x) * x;
    const nrm: f32 = @floatCast(@sqrt(s) + 1e-9);
    for (v) |*x| x.* /= nrm; // unit-length
    var best: f32 = -2;
    var second: f32 = -2;
    var best_i: usize = 0;
    var second_i: usize = 0;
    for (cents.items, 0..) |*c, i| {
        var dot: f64 = 0;
        var cs: f64 = 0;
        for (0..diar.EMB) |k| {
            dot += @as(f64, v[k]) * c.sum[k];
            cs += @as(f64, c.sum[k]) * c.sum[k];
        }
        const sim: f32 = @floatCast(dot / (@sqrt(cs) + 1e-9));
        if (sim > best) { second = best; second_i = best_i; best = sim; best_i = i; } else if (sim > second) { second = sim; second_i = i; }
    }
    // 앵커 거절 폴백 (engine-diar-3a): best가 앵커인데 검증 문턱 미달이면,
    // 신규 출생 전에 두 번째 후보(비앵커, 일반 문턱 통과)를 먼저 취한다 —
    // 기존 화자 B의 창이 앵커에 살짝 더 가깝다는 이유로 B의 복제 id가
    // 태어나는 것을 방지.
    if (cents.items.len >= 2 and best_i < anchor_n and best < anchor_sim and
        second_i >= anchor_n and second >= sim_thr)
    {
        var c2 = &cents.items[second_i];
        for (0..diar.EMB) |k| c2.sum[k] += v[k];
        c2.count += 1;
        return .{ .id = second_i, .fallback = second_i, .margin = second - best };
    }
    // S1: an ANCHORED centroid (enrolled voiceprint, ids < anchor_n) demands a
    // HIGHER similarity to claim a window — "if it isn't clearly the enrolled
    // voice, it's someone else". Without this, a second voice merely CLOSE to
    // the anchor (best ≥ sim_thr) gets absorbed and never births its own id.
    const eff_thr: f32 = if (best_i < anchor_n) @max(sim_thr, anchor_sim) else sim_thr;
    if (cents.items.len == 0 or (best < eff_thr and cents.items.len < max_k)) {
        const spk = cents.items.len; // birth a new speaker
        var c: DiarCentroid = .{ .count = 1, .sum = undefined };
        for (0..diar.EMB) |k| c.sum[k] = v[k];
        try cents.append(c);
        return .{ .id = spk, .fallback = if (spk == 0) spk else best_i, .margin = 1.0 };
    }
    var c = &cents.items[best_i];
    for (0..diar.EMB) |k| c.sum[k] += v[k];
    c.count += 1;
    return .{ .id = best_i, .fallback = best_i, .margin = if (cents.items.len >= 2) best - second else 1.0 };
}

// Periodic live re-clustering: batch k-means + silhouette auto-K over the
// accumulated (unit-normalized) window embeddings, remapped onto the existing
// stable speaker ids by greedy best-cosine — transcript labels and voiceprint
// claims keep their ids. Fixes the online leader-follower's two measured
// failure modes (QUALITY_BENCH): over-splitting far-field voices (ES2004a
// K=8/38.3% DER) and merging similar clean voices (demo4 K=2/51.5%).
fn liveRecluster(cents: *std.ArrayList(DiarCentroid), emb: []const f32, ids: []const u8, max_k: u32, fixed_k: u32, kmin: usize, active: ?[]bool) !void {
    const segd = diar.EMB;
    var m = emb.len / segd;
    if (m < 8) return;
    // stride-subsample very long sessions (keeps k-means cost bounded)
    var X: []const f32 = emb;
    var I: []const u8 = ids;
    var sub: []f32 = &.{};
    var subi: []u8 = &.{};
    defer if (sub.len > 0) alloc.free(sub);
    defer if (subi.len > 0) alloc.free(subi);
    if (m > 4096) {
        const stride = (m + 4095) / 4096;
        const ms = (m + stride - 1) / stride;
        sub = try alloc.alloc(f32, ms * segd);
        subi = try alloc.alloc(u8, ms);
        var w: usize = 0;
        var i: usize = 0;
        while (i < m) : (i += stride) {
            @memcpy(sub[w * segd ..][0..segd], emb[i * segd ..][0..segd]);
            subi[w] = ids[i];
            w += 1;
        }
        X = sub[0 .. w * segd];
        I = subi[0..w];
        m = w;
    }
    // K: fixed via DIAR_K hint, else auto via simplified silhouette (same
    // scheme as the file-mode diarizer)
    const asg = try alloc.alloc(usize, m);
    defer alloc.free(asg);
    const tmp = try alloc.alloc(usize, m);
    defer alloc.free(tmp);
    var K: usize = undefined;
    if (fixed_k >= 1) {
        K = @min(@as(usize, fixed_k), m);
        try kmeansFit(X, m, segd, K, asg);
    } else {
        const kwin = envU("DIAR_KWIN", 8);
        const maxK: usize = @min(@min(@as(usize, max_k), m), @max(2, m / @max(kwin, 1))); // windows-per-speaker floor (see diarizeEmb)
        var bestK: usize = 2;
        var bestSil: f32 = -2;
        var kk: usize = 2;
        while (kk <= maxK) : (kk += 1) {
            try kmeansFit(X, m, segd, kk, tmp);
            const sil = try silhouetteSimplified(X, m, segd, tmp, kk);
            if (sil > bestSil) { bestSil = sil; bestK = kk; @memcpy(asg, tmp); }
        }
        K = bestK;
        if (bestSil < envF("DIAR_SIL_TAU", 0.35)) { K = 1; @memset(asg, 0); } // 0.35: see diarizeEmb
        // absolute-separation gate (same as file mode): a presenter whose voice
        // varies splits with high silhouette but close centroids → one speaker
        if (K >= 2 and maxCentroidCosDist(X, m, segd, asg, K) < envF("DIAR_MIN_SEP", 0.50)) { K = 1; @memset(asg, 0); }
        if (try maybePromoteSpherical4(X, m, segd, maxK, K, asg)) |promotion| {
            K = 4;
            bestSil = promotion.sil;
        }
        // voiceprint lower bound: every CLAIMED print is a speaker the session
        // has already voice-matched — auto-K may not merge below that count
        if (K < kmin) {
            K = @min(kmin, m);
            try kmeansFit(X, m, segd, K, asg);
        }
    }
    // cluster sums of unit embeddings (same scale as diarAssign's running sums)
    const sums = try alloc.alloc(f32, K * segd);
    defer alloc.free(sums);
    const cnts = try alloc.alloc(u32, K);
    defer alloc.free(cnts);
    @memset(sums, 0);
    @memset(cnts, 0);
    for (0..m) |i| {
        const k = asg[i];
        for (0..segd) |d| sums[k * segd + d] += X[i * segd + d];
        cnts[k] += 1;
    }
    // Remap clusters → stable ids by MAJORITY VOTE of each cluster's windows'
    // already-emitted ids (continuity with what the user has seen, so
    // --speakers "0=name" and voiceprint claims stay on the right voice).
    // Conflicts: the cluster with more votes keeps the id. Tiny clusters
    // (<3 windows) never mint new ids — they fold into assignment noise.
    const ns = cents.items.len;
    const new2stable = try alloc.alloc(isize, K);
    defer alloc.free(new2stable);
    @memset(new2stable, -1);
    const taken = try alloc.alloc(bool, ns);
    defer alloc.free(taken);
    @memset(taken, false);
    // votes[k][s] = #windows of cluster k previously labeled stable id s
    const votes = try alloc.alloc(u32, K * ns);
    defer alloc.free(votes);
    @memset(votes, 0);
    for (0..m) |i| {
        const s: usize = I[i];
        if (s < ns) votes[asg[i] * ns + s] += 1;
    }
    // resolve globally: repeatedly take the largest remaining (cluster, id) vote
    var round: usize = 0;
    while (round < @min(K, ns)) : (round += 1) {
        var best: u32 = 0;
        var bk: usize = 0;
        var bs: usize = 0;
        for (0..K) |k| {
            if (new2stable[k] >= 0) continue;
            for (0..ns) |s| {
                if (taken[s]) continue;
                if (votes[k * ns + s] > best) { best = votes[k * ns + s]; bk = k; bs = s; }
            }
        }
        if (best == 0) break;
        new2stable[bk] = @intCast(bs);
        taken[bs] = true;
    }
    // write back: matched ids get the recomputed centroid; unmatched clusters
    // mint a fresh id only if big enough. Stale ids keep their old centroid
    // (speaker may return; voiceprint claims stay valid).
    const min_sz: u32 = 3;
    for (0..K) |k| {
        if (cnts[k] == 0) continue;
        var sidx: usize = undefined;
        if (new2stable[k] >= 0) {
            sidx = @intCast(new2stable[k]);
        } else {
            // FIXED-K (화자 N명 고정): never mint a (N+1)th stable id — recluster
            // may only REMAP the accumulated windows onto the diar_k ids, else a
            // fixed 2명 session drifts to 3+ speakers over time.
            if (fixed_k >= 1) continue;
            if (cnts[k] < min_sz or cents.items.len >= 32) continue;
            try cents.append(.{ .count = 0, .sum = [_]f32{0} ** diar.EMB });
            sidx = cents.items.len - 1;
        }
        cents.items[sidx].count = cnts[k];
        @memcpy(cents.items[sidx].sum[0..], sums[k * segd ..][0..segd]);
        if (active) |a| { if (sidx < a.len) a[sidx] = true; }
    }
}

pub fn main() !void {
    const out = std.io.getStdOut().writer();
    evOpen(); // structured event stream (opt-in EVENTS_FILE) — frozen stdout text contract unaffected
    g_partials = std.posix.getenv("PARTIALS") != null; // streaming partial-hypothesis events (live)
    g_no_repeat_ngram = @intCast(envU("NO_REPEAT_NGRAM", 3)); // decode-time phrase-loop guard (0=off)
    g_q4 = !std.mem.eql(u8, std.posix.getenv("Q4") orelse "0", "0"); // int4 quality probe
    if (std.posix.getenv("AUDIO_CTX")) |ac| { // truncated encoder context (see audioCtx)
        if (std.mem.eql(u8, ac, "auto")) {
            g_actx_auto = true;
        } else {
            g_actx_fixed = std.fmt.parseInt(u32, ac, 10) catch 0;
        }
    }
    if (std.posix.getenv("DEC_INT4")) |v| g_dec_int4 = std.fmt.parseInt(u8, v, 10) catch 0;
    if (std.posix.getenv("LANG_CANDIDATES")) |lc| { // T12 per-segment language whitelist
        var lit = std.mem.splitScalar(u8, lc, ',');
        while (lit.next()) |tokstr| {
            if (g_lang_ncands >= g_lang_cands.len) break;
            const v = std.fmt.parseInt(u32, std.mem.trim(u8, tokstr, " "), 10) catch continue;
            if (v >= 50259 and v <= 50358) { g_lang_cands[g_lang_ncands] = v; g_lang_ncands += 1; }
        }
        if (g_lang_ncands == 1) g_lang_ncands = 0; // a single candidate is just a lock — use WHISPER_LANG_ID
    }
    if (std.posix.getenv("QBITS")) |b| { // 4/5/6-bit sweep: levels = 2^(b-1)-1
        const nbits = std.fmt.parseInt(u6, b, 10) catch 4;
        g_qmax = @floatFromInt((@as(u32, 1) << @as(u5, @intCast(nbits - 1))) - 1);
    }
    var args = try std.process.argsWithAllocator(alloc);
    _ = args.next();
    const model_path = args.next() orelse "assets/model.safetensors";
    const wav_path = args.next() orelse "assets/jfk.wav";
    const bpe_path = args.next() orelse "assets/WHISPER_BPE.bin";
    const rttm_out = args.next(); // optional 4th arg: write system RTTM here (DER scoring)
    const spk_arg = args.next(); // optional 5th arg: number of speakers (0/absent = 2)
    // term biasing: env PROMPT = space-separated domain vocabulary. Encoded once,
    // prepended as <|startofprev|> context so the decoder leans toward these
    // words (names, jargon). A leading space matches the BPE space convention.
    if (std.posix.getenv("PROMPT")) |p| {
        if (p.len > 0) {
            const spaced = std.fmt.allocPrint(alloc, " {s}", .{p}) catch p;
            g_prompt = bpeEncode(bpe_path, spaced) catch &.{};
            var it = std.mem.tokenizeScalar(u8, p, ' ');
            while (it.next()) |w| g_bias_words.append(w) catch {};
            try out.print("[prompt] biasing {d} word(s) → {d} tokens\n", .{ g_bias_words.items.len, g_prompt.len });
        }
    }
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
    const f_emb = try mtl.getFunction(if (g_dec_int4 >= 2) "gpu_emb_lookup_q4" else "gpu_emb_lookup_q8");
    // GPU-resident decode-loop kernels (sync-free replay; from the SHARE build)
    const f_emb_ind = try mtl.getFunction(if (g_dec_int4 >= 2) "emb_lookup_indirect_q4" else "emb_lookup_indirect_q8");
    const f_pe_ind = try mtl.getFunction("pos_embed_add_indirect");
    const f_step = try mtl.getFunction("step_advance");
    const f_argmax = try mtl.getFunction("argmax_conf"); // argmax + per-token confidence
    const f_filt_plain = try mtl.getFunction("logit_filter_indirect"); // no-ts greedy (default; best code-switch fidelity)
    const f_filt_ts = try mtl.getFunction("ts_rules_indirect"); // ts-token decode (collapse-rescue mode)
    const f_suppress = try mtl.getFunction("suppress_list");
    const f_logit = try mtl.getFunction(if (g_dec_int4 >= 2) "logit_gemv_q4" else "logit_gemv_q8");
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
    // Silero-VAD (sovereign CPU port) — trained speech/non-speech verdict.
    // Energy/relative-RMS cannot reject music (pqmho music RMS > close-mic
    // speech RMS) and <|nospeech|> is dead in large-v3-turbo; Silero is the
    // signal that separates (measured: pqmho 138s → 11.4s vs ref 14.9s).
    // Optional asset: absent → legacy energy-only behavior.
    var kb_d3: [256]u8 = undefined;
    const vad_path = std.fmt.bufPrint(&kb_d3, "{s}/silero_vad.bin", .{bpe_dir(bpe_path)}) catch unreachable;
    var vad_model: ?vad.Model = vad.Model.load(alloc, vad_path) catch null;
    if (vad_model == null) try out.print("[vad] silero_vad.bin not found — energy-only VAD\n", .{});
    // pyannote segmentation-3.0 (overlap detection) — opt-in OSD=1 while the
    // 2nd-speaker emission is validated; single-label diar's overlap miss
    // floor is 14.7% of ES2004a scored time (PERF_LOG O-1)
    var kb_d4: [256]u8 = undefined;
    const osd_path = std.fmt.bufPrint(&kb_d4, "{s}/pyannote_osd.bin", .{bpe_dir(bpe_path)}) catch unreachable;
    // default ON in file AND stream mode (OSD=0 disables). Live cost: ~90 ms
    // per 10 s window (Accelerate path), threaded over the diar embed pool —
    // measured ~5% of per-segment processing latency.
    const osd_on = !std.mem.eql(u8, std.posix.getenv("OSD") orelse "1", "0");
    const osd_model: ?osd.Model = if (osd_on) osd.Model.load(alloc, osd_path) catch null else null;
    if (osd_on and osd_model == null) try out.print("[osd] pyannote_osd.bin not found — overlap emission off\n", .{});
    const c1w = try upConvWF16(sf, "model.encoder.conv1.weight", D, mel.N_MELS, 3);
    const c1b = try upVec(sf, "model.encoder.conv1.bias");
    const c2w = try upConvWF16(sf, "model.encoder.conv2.weight", D, D, 3);
    const c2b = try upVec(sf, "model.encoder.conv2.bias");
    const enc_pe = try upVec(sf, "model.encoder.embed_positions.weight"); // [1500][D]
    // Batched encoder width: run up to enc_batch 30s chunks through ONE forward,
    // amortizing weight reads + JIT dequant across chunks (MPS is ~5% cheaper
    // per row at M=3000+ and the 68ms/chunk dequant divides by the batch).
    // ENC_BATCH env overrides; default 4 in file mode, 1 in STREAM mode (live
    // segments are single-chunk — keeps the resident RSS unchanged).
    const enc_batch: u32 = blk: {
        if (std.posix.getenv("ENC_BATCH")) |s| {
            const v = std.fmt.parseInt(u32, s, 10) catch 1;
            break :blk @max(1, @min(8, v));
        }
        break :blk if (std.posix.getenv("STREAM") != null) 1 else 4;
    };
    const EB: usize = enc_batch;
    const conv1o = (try mtl.allocSlice(f32, D * mel.N_FRAMES)).ptr; // [D][3000] F32
    const col1 = (try mtl.allocSlice(f16, mel.N_FRAMES * (mel.N_MELS * 3))).ptr;
    const t1 = (try mtl.allocSlice(f16, mel.N_FRAMES * D)).ptr;
    const col2 = (try mtl.allocSlice(f16, ENC_SEQ * (D * 3))).ptr;
    const t2 = (try mtl.allocSlice(f16, ENC_SEQ * D)).ptr;
    const d_ex = (try mtl.allocSlice(f32, EB * ENC_SEQ * D)).ptr;
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
    if (std.posix.getenv("ENC_F16_CACHE") != null) {
        var cache_timer = try std.time.Timer.start();
        try enc.cacheWeights(Ke, &elayers);
        try out.print("[5c] encoder F16 cache ready ({d:.0} ms, ~1.25 GB)\n", .{
            @as(f64, @floatFromInt(cache_timer.read())) / 1e6,
        });
    }

    // ── encoder scratch (F16 activations, reused per chunk) ─────────
    const escr = enc.Scratch{
        .x_ln = (try mtl.allocSlice(f16, EB * ENC_SEQ * D)).ptr,
        // +64 rows: m4_flash_enc 64-row tail tiles read past the last batch's
        // row 1500 (masked/dropped, but the bytes must exist)
        .qkv = (try mtl.allocSlice(f16, (3 * EB * ENC_SEQ + 64) * D)).ptr,
        .ao = (try mtl.allocSlice(f16, EB * ENC_SEQ * D)).ptr,
        .mo = (try mtl.allocSlice(f16, EB * ENC_SEQ * D)).ptr,
        .mh = (try mtl.allocSlice(f16, EB * ENC_SEQ * MLP)).ptr,
        .wdq = (try mtl.allocSlice(f16, MLP * D)).ptr, // weight tile — batch-independent
        .wdq2 = (try mtl.allocSlice(f16, MLP * D)).ptr,
    };
    const out_f16 = (try mtl.allocSlice(f16, EB * ENC_SEQ * D)).ptr;
    const enc_out = (try mtl.allocSlice(f32, EB * ENC_SEQ * D)).ptr;

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
    // Q4_K_M-style mixed precision: keep the tied embed/output head at Q8 (it
    // directly produces logits → Q4 noise flips argmax). Q4KEEPHEAD=1 probes this.
    const keep_head = g_q4 and !std.mem.eql(u8, std.posix.getenv("Q4KEEPHEAD") orelse "0", "0");
    if (keep_head) g_q4 = false;
    var tok_emb = try upVecQ8(sf, "model.decoder.embed_tokens.weight", VOCAB, D); // Q8_0 (DEC_INT4=2: repacked below)
    // WHASH=1: prove the Q8-file load is bit-identical to F16-quantize at the
    // WEIGHT level (transcripts are nondeterministic via GPU FP, so the proof
    // must be on weights). Covers all 4 Q8 loaders: upVecQ8(tok_emb,ow),
    // upQKVQ8(dec qkv), upMatQ8(enc o_w), upQKVQ8enc(enc qkv).
    if (std.posix.getenv("WHASH") != null) {
        const nb = @as(usize, D) / 32;
        var x: u64 = 0xcbf29ce484222325;
        x = fnvQ8(x, tok_emb, VOCAB * D, VOCAB * nb);
        x = fnvQ8(x, dlayers[0].qkvw, 3 * @as(usize, D) * D, 3 * @as(usize, D) * nb);
        x = fnvQ8(x, dlayers[0].ow, @as(usize, D) * D, @as(usize, D) * nb);
        x = fnvQ8(x, elayers[0].o_w, @as(usize, D) * D, @as(usize, D) * nb);
        x = fnvQ8(x, elayers[0].qkv_w, 3 * @as(usize, D) * D, 3 * @as(usize, D) * nb);
        std.debug.print("[whash] {x}\n", .{x});
    }
    if (keep_head) g_q4 = true;
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
        .ca_sc = (try mtl.allocSlice(f32, dec.NH * ENC_SEQ)).ptr, // 20×1500 normalized scores
        .ca_part = (try mtl.allocSlice(f32, dec.NH * dec.CA_NSPLIT * (2 + dec.HDD))).ptr, // split-attn partials (42 KB)
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
    const d_conf = (try mtl.allocSlice(f32, MAX_TOK)).ptr; // per-token softmax confidence (unified)
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
    const head_base = [dec.NL]u32{ 0, 0, 0, 2 }; // plane offset per layer (cumulative align heads)
    const inv_n: f32 = 1.0 / 6.0;
    // Per-head alignment planes [NALIGN][MAX_TOK][ENC_SEQ] — kept separate so
    // wordTimestamps can z-normalize each head BEFORE averaging (OpenAI timing
    // semantics; normalizing the averaged matrix is NOT equivalent — verified).
    const NALIGN: usize = 6;
    const d_ca = try mtl.allocSlice(f32, NALIGN * MAX_TOK * ENC_SEQ);
    @memset(d_ca, 0);

    // ── BATCHDEC (P5 multichunk decode) — M1 shadow: gated BATCHDEC=1 (default
    // off). Decodes the encoder batch's nb chunks BATCHED, alongside the per-slot
    // path (which still produces the real output), to verify text-equivalence +
    // measure decode speed in-engine. Productionized (replace + word-ts) in M2/M3.
    const batchdec = std.posix.getenv("BATCHDEC") != null;
    const MAXB: usize = 8;
    var bb_x: [*]f32 = undefined;
    var bb_x16: [*]f16 = undefined;
    var bb_l16: [*]f16 = undefined;
    var bb_tokens: []u32 = &.{};
    var bb_logits: [*]f32 = undefined;
    var bb_pos: [*]u32 = undefined;
    var bb_skc: [MAXB][dec.NL][*]f32 = undefined;
    var bb_svc: [MAXB][dec.NL][*]f32 = undefined;
    var bb_ckc: [dec.NL][*]f16 = undefined;
    var bb_cvc: [dec.NL][*]f16 = undefined;
    var bb_wf: [dec.NL]dec.WF16 = undefined;
    var bb_temb: [*]f16 = undefined;
    var bb_scr: dec.BScratch = undefined;
    if (batchdec) {
        bb_x = (try mtl.allocSlice(f32, MAXB * D)).ptr;
        bb_x16 = (try mtl.allocSlice(f16, MAXB * D)).ptr;
        bb_l16 = (try mtl.allocSlice(f16, MAXB * VOCAB)).ptr;
        bb_tokens = try mtl.allocSlice(u32, MAXB * MAX_TOK);
        bb_logits = (try mtl.allocSlice(f32, MAXB * VOCAB)).ptr;
        bb_pos = (try mtl.allocSlice(u32, 1)).ptr; // shared (all slots lockstep)
        for (0..MAXB) |b| for (0..dec.NL) |l| {
            bb_skc[b][l] = (try mtl.allocSlice(f32, MAX_TOK * D)).ptr;
            bb_svc[b][l] = (try mtl.allocSlice(f32, MAX_TOK * D)).ptr;
        };
        for (0..dec.NL) |l| {
            bb_ckc[l] = (try mtl.allocSlice(f16, MAXB * ENC_SEQ * D)).ptr;
            bb_cvc[l] = (try mtl.allocSlice(f16, MAXB * ENC_SEQ * D)).ptr;
            bb_wf[l] = .{
                .qkvw = (try mtl.allocSlice(f16, 3 * @as(usize, D) * D)).ptr, .ow = (try mtl.allocSlice(f16, @as(usize, D) * D)).ptr,
                .cqw = (try mtl.allocSlice(f16, @as(usize, D) * D)).ptr, .cow = (try mtl.allocSlice(f16, @as(usize, D) * D)).ptr,
                .m0w = (try mtl.allocSlice(f16, @as(usize, D) * MLP)).ptr, .m2w = (try mtl.allocSlice(f16, @as(usize, MLP) * D)).ptr,
            };
        }
        bb_temb = (try mtl.allocSlice(f16, @as(usize, D) * VOCAB)).ptr;
        bb_scr = .{
            .xb = (try mtl.allocSlice(f32, MAXB * D)).ptr, .qkv = (try mtl.allocSlice(f32, MAXB * 3 * D)).ptr,
            .ao = (try mtl.allocSlice(f32, MAXB * D)).ptr, .mo = (try mtl.allocSlice(f32, MAXB * D)).ptr,
            .mh = (try mtl.allocSlice(f32, MAXB * MLP)).ptr, .ca_sc = (try mtl.allocSlice(f32, dec.NH * ENC_SEQ)).ptr,
            .in16 = (try mtl.allocSlice(f16, MAXB * MLP)).ptr, .out16 = (try mtl.allocSlice(f16, MAXB * MLP)).ptr,
        };
        // static-weight deq → WF16 + tok_emb f16, ONCE (amortized over all tokens)
        const q8 = struct { fn w(x: dec.Q8w) enc.Q8 { return .{ .qs = x.qs, .scales = x.scales }; } }.w;
        try mtl.beginCommandBuffer();
        for (0..dec.NL) |l| {
            try deqW16(f_deq, bb_wf[l].qkvw, q8(dlayers[l].qkvw), 3 * D, D);
            try deqW16(f_deq, bb_wf[l].ow, q8(dlayers[l].ow), D, D);
            try deqW16(f_deq, bb_wf[l].cqw, q8(dlayers[l].cqw), D, D);
            try deqW16(f_deq, bb_wf[l].cow, q8(dlayers[l].cow), D, D);
            try deqW16(f_deq, bb_wf[l].m0w, q8(dlayers[l].m0w), MLP, D);
            try deqW16(f_deq, bb_wf[l].m2w, q8(dlayers[l].m2w), D, MLP);
        }
        try deqW16(f_deq, bb_temb, q8(tok_emb), VOCAB, D); // [VOCAB][D] → [D][VOCAB] f16
        try mtl.commitCommandBuffer();
        try mtl.sync();
    }

    // ── DEC_INT4: repack decode GEMV weights to in-memory int4 ───────────────
    // AFTER the WHASH hash (defined on Q8) and the batchdec WF16 dequant (its
    // source is the Q8 buffers). Level 1 = decoder blocks (~92 MB/tok → ½);
    // level 2 also repacks the tied embed/logit head (+66 MB → ½ — the Q4-
    // flips-argmax risk documented at the tok_emb load, so it's a probe level).
    // Decode is GEMV-bandwidth-bound (FUSE-2) — bytes, not launches, move it.
    if (g_dec_int4 >= 1) {
        var rq = try std.time.Timer.start();
        for (0..dec.NL) |l| {
            dlayers[l].qkvw = try repackQ4(dlayers[l].qkvw, 3 * @as(usize, D), D);
            dlayers[l].ow = try repackQ4(dlayers[l].ow, D, D);
            dlayers[l].cqw = try repackQ4(dlayers[l].cqw, D, D);
            dlayers[l].cow = try repackQ4(dlayers[l].cow, D, D);
            dlayers[l].m0w = try repackQ4(dlayers[l].m0w, MLP, D);
            dlayers[l].m2w = try repackQ4(dlayers[l].m2w, D, MLP);
        }
        if (g_dec_int4 >= 2) tok_emb = try repackQ4(tok_emb, VOCAB, D);
        try out.print("[dec-int4] level {d} repack ({d} ms) — decode GEMV bytes ½\n", .{ g_dec_int4, rq.read() / 1_000_000 });
    }

    // ── resident buffers + state (allocated ONCE; reused across stream jobs) ──
    const samples = try alloc.alloc(f32, mel.CHUNK_SAMPLES);
    // per-slot 1 ms-hop energy envelope (word-boundary snapping) — `samples`
    // is overwritten while gathering the encoder batch, so keep one per slot
    const ENV_LEN: usize = mel.CHUNK_SAMPLES / 16 + 1;
    const slot_env = try alloc.alloc(f32, 8 * ENV_LEN);
    // raw chunk audio per slot — the timestamp-seek re-encode needs it after
    // `samples` has been overwritten while gathering the rest of the batch
    const slot_samp = try alloc.alloc(f32, 8 * mel.CHUNK_SAMPLES);
    const vad_probs = try alloc.alloc(f32, mel.CHUNK_SAMPLES / vad.N_WINDOW + 2); // silero per-32ms speech probs (per chunk)
    const OSD_STEP: usize = osd.WIN_SAMPLES; // disjoint 10 s windows (5 s sliding measured ≈ no gain: 17.05 vs 17.12)
    const OSD_NW: usize = mel.CHUNK_SAMPLES / OSD_STEP; // up to 6 windows per 30 s chunk
    const osd_logp = try alloc.alloc(f32, OSD_NW * 600 * osd.N_CLASSES);
    const osd_nf = try alloc.alloc(usize, OSD_NW);
    var full = std.ArrayList(u8).init(alloc);
    const SEG_SAMP: usize = 24000; // 1.5 s @ 16 kHz
    const SEG_SEC: f32 = 1.5;
    const SEGD: usize = diar.EMB; // 256
    var diar_emb = std.ArrayList(f32).init(alloc); // n × 256
    var diar_bm = std.ArrayList(f32).init(alloc); // per-window RMS (for VAD)
    var diar_t0 = std.ArrayList(f32).init(alloc);
    var diar_pf = std.ArrayList(f32).init(alloc); // per-window raw silero frame probs (offline VAD sweep, VAD_DUMP)
    var diar_n: usize = 0;
    // diar threading: 1 sgemm thread per worker (avoid Accelerate oversubscription)
    _ = setenv("VECLIB_MAXIMUM_THREADS", "1", 1);
    const diar_nthreads: usize = @min(std.Thread.getCpuCount() catch 4, 16);
    const max_win: usize = mel.CHUNK_SAMPLES / SEG_SAMP; // 20
    const cemb = try alloc.alloc(f32, max_win * diar.EMB);
    const crms = try alloc.alloc(f32, max_win);
    // language token for the SEED: env WHISPER_LANG_ID overrides; else 0 = auto.
    // Detected ONCE (on the first speech segment) and reused for the rest of the
    // session — in stream mode this also kills per-segment language flapping.
    var lang_tok: u32 = blk: {
        if (std.posix.getenv("WHISPER_LANG_ID")) |s| break :blk std.fmt.parseInt(u32, s, 10) catch 0;
        break :blk 0;
    };
    // task token: <|transcribe|>=50360 (default) or <|translate|>=50359 (X→English,
    // Whisper-native). TRANSLATE=1 → on-device live translation; source language
    // is still detected/forced via lang_tok, only the OUTPUT becomes English.
    const translate = !std.mem.eql(u8, std.posix.getenv("TRANSLATE") orelse "0", "0");
    const task_tok: u32 = if (translate) 50359 else 50360;

    // ── stream mode: load model ONCE, then process segment wavs from stdin ────
    // Each stdin line is "<global_offset_seconds> <wav_path>"; we emit that
    // segment's WORD TIMESTAMPS / TRANSCRIPTION (with global offset) and a
    // "<<SEG_END>>" sentinel, then wait for the next line. No model reload.
    const stream = std.posix.getenv("STREAM") != null;
    // resident in-process diarization (stream only): cluster 1.5 s windows online
    // into a persistent centroid set → consistent speaker ids, no external proc.
    var cents = std.ArrayList(DiarCentroid).init(alloc);
    const diar_sim = envF("DIAR_SIM", 0.40);
    const diar_max: u32 = @intCast(envU("DIAR_MAXK", 8));
    // periodic live re-clustering: every N accepted windows, re-run batch
    // k-means over all accumulated embeddings (DIAR_RECLUSTER=0 disables).
    const recluster_every: usize = envU("DIAR_RECLUSTER", 16);
    // Auto live birth lock: the first recluster runs early (8 windows) to fix
    // obvious bad ids, but locking speaker births that early collapses 3-4
    // speaker panel audio into K=2. Keep births open until the session has enough
    // accepted windows to have likely seen every participant.
    const birth_lock_win: usize = envU("DIAR_BIRTH_LOCK_WIN", 64);
    var live_emb = std.ArrayList(f32).init(alloc); // accepted windows, unit-normalized
    var live_ids = std.ArrayList(u8).init(alloc); // each window's visible stable/fallback id
    var live_raw_ids = std.ArrayList(u8).init(alloc); // internal pre-confirmation id
    var live_pending = std.ArrayList(bool).init(alloc); // visible id still folded into fallback
    var live_margins = std.ArrayList(f32).init(alloc); // original acoustic margin
    var live_t0 = std.ArrayList(f32).init(alloc); // each window's global time (for SPKFIX)
    var live_since: usize = 0;
    var recl_done = false; // after the first recluster, k-means owns K (no online births)
    const stream_diar = stream and !std.mem.eql(u8, std.posix.getenv("DIAR") orelse "1", "0");
    // ── voiceprint enrollment (stream only): VOICEPRINTS=<dir> of <name>.vec
    // files (256×f32, unit-normalized on load). When a session speaker's centroid
    // stabilizes and matches an enrolled print (cosine ≥ VP_SIM), emit
    // "SPKNAME <id> <name>" once — the live runner renames the speaker. At
    // session end the final centroids are dumped to <dir>/.last/spk<id>.vec so
    // the runner can enroll user-named speakers for the NEXT session.
    const vp_dir: ?[]const u8 = if (stream) std.posix.getenv("VOICEPRINTS") else null;
    const vp_sim = envF("VP_SIM", 0.40);
    var vp_names = std.ArrayList([]u8).init(alloc);
    var vp_vecs = std.ArrayList([]f32).init(alloc);
    var vp_claimed = std.ArrayList(bool).init(alloc);
    var spk_named = std.ArrayList(bool).init(alloc); // session speaker already announced
    if (vp_dir) |vd| {
        if (std.fs.cwd().openDir(vd, .{ .iterate = true })) |dh| {
            var d = dh;
            defer d.close();
            var it = d.iterate();
            while (it.next() catch null) |e| {
                if (e.kind != .file or !std.mem.endsWith(u8, e.name, ".vec")) continue;
                const data = d.readFileAlloc(alloc, e.name, 4096) catch continue;
                defer alloc.free(data);
                if (data.len != diar.EMB * 4) continue;
                const vec = try alloc.alloc(f32, diar.EMB);
                @memcpy(std.mem.sliceAsBytes(vec), data[0 .. diar.EMB * 4]);
                var ss: f32 = 0;
                for (vec) |x| ss += x * x;
                const inv = 1.0 / (@sqrt(ss) + 1e-9);
                for (vec) |*x| x.* *= inv;
                try vp_vecs.append(vec);
                try vp_names.append(try alloc.dupe(u8, e.name[0 .. e.name.len - 4]));
                try vp_claimed.append(false);
            }
            try out.print("[stream] {d} voiceprint(s) loaded from {s}\n", .{ vp_vecs.items.len, vd });
        } else |_| {}
    }
    // S1: ANCHOR mode (DIAR_ANCHOR=1) — seed the centroid set from the enrolled
    // voiceprints BEFORE any audio, so a known voice (clinic staff) is matched
    // against a fixed reference instead of being re-discovered by clustering.
    // "Who is speaking" becomes verification, not estimation: the anchored id
    // exists from t=0, is claimed (name announced immediately), and counts into
    // the recluster K lower bound so auto-K can never merge it away.
    var n_anchor: usize = 0;
    if (std.posix.getenv("DIAR_ANCHOR") != null and vp_vecs.items.len > 0) {
        const aw: f32 = @floatFromInt(envU("DIAR_ANCHOR_W", 4));
        for (vp_vecs.items, 0..) |v, vi| {
            var c: DiarCentroid = .{ .count = @intFromFloat(aw), .sum = undefined };
            for (0..diar.EMB) |k| c.sum[k] = v[k] * aw; // scaled: direction unchanged, weight = aw windows
            try cents.append(c);
            vp_claimed.items[vi] = true;
            try spk_named.append(true);
            try out.print("SPKNAME {d} {s}\n", .{ vi, vp_names.items[vi] });
        }
        n_anchor = vp_vecs.items.len;
        try out.print("[stream] {d} anchored voiceprint speaker(s)\n", .{n_anchor});
    }
    // hallucination guard: Whisper invents words ("Oh my", "Okay okay") in near-
    // silent / ambient stretches. Drop a segment's text when the loudest 1 s
    // window is below HALLU_RMS — a *strong* utterance (shouting "아아아") has
    // high RMS and is always kept. Off with HALLU_GUARD=0.
    const hallu_guard = !std.mem.eql(u8, std.posix.getenv("HALLU_GUARD") orelse "1", "0");
    const hallu_rms = envF("HALLU_RMS", 0.020);
    const vad_thresh = envF("VAD_THRESH", 0.010);
    // Silero trained-VAD speech-probability threshold (was hardcoded 0.5).
    // Exposed for per-language / per-speaker-count tuning: KO conversational and
    // far-field multi-speaker audio want different operating points than the
    // whisper.cpp default. neg (hysteresis exit) defaults to prob−0.15.
    const vad_prob = envF("VAD_PROB", 0.5);
    const vad_neg = envF("VAD_NEG", vad_prob - 0.15);
    _ = vad_neg; // (segment-state-machine neg lives in vad_silero.zig; kept for symmetry/diag)
    // gate-only AGC: low-gain sources (quiet mic, far speaker; FLEURS masters at
    // −33 dBFS) were silently dropped by BOTH speech gates (energy RMS and
    // Silero STFT magnitudes too small → product goes totally silent). Normalize
    // a scratch copy to a target peak for the gates/detectors ONLY. AGC=0 reverts.
    const agc_on = !std.mem.eql(u8, std.posix.getenv("AGC") orelse "1", "0");
    evMeta("whisper-large-v3-turbo-q8", lang_tok, mel.SAMPLE_RATE); // structured contract header (both modes)
    if (stream) { evReady(); try out.print("[stream] ready (model resident; feed '<offset> <wav>' lines on stdin)\n", .{}); }
    var stdin_buf: [8192]u8 = undefined;
    const stdin_r = std.io.getStdIn().reader();

    job: while (true) {
        // ── obtain the next job (wav path + global time offset) ──────────────
        var cur_path: []const u8 = wav_path;
        var g_off: f32 = 0;
        if (stream) {
            const line = (stdin_r.readUntilDelimiterOrEof(&stdin_buf, '\n') catch null) orelse break :job;
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue :job;
            // session-end relabel handshake: re-cluster over the WHOLE session,
            // re-assign every accumulated window to the final centroids, and
            // emit corrected labels so the runner can rewrite .md/.srt with
            // file-mode-quality speakers (the console stays streaming).
            if (std.mem.eql(u8, trimmed, "FLUSH")) {
                const mwin = live_emb.items.len / diar.EMB;
                if (mwin >= 8 and cents.items.len > 0) {
                    var nclaim: usize = 0;
                    for (vp_claimed.items, 0..) |c, ci| {
                        if (!c) continue;
                        // 부재 앵커는 K 하한에서 제외 — 등록만 되고 발화가 없는
                        // 프린트가 kmin을 부풀리면 k-means가 강제 과분할된다
                        // (역검증 engine-diar-0). 앵커는 시드 가중(aw)보다 실제
                        // 윈도가 쌓였을 때만 센다.
                        if (ci < n_anchor) {
                            const aw_seed: u32 = @intCast(envU("DIAR_ANCHOR_W", 4));
                            if (ci >= cents.items.len or cents.items[ci].count <= aw_seed) continue;
                        }
                        nclaim += 1;
                    }
                    const final_active = try alloc.alloc(bool, 64);
                    defer alloc.free(final_active);
                    @memset(final_active, false);
                    try liveRecluster(&cents, live_emb.items, live_raw_ids.items, diar_max, diar_k, nclaim, final_active);
                    if (n_anchor > 0) {
                        const awf: f32 = @floatFromInt(envU("DIAR_ANCHOR_W", 4));
                        for (0..@min(n_anchor, cents.items.len)) |vi| {
                            for (0..diar.EMB) |kf| cents.items[vi].sum[kf] += vp_vecs.items[vi][kf] * awf;
                        }
                    }
                    // normalized centroid directions. Prefer ids that the final
                    // whole-session recluster actually touched; if auto-K collapses
                    // a panel to K<3, fall back to robust online-birthed ids.
                    const final_min_win = envU("DIAR_FINAL_MIN_WIN", 3);
                    const final_min_active = envU("DIAR_FINAL_MIN_ACTIVE", 3);
                    const final_ids = try alloc.alloc(usize, cents.items.len); defer alloc.free(final_ids);
                    const broad_ids = try alloc.alloc(usize, cents.items.len); defer alloc.free(broad_ids);
                    var nc: usize = 0;
                    var nbroad: usize = 0;
                    for (cents.items, 0..) |*c, sidx| {
                        if (sidx >= n_anchor and c.count < final_min_win) continue;
                        broad_ids[nbroad] = sidx; nbroad += 1;
                        if (sidx < final_active.len and final_active[sidx]) { final_ids[nc] = sidx; nc += 1; }
                    }
                    if (diar_k == 0 and n_anchor == 0 and nc < final_min_active and nbroad >= final_min_active) {
                        @memcpy(final_ids[0..nbroad], broad_ids[0..nbroad]);
                        nc = nbroad;
                    }
                    if (nc == 0) {
                        for (cents.items, 0..) |*c, sidx| {
                            if (c.count == 0) continue;
                            final_ids[nc] = sidx; nc += 1;
                        }
                    }
                    const dirs = try alloc.alloc(f32, nc * diar.EMB);
                    defer alloc.free(dirs);
                    for (final_ids[0..nc], 0..) |sidx, j| {
                        const c = &cents.items[sidx];
                        var ss: f32 = 0;
                        for (c.sum) |x| ss += x * x;
                        const inv = 1.0 / (@sqrt(ss) + 1e-9);
                        for (0..diar.EMB) |d| dirs[j * diar.EMB + d] = c.sum[d] * inv;
                    }
                    const fix_ids = try alloc.alloc(i32, mwin);
                    defer alloc.free(fix_ids);
                    // FIXED-K live Unknown: with online births + recluster capped at
                    // diar_k (born_cap + write-back block), the N centroids are the N
                    // fixed speakers; a window whose best cosine to ALL of them is
                    // below DIAR_UNK_THR matches none → single Unknown bucket (only if
                    // >= DIAR_UNK_MIN such windows, mirroring file mode).
                    const live_do_unk = diar_k >= 1 and !std.mem.eql(u8, std.posix.getenv("DIAR_UNK") orelse "1", "0");
                    const live_unk_thr = envF("DIAR_UNK_THR", 0.35);
                    const live_unk_min = envU("DIAR_UNK_MIN", 3);
                    const wbest = try alloc.alloc(f32, mwin); defer alloc.free(wbest);
                    const wmar = try alloc.alloc(f32, mwin); defer alloc.free(wmar);
                    var n_unk: usize = 0;
                    for (0..mwin) |i| {
                        const v = live_emb.items[i * diar.EMB ..][0 .. diar.EMB];
                        var best: f32 = -2;
                        var second: f32 = -2;
                        var bs: usize = 0;
                        for (0..nc) |sidx| {
                            var dt: f32 = 0;
                            for (0..diar.EMB) |d| dt += v[d] * dirs[sidx * diar.EMB + d];
                            if (dt > best) { second = best; best = dt; bs = sidx; } else if (dt > second) second = dt;
                        }
                        fix_ids[i] = @intCast(final_ids[bs]);
                        wbest[i] = best;
                        wmar[i] = if (nc >= 2) best - second else 1.0;
                        if (live_do_unk and best < live_unk_thr) n_unk += 1;
                    }
                    const emit_unk = live_do_unk and n_unk >= live_unk_min;
                    for (0..mwin) |i| {
                        if (emit_unk and wbest[i] < live_unk_thr) fix_ids[i] = DIAR_UNK_ID;
                        try emitClippedSpk(out, "SPKFIX", live_t0.items[i], @intCast(fix_ids[i]), wmar[i]);
                    }
                    // overlap rows for the saved transcript: same local-track
                    // identity as diarizeEmb, against the RELABELED windows
                    try emitOsdOverlap(out, live_t0.items[0..mwin], fix_ids);
                }
                evEnd("flush_end");
                try out.print("<<FLUSH_END>>\n", .{});
                continue :job;
            }
            const sp = std.mem.indexOfScalar(u8, trimmed, ' ') orelse continue :job;
            g_off = std.fmt.parseFloat(f32, trimmed[0..sp]) catch 0;
            cur_path = std.mem.trim(u8, trimmed[sp + 1 ..], " \t\r");
        }

        var checked_stream_path: ?[]u8 = null;
        if (stream) {
            checked_stream_path = validateStreamWavPath(alloc, cur_path) catch |e| {
                std.debug.print("[skip] rejected stream path '{s}': {s}\n", .{ cur_path, @errorName(e) });
                try out.print("=== TRANSCRIPTION (0.00s, 0 chunk(s)) ===\n", .{});
                evEnd("seg_end");
                try out.print("<<SEG_END>>\n", .{});
                continue :job;
            };
            cur_path = checked_stream_path.?;
        }
        defer if (checked_stream_path) |p| alloc.free(p);

        const wav = try std.fs.cwd().readFileAlloc(alloc, cur_path, 2 * 1024 * 1024 * 1024);
        defer alloc.free(wav);
        const total = mel.wavTotalSamples(wav);
        // W-3: fail loudly instead of crashing on empty / unsupported audio.
        // 0 samples used to reach Silero/mel and SIGSEGV; an unsupported codec
        // (non-PCM16/float32) used to decode as silence with no signal.
        if (total == 0) {
            const why: []const u8 = if (wav.len < 44)
                "empty or truncated WAV file"
            else if (mel.wavFmt(wav).fmt == .unsupported)
                "unsupported WAV format (need PCM16 or float32 mono/stereo)"
            else
                "no audio data (0 samples)";
            std.debug.print("[skip] {s}: {s}\n", .{ cur_path, why });
            if (stream) {
                try out.print("=== TRANSCRIPTION (0.00s, 0 chunk(s)) ===\n", .{});
                evEnd("seg_end");
                try out.print("<<SEG_END>>\n", .{});
                continue :job;
            }
            return;
        }
        const n_chunks: usize = if (total <= mel.CHUNK_SAMPLES) 1 else (total + mel.CHUNK_SAMPLES - 1) / mel.CHUNK_SAMPLES;
        if (!stream) try out.print("[8] audio: {d} samples ({d:.1}s) → {d} chunk(s) × 30s\n", .{ total, @as(f64, @floatFromInt(total)) / 16000.0, n_chunks });
        full.clearRetainingCapacity();
        var timer = try std.time.Timer.start();
        var chunk: usize = 0;
        var reached_end = false;
        while (chunk < n_chunks and !reached_end) {
            // ── Phase A: gather up to enc_batch speech chunks (mel→conv → d_ex slots)
            var nb: u32 = 0;
            var slot_toff: [8]f32 = undefined;
            var slot_rms: [8]f32 = undefined;
            var slot_chunk: [8]usize = undefined;
            var slot_conv: [8]f64 = undefined;
            var slot_got: [8]usize = undefined;
            var slot_nenv: [8]usize = undefined;
            gather: while (chunk < n_chunks and nb < enc_batch) {
            const got = mel.loadWavChunk(wav, chunk * mel.CHUNK_SAMPLES, samples);
            if (chunk > 0 and got == 0) { reached_end = true; break :gather; }
            const t_off: f32 = g_off + @as(f32, @floatFromInt(chunk)) * 30.0;

            // Silero speech mask for this chunk (32 ms frames). Drives both
            // gates below: diar windows without ≥0.25 s of speech get their
            // RMS zeroed (the existing relative-RMS VAD then drops them on
            // every path — file timeline/RTTM, live SPK, FLUSH relabel), and
            // a chunk with <0.25 s of speech total skips encode/decode.
            var vad_np: usize = 0;
            var chunk_speech_s: f32 = 1e9; // no model → everything passes
            var vad_thread: ?std.Thread = null;
            var osd_threads: [4]?std.Thread = .{ null, null, null, null };
            var osd_nw_used: usize = 0;
            // ── AGC ───────────────────────────────────────────────────────
            // Quiet sources (quiet mic, far speaker, low-gain masters) make BOTH
            // the speech gates AND the encoder fail — gates read silence, and the
            // encoder emits empty/degraded text even on MODERATELY quiet audio
            // (peak 0.11–0.23 FLEURS utts came out empty until boosted). When a
            // chunk is below the normal-speech floor, normalize it toward a target
            // peak (−1 dBFS — the level that gave FLEURS CER 3.99%) IN PLACE so
            // gates AND encoder both see a healthy level. Normal/loud audio
            // (peak ≥ ACTIVATE) is untouched → bit-exact. AGC=0 reverts.
            const AGC_ACTIVATE: f32 = 0.30;
            const AGC_TARGET: f32 = 0.90;
            const AGC_GAIN_MAX: f32 = 40.0;
            if (agc_on) {
                var pk: f32 = 0;
                for (samples[0..got]) |x| {
                    const a = @abs(x);
                    if (a > pk) pk = a;
                }
                if (pk > 1e-6 and pk < AGC_ACTIVATE) {
                    const g = @min(AGC_GAIN_MAX, AGC_TARGET / pk);
                    for (samples[0..got]) |*x| x.* *= g;
                }
            }
            const gate_samples: []f32 = samples[0..got];
            if (osd_model) |*om| {
                // pyannote OSD on 10 s windows, threaded (≈410 ms each naive;
                // overlaps the diar embed pool + silero below)
                @memset(osd_nf, 0);
                var wi: usize = 0;
                while (wi * OSD_STEP < got and wi < OSD_NW) : (wi += 1) {
                    const s0 = wi * OSD_STEP;
                    const slen = @min(osd.WIN_SAMPLES, got - s0);
                    osd_threads[wi % 4] = try std.Thread.spawn(.{}, osdWorker, .{ om, gate_samples[s0 .. s0 + slen], osd_logp[wi * 600 * osd.N_CLASSES ..][0 .. 600 * osd.N_CLASSES], &osd_nf[wi] });
                    if (wi % 4 == 3) { // cap concurrency at 4 OSD threads
                        for (0..4) |q| {
                            if (osd_threads[q]) |t_| {
                                t_.join();
                                osd_threads[q] = null;
                            }
                        }
                    }
                    if (slen < osd.WIN_SAMPLES) { wi += 1; break; }
                }
                osd_nw_used = wi;
            }
            if (vad_model) |*vm| {
                // run Silero on its own thread — it overlaps the ResNet diar
                // embedding pool below (~150 ms each on a 30 s chunk), so the
                // trained VAD costs ~0 wall time on the gather path
                vad_thread = try std.Thread.spawn(.{}, vadWorker, .{ vm, gate_samples, vad_probs, &vad_np });
            }

            // diarization: 256-d ResNet34 embedding per 1.5 s window. Non-stream
            // accumulates for end-of-file k-means; stream mode clusters online
            // (resident centroids) and emits "SPK <gtime> <id>" right away.
            if (!stream or stream_diar) {
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
                if (vad_thread) |vt| {
                    vt.join();
                    vad_thread = null;
                    chunk_speech_s = 0;
                    for (vad_probs[0..vad_np]) |pv| {
                        if (pv >= vad_prob) chunk_speech_s += 0.032;
                    }
                    { // speech intervals: file-mode RTTM clipping AND live SPK/SPKFIX clipping
                        var iv = try vad.segmentsFromProbsP(alloc, vad_probs[0..vad_np], @intCast(envU("VAD_MIN_SPEECH_MS", 60)), @intCast(envU("VAD_PAD_MS", 200)));
                        defer iv.deinit();
                        for (iv.items) |sg| try g_vad_iv.append(.{ t_off + sg.start, t_off + sg.end });
                    }
                }
                for (0..osd_nw_used) |wi| {
                    if (osd_threads[wi]) |t_| {
                        t_.join();
                        osd_threads[wi] = null;
                    }
                }
                if (osd_nw_used > 0) {
                    // store each model window's per-frame argmax class and
                    // P(overlap): the powerset class names the LOCAL PAIR
                    // ({0,1}/{0,2}/{1,2}) — diarizeEmb maps locals to global
                    // speakers via their SOLO frames (the turn-taking-prior
                    // identity was the limiter: ~85% right, DER stuck ~17.1)
                    for (0..osd_nw_used) |wi| {
                        const lp = osd_logp[wi * 600 * osd.N_CLASSES ..];
                        var w: OsdWin = undefined;
                        w.t = t_off + @as(f32, @floatFromInt(wi * OSD_STEP)) / 16000.0;
                        w.nf = @intCast(@min(osd_nf[wi], 600));
                        for (0..w.nf) |fi| {
                            var best: usize = 0;
                            var pov: f32 = 0;
                            for (0..osd.N_CLASSES) |c| {
                                if (lp[fi * osd.N_CLASSES + c] > lp[fi * osd.N_CLASSES + best]) best = c;
                                if (c >= 4) pov += @exp(lp[fi * osd.N_CLASSES + c]);
                            }
                            w.cls[fi] = @intCast(best);
                            w.pov[fi] = pov;
                        }
                        try g_osd_win.append(w);
                    }
                }
                if (vad_np > 0) {
                    // silero is AUTHORITATIVE for window selection: binarize
                    // crms to {0,1} so the downstream relative-RMS gates
                    // degenerate to keep-iff-speech. The RMS gate dropped
                    // QUIET SPEECH windows (mevkw: 23.4% miss vs 0.9%
                    // silero floor — the loss was ours, not the model's).
                    const sp_gate = envF("DIAR_VAD_SP", 0.15);
                    for (0..nwin) |wsg| {
                        const f0 = wsg * SEG_SAMP / vad.N_WINDOW; // 1.5 s window → 32 ms frames
                        const f1 = @min(f0 + SEG_SAMP / vad.N_WINDOW, vad_np);
                        var sp_s: f32 = 0;
                        for (vad_probs[f0..f1]) |pv| {
                            if (pv >= vad_prob) sp_s += 0.032;
                        }
                        crms[wsg] = if (sp_s >= sp_gate) 1.0 else 0.0;
                    }
                }
                if (stream_diar) {
                    // per-segment relative-energy VAD: keep windows RMS > 0.3×median
                    var rtmp: [64]f32 = undefined;
                    const m = @min(nwin, rtmp.len);
                    for (0..m) |w| rtmp[w] = crms[w];
                    std.mem.sort(f32, rtmp[0..m], {}, std.sort.asc(f32));
                    const thr = rtmp[m / 2] * 0.3;
                    for (0..nwin) |wsg| {
                        if (crms[wsg] < thr) continue;
                        const gt = t_off + @as(f32, @floatFromInt(wsg)) * SEG_SEC;
                        // once re-clustering owns K, suppress online births
                        // (new speakers enter via the next k-means auto-K bump)
                        // 앵커 모드: recl_done 후에도 출생 허용 — 봉쇄하면 늦게
                        // 등장한 앵커-근접 화자가 앵커에 흡수·명명된다 (engine-diar-1)
                        // FIXED-K: cap online births at the fixed count (+ enrolled
                        // anchors, which hold slots but still need room for the N
                        // conversational speakers), so a 2명 session never shows 8
                        // transient speakers before the first recluster.
                        const born_cap: u32 = if (diar_k >= 1) @max(diar_k, @as(u32, @intCast(n_anchor))) else diar_max;
                        const seen_before = live_emb.items.len / diar.EMB;
                        const auto_birth_locked = diar_k == 0 and recl_done and n_anchor == 0 and seen_before >= birth_lock_win;
                        const eff_max: u32 = if (auto_birth_locked) @intCast(cents.items.len) else born_cap;
                        const ar = try diarAssign(&cents, cemb[wsg * diar.EMB ..][0 .. diar.EMB], diar_sim, eff_max, n_anchor, envF("DIAR_ANCHOR_SIM", 0.70));
                        const spk = ar.id;
                        const visible_spk = try liveVisibleSpeaker(
                            out,
                            spk,
                            ar.fallback,
                            cents.items[spk].count,
                            recluster_every > 0 and diar_k == 0 and n_anchor == 0,
                            envU("DIAR_CONFIRM_WIN", 2),
                            live_raw_ids.items,
                            live_ids.items,
                            live_pending.items,
                            live_t0.items,
                            live_margins.items,
                        );
                        // far-field silence inside the 1.5 s grid window was
                        // the live FA driver (live 44.7% vs file 18.8%) —
                        // emit silero-clipped pieces; extra duration field is
                        // ignored by the runner's awk (backward compatible)
                        try emitClippedSpk(out, "SPK", gt, @intCast(visible_spk), ar.margin);
                        // voiceprint match: once a speaker's centroid has ≥2
                        // windows, compare to unclaimed prints; announce once.
                        while (spk_named.items.len < cents.items.len) try spk_named.append(false);
                        if (vp_vecs.items.len > 0 and !spk_named.items[spk] and cents.items[spk].count >= 2) {
                            var cnorm: [diar.EMB]f32 = undefined;
                            var css: f32 = 0;
                            for (cents.items[spk].sum) |x| css += x * x;
                            const cinv = 1.0 / (@sqrt(css) + 1e-9);
                            for (0..diar.EMB) |ci| cnorm[ci] = cents.items[spk].sum[ci] * cinv;
                            var best: f32 = -1;
                            var bidx: usize = 0;
                            for (vp_vecs.items, 0..) |v, vi| {
                                if (vp_claimed.items[vi]) continue;
                                var dt: f32 = 0;
                                for (0..diar.EMB) |ci| dt += v[ci] * cnorm[ci];
                                if (dt > best) { best = dt; bidx = vi; }
                            }
                            if (best >= vp_sim) {
                                vp_claimed.items[bidx] = true;
                                spk_named.items[spk] = true;
                                try out.print("SPKNAME {d} {s}\n", .{ spk, vp_names.items[bidx] });
                            }
                        }
                        // accumulate (diarAssign left this window unit-normalized)
                        // and periodically re-cluster the whole session.
                        if (recluster_every > 0) {
                            try live_emb.appendSlice(cemb[wsg * diar.EMB ..][0 .. diar.EMB]);
                            try live_ids.append(@intCast(@min(visible_spk, 255)));
                            try live_raw_ids.append(@intCast(@min(spk, 255)));
                            try live_pending.append(visible_spk != spk);
                            try live_margins.append(ar.margin);
                            try live_t0.append(gt);
                            live_since += 1;
                            const acc_total = live_emb.items.len / diar.EMB;
                            // first recluster early (8 windows) so short sessions
                            // benefit too; thereafter every recluster_every windows
                            if ((!recl_done and acc_total >= 8) or live_since >= recluster_every) {
                                live_since = 0;
                                var nclaim: usize = 0;
                                for (vp_claimed.items, 0..) |c, ci| {
                                    if (!c) continue;
                                    if (ci < n_anchor) { // 부재 앵커 제외 (engine-diar-0)
                                        const aw_seed: u32 = @intCast(envU("DIAR_ANCHOR_W", 4));
                                        if (ci >= cents.items.len or cents.items[ci].count <= aw_seed) continue;
                                    }
                                    nclaim += 1;
                                }
                                const livefix_active = try alloc.alloc(bool, 64);
                                defer alloc.free(livefix_active);
                                @memset(livefix_active, false);
                                try liveRecluster(&cents, live_emb.items, live_raw_ids.items, diar_max, diar_k, nclaim, livefix_active);
                                recl_done = true;
                                // S1: re-inject anchor directions after recluster so the
                                // enrolled reference never washes out of its centroid.
                                if (n_anchor > 0) {
                                    const aw2: f32 = @floatFromInt(envU("DIAR_ANCHOR_W", 4));
                                    for (0..@min(n_anchor, cents.items.len)) |vi| {
                                        for (0..diar.EMB) |k2| cents.items[vi].sum[k2] += vp_vecs.items[vi][k2] * aw2;
                                    }
                                    // 유령 흡수 (engine-diar-3b): 채널 미스매치로
                                    // 태어난 등록자 본인의 중복 id를 앵커로 회수
                                    const gsim = envF("DIAR_ANCHOR_SIM", 0.70);
                                    for (n_anchor..cents.items.len) |gi| {
                                        for (0..n_anchor) |vi2| {
                                            var gd: f32 = 0;
                                            var gc: f32 = 0;
                                            for (0..diar.EMB) |gk| { gd += cents.items[gi].sum[gk] * vp_vecs.items[vi2][gk]; gc += cents.items[gi].sum[gk] * cents.items[gi].sum[gk]; }
                                            const gs2 = gd / (@sqrt(gc) + 1e-9);
                                            if (gs2 >= gsim) {
                                                for (0..diar.EMB) |gk| { cents.items[vi2].sum[gk] += cents.items[gi].sum[gk]; cents.items[gi].sum[gk] = 0; }
                                                cents.items[vi2].count += cents.items[gi].count;
                                                cents.items[gi].count = 0;
                                                break;
                                            }
                                        }
                                    }
                                }
                                // S4: re-emit corrected labels for PAST windows so the
                                // app fixes earlier lines DURING the session, not only at
                                // FLUSH. Changed labels only (bounded output). DIAR_LIVEFIX=0
                                // disables.
                                if (!std.mem.eql(u8, std.posix.getenv("DIAR_LIVEFIX") orelse "1", "0")) {
                                    const livefix_min_win = envU("DIAR_LIVEFIX_MIN_WIN", 3);
                                    const livefix_min_active = envU("DIAR_LIVEFIX_MIN_ACTIVE", 3);
                                    const livefix_ids = try alloc.alloc(usize, cents.items.len); defer alloc.free(livefix_ids);
                                    const livefix_broad_ids = try alloc.alloc(usize, cents.items.len); defer alloc.free(livefix_broad_ids);
                                    var ncl: usize = 0;
                                    var nbroad_livefix: usize = 0;
                                    for (cents.items, 0..) |*c, sidx| {
                                        if (sidx >= n_anchor and c.count < livefix_min_win) continue;
                                        livefix_broad_ids[nbroad_livefix] = sidx; nbroad_livefix += 1;
                                        if (sidx < livefix_active.len and livefix_active[sidx]) { livefix_ids[ncl] = sidx; ncl += 1; }
                                    }
                                    if (diar_k == 0 and n_anchor == 0 and ncl < livefix_min_active and nbroad_livefix >= livefix_min_active) {
                                        @memcpy(livefix_ids[0..nbroad_livefix], livefix_broad_ids[0..nbroad_livefix]);
                                        ncl = nbroad_livefix;
                                    }
                                    if (ncl > 0) {
                                        const dirsl = try alloc.alloc(f32, ncl * diar.EMB);
                                        defer alloc.free(dirsl);
                                        for (livefix_ids[0..ncl], 0..) |sidx, j| {
                                            const c = &cents.items[sidx];
                                            var ss2: f32 = 0;
                                            for (c.sum) |x| ss2 += x * x;
                                            const inv2 = 1.0 / (@sqrt(ss2) + 1e-9);
                                            for (0..diar.EMB) |dd| dirsl[j * diar.EMB + dd] = c.sum[dd] * inv2;
                                        }
                                        for (0..acc_total) |wi| {
                                            const v = live_emb.items[wi * diar.EMB ..][0..diar.EMB];
                                            var b1: f32 = -2;
                                            var b2: f32 = -2;
                                            var bs: usize = 0;
                                            for (0..ncl) |sidx| {
                                                var dt: f32 = 0;
                                                for (0..diar.EMB) |dd| dt += v[dd] * dirsl[sidx * diar.EMB + dd];
                                                if (dt > b1) { b2 = b1; b1 = dt; bs = sidx; } else if (dt > b2) b2 = dt;
                                            }
                                            const stable_bs = livefix_ids[bs];
                                            live_raw_ids.items[wi] = @intCast(@min(stable_bs, 255));
                                            live_pending.items[wi] = false;
                                            if (stable_bs != live_ids.items[wi]) {
                                                live_ids.items[wi] = @intCast(@min(stable_bs, 255));
                                                try emitClippedSpk(out, "SPKFIX", live_t0.items[wi], @intCast(stable_bs), if (ncl >= 2) b1 - b2 else 1.0);
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                } else {
                    const FPW = SEG_SAMP / vad.N_WINDOW; // silero frames per 1.5 s window
                    for (0..nwin) |wsg| {
                        try diar_emb.appendSlice(cemb[wsg * diar.EMB ..][0 .. diar.EMB]);
                        try diar_bm.append(crms[wsg]);
                        try diar_t0.append(t_off + @as(f32, @floatFromInt(wsg)) * SEG_SEC);
                        // raw per-frame silero probs for this window (offline VAD-threshold
                        // sweep): reproduces the f0 indexing of the binarization loop above.
                        const pf0 = wsg * SEG_SAMP / vad.N_WINDOW;
                        for (0..FPW) |fi| {
                            const idx = pf0 + fi;
                            try diar_pf.append(if (idx < vad_np) vad_probs[idx] else 0.0);
                        }
                        diar_n += 1;
                    }
                }
            }
        }

        if (vad_thread) |vt| { // diar block skipped (no-diar stream) — join here
            vt.join();
            vad_thread = null;
            chunk_speech_s = 0;
            for (vad_probs[0..vad_np]) |pv| {
                if (pv >= vad_prob) chunk_speech_s += 0.032;
            }
        }
        // DIAR_ONLY=1: diarization-only run (DER benches) — diar windows +
        // silero intervals are complete at this point; whisper encode/decode
        // contributes nothing to the RTTM. ~20× faster VoxConverse sweeps.
        if (std.posix.getenv("DIAR_ONLY") != null) {
            if (got < mel.CHUNK_SAMPLES) { reached_end = true; chunk += 1; break :gather; }
            chunk += 1;
            continue :gather;
        }
        // VAD: skip silent chunks entirely (no mel/encode/decode) — avoids the
        // silence-hallucination junk and saves compute on quiet meeting stretches.
        const seg_rms = maxWinRms(gate_samples, got); // loudest 1 s window, [-1,1] RMS (AGC-normalized)
        if (seg_rms <= vad_thresh or chunk_speech_s < 0.25) {
            if (n_chunks > 1) try out.print("\n[chunk {d}/{d} @ {d:.0}s] ({s} — skipped)\n", .{ chunk + 1, n_chunks, t_off, if (seg_rms <= vad_thresh) @as([]const u8, "silence") else "non-speech" });
            if (got < mel.CHUNK_SAMPLES) { reached_end = true; chunk += 1; break :gather; }
            chunk += 1;
            continue :gather;
        }

        // front-end: mel → Conv1D×2 → enc_input (into this chunk's batch slot)
        var mt = try std.time.Timer.start();
        mel.melSpectrogram(samples, mel_filters, mel_buf);
        g_t_mel += mt.read();
        var ct = try std.time.Timer.start();
        try mtl.beginCommandBuffer();
        try imIm2col(f_im2col, col1, mel_buf.ptr, mel.N_MELS, mel.N_FRAMES, 1, 1, mel.N_FRAMES);
        try mtl.matmulF16Batched(col1, c1w, t1, mel.N_FRAMES, D, mel.N_MELS * 3);
        try geluTranspose(f_geluT, conv1o, t1, c1b, mel.N_FRAMES, D);
        try imIm2col(f_im2col, col2, conv1o, D, mel.N_FRAMES, 2, 1, ENC_SEQ);
        try mtl.matmulF16Batched(col2, c2w, t2, ENC_SEQ, D, D * 3);
        try geluPos(f_geluPos, d_ex + @as(usize, nb) * ENC_SEQ * D, t2, c2b, enc_pe, ENC_SEQ * D, D);
        try mtl.commitCommandBuffer();
        try mtl.sync();
        const conv_ns_t = ct.read();
        g_t_conv += conv_ns_t;
        slot_conv[nb] = @as(f64, @floatFromInt(conv_ns_t)) / 1e6;
        slot_nenv[nb] = energyEnvelope(samples[0..got], slot_env[@as(usize, nb) * ENV_LEN ..][0..ENV_LEN]);
        @memcpy(slot_samp[@as(usize, nb) * mel.CHUNK_SAMPLES ..][0..got], samples[0..got]);
        slot_got[nb] = got;
        slot_toff[nb] = t_off;
        slot_rms[nb] = seg_rms;
        slot_chunk[nb] = chunk;
        nb += 1;
        if (got < mel.CHUNK_SAMPLES) { reached_end = true; chunk += 1; break :gather; }
        chunk += 1;
        } // gather
        if (nb == 0) break;

        // ── Phase B: ONE batched encoder forward (weights + dequant amortized ×nb)
        // Single-slot windows (stream mode is always nb=1) shrink to the audio's
        // own rows under AUDIO_CTX; batched slots keep the fixed ENC_SEQ stride.
        var actx: u32 = if (nb == 1) audioCtx(slot_got[0]) else ENC_SEQ;
        var et = try std.time.Timer.start();
        try enc.forward(Ke, &elayers, elnp_w, elnp_b, d_ex, out_f16, enc_out, escr, nb, actx);
        const enc_ns_t = et.read();
        g_t_enc += enc_ns_t;
        const enc_ms = @as(f64, @floatFromInt(enc_ns_t)) / 1e6 / @as(f64, @floatFromInt(nb));

        // ── BATCHDEC M1 shadow: decode all nb chunks BATCHED (verify text + speed)
        // alongside the per-slot path. Plain no-ts; lang must be known. Gated off.
        if (batchdec and lang_tok != 0 and nb >= 1) {
            const B: u32 = @intCast(nb);
            var sht = try std.time.Timer.start();
            // cross-KV → contiguous [B][ENC_SEQ][D] per layer (per-slot enc_out)
            for (0..B) |b| {
                const eo16b = out_f16 + b * @as(usize, ENC_SEQ) * D;
                try mtl.beginCommandBuffer();
                for (0..dec.NL) |l| {
                    try deqW16(f_deq, cross_wdq, ckw[l], D, D);
                    try mtl.matmulF16Batched(eo16b, cross_wdq, bb_ckc[l] + b * @as(usize, ENC_SEQ) * D, ENC_SEQ, D, D);
                    try deqW16(f_deq, cross_wdq, cvw[l], D, D);
                    try mtl.matmulF16Batched(eo16b, cross_wdq, bb_cvc[l] + b * @as(usize, ENC_SEQ) * D, ENC_SEQ, D, D);
                    try biasAdd16(f_bias16, bb_cvc[l] + b * @as(usize, ENC_SEQ) * D, cvb[l], ENC_SEQ * D, D);
                }
                try mtl.commitCommandBuffer();
                try mtl.sync();
            }
            // seed: sot|lang|task|notimestamps per slot; zero self-KV
            const PLb: u32 = 4;
            for (0..B) |b| {
                const t = bb_tokens.ptr + b * MAX_TOK;
                t[0] = SEED[0]; t[1] = lang_tok; t[2] = task_tok; t[3] = 50364;
                for (0..dec.NL) |l| { @memset(bb_skc[b][l][0 .. MAX_TOK * D], 0); @memset(bb_svc[b][l][0 .. MAX_TOK * D], 0); }
            }
            var sk: [8][*]f32 = undefined;
            var sv: [8][*]f32 = undefined;
            var pp: [8][*]u32 = undefined;
            for (0..B) |b| pp[b] = bb_pos;
            // seed phase: fill KV for positions 0..PLb-2 (no prediction)
            bb_pos[0] = 0;
            for (0..PLb - 1) |_| {
                try mtl.beginCommandBuffer();
                for (0..B) |b| {
                    try kEmbInd(f_emb_ind, bb_x + b * @as(usize, D), tok_emb.qs, tok_emb.scales, bb_tokens.ptr + b * MAX_TOK, bb_pos);
                    try kPeInd(f_pe_ind, bb_x + b * @as(usize, D), dec_pe, bb_pos);
                }
                for (0..dec.NL) |l| {
                    for (0..B) |b| { sk[b] = bb_skc[b][l]; sv[b] = bb_svc[b][l]; }
                    try dec.decodeBlockBatched(Kd, dlayers[l], bb_wf[l], B, bb_x, bb_scr, sk[0..B], sv[0..B], bb_ckc[l], bb_cvc[l], pp[0..B]);
                }
                try kStep(f_step, bb_pos);
                try mtl.commitCommandBuffer();
                try mtl.sync();
            }
            // predict loop (DBATCH/cb for fair speed; ragged EOT per slot)
            bb_pos[0] = PLb - 1;
            var bb_done = [_]bool{false} ** 8;
            var bb_ntext = [_]u32{0} ** 8;
            const bb_maxgen: u32 = MAX_TOK - PLb - 1;
            var gen: u32 = 0;
            var bb_total: u32 = 0;
            while (gen < bb_maxgen) {
                const this_b: u32 = @min(@as(u32, 8), bb_maxgen - gen);
                try mtl.beginCommandBuffer();
                for (0..this_b) |_| {
                    for (0..B) |b| {
                        try kEmbInd(f_emb_ind, bb_x + b * @as(usize, D), tok_emb.qs, tok_emb.scales, bb_tokens.ptr + b * MAX_TOK, bb_pos);
                        try kPeInd(f_pe_ind, bb_x + b * @as(usize, D), dec_pe, bb_pos);
                    }
                    for (0..dec.NL) |l| {
                        for (0..B) |b| { sk[b] = bb_skc[b][l]; sv[b] = bb_svc[b][l]; }
                        try dec.decodeBlockBatched(Kd, dlayers[l], bb_wf[l], B, bb_x, bb_scr, sk[0..B], sv[0..B], bb_ckc[l], bb_cvc[l], pp[0..B]);
                    }
                    try dec.kLN(Kd, bb_x, bb_scr.xb, dln_w, dln_b, D, B);
                    try dec.kCvt32(Kd, bb_x16, bb_scr.xb, B * D);
                    try mtl.matmulF16Batched(bb_x16, bb_temb, bb_l16, B, VOCAB, D);
                    try dec.kCvt16(Kd, bb_logits, bb_l16, B * VOCAB);
                    for (0..B) |b| {
                        try kSuppress(f_suppress, bb_logits + b * @as(usize, VOCAB), d_suppress.ptr, n_suppress);
                        try kFilt(f_filt_plain, bb_logits + b * @as(usize, VOCAB), bb_tokens.ptr + b * MAX_TOK, bb_pos, PLb, g_no_repeat_ngram);
                    }
                    try kStep(f_step, bb_pos);
                    for (0..B) |b| try kArgmaxConf(f_argmax, bb_logits + b * @as(usize, VOCAB), bb_tokens.ptr + b * MAX_TOK, d_conf, bb_pos, MAX_TOK);
                }
                try mtl.commitCommandBuffer();
                try mtl.sync();
                // EOT scan over the this_b new tokens (indices PLb+gen .. +this_b)
                var all_done = true;
                for (0..this_b) |j| {
                    const idx = PLb + gen + @as(u32, @intCast(j));
                    for (0..B) |b| {
                        if (bb_done[b]) continue;
                        if (bb_tokens[b * MAX_TOK + idx] == EOT) bb_done[b] = true else { bb_ntext[b] += 1; bb_total += 1; }
                    }
                }
                for (0..B) |b| { if (!bb_done[b]) all_done = false; }
                gen += this_b;
                if (all_done) break;
            }
            const sh_ms = @as(f64, @floatFromInt(sht.read())) / 1e6;
            try out.print("[batchdec] B={d}: {d} tok {d:.0}ms ({d:.0} tok/s, incl cross-KV+seed)\n", .{ B, bb_total, sh_ms, @as(f64, @floatFromInt(bb_total)) / (sh_ms / 1000.0) });
            for (0..B) |b| {
                const txt = bpeDecode(bpe_path, bb_tokens[b * MAX_TOK + PLb .. b * MAX_TOK + PLb + bb_ntext[b]]) catch "";
                try out.print("[batchdec] slot {d} ({d}tok): {s}\n", .{ b, bb_ntext[b], txt[0..@min(txt.len, 70)] });
            }
        }

        // ── Phase C: per-slot cross-KV + decode + timestamps (chronological order)
        for (0..nb) |slot| {
        const t_off = slot_toff[slot];
        const seg_rms2 = slot_rms[slot];
        const conv_ms = slot_conv[slot];
        const cchunk = slot_chunk[slot];
        const cgot = slot_got[slot];
        const eo16 = out_f16 + slot * @as(usize, ENC_SEQ) * D;
        // cross-KV rows follow the (possibly AUDIO_CTX-shrunk) encoder rows;
        // the ckc/cvc buffers stay allocated at ENC_SEQ so only counts change.
        // Reset per slot: a rescue re-encode in the PREVIOUS slot may have
        // shrunk actx to its seek window — this slot's KV must match its own.
        actx = if (nb == 1) audioCtx(cgot) else ENC_SEQ;
        var ckvt = try std.time.Timer.start();
        for (0..dec.NL) |l| {
            try mtl.beginCommandBuffer();
            try deqW16(f_deq, cross_wdq, ckw[l], D, D);
            try mtl.matmulF16Batched(eo16, cross_wdq, ckc[l], actx, D, D);
            try deqW16(f_deq, cross_wdq, cvw[l], D, D);
            try mtl.matmulF16Batched(eo16, cross_wdq, cvc[l], actx, D, D);
            try biasAdd16(f_bias16, cvc[l], cvb[l], actx * D, D);
            try mtl.commitCommandBuffer();
            try mtl.sync();
        }
        g_t_ckv += ckvt.read();

        // reset decode state for this chunk
        for (SEED, 0..) |s, i| { d_tokens[i] = s; out_tokens[i] = s; }
        @memset(d_ca, 0);

        // SOT probe (every chunk): the prediction at the <|sot|> position
        // carries TWO model-side signals from one cheap forward —
        //   · language token arg-max [50259..50358] (detected once per file)
        //   · P(<|nospeech|>=50363): the model's own speech/non-speech verdict.
        //     Energy cannot make this call — measured: pqmho's music has
        //     HIGHER window RMS (p25 0.154) than wife real speech (med 0.052)
        //     or ES2004a far-field (med 0.0067).
        // (P(nospeech) was measured here and REFUTED: ≈1e-10 on pure music and
        // real speech alike — <|nospeech|> is dead in large-v3-turbo. The SOT
        // probe stays lang-detect-only; see PERF_LOG SV-2.)
        // T12: with a LANG_CANDIDATES whitelist the probe runs EVERY segment and
        // this segment's seed language may differ from the session lock — a KO
        // staff line and the JA patient's reply each decode with their own token.
        var seg_lang: u32 = lang_tok;
        if (lang_tok == 0 or g_lang_ncands > 0) {
            d_pos[0] = 0;
            try mtl.beginCommandBuffer();
            try embLookup(f_emb, d_x, tok_emb.qs, tok_emb.scales, &d_tokens[0]);
            try residual(Kd, d_x, dec_pe, D); // pos-0 positional embedding
            for (0..dec.NL) |l| {
                const ca_ctx = dec.CaCtx{ .weights = d_ca.ptr, .tok = d_pos, .heads = layer_heads[l], .inv_n = inv_n, .head_base = head_base[l] };
                try dec.decodeBlock(Kd, dlayers[l], d_x, dscr, skc[l], svc[l], ckc[l], cvc[l], d_pos, ca_ctx, actx);
            }
            try layerNorm(Kd, d_x, dscr.xb, dln_w, dln_b, D);
            try kLogitGemv(f_logit, d_logits, tok_emb.qs, tok_emb.scales, dscr.xb, VOCAB, D);
            try mtl.commitCommandBuffer();
            try mtl.sync();
            if (lang_tok == 0) {
                // First detection (auto): FULL-range argmax even when a candidate
                // whitelist is set — the whitelist is built from the TRANSLATE
                // TARGETS, and the actually-spoken language can sit OUTSIDE it
                // (EN speech with {中,韓} targets → forced-KO decode produced the
                // "일요일…/이 시각 세계였습니다" hallucinations, 2026-07-13 폭파).
                // The detected session language then joins the whitelist below.
                var bl: u32 = 50259;
                var bv: f32 = d_logits[50259];
                var lt: u32 = 50259;
                while (lt <= 50358) : (lt += 1) { if (d_logits[lt] > bv) { bv = d_logits[lt]; bl = lt; } }
                lang_tok = bl;
                seg_lang = bl;
                try out.print("[lang] detected token {d} (en=50259 ko=50264)\n", .{lang_tok});
            } else {
                // Per-segment re-probe (T12): argmax over the whitelist ∪ the
                // SESSION language — the session lock/first-detect must always be
                // able to win, or a source language outside the target-derived
                // whitelist gets relabeled every segment.
                var bl: u32 = lang_tok;
                var bv: f32 = d_logits[lang_tok];
                for (g_lang_cands[0..g_lang_ncands]) |c| {
                    if (d_logits[c] > bv) { bv = d_logits[c]; bl = c; }
                }
                seg_lang = bl;
                if (seg_lang != lang_tok) {
                    try out.print("[lang] seg token {d}\n", .{seg_lang});
                }
            }
        }
        d_tokens[1] = seg_lang;
        out_tokens[1] = seg_lang;
        d_tokens[2] = task_tok; // transcribe(50360) / translate(50359)
        out_tokens[2] = task_tok;

        // GPU-resident autoregressive decode (idea from the SHARE build's CUDA
        // Graph replay): the whole step runs on-GPU — indirect embed, blocks,
        // logit GEMV, GPU logit-filter + argmax + step-advance — so NO CPU sits
        // between tokens. B steps are recorded into one command buffer; we sync
        // only once per batch (then read tokens to detect EOT).
        var dt2 = try std.time.Timer.start();
        const DBATCH: u32 = 8;
        // Seek loop — OpenAI window-seek, faithfully WITH the re-encode: a
        // greedy ts decode may close its last segment and EOT while voiced
        // audio remains (jfk stops at 7.52 s before the long pause). The
        // remaining audio is then RE-ENCODED as a fresh window starting at
        // the seek point and decoded again. Two cheaper shortcuts were
        // reverse-verified WORSE and removed:
        //   · banning EOT while voice remains → the model fills with junk
        //     text when it wants to stop (wife_conv ". . . ~~" loop);
        //   · re-decoding the SAME encoder window with a forced initial
        //     timestamp (± <|startofprev|> prompt) → out-of-distribution,
        //     the model re-transcribes the window start (jfk "and so," dup).
        // The re-encode (~600 ms) only runs on the rare early-EOT chunks.
        const senv = slot_env[slot * ENV_LEN ..][0..slot_nenv[slot]];
        const voice_end_fr: u32 = blk: {
            if (senv.len < 8) break :blk 0;
            var gm: f32 = 0;
            for (senv) |e| gm += e;
            gm /= @floatFromInt(senv.len);
            var ve: usize = 0;
            for (senv, 0..) |e, ii| { if (e > 0.5 * gm) ve = ii; }
            break :blk @intCast(ve / 20);
        };
        // near-silence hallucination guard: drop this chunk's text when the audio
        // was quiet (loud speech keeps high seg_rms and is never dropped).
        const dropped = hallu_guard and seg_rms2 < hallu_rms;
        var chunk_text = std.ArrayList(u8).init(alloc);
        defer chunk_text.deinit();
        var n_tok_total: u32 = 0;
        var sum_lp: f64 = 0; // Σ ln(token prob) over accepted text tokens (avg_logprob)
        var n_lp: u32 = 0;
        var fb_reason: []const u8 = "none"; // rescue reason for the seg event (none/collapse/logprob)
        var enc_ns: u64 = 0; // CPU: command recording + commit
        var sync_ns: u64 = 0; // GPU: execution wait
        var host_ns: u64 = 0; // host post-processing (BPE decode + word DTW) — excluded from decode tok/s
        // Hybrid decode: plain no-ts greedy first (best code-switch fidelity:
        // ts-mode inherently transliterates EN terms in KO speech — verified
        // engine-independent, wcpp ts-greedy says "아키텍츄럴" too). Only when
        // the plain pass COLLAPSES into a periodic repeat loop is the chunk
        // re-decoded in timestamp-token mode (collapse-immune) + seek.
        var ts_mode = false;
        var total_passes: u32 = 0;
        mode: while (true) {
        chunk_text.clearRetainingCapacity();
        n_tok_total = 0;
        sum_lp = 0; n_lp = 0;
        var seek_fr: u32 = 0; // chunk-relative 20 ms frame the CURRENT window starts at
        var pass: u32 = 0;
        seek: while (pass < 6) : (pass += 1) {
            total_passes += 1;
            var PL: u32 = 0;
            // term-biasing prefix: <|startofprev|> + prompt tokens, seeded before
            // the SOT (KV-filled, never predicted) so they bias generation.
            if (g_prompt.len > 0 and g_prompt.len + 8 < MAX_TOK) {
                d_tokens[PL] = STARTOFPREV; PL += 1;
                for (g_prompt) |t| { d_tokens[PL] = t; PL += 1; }
            }
            d_tokens[PL] = SEED[0]; // sot
            d_tokens[PL + 1] = seg_lang; // per-segment language (== lang_tok unless LANG_CANDIDATES)
            d_tokens[PL + 2] = task_tok; // transcribe(50360) / translate(50359)
            PL += 3;
            if (!ts_mode) { d_tokens[PL] = 50364; PL += 1; } // <|notimestamps|>
            for (0..PL) |q| out_tokens[q] = d_tokens[q];
            const sample_begin: u32 = PL;
            const max_gen: u32 = MAX_TOK - PL - 1;
            const pass_got: usize = cgot - @min(@as(usize, seek_fr) * 320, cgot); // samples in this window
            const pass_off: f32 = @as(f32, @floatFromInt(seek_fr)) * 0.02; // window start within the chunk (s)
            // Seed phase: fill KV[0..P-1) without prediction — recorded as ONE
            // command buffer (indirect embed/pos/step; positions restart each
            // pass, KV/ca rows are simply overwritten).
            if (PL >= 2) {
                d_pos[0] = 0;
                try mtl.beginCommandBuffer();
                for (0..PL - 1) |_| {
                    try kEmbInd(f_emb_ind, d_x, tok_emb.qs, tok_emb.scales, d_tokens.ptr, d_pos);
                    try kPeInd(f_pe_ind, d_x, dec_pe, d_pos);
                    for (0..dec.NL) |l| {
                        const ca_ctx = dec.CaCtx{ .weights = d_ca.ptr, .tok = d_pos, .heads = layer_heads[l], .inv_n = inv_n, .head_base = head_base[l] };
                        try dec.decodeBlock(Kd, dlayers[l], d_x, dscr, skc[l], svc[l], ckc[l], cvc[l], d_pos, ca_ctx, actx);
                    }
                    try kStep(f_step, d_pos);
                }
                try mtl.commitCommandBuffer();
                try mtl.sync();
            }
            d_pos[0] = PL - 1; // first prediction step
            var n_text: u32 = 0;
            var done = false;
            var partial_frozen = false; // stop streaming a runaway hypothesis (see partial emit below)
            while (n_text < max_gen and !done) {
                const this_b = @min(DBATCH, max_gen - n_text);
                var rec_t = try std.time.Timer.start();
                try mtl.beginCommandBuffer();
                for (0..this_b) |_| {
                    try kEmbInd(f_emb_ind, d_x, tok_emb.qs, tok_emb.scales, d_tokens.ptr, d_pos);
                    try kPeInd(f_pe_ind, d_x, dec_pe, d_pos);
                    for (0..dec.NL) |l| {
                        const ca_ctx = dec.CaCtx{ .weights = d_ca.ptr, .tok = d_pos, .heads = layer_heads[l], .inv_n = inv_n, .head_base = head_base[l] };
                        try dec.decodeBlock(Kd, dlayers[l], d_x, dscr, skc[l], svc[l], ckc[l], cvc[l], d_pos, ca_ctx, actx);
                    }
                    try layerNorm(Kd, d_x, dscr.xb, dln_w, dln_b, D);
                    try kLogitGemv(f_logit, d_logits, tok_emb.qs, tok_emb.scales, dscr.xb, VOCAB, D);
                    try kSuppress(f_suppress, d_logits, d_suppress.ptr, n_suppress);
                    try kFilt(if (ts_mode) f_filt_ts else f_filt_plain, d_logits, d_tokens.ptr, d_pos, sample_begin, g_no_repeat_ngram);
                    try kStep(f_step, d_pos); // pos += 1
                    try kArgmaxConf(f_argmax, d_logits, d_tokens.ptr, d_conf, d_pos, MAX_TOK); // tokens[pos]=argmax, conf[pos]=prob
                }
                try mtl.commitCommandBuffer();
                enc_ns += rec_t.read();
                var sync_t = try std.time.Timer.start();
                try mtl.sync();
                sync_ns += sync_t.read();
                // detect EOT among the this_b newly written tokens
                const base = PL + n_text;
                var bi: u32 = 0;
                while (bi < this_b) : (bi += 1) {
                    const tk = d_tokens[base + bi];
                    out_tokens[base + bi] = tk;
                    if (tk == EOT) { done = true; break; }
                }
                n_text += bi;
                // streaming partial: emit the in-progress text after this batch.
                // PARTIALS=1 also mirrors it onto stdout as a «partial» line so
                // the app renders the segment's text WHILE it decodes instead of
                // all-at-once at SEG_END. Opt-in env → the frozen stdout text
                // contract is untouched for every existing consumer.
                // Runaway-guard the STREAMING preview: the plain pass can over-
                // generate past the real speech (run-on hallucination that
                // NO_REPEAT_NGRAM doesn't catch — the tokens don't repeat). The
                // post-loop rescue (tokenCollapse / LOGPROB_RESCUE below) discards
                // and re-decodes such a pass, but the ballooning «partial»s were
                // ALREADY streamed → a huge preview flashes on screen then gets
                // "corrected" by the clean commit. Freeze partials the moment the
                // hypothesis trips the SAME collapse predicate the rescue uses, or
                // exceeds a token budget (~½ MAX_TOK) — keep the last good preview;
                // the rescue still lands the clean committed text.
                if (g_partials and !dropped and n_text > 0 and !partial_frozen) {
                    if (tokenCollapse(out_tokens[PL .. PL + n_text]) or
                        tokenDiversityCollapse(out_tokens[PL .. PL + n_text]) or
                        n_text > envU("PARTIAL_MAX_TOK", 224))
                    {
                        partial_frozen = true;
                    } else {
                        const ptext = bpeDecode(bpe_path, out_tokens[PL .. PL + n_text]) catch "";
                        evPartial(t_off + pass_off, ptext);
                        if (stream) try out.print("\u{00AB}partial {d:.2}\u{00BB} {s}\n", .{ t_off + pass_off, std.mem.trim(u8, ptext, " \n") });
                    }
                }
            }
            n_tok_total += n_text;
            // this pass's avg_logprob: mean ln(softmax prob) over its tokens
            // (d_conf[pos] = argmax prob). High for confident decodes — a genuine
            // repeat stays high (jfk3 3× real repeat −0.03), only DEGENERATE decodes
            // sink low. Measured (test-other worst/best, bench/logprob_probe.py):
            // best mean −0.07, worst mean −0.44, but <−1.0 fires on 0/30 normal utts
            // and only the 1 catastrophic over-generation → a precise, FP-free net.
            var pass_lp: f64 = 0; var pass_nlp: u32 = 0;
            for (0..n_text) |i| { const c = d_conf[PL + i]; if (c > 0) { pass_lp += @log(@as(f64, c)); pass_nlp += 1; } }
            const pass_avg_lp: f64 = if (pass_nlp > 0) pass_lp / @as(f64, @floatFromInt(pass_nlp)) else 0;
            // rescue trigger: periodic collapse (existing) OR a MUTATED loop
            // (tokenDiversityCollapse — the NRNG ban makes a stuck decode vary
            // each period, which defeats exact-match runs; 2026-07-13 폭파) OR a
            // degenerate decode (avg_logprob below LOGPROB_RESCUE, default −1.0 —
            // Whisper's threshold). Predicates run on TEXT tokens only: the
            // ts-mode pass interleaves <|t|> tokens that would break period runs
            // and inflate 4-gram diversity, masking a text loop.
            var loop_txt: [MAX_TOK]u32 = undefined;
            var n_loop: usize = 0;
            for (0..n_text) |i| {
                const tk = out_tokens[PL + i];
                if (tk < EOT) { loop_txt[n_loop] = tk; n_loop += 1; }
            }
            const loopy = tokenCollapse(loop_txt[0..n_loop]) or tokenDiversityCollapse(loop_txt[0..n_loop]);
            if (!ts_mode and (loopy or pass_avg_lp < envF("LOGPROB_RESCUE", -1.0))) {
                ts_mode = true; // discard this pass, re-decode in ts mode
                fb_reason = if (pass_avg_lp < envF("LOGPROB_RESCUE", -1.0)) "logprob" else "collapse";
                try out.print("[rescue] chunk {d}: {s} — re-decoding with timestamp tokens\n", .{ cchunk + 1, fb_reason });
                continue :mode;
            }
            // the RESCUE re-decode itself was previously committed UNGATED — a ts
            // pass that also loops walked straight into the transcript (the 폭파
            // screenshot's "이 시각 세계였습니다" ×20 line). Empty output is
            // strictly better than committed garbage: drop the pass.
            const pass_garbage = ts_mode and loopy;
            if (pass_garbage)
                try out.print("[rescue] chunk {d}: re-decode still degenerate — segment dropped\n", .{cchunk + 1});
            if (!dropped and n_text > 0 and !pass_garbage) {
                sum_lp += pass_lp; n_lp += pass_nlp; // accumulate for the seg event
                var ht = try std.time.Timer.start();
                const text = try bpeDecode(bpe_path, out_tokens[PL .. PL + n_text]);
                try chunk_text.appendSlice(text);
                const env_off = @min(@as(usize, seek_fr) * 20, senv.len);
                try wordTimestamps(out, bpe_path, d_ca.ptr, out_tokens, n_text, PL, t_off + pass_off, pass_got, senv[env_off..], d_conf);
                host_ns += ht.read();
            }
            if (pass_garbage) break :seek; // garbage timestamps — don't seek into junk
            if (!ts_mode) break :seek; // plain mode: single pass, no seek
            // continue from the last closed segment if ≥1 s of voiced audio remains
            var last_fr: u32 = 0; // window-relative frame of the last <|t|>
            var any_text = false;
            for (0..n_text) |i| {
                const tk = out_tokens[PL + i];
                if (tk >= TS0) last_fr = tk - TS0 else any_text = true;
            }
            if (!any_text or last_fr == 0) break :seek; // no forward progress
            const new_seek = seek_fr + last_fr;
            if (new_seek + 50 >= voice_end_fr) break :seek; // <1 s voiced left
            seek_fr = new_seek;
            // re-encode the remaining audio as a fresh window starting at seek
            const soff = @as(usize, seek_fr) * 320;
            if (soff >= cgot) break :seek;
            const rem = cgot - soff;
            const sbase = slot_samp[slot * mel.CHUNK_SAMPLES ..];
            @memcpy(samples[0..rem], sbase[soff .. soff + rem]);
            @memset(samples[rem..mel.CHUNK_SAMPLES], 0);
            mel.melSpectrogram(samples, mel_filters, mel_buf);
            try mtl.beginCommandBuffer();
            try imIm2col(f_im2col, col1, mel_buf.ptr, mel.N_MELS, mel.N_FRAMES, 1, 1, mel.N_FRAMES);
            try mtl.matmulF16Batched(col1, c1w, t1, mel.N_FRAMES, D, mel.N_MELS * 3);
            try geluTranspose(f_geluT, conv1o, t1, c1b, mel.N_FRAMES, D);
            try imIm2col(f_im2col, col2, conv1o, D, mel.N_FRAMES, 2, 1, ENC_SEQ);
            try mtl.matmulF16Batched(col2, c2w, t2, ENC_SEQ, D, D * 3);
            try geluPos(f_geluPos, d_ex + slot * @as(usize, ENC_SEQ) * D, t2, c2b, enc_pe, ENC_SEQ * D, D);
            try mtl.commitCommandBuffer();
            try mtl.sync();
            // seek window is always a single-slot encode → it can shrink to the
            // remaining audio under AUDIO_CTX (rem < the original chunk).
            actx = audioCtx(rem);
            try enc.forward(Ke, &elayers, elnp_w, elnp_b, d_ex + slot * @as(usize, ENC_SEQ) * D, eo16, enc_out + slot * @as(usize, ENC_SEQ) * D, escr, 1, actx);
            for (0..dec.NL) |l| {
                try mtl.beginCommandBuffer();
                try deqW16(f_deq, cross_wdq, ckw[l], D, D);
                try mtl.matmulF16Batched(eo16, cross_wdq, ckc[l], actx, D, D);
                try deqW16(f_deq, cross_wdq, cvw[l], D, D);
                try mtl.matmulF16Batched(eo16, cross_wdq, cvc[l], actx, D, D);
                try biasAdd16(f_bias16, cvc[l], cvb[l], actx * D, D);
                try mtl.commitCommandBuffer();
                try mtl.sync();
            }
            @memset(d_ca, 0);
        }
        break :mode;
        }

        const dec_gpu_ns = dt2.read() -| host_ns;
        g_t_dec += dec_gpu_ns;
        g_t_dtw += host_ns;
        const dec_ms = @as(f64, @floatFromInt(dec_gpu_ns)) / 1e6; // word-DTW/BPE moved inside the loop; keep tok/s comparable
        try out.print("[perf] chunk {d}: conv {d:.0}ms | encoder {d:.0}ms (batch {d}) | decode {d} tok {d:.0}ms ({d:.1} tok/s)  [cpu-rec {d:.0}ms | gpu-sync {d:.0}ms | passes {d}]\n", .{ cchunk + 1, conv_ms, enc_ms, nb, n_tok_total, dec_ms, @as(f64, @floatFromInt(n_tok_total)) / (dec_ms / 1000.0), @as(f64, @floatFromInt(enc_ns)) / 1e6, @as(f64, @floatFromInt(sync_ns)) / 1e6, total_passes });
        const avg_lp: f32 = if (n_lp > 0) @floatCast(sum_lp / @as(f64, @floatFromInt(n_lp))) else 0;
        evSeg(@intCast(cchunk), t_off, t_off + @as(f32, @floatFromInt(cgot)) / 16000.0, chunk_text.items, @as(f32, @floatFromInt(n_tok_total)) / @as(f32, @floatCast(dec_ms / 1000.0)), @floatCast(enc_ms), @floatCast(dec_ms), total_passes, dropped, avg_lp, fb_reason);
        if (dropped) {
            if (n_chunks > 1) try out.print("\n[chunk {d}/{d} @ {d:.0}s] (low-energy — hallucination guard, rms {d:.3})\n", .{ cchunk + 1, n_chunks, t_off, seg_rms2 });
        } else {
            if (n_chunks > 1) try out.print("\n[chunk {d}/{d} @ {d:.0}s] {s}\n", .{ cchunk + 1, n_chunks, t_off, chunk_text.items });
            try full.appendSlice(chunk_text.items);
        }
        } // slot
    }
        const dt = @as(f64, @floatFromInt(timer.read())) / 1e9;
        try out.print("\n=== TRANSCRIPTION ({d:.2}s, {d} chunk(s)) ===\n{s}\n", .{ dt, n_chunks, full.items });

        // stream mode: one segment done → emit sentinel and await the next job.
        if (stream) {
            evEnd("seg_end");
            try out.print("<<SEG_END>>\n", .{});
            continue :job;
        }

        // optional: dump raw pooled segment embeddings for offline clustering sweeps
        if (std.posix.getenv("DIAR_DUMP")) |dp| {
            var df = try std.fs.cwd().createFile(dp, .{});
            defer df.close();
            const hdr = [_]u32{ @intCast(diar_n), @intCast(SEGD) };
            try df.writeAll(std.mem.sliceAsBytes(hdr[0..]));
            try df.writeAll(std.mem.sliceAsBytes(diar_t0.items[0..diar_n]));
            try df.writeAll(std.mem.sliceAsBytes(diar_bm.items[0..diar_n])); // per-window RMS (VAD replication offline)
            try df.writeAll(std.mem.sliceAsBytes(diar_emb.items[0 .. diar_n * SEGD]));
            try out.print("  [diar dump → {s}: {d} segs × {d}]\n", .{ dp, diar_n, SEGD });
        }
        // VAD_DUMP: richer dump incl. raw per-window silero frame probs → enables a
        // FULLY OFFLINE sweep of (VAD_PROB × sp_gate × min_speech × pad × cluster
        // params) from a single encoder pass. Format: u32{n, SEGD, FPW}, then
        // t0[n], emb[n*SEGD], pf[n*FPW] (all little-endian f32).
        if (std.posix.getenv("VAD_DUMP")) |dp| {
            const FPW: usize = SEG_SAMP / vad.N_WINDOW;
            var df = try std.fs.cwd().createFile(dp, .{});
            defer df.close();
            const hdr = [_]u32{ @intCast(diar_n), @intCast(SEGD), @intCast(FPW) };
            try df.writeAll(std.mem.sliceAsBytes(hdr[0..]));
            try df.writeAll(std.mem.sliceAsBytes(diar_t0.items[0..diar_n]));
            try df.writeAll(std.mem.sliceAsBytes(diar_emb.items[0 .. diar_n * SEGD]));
            try df.writeAll(std.mem.sliceAsBytes(diar_pf.items[0 .. diar_n * FPW]));
            try out.print("  [vad dump → {s}: {d} win × ({d} emb + {d} pf)]\n", .{ dp, diar_n, SEGD, FPW });
        }
        var diart = try std.time.Timer.start();
        try diarizeEmb(out, diar_emb.items, diar_bm.items, diar_t0.items, diar_n, SEGD, SEG_SEC, diar_k, rttm_out, file_id);
        try attributeTranscript(out);
        g_t_diar += diart.read();
        if (std.posix.getenv("PROF") != null) {
            const ms = struct { fn f(ns: u64) f64 { return @as(f64, @floatFromInt(ns)) / 1e6; } }.f;
            try out.print("\n=== PROF (full wall attribution, ms) ===\n  mel {d:.0} | conv {d:.0} | encoder {d:.0} | cross-KV {d:.0} | decode(gpu) {d:.0} | word-DTW+bpe {d:.0} | diar {d:.0}\n  (load + Metal init + output I/O = external wall − above)\n", .{ ms(g_t_mel), ms(g_t_conv), ms(g_t_enc), ms(g_t_ckv), ms(g_t_dec), ms(g_t_dtw), ms(g_t_diar) });
        }
        // App file mode: re-emit the offline speaker timeline as streaming
        // `SPK <gt> <id> <dur>` lines so the macOS app's existing parser
        // attributes each word by time, then signal completion like the stream
        // path so the app finalizes + enables export. Gated on APP_FILE.
        if (std.posix.getenv("APP_FILE") != null) {
            for (g_segs.items) |s| {
                try out.print("SPK {d:.3} {d} {d:.3}\n", .{ s.a, s.spk, s.b - s.a });
            }
            try out.print("<<FLUSH_END>>\n", .{});
        }
        break :job; // single-file mode runs exactly once
    }

    // stream session ended (stdin EOF): dump final speaker centroids so the
    // live runner can enroll user-named speakers as voiceprints for next time.
    if (vp_dir) |vd| {
        if (cents.items.len > 0) {
            var db: [512]u8 = undefined;
            const lastdir = std.fmt.bufPrint(&db, "{s}/.last", .{vd}) catch vd;
            std.fs.cwd().makePath(lastdir) catch {};
            for (cents.items, 0..) |*c, i| {
                var cnorm: [diar.EMB]f32 = undefined;
                var css: f32 = 0;
                for (c.sum) |x| css += x * x;
                const cinv = 1.0 / (@sqrt(css) + 1e-9);
                for (0..diar.EMB) |ci| cnorm[ci] = c.sum[ci] * cinv;
                var pb: [512]u8 = undefined;
                const path = std.fmt.bufPrint(&pb, "{s}/.last/spk{d}.vec", .{ vd, i }) catch continue;
                const f = std.fs.cwd().createFile(path, .{}) catch continue;
                f.writeAll(std.mem.sliceAsBytes(cnorm[0..])) catch {};
                f.close();
            }
        }
    }
}

fn envU(name: [:0]const u8, dflt: usize) usize {
    if (std.posix.getenv(name)) |s| return std.fmt.parseInt(usize, s, 10) catch dflt;
    return dflt;
}
fn envF(name: [:0]const u8, dflt: f32) f32 {
    if (std.posix.getenv(name)) |s| return std.fmt.parseFloat(f32, s) catch dflt;
    return dflt;
}
fn pathUnderRoot(path: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, path, root)) return true;
    return path.len > root.len and std.mem.startsWith(u8, path, root) and std.fs.path.isSep(path[root.len]);
}
fn validateStreamWavPath(a: std.mem.Allocator, input_path: []const u8) ![]u8 {
    if (input_path.len == 0 or !std.mem.endsWith(u8, input_path, ".wav")) return error.InvalidStreamPath;
    const resolved = try std.fs.cwd().realpathAlloc(a, input_path);
    errdefer a.free(resolved);
    const roots = std.posix.getenv("STREAM_WAV_ROOTS") orelse std.posix.getenv("TMPDIR") orelse "/tmp";
    var it = std.mem.splitScalar(u8, roots, std.fs.path.delimiter);
    while (it.next()) |root| {
        if (root.len == 0) continue;
        const resolved_root = std.fs.cwd().realpathAlloc(a, root) catch continue;
        defer a.free(resolved_root);
        if (pathUnderRoot(resolved, resolved_root)) return resolved;
    }
    return error.StreamPathOutsideAllowedRoots;
}
fn d2(a: []const f32, b: []const f32) f32 {
    var s: f32 = 0;
    for (0..a.len) |j| { const t = a[j] - b[j]; s += t * t; }
    return s;
}
// k-means over L2-normalized embeddings. The spherical candidate removes the
// input-order bias of seeding from X[0] and reprojects updated centroids onto
// the unit sphere; the shipped legacy path stays byte-stable when false.
fn kmeansFitMode(X: []const f32, m: usize, segd: usize, K: usize, asg: []usize, spherical: bool) !void {
    if (K <= 1) { @memset(asg, 0); return; }
    const cent = try alloc.alloc(f32, K * segd); defer alloc.free(cent);
    if (spherical) {
        @memset(cent[0..segd], 0);
        for (0..m) |i| {
            for (0..segd) |j| cent[j] += X[i * segd + j];
        }
        const inv_m = 1.0 / @as(f32, @floatFromInt(m));
        for (0..segd) |j| cent[j] *= inv_m;
        var far: usize = 0; var far_d = d2(X[0..segd], cent[0..segd]);
        for (1..m) |i| {
            const dd = d2(X[i * segd ..][0..segd], cent[0..segd]);
            if (dd > far_d) { far_d = dd; far = i; }
        }
        @memcpy(cent[0..segd], X[far * segd ..][0..segd]);
    } else {
        @memcpy(cent[0..segd], X[0..segd]);
    }
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
        for (0..K) |c| if (ccnt[c] > 0) {
            if (spherical) {
                var norm2: f32 = 0;
                for (0..segd) |j| norm2 += csum[c * segd + j] * csum[c * segd + j];
                const inv = 1.0 / (@sqrt(norm2) + 1e-9);
                for (0..segd) |j| cent[c * segd + j] = csum[c * segd + j] * inv;
            } else {
                const inv = 1.0 / @as(f32, @floatFromInt(ccnt[c]));
                for (0..segd) |j| cent[c * segd + j] = csum[c * segd + j] * inv;
            }
        };
    }
}
fn kmeansFit(X: []const f32, m: usize, segd: usize, K: usize, asg: []usize) !void {
    return kmeansFitMode(X, m, segd, K, asg, false);
}
// Max pairwise centroid cosine distance — ABSOLUTE speaker separation. The
// silhouette is RELATIVE ((b-a)/max), so a single speaker whose delivery varies
// (presentation tone/energy) splits into well-separated sub-clusters with high
// silhouette. But all sub-cluster centroids stay CLOSE (same voice): measured
// jfk3 single-speaker max=0.326 vs every real multi-speaker file max≥0.727.
// Gate on this to reject single-speaker over-splits without merging real
// speakers (a multi-speaker file has ≥2 far centroids → max high → unaffected).
fn maxCentroidCosDist(X: []const f32, m: usize, segd: usize, asg: []const usize, K: usize) f32 {
    if (K < 2) return 2;
    const mu = alloc.alloc(f32, K * segd) catch return 2; defer alloc.free(mu);
    const cnt = alloc.alloc(usize, K) catch return 2; defer alloc.free(cnt);
    @memset(mu, 0); @memset(cnt, 0);
    for (0..m) |i| { cnt[asg[i]] += 1; for (0..segd) |j| mu[asg[i] * segd + j] += X[i * segd + j]; }
    for (0..K) |c| if (cnt[c] > 0) for (0..segd) |j| { mu[c * segd + j] /= @as(f32, @floatFromInt(cnt[c])); };
    var maxd: f32 = -2;
    for (0..K) |a| for (a + 1..K) |b| {
        var dot: f32 = 0; var na: f32 = 0; var nb: f32 = 0;
        for (0..segd) |j| { dot += mu[a*segd+j]*mu[b*segd+j]; na += mu[a*segd+j]*mu[a*segd+j]; nb += mu[b*segd+j]*mu[b*segd+j]; }
        const cd = 1.0 - dot / (@sqrt(na*nb) + 1e-9);
        if (cd > maxd) maxd = cd;
    };
    return maxd;
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

const SphericalPromotion = struct { sil: f32, sep: f32 };

// Narrow auto-K challenger for the measured 3-4-person panel failure. Preserve
// every legacy K=1 decision and every K>=4 result. Only promote a surviving
// legacy K=2/3 when a full spherical sweep independently selects K=4 with a
// strong silhouette and the existing absolute-separation safety gate passes.
fn maybePromoteSpherical4(X: []const f32, m: usize, segd: usize, maxK: usize, legacy_k: usize, asg: []usize) !?SphericalPromotion {
    if (envU("DIAR_PROMOTE4", 1) == 0 or legacy_k < 2 or legacy_k >= 4 or maxK < 4) return null;
    const best_asg = try alloc.alloc(usize, m); defer alloc.free(best_asg);
    const tmp = try alloc.alloc(usize, m); defer alloc.free(tmp);
    var best_k: usize = 2;
    var best_sil: f32 = -2;
    var kk: usize = 2;
    while (kk <= maxK) : (kk += 1) {
        try kmeansFitMode(X, m, segd, kk, tmp, true);
        const sil = try silhouetteSimplified(X, m, segd, tmp, kk);
        if (sil > best_sil) { best_sil = sil; best_k = kk; @memcpy(best_asg, tmp); }
    }
    if (best_k != 4 or best_sil < envF("DIAR_PROMOTE4_SIL", 0.50)) return null;
    const sep = maxCentroidCosDist(X, m, segd, best_asg, 4);
    if (sep < envF("DIAR_MIN_SEP", 0.50)) return null;
    @memcpy(asg, best_asg);
    return .{ .sil = best_sil, .sep = sep };
}

// Reserved speaker id for the single "Unknown" (미확인) bucket used ONLY in
// fixed-K mode: a rare acoustically-distinct extra voice that matches none of the
// N fixed speakers. Must be POSITIVE (file mode treats spk<0 as non-speech) and
// >= 16 (the OSD votes[.][16] `g<16` guards silently drop it so Unknown never
// becomes an overlap target) and <= 255 (fits the live_ids u8 clamp). Shared
// verbatim with the app (Swift SpeakerID.unknown). 255 satisfies all three.
const DIAR_UNK_ID: i32 = 255;

// Fixed-K clustering WITH a single "Unknown" bucket (화자 N명 고정 + 미확인).
// Naive k-means at K=N mis-seeds under farthest-point init: the most-distant
// outlier seeds cent[1], so "2 near voices A,B + 1 distinct C" collapses to
// {A∪B} vs {C} — the inverse of what the user wants. Fix: cluster at N+1 so the
// outlier gets its OWN cluster, keep the N most-POPULOUS clusters as the fixed
// speakers (the main conversation), and route the single leftover cluster to
// Unknown IFF it is both sizeable (>= DIAR_UNK_MIN windows) AND acoustically
// distinct from every kept speaker (max centroid cos-sim < DIAR_UNK_THR). A
// leftover that is just an over-split sub-cluster of a real voice is highly
// similar to a kept centroid → folded back in (protects clean N-speaker files
// from false Unknown). Fills asg[i] in 0..N-1 (real) + unk[i]=true for Unknown;
// keeping N clusters guarantees the "min N real speakers" floor (Unknown can only
// ever come from the (N+1)th cluster). Returns the real speaker count.
fn assignFixedKUnknown(X: []const f32, m: usize, segd: usize, N: usize, asg: []usize, unk: []bool) !usize {
    @memset(unk, false);
    // too few windows to spare an outlier cluster → plain fixed-K, no Unknown
    if (m <= N + 1 or N < 1) {
        const K = @max(@min(N, m), 1);
        try kmeansFit(X, m, segd, K, asg);
        return K;
    }
    // cos-sim floor: a leftover cluster below this to EVERY kept speaker is "a
    // different voice". 0.35 sits just under the online-birth bar DIAR_SIM=0.40
    // and well above the ~0.27 cross-speaker centroid floor, so only a genuinely
    // unmodeled voice is flagged; a swept 0.30–0.45 shows zero false Unknown on
    // clean 1/2-speaker audio. Tune DOWN (stricter) if over-flagging appears.
    const unk_thr = envF("DIAR_UNK_THR", 0.35);
    const unk_min = envU("DIAR_UNK_MIN", 3); // min windows to materialize Unknown (mirrors min_sz=3 / OSD ≥3-frame trust)
    const Kp = N + 1;
    const a2 = try alloc.alloc(usize, m); defer alloc.free(a2);
    try kmeansFit(X, m, segd, Kp, a2);
    // mean UNIT-centroid direction + window count per cluster
    const mu = try alloc.alloc(f32, Kp * segd); defer alloc.free(mu);
    const cnt = try alloc.alloc(usize, Kp); defer alloc.free(cnt);
    @memset(mu, 0); @memset(cnt, 0);
    for (0..m) |i| { cnt[a2[i]] += 1; for (0..segd) |j| mu[a2[i] * segd + j] += X[i * segd + j]; }
    for (0..Kp) |c| {
        var s: f32 = 0; for (0..segd) |j| s += mu[c * segd + j] * mu[c * segd + j];
        const inv = 1.0 / (@sqrt(s) + 1e-9);
        for (0..segd) |j| mu[c * segd + j] *= inv;
    }
    // rank clusters by size desc (selection sort — Kp is tiny)
    const order = try alloc.alloc(usize, Kp); defer alloc.free(order);
    for (0..Kp) |c| order[c] = c;
    for (0..Kp) |i| {
        var mx = i;
        for (i + 1..Kp) |j| if (cnt[order[j]] > cnt[order[mx]]) { mx = j; };
        const t = order[i]; order[i] = order[mx]; order[mx] = t;
    }
    const leftover = order[N]; // smallest cluster
    const c2real = try alloc.alloc(i32, Kp); defer alloc.free(c2real);
    for (0..Kp) |c| c2real[c] = -1;
    for (0..N) |r| c2real[order[r]] = @intCast(r);
    // leftover distinctness: max cos-sim of its centroid to any KEPT centroid
    var lmax: f32 = -2;
    for (0..N) |r| {
        var dot: f32 = 0;
        for (0..segd) |j| dot += mu[leftover * segd + j] * mu[order[r] * segd + j];
        if (dot > lmax) lmax = dot;
    }
    const leftoverUnknown = cnt[leftover] >= unk_min and lmax < unk_thr;
    for (0..m) |i| {
        const c = a2[i];
        if (c2real[c] >= 0) { asg[i] = @intCast(c2real[c]); continue; }
        if (leftoverUnknown) { unk[i] = true; asg[i] = 0; continue; }
        // not distinct enough → fold leftover window into its nearest kept speaker
        var best: f32 = -2; var br: usize = 0;
        for (0..N) |r| {
            var dot: f32 = 0;
            for (0..segd) |j| dot += X[i * segd + j] * mu[order[r] * segd + j];
            if (dot > best) { best = dot; br = r; }
        }
        asg[i] = br;
    }
    return N;
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
    const unk = try alloc.alloc(bool, m); defer alloc.free(unk);
    @memset(unk, false);
    var K: usize = undefined;
    var ev_sil: f32 = 0; var ev_sep: f32 = 2; var ev_tau: f32 = 0; // for the structured diar event
    if (diar_k >= 1) {
        // Fixed-K: cluster to EXACTLY N speakers (no auto-K, no tau/MIN_SEP
        // collapse), routing a rare distinct extra voice to a single Unknown
        // bucket. Env DIAR_UNK=0 disables Unknown (plain fixed-K fallback).
        if (std.mem.eql(u8, std.posix.getenv("DIAR_UNK") orelse "1", "0")) {
            K = @min(@as(usize, diar_k), m);
            try kmeansFit(X, m, segd, K, asg);
        } else {
            K = try assignFixedKUnknown(X, m, segd, @min(@as(usize, diar_k), m), asg, unk);
        }
    } else {
        // windows-per-speaker floor: a K-speaker split needs ≥DIAR_KWIN
        // windows each on average — silhouette happily splits a 14-window
        // single-speaker file into 10 "speakers" (hqyok sil=0.835, DER 57→77%)
        // while real 8-20-speaker meetings have m≥79. Floor separates them.
        const kwin = envU("DIAR_KWIN", 8);
        const maxK: usize = @min(@min(envU("DIAR_MAXK", 10), m), @max(2, m / @max(kwin, 1)));
        // tau 0.35: VoxConverse-dev 215-file sweep — flips 5 true-1-speaker
        // files to K=1 (DER 9.7-57.5% → 0.0-3.5%) with ZERO multi-speaker
        // false positives (first FP appears at tau 0.40). bench/k_sweep_vox.py
        const tau: f32 = envF("DIAR_SIL_TAU", 0.35); // below this → single speaker
        const tmp = try alloc.alloc(usize, m); defer alloc.free(tmp);
        var bestK: usize = 2; var bestSil: f32 = -2;
        var kk: usize = 2;
        while (kk <= maxK) : (kk += 1) {
            try kmeansFit(X, m, segd, kk, tmp);
            const sil = try silhouetteSimplified(X, m, segd, tmp, kk);
            if (sil > bestSil) { bestSil = sil; bestK = kk; @memcpy(asg, tmp); }
        }
        if (bestSil < tau) { K = 1; @memset(asg, 0); } else K = bestK;
        // absolute-separation gate: reject single-speaker over-splits (presenter
        // delivery variation) — max centroid cosdist < DIAR_MIN_SEP → one speaker
        if (K >= 2) {
            const sep = maxCentroidCosDist(X, m, segd, asg, K);
            ev_sep = sep;
            if (sep < envF("DIAR_MIN_SEP", 0.50)) { K = 1; @memset(asg, 0); bestSil = -2; }
        }
        if (try maybePromoteSpherical4(X, m, segd, maxK, K, asg)) |promotion| {
            K = 4;
            bestSil = promotion.sil;
            ev_sep = promotion.sep;
        }
        ev_sil = bestSil; ev_tau = tau;
        try out.print("  [auto-K] K={d} (silhouette {d:.3}, tau {d:.2})\n", .{ K, bestSil, tau });
    }

    // per-segment speaker label (kept segments only), relabel by first appearance
    const spk = try alloc.alloc(i32, n); defer alloc.free(spk);
    for (0..n) |i| spk[i] = -1;
    const remap = try alloc.alloc(i32, K); defer alloc.free(remap);
    for (0..K) |i| remap[i] = -1;
    var nspk: i32 = 0;
    for (0..m) |i| {
        if (unk[i]) { spk[keep[i]] = DIAR_UNK_ID; continue; } // Unknown bucket — bypass remap, excluded from nspk
        const c = asg[i];
        if (remap[c] < 0) { remap[c] = nspk; nspk += 1; }
        spk[keep[i]] = remap[c];
    }

    // merge temporally-consecutive same-speaker speech segments → RTTM + timeline
    var rttm = std.ArrayList(u8).init(alloc);
    defer rttm.deinit();
    const flush = struct {
        // emit [a,b] clipped to the silero speech intervals (sub-window
        // precision — a 1.5 s diar window containing 0.3 s of speech must
        // not claim 1.5 s of speaker time; tucrg measured 919% DER that way)
        fn f(o: anytype, r: *std.ArrayList(u8), fid: []const u8, a: f32, b: f32, sp: i32) !void {
            if (g_vad_iv.items.len == 0) return emit(o, r, fid, a, b, sp);
            for (g_vad_iv.items) |iv| {
                const lo = @max(a, iv[0]);
                const hi = @min(b, iv[1]);
                if (hi - lo >= 0.1) try emit(o, r, fid, lo, hi, sp);
            }
        }
        fn emit(o: anytype, r: *std.ArrayList(u8), fid: []const u8, a: f32, b: f32, sp: i32) !void {
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
    // OSD overlap → 2nd-speaker emission (local-track identity): within one
    // 10 s model window, each local speaker's SOLO frames vote for a global
    // speaker (majority of our diar-window labels at those times); an
    // overlap frame's powerset class then names the global PAIR directly.
    // RTTM/timeline only; word attribution (g_segs) is left untouched.
    var n_ov: usize = 0;
    const osd_thr = envF("OSD_THR", 0.45); // P2b/H: VoxConverse-dev sweep — 0.45 cuts noise-clip false overlaps (tucrg 356→315) for MEAN 8.03→7.82% (live path keeps 0.25, L-3-tuned)
    for (g_osd_win.items) |*w| {
        // local → global vote per window
        var votes: [3][16]u32 = .{ .{0} ** 16, .{0} ** 16, .{0} ** 16 };
        for (0..w.nf) |fi| {
            const c = w.cls[fi];
            if (c < 1 or c > 3) continue; // solo classes only
            const ft = w.t + (@as(f32, @floatFromInt(osd.RFIELD)) / 2.0 + @as(f32, @floatFromInt(fi * osd.SHIFT))) / 16000.0;
            // diar window containing ft
            for (0..n) |i| {
                if (spk[i] < 0) continue;
                if (ft >= t0[i] and ft < t0[i] + seg_sec) {
                    const g: usize = @intCast(spk[i]);
                    if (g < 16) votes[c - 1][g] += 1;
                    break;
                }
            }
        }
        var loc2glob: [3]i32 = .{ -1, -1, -1 };
        for (0..3) |k| {
            var bg: usize = 0;
            for (1..16) |g| {
                if (votes[k][g] > votes[k][bg]) bg = g;
            }
            if (votes[k][bg] >= 3) loc2glob[k] = @intCast(bg); // ≥3 solo frames (50 ms) to trust
        }
        // overlap runs → second-speaker rows
        const pairs = [3][2]usize{ .{ 0, 1 }, .{ 0, 2 }, .{ 1, 2 } };
        var run_s: f32 = -1;
        var run_e: f32 = -1;
        var run_sec: i32 = -1;
        for (0..w.nf) |fi| {
            const ft = w.t + (@as(f32, @floatFromInt(osd.RFIELD)) / 2.0 + @as(f32, @floatFromInt(fi * osd.SHIFT))) / 16000.0;
            var sec: i32 = -1;
            if (w.pov[fi] >= osd_thr) {
                // pair = argmax over the 3 overlap classes (cls if ≥4, else recover)
                var pc: usize = if (w.cls[fi] >= 4) w.cls[fi] - 4 else 0;
                if (w.cls[fi] < 4) {
                    // pov passed threshold but argmax was solo — pick the
                    // likelier pair containing that solo speaker
                    const solo: usize = if (w.cls[fi] >= 1) w.cls[fi] - 1 else 0;
                    pc = if (solo == 0) 0 else if (solo == 1) 0 else 1; // {0,1} or {0,2} default
                    if (solo == 1) pc = 0 else if (solo == 2) pc = 1;
                }
                const ga = loc2glob[pairs[pc][0]];
                const gb = loc2glob[pairs[pc][1]];
                // primary at ft = our window label
                var prim: i32 = -1;
                for (0..n) |i| {
                    if (spk[i] < 0) continue;
                    if (ft >= t0[i] and ft < t0[i] + seg_sec) {
                        prim = spk[i];
                        break;
                    }
                }
                if (prim == DIAR_UNK_ID) prim = -1; // Unknown never gets overlap attribution
                if (prim >= 0) { // a 2nd speaker only ON TOP of an asserted 1st
                    if (ga >= 0 and ga != prim) sec = ga;
                    if (gb >= 0 and gb != prim and (sec < 0 or ga == prim)) sec = gb;
                }
            }
            if (sec >= 0 and sec == run_sec) {
                run_e = ft + 0.017;
            } else {
                if (run_sec >= 0 and run_e - run_s >= 0.1)
                    n_ov += try emitOverlapRow(&rttm, file_id, run_s, run_e, run_sec);
                run_sec = sec;
                run_s = ft;
                run_e = ft + 0.017;
            }
        }
        if (run_sec >= 0 and run_e - run_s >= 0.1)
            n_ov += try emitOverlapRow(&rttm, file_id, run_s, run_e, run_sec);
    }
    if (n_ov > 0) try out.print("  [osd] {d} overlap 2nd-speaker rows (local-track identity)\n", .{n_ov});
        try out.print("  → {d} speaker(s) ({d}/{d} speech segments)\n", .{ nspk, m, n });
        evDiar(@intCast(nspk), ev_sil, ev_sep, ev_tau, m);

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
            if (line.items.len > 0) { try out.print("  [{d:.2}s] Speaker {d}:{s}\n", .{ cur_t, cur, line.items }); evSpeakerSeg(cur_t, cur, line.items); }
            line.clearRetainingCapacity();
            cur = sp; cur_t = w.t;
        }
        try line.appendSlice(w.txt); // txt already has a leading space for word starts
    }
    if (line.items.len > 0) { try out.print("  [{d:.2}s] Speaker {d}:{s}\n", .{ cur_t, cur, line.items }); evSpeakerSeg(cur_t, cur, line.items); }
}
// Word timestamps via DTW over the alignment-head cross-attention (d_ca already
// averages Whisper-turbo align heads {2,4}{2,11}{3,3}{3,6}{3,11}{3,14}). This is
// the canonical Whisper word-alignment method and replaces the old per-token
// argmax, which picked each token's peak independently (non-monotonic → time
// inversions). DTW finds one monotonic token→frame path maximizing total
// attention, so every token's onset is strictly ordered. Frame = 20 ms.
fn vadWorker(vm: *vad.Model, samples_: []const f32, probs: []f32, np: *usize) void {
    np.* = vm.detect(samples_, probs);
}

fn osdWorker(om: *const osd.Model, samples_: []const f32, logp: []f32, nf: *usize) void {
    nf.* = om.forward(alloc, samples_, logp) catch 0;
}

// 2nd-speaker overlap row, clipped to the silero speech intervals — OSD fires
// on music/crowd too (tucrg 232→462% when rows bypassed the speech gate)
fn emitOverlapRow(rttm: *std.ArrayList(u8), file_id: []const u8, a: f32, b: f32, sp: i32) !usize {
    var n: usize = 0;
    if (g_vad_iv.items.len == 0) {
        try rttm.writer().print("SPEAKER {s} 1 {d:.3} {d:.3} <NA> <NA> spk{d} <NA> <NA>\n", .{ file_id, a, b - a, sp });
        return 1;
    }
    for (g_vad_iv.items) |iv| {
        const lo = @max(a, iv[0]);
        const hi = @min(b, iv[1]);
        if (hi - lo >= 0.1) {
            try rttm.writer().print("SPEAKER {s} 1 {d:.3} {d:.3} <NA> <NA> spk{d} <NA> <NA>\n", .{ file_id, lo, hi - lo, sp });
            n += 1;
        }
    }
    return n;
}

// Emit "<tag> <t> <id> <dur>" for each silero speech piece of the 1.5 s diar
// window at gt; falls back to the whole window when no VAD intervals exist.
fn emitClippedSpk(out: anytype, tag: []const u8, gt: f32, id: u32, margin: f32) !void {
    // 5th field = acoustic margin (best−second centroid cosine) — the app's
    // fusion gate (S3): only low-margin lines may be relabeled by the LLM.
    // Extra fields are ignored by the runner's awk (backward compatible).
    if (g_vad_iv.items.len == 0) {
        try out.print("{s} {d:.2} {d} 1.50 {d:.2}\n", .{ tag, gt, id, margin });
        return;
    }
    for (g_vad_iv.items) |iv| {
        const lo = @max(gt, iv[0]);
        const hi = @min(gt + 1.5, iv[1]);
        if (hi - lo >= 0.1)
            try out.print("{s} {d:.2} {d} {d:.2} {d:.2}\n", .{ tag, lo, id, hi - lo, margin });
    }
}

// Live-session OSD overlap emission: same local-track identity as the
// file-mode diarizeEmb block, but against the FLUSH-relabeled 1.5 s windows;
// emits "SPKOV <t> <global_id> <dur>" pieces clipped to silero speech.
fn emitOsdOverlap(out: anytype, t0s: []const f32, ids: []const i32) !void {
    if (g_osd_win.items.len == 0) return;
    const osd_thr = envF("OSD_THR", 0.25);
    const pairs = [3][2]usize{ .{ 0, 1 }, .{ 0, 2 }, .{ 1, 2 } };
    var n_ov: usize = 0;
    for (g_osd_win.items) |*w| {
        var votes: [3][16]u32 = .{ .{0} ** 16, .{0} ** 16, .{0} ** 16 };
        for (0..w.nf) |fi| {
            const c = w.cls[fi];
            if (c < 1 or c > 3) continue; // solo classes vote
            const ft = w.t + (@as(f32, @floatFromInt(osd.RFIELD)) / 2.0 + @as(f32, @floatFromInt(fi * osd.SHIFT))) / 16000.0;
            for (t0s, 0..) |t0, i| {
                if (ft >= t0 and ft < t0 + 1.5) {
                    const g: usize = @intCast(@max(ids[i], 0));
                    if (g < 16) votes[c - 1][g] += 1;
                    break;
                }
            }
        }
        var loc2glob: [3]i32 = .{ -1, -1, -1 };
        for (0..3) |k| {
            var bg: usize = 0;
            for (1..16) |g| {
                if (votes[k][g] > votes[k][bg]) bg = g;
            }
            if (votes[k][bg] >= 3) loc2glob[k] = @intCast(bg);
        }
        var run_s: f32 = -1;
        var run_e: f32 = -1;
        var run_sec: i32 = -1;
        for (0..w.nf) |fi| {
            const ft = w.t + (@as(f32, @floatFromInt(osd.RFIELD)) / 2.0 + @as(f32, @floatFromInt(fi * osd.SHIFT))) / 16000.0;
            var sec: i32 = -1;
            if (w.pov[fi] >= osd_thr) {
                const pc: usize = if (w.cls[fi] >= 4) w.cls[fi] - 4 else 0;
                const ga = loc2glob[pairs[pc][0]];
                const gb = loc2glob[pairs[pc][1]];
                var prim: i32 = -1;
                for (t0s, 0..) |t0, i| {
                    if (ft >= t0 and ft < t0 + 1.5) {
                        prim = ids[i];
                        break;
                    }
                }
                if (prim >= 0) {
                    if (ga >= 0 and ga != prim) sec = ga;
                    if (gb >= 0 and gb != prim and (sec < 0 or ga == prim)) sec = gb;
                }
            }
            if (sec >= 0 and sec == run_sec) {
                run_e = ft + 0.017;
            } else {
                if (run_sec >= 0 and run_e - run_s >= 0.1)
                    n_ov += try emitOvPieces(out, run_s, run_e, run_sec);
                run_sec = sec;
                run_s = ft;
                run_e = ft + 0.017;
            }
        }
        if (run_sec >= 0 and run_e - run_s >= 0.1)
            n_ov += try emitOvPieces(out, run_s, run_e, run_sec);
    }
    if (n_ov > 0) try out.print("[osd] {d} live overlap rows\n", .{n_ov});
}

fn emitOvPieces(out: anytype, a: f32, b: f32, sp: i32) !usize {
    var n: usize = 0;
    if (g_vad_iv.items.len == 0) {
        try out.print("SPKOV {d:.2} {d} {d:.2}\n", .{ a, sp, b - a });
        return 1;
    }
    for (g_vad_iv.items) |iv| {
        const lo = @max(a, iv[0]);
        const hi = @min(b, iv[1]);
        if (hi - lo >= 0.1) {
            try out.print("SPKOV {d:.2} {d} {d:.2}\n", .{ lo, sp, hi - lo });
            n += 1;
        }
    }
    return n;
}

// Repeat-loop collapse detector: greedy no-ts decoding can lock into a
// periodic token loop on hard audio ("Q. Q. Q."×55 — clova 5/99 chunks).
// Periodicity test: a run of ≥max(16, 4p) positions with tok[i]==tok[i-p]
// at any period p ≤ 8 is far beyond natural repetition (backchannels ≈ 3-4).
fn tokenCollapse(toks: []const u32) bool {
    var p: usize = 1;
    while (p <= 8) : (p += 1) {
        if (toks.len < p + 16) break;
        var run: usize = 0;
        for (p..toks.len) |i| {
            if (toks[i] == toks[i - p]) {
                run += 1;
                if (run >= @max(16, 4 * p)) return true;
            } else run = 0;
        }
    }
    // sentence-length loops (STATUS backlog "repeat-loop hallucination"): a
    // whole sentence (~9-48 BPE tokens) repeating verbatim escapes the short-
    // period net above. Require run ≥ 2p = two EXTRA full periods (≥3 total
    // occurrences) so a genuine once-repeated sentence is spared; a decode
    // stuck in a loop repeats far more (FLEURS 1728: ~12×, escaped p≤8).
    p = 9;
    while (p <= 48) : (p += 1) {
        if (toks.len < 3 * p) break;
        var run: usize = 0;
        for (p..toks.len) |i| {
            if (toks[i] == toks[i - p]) {
                run += 1;
                if (run >= 2 * p) return true;
            } else run = 0;
        }
    }
    return false;
}

// MUTATION-TOLERANT loop detector (2026-07-13 폭파 후속): the NRNG window ban
// forces a stuck decode to VARY each period ("이 시각 세계였습니다"→"시각
// 세계였습니다") — tokenCollapse's exact-match runs reset at every mutation and
// the loop commits. Whisper's own compression-ratio gate catches this class;
// the equivalent token-level signal is 4-GRAM DIVERSITY: distinct 4-grams /
// total. A looped segment reuses the same few 4-grams (screenshot loop ≈0.12)
// while real speech is near 1.0. Threshold LOOP_DIV_TAU (default 0.35) fires
// only on heavy reuse; segments under 24 text tokens are exempt (too little
// signal — and a short genuine repeat is legitimate). Zero-alloc: fixed
// open-addressed table (947 slots ≫ 445 max 4-grams).
fn tokenDiversityCollapse(toks: []const u32) bool {
    if (toks.len < 24) return false;
    var table = [_]u64{0} ** 947;
    var distinct: usize = 0;
    const total = toks.len - 3;
    for (0..total) |i| {
        var h: u64 = 0xcbf29ce484222325;
        for (0..4) |k| {
            h ^= toks[i + k];
            h *%= 0x100000001b3;
        }
        if (h == 0) h = 1; // 0 marks an empty slot
        var s: usize = @intCast(h % table.len);
        while (table[s] != 0 and table[s] != h) s = (s + 1) % table.len;
        if (table[s] == 0) { table[s] = h; distinct += 1; }
    }
    const ratio = @as(f32, @floatFromInt(distinct)) / @as(f32, @floatFromInt(total));
    return ratio < envF("LOOP_DIV_TAU", 0.35);
}

// 1 ms-hop energy envelope: mean |x| over a ±2 ms window (whisper.cpp
// get_signal_energy parity, half-window 32 samples). Returns #entries.
fn energyEnvelope(s: []const f32, env: []f32) usize {
    const HOP: usize = 16; // 1 ms @ 16 kHz
    const HW: usize = 32; // ±2 ms
    if (s.len < HOP) return 0;
    const n = @min(s.len / HOP, env.len);
    for (0..n) |i| {
        const c = i * HOP;
        const lo = if (c >= HW) c - HW else 0;
        const hi = @min(c + HW + 1, s.len);
        var sum: f32 = 0;
        for (s[lo..hi]) |x| sum += @abs(x);
        env[i] = sum / @as(f32, @floatFromInt(hi - lo));
    }
    return n;
}

fn wordTimestamps(out: anytype, bpe_path: []const u8, ca: [*]f32, out_tokens: []const u32, n_text: u32, seed_len: u32, t_off: f32, got_samples: usize, env: []const f32, conf_buf: [*]const f32) !void {
    const SL: usize = seed_len; // this pass's seed length (prompt + sot/lang/task)
    const toks = try loadBpe(bpe_path);
    const E: usize = ENC_SEQ;
    // ts-token decoding interleaves <|t|> tokens with text: the DTW alignment
    // runs over TEXT tokens only (wcpp strips them the same way). tpos[k] =
    // generated-stream index of the k-th text token; its emitting attention
    // row is position SEED.len-1+tpos[k].
    var tpos = std.ArrayList(usize).init(alloc);
    defer tpos.deinit();
    for (0..n_text) |i| {
        if (out_tokens[SL + i] < 50257) try tpos.append(i);
    }
    const N: usize = tpos.items.len;
    if (N == 0) {
        try out.print("\n=== WORD TIMESTAMPS ===\n", .{});
        return;
    }
    // OpenAI/wcpp keep one extra row: the attention of the step AFTER the
    // last text token (it emits the closing <|t|>/eot — that step ran, the
    // row exists). It takes the forced DTW endpoint so the last word ends
    // where the boundary's attention begins, not at the final frame.
    const NR: usize = N + 1;
    // Clip to the chunk's ACTUAL audio frames (320 samples = 20 ms per encoder
    // frame); letting the DTW path wander into the zero-padding region skewed
    // onsets late (acoustic referee: ~+350 ms before this fix).
    const F: usize = @max(@min((got_samples + 319) / 320, E), 8);

    // DIAG: dump per-position raw-attention argmax (env TS_DIAG=1) — which row
    // convention holds each word's acoustic location?
    if (std.posix.getenv("TS_DIAG") != null) {
        try out.print("[ts-diag] pos: argmax_t(s) (avg over heads, raw)\n", .{});
        for (0..n_text + SL) |p| {
            var bj: usize = 0;
            var bv: f32 = -1e30;
            for (0..F) |j| {
                var v: f32 = 0;
                for (0..6) |h| v += ca[(h * MAX_TOK + p) * E + j];
                if (v > bv) { bv = v; bj = j; }
            }
            try out.print("[ts-diag] p={d}: {d:.2}s\n", .{ p, @as(f32, @floatFromInt(bj)) * 0.02 });
        }
    }
    // OpenAI timing pipeline, per alignment head (planes from ca_accumulate):
    // z-normalize each head's [N×F] across TOKENS per frame → median-7 over
    // frames → average heads. Normalizing per head BEFORE averaging matters —
    // the averaged-matrix shortcut was reverse-verified worse.
    const NAL: usize = 6;
    const filtered = try alloc.alloc(f32, NR * F); // head-averaged, normalized+filtered
    defer alloc.free(filtered);
    @memset(filtered, 0);
    const work = try alloc.alloc(f32, NR * F);
    defer alloc.free(work);
    const rawavg = try alloc.alloc(f32, NR * F); // pre-norm attention (for onset snap)
    defer alloc.free(rawavg);
    @memset(rawavg, 0);
    const inv_h: f32 = 1.0 / @as(f32, @floatFromInt(NAL));
    for (0..NAL) |h| {
        for (0..NR) |i| {
            // OFF-BY-ONE: the attention that EMITS a token lives at the decode
            // position BEFORE it (query = previous token; logits → the token).
            // Row N (the extra anchor) = the step after the last text token.
            const gi: usize = if (i < N) tpos.items[i] else tpos.items[N - 1] + 1;
            const row = ca[(h * MAX_TOK + SL - 1 + gi) * E ..][0..F];
            @memcpy(work[i * F ..][0..F], row);
            for (0..F) |j| rawavg[i * F + j] += row[j] * inv_h;
        }
        // per-frame z-norm across tokens (ggml_norm / torch.std_mean dim=-2).
        // wcpp/OpenAI take the stats over ALL rows of the alignment pass —
        // seed (sot/lang/task) rows included — then slice; match that.
        const NP: usize = SL + n_text; // positions 0..NP-1 exist in the ca planes
        if (NR >= 2) {
            for (0..F) |j| {
                var mu: f32 = 0;
                for (0..NP) |p| mu += ca[(h * MAX_TOK + p) * E + j];
                mu /= @floatFromInt(NP);
                var va: f32 = 0;
                for (0..NP) |p| { const d = ca[(h * MAX_TOK + p) * E + j] - mu; va += d * d; }
                const sd = @sqrt(va / @as(f32, @floatFromInt(NP))) + 1e-9;
                for (0..NR) |i| work[i * F + j] = (work[i * F + j] - mu) / sd;
            }
        }
        // median-7 over frames per token row, accumulate the head average
        var win: [7]f32 = undefined;
        for (0..NR) |i| {
            const row = work[i * F ..][0..F];
            for (0..F) |j| {
                for (0..7) |w| {
                    const jj = @as(isize, @intCast(j)) + @as(isize, @intCast(w)) - 3;
                    const jc: usize = @intCast(@max(@min(jj, @as(isize, @intCast(F - 1))), 0));
                    win[w] = row[jc];
                }
                for (1..7) |a| {
                    const v = win[a];
                    var b = a;
                    while (b > 0 and win[b - 1] > v) : (b -= 1) win[b] = win[b - 1];
                    win[b] = v;
                }
                filtered[i * F + j] += win[3] * inv_h;
            }
        }
    }

    // Phase 2: classic DTW over [N×F] with FORCED endpoints (0,0)→(N-1,F-1),
    // matching OpenAI/whisper.cpp. The path must cover every frame, so token
    // boundaries land at attention TRANSITIONS (≈ acoustic onsets) instead of
    // each token parking at its attention peak — the free-endpoint version was
    // measured ~+350 ms late (peaks sit mid-word).
    const score = try alloc.alloc(f32, NR * F);
    defer alloc.free(score);
    score[0] = filtered[0];
    for (1..F) |j| score[j] = score[j - 1] + filtered[j]; // token 0 covers the prefix
    for (1..NR) |i| {
        score[i * F] = score[(i - 1) * F] + filtered[i * F]; // frame-0 column (degenerate)
        for (1..F) |j| {
            var m = score[(i - 1) * F + j]; // ↑ same frame, previous token
            const d = score[(i - 1) * F + j - 1]; // ↖ advance frame + token
            if (d > m) m = d;
            const l = score[i * F + j - 1]; // ← advance frame, same token
            if (l > m) m = l;
            score[i * F + j] = m + filtered[i * F + j];
        }
    }

    // Phase 3: backtrace from the forced terminal (NR-1, F-1) → per-token
    // onsets. Row N (eot) takes the terminal; its onset = last word's END.
    const ts_frame = try alloc.alloc(u32, NR);
    defer alloc.free(ts_frame);
    var ci: usize = NR - 1;
    var cj: usize = F - 1;
    while (true) {
        ts_frame[ci] = @intCast(cj); // revisited right→left; final value = token onset
        if (ci == 0 and cj == 0) break;
        if (ci == 0) { cj -= 1; continue; } // only ← remains
        if (cj == 0) { ci -= 1; continue; } // only ↑ remains
        var ni = ci - 1; var nj = cj; var m = score[(ci - 1) * F + cj]; // ↑
        if (score[(ci - 1) * F + cj - 1] > m) { m = score[(ci - 1) * F + cj - 1]; ni = ci - 1; nj = cj - 1; } // ↖
        if (score[ci * F + cj - 1] > m) { ni = ci; nj = cj - 1; } // ←
        ci = ni; cj = nj;
    }

    // Onset snap: within each token's path segment [onset, next_onset), move the
    // onset forward to the first frame reaching 50% of the segment's attention
    // peak. Fixes boundaries that drift early into pauses (the DTW must split
    // silent stretches somewhere); stays inside the segment → monotonicity kept.
    for (0..N) |i| {
        const j0: usize = ts_frame[i];
        const j1: usize = @max(@as(usize, ts_frame[i + 1]), j0 + 1); // i+1 ≤ N (eot row bounds the last word)
        if (j1 <= j0 + 1) continue;
        var peak: f32 = -1e30;
        for (j0..j1) |j| peak = @max(peak, rawavg[i * F + j]);
        const thr = peak * 0.15;
        var js: usize = j0;
        while (js + 1 < j1 and rawavg[i * F + js] < thr) js += 1;
        // only correct PAUSES: apply when the sub-threshold stretch is ≥200 ms
        // (10 frames) (8 frames = 160 ms) — normal word onsets stay at the DTW boundary.
        if (std.posix.getenv("TS_NOATTSNAP") == null and js - j0 >= 8) ts_frame[i] = @intCast(js);
    }

    // group BPE sub-words into words (space-prefixed token = new word),
    // keeping each word's DTW span [onset, next word's onset) in 1 ms units
    const WSpan = struct { s0: usize, s1: usize, txt: []u8, conf: f32 };
    var words = std.ArrayList(WSpan).init(alloc);
    defer words.deinit();
    var word = std.ArrayList(u8).init(alloc);
    var w_first: usize = 0; // first TEXT-token index of the open word
    var wconf: f32 = 1e30; // min metric over the open word's tokens (lower=uncertain; 1e30 so any metric range works)
    for (0..N) |i| {
        const ti = SL + tpos.items[i];
        const tok_bytes = if (out_tokens[ti] < toks.len) toks[out_tokens[ti]] else "";
        const starts_word = tok_bytes.len > 0 and tok_bytes[0] == ' ';
        if (starts_word and word.items.len > 0) {
            try words.append(.{ .s0 = @as(usize, ts_frame[w_first]) * 20, .s1 = @as(usize, ts_frame[i]) * 20, .txt = try alloc.dupe(u8, word.items), .conf = wconf });
            word.clearRetainingCapacity();
            wconf = 1e30;
        }
        if (word.items.len == 0) w_first = i;
        try word.appendSlice(tok_bytes);
        wconf = @min(wconf, conf_buf[ti]); // word conf = min over its subword tokens
    }
    if (word.items.len > 0)
        try words.append(.{ .s0 = @as(usize, ts_frame[w_first]) * 20, .s1 = @as(usize, ts_frame[N]) * 20, .txt = try alloc.dupe(u8, word.items), .conf = wconf });

    // Energy snap (whisper.cpp exp_compute_token_level_timestamps VAD parity):
    // snap word ONSETS to acoustic voice edges (judged against the raw-wave
    // voiced-region table, NOT whisper.cpp — its console heuristic provably
    // drops onsets into silence, e.g. jfk "And" at 0.10s vs voice at 0.33s).
    // thold = 0.5 × mean envelope around the word (local → soft words OK).
    //   onset in silence → the DTW boundary fell in a pause: snap RIGHT to
    //                      the voice onset.
    //   onset mid-voice  → if this voiced region STARTS after the previous
    //                      word's onset, the region is this word's own and
    //                      DTW was late: snap LEFT to the region start.
    //                      Otherwise the region is shared with the previous
    //                      word (continuous speech): keep DTW — energy can't
    //                      split words inside one voiced run.
    if (env.len > 8) {
        const ne = env.len;
        // CHUNK-global threshold. A word-local window gets inflated by loud
        // neighbors (jfk "so," tail read as silence next to "my fellow…"),
        // while the chunk mean classified every jfk boundary correctly.
        var gmean: f32 = 0;
        for (env) |e| gmean += e;
        gmean /= @floatFromInt(ne);
        const thold = 0.5 * gmean;
        var prev_onset: usize = 0;
        for (words.items, 0..) |*w, wi| {
            var s0 = @min(w.s0, ne - 1);
            const s1 = @min(@max(w.s1, s0 + 1), ne - 1);
            if (env[s0] > thold) {
                var k = s0;
                while (k > 0 and env[k - 1] > thold) k -= 1;
                if (wi == 0 or k > prev_onset) s0 = k;
            } else if (env[s0] < 0.5 * thold) {
                // clearly silent (hysteresis: 0.25×mean — soft speech between
                // 0.25 and 0.5 is ambiguous and keeps its DTW onset). Cap the
                // jump at 400 ms: a longer "pause" is more likely sustained
                // soft speech under the global threshold than a DTW miss.
                var k = s0;
                while (k < s1 and env[k] < thold) k += 1;
                if (k - s0 <= 400) s0 = k;
            }
            if (wi > 0 and s0 <= prev_onset) s0 = @min(prev_onset + 1, ne - 1);
            w.s0 = s0;
            w.s1 = @max(@min(w.s1, ne - 1), s0 + 1);
            prev_onset = s0;
        }
        // word ENDS: a word's end is the next word's REFINED onset (continuous
        // speech) — but when that boundary follows a pause, contract LEFT to
        // the last voiced moment so .srt lines stop when the voice stops.
        // Probe 10 ms before the boundary (the boundary itself may BE the
        // next word's rising edge).
        for (words.items, 0..) |*w, wi| {
            if (wi + 1 < words.items.len)
                w.s1 = @max(@min(words.items[wi + 1].s0, ne - 1), w.s0 + 1);
            // probe = min envelope in the 40-10 ms window before the boundary
            // (a single point can land on the next word's rising edge)
            const plo = if (w.s1 > w.s0 + 40) w.s1 - 40 else w.s0;
            const phi = if (w.s1 > w.s0 + 10) w.s1 - 10 else w.s1;
            var probe: f32 = 1e30;
            for (plo..@max(phi, plo + 1)) |j| probe = @min(probe, env[j]);
            if (probe < 0.5 * thold) {
                const bound = w.s1; // next word's refined onset (or eot edge)
                var k = w.s1 - 1;
                while (k > w.s0 and env[k] < thold) k -= 1;
                w.s1 = k + 1;
                // soft words can sit entirely sub-threshold → keep ≥80 ms
                if (w.s1 < w.s0 + 80) w.s1 = @min(w.s0 + 80, bound);
            }
        }
    }

    const conf_on = std.posix.getenv("CONF") != null; // validation dump
    // App file mode: the FIRST word of each chunk has no left context, so its
    // confidence is a diffuse-prior artifact (e.g. "Right «conf 0.07»"), not real
    // uncertainty. Omit its conf so the app doesn't paint it amber (absent conf
    // ⇒ app treats as 1.0). Gated on APP_FILE → CLI/bench output unchanged.
    const app_file = std.posix.getenv("APP_FILE") != null;
    try out.print("\n=== WORD TIMESTAMPS ===\n", .{});
    for (words.items, 0..) |w, i| {
        const ts: f32 = t_off + @as(f32, @floatFromInt(w.s0)) * 0.001;
        const te: f32 = t_off + @as(f32, @floatFromInt(w.s1)) * 0.001;
        if (conf_on and !(app_file and i == 0)) {
            try out.print("  [{d:.2}s-{d:.2}s] {s}  «conf {d:.2}»\n", .{ ts, te, w.txt, w.conf });
        } else {
            try out.print("  [{d:.2}s-{d:.2}s] {s}\n", .{ ts, te, w.txt });
        }
        evWord(ts, te, w.txt, w.conf, -1); // spk resolved later via spk_seg (diar runs after decode)
        try g_words.append(.{ .t = ts, .txt = w.txt });
    }
}

var g_bpe_cache: ?[][]const u8 = null;
fn loadBpe(path: []const u8) ![][]const u8 {
    if (g_bpe_cache) |c| return c; // load the 64 MB vocab once (per-word/partial decode reuse)
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
    g_bpe_cache = toks;
    return toks;
}

// Greedy longest-match byte-level BPE encoder (text → token ids). The vocab
// stores raw UTF-8 bytes (bpeDecode appends them verbatim), so encoding is a
// straight longest-prefix match against the vocab — Korean included. Not a true
// merge-rank BPE, but term-biasing prompts are forgiving: the goal is to seed
// the jargon's tokens into context, and a near-tokenization biases just as well.
fn bpeEncode(path: []const u8, text: []const u8) ![]u32 {
    const toks = try loadBpe(path);
    var map = std.StringHashMap(u32).init(alloc);
    var maxlen: usize = 1;
    for (toks, 0..) |tk, i| {
        if (i >= 50257 or tk.len == 0) continue; // text tokens only (skip specials)
        try map.put(tk, @intCast(i));
        if (tk.len > maxlen) maxlen = tk.len;
    }
    var out = std.ArrayList(u32).init(alloc);
    var i: usize = 0;
    while (i < text.len) {
        var matched = false;
        var L = @min(maxlen, text.len - i);
        while (L >= 1) : (L -= 1) {
            if (map.get(text[i .. i + L])) |id| { try out.append(id); i += L; matched = true; break; }
        }
        if (!matched) i += 1; // unencodable byte — skip
    }
    return out.toOwnedSlice();
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
    try mtl.dispatch(f, .{ (vocab + 7) / 8, 1, 1 }, .{ 256, 1, 1 }, &p, &s); // NR0=4 → 32 vocab/tg
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
// Loudest 1 s window RMS over the chunk ([-1,1]; speech≈0.14, ambient≲0.001).
// Used both for the silence-skip VAD and the near-silence hallucination guard.
fn maxWinRms(samples: []const f32, got: usize) f32 {
    const win: usize = 16000; // 1 s @ 16 kHz
    var mx: f32 = 0;
    var i: usize = 0;
    while (i < got) : (i += win) {
        const end = @min(i + win, got);
        var s: f64 = 0;
        for (samples[i..end]) |x| s += @as(f64, x) * @as(f64, x);
        const r: f32 = @floatCast(@sqrt(s / @as(f64, @floatFromInt(end - i))));
        if (r > mx) mx = r;
    }
    return mx;
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
fn kArgmaxConf(f: mtl.Function, logits: [*]f32, toks: [*]u32, conf: [*]f32, pos: [*]u32, max_len: u32) !void {
    var a0 = logits; var a1 = toks; var a2 = conf; var a3 = pos; var ml = max_len;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&a2), P(&a3), P(&ml) };
    const s = [_]usize{ PS, PS, PS, PS, U };
    try mtl.dispatch(f, .{ 1, 1, 1 }, .{ 1024, 1, 1 }, &p, &s);
}
fn kFilt(f: mtl.Function, logits: [*]f32, toks: [*]u32, pos: [*]u32, sample_begin: u32, nrng: u32) !void {
    var a0 = logits; var a1 = toks; var ns: u32 = 0; var a3 = pos; var sb = sample_begin; var nr = nrng;
    const p = [_]?*const anyopaque{ P(&a0), P(&a1), P(&ns), P(&a3), P(&sb), P(&nr) };
    const s = [_]usize{ PS, PS, U, PS, U, U };
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
    const toks = try loadBpe(path); // cached vocab (no per-call 64 MB reload)
    var buf = std.ArrayList(u8).init(alloc);
    for (ids) |id| {
        if (id >= 50257) continue; // strip EOT/specials/timestamp tokens
        if (id < toks.len) try buf.appendSlice(toks[id]);
    }
    return buf.items;
}
