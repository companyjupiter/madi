#!/usr/bin/env python3
"""Drop-in speaker-embedder oracle against Madi's exact VAD/timeline gate.

Runs the sovereign engine once per VoxConverse case with OSD disabled, keeps
its Silero-clipped speech coverage, replaces only 1.5 s speaker embeddings,
then scores both Madi auto-K and reference-K. This answers whether a model is
worth porting before adding any product runtime or asset.

Example:
  python embedder_oracle.py --model /tmp/campplus.onnx \
    --vox-id migzj --vox-id jnivh --vox-id gwtwd --out-dir runs/campplus
"""

from __future__ import annotations

import argparse
import json
import os
import struct
import subprocess
import wave
from pathlib import Path

import kaldi_native_fbank as knf
import numpy as np
import onnxruntime as ort

from diar_panel_eval import BENCH, ROOT, RUNS, VOX, VOX_AUDIO, parse_engine, score, to_wav16

SEG = 1.5
SR = 16000
SEG_SAMP = int(SEG * SR)


def load_vad_dump(path: Path) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    b = path.read_bytes()
    n, dim, fpw = struct.unpack_from("<III", b)
    off = 12
    t0 = np.frombuffer(b, "<f4", n, off).copy()
    off += 4 * n
    emb = np.frombuffer(b, "<f4", n * dim, off).reshape(n, dim).copy()
    off += 4 * n * dim
    pf = np.frombuffer(b, "<f4", n * fpw, off).reshape(n, fpw).copy()
    return t0, emb, pf


def read_pcm(path: Path) -> np.ndarray:
    with wave.open(str(path)) as w:
        assert w.getframerate() == SR and w.getnchannels() == 1 and w.getsampwidth() == 2
        return np.frombuffer(w.readframes(w.getnframes()), "<i2").astype(np.float32) / 32768.0


def fbank80(sig: np.ndarray) -> np.ndarray:
    opts = knf.FbankOptions()
    opts.frame_opts.samp_freq = SR
    opts.frame_opts.dither = 0.0
    opts.frame_opts.snip_edges = False
    opts.frame_opts.window_type = "hamming"
    opts.mel_opts.num_bins = 80
    fb = knf.OnlineFbank(opts)
    # WeSpeaker's official ONNX frontend feeds int16-scale PCM to Kaldi fbank.
    fb.accept_waveform(SR, (sig * 32768.0).tolist())
    fb.input_finished()
    out = np.asarray([fb.get_frame(i) for i in range(fb.num_frames_ready)], np.float32)
    return out - out.mean(0, keepdims=True)


def extract(sess: ort.InferenceSession, pcm: np.ndarray, t0: np.ndarray, window_sec: float) -> np.ndarray:
    name = sess.get_inputs()[0].name
    window_samples = round(window_sec * SR)
    rows = []
    for t in t0:
        # Preserve the 1.5 s output grid while giving the embedder a longer,
        # centered identity context (multiscale identity/timestamp split).
        start = round((float(t) + SEG / 2.0 - window_sec / 2.0) * SR)
        src_a, src_b = max(start, 0), min(start + window_samples, len(pcm))
        sig = pcm[src_a:src_b]
        sig = np.pad(sig, (max(0, -start), max(0, start + window_samples - len(pcm))))
        out = sess.run(None, {name: fbank80(sig)[None]})[0]
        e = np.asarray(out).reshape(-1).astype(np.float32)
        rows.append(e / (np.linalg.norm(e) + 1e-8))
    return np.asarray(rows)


