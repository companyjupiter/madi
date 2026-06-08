#!/usr/bin/env python3
# Estimate the number of speakers from dumped mel segment features.
# (eigengap heuristic on a cosine affinity + cluster-size sanity for K=2..8).
# NOTE: mel features are weak speaker descriptors, so this is a rough estimate.
import sys, struct
import numpy as np
from sklearn.cluster import KMeans

DUMP = sys.argv[1] if len(sys.argv) > 1 else "/tmp/clova_mel.bin"
b = open(DUMP, "rb").read()
n, d = struct.unpack("<II", b[:8]); off = 8
T = np.frombuffer(b, "<f4", n, off).copy(); off += 4*n
E = np.frombuffer(b, "<f4", n*d, off).reshape(n, d).copy()
print(f"{n} segments x {d}")

# VAD: drop low-energy segments (raw log-mel block mean)
bm = E.mean(1); keep = bm > bm.mean() - 0.5
X = E[keep]
print(f"speech segments after VAD: {len(X)}/{n}")
# per-dim z-score + L2
X = (X - X.mean(0)) / (X.std(0) + 1e-8)
X = X / (np.linalg.norm(X, axis=1, keepdims=True) + 1e-8)

# cosine affinity → normalized Laplacian → eigengap
S = X @ X.T
S = (S + 1) / 2.0           # map cosine [-1,1] → [0,1]
np.fill_diagonal(S, 0)
dg = S.sum(1); dinv = 1/np.sqrt(np.maximum(dg, 1e-8))
L = np.eye(len(X)) - dinv[:, None]*S*dinv[None, :]
ev = np.linalg.eigvalsh(L)        # ascending
print("\nsmallest 9 Laplacian eigenvalues:")
print("  " + "  ".join(f"{v:.3f}" for v in ev[:9]))
gaps = np.diff(ev[:9])
kbest = int(np.argmax(gaps[1:8])) + 2   # largest gap after the first (trivial) eigenvalue
print(f"eigengaps (λ_{{i+1}}-λ_i): " + "  ".join(f"{g:.3f}" for g in gaps[:8]))
print(f"→ eigengap suggests ~{kbest} speakers")

print("\nkmeans cluster-size distribution (z-scored, no L2):")
Xz = (E[keep] - E[keep].mean(0)) / (E[keep].std(0) + 1e-8)
for K in range(2, 9):
    lab = KMeans(K, n_init=10, random_state=0).fit_predict(Xz)
    sizes = sorted(np.bincount(lab, minlength=K).tolist(), reverse=True)
    # inertia-based: smaller clusters that are tiny → over-split
    print(f"  K={K}: sizes={sizes}")
