// diar_resnet.zig — sovereign CPU inference of wespeaker ResNet34 speaker
// embedding for diarization. Reimplemented from the onnx weights (no runtime
// dependency); verified bit-for-bit against onnxruntime via bench/*_ref.py.
//   pipeline: 16k mono → kaldi 80-fbank → ResNet34 (BN folded) → stats pool
//             → FC 5120→256 → −mean_vec → (L2-norm at clustering)
const std = @import("std");

pub const NMEL: usize = 80;
const SR: usize = 16000;
const FLEN: usize = 400; // 25 ms
const FSHIFT: usize = 160; // 10 ms
const FFT: usize = 512;
const NBINS: usize = FFT / 2 + 1; // 257
const PREEMPH: f32 = 0.97;
pub const EMB: usize = 256;

// ── weights (loaded from resnet34_weights.bin; layout per bench/resnet34_ref.py)
const Conv = struct { o: usize, c: usize, kh: usize, kw: usize, stride: usize, w: []f32, b: []f32 };
pub const Model = struct {
    convs: []Conv,
    gemm_w: []f32, // [256][5120]
    gemm_b: []f32, // [256]
    mean_vec: []f32, // [256]
    melbank: []f32, // [80][257]
    win: [FLEN]f32, // povey window
    alloc: std.mem.Allocator,

    pub fn load(alloc: std.mem.Allocator, weights_path: []const u8, melbank_path: []const u8) !Model {
        const wb = try std.fs.cwd().readFileAllocOptions(alloc, weights_path, 1 << 30, null, @alignOf(f32), null);
        var off: usize = 0;
        const rdU = struct {
            fn f(b: []const u8, o: *usize) u32 { const v = std.mem.readInt(u32, b[o.*..][0..4], .little); o.* += 4; return v; }
        }.f;
        const nconv = rdU(wb, &off);
        const convs = try alloc.alloc(Conv, nconv);
        for (convs) |*cv| {
            const o = rdU(wb, &off); const c = rdU(wb, &off); const kh = rdU(wb, &off); const kw = rdU(wb, &off); const st = rdU(wb, &off);
            const nw = @as(usize, o) * c * kh * kw;
            cv.* = .{ .o = o, .c = c, .kh = kh, .kw = kw, .stride = st,
                .w = @alignCast(std.mem.bytesAsSlice(f32, wb[off .. off + nw * 4])), .b = undefined };
            off += nw * 4;
            cv.b = @alignCast(std.mem.bytesAsSlice(f32, wb[off .. off + o * 4]));
            off += o * 4;
        }
        const gr = rdU(wb, &off); const gc = rdU(wb, &off); // 256, 5120
        const gemm_w = @as([]f32, @alignCast(std.mem.bytesAsSlice(f32, wb[off .. off + @as(usize, gr) * gc * 4]))); off += @as(usize, gr) * gc * 4;
        const gemm_b = @as([]f32, @alignCast(std.mem.bytesAsSlice(f32, wb[off .. off + @as(usize, gr) * 4]))); off += @as(usize, gr) * 4;
        const mean_vec = @as([]f32, @alignCast(std.mem.bytesAsSlice(f32, wb[off .. off + @as(usize, gr) * 4])));
        const mb = try std.fs.cwd().readFileAllocOptions(alloc, melbank_path, 1 << 24, null, @alignOf(f32), null);
        var m = Model{ .convs = convs, .gemm_w = gemm_w, .gemm_b = gemm_b, .mean_vec = mean_vec,
            .melbank = @alignCast(std.mem.bytesAsSlice(f32, mb)), .win = undefined, .alloc = alloc };
        for (0..FLEN) |n| {
            const h = 0.5 - 0.5 * @cos(2.0 * std.math.pi * @as(f64, @floatFromInt(n)) / @as(f64, @floatFromInt(FLEN - 1)));
            m.win[n] = @floatCast(std.math.pow(f64, h, 0.85));
        }
        return m;
    }
};

