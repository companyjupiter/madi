// test_mel.zig — asset-free correctness check for the front-end DSP.
//   (1) rfft: a pure cosine at bin k0 must produce a spectral peak at k0
//       with X[k0] ≈ N/2 (real) and ≈0 imaginary.
//   (2) end-to-end mel → GPU conv1d shape/finiteness sanity (uses the already
//       numerically-verified conv1d_gelu kernel; real-weight verification waits
//       on model assets — see PORT.md).
const std = @import("std");
const mel = @import("mel.zig");
const mtl = @import("metal_backend.zig");

const METALLIB = @embedFile("whisper.metallib");
const N = mel.N_FFT;

pub fn main() !void {
    const out = std.io.getStdOut().writer();

    // ── (1) rfft peak test ───────────────────────────────────────────
    var win_ones: [N]f32 = undefined;
    for (&win_ones) |*v| v.* = 1.0;
    const k0: usize = 10;
    var sig: [N]f32 = undefined;
    for (0..N) |n| {
        const a = 2.0 * std.math.pi * @as(f64, @floatFromInt(k0)) * @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(N));
        sig[n] = @floatCast(@cos(a));
    }
    var re: [N]f32 = undefined;
    var im: [N]f32 = undefined;
    mel.rfft(&sig, &win_ones, &re, &im);

    var peak_bin: usize = 0;
    var peak_mag: f32 = -1;
    for (0..mel.FFT_BINS) |k| {
        const m = re[k] * re[k] + im[k] * im[k];
        if (m > peak_mag) {
            peak_mag = m;
            peak_bin = k;
        }
    }
    try out.print("rfft: peak bin = {d} (expected {d}), X[{d}] = {d:.2} + {d:.2}i (expect ~{d}+0i)\n", .{ peak_bin, k0, k0, re[k0], im[k0], N / 2 });
    if (peak_bin != k0 or @abs(re[k0] - @as(f32, N / 2)) > 1.0 or @abs(im[k0]) > 1.0) {
        try out.print("❌ RFFT FAIL\n", .{});
        return error.RfftMismatch;
    }
    try out.print("✅ RFFT OK\n\n", .{});

    // ── (2) mel → GPU conv1d shape/finiteness sanity ─────────────────
    try mtl.init();
    defer mtl.deinit();
    try mtl.loadLibrary(METALLIB);
    const f_conv = try mtl.getFunction("conv1d_gelu");

    const alloc = std.heap.page_allocator;
    // Synthetic 30s of a 440 Hz tone (no model/mel_filters needed: identity-ish
    // mel filters so we exercise the full path deterministically).
    const samples = try alloc.alloc(f32, mel.CHUNK_SAMPLES);
    defer alloc.free(samples);
    for (0..mel.CHUNK_SAMPLES) |i| {
        const a = 2.0 * std.math.pi * 440.0 * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(mel.SAMPLE_RATE));
        samples[i] = @floatCast(0.5 * @sin(a));
    }
    // Synthetic mel filters: triangular-ish nonneg weights, stride 201.
    const filt = try alloc.alloc(f32, mel.N_MELS * mel.MEL_FILTER_STRIDE);
    defer alloc.free(filt);
    @memset(filt, 0);
    for (0..mel.N_MELS) |m| {
        const center = (m * mel.FFT_BINS) / mel.N_MELS;
        filt[m * mel.MEL_FILTER_STRIDE + center] = 1.0;
    }
    const mel_out = try alloc.alloc(f32, mel.N_MELS * mel.N_FRAMES);
    defer alloc.free(mel_out);
    mel.melSpectrogram(samples, filt, mel_out);

    // Upload mel → GPU, run conv1 (C_in=128 → C_out=256 toy) with random weights.
    const C_in: u32 = mel.N_MELS; // 128
    const C_out: u32 = 256;
    const L: u32 = mel.N_FRAMES; // 3000
    const Kk: u32 = 3;
    const d_mel = try mtl.allocSlice(f32, C_in * L);
    const d_w = try mtl.allocSlice(f32, Kk * C_in * C_out);
    const d_b = try mtl.allocSlice(f32, C_out);
    const d_out = try mtl.allocSlice(f32, C_out * L);
    defer mtl.free(d_mel.ptr);
    defer mtl.free(d_w.ptr);
    defer mtl.free(d_b.ptr);
    defer mtl.free(d_out.ptr);
    @memcpy(d_mel, mel_out);
    var rng = std.Random.DefaultPrng.init(7);
    const r = rng.random();
    for (d_w) |*v| v.* = r.float(f32) * 0.1 - 0.05;
    for (d_b) |*v| v.* = 0;

    var a0 = d_out.ptr;
    var a1 = d_mel.ptr;
    var a2 = d_w.ptr;
    var a3 = d_b.ptr;
    var p_cin = C_in;
    var p_cout = C_out;
    var p_lin = L;
    var p_k = Kk;
    var p_s: u32 = 1;
    var p_p: u32 = 1;
    const ptrs = [_]?*const anyopaque{
        @ptrCast(&a0), @ptrCast(&a1), @ptrCast(&a2), @ptrCast(&a3),
        @ptrCast(&p_cin), @ptrCast(&p_cout), @ptrCast(&p_lin), @ptrCast(&p_k), @ptrCast(&p_s), @ptrCast(&p_p),
    };
    const sizes = [_]usize{
        @sizeOf(usize), @sizeOf(usize), @sizeOf(usize), @sizeOf(usize),
        @sizeOf(u32), @sizeOf(u32), @sizeOf(u32), @sizeOf(u32), @sizeOf(u32), @sizeOf(u32),
    };
    try mtl.beginCommandBuffer();
    try mtl.dispatch(f_conv, .{ L, 1, 1 }, .{ 256, 1, 1 }, &ptrs, &sizes);
    try mtl.commitCommandBuffer();
    try mtl.sync();

    var finite: bool = true;
    var mel_min: f32 = 1e30;
    var mel_max: f32 = -1e30;
    for (mel_out) |v| {
        if (v < mel_min) mel_min = v;
        if (v > mel_max) mel_max = v;
    }
    for (d_out) |v| {
        if (std.math.isNan(v) or std.math.isInf(v)) finite = false;
    }
    // Whisper norm only clamps the FLOOR (max-8), so min == (mel_max-8+4)/4
    // exactly and the top is uncapped (loud synthetic tones legitimately >1).
    try out.print("mel range: [{d:.3}, {d:.3}] (floor-clamped Whisper norm)\n", .{ mel_min, mel_max });
    try out.print("conv1(mel) {d}×{d}→{d}×{d}: all finite = {}\n", .{ C_in, L, C_out, L, finite });
    if (!finite or mel_min < -2.0 or mel_max > 5.0) {
        try out.print("❌ MEL PIPELINE FAIL\n", .{});
        return error.MelPipeline;
    }
    try out.print("✅ MEL→CONV PIPELINE OK (full numeric verify pending model assets)\n", .{});
}
