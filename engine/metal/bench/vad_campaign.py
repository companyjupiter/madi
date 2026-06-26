#!/usr/bin/env python3
# VAD_PROB sweep campaign — DER per asset across the Silero speech-probability
# threshold, for the per-language × per-speaker-count study. Faithful: runs the
# REAL engine (DIAR_ONLY, auto-K) so OSD overlap rows + silero clipping are in
# the loop. Resume-safe: each (prob, fid) result is appended to JSONL immediately.
#
#   python3 bench/vad_campaign.py                  # default prob grid
#   VAD_PROBS=0.5,0.6 python3 bench/vad_campaign.py
#
# Output: bench/runs/vad_campaign.jsonl  {prob, fid, group, nspk_ref, bucket, der}
# Durable on the repo disk (NEVER /tmp — a macOS cleanup once cost a day).
import os, glob, subprocess, json, sys, time, fcntl

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)                       # metal/
RUNS = os.path.join(HERE, "runs")
SCRATCH = os.path.join(RUNS, "vad_scratch")
os.makedirs(SCRATCH, exist_ok=True)
DUMPDIR = os.path.join(RUNS, "vad_dumps")
os.makedirs(DUMPDIR, exist_ok=True)

_lock = open(os.path.join(RUNS, "vad_campaign.lock"), "w")
try:
    fcntl.flock(_lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
except OSError:
    sys.exit("another vad_campaign.py is running — refusing to race it")

MODEL = os.path.join(ROOT, "assets/model.safetensors")
BPE = os.path.join(ROOT, "assets/WHISPER_BPE.bin")
TR = os.path.join(ROOT, "out/transcribe")
MDEVAL = os.path.join(HERE, "md-eval.pl")
BS = os.path.expanduser("~/Downloads/benchmark_samples")
VOX_AUDIO = os.path.join(BS, "audio")
VOX_REF = os.path.join(BS, "voxconverse/dev")
RESULTS = os.path.join(RUNS, "vad_campaign.jsonl")

PROBS = [float(x) for x in os.environ.get("VAD_PROBS", "0.2,0.35,0.5,0.65,0.8,0.9").split(",")]
DUMP_AT = float(os.environ.get("VAD_DUMP_AT", "0.5"))  # write VAD_DUMP on this pass

def nspk(rttm):
    return len({l.split()[7] for l in open(rttm) if l.startswith("SPEAKER")})

def bucket(k):
    return "1" if k == 1 else "2" if k == 2 else "multi"

def der(ref, sysr):
    out = subprocess.run(["perl", MDEVAL, "-c", "0.25", "-r", ref, "-s", sysr],
                         capture_output=True, text=True).stdout
    for L in out.splitlines():
        if "OVERALL SPEAKER DIARIZATION ERROR" in L:
            return float(L.split("=")[1].split()[0])
    return None

# ---- asset table: (fid, group, wav, ref) ----
assets = []
for r in sorted(glob.glob(os.path.join(VOX_REF, "*.rttm"))):
    fid = os.path.basename(r)[:-5]
    w = os.path.join(VOX_AUDIO, fid + ".wav")
    if os.path.exists(w):
        assets.append((fid, "vox", w, r))
ami_wav = os.path.join(BS, "ES2004a.wav")
ami_ref = os.path.join(BS, "ES2004a_gt_full.rttm")
if os.path.exists(ami_wav):
    assets.append(("ES2004a", "ami", ami_wav, ami_ref))
for n in ("ko1", "ko2", "ko4"):
    w = os.path.join(HERE, n + ".wav"); r = os.path.join(HERE, n + ".ref.rttm")
    if os.path.exists(w):
        assets.append((n, "ko", w, r))

refk = {fid: nspk(r) for fid, _, _, r in assets}

done = set()
if os.path.exists(RESULTS):
    for l in open(RESULTS):
        if l.strip():
            d = json.loads(l); done.add((d["prob"], d["fid"]))

total = len(PROBS) * len(assets)
print(f"[campaign] {len(assets)} assets × {len(PROBS)} probs = {total}; {len(done)} done; probs={PROBS}")
t0 = time.time(); n = 0
with open(RESULTS, "a") as out:
    for prob in PROBS:
        for fid, group, wav, ref in assets:
            n += 1
            if (prob, fid) in done:
                continue
            sysr = os.path.join(SCRATCH, f"{fid}_p{prob}.rttm")
            env = {**os.environ, "DIAR_ONLY": "1", "VAD_PROB": str(prob)}
            if abs(prob - DUMP_AT) < 1e-9:
                env["VAD_DUMP"] = os.path.join(DUMPDIR, f"{fid}.bin")
            subprocess.run([TR, MODEL, wav, BPE, sysr], env=env, capture_output=True)
            d = der(ref, sysr) if os.path.exists(sysr) else None
            k = refk[fid]
            rec = {"prob": prob, "fid": fid, "group": group, "nspk_ref": k,
                   "bucket": bucket(k), "der": d}
            out.write(json.dumps(rec) + "\n"); out.flush()
            if n % 20 == 0:
                el = time.time() - t0
                print(f"  {n}/{total}  {el:.0f}s  last={fid} p={prob} der={d}", flush=True)
print(f"[campaign] done in {(time.time()-t0)/60:.1f} min → {RESULTS}")
