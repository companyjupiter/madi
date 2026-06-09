// online_diar.zig — stateful online speaker clustering for live transcription.
//
// The file-based `transcribe` re-clusters each segment independently, so its
// "Speaker 0/1/…" labels are NOT consistent across segments. This tool keeps a
// persistent centroid set on disk so the SAME physical speaker keeps the SAME
// id across an entire live session (online / leader-follower clustering).
//
// Pipeline (per live segment):
//   diar_embed_wav seg_i.wav … emb_i.bin          # 256-d emb per 1.5s window
//   online_diar state.bin emb_i.bin <t_off> …     # assign global speaker ids
//
// emb_i.bin layout (from diar_embed_wav):
//   u32 n; then n × { f32 t0_local; f32 emb[256] }
//
// state.bin layout (this tool owns it):
//   u32 magic=0x4f44_4941 ("OD" ia); u32 k;
//   then k × { u32 count; f32 sum[256] }          # sum of L2-normalized embs
// centroid = normalize(sum); a new speaker is created when the best cosine
// similarity to every existing centroid is below the threshold (until max_k).
//
// Args:
//   online_diar <state.bin> <emb.bin> <t_off_sec> [sim_thr=0.50] [max_k=8]
// Stdout: one line per accepted window:  "<global_t_sec> <speaker_id>"
const std = @import("std");
const alloc = std.heap.page_allocator;

const D = 256;
const MAGIC: u32 = 0x4f444941;

const Centroid = struct { count: u32, sum: [D]f32 };

fn l2normalize(v: []f32) void {
    var s: f64 = 0;
    for (v) |x| s += @as(f64, x) * x;
    const n: f32 = @floatCast(@sqrt(s) + 1e-9);
    for (v) |*x| x.* /= n;
}

fn cosineToCentroid(v: []const f32, c: *const Centroid) f32 {
    // centroid direction = normalize(sum); v is already unit-length.
    var dot: f64 = 0;
    var cs: f64 = 0;
    for (0..D) |i| {
        dot += @as(f64, v[i]) * c.sum[i];
        cs += @as(f64, c.sum[i]) * c.sum[i];
    }
    const cn = @sqrt(cs) + 1e-9;
    return @floatCast(dot / cn);
}

pub fn main() !void {
    var args = std.process.args();
    _ = args.next();
    const state_path = args.next() orelse return error.MissingState;
    const emb_path = args.next() orelse return error.MissingEmb;
    const t_off: f32 = std.fmt.parseFloat(f32, args.next() orelse "0") catch 0;
    const sim_thr: f32 = std.fmt.parseFloat(f32, args.next() orelse "0.50") catch 0.50;
    const max_k: u32 = std.fmt.parseInt(u32, args.next() orelse "8", 10) catch 8;
    const out = std.io.getStdOut().writer();

    // ── load (or init) persistent centroids ─────────────────────────────────
    var cents = std.ArrayList(Centroid).init(alloc);
    if (std.fs.cwd().readFileAlloc(alloc, state_path, 1 << 28)) |sd| {
        if (sd.len >= 8 and std.mem.readInt(u32, sd[0..4], .little) == MAGIC) {
            const k = std.mem.readInt(u32, sd[4..8], .little);
            var p: usize = 8;
            for (0..k) |_| {
                if (p + 4 + D * 4 > sd.len) break;
                var c: Centroid = undefined;
                c.count = std.mem.readInt(u32, sd[p..][0..4], .little);
                p += 4;
                for (0..D) |i| {
                    c.sum[i] = @bitCast(std.mem.readInt(u32, sd[p..][0..4], .little));
                    p += 4;
                }
                try cents.append(c);
            }
        }
    } else |_| {}

    // ── read this segment's embeddings ──────────────────────────────────────
    const ed = try std.fs.cwd().readFileAlloc(alloc, emb_path, 1 << 28);
    if (ed.len < 4) return;
    const n = std.mem.readInt(u32, ed[0..4], .little);
    var p: usize = 4;
    const rec = 4 + D * 4;

    for (0..n) |_| {
        if (p + rec > ed.len) break;
        const t0: f32 = @bitCast(std.mem.readInt(u32, ed[p..][0..4], .little));
        var v: [D]f32 = undefined;
        for (0..D) |i| v[i] = @bitCast(std.mem.readInt(u32, ed[p + 4 + i * 4 ..][0..4], .little));
        p += rec;
        l2normalize(v[0..]);

        // nearest existing centroid by cosine
        var best: f32 = -2;
        var best_i: usize = 0;
        for (cents.items, 0..) |*c, i| {
            const sim = cosineToCentroid(v[0..], c);
            if (sim > best) {
                best = sim;
                best_i = i;
            }
        }

        var spk: usize = undefined;
        if (cents.items.len == 0 or (best < sim_thr and cents.items.len < max_k)) {
            // birth a new speaker
            spk = cents.items.len;
            var c: Centroid = .{ .count = 0, .sum = [_]f32{0} ** D };
            for (0..D) |i| c.sum[i] = v[i];
            c.count = 1;
            try cents.append(c);
        } else {
            spk = best_i;
            var c = &cents.items[spk];
            for (0..D) |i| c.sum[i] += v[i];
            c.count += 1;
        }
        try out.print("{d:.2} {d}\n", .{ t_off + t0, spk });
    }

    // ── persist updated centroids ───────────────────────────────────────────
    var tmp = std.ArrayList(u8).init(alloc);
    try tmp.appendSlice(std.mem.asBytes(&MAGIC));
    const k: u32 = @intCast(cents.items.len);
    try tmp.appendSlice(std.mem.asBytes(&k));
    for (cents.items) |*c| {
        try tmp.appendSlice(std.mem.asBytes(&c.count));
        try tmp.appendSlice(std.mem.sliceAsBytes(c.sum[0..]));
    }
    var f = try std.fs.cwd().createFile(state_path, .{});
    defer f.close();
    try f.writeAll(tmp.items);
}
