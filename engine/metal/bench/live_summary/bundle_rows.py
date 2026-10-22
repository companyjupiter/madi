"""Debug bundle → replay rows. translate.jsonl carries every committed source line (one turn per
target language, re-sent when a row grows), so keep one language, drop exact repeats, and let a
grown row replace the fragment it extends. Speakers are not in that log → generic label."""
import json, os

def load_bundle(b, lang='English'):
    raw = []
    for line in open(os.path.join(b, 'translate.jsonl'), encoding='utf-8'):
        try: d = json.loads(line)
        except Exception: continue
        if d.get('ev') == 'turn' and d.get('kind') == 'committed' and d.get('lang') == lang:
            s = (d.get('source') or '').strip()
            if s: raw.append((float(d.get('t', 0)), s))
    raw.sort()
    rows = []
    for t, s in raw:
        if any(s == r[2] for r in rows[-6:]): continue                 # exact repeat (retry)
        if rows and s.startswith(rows[-1][2]) and t - rows[-1][0] < 20:  # grown row replaces fragment
            rows[-1] = (rows[-1][0], rows[-1][1], s); continue
        rows.append((int(t), '화자', s))
    return rows
