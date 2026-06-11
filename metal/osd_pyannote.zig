// osd_pyannote.zig — sovereign CPU port of pyannote segmentation-3.0
// (overlapped-speech detection / local speaker activity), weights from the
// sherpa-onnx ONNX export via bench/convert_pyannote_seg.py; onnxruntime is
// the bit-level validation referee (test_osd.zig).
//
// Why: single-label diarization has a structural miss floor on overlapped
// speech — ES2004a ref overlap = 14.7% of scored time while our 1-spk-region
// miss is only 7.2% (PERF_LOG O-1). Cheap detectors were measured + refuted
// (centroid ambiguity recall 20%, transition windows precision 46%); a
// trained multilabel segmenter is the only signal that works.
//
// Graph (verified against the ONNX node dump):
//   IN(1) → SincConv(80,1,251,s10) → |x| → MaxPool3 → IN(80) → LReLU
//   → Conv(60,80,5) → MaxPool3 → IN(60) → LReLU
//   → Conv(60,60,5) → MaxPool3 → IN(60) → LReLU            (frames F, 60ch)
//   → 4× BiLSTM(h=128; ONNX gate order i,o,f,c; dir1 = time-reversed)
//   → 256→128 LReLU → 128→128 LReLU → 128→7 → LogSoftmax
// 10 s @16 kHz (160000) → F=589 frames, shift 270 samples (16.875 ms),
// receptive field 991. Powerset classes: ∅,{0},{1},{2},{0,1},{0,2},{1,2}.
const std = @import("std");

// Accelerate BLAS (the build links -framework Accelerate)
extern fn cblas_sgemm(order: c_int, transA: c_int, transB: c_int, M: c_int, N: c_int, K: c_int, alpha: f32, A: [*]const f32, lda: c_int, B: [*]const f32, ldb: c_int, beta: f32, C: [*]f32, ldc: c_int) void;
extern fn cblas_sgemv(order: c_int, trans: c_int, M: c_int, N: c_int, alpha: f32, A: [*]const f32, lda: c_int, x: [*]const f32, incx: c_int, beta: f32, y: [*]f32, incy: c_int) void;
const RM: c_int = 101;
const NT: c_int = 111;
const TR: c_int = 112;

pub const WIN_SAMPLES: usize = 160000; // 10 s @ 16 kHz
pub const N_CLASSES: usize = 7;
pub const SHIFT: usize = 270; // samples per output frame
pub const RFIELD: usize = 991;
const H: usize = 128;

const Tensor = struct { dims: [4]usize, nd: usize, data: []f32 };

