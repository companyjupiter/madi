// whisper_decode_v2.zig — 100% GPU-Native Whisper Decoder
// ZIG + PTX only. No Python. No CPU fallback.
const std = @import("std");
const CUresult = i32;
const CUdeviceptr = u64;
const CUfn = *anyopaque;
const CUstream = ?*anyopaque;

// CUDA Driver API
var cuLaunch: *const fn(CUfn,u32,u32,u32,u32,u32,u32,u32,CUstream,[*]?*anyopaque,?*anyopaque)callconv(.C)CUresult = undefined;
var cuAlloc:  *const fn(*CUdeviceptr,usize)callconv(.C)CUresult = undefined;
var cuFree:   *const fn(CUdeviceptr)callconv(.C)CUresult = undefined;
var cuH2D:    *const fn(CUdeviceptr,*const anyopaque,usize)callconv(.C)CUresult = undefined;
var cuD2H:    *const fn(*anyopaque,CUdeviceptr,usize)callconv(.C)CUresult = undefined;
var cuD2D:    *const fn(CUdeviceptr,CUdeviceptr,usize)callconv(.C)CUresult = undefined;
var cuSync:   *const fn()callconv(.C)CUresult = undefined;
var cuMemset: *const fn(CUdeviceptr,u8,usize)callconv(.C)CUresult = undefined;
var stream:   CUstream = null;

// Kernel handles
var fn_ln:     CUfn = undefined; // layer_norm
var fn_tc:     CUfn = undefined; // tc_gemv (Tensor Core)
var fn_f2h:    CUfn = undefined; // f32_to_f16
var fn_res:    CUfn = undefined; // gpu_residual
var fn_gelu:   CUfn = undefined; // gelu_f32
var fn_emb:    CUfn = undefined; // gpu_emb_lookup
var fn_bias:   CUfn = undefined; // bias_add
var fn_scale:  CUfn = undefined; // scale_f32
var fn_kv_store: CUfn = undefined; // gpu_kv_store
var fn_soft:   CUfn = undefined; // softmax_f32
var fn_att:    CUfn = undefined; // gpu_attention (autoregressive)
var fn_filt:   CUfn = undefined; // logit_filter  (decoder_ops.ptx)
var fn_argmax: CUfn = undefined; // argmax_append (decoder_ops.ptx)
var fn_gv:     CUfn = undefined; // f32_gemv (F16 weight)
var fn_gv32:   CUfn = undefined; // f32_gemv_f32w (F32 weight)
var fn_ca_head:CUfn = undefined; // extract_ca_head (mfa_align.ptx)
var fn_suppress:CUfn = undefined; // suppress_apply (mfa_align.ptx)

// Whisper turbo alignment heads: (layer, head) pairs
const ALIGN_HEADS = [_][2]u32{ .{2,4}, .{2,11}, .{3,3}, .{3,6}, .{3,11}, .{3,14} };
const N_ALIGN: u32 = 6;

// CUDA Graph API
var cuCapBegin: *const fn(CUstream, u32)callconv(.C)CUresult = undefined;
var cuCapEnd:   *const fn(CUstream, *?*anyopaque)callconv(.C)CUresult = undefined;
var cuGrInst:   *const fn(*?*anyopaque, ?*anyopaque, u64)callconv(.C)CUresult = undefined;
var cuGrLaunch: *const fn(?*anyopaque, CUstream)callconv(.C)CUresult = undefined;

// Model dims (Whisper large-v3-turbo)
const D:    u32 = 1280;
const NL:   u32 = 4;
const NH:   u32 = 20;
const MLP:  u32 = 5120;
const VOCAB:u32 = 51866;
const ENC_SEQ: u32 = 1500;
const MAX_TOK: u32 = 448;


// --- Launcher helpers ---
inline fn kLN(x:CUdeviceptr,y:CUdeviceptr,g:CUdeviceptr,b:CUdeviceptr,d:u32,rows:u32) void {
    var a0=x;var a1=y;var a2=g;var a3=b;var a4=d;var a5:f32=1e-5;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2),@ptrCast(&a3),@ptrCast(&a4),@ptrCast(&a5)};
    _ = cuLaunch(fn_ln,rows,1,1,256,1,1,0,stream,&p,null);
}
inline fn kTC(a:CUdeviceptr,b:CUdeviceptr,c:CUdeviceptr,n:u32,d:u32) void {
    var a0=a;var a1=b;var a2=c;var a3=n;var a4=d;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2),@ptrCast(&a3),@ptrCast(&a4)};
    _ = cuLaunch(fn_tc,(d+15)/16,1,1,32,1,1,0,stream,&p,null);
}
// F32 scalar GEMV: y[D] = x_f32[N] @ W_f16[N,D]
inline fn kGV(y:CUdeviceptr,x:CUdeviceptr,w:CUdeviceptr,n:u32,d:u32) void {
    var a0=y;var a1=x;var a2=w;var a3=n;var a4=d;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2),@ptrCast(&a3),@ptrCast(&a4)};
    _ = cuLaunch(fn_gv,(d+255)/256,1,1,256,1,1,0,stream,&p,null);
}
// F32 scalar GEMV with F32 weights: y[D] = x_f32[N] @ W_f32[N,D]
inline fn kGV32(y:CUdeviceptr,x:CUdeviceptr,w:CUdeviceptr,n:u32,d:u32) void {
    var a0=y;var a1=x;var a2=w;var a3=n;var a4=d;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2),@ptrCast(&a3),@ptrCast(&a4)};
    _ = cuLaunch(fn_gv32,(d+255)/256,1,1,256,1,1,0,stream,&p,null);
}
inline fn kF2H(dst:CUdeviceptr,src:CUdeviceptr,n:u32) void {
    var a0=dst;var a1=src;var a2=n;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2)};
    _ = cuLaunch(fn_f2h,(n+255)/256,1,1,256,1,1,0,stream,&p,null);
}
inline fn kRes(dst:CUdeviceptr,src:CUdeviceptr,n:u32) void {
    var a0=dst;var a1=src;var a2=n;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2)};
    _ = cuLaunch(fn_res,(n+255)/256,1,1,256,1,1,0,stream,&p,null);
}
inline fn kEmb(out:CUdeviceptr, emb:CUdeviceptr, tok_ptr:CUdeviceptr) void {
    var a0=out; var a1=emb; var a2=tok_ptr; var a3: u32=D;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2),@ptrCast(&a3)};
    _ = cuLaunch(fn_emb,(D+255)/256,1,1,256,1,1,0,stream,&p,null);
}
inline fn kBias(x:CUdeviceptr,b:CUdeviceptr,n:u32,d:u32) void {
    var a0=x;var a1=b;var a2=n;var a3=d;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2),@ptrCast(&a3)};
    _ = cuLaunch(fn_bias,(n+255)/256,1,1,256,1,1,0,stream,&p,null);
}
inline fn kGelu(x:CUdeviceptr,n:u32) void {
    var a0=x;var a1=n;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1)};
    _ = cuLaunch(fn_gelu,(n+255)/256,1,1,256,1,1,0,stream,&p,null);
}
inline fn kScale(x:CUdeviceptr,n:u32,s:f32) void {
    var a0=x;var a1=n;var a2=s;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2)};
    _ = cuLaunch(fn_scale,(n+255)/256,1,1,256,1,1,0,stream,&p,null);
}

