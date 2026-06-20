#!/usr/bin/env python3
"""Auto-K estimator shoot-out on VoxConverse-dev diar_embed_wav dumps.

Usage: k_study_vox.py /tmp/voxk ~/Downloads/benchmark_samples/voxconverse/dev
Dump format (diar_embed_wav.zig): u32 n, then n × [f32 t0, f32 emb[256]]
(already VAD-filtered). Ground-truth K = distinct speakers in the ref rttm.
Estimators: sil (shipped), rsil (sil + recursive 2-way split at sub-sil ≥ tau),
eig (Laplacian eigengap), nmesc (p-binarized NME-SC, simplified).
Reports exact / ±1 accuracy and MAE bucketed by true K.
"""
import glob, os, struct, sys

import numpy as np

MAXK = 6
CAP = 400  # subsample cap per file (k-means O(n²) bits get slow on 1h files)


def load(path):
    b = open(path, 'rb').read()
    n = struct.unpack('<I', b[:4])[0]
    rec = np.frombuffer(b, '<f4', n * 257, 4).reshape(n, 257)
    X = rec[:, 1:].astype(np.float64)
    X /= np.linalg.norm(X, axis=1, keepdims=True) + 1e-8
    if len(X) > CAP:
        idx = np.linspace(0, len(X) - 1, CAP).astype(int)
        X = X[idx]
    return X


def kmeans_fp(X, K, iters=30):
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


def sil(X, a, C, K):
    if K < 2 or len(X) < 2:
        return -2
    d2 = ((X[:, None] - C[None]) ** 2).sum(-1)
    aa = d2[np.arange(len(X)), a]
    d2[np.arange(len(X)), a] = np.inf
    bb = d2.min(1)
    mx = np.maximum(aa, bb)
    ok = mx > 1e-9
    return float(((bb - aa)[ok] / mx[ok]).sum() / len(X))


def est_sil(X, tau=0.10):
    best, bk, ba = -2, 2, None
    for K in range(2, min(MAXK, len(X)) + 1):
        a, C = kmeans_fp(X, K)
        s = sil(X, a, C, K)
        if s > best:
            best, bk, ba = s, K, a
    return (1, None) if best < tau else (bk, ba)


def est_rsil(X, tau=0.10, sub_tau=0.50, min_sub=6, min_half=3):
    bk, ba = est_sil(X, tau)
    if ba is None:
        return bk
    total = bk
    for c in range(bk):
        sub = X[ba == c]
        if len(sub) < min_sub:
            continue
        a2, C2 = kmeans_fp(sub, 2)
        if sil(sub, a2, C2, 2) >= sub_tau and min((a2 == 0).sum(), (a2 == 1).sum()) >= min_half:
            total += 1
    return total


def est_eig(X):
    S = (X @ X.T + 1) / 2
    np.fill_diagonal(S, 0)
    di = 1 / np.sqrt(np.maximum(S.sum(1), 1e-8))
    L = np.eye(len(X)) - di[:, None] * S * di[None]
    ev = np.linalg.eigvalsh(L)[: MAXK + 1]
    gaps = np.diff(ev)
    return int(np.argmax(gaps[1:MAXK])) + 2


def est_nmesc(X):
    n = len(X)
    S = (X @ X.T + 1) / 2
    np.fill_diagonal(S, 0)
    best_r, best_K = np.inf, 1
    for frac in (0.05, 0.1, 0.15, 0.2, 0.3, 0.4, 0.5):
        p = max(2, int(n * frac))
        A = np.zeros_like(S)
        idx = np.argsort(-S, axis=1)[:, :p]
        for i in range(n):
            A[i, idx[i]] = 1
        A = np.maximum(A, A.T) * S
        di = 1 / np.sqrt(np.maximum(A.sum(1), 1e-8))
        L = np.eye(n) - di[:, None] * A * di[None]
        ev = np.linalg.eigvalsh(L)[: MAXK + 1]
        gaps = np.diff(ev)
        k_cand = int(np.argmax(gaps[1:MAXK])) + 2
        r = (p / n) / max(gaps[k_cand - 1], 1e-9)
        if r < best_r:
            best_r, best_K = r, k_cand
    return best_K


dumps, refdir = sys.argv[1], os.path.expanduser(sys.argv[2])
rows = []
for f in sorted(glob.glob(os.path.join(dumps, '*.emb'))):
    id_ = os.path.basename(f)[:-4]
    ref = os.path.join(refdir, id_ + '.rttm')
    if not os.path.exists(ref):
        continue
    gt = len({l.split()[7] for l in open(ref) if l.startswith('SPEAKER')})
    X = load(f)
    if len(X) < 3:
        continue
    rows.append((id_, gt, est_sil(X)[0], est_rsil(X), est_eig(X), est_nmesc(X)))
    if len(rows) % 40 == 0:
        print(f'  …{len(rows)} files', file=sys.stderr)

names = ['sil', 'rsil', 'eig', 'nmesc']
print(f'files: {len(rows)}   (gt capped at {MAXK} for scoring — estimator max is {MAXK})')
gts = np.array([min(r[1], MAXK) for r in rows])
for i, nm in enumerate(names):
    est = np.array([r[2 + i] for r in rows])
    print(f'{nm:>6}: exact {np.mean(est == gts) * 100:5.1f}%  ±1 {np.mean(abs(est - gts) <= 1) * 100:5.1f}%  '
          f'MAE {np.mean(abs(est - gts)):.2f}  over {np.mean(est > gts) * 100:4.1f}%  under {np.mean(est < gts) * 100:4.1f}%')
print('\nby true K (n, sil/rsil/eig/nmesc exact%):')
for k in range(1, 8):
    sel = [r for r in rows if min(r[1], MAXK) == min(k, MAXK) and r[1] == k]
    if not sel:
        continue
    accs = [f'{np.mean([min(r[1], MAXK) == r[2 + i] for r in sel]) * 100:4.0f}' for i in range(4)]
    print(f'  K={k}: n={len(sel):3d}  ' + ' / '.join(accs))
