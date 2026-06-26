#!/usr/bin/env python3
# Analyze vad_campaign.jsonl: mean DER per (language-domain × speaker-bucket)
# across VAD_PROB, find the optimum + a robust operating range per cell.
#   python3 bench/vad_analyze.py            # full table
#   python3 bench/vad_analyze.py --json     # machine-readable per-cell optima
import json, os, sys, collections, statistics

HERE = os.path.dirname(os.path.abspath(__file__))
RESULTS = os.path.join(HERE, "runs", "vad_campaign.jsonl")

# language-domain: vox=EN conversational, ami=EN far-field meeting, ko=KO TTS
DOMAIN = {"vox": "EN-conv", "ami": "EN-farfield", "ko": "KO"}

rows = [json.loads(l) for l in open(RESULTS) if l.strip()]
# cell = (domain, bucket); collect der per prob (mean over files in the cell)
cells = collections.defaultdict(lambda: collections.defaultdict(list))
for r in rows:
    if r["der"] is None:
        continue
    dom = DOMAIN.get(r["group"], r["group"])
    cells[(dom, r["bucket"])][r["prob"]].append(r["der"])

probs = sorted({r["prob"] for r in rows})
order = [("EN-conv", "1"), ("EN-conv", "2"), ("EN-conv", "multi"),
         ("EN-farfield", "multi"), ("KO", "1"), ("KO", "2"), ("KO", "multi")]

def fmt(x): return f"{x:6.2f}" if x is not None else "   -- "

optima = {}
print(f"\n{'cell':<22} {'n':>3} | " + " ".join(f"p={p:<4}" for p in probs) + " | best")
print("-" * (28 + 8 * len(probs)))
seen = set()
for cell in order + [c for c in cells if c not in order]:
    if cell not in cells or cell in seen:
        continue
    seen.add(cell)
    dom, bk = cell
    perp = {p: (statistics.mean(v) if v else None) for p, v in cells[cell].items()}
    nfiles = max((len(v) for v in cells[cell].values()), default=0)
    means = [perp.get(p) for p in probs]
    valid = [(p, perp[p]) for p in probs if perp.get(p) is not None]
    best_p, best_d = (min(valid, key=lambda x: x[1]) if valid else (None, None))
    # robust range: probs within +0.5pp of best
    rng = [p for p, d in valid if best_d is not None and d <= best_d + 0.5]
    optima[f"{dom}/{bk}"] = {"best_prob": best_p, "best_der": best_d,
                             "robust_range": [min(rng), max(rng)] if rng else None,
                             "n_files": nfiles, "curve": {str(p): perp.get(p) for p in probs}}
    line = f"{dom+'/'+bk:<22} {nfiles:>3} | " + " ".join(fmt(m) for m in means)
    line += f" | {best_p} ({fmt(best_d).strip()})  range {rng}"
    print(line)

# overall VoxConverse mean (all 216, parity with history ~8.5%)
vox = collections.defaultdict(list)
for r in rows:
    if r["group"] == "vox" and r["der"] is not None:
        vox[r["prob"]].append(r["der"])
print("\nVoxConverse-all mean DER by prob (history ref ~8.5% @ prob=0.5):")
for p in probs:
    if vox[p]:
        print(f"  p={p}: {statistics.mean(vox[p]):.2f}%  (n={len(vox[p])})")

if "--json" in sys.argv:
    print("\n" + json.dumps(optima, indent=2, ensure_ascii=False))
