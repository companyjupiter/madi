#!/usr/bin/env python3
# Find a mel-feature config where K=4 clustering works on AMI (4 speakers).
import sys, subprocess, tempfile, wave
import numpy as np
from sklearn.cluster import KMeans, AgglomerativeClustering

WAV, REF, FID = "bench/ES2004a.wav", "bench/ES2004a.ref.rttm", "ES2004a"
SEG, N_FFT, HOP, N_MELS = 1.5, 400, 160, 128

w = wave.open(WAV); n = w.getnframes(); sr = w.getframerate()
x = np.frombuffer(w.readframes(n), dtype="<i2").astype(np.float64)/32768.0
filt = np.fromfile("assets/mel_filters.bin", dtype="<f4").reshape(N_MELS, N_FFT//2+1)
win = np.hanning(N_FFT)
nfr = 1+(len(x)-N_FFT)//HOP
fr = np.stack([x[i*HOP:i*HOP+N_FFT]*win for i in range(nfr)])
mel = np.log10(np.maximum(filt @ (np.abs(np.fft.rfft(fr,N_FFT,1))**2).T, 1e-10)).T
fps = sr/HOP
seg_fr = int(SEG*fps); gmean = mel.mean()
T, E = [], []
for s in range(0, len(mel)-seg_fr, seg_fr):
    b = mel[s:s+seg_fr]
    if b.mean() < gmean-0.5: continue
    T.append(s/fps); E.append(b.mean(0))
T = np.array(T); E = np.array(E)

refsegs = []
for L in open(REF):
    p = L.split()
    if p and p[0] == "SPEAKER": refsegs.append((float(p[3]), float(p[3])+float(p[4]), p[7]))
def olabel(t):
    ov = {}
    for a,b,s in refsegs:
        o = max(0,min(t+SEG,b)-max(t,a))
        if o>0: ov[s]=ov.get(s,0)+o
    return max(ov,key=ov.get) if ov else "NONE"
y = np.array([olabel(t) for t in T])

def der(labels):
    f = tempfile.mktemp(suffix=".rttm"); lines=[]; ss,se,sp=T[0],T[0]+SEG,labels[0]
    for i in range(1,len(T)):
        if labels[i]==sp and T[i]-se<SEG: se=T[i]+SEG
        else: lines.append(f"SPEAKER {FID} 1 {ss:.3f} {se-ss:.3f} <NA> <NA> spk{sp} <NA> <NA>"); ss,se,sp=T[i],T[i]+SEG,labels[i]
    lines.append(f"SPEAKER {FID} 1 {ss:.3f} {se-ss:.3f} <NA> <NA> spk{sp} <NA> <NA>")
    open(f,"w").write("\n".join(lines)+"\n")
    out=subprocess.run(["perl","bench/md-eval.pl","-c","0.25","-r",REF,"-s",f],capture_output=True,text=True).stdout
    for L in out.splitlines():
        if "OVERALL SPEAKER DIARIZATION ERROR" in L: return float(L.split("=")[1].split()[0])

# oracle for this segmentation
um = {s:i for i,s in enumerate(sorted(set(y)))}
print(f"segs={len(T)}  ORACLE DER={der(np.array([um[v] for v in y])):.2f}%")

def feats(E, zscore, bands, l2):
    X = E[:, :bands].astype(np.float64).copy()
    if zscore: X = (X - X.mean(0)) / (X.std(0)+1e-8)
    else: X = X - X.mean(0)
    if l2: X /= np.linalg.norm(X,axis=1,keepdims=True)+1e-8
    return X

print("\nconfig                              K=2    K=3    K=4")
for zscore in (False, True):
    for bands in (80, 128):
        for l2 in (False, True):
            X = feats(E, zscore, bands, l2)
            ds = []
            for K in (2,3,4):
                lab = KMeans(K,n_init=10,random_state=0).fit_predict(X)
                ds.append(der(lab))
            print(f"  zscore={int(zscore)} bands={bands} l2={int(l2)}:  {ds[0]:5.1f}  {ds[1]:5.1f}  {ds[2]:5.1f}")

# best config agglomerative too
print("\nAgglomerative (ward, zscore bands=80):")
X = feats(E, True, 80, False)
for K in (2,3,4,5):
    lab = AgglomerativeClustering(n_clusters=K, linkage="ward").fit_predict(X)
    print(f"  K={K}: DER={der(lab):.2f}%")
