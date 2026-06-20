#!/usr/bin/env python3
"""conf_eval.py — is the per-word confidence a GOOD error predictor?

The live UI flags words below a threshold; a user reported it flags too much even
on clear speech. This measures, on FLEURS-ko (ground-truth), the precision/recall
of "conf < T predicts an actual word error" across thresholds — turning the
"flags too much" feeling into a number, and finding the threshold knee.

Per file: run the engine with CONF=1, parse `[t0s-t1s] word «conf x.xx»`, align
the hyp word stream to the reference with jiwer, label each hyp word
correct/substituted/inserted, and record (conf, is_error). Aggregate.

Usage: conf_eval.py [N_FILES]
"""
import os, re, subprocess, sys
M = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VENV = os.path.join(M, 'bench/wer_runs/venv/bin/python')
FLEURS = os.path.join(M, 'bench/wer_runs/data/fleurs_ko')
N = int(sys.argv[1]) if len(sys.argv) > 1 else 40

rows = [l.rstrip('\n').split('\t') for l in open(os.path.join(FLEURS, 'test.tsv'))]
rows = [(r[1], r[2]) for r in rows if len(r) >= 3][:N]

env = {**os.environ, 'STREAM': '1', 'DIAR': '0', 'CONF': '1', 'WHISPER_LANG_ID': '50264', 'METRIC': os.environ.get('METRIC','prob')}
proc = subprocess.Popen([f'{M}/out/transcribe', f'{M}/assets/model.safetensors', '/dev/null',
                         f'{M}/assets/WHISPER_BPE.bin'],
                        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                        text=True, cwd=M, bufsize=1, env=env)
for line in proc.stdout:
    if line.startswith('[stream] ready'):
        break

WORD = re.compile(r'^\s*\[[0-9.]+s-[0-9.]+s\]\s+(.*?)\s+«conf (-?[0-9.]+)»\s*$')
samples = []  # (hyp_words_with_conf, ref) per file
for wav, ref in rows:
    proc.stdin.write(f'0.0 {os.path.join(FLEURS, "test", wav)}\n'); proc.stdin.flush()
    hyp = []
    for line in proc.stdout:
        s = line.rstrip('\n')
        if s.startswith('<<SEG_END>>'):
            break
        m = WORD.match(s)
        if m:
            hyp.append((m.group(1).strip(), float(m.group(2))))
    samples.append((hyp, ref))
proc.stdin.write('FLUSH\n'); proc.stdin.flush(); proc.stdin.close(); proc.wait(timeout=30)

# write to a tmp jsonl and score in the venv (jiwer there)
import json
data = os.path.join(M, 'bench/wer_runs/conf_eval.jsonl')
with open(data, 'w') as f:
    for hyp, ref in samples:
        f.write(json.dumps({'hyp': hyp, 'ref': ref}, ensure_ascii=False) + '\n')
print(f'collected {len(samples)} files, {sum(len(h) for h,_ in samples)} hyp words -> scoring')

SCORE = r'''
import json, sys, jiwer
from whisper_normalizer.basic import BasicTextNormalizer
norm = BasicTextNormalizer()
pairs = []  # (conf, is_error)
for line in open(sys.argv[1]):
    d = json.loads(line)
    hyp_words = [(norm(w).strip(), c) for w, c in d['hyp']]
    hyp_words = [(w, c) for w, c in hyp_words if w]
    ref_words = [w for w in norm(d['ref']).split() if w]
    if not ref_words or not hyp_words:
        continue
    out = jiwer.process_words([' '.join(w for w, _ in hyp_words)], [' '.join(ref_words)])
    # jiwer aligns ref->hyp; iterate alignment chunks to mark each hyp word
    hi = 0
    for chunk in out.alignments[0]:
        n = chunk.hyp_end_idx - chunk.hyp_start_idx
        is_err = chunk.type in ('substitute', 'insert')
        for _ in range(n):
            if hi < len(hyp_words):
                pairs.append((hyp_words[hi][1], 1 if is_err else 0))
                hi += 1
errs = sum(e for _, e in pairs)
print(f'words={len(pairs)} errors={errs} ({100*errs/len(pairs):.1f}%)')
import statistics
ce = [c for c, e in pairs if e]; cc = [c for c, e in pairs if not e]
print(f'conf  mean: error={statistics.mean(ce):.3f}  correct={statistics.mean(cc):.3f}')
print(f'conf median: error={statistics.median(ce):.3f}  correct={statistics.median(cc):.3f}')
import os as _os
print(f'--- bottom-X% sweep (flag most-uncertain X%) metric={_os.environ.get("METRIC","prob")} ---')
print(f'{"X%":>5} {"flagged":>8} {"precision":>10} {"recall":>8} {"F1":>6}')
vals = sorted(c for c, _ in pairs)  # ascending: lower = more uncertain
for X in [5, 10, 15, 20, 30, 40]:
    k = max(1, int(len(pairs) * X / 100))
    thr = vals[k - 1]
    flagged = [(c, e) for c, e in pairs if c <= thr]
    tp = sum(e for _, e in flagged)
    prec = tp / len(flagged) if flagged else 0
    rec = tp / errs if errs else 0
    f1 = 2 * prec * rec / (prec + rec) if (prec + rec) else 0
    print(f'{X:>4}% {len(flagged):>8} {prec:>10.2f} {rec:>8.2f} {f1:>6.2f}')
'''
subprocess.run([VENV, '-c', SCORE, data], check=True)
