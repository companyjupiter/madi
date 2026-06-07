// wav_to_enc.zig — Metal front-end: WAV → log-mel → GPU Conv1D×2(+GELU) →
// transpose + positional embedding → enc_input.bin [1500×1280].
// Self-contained macOS port of the CUDA wav_to_enc.zig.
//
// Weights are read as raw f32 .bin files from a directory (default
// ./enc_weights), matching the CUDA build's quarks/.../enc_weights layout:
//   mel_filters.bin  conv1_w.bin  conv1_b.bin  conv2_w.bin  conv2_b.bin  pos_emb.bin
// Conv weight layout expected by conv1d_gelu: [K][C_in][C_out] f32.
//
// Usage: wav_to_enc <input.wav> [out.bin] [offset_sec] [weights_dir]
const std = @import("std");
const mel = @import("mel.zig");
const mtl = @import("metal_backend.zig");

const METALLIB = @embedFile("whisper.metallib");
const D: u32 = 1280;
const SEQ: u32 = 1500;

fn readF32Bin(alloc: std.mem.Allocator, dir: []const u8, name: []const u8) ![]f32 {
    var pb: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, "{s}/{s}", .{ dir, name });
    const bytes = try std.fs.cwd().readFileAllocOptions(alloc, path, 256 * 1024 * 1024, null, @alignOf(f32), null);
    return std.mem.bytesAsSlice(f32, bytes);
}

fn dispatchConv(
    f: mtl.Function,
    o: [*]f32,
    i: [*]f32,
    w: [*]f32,
    b: [*]f32,
    c_in: u32,
    c_out: u32,
    l_in: u32,
    stride: u32,
    l_out: u32,
) !void {
    var a0 = o;
    var a1 = i;
    var a2 = w;
    var a3 = b;
    var p_cin = c_in;
    var p_cout = c_out;
    var p_lin = l_in;
    var p_k: u32 = 3;
    var p_s = stride;
    var p_p: u32 = 1;
    const ptrs = [_]?*const anyopaque{
        @ptrCast(&a0), @ptrCast(&a1), @ptrCast(&a2), @ptrCast(&a3),
        @ptrCast(&p_cin), @ptrCast(&p_cout), @ptrCast(&p_lin), @ptrCast(&p_k), @ptrCast(&p_s), @ptrCast(&p_p),
    };
    const sizes = [_]usize{
        @sizeOf(usize), @sizeOf(usize), @sizeOf(usize), @sizeOf(usize),
        @sizeOf(u32), @sizeOf(u32), @sizeOf(u32), @sizeOf(u32), @sizeOf(u32), @sizeOf(u32),
    };
    try mtl.dispatch(f, .{ l_out, 1, 1 }, .{ 256, 1, 1 }, &ptrs, &sizes);
}

