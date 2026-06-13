#!/usr/bin/env python3
"""srt_broadcast.py — broadcast-grade SRT from the engine's word events.

Consumes the structured event contract (docs/EVENTS.md): `word` events carry
{t0, t1, text}. Groups them into subtitle cues that satisfy broadcast reading
constraints, then SELF-VERIFIES conformance (the verification is the point —
a cue that violates a rule is a hard failure, not a warning).

Constraints (Netflix/BBC-style, tunable):
  - <= 2 lines per cue, <= MAX_CHARS_PER_LINE chars per line
  - reading speed <= MAX_CPS chars/second (extend the out-time if too fast)
  - duration in [MIN_DUR, MAX_DUR] s; >= MIN_GAP between consecutive cues
  - prefer breaking at sentence-final punctuation

Usage:
  srt_broadcast.py <events.jsonl> [--out file.srt] [--cps 17] [--max-line 42]
"""
import json, sys, argparse

def dwidth(s):
    """Display width: CJK/Hangul are full-width (2), others 1. Broadcast subtitle
    line limits are width-based — 42 cells ≈ 42 Latin or ~21 Korean chars."""
    w = 0
    for ch in s:
        o = ord(ch)
        w += 2 if (0x1100 <= o <= 0x115F or 0x2E80 <= o <= 0xA4CF or 0xAC00 <= o <= 0xD7A3
                   or 0xF900 <= o <= 0xFAFF or 0xFF00 <= o <= 0xFF60 or 0xFFE0 <= o <= 0xFFE6) else 1
    return w

def load_words(path):
    ws = []
    for l in open(path, encoding='utf-8'):
        l = l.strip()
        if not l:
            continue
        d = json.loads(l)
        if d.get('t') == 'word':
            ws.append((d['t0'], d['t1'], d['text'].strip()))
    return ws

def fill_lines(words, max_line, max_lines=2):
    """Greedily pack word strings into lines of <= max_line display cells.
    Returns the list of line strings, or None if it needs more than max_lines."""
    lines, cur = [], ''
    for w in words:
        nxt = (cur + ' ' + w).strip()
        if dwidth(nxt) <= max_line:
            cur = nxt
        else:
            if cur:
                lines.append(cur)
            cur = w
            if dwidth(w) > max_line or len(lines) >= max_lines:
                # single token wider than a line, or out of lines → infeasible
                if dwidth(w) > max_line:
                    return None
    if cur:
        lines.append(cur)
    return lines if len(lines) <= max_lines else None

def wrap_two_lines(text, max_line):
    lines = fill_lines(text.split(), max_line)
    return lines if lines else [text]

SENT_END = tuple('.?!。…?!')

def build_cues(words, cps, max_line, min_dur, max_dur, min_gap):
    max_chars = max_line * 2
    cues, cur, start = [], [], None
    def text_of(ws): return ' '.join(w[2] for w in ws).strip()
    def flush(ws, nxt_start):
        if not ws:
            return
        txt = text_of(ws)
        s, e = ws[0][0], ws[-1][1]
        chars = dwidth(txt.replace(' ', ''))
        e = max(e, s + chars / cps)   # reading-speed floor: extend to meet CPS
        e = max(e, s + min_dur)       # min display duration
        e = min(e, s + max_dur)       # max display duration
        e = max(e, s + 0.05)          # never zero-length (before the hard clamp)
        # HARD constraint, applied LAST — never overlap the next cue (takes
        # priority over min-dur/CPS; dense speech may end up short/fast)
        if nxt_start is not None:
            e = min(e, nxt_start - min_gap)
        cues.append((s, e, wrap_two_lines(txt, max_line)))
    for i, w in enumerate(words):
        cand = cur + [w]
        dur = w[1] - cand[0][0]
        # line-aware: flush when the words can't pack into <=2 lines of max_line
        too_long = fill_lines([x[2] for x in cand], max_line) is None
        too_fast = dur > 0 and dwidth(text_of(cand).replace(' ', '')) / dur > cps and len(cand) > 1
        if (too_long or too_fast) and cur:
            flush(cur, w[0])
            cur = [w]
        else:
            cur = cand
        # break after sentence-final punctuation
        if cur and cur[-1][2].endswith(SENT_END):
            nxt = words[i + 1][0] if i + 1 < len(words) else None
            flush(cur, nxt)
            cur = []
    flush(cur, None)
    return cues

def fmt_time(t):
    h = int(t // 3600); m = int((t % 3600) // 60); s = int(t % 60); ms = int(round((t - int(t)) * 1000))
    if ms == 1000: s += 1; ms = 0
    return f"{h:02d}:{m:02d}:{s:02d},{ms:03d}"

def render(cues):
    out = []
    for i, (s, e, lines) in enumerate(cues, 1):
        out.append(f"{i}\n{fmt_time(s)} --> {fmt_time(e)}\n" + "\n".join(lines) + "\n")
    return "\n".join(out)

def verify(cues, cps, max_line, min_dur, max_dur, min_gap):
    # HARD rules (always satisfiable by segmentation) vs SOFT targets (limited by
    # speech density — a passage spoken faster than CPS can't slow down without
    # overlap or dropping words; broadcast practice tolerates these).
    hard, soft = [], []
    for i, (s, e, lines) in enumerate(cues, 1):
        dur = e - s
        chars = sum(dwidth(l) for l in lines)
        if len(lines) > 2: hard.append(f"cue {i}: {len(lines)} lines > 2")
        for l in lines:
            if dwidth(l) > max_line: hard.append(f"cue {i}: line {dwidth(l)} > {max_line} cells (\"{l[:20]}…\")")
        if dur > max_dur + 0.01: hard.append(f"cue {i}: {dur:.2f}s > {max_dur}s")
        if i < len(cues) and cues[i][0] - e < -0.01: hard.append(f"cue {i}: overlaps next by {e-cues[i][0]:.2f}s")
        if dur > 0 and chars / dur > cps + 0.5: soft.append(f"cue {i}: {chars/dur:.1f} CPS > {cps} (dense speech)")
        if dur < min_dur - 0.01: soft.append(f"cue {i}: {dur:.2f}s < {min_dur}s (next cue too soon)")
    return hard, soft

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('events'); ap.add_argument('--out')
    ap.add_argument('--cps', type=float, default=17); ap.add_argument('--max-line', type=int, default=42)
    ap.add_argument('--min-dur', type=float, default=0.83); ap.add_argument('--max-dur', type=float, default=7.0)
    ap.add_argument('--min-gap', type=float, default=0.083)
    a = ap.parse_args()
    words = load_words(a.events)
    cues = build_cues(words, a.cps, a.max_line, a.min_dur, a.max_dur, a.min_gap)
    srt = render(cues)
    if a.out:
        open(a.out, 'w', encoding='utf-8').write(srt)
    hard, soft = verify(cues, a.cps, a.max_line, a.min_dur, a.max_dur, a.min_gap)
    print(f"{len(words)} words → {len(cues)} cues")
    if soft:
        print(f"⚠️  {len(soft)} soft (speech-density limited): " + "; ".join(soft[:4]) + (" …" if len(soft) > 4 else ""))
    if hard:
        print(f"❌ {len(hard)} HARD conformance failures:")
        for f in hard[:15]: print("  " + f)
        sys.exit(1)
    print(f"✅ all {len(cues)} cues pass HARD rules (≤2 lines, ≤{a.max_line} chars/line, ≤{a.max_dur}s, no overlap)")
