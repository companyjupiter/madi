// test_conv1d.zig — numerical correctness check for conv1d.metal.
// Runs a small conv1d_gelu on the GPU and compares against an independent
// CPU implementation of the same math. Proves the PTX→Metal port is correct
// (no model weights needed — uses synthetic inputs).
const std = @import("std");
const mtl = @import("metal_backend.zig");

const METALLIB = @embedFile("whisper.metallib");

fn geluTanh(x: f32) f32 {
    const k0: f32 = 0.7978845608028654;
    const k1: f32 = 0.044715;
    const inner = k0 * (x + k1 * x * x * x);
    return 0.5 * x * (1.0 + std.math.tanh(inner));
}

pub fn main() !void {
    const out = std.io.getStdOut().writer();
    try mtl.init();
    defer mtl.deinit();
    try mtl.loadLibrary(METALLIB);
    const f_conv = try mtl.getFunction("conv1d_gelu");

    // Small but representative dims (same shape family as Whisper conv1).
    const C_in: u32 = 8;
    const C_out: u32 = 12;
    const L_in: u32 = 50;
    const K: u32 = 3;
    const stride: u32 = 1;
    const padding: u32 = 1;
    const L_out: u32 = (L_in + 2 * padding - K) / stride + 1; // = L_in here

    const in_buf = try mtl.allocSlice(f32, C_in * L_in);
    const w_buf = try mtl.allocSlice(f32, K * C_in * C_out);
    const b_buf = try mtl.allocSlice(f32, C_out);
    const o_buf = try mtl.allocSlice(f32, C_out * L_out);
    defer mtl.free(in_buf.ptr);
    defer mtl.free(w_buf.ptr);
    defer mtl.free(b_buf.ptr);
    defer mtl.free(o_buf.ptr);

    var rng = std.Random.DefaultPrng.init(42);
    const rnd = rng.random();
    for (in_buf) |*v| v.* = rnd.float(f32) * 2.0 - 1.0;
    for (w_buf) |*v| v.* = rnd.float(f32) * 0.5 - 0.25;
    for (b_buf) |*v| v.* = rnd.float(f32) * 0.1;
    @memset(o_buf, -999.0);

    // GPU launch: Grid = (L_out,1,1), Block = (256,1,1)
    var a0 = o_buf.ptr;
    var a1 = in_buf.ptr;
    var a2 = w_buf.ptr;
    var a3 = b_buf.ptr;
    var p_cin = C_in;
    var p_cout = C_out;
    var p_lin = L_in;
    var p_k = K;
    var p_s = stride;
    var p_p = padding;
    const ptrs = [_]?*const anyopaque{
        @ptrCast(&a0), @ptrCast(&a1), @ptrCast(&a2), @ptrCast(&a3),
        @ptrCast(&p_cin), @ptrCast(&p_cout), @ptrCast(&p_lin),
        @ptrCast(&p_k), @ptrCast(&p_s), @ptrCast(&p_p),
    };
    const sizes = [_]usize{
        @sizeOf(usize), @sizeOf(usize), @sizeOf(usize), @sizeOf(usize),
        @sizeOf(u32), @sizeOf(u32), @sizeOf(u32), @sizeOf(u32), @sizeOf(u32), @sizeOf(u32),
    };
    try mtl.beginCommandBuffer();
    try mtl.dispatch(f_conv, .{ L_out, 1, 1 }, .{ 256, 1, 1 }, &ptrs, &sizes);
    try mtl.commitCommandBuffer();
    try mtl.sync();

    // CPU reference.
    var max_err: f32 = 0;
    for (0..C_out) |co| {
        for (0..L_out) |t| {
            var sum = b_buf[co];
            for (0..C_in) |ci| {
                for (0..K) |k| {
                    const ti_s: i64 = @as(i64, @intCast(t * stride + k)) - @as(i64, @intCast(padding));
                    if (ti_s < 0 or ti_s >= L_in) continue;
                    const ti: usize = @intCast(ti_s);
                    const val = in_buf[ci * L_in + ti];
                    const wf = w_buf[((k * C_in) + ci) * C_out + co];
                    sum += val * wf;
                }
            }
            const ref = geluTanh(sum);
            const got = o_buf[co * L_out + t];
            const err = @abs(ref - got);
            if (err > max_err) max_err = err;
        }
    }
    try out.print("conv1d_gelu: dims C_in={d} C_out={d} L={d}->{d}, max_abs_err = {e}\n", .{ C_in, C_out, L_in, L_out, max_err });
    if (max_err < 1e-5) {
        try out.print("✅ CONV1D OK — GPU matches CPU reference\n", .{});
    } else {
        try out.print("❌ CONV1D FAIL — error too large\n", .{});
        return error.ConvMismatch;
    }
}
