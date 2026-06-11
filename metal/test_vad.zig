// test_vad.zig — Silero-VAD port validation harness.
// Usage: test_vad <wav> [model.bin]
// Prints speech segments in whisper-vad-speech-segments format (centiseconds)
// for direct diff against the whisper.cpp reference CLI.
const std = @import("std");
const mel = @import("mel.zig");
const vad = @import("vad_silero.zig");
const alloc = std.heap.page_allocator;

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    const wav_path = args.next().?;
    const model_path = args.next() orelse "/tmp/silero.bin";
    const out = std.io.getStdOut().writer();

    var m = try vad.Model.load(alloc, model_path);
    const wav = try std.fs.cwd().readFileAlloc(alloc, wav_path, 2 << 30);
    const total = mel.wavTotalSamples(wav);
    const samples = try alloc.alloc(f32, total + mel.CHUNK_SAMPLES);
    @memset(samples, 0);
    var off: usize = 0;
    while (off < total) : (off += mel.CHUNK_SAMPLES) {
        if (mel.loadWavChunk(wav, off, samples[off..][0..mel.CHUNK_SAMPLES]) == 0) break;
    }

    const probs = try alloc.alloc(f32, total / vad.N_WINDOW + 2);
    var t = try std.time.Timer.start();
    const np = m.detect(samples[0..total], probs);
    const ms = @as(f64, @floatFromInt(t.read())) / 1e6;
    const segs = try vad.segmentsFromProbs(alloc, probs[0..np]);
    try out.print("\nDetected {d} speech segments ({d} frames in {d:.0}ms):\n", .{ segs.items.len, np, ms });
    for (segs.items, 0..) |s, i| {
        try out.print("Speech segment {d}: start = {d:.2}, end = {d:.2}\n", .{ i, s.start * 100.0, s.end * 100.0 });
    }
}