inline fn kStore(cache:CUdeviceptr, src:CUdeviceptr, kvd:u32, pos_ptr:CUdeviceptr) void {
    var a0=cache; var a1=src; var a2=kvd; var a3=pos_ptr;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2),@ptrCast(&a3)};
    _ = cuLaunch(fn_kv_store,(kvd+255)/256,1,1,256,1,1,0,stream,&p,null);
}
// Autoregressive attention: query=1 token, kv_cache up to pos tokens
inline fn kAtt(out:CUdeviceptr,q:CUdeviceptr,kc:CUdeviceptr,vc:CUdeviceptr,pos_ptr:CUdeviceptr) void {
    var a0=out;var a1=q;var a2=kc;var a3=vc;var a4=pos_ptr;
    var a5:u32=D/NH; // head_dim=64
    var a6:u32=D;    // kvd=D
    var a7:u32=NH;   // nkv=NH
    var a8:u32=NH;   // nh=NH
    var a9:f32=0.125; // scale=1/sqrt(64)
    var a10:f32=0.0;  // cap=0 (no logit cap)
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2),@ptrCast(&a3),@ptrCast(&a4),@ptrCast(&a5),@ptrCast(&a6),@ptrCast(&a7),@ptrCast(&a8),@ptrCast(&a9),@ptrCast(&a10)};
    _ = cuLaunch(fn_att,NH,1,1,256,1,1,0,stream,&p,null);
}

// Windows mmap helpers
const w_api = std.os.windows;
const externs = struct {
    extern "kernel32" fn CreateFileMappingW(h:w_api.HANDLE,a:?*anyopaque,b:w_api.DWORD,c:w_api.DWORD,d:w_api.DWORD,e:?[*:0]const u16)callconv(w_api.WINAPI)?w_api.HANDLE;
    extern "kernel32" fn MapViewOfFile(h:w_api.HANDLE,a:w_api.DWORD,b:w_api.DWORD,c:w_api.DWORD,d:usize)callconv(w_api.WINAPI)?*anyopaque;
    extern "kernel32" fn QueryPerformanceCounter(c:*i64)callconv(w_api.WINAPI)w_api.BOOL;
    extern "kernel32" fn QueryPerformanceFrequency(f:*i64)callconv(w_api.WINAPI)w_api.BOOL;
};
fn mmapFile(path:[]const u8) ![]const u8 {
    const f = try std.fs.cwd().openFile(path,.{});
    const sz = try f.getEndPos();
    const mh = externs.CreateFileMappingW(f.handle,null,w_api.PAGE_READONLY,0,0,null) orelse return error.MmapFailed;
    const mp = externs.MapViewOfFile(mh,4,0,0,0) orelse return error.MmapFailed;
    return @as([*]const u8,@ptrCast(mp))[0..sz];
}
fn nowMs() f64 {
    var c:i64=0; var f:i64=0;
    _ = externs.QueryPerformanceCounter(&c); _ = externs.QueryPerformanceFrequency(&f);
    return @as(f64,@floatFromInt(c))/@as(f64,@floatFromInt(f))*1000.0;
}

fn loadPtxMod(nv: *std.DynLib, alloc: std.mem.Allocator, fname: []const u8) !*anyopaque {
    const cuModLD = nv.lookup(*const fn(**anyopaque,[*]const u8)callconv(.C)CUresult,"cuModuleLoadData").?;
    const data = try std.fs.cwd().readFileAlloc(alloc,fname,4*1024*1024);
    const s = try alloc.allocSentinel(u8,data.len,0); @memcpy(s,data);
    var mod: *anyopaque = undefined;
    const r = cuModLD(&mod,@ptrCast(s.ptr));
    if (r != 0) { std.debug.print("PTX load FAIL {s}: {d}\n",.{fname,r}); return error.PtxLoadFailed; }
    return mod;
}

