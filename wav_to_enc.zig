// wav_to_enc.zig — WAV → CPU STFT MEL(128) [Center=True ReflPadding] → GPU Conv1D×2(GELU) → enc_input.bin [1500×1280]
// Zero external dependencies. Zig + CUDA Driver API only.
const std = @import("std");
const CUresult = i32;
const CUdeviceptr = u64;
const CUfn = *anyopaque;
const CUstream = ?*anyopaque;

const SAMPLE_RATE: u32 = 16000;
const N_FFT: u32 = 400;
const HOP_LENGTH: u32 = 160;
const N_MELS: u32 = 128;
const CHUNK_LENGTH: u32 = 30;
const N_FRAMES: u32 = 3000; // 30s * 16000 / 160
const D: u32 = 1280;
const SEQ: u32 = 1500;
const PI: f64 = 3.14159265358979323846;

fn hann_window(buf: *[N_FFT]f32) void {
    for (buf, 0..) |*v, i| {
        const x = @sin(PI * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(N_FFT - 1))); // periodic=False
        v.* = @floatCast(x * x);
    }
}

fn rfft(input: []const f32, window: *const [N_FFT]f32, re_out: []f32, im_out: []f32) void {
    const N = N_FFT; // 400
    const bins = N / 2 + 1; // 201
    
    // Naive DFT to perfectly match PyTorch's 400-point STFT
    for (0..bins) |k| {
        var sum_re: f64 = 0.0;
        var sum_im: f64 = 0.0;
        const angle_factor = -2.0 * PI * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(N));
        for (0..N) |n| {
            const val = @as(f64, @floatCast(input[n] * window[n]));
            const angle = angle_factor * @as(f64, @floatFromInt(n));
            sum_re += val * @cos(angle);
            sum_im += val * @sin(angle);
        }
        re_out[k] = @floatCast(sum_re);
        im_out[k] = @floatCast(sum_im);
    }
}

