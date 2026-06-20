// smoke.zig — end-to-end toolchain proof for the Metal backend.
// Allocates two unified-memory buffers, fills them on the CPU, runs the
// `vadd` GPU kernel, and verifies the result on the CPU. If this prints
// "SMOKE OK" the entire Zig→ObjC→Metal→.metallib path is wired correctly.
const std = @import("std");
const mtl = @import("metal_backend.zig");

const METALLIB = @embedFile("smoke.metallib");

pub fn main() !void {
    const out = std.io.getStdOut().writer();
    try mtl.init();
    defer mtl.deinit();
    try mtl.loadLibrary(METALLIB);
    const f_vadd = try mtl.getFunction("vadd");
    try out.print("[1] Metal init + library + vadd handle OK\n", .{});

    const N: u32 = 1_000_003; // non-round to exercise the bounds check
    const a = try mtl.allocSlice(f32, N);
    const b = try mtl.allocSlice(f32, N);
    const c = try mtl.allocSlice(f32, N);
    defer mtl.free(a.ptr);
    defer mtl.free(b.ptr);
    defer mtl.free(c.ptr);

    // Unified memory: write straight into the GPU buffers from the CPU.
    for (0..N) |i| {
        a[i] = @floatFromInt(i % 1000);
        b[i] = @as(f32, @floatFromInt(i % 1000)) * 2.0;
        c[i] = -1.0;
    }

    // Launch: 1D grid of ceil(N/256) threadgroups × 256 threads.
    var a0 = a.ptr;
    var a1 = b.ptr;
    var a2 = c.ptr;
    var a3 = N;
    const arg_ptrs = [_]?*const anyopaque{ @ptrCast(&a2), @ptrCast(&a0), @ptrCast(&a1), @ptrCast(&a3) };
    const arg_sizes = [_]usize{ @sizeOf(@TypeOf(a2)), @sizeOf(@TypeOf(a0)), @sizeOf(@TypeOf(a1)), @sizeOf(u32) };
    const TPB: u32 = 256;
    const grid: u32 = (N + TPB - 1) / TPB;

    try mtl.beginCommandBuffer();
    try mtl.dispatch(f_vadd, .{ grid, 1, 1 }, .{ TPB, 1, 1 }, &arg_ptrs, &arg_sizes);
    try mtl.commitCommandBuffer();
    try mtl.sync();
    try out.print("[2] dispatched vadd over {d} elems ({d} groups × {d})\n", .{ N, grid, TPB });

    // Verify on CPU.
    var bad: usize = 0;
    for (0..N) |i| {
        const want = a[i] + b[i];
        if (c[i] != want) {
            if (bad < 5) try out.print("  mismatch @ {d}: got {d} want {d}\n", .{ i, c[i], want });
            bad += 1;
        }
    }
    if (bad == 0) {
        try out.print("[3] verified all {d} elements\n\n✅ SMOKE OK — Metal toolchain working on this machine\n", .{N});
    } else {
        try out.print("\n❌ SMOKE FAIL — {d} mismatches\n", .{bad});
        return error.SmokeFailed;
    }
}
