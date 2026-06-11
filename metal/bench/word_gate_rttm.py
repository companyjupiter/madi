#!/usr/bin/env python3
"""Prototype: gate system RTTM speech segments by transcription word spans.

Usage: word_gate_rttm.py <transcribe_out.txt> <sys.rttm> <out.rttm> [pad_s]
Speech mask = union of word spans [t0-pad, t1+pad] parsed from the
'[t0s-t1s] word' lines. Each RTTM segment is intersected with the mask
(possibly splitting); pieces shorter than 0.1 s are dropped. Whisper itself
is the speech detector — energy cannot reject music (pqmho music RMS >
real-speech RMS), and <|nospeech|> is dead in large-v3-turbo (~1e-10
everywhere, measured).
"""
import re, sys

pad = float(sys.argv[4]) if len(sys.argv) > 4 else 0.30
spans = []
for line in open(sys.argv[1], errors='replace'):
    m = re.match(r'\s*\[(\d+\.\d+)s-(\d+\.\d+)s\]\s+\S', line)
    if m:
        spans.append((float(m.group(1)) - pad, float(m.group(2)) + pad))
spans.sort()
mask = []
for a, b in spans:
    if mask and a <= mask[-1][1]:
        mask[-1][1] = max(mask[-1][1], b)
    else:
        mask.append([a, b])

out = open(sys.argv[3], 'w')
kept = dropped = 0.0
for line in open(sys.argv[2]):
    f = line.split()
    if not f or f[0] != 'SPEAKER':
        out.write(line)
        continue
    t0, dur = float(f[3]), float(f[4])
    t1 = t0 + dur
    covered = []
    for a, b in mask:
        lo, hi = max(t0, a), min(t1, b)
        if hi - lo >= 0.1:
            covered.append((lo, hi))
    for lo, hi in covered:
        f[3], f[4] = f'{lo:.3f}', f'{hi - lo:.3f}'
        out.write(' '.join(f) + '\n')
        kept += hi - lo
    dropped += dur - sum(hi - lo for lo, hi in covered)
out.close()
print(f'word-mask {sum(b-a for a,b in mask):.1f}s | kept {kept:.1f}s | dropped {dropped:.1f}s')