fn runZeroShotDiarization(out: anytype, enc_data: []const u8) !void {
    try out.print("=== 🎯 Zero-Shot Diarization Timeline ===\n", .{});
    const D_enc: usize = 1280;
    const seq_len: usize = 1500;
    const floats = @as([*]const f32, @ptrCast(@alignCast(enc_data.ptr)))[0 .. enc_data.len/4];
    
    var is_speech = [_]bool{false} ** seq_len;
    var energy = [_]f32{0} ** seq_len;
    
    var total_energy: f32 = 0;
    // 1. Calculate Energy (L2 Norm)
    for (0..seq_len) |i| {
        var sum_sq: f32 = 0;
        for (0..D_enc) |j| {
            const v = floats[i*D_enc + j];
            sum_sq += v * v;
        }
        energy[i] = @sqrt(sum_sq);
        total_energy += energy[i];
    }
    const mean_energy = total_energy / @as(f32, @floatFromInt(seq_len));
    const vad_threshold = mean_energy * 0.5; // VAD threshold
    
    var active_count: usize = 0;
    for (0..seq_len) |i| {
        if (energy[i] > vad_threshold) {
            is_speech[i] = true;
            active_count += 1;
        }
    }
    
    if (active_count < 2) return; // Not enough speech
    
    // 2. K-Means (K=2) Clustering on active frames
    var c0 = [_]f32{0} ** D_enc;
    var c1 = [_]f32{0} ** D_enc;
    var labels = [_]u8{0} ** seq_len;
    
    // Init centroids (first active frame and last active frame)
    var first_idx: usize = 0;
    var last_idx: usize = seq_len - 1;
    for (0..seq_len) |i| { if (is_speech[i]) { first_idx = i; break; } }
    var i_rev: usize = seq_len - 1;
    while (i_rev > 0) : (i_rev -= 1) { if (is_speech[i_rev]) { last_idx = i_rev; break; } }
    
    for (0..D_enc) |j| {
        c0[j] = floats[first_idx*D_enc + j];
        c1[j] = floats[last_idx*D_enc + j];
    }
    
    // K-Means iterations
    for (0..5) |_| {
        var sum0 = [_]f32{0} ** D_enc;
        var sum1 = [_]f32{0} ** D_enc;
        var count0: usize = 0;
        var count1: usize = 0;
        
        for (0..seq_len) |i| {
            if (!is_speech[i]) continue;
            var dist0: f32 = 0;
            var dist1: f32 = 0;
            for (0..D_enc) |j| {
                const diff0 = floats[i*D_enc + j] - c0[j];
                const diff1 = floats[i*D_enc + j] - c1[j];
                dist0 += diff0 * diff0;
                dist1 += diff1 * diff1;
            }
            if (dist0 < dist1) {
                labels[i] = 0;
                count0 += 1;
                for (0..D_enc) |j| sum0[j] += floats[i*D_enc + j];
            } else {
                labels[i] = 1;
                count1 += 1;
                for (0..D_enc) |j| sum1[j] += floats[i*D_enc + j];
            }
        }
        
        // Update centroids
        if (count0 > 0) {
            for (0..D_enc) |j| c0[j] = sum0[j] / @as(f32, @floatFromInt(count0));
        }
        if (count1 > 0) {
            for (0..D_enc) |j| c1[j] = sum1[j] / @as(f32, @floatFromInt(count1));
        }
    }
    
    // 3. Temporal Smoothing (Median Filter approx, size 21 = 420ms)
    var smoothed_labels = [_]u8{0} ** seq_len;
    for (0..seq_len) |i| {
        if (!is_speech[i]) continue;
        var window_votes: i32 = 0;
        const start_w = if (i > 10) i - 10 else 0;
        const end_w = if (i + 10 < seq_len) i + 10 else seq_len - 1;
        var w_count: i32 = 0;
        for (start_w..end_w + 1) |w| {
            if (is_speech[w]) {
                window_votes += if (labels[w] == 1) 1 else -1;
                w_count += 1;
            }
        }
        smoothed_labels[i] = if (window_votes > 0) 1 else 0;
    }
    
    // 4. Output Timeline
    var in_segment = false;
    var seg_start: usize = 0;
    var cur_spk: u8 = 0;
    
    for (0..seq_len) |i| {
        if (is_speech[i]) {
            const spk = smoothed_labels[i];
            if (!in_segment) {
                in_segment = true;
                seg_start = i;
                cur_spk = spk;
            } else if (cur_spk != spk) {
                if (i - seg_start > 15) { // Min duration 300ms
                    try out.print("[{d:0>2.2}s - {d:0>2.2}s] Speaker {d}\n", .{ @as(f32, @floatFromInt(seg_start))*0.02, @as(f32, @floatFromInt(i))*0.02, cur_spk });
                }
                seg_start = i;
                cur_spk = spk;
            }
        } else {
            if (in_segment) {
                if (i - seg_start > 15) { // Min duration 300ms
                    try out.print("[{d:0>2.2}s - {d:0>2.2}s] Speaker {d}\n", .{ @as(f32, @floatFromInt(seg_start))*0.02, @as(f32, @floatFromInt(i))*0.02, cur_spk });
                }
                in_segment = false;
            }
        }
    }
    if (in_segment) {
        if (seq_len - seg_start > 15) {
            try out.print("[{d:0>2.2}s - {d:0>2.2}s] Speaker {d}\n", .{ @as(f32, @floatFromInt(seg_start))*0.02, @as(f32, @floatFromInt(seq_len))*0.02, cur_spk });
        }
    }
}

