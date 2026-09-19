// sovereign_whisper_v20_hybrid_masterpiece.zig
// SSOT: Madi V20 Hybrid Architecture (trans workspace)
// Architecture: Model Loading = CPU (BypassIO/mmap) -> Inference = 100% All-GPU (Zero CPU Stall)
const std = @import("std");
const CUresult = i32;
const CUdeviceptr = u64;
const CUfn = *anyopaque;
const CUstream = ?*anyopaque;
const CublasHandle = ?*anyopaque;
const CUBLAS_OP_N: i32 = 0;
const CUBLAS_OP_T: i32 = 1;

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

// cuBLAS (loaded dynamically)
var cublasSgemmStridedBatched: *const fn(CublasHandle, i32, i32, i32, i32, i32, *const f32, CUdeviceptr, i32, i64, CUdeviceptr, i32, i64, *const f32, CUdeviceptr, i32, i64, i32)callconv(.C)i32 = undefined;
var cublasGemmEx: *const fn(CublasHandle,i32,i32,i32,i32,i32,*const f32,CUdeviceptr,i32,i32,CUdeviceptr,i32,i32,*const f32,CUdeviceptr,i32,i32,i32,i32)callconv(.C)i32 = undefined;
var cublasSgemm: *const fn(CublasHandle,i32,i32,i32,i32,i32,*const f32,CUdeviceptr,i32,CUdeviceptr,i32,*const f32,CUdeviceptr,i32)callconv(.C)i32 = undefined;

// Kernel handles
var fn_ln:     CUfn = undefined; // layer_norm
var fn_tc:     CUfn = undefined; // tc_gemv (matmul kernel)
var fn_f2h:    CUfn = undefined; // f32_to_f16
var fn_res:    CUfn = undefined; // gpu_residual
var fn_gelu:   CUfn = undefined; // gelu_f32
var fn_emb:    CUfn = undefined; // gpu_emb_lookup
var fn_bias:   CUfn = undefined; // bias_add
var fn_scale:  CUfn = undefined; // scale_f32
var fn_kv_store: CUfn = undefined; // gpu_kv_store
var fn_soft:   CUfn = undefined; // softmax_f32
var fn_att:    CUfn = undefined; // gpu_attention (autoregressive)
var fn_att_cross: CUfn = undefined; // gpu_attention_cross (Corridor Attention)
var fn_flash_ca: CUfn = undefined; // flash_cross_attn
var fn_filt:   CUfn = undefined; // logit_filter  (decoder_ops.ptx)
var fn_argmax: CUfn = undefined; // argmax_append (decoder_ops.ptx)
var fn_gv:     CUfn = undefined; // f32_gemv (F16 weight)
var fn_gv_fast:CUfn = undefined; // f32_gemv_fast (reduction-parallel)
var fn_gv32:   CUfn = undefined; // f32_gemv_f32w (F32 weight)
var fn_ca_head:CUfn = undefined; // extract_ca_head (mfa_align.ptx)
var fn_suppress:CUfn = undefined; // suppress_apply (mfa_align.ptx)
var fn_emb_ind:CUfn = undefined; // emb_lookup_indirect (graph_helpers.ptx)
var fn_pe_ind: CUfn = undefined; // pos_embed_add_indirect (graph_helpers.ptx)
var fn_step_adv:CUfn = undefined; // step_advance (graph_helpers.ptx)
var fn_argmax_ni:CUfn = undefined; // argmax_no_inc (graph_helpers.ptx)
var fn_filt_ind:CUfn = undefined; // logit_filter_indirect (graph_helpers.ptx)
var fn_flash_enc:CUfn = undefined; // flash_attention_enc (flash_attention_enc.ptx)
var fn_bias_res_ln: CUfn = undefined; // bias_res_ln (bias_res_ln.ptx)
var fn_f2h_single: CUfn = undefined; // f32_to_f16 (f16_convert.ptx)
var fn_conv1d_gelu: CUfn = undefined; // conv1d_gelu (conv1d.ptx)

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
const ENC_SEQ: u32 = 1504;
const MAX_TOK: u32 = 448;
const ENL: u32 = 32;
const MAX_BATCH: u32 = 8;  // Batched encoder: up to 8 chunks simultaneously

// WAV preprocessing constants
const SAMPLE_RATE: u32 = 16000;
const N_FFT: u32 = 400;
const HOP_LENGTH: u32 = 160;
const N_MELS: u32 = 128;
const CHUNK_SECS: u32 = 30;
const STRIDE_SECS: u32 = 28; // 2s overlap between chunks
const N_FRAMES: u32 = 3000; // 30s * 16000 / 160
const PI: f64 = 3.14159265358979323846;


// --- Launcher helpers ---
inline fn checkLaunch(err: i32, name: []const u8) void {
    if (err != 0) {
        std.debug.print("CUDA LAUNCH ERROR in {s}: code {d}\n", .{name, err});
        @panic("cuLaunch failed");
    }
}
inline fn syncAfterLaunch(name: []const u8) void {
    const err = cuSync();
    if (err != 0) {
        std.debug.print("CUDA SYNC ERROR after {s}: code {d}\n", .{name, err});
        @panic("cuSync failed");
    }
}

inline fn kLN(x:CUdeviceptr,y:CUdeviceptr,w:CUdeviceptr,b:CUdeviceptr,n:u32,rows:u32) void {
    var a0=x;var a1=y;var a2=w;var a3=b;var a4=n;var a5:f32=1e-5;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2),@ptrCast(&a3),@ptrCast(&a4),@ptrCast(&a5)};
    checkLaunch(cuLaunch(fn_ln,rows,1,1,256,1,1,0,stream,&p,null), "kLN");
}

inline fn biasResLN(x: CUdeviceptr, mo: CUdeviceptr, bias: CUdeviceptr, y: CUdeviceptr, w: CUdeviceptr, b: CUdeviceptr, n: u32, rows: u32) void {
    var a0 = x; var a1 = mo; var a2 = bias; var a3 = y; var a4 = w; var a5 = b; var a6 = n; var a7: f32 = 1e-5;
    var p = [_]?*anyopaque{
        @ptrCast(&a0), @ptrCast(&a1), @ptrCast(&a2), @ptrCast(&a3),
        @ptrCast(&a4), @ptrCast(&a5), @ptrCast(&a6), @ptrCast(&a7)
    };
    checkLaunch(cuLaunch(fn_bias_res_ln, rows, 1, 1, 256, 1, 1, 0, stream, &p, null), "biasResLN");
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
    checkLaunch(cuLaunch(fn_gv,(d+255)/256,1,1,256,1,1,0,stream,&p,null), "kGV");
}
// F32 scalar GEMV with F32 weights: y[D] = x_f32[N] @ W_f32[N,D]
inline fn kGV32(y:CUdeviceptr,x:CUdeviceptr,w:CUdeviceptr,n:u32,d:u32) void {
    var a0=y;var a1=x;var a2=w;var a3=n;var a4=d;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2),@ptrCast(&a3),@ptrCast(&a4)};
    _ = cuLaunch(fn_gv32,(d+255)/256,1,1,256,1,1,0,stream,&p,null);
}
// cuBLAS GEMV: y_f32[D] = x_f32[N] * W_f16t[N,D] via GemmEx (M=1)
var dm0W16_g:[4]CUdeviceptr = .{0,0,0,0};
var dm2W16_g:[4]CUdeviceptr = .{0,0,0,0};
var blas_handle_g: CublasHandle = null;
var d_dec_f16_g: CUdeviceptr = 0;
inline fn kCGV(y:CUdeviceptr,x:CUdeviceptr,w_f16t:CUdeviceptr,n:u32,d:u32) void {
    kF2HSingle(d_dec_f16_g, x, n);
    cublasRowMajorGemmExMixed(blas_handle_g, d_dec_f16_g, w_f16t, y, 1, d, n) catch {};
}
// Fast GEMV: Grid=D blocks, Block=256, warp-shuffle reduction over N
inline fn kGVU(y:CUdeviceptr,x:CUdeviceptr,w:CUdeviceptr,n:u32,d:u32) void {
    var a0=y;var a1=x;var a2=w;var a3=n;var a4=d;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2),@ptrCast(&a3),@ptrCast(&a4)};
    checkLaunch(cuLaunch(fn_gv_fast,d,1,1,256,1,1,32,stream,&p,null), "kGVF");
}
inline fn kF2H(dst:CUdeviceptr,src:CUdeviceptr,n:u32) void {
    var a0=dst;var a1=src;var a2=n;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2)};
    _ = cuLaunch(fn_f2h,(n+255)/256,1,1,256,1,1,0,stream,&p,null);
}
inline fn kF2HSingle(dst: CUdeviceptr, src: CUdeviceptr, n: u32) void {
    var a0 = dst; var a1 = src; var a2 = n;
    var p = [_]?*anyopaque{@ptrCast(&a0), @ptrCast(&a1), @ptrCast(&a2)};
    checkLaunch(cuLaunch(fn_f2h_single, (n + 255) / 256, 1, 1, 256, 1, 1, 0, stream, &p, null), "kF2HSingle");
}
inline fn kRes(dst:CUdeviceptr,src:CUdeviceptr,n:u32) void {
    var a0=dst;var a1=src;var a2=n;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2)};
    checkLaunch(cuLaunch(fn_res,(n+255)/256,1,1,256,1,1,0,stream,&p,null), "kRes");
}
inline fn kEmb(out:CUdeviceptr, emb:CUdeviceptr, tok_ptr:CUdeviceptr) void {
    var a0=out; var a1=emb; var a2=tok_ptr; var a3: u32=D;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2),@ptrCast(&a3)};
    _ = cuLaunch(fn_emb,(D+255)/256,1,1,256,1,1,0,stream,&p,null);
}
inline fn kEmbInd(out:CUdeviceptr, emb:CUdeviceptr, tokens:CUdeviceptr, pos_ptr:CUdeviceptr) void {
    var a0=out; var a1=emb; var a2=tokens; var a3=pos_ptr; var a4:u32=D;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2),@ptrCast(&a3),@ptrCast(&a4)};
    _ = cuLaunch(fn_emb_ind,(D+255)/256,1,1,256,1,1,0,stream,&p,null);
}
inline fn kPeInd(out:CUdeviceptr, pe:CUdeviceptr, pos_ptr:CUdeviceptr) void {
    var a0=out; var a1=pe; var a2=pos_ptr; var a3:u32=D;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2),@ptrCast(&a3)};
    _ = cuLaunch(fn_pe_ind,(D+255)/256,1,1,256,1,1,0,stream,&p,null);
}
inline fn kStepAdv(pos_ptr:CUdeviceptr) void {
    var a0=pos_ptr;
    var p=[_]?*anyopaque{@ptrCast(&a0)};
    _ = cuLaunch(fn_step_adv,1,1,1,1,1,1,0,stream,&p,null);
}
inline fn kBias(x:CUdeviceptr,b:CUdeviceptr,n:u32,d:u32) void {
    if (b == 0) return;
    var a0=x;var a1=b;var a2=n;var a3=d;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2),@ptrCast(&a3)};
    checkLaunch(cuLaunch(fn_bias,(n+255)/256,1,1,256,1,1,0,stream,&p,null), "kBias");
}
inline fn kGelu(x:CUdeviceptr,n:u32) void {
    var a0=x;var a1=n;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1)};
    checkLaunch(cuLaunch(fn_gelu,(n+255)/256,1,1,256,1,1,0,stream,&p,null), "kGelu");
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
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2),@ptrCast(&a3),@ptrCast(&a4),@ptrCast(&a5),@ptrCast(&a6),@ptrCast(&a7),@ptrCast(&a8)};
    checkLaunch(cuLaunch(fn_att,NH,1,1,256,1,1,0,stream,&p,null), "kAtt");
}
inline fn kAttCross(out:CUdeviceptr,q:CUdeviceptr,kc:CUdeviceptr,vc:CUdeviceptr,step_ptr:CUdeviceptr) void {
    var a0=out;var a1=q;var a2=kc;var a3=vc;var a4=step_ptr;
    var a5:u32=D/NH; // head_dim=64
    var a6:u32=D;    // kvd=D
    var a7:u32=NH;   // nkv=NH
    var a8:u32=NH;   // nh=NH
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2),@ptrCast(&a3),@ptrCast(&a4),@ptrCast(&a5),@ptrCast(&a6),@ptrCast(&a7),@ptrCast(&a8)};
    checkLaunch(cuLaunch(fn_att_cross,NH,1,1,256,1,1,0,stream,&p,null), "kAttCross");
}
// Flash Cross-Attention: dedicated kernel for decoder cross-attention (seqlen=1500 fixed)
inline fn kFlashCA(out:CUdeviceptr,q:CUdeviceptr,kc:CUdeviceptr,vc:CUdeviceptr,step_ptr:CUdeviceptr) void {
    var a0=out;var a1=q;var a2=kc;var a3=vc;var a4=step_ptr;
    var a5:u32=D/NH; var a6:u32=D; var a7:u32=NH; var a8:u32=NH;
    var p=[_]?*anyopaque{@ptrCast(&a0),@ptrCast(&a1),@ptrCast(&a2),@ptrCast(&a3),@ptrCast(&a4),@ptrCast(&a5),@ptrCast(&a6),@ptrCast(&a7),@ptrCast(&a8)};
    checkLaunch(cuLaunch(fn_flash_ca,NH,1,1,256,1,1,6016,stream,&p,null), "kFlashCA");
}

