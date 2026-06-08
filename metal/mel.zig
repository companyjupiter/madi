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
/// Writes bins 0..N_FFT/2+1 of the windowed real input.
pub fn rfft(input: *const [N_FFT]f32, window: *const [N_FFT]f32, re_out: []f32, im_out: []f32) void {
    const N = N_FFT;
    const bins = N / 2 + 1; // 201
    for (0..bins) |k| {
        var sum_re: f64 = 0.0;
        var sum_im: f64 = 0.0;
        const af = -2.0 * PI * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(N));
        for (0..N) |n| {
            const val = @as(f64, @floatCast(input[n] * window[n]));
            const angle = af * @as(f64, @floatFromInt(n));
            sum_re += val * @cos(angle);
            sum_im += val * @sin(angle);
        }
        re_out[k] = @floatCast(sum_re);
        im_out[k] = @floatCast(sum_im);
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

    var window: [N_FFT]f32 = undefined;
    hannWindow(&window);

    var frame_buf: [N_FFT]f32 = undefined;
    var re_out: [N_FFT]f32 = undefined;
    var im_out: [N_FFT]f32 = undefined;
    var power: [FFT_BINS]f32 = undefined;
    const padding = N_FFT / 2; // 200, center=True reflect padding

    for (0..N_FRAMES) |f| {
        const start_idx = f * HOP_LENGTH;
        // Reflect-padded frame extraction.
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
            frame_buf[t] = samples[ri];
        }
        rfft(&frame_buf, &window, &re_out, &im_out);
        for (0..FFT_BINS) |k| {
            power[k] = re_out[k] * re_out[k] + im_out[k] * im_out[k];
        }
        for (0..N_MELS) |m| {
            var sum: f32 = 0.0;
            for (0..FFT_BINS) |k| {
                sum += power[k] * mel_filters[m * MEL_FILTER_STRIDE + k];
            }
            mel[m * N_FRAMES + f] = sum;
        }
    }

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

/// Total mono sample count of a 16-bit PCM WAV (0 if unsupported).
pub fn wavTotalSamples(wav_data: []const u8) usize {
    var header_size: usize = 44;
    if (wav_data.len > 4) {
        for (0..wav_data.len - 4) |i| {
            if (std.mem.eql(u8, wav_data[i .. i + 4], "data")) {
                header_size = i + 8;
                break;
            }
        }
    }
    if (wav_data.len < 36) return 0;
    const channels = @as(*align(1) const u16, @ptrCast(wav_data.ptr + 22)).*;
    const bits_ps = @as(*align(1) const u16, @ptrCast(wav_data.ptr + 34)).*;
    if (bits_ps != 16 or channels == 0) return 0;
    return (wav_data.len - header_size) / (bits_ps / 8) / channels;
}

/// Decode a 16-bit PCM WAV into mono f32 samples in [-1,1), starting at
/// `offset_samples`, returning up to CHUNK_SAMPLES (zero-padded). Returns the
/// number of real (non-pad) samples written.
pub fn loadWavChunk(wav_data: []const u8, offset_samples: usize, out: []f32) usize {
    std.debug.assert(out.len >= CHUNK_SAMPLES);
    @memset(out[0..CHUNK_SAMPLES], 0);

    var header_size: usize = 44;
    if (wav_data.len > 4) {
        for (0..wav_data.len - 4) |i| {
            if (std.mem.eql(u8, wav_data[i .. i + 4], "data")) {
                header_size = i + 8;
                break;
            }
        }
    }
    const pcm = wav_data[header_size..];
    const channels = @as(*align(1) const u16, @ptrCast(wav_data.ptr + 22)).*;
    const bits_ps = @as(*align(1) const u16, @ptrCast(wav_data.ptr + 34)).*;
    if (bits_ps != 16 or channels == 0) return 0;
    const total = pcm.len / (bits_ps / 8) / channels;
    const start = @min(offset_samples, total);
    const avail = total - start;
    const n = @min(avail, CHUNK_SAMPLES);
    const pcm16 = @as([*]align(1) const i16, @ptrCast(pcm.ptr));
    for (0..n) |i| {
        out[i] = @as(f32, @floatFromInt(pcm16[(start + i) * channels])) / 32768.0;
    }
    return n;
}
