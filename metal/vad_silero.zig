// vad_silero.zig — sovereign CPU port of Silero-VAD v6 (16 kHz), weights from
// whisper.cpp's ggml export via bench/convert_silero.py. Mirrors the wcpp
// graph exactly (whisper_vad_build_{stft,encoder,lstm}_layer + the
// segments_from_probs state machine) so wcpp's whisper-vad-speech-segments
// CLI is the bit-level validation referee.
//
// Why this exists (measured, 2026-06-11): energy/relative-RMS VAD cannot
// reject music — pqmho's music has HIGHER window RMS than real close-mic
// speech; <|nospeech|> is dead in large-v3-turbo (P≈1e-10 on pure music);
// word-span gating fails both ways. A trained VAD is the only signal that
// separates (wcpp Silero: pqmho 138s → 11.4s speech vs ref 14.9s).
//
// Per 512-sample frame (32 ms): reflect-pad 64 → STFT conv (k=256, s=128,
// 258ch = 129 re + 129 im) → magnitude[129][4] → 4 conv1d k3 (129→128 s1,
// 128→64 s2, 64→64 s2, 64→128 s1) + ReLU → take t=0 → LSTM(128) step →
// ReLU → dot(128)+bias → sigmoid = P(speech).
const std = @import("std");

pub const N_WINDOW: usize = 512; // 32 ms @ 16 kHz, non-overlapping
const PAD: usize = 64;
const STFT_K: usize = 256;
const STFT_S: usize = 128;
const NFREQ: usize = 129; // cutoff (258/2)
const T0: usize = 4; // STFT output positions per frame
const H: usize = 128; // lstm hidden

