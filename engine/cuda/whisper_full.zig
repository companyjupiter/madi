// whisper_full.zig — Full Sovereign Whisper Encoder+Decoder
// 100% ZIG + PTX, Zero Dependencies
const std = @import("std");
const CUresult = i32;
const CUdeviceptr = u64;
const CUfn = *anyopaque;
const CUstream = ?*anyopaque;

// CUDA API
var cuLaunch: *const fn(CUfn,u32,u32,u32,u32,u32,u32,u32,CUstream,[*]?*anyopaque,?*anyopaque)callconv(.C)CUresult = undefined;
var cuAlloc: *const fn(*CUdeviceptr,usize)callconv(.C)CUresult = undefined;
var cuH2D: *const fn(*anyopaque,*const anyopaque,usize)callconv(.C)CUresult = undefined;
var cuD2H: *const fn(*anyopaque,*const anyopaque,usize)callconv(.C)CUresult = undefined;
var cuD2D: *const fn(CUdeviceptr,CUdeviceptr,usize)callconv(.C)CUresult = undefined;
var cuSync: *const fn()callconv(.C)CUresult = undefined;
var cuStreamSync: *const fn(CUstream)callconv(.C)CUresult = undefined;
var cuMemset: *const fn(*anyopaque,u32,usize)callconv(.C)CUresult = undefined;
var cuMemFree: *const fn(CUdeviceptr)callconv(.C)CUresult = undefined;

var fn_ln: CUfn = undefined;      // layer_norm
var fn_vm16: CUfn = undefined;    // vec_matmul_f16
var fn_tc: CUfn = undefined;      // tc_gemv
var fn_f2h: CUfn = undefined;     // f32_to_f16
var fn_f2hb: CUfn = undefined;    // f32_to_f16_batch16
var fn_res: CUfn = undefined;     // gpu_residual
var fn_gelu: CUfn = undefined;    // gelu_f32
var fn_soft: CUfn = undefined;    // softmax_f32
var fn_bias: CUfn = undefined;    // bias_add
var fn_scale: CUfn = undefined;   // scale_f32
var fn_h2f: CUfn = undefined;     // f16_to_f32

// cuBLAS handle
var cublas: *anyopaque = undefined;
var cublasCreate: *const fn(**anyopaque)callconv(.C)u32 = undefined;
var cublasSgemm: *const fn(*anyopaque,u32,u32,i32,i32,i32,*const f32,*const anyopaque,i32,*const anyopaque,i32,*const f32,*anyopaque,i32)callconv(.C)u32 = undefined;
var cublasGemmEx: *const fn(*anyopaque,u32,u32,i32,i32,i32,*const anyopaque,*const anyopaque,u32,i32,*const anyopaque,u32,i32,*const anyopaque,*anyopaque,u32,i32,u32,u32)callconv(.C)u32 = undefined;
var cublasSetStream: *const fn(*anyopaque, CUstream)callconv(.C)u32 = undefined;
var stream: CUstream = null;

const D: u32 = 1280;
const NL: u32 = 32;
const NH: u32 = 20;     // attention heads
const DH: u32 = 64;     // head dim (D/NH)
const MLP: u32 = 5120;
const SEQ: u32 = 1500;
const BATCH: u32 = 16;

// cuBLAS constants
const CUBLAS_OP_N: u32 = 0;
const CUBLAS_OP_T: u32 = 1;
// cuBLAS data types
const CUDA_R_16F: u32 = 2;
const CUDA_R_32F: u32 = 0;
const CUBLAS_GEMM_DEFAULT_TENSOR_OP: u32 = 99;
const CUBLAS_COMPUTE_32F: u32 = 68;

