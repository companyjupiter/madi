#!/usr/bin/env python3
# Offline diarization clustering sweep on dumped segment embeddings.
# Decouples the expensive encoder pass from clustering/param tuning.
import sys, struct, subprocess, os, tempfile
import numpy as np

EMB = sys.argv[1] if len(sys.argv) > 1 else "/tmp/ami_emb.bin"
REF = sys.argv[2] if len(sys.argv) > 2 else "bench/ES2004a.ref.rttm"
FID = sys.argv[3] if len(sys.argv) > 3 else "ES2004a"
SEG = 1.5
MDEVAL = "bench/md-eval.pl"

def load(path):
    b = open(path, "rb").read()
    n, d = struct.unpack("<II", b[:8])
    off = 8
    t0 = np.frombuffer(b, dtype="<f4", count=n, offset=off).copy(); off += 4*n
    emb = np.frombuffer(b, dtype="<f4", count=n*d, offset=off).reshape(n, d).copy()
    return t0, emb

def write_rttm(path, t0, labels):
    # merge consecutive same-label segments
    lines = []
    s_start, s_end, s_spk = t0[0], t0[0]+SEG, labels[0]
    for i in range(1, len(t0)):
        if labels[i] == s_spk and t0[i]-s_end < SEG:
            s_end = t0[i]+SEG
        else:
            lines.append(f"SPEAKER {FID} 1 {s_start:.3f} {s_end-s_start:.3f} <NA> <NA> spk{s_spk} <NA> <NA>")
            s_start, s_end, s_spk = t0[i], t0[i]+SEG, labels[i]
    lines.append(f"SPEAKER {FID} 1 {s_start:.3f} {s_end-s_start:.3f} <NA> <NA> spk{s_spk} <NA> <NA>")
    open(path, "w").write("\n".join(lines)+"\n")

def der(t0, labels):
    f = tempfile.mktemp(suffix=".rttm")
    write_rttm(f, t0, labels)
    out = subprocess.run(["perl", MDEVAL, "-c", "0.25", "-r", REF, "-s", f],
                         capture_output=True, text=True).stdout
    for line in out.splitlines():
        if "OVERALL SPEAKER DIARIZATION ERROR" in line:
            return float(line.split("=")[1].strip().split()[0])
    return None

def ref_segments(path):
    segs = []
    for line in open(path):
        p = line.split()
        if p and p[0] == "SPEAKER":
            segs.append((float(p[3]), float(p[3])+float(p[4]), p[7]))
    return segs

def oracle_labels(t0, refsegs):
    # majority ref speaker overlapping each 1.5s segment
    spk_ids = {}
    labels = []
    for t in t0:
        a, b = t, t+SEG
        best, bestov = None, 0.0
        ov = {}
        for (ra, rb, rs) in refsegs:
            o = max(0, min(b, rb)-max(a, ra))
            if o > 0: ov[rs] = ov.get(rs, 0)+o
        if ov:
            best = max(ov, key=ov.get)
        if best is None: best = "NONE"
        if best not in spk_ids: spk_ids[best] = len(spk_ids)
        labels.append(spk_ids[best])
    return np.array(labels), len(spk_ids)

from sklearn.cluster import AgglomerativeClustering, KMeans

t0, emb = load(EMB)
print(f"loaded {len(t0)} segs x {emb.shape[1]}")
refsegs = ref_segments(REF)
ntrue = len(set(s[2] for s in refsegs))
print(f"ref: {len(refsegs)} segments, {ntrue} speakers")

# oracle: best achievable DER given our 1.5s segmentation + VAD
olab, ok = oracle_labels(t0, refsegs)
print(f"ORACLE (our segmentation, true labels): DER={der(t0, olab):.2f}%  ({ok} spk incl NONE)")

def prep(emb, center=True, l2=True, whiten=False):
    X = emb.astype(np.float64).copy()
    if center: X -= X.mean(0)
    if whiten:
        # PCA whitening
        u, s, vt = np.linalg.svd(X - X.mean(0), full_matrices=False)
        k = min(64, len(s))
        X = (X @ vt[:k].T) / (s[:k]/np.sqrt(len(X)) + 1e-6)
    if l2:
        X /= (np.linalg.norm(X, axis=1, keepdims=True)+1e-8)
    return X

print("\n=== KMeans (fixed K) ===")
for center in (True,):
    for whiten in (False, True):
        X = prep(emb, center=center, l2=True, whiten=whiten)
        for K in (2,3,4,5,6):
            lab = KMeans(K, n_init=10, random_state=0).fit_predict(X)
            print(f"  center={center} whiten={whiten} K={K}: DER={der(t0,lab):.2f}%")

print("\n=== Agglomerative (cosine, average) variable-K via distance_threshold ===")
for whiten in (False, True):
    X = prep(emb, center=True, l2=True, whiten=whiten)
    for thr in (0.4,0.5,0.6,0.7,0.8,0.9,1.0):
        ac = AgglomerativeClustering(n_clusters=None, distance_threshold=thr,
                                     metric="cosine", linkage="average")
        lab = ac.fit_predict(X)
        print(f"  whiten={whiten} thr={thr}: K={lab.max()+1} DER={der(t0,lab):.2f}%")
