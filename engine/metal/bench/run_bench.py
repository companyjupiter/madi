#!/usr/bin/env python3
# Multi-file diarization DER benchmark (VoxConverse dev + AMI). Honors DIAR_*
# env vars (passed through to ./out/transcribe) so the tuning loop can sweep
# params without rebuilding. Prints per-file DER + mean (overall + by spk-count).
import os, sys, subprocess, glob, json, statistics
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # metal/
BENCH_SAMPLES = os.path.expanduser(os.environ.get("MADI_BENCH_SAMPLES", "bench/data"))
VOX = os.path.join(BENCH_SAMPLES, "voxconverse")
AUDIO = os.path.join(BENCH_SAMPLES, "audio")
MODEL = os.path.join(ROOT, "assets/model.safetensors")
BPE = os.path.join(ROOT, "assets/WHISPER_BPE.bin")
TR = os.path.join(ROOT, "out/transcribe")
MDEVAL = os.path.join(ROOT, "bench/md-eval.pl")

def nspk(rttm): return len({l.split()[7] for l in open(rttm) if l.startswith("SPEAKER")})

def der(ref, sysr):
    out = subprocess.run(["perl", MDEVAL, "-c", "0.25", "-r", ref, "-s", sysr],
                         capture_output=True, text=True).stdout
    for L in out.splitlines():
        if "OVERALL SPEAKER DIARIZATION ERROR" in L:
            return float(L.split("=")[1].split()[0])
    return None

def run_one(id_):
    wav = os.path.join(AUDIO, id_ + ".wav")
    ref = os.path.join(VOX, "dev", id_ + ".rttm")
    if not (os.path.exists(wav) and os.path.exists(ref)): return None
    tmp = f"/tmp/{id_}.wav"
    subprocess.run(["ffmpeg", "-y", "-i", wav, "-ar", "16000", "-ac", "1", tmp],
                   capture_output=True)
    sysr = f"/tmp/{id_}.sys.rttm"
    subprocess.run([TR, MODEL, tmp, BPE, sysr], capture_output=True, env={**os.environ})
    return der(ref, sysr), nspk(ref)

def pick_subset(n=12):
    # diverse by ground-truth speaker count
    ids = [os.path.basename(p)[:-5] for p in glob.glob(os.path.join(VOX, "dev", "*.rttm"))]
    ids = [i for i in ids if os.path.exists(os.path.join(AUDIO, i + ".wav"))]
    ids.sort(key=lambda i: (nspk(os.path.join(VOX, "dev", i + ".rttm")), i))
    if not ids: return []
    step = max(1, len(ids)//n)
    return ids[::step][:n]

ids = sys.argv[1:] if len(sys.argv) > 1 else (json.load(open("/tmp/bench_subset.json")) if os.path.exists("/tmp/bench_subset.json") else pick_subset())
print(f"benchmark: {len(ids)} files | params: " +
      " ".join(f"{k}={v}" for k,v in os.environ.items() if k.startswith("DIAR")))
results = []
for i in ids:
    r = run_one(i)
    if r is None: print(f"  {i}: (missing)"); continue
    d, k = r
    print(f"  {i}: DER={d:5.1f}%  (gt {k} spk)")
    results.append((i, d, k))
if results:
    ds = [d for _, d, _ in results]
    print(f"\nMEAN DER = {statistics.mean(ds):.2f}%  (median {statistics.median(ds):.1f}, n={len(ds)})")
    json.dump([i for i, _, _ in results], open("/tmp/bench_subset.json", "w"))