pub fn main() !void {
    const out = std.io.getStdOut().writer();
    const alloc = std.heap.page_allocator;

    var argit = try std.process.argsWithAllocator(alloc);
    _ = argit.next(); // skip exe name
    const wav_path = argit.next() orelse {
        try out.print("Usage: wav_to_enc <input.wav> <output.bin> [offset_sec]\n", .{});
        return;
    };
    const out_path = argit.next() orelse "quarks/enc_input.bin";
    const offset_str = argit.next() orelse "0.0";
    const offset_sec = std.fmt.parseFloat(f32, offset_str) catch 0.0;
    
    const offset_samples = @as(usize, @intFromFloat(offset_sec * @as(f32, @floatFromInt(SAMPLE_RATE))));
    const weights_base = "quarks/whisper-turbo-v3-atom/enc_weights";

    try out.print("\n=== WAV → ENC_INPUT (Zig+CPU FFT - REFLECT PADDING ACTIVE v3) ===\n", .{});

    // 1. CUDA init & Context Creation
    var nv = std.DynLib.open("nvcuda.dll") catch return error.CudaNotFound;
    const cuInit = nv.lookup(*const fn(u32)callconv(.C)CUresult, "cuInit").?;
    const cuDevGet = nv.lookup(*const fn(*i32,i32)callconv(.C)CUresult, "cuDeviceGet").?;
    const cuCtxCr = nv.lookup(*const fn(**anyopaque,u32,i32)callconv(.C)CUresult, "cuCtxCreate_v2").?;

    const cuModLD = nv.lookup(*const fn(**anyopaque,[*]const u8)callconv(.C)CUresult,"cuModuleLoadData").?;
    const cuGetF = nv.lookup(*const fn(*CUfn,*anyopaque,[*:0]const u8)callconv(.C)CUresult,"cuModuleGetFunction").?;
    const cuAlloc = nv.lookup(*const fn(*CUdeviceptr,usize)callconv(.C)CUresult,"cuMemAlloc_v2").?;
    const cuH2D = nv.lookup(*const fn(*anyopaque,*const anyopaque,usize)callconv(.C)CUresult,"cuMemcpyHtoD_v2").?;
    const cuD2H = nv.lookup(*const fn(*anyopaque,*const anyopaque,usize)callconv(.C)CUresult,"cuMemcpyDtoH_v2").?;
    const cuSync = nv.lookup(*const fn()callconv(.C)CUresult,"cuCtxSynchronize").?;
    const cuLaunch = nv.lookup(*const fn(CUfn,u32,u32,u32,u32,u32,u32,u32,CUstream,[*]?*anyopaque,?*anyopaque)callconv(.C)CUresult,"cuLaunchKernel").?;

    _ = cuInit(0);
    var dev: i32 = undefined;
    _ = cuDevGet(&dev, 0);
    var ctx: *anyopaque = undefined;
    _ = cuCtxCr(&ctx, 0, dev);

    try out.print("[1] CUDA ready\n", .{});

    // 2. Load PTX
    const ptx_data = try std.fs.cwd().readFileAlloc(alloc, "conv1d.ptx", 1024*1024);
    const ptx_s = try alloc.allocSentinel(u8, ptx_data.len, 0); @memcpy(ptx_s, ptx_data);
    var mod_conv: *anyopaque = undefined;
    _ = cuModLD(&mod_conv, @ptrCast(ptx_s.ptr));
    var fn_conv1d: CUfn = undefined;
    _ = cuGetF(&fn_conv1d, mod_conv, "conv1d_gelu");
    try out.print("[2] conv1d.ptx loaded\n", .{});

    // 3. Read WAV
    const wav_data = try std.fs.cwd().readFileAlloc(alloc, wav_path, 200 * 1024 * 1024);
    var header_size: usize = 44;
    for (0..wav_data.len - 4) |i| {
        if (std.mem.eql(u8, wav_data[i..i+4], "data")) {
            header_size = i + 8;
            break;
        }
    }
    const pcm_bytes = wav_data[header_size..];
    const sample_rate_wav = @as(*align(1) const u32, @ptrCast(wav_data.ptr + 24)).*;
    const bits_per_sample = @as(*align(1) const u16, @ptrCast(wav_data.ptr + 34)).*;
    const channels = @as(*align(1) const u16, @ptrCast(wav_data.ptr + 22)).*;
    const n_samples_raw = pcm_bytes.len / (bits_per_sample / 8) / channels;
    try out.print("[3] WAV: {s} SR={d} CH={d} BPS={d} samples={d}\n", .{wav_path, sample_rate_wav, channels, bits_per_sample, n_samples_raw});

    // 4. Convert to F32 + pad to 30s
    const chunk_samples = CHUNK_LENGTH * SAMPLE_RATE;
    const start_sample = @min(offset_samples, n_samples_raw);
    const remain_samples = n_samples_raw - start_sample;
    try out.print("DEBUG: offset_sec={d}, start_sample={d}\n", .{offset_sec, start_sample});
    const n_samples = @min(remain_samples, chunk_samples);
    var samples = try alloc.alloc(f32, chunk_samples);
    @memset(samples, 0);
    if (bits_per_sample == 16) {
        const pcm16 = @as([*]align(1) const i16, @ptrCast(pcm_bytes.ptr));
        var min_val: f32 = 1.0;
        var max_val: f32 = -1.0;
        for (0..n_samples) |i| {
            samples[i] = @as(f32, @floatFromInt(pcm16[(start_sample + i) * channels])) / 32768.0;
            if (samples[i] < min_val) min_val = samples[i];
            if (samples[i] > max_val) max_val = samples[i];
        }
        try out.print("DEBUG: samples min={d:.4}, max={d:.4}\n", .{min_val, max_val});
    }
    try out.print("[4] {d} samples padded to {d}\n", .{n_samples, chunk_samples});

    // 5. Compute MEL on CPU with Golden Radix-2 FFT & Reflect Padding (center=True)
    var fb:[512]u8=undefined;
    const mel_path = std.fmt.bufPrint(&fb, "{s}/mel_filters.bin", .{weights_base}) catch unreachable;
    const mel_filt_data = try std.fs.cwd().readFileAlloc(alloc, mel_path, 1024*1024);
    const mel_filters = std.mem.bytesAsSlice(f32, mel_filt_data);
    const fft_bins = N_FFT / 2; // 200 (Whisper Golden: exclude Nyquist bin stft[..., :-1])
    try out.print("[5] Computing MEL on CPU (FFT + Reflect Padding) ({d} frames)...\n", .{N_FRAMES});

    var window: [N_FFT]f32 = undefined;
    hann_window(&window);

    const mel = try alloc.alloc(f32, N_MELS * N_FRAMES);
    defer alloc.free(mel);
    @memset(mel, 0.0);

    var re_out: [N_FFT]f32 = undefined;
    var im_out: [N_FFT]f32 = undefined;
    var power: [N_FFT / 2 + 1]f32 = undefined;
    var frame_buf: [N_FFT]f32 = undefined;

    const padding = N_FFT / 2; // 200

    for (0..N_FRAMES) |f| {
        const start_idx = f * HOP_LENGTH;
        for (0..N_FFT) |t| {
            const sample_idx = @as(isize, @intCast(start_idx + t)) - @as(isize, @intCast(padding));
            var ref_idx: usize = 0;
            if (sample_idx < 0) {
                ref_idx = @intCast(-sample_idx);
            } else if (sample_idx >= chunk_samples) {
                ref_idx = @intCast(2 * @as(isize, @intCast(chunk_samples)) - 2 - sample_idx);
            } else {
                ref_idx = @intCast(sample_idx);
            }
            frame_buf[t] = samples[ref_idx];
        }
        
        // Radix-2 FFT
        rfft(&frame_buf, &window, &re_out, &im_out);

        for (0..fft_bins) |k| {
            power[k] = re_out[k] * re_out[k] + im_out[k] * im_out[k];
        }

        for (0..N_MELS) |m| {
            var sum: f32 = 0.0;
            for (0..fft_bins) |k| {
                sum += power[k] * mel_filters[m * 201 + k]; // Stride must remain 201 to map correct weights!
            }
            mel[m * N_FRAMES + f] = sum;
        }
    }

    // Normalize Mel Spectrogram (Whisper Golden standard: log10(max(mel, 1e-10)))
    var mel_max_val: f32 = -1e30;
    for (mel) |*v| {
        const clamped = @max(v.*, 1e-10);
        v.* = @log10(clamped); // Golden Standard log10!
        if (v.* > mel_max_val) mel_max_val = v.*;
    }

    for (mel) |*v| {
        const clipped = @max(v.*, mel_max_val - 8.0);
        v.* = (clipped + 4.0) / 4.0;
    }

    var d_mel: CUdeviceptr = 0;
    _ = cuAlloc(&d_mel, N_MELS * N_FRAMES * 4);
    _ = cuH2D(@ptrFromInt(d_mel), mel.ptr, N_MELS * N_FRAMES * 4);

    try out.print("\n[5b] MEL computed on CPU: [{d}×{d}] max={d:.4}\n", .{N_MELS, N_FRAMES, mel_max_val});

    // 6. Upload Conv1D weights
    var pb2:[512]u8=undefined;
    const c1w_data = try std.fs.cwd().readFileAlloc(alloc, std.fmt.bufPrint(&pb2, "{s}/conv1_w.bin", .{weights_base}) catch unreachable, 4*1024*1024);
    const c1b_data = try std.fs.cwd().readFileAlloc(alloc, std.fmt.bufPrint(&pb2, "{s}/conv1_b.bin", .{weights_base}) catch unreachable, 64*1024);
    const c2w_data = try std.fs.cwd().readFileAlloc(alloc, std.fmt.bufPrint(&pb2, "{s}/conv2_w.bin", .{weights_base}) catch unreachable, 40*1024*1024);
    const c2b_data = try std.fs.cwd().readFileAlloc(alloc, std.fmt.bufPrint(&pb2, "{s}/conv2_b.bin", .{weights_base}) catch unreachable, 64*1024);
    const pos_data = try std.fs.cwd().readFileAlloc(alloc, std.fmt.bufPrint(&pb2, "{s}/pos_emb.bin", .{weights_base}) catch unreachable, 10*1024*1024);

    var d_c1w: CUdeviceptr=0; _ = cuAlloc(&d_c1w, c1w_data.len); _ = cuH2D(@ptrFromInt(d_c1w), c1w_data.ptr, c1w_data.len);
    var d_c1b: CUdeviceptr=0; _ = cuAlloc(&d_c1b, c1b_data.len); _ = cuH2D(@ptrFromInt(d_c1b), c1b_data.ptr, c1b_data.len);
    var d_c2w: CUdeviceptr=0; _ = cuAlloc(&d_c2w, c2w_data.len); _ = cuH2D(@ptrFromInt(d_c2w), c2w_data.ptr, c2w_data.len);
    var d_c2b: CUdeviceptr=0; _ = cuAlloc(&d_c2b, c2b_data.len); _ = cuH2D(@ptrFromInt(d_c2b), c2b_data.ptr, c2b_data.len);
    // Conv1 output: [1280][3000] F32
    var d_conv1_out: CUdeviceptr=0; _ = cuAlloc(&d_conv1_out, D * N_FRAMES * 4);
    // Conv2 output: [1280][1500] F32
    var d_conv2_out: CUdeviceptr=0; _ = cuAlloc(&d_conv2_out, D * SEQ * 4);
    _ = cuSync();
    try out.print("[6] Weights uploaded to GPU\n", .{});

    // 7. Run Conv1D: mel[128][3000] → conv1_out[1280][3000]
    const w = @import("std").os.windows;
    var t_c: i64 = 0; var t_f: i64 = 0;
    const qpc = @extern(*const fn(*i64) callconv(w.WINAPI) w.BOOL, .{.name = "QueryPerformanceCounter"});
    const qpf = @extern(*const fn(*i64) callconv(w.WINAPI) w.BOOL, .{.name = "QueryPerformanceFrequency"});
    _ = qpf(&t_f);
    _ = qpc(&t_c);
    const t_start = t_c;

    // Conv1: Grid=(3000,1,1), Block=(256,1,1), C_in=128, C_out=1280, K=3, stride=1, pad=1
    var a_out=d_conv1_out; var a_in=d_mel; var a_w=d_c1w; var a_b=d_c1b;
    var a_cin:u32=N_MELS; var a_cout:u32=D; var a_lin:u32=N_FRAMES; var a_k:u32=3; var a_s:u32=1; var a_p:u32=1;
    var p1=[_]?*anyopaque{@ptrCast(&a_out),@ptrCast(&a_in),@ptrCast(&a_w),@ptrCast(&a_b),
        @ptrCast(&a_cin),@ptrCast(&a_cout),@ptrCast(&a_lin),@ptrCast(&a_k),@ptrCast(&a_s),@ptrCast(&a_p)};
    _ = cuLaunch(fn_conv1d, N_FRAMES,1,1, 256,1,1, 0,null, &p1, null);

    // Conv2: Grid=(1500,1,1), Block=(256,1,1), C_in=1280, C_out=1280, K=3, stride=2, pad=1
    a_out=d_conv2_out; a_in=d_conv1_out; a_w=d_c2w; a_b=d_c2b;
    a_cin=D; a_cout=D; a_lin=N_FRAMES; a_k=3; a_s=2; a_p=1;
    var p2=[_]?*anyopaque{@ptrCast(&a_out),@ptrCast(&a_in),@ptrCast(&a_w),@ptrCast(&a_b),
        @ptrCast(&a_cin),@ptrCast(&a_cout),@ptrCast(&a_lin),@ptrCast(&a_k),@ptrCast(&a_s),@ptrCast(&a_p)};
    _ = cuLaunch(fn_conv1d, SEQ,1,1, 256,1,1, 0,null, &p2, null);

    _ = cuSync();
    _ = qpc(&t_c);
    const conv_ms = @as(f64, @floatFromInt(t_c - t_start)) / @as(f64, @floatFromInt(t_f)) * 1000.0;
    try out.print("[7] Conv1D×2 done in {d:.1}ms\n", .{conv_ms});

    // 8. Add positional embedding: conv2_out[c][t] += pos_emb[t][c] → transpose to [1500][1280]
    var enc_input = try alloc.alloc(f32, SEQ * D);
    const conv2_buf = try alloc.alloc(f32, D * SEQ);
    _ = cuD2H(conv2_buf.ptr, @ptrFromInt(d_conv2_out), D * SEQ * 4);
    const pos_f32 = std.mem.bytesAsSlice(f32, pos_data);

    // Transpose [D][SEQ] → [SEQ][D] + add pos_emb[SEQ][D]
    for (0..SEQ) |t| {
        for (0..D) |c| {
            enc_input[t * D + c] = conv2_buf[c * SEQ + t] + pos_f32[t * D + c];
        }
    }
    try out.print("[8] Transposed + positional embedding added\n", .{});

    // 9. Save as binary file
    const file = try std.fs.cwd().createFile(out_path, .{});
    defer file.close();
    try file.writeAll(std.mem.sliceAsBytes(enc_input));
    try out.print("[9] Saved standalone encoder input to {s} OK\n\n", .{out_path});
}