// Windows mmap helpers -> Refactored to pure heap loading
const w_api = std.os.windows;
const externs = struct {
    extern "kernel32" fn QueryPerformanceCounter(c:*i64)callconv(w_api.WINAPI)w_api.BOOL;
    extern "kernel32" fn QueryPerformanceFrequency(f:*i64)callconv(w_api.WINAPI)w_api.BOOL;
    extern "kernel32" fn GetCommandLineA() callconv(w_api.WINAPI) [*:0]const u8;
};
fn mmapFile(path:[]const u8) ![]const u8 {
    const f = try std.fs.cwd().openFile(path,.{});
    defer f.close();
    const sz = try f.getEndPos();
    if (sz > 100 * 1024 * 1024) {
        // Large file: use Windows MapViewOfFile for reliability
        var k32 = std.DynLib.open("kernel32.dll") catch {
            // Fallback to readAll
            const buf = try std.heap.page_allocator.alloc(u8, sz);
            const read_sz = try f.readAll(buf);
            if (read_sz != sz) return error.IncompleteRead;
            return buf;
        };
        const CreateFileMappingA = k32.lookup(*const fn(std.os.windows.HANDLE,?*anyopaque,u32,u32,u32,?[*:0]const u8)callconv(.C)?std.os.windows.HANDLE, "CreateFileMappingA") orelse return error.MmapFailed;
        const MapViewOfFile = k32.lookup(*const fn(?std.os.windows.HANDLE,u32,u32,u32,usize)callconv(.C)?[*]u8, "MapViewOfFile") orelse return error.MmapFailed;
        const PAGE_READONLY: u32 = 0x02;
        const FILE_MAP_READ: u32 = 0x04;
        const hMap = CreateFileMappingA(f.handle, null, PAGE_READONLY, 0, 0, null) orelse return error.MmapFailed;
        const ptr = MapViewOfFile(hMap, FILE_MAP_READ, 0, 0, 0) orelse return error.MmapFailed;
        return ptr[0..sz];
    }
    const buf = try std.heap.page_allocator.alloc(u8, sz);
    const read_sz = try f.readAll(buf);
    if (read_sz != sz) return error.IncompleteRead;
    return buf;
}

// === Safetensors direct loader ===
const SfEntry = struct { start: u64, end: u64 };
const MAX_SF_ENTRIES = 600;
var sf_data: ?[]const u8 = null;      // mmap'd safetensors file
var sf_data_offset: u64 = 0;           // offset to tensor data
var sf_keys: [MAX_SF_ENTRIES][128]u8 = undefined;
var sf_entries: [MAX_SF_ENTRIES]SfEntry = undefined;
var sf_count: u32 = 0;

fn sfInit() void {
    const data = mmapFile("model.safetensors") catch return;
    sf_data = data;
    const header_size = std.mem.readInt(u64, data[0..8], .little);
    sf_data_offset = 8 + header_size;
    const hdr = data[8..8+header_size];
    // Parse JSON entries
    var pos: usize = 0;
    while (pos < hdr.len and sf_count < MAX_SF_ENTRIES) {
        const ks = std.mem.indexOfPos(u8, hdr, pos, "\"") orelse break;
        const ke = std.mem.indexOfPos(u8, hdr, ks+1, "\"") orelse break;
        const key = hdr[ks+1..ke];
        if (std.mem.eql(u8, key, "__metadata__")) { pos = ke+1; if (std.mem.indexOfPos(u8, hdr, pos, "}")) |p| { pos = p+1; } continue; }
        const op = std.mem.indexOfPos(u8, hdr, ke, "data_offsets") orelse { pos = ke+1; continue; };
        const bs = std.mem.indexOfPos(u8, hdr, op, "[") orelse { pos = ke+1; continue; };
        const cm = std.mem.indexOfPos(u8, hdr, bs, ",") orelse { pos = ke+1; continue; };
        const be = std.mem.indexOfPos(u8, hdr, cm, "]") orelse { pos = ke+1; continue; };
        const s = std.fmt.parseInt(u64, std.mem.trim(u8, hdr[bs+1..cm], " "), 10) catch { pos = be+1; continue; };
        const e = std.fmt.parseInt(u64, std.mem.trim(u8, hdr[cm+1..be], " "), 10) catch { pos = be+1; continue; };
        const klen = @min(key.len, 127);
        @memcpy(sf_keys[sf_count][0..klen], key[0..klen]);
        sf_keys[sf_count][klen] = 0;
        sf_entries[sf_count] = .{ .start = s, .end = e };
        sf_count += 1;
        pos = be + 1;
    }
}

fn sfLookup(name: []const u8) ?[]const u8 {
    const data = sf_data orelse return null;
    for (0..sf_count) |i| {
        const klen = std.mem.indexOf(u8, &sf_keys[i], &[_]u8{0}) orelse 128;
        if (std.mem.eql(u8, sf_keys[i][0..klen], name)) {
            return data[sf_data_offset + sf_entries[i].start .. sf_data_offset + sf_entries[i].end];
        }
    }
    return null;
}

fn atomToSfKey(atom_name: []const u8, buf: *[256]u8) ?[]const u8 {
    // decoder/blocks/N/attn/query/weight → model.decoder.layers.N.self_attn.q_proj.weight
    if (std.mem.startsWith(u8, atom_name, "decoder/blocks/")) {
        const rest = atom_name["decoder/blocks/".len..];
        return mapAtomLayer(buf, "decoder", rest);
    }
    if (std.mem.startsWith(u8, atom_name, "encoder/blocks/")) {
        const rest = atom_name["encoder/blocks/".len..];
        return mapAtomLayer(buf, "encoder", rest);
    }
    if (std.mem.eql(u8, atom_name, "decoder/ln/weight")) return copyStr(buf, "model.decoder.layer_norm.weight");
    if (std.mem.eql(u8, atom_name, "decoder/ln/bias")) return copyStr(buf, "model.decoder.layer_norm.bias");
    if (std.mem.eql(u8, atom_name, "encoder/ln_post/weight")) return copyStr(buf, "model.encoder.layer_norm.weight");
    if (std.mem.eql(u8, atom_name, "encoder/ln_post/bias")) return copyStr(buf, "model.encoder.layer_norm.bias");
    if (std.mem.eql(u8, atom_name, "decoder/token_embedding/weight")) return copyStr(buf, "model.decoder.embed_tokens.weight");
    return null;
}

fn mapAtomLayer(buf: *[256]u8, ed: []const u8, rest: []const u8) ?[]const u8 {
    const slash = std.mem.indexOf(u8, rest, "/") orelse return null;
    const num = rest[0..slash];
    const suffix = rest[slash+1..];
    const M = struct { atom: []const u8, sf: []const u8 };
    const maps = [_]M{
        .{ .atom = "attn/query/weight",      .sf = "self_attn.q_proj.weight" },
        .{ .atom = "attn/query/bias",        .sf = "self_attn.q_proj.bias" },
        .{ .atom = "attn/key/weight",        .sf = "self_attn.k_proj.weight" },
        .{ .atom = "attn/key/bias",          .sf = "self_attn.k_proj.bias" },
        .{ .atom = "attn/value/weight",      .sf = "self_attn.v_proj.weight" },
        .{ .atom = "attn/value/bias",        .sf = "self_attn.v_proj.bias" },
        .{ .atom = "attn/out/weight",        .sf = "self_attn.out_proj.weight" },
        .{ .atom = "attn/out/bias",          .sf = "self_attn.out_proj.bias" },
        .{ .atom = "attn_ln/weight",         .sf = "self_attn_layer_norm.weight" },
        .{ .atom = "attn_ln/bias",           .sf = "self_attn_layer_norm.bias" },
        .{ .atom = "cross_attn/query/weight",.sf = "encoder_attn.q_proj.weight" },
        .{ .atom = "cross_attn/query/bias",  .sf = "encoder_attn.q_proj.bias" },
        .{ .atom = "cross_attn/key/weight",  .sf = "encoder_attn.k_proj.weight" },
        .{ .atom = "cross_attn/value/weight",.sf = "encoder_attn.v_proj.weight" },
        .{ .atom = "cross_attn/value/bias",  .sf = "encoder_attn.v_proj.bias" },
        .{ .atom = "cross_attn/out/weight",  .sf = "encoder_attn.out_proj.weight" },
        .{ .atom = "cross_attn/out/bias",    .sf = "encoder_attn.out_proj.bias" },
        .{ .atom = "cross_attn_ln/weight",   .sf = "encoder_attn_layer_norm.weight" },
        .{ .atom = "cross_attn_ln/bias",     .sf = "encoder_attn_layer_norm.bias" },
        .{ .atom = "mlp/0/weight",           .sf = "fc1.weight" },
        .{ .atom = "mlp/0/bias",             .sf = "fc1.bias" },
        .{ .atom = "mlp/2/weight",           .sf = "fc2.weight" },
        .{ .atom = "mlp/2/bias",             .sf = "fc2.bias" },
        .{ .atom = "mlp_ln/weight",          .sf = "final_layer_norm.weight" },
        .{ .atom = "mlp_ln/bias",            .sf = "final_layer_norm.bias" },
    };
    for (maps) |m| {
        if (std.mem.eql(u8, suffix, m.atom)) {
            return std.fmt.bufPrint(buf, "model.{s}.layers.{s}.{s}", .{ed, num, m.sf}) catch null;
        }
    }
    return null;
}