pub const Model = struct {
    t: [31]Tensor,

    pub fn load(alloc: std.mem.Allocator, path: []const u8) !Model {
        const bytes = try std.fs.cwd().readFileAlloc(alloc, path, 64 * 1024 * 1024);
        var off: usize = 0;
        const ru = struct {
            fn f(b: []const u8, o: *usize) u32 {
                const v = std.mem.readInt(u32, b[o.*..][0..4], .little);
                o.* += 4;
                return v;
            }
        }.f;
        if (ru(bytes, &off) != 0x504F5344) return error.BadMagic;
        var m: Model = undefined;
        for (0..31) |i| {
            const nd = ru(bytes, &off);
            var dims = [4]usize{ 1, 1, 1, 1 };
            var n: usize = 1;
            for (0..nd) |d| {
                dims[d] = ru(bytes, &off);
                n *= dims[d];
            }
            m.t[i] = .{ .dims = dims, .nd = nd, .data = @as([*]f32, @ptrCast(@alignCast(@constCast(bytes[off..].ptr))))[0..n] };
            off += 4 * n;
        }
        return m;
    }

    fn instNorm(x: []f32, ch: usize, tlen: usize, w: []const f32, b: []const f32) void {
        for (0..ch) |c| {
            const row = x[c * tlen ..][0..tlen];
            var mu: f64 = 0;
            for (row) |v| mu += v;
            mu /= @floatFromInt(tlen);
            var va: f64 = 0;
            for (row) |v| {
                const d = @as(f64, v) - mu;
                va += d * d;
            }
            va /= @floatFromInt(tlen);
            const inv = 1.0 / @sqrt(va + 1e-5);
            const sc = w[c];
            const bi = b[c];
            for (row) |*v| v.* = @floatCast((@as(f64, v.*) - mu) * inv * sc + bi);
        }
    }

    fn lrelu(x: []f32) void {
        for (x) |*v| {
            if (v.* < 0) v.* *= 0.01;
        }
    }

    // generic conv1d, no pad: in[cin][tin] → out[cout][tout]
    fn conv1d(out: []f32, in_: []const f32, w: []const f32, b: []const f32, cin: usize, cout: usize, k: usize, stride: usize, tin: usize) usize {
        const tout = (tin - k) / stride + 1;
        for (0..cout) |co| {
            const wrow = w[co * cin * k ..][0 .. cin * k];
            for (0..tout) |to| {
                var acc: f32 = b[co];
                const base = to * stride;
                for (0..cin) |ci| {
                    const wk = wrow[ci * k ..][0..k];
                    const xr = in_[ci * tin + base ..][0..k];
                    for (0..k) |kk| acc += wk[kk] * xr[kk];
                }
                out[co * tout + to] = acc;
            }
        }
        return tout;
    }

    fn maxpool3(out: []f32, in_: []const f32, ch: usize, tin: usize) usize {
        const tout = (tin - 3) / 3 + 1;
        for (0..ch) |c| {
            for (0..tout) |to| {
                const x = in_[c * tin + to * 3 ..][0..3];
                out[c * tout + to] = @max(x[0], @max(x[1], x[2]));
            }
        }
        return tout;
    }

    // one bidirectional LSTM layer: x[F][din] → y[F][256] (fwd|bwd concat).
    // ONNX gate order i,o,f,c; W[dir][512][din], R[dir][512][128],
    // B[dir][1024] = Wb|Rb. xw scratch holds F*512 per direction.
    fn bilstm(alloc: std.mem.Allocator, x: []const f32, F: usize, din: usize, W: Tensor, R: Tensor, B: Tensor, y: []f32) !void {
        const xw = try alloc.alloc(f32, F * 512);
        defer alloc.free(xw);
        for (0..2) |dir| {
            const Wd = W.data[dir * 512 * din ..][0 .. 512 * din];
            const Rd = R.data[dir * 512 * H ..][0 .. 512 * H];
            const Bd = B.data[dir * 1024 ..][0..1024];
            // input contribution for all frames: xw[F][512] = X · Wᵀ (sgemm)
            cblas_sgemm(RM, NT, TR, @intCast(F), 512, @intCast(din), 1.0, x.ptr, @intCast(din), Wd.ptr, @intCast(din), 0.0, xw.ptr, 512);
            for (0..F) |t| {
                for (0..512) |gq| xw[t * 512 + gq] += Bd[gq] + Bd[512 + gq];
            }
            var h = [_]f32{0} ** H;
            var cc = [_]f32{0} ** H;
            var step: usize = 0;
            while (step < F) : (step += 1) {
                const t = if (dir == 0) step else F - 1 - step;
                var z: [512]f32 = undefined;
                @memcpy(z[0..], xw[t * 512 ..][0..512]);
                cblas_sgemv(RM, NT, 512, H, 1.0, Rd.ptr, H, &h, 1, 1.0, &z, 1); // z += R·h
                for (0..H) |j| {
                    const ig = 1.0 / (1.0 + @exp(-z[j]));
                    const og = 1.0 / (1.0 + @exp(-z[H + j]));
                    const fg = 1.0 / (1.0 + @exp(-z[2 * H + j]));
                    const gg = std.math.tanh(z[3 * H + j]);
                    cc[j] = fg * cc[j] + ig * gg;
                    h[j] = og * std.math.tanh(cc[j]);
                }
                @memcpy(y[t * 256 + dir * H ..][0..H], h[0..]);
            }
        }
    }

    // full forward: samples[WIN_SAMPLES] → logp[F][7]; returns F
    pub fn forward(self: *const Model, alloc: std.mem.Allocator, samples: []const f32, logp: []f32) !usize {
        const T = samples.len;
        // input instance-norm (C=1 over the whole window)
        const x0 = try alloc.alloc(f32, T);
        defer alloc.free(x0);
        @memcpy(x0, samples);
        instNorm(x0, 1, T, self.t[0].data, self.t[1].data);
        // sinc conv 80×251 s10 → |x| → pool → IN → LReLU
        const t1 = (T - 251) / 10 + 1;
        const a = try alloc.alloc(f32, 80 * t1);
        defer alloc.free(a);
        { // sinc conv as im2col + sgemm: out[80][t1] = W[80][251] · colᵀ[251][t1]
            const col = try alloc.alloc(f32, t1 * 251);
            defer alloc.free(col);
            for (0..t1) |to| @memcpy(col[to * 251 ..][0..251], x0[to * 10 ..][0..251]);
            cblas_sgemm(RM, NT, TR, 80, @intCast(t1), 251, 1.0, self.t[2].data.ptr, 251, col.ptr, 251, 0.0, a.ptr, @intCast(t1));
        }
        for (a) |*v| v.* = @abs(v.*);
        const t2 = (t1 - 3) / 3 + 1;
        const bbuf = try alloc.alloc(f32, 80 * t2);
        defer alloc.free(bbuf);
        _ = maxpool3(bbuf, a, 80, t1);
        instNorm(bbuf, 80, t2, self.t[3].data, self.t[4].data);
        lrelu(bbuf);
        // conv 60×80×5 → pool → IN → LReLU
        const t3 = t2 - 4;
        const cbuf = try alloc.alloc(f32, 60 * t3);
        defer alloc.free(cbuf);
        _ = conv1d(cbuf, bbuf, self.t[5].data, self.t[6].data, 80, 60, 5, 1, t2);
        const t4 = (t3 - 3) / 3 + 1;
        const dbuf = try alloc.alloc(f32, 60 * t4);
        defer alloc.free(dbuf);
        _ = maxpool3(dbuf, cbuf, 60, t3);
        instNorm(dbuf, 60, t4, self.t[7].data, self.t[8].data);
        lrelu(dbuf);
        // conv 60×60×5 → pool → IN → LReLU
        const t5 = t4 - 4;
        const ebuf = try alloc.alloc(f32, 60 * t5);
        defer alloc.free(ebuf);
        _ = conv1d(ebuf, dbuf, self.t[9].data, self.t[10].data, 60, 60, 5, 1, t4);
        const F = (t5 - 3) / 3 + 1;
        const feat = try alloc.alloc(f32, 60 * F);
        defer alloc.free(feat);
        _ = maxpool3(feat, ebuf, 60, t5);
        instNorm(feat, 60, F, self.t[11].data, self.t[12].data);
        lrelu(feat);
        // transpose [60][F] → [F][60]
        const xt = try alloc.alloc(f32, F * 60);
        defer alloc.free(xt);
        for (0..F) |t| for (0..60) |c| {
            xt[t * 60 + c] = feat[c * F + t];
        };
        // 4× BiLSTM
        var cur = try alloc.alloc(f32, F * 256);
        var nxt = try alloc.alloc(f32, F * 256);
        defer alloc.free(cur);
        defer alloc.free(nxt);
        try bilstm(alloc, xt, F, 60, self.t[13], self.t[14], self.t[15], cur);
        for (0..3) |l| {
            try bilstm(alloc, cur, F, 256, self.t[16 + l * 3], self.t[17 + l * 3], self.t[18 + l * 3], nxt);
            const tmp = cur;
            cur = nxt;
            nxt = tmp;
        }
        // linears (MatMul weights are [in][out]) + logsoftmax
        const w0 = self.t[25].data;
        const b0 = self.t[26].data;
        const w1 = self.t[27].data;
        const b1 = self.t[28].data;
        const w2 = self.t[29].data;
        const b2 = self.t[30].data;
        const h0 = try alloc.alloc(f32, F * 128);
        defer alloc.free(h0);
        const h1 = try alloc.alloc(f32, F * 128);
        defer alloc.free(h1);
        cblas_sgemm(RM, NT, NT, @intCast(F), 128, 256, 1.0, cur.ptr, 256, w0.ptr, 128, 0.0, h0.ptr, 128);
        for (0..F) |t| {
            for (0..128) |o| {
                const v = h0[t * 128 + o] + b0[o];
                h0[t * 128 + o] = if (v < 0) v * 0.01 else v;
            }
        }
        cblas_sgemm(RM, NT, NT, @intCast(F), 128, 128, 1.0, h0.ptr, 128, w1.ptr, 128, 0.0, h1.ptr, 128);
        for (0..F) |t| {
            for (0..128) |o| {
                const v = h1[t * 128 + o] + b1[o];
                h1[t * 128 + o] = if (v < 0) v * 0.01 else v;
            }
        }
        for (0..F) |t| {
            var z: [7]f32 = undefined;
            var mx: f32 = -1e30;
            for (0..7) |o| {
                var acc: f32 = b2[o];
                for (0..128) |j| acc += h1[t * 128 + j] * w2[j * 7 + o];
                z[o] = acc;
                mx = @max(mx, acc);
            }
            var se: f32 = 0;
            for (0..7) |o| se += @exp(z[o] - mx);
            const lse = mx + @log(se);
            for (0..7) |o| logp[t * 7 + o] = z[o] - lse;
        }
                return F;
    }
};
