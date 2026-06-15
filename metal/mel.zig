// mel.zig — CPU front-end DSP, ported verbatim from the CUDA build's
// wav_to_enc.zig so the mel spectrogram is bit-for-bit compatible with the
// reference (and thus with PyTorch Whisper's 400-pt STFT, center=True,
// reflect padding, log10 normalization).
//
// On Apple Silicon this stays on the CPU (it's cheap and exactly matches the
// reference); only Conv1D×2 runs on the GPU. Pure std, no external deps.
const std = @import("std");

pub const SAMPLE_RATE: u32 = 16000;
pub const N_FFT: u32 = 400;
pub const HOP_LENGTH: u32 = 160;
pub const N_MELS: u32 = 128;
pub const CHUNK_LENGTH: u32 = 30;
pub const N_FRAMES: u32 = 3000; // 30s * 16000 / 160
pub const FFT_BINS: u32 = N_FFT / 2; // 200 (Whisper golden: drops Nyquist bin)
pub const MEL_FILTER_STRIDE: u32 = 201; // mel_filters.bin row stride
pub const CHUNK_SAMPLES: u32 = CHUNK_LENGTH * SAMPLE_RATE; // 480000
const PI: f64 = 3.14159265358979323846;

/// Periodic Hann window (matches torch.hann_window(periodic=True) via /(N-1)).
pub fn hannWindow(buf: *[N_FFT]f32) void {
    for (buf, 0..) |*v, i| {
        const x = @sin(PI * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(N_FFT - 1)));
        v.* = @floatCast(x * x);
    }
}

/// Naive 400-pt DFT (matches the reference exactly; f64 accumulation).
const BINS: usize = N_FFT / 2 + 1; // 201

/// Precomputed DFT twiddle factors + Hann window, built ONCE. The old per-frame
/// rfft recomputed @cos/@sin ~482M times PER 30 s chunk (a naive O(N²) DFT) —
/// the single biggest file-mode cost (~1.3 s/chunk, dominating wall; cf. mel
/// time 3.6 ms in whisper.cpp). Now it's a table lookup. Bit-identical: f64
/// cos/sin (= the old @cos(angle)), f64 accumulation, same f32 window.
const TwTable = struct {
    cos: [BINS * N_FFT]f64 = undefined,
    sin: [BINS * N_FFT]f64 = undefined,
    window: [N_FFT]f32 = undefined,
};
var g_tw: TwTable = .{};
var g_tw_ready: bool = false;
fn ensureTwiddles() void {
    if (g_tw_ready) return;
    hannWindow(&g_tw.window);
    for (0..BINS) |k| {
        const af = -2.0 * PI * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(N_FFT));
        for (0..N_FFT) |n| {
            const angle = af * @as(f64, @floatFromInt(n));
            g_tw.cos[k * N_FFT + n] = @cos(angle);
            g_tw.sin[k * N_FFT + n] = @sin(angle);
        }
    }
    g_tw_ready = true;
}

/// rfft of an already-windowed real frame via the twiddle table → bins 0..N/2.
fn rfftTw(windowed: *const [N_FFT]f32, re_out: []f32, im_out: []f32) void {
    for (0..BINS) |k| {
        var sr: f64 = 0.0;
        var si: f64 = 0.0;
        const base = k * N_FFT;
        for (0..N_FFT) |n| {
            const v = @as(f64, @floatCast(windowed[n]));
            sr += v * g_tw.cos[base + n];
            si += v * g_tw.sin[base + n];
        }
        re_out[k] = @floatCast(sr);
        im_out[k] = @floatCast(si);
    }
}

/// Compute the normalized log-mel spectrogram for one 30s chunk.
/// `samples` must be CHUNK_SAMPLES long (zero-padded if the audio is shorter).
/// `mel_filters` is the raw mel_filters.bin as f32 (rows of MEL_FILTER_STRIDE).
/// Output `mel` is [N_MELS * N_FRAMES], row-major [mel][frame].
pub fn melSpectrogram(
    samples: []const f32,
    mel_filters: []const f32,
    mel: []f32,
) void {
    melSpectrogramRaw(samples, mel_filters, mel, null);
}

