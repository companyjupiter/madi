#!/usr/bin/env python3
"""wer_bench.py — absolute ASR quality: WER on standard benchmarks.

Closes the product-evaluation gap "no absolute quality numbers": runs the
resident engine (STREAM mode, model loaded ONCE) over a standard test set and
scores with the OFFICIAL Whisper text normalizer + jiwer, so the number is
directly comparable to OpenAI's published large-v3-turbo results and to
whisper.cpp runs on the same data.

Usage:
  wer_bench.py librispeech <LibriSpeech/test-clean dir> [--limit N] [--out results.jsonl]
  wer_bench.py rescore <results.jsonl>          # re-score saved hyps (no engine)

Engine env: DIAR=0 (pure ASR). Each utterance is one stream job; per-job
transcript is parsed from the `=== TRANSCRIPTION ===` section (verified
protocol: ... text line(s) ... <<SEG_END>>).
Single-instance flock guard (lesson: parallel engine runs corrupt shared state).
"""
import argparse, fcntl, json, os, re, subprocess, sys, tempfile, time

M = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # metal/
VENV = '/tmp/werenv/bin/python'  # jiwer + whisper_normalizer live here


def collect_librispeech(root):
    """[(utt_id, flac_path, reference_text)] from *.trans.txt files."""
    utts = []
    for dirpath, _, files in os.walk(root):
        for f in files:
            if f.endswith('.trans.txt'):
                for line in open(os.path.join(dirpath, f)):
                    uid, text = line.strip().split(' ', 1)
                    utts.append((uid, os.path.join(dirpath, uid + '.flac'), text))
    utts.sort()
    return utts


def run_engine(utts, out_path):
    """Feed all utterances through ONE resident engine; save hyps as jsonl.
    Resumable: per-utt flush + skip ids already in out_path (interrupted runs
    lose nothing — lesson from the overnight kill at 1624/2620)."""
    lock = open('/tmp/wer_bench.lock', 'w')
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        sys.exit('another wer_bench is running (flock) — refusing to race')

    done_ids = set()
    if os.path.exists(out_path):
        for line in open(out_path):
            try:
                done_ids.add(json.loads(line)['id'])
            except (json.JSONDecodeError, KeyError):
                pass  # truncated tail line from a kill — re-run that utt
        utts = [u for u in utts if u[0] not in done_ids]
        print(f'resume: {len(done_ids)} done, {len(utts)} remaining')

    wav_dir = tempfile.mkdtemp(prefix='wer_wav_')
    env = {**os.environ, 'STREAM': '1', 'DIAR': '0'}
    proc = subprocess.Popen(
        [f'{M}/out/transcribe', f'{M}/assets/model.safetensors', '/dev/null',
         f'{M}/assets/WHISPER_BPE.bin'],
        stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
        text=True, cwd=M, bufsize=1, env=env)

    # wait for resident-ready
    for line in proc.stdout:
        if line.startswith('[stream] ready'):
            break

    out = open(out_path, 'a')  # append: resume must not wipe prior rows
    t0 = time.time()
    done = 0
    audio_s = 0.0
    for uid, flac, ref in utts:
        wav = os.path.join(wav_dir, uid + '.wav')
        subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-i', flac,
                        '-ar', '16000', '-ac', '1', wav], check=True)
        proc.stdin.write(f'0.0 {wav}\n')
        proc.stdin.flush()
        # read until <<SEG_END>>, grab the TRANSCRIPTION section body
        hyp_lines, in_tx = [], False
        for line in proc.stdout:
            s = line.rstrip('\n')
            if s.startswith('=== TRANSCRIPTION'):
                in_tx = True
                continue
            if s.startswith('<<SEG_END>>'):
                break
            if in_tx and s.strip():
                hyp_lines.append(s.strip())
        hyp = ' '.join(hyp_lines)
        out.write(json.dumps({'id': uid, 'ref': ref, 'hyp': hyp}, ensure_ascii=False) + '\n')
        out.flush()
        os.unlink(wav)
        done += 1
        audio_s += os.path.getsize(flac) / 32000  # rough (flac ~16kbit/s/ch? just progress)
        if done % 100 == 0:
            el = time.time() - t0
            print(f'  {done}/{len(utts)}  ({el:.0f}s elapsed, {el/done:.2f}s/utt)', flush=True)
    proc.stdin.write('FLUSH\n')
    proc.stdin.flush()
    proc.stdin.close()
    proc.wait(timeout=60)
    out.close()
    print(f'engine pass done: {done} utts in {time.time()-t0:.0f}s → {out_path}')


SCORE_SNIPPET = r'''
import json, sys
import jiwer
from whisper_normalizer.english import EnglishTextNormalizer
norm = EnglishTextNormalizer()
refs, hyps, skipped = [], [], 0
for line in open(sys.argv[1]):
    d = json.loads(line)
    r, h = norm(d['ref']), norm(d['hyp'])
    if not r.strip():
        skipped += 1
        continue
    refs.append(r)
    hyps.append(h if h.strip() else '*')
wer = jiwer.wer(refs, hyps)
m = jiwer.process_words(refs, hyps)
print(f'utterances: {len(refs)} (skipped empty-ref: {skipped})')
print(f'WER = {wer*100:.2f}%  (S={m.substitutions} D={m.deletions} I={m.insertions} / W={m.hits+m.substitutions+m.deletions})')
# worst 10 utterances for inspection
per = []
for i,(r,h) in enumerate(zip(refs,hyps)):
    w = jiwer.wer(r,h)
    per.append((w,i,r,h))
per.sort(reverse=True)
print('--- worst 10 ---')
for w,i,r,h in per[:10]:
    print(f'[{w*100:.0f}%] REF: {r[:90]}')
    print(f'        HYP: {h[:90]}')
'''


def score(jsonl):
    subprocess.run([VENV, '-c', SCORE_SNIPPET, jsonl], check=True)


if __name__ == '__main__':
    ap = argparse.ArgumentParser()
    ap.add_argument('mode', choices=['librispeech', 'rescore'])
    ap.add_argument('path')
    ap.add_argument('--limit', type=int, default=0)
    ap.add_argument('--out', default='/tmp/wer/results.jsonl')
    a = ap.parse_args()
    if a.mode == 'rescore':
        score(a.path)
    else:
        utts = collect_librispeech(a.path)
        if a.limit:
            utts = utts[:a.limit]
        print(f'{len(utts)} utterances')
        os.makedirs(os.path.dirname(a.out), exist_ok=True)
        run_engine(utts, a.out)
        score(a.out)
