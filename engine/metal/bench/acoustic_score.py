#!/usr/bin/env python3
"""Automated acoustic referee: score pause-adjacent word boundaries vs the
waveform's voiced-region edges (engine-independent ground truth).

Usage: acoustic_score.py <wav> <transcribe_output.txt>
For every voiced-region START preceded by a ≥150 ms gap, find the nearest
word ONSET within ±400 ms and record the delta; likewise region ENDS followed
by a ≥150 ms gap vs word ENDS. Mid-voice boundaries are not scored (energy
cannot adjudicate them). Reports n / mean|Δ| / median / max per side.
Envelope: mean |x| over ±2 ms at 1 ms hop, threshold 0.5×mean (same as
acoustic_ref.py and the engine's snap).
"""
import array, re, sys, wave

w = wave.open(sys.argv[1])
sr, n = w.getframerate(), w.getnframes()
assert sr == 16000
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
th = 0.5 * sum(env) / len(env)

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
merged = [(a, b) for a, b in merged if b - a >= 40]

words = []  # (t0_ms, t1_ms, txt)
# errors=replace: BPE sub-word boundaries can split multi-byte chars mid-stream
for line in open(sys.argv[2], errors='replace'):
    m = re.match(r'\s*\[(\d+\.\d+)s-(\d+\.\d+)s\]\s+(.+)', line)
    if m:
        words.append((float(m.group(1)) * 1000, float(m.group(2)) * 1000, m.group(3).strip()))
if not words:
    sys.exit('no word spans found (expected "  [t0s-t1s] word" lines)')

GAP, TOL = 150, 400
onset_d, end_d = [], []
for i, (a, b) in enumerate(merged):
    prev_end = merged[i - 1][1] if i > 0 else 0
    next_start = merged[i + 1][0] if i + 1 < len(merged) else len(env)
    if a - prev_end >= GAP:  # region start after a real pause
        cands = [wt for wt, _, _ in words if abs(wt - a) <= TOL]
        if cands:
            d = min(cands, key=lambda t: abs(t - a)) - a
            onset_d.append(d)
    if next_start - b >= GAP:  # region end before a real pause
        cands = [we for _, we, _ in words if abs(we - b) <= TOL]
        if cands:
            d = min(cands, key=lambda t: abs(t - b)) - b
            end_d.append(d)

def rep(name, ds):
    if not ds:
        print(f'{name}: no scorable boundaries')
        return
    a = sorted(abs(d) for d in ds)
    print(f'{name}: n={len(a)}  mean|Δ|={sum(a)/len(a):.0f}ms  median={a[len(a)//2]:.0f}ms  max={a[-1]:.0f}ms')

print(f'voiced regions: {len(merged)}  words: {len(words)}')
rep('pause-adjacent ONSETS', onset_d)
rep('pause-adjacent ENDS  ', end_d)