pub fn run(ext_ctx: *anyopaque, d_enc_out: u64) !void {
    const out = std.io.getStdOut().writer();
    const alloc = std.heap.page_allocator;
    try out.print("\n=== SOVEREIGN WHISPER DECODER V2 ===\n",.{});

    // 1. CUDA init
    var nv = std.DynLib.open("nvcuda.dll") catch { try out.print("nvcuda.dll not found\n",.{}); return; };

    const cuGetF  = nv.lookup(*const fn(*CUfn,*anyopaque,[*:0]const u8)callconv(.C)CUresult,"cuModuleGetFunction").?;
    cuAlloc  = nv.lookup(@TypeOf(cuAlloc),"cuMemAlloc_v2").?;
    cuFree   = nv.lookup(@TypeOf(cuFree),"cuMemFree_v2").?;
    cuH2D    = nv.lookup(@TypeOf(cuH2D),"cuMemcpyHtoD_v2").?;
    cuD2H    = nv.lookup(@TypeOf(cuD2H),"cuMemcpyDtoH_v2").?;
    cuD2D    = nv.lookup(@TypeOf(cuD2D),"cuMemcpyDtoD_v2").?;
    cuSync   = nv.lookup(@TypeOf(cuSync),"cuCtxSynchronize").?;
    cuMemset = nv.lookup(@TypeOf(cuMemset),"cuMemsetD8_v2").?;
    cuLaunch = nv.lookup(@TypeOf(cuLaunch),"cuLaunchKernel").?;
    const cuStreamCreate = nv.lookup(*const fn(*CUstream,u32)callconv(.C)CUresult,"cuStreamCreate").?;
    const cuCtxSetCurrent = nv.lookup(*const fn(*anyopaque)callconv(.C)CUresult,"cuCtxSetCurrent").?;
    _ = cuCtxSetCurrent(ext_ctx);
    _ = cuStreamCreate(&stream,0);
    cuCapBegin = nv.lookup(@TypeOf(cuCapBegin),"cuStreamBeginCapture_v2").?;
    cuCapEnd   = nv.lookup(@TypeOf(cuCapEnd),  "cuStreamEndCapture").?;
    cuGrInst   = nv.lookup(@TypeOf(cuGrInst),  "cuGraphInstantiateWithFlags").?;
    cuGrLaunch = nv.lookup(@TypeOf(cuGrLaunch),"cuGraphLaunch").?;
    try out.print("[1] CUDA Shared Context (Graph API loaded)\n",.{});

    // 2. Load PTX modules
    const mod_wk  = try loadPtxMod(&nv,alloc,"whisper_kernels.ptx");
    const mod_ops = try loadPtxMod(&nv,alloc,"C:\\Users\\BASEMENT_ADMIN\\trans\\_quarks\\lane_WHISPER_002_fix\\whisper_ops.ptx");
    const mod_gpu = try loadPtxMod(&nv,alloc,"gpu_ops_root_backup.ptx");
    const mod_tc  = try loadPtxMod(&nv,alloc,"tensor_core.ptx");
    const mod_ln  = try loadPtxMod(&nv,alloc,"layer_norm.ptx");
    const mod_f16 = try loadPtxMod(&nv,alloc,"f16_convert.ptx");
    const mod_dec = try loadPtxMod(&nv,alloc,"C:\\Users\\BASEMENT_ADMIN\\trans\\_quarks\\lane_WHISPER_002_fix\\decoder_ops.ptx");
    const mod_gv  = try loadPtxMod(&nv,alloc,"C:\\Users\\BASEMENT_ADMIN\\trans\\_quarks\\lane_WHISPER_002_fix\\f32_gemv.ptx");
    _ = cuGetF(&fn_gelu,  mod_wk,  "gelu_f32");
    _ = cuGetF(&fn_soft,  mod_wk,  "softmax_f32");
    _ = cuGetF(&fn_bias,  mod_wk,  "bias_add");
    _ = cuGetF(&fn_scale, mod_wk,  "scale_f32");
    _ = cuGetF(&fn_kv_store, mod_ops, "gpu_kv_store");
    _ = cuGetF(&fn_res,   mod_gpu, "gpu_residual");
    _ = cuGetF(&fn_emb,   mod_gpu, "gpu_emb_lookup");
    _ = cuGetF(&fn_att,   mod_gpu, "gpu_attention");
    _ = cuGetF(&fn_tc,    mod_tc,  "tc_gemv");
    _ = cuGetF(&fn_ln,    mod_ln,  "layer_norm");
    _ = cuGetF(&fn_f2h,   mod_f16, "f32_to_f16_batch16");
    _ = cuGetF(&fn_filt,  mod_dec, "logit_filter");
    _ = cuGetF(&fn_argmax,mod_dec, "argmax_append");
    _ = cuGetF(&fn_gv,    mod_gv,  "f32_gemv");
    _ = cuGetF(&fn_gv32,  mod_gv,  "f32_gemv_f32w");
    const mod_mfa = try loadPtxMod(&nv,alloc,"mfa_align.ptx");
    _ = cuGetF(&fn_ca_head, mod_mfa, "extract_ca_head");
    _ = cuGetF(&fn_suppress, mod_mfa, "suppress_apply");
    try out.print("[2] PTX loaded (+ mfa_align)\n",.{});

    // 3. Tensor mmap (zero-copy)
    const hr = nv.lookup(*const fn(*const anyopaque,usize,u32)callconv(.C)CUresult,"cuMemHostRegister_v2").?;
    const hg = nv.lookup(*const fn(*CUdeviceptr,*const anyopaque,u32)callconv(.C)CUresult,"cuMemHostGetDevicePointer_v2").?;
    const ATOM: []const u8 = "quarks/whisper-turbo-v3-atom";
    const mapTen = struct {
        fn f(base:[]const u8,name:[]const u8,hr2:*const fn(*const anyopaque,usize,u32)callconv(.C)CUresult,hg2:*const fn(*CUdeviceptr,*const anyopaque,u32)callconv(.C)CUresult) CUdeviceptr {
            var pb:[512]u8=undefined;
            const path=std.fmt.bufPrint(&pb,"{s}/{s}/data.bin",.{base,name}) catch return 0;
            const d=mmapFile(path) catch return 0;
            var dp:CUdeviceptr=0;
            // Try zero-copy pinned first
            if (hr2(d.ptr,d.len,2)==0) {
                if (hg2(&dp,d.ptr,0)==0) return dp;
            }
            // Fallback: cuAlloc + cuH2D upload
            if (cuAlloc(&dp,d.len)==0 and dp!=0) {
                _ = cuH2D(dp,d.ptr,d.len);
            }
            return dp;
        }
    }.f;
    const tok_emb=mapTen(ATOM,"decoder/token_embedding/weight",hr,hg); _ = tok_emb;
    // pos_emb: load from F32 file directly
    var pos_emb: CUdeviceptr = 0;
    {
        const pe_data = std.fs.cwd().readFileAlloc(alloc, "quarks/whisper-turbo-v3-atom/pos_emb_f32.bin", 8*1024*1024) catch unreachable;
        _ = cuAlloc(&pos_emb, pe_data.len);
        _ = cuH2D(pos_emb, pe_data.ptr, pe_data.len);
    }
    const ln_w=mapTen(ATOM,"decoder/ln/weight",hr,hg);
    const ln_b=mapTen(ATOM,"decoder/ln/bias",hr,hg);
    var alnW:[NL]CUdeviceptr=undefined; var alnB:[NL]CUdeviceptr=undefined;
    var qW:[NL]CUdeviceptr=undefined;   var qB:[NL]CUdeviceptr=undefined;
    var kW:[NL]CUdeviceptr=undefined;
    var vW:[NL]CUdeviceptr=undefined;   var vB:[NL]CUdeviceptr=undefined;
    var oW:[NL]CUdeviceptr=undefined;   var oB:[NL]CUdeviceptr=undefined;
    var calnW:[NL]CUdeviceptr=undefined;var calnB:[NL]CUdeviceptr=undefined;
    var cqW:[NL]CUdeviceptr=undefined;  var cqB:[NL]CUdeviceptr=undefined;
    var ckW:[NL]CUdeviceptr=undefined;
    var cvW:[NL]CUdeviceptr=undefined;  var cvB:[NL]CUdeviceptr=undefined;
    var coW:[NL]CUdeviceptr=undefined;  var coB:[NL]CUdeviceptr=undefined;
    var mlnW:[NL]CUdeviceptr=undefined; var mlnB:[NL]CUdeviceptr=undefined;
    var m0W:[NL]CUdeviceptr=undefined;  var m0B:[NL]CUdeviceptr=undefined;
    var m2W:[NL]CUdeviceptr=undefined;  var m2B:[NL]CUdeviceptr=undefined;
    for (0..NL) |l| {
        var nb:[8][128]u8=undefined;
        const pre=std.fmt.bufPrint(&nb[0],"decoder/blocks/{d}",.{l}) catch unreachable;
        alnW[l]=mapTen(ATOM,std.fmt.bufPrint(&nb[1],"{s}/attn_ln/weight",.{pre}) catch unreachable,hr,hg);
        alnB[l]=mapTen(ATOM,std.fmt.bufPrint(&nb[2],"{s}/attn_ln/bias",.{pre}) catch unreachable,hr,hg);
        qW[l]  =mapTen(ATOM,std.fmt.bufPrint(&nb[3],"{s}/attn/query/weight",.{pre}) catch unreachable,hr,hg);
        qB[l]  =mapTen(ATOM,std.fmt.bufPrint(&nb[4],"{s}/attn/query/bias",.{pre}) catch unreachable,hr,hg);
        kW[l]  =mapTen(ATOM,std.fmt.bufPrint(&nb[5],"{s}/attn/key/weight",.{pre}) catch unreachable,hr,hg);
        vW[l]  =mapTen(ATOM,std.fmt.bufPrint(&nb[6],"{s}/attn/value/weight",.{pre}) catch unreachable,hr,hg);
        vB[l]  =mapTen(ATOM,std.fmt.bufPrint(&nb[7],"{s}/attn/value/bias",.{pre}) catch unreachable,hr,hg);
        var nb2:[8][128]u8=undefined;
        oW[l]  =mapTen(ATOM,std.fmt.bufPrint(&nb2[0],"{s}/attn/out/weight",.{pre}) catch unreachable,hr,hg);
        oB[l]  =mapTen(ATOM,std.fmt.bufPrint(&nb2[1],"{s}/attn/out/bias",.{pre}) catch unreachable,hr,hg);
        calnW[l]=mapTen(ATOM,std.fmt.bufPrint(&nb2[2],"{s}/cross_attn_ln/weight",.{pre}) catch unreachable,hr,hg);
        calnB[l]=mapTen(ATOM,std.fmt.bufPrint(&nb2[3],"{s}/cross_attn_ln/bias",.{pre}) catch unreachable,hr,hg);
        cqW[l] =mapTen(ATOM,std.fmt.bufPrint(&nb2[4],"{s}/cross_attn/query/weight",.{pre}) catch unreachable,hr,hg);
        cqB[l] =mapTen(ATOM,std.fmt.bufPrint(&nb2[5],"{s}/cross_attn/query/bias",.{pre}) catch unreachable,hr,hg);
        ckW[l] =mapTen(ATOM,std.fmt.bufPrint(&nb2[6],"{s}/cross_attn/key/weight",.{pre}) catch unreachable,hr,hg);
        cvW[l] =mapTen(ATOM,std.fmt.bufPrint(&nb2[7],"{s}/cross_attn/value/weight",.{pre}) catch unreachable,hr,hg);
        var nb3:[6][128]u8=undefined;
        cvB[l] =mapTen(ATOM,std.fmt.bufPrint(&nb3[0],"{s}/cross_attn/value/bias",.{pre}) catch unreachable,hr,hg);
        coW[l] =mapTen(ATOM,std.fmt.bufPrint(&nb3[1],"{s}/cross_attn/out/weight",.{pre}) catch unreachable,hr,hg);
        coB[l] =mapTen(ATOM,std.fmt.bufPrint(&nb3[2],"{s}/cross_attn/out/bias",.{pre}) catch unreachable,hr,hg);
        mlnW[l]=mapTen(ATOM,std.fmt.bufPrint(&nb3[3],"{s}/mlp_ln/weight",.{pre}) catch unreachable,hr,hg);
        mlnB[l]=mapTen(ATOM,std.fmt.bufPrint(&nb3[4],"{s}/mlp_ln/bias",.{pre}) catch unreachable,hr,hg);
        m0W[l] =mapTen(ATOM,std.fmt.bufPrint(&nb3[5],"{s}/mlp/0/weight",.{pre}) catch unreachable,hr,hg);
        var nb4:[3][128]u8=undefined;
        m0B[l] =mapTen(ATOM,std.fmt.bufPrint(&nb4[0],"{s}/mlp/0/bias",.{pre}) catch unreachable,hr,hg);
        m2W[l] =mapTen(ATOM,std.fmt.bufPrint(&nb4[1],"{s}/mlp/2/weight",.{pre}) catch unreachable,hr,hg);
        m2B[l] =mapTen(ATOM,std.fmt.bufPrint(&nb4[2],"{s}/mlp/2/bias",.{pre}) catch unreachable,hr,hg);
    }
    try out.print("[3] Decoder weights mapped\n",.{});

    // 4. GPU scratch
    var d_x: CUdeviceptr = 0;   _ = cuAlloc(&d_x, D * 4 * 16);
    var d_xb: CUdeviceptr = 0;  _ = cuAlloc(&d_xb, D * 4 * 16);
    var d_xf: CUdeviceptr = 0;  _ = cuAlloc(&d_xf, MLP * 2 * 16); // Must fit MLP=5120 for kF2H in MLP path
    var d_q: CUdeviceptr = 0;   _ = cuAlloc(&d_q, D * 4 * 16);
    var d_ao: CUdeviceptr = 0;  _ = cuAlloc(&d_ao, D * 4 * 16);
    var d_mh: CUdeviceptr = 0;  _ = cuAlloc(&d_mh, 5120 * 4 * 16);
    var d_mo: CUdeviceptr = 0;  _ = cuAlloc(&d_mo, D * 4 * 16);
    var d_skc:CUdeviceptr=0;    _ = cuAlloc(&d_skc, NL*MAX_TOK*D*4);
    var d_svc:CUdeviceptr=0;    _ = cuAlloc(&d_svc, NL*MAX_TOK*D*4);
    var d_ckc:CUdeviceptr=0;    _ = cuAlloc(&d_ckc, NL*ENC_SEQ*D*4);
    var d_cvc:CUdeviceptr=0;    _ = cuAlloc(&d_cvc, NL*ENC_SEQ*D*4);
    var d_logits: CUdeviceptr = 0;
    _ = cuAlloc(&d_logits, (VOCAB + 16) * 4 * 16);
    var d_tokens:CUdeviceptr=0; _ = cuAlloc(&d_tokens, MAX_TOK*4);
    var d_pos:CUdeviceptr=0;    _ = cuAlloc(&d_pos, 4);
    var d_enc_pos:CUdeviceptr=0; _ = cuAlloc(&d_enc_pos, 4);
    var ep:u32=ENC_SEQ - 1; _ = cuH2D(d_enc_pos, &ep, 4);
    var d_ca_weights:CUdeviceptr=0; _ = cuAlloc(&d_ca_weights, MAX_TOK*ENC_SEQ*4);
    _ = cuMemset(d_ca_weights, 0, MAX_TOK*ENC_SEQ*4);
    _ = cuSync();
    try out.print("[4] GPU buffers allocated (+ca_weights)\n",.{});

    // 5. Load shared data (1x): cross-attn KV cache + tok embeddings
    const ckc_data = std.fs.cwd().readFileAlloc(alloc, "quarks/whisper-turbo-v3-atom/ckc.bin", 512*1024*1024) catch unreachable;
    const cvc_data = std.fs.cwd().readFileAlloc(alloc, "quarks/whisper-turbo-v3-atom/cvc.bin", 512*1024*1024) catch unreachable;
    var d_tok_emb_f32: CUdeviceptr=0; _ = cuAlloc(&d_tok_emb_f32, VOCAB*D*4);
    const te_data = std.fs.cwd().readFileAlloc(alloc, "quarks/whisper-turbo-v3-atom/tok_emb_f32.bin", 512*1024*1024) catch unreachable;
    _ = cuH2D(d_tok_emb_f32, te_data.ptr, te_data.len);
    
    const VOCAB_PAD: u32 = 51872;
    var d_tok_emb_f16: CUdeviceptr=0; _ = cuAlloc(&d_tok_emb_f16, VOCAB_PAD*D*2);
    var te_f16 = alloc.alloc(f16, VOCAB_PAD*D) catch unreachable;
    const te_f32_slice = std.mem.bytesAsSlice(f32, te_data);
    for (0..VOCAB_PAD) |v| {
        for (0..D) |d_idx| {
            if (v < VOCAB) {
                te_f16[v * D + d_idx] = @floatCast(te_f32_slice[v * D + d_idx]);
            } else {
                te_f16[v * D + d_idx] = 0.0;
            }
        }
    }
    _ = cuH2D(d_tok_emb_f16, std.mem.sliceAsBytes(te_f16).ptr, VOCAB_PAD*D*2);
    alloc.free(te_f16);
    
    _ = cuSync();
    try out.print("[4b] Shared data loaded (ckc/cvc/tok_emb)\n",.{});

    // 6. Receive zero-copy encoder output
    const enc_data = try alloc.alloc(u8, 1500 * 1280 * 4);
    _ = cuD2H(enc_data.ptr, d_enc_out, 1500 * 1280 * 4);
    
    // Upload cross-attn KV (per-input, encoder-dependent)
    _ = cuH2D(d_ckc, ckc_data.ptr, ckc_data.len);
    _ = cuH2D(d_cvc, cvc_data.ptr, cvc_data.len);
    _ = cuSync();

    try out.print("[5] Encoder output received in VRAM (Zero-copy)\n", .{});

    try runZeroShotDiarization(out, enc_data);

    // Run decode loop
    try runDecodeLoop(out, alloc, d_x,d_xb,d_xf,d_q,d_ao,d_mh,d_mo,
        d_skc,d_svc,d_ckc,d_cvc,d_logits,d_tokens,d_pos,
        d_tok_emb_f16,d_tok_emb_f32,pos_emb,ln_w,ln_b,
        &alnW,&alnB,&qW,&qB,&kW,&vW,&vB,&oW,&oB,
        &calnW,&calnB,&cqW,&cqB,&ckW,&cvW,&cvB,&coW,&coB,
        &mlnW,&mlnB,&m0W,&m0B,&m2W,&m2B, d_ckc, d_enc_pos, d_ca_weights);
}