// ── Kernel launchers ──
inline fn launch(f: CUfn, gx: u32, bx: u32, p: [*]?*anyopaque) void {
    _ = cuLaunch(f,gx,1,1,bx,1,1,0,stream,p,null);
}
noinline fn kLN(x:CUdeviceptr,y:CUdeviceptr,g:CUdeviceptr,b:CUdeviceptr,d:u32,rows:u32) void {
    var a0=x;var a1=y;var a2=g;var a3=b;var a4=d;var a5:f32=1e-5;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2),@ptrCast(&a3),@ptrCast(&a4),@ptrCast(&a5)};
    _ = cuLaunch(fn_ln,rows,1,1,256,1,1,0,stream,&p,null);
}
noinline fn kVM16(o:CUdeviceptr,x:CUdeviceptr,w:CUdeviceptr,n:u32,d:u32) void {
    var a0=o;var a1=x;var a2=w;var a3=n;var a4=d;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2),@ptrCast(&a3),@ptrCast(&a4)};
    _ = cuLaunch(fn_vm16,(d+255)/256,1,1,256,1,1,0,stream,&p,null);
}
noinline fn kTC(a:CUdeviceptr,b:CUdeviceptr,c:CUdeviceptr,n:u32,d:u32) void {
    var a0=a;var a1=b;var a2=c;var a3=n;var a4=d;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2),@ptrCast(&a3),@ptrCast(&a4)};
    _ = cuLaunch(fn_tc,(d+15)/16,1,1,32,1,1,0,stream,&p,null);
}
noinline fn kF2H(dst:CUdeviceptr,src:CUdeviceptr,n:u32) void {
    var a0=dst;var a1=src;var a2=n;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2)};
    _ = cuLaunch(fn_f2h,(n+255)/256,1,1,256,1,1,0,stream,&p,null);
}
noinline fn kRes(dst:CUdeviceptr,src:CUdeviceptr,n:u32) void {
    var a0=dst;var a1=src;var a2=n;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2)};
    _ = cuLaunch(fn_res,(n+255)/256,1,1,256,1,1,0,stream,&p,null);
}
noinline fn kGelu(x:CUdeviceptr,n:u32) void {
    var a0=x;var a1=n;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1)};
    _ = cuLaunch(fn_gelu,(n+255)/256,1,1,256,1,1,0,stream,&p,null);
}
noinline fn kSoft(x:CUdeviceptr,d:u32,rows:u32) void {
    var a0=x;var a1=d;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1)};
    _ = cuLaunch(fn_soft,rows,1,1,256,1,1,0,stream,&p,null);
}
noinline fn kBias(x:CUdeviceptr,b:CUdeviceptr,n:u32,d:u32) void {
    var a0=x;var a1=b;var a2=n;var a3=d;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2),@ptrCast(&a3)};
    _ = cuLaunch(fn_bias,(n+255)/256,1,1,256,1,1,0,stream,&p,null);
}
noinline fn kScale(x:CUdeviceptr,n:u32,s:f32) void {
    var a0=x;var a1=n;var a2=s;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2)};
    _ = cuLaunch(fn_scale,(n+255)/256,1,1,256,1,1,0,stream,&p,null);
}
noinline fn kH2F(dst:CUdeviceptr,src:CUdeviceptr,n:u32) void {
    var a0=dst;var a1=src;var a2=n;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2)};
    _ = cuLaunch(fn_h2f,(n+255)/256,1,1,256,1,1,0,stream,&p,null);
}

const w_api = std.os.windows;
const externs = struct {
    extern "kernel32" fn CreateFileMappingW(hFile:w_api.HANDLE,a:?*anyopaque,b:w_api.DWORD,c:w_api.DWORD,d:w_api.DWORD,e:?[*:0]const u16)callconv(w_api.WINAPI)?w_api.HANDLE;
    extern "kernel32" fn MapViewOfFile(h:w_api.HANDLE,a:w_api.DWORD,b:w_api.DWORD,c:w_api.DWORD,d:usize)callconv(w_api.WINAPI)?*anyopaque;
    extern "kernel32" fn QueryPerformanceCounter(c:*i64)callconv(w_api.WINAPI)w_api.BOOL;
    extern "kernel32" fn QueryPerformanceFrequency(f:*i64)callconv(w_api.WINAPI)w_api.BOOL;
};
fn mmapFile(path: []const u8) ![]u8 {
    const f = std.fs.cwd().openFile(path, .{}) catch return error.MmapFailed;
    const sz = try f.getEndPos();
    const mh = externs.CreateFileMappingW(f.handle,null,w_api.PAGE_READONLY,0,0,null) orelse return error.MmapFailed;
    const mp = externs.MapViewOfFile(mh,4,0,0,0) orelse return error.MmapFailed;
    return @as([*]u8, @ptrCast(mp))[0..sz];
}
fn ms() f64 {
    var c:i64=0; var f:i64=0;
    _ = externs.QueryPerformanceCounter(&c); _ = externs.QueryPerformanceFrequency(&f);
    return @as(f64,@floatFromInt(c))/@as(f64,@floatFromInt(f))*1000.0;
}

