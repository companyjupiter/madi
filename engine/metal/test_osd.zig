// test_osd.zig — pyannote segmentation port validation vs onnxruntime.
// Usage: test_osd [ref.bin] [model.bin]
// ref.bin (from convert_pyannote_seg.py): u32 F, u32 C, f32 x[160000],
// f32 y[F*C] — compares our forward against the onnxruntime log-probs.
const std = @import("std");
const osd = @import("osd_pyannote.zig");
const alloc = std.heap.page_allocator;

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    const ref_path = args.next() orelse "/tmp/posd_ref.bin";
    const model_path = args.next() orelse "/tmp/posd.bin";
    const out = std.io.getStdOut().writer();

    const m = try osd.Model.load(alloc, model_path);
    const b = try std.fs.cwd().readFileAlloc(alloc, ref_path, 32 * 1024 * 1024);
    const F = std.mem.readInt(u32, b[0..4], .little);
    const C = std.mem.readInt(u32, b[4..8], .little);
    const x = @as([*]const f32, @ptrCast(@alignCast(b[8..].ptr)))[0..osd.WIN_SAMPLES];
    const ref = @as([*]const f32, @ptrCast(@alignCast(b[8 + 4 * osd.WIN_SAMPLES ..].ptr)))[0 .. F * C];

    const logp = try alloc.alloc(f32, (F + 8) * osd.N_CLASSES);
    var t = try std.time.Timer.start();
    const got_f = try m.forward(alloc, x, logp);
    const ms = @as(f64, @floatFromInt(t.read())) / 1e6;
    try out.print("frames: ours={d} ref={d}  ({d:.0}ms / 10s window)\n", .{ got_f, F, ms });

    var max_err: f32 = 0;
    var arg_mismatch: usize = 0;
    for (0..@min(got_f, F)) |fi| {
        var ra: usize = 0;
        var oa: usize = 0;
        for (0..7) |c| {
            const e = @abs(logp[fi * 7 + c] - ref[fi * 7 + c]);
            max_err = @max(max_err, e);
            if (ref[fi * 7 + c] > ref[fi * 7 + ra]) ra = c;
            if (logp[fi * 7 + c] > logp[fi * 7 + oa]) oa = c;
        }
        if (ra != oa) arg_mismatch += 1;
    }
    try out.print("max |Δlogp| = {e:.3}, argmax mismatches = {d}/{d}\n", .{ max_err, arg_mismatch, F });
    if (max_err < 1e-3 and arg_mismatch == 0) {
        try out.print("✅ OSD PORT OK — matches onnxruntime\n", .{});
    } else {
        try out.print("❌ MISMATCH\n", .{});
        for (0..3) |fi| {
            try out.print("f{d} ours: ", .{fi});
            for (0..7) |c| try out.print("{d:.3} ", .{logp[fi * 7 + c]});
            try out.print("\n f{d} ref: ", .{fi});
            for (0..7) |c| try out.print("{d:.3} ", .{ref[fi * 7 + c]});
            try out.print("\n", .{});
        }
    }
}