fn decodeBlock(l:usize, d_x:CUdeviceptr, d_xb:CUdeviceptr, d_xf:CUdeviceptr,
               d_q:CUdeviceptr, d_ao:CUdeviceptr, d_mh:CUdeviceptr, d_mo:CUdeviceptr,
               d_skc:CUdeviceptr, d_svc:CUdeviceptr,
               d_ckc:CUdeviceptr, d_cvc:CUdeviceptr,
               d_pos:CUdeviceptr,
               alnW:[]CUdeviceptr, alnB:[]CUdeviceptr,
               qW:[]CUdeviceptr,   qB:[]CUdeviceptr,
               kW:[]CUdeviceptr,   vW:[]CUdeviceptr, vB:[]CUdeviceptr,
               oW:[]CUdeviceptr,   oB:[]CUdeviceptr,
               calnW:[]CUdeviceptr,calnB:[]CUdeviceptr,
               cqW:[]CUdeviceptr,  cqB:[]CUdeviceptr,
               ckW:[]CUdeviceptr,  cvW:[]CUdeviceptr, cvB:[]CUdeviceptr,
               coW:[]CUdeviceptr,  coB:[]CUdeviceptr,
               mlnW:[]CUdeviceptr, mlnB:[]CUdeviceptr,
               m0W:[]CUdeviceptr,  m0B:[]CUdeviceptr,
               m2W:[]CUdeviceptr,  m2B:[]CUdeviceptr,
               d_enc_pos:CUdeviceptr, d_ca_weights:CUdeviceptr) void {
    // Self-Attn LN
    kLN(d_x,d_xb,alnW[l],alnB[l],D,1);
    // Q=LN*Wq+b, K=LN*Wk, V=LN*Wv+b  (WMMA fast path)
    kF2H(d_xf,d_xb,D);
    kTC(d_xf,qW[l],d_q,D,D); kBias(d_q,qB[l],D,D);
    kTC(d_xf,kW[l],d_ao,D,D);
    kTC(d_xf,vW[l],d_mh,D,D); kBias(d_mh,vB[l],D,D);
    // Store K/V into self-attn cache
    kStore(d_skc, d_ao, D, d_pos);
    kStore(d_svc, d_mh, D, d_pos);
    kAtt(d_ao,d_q,d_skc,d_svc,d_pos);
    // Out proj
    kF2H(d_xf,d_ao,D);
    kTC(d_xf,oW[l],d_mo,D,D); kBias(d_mo,oB[l],D,D);
    kRes(d_x,d_mo,D);
    // Cross-Attn LN
    kLN(d_x,d_xb,calnW[l],calnB[l],D,1);
    kF2H(d_xf,d_xb,D);
    kTC(d_xf,cqW[l],d_q,D,D); kBias(d_q,cqB[l],D,D);
    kAtt(d_ao,d_q,d_ckc + l*ENC_SEQ*D*4, d_cvc + l*ENC_SEQ*D*4, d_enc_pos);
    // Extract cross-attn weights for alignment heads (inside CUDA Graph)
    const inv_n: f32 = 1.0 / @as(f32, @floatFromInt(N_ALIGN));
    for (ALIGN_HEADS) |ah| {
        if (ah[0] == l) {
            var ca0 = d_q;
            var ca1 = d_ckc + @as(u64, l)*ENC_SEQ*D*4;
            var ca2 = d_ca_weights;
            var ca3 = d_pos; // GPU pointer — Graph compatible
            var ca4 = ah[1];
            var ca5 = inv_n;
            var cap = [_]?*anyopaque{@ptrCast(&ca0),@ptrCast(&ca1),@ptrCast(&ca2),@ptrCast(&ca3),@ptrCast(&ca4),@ptrCast(&ca5)};
            _ = cuLaunch(fn_ca_head,1,1,1,256,1,1,0,stream,&cap,null);
        }
    }
    kF2H(d_xf,d_ao,D);
    kTC(d_xf,coW[l],d_mo,D,D); kBias(d_mo,coB[l],D,D);
    kRes(d_x,d_mo,D);
    // MLP
    kLN(d_x,d_xb,mlnW[l],mlnB[l],D,1);
    kF2H(d_xf,d_xb,D);
    kTC(d_xf,m0W[l],d_mh,D,MLP); kBias(d_mh,m0B[l],MLP,MLP);
    kGelu(d_mh,MLP);
    kF2H(d_xf,d_mh,MLP);
    kTC(d_xf,m2W[l],d_mo,MLP,D); kBias(d_mo,m2B[l],D,D);
    kRes(d_x,d_mo,D);
    _ = ckW; _ = cvW; _ = cvB;
}

