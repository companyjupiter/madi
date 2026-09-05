#!/usr/bin/env python3
"""Replay the live session's own segment WAVs at the EXACT offsets the app used
(read from the live events file), so the only thing that differs from the live
run is what we deliberately change.  ENGINE / EXTRA / WHISPER_LANG_ID via env."""
import glob, json, os, re, subprocess, sys
M = os.path.expanduser("~/antigravity/madi/engine/metal")
SEGDIR = sys.argv[2] if len(sys.argv) > 2 else "/private/var/folders/pj/n1890y6s2l7dp5rwtjqbl6qr0000gn/T/sovereign-segs"
REF = os.path.join(M, "bench/wer_runs/p5/live_ref.json")   # frozen live reference
_g = glob.glob('/private/var/folders/pj/*/T/madi-engine-*.events.jsonl')
LIVE = max(_g, key=os.path.getmtime) if _g else None
ENGINE = os.environ.get("ENGINE", os.path.join(M, "out/transcribe"))
MODEL = os.environ.get("MADI_MODEL", os.path.expanduser("~/Library/Application Support/Madi/model.q8.safetensors"))
BPE = os.path.join(M, "assets/WHISPER_BPE.bin")
out_path = sys.argv[1]; ev = out_path + ".events"
live = ([json.loads(l) for l in open(LIVE, errors="replace") if '"t":"seg"' in l]
        if LIVE else json.load(open(REF)))
if len(live) < 20 and os.path.exists(REF): live = json.load(open(REF))
wavs = sorted(f for f in os.listdir(SEGDIR) if re.fullmatch(r"seg\d+\.wav", f))
n = min(len(live), len(wavs))
env = {**os.environ, "STREAM": "1", "CONF": "1", "EVENTS_FILE": ev,
       "STREAM_WAV_ROOTS": SEGDIR, "AUDIO_CTX": "auto", "APP_FILE": "1",
       "DIAR": "0", "PARTIALS": "0",
       "LANG_CANDIDATES": os.environ.get("LANG_CANDIDATES", "50264,50266")}
for kv in filter(None, os.environ.get("EXTRA", "").split(",")):
    k, _, v = kv.partition("="); env[k] = v
env.pop("WHISPER_LANG_ID", None)
if os.environ.get("FORCE_LANG"): env["WHISPER_LANG_ID"] = os.environ["FORCE_LANG"]
if os.path.exists(ev): os.remove(ev)
# BISECT: PREVIEW=k interleaves k preview jobs before every committed segment,
# the way the live lane does (~1/s between 5 s segments). PREVIEW_FP=1 also sends
# the %%FP forced prefix the app attaches.
pv = sorted(f for f in os.listdir(SEGDIR) if f.startswith("preview-"))
k = int(os.environ.get("PREVIEW", "0"))
fp = os.environ.get("PREVIEW_FP") == "1"
feed = []
for i in range(n):
    for j in range(k):
        if not pv: break
        w = os.path.join(SEGDIR, pv[(i * k + j) % len(pv)])
        tail = " %%FP " + (live[i - 1].get("text", "")[-120:] if i and fp else "") if fp and i else ""
        feed.append(f"PREVIEW {w}{tail}")
    feed.append(f"{live[i]['t0']:.3f} {os.path.join(SEGDIR, wavs[i])}")
feed.append("FLUSH")
p = subprocess.run([ENGINE, MODEL, "/dev/null", BPE], input="\n".join(feed) + "\n",
                   text=True, capture_output=True, cwd=M, env=env)
open(out_path + ".stdout", "w").write(p.stdout)
segs = [json.loads(l) for l in open(ev, errors="replace") if '"t":"seg"' in l] if os.path.exists(ev) else []
json.dump({"live": live[:n], "replay": segs}, open(out_path, "w"), ensure_ascii=False)
same = sum(1 for a, b in zip(live, segs) if a.get("text", "").strip() == b.get("text", "").strip())
print(f"{os.path.basename(ENGINE):18} EXTRA={os.environ.get('EXTRA','-'):34} n={len(segs):3} 라이브와 동일 {same}/{n}  rescue={len(re.findall(r'.rescue.', p.stdout))}")
