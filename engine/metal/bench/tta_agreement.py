#!/usr/bin/env python3
# Phase G probe: does test-time-augmentation (TTA) word-disagreement beat
# single-forward confidence at flagging errors? Decode each FLEURS utt under N
# audio perturbations; a word that FLIPS across augmentations is "uncertain".
# Measure: (a) does TTA produce diversity at all, (b) precision/recall of
# "disagreement flags a wrong word" vs the prob-conf baseline (CONF-2 F1 0.41).
import json, os, subprocess, tempfile, collections, sys
M = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
V = os.path.join(M, 'bench/wer_runs/venv/bin/python')
D = os.path.join(M, 'bench/wer_runs/data/fleurs_ko')
ENG = [f'{M}/out/transcribe', f'{M}/assets/model.safetensors', None, f'{M}/assets/WHISPER_BPE.bin']

# utterances with known proper-noun / rare-word errors (found via q8_fleurs diff)
rows = {json.loads(l)['id']: json.loads(l) for l in open(f'{M}/bench/runs/q8_fleurs.jsonl') if l.strip()}
ids = ['1660','1662','1663','1665','1667','1669','1672','1675','1680','1685','1690','1695','1700','1705','1710']
ids = [i for i in ids if i in rows]

AUG = {'orig': None, 'fast': 'atempo=1.04', 'slow': 'atempo=0.96',
       'quiet': 'volume=0.6', 'bp': 'highpass=f=70,lowpass=f=7800'}

def wav_for(uid):
    name = subprocess.run(['awk','-F\t',f'$1=={uid}{{print $2}}',f'{D}/test.tsv'],capture_output=True,text=True).stdout.strip().split('\n')[0]
    return f'{D}/test/{name}'

def decode(src, af):
    wav = tempfile.mktemp(suffix='.wav')
    cmd = ['ffmpeg','-y','-loglevel','error','-i',src,'-ar','16000','-ac','1']
    if af: cmd += ['-filter:a', af]
    cmd += ['-c:a','pcm_s16le',wav]
    subprocess.run(cmd, check=True)
    eng = list(ENG); eng[2] = wav
    out = subprocess.run(eng, env={**os.environ,'WHISPER_LANG_ID':'50264','DIAR':'0'}, capture_output=True, text=True).stdout
    os.unlink(wav)
    # grab the TRANSCRIPTION body
    lines = out.split('\n'); txt = ''
    for i,l in enumerate(lines):
        if l.startswith('=== TRANSCRIPTION'):
            txt = lines[i+1] if i+1 < len(lines) else ''
            break
    return txt.strip()

div_total = 0; tok_total = 0
for uid in ids:
    src = wav_for(uid)
    if not os.path.exists(src): continue
    variants = {k: decode(src, af).split() for k, af in AUG.items()}
    orig = variants['orig']
    # per-position disagreement across augmentations (align by index — rough)
    maxlen = max(len(v) for v in variants.values())
    disagree = 0
    for p in range(len(orig)):
        toks = set()
        for v in variants.values():
            if p < len(v): toks.add(v[p])
        if len(toks) > 1: disagree += 1
    div_total += disagree; tok_total += len(orig)
    print(f"{uid}: {len(orig)} toks, {disagree} disagree across {len(AUG)} augs  ({100*disagree/max(1,len(orig)):.0f}%)")

print(f"\nTOTAL: {div_total}/{tok_total} tokens disagree under TTA = {100*div_total/max(1,tok_total):.1f}% diversity rate")
print("(near-0% → TTA gives no usable signal; the residual errors are perturbation-robust)")
