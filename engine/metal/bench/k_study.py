#!/usr/bin/env python3
"""Auto-K estimator study on DIAR_DUMP embeddings (n, d, t0[n], rms[n], emb[n*d]).

Usage: k_study.py <dump.bin>=<trueK> [<dump.bin>=<trueK> ...]
Replicates the binary's VAD (rms > 0.4 * median) + L2 norm, then scores each
candidate estimator against the true speaker count:
  sil    — simplified silhouette over k-means K=2..6 (current shipped method)
  eig    — eigengap on the normalized Laplacian of a cosine affinity
  bic    — spherical k-means BIC elbow
  ahc    — agglomerative (average-link, cosine) cut at a distance threshold
"""
import struct, sys

import numpy as np
from sklearn.cluster import AgglomerativeClustering

MAXK = 6


def load(path):
    b = open(path, 'rb').read()
    n, d = struct.unpack('<II', b[:8])
    off = 8
    t0 = np.frombuffer(b, '<f4', n, off); off += 4 * n
    rms = np.frombuffer(b, '<f4', n, off); off += 4 * n
    E = np.frombuffer(b, '<f4', n * d, off).reshape(n, d)
    keep = rms > np.median(rms) * 0.4  # binary's DIAR_VAD default
    X = E[keep].astype(np.float64)
    X /= np.linalg.norm(X, axis=1, keepdims=True) + 1e-8
    return X


def kmeans_fp(X, K, iters=30):
    """deterministic farthest-point-init k-means (mirrors the binary)."""
    n = len(X)
    cid = [int(np.argmax(np.linalg.norm(X - X.mean(0), axis=1)))]
    for _ in range(1, K):
        dmin = np.min([np.linalg.norm(X - X[c], axis=1) for c in cid], axis=0)
        cid.append(int(np.argmax(dmin)))
    C = X[cid].copy()
    for _ in range(iters):
        a = np.argmin(((X[:, None] - C[None]) ** 2).sum(-1), axis=1)
        for k in range(K):
            if (a == k).any():
                C[k] = X[a == k].mean(0)
    return a, C


def sil_simplified(X, a, C, K):
    if K < 2:
        return -2
    d2 = ((X[:, None] - C[None]) ** 2).sum(-1)
    aa = d2[np.arange(len(X)), a]
    d2[np.arange(len(X)), a] = np.inf
    bb = d2.min(1)
    mx = np.maximum(aa, bb)
    ok = mx > 1e-9
    return float(((bb - aa)[ok] / mx[ok]).sum() / len(X))


def est_sil(X):
    best, bk = -2, 2
    for K in range(2, min(MAXK, len(X)) + 1):
        a, C = kmeans_fp(X, K)
        s = sil_simplified(X, a, C, K)
        if s > best:
            best, bk = s, K
    return bk if best >= 0.10 else 1


def est_eig(X):
    S = (X @ X.T + 1) / 2
    np.fill_diagonal(S, 0)
    dg = np.maximum(S.sum(1), 1e-8)
    di = 1 / np.sqrt(dg)
    L = np.eye(len(X)) - di[:, None] * S * di[None]
    ev = np.linalg.eigvalsh(L)[: MAXK + 2]
    gaps = np.diff(ev)
    return int(np.argmax(gaps[1 : MAXK])) + 2  # skip trivial first gap


def est_bic(X):
    n, d = X.shape
    best, bk = -np.inf, 1
    for K in range(1, min(MAXK, n) + 1):
        a, C = kmeans_fp(X, K) if K > 1 else (np.zeros(n, int), X.mean(0, keepdims=True))
        rss = ((X - C[a]) ** 2).sum()
        var = max(rss / max(n - K, 1), 1e-12)
        ll = -0.5 * n * d * np.log(2 * np.pi * var) - 0.5 * rss / var
        bic = ll - 0.5 * (K * d + 1) * np.log(n)
        if bic > best:
            best, bk = bic, K
    return bk


def est_ahc(X, thr):
    ac = AgglomerativeClustering(n_clusters=None, distance_threshold=thr,
                                 metric='cosine', linkage='average').fit(X)
    return int(ac.n_clusters_)


names = []
results = {}
for spec in sys.argv[1:]:
    path, k = spec.rsplit('=', 1)
    X = load(path)
    name = path.split('/')[-1].split('_')[0]
    names.append((name, int(k), len(X)))
    row = {'sil': est_sil(X), 'eig': est_eig(X), 'bic': est_bic(X)}
    for thr in (0.30, 0.35, 0.40, 0.45, 0.50, 0.55, 0.60):
        row[f'ahc{thr:.2f}'] = est_ahc(X, thr)
    results[name] = row

cols = list(next(iter(results.values())).keys())
print(f'{"file":>8} {"true":>4} {"m":>4} | ' + ' '.join(f'{c:>7}' for c in cols))
for name, k, m in names:
    r = results[name]
    print(f'{name:>8} {k:>4} {m:>4} | ' + ' '.join(
        f'{"*" if r[c] == k else " "}{r[c]:>6}' for c in cols))