// ── radix-2 iterative FFT (in-place, complex), size 512 ──────────────────
fn fft512(re: *[FFT]f32, im: *[FFT]f32) void {
    // bit reversal
    var j: usize = 0;
    for (1..FFT) |i| {
        var bit: usize = FFT >> 1;
        while (j & bit != 0) : (bit >>= 1) j ^= bit;
        j ^= bit;
        if (i < j) { std.mem.swap(f32, &re[i], &re[j]); std.mem.swap(f32, &im[i], &im[j]); }
    }
    var len: usize = 2;
    while (len <= FFT) : (len <<= 1) {
        const ang = -2.0 * std.math.pi / @as(f32, @floatFromInt(len));
        const wr = @cos(ang); const wi = @sin(ang);
        var i: usize = 0;
        while (i < FFT) : (i += len) {
            var cwr: f32 = 1; var cwi: f32 = 0;
            for (0..len / 2) |k| {
                const a = i + k; const b = a + len / 2;
                const tr = cwr * re[b] - cwi * im[b];
                const ti = cwr * im[b] + cwi * re[b];
                re[b] = re[a] - tr; im[b] = im[a] - ti;
                re[a] += tr; im[a] += ti;
                const ncwr = cwr * wr - cwi * wi;
                cwi = cwr * wi + cwi * wr; cwr = ncwr;
            }
        }
    }
}

/// kaldi 80-fbank of a 16k mono segment → out [nfr][NMEL] (caller frees).
pub fn fbank(m: *const Model, sig: []const f32, out_nfr: *usize) ![]f32 {
    const n = sig.len;
    const nfr = (n + FSHIFT / 2) / FSHIFT;
    out_nfr.* = nfr;
    const out = try m.alloc.alloc(f32, nfr * NMEL);
    var re: [FFT]f32 = undefined; var im: [FFT]f32 = undefined;
    var fr: [FLEN]f32 = undefined;
    for (0..nfr) |mi| {
        const start = @as(isize, @intCast(mi * FSHIFT)) - @as(isize, @intCast((FLEN - FSHIFT) / 2));
        var mean: f32 = 0;
        for (0..FLEN) |k| {
            var idx = start + @as(isize, @intCast(k));
            while (idx < 0 or idx >= @as(isize, @intCast(n))) {
                if (idx < 0) idx = -idx - 1 else idx = 2 * @as(isize, @intCast(n)) - 1 - idx;
            }
            fr[k] = sig[@intCast(idx)];
            mean += fr[k];
        }
        mean /= @floatFromInt(FLEN);
        for (0..FLEN) |k| fr[k] -= mean; // remove DC
        // preemphasis (in place, high→low so x[k-1] is pre-emph source)
        var k: usize = FLEN - 1;
        while (k >= 1) : (k -= 1) fr[k] = fr[k] - PREEMPH * fr[k - 1];
        fr[0] = fr[0] - PREEMPH * fr[0];
        for (0..FLEN) |t| { re[t] = fr[t] * m.win[t]; im[t] = 0; }
        for (FLEN..FFT) |t| { re[t] = 0; im[t] = 0; }
        fft512(&re, &im);
        const row = out[mi * NMEL ..][0..NMEL];
        for (0..NMEL) |b| {
            var s: f32 = 0;
            const fb = m.melbank[b * NBINS ..][0..NBINS];
            for (0..NBINS) |bin| {
                const p = re[bin] * re[bin] + im[bin] * im[bin];
                s += fb[bin] * p;
            }
            row[b] = @log(@max(s, 1.1920929e-7));
        }
    }
    return out;
}

// Accelerate (Apple system BLAS) — used like MPS: a vendor *system* framework,
// no third-party runtime. Drives the conv GEMMs (im2col + sgemm).
const CblasRowMajor: c_int = 101;
const CblasNoTrans: c_int = 111;
extern "c" fn cblas_sgemm(order: c_int, ta: c_int, tb: c_int, m: c_int, n: c_int, k: c_int, alpha: f32, a: [*]const f32, lda: c_int, b: [*]const f32, ldb: c_int, beta: f32, c: [*]f32, ldc: c_int) void;

