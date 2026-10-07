"""Replay a saved Madi transcript through the live rolling-summary loop.

Faithful to main 3a8d3fa: SessionController.tickLiveSummary (30 s tick, >= 6 new lines,
"화자: 발언" lines), SummaryEngine.liveSummarize (" / " join, one line), LiveSummary.prompt
(carry prefix 400, window suffix 700), DNAEngineBroker.oneLine + SOV_NSTEPS=512,
SummaryReplySanitizer(headMarker "[요약]"), empty reply keeps the previous summary.
Designs are pluggable so a redesign is measured on the same replay.
Transcripts are private: read from a local path, never committed.
"""
import json, os, re, subprocess, sys, time

ENGINE = os.environ.get('ENGINE', '/Applications/Madi.app/Contents/MacOS/translate-engine-4b')
MODEL = os.environ.get('MODEL', os.path.expanduser('~/Library/Application Support/Madi/DNA3.0-4B.i1-Q4_K_M.gguf'))
NSTEPS = os.environ.get('SOV_NSTEPS', '512')


class Engine:
    def __init__(self):
        env = dict(os.environ); env['SOV_NSTEPS'] = NSTEPS; env.pop('SOV_DEBUG', None)
        self.p = subprocess.Popen([ENGINE, MODEL], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, text=True, bufsize=1, env=env)
        while True:
            l = self.p.stdout.readline()
            if not l: raise RuntimeError('engine exited before READY')
            if 'READY' in l: break

    def turn(self, prompt):
        wire = re.sub(r'[\r\n]', ' ', prompt).strip()          # DNAEngineBroker.oneLine
        self.p.stdin.write(wire + '\n'); self.p.stdin.flush()
        t0 = time.time(); seen = False; out = []; pf = gen = (0, 0.0)
        while True:
            l = self.p.stdout.readline()
            if not l: raise RuntimeError('engine exited mid-turn')
            s = l.rstrip('\n')
            m = re.search(r'\[perf\] prefill: (\d+) tok in ([0-9.]+)ms', s)
            if m: pf = (int(m.group(1)), float(m.group(2))); seen = True; continue
            m = re.search(r'\[perf\] generation: (\d+) tok in ([0-9.]+)ms', s)
            if m: gen = (int(m.group(1)), float(m.group(2))); break
            if seen and not s.startswith('[warn]'): out.append(s)
        return {'text': '\n'.join(out).strip(), 'pf_tok': pf[0], 'pf_ms': pf[1], 'gen_tok': gen[0],
                'gen_ms': gen[1], 'wall_s': time.time() - t0, 'wire_bytes': len(wire.encode())}

    def close(self):
        try: self.p.stdin.close(); self.p.wait(timeout=10)
        except Exception: self.p.kill()


def load_md(path):
    """Madi autosave Markdown → [(t_sec, speaker, text)] in order (translations skipped)."""
    rows = []
    for line in open(path, encoding='utf-8'):
        m = re.match(r'^- \*\*\[(\d+):(\d{2})(?::(\d{2}))?\] (.+?)\*\* ?(.*)$', line.rstrip('\n'))
        if not m: continue
        a, b, c = m.group(1), m.group(2), m.group(3)
        t = int(a) * 3600 + int(b) * 60 + int(c) if c else int(a) * 60 + int(b)
        text = re.sub(r'⟨[^⟩]*⟩', '', m.group(5)).replace('*', '').strip()
        if text: rows.append((t, m.group(4).strip(), text))
    return rows


# ── SummaryReplySanitizer (live-summary path: headMarker "[요약]", default cap 12) ──
SECTION_CAPS = {'요약': 12, '액션': 12, '결정': 12, '요점': 5, '용어': 5, '문답': 10, '후속': 6}

def sanitize(reply, head='[요약]'):
    text = reply
    if '</think>' in text:
        segs = text.split('</think>'); carrying = [s for s in segs if head in s]
        text = (carrying[-1] if carrying else max(segs, key=len)).strip()
    out, seen, blank, cap, n = [], set(), 0, 12, 0
    for raw in text.split('\n'):
        line = raw.strip()
        if not line:
            blank += 1
            if blank > 1: continue
            out.append(raw); continue
        blank = 0
        if line in seen: continue
        seen.add(line)
        sec = next((k for k in SECTION_CAPS if line.startswith(f'[{k}]')), None)
        if sec: cap, n = SECTION_CAPS[sec], 0
        elif line.startswith('['): cap, n = 12, 0
        else:
            n += 1
            if n > cap: continue
        out.append(raw)
    return '\n'.join(out).strip()


def bullets(reply):
    out = []
    for raw in reply.split('\n'):
        line = raw.strip()
        if not line: continue
        for mark in ['- ', '* ', '• ', '· ', '-', '•']:
            if line.startswith(mark): line = line[len(mark):].strip(); break
        if line: out.append(line)
    return out


# ── design: current rolling carry (LiveSummary.prompt, .meeting template) ──
CARRY_CAP, WINDOW_CAP = 400, 700