fn copyStr(buf: *[256]u8, s: []const u8) []const u8 {
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

// Read tensor: try safetensors first, then quarks fallback
// quarks stores bias/LN as F32, safetensors stores everything as F16
// Auto-convert F16→F32 for bias and LayerNorm tensors
fn needsF32(name: []const u8) bool {
    // bias tensors
    if (name.len >= 4 and std.mem.endsWith(u8, name, "bias")) return true;
    // LayerNorm weights: attn_ln/weight, mlp_ln/weight, ln/weight, ln_post/weight
    if (std.mem.indexOf(u8, name, "_ln/") != null) return true;
    if (std.mem.indexOf(u8, name, "ln/") != null) return true;
    if (std.mem.indexOf(u8, name, "ln_post/") != null) return true;
    return false;
}

var sf_f32_bufs: [128]?[]u8 = [_]?[]u8{null} ** 128;
var sf_f32_count: u32 = 0;

fn sfConvertF16toF32(raw: []const u8) ?[]const u8 {
    const n = raw.len / 2;
    const f32_buf = std.heap.page_allocator.alloc(u8, n * 4) catch return null;
    const u16s = @as([*]const u16, @ptrCast(@alignCast(raw.ptr)))[0..n];
    const f32s = @as([*]f32, @ptrCast(@alignCast(f32_buf.ptr)))[0..n];
    for (0..n) |i| { f32s[i] = @floatCast(@as(f16, @bitCast(u16s[i]))); }
    if (sf_f32_count < 128) { sf_f32_bufs[sf_f32_count] = f32_buf; sf_f32_count += 1; }
    return f32_buf;
}

fn sfReadTensor(atom_base: []const u8, atom_name: []const u8) ?[]const u8 {
    if (sf_data != null) {
        var kb: [256]u8 = undefined;
        if (atomToSfKey(atom_name, &kb)) |sf_key| {
            if (sfLookup(sf_key)) |slice| {
                if (needsF32(atom_name)) {
                    return sfConvertF16toF32(slice);
                }
                return slice;
            }
        }
    }
    // Fallback: quarks file
    var pb: [512]u8 = undefined;
    const path = std.fmt.bufPrint(&pb, "{s}/{s}/data.bin", .{atom_base, atom_name}) catch return null;
    return mmapFile(path) catch null;
}

fn openCublas() !std.DynLib {
    return std.DynLib.open("cublas64_12.dll") catch {
        return std.DynLib.open("cublas64_11.dll") catch {
            return std.DynLib.open("C:\\Program Files\\NVIDIA GPU Computing Toolkit\\CUDA\\v11.8\\bin\\cublas64_11.dll");
        };
    };
}

fn uploadF16Tensor(alloc: std.mem.Allocator, base: []const u8, name: []const u8) !CUdeviceptr {
    _ = alloc;
    const data = sfReadTensor(base, name) orelse return error.TensorNotFound;
    var dp: CUdeviceptr = 0;
    if (cuAlloc(&dp, data.len) != 0 or dp == 0) return error.CudaAllocFailed;
    if (cuH2D(dp, data.ptr, data.len) != 0) return error.CudaCopyFailed;
    return dp;
}

fn uploadF16TensorAsF32Transposed(alloc: std.mem.Allocator, atom_path: []const u8, tensor_name: []const u8, rows: u32, cols: u32) !CUdeviceptr {
    const data = sfReadTensor(atom_path, tensor_name) orelse return error.TensorNotFound;
    const count = data.len / 2;
    if (count != rows * cols) return error.SizeMismatch;
    
    var f32_data = try alloc.alloc(f32, count);
    defer alloc.free(f32_data);
    
    const u16_data = std.mem.bytesAsSlice(u16, data);
    
    // Transpose: src is [rows][cols], dst is [cols][rows]
    for (0..rows) |r| {
        for (0..cols) |c| {
            const bits = u16_data[r * cols + c];
            f32_data[c * rows + r] = @floatCast(@as(f16, @bitCast(bits)));
        }
    }
    
    var dp: CUdeviceptr = 0;
    if (cuAlloc(&dp, count * 4) != 0 or dp == 0) return error.CudaAllocFailed;
    if (cuH2D(dp, f32_data.ptr, count * 4) != 0) return error.CudaCopyFailed;
    return dp;
}

fn uploadF16TensorAsF16Transposed(alloc: std.mem.Allocator, atom_path: []const u8, tensor_name: []const u8, rows: u32, cols: u32) !CUdeviceptr {
    const data = sfReadTensor(atom_path, tensor_name) orelse return error.TensorNotFound;
    const count = data.len / 2;
    if (count != rows * cols) return error.SizeMismatch;
    
    var f16_data = try alloc.alloc(u16, count);
    defer alloc.free(f16_data);
    
    const u16_data = std.mem.bytesAsSlice(u16, data);
    
    // Transpose: src is [rows][cols], dst is [cols][rows]
    for (0..rows) |r| {
        for (0..cols) |c| {
            const bits = u16_data[r * cols + c];
            f16_data[c * rows + r] = bits;
        }
    }
    
    var dp: CUdeviceptr = 0;
    if (cuAlloc(&dp, count * 2) != 0 or dp == 0) return error.CudaAllocFailed;
    if (cuH2D(dp, f16_data.ptr, count * 2) != 0) return error.CudaCopyFailed;
    return dp;
}

fn cublasRowMajorGemmExMixed(handle: CublasHandle, a_rm_f16: CUdeviceptr, w_rm_transposed: CUdeviceptr, c_rm: CUdeviceptr, m: u32, n: u32, k: u32) !void {
    // A_rm_f16 is [m, k] (F16), W_rm_transposed is [k, n] (F16). C_rm is [m, n] (F32).
    // Column-major representation: C_cm = W_cm @ A_cm
    // W_cm is F16 [n, k] -> lda = n, type = CUDA_R_16F (2)
    // A_cm is F16 [k, m] -> ldb = k, type = CUDA_R_16F (2)
    // C_cm is F32 [n, m] -> ldc = n, type = CUDA_R_32F (0)
    var alpha: f32 = 1.0;
    var beta: f32 = 0.0;
    
    const status = cublasGemmEx(
        handle,
        CUBLAS_OP_N, CUBLAS_OP_N,
        @intCast(n), @intCast(m), @intCast(k),
        &alpha,
        w_rm_transposed, 2, @intCast(n),  // A = W_cm (type 2 = F16)
        a_rm_f16, 2, @intCast(k),         // B = A_cm (type 2 = F16)
        &beta,
        c_rm, 0, @intCast(n),             // C = C_cm (type 0 = F32)
        0,                                 // computeType = CUDA_R_32F (0)
        -1                                 // CUBLAS_GEMM_DEFAULT_TENSOR_OP = -1
    );
    if (status != 0) return error.CublasGemmExFailed;
}

fn cublasRowMajorSgemmTransposedWeight(handle: CublasHandle, a_rm: CUdeviceptr, w_rm_transposed: CUdeviceptr, c_rm: CUdeviceptr, m: u32, n: u32, k: u32) !void {
    // A_rm is [m, k], W_rm_transposed is [k, n]. C_rm is [m, n].
    // C_cm = W_cm * A_cm
    // W_cm is [n, k] (because W_rm_trans is [k, n]). lda = n.
    // A_cm is [k, m]. ldb = k.
    // C_cm is [n, m]. ldc = n.
    var alpha: f32 = 1.0;
    var beta: f32 = 0.0;
    const status = cublasSgemm(handle, CUBLAS_OP_N, CUBLAS_OP_N, @intCast(n), @intCast(m), @intCast(k), &alpha, w_rm_transposed, @intCast(n), a_rm, @intCast(k), &beta, c_rm, @intCast(n));
    if (status != 0) return error.CublasSgemmFailed;
}

fn uploadF16TensorAsF32(alloc: std.mem.Allocator, base: []const u8, name: []const u8) !CUdeviceptr {
    var pb: [512]u8 = undefined;
    const path = try std.fmt.bufPrint(&pb, "{s}/{s}/data.bin", .{ base, name });
    const data = try mmapFile(path);
    if (data.len % 2 != 0) return error.InvalidF16Tensor;
    const count = data.len / 2;
    const f32_data = try alloc.alloc(f32, count);
    defer alloc.free(f32_data);
    for (0..count) |i| {
        const lo: u16 = data[i * 2];
        const hi: u16 = @as(u16, data[i * 2 + 1]) << 8;
        const bits: u16 = lo | hi;
        f32_data[i] = @floatCast(@as(f16, @bitCast(bits)));
    }
    var dp: CUdeviceptr = 0;
    if (cuAlloc(&dp, count * 4) != 0 or dp == 0) return error.CudaAllocFailed;
    if (cuH2D(dp, f32_data.ptr, count * 4) != 0) return error.CudaCopyFailed;
    return dp;
}

fn cublasRowMajorSgemm(handle: CublasHandle, a_rm: CUdeviceptr, b_rm: CUdeviceptr, c_rm: CUdeviceptr, m: u32, n: u32, k: u32) !void {
    var alpha: f32 = 1.0;
    var beta: f32 = 0.0;
    const status = cublasSgemm(handle, CUBLAS_OP_T, CUBLAS_OP_N, @intCast(n), @intCast(m), @intCast(k), &alpha, b_rm, @intCast(k), a_rm, @intCast(k), &beta, c_rm, @intCast(n));
    if (status != 0) return error.CublasSgemmFailed;
}


fn computeCrossAttentionKv(handle: CublasHandle, d_enc_out: CUdeviceptr, d_ckc: CUdeviceptr, d_cvc: CUdeviceptr, ckW32: []CUdeviceptr, cvW32: []CUdeviceptr, cvB: []CUdeviceptr) !void {
    var d_enc_out_f16: CUdeviceptr = 0;
    if (cuAlloc(&d_enc_out_f16, ENC_SEQ * D * 2) != 0 or d_enc_out_f16 == 0) return error.CudaAllocFailed;
    defer _ = cuFree(d_enc_out_f16);
    
    kF2HSingle(d_enc_out_f16, d_enc_out, ENC_SEQ * D);

    for (0..NL) |l| {
        const layer_off = @as(u64, @intCast(l)) * ENC_SEQ * D * 4;
        try cublasRowMajorGemmExMixed(handle, d_enc_out_f16, ckW32[l], d_ckc + layer_off, ENC_SEQ, D, D);
        try cublasRowMajorGemmExMixed(handle, d_enc_out_f16, cvW32[l], d_cvc + layer_off, ENC_SEQ, D, D);
        if (cvB[l] != 0) kBias(d_cvc + layer_off, cvB[l], ENC_SEQ * D, D);
    }
    // reverted(CUDA SYNC FAILED!\n, .{});
    
    // Dump layer 0 for debugging
    const alloc = std.heap.page_allocator;
    const buf = try alloc.alloc(u8, ENC_SEQ * D * 4);
    defer alloc.free(buf);
    _ = cuD2H(buf.ptr, d_ckc, buf.len);
    const file = try std.fs.cwd().createFile("ckc_zig.bin", .{});
    defer file.close();
    try file.writeAll(buf);
}

const Tokenizer = struct {
    tokens: std.ArrayList([]const u8),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator, path: []const u8) !Tokenizer {
        const data = try mmapFile(path);
        var tokens = std.ArrayList([]const u8).init(alloc);
        var offset: usize = 4; // First 4 bytes is vocab size
        const vocab_size = std.mem.readInt(u32, data[0..4][0..4], .little);
        for (0..vocab_size) |_| {
            if (offset + 4 > data.len) break;
            const len = std.mem.readInt(u32, data[offset..offset+4][0..4], .little);
            offset += 4;
            if (offset + len > data.len) break;
            try tokens.append(data[offset..offset+len]);
            offset += len;
        }
        return Tokenizer{ .tokens = tokens, .alloc = alloc };
    }

    pub fn decode(self: *const Tokenizer, ids: []const u32, out: anytype) !void {
        for (ids) |id| {
            if (id < self.tokens.items.len) {
                try out.writeAll(self.tokens.items[id]);
            }
        }
        try out.print("\n", .{});
    }
};
fn nowMs() f64 {
    var c:i64=0; var f:i64=0;
    _ = externs.QueryPerformanceCounter(&c); _ = externs.QueryPerformanceFrequency(&f);
    return @as(f64,@floatFromInt(c))/@as(f64,@floatFromInt(f))*1000.0;
}

