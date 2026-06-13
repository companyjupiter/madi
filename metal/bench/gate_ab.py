#!/usr/bin/env python3
# Clean A/B for the solo-speaker over-split gate: SAME binary, gate ON
# (DIAR_MIN_SEP=0.50) vs OFF (DIAR_MIN_SEP=-1, never fires). Isolates the gate's
# effect from config drift (the committed FULL_BENCH_RESULT.md used maxK=10) and
# from GPU FP run-to-run wobble. Reports overall + per-gt-bucket mean DER and the
# per-file files the gate actually changed (|ΔDER|>0.5pt) with their gt speaker
# count — so a wrongly-collapsed REAL multi-speaker file is caught loudly.
import json, sys, statistics
def load(p): return {d["id"]: d for d in (json.loads(l) for l in open(p) if l.strip())}
on  = load("bench/runs/gate_bench_results.jsonl")
off = load("bench/runs/nogate_bench_results.jsonl")
ids = sorted(set(on) & set(off))
def bucket(n): return n if n <= 2 else (3 if n == 3 else (4 if n == 4 else ("5-6" if n <= 6 else "7+")))
print(f"matched files: {len(ids)}  (on={len(on)} off={len(off)})")
mo = statistics.mean(on[i]["der"] for i in ids)
mf = statistics.mean(off[i]["der"] for i in ids)
print(f"MEAN DER:  OFF {mf:.2f}%  ->  ON {mo:.2f}%   (Δ {mo-mf:+.2f}pt)")
print(f"MEDIAN:    OFF {statistics.median(off[i]['der'] for i in ids):.2f}%  ->  ON {statistics.median(on[i]['der'] for i in ids):.2f}%")
print("\nper gt-speaker bucket (n / OFF / ON / Δ):")
from collections import defaultdict
bk = defaultdict(list)
for i in ids: bk[bucket(on[i]["nspk"])].append(i)
for b in [1,2,3,4,"5-6","7+"]:
    g = bk.get(b, [])
    if not g: continue
    bo = statistics.mean(off[i]["der"] for i in g); bn = statistics.mean(on[i]["der"] for i in g)
    print(f"  gt={b:<4} n={len(g):<3} OFF {bo:6.2f}%  ON {bn:6.2f}%  Δ {bn-bo:+6.2f}pt")
print("\nfiles the gate CHANGED (|ΔDER|>0.5pt), sorted by Δ:")
chg = sorted(((on[i]["der"]-off[i]["der"], i) for i in ids if abs(on[i]["der"]-off[i]["der"])>0.5), key=lambda x:x[0])
worse_multi = []
for d, i in chg:
    tag = ""
    if on[i]["nspk"] >= 2 and d > 0.5:
        tag = "  <== REAL multi-speaker got WORSE (possible false collapse)"
        worse_multi.append(i)
    print(f"  {i}  gt={on[i]['nspk']}  OFF {off[i]['der']:6.2f}% -> ON {on[i]['der']:6.2f}%  Δ {d:+6.2f}pt{tag}")
print(f"\nfiles changed: {len(chg)}   real-multi-speaker made worse: {len(worse_multi)} {worse_multi}")
