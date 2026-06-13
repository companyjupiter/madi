#!/usr/bin/env python3
"""minutes.py — structured meeting minutes from the engine's event contract.

No LLM: pure structure from the signals already in the stream (docs/EVENTS.md) —
speaker turns (spk_seg), topic sections (split at long inter-turn pauses), per-
speaker talk share, and a review list (low-confidence words). Output is Markdown.

Usage:
  minutes.py <events.jsonl> [--gap 6] [--low-conf 0.55] [--out minutes.md]
  --gap: seconds of silence between turns that starts a new section.
"""
import json, sys, argparse, collections

def load(path):
    words, spk, meta, dur = [], [], None, 0.0
    for l in open(path, encoding='utf-8'):
        l = l.strip()
        if not l:
            continue
        d = json.loads(l)
        t = d['t']
        if t == 'word': words.append(d)
        elif t == 'spk_seg': spk.append(d)
        elif t == 'meta': meta = d
        elif t == 'seg': dur = max(dur, d['t1'])
    return words, sorted(spk, key=lambda x: x['t0']), meta, dur

def mmss(t): return f"{int(t // 60):02d}:{int(t % 60):02d}"

def build(words, spk, meta, dur, gap, low_conf):
    # turns: spk_seg already groups consecutive same-speaker words into a run.
    # attach each word's confidence to flag low-confidence terms per turn.
    # each turn's END = its last word's t1 (so section splits use REAL silence
    # between turns, not a turn's own duration).
    turns = []
    for i, sg in enumerate(spk):
        lo = sg['t0']
        hi = spk[i + 1]['t0'] if i + 1 < len(spk) else dur + 1
        tw = [w for w in words if lo <= w['t0'] < hi]
        end = max((w['t1'] for w in tw), default=lo)
        turns.append({'t0': sg['t0'], 'end': end, 'spk': sg['spk'], 'text': sg['text'].strip()})
    share = collections.Counter()
    for tn in turns:
        share[tn['spk']] += max(0, tn['end'] - tn['t0'])
    # sections: split where the SILENCE (prev turn end → this turn start) > gap
    sections, cur = [], []
    for i, tn in enumerate(turns):
        if cur and tn['t0'] - turns[i - 1]['end'] > gap:
            sections.append(cur); cur = []
        cur.append(tn)
    if cur:
        sections.append(cur)
    # review list: low-confidence words
    review = sorted([w for w in words if w['conf'] < low_conf], key=lambda w: w['conf'])

    out = []
    title = (meta or {}).get('model', 'transcript')
    out.append(f"# 회의록\n")
    out.append(f"- 길이: **{mmss(dur)}** · 화자 **{len({t['spk'] for t in turns})}명** · "
               f"단어 **{len(words)}** · 섹션 **{len(sections)}**")
    if share:
        parts = " · ".join(f"화자 {s}: {int(100 * v / max(1, sum(share.values())))}%"
                           for s, v in sorted(share.items()))
        out.append(f"- 발화 비중: {parts}")
    out.append(f"- 모델: `{title}`\n")
    for si, sec in enumerate(sections, 1):
        out.append(f"## 섹션 {si} · {mmss(sec[0]['t0'])}\n")
        for tn in sec:
            out.append(f"**[{mmss(tn['t0'])}] 화자 {tn['spk'] if tn['spk'] >= 0 else '?'}:** {tn['text']}\n")
    if review:
        out.append(f"## 검토 권장 ({len(review)})\n")
        seen = set(); chips = []
        for w in review:
            t = w['text'].strip()
            if t in seen: continue
            seen.add(t); chips.append(f"`{t}` ({int(w['conf']*100)}%)")
            if len(chips) >= 30: break
        out.append(" · ".join(chips))
    return "\n".join(out), {'turns': len(turns), 'sections': len(sections), 'review': len(review)}

if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('events'); ap.add_argument('--out')
    ap.add_argument('--gap', type=float, default=6.0); ap.add_argument('--low-conf', type=float, default=0.55)
    a = ap.parse_args()
    words, spk, meta, dur = load(a.events)
    if not spk:
        print("no speaker segments (need DIAR=1 events)"); sys.exit(1)
    md, stats = build(words, spk, meta, dur, a.gap, a.low_conf)
    if a.out:
        open(a.out, 'w', encoding='utf-8').write(md)
    print(f"✅ {stats['turns']} turns → {stats['sections']} sections, {stats['review']} review terms"
          + (f" → {a.out}" if a.out else ""))