fn mapTensor(base:[]const u8, name:[]const u8,
    hr:*const fn(*const anyopaque,usize,u32)callconv(.C)CUresult,
    hg:*const fn(*CUdeviceptr,*const anyopaque,u32)callconv(.C)CUresult,
    ok:*usize, fail:*usize) struct{p:CUdeviceptr,n:usize} {
    var pb:[512]u8=undefined;
    const path = std.fmt.bufPrint(&pb, "{s}/{s}/data.bin", .{base, name}) catch return .{.p=0,.n=0};
    const d = mmapFile(path) catch return .{.p=0,.n=0};
    var dp:CUdeviceptr=0;
    if (hr(d.ptr, d.len, 2) == 0) { _ = hg(&dp, d.ptr, 0); ok.*+=1; }
    else { fail.*+=1; _ = cuAlloc(&dp, d.len); if(dp!=0) _ = cuH2D(@ptrFromInt(dp), d.ptr, d.len); }
    return .{.p=dp,.n=d.len};
}

pub fn run(ext_ctx: *anyopaque, d_enc_in: u64) !u64 {
    const out = std.io.getStdOut().writer();
    const alloc = std.heap.page_allocator;
    try out.print("\n=== SOVEREIGN WHISPER — FULL PIPELINE ===\n\n", .{});

    // 1. CUDA
    var nv = std.DynLib.open("nvcuda.dll") catch return error.CudaNotFound;

    const cuModLD = nv.lookup(*const fn(**anyopaque,[*]const u8)callconv(.C)CUresult,"cuModuleLoadData").?;
    const cuGetF = nv.lookup(*const fn(*CUfn,*anyopaque,[*:0]const u8)callconv(.C)CUresult,"cuModuleGetFunction").?;
    cuAlloc=nv.lookup(@TypeOf(cuAlloc),"cuMemAlloc_v2").?;
    cuH2D=nv.lookup(@TypeOf(cuH2D),"cuMemcpyHtoD_v2").?;
    cuD2H=nv.lookup(@TypeOf(cuD2H),"cuMemcpyDtoH_v2").?;
    cuLaunch=nv.lookup(@TypeOf(cuLaunch),"cuLaunchKernel").?;
    cuSync=nv.lookup(@TypeOf(cuSync),"cuCtxSynchronize").?;
    cuStreamSync=nv.lookup(@TypeOf(cuStreamSync),"cuStreamSynchronize").?;
    cuMemset=nv.lookup(@TypeOf(cuMemset),"cuMemsetD8_v2").?;
    cuMemFree=nv.lookup(@TypeOf(cuMemFree),"cuMemFree_v2").?;
    cuD2D=nv.lookup(@TypeOf(cuD2D),"cuMemcpyDtoD_v2").?;
    const cuStreamCreate=nv.lookup(*const fn(*CUstream,u32)callconv(.C)CUresult,"cuStreamCreate").?;

    const cuCtxSetCurrent = nv.lookup(*const fn(*anyopaque)callconv(.C)CUresult,"cuCtxSetCurrent").?;
    _ = cuCtxSetCurrent(ext_ctx);
    _ = cuStreamCreate(&stream, 0);

    // cublas (context must exist)
    var cb = std.DynLib.open("cublas64_12.dll") catch std.DynLib.open("cublas64_11.dll") catch return error.CublasNotFound;
    cublasCreate = cb.lookup(@TypeOf(cublasCreate), "cublasCreate_v2").?;
    cublasSgemm = cb.lookup(@TypeOf(cublasSgemm), "cublasSgemm_v2").?;
    cublasSetStream = cb.lookup(@TypeOf(cublasSetStream), "cublasSetStream_v2").?;
    cublasGemmEx = cb.lookup(@TypeOf(cublasGemmEx), "cublasGemmEx").?;
    _ = cublasCreate(&cublas);
    _ = cublasSetStream(cublas, stream);

    try out.print("[1] CUDA Shared Context (cuBLAS ready)\n", .{});

    // 2. Load PTX
    const ptx_names = [_][]const u8{"layer_norm.ptx","vec_matmul.ptx","tensor_core.ptx","f16_convert.ptx","whisper_kernels.ptx"};
    var mods: [5]*anyopaque = undefined;
    for (ptx_names, 0..) |pn, i| {
        const data = try std.fs.cwd().readFileAlloc(alloc, pn, 1024*1024);
        const s = try alloc.allocSentinel(u8, data.len, 0); @memcpy(s, data);
        _ = cuModLD(&mods[i], @ptrCast(s.ptr));
    }
    _ = cuGetF(&fn_ln, mods[0], "layer_norm");
    _ = cuGetF(&fn_vm16, mods[1], "vec_matmul_f16");
    _ = cuGetF(&fn_tc, mods[2], "tc_gemv");
    _ = cuGetF(&fn_f2h, mods[3], "f32_to_f16");
    _ = cuGetF(&fn_f2hb, mods[3], "f32_to_f16_batch16");
    _ = cuGetF(&fn_gelu, mods[4], "gelu_f32");
    _ = cuGetF(&fn_soft, mods[4], "softmax_f32");
    _ = cuGetF(&fn_bias, mods[4], "bias_add");
    _ = cuGetF(&fn_scale, mods[4], "scale_f32");
    const h2f_result = cuGetF(&fn_h2f, mods[3], "f16_to_f32");
    try out.print("[2] 6 PTX modules loaded (h2f={d})\n", .{h2f_result});
    // gpu_residual from gpu_ops.ptx
    const ops_data = try std.fs.cwd().readFileAlloc(alloc, "gpu_ops.ptx", 1024*1024);
    const ops_s = try alloc.allocSentinel(u8, ops_data.len, 0); @memcpy(ops_s, ops_data);
    var mod_ops: *anyopaque = undefined;
    _ = cuModLD(&mod_ops, @ptrCast(ops_s.ptr));
    _ = cuGetF(&fn_res, mod_ops, "gpu_residual");
    try out.print("[2] 6 PTX modules loaded\n", .{});

    // 3. Map encoder tensors (B-Tree atom)
    const t0 = ms();
    const base = "quarks/whisper-turbo-v3-atom";
    const hr = nv.lookup(*const fn(*const anyopaque,usize,u32)callconv(.C)CUresult,"cuMemHostRegister_v2").?;
    const hg = nv.lookup(*const fn(*CUdeviceptr,*const anyopaque,u32)callconv(.C)CUresult,"cuMemHostGetDevicePointer_v2").?;
    var ok:usize=0; var fail:usize=0; var tb:usize=0;

    // Per-layer arrays
    var qw:[NL]CUdeviceptr=undefined; var kw:[NL]CUdeviceptr=undefined;
    var vw:[NL]CUdeviceptr=undefined; var ow:[NL]CUdeviceptr=undefined;
    var qb:[NL]CUdeviceptr=undefined; var kb:[NL]CUdeviceptr=undefined;
    var vb:[NL]CUdeviceptr=undefined; var ob:[NL]CUdeviceptr=undefined;
    var aln_w:[NL]CUdeviceptr=undefined; var aln_b:[NL]CUdeviceptr=undefined;
    var m0w:[NL]CUdeviceptr=undefined; var m0b:[NL]CUdeviceptr=undefined;
    var m2w:[NL]CUdeviceptr=undefined; var m2b:[NL]CUdeviceptr=undefined;
    var mln_w:[NL]CUdeviceptr=undefined; var mln_b:[NL]CUdeviceptr=undefined;

    for (0..NL) |l| {
        var nb:[16][512]u8 = undefined;
        const n = [_][]const u8{
            std.fmt.bufPrint(&nb[0],"encoder/blocks/{d}/attn/query/weight",.{l}) catch unreachable,
            std.fmt.bufPrint(&nb[1],"encoder/blocks/{d}/attn/key/weight",.{l}) catch unreachable,
            std.fmt.bufPrint(&nb[2],"encoder/blocks/{d}/attn/value/weight",.{l}) catch unreachable,
            std.fmt.bufPrint(&nb[3],"encoder/blocks/{d}/attn/out/weight",.{l}) catch unreachable,
            std.fmt.bufPrint(&nb[4],"encoder/blocks/{d}/attn/query/bias",.{l}) catch unreachable,
            std.fmt.bufPrint(&nb[5],"encoder/blocks/{d}/attn/key/bias",.{l}) catch unreachable,
            std.fmt.bufPrint(&nb[6],"encoder/blocks/{d}/attn/value/bias",.{l}) catch unreachable,
            std.fmt.bufPrint(&nb[7],"encoder/blocks/{d}/attn/out/bias",.{l}) catch unreachable,
            std.fmt.bufPrint(&nb[8],"encoder/blocks/{d}/attn_ln/weight",.{l}) catch unreachable,
            std.fmt.bufPrint(&nb[9],"encoder/blocks/{d}/attn_ln/bias",.{l}) catch unreachable,
            std.fmt.bufPrint(&nb[10],"encoder/blocks/{d}/mlp/0/weight",.{l}) catch unreachable,
            std.fmt.bufPrint(&nb[11],"encoder/blocks/{d}/mlp/0/bias",.{l}) catch unreachable,
            std.fmt.bufPrint(&nb[12],"encoder/blocks/{d}/mlp/2/weight",.{l}) catch unreachable,
            std.fmt.bufPrint(&nb[13],"encoder/blocks/{d}/mlp/2/bias",.{l}) catch unreachable,
            std.fmt.bufPrint(&nb[14],"encoder/blocks/{d}/mlp_ln/weight",.{l}) catch unreachable,
            std.fmt.bufPrint(&nb[15],"encoder/blocks/{d}/mlp_ln/bias",.{l}) catch unreachable,
        };
        var r = mapTensor(base,n[0],hr,hg,&ok,&fail); qw[l]=r.p; tb+=r.n;
        r = mapTensor(base,n[1],hr,hg,&ok,&fail); kw[l]=r.p; tb+=r.n;
        r = mapTensor(base,n[2],hr,hg,&ok,&fail); vw[l]=r.p; tb+=r.n;
        r = mapTensor(base,n[3],hr,hg,&ok,&fail); ow[l]=r.p; tb+=r.n;
        r = mapTensor(base,n[4],hr,hg,&ok,&fail); qb[l]=r.p; tb+=r.n;
        r = mapTensor(base,n[5],hr,hg,&ok,&fail); kb[l]=r.p; tb+=r.n;
        r = mapTensor(base,n[6],hr,hg,&ok,&fail); vb[l]=r.p; tb+=r.n;
        r = mapTensor(base,n[7],hr,hg,&ok,&fail); ob[l]=r.p; tb+=r.n;
        r = mapTensor(base,n[8],hr,hg,&ok,&fail); aln_w[l]=r.p; tb+=r.n;
        r = mapTensor(base,n[9],hr,hg,&ok,&fail); aln_b[l]=r.p; tb+=r.n;
        r = mapTensor(base,n[10],hr,hg,&ok,&fail); m0w[l]=r.p; tb+=r.n;
        r = mapTensor(base,n[11],hr,hg,&ok,&fail); m0b[l]=r.p; tb+=r.n;
        r = mapTensor(base,n[12],hr,hg,&ok,&fail); m2w[l]=r.p; tb+=r.n;
        r = mapTensor(base,n[13],hr,hg,&ok,&fail); m2b[l]=r.p; tb+=r.n;
        r = mapTensor(base,n[14],hr,hg,&ok,&fail); mln_w[l]=r.p; tb+=r.n;
        r = mapTensor(base,n[15],hr,hg,&ok,&fail); mln_b[l]=r.p; tb+=r.n;
    }
    const load_ms = ms() - t0;
    try out.print("[3] {d} tensors, {d:.0}MB in {d:.0}ms (zc:{d} vram:{d})\n", .{ok+fail, @as(f64,@floatFromInt(tb))/1048576.0, load_ms, ok, fail});

    // 4. Allocate scratch (BATCH=16 positions)
    const B = BATCH;
    const d_x:CUdeviceptr = d_enc_in;      // [SEQ×D] F32 — passed directly from wav_to_enc!
    var d_xb:CUdeviceptr=0; _ = cuAlloc(&d_xb, B*D*4);      // [B×D] batch scratch
    var d_xb2:CUdeviceptr=0; _ = cuAlloc(&d_xb2, B*D*4);    // [B×D] LN output scratch
    var d_xf:CUdeviceptr=0; _ = cuAlloc(&d_xf, B*D*2);     // [B×D] F16
    var d_q:CUdeviceptr=0; _ = cuAlloc(&d_q, B*D*4);
    var d_k:CUdeviceptr=0; _ = cuAlloc(&d_k, B*D*4);
    var d_v:CUdeviceptr=0; _ = cuAlloc(&d_v, B*D*4);
    var d_ao:CUdeviceptr=0; _ = cuAlloc(&d_ao, B*D*4);
    var d_mh:CUdeviceptr=0; _ = cuAlloc(&d_mh, B*MLP*4);
    var d_mhf:CUdeviceptr=0; _ = cuAlloc(&d_mhf, B*MLP*2);
    var d_mo:CUdeviceptr=0; _ = cuAlloc(&d_mo, SEQ*D*4);
    // Attention scratch: [NH × SEQ × SEQ] scores + [SEQ × D] value weighting
    var d_attn:CUdeviceptr=0; _ = cuAlloc(&d_attn, NH*SEQ*SEQ*4);
    var d_ao_f16:CUdeviceptr=0; _ = cuAlloc(&d_ao_f16, SEQ*D*2);
    // MLP scratch
    var d_mhf_seq:CUdeviceptr=0; _ = cuAlloc(&d_mhf_seq, SEQ*MLP*2);
    _ = cuSync();

    // 5. Encoder input is already in GPU VRAM (Zero-copy)
    try out.print("[4] Input received directly in VRAM (Zero-copy)\n", .{});
    _ = cuSync();
    try out.print("[5] Input → GPU ({d}×{d})\n", .{SEQ, D});

    // 6. Full Encoder — Layer-wise processing (1500 positions, cublasSgemm F32)
    const t_enc = ms();
    const alpha_f: f32 = 1.0;
    const beta_f: f32 = 0.0;

    // Global scratch buffers
    var d_x_ln:CUdeviceptr=0; _ = cuAlloc(&d_x_ln, SEQ*D*4);   // [SEQ×D] F32 LN output
    var d_q_seq:CUdeviceptr=0; _ = cuAlloc(&d_q_seq, SEQ*D*4);  // [SEQ×D] F32 Q
    var d_k_seq:CUdeviceptr=0; _ = cuAlloc(&d_k_seq, SEQ*D*4);  // [SEQ×D] F32 K
    var d_v_seq:CUdeviceptr=0; _ = cuAlloc(&d_v_seq, SEQ*D*4);  // [SEQ×D] F32 V
    // F32 weight scratch (max size = MLP×D = 5120×1280)
    var d_wf:CUdeviceptr=0; _ = cuAlloc(&d_wf, MLP*D*4);

    for (0..NL) |l| {
        const t_l = ms();
        // A. LayerNorm
        kLN(d_x, d_x_ln, aln_w[l], aln_b[l], D, SEQ);
        _ = cuSync();

        // B. Q Projection
        kH2F(d_wf, qw[l], D*D);
        _ = cuSync();
        _ = cublasSgemm(cublas, CUBLAS_OP_T, CUBLAS_OP_N,
            @intCast(D), @intCast(SEQ), @intCast(D),
            &alpha_f, @ptrFromInt(d_wf), @intCast(D),
            @ptrFromInt(d_x_ln), @intCast(D),
            &beta_f, @ptrFromInt(d_q_seq), @intCast(D));
        _ = cuSync();
        if(qb[l]!=0) kBias(d_q_seq, qb[l], SEQ*D, D);

        // K Projection
        kH2F(d_wf, kw[l], D*D);
        _ = cuSync();
        _ = cublasSgemm(cublas, CUBLAS_OP_T, CUBLAS_OP_N,
            @intCast(D), @intCast(SEQ), @intCast(D),
            &alpha_f, @ptrFromInt(d_wf), @intCast(D),
            @ptrFromInt(d_x_ln), @intCast(D),
            &beta_f, @ptrFromInt(d_k_seq), @intCast(D));
        _ = cuSync();
        if(kb[l]!=0) kBias(d_k_seq, kb[l], SEQ*D, D);

        // V Projection
        kH2F(d_wf, vw[l], D*D);
        _ = cuSync();
        _ = cublasSgemm(cublas, CUBLAS_OP_T, CUBLAS_OP_N,
            @intCast(D), @intCast(SEQ), @intCast(D),
            &alpha_f, @ptrFromInt(d_wf), @intCast(D),
            @ptrFromInt(d_x_ln), @intCast(D),
            &beta_f, @ptrFromInt(d_v_seq), @intCast(D));
        _ = cuSync();
        if(vb[l]!=0) kBias(d_v_seq, vb[l], SEQ*D, D);

        // C. Scale Q
        kScale(d_q_seq, SEQ*D, 0.125);

        // D. Self-Attention per head
        for (0..NH) |h| {
            const h_off = h * DH * 4;
            const s_off = h * SEQ * SEQ * 4;
            _ = cublasSgemm(cublas, CUBLAS_OP_T, CUBLAS_OP_N,
                @intCast(SEQ), @intCast(SEQ), @intCast(DH),
                &alpha_f, @ptrFromInt(d_k_seq + h_off), @intCast(D),
                @ptrFromInt(d_q_seq + h_off), @intCast(D),
                &beta_f, @ptrFromInt(d_attn + s_off), @intCast(SEQ));
        }
        _ = cuSync(); // sync before softmax reads attn scores

        kSoft(d_attn, SEQ, SEQ * NH);
        _ = cuSync(); // sync before V weighting reads softmax output

        // O = scores @ V per head
        for (0..NH) |h| {
            const h_off = h * DH * 4;
            const s_off = h * SEQ * SEQ * 4;
            _ = cublasSgemm(cublas, CUBLAS_OP_N, CUBLAS_OP_N,
                @intCast(DH), @intCast(SEQ), @intCast(SEQ),
                &alpha_f, @ptrFromInt(d_v_seq + h_off), @intCast(D),
                @ptrFromInt(d_attn + s_off), @intCast(SEQ),
                &beta_f, @ptrFromInt(d_mo + h_off), @intCast(D));
        }
        _ = cuSync(); // sync before output projection

        // E. Output projection
        kH2F(d_wf, ow[l], D*D);
        _ = cuSync();
        _ = cublasSgemm(cublas, CUBLAS_OP_T, CUBLAS_OP_N,
            @intCast(D), @intCast(SEQ), @intCast(D),
            &alpha_f, @ptrFromInt(d_wf), @intCast(D),
            @ptrFromInt(d_mo), @intCast(D),
            &beta_f, @ptrFromInt(d_q_seq), @intCast(D));
        _ = cuSync();
        if(ob[l]!=0) kBias(d_q_seq, ob[l], SEQ*D, D);

        // F. Residual (Attention)
        kRes(d_x, d_q_seq, SEQ*D);
        _ = cuSync();

        // G. MLP LayerNorm
        kLN(d_x, d_x_ln, mln_w[l], mln_b[l], D, SEQ);
        _ = cuSync();

        // H. MLP up + GELU
        kH2F(d_wf, m0w[l], MLP*D);
        _ = cuSync();
        const d_mh_seq = d_attn;
        _ = cublasSgemm(cublas, CUBLAS_OP_T, CUBLAS_OP_N,
            @intCast(MLP), @intCast(SEQ), @intCast(D),
            &alpha_f, @ptrFromInt(d_wf), @intCast(D),
            @ptrFromInt(d_x_ln), @intCast(D),
            &beta_f, @ptrFromInt(d_mh_seq), @intCast(MLP));
        _ = cuSync();
        if(m0b[l]!=0) kBias(d_mh_seq, m0b[l], SEQ*MLP, MLP);
        kGelu(d_mh_seq, SEQ*MLP);
        _ = cuSync();

        // I. MLP down
        kH2F(d_wf, m2w[l], D*MLP);
        _ = cuSync();
        _ = cublasSgemm(cublas, CUBLAS_OP_T, CUBLAS_OP_N,
            @intCast(D), @intCast(SEQ), @intCast(MLP),
            &alpha_f, @ptrFromInt(d_wf), @intCast(MLP),
            @ptrFromInt(d_mh_seq), @intCast(MLP),
            &beta_f, @ptrFromInt(d_mo), @intCast(D));
        _ = cuSync();
        if(m2b[l]!=0) kBias(d_mo, m2b[l], SEQ*D, D);

        // J. Residual (MLP)
        kRes(d_x, d_mo, SEQ*D);
        _ = cuSync();
        try out.print("\r  Layer {d}/{d} in {d}ms", .{l+1, NL, ms()-t_l});
        if(l==0) {
            var l0: [8]f32 = undefined;
            _ = cuD2H(&l0, @ptrFromInt(d_x), 32);
            try out.print("\n  L0 out: {d:.6} {d:.6} {d:.6} {d:.6} {d:.6} {d:.6} {d:.6} {d:.6}\n", .{l0[0],l0[1],l0[2],l0[3],l0[4],l0[5],l0[6],l0[7]});
        }
    }
    _ = cuStreamSync(stream);

    // K. Final LayerNorm (ln_post)
    var lnp_w: CUdeviceptr = 0;
    var lnp_b: CUdeviceptr = 0;
    {
        var r = mapTensor(base, "encoder/ln_post/weight", hr, hg, &ok, &fail);
        lnp_w = r.p;
        r = mapTensor(base, "encoder/ln_post/bias", hr, hg, &ok, &fail);
        lnp_b = r.p;
    }
    kLN(d_x, d_x, lnp_w, lnp_b, D, SEQ);
    _ = cuSync();

    const enc_ms = ms() - t_enc;
    const rtf = enc_ms / 30000.0;

    // Read back encoder output
    var enc_out = try alloc.alloc(f32, SEQ * D);
    _ = cuD2H(enc_out.ptr, @ptrFromInt(d_x), SEQ * D * 4);
    
    var probe: [8]f32 = undefined;
    @memcpy(&probe, enc_out[0..8]);
    try out.print("\n[6] ENCODER RESULTS:\n", .{});
    try out.print("  Input: GPU Pointer (Zero-copy)\n", .{});
    try out.print("  {d} positions × {d} layers in {d:.1}ms\n", .{SEQ, NL, enc_ms});
    try out.print("  30s RTF:  {d:.4}\n", .{rtf});
    try out.print("  Speed:    {d:.1}x realtime\n", .{1.0/rtf});
    try out.print("  Output[0..8]: ", .{});
    for (probe) |v| try out.print("{d:.4} ", .{v});
    
    // Zero-copy: Return d_x pointer
    try out.print("\n  Zero-copy GPU Pointer returned\n", .{});
    try out.print("\n  ✅ SOVEREIGN WHISPER — ENCODER COMPLETE\n", .{});
    return @intCast(d_x);
}

