#!/usr/bin/env python3
# Re-score the saved campaign RTTMs to extract MISS / FALARM / CONFUSION
# components (md-eval only stored OVERALL). Explains the mechanism behind each
# cell's VAD_PROB optimum (high prob → less FA but more MISS on quiet speech).
# Parallel (CPU). → bench/runs/vad_components.jsonl
import os, glob, json, subprocess, re
from multiprocessing import Pool

HERE = os.path.dirname(os.path.abspath(__file__))
SCRATCH = os.path.join(HERE, "runs", "vad_scratch")
MDEVAL = os.path.join(HERE, "md-eval.pl")
BS = os.path.expanduser(os.environ.get("MADI_BENCH_SAMPLES", "bench/data"))
VOX_REF = os.path.join(BS, "voxconverse/dev")
CAMP = os.path.join(HERE, "runs", "vad_campaign.jsonl")
OUT = os.path.join(HERE, "runs", "vad_components.jsonl")

meta = {}  # fid -> (group, bucket, nspk)
for l in open(CAMP):
    d = json.loads(l)
    meta[d["fid"]] = (d["group"], d["bucket"], d["nspk_ref"])

def ref_for(fid):
    if fid == "ES2004a": return os.path.join(BS, "ES2004a_gt_full.rttm")
    if fid in ("ko1", "ko2", "ko4"): return os.path.join(HERE, fid + ".ref.rttm")
    return os.path.join(VOX_REF, fid + ".rttm")

PAT = {"scored": r"SCORED SPEAKER TIME *=([\d.]+)",
       "miss": r"MISSED SPEAKER TIME *=([\d.]+)",
       "fa": r"FALARM SPEAKER TIME *=([\d.]+)",
       "conf": r"SPEAKER ERROR TIME *=([\d.]+)"}

def score(path):
    base = os.path.basename(path)[:-5]               # e.g. afjiv_p0.5
    m = re.match(r"(.+)_p([\d.]+)$", base)
    if not m: return None
    fid, prob = m.group(1), float(m.group(2))
    if fid not in meta: return None
    ref = ref_for(fid)
    out = subprocess.run(["perl", MDEVAL, "-c", "0.25", "-r", ref, "-s", path],
                         capture_output=True, text=True).stdout
    vals = {}
    for k, p in PAT.items():
        mm = re.search(p, out)
        vals[k] = float(mm.group(1)) if mm else None
    der = None
    mm = re.search(r"OVERALL SPEAKER DIARIZATION ERROR = ([\d.]+)", out)
    if mm: der = float(mm.group(1))
    g, bk, k = meta[fid]
    return {"prob": prob, "fid": fid, "group": g, "bucket": bk, "nspk_ref": k,
            "scored": vals["scored"], "miss": vals["miss"], "fa": vals["fa"],
            "conf": vals["conf"], "der": der}

if __name__ == "__main__":
    paths = sorted(glob.glob(os.path.join(SCRATCH, "*.rttm")))
    with Pool(os.cpu_count()) as pool:
        res = [r for r in pool.map(score, paths) if r]
    with open(OUT, "w") as f:
        for r in res:
            f.write(json.dumps(r) + "\n")
    print(f"scored {len(res)} rttms → {OUT}")