def kmeans(x: np.ndarray, k: int, spherical: bool = False) -> np.ndarray:
    if k <= 1:
        return np.zeros(len(x), np.int32)
    c = np.empty((k, x.shape[1]), np.float32)
    if spherical:
        mean = x.mean(0)
        c[0] = x[np.argmax(((x - mean) ** 2).sum(1))]
    else:
        c[0] = x[0]
    dmin = ((x - c[0]) ** 2).sum(1)
    for ci in range(1, k):
        c[ci] = x[np.argmax(dmin)]
        dmin = np.minimum(dmin, ((x - c[ci]) ** 2).sum(1))
    a = np.zeros(len(x), np.int32)
    for _ in range(25):
        a = ((x[:, None] - c[None]) ** 2).sum(2).argmin(1)
        for ci in range(k):
            if np.any(a == ci):
                c[ci] = x[a == ci].sum(0)
                if spherical:
                    c[ci] /= np.linalg.norm(c[ci]) + 1e-9
                else:
                    c[ci] /= np.sum(a == ci)
    return a


def centroids(x: np.ndarray, a: np.ndarray, k: int) -> tuple[np.ndarray, np.ndarray]:
    mu = np.zeros((k, x.shape[1]), np.float32)
    cnt = np.bincount(a, minlength=k)
    for ci in range(k):
        if cnt[ci]:
            mu[ci] = x[a == ci].mean(0)
    return mu, cnt


def silhouette(x: np.ndarray, a: np.ndarray, k: int) -> float:
    mu, cnt = centroids(x, a, k)
    d = ((x[:, None] - mu[None]) ** 2).sum(2)
    own = d[np.arange(len(x)), a]
    d[np.arange(len(x)), a] = np.inf
    d[:, cnt == 0] = np.inf
    other = d.min(1)
    den = np.maximum(own, other)
    return float(np.where(den > 1e-9, (other - own) / den, 0).mean())


def max_sep(x: np.ndarray, a: np.ndarray, k: int) -> float:
    mu, cnt = centroids(x, a, k)
    mu = mu[cnt > 0]
    mu /= np.linalg.norm(mu, axis=1, keepdims=True) + 1e-9
    if len(mu) < 2:
        return 2.0
    return float(np.max(1.0 - mu @ mu.T))