// ── conv2d via im2col + sgemm (in [C][H][W] flat, single batch) ──────────
fn conv2d(a: std.mem.Allocator, in: []const f32, c: usize, h: usize, w: usize, cv: Conv, ho: *usize, wo: *usize) ![]f32 {
    const pad: usize = if (cv.kw == 3) 1 else 0;
    const Ho = (h + 2 * pad - cv.kh) / cv.stride + 1;
    const Wo = (w + 2 * pad - cv.kw) / cv.stride + 1;
    ho.* = Ho; wo.* = Wo;
    const M = cv.o; const N = Ho * Wo; const K = c * cv.kh * cv.kw;
    var im_t = std.time.Timer.start() catch unreachable;
    // im2col → cols[K][N]. cols is a transient; allocate from the page allocator
    // and free it after the sgemm (NOT the per-embed arena, which never frees —
    // accumulating 36 convs' cols × N threads was a ~1.3GB RSS leak).
    const pa = std.heap.page_allocator;
    const cols = try pa.alloc(f32, K * N);
    defer pa.free(cols);
    @memset(cols, 0); // padding stays 0; valid spans overwritten below
    const wI: isize = @intCast(w);
    const WoI: isize = @intCast(Wo);
    for (0..c) |ic| {
        const inb = ic * h * w;
        for (0..cv.kh) |ky| {
            for (0..cv.kw) |kx| {
                const r = (ic * cv.kh + ky) * cv.kw + kx;
                const rb = r * N;
                for (0..Ho) |oy| {
                    const iy = @as(isize, @intCast(oy * cv.stride + ky)) - @as(isize, @intCast(pad));
                    if (iy < 0 or iy >= @as(isize, @intCast(h))) continue;
                    const iry = inb + @as(usize, @intCast(iy)) * w;
                    const dst = cols[rb + oy * Wo ..][0..Wo];
                    if (cv.stride == 1) {
                        // ix = ox + (kx-pad); copy the contiguous valid ox range
                        const shift = @as(isize, @intCast(kx)) - @as(isize, @intCast(pad));
                        const lo: usize = if (shift < 0) @intCast(-shift) else 0;
                        var hiI: isize = wI - shift;
                        if (hiI > WoI) hiI = WoI;
                        if (hiI > @as(isize, @intCast(lo))) {
                            const hi: usize = @intCast(hiI);
                            @memcpy(dst[lo..hi], in[iry + @as(usize, @intCast(@as(isize, @intCast(lo)) + shift)) ..][0 .. hi - lo]);
                        }
                    } else {
                        for (0..Wo) |ox| {
                            const ix = @as(isize, @intCast(ox * cv.stride + kx)) - @as(isize, @intCast(pad));
                            if (ix >= 0 and ix < wI) dst[ox] = in[iry + @as(usize, @intCast(ix))];
                        }
                    }
                }
            }
        }
    }
    conv_im2col_ns += im_t.read();
    const out = try a.alloc(f32, M * N);
    var gt = std.time.Timer.start() catch unreachable;
    // out[M][N] = W[M][K] @ cols[K][N]
    cblas_sgemm(CblasRowMajor, CblasNoTrans, CblasNoTrans, @intCast(M), @intCast(N), @intCast(K), 1.0, cv.w.ptr, @intCast(K), cols.ptr, @intCast(N), 0.0, out.ptr, @intCast(N));
    conv_sgemm_ns += gt.read();
    // + bias (broadcast per output channel)
    for (0..M) |oc| { const bv = cv.b[oc]; const ob = oc * N; for (0..N) |i| out[ob + i] += bv; }
    return out;
}
fn relu(x: []f32) void { for (x) |*v| { if (v.* < 0) v.* = 0; } }

// per-stage profiling accumulators (ns): fbank, stem, stage1..4, pool+gemm
pub var prof = [_]u64{0} ** 7;
pub var prof_n: u64 = 0;
pub var conv_im2col_ns: u64 = 0;
pub var conv_sgemm_ns: u64 = 0;