pub fn main() !void {
    const out = std.io.getStdOut().writer();
    const alloc = std.heap.page_allocator;

    var args = try std.process.argsWithAllocator(alloc);
    _ = args.next();
    const wav_path = args.next() orelse {
        try out.print("Usage: wav_to_enc <input.wav> [out.bin] [offset_sec] [weights_dir]\n", .{});
        return;
    };
    const out_path = args.next() orelse "enc_input.bin";
    const offset_sec = std.fmt.parseFloat(f32, args.next() orelse "0.0") catch 0.0;
    const wdir = args.next() orelse "enc_weights";

    try out.print("=== WAV → ENC_INPUT (Metal front-end) ===\n", .{});

    try mtl.init();
    defer mtl.deinit();
    try mtl.loadLibrary(METALLIB);
    const f_conv = try mtl.getFunction("conv1d_gelu");
    try out.print("[1] Metal ready, conv1d_gelu loaded\n", .{});

    // ── Load weights (raw f32 .bin) ──────────────────────────────────
    const mel_filters = readF32Bin(alloc, wdir, "mel_filters.bin") catch |e| {
        try out.print("\n⚠ missing weights in '{s}/' ({s}). Need: mel_filters.bin, conv1_w/b.bin, conv2_w/b.bin, pos_emb.bin\n  (export them from model.safetensors — see PORT.md). Front-end built OK; rerun with assets.\n", .{ wdir, @errorName(e) });
        return;
    };
    const c1w = try readF32Bin(alloc, wdir, "conv1_w.bin");
    const c1b = try readF32Bin(alloc, wdir, "conv1_b.bin");
    const c2w = try readF32Bin(alloc, wdir, "conv2_w.bin");
    const c2b = try readF32Bin(alloc, wdir, "conv2_b.bin");
    const pos_emb = try readF32Bin(alloc, wdir, "pos_emb.bin");
    try out.print("[2] Weights loaded from {s}/\n", .{wdir});

    // ── Read WAV + mel ───────────────────────────────────────────────
    const wav = try std.fs.cwd().readFileAlloc(alloc, wav_path, 2 * 1024 * 1024 * 1024);
    const samples = try alloc.alloc(f32, mel.CHUNK_SAMPLES);
    defer alloc.free(samples);
    const off = @as(usize, @intFromFloat(offset_sec * @as(f32, @floatFromInt(mel.SAMPLE_RATE))));
    const n = mel.loadWavChunk(wav, off, samples);
    try out.print("[3] WAV: {d} samples @ offset {d:.1}s\n", .{ n, offset_sec });

    const mel_buf = try mtl.allocSlice(f32, mel.N_MELS * mel.N_FRAMES);
    defer mtl.free(mel_buf.ptr);
    mel.melSpectrogram(samples, mel_filters, mel_buf);
    try out.print("[4] log-mel [{d}×{d}] computed\n", .{ mel.N_MELS, mel.N_FRAMES });

    // ── GPU Conv1D×2 ─────────────────────────────────────────────────
    const d_c1w = try mtl.allocSlice(f32, c1w.len);
    const d_c1b = try mtl.allocSlice(f32, c1b.len);
    const d_c2w = try mtl.allocSlice(f32, c2w.len);
    const d_c2b = try mtl.allocSlice(f32, c2b.len);
    const d_conv1 = try mtl.allocSlice(f32, D * mel.N_FRAMES);
    const d_conv2 = try mtl.allocSlice(f32, D * SEQ);
    @memcpy(d_c1w, c1w);
    @memcpy(d_c1b, c1b);
    @memcpy(d_c2w, c2w);
    @memcpy(d_c2b, c2b);

    try mtl.beginCommandBuffer();
    // Conv1: mel[128][3000] → [1280][3000], stride 1
    try dispatchConv(f_conv, d_conv1.ptr, mel_buf.ptr, d_c1w.ptr, d_c1b.ptr, mel.N_MELS, D, mel.N_FRAMES, 1, mel.N_FRAMES);
    // Conv2: [1280][3000] → [1280][1500], stride 2
    try dispatchConv(f_conv, d_conv2.ptr, d_conv1.ptr, d_c2w.ptr, d_c2b.ptr, D, D, mel.N_FRAMES, 2, SEQ);
    try mtl.commitCommandBuffer();
    try mtl.sync();
    try out.print("[5] Conv1D×2 done on GPU\n", .{});

    // ── Transpose [D][SEQ] → [SEQ][D] + positional embedding ─────────
    const enc_input = try alloc.alloc(f32, SEQ * D);
    defer alloc.free(enc_input);
    for (0..SEQ) |t| {
        for (0..D) |c| {
            enc_input[t * D + c] = d_conv2[c * SEQ + t] + pos_emb[t * D + c];
        }
    }
    const file = try std.fs.cwd().createFile(out_path, .{});
    defer file.close();
    try file.writeAll(std.mem.sliceAsBytes(enc_input));
    try out.print("[6] Saved enc_input → {s} ([{d}×{d}])\n✅ FRONT-END COMPLETE\n", .{ out_path, SEQ, D });
}