def auto_k(x: np.ndarray) -> tuple[np.ndarray, int, float, float]:
    max_k = min(10, len(x), max(2, len(x) // 8))
    scored = []
    for k in range(2, max_k + 1):
        a = kmeans(x, k)
        scored.append((silhouette(x, a, k), k, a))
    sil, k, a = max(scored, key=lambda row: row[0])
    sep = max_sep(x, a, k)
    if sil < 0.35 or sep < 0.50:
        return np.zeros(len(x), np.int32), 1, sil, sep
    if 2 <= k < 4 and max_k >= 4:
        spherical = []
        for sk in range(2, max_k + 1):
            sa = kmeans(x, sk, True)
            spherical.append((silhouette(x, sa, sk), sk, sa))
        ssil, sk, sa = max(spherical, key=lambda row: row[0])
        ssep = max_sep(x, sa, sk)
        if sk == 4 and ssil >= 0.50 and ssep >= 0.50:
            return sa, 4, ssil, ssep
    return a, k, sil, sep


def coverage(path: Path) -> list[tuple[float, float]]:
    iv = []
    for line in path.read_text().splitlines():
        p = line.split()
        if p and p[0] == "SPEAKER":
            iv.append((float(p[3]), float(p[3]) + float(p[4])))
    iv.sort()
    merged = []
    for a, b in iv:
        if merged and a <= merged[-1][1] + 0.001:
            merged[-1] = (merged[-1][0], max(merged[-1][1], b))
        else:
            merged.append((a, b))
    return merged


def write_relabel(path: Path, fid: str, t0: np.ndarray, labels: np.ndarray, iv: list[tuple[float, float]]) -> None:
    pieces = []
    for t, label in zip(t0, labels):
        wa, wb = float(t), float(t) + SEG
        for a, b in iv:
            lo, hi = max(wa, a), min(wb, b)
            if hi - lo >= 0.1:
                pieces.append([lo, hi, int(label)])
    pieces.sort()
    merged = []
    for a, b, label in pieces:
        if merged and label == merged[-1][2] and a <= merged[-1][1] + 0.01:
            merged[-1][1] = max(merged[-1][1], b)
        else:
            merged.append([a, b, label])
    with path.open("w") as f:
        for a, b, label in merged:
            f.write(f"SPEAKER {fid} 1 {a:.3f} {b-a:.3f} <NA> <NA> spk{label} <NA> <NA>\n")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", required=True)
    ap.add_argument("--vox-id", action="append", default=[])
    ap.add_argument("--vox-all", action="store_true")
    ap.add_argument("--ref-k", type=int, help="filter Vox cases by reference speaker count")
    ap.add_argument("--window-sec", type=float, default=SEG)
    ap.add_argument("--out-dir", default=str(RUNS / "embedder_oracle"))
    args = ap.parse_args()
    out = Path(args.out_dir)
    out.mkdir(parents=True, exist_ok=True)
    sess = ort.InferenceSession(args.model, providers=["CPUExecutionProvider"])
    ids = list(args.vox_id)
    if args.vox_all:
        ids.extend(p.stem for p in sorted(VOX.glob("*.rttm")))
    if args.ref_k is not None:
        ids = [fid for fid in ids if len({line.split()[7] for line in (VOX / f"{fid}.rttm").read_text().splitlines() if line.startswith("SPEAKER")}) == args.ref_k]
    if not ids:
        ap.error("pass --vox-id or --vox-all (and ensure --ref-k matches)")
    records = []
    for fid in dict.fromkeys(ids):
        src, ref = VOX_AUDIO / f"{fid}.wav", VOX / f"{fid}.rttm"
        wav, dump, base = out / f"{fid}.wav", out / f"{fid}.vad.bin", out / f"{fid}.base.rttm"
        to_wav16(src, wav)
        env = {**os.environ, "DIAR_ONLY": "1", "OSD": "0", "VAD_DUMP": str(dump)}
        p = subprocess.run([
            str(ROOT / "out/transcribe"), str(ROOT / "assets/model.safetensors"), str(wav),
            str(ROOT / "assets/WHISPER_BPE.bin"), str(base),
        ], cwd=ROOT, env=env, text=True, capture_output=True, check=True)
        t0, sovereign_emb, pf = load_vad_dump(dump)
        keep = ((pf >= 0.5).sum(1) * 0.032) >= 0.15
        kt = t0[keep]
        x = extract(sess, read_pcm(wav), kt, args.window_sec)
        sx = sovereign_emb[keep]
        sx /= np.linalg.norm(sx, axis=1, keepdims=True) + 1e-8
        self_a, self_n, self_sil, self_sep = auto_k(sx)
        auto_a, auto_n, sil, sep = auto_k(x)
        true_k = len({line.split()[7] for line in ref.read_text().splitlines() if line.startswith("SPEAKER")})
        forced_a = kmeans(x, min(true_k, len(x)))
        cov = coverage(base)
        self_rttm = out / f"{fid}.selfcheck.rttm"
        auto_rttm, forced_rttm = out / f"{fid}.auto.rttm", out / f"{fid}.forced.rttm"
        write_relabel(self_rttm, fid, kt, self_a, cov)
        write_relabel(auto_rttm, fid, kt, auto_a, cov)
        write_relabel(forced_rttm, fid, kt, forced_a, cov)
        rec = {
            "id": fid, "windows": len(x), "ref_k": true_k,
            "baseline": {**parse_engine(p.stdout), **score(ref, base)},
            "selfcheck": {"k": self_n, "sil": round(self_sil, 4), "sep": round(self_sep, 4), **score(ref, self_rttm)},
            "candidate_auto": {"k": auto_n, "sil": round(sil, 4), "sep": round(sep, 4), **score(ref, auto_rttm)},
            "candidate_forced": {"k": true_k, **score(ref, forced_rttm)},
        }
        records.append(rec)
        print(json.dumps(rec, ensure_ascii=False))
    (out / "results.json").write_text(json.dumps(records, ensure_ascii=False, indent=2) + "\n")


if __name__ == "__main__":
    main()
