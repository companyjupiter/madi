#!/usr/bin/env python3
# Replicate kaldi fbank (knf config) in numpy, verify vs knf reference, then
# dump the mel filterbank [80x257] for the Zig port (DSP is deterministic).
import numpy as np
SR, FLEN, FSHIFT, FFT, NMEL = 16000, 400, 160, 512, 80
PREEMPH, LOW, HIGH = 0.97, 20.0, 8000.0

def mel(f): return 1127.0 * np.log(1 + f/700.0)
def melbank():
    fbw = SR/FFT                       # 31.25 Hz/bin
    ml, mh = mel(LOW), mel(HIGH)
    d = (mh-ml)/(NMEL+1)
    nb = FFT//2 + 1                    # 257 power bins
    fb = np.zeros((NMEL, nb), np.float32)
    for b in range(NMEL):
        lm, cm, rm = ml+b*d, ml+(b+1)*d, ml+(b+2)*d
        for i in range(nb):
            m = mel(fbw*i)
            if lm < m < rm:
                fb[b,i] = (m-lm)/(cm-lm) if m <= cm else (rm-m)/(rm-cm)
    return fb
FB = melbank()

def povey(N):
    n = np.arange(N)
    return (0.5 - 0.5*np.cos(2*np.pi*n/(N-1)))**0.85

WIN = povey(FLEN).astype(np.float32)

def fbank(sig):
    n = len(sig)
    nfr = (n + FSHIFT//2)//FSHIFT      # snip_edges=false
    out = np.zeros((nfr, NMEL), np.float32)
    for m in range(nfr):
        start = m*FSHIFT - (FLEN-FSHIFT)//2
        fr = np.empty(FLEN, np.float32)
        for k in range(FLEN):
            idx = start+k
            # kaldi reflection at edges
            while idx < 0 or idx >= n:
                if idx < 0: idx = -idx - 1
                elif idx >= n: idx = 2*n - 1 - idx
            fr[k] = sig[idx]
        fr = fr - fr.mean()                       # remove_dc_offset
        pe = fr.copy()                            # preemphasis
        pe[1:] = fr[1:] - PREEMPH*fr[:-1]; pe[0] = fr[0] - PREEMPH*fr[0]
        pe *= WIN                                 # povey window
        sp = np.abs(np.fft.rfft(pe, FFT))**2      # power, 257 bins
        me = FB @ sp
        out[m] = np.log(np.maximum(me, 1.1920929e-7))   # log, kaldi FLT_EPSILON floor
    return out

if __name__ == "__main__":
    seg = np.fromfile("/tmp/seg.f32", np.float32)
    ref = np.fromfile("/tmp/fb_ref.f32", np.float32).reshape(-1, NMEL)
    out = fbank(seg)
    print("shape", out.shape, "ref", ref.shape)
    print("frame0[:5]", out[0,:5], "ref", ref[0,:5])
    print("maxabs diff", np.abs(out-ref).max(), "mean diff", np.abs(out-ref).mean())
    FB.tofile("/tmp/kaldi_melbank.f32")  # [80,257]
    print("✅ match" if np.abs(out-ref).max() < 1e-2 else "❌ mismatch")
