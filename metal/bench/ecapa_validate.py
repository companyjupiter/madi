#!/usr/bin/env python3
# De-risk #1: does a dedicated speaker-embedding model (CAM++/ECAPA-class) get
# good DER on AMI? Extract per-1.5s-segment CAM++ embeddings → cluster → DER.
# If yes, the Metal port of such a model is justified.
import sys, subprocess, tempfile, wave
import numpy as np
import onnxruntime as ort
import kaldi_native_fbank as knf
from sklearn.cluster import AgglomerativeClustering, KMeans

WAV = sys.argv[1] if len(sys.argv) > 1 else "bench/ES2004a.wav"
REF = sys.argv[2] if len(sys.argv) > 2 else "bench/ES2004a.ref.rttm"
FID = sys.argv[3] if len(sys.argv) > 3 else "ES2004a"
SEG = 1.5

w = wave.open(WAV); n = w.getnframes(); sr = w.getframerate()
x = np.frombuffer(w.readframes(n), "<i2").astype(np.float32) / 32768.0

def fbank80(sig):
    opts = knf.FbankOptions()
    opts.frame_opts.samp_freq = 16000
    opts.frame_opts.dither = 0.0
    opts.frame_opts.snip_edges = False
    opts.mel_opts.num_bins = 80
    f = knf.OnlineFbank(opts)
    f.accept_waveform(16000, sig.tolist())
    f.input_finished()
    return np.array([f.get_frame(i) for i in range(f.num_frames_ready)], dtype=np.float32)

sess = ort.InferenceSession("bench/campplus.onnx", providers=["CPUExecutionProvider"])
def embed(sig):
    fb = fbank80(sig)
    if len(fb) < 10: return None
    fb = fb - fb.mean(0, keepdims=True)            # global-mean normalize
    e = sess.run(None, {"x": fb[None].astype(np.float32)})[0][0]
    return e / (np.linalg.norm(e) + 1e-8)

seg_n = int(SEG * sr)
T, E = [], []
# simple waveform-RMS VAD relative to median
rmss = []
for s in range(0, len(x)-seg_n, seg_n):
    rmss.append(np.sqrt((x[s:s+seg_n]**2).mean()))
thr = 0.3 * np.median(rmss)
for s in range(0, len(x)-seg_n, seg_n):
    sig = x[s:s+seg_n]
    if np.sqrt((sig**2).mean()) < thr: continue
    em = embed(sig)
    if em is None: continue
    T.append(s/sr); E.append(em)
T = np.array(T); E = np.array(E)
print(f"{len(T)} speech segments, emb dim {E.shape[1]}")

refsegs = [(float(p[3]), float(p[3])+float(p[4]), p[7]) for p in (L.split() for L in open(REF)) if p and p[0]=="SPEAKER"]
ntrue = len(set(s[2] for s in refsegs))
def olabel(t):
    ov = {}
    for a,b,s in refsegs:
        o = max(0, min(t+SEG,b)-max(t,a))
        if o>0: ov[s]=ov.get(s,0)+o
    return max(ov,key=ov.get) if ov else "NONE"
y = np.array([olabel(t) for t in T])

# speaker separation check
S = E @ E.T
intra,inter=[],[]
for i in range(len(y)):
    if y[i]=="NONE":continue
    for j in range(i+1,len(y)):
        if y[j]=="NONE":continue
        (intra if y[i]==y[j] else inter).append(S[i,j])
print(f"CAM++ separation: intra={np.mean(intra):.3f} inter={np.mean(inter):.3f} SEP={np.mean(intra)-np.mean(inter):.3f}")

def der(labels):
    f=tempfile.mktemp(".rttm");ls=[];ss,se,sp=T[0],T[0]+SEG,labels[0]
    for i in range(1,len(T)):
        if labels[i]==sp and T[i]-se<SEG:se=T[i]+SEG
        else:ls.append(f"SPEAKER {FID} 1 {ss:.3f} {se-ss:.3f} <NA> <NA> spk{sp} <NA> <NA>");ss,se,sp=T[i],T[i]+SEG,labels[i]
    ls.append(f"SPEAKER {FID} 1 {ss:.3f} {se-ss:.3f} <NA> <NA> spk{sp} <NA> <NA>")
    open(f,"w").write("\n".join(ls)+"\n")
    o=subprocess.run(["perl","bench/md-eval.pl","-c","0.25","-r",REF,"-s",f],capture_output=True,text=True).stdout
    for L in o.splitlines():
        if "OVERALL SPEAKER" in L:return float(L.split("=")[1].split()[0])

um={s:i for i,s in enumerate(sorted(set(y)))}
print(f"\nref speakers={ntrue}  ORACLE DER={der(np.array([um[v] for v in y])):.2f}%")
print("KMeans:        " + "  ".join(f"K{K}={der(KMeans(K,n_init=10,random_state=0).fit_predict(E)):.1f}" for K in (2,3,4,5)))
print("AHC(cos,avg):  " + "  ".join(f"K{K}={der(AgglomerativeClustering(n_clusters=K,metric='cosine',linkage='average').fit_predict(E)):.1f}" for K in (2,3,4,5)))
for thr_ in (0.5,0.6,0.7):
    ac=AgglomerativeClustering(n_clusters=None,distance_threshold=thr_,metric="cosine",linkage="average").fit_predict(E)
    print(f"AHC thr={thr_}: K={ac.max()+1} DER={der(ac):.2f}%")