fn loadPtxMod(nv: *std.DynLib, alloc: std.mem.Allocator, fname: []const u8) !*anyopaque {
    const cuModLD = nv.lookup(*const fn(**anyopaque,[*]const u8)callconv(.C)CUresult,"cuModuleLoadData").?;
    const data = try mmapFile(fname);
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

pub fn main() !void {
    const out = std.io.getStdOut().writer();
    const alloc = std.heap.page_allocator;
    try out.print("\n=== MADI DECODER V2 ===\n",.{});

    // 1. CUDA init
    var nv = std.DynLib.open("nvcuda.dll") catch { try out.print("nvcuda.dll not found\n",.{}); return; };
    const cuInit  = nv.lookup(*const fn(u32)callconv(.C)CUresult,"cuInit").?;
    const cuDevGet= nv.lookup(*const fn(*i32,i32)callconv(.C)CUresult,"cuDeviceGet").?;
    const cuCtxCr = nv.lookup(*const fn(**anyopaque,u32,i32)callconv(.C)CUresult,"cuCtxCreate_v2").?;
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
    _ = cuInit(0);
    // Parse --gpu N from command line
    var gpu_id: i32 = 0;
    {
        const cmd = std.mem.span(externs.GetCommandLineA());
        if (std.mem.indexOf(u8, cmd, "--gpu ")) |pos| {
            const rest = cmd[pos + 6..];
            gpu_id = std.fmt.parseInt(i32, rest[0..1], 10) catch 0;
        }
    }
    var dev:i32=undefined; _ = cuDevGet(&dev, gpu_id);
    var ctx:*anyopaque=undefined; _ = cuCtxCr(&ctx,0,dev);
    _ = cuStreamCreate(&stream,0);
    cuCapBegin = nv.lookup(@TypeOf(cuCapBegin),"cuStreamBeginCapture_v2").?;
    cuCapEnd   = nv.lookup(@TypeOf(cuCapEnd),  "cuStreamEndCapture").?;
    cuGrInst   = nv.lookup(@TypeOf(cuGrInst),  "cuGraphInstantiateWithFlags").?;
    cuGrLaunch = nv.lookup(@TypeOf(cuGrLaunch),"cuGraphLaunch").?;
    try out.print("[1] CUDA device {d} (Graph API loaded)\n",.{dev});

    var blas = openCublas() catch { try out.print("cuBLAS DLL not found\n", .{}); return; };
    const cublasCreate = blas.lookup(*const fn(*CublasHandle)callconv(.C)i32, "cublasCreate_v2").?;
    const cublasSetStream = blas.lookup(*const fn(CublasHandle, CUstream)callconv(.C)i32, "cublasSetStream_v2").?;
    cublasSgemm = blas.lookup(@TypeOf(cublasSgemm), "cublasSgemm_v2").?;
    cublasSgemmStridedBatched = blas.lookup(@TypeOf(cublasSgemmStridedBatched), "cublasSgemmStridedBatched").?;
    cublasGemmEx = blas.lookup(@TypeOf(cublasGemmEx), "cublasGemmEx").?;
    var blas_handle: CublasHandle = null;
    if (cublasCreate(&blas_handle) != 0 or blas_handle == null) return error.CublasCreateFailed;
    if (cublasSetStream(blas_handle, stream) != 0) return error.CublasSetStreamFailed;
    
    // Enable TF32 math mode
    if (blas.lookup(*const fn(CublasHandle, i32)callconv(.C)i32, "cublasSetMathMode")) |cublasSetMathMode| {
        _ = cublasSetMathMode(blas_handle, 3); // CUBLAS_TF32_TENSOR_OP_MATH
    }

    try out.print("[1b] cuBLAS SGEMM ready (TF32 enabled)\n", .{});
    blas_handle_g = blas_handle;

    var bpe = try Tokenizer.init(alloc, "WHISPER_BPE.bin");
    try out.print("[1c] Native BPE Tokenizer loaded ({d} tokens)\n", .{bpe.tokens.items.len});
    // Auto-detect GPU SM version → select kernel directory
    const cuDevGetAttr = nv.lookup(*const fn(*i32, i32, i32)callconv(.C)CUresult, "cuDeviceGetAttribute").?;
    var sm_major: i32 = 0; var sm_minor: i32 = 0;
    _ = cuDevGetAttr(&sm_major, 75, dev); // CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MAJOR
    _ = cuDevGetAttr(&sm_minor, 76, dev); // CU_DEVICE_ATTRIBUTE_COMPUTE_CAPABILITY_MINOR
    const sm_ver = @as(u32, @intCast(sm_major)) * 10 + @as(u32, @intCast(sm_minor));
    var sm_dir_buf: [32]u8 = undefined;
    const sm_dir: []const u8 = blk: {
        if (sm_ver >= 89) break :blk std.fmt.bufPrint(&sm_dir_buf, "kernels/sm89", .{}) catch "kernels/sm89"
        else if (sm_ver >= 86) break :blk std.fmt.bufPrint(&sm_dir_buf, "kernels/sm86", .{}) catch "kernels/sm86"
        else break :blk std.fmt.bufPrint(&sm_dir_buf, "kernels/sm86", .{}) catch "kernels/sm86";
    };
    try out.print("[1d] GPU sm_{d} detected → {s}/\n", .{sm_ver, sm_dir});

    // 2. Load compiled GPU modules (auto-selected for GPU architecture)
    var kb: [15][128]u8 = undefined;
    const kn = [_][]const u8{"whisper_kernels","whisper_ops","gpu_ops_root_backup","tensor_core","layer_norm","f16_convert","decoder_ops","f32_gemv_fixed","f32_gemv_fast","bias_res_ln","mfa_align","graph_helpers","flash_attention_enc","flash_cross_attn","conv1d"};
    var kp: [15][]const u8 = undefined;
    for (0..15) |i| { kp[i] = std.fmt.bufPrint(&kb[i], "{s}/{s}.bin", .{sm_dir, kn[i]}) catch ""; }
    const mod_wk  = try loadPtxMod(&nv,alloc,kp[0]);
    const mod_ops = try loadPtxMod(&nv,alloc,kp[1]);
    const mod_gpu = try loadPtxMod(&nv,alloc,kp[2]);
    const mod_tc  = try loadPtxMod(&nv,alloc,kp[3]);
    const mod_ln  = try loadPtxMod(&nv,alloc,kp[4]);
    const mod_f16 = try loadPtxMod(&nv,alloc,kp[5]);
    const mod_dec = try loadPtxMod(&nv,alloc,kp[6]);
    const mod_gv  = try loadPtxMod(&nv,alloc,kp[7]);
    _ = cuGetF(&fn_gelu,  mod_wk,  "gelu_f32");
    _ = cuGetF(&fn_soft,  mod_wk,  "softmax_f32");
    _ = cuGetF(&fn_bias,  mod_wk,  "bias_add");
    _ = cuGetF(&fn_scale, mod_wk,  "scale_f32");
    _ = cuGetF(&fn_kv_store, mod_ops, "gpu_kv_store");
    _ = cuGetF(&fn_res,   mod_gpu, "gpu_residual");
    _ = cuGetF(&fn_emb,   mod_gpu, "gpu_emb_lookup");
    _ = cuGetF(&fn_att,   mod_gpu, "gpu_attention");
    _ = cuGetF(&fn_att_cross, mod_gpu, "gpu_attention");
    _ = cuGetF(&fn_tc,    mod_tc,  "tc_gemv");
    _ = cuGetF(&fn_ln,    mod_ln,  "layer_norm");
    _ = cuGetF(&fn_f2h,   mod_f16, "f32_to_f16_batch16");
    _ = cuGetF(&fn_f2h_single, mod_f16, "f32_to_f16");
    _ = cuGetF(&fn_filt,  mod_dec, "logit_filter");
    _ = cuGetF(&fn_argmax,mod_dec, "argmax_append");
    _ = cuGetF(&fn_gv,    mod_gv,  "f32_gemv");
    const mod_gvf = try loadPtxMod(&nv,alloc,kp[8]);
    _ = cuGetF(&fn_gv_fast, mod_gvf, "f32_gemv_fast");
    _ = cuGetF(&fn_gv32,  mod_gv,  "f32_gemv_f32w");
    const mod_brln = try loadPtxMod(&nv, alloc, kp[9]);
    _ = cuGetF(&fn_bias_res_ln, mod_brln, "bias_res_ln");
    const mod_mfa = try loadPtxMod(&nv,alloc,kp[10]);
    _ = cuGetF(&fn_ca_head, mod_mfa, "extract_ca_head");
    _ = cuGetF(&fn_suppress, mod_mfa, "suppress_apply");
    const mod_gh = try loadPtxMod(&nv,alloc,kp[11]);
    _ = cuGetF(&fn_emb_ind, mod_gh, "emb_lookup_indirect");
    _ = cuGetF(&fn_pe_ind,  mod_gh, "pos_embed_add_indirect");
    _ = cuGetF(&fn_step_adv,mod_gh, "step_advance");
    _ = cuGetF(&fn_argmax_ni,mod_gh, "argmax_no_inc");
    _ = cuGetF(&fn_filt_ind, mod_gh, "logit_filter_indirect");
    const mod_fa = try loadPtxMod(&nv,alloc,kp[12]);
    _ = cuGetF(&fn_flash_enc, mod_fa, "flash_attention_enc");
    const mod_fca = try loadPtxMod(&nv,alloc,kp[13]);
    _ = cuGetF(&fn_flash_ca, mod_fca, "flash_cross_attn");
    const mod_conv = try loadPtxMod(&nv,alloc,kp[14]);
    _ = cuGetF(&fn_conv1d_gelu, mod_conv, "conv1d_gelu");
    try out.print("[2] GPU modules loaded (15 kernels from {s})\n",.{sm_dir});

    // 3. Tensor loading (safetensors direct → quarks fallback)
    sfInit();
    if (sf_data != null) {
        try out.print("[3] model.safetensors loaded ({d} tensors)\n", .{sf_count});
    } else {
        try out.print("[3] Using quarks/whisper-turbo-v3-atom/\n", .{});
    }
    const hr = nv.lookup(*const fn(*const anyopaque,usize,u32)callconv(.C)CUresult,"cuMemHostRegister_v2").?;
    const hg = nv.lookup(*const fn(*CUdeviceptr,*const anyopaque,u32)callconv(.C)CUresult,"cuMemHostGetDevicePointer_v2").?;
    const ATOM: []const u8 = "quarks/whisper-turbo-v3-atom";
    const mapTen = struct {
        fn f(base:[]const u8,name:[]const u8,hr2:*const fn(*const anyopaque,usize,u32)callconv(.C)CUresult,hg2:*const fn(*CUdeviceptr,*const anyopaque,u32)callconv(.C)CUresult) CUdeviceptr {
            _ = hr2; _ = hg2;
            const d = sfReadTensor(base, name) orelse return 0;
            var dp:CUdeviceptr=0;
            if (cuAlloc(&dp,d.len)!=0 or dp==0) return 0;
            if (cuH2D(dp,d.ptr,d.len)!=0) {
                _ = cuFree(dp);
                return 0;
            }
            return dp;
        }
    }.f;
    // const tok_emb=mapTen(ATOM,"decoder/token_embedding/weight",hr,hg);
    // pos_emb: F16→F32 from safetensors, or quarks fallback
    var pos_emb: CUdeviceptr = 0;
    {
        if (sfLookup("model.decoder.embed_positions.weight")) |raw| {
            // safetensors: F16 → convert to F32
            const n = raw.len / 2;
            var f32_buf = alloc.alloc(f32, n) catch unreachable;
            defer alloc.free(f32_buf);
            const u16s = @as([*]const u16, @ptrCast(@alignCast(raw.ptr)))[0..n];
            for (0..n) |i| { f32_buf[i] = @floatCast(@as(f16, @bitCast(u16s[i]))); }
            _ = cuAlloc(&pos_emb, n * 4);
            _ = cuH2D(pos_emb, f32_buf.ptr, n * 4);
        } else {
            const pe_data = mmapFile("quarks/whisper-turbo-v3-atom/pos_emb_f32.bin") catch unreachable;
            _ = cuAlloc(&pos_emb, pe_data.len);
            _ = cuH2D(pos_emb, pe_data.ptr, pe_data.len);
        }
    }
    var d_enc_pe: CUdeviceptr = 0;
    {
        if (sfLookup("model.encoder.embed_positions.weight")) |raw| {
            // safetensors: F16 → F32
            const n = raw.len / 2;
            var f32_buf = alloc.alloc(f32, n) catch unreachable;
            const u16s = @as([*]const u16, @ptrCast(@alignCast(raw.ptr)))[0..n];
            for (0..n) |i| { f32_buf[i] = @floatCast(@as(f16, @bitCast(u16s[i]))); }
            _ = cuAlloc(&d_enc_pe, n * 4);
            _ = cuH2D(d_enc_pe, f32_buf.ptr, n * 4);
        } else {
            const enc_pe_data = mmapFile("quarks/whisper-turbo-v3-atom/enc_weights/pos_emb.bin") catch unreachable;
            _ = cuAlloc(&d_enc_pe, enc_pe_data.len);
            _ = cuH2D(d_enc_pe, enc_pe_data.ptr, enc_pe_data.len);
        }
    }
    const ln_w=mapTen(ATOM,"decoder/ln/weight",hr,hg);
    const ln_b=mapTen(ATOM,"decoder/ln/bias",hr,hg);
    const elnp_w = mapTen(ATOM,"encoder/ln_post/weight",hr,hg);
    const elnp_b = mapTen(ATOM,"encoder/ln_post/bias",hr,hg);

    var ealnW:[ENL]CUdeviceptr=undefined; var ealnB:[ENL]CUdeviceptr=undefined;
    var eqW:[ENL]CUdeviceptr=undefined;   var eqB:[ENL]CUdeviceptr=undefined;
    var ekW:[ENL]CUdeviceptr=undefined;   var ekB:[ENL]CUdeviceptr=undefined;
    var evW:[ENL]CUdeviceptr=undefined;   var evB:[ENL]CUdeviceptr=undefined;
    var eoW:[ENL]CUdeviceptr=undefined;   var eoB:[ENL]CUdeviceptr=undefined;
    var emlnW:[ENL]CUdeviceptr=undefined; var emlnB:[ENL]CUdeviceptr=undefined;
    var em0W:[ENL]CUdeviceptr=undefined;  var em0B:[ENL]CUdeviceptr=undefined;
    var em2W:[ENL]CUdeviceptr=undefined;  var em2B:[ENL]CUdeviceptr=undefined;

    var eqW32:[ENL]CUdeviceptr=undefined;
    var ekW32:[ENL]CUdeviceptr=undefined;
    var evW32:[ENL]CUdeviceptr=undefined;
    var eoW32:[ENL]CUdeviceptr=undefined;
    var em0W32:[ENL]CUdeviceptr=undefined;
    var em2W32:[ENL]CUdeviceptr=undefined;
    var eqkvW32:[ENL]CUdeviceptr=undefined;
    // var eqW16:[ENL]CUdeviceptr=undefined;
    // var ekW16:[ENL]CUdeviceptr=undefined;
    // var evW16:[ENL]CUdeviceptr=undefined;

    for (0..ENL) |l| {
        var nb:[8][128]u8=undefined;
        const pre=std.fmt.bufPrint(&nb[0],"encoder/blocks/{d}",.{l}) catch unreachable;
        ealnW[l]=mapTen(ATOM,std.fmt.bufPrint(&nb[1],"{s}/attn_ln/weight",.{pre}) catch unreachable,hr,hg);
        ealnB[l]=mapTen(ATOM,std.fmt.bufPrint(&nb[2],"{s}/attn_ln/bias",.{pre}) catch unreachable,hr,hg);
        eqW[l]  =mapTen(ATOM,std.fmt.bufPrint(&nb[3],"{s}/attn/query/weight",.{pre}) catch unreachable,hr,hg);
        eqW32[l]=try uploadF16TensorAsF32Transposed(alloc,ATOM,std.fmt.bufPrint(&nb[3],"{s}/attn/query/weight",.{pre}) catch unreachable, D, D);
        eqB[l]  =mapTen(ATOM,std.fmt.bufPrint(&nb[4],"{s}/attn/query/bias",.{pre}) catch unreachable,hr,hg);
        ekW[l]  =mapTen(ATOM,std.fmt.bufPrint(&nb[5],"{s}/attn/key/weight",.{pre}) catch unreachable,hr,hg);
        ekW32[l]=try uploadF16TensorAsF32Transposed(alloc,ATOM,std.fmt.bufPrint(&nb[5],"{s}/attn/key/weight",.{pre}) catch unreachable, D, D);
        ekB[l]  =mapTen(ATOM,std.fmt.bufPrint(&nb[6],"{s}/attn/key/bias",.{pre}) catch unreachable,hr,hg);
        evW[l]  =mapTen(ATOM,std.fmt.bufPrint(&nb[7],"{s}/attn/value/weight",.{pre}) catch unreachable,hr,hg);
        evW32[l]=try uploadF16TensorAsF32Transposed(alloc,ATOM,std.fmt.bufPrint(&nb[7],"{s}/attn/value/weight",.{pre}) catch unreachable, D, D);
        _ = cuAlloc(&eqkvW32[l], D * D * 4 * 3);
        _ = cuD2D(eqkvW32[l], eqW32[l], D * D * 4);
        _ = cuD2D(eqkvW32[l] + D * D * 4, ekW32[l], D * D * 4);
        _ = cuD2D(eqkvW32[l] + D * D * 4 * 2, evW32[l], D * D * 4);



        var nb2:[8][128]u8=undefined;
        evB[l]  =mapTen(ATOM,std.fmt.bufPrint(&nb2[0],"{s}/attn/value/bias",.{pre}) catch unreachable,hr,hg);
        eoW[l]  =mapTen(ATOM,std.fmt.bufPrint(&nb2[1],"{s}/attn/out/weight",.{pre}) catch unreachable,hr,hg);
        eoW32[l]=try uploadF16TensorAsF16Transposed(alloc,ATOM,std.fmt.bufPrint(&nb2[1],"{s}/attn/out/weight",.{pre}) catch unreachable, D, D);
        eoB[l]  =mapTen(ATOM,std.fmt.bufPrint(&nb2[2],"{s}/attn/out/bias",.{pre}) catch unreachable,hr,hg);
        emlnW[l]=mapTen(ATOM,std.fmt.bufPrint(&nb2[3],"{s}/mlp_ln/weight",.{pre}) catch unreachable,hr,hg);
        emlnB[l]=mapTen(ATOM,std.fmt.bufPrint(&nb2[4],"{s}/mlp_ln/bias",.{pre}) catch unreachable,hr,hg);
        em0W[l] =mapTen(ATOM,std.fmt.bufPrint(&nb2[5],"{s}/mlp/0/weight",.{pre}) catch unreachable,hr,hg);
        em0W32[l]=try uploadF16TensorAsF16Transposed(alloc,ATOM,std.fmt.bufPrint(&nb2[5],"{s}/mlp/0/weight",.{pre}) catch unreachable, MLP, D);
        em0B[l] =mapTen(ATOM,std.fmt.bufPrint(&nb2[6],"{s}/mlp/0/bias",.{pre}) catch unreachable,hr,hg);
        em2W[l] =mapTen(ATOM,std.fmt.bufPrint(&nb2[7],"{s}/mlp/2/weight",.{pre}) catch unreachable,hr,hg);
        em2W32[l]=try uploadF16TensorAsF16Transposed(alloc,ATOM,std.fmt.bufPrint(&nb2[7],"{s}/mlp/2/weight",.{pre}) catch unreachable, D, MLP);
        var nb3:[3][128]u8=undefined;
        em2B[l] =mapTen(ATOM,std.fmt.bufPrint(&nb3[0],"{s}/mlp/2/bias",.{pre}) catch unreachable,hr,hg);
    }

    var alnW:[NL]CUdeviceptr=undefined; var alnB:[NL]CUdeviceptr=undefined;
    var qW:[NL]CUdeviceptr=undefined;   var qB:[NL]CUdeviceptr=undefined;
    var kW:[NL]CUdeviceptr=undefined;
    var vW:[NL]CUdeviceptr=undefined;   var vB:[NL]CUdeviceptr=undefined;
    var oW:[NL]CUdeviceptr=undefined;   var oB:[NL]CUdeviceptr=undefined;
    var calnW:[NL]CUdeviceptr=undefined;var calnB:[NL]CUdeviceptr=undefined;
    var cqW:[NL]CUdeviceptr=undefined;  var cqB:[NL]CUdeviceptr=undefined;
    var ckW:[NL]CUdeviceptr=undefined;
    var ckW32:[NL]CUdeviceptr=undefined;
    var cvW32:[NL]CUdeviceptr=undefined;
    var cvW:[NL]CUdeviceptr=undefined;  var cvB:[NL]CUdeviceptr=undefined;
    var coW:[NL]CUdeviceptr=undefined;  var coB:[NL]CUdeviceptr=undefined;
    var mlnW:[NL]CUdeviceptr=undefined; var mlnB:[NL]CUdeviceptr=undefined;
    var m0W:[NL]CUdeviceptr=undefined;  var m0B:[NL]CUdeviceptr=undefined;
    var m2W:[NL]CUdeviceptr=undefined;  var m2B:[NL]CUdeviceptr=undefined;
    // cuBLAS-ready F16 transposed weights for decoder GEMV
    var dqW16:[NL]CUdeviceptr=undefined;
    var dkW16:[NL]CUdeviceptr=undefined;
    var dvW16:[NL]CUdeviceptr=undefined;
    var doW16:[NL]CUdeviceptr=undefined;
    var dcqW16:[NL]CUdeviceptr=undefined;
    var dcoW16:[NL]CUdeviceptr=undefined;
    var dm0W16:[NL]CUdeviceptr=undefined;
    var dm2W16:[NL]CUdeviceptr=undefined;
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
        ckW32[l] = try uploadF16TensorAsF16Transposed(alloc, ATOM, std.fmt.bufPrint(&nb2[6],"{s}/cross_attn/key/weight",.{pre}) catch unreachable, D, D);
        cvW[l] =mapTen(ATOM,std.fmt.bufPrint(&nb2[7],"{s}/cross_attn/value/weight",.{pre}) catch unreachable,hr,hg);
        cvW32[l] = try uploadF16TensorAsF16Transposed(alloc, ATOM, std.fmt.bufPrint(&nb2[7],"{s}/cross_attn/value/weight",.{pre}) catch unreachable, D, D);
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
        // Upload F16 transposed weights for cuBLAS decoder GEMV
        dqW16[l] = try uploadF16TensorAsF16Transposed(alloc,ATOM,std.fmt.bufPrint(&nb[3],"{s}/attn/query/weight",.{pre}) catch unreachable, D, D);
        dkW16[l] = try uploadF16TensorAsF16Transposed(alloc,ATOM,std.fmt.bufPrint(&nb[5],"{s}/attn/key/weight",.{pre}) catch unreachable, D, D);
        dvW16[l] = try uploadF16TensorAsF16Transposed(alloc,ATOM,std.fmt.bufPrint(&nb[6],"{s}/attn/value/weight",.{pre}) catch unreachable, D, D);
        doW16[l] = try uploadF16TensorAsF16Transposed(alloc,ATOM,std.fmt.bufPrint(&nb2[0],"{s}/attn/out/weight",.{pre}) catch unreachable, D, D);
        dcqW16[l]= try uploadF16TensorAsF16Transposed(alloc,ATOM,std.fmt.bufPrint(&nb2[4],"{s}/cross_attn/query/weight",.{pre}) catch unreachable, D, D);
        dcoW16[l]= try uploadF16TensorAsF16Transposed(alloc,ATOM,std.fmt.bufPrint(&nb3[1],"{s}/cross_attn/out/weight",.{pre}) catch unreachable, D, D);
        dm0W16[l]= try uploadF16TensorAsF16Transposed(alloc,ATOM,std.fmt.bufPrint(&nb3[5],"{s}/mlp/0/weight",.{pre}) catch unreachable, D, MLP);
        dm0W16_g[l] = dm0W16[l];
        dm2W16[l]= try uploadF16TensorAsF16Transposed(alloc,ATOM,std.fmt.bufPrint(&nb4[1],"{s}/mlp/2/weight",.{pre}) catch unreachable, MLP, D);
        dm2W16_g[l] = dm2W16[l];
    }
    
    for (0..ENL) |l| {
        if (eqW[l] == 0 or ekW[l] == 0 or evW[l] == 0 or em0W[l] == 0 or em2W[l] == 0 or eoW[l] == 0 or ealnW[l] == 0 or emlnW[l] == 0) {
            try out.print("CRITICAL: Missing weights at Encoder layer {d}!\n", .{l});
            return error.MissingWeights;
        }
    }

    for (0..NL) |l| {
        if (qW[l] == 0 or kW[l] == 0 or vW[l] == 0 or oW[l] == 0 or alnW[l] == 0 or mlnW[l] == 0 or m0W[l] == 0 or m2W[l] == 0 or cqW[l] == 0 or ckW[l] == 0 or cvW[l] == 0 or coW[l] == 0 or calnW[l] == 0) {
            try out.print("CRITICAL: Missing weights at Decoder layer {d}!\n", .{l});
            return error.MissingWeights;
        }
    }
    
    // 4. GPU scratch — Batched encoder: buffers sized for MAX_BATCH chunks
    var d_e_x: CUdeviceptr = 0;   _ = cuAlloc(&d_e_x, MAX_BATCH * ENC_SEQ * D * 4);
    var d_e_x_ln: CUdeviceptr=0;  _ = cuAlloc(&d_e_x_ln, MAX_BATCH * ENC_SEQ * D * 4);
    var d_e_qkv: CUdeviceptr = 0; _ = cuAlloc(&d_e_qkv, MAX_BATCH * ENC_SEQ * D * 4 * 3);
    var d_e_ao: CUdeviceptr = 0;  _ = cuAlloc(&d_e_ao, MAX_BATCH * ENC_SEQ * D * 4);
    var d_e_mo: CUdeviceptr = 0;  _ = cuAlloc(&d_e_mo, MAX_BATCH * ENC_SEQ * D * 4);
    var d_e_mh: CUdeviceptr = 0;  _ = cuAlloc(&d_e_mh, MAX_BATCH * ENC_SEQ * MLP * 4);
    var d_enc_out: CUdeviceptr = 0; _ = cuAlloc(&d_enc_out, MAX_BATCH * ENC_SEQ * D * 4);


    var d_x: CUdeviceptr = 0;   _ = cuAlloc(&d_x, D * 4 * 16);
    var d_xb: CUdeviceptr = 0;  _ = cuAlloc(&d_xb, D * 4 * 16);
    var d_xf: CUdeviceptr = 0;  _ = cuAlloc(&d_xf, MLP * 2 * 16);
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
    var d_scores: CUdeviceptr = 0; _ = cuAlloc(&d_scores, 20 * 1504 * 1504 * 4);
    // Decoder cuBLAS scratch: F16 input buffer for GEMV
    var d_dec_f16: CUdeviceptr = 0; _ = cuAlloc(&d_dec_f16, MLP * 2);
    d_dec_f16_g = d_dec_f16;
    var d_ca_weights:CUdeviceptr=0; _ = cuAlloc(&d_ca_weights, MAX_TOK*ENC_SEQ*4);
    _ = cuMemset(d_ca_weights, 0, MAX_TOK*ENC_SEQ*4);
    
    // Flash Attention Encoder: Grid-parallel Warp-only (kAtt 1504x 순차 → 단일 커널)
    // Grid: (NH=20, SEQ=1504, 1), Block: (32, 1, 1) — Warp-only, 0 shared memory
    try out.print("[G] Flash Attention Encoder loaded (Grid 20x1504, Warp-only)\n", .{});

    try out.print("[4] GPU buffers allocated (+ca_weights)\n",.{});


    // 5. Load shared data (1x): cross-attn KV cache + tok embeddings
    var d_tok_emb_f32: CUdeviceptr=0; _ = cuAlloc(&d_tok_emb_f32, VOCAB*D*4);
    var te_data: []const u8 = undefined;
    var te_f32_owned: ?[]f32 = null;
    if (sfLookup("model.decoder.embed_tokens.weight")) |raw| {
        // safetensors: F16 → F32 conversion
        const n = raw.len / 2;
        te_f32_owned = alloc.alloc(f32, n) catch unreachable;
        const u16s = @as([*]const u16, @ptrCast(@alignCast(raw.ptr)))[0..n];
        for (0..n) |i| { te_f32_owned.?[i] = @floatCast(@as(f16, @bitCast(u16s[i]))); }
        te_data = std.mem.sliceAsBytes(te_f32_owned.?);
        _ = cuH2D(d_tok_emb_f32, te_data.ptr, te_data.len);
    } else {
        te_data = mmapFile("quarks/whisper-turbo-v3-atom/tok_emb_f32.bin") catch unreachable;
        _ = cuH2D(d_tok_emb_f32, te_data.ptr, te_data.len);
    }
    
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

    // reverted(CUDA SYNC FAILED!\n, .{});
    try out.print("[4b] Shared data loaded (ckc/cvc/tok_emb)\n",.{});

    // 5b. Load WAV preprocessing weights (conv1d + mel filters)
    const mel_filt_raw = try std.fs.cwd().readFileAlloc(alloc, "mel_filters.bin", 1024*1024);
    const mel_filters = std.mem.bytesAsSlice(f32, mel_filt_raw);
    // Helper: convert F16 safetensors slice → F32 bytes
    const sfF16toF32 = struct {
        fn conv(a: std.mem.Allocator, raw: []const u8) []const u8 {
            const n = raw.len / 2;
            var f32_buf = a.alloc(f32, n) catch unreachable;
            const u16s = @as([*]const u16, @ptrCast(@alignCast(raw.ptr)))[0..n];
            for (0..n) |i| { f32_buf[i] = @floatCast(@as(f16, @bitCast(u16s[i]))); }
            return std.mem.sliceAsBytes(f32_buf);
        }
        // Conv weight: safetensors [out_ch, in_ch, k] → quarks [k, in_ch, out_ch] (perm 2,1,0)
        fn convWeight(a: std.mem.Allocator, raw: []const u8, out_ch: u32, in_ch: u32, k: u32) []const u8 {
            const n = raw.len / 2;
            var f32_buf = a.alloc(f32, n) catch unreachable;
            const u16s = @as([*]const u16, @ptrCast(@alignCast(raw.ptr)))[0..n];
            // Transpose [out_ch][in_ch][k] → [k][in_ch][out_ch]
            for (0..k) |ki| {
                for (0..in_ch) |ic| {
                    for (0..out_ch) |oc| {
                        const src_idx = oc * in_ch * k + ic * k + ki;
                        const dst_idx = ki * in_ch * out_ch + ic * out_ch + oc;
                        f32_buf[dst_idx] = @floatCast(@as(f16, @bitCast(u16s[src_idx])));
                    }
                }
            }
            return std.mem.sliceAsBytes(f32_buf);
        }
    };
    const c1w_data = if (sfLookup("model.encoder.conv1.weight")) |raw| sfF16toF32.convWeight(alloc, raw, 1280, 128, 3) else blk: { var wpb:[512]u8=undefined; break :blk try std.fs.cwd().readFileAlloc(alloc, std.fmt.bufPrint(&wpb, "quarks/whisper-turbo-v3-atom/enc_weights/conv1_w.bin", .{}) catch unreachable, 4*1024*1024); };
    const c1b_data = if (sfLookup("model.encoder.conv1.bias")) |raw| sfF16toF32.conv(alloc, raw) else blk: { var wpb:[512]u8=undefined; break :blk try std.fs.cwd().readFileAlloc(alloc, std.fmt.bufPrint(&wpb, "quarks/whisper-turbo-v3-atom/enc_weights/conv1_b.bin", .{}) catch unreachable, 64*1024); };
    const c2w_data = if (sfLookup("model.encoder.conv2.weight")) |raw| sfF16toF32.convWeight(alloc, raw, 1280, 1280, 3) else blk: { var wpb:[512]u8=undefined; break :blk try std.fs.cwd().readFileAlloc(alloc, std.fmt.bufPrint(&wpb, "quarks/whisper-turbo-v3-atom/enc_weights/conv2_w.bin", .{}) catch unreachable, 40*1024*1024); };
    const c2b_data = if (sfLookup("model.encoder.conv2.bias")) |raw| sfF16toF32.conv(alloc, raw) else blk: { var wpb:[512]u8=undefined; break :blk try std.fs.cwd().readFileAlloc(alloc, std.fmt.bufPrint(&wpb, "quarks/whisper-turbo-v3-atom/enc_weights/conv2_b.bin", .{}) catch unreachable, 64*1024); };
    var d_c1w: CUdeviceptr=0; _ = cuAlloc(&d_c1w, c1w_data.len); _ = cuH2D(d_c1w, c1w_data.ptr, c1w_data.len);
    var d_c1b: CUdeviceptr=0; _ = cuAlloc(&d_c1b, c1b_data.len); _ = cuH2D(d_c1b, c1b_data.ptr, c1b_data.len);
    var d_c2w: CUdeviceptr=0; _ = cuAlloc(&d_c2w, c2w_data.len); _ = cuH2D(d_c2w, c2w_data.ptr, c2w_data.len);
    var d_c2b: CUdeviceptr=0; _ = cuAlloc(&d_c2b, c2b_data.len); _ = cuH2D(d_c2b, c2b_data.ptr, c2b_data.len);
    var d_mel_buf: CUdeviceptr=0; _ = cuAlloc(&d_mel_buf, N_MELS * N_FRAMES * 4);
    var d_conv1_out: CUdeviceptr=0; _ = cuAlloc(&d_conv1_out, D * N_FRAMES * 4);
    var d_conv2_out: CUdeviceptr=0; _ = cuAlloc(&d_conv2_out, D * 1500 * 4);
    try out.print("[5a] WAV preprocessing weights loaded (conv1d + mel filters)\n",.{});

    // 6. Build input list from args (multi-input queue)
    var argit = try std.process.argsWithAllocator(alloc);
    _ = argit.next(); // skip exe name
    var input_buf: [64][]const u8 = undefined;
    var n_inputs: usize = 0;
    while (argit.next()) |arg| {
        if (n_inputs < 64) { input_buf[n_inputs] = arg; n_inputs += 1; }
    }
    if (n_inputs == 0) {
        input_buf[0] = "enc_in.bin";
        n_inputs = 1;
    }
    try out.print("[5] Queue: {d} input(s)\n", .{n_inputs});

    // 7. Batched encoder processing
    var d_e_ao_f16: CUdeviceptr = 0; _ = cuAlloc(&d_e_ao_f16, MAX_BATCH * ENC_SEQ * D * 2);
    var d_e_x_ln_f16: CUdeviceptr = 0; _ = cuAlloc(&d_e_x_ln_f16, MAX_BATCH * ENC_SEQ * D * 2);
    var d_e_mh_f16: CUdeviceptr = 0; _ = cuAlloc(&d_e_mh_f16, MAX_BATCH * ENC_SEQ * MLP * 2);
    
    // Hann window (precompute once)
    var hann_win: [N_FFT]f32 = undefined;
    for (&hann_win, 0..) |*v, i| {
        const x = @sin(PI * @as(f64, @floatFromInt(i)) / @as(f64, N_FFT - 1));
        v.* = @floatCast(x * x);
    }

    // Precompute DFT twiddle factors × Hann window (eliminates all cos/sin from hot loop)
    // twiddle_re[k][n] = cos(-2πkn/N) * hann[n], twiddle_im[k][n] = sin(-2πkn/N) * hann[n]
    const FFT_BINS: usize = N_FFT / 2; // 200
    const twiddle_re = try alloc.alloc(f32, FFT_BINS * N_FFT); // 200×400 = 80K × 4 = 320KB
    const twiddle_im = try alloc.alloc(f32, FFT_BINS * N_FFT);
    for (0..FFT_BINS) |k| {
        const af = -2.0 * PI * @as(f64, @floatFromInt(k)) / @as(f64, N_FFT);
        for (0..N_FFT) |n| {
            const a = af * @as(f64, @floatFromInt(n));
            const w: f64 = @floatCast(hann_win[n]);
            twiddle_re[k * N_FFT + n] = @floatCast(w * @cos(a));
            twiddle_im[k * N_FFT + n] = @floatCast(w * @sin(a));
        }
    }
    try out.print("[5c] DFT twiddle table precomputed ({d}×{d} = {d}KB)\n", .{FFT_BINS, N_FFT, FFT_BINS * N_FFT * 4 * 2 / 1024});

    // Upload twiddle tables to GPU for SGEMM-based DFT
    var d_twiddle_re: CUdeviceptr = 0;
    var d_twiddle_im: CUdeviceptr = 0;
    var d_frames: CUdeviceptr = 0;
    var d_re_out: CUdeviceptr = 0;
    var d_im_out: CUdeviceptr = 0;
    _ = cuAlloc(&d_twiddle_re, FFT_BINS * N_FFT * 4);
    _ = cuAlloc(&d_twiddle_im, FFT_BINS * N_FFT * 4);
    _ = cuAlloc(&d_frames, N_FRAMES * N_FFT * 4);     // [3000][400]
    _ = cuAlloc(&d_re_out, N_FRAMES * FFT_BINS * 4);   // [3000][200]
    _ = cuAlloc(&d_im_out, N_FRAMES * FFT_BINS * 4);   // [3000][200]
    _ = cuH2D(d_twiddle_re, twiddle_re.ptr, FFT_BINS * N_FFT * 4);
    _ = cuH2D(d_twiddle_im, twiddle_im.ptr, FFT_BINS * N_FFT * 4);
    try out.print("[5d] GPU STFT buffers allocated (twiddle + frames + output)\n", .{});

    var file_idx: usize = 0;
    var wav_chunk_state: usize = 0; // tracks current chunk within a long WAV
    while (file_idx < n_inputs) {
        // Collect batch: load up to MAX_BATCH files into contiguous GPU buffer
        const batch_start = file_idx;
        var batch_count: u32 = 0;
        while (batch_count < MAX_BATCH and file_idx < n_inputs) {
            const enc_path = input_buf[file_idx];
            const offset = batch_count * ENC_SEQ * D * 4;
            
            // Detect .wav vs .bin
            const is_wav = enc_path.len >= 4 and std.mem.eql(u8, enc_path[enc_path.len-4..], ".wav");
            
            if (is_wav) {
                // === WAV PREPROCESSING PIPELINE (auto-split long files) ===
                try out.print("[WAV] Processing: {s}\n", .{enc_path});
                
                // 1. Read WAV file
                const wav_data = std.fs.cwd().readFileAlloc(alloc, enc_path, 2*1024*1024*1024) catch {
                    try out.print("WAV read failed: {s} — skipping\n", .{enc_path});
                    file_idx += 1;
                    continue;
                };
                defer alloc.free(wav_data);
                
                // Find "data" chunk
                var header_size: usize = 44;
                for (0..wav_data.len - 4) |i| {
                    if (std.mem.eql(u8, wav_data[i..i+4], "data")) { header_size = i + 8; break; }
                }
                const pcm_bytes = wav_data[header_size..];
                const channels = @as(*align(1) const u16, @ptrCast(wav_data.ptr + 22)).*;
                const bits_ps = @as(*align(1) const u16, @ptrCast(wav_data.ptr + 34)).*;
                const n_samples_total = pcm_bytes.len / (bits_ps / 8) / channels;
                const chunk_samples: usize = CHUNK_SECS * SAMPLE_RATE; // 30s window
                const stride_samples: usize = STRIDE_SECS * SAMPLE_RATE; // 28s stride (2s overlap)
                // n_chunks: first chunk at 0, then stride by 28s until we cover all samples
                const n_chunks = if (n_samples_total <= chunk_samples) @as(usize, 1) else (n_samples_total - chunk_samples + stride_samples - 1) / stride_samples + 1;
                try out.print("[WAV] {d} samples ({d:.1}s) → {d} chunk(s) [stride={d}s, overlap=2s]\n", .{n_samples_total, @as(f64, @floatFromInt(n_samples_total)) / @as(f64, SAMPLE_RATE), n_chunks, STRIDE_SECS});
                
                // Process single chunk at wav_chunk_state index
                const chunk_idx = wav_chunk_state;
                const sample_offset = chunk_idx * stride_samples; // stride-based offset!
                const avail = n_samples_total - @min(sample_offset, n_samples_total);
                const n_samples = @min(avail, chunk_samples);
                const offset_sec = @as(f64, @floatFromInt(sample_offset)) / @as(f64, SAMPLE_RATE);
                try out.print("  [chunk {d}/{d}] offset={d:.1}s samples={d}\n", .{chunk_idx+1, n_chunks, offset_sec, n_samples});
                const samples = try alloc.alloc(f32, chunk_samples);
                defer alloc.free(samples);
                @memset(samples, 0);
                if (bits_ps == 16) {
                    const pcm16 = @as([*]align(1) const i16, @ptrCast(pcm_bytes.ptr));
                    for (0..n_samples) |i| {
                        samples[i] = @as(f32, @floatFromInt(pcm16[(sample_offset + i) * channels])) / 32768.0;
                    }
                }
                
                // 3. STFT via GPU SGEMM + CPU Mel Filterbank
                const padding: usize = N_FFT / 2;
                
                // 3a. CPU Windowing: extract reflect-padded frames [3000][400]
                const frames_buf = try alloc.alloc(f32, N_FRAMES * N_FFT);
                defer alloc.free(frames_buf);
                for (0..N_FRAMES) |fr| {
                    const stt = fr * HOP_LENGTH;
                    const row = fr * N_FFT;
                    for (0..N_FFT) |t2| {
                        const si = @as(isize, @intCast(stt + t2)) - @as(isize, @intCast(padding));
                        var ri: usize = 0;
                        if (si < 0) { ri = @intCast(-si); }
                        else if (si >= chunk_samples) { ri = @intCast(2 * @as(isize, @intCast(chunk_samples)) - 2 - si); }
                        else { ri = @intCast(si); }
                        frames_buf[row + t2] = samples[ri];
                    }
                }
                
                // 3b. GPU DFT: frames[3000×400] × twiddle[200×400]^T = output[3000×200]
                _ = cuH2D(d_frames, frames_buf.ptr, N_FRAMES * N_FFT * 4);
                // re_out = frames × twiddle_re^T (row-major SGEMM)
                try cublasRowMajorSgemm(blas_handle, d_frames, d_twiddle_re, d_re_out, N_FRAMES, FFT_BINS, N_FFT);
                // im_out = frames × twiddle_im^T
                try cublasRowMajorSgemm(blas_handle, d_frames, d_twiddle_im, d_im_out, N_FRAMES, FFT_BINS, N_FFT);
                _ = cuSync();
                
                // 3c. Download DFT results
                const re_out = try alloc.alloc(f32, N_FRAMES * FFT_BINS);
                defer alloc.free(re_out);
                const im_out = try alloc.alloc(f32, N_FRAMES * FFT_BINS);
                defer alloc.free(im_out);
                _ = cuD2H(re_out.ptr, d_re_out, N_FRAMES * FFT_BINS * 4);
                _ = cuD2H(im_out.ptr, d_im_out, N_FRAMES * FFT_BINS * 4);
                
                // 3d. CPU: Power spectrum → Mel filterbank
                const mel = try alloc.alloc(f32, N_MELS * N_FRAMES);
                defer alloc.free(mel);
                for (0..N_MELS) |m| {
                    for (0..N_FRAMES) |fr| {
                        var s: f32 = 0;
                        const fr_base = fr * FFT_BINS;
                        for (0..FFT_BINS) |k| {
                            const r = re_out[fr_base + k];
                            const im2 = im_out[fr_base + k];
                            s += (r*r + im2*im2) * mel_filters[m * 201 + k];
                        }
                        mel[m * N_FRAMES + fr] = s;
                    }
                }
                // Normalize: log10(max(mel,1e-10)) then clip+scale
                var mel_max: f32 = -1e30;
                for (mel) |*v| { const c = @max(v.*, 1e-10); v.* = @log10(c); if (v.* > mel_max) mel_max = v.*; }
                for (mel) |*v| { v.* = (@max(v.*, mel_max - 8.0) + 4.0) / 4.0; }
                
                // 4. Upload mel → GPU Conv1D×2
                _ = cuH2D(d_mel_buf, mel.ptr, N_MELS * N_FRAMES * 4);
                {
                    // Conv1: mel[128][3000] → conv1_out[1280][3000]
                    var a_out=d_conv1_out; var a_in=d_mel_buf; var a_w=d_c1w; var a_b=d_c1b;
                    var a_cin:u32=N_MELS; var a_cout:u32=D; var a_lin:u32=N_FRAMES; var a_k:u32=3; var a_s:u32=1; var a_p:u32=1;
                    var p1=[_]?*anyopaque{@ptrCast(&a_out),@ptrCast(&a_in),@ptrCast(&a_w),@ptrCast(&a_b),
                        @ptrCast(&a_cin),@ptrCast(&a_cout),@ptrCast(&a_lin),@ptrCast(&a_k),@ptrCast(&a_s),@ptrCast(&a_p)};
                    _ = cuLaunch(fn_conv1d_gelu, N_FRAMES,1,1, 256,1,1, 0,stream, &p1, null);
                    // Conv2: conv1_out[1280][3000] → conv2_out[1280][1500], stride=2
                    a_out=d_conv2_out; a_in=d_conv1_out; a_w=d_c2w; a_b=d_c2b;
                    a_cin=D; a_cout=D; a_lin=N_FRAMES; a_k=3; a_s=2; a_p=1;
                    var p2=[_]?*anyopaque{@ptrCast(&a_out),@ptrCast(&a_in),@ptrCast(&a_w),@ptrCast(&a_b),
                        @ptrCast(&a_cin),@ptrCast(&a_cout),@ptrCast(&a_lin),@ptrCast(&a_k),@ptrCast(&a_s),@ptrCast(&a_p)};
                    _ = cuLaunch(fn_conv1d_gelu, 1500,1,1, 256,1,1, 0,stream, &p2, null);
                }
                _ = cuSync();
                
                // 5. Transpose [D][1500] → [1500][D] → d_e_x
                const conv2_buf = try alloc.alloc(f32, D * 1500);
                defer alloc.free(conv2_buf);
                _ = cuD2H(conv2_buf.ptr, d_conv2_out, D * 1500 * 4);
                const enc_input = try alloc.alloc(f32, 1500 * D);
                defer alloc.free(enc_input);
                for (0..1500) |t| {
                    for (0..D) |c| {
                        enc_input[t * D + c] = conv2_buf[c * 1500 + t];
                    }
                }
                _ = cuH2D(d_e_x + offset, enc_input.ptr, 1500 * D * 4);
                _ = cuMemset(d_e_x + offset + 1500 * D * 4, 0, 4 * D * 4);
                kRes(d_e_x + offset, d_enc_pe, 1500 * D);
                batch_count += 1;
                
                // Advance chunk state; if more chunks, don't advance file_idx
                wav_chunk_state += 1;
                if (wav_chunk_state >= n_chunks) {
                    wav_chunk_state = 0;
                    file_idx += 1;
                }
                // Break to run encoder+decoder for this chunk
                break;
            } else if (mmapFile(enc_path)) |enc_data| {
                _ = cuH2D(d_e_x + offset, enc_data.ptr, enc_data.len);
                // Add positional embedding per chunk
                kRes(d_e_x + offset, d_enc_pe, 1500 * D);
                batch_count += 1;
            } else |_| {
                try out.print("Enc load failed: {s} — skipping\n", .{enc_path});
            }
            if (!is_wav) file_idx += 1;
        }
        
        if (batch_count == 0) continue;
        
        const B_SEQ: u32 = batch_count * ENC_SEQ;  // batched sequence length
        try out.print("\n=== Batched Encoder: {d} chunk(s), M={d} ===\n", .{batch_count, B_SEQ});
        
        // Initial LN for all chunks at once
        kLN(d_e_x, d_e_x_ln, ealnW[0], ealnB[0], D, B_SEQ);
        kF2HSingle(d_e_x_ln_f16, d_e_x_ln, B_SEQ * D);

        var timer = try std.time.Timer.start();


        for (0..ENL) |l| {
            // QKV Batched GEMM: M = B_SEQ (all chunks at once!)
            const d_e_q: CUdeviceptr = d_e_qkv;
            const d_e_k: CUdeviceptr = d_e_qkv + B_SEQ * D * 4;
            const d_e_v: CUdeviceptr = d_e_qkv + B_SEQ * D * 4 * 2;
            {
                var alpha: f32 = 1.0;
                var beta: f32 = 0.0;
                const n_i32: i32 = @intCast(D);
                const m_i32: i32 = @intCast(B_SEQ);
                const k_i32: i32 = @intCast(D);
                const strideB: i64 = @intCast(D * D);
                const strideC: i64 = @intCast(B_SEQ * D);
                const status = cublasSgemmStridedBatched(
                    blas_handle, CUBLAS_OP_N, CUBLAS_OP_N,
                    n_i32, m_i32, k_i32,
                    &alpha,
                    eqkvW32[l], n_i32, strideB,
                    d_e_x_ln, k_i32, 0,
                    &beta,
                    d_e_qkv, n_i32, strideC,
                    3
                );
                if (status != 0) return error.CublasBatchedFailed;
            }
            kBias(d_e_q, eqB[l], B_SEQ * D, D);
            kBias(d_e_k, ekB[l], B_SEQ * D, D);
            kBias(d_e_v, evB[l], B_SEQ * D, D);

            // Flash Attention: per-chunk
            for (0..batch_count) |bi| {
                const chunk_off: u32 = @intCast(bi * ENC_SEQ * D * 4);
                const FA_NH: u32 = 20;
                const FA_HDD: u32 = 64;
                var fa_out = d_e_ao + chunk_off;
                var fa_q = d_e_q + chunk_off;
                var fa_k = d_e_k + chunk_off;
                var fa_v = d_e_v + chunk_off;
                var fa_seq: u32 = ENC_SEQ;
                var fa_hdd: u32 = FA_HDD;
                var fa_nh: u32 = FA_NH;
                var fa_params = [_]?*anyopaque{
                    @ptrCast(&fa_out), @ptrCast(&fa_q), @ptrCast(&fa_k),
                    @ptrCast(&fa_v), @ptrCast(&fa_seq), @ptrCast(&fa_hdd), @ptrCast(&fa_nh)
                };
                _ = cuLaunch(fn_flash_enc, FA_NH, ENC_SEQ, 1, 32, 1, 1, 0, stream, &fa_params, null);
            }

            // Attention output projection
            kF2HSingle(d_e_ao_f16, d_e_ao, B_SEQ * D);
            try cublasRowMajorGemmExMixed(blas_handle, d_e_ao_f16, eoW32[l], d_e_mo, B_SEQ, D, D);
            biasResLN(d_e_x, d_e_mo, eoB[l], d_e_x_ln, emlnW[l], emlnB[l], D, B_SEQ);

            // FFN
            kF2HSingle(d_e_x_ln_f16, d_e_x_ln, B_SEQ * D);
            try cublasRowMajorGemmExMixed(blas_handle, d_e_x_ln_f16, em0W32[l], d_e_mh, B_SEQ, MLP, D);
            kBias(d_e_mh, em0B[l], B_SEQ * MLP, MLP);
            kGelu(d_e_mh, B_SEQ * MLP);
            
            kF2HSingle(d_e_mh_f16, d_e_mh, B_SEQ * MLP);
            try cublasRowMajorGemmExMixed(blas_handle, d_e_mh_f16, em2W32[l], d_e_mo, B_SEQ, D, MLP);
            
            if (l < ENL - 1) {
                biasResLN(d_e_x, d_e_mo, em2B[l], d_e_x_ln, ealnW[l+1], ealnB[l+1], D, B_SEQ);
                kF2HSingle(d_e_x_ln_f16, d_e_x_ln, B_SEQ * D);
            } else {
                biasResLN(d_e_x, d_e_mo, em2B[l], d_enc_out, elnp_w, elnp_b, D, B_SEQ);
            }
        }
        
        const sync_res = cuSync();
        if (sync_res != 0) return error.CudaSyncFailed;
        const enc_time = timer.read();
        try out.print("[ENC] {d}-chunk batched encoder done in {d:.2} ms ({d:.1} ms/chunk)\n",
            .{batch_count, @as(f64, @floatFromInt(enc_time)) / 1_000_000.0,
             @as(f64, @floatFromInt(enc_time)) / 1_000_000.0 / @as(f64, @floatFromInt(batch_count))});
        
        // Decode each chunk sequentially (decoder is autoregressive)
        for (0..batch_count) |bi| {
            const chunk_enc_out = d_enc_out + @as(CUdeviceptr, @intCast(bi * ENC_SEQ * D * 4));
            const abs_idx = batch_start + bi;
            if (n_inputs > 1) {
                try out.print("\n--- [{d}/{d}] DEC ---\n", .{abs_idx+1, n_inputs});
            }
            
            try computeCrossAttentionKv(blas_handle, chunk_enc_out, d_ckc, d_cvc, &ckW32, &cvW32, &cvB);

            const out_data = try alloc.alloc(u8, ENC_SEQ * D * 4);
            _ = cuD2H(out_data.ptr, chunk_enc_out, out_data.len);
            try runZeroShotDiarization(out, out_data);
            alloc.free(out_data);

            _ = cuMemset(d_ca_weights, 0, MAX_TOK*ENC_SEQ*4);
            try runDecodeLoop(out, alloc, d_x,d_xb,d_xf,d_q,d_ao,d_mh,d_mo,
                d_skc,d_svc,d_ckc,d_cvc,d_logits,d_tokens,d_pos,
                d_tok_emb_f16,d_tok_emb_f32,pos_emb,ln_w,ln_b,
                &alnW,&alnB,&qW,&qB,&kW,&vW,&vB,&oW,&oB,
                &calnW,&calnB,&cqW,&cqB,&ckW,&cvW,&cvB,&coW,&coB,
                &mlnW,&mlnB,&m0W,&m0B,&m2W,&m2B, chunk_enc_out, d_enc_pos, d_ca_weights, &bpe);
        }
    }
    
    _ = cuFree(d_e_ao_f16);
    _ = cuFree(d_e_x_ln_f16);
    _ = cuFree(d_e_mh_f16);

    if (n_inputs > 1) {
        try out.print("\n=== Batch complete: {d} files processed ===\n", .{n_inputs});
    }
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
    _ = d_xf;
    // Self-Attn LN
    kLN(d_x,d_xb,alnW[l],alnB[l],D,1);
    
    // Q=LN*Wq+b, K=LN*Wk, V=LN*Wv+b via F32 GEMV (F32 precision path)
    kGVU(d_q, d_xb, qW[l], D, D); kBias(d_q,qB[l],D,D);
    kGVU(d_ao, d_xb, kW[l], D, D);
    kGVU(d_mh, d_xb, vW[l], D, D); kBias(d_mh,vB[l],D,D);
    
    // Store K/V into self-attn cache
    kStore(d_skc, d_ao, D, d_pos);
    kStore(d_svc, d_mh, D, d_pos);
    kAtt(d_ao,d_q,d_skc,d_svc,d_pos);
    
    // Out proj + Residual + Cross-Attn LN (fused)
    kGVU(d_mo, d_ao, oW[l], D, D);
    biasResLN(d_x, d_mo, oB[l], d_xb, calnW[l], calnB[l], D, 1);
    
    // (fused above)
    
    kGVU(d_q, d_xb, cqW[l], D, D); kBias(d_q,cqB[l],D,D);
    kFlashCA(d_ao,d_q,d_ckc + l*ENC_SEQ*D*4, d_cvc + l*ENC_SEQ*D*4, d_enc_pos);
    
    // Extract cross-attn weights for alignment heads (inside CUDA Graph)
    const inv_n: f32 = 1.0 / @as(f32, @floatFromInt(N_ALIGN));
    for (ALIGN_HEADS) |ah| {
        if (ah[0] == l) {
            var ca0 = d_q;
            var ca1 = d_ckc + @as(u64, l)*ENC_SEQ*D*4;
            var ca2 = d_ca_weights;
            var ca3 = d_pos; // GPU pointer
            var ca4 = ah[1];
            var ca5 = inv_n;
            var cap = [_]?*anyopaque{@ptrCast(&ca0),@ptrCast(&ca1),@ptrCast(&ca2),@ptrCast(&ca3),@ptrCast(&ca4),@ptrCast(&ca5)};
            _ = cuLaunch(fn_ca_head,1,1,1,256,1,1,0,stream,&cap,null);
        }
    }
    // Cross-Attn Out + Residual + MLP LN (fused)
    kGVU(d_mo, d_ao, coW[l], D, D);
    biasResLN(d_x, d_mo, coB[l], d_xb, mlnW[l], mlnB[l], D, 1);
    
    // (fused above)
    kGVU(d_mh, d_xb, m0W[l], D, MLP); kBias(d_mh, m0B[l], MLP, MLP);
    kGelu(d_mh,MLP);
    kGVU(d_mo, d_mh, m2W[l], MLP, D); kBias(d_mo, m2B[l], D, D);
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
    d_enc_out:CUdeviceptr, d_enc_pos:CUdeviceptr, d_ca_weights:CUdeviceptr, bpe: *const Tokenizer) !void {
    _ = d_enc_out;
    // Standard safe heap load for suppress tokens to bypass page faults
    const sup_f = try std.fs.cwd().openFile("suppress_tokens.bin", .{});
    defer sup_f.close();
    const sup_sz = try sup_f.getEndPos();
    const suppress_data = try alloc.alloc(u8, sup_sz);
    defer alloc.free(suppress_data);
    const sup_bytes = try sup_f.readAll(suppress_data);
    if (sup_bytes != sup_sz) return error.ReadFailed;
    const suppress_count: u32 = @intCast(sup_sz / 4);
    const suppress_tokens = @as([*]const u32, @ptrCast(@alignCast(suppress_data.ptr)))[0..suppress_count];

    const SEED = [_]u32{50258, 50264, 50360, 50364};
    var seq_len: u32 = @intCast(SEED.len);
    _ = cuH2D(d_tokens, &SEED, SEED.len*4);
    _ = cuH2D(d_pos, &seq_len, 4);

    // Clear ca_weights buffer
    _ = cuMemset(d_ca_weights, 0, MAX_TOK*ENC_SEQ*4);

    const MAX_STEPS: u32 = 224;
    var out_tokens: [MAX_TOK]u32 = undefined;
    const EOT: u32 = 50257;

    // Initialize out_tokens with SEED
    for (SEED, 0..) |s, i| {
        out_tokens[i] = s;
    }

    const cpu_logits = try alloc.alloc(f32, 51872);
    defer alloc.free(cpu_logits);

    const t0 = nowMs();

    // Phase 1: SEED steps (0..2) — fill KV caches without prediction
    for (0..SEED.len - 1) |si| {
        const s: u32 = @intCast(si);
        _ = cuH2D(d_pos, &s, 4);
        
        // Corridor Sparse Attention: d_enc_pos에 1500 + step 값 복사
        const enc_pos_val: u32 = 1500 + s;
        _ = cuH2D(d_enc_pos, &enc_pos_val, 4);

        const tok_ptr = d_tokens + @as(u64, s)*4;
        kEmb(d_x, d_tok_emb_f32, tok_ptr);
        kRes(d_x, pos_emb + @as(u64, s)*D*4, D);

        for (0..NL) |l| {
            decodeBlock(l, d_x,d_xb,d_xf,d_q,d_ao,d_mh,d_mo,
                        d_skc + l*MAX_TOK*D*4, d_svc + l*MAX_TOK*D*4, d_ckc, d_cvc, d_pos,
                        alnW,alnB,qW,qB,kW,vW,vB,oW,oB,
                        calnW,calnB,cqW,cqB,ckW,cvW,cvB,coW,coB,
                        mlnW,mlnB,m0W,m0B,m2W,m2B,d_enc_pos,d_ca_weights);
        }
    }

    // === DECODER PROFILING: 1-step breakdown ===
    {
        _ = cuSync();
        const prof_s: u32 = SEED.len - 1;
        _ = cuH2D(d_pos, &prof_s, 4);
        const enc_pv: u32 = 1500 + prof_s;
        _ = cuH2D(d_enc_pos, &enc_pv, 4);
        kEmb(d_x, d_tok_emb_f32, d_tokens + @as(u64, prof_s)*4);
        kRes(d_x, pos_emb + @as(u64, prof_s)*D*4, D);
        _ = cuSync();
        var t_sa = try std.time.Timer.start();
        for (0..NL) |l| {
            kLN(d_x,d_xb,alnW[l],alnB[l],D,1);
            kGVU(d_q, d_xb, qW[l], D, D); kBias(d_q,qB[l],D,D);
            kGVU(d_ao, d_xb, kW[l], D, D);
            kGVU(d_mh, d_xb, vW[l], D, D); kBias(d_mh,vB[l],D,D);
            kStore(d_skc + l*MAX_TOK*D*4, d_ao, D, d_pos);
            kStore(d_svc + l*MAX_TOK*D*4, d_mh, D, d_pos);
            kAtt(d_ao,d_q,d_skc + l*MAX_TOK*D*4,d_svc + l*MAX_TOK*D*4,d_pos);
            kGVU(d_mo, d_ao, oW[l], D, D); kBias(d_mo,oB[l],D,D);
            kRes(d_x,d_mo,D);
        }
        _ = cuSync();
        const sa_us = t_sa.read();
        var t_ca = try std.time.Timer.start();
        for (0..NL) |l| {
            kLN(d_x,d_xb,calnW[l],calnB[l],D,1);
            kGVU(d_q, d_xb, cqW[l], D, D); kBias(d_q,cqB[l],D,D);
            kFlashCA(d_ao,d_q,d_ckc + l*ENC_SEQ*D*4, d_cvc + l*ENC_SEQ*D*4, d_enc_pos);
            kGVU(d_mo, d_ao, coW[l], D, D); kBias(d_mo,coB[l],D,D);
            kRes(d_x,d_mo,D);
        }
        _ = cuSync();
        const ca_us = t_ca.read();
        var t_mlp = try std.time.Timer.start();
        for (0..NL) |l| {
            kLN(d_x,d_xb,mlnW[l],mlnB[l],D,1);
            kGVU(d_mh, d_xb, m0W[l], D, MLP); kBias(d_mh, m0B[l], MLP, MLP);
            kGelu(d_mh,MLP);
            kGVU(d_mo, d_mh, m2W[l], MLP, D); kBias(d_mo, m2B[l], D, D);
            kRes(d_x,d_mo,D);
        }
        _ = cuSync();
        const mlp_us = t_mlp.read();
        var t_logit = try std.time.Timer.start();
        kLN(d_x,d_xb,ln_w,ln_b,D,1);
        kGVU(d_logits, d_xb, tok_emb, D, 51872);
        _ = cuSync();
        const logit_us = t_logit.read();
        try out.print("\n=== DECODER PROFILING (1 step, {d} layers) ===\n", .{NL});
        try out.print("  Self-Attn:  {d:.2} ms\n", .{@as(f64, @floatFromInt(sa_us)) / 1_000_000.0});
        try out.print("  Cross-Attn: {d:.2} ms\n", .{@as(f64, @floatFromInt(ca_us)) / 1_000_000.0});
        try out.print("  MLP:        {d:.2} ms\n", .{@as(f64, @floatFromInt(mlp_us)) / 1_000_000.0});
        try out.print("  Logit:      {d:.2} ms\n", .{@as(f64, @floatFromInt(logit_us)) / 1_000_000.0});
        const total_us = sa_us + ca_us + mlp_us + logit_us;
        try out.print("  TOTAL:      {d:.2} ms  (x137 = {d:.0} ms est.)\n", .{@as(f64, @floatFromInt(total_us)) / 1_000_000.0, @as(f64, @floatFromInt(total_us)) / 1_000_000.0 * 137.0});

        // cuBLAS MLP comparison
        var t_cmlp = try std.time.Timer.start();
        for (0..NL) |l| {
            kLN(d_x,d_xb,mlnW[l],mlnB[l],D,1);
            kGVU(d_mh, d_xb, m0W[l], D, MLP); kBias(d_mh, m0B[l], MLP, MLP);
            kGelu(d_mh,MLP);
            kGVU(d_mo, d_mh, m2W[l], MLP, D); kBias(d_mo, m2B[l], D, D);
            kRes(d_x,d_mo,D);
        }
        _ = cuSync();
        const umlp_us = t_cmlp.read();
        try out.print("  Fast MLP:   {d:.2} ms  (vs PTX {d:.2} ms)\n", .{@as(f64, @floatFromInt(umlp_us)) / 1_000_000.0, @as(f64, @floatFromInt(mlp_us)) / 1_000_000.0});
    }
    // Phase 2: Step 3 — first prediction step, capture CUDA Graph
    {
        const s3: u32 = SEED.len - 1; // = 3
        _ = cuH2D(d_pos, &s3, 4);
        
        // Initialize enc_pos on GPU (will be incremented by step_advance inside graph)
        const enc_pos_init: u32 = 1500 + s3;
        _ = cuH2D(d_enc_pos, &enc_pos_init, 4);
    }

    // Capture decoder graph: embed → decode → LN → logit → filter → enc_pos++ → step++ → argmax
    var dec_graph: ?*anyopaque = null;
    var dec_exec: ?*anyopaque = null;

    if (cuCapBegin(stream, 0) == 0) {
        // 1. Indirect embedding lookup (reads token from d_tokens[*d_pos])
        kEmbInd(d_x, d_tok_emb_f32, d_tokens, d_pos);
        // 2. Indirect positional embedding add
        kPeInd(d_x, pos_emb, d_pos);

        // 3. Forward through all decoder blocks
        for (0..NL) |l| {
            decodeBlock(l, d_x,d_xb,d_xf,d_q,d_ao,d_mh,d_mo,
                        d_skc + l*MAX_TOK*D*4, d_svc + l*MAX_TOK*D*4, d_ckc, d_cvc, d_pos,
                        alnW,alnB,qW,qB,kW,vW,vB,oW,oB,
                        calnW,calnB,cqW,cqB,ckW,cvW,cvB,coW,coB,
                        mlnW,mlnB,m0W,m0B,m2W,m2B,d_enc_pos,d_ca_weights);
        }

        // 4. Final LN + logit projection
        kLN(d_x,d_xb,ln_w,ln_b,D,1);
        kGVU(d_logits, d_xb, tok_emb, D, 51872);

        // 5. GPU logit filter (indirect — reads step from d_pos)
        {
            var f0=d_logits; var f1=d_tokens; var f2:u32=0; var f3=d_pos; var f4:u32=@intCast(SEED.len);
            var pf=[_]?*anyopaque{@ptrCast(&f0),@ptrCast(&f1),@ptrCast(&f2),@ptrCast(&f3),@ptrCast(&f4)};
            _ = cuLaunch(fn_filt_ind,1,1,1,256,1,1,0,stream,&pf,null);
        }

        // 6. enc_pos advance: *d_enc_pos += 1 (GPU-side, no cuH2D needed)
        kStepAdv(d_enc_pos);

        // 7. step_advance: *d_pos += 1
        kStepAdv(d_pos);

        // 8. GPU argmax: tokens[*d_pos] = argmax(logits)
        {
            var g0=d_logits; var g1=d_tokens; var g2=d_pos; var g3:u32=MAX_STEPS;
            var pg=[_]?*anyopaque{@ptrCast(&g0),@ptrCast(&g1),@ptrCast(&g2),@ptrCast(&g3)};
            _ = cuLaunch(fn_argmax_ni,1,1,1,1024,1,1,0,stream,&pg,null);
        }

        _ = cuCapEnd(stream, &dec_graph);
        if (dec_graph) |g| {
            _ = cuGrInst(&dec_exec, g, 0);
        }
    }

    var step: u32 = @intCast(SEED.len - 1);

    if (dec_exec) |exec| {
        // Speculative Decoding: draft (2-layer) → verify (4-layer)
        _ = @as(u32, 4); // DRAFT_K placeholder
        const BATCH: u32 = 8;
        
        {
            // Non-speculative fallback (same as before)
            while (step < MAX_STEPS) {
                const remaining = MAX_STEPS - step;
                const this_batch = if (remaining < BATCH) remaining else BATCH;
                for (0..this_batch) |_| {
                    _ = cuGrLaunch(exec, stream);
                }
                _ = cuSync();
                _ = cuD2H(out_tokens[step + 1..].ptr, d_tokens + @as(u64, step + 1) * 4, this_batch * 4);
                var found_eot = false;
                for (0..this_batch) |bi| {
                    if (out_tokens[step + 1 + bi] == EOT) {
                        step += @as(u32, @intCast(bi)) + 1;
                        found_eot = true;
                        break;
                    }
                }
                if (found_eot) break;
                step += this_batch;
            }
        }
    } else {
        // Fallback: non-graph path (should not normally reach here)
        while (step < MAX_STEPS) : (step += 1) {
            _ = cuH2D(d_pos, &step, 4);
            const tok_ptr = d_tokens + @as(u64, step)*4;
            kEmb(d_x, d_tok_emb_f32, tok_ptr);
            kRes(d_x, pos_emb + @as(u64, step)*D*4, D);

            for (0..NL) |l| {
                decodeBlock(l, d_x,d_xb,d_xf,d_q,d_ao,d_mh,d_mo,
                            d_skc + l*MAX_TOK*D*4, d_svc + l*MAX_TOK*D*4, d_ckc, d_cvc, d_pos,
                            alnW,alnB,qW,qB,kW,vW,vB,oW,oB,
                            calnW,calnB,cqW,cqB,ckW,cvW,cvB,coW,coB,
                            mlnW,mlnB,m0W,m0B,m2W,m2B,d_enc_pos,d_ca_weights);
            }
            kLN(d_x,d_xb,ln_w,ln_b,D,1);
            kGVU(d_logits, d_xb, tok_emb, D, 51872);
            _ = cuSync();
            _ = cuD2H(cpu_logits.ptr, d_logits, 51872 * 4);
            for (suppress_tokens) |sid| {
                if (sid < 51872) cpu_logits[sid] = -1e20;
            }
            for (50258..51866) |t| cpu_logits[t] = -1e20;
            var best_t: u32 = 50257;
            var best_v: f32 = -1e38;
            for (0..51866) |t| {
                if (cpu_logits[t] > best_v) { best_v = cpu_logits[t]; best_t = @intCast(t); }
            }
            _ = cuH2D(d_tokens + @as(u64, step + 1) * 4, &best_t, 4);
            out_tokens[step + 1] = best_t;
            if (best_t == EOT) { step += 1; break; }
        }
    }

    const elapsed = nowMs() - t0;
    try out.print("[5] Decoded {d} tokens in {d:.1}ms ({d:.1} tok/s)\n",
        .{step, elapsed, @as(f64,@floatFromInt(step))/elapsed*1000.0});
    try out.print("Tokens:", .{});
    for (out_tokens[0..step]) |t| try out.print(" {d}", .{t});

    try out.print("\n\n[🤖 Text Output]: ", .{});
    try bpe.decode(out_tokens[0..step], out);
    try out.print("\n", .{});

    // === Word-level timestamps from cross-attention weights ===
    const n_text = step - SEED.len; // text tokens only
    if (n_text > 0) {
        // Download ca_weights [MAX_TOK x ENC_SEQ] from GPU
        const ca_size = MAX_TOK * ENC_SEQ;
        const ca_buf = try alloc.alloc(f32, ca_size);
        defer alloc.free(ca_buf);
        _ = cuD2H(ca_buf.ptr, d_ca_weights, ca_size * 4);

        // Median filter (kernel size 3) on each text token's attention row
        var filtered = try alloc.alloc(f32, ca_size);
        defer alloc.free(filtered);
        for (SEED.len..step) |ti| {
            const row = ca_buf[ti*ENC_SEQ .. (ti+1)*ENC_SEQ];
            const frow = filtered[ti*ENC_SEQ .. (ti+1)*ENC_SEQ];
            for (0..ENC_SEQ) |j| {
                const lo = if (j > 0) j-1 else 0;
                const hi = if (j+1 < ENC_SEQ) j+1 else ENC_SEQ-1;
                var a_v = row[lo]; var b_v = row[j]; var c_v = row[hi];
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
