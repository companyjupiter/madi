#!/usr/bin/env python3
"""Transparent shim in place of the engine binary: records EXACTLY what the app sends
(stdin lines with wall-clock timestamps), snapshots every WAV at the moment it is
referenced (so a later mutation of the file cannot hide), and tees the engine's
stdout — then replays offline byte-for-byte are possible. Installed as
Contents/MacOS/transcribe next to the real binary renamed transcribe.real."""
import os, shutil, subprocess, sys, threading, time
real = os.path.join(os.path.dirname(os.path.abspath(__file__)), "transcribe.real")
cap = os.path.join(os.path.expanduser("~/Library/Application Support/Madi"), "engine-capture", time.strftime("%Y%m%d-%H%M%S"))
os.makedirs(os.path.join(cap, "wav"), exist_ok=True)
with open(os.path.join(cap, "env.txt"), "w") as f:
    for k, v in sorted(os.environ.items()): f.write(f"{k}={v}\n")
p = subprocess.Popen([real] + sys.argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=sys.stderr, bufsize=0)
t0 = time.monotonic()
def pump_out():
    with open(os.path.join(cap, "stdout.log"), "ab") as log:
        while True:
            chunk = p.stdout.read1(65536) if hasattr(p.stdout, "read1") else p.stdout.read(4096)
            if not chunk: break
            log.write(chunk); log.flush()
            sys.stdout.buffer.write(chunk); sys.stdout.buffer.flush()
threading.Thread(target=pump_out, daemon=True).start()
with open(os.path.join(cap, "stdin.log"), "a") as log:
    n = 0
    for raw in sys.stdin.buffer:
        line = raw.decode("utf-8", "replace").rstrip("\n")
        # snapshot the wav the command references, named by feed order so the
        # live sequence (including preview rotation) is reconstructible
        parts = line.split()
        path = next((q for q in parts if q.endswith(".wav")), None)
        snap = ""
        if path and os.path.exists(path):
            snap = f"{n:05d}-{os.path.basename(path)}"
            try: shutil.copy2(path, os.path.join(cap, "wav", snap))
            except Exception as e: snap = f"COPYFAIL:{e}"
        log.write(f"{time.monotonic()-t0:9.3f}\t{snap}\t{line}\n"); log.flush()
        n += 1
        try:
            p.stdin.write(raw); p.stdin.flush()
        except BrokenPipeError:
            break
try: p.stdin.close()
except Exception: pass
sys.exit(p.wait())
