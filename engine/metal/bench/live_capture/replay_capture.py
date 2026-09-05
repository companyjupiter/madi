#!/usr/bin/env python3
"""Replay a tee_transcribe capture EXACTLY: same env (env.txt), same command stream
(stdin.log), the WAV bytes as they were at feed time (wav/ snapshots), optionally the
same wall-clock pacing. Then diff the live stdout's segments against the replay's.
  python3 replay_capture.py <capture_dir> [--paced] [--engine out/transcribe_p5] [--env K=V,...]
"""
import argparse, json, os, re, subprocess, sys, threading, time
M = os.path.expanduser("~/antigravity/madi/engine/metal")
ap = argparse.ArgumentParser(); ap.add_argument("cap"); ap.add_argument("--paced", action="store_true")
ap.add_argument("--engine", default=os.path.join(M, "out/transcribe_p5")); ap.add_argument("--env", default="")
ap.add_argument("--limit", type=int, default=0)
a = ap.parse_args()
cap = os.path.abspath(a.cap); wavdir = os.path.join(cap, "wav")
env = {}
for l in open(os.path.join(cap, "env.txt")):
    k, _, v = l.rstrip("\n").partition("="); env[k] = v
ev = os.path.join(cap, "replay.events.jsonl")
env["EVENTS_FILE"] = ev; env["STREAM_WAV_ROOTS"] = wavdir
for kv in filter(None, a.env.split(",")):
    k, _, v = kv.partition("="); env[k] = v
if os.path.exists(ev): os.remove(ev)
rows = []
for l in open(os.path.join(cap, "stdin.log")):
    t, snap, line = l.rstrip("\n").split("\t", 2)
    rows.append((float(t), snap, line))
if a.limit and a.limit < len(rows): rows = rows[: a.limit] + [(rows[a.limit - 1][0] + 1, "", "FLUSH")]
model = os.environ.get("MADI_MODEL", os.path.expanduser("~/Library/Application Support/Madi/model.q8.safetensors"))
p = subprocess.Popen([a.engine, model, "/dev/null", os.path.join(M, "assets/WHISPER_BPE.bin")],
                     stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                     text=True, errors="replace", cwd=M, bufsize=1, env=env)
out = []
threading.Thread(target=lambda: [out.append(x) for x in p.stdout], daemon=True).start()
while not any(x.startswith("[stream] ready") for x in out): time.sleep(0.2)
start = time.monotonic(); sent = 0
for t, snap, line in rows:
    if a.paced:
        dt = t - (time.monotonic() - start)
        if dt > 0: time.sleep(dt)
    if snap and not snap.startswith("COPYFAIL"):
        parts = line.split(); path = next(q for q in parts if q.endswith(".wav"))
        line = line.replace(path, os.path.join(wavdir, snap))
    p.stdin.write(line + "\n"); p.stdin.flush(); sent += 1
if not any(r[2].strip() == "FLUSH" for r in rows): p.stdin.write("FLUSH\n"); p.stdin.flush()
p.stdin.close(); p.wait(timeout=600)
open(os.path.join(cap, "replay.stdout.log"), "w").write("".join(out))
# ---- compare committed segment texts: live stdout vs replay stdout ----
def segs_from_stdout(text):
    segs, cur, inside = [], [], False
    for ln in text.splitlines():
        if ln.startswith("<<PREVIEW_BEGIN>>"): inside = "pv"; continue
        if ln.startswith("<<PREVIEW_END>>"): inside = False; continue
        if inside == "pv": continue
        if ln.startswith("=== TRANSCRIPTION"): cur = []; inside = "tr"; continue
        if ln.startswith("<<SEG_END>>"): segs.append(" ".join(cur).strip()); inside = False; continue
        if inside == "tr" and ln and not ln.startswith(("[", "<<", "SPK", "«", "===")): cur.append(ln.strip())
    return segs
live = segs_from_stdout(open(os.path.join(cap, "stdout.log"), errors="replace").read())
rep = segs_from_stdout("".join(out))
de = re.compile(r'\b(der|die|das|und|nicht|werden|dass|sehr|mit|wenn|für|über|aber|haben|sind|ihre|ich|es|ist|wir|man)\b')
def deg(t): ws = t.split(); return sum(1 for w in ws if de.fullmatch(w.strip('.,?!"'))) / max(1, len(ws))
def stat(name, s):
    b = [x for x in s if deg(x) > 0.12]
    print(f"  {name:8} segs={len(s):4}  독일어 {len(b):3} ({100*len(b)/max(1,len(s)):3.0f}%)")
print(f"capture {cap}\n  commands sent {sent}, paced={a.paced}, engine={os.path.basename(a.engine)}")
stat("live", live); stat("replay", rep)
same = sum(1 for x, y in zip(live, rep) if x == y)
print(f"  텍스트 동일 {same}/{min(len(live), len(rep))}")
livelog = open(os.path.join(cap, "stdout.log"), errors="replace").read()
for tag in ("[lang]", "[rescue]", "[loop-p2]", "[prompt]", "[warn]"):
    print(f"  live stdout {tag:10} {livelog.count(tag):4}   replay {''.join(out).count(tag):4}")
for i, (x, y) in enumerate(zip(live, rep)):
    if x != y and (deg(x) > 0.12 or deg(y) > 0.12):
        print(f"  #{i}\n    L: {x[:100]}\n    R: {y[:100]}")
        if i > 60: break
