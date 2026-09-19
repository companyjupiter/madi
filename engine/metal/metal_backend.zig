// metal_backend.zig — Lean Zig wrapper over the Objective-C Metal bridge.
// Self-contained Whisper port. Exposes only what the Madi
// pipeline needs, mapping 1:1 onto the CUDA Driver API idioms the original
// code used (cuLaunchKernel → dispatch, cuMemAlloc → alloc, etc.).
//
// Apple Silicon unified memory: alloc() returns a pointer that is valid on
// BOTH cpu and gpu. So "H2D"/"D2H" copies collapse to plain memcpy — there
// is no separate device address space like CUDA's CUdeviceptr.
const std = @import("std");

// ── C bridge externs (metal_backend.h) ──────────────────────────────
extern fn mtl_init() c_int;
extern fn mtl_cleanup() void;
extern fn mtl_alloc(size: usize) ?*anyopaque;
extern fn mtl_free(ptr: ?*anyopaque) void;
extern fn mtl_load_library_data(data: ?*const anyopaque, len: c_ulong) c_int;
extern fn mtl_get_function(name: [*:0]const u8, out_id: *c_int) c_int;
extern fn mtl_dispatch(
    func_id: c_int,
    gx: u32, gy: u32, gz: u32,
    bx: u32, by: u32, bz: u32,
    args: [*]const ?*const anyopaque,
    arg_sizes: [*]const usize,
    n_args: c_int,
) c_int;
extern fn mtl_sync() c_int;
extern fn mtl_matmul_f32(a: ?*const anyopaque, b: ?*const anyopaque, c: ?*anyopaque, m: c_int, n: c_int, k: c_int, alpha: f32, beta: f32) c_int;
extern fn mtl_matmul_f32_enc(a: ?*const anyopaque, b: ?*const anyopaque, c: ?*anyopaque, m: c_int, n: c_int, k: c_int, alpha: f32, beta: f32) c_int;
extern fn mtl_matmul_f16_enc(a: ?*const anyopaque, b: ?*const anyopaque, c: ?*anyopaque, m: c_int, n: c_int, k: c_int, alpha: f32, beta: f32) c_int;
extern fn mtl_begin_command_buffer() c_int;
extern fn mtl_commit_command_buffer() c_int;
extern fn mtl_flush() void;

pub const Error = error{
    InitFailed,
    LibraryLoadFailed,
    FunctionNotFound,
    AllocFailed,
    DispatchFailed,
    SyncFailed,
};

/// A GPU function handle. On Metal this is an index into the loaded library's
/// pipeline-state table (analogous to a CUfunction).
pub const Function = struct { id: c_int };

/// Initialize the Metal device + command queue. Call once at startup.
pub fn init() Error!void {
    if (mtl_init() != 0) return Error.InitFailed;
}

pub fn deinit() void {
    mtl_cleanup();
}

/// Load all kernels from an embedded .metallib blob (@embedFile bytes).
pub fn loadLibrary(blob: []const u8) Error!void {
    if (mtl_load_library_data(blob.ptr, @intCast(blob.len)) != 0)
        return Error.LibraryLoadFailed;
}

/// Resolve a kernel by name. Mirrors cuModuleGetFunction.
pub fn getFunction(name: [*:0]const u8) Error!Function {
    var id: c_int = -1;
    if (mtl_get_function(name, &id) != 0) return Error.FunctionNotFound;
    return .{ .id = id };
}

/// Allocate a unified-memory buffer. The returned pointer is usable from both
/// CPU (direct load/store, memcpy) and GPU (pass to dispatch as a buffer arg).
pub fn alloc(size: usize) Error![*]u8 {
    const p = mtl_alloc(size) orelse return Error.AllocFailed;
    return @ptrCast(p);
}

/// Typed allocation helper: returns a slice of `n` elements of type T.
pub fn allocSlice(comptime T: type, n: usize) Error![]T {
    const p = try alloc(n * @sizeOf(T));
    return @as([*]T, @ptrCast(@alignCast(p)))[0..n];
}

pub fn free(ptr: anytype) void {
    mtl_free(@ptrCast(@constCast(ptr)));
}

pub fn sync() Error!void {
    if (mtl_sync() != 0) return Error.SyncFailed;
}

/// Row-major F32 matmul via MPS: C[M×N] = alpha·A[M×K]·B[K×N] + beta·C.
/// Self-contained & blocking — commit/sync pending dispatches first.
pub fn matmul(
    a: anytype,
    b: anytype,
    c: anytype,
    m: u32,
    n: u32,
    k: u32,
) Error!void {
    if (mtl_matmul_f32(@ptrCast(a), @ptrCast(b), @ptrCast(c), @intCast(m), @intCast(n), @intCast(k), 1.0, 0.0) != 0)
        return Error.DispatchFailed;
}

/// Batched matmul: encodes onto the active command buffer (no commit/wait).
/// Wrap calls in beginCommandBuffer/commitCommandBuffer/sync. Order with
/// dispatches is preserved, so data dependencies are safe.
pub fn matmulBatched(
    a: anytype,
    b: anytype,
    c: anytype,
    m: u32,
    n: u32,
    k: u32,
) Error!void {
    if (mtl_matmul_f32_enc(@ptrCast(a), @ptrCast(b), @ptrCast(c), @intCast(m), @intCast(n), @intCast(k), 1.0, 0.0) != 0)
        return Error.DispatchFailed;
}

/// Batched F16 matmul (A/B/C all f16) onto the active command buffer.
pub fn matmulF16Batched(a: anytype, b: anytype, c: anytype, m: u32, n: u32, k: u32) Error!void {
    if (mtl_matmul_f16_enc(@ptrCast(a), @ptrCast(b), @ptrCast(c), @intCast(m), @intCast(n), @intCast(k), 1.0, 0.0) != 0)
        return Error.DispatchFailed;
}

pub fn beginCommandBuffer() Error!void {
    if (mtl_begin_command_buffer() != 0) return Error.DispatchFailed;
}
pub fn commitCommandBuffer() Error!void {
    if (mtl_commit_command_buffer() != 0) return Error.DispatchFailed;
}
pub fn flush() void {
    mtl_flush();
}

/// A kernel argument: either a GPU buffer (pointer-sized) or an inline scalar.
/// The bridge distinguishes them by size — pointer-sized args that match a
/// known allocation are bound as MTLBuffers, everything else is set as bytes.
pub const Arg = struct {
    ptr: ?*const anyopaque,
    size: usize,

    pub fn buf(p: anytype) Arg {
        return .{ .ptr = @ptrCast(&p), .size = @sizeOf(@TypeOf(p)) };
    }
};

/// Generic launch. `grid` = number of threadgroups (CUDA gridDim),
/// `block` = threads per threadgroup (CUDA blockDim).
/// `args` is a slice of {pointer-to-value, byte-size} pairs, in kernel
/// parameter order — exactly the cuLaunchKernel kernelParams convention.
pub fn dispatch(
    f: Function,
    grid: [3]u32,
    block: [3]u32,
    arg_ptrs: []const ?*const anyopaque,
    arg_sizes: []const usize,
) Error!void {
    std.debug.assert(arg_ptrs.len == arg_sizes.len);
    if (mtl_dispatch(
        f.id,
        grid[0], grid[1], grid[2],
        block[0], block[1], block[2],
        arg_ptrs.ptr,
        arg_sizes.ptr,
        @intCast(arg_ptrs.len),
    ) != 0) return Error.DispatchFailed;
}
