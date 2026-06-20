#!/usr/bin/env python3
"""Sweep silhouette-tau (K=1 gate) and recursive-split sub-tau on VoxConverse.

Usage: k_sweep_vox.py /tmp/voxk ~/Downloads/benchmark_samples/voxconverse/dev
Caches per-file (bestSil, bestK, per-cluster sub-sils, gt) so the sweeps are
instant. Reports exact-match for the silhouette estimator under each tau, and
for sil+split under each sub_tau (with the best tau).
"""
import glob, json, os, struct, sys

import numpy as np

MAXK = 6
CAP = 400
import os as _os
_RUNS = _os.path.join(_os.path.dirname(_os.path.dirname(_os.path.abspath(__file__))), 'bench/runs')
_os.makedirs(_RUNS, exist_ok=True)
CACHE = _os.path.join(_RUNS, 'voxk_cache.jsonl')  # durable: /tmp cleanup once cost a day


def load(path):
    b = open(path, 'rb').read()
    n = struct.unpack('<I', b[:4])[0]
    rec = np.frombuffer(b, '<f4', n * 257, 4).reshape(n, 257)
    X = rec[:, 1:].astype(np.float64)
    X /= np.linalg.norm(X, axis=1, keepdims=True) + 1e-8
    if len(X) > CAP:
        X = X[np.linspace(0, len(X) - 1, CAP).astype(int)]
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
        return -2.0
    d2 = ((X[:, None] - C[None]) ** 2).sum(-1)
    aa = d2[np.arange(len(X)), a]
    d2[np.arange(len(X)), a] = np.inf
    bb = d2.min(1)
    mx = np.maximum(aa, bb)
    ok = mx > 1e-9
    return float(((bb - aa)[ok] / mx[ok]).sum() / len(X))


def analyze(X):
    best, bk, ba = -2.0, 2, None
    for K in range(2, min(MAXK, len(X)) + 1):
        a, C = kmeans_fp(X, K)
        s = sil(X, a, C, K)
        if s > best:
            best, bk, ba = s, K, a
    subs = []
    for c in range(bk):
        sub = X[ba == c]
        if len(sub) < 6:
            subs.append(-2.0)
            continue
        a2, C2 = kmeans_fp(sub, 2)
        s2 = sil(sub, a2, C2, 2) if min((a2 == 0).sum(), (a2 == 1).sum()) >= 3 else -2.0
        subs.append(s2)
    return best, bk, subs


dumps, refdir = sys.argv[1], os.path.expanduser(sys.argv[2])
cache = {}
if os.path.exists(CACHE):
    for l in open(CACHE):
        r = json.loads(l)
        cache[r['id']] = r

rows = []
for f in sorted(glob.glob(os.path.join(dumps, '*.emb'))):
    id_ = os.path.basename(f)[:-4]
    ref = os.path.join(refdir, id_ + '.rttm')
    if not os.path.exists(ref):
        continue
    if id_ in cache:
        rows.append(cache[id_])
        continue
    gt = len({l.split()[7] for l in open(ref) if l.startswith('SPEAKER')})
    X = load(f)
    if len(X) < 3:
        continue
    best, bk, subs = analyze(X)
    r = {'id': id_, 'gt': gt, 'sil': best, 'k': bk, 'subs': subs}
    open(CACHE, 'a').write(json.dumps(r) + '\n')
    rows.append(r)
    if len(rows) % 40 == 0:
        print(f'  …{len(rows)}', file=sys.stderr)

gts = np.array([min(r['gt'], MAXK) for r in rows])
print(f'files: {len(rows)}')
print('\ntau sweep (sil estimator, K=1 below tau):')
for tau in (0.10, 0.15, 0.20, 0.25, 0.30, 0.35, 0.40):
    est = np.array([1 if r['sil'] < tau else r['k'] for r in rows])
    k1 = [(r['sil'] < tau) == (r['gt'] == 1) for r in rows if r['gt'] == 1]
    fp1 = sum(1 for r in rows if r['sil'] < tau and r['gt'] > 1)
    print(f'  tau={tau:.2f}: exact {np.mean(est == gts)*100:5.1f}%  MAE {np.mean(abs(est-gts)):.2f}  '
          f'K1-recall {np.mean(k1)*100 if k1 else 0:4.0f}%  K1-falsepos {fp1}')
print('\nsub_tau sweep (split each cluster with sub-sil ≥ sub_tau; tau=0.10):')
for st in (0.45, 0.50, 0.55, 0.60, 0.65, 0.70, 0.75, 0.80):
    est = []
    for r in rows:
        k = 1 if r['sil'] < 0.10 else r['k']
        if r['sil'] >= 0.10:
            k = min(k + sum(1 for s in r['subs'] if s >= st), MAXK)
        est.append(k)
    est = np.array(est)
    print(f'  sub_tau={st:.2f}: exact {np.mean(est == gts)*100:5.1f}%  MAE {np.mean(abs(est-gts)):.2f}  '
          f'over {np.mean(est > gts)*100:4.1f}%  under {np.mean(est < gts)*100:4.1f}%')
