#!/usr/bin/env python3
"""Acoustic referee: voiced-region table from the raw waveform energy.

Usage: acoustic_ref.py <wav> [thresh_frac]
Prints voiced segments (envelope > frac * mean envelope, default 0.5) with
gaps < 80 ms merged and blips < 40 ms dropped, so word-onset claims near
pauses can be judged engine-independently (this is how the jfk anchors
And=0.33 / my=0.69 / Americans=1.37 / ask=3.29 / not=4.03 / ask=8.20 were
derived). Envelope: mean |x| over ±2 ms at 1 ms hop — identical to the
engine's energyEnvelope() and whisper.cpp's get_signal_energy.
Stdlib only (no numpy).
"""
import array, sys, wave

w = wave.open(sys.argv[1])
sr, n = w.getframerate(), w.getnframes()
assert sr == 16000, f'expected 16 kHz, got {sr}'
x = array.array('h')
x.frombytes(w.readframes(n))
if w.getnchannels() > 1:
    ch = w.getnchannels()
    x = array.array('h', [sum(x[i:i + ch]) // ch for i in range(0, len(x), ch)])

hop, hw = 16, 32
cs = [0.0]
for v in x:
    cs.append(cs[-1] + abs(v) / 32768.0)
env = []
for c in range(0, len(x), hop):
    lo, hi = max(c - hw, 0), min(c + hw + 1, len(x))
    env.append((cs[hi] - cs[lo]) / (hi - lo))

frac = float(sys.argv[2]) if len(sys.argv) > 2 else 0.5
mean = sum(env) / len(env)
th = frac * mean
segs, s = [], None
for i, v in enumerate(env):
    if v > th and s is None:
        s = i
    elif v <= th and s is not None:
        segs.append([s, i]); s = None
if s is not None:
    segs.append([s, len(env)])
merged = []
for a, b in segs:
    if merged and a - merged[-1][1] < 80:
        merged[-1][1] = b
    else:
        merged.append([a, b])
print(f'mean env={mean:.4f}  thresh={th:.4f}')
for a, b in merged:
    if b - a >= 40:
        print(f'voiced {a/1000:7.2f} - {b/1000:7.2f}  ({b-a} ms)')
