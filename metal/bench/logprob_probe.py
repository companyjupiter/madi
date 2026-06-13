#!/usr/bin/env python3
# P1 measurement: does avg_logprob (a) separate high-WER from low-WER utterances,
# and (b) flag failures the EXISTING collapse-rescue (passes>1) misses?
# Re-runs the engine single-file on the worst/best LibriSpeech test-other utts,
# capturing per-utt avg_logprob (min over segs) + passes from the event stream.
import json, os, subprocess, tempfile, sys
M = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
VENV = os.path.join(M, 'bench/wer_runs/venv/bin/python')
DATA = os.path.join(M, 'bench/wer_runs/data/LibriSpeech/test-other')
RES = os.path.join(M, 'bench/runs/q8_other300.jsonl')

rows = [json.loads(l) for l in open(RES) if l.strip()]

# per-utt WER via the official normalizer + jiwer (same as wer_bench)
SNIP = r'''
import json,sys,jiwer
from whisper_normalizer.english import EnglishTextNormalizer
n=EnglishTextNormalizer()
out=[]
for d in json.load(sys.stdin):
    r,h=n(d['ref']),n(d['hyp'])
    if not r.strip(): continue
    out.append({'id':d['id'],'wer':jiwer.wer(r, h if h.strip() else '*')})
print(json.dumps(out))
'''
wer = json.loads(subprocess.run([VENV,'-c',SNIP], input=json.dumps(rows), capture_output=True, text=True).stdout)
wer.sort(key=lambda x: x['wer'])
best = wer[:15]
worst = wer[-15:]

def flac(uid):
    a,b,_ = uid.split('-'); return os.path.join(DATA, a, b, uid + '.flac')

def measure(uid):
    wav = tempfile.mktemp(suffix='.wav')
    subprocess.run(['ffmpeg','-y','-loglevel','error','-i',flac(uid),'-ar','16000','-ac','1','-c:a','pcm_s16le',wav], check=True)
    ev = tempfile.mktemp(suffix='.jsonl')
    subprocess.run([f'{M}/out/transcribe', f'{M}/assets/model.safetensors', wav, f'{M}/assets/WHISPER_BPE.bin'],
                   env={**os.environ,'EVENTS_FILE':ev,'DIAR':'0'}, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    segs=[json.loads(l) for l in open(ev) if l.strip() and json.loads(l)['t']=='seg']
    os.unlink(wav); os.unlink(ev)
    if not segs: return None, None
    return min(s['avg_logprob'] for s in segs), max(s['passes'] for s in segs)

print(f"{'bucket':6} {'id':24} {'WER%':>6} {'avg_lp':>8} {'passes':>6}")
agg={'best':[], 'worst':[]}
for bucket, items in [('best',best),('worst',worst)]:
    for x in items:
        lp, passes = measure(x['id'])
        if lp is None: continue
        agg[bucket].append((x['wer'], lp, passes))
        flag = '  <flag avg_lp<-1.0' if lp < -1.0 else ''
        rescued = ' RESCUED' if passes and passes>1 else ''
        print(f"{bucket:6} {x['id']:24} {x['wer']*100:6.0f} {lp:8.3f} {passes or 0:6}{flag}{rescued}")
import statistics as st
for b in ('best','worst'):
    a=agg[b]
    if a:
        print(f"\n{b}: n={len(a)} meanWER={st.mean(w for w,_,_ in a)*100:.0f}% mean_avg_lp={st.mean(l for _,l,_ in a):.3f} "
              f"flagged(<-1.0)={sum(1 for _,l,_ in a if l<-1.0)} already_rescued={sum(1 for _,_,p in a if p and p>1)}")