def baseline_prompt(carry, window):
    w = window.replace('\n', ' ')[-WINDOW_CAP:]
    c = (carry or '').replace('\n', ' ').strip()
    if not c:
        return ("다음은 진행 중인 회의의 최근 발언입니다. 지금까지의 핵심을 3-5개 불릿으로 요약하세요. "
                "반드시 발언과 같은 언어로만 답하세요(발언이 영어면 영어로). "
                f"각 줄을 - 로 시작, 다른 말 없이 불릿만. 발언: {w}")
    return ("다음은 진행 중인 회의의 기존 요약과 새 발언입니다. 새 발언을 반영해 핵심 요약을 "
            "3-6개 불릿으로 갱신하세요. 여전히 중요한 항목은 유지하고 새 내용을 반영하세요. "
            "반드시 발언과 같은 언어로만 답하세요(발언이 영어면 영어로). "
            f"각 줄을 - 로 시작, 다른 말 없이 불릿만. 기존 요약: {c[:CARRY_CAP]} 새 발언: {w}")


class Baseline:
    name = 'baseline'
    def __init__(self): self.carry = None
    def update(self, eng, new_rows, all_rows_upto):
        t = ' / '.join(f'{s}: {x}' for _, s, x in new_rows).replace('\n', ' ').strip()
        r = eng.turn(baseline_prompt(self.carry, t))
        clean = sanitize(r['text'])
        if clean: self.carry = clean
        return [r]
    def pane(self): return bullets(self.carry or '')


def replay(rows, design, tick=30, min_new=6, snapshots=(600, 1200, 1800)):
    eng = Engine(); last = 0; t = tick; log = []; snaps = {}
    end = rows[-1][0] + tick
    try:
        while t <= end:
            total = sum(1 for r in rows if r[0] <= t)
            if last > total: last = total
            if total >= last + getattr(design, 'MIN_NEW', min_new):
                reqs = design.update(eng, rows[last:total], rows[:total])
                for r in reqs:
                    log.append({'t': t, **{k: r[k] for k in ('pf_tok', 'pf_ms', 'gen_tok', 'gen_ms', 'wire_bytes')},
                                'new_rows': total - last, 'kind': r.get('kind', 'rewrite')})
                last = total
            for s in snapshots:
                if s not in snaps and t >= s: snaps[s] = design.pane()
            t += tick
    finally:
        eng.close()
    snaps['end'] = design.pane()
    if hasattr(design, 'pane_raw'): snaps['raw_notes'] = design.pane_raw()
    return log, snaps


def report(name, log, snaps):
    inflight = sorted(r['pf_ms'] + r['gen_ms'] for r in log)
    q = lambda p: inflight[min(len(inflight) - 1, int(p * len(inflight)))] if inflight else 0
    print(f'\n=== {name}: {len(log)} requests ===')
    print(f'  in-flight ms  p50 {q(.5):.0f}  p90 {q(.9):.0f}  max {max(inflight) if inflight else 0:.0f}')
    print(f'  prompt tok    p50 {sorted(r["pf_tok"] for r in log)[len(log)//2]}  max {max(r["pf_tok"] for r in log)}')
    kinds = {}
    for r in log: kinds.setdefault(r['kind'], []).append(r['pf_ms'] + r['gen_ms'])
    for k, v in kinds.items(): v = sorted(v); print(f'    {k:8s} n={len(v):3d}  p50 {v[len(v)//2]:.0f}  max {v[-1]:.0f} ms')
    for k in list(snaps):
        if k == 'raw_notes': continue
        lab = f'{k//60} min' if isinstance(k, int) else k
        print(f'  -- pane @ {lab} ({len(snaps[k])} bullets)')
        for b in snaps[k]: print('     •', b[:150])


if __name__ == '__main__':
    path = sys.argv[1]; which = sys.argv[2] if len(sys.argv) > 2 else 'baseline'
    if os.path.isdir(path):
        import bundle_rows; rows = bundle_rows.load_bundle(path)
    else:
        rows = load_md(path)
    print(f'{os.path.basename(path)}: {len(rows)} rows, {rows[-1][0]/60:.1f} min, '
          f'{len(set(s for _, s, _ in rows))} speakers')
    designs = {'baseline': Baseline}
    import importlib.util
    extra = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'designs.py')
    if os.path.exists(extra):
        spec = importlib.util.spec_from_file_location('designs', extra); mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(mod); designs.update(mod.DESIGNS)
    d = designs[which]()
    log, snaps = replay(rows, d)
    report(which, log, snaps)
    # Runs hold notes from private meetings — never write them inside the (public) repo.
    import tempfile
    out_dir = os.environ.get('LIVE_SUMMARY_OUT', tempfile.gettempdir())
    out = os.path.join(out_dir, f'run_{which}_{os.path.basename(path.rstrip("/"))}.json')
    json.dump({'log': log, 'snaps': {str(k): v for k, v in snaps.items()}}, open(out, 'w'), ensure_ascii=False, indent=1)
    print('saved', out)
