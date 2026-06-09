// diar_embed_wav.zig — run the Zig ResNet34 speaker embedder over a whole wav
// (1.5s segments, RMS VAD), dump [t0, emb256] per segment. Used to verify the
// Zig port end-to-end on AMI (python clusters + DER) before integration.
const std = @import("std");
const mel = @import("mel.zig");
const diar = @import("diar_resnet.zig");
const alloc = std.heap.page_allocator;

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    const wav_path = args.next().?;
    const weights = args.next() orelse "/tmp/resnet34_weights.bin";
    const melbank = args.next() orelse "/tmp/kaldi_melbank.f32";
    const out_path = args.next() orelse "/tmp/zig_wav_emb.bin";
    const out = std.io.getStdOut().writer();

    var m = try diar.Model.load(alloc, weights, melbank);
    const wav = try std.fs.cwd().readFileAlloc(alloc, wav_path, 2 << 30);
    const total = mel.wavTotalSamples(wav);
    const samples = try alloc.alloc(f32, total + mel.CHUNK_SAMPLES);
    @memset(samples, 0);
    var off: usize = 0;
    while (off < total) : (off += mel.CHUNK_SAMPLES) {
        const got = mel.loadWavChunk(wav, off, samples[off..][0..mel.CHUNK_SAMPLES]);
        if (got == 0) break;
    }

    const SEG: usize = 24000; // 1.5 s
    const nseg = total / SEG;
    // RMS VAD: keep > 0.3 * median segment RMS
    const rms = try alloc.alloc(f32, nseg);
    for (0..nseg) |s| {
        var e: f64 = 0;
        for (samples[s * SEG ..][0..SEG]) |v| e += @as(f64, v) * v;
        rms[s] = @floatCast(@sqrt(e / SEG));
    }
    const rs = try alloc.dupe(f32, rms);
    std.mem.sort(f32, rs, {}, std.sort.asc(f32));
    const thr = rs[nseg / 2] * 0.3;

    var buf = std.ArrayList(u8).init(alloc);
    var n: u32 = 0;
    var t = try std.time.Timer.start();
    for (0..nseg) |s| {
        if (rms[s] < thr) continue;
        const e = try diar.embed(&m, samples[s * SEG ..][0..SEG]);
        const t0: f32 = @floatFromInt(s);
        try buf.appendSlice(std.mem.asBytes(&@as(f32, t0 * 1.5)));
        try buf.appendSlice(std.mem.sliceAsBytes(e[0..]));
        n += 1;
    }
    const ms = @as(f64, @floatFromInt(t.read())) / 1e6;
    var f = try std.fs.cwd().createFile(out_path, .{});
    defer f.close();
    try f.writeAll(std.mem.asBytes(&n));
    try f.writeAll(buf.items);
    try out.print("{d} segments embedded in {d:.0}ms ({d:.0}ms/seg) → {s}\n", .{ n, ms, ms / @as(f64, @floatFromInt(n)), out_path });
    try diar.dumpProf(out);
}
