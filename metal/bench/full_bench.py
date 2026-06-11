#!/usr/bin/env python3
# Full VoxConverse-dev diarization DER benchmark (all 216 files w/ audio), with
# the shipped tuned defaults (auto-K, maxK=6, vad=0.40). Resumable + incremental:
# each file's result is appended to RESULTS jsonl immediately, so a kill/restart
# skips finished files. Final summary → bench/FULL_BENCH_RESULT.md.
import os, glob, subprocess, json, statistics, time, sys, fcntl, tempfile
_lock = open('/tmp/full_bench.lock', 'w')
try:
    fcntl.flock(_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit('another full_bench.py is running — refusing to race it')
RTTM_DIR = tempfile.mkdtemp(prefix='fb_rttm_')
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # metal/
VOX = os.path.expanduser("~/Downloads/benchmark_samples/voxconverse")
AUDIO = os.path.expanduser("~/Downloads/benchmark_samples/audio")
MODEL = os.path.join(ROOT, "assets/model.safetensors")
BPE = os.path.join(ROOT, "assets/WHISPER_BPE.bin")
TR = os.path.join(ROOT, "out/transcribe")
MDEVAL = os.path.join(ROOT, "bench/md-eval.pl")
RESULTS = os.environ.get("BENCH_RESULTS", "/tmp/full_bench_results.jsonl")
SUMMARY = os.environ.get("BENCH_SUMMARY", os.path.join(ROOT, "bench/FULL_BENCH_RESULT.md"))

def nspk(r): return len({l.split()[7] for l in open(r) if l.startswith("SPEAKER")})
def der(ref, sysr):
    out = subprocess.run(["perl", MDEVAL, "-c", "0.25", "-r", ref, "-s", sysr],
                         capture_output=True, text=True).stdout
    for L in out.splitlines():
        if "OVERALL SPEAKER DIARIZATION ERROR" in L:
            return float(L.split("=")[1].split()[0])
    return None

ids = sorted(os.path.basename(p)[:-5] for p in glob.glob(os.path.join(VOX, "dev", "*.rttm"))
             if os.path.exists(os.path.join(AUDIO, os.path.basename(p)[:-5] + ".wav")))
done = set()
if os.path.exists(RESULTS):
    done = {json.loads(l)["id"] for l in open(RESULTS) if l.strip()}

t0 = time.time()
print(f"full bench: {len(ids)} files ({len(done)} already done) — defaults auto-K maxK=6 vad=0.40", flush=True)
for i, id_ in enumerate(ids):
    if id_ in done:
        continue
    wav, ref = os.path.join(AUDIO, id_ + ".wav"), os.path.join(VOX, "dev", id_ + ".rttm")
    tmp, sysr = os.path.join(RTTM_DIR, id_ + ".wav"), os.path.join(RTTM_DIR, id_ + ".sys.rttm")
    subprocess.run(["ffmpeg", "-y", "-i", wav, "-ar", "16000", "-ac", "1", tmp], capture_output=True)
    subprocess.run([TR, MODEL, tmp, BPE, sysr], capture_output=True,
                   env={**os.environ, "DIAR_ONLY": "1"})  # DER needs diar only (~20x faster)
    d, k = der(ref, sysr), nspk(ref)
    rec = {"id": id_, "der": d, "nspk": k}
    open(RESULTS, "a").write(json.dumps(rec) + "\n")
    try: os.remove(tmp)
    except OSError: pass
    el = time.time() - t0
    print(f"[{i+1:3d}/{len(ids)}] {id_}: DER={d}%  (gt {k} spk)  | {el/60:.1f}min elapsed", flush=True)

# summary
recs = [json.loads(l) for l in open(RESULTS) if l.strip()]
recs = [r for r in recs if r["der"] is not None]
ds = [r["der"] for r in recs]
lines = ["# Full VoxConverse-dev DER (all files, tuned defaults auto-K/maxK=6/vad=0.40)", "",
         f"- files scored: **{len(ds)}**", f"- **MEAN DER = {statistics.mean(ds):.2f}%**  (median {statistics.median(ds):.2f}%)",
         f"- pyannote 3.1 reference ≈ 11.2%; our 12-file subset was 9.67%", "",
         "| gt speakers | n | mean DER |", "|---|---|---|"]
buckets = {}
for r in recs:
    b = r["nspk"] if r["nspk"] <= 4 else (5 if r["nspk"] <= 6 else 7)
    buckets.setdefault(b, []).append(r["der"])
for b in sorted(buckets):
    lab = {7: "7+"}.get(b, str(b)) if b != 5 else "5-6"
    lines.append(f"| {lab} | {len(buckets[b])} | {statistics.mean(buckets[b]):.2f}% |")
worst = sorted(recs, key=lambda r: -r["der"])[:10]
lines += ["", "### 10 worst files", "| id | DER | spk |", "|---|---|---|"]
lines += [f"| {r['id']} | {r['der']}% | {r['nspk']} |" for r in worst]
open(SUMMARY, "w").write("\n".join(lines) + "\n")
print(f"\nDONE — MEAN DER {statistics.mean(ds):.2f}% over {len(ds)} files → {SUMMARY}", flush=True)
