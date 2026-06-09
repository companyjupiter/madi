#!/usr/bin/env python3
# One diarization-tuning iteration: run the next untried (tau, maxK, VAD) combo
# over the VoxConverse benchmark, record mean DER, track best. Driven repeatedly
# by the autonomous /loop. Prints DONE when the grid is exhausted.
import json, os, subprocess, sys
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STATE = "/tmp/tune_state.json"
LOG = os.path.join(ROOT, "bench/TUNING_LOG.md")
PY = "/tmp/diarvenv/bin/python"

grid = [{"DIAR_SIL_TAU": t, "DIAR_MAXK": k, "DIAR_VAD": v}
        for t in ("0.05", "0.10", "0.15")
        for k in ("6", "8", "10")
        for v in ("0.20", "0.30", "0.40")]

st = json.load(open(STATE)) if os.path.exists(STATE) else {"done": [], "best": None, "n": 0}

for combo in grid:
    key = " ".join(f"{a}={b}" for a, b in combo.items())
    if key in st["done"]:
        continue
    out = subprocess.run([PY, os.path.join(ROOT, "bench/run_bench.py")],
                         capture_output=True, text=True, env={**os.environ, **combo}).stdout
    der = next((float(L.split("=")[1].split("%")[0]) for L in out.splitlines() if "MEAN DER" in L), None)
    st["done"].append(key); st["n"] += 1
    if der is not None and (st["best"] is None or der < st["best"]["der"]):
        st["best"] = {"key": key, "der": der}
    json.dump(st, open(STATE, "w"))
    b = st["best"]
    line = f"| {st['n']:2d} | {key} | {der}% | **best {b['der']}%** ({b['key']}) |"
    open(LOG, "a").write(line + "\n")
    print(line)
    sys.exit(0)

print(f"DONE — grid exhausted ({st['n']} runs). BEST: {st['best']}")