pub const Model = struct {
    stft: []f32, // [258][256]
    w: [4][]f32, // enc conv weights [out][in][3]
    b: [4][]f32,
    enc_in: [4]usize,
    enc_out: [4]usize,
    enc_stride: [4]usize,
    ih_w: []f32, // [512][128]
    ih_b: []f32, // [512]
    hh_w: []f32, // [512][128]
    hh_b: []f32, // [512]
    fin_w: []f32, // [128]
    fin_b: f32,
    // streaming state
    h: [H]f32 = [_]f32{0} ** H,
    c: [H]f32 = [_]f32{0} ** H,

    pub fn load(alloc: std.mem.Allocator, path: []const u8) !Model {
        const bytes = try std.fs.cwd().readFileAlloc(alloc, path, 16 * 1024 * 1024);
        var off: usize = 0;
        const ru = struct {
            fn f(b: []const u8, o: *usize) u32 {
                const v = std.mem.readInt(u32, b[o.*..][0..4], .little);
                o.* += 4;
                return v;
            }
        }.f;
        if (ru(bytes, &off) != 0x53564144) return error.BadMagic;
        const n_window = ru(bytes, &off);
        _ = ru(bytes, &off); // n_context (folded into the reflect pad)
        if (n_window != N_WINDOW) return error.BadWindow;
        const nl = ru(bytes, &off);
        if (nl != 4) return error.BadLayers;
        var enc_in: [4]usize = undefined;
        var enc_out: [4]usize = undefined;
        for (0..4) |i| {
            enc_in[i] = ru(bytes, &off);
            enc_out[i] = ru(bytes, &off);
            _ = ru(bytes, &off); // kernel (always 3)
        }
        _ = ru(bytes, &off); // lstm_input
        _ = ru(bytes, &off); // lstm_hidden
        _ = ru(bytes, &off); // final_in
        _ = ru(bytes, &off); // final_out
        const tens = struct {
            fn f(b: []const u8, o: *usize) []f32 {
                const nd = std.mem.readInt(u32, b[o.*..][0..4], .little);
                o.* += 4;
                var n: usize = 1;
                for (0..nd) |_| {
                    n *= std.mem.readInt(u32, b[o.*..][0..4], .little);
                    o.* += 4;
                }
                const s = @as([*]f32, @ptrCast(@alignCast(@constCast(b[o.*..].ptr))))[0..n];
                o.* += 4 * n;
                return s;
            }
        }.f;
        var m: Model = undefined;
        m.h = [_]f32{0} ** H;
        m.c = [_]f32{0} ** H;
        m.enc_in = enc_in;
        m.enc_out = enc_out;
        m.enc_stride = .{ 1, 2, 2, 1 };
        m.stft = tens(bytes, &off);
        for (0..4) |i| {
            m.w[i] = tens(bytes, &off);
            m.b[i] = tens(bytes, &off);
        }
        m.ih_w = tens(bytes, &off);
        m.ih_b = tens(bytes, &off);
        m.hh_w = tens(bytes, &off);
        m.hh_b = tens(bytes, &off);
        m.fin_w = tens(bytes, &off);
        m.fin_b = tens(bytes, &off)[0];
        return m;
    }

    pub fn reset(self: *Model) void {
        self.h = [_]f32{0} ** H;
        self.c = [_]f32{0} ** H;
    }

    // one 512-sample frame → P(speech). Stateful (LSTM h/c carry over).
    pub fn frameProb(self: *Model, x: []const f32) f32 {
        // reflect pad 64|64 (PyTorch ReflectionPad1d semantics)
        var pd: [N_WINDOW + 2 * PAD]f32 = undefined;
        for (0..PAD) |i| pd[i] = x[PAD - i];
        @memcpy(pd[PAD..][0..N_WINDOW], x[0..N_WINDOW]);
        for (0..PAD) |i| pd[PAD + N_WINDOW + i] = x[N_WINDOW - 2 - i];

        // STFT conv + magnitude → mag[129][4]
        var mag: [NFREQ * T0]f32 = undefined;
        for (0..NFREQ) |f| {
            for (0..T0) |t| {
                var re: f32 = 0;
                var im: f32 = 0;
                const base = t * STFT_S;
                const wr = self.stft[f * STFT_K ..][0..STFT_K];
                const wi = self.stft[(f + NFREQ) * STFT_K ..][0..STFT_K];
                for (0..STFT_K) |k| {
                    re += wr[k] * pd[base + k];
                    im += wi[k] * pd[base + k];
                }
                mag[f * T0 + t] = @sqrt(re * re + im * im);
            }
        }

        // encoder convs (k=3, pad=1) + ReLU
        var buf_a: [NFREQ * T0]f32 = undefined;
        var buf_b: [NFREQ * T0]f32 = undefined;
        var cur: []f32 = mag[0..];
        var cur_t: usize = T0;
        var out_buf: []f32 = buf_a[0..];
        var alt_buf: []f32 = buf_b[0..];
        for (0..4) |l| {
            const cin = self.enc_in[l];
            const cout = self.enc_out[l];
            const st = self.enc_stride[l];
            const tout = (cur_t + 2 - 3) / st + 1;
            for (0..cout) |co| {
                const wrow = self.w[l][co * cin * 3 ..][0 .. cin * 3];
                for (0..tout) |to| {
                    var acc: f32 = self.b[l][co];
                    const t_in = @as(isize, @intCast(to * st)) - 1;
                    for (0..cin) |ci| {
                        const wk = wrow[ci * 3 ..][0..3];
                        for (0..3) |k| {
                            const ti = t_in + @as(isize, @intCast(k));
                            if (ti < 0 or ti >= @as(isize, @intCast(cur_t))) continue;
                            acc += wk[k] * cur[ci * cur_t + @as(usize, @intCast(ti))];
                        }
                    }
                    out_buf[co * tout + to] = @max(acc, 0); // ReLU
                }
            }
            const tmp = out_buf;
            out_buf = alt_buf;
            alt_buf = tmp;
            cur = tmp;
            cur_t = tout;
        }
        // cur = [128][cur_t]; take t=0 → xin[128]
        var xin: [H]f32 = undefined;
        for (0..H) |i| xin[i] = cur[i * cur_t];

        // LSTM step (gate order i,f,g,o — PyTorch)
        var gates: [4 * H]f32 = undefined;
        for (0..4 * H) |g| {
            var acc: f32 = self.ih_b[g] + self.hh_b[g];
            const wi_ = self.ih_w[g * H ..][0..H];
            const wh = self.hh_w[g * H ..][0..H];
            for (0..H) |j| acc += wi_[j] * xin[j] + wh[j] * self.h[j];
            gates[g] = acc;
        }
        const sg = struct {
            fn f(v: f32) f32 {
                return 1.0 / (1.0 + @exp(-v));
            }
        }.f;
        var hout: [H]f32 = undefined;
        for (0..H) |j| {
            const i_t = sg(gates[j]);
            const f_t = sg(gates[H + j]);
            const g_t = std.math.tanh(gates[2 * H + j]);
            const o_t = sg(gates[3 * H + j]);
            const c_t = f_t * self.c[j] + i_t * g_t;
            self.c[j] = c_t;
            hout[j] = o_t * std.math.tanh(c_t);
            self.h[j] = hout[j];
        }
        // ReLU → final 1×128 conv + sigmoid
        var acc: f32 = self.fin_b;
        for (0..H) |j| acc += self.fin_w[j] * @max(hout[j], 0);
        return sg(acc);
    }

    // probs for a whole buffer (chunked by 512, zero-padded tail), state reset
    pub fn detect(self: *Model, samples: []const f32, probs: []f32) usize {
        self.reset();
        const n_chunks = (samples.len + N_WINDOW - 1) / N_WINDOW;
        const n = @min(n_chunks, probs.len);
        var win: [N_WINDOW]f32 = undefined;
        for (0..n) |i| {
            const s0 = i * N_WINDOW;
            const got = @min(N_WINDOW, samples.len - s0);
            @memcpy(win[0..got], samples[s0 .. s0 + got]);
            if (got < N_WINDOW) @memset(win[got..], 0);
            probs[i] = self.frameProb(win[0..]);
        }
        return n;
    }
};

