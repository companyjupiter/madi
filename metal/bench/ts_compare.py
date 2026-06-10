#!/usr/bin/env python3
"""Word-timestamp referee: ours (transcribe stdout) vs whisper.cpp (-ml 1 --dtw).

Usage: ts_compare.py <ours.txt> <wcpp.txt>
Parses our '=== WORD TIMESTAMPS ===' block and wcpp's per-token lines, merges
wcpp tokens into words (leading-space token = new word; punctuation glues to
the previous word), aligns word-by-word, prints per-word Δ and summary stats.
Acoustic referee anchors (jfk): ask#1=3.28s, ask#2=8.18s (energy onsets).
"""
import re, sys

def parse_ours(path):
    words = []
    in_block = False
    for line in open(path):
        if 'WORD TIMESTAMPS' in line:
            in_block = True
            continue
        if in_block:
            m = re.match(r'\s*\[(\d+\.\d+)s\]\s+(.+)', line)
            if not m:
                if line.strip() == '' or line.startswith('==='):
                    break
                continue
            words.append((float(m.group(1)), m.group(2).strip()))
    return words

def parse_wcpp(path):
    toks = []
    for line in open(path):
        m = re.match(r'\[(\d+):(\d+):(\d+)\.(\d+) --> .*?\]\s\s(.*)$', line)
        if not m:
            continue
        h, mn, s, ms, txt = m.groups()
        t = int(h) * 3600 + int(mn) * 60 + int(s) + int(ms) / 1000.0
        toks.append((t, txt))
    # merge tokens into words: token starting with ' ' begins a new word;
    # punctuation-only tokens (no leading space) glue to the previous word
    words = []
    for t, txt in toks:
        if txt.strip() == '':
            continue
        if txt.startswith(' ') or not words:
            words.append([t, txt.strip()])
        else:
            words[-1][1] += txt.strip()
    return [(t, w) for t, w in words]

def norm(w):
    return re.sub(r'[^\w]', '', w).lower()

ours = parse_ours(sys.argv[1])
wcpp = parse_wcpp(sys.argv[2])

if len(ours) != len(wcpp) or any(norm(a[1]) != norm(b[1]) for a, b in zip(ours, wcpp)):
    print(f'WORD MISMATCH: ours={len(ours)} wcpp={len(wcpp)}')
    for i in range(max(len(ours), len(wcpp))):
        a = ours[i] if i < len(ours) else ('-', '-')
        b = wcpp[i] if i < len(wcpp) else ('-', '-')
        print(f'  {i:2d}  {a[1]!r:>15} {b[1]!r:>15}')
    sys.exit(1)

deltas = []
print(f'{"word":>12} {"ours":>7} {"wcpp":>7} {"Δms":>6}')
for (to, w), (tw, _) in zip(ours, wcpp):
    d = (to - tw) * 1000
    deltas.append(abs(d))
    print(f'{w:>12} {to:7.2f} {tw:7.2f} {d:+6.0f}')
ad = sorted(deltas)
n = len(ad)
print(f'\nn={n}  mean|Δ|={sum(ad)/n:.0f}ms  median={ad[n//2]:.0f}ms  max={ad[-1]:.0f}ms')

# acoustic anchors (jfk only): both 'ask' onsets
asks = [t for t, w in ours if norm(w) == 'ask']
if len(asks) == 2:
    print(f'acoustic: ask#1 {asks[0]:.2f} (ref 3.28, {(asks[0]-3.28)*1000:+.0f}ms)  '
          f'ask#2 {asks[1]:.2f} (ref 8.18, {(asks[1]-8.18)*1000:+.0f}ms)')