/// As `melSpectrogram`, but if `raw_out` is given it receives the absolute
/// log10(mel) BEFORE Whisper's per-chunk max-clip + affine normalization.
/// Diarization needs this: the per-chunk normalization makes a quiet chunk's
/// noise look as loud as speech, breaking cross-chunk energy VAD + clustering.
pub fn melSpectrogramRaw(
    samples: []const f32,
    mel_filters: []const f32,
    mel: []f32,
    raw_out: ?[]f32,
) void {
    std.debug.assert(samples.len >= CHUNK_SAMPLES);
    std.debug.assert(mel.len >= N_MELS * N_FRAMES);

    ensureTwiddles();

    // The frame loop is embarrassingly parallel — each frame extracts its own
    // window, rfft's it, and writes its OWN mel column [*][f] (no overlap). Fan
    // it across cores: combined with the twiddle table this is the file-mode win.
    const FrameJob = struct {
        samples: []const f32,
        mel_filters: []const f32,
        mel: []f32,
        lo: usize,
        hi: usize,
        fn run(j: @This()) void {
            var frame_buf: [N_FFT]f32 = undefined;
            var re_out: [N_FFT]f32 = undefined;
            var im_out: [N_FFT]f32 = undefined;
            var power: [FFT_BINS]f32 = undefined;
            const padding = N_FFT / 2; // center=True reflect padding
            for (j.lo..j.hi) |f| {
                const start_idx = f * HOP_LENGTH;
                for (0..N_FFT) |t| {
                    const si = @as(isize, @intCast(start_idx + t)) - @as(isize, @intCast(padding));
                    var ri: usize = 0;
                    if (si < 0) {
                        ri = @intCast(-si);
                    } else if (si >= CHUNK_SAMPLES) {
                        ri = @intCast(2 * @as(isize, @intCast(CHUNK_SAMPLES)) - 2 - si);
                    } else {
                        ri = @intCast(si);
                    }
                    frame_buf[t] = j.samples[ri] * g_tw.window[t]; // window applied here
                }
                rfftTw(&frame_buf, &re_out, &im_out);
                for (0..FFT_BINS) |k| power[k] = re_out[k] * re_out[k] + im_out[k] * im_out[k];
                for (0..N_MELS) |m| {
                    var sum: f32 = 0.0;
                    for (0..FFT_BINS) |k| sum += power[k] * j.mel_filters[m * MEL_FILTER_STRIDE + k];
                    j.mel[m * N_FRAMES + f] = sum;
                }
            }
        }
    };
    const nthreads: usize = @min(@as(usize, 8), @max(@as(usize, 1), std.Thread.getCpuCount() catch 1));
    const per = (N_FRAMES + nthreads - 1) / nthreads;
    var threads: [8]std.Thread = undefined;
    var nt: usize = 0;
    var ti: usize = 0;
    while (ti < nthreads) : (ti += 1) {
        const lo = ti * per;
        if (lo >= N_FRAMES) break;
        const job = FrameJob{ .samples = samples, .mel_filters = mel_filters, .mel = mel, .lo = lo, .hi = @min(lo + per, N_FRAMES) };
        if (std.Thread.spawn(.{}, FrameJob.run, .{job})) |th| {
            threads[nt] = th;
            nt += 1;
        } else |_| {
            job.run(); // spawn failed → run this range inline
        }
    }
    for (threads[0..nt]) |th| th.join();

    // Whisper normalization: log10(max(mel,1e-10)), clip to (max-8), (.+4)/4.
    var mel_max: f32 = -1e30;
    for (mel[0 .. N_MELS * N_FRAMES]) |*v| {
        const clamped = @max(v.*, 1e-10);
        v.* = @log10(clamped);
        if (v.* > mel_max) mel_max = v.*;
    }
    if (raw_out) |ro| @memcpy(ro[0 .. N_MELS * N_FRAMES], mel[0 .. N_MELS * N_FRAMES]);
    for (mel[0 .. N_MELS * N_FRAMES]) |*v| {
        const clipped = @max(v.*, mel_max - 8.0);
        v.* = (clipped + 4.0) / 4.0;
    }
}