pub const Segment = struct { start: f32, end: f32 };

// Port of whisper_vad_segments_from_probs (defaults: threshold 0.5,
// min_speech 250 ms, min_silence 100 ms, pad 30 ms, no max-duration split,
// 200 ms adjacent-gap merge). Returns seconds.
pub fn segmentsFromProbs(alloc: std.mem.Allocator, probs: []const f32) !std.ArrayList(Segment) {
    const SR: f32 = 16000;
    const threshold: f32 = 0.5;
    const neg_threshold: f32 = threshold - 0.15;
    const min_silence: i64 = 16000 * 100 / 1000;
    const min_speech: i64 = 16000 * 250 / 1000;
    const pad_s: i64 = 16000 * 30 / 1000;
    const audio_len: i64 = @intCast(probs.len * N_WINDOW);

    var raw = std.ArrayList([2]i64).init(alloc);
    defer raw.deinit();
    var in_speech = false;
    var temp_end: i64 = 0;
    var start: i64 = 0;
    var has_cur = false;
    for (probs, 0..) |p, i| {
        const cur: i64 = @intCast(i * N_WINDOW);
        if (p >= threshold and temp_end != 0) temp_end = 0;
        if (p >= threshold and !in_speech) {
            in_speech = true;
            start = cur;
            has_cur = true;
            continue;
        }
        if (p < neg_threshold and in_speech) {
            if (temp_end == 0) temp_end = cur;
            if (cur - temp_end < min_silence) continue;
            if (temp_end - start > min_speech) try raw.append(.{ start, temp_end });
            temp_end = 0;
            in_speech = false;
            has_cur = false;
        }
    }
    if (has_cur and audio_len - start > min_speech) try raw.append(.{ start, audio_len });

    // merge gaps < 200 ms
    const merge_gap: i64 = 16000 * 200 / 1000;
    var merged = std.ArrayList([2]i64).init(alloc);
    defer merged.deinit();
    for (raw.items) |s| {
        if (merged.items.len > 0 and s[0] - merged.items[merged.items.len - 1][1] < merge_gap) {
            merged.items[merged.items.len - 1][1] = s[1];
        } else try merged.append(s);
    }
    var segs = std.ArrayList(Segment).init(alloc);
    for (merged.items) |s| {
        if (s[1] - s[0] < min_speech) continue;
        const a = @max(s[0] - pad_s, 0);
        const b = @min(s[1] + pad_s, audio_len);
        try segs.append(.{ .start = @as(f32, @floatFromInt(a)) / SR, .end = @as(f32, @floatFromInt(b)) / SR });
    }
    return segs;
}
