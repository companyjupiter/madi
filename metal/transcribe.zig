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
var g_vad_iv = std.ArrayList([2]f32).init(alloc); // silero speech intervals (global s) — clips diar segments to speech
var g_osd_iv = std.ArrayList([2]f32).init(alloc); // pyannote OSD overlap intervals (global s) — 2nd-speaker emission
const OsdWin = struct { t: f32, nf: u32, cls: [600]u8, pov: [600]f32 }; // one 10s model window: argmax class + P(overlap) per frame
var g_osd_win = std.ArrayList(OsdWin).init(alloc);

fn keyL(buf: []u8, comptime fmt: []const u8, l: usize) []const u8 {
    return std.fmt.bufPrint(buf, fmt, .{l}) catch unreachable;
}

// ── in-process online speaker clustering (resident; folds in online_diar) ────
// A persistent centroid set kept in memory across stream segments, so the SAME
// voice keeps the SAME id for the whole session without an external process or
// state file. centroid direction = normalize(sum of L2-normalized embeddings).
const DiarCentroid = struct { count: u32, sum: [diar.EMB]f32 };
fn diarAssign(cents: *std.ArrayList(DiarCentroid), v: []f32, sim_thr: f32, max_k: u32) !usize {
    var s: f64 = 0;
    for (v) |x| s += @as(f64, x) * x;
    const nrm: f32 = @floatCast(@sqrt(s) + 1e-9);
    for (v) |*x| x.* /= nrm; // unit-length
    var best: f32 = -2;
    var best_i: usize = 0;
    for (cents.items, 0..) |*c, i| {
        var dot: f64 = 0;
        var cs: f64 = 0;
        for (0..diar.EMB) |k| {
            dot += @as(f64, v[k]) * c.sum[k];
            cs += @as(f64, c.sum[k]) * c.sum[k];
        }
        const sim: f32 = @floatCast(dot / (@sqrt(cs) + 1e-9));
        if (sim > best) { best = sim; best_i = i; }
    }
    if (cents.items.len == 0 or (best < sim_thr and cents.items.len < max_k)) {
        const spk = cents.items.len; // birth a new speaker
        var c: DiarCentroid = .{ .count = 1, .sum = undefined };
        for (0..diar.EMB) |k| c.sum[k] = v[k];
        try cents.append(c);
        return spk;
    }
    var c = &cents.items[best_i];
    for (0..diar.EMB) |k| c.sum[k] += v[k];
    c.count += 1;
    return best_i;
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
    const f_filt_plain = try mtl.getFunction("logit_filter_indirect"); // no-ts greedy (default; best code-switch fidelity)
    const f_filt_ts = try mtl.getFunction("ts_rules_indirect"); // ts-token decode (collapse-rescue mode)
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
    // default ON in file mode (OSD=0 disables); live/stream stays off (latency)
    const osd_on = std.posix.getenv("STREAM") == null and !std.mem.eql(u8, std.posix.getenv("OSD") orelse "1", "0");
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

    // ── encoder scratch (F16 activations, reused per chunk) ─────────
    const escr = enc.Scratch{
        .x_ln = (try mtl.allocSlice(f16, EB * ENC_SEQ * D)).ptr,
        .qkv = (try mtl.allocSlice(f16, 3 * EB * ENC_SEQ * D)).ptr,
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
        .ca_sc = (try mtl.allocSlice(f32, dec.NH * ENC_SEQ)).ptr, // 20×1500 normalized scores
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
    const head_base = [dec.NL]u32{ 0, 0, 0, 2 }; // plane offset per layer (cumulative align heads)
    const inv_n: f32 = 1.0 / 6.0;
    // Per-head alignment planes [NALIGN][MAX_TOK][ENC_SEQ] — kept separate so
    // wordTimestamps can z-normalize each head BEFORE averaging (OpenAI timing
    // semantics; normalizing the averaged matrix is NOT equivalent — verified).
    const NALIGN: usize = 6;
    const d_ca = try mtl.allocSlice(f32, NALIGN * MAX_TOK * ENC_SEQ);
    @memset(d_ca, 0);

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
    var live_emb = std.ArrayList(f32).init(alloc); // accepted windows, unit-normalized
    var live_ids = std.ArrayList(u8).init(alloc); // each window's emitted stable id
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
    // hallucination guard: Whisper invents words ("Oh my", "Okay okay") in near-
    // silent / ambient stretches. Drop a segment's text when the loudest 1 s
    // window is below HALLU_RMS — a *strong* utterance (shouting "아아아") has
    // high RMS and is always kept. Off with HALLU_GUARD=0.
    const hallu_guard = !std.mem.eql(u8, std.posix.getenv("HALLU_GUARD") orelse "1", "0");
    const hallu_rms = envF("HALLU_RMS", 0.020);
    const vad_thresh = envF("VAD_THRESH", 0.010);
    if (stream) try out.print("[stream] ready (model resident; feed '<offset> <wav>' lines on stdin)\n", .{});
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
                    for (vp_claimed.items) |c| { if (c) nclaim += 1; }
                    try liveRecluster(&cents, live_emb.items, live_ids.items, diar_max, diar_k, nclaim, null);
                    // normalized centroid directions; reassign against ALL ids —
                    // restricting to final-kmeans ids was reverse-verified worse
                    // (stale centroids absorb coherent subsets; md-eval -3.7pt)
                    const nc = cents.items.len;
                    const dirs = try alloc.alloc(f32, nc * diar.EMB);
                    defer alloc.free(dirs);
                    for (cents.items, 0..) |*c, sidx| {
                        var ss: f32 = 0;
                        for (c.sum) |x| ss += x * x;
                        const inv = 1.0 / (@sqrt(ss) + 1e-9);
                        for (0..diar.EMB) |d| dirs[sidx * diar.EMB + d] = c.sum[d] * inv;
                    }
                    for (0..mwin) |i| {
                        const v = live_emb.items[i * diar.EMB ..][0 .. diar.EMB];
                        var best: f32 = -2;
                        var bs: usize = 0;
                        for (0..nc) |sidx| {
                            var dt: f32 = 0;
                            for (0..diar.EMB) |d| dt += v[d] * dirs[sidx * diar.EMB + d];
                            if (dt > best) { best = dt; bs = sidx; }
                        }
                        try emitClippedSpk(out, "SPKFIX", live_t0.items[i], @intCast(bs));
                    }
                }
                try out.print("<<FLUSH_END>>\n", .{});
                continue :job;
            }
            const sp = std.mem.indexOfScalar(u8, trimmed, ' ') orelse continue :job;
            g_off = std.fmt.parseFloat(f32, trimmed[0..sp]) catch 0;
            cur_path = std.mem.trim(u8, trimmed[sp + 1 ..], " \t\r");
        }

        const wav = try std.fs.cwd().readFileAlloc(alloc, cur_path, 2 * 1024 * 1024 * 1024);
        defer alloc.free(wav);
        const total = mel.wavTotalSamples(wav);
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
            if (osd_model) |*om| {
                // pyannote OSD on 10 s windows, threaded (≈410 ms each naive;
                // overlaps the diar embed pool + silero below)
                @memset(osd_nf, 0);
                var wi: usize = 0;
                while (wi * OSD_STEP < got and wi < OSD_NW) : (wi += 1) {
                    const s0 = wi * OSD_STEP;
                    const slen = @min(osd.WIN_SAMPLES, got - s0);
                    osd_threads[wi % 4] = try std.Thread.spawn(.{}, osdWorker, .{ om, samples[s0 .. s0 + slen], osd_logp[wi * 600 * osd.N_CLASSES ..][0 .. 600 * osd.N_CLASSES], &osd_nf[wi] });
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
                vad_thread = try std.Thread.spawn(.{}, vadWorker, .{ vm, samples[0..got], vad_probs, &vad_np });
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
                        if (pv >= 0.5) chunk_speech_s += 0.032;
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
                            if (pv >= 0.5) sp_s += 0.032;
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
                        const eff_max: u32 = if (recl_done) @intCast(cents.items.len) else diar_max;
                        const spk = try diarAssign(&cents, cemb[wsg * diar.EMB ..][0 .. diar.EMB], diar_sim, eff_max);
                        // far-field silence inside the 1.5 s grid window was
                        // the live FA driver (live 44.7% vs file 18.8%) —
                        // emit silero-clipped pieces; extra duration field is
                        // ignored by the runner's awk (backward compatible)
                        try emitClippedSpk(out, "SPK", gt, @intCast(spk));
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
                            try live_ids.append(@intCast(@min(spk, 255)));
                            try live_t0.append(gt);
                            live_since += 1;
                            const acc_total = live_emb.items.len / diar.EMB;
                            // first recluster early (8 windows) so short sessions
                            // benefit too; thereafter every recluster_every windows
                            if ((!recl_done and acc_total >= 8) or live_since >= recluster_every) {
                                live_since = 0;
                                var nclaim: usize = 0;
                                for (vp_claimed.items) |c| { if (c) nclaim += 1; }
                                try liveRecluster(&cents, live_emb.items, live_ids.items, diar_max, diar_k, nclaim, null);
                                recl_done = true;
                            }
                        }
                    }
                } else {
                    for (0..nwin) |wsg| {
                        try diar_emb.appendSlice(cemb[wsg * diar.EMB ..][0 .. diar.EMB]);
                        try diar_bm.append(crms[wsg]);
                        try diar_t0.append(t_off + @as(f32, @floatFromInt(wsg)) * SEG_SEC);
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
                if (pv >= 0.5) chunk_speech_s += 0.032;
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
        const seg_rms = maxWinRms(samples, got); // loudest 1 s window, [-1,1] RMS
        if (seg_rms <= vad_thresh or chunk_speech_s < 0.25) {
            if (n_chunks > 1) try out.print("\n[chunk {d}/{d} @ {d:.0}s] ({s} — skipped)\n", .{ chunk + 1, n_chunks, t_off, if (seg_rms <= vad_thresh) @as([]const u8, "silence") else "non-speech" });
            if (got < mel.CHUNK_SAMPLES) { reached_end = true; chunk += 1; break :gather; }
            chunk += 1;
            continue :gather;
        }

        // front-end: mel → Conv1D×2 → enc_input (into this chunk's batch slot)
        mel.melSpectrogram(samples, mel_filters, mel_buf);
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
        slot_conv[nb] = @as(f64, @floatFromInt(ct.read())) / 1e6;
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
        var et = try std.time.Timer.start();
        try enc.forward(Ke, &elayers, elnp_w, elnp_b, d_ex, out_f16, enc_out, escr, nb);
        const enc_ms = @as(f64, @floatFromInt(et.read())) / 1e6 / @as(f64, @floatFromInt(nb));

        // ── Phase C: per-slot cross-KV + decode + timestamps (chronological order)
        for (0..nb) |slot| {
        const t_off = slot_toff[slot];
        const seg_rms2 = slot_rms[slot];
        const conv_ms = slot_conv[slot];
        const cchunk = slot_chunk[slot];
        const cgot = slot_got[slot];
        const eo16 = out_f16 + slot * @as(usize, ENC_SEQ) * D;
        for (0..dec.NL) |l| {
            try mtl.beginCommandBuffer();
            try deqW16(f_deq, cross_wdq, ckw[l], D, D);
            try mtl.matmulF16Batched(eo16, cross_wdq, ckc[l], ENC_SEQ, D, D);
            try deqW16(f_deq, cross_wdq, cvw[l], D, D);
            try mtl.matmulF16Batched(eo16, cross_wdq, cvc[l], ENC_SEQ, D, D);
            try biasAdd16(f_bias16, cvc[l], cvb[l], ENC_SEQ * D, D);
            try mtl.commitCommandBuffer();
            try mtl.sync();
        }

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
        if (lang_tok == 0) {
            d_pos[0] = 0;
            try mtl.beginCommandBuffer();
            try embLookup(f_emb, d_x, tok_emb.qs, tok_emb.scales, &d_tokens[0]);
            try residual(Kd, d_x, dec_pe, D); // pos-0 positional embedding
            for (0..dec.NL) |l| {
                const ca_ctx = dec.CaCtx{ .weights = d_ca.ptr, .tok = d_pos, .heads = layer_heads[l], .inv_n = inv_n, .head_base = head_base[l] };
                try dec.decodeBlock(Kd, dlayers[l], d_x, dscr, skc[l], svc[l], ckc[l], cvc[l], d_pos, ca_ctx);
            }
            try layerNorm(Kd, d_x, dscr.xb, dln_w, dln_b, D);
            try kLogitGemv(f_logit, d_logits, tok_emb.qs, tok_emb.scales, dscr.xb, VOCAB, D);
            try mtl.commitCommandBuffer();
            try mtl.sync();
            var bl: u32 = 50259;
            var bv: f32 = d_logits[50259];
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
        var seek_fr: u32 = 0; // chunk-relative 20 ms frame the CURRENT window starts at
        var pass: u32 = 0;
        seek: while (pass < 6) : (pass += 1) {
            total_passes += 1;
            var PL: u32 = 0;
            d_tokens[PL] = SEED[0]; // sot
            d_tokens[PL + 1] = lang_tok;
            d_tokens[PL + 2] = SEED[2]; // transcribe
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
                        try dec.decodeBlock(Kd, dlayers[l], d_x, dscr, skc[l], svc[l], ckc[l], cvc[l], d_pos, ca_ctx);
                    }
                    try kStep(f_step, d_pos);
                }
                try mtl.commitCommandBuffer();
                try mtl.sync();
            }
            d_pos[0] = PL - 1; // first prediction step
            var n_text: u32 = 0;
            var done = false;
            while (n_text < max_gen and !done) {
                const this_b = @min(DBATCH, max_gen - n_text);
                var rec_t = try std.time.Timer.start();
                try mtl.beginCommandBuffer();
                for (0..this_b) |_| {
                    try kEmbInd(f_emb_ind, d_x, tok_emb.qs, tok_emb.scales, d_tokens.ptr, d_pos);
                    try kPeInd(f_pe_ind, d_x, dec_pe, d_pos);
                    for (0..dec.NL) |l| {
                        const ca_ctx = dec.CaCtx{ .weights = d_ca.ptr, .tok = d_pos, .heads = layer_heads[l], .inv_n = inv_n, .head_base = head_base[l] };
                        try dec.decodeBlock(Kd, dlayers[l], d_x, dscr, skc[l], svc[l], ckc[l], cvc[l], d_pos, ca_ctx);
                    }
                    try layerNorm(Kd, d_x, dscr.xb, dln_w, dln_b, D);
                    try kLogitGemv(f_logit, d_logits, tok_emb.qs, tok_emb.scales, dscr.xb, VOCAB, D);
                    try kSuppress(f_suppress, d_logits, d_suppress.ptr, n_suppress);
                    try kFilt(if (ts_mode) f_filt_ts else f_filt_plain, d_logits, d_tokens.ptr, d_pos, sample_begin);
                    try kStep(f_step, d_pos); // pos += 1
                    try kArgmax(f_argmax, d_logits, d_tokens.ptr, d_pos, MAX_TOK); // tokens[pos] = argmax
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
            }
            n_tok_total += n_text;
            if (!ts_mode and tokenCollapse(out_tokens[PL .. PL + n_text])) {
                ts_mode = true; // discard this pass, re-decode in ts mode
                try out.print("[collapse-rescue] chunk {d}: periodic repeat loop — re-decoding with timestamp tokens\n", .{cchunk + 1});
                continue :mode;
            }
            if (!dropped and n_text > 0) {
                var ht = try std.time.Timer.start();
                const text = try bpeDecode(bpe_path, out_tokens[PL .. PL + n_text]);
                try chunk_text.appendSlice(text);
                const env_off = @min(@as(usize, seek_fr) * 20, senv.len);
                try wordTimestamps(out, bpe_path, d_ca.ptr, out_tokens, n_text, PL, t_off + pass_off, pass_got, senv[env_off..]);
                host_ns += ht.read();
            }
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
            try enc.forward(Ke, &elayers, elnp_w, elnp_b, d_ex + slot * @as(usize, ENC_SEQ) * D, eo16, enc_out + slot * @as(usize, ENC_SEQ) * D, escr, 1);
            for (0..dec.NL) |l| {
                try mtl.beginCommandBuffer();
                try deqW16(f_deq, cross_wdq, ckw[l], D, D);
                try mtl.matmulF16Batched(eo16, cross_wdq, ckc[l], ENC_SEQ, D, D);
                try deqW16(f_deq, cross_wdq, cvw[l], D, D);
                try mtl.matmulF16Batched(eo16, cross_wdq, cvc[l], ENC_SEQ, D, D);
                try biasAdd16(f_bias16, cvc[l], cvb[l], ENC_SEQ * D, D);
                try mtl.commitCommandBuffer();
                try mtl.sync();
            }
            @memset(d_ca, 0);
        }
        break :mode;
        }

        const dec_ms = @as(f64, @floatFromInt(dt2.read() -| host_ns)) / 1e6; // word-DTW/BPE moved inside the loop; keep tok/s comparable
        try out.print("[perf] chunk {d}: conv {d:.0}ms | encoder {d:.0}ms (batch {d}) | decode {d} tok {d:.0}ms ({d:.1} tok/s)  [cpu-rec {d:.0}ms | gpu-sync {d:.0}ms | passes {d}]\n", .{ cchunk + 1, conv_ms, enc_ms, nb, n_tok_total, dec_ms, @as(f64, @floatFromInt(n_tok_total)) / (dec_ms / 1000.0), @as(f64, @floatFromInt(enc_ns)) / 1e6, @as(f64, @floatFromInt(sync_ns)) / 1e6, total_passes });
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
        try diarizeEmb(out, diar_emb.items, diar_bm.items, diar_t0.items, diar_n, SEGD, SEG_SEC, diar_k, rttm_out, file_id);
        try attributeTranscript(out);
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
    const osd_thr = envF("OSD_THR", 0.25); // ES2004a sweep saturates at 0.25 (16.47%)
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
fn emitClippedSpk(out: anytype, tag: []const u8, gt: f32, id: u32) !void {
    if (g_vad_iv.items.len == 0) {
        try out.print("{s} {d:.2} {d} 1.50\n", .{ tag, gt, id });
        return;
    }
    for (g_vad_iv.items) |iv| {
        const lo = @max(gt, iv[0]);
        const hi = @min(gt + 1.5, iv[1]);
        if (hi - lo >= 0.1)
            try out.print("{s} {d:.2} {d} {d:.2}\n", .{ tag, lo, id, hi - lo });
    }
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
    return false;
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

fn wordTimestamps(out: anytype, bpe_path: []const u8, ca: [*]f32, out_tokens: []const u32, n_text: u32, seed_len: u32, t_off: f32, got_samples: usize, env: []const f32) !void {
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
    const WSpan = struct { s0: usize, s1: usize, txt: []u8 };
    var words = std.ArrayList(WSpan).init(alloc);
    defer words.deinit();
    var word = std.ArrayList(u8).init(alloc);
    var w_first: usize = 0; // first TEXT-token index of the open word
    for (0..N) |i| {
        const ti = SL + tpos.items[i];
        const tok_bytes = if (out_tokens[ti] < toks.len) toks[out_tokens[ti]] else "";
        const starts_word = tok_bytes.len > 0 and tok_bytes[0] == ' ';
        if (starts_word and word.items.len > 0) {
            try words.append(.{ .s0 = @as(usize, ts_frame[w_first]) * 20, .s1 = @as(usize, ts_frame[i]) * 20, .txt = try alloc.dupe(u8, word.items) });
            word.clearRetainingCapacity();
        }
        if (word.items.len == 0) w_first = i;
        try word.appendSlice(tok_bytes);
    }
    if (word.items.len > 0)
        try words.append(.{ .s0 = @as(usize, ts_frame[w_first]) * 20, .s1 = @as(usize, ts_frame[N]) * 20, .txt = try alloc.dupe(u8, word.items) });

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

    try out.print("\n=== WORD TIMESTAMPS ===\n", .{});
    for (words.items) |w| {
        const ts: f32 = t_off + @as(f32, @floatFromInt(w.s0)) * 0.001;
        const te: f32 = t_off + @as(f32, @floatFromInt(w.s1)) * 0.001;
        try out.print("  [{d:.2}s-{d:.2}s] {s}\n", .{ ts, te, w.txt });
        try g_words.append(.{ .t = ts, .txt = w.txt });
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
        if (id >= 50257) continue; // strip EOT/specials/timestamp tokens
        if (id < vs) try buf.appendSlice(toks[id]);
    }
    return buf.items;
}