/// Supported PCM sample encodings.
pub const WavFmt = enum { pcm16, float32, unsupported };

/// Inspect the fmt chunk: returns (format, channels). PCM16 (tag 1, 16-bit) and
/// IEEE float32 (tag 3, 32-bit) are supported; anything else → .unsupported so
/// the caller can fail loudly instead of silently producing 0 samples (FLEURS
/// ships float32 — was read as silence, see W-3).
pub fn wavFmt(wav_data: []const u8) struct { fmt: WavFmt, channels: u16 } {
    if (wav_data.len < 36) return .{ .fmt = .unsupported, .channels = 0 };
    const tag = @as(*align(1) const u16, @ptrCast(wav_data.ptr + 20)).*;
    const channels = @as(*align(1) const u16, @ptrCast(wav_data.ptr + 22)).*;
    const bits_ps = @as(*align(1) const u16, @ptrCast(wav_data.ptr + 34)).*;
    if (channels == 0) return .{ .fmt = .unsupported, .channels = 0 };
    const f: WavFmt = if ((tag == 1 or tag == 0xFFFE) and bits_ps == 16)
        .pcm16
    else if ((tag == 3 or tag == 0xFFFE) and bits_ps == 32)
        .float32
    else
        .unsupported;
    return .{ .fmt = f, .channels = channels };
}

fn wavHeaderSize(wav_data: []const u8) usize {
    if (wav_data.len > 4) {
        for (0..wav_data.len - 4) |i| {
            if (std.mem.eql(u8, wav_data[i .. i + 4], "data")) return i + 8;
        }
    }
    return 44;
}

/// Total mono sample count of a supported WAV (0 if unsupported/empty).
pub fn wavTotalSamples(wav_data: []const u8) usize {
    const info = wavFmt(wav_data);
    if (info.fmt == .unsupported) return 0;
    const header_size = wavHeaderSize(wav_data);
    if (wav_data.len <= header_size) return 0;
    const bps: usize = if (info.fmt == .pcm16) 2 else 4;
    return (wav_data.len - header_size) / bps / info.channels;
}

/// Decode a PCM16 or float32 WAV into mono f32 samples in [-1,1), starting at
/// `offset_samples`, returning up to CHUNK_SAMPLES (zero-padded). Returns the
/// number of real (non-pad) samples written (0 if unsupported/empty).
pub fn loadWavChunk(wav_data: []const u8, offset_samples: usize, out: []f32) usize {
    std.debug.assert(out.len >= CHUNK_SAMPLES);
    @memset(out[0..CHUNK_SAMPLES], 0);

    const info = wavFmt(wav_data);
    if (info.fmt == .unsupported) return 0;
    const header_size = wavHeaderSize(wav_data);
    if (wav_data.len <= header_size) return 0;
    const pcm = wav_data[header_size..];
    const channels = info.channels;
    const bps: usize = if (info.fmt == .pcm16) 2 else 4;
    const total = pcm.len / bps / channels;
    const start = @min(offset_samples, total);
    const n = @min(total - start, CHUNK_SAMPLES);
    switch (info.fmt) {
        .pcm16 => {
            const p = @as([*]align(1) const i16, @ptrCast(pcm.ptr));
            for (0..n) |i| out[i] = @as(f32, @floatFromInt(p[(start + i) * channels])) / 32768.0;
        },
        .float32 => {
            const p = @as([*]align(1) const f32, @ptrCast(pcm.ptr));
            for (0..n) |i| out[i] = p[(start + i) * channels]; // already [-1,1]
        },
        .unsupported => unreachable,
    }
    return n;
}
