// test_diar.zig — verify the Zig ResNet34 speaker embedding against the
// onnx-exact numpy reference on a single 1.5 s segment.
const std = @import("std");
const diar = @import("diar_resnet.zig");
const alloc = std.heap.page_allocator;

pub fn main() !void {
    const out = std.io.getStdOut().writer();
    var m = try diar.Model.load(alloc, "/tmp/resnet34_weights.bin", "/tmp/kaldi_melbank.f32");
    const sig_bytes = try std.fs.cwd().readFileAllocOptions(alloc, "/tmp/seg.f32", 1 << 24, null, @alignOf(f32), null);
    const sig = std.mem.bytesAsSlice(f32, sig_bytes);
    var t = try std.time.Timer.start();
    const e = try diar.embed(&m, sig);
    const ms = @as(f64, @floatFromInt(t.read())) / 1e6;
    try out.print("embed[:6] = {d:.5} {d:.5} {d:.5} {d:.5} {d:.5} {d:.5}\n", .{ e[0], e[1], e[2], e[3], e[4], e[5] });
    try out.print("({d:.1} ms / 1.5s segment)\n", .{ms});
    var f = try std.fs.cwd().createFile("/tmp/zig_emb.f32", .{});
    defer f.close();
    try f.writeAll(std.mem.sliceAsBytes(e[0..]));
}