/// Full forward: fbank features [nfr][80] → 256-d embedding (caller frees).
pub fn embed(m: *const Model, sig: []const f32) ![EMB]f32 {
    var a = std.heap.ArenaAllocator.init(m.alloc); // scratch for one segment
    defer a.deinit();
    const ar = a.allocator();
    var tm = std.time.Timer.start() catch unreachable;
    prof_n += 1;
    var nfr: usize = 0;
    const fb = try fbank(m, sig, &nfr);
    // global-mean normalize fbank over time, then layout as [C=1][H=80][W=nfr]
    var colmean: [NMEL]f32 = [_]f32{0} ** NMEL;
    for (0..nfr) |t| for (0..NMEL) |b| { colmean[b] += fb[t * NMEL + b]; };
    for (0..NMEL) |b| colmean[b] /= @floatFromInt(nfr);
    var x = try ar.alloc(f32, NMEL * nfr); // [80][nfr]
    for (0..NMEL) |b| for (0..nfr) |t| { x[b * nfr + t] = fb[t * NMEL + b] - colmean[b]; };
    m.alloc.free(fb);
    var c: usize = 1; var h: usize = NMEL; var w: usize = nfr;

    prof[0] += tm.lap();
    var ci: usize = 0;
    // stem
    var ho: usize = 0; var wo: usize = 0;
    x = try conv2d(ar, x, c, h, w, m.convs[ci], &ho, &wo); ci += 1; relu(x);
    c = m.convs[0].o; h = ho; w = wo;
    prof[1] += tm.lap();
    const stages = [_]struct { nb: usize, downs: bool }{ .{ .nb = 3, .downs = false }, .{ .nb = 4, .downs = true }, .{ .nb = 6, .downs = true }, .{ .nb = 3, .downs = true } };
    for (stages, 0..) |st, si| {
        for (0..st.nb) |k| {
            const downs = st.downs and k == 0;
            const inp = x; const ic = c; const ih = h; const iw = w;
            // conv1 (+relu)
            var y = try conv2d(ar, x, c, h, w, m.convs[ci], &ho, &wo); ci += 1; relu(y);
            const yc = m.convs[ci - 1].o; const yh = ho; const yw = wo;
            // conv2
            y = try conv2d(ar, y, yc, yh, yw, m.convs[ci], &ho, &wo); ci += 1;
            var sc = inp;
            if (downs) { sc = try conv2d(ar, inp, ic, ih, iw, m.convs[ci], &ho, &wo); ci += 1; }
            // residual add + relu
            for (0..y.len) |i| y[i] += sc[i];
            relu(y);
            x = y; c = m.convs[ci - 1].o; h = yh; w = yw;
        }
        prof[2 + si] += tm.lap();
    }
    // stats pooling over time (W) per [C][H]
    const ch = c * h; // 256*10
    var pooled = try ar.alloc(f32, 2 * ch);
    for (0..c) |cc| for (0..h) |hh| {
        const base = (cc * h + hh) * w;
        var mu: f32 = 0;
        for (0..w) |t| mu += x[base + t];
        mu /= @floatFromInt(w);
        var v: f32 = 0;
        for (0..w) |t| { const d = x[base + t] - mu; v += d * d; }
        v /= @floatFromInt(w - 1); // sample variance (ddof=1)
        pooled[cc * h + hh] = mu;
        pooled[ch + cc * h + hh] = @sqrt(v + 1e-7);
    };
    // gemm [256][5120] @ pooled[5120] + b - mean_vec
    var out: [EMB]f32 = undefined;
    const K = 2 * ch;
    for (0..EMB) |o| {
        var acc: f32 = m.gemm_b[o];
        const wr = m.gemm_w[o * K ..][0..K];
        for (0..K) |i| acc += wr[i] * pooled[i];
        out[o] = acc - m.mean_vec[o];
    }
    prof[6] += tm.lap();
    return out;
}

/// Print accumulated per-stage profile (ns→ms) to the given writer.
pub fn dumpProf(out: anytype) !void {
    const names = [_][]const u8{ "fbank", "stem", "stage1", "stage2", "stage3", "stage4", "pool+gemm" };
    var tot: u64 = 0;
    for (prof) |p| tot += p;
    if (prof_n == 0 or tot == 0) return;
    try out.print("\n=== diar ResNet34 profile ({d} embeds, {d:.1} ms/embed) ===\n", .{ prof_n, @as(f64, @floatFromInt(tot)) / 1e6 / @as(f64, @floatFromInt(prof_n)) });
    for (names, 0..) |nm, i| {
        const ms = @as(f64, @floatFromInt(prof[i])) / 1e6;
        try out.print("  {s:<11} {d:8.1} ms  ({d:4.1}%)\n", .{ nm, ms, 100.0 * @as(f64, @floatFromInt(prof[i])) / @as(f64, @floatFromInt(tot)) });
    }
    try out.print("  conv split: im2col {d:.1} ms / sgemm {d:.1} ms\n", .{ @as(f64, @floatFromInt(conv_im2col_ns)) / 1e6, @as(f64, @floatFromInt(conv_sgemm_ns)) / 1e6 });
}
