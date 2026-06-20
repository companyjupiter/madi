#!/usr/bin/env python3
# Validate the hypothesis: mel-spectrogram features separate speakers, while
# Whisper-encoder features do not. Computes Whisper-style log-mel from the AMI
# wav, pools per 1.5s segment, and measures intra/inter-speaker separation +
# a spectral-bisection DER — to confirm the CUDA reference's design.
import sys, struct, subprocess, tempfile, wave
import numpy as np

WAV = sys.argv[1] if len(sys.argv) > 1 else "bench/ES2004a.wav"
REF = sys.argv[2] if len(sys.argv) > 2 else "bench/ES2004a.ref.rttm"
FID = sys.argv[3] if len(sys.argv) > 3 else "ES2004a"
SEG = 1.5
N_FFT, HOP, N_MELS = 400, 160, 128

# load wav (16k mono 16-bit)
w = wave.open(WAV); n = w.getnframes(); sr = w.getframerate()
x = np.frombuffer(w.readframes(n), dtype="<i2").astype(np.float64) / 32768.0
# log-mel (Whisper-style)
filt = np.fromfile("assets/mel_filters.bin", dtype="<f4").reshape(N_MELS, N_FFT//2 + 1)
win = np.hanning(N_FFT)
nfr = 1 + (len(x) - N_FFT) // HOP
frames = np.stack([x[i*HOP:i*HOP+N_FFT]*win for i in range(nfr)])
spec = np.abs(np.fft.rfft(frames, n=N_FFT, axis=1))**2          # [nfr,201] power
mel = np.log10(np.maximum(filt @ spec.T, 1e-10)).T               # [nfr,128]
fps = sr / HOP                                                   # mel frames/sec (100)
print(f"wav {n/sr:.0f}s, mel {mel.shape}, {fps:.0f} fr/s")

# pool per 1.5s segment with simple energy VAD (mel mean as proxy)
seg_fr = int(SEG * fps)
segs_t, segs_e = [], []
gmean = mel.mean()
for s in range(0, len(mel)-seg_fr, seg_fr):
    block = mel[s:s+seg_fr]
    if block.mean() < gmean - 0.5:   # crude VAD: skip quiet segments
        continue
    segs_t.append(s/fps); segs_e.append(block.mean(0))
T = np.array(segs_t); E = np.array(segs_e)
print(f"{len(T)} speech segments")

# oracle labels from ref
refsegs = []
for L in open(REF):
    p = L.split()
    if p and p[0] == "SPEAKER": refsegs.append((float(p[3]), float(p[3])+float(p[4]), p[7]))
ntrue = len(set(s[2] for s in refsegs))
def olabel(t):
    ov = {}
    for a, b, s in refsegs:
        o = max(0, min(t+SEG, b)-max(t, a))
        if o > 0: ov[s] = ov.get(s, 0)+o
    return max(ov, key=ov.get) if ov else "NONE"
y = np.array([olabel(t) for t in T])

def separation(X, tag):
    Xn = X - X.mean(0); Xn /= np.linalg.norm(Xn, axis=1, keepdims=True)+1e-8
    S = Xn @ Xn.T
    intra, inter = [], []
    for i in range(len(y)):
        if y[i] == "NONE": continue
        for j in range(i+1, len(y)):
            if y[j] == "NONE": continue
            (intra if y[i] == y[j] else inter).append(S[i, j])
    intra, inter = np.array(intra), np.array(inter)
    print(f"  [{tag}] intra={intra.mean():.3f} inter={inter.mean():.3f} SEPARATION={intra.mean()-inter.mean():.4f}")

print(f"\nref speakers={ntrue}")
separation(E, "MEL (raw log-mel, 128d)")

# spectral bisection (Fiedler) like the CUDA ref, on mel euclidean RBF
def spectral2(X):
    D2 = ((X[:,None,:]-X[None,:,:])**2).sum(-1)
    md = D2[np.triu_indices(len(X),1)].mean()
    best = None
    for mul in [0.1,0.5,1,2,5,10,50]:
        sig = md*mul
        W = np.exp(-D2/(2*sig)); np.fill_diagonal(W,0)
        d = W.sum(1); dinv = 1/np.sqrt(np.maximum(d,1e-8))
        L = np.eye(len(X)) - (dinv[:,None]*W*dinv[None,:])
        evals, evecs = np.linalg.eigh(L)
        lam2 = evals[1]
        if best is None or lam2 > best[0]:
            best = (lam2, (evecs[:,1] > 0).astype(int))
    return best[1]

def der(labels):
    f = tempfile.mktemp(suffix=".rttm")
    lines=[]; ss,se,sp=T[0],T[0]+SEG,labels[0]
    for i in range(1,len(T)):
        if labels[i]==sp and T[i]-se<SEG: se=T[i]+SEG
        else: lines.append(f"SPEAKER {FID} 1 {ss:.3f} {se-ss:.3f} <NA> <NA> spk{sp} <NA> <NA>"); ss,se,sp=T[i],T[i]+SEG,labels[i]
    lines.append(f"SPEAKER {FID} 1 {ss:.3f} {se-ss:.3f} <NA> <NA> spk{sp} <NA> <NA>")
    open(f,"w").write("\n".join(lines)+"\n")
    out=subprocess.run(["perl","bench/md-eval.pl","-c","0.25","-r",REF,"-s",f],capture_output=True,text=True).stdout
    for line in out.splitlines():
        if "OVERALL SPEAKER DIARIZATION ERROR" in line: return float(line.split("=")[1].split()[0])
print("\n=== DER on MEL features ===")
print(f"  spectral-bisection (2 spk, CUDA-style): DER={der(spectral2(E)):.2f}%")
from sklearn.cluster import KMeans
Xn = E - E.mean(0); Xn /= np.linalg.norm(Xn,axis=1,keepdims=True)+1e-8
for K in (2,3,4):
    print(f"  kmeans K={K}: DER={der(KMeans(K,n_init=10,random_state=0).fit_predict(Xn)):.2f}%")