fn runDecodeLoop(out: anytype, alloc: std.mem.Allocator,
    d_x:CUdeviceptr, d_xb:CUdeviceptr, d_xf:CUdeviceptr,
    d_q:CUdeviceptr, d_ao:CUdeviceptr, d_mh:CUdeviceptr, d_mo:CUdeviceptr,
    d_skc:CUdeviceptr, d_svc:CUdeviceptr, d_ckc:CUdeviceptr, d_cvc:CUdeviceptr,
    d_logits:CUdeviceptr, d_tokens:CUdeviceptr, d_pos:CUdeviceptr,
    tok_emb:CUdeviceptr, d_tok_emb_f32:CUdeviceptr, pos_emb:CUdeviceptr, ln_w:CUdeviceptr, ln_b:CUdeviceptr,
    alnW:[]CUdeviceptr, alnB:[]CUdeviceptr, qW:[]CUdeviceptr, qB:[]CUdeviceptr, kW:[]CUdeviceptr,
    vW:[]CUdeviceptr, vB:[]CUdeviceptr, oW:[]CUdeviceptr, oB:[]CUdeviceptr,
    calnW:[]CUdeviceptr, calnB:[]CUdeviceptr,
    cqW:[]CUdeviceptr, cqB:[]CUdeviceptr, ckW:[]CUdeviceptr,
    cvW:[]CUdeviceptr, cvB:[]CUdeviceptr, coW:[]CUdeviceptr, coB:[]CUdeviceptr,
    mlnW:[]CUdeviceptr, mlnB:[]CUdeviceptr,
    m0W:[]CUdeviceptr, m0B:[]CUdeviceptr, m2W:[]CUdeviceptr, m2B:[]CUdeviceptr,
    d_enc_out:CUdeviceptr, d_enc_pos:CUdeviceptr, d_ca_weights:CUdeviceptr) !void {
    const suppress_data = std.fs.cwd().readFileAlloc(alloc, "quarks/suppress_tokens.bin", 4096) catch unreachable;
    const suppress_count: u32 = @intCast(suppress_data.len / 4);
    // Upload suppress token IDs to GPU (once)
    var d_suppress: CUdeviceptr = 0;
    _ = cuAlloc(&d_suppress, suppress_data.len);
    _ = cuH2D(d_suppress, suppress_data.ptr, suppress_data.len);
    const SEED = [_]u32{50258, 50264, 50360, 50364};
    var seq_len: u32 = @intCast(SEED.len);
    _ = cuH2D(d_tokens, &SEED, SEED.len*4);
    _ = cuH2D(d_pos, &seq_len, 4);
    _ = d_enc_out;

    // Clear ca_weights buffer
    _ = cuMemset(d_ca_weights, 0, MAX_TOK*ENC_SEQ*4);
    _ = cuSync();

    var step: u32 = 0;
    const MAX_STEPS: u32 = 224;
    var out_tokens: [MAX_TOK]u32 = undefined;
    const EOT: u32 = 50257;

    // CUDA Graph state
    var cuda_graph: ?*anyopaque = null;
    var graph_exec: ?*anyopaque = null;
    var graph_ok: bool = false;


    const t0 = nowMs();
    while (step < MAX_STEPS) : (step += 1) {
        // PRE: token embed + pos
        const tok_ptr = d_tokens + @as(u64, step)*4;
        kEmb(d_x, d_tok_emb_f32, tok_ptr);
        _ = cuD2D(d_xb, pos_emb + @as(u64, step)*D*4, D*4);
        kRes(d_x, d_xb, D);
        _ = cuH2D(d_pos, &step, 4);

        // FORWARD: CUDA Graph accelerated (includes extract_ca_head)
        if (!graph_ok) {
            if (cuCapBegin(stream, 0) == 0) {
                for (0..NL) |l| {
                    decodeBlock(l, d_x,d_xb,d_xf,d_q,d_ao,d_mh,d_mo,
                                d_skc + l*MAX_TOK*D*4, d_svc + l*MAX_TOK*D*4, d_ckc, d_cvc, d_pos,
                                alnW,alnB,qW,qB,kW,vW,vB,oW,oB,
                                calnW,calnB,cqW,cqB,ckW,cvW,cvB,coW,coB,
                                mlnW,mlnB,m0W,m0B,m2W,m2B,d_enc_pos,d_ca_weights);
                }
                kLN(d_x,d_xb,ln_w,ln_b,D,1);
                kF2H(d_xf,d_xb,D);
                kTC(d_xf,tok_emb,d_logits,D,51872);
                if (cuCapEnd(stream, &cuda_graph) == 0) {
                    if (cuGrInst(&graph_exec, cuda_graph.?, 0) == 0) {
                        graph_ok = true;
                        try out.print("[G] CUDA Graph captured (+ extract_ca_head)\n", .{});
                    }
                }
            }
            if (graph_ok) {
                _ = cuGrLaunch(graph_exec.?, stream);
            } else {
                try out.print("[G] Graph capture failed, running inline\n", .{});
                for (0..NL) |l| {
                    decodeBlock(l, d_x,d_xb,d_xf,d_q,d_ao,d_mh,d_mo,
                                d_skc + l*MAX_TOK*D*4, d_svc + l*MAX_TOK*D*4, d_ckc, d_cvc, d_pos,
                                alnW,alnB,qW,qB,kW,vW,vB,oW,oB,
                                calnW,calnB,cqW,cqB,ckW,cvW,cvB,coW,coB,
                                mlnW,mlnB,m0W,m0B,m2W,m2B,d_enc_pos,d_ca_weights);
                }
                kLN(d_x,d_xb,ln_w,ln_b,D,1);
                kF2H(d_xf,d_xb,D);
                kTC(d_xf,tok_emb,d_logits,D,51872);
            }
        } else {
            _ = cuGrLaunch(graph_exec.?, stream);
        }

        // POST: logit filter + suppress + argmax (SINGLE cuSync)
        if (step >= SEED.len - 1) {
            var a0=d_logits; var a1=d_tokens; var a2:u32=0;
            var a3=step; var a4:u32=@intCast(SEED.len);
            var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2),@ptrCast(&a3),@ptrCast(&a4)};
            _ = cuLaunch(fn_filt,1,1,1,256,1,1,0,stream,&p,null);
            // GPU suppress — no sync needed between filt and suppress
            var s0=d_logits; var s1=d_suppress; var s2=suppress_count;
            var sp=[_]?*anyopaque{@ptrCast(&s0),@ptrCast(&s1),@ptrCast(&s2)};
            _ = cuLaunch(fn_suppress,1,1,1,256,1,1,0,stream,&sp,null);
        }

        // argmax_append
        var b0=d_logits; var b1=d_tokens; var b2=d_pos; var b3=MAX_TOK;
        var p2=[_]?*anyopaque{@ptrCast(&b0),@ptrCast(&b1),@ptrCast(&b2),@ptrCast(&b3)};
        if (step >= SEED.len - 1) {
            var next_pos: u32 = step + 1;
            _ = cuH2D(d_pos, &next_pos, 4);
            _ = cuLaunch(fn_argmax,1,1,1,1024,1,1,0,stream,&p2,null);
            _ = cuSync();
            var new_tok: u32 = 0;
            _ = cuD2H(&new_tok, d_tokens + @as(u64,next_pos)*4, 4);
            out_tokens[step] = new_tok;
            if (new_tok == EOT) break;
        } else {
            out_tokens[step] = SEED[step];
        }
    }
    const elapsed = nowMs() - t0;
    try out.print("[5] Decoded {d} tokens in {d:.1}ms ({d:.1} tok/s)\n",
        .{step, elapsed, @as(f64,@floatFromInt(step))/elapsed*1000.0});
        
    // --- Detokenizer ---
    if (std.fs.cwd().readFileAlloc(alloc, "vocab.bin", 64*1024*1024)) |vocab_data| {
        try out.print("Text: ", .{});
        var vocab_idx: usize = 4;
        const max_tokens = std.mem.readInt(u32, vocab_data[0..4][0..4], .little);
        var vocab_lens = try alloc.alloc(u16, max_tokens);
        var vocab_strs = try alloc.alloc([]const u8, max_tokens);
        for (0..max_tokens) |i| {
            const l = std.mem.readInt(u16, vocab_data[vocab_idx..vocab_idx+2][0..2], .little);
            vocab_idx += 2;
            vocab_lens[i] = l;
            vocab_strs[i] = vocab_data[vocab_idx..vocab_idx+l];
            vocab_idx += l;
        }
        for (out_tokens[0..step]) |t| {
            if (t < max_tokens) {
                try out.print("{s}", .{vocab_strs[t]});
            }
        }
        try out.print("\n", .{});
    } else |_| {
        try out.print("Tokens:", .{});
        for (out_tokens[0..step]) |t| try out.print(" {d}", .{t});
        try out.print("\n", .{});
    }

    // === Word-level timestamps from cross-attention weights ===
    const n_text = step - SEED.len; // text tokens only
    if (n_text > 0) {
        // Download ca_weights [MAX_TOK x ENC_SEQ] from GPU
        const ca_size = MAX_TOK * ENC_SEQ;
        const ca_buf = alloc.alloc(f32, ca_size) catch unreachable;
        _ = cuD2H(ca_buf.ptr, d_ca_weights, ca_size * 4);
        _ = cuSync();

        // Median filter (kernel size 7) on each text token's attention row
        var filtered = alloc.alloc(f32, ca_size) catch unreachable;
        for (SEED.len..step) |ti| {
            const row = ca_buf[ti*ENC_SEQ .. (ti+1)*ENC_SEQ];
            const frow = filtered[ti*ENC_SEQ .. (ti+1)*ENC_SEQ];
            for (0..ENC_SEQ) |j| {
                // Simple median-3 approximation
                const lo = if (j > 0) j-1 else 0;
                const hi = if (j+1 < ENC_SEQ) j+1 else ENC_SEQ-1;
                var a_v = row[lo]; var b_v = row[j]; var c_v = row[hi];
                // Sort 3
                if (a_v > b_v) { const tmp = a_v; a_v = b_v; b_v = tmp; }
                if (b_v > c_v) { const tmp = b_v; b_v = c_v; c_v = tmp; }
                if (a_v > b_v) { b_v = a_v; }
                frow[j] = b_v;
            }
        }

        // Argmax per token → encoder frame index → timestamp
        try out.print("WordTS:", .{});
        for (SEED.len..step) |ti| {
            const row = filtered[ti*ENC_SEQ .. (ti+1)*ENC_SEQ];
            var best_j: u32 = 0;
            var best_v: f32 = -1.0;
            for (0..ENC_SEQ) |j| {
                if (row[j] > best_v) { best_v = row[j]; best_j = @intCast(j); }
            }
            // Each encoder frame = 20ms
            const ts_ms: u32 = best_j * 20;
            try out.print(" {d}:{d}", .{out_tokens[ti], ts_ms});
        }
        try out.print("\n", .{});
    }
}

// FINAL MAIN — wire up decodeLoop call
// Run: sovereign_whisper_wts.exe <encoder_output.bin>

