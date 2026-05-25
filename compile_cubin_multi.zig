// compile_cubin_multi.zig — 여러 SM 타겟으로 cubin 컴파일
const std = @import("std");
const CUresult = i32;

const externs = struct {
    extern "kernel32" fn LoadLibraryA([*:0]const u8) callconv(.C) ?*anyopaque;
    extern "kernel32" fn GetProcAddress(?*anyopaque, [*:0]const u8) callconv(.C) ?*anyopaque;
};

pub fn main() !void {
    const alloc = std.heap.page_allocator;
    const out = std.io.getStdOut().writer();
    const nv = externs.LoadLibraryA("nvcuda.dll") orelse return;

    const L = struct { fn f(comptime T: type, h: ?*anyopaque, n: [*:0]const u8) T { return @as(T, @ptrCast(externs.GetProcAddress(h, n).?)); } }.f;
    const cuInit = L(*const fn(u32)callconv(.C)CUresult, nv, "cuInit");
    const cuDeviceGet = L(*const fn(*i32, i32)callconv(.C)CUresult, nv, "cuDeviceGet");
    const cuCtxCreate = L(*const fn(*?*anyopaque, u32, i32)callconv(.C)CUresult, nv, "cuCtxCreate_v2");
    const cuLinkCreate = L(*const fn(u32, ?[*]const i32, ?[*]?*anyopaque, *?*anyopaque)callconv(.C)CUresult, nv, "cuLinkCreate_v2");
    const cuLinkAddData = L(*const fn(?*anyopaque, i32, [*]const u8, usize, [*:0]const u8, u32, ?*anyopaque, ?*anyopaque)callconv(.C)CUresult, nv, "cuLinkAddData_v2");
    const cuLinkComplete = L(*const fn(?*anyopaque, *?[*]u8, *usize)callconv(.C)CUresult, nv, "cuLinkComplete");
    const cuLinkDestroy = L(*const fn(?*anyopaque)callconv(.C)CUresult, nv, "cuLinkDestroy");

    _ = cuInit(0);
    var dev: i32 = 0; _ = cuDeviceGet(&dev, 0);
    var ctx: ?*anyopaque = null; _ = cuCtxCreate(&ctx, 0, dev);

    const CU_JIT_TARGET = 0;
    const CU_JIT_INPUT_PTX = 1;
    
    const targets = [_]struct { sm: i32, name: []const u8 }{
        .{ .sm = 86, .name = "sm86" },  // RTX 3060/3070/3080/3090
        .{ .sm = 89, .name = "sm89" },  // RTX 4060/4070/4080/4090
    };

    const ptx_files = [_][]const u8{
        "kernels/bias_res_ln.ptx",
        "kernels/conv1d.ptx",
        "kernels/decoder_ops.ptx",
        "kernels/f16_convert.ptx",
        "kernels/f32_gemv_fast.ptx",
        "kernels/f32_gemv_fixed.ptx",
        "kernels/flash_attention_enc.ptx",
        "kernels/flash_cross_attn.ptx",
        "kernels/gpu_ops_root_backup.ptx",
        "kernels/graph_helpers.ptx",
        "kernels/layer_norm.ptx",
        "kernels/mfa_align.ptx",
        "kernels/tensor_core.ptx",
        "kernels/whisper_kernels.ptx",
        "kernels/whisper_ops.ptx",
    };

    for (targets) |tgt| {
        // Create output directory
        var dir_buf: [64]u8 = undefined;
        const dir_path = std.fmt.bufPrint(&dir_buf, "kernels/{s}", .{tgt.name}) catch continue;
        std.fs.cwd().makePath(dir_path) catch {};
        
        var ok: u32 = 0;
        for (ptx_files) |ptx_path| {
            const f = std.fs.cwd().openFile(ptx_path, .{}) catch continue;
            defer f.close();
            const ptx = f.readToEndAllocOptions(alloc, 4*1024*1024, null, 1, 0) catch continue;
            defer alloc.free(ptx);

            // Create linker with target SM
            var opts = [_]i32{CU_JIT_TARGET};
            var vals = [_]?*anyopaque{@ptrFromInt(@as(usize, @intCast(tgt.sm)))};
            var linker: ?*anyopaque = null;
            var r = cuLinkCreate(1, &opts, &vals, &linker);
            if (r != 0) { try out.print("FAIL create {s} sm{d}: {d}\n", .{ptx_path, tgt.sm, r}); continue; }

            r = cuLinkAddData(linker, CU_JIT_INPUT_PTX, @ptrCast(ptx.ptr), ptx.len, "k.ptx", 0, null, null);
            if (r != 0) { try out.print("FAIL add {s} sm{d}: {d}\n", .{ptx_path, tgt.sm, r}); _ = cuLinkDestroy(linker); continue; }

            var cubin_ptr: ?[*]u8 = null; var cubin_size: usize = 0;
            r = cuLinkComplete(linker, &cubin_ptr, &cubin_size);
            if (r != 0) { try out.print("FAIL link {s} sm{d}: {d}\n", .{ptx_path, tgt.sm, r}); _ = cuLinkDestroy(linker); continue; }

            // Output: kernels/sm86/bias_res_ln.bin
            const basename_start = if (std.mem.lastIndexOf(u8, ptx_path, "/")) |i| i + 1 else 0;
            const basename = ptx_path[basename_start..ptx_path.len - 4]; // remove .ptx
            var out_buf: [128]u8 = undefined;
            const out_path = std.fmt.bufPrint(&out_buf, "kernels/{s}/{s}.bin", .{tgt.name, basename}) catch continue;

            const wf = std.fs.cwd().createFile(out_path, .{}) catch continue;
            defer wf.close();
            wf.writeAll(cubin_ptr.?[0..cubin_size]) catch continue;

            ok += 1;
            _ = cuLinkDestroy(linker);
        }
        try out.print("=== {s}: {d}/{d} kernels ===\n", .{tgt.name, ok, ptx_files.len});
    }
}
