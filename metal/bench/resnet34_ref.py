#!/usr/bin/env python3
# P1: numpy reference of wespeaker ResNet34 (BN folded into convs) reconstructed
# purely from the onnx weights — verified against onnxruntime. Proves the
# architecture map before the Zig/Metal port, and dumps weights for the port.
import sys, struct
import numpy as np
import onnx
from onnx import numpy_helper

M = onnx.load("bench/wespeaker_en_voxceleb_resnet34.onnx")
W = {t.name: numpy_helper.to_array(t) for t in M.graph.initializer}
# collect conv (W,b) in graph order + gemm + final mean_vec
convs = []
gemm_w = gemm_b = mean_vec = None
for n in M.graph.node:
    if n.op_type == "Conv":
        w = W[n.input[1]]; b = W[n.input[2]] if len(n.input) > 2 else np.zeros(w.shape[0], np.float32)
        s = n.attribute  # strides
        stride = 1
        for a in n.attribute:
            if a.name == "strides": stride = a.ints[0]
        convs.append((w.astype(np.float32), b.astype(np.float32), stride))
    elif n.op_type == "Gemm":
        gemm_w = W[n.input[1]].astype(np.float32); gemm_b = W[n.input[2]].astype(np.float32)
    elif n.op_type == "Sub" and n.input[1] in W:
        mean_vec = W[n.input[1]].astype(np.float32)
print(f"{len(convs)} convs, gemm{gemm_w.shape}, mean_vec{mean_vec.shape}")

def conv2d(x, w, b, stride, pad):  # x[C,H,W] -> [O,H',W']  (im2col)
    C, H, Wd = x.shape; O, _, kh, kw = w.shape
    xp = np.pad(x, ((0,0),(pad,pad),(pad,pad)))
    Ho = (H + 2*pad - kh)//stride + 1; Wo = (Wd + 2*pad - kw)//stride + 1
    cols = np.empty((C*kh*kw, Ho*Wo), np.float32)
    idx = 0
    for c in range(C):
        for i in range(kh):
            for j in range(kw):
                patch = xp[c, i:i+stride*Ho:stride, j:j+stride*Wo:stride]
                cols[idx] = patch.reshape(-1); idx += 1
    out = (w.reshape(O, -1) @ cols + b[:, None]).reshape(O, Ho, Wo)
    return out

def relu(x): return np.maximum(x, 0)

ci = [0]
def nextconv(): c = convs[ci[0]]; ci[0]+=1; return c
def block(x, downs):
    inp = x
    w,b,st = nextconv(); y = relu(conv2d(x, w, b, st, 1))          # conv1 (stride st)
    w,b,_  = nextconv(); y = conv2d(y, w, b, 1, 1)                 # conv2
    if downs:
        w,b,st = nextconv(); inp = conv2d(inp, w, b, st, 0)        # 1x1 shortcut
    return relu(y + inp)

def forward(feats):  # feats [T,80]
    x = feats.T[None]                       # [1,80,T]  (C=1,H=freq,W=time)
    w,b,st = nextconv(); x = relu(conv2d(x[0:1].reshape(1,80,-1), w, b, 1, 1))
    for nb, downs0 in [(3,False),(4,True),(6,True),(3,True)]:
        for k in range(nb):
            x = block(x, downs0 and k == 0)
    # stats pooling over time (W): mean + std per (C,H)
    mean = x.mean(2)                         # [256,10]
    var = x.var(2, ddof=1)                    # sample variance (N-1), matches onnx
    std = np.sqrt(var + 1e-7)                 # onnx adds eps before sqrt
    pooled = np.concatenate([mean.reshape(-1), std.reshape(-1)])   # [5120]
    emb = gemm_w @ pooled + gemm_b          # [256]
    return emb - mean_vec

# ---- verify vs onnxruntime on a real fbank segment ----
import onnxruntime as ort, kaldi_native_fbank as knf, wave
sess = ort.InferenceSession("bench/wespeaker_en_voxceleb_resnet34.onnx", providers=["CPUExecutionProvider"])
w = wave.open("bench/ES2004a.wav"); x = np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(np.float32)/32768.0
o = knf.FbankOptions(); o.frame_opts.samp_freq=16000; o.frame_opts.dither=0; o.frame_opts.snip_edges=False; o.mel_opts.num_bins=80
f = knf.OnlineFbank(o); seg = x[16000*20:16000*20+24000]; f.accept_waveform(16000, seg.tolist()); f.input_finished()
fb = np.array([f.get_frame(i) for i in range(f.num_frames_ready)], np.float32); fb = fb - fb.mean(0)
ort_emb = sess.run(None, {"feats": fb[None]})[0][0]
ci[0] = 0
ref_emb = forward(fb)
cos = (ort_emb@ref_emb)/(np.linalg.norm(ort_emb)*np.linalg.norm(ref_emb))
print(f"numpy-ref vs onnxruntime: cosine={cos:.6f}  maxabs={np.abs(ort_emb-ref_emb).max():.4e}")
print("✅ architecture verified" if cos > 0.9999 else "❌ MISMATCH")

if cos > 0.9999 and len(sys.argv) > 1:  # dump weights for the Zig port
    with open(sys.argv[1], "wb") as fh:
        fh.write(struct.pack("<I", len(convs)))
        for w_,b_,st in convs:
            fh.write(struct.pack("<5i", w_.shape[0], w_.shape[1], w_.shape[2], w_.shape[3], st))
            fh.write(w_.tobytes()); fh.write(b_.tobytes())
        fh.write(struct.pack("<2i", *gemm_w.shape)); fh.write(gemm_w.tobytes()); fh.write(gemm_b.tobytes())
        fh.write(mean_vec.tobytes())
    print(f"dumped weights → {sys.argv[1]}")
