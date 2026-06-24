#!/usr/bin/env python3
# FLEURS-ko CER vs VAD_PROB — the KO transcription (language) axis. Establishes
# the SAFE UPPER BOUND for the speech-probability threshold: too high and quiet
# read-speech utterances get chunk-skipped (empty hyp) → CER spikes. Single
# resident engine per prob (DIAR=0, forced ko=50264), subset for speed.
#   FLEURS_N=80 VAD_PROBS=0.3,0.5,0.7,0.85,0.95 python3 bench/fleurs_vad_sweep.py
import os, sys, json, subprocess, time, tempfile, fcntl

HERE = os.path.dirname(os.path.abspath(__file__))
M = os.path.dirname(HERE)
DATA = os.path.join(M, "bench/wer_runs/data/fleurs_ko")
VENV = os.path.join(M, "bench/wer_runs/venv/bin/python")
TR = os.path.join(M, "out/transcribe")
RUNS = os.path.join(HERE, "runs")
OUTJ = os.path.join(RUNS, "fleurs_vad_sweep.jsonl")

PROBS = [float(x) for x in os.environ.get("VAD_PROBS", "0.3,0.5,0.7,0.85,0.95").split(",")]
N = int(os.environ.get("FLEURS_N", "80"))

def collect():
    utts = []
    for line in open(os.path.join(DATA, "test.tsv")):
        c = line.rstrip("\n").split("\t")
        if len(c) < 3:
            continue
        utts.append((c[0], os.path.join(DATA, "test", c[1]), c[2].strip().strip('"')))
    utts.sort()
    return utts[:N]

KO_SCORE = r'''
import json,sys,jiwer
from whisper_normalizer.basic import BasicTextNormalizer
norm=BasicTextNormalizer()
refs,hyps,empty=[],[],0
for line in open(sys.argv[1]):
    d=json.loads(line)
    r=norm(d['ref']); h=norm(d['hyp'])
    if not r.strip(): continue
    if not h.strip(): empty+=1
    refs.append(r); hyps.append(h if h.strip() else '*')
print(f"CER={jiwer.cer(refs,hyps)*100:.2f} WER={jiwer.wer(refs,hyps)*100:.2f} n={len(refs)} empty={empty}")
'''

def run_prob(prob, utts):
    scratch = tempfile.mkdtemp(prefix=f"flv_{prob}_", dir=os.path.join(RUNS, "vad_scratch"))
    # STREAM mode only reads wavs under STREAM_WAV_ROOTS/TMPDIR/"/tmp" (sandbox,
    # transcribe.zig validateStreamWavPath) — point it at our scratch dir.
    env = {**os.environ, "STREAM": "1", "DIAR": "0", "VAD_PROB": str(prob),
           "WHISPER_LANG_ID": "50264", "STREAM_WAV_ROOTS": scratch}
    proc = subprocess.Popen([TR, os.path.join(M, "assets/model.safetensors"), "/dev/null",
                             os.path.join(M, "assets/WHISPER_BPE.bin")],
                            stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                            stderr=subprocess.DEVNULL, text=True, cwd=M, bufsize=1, env=env)
    for line in proc.stdout:
        if line.startswith("[stream] ready"):
            break
    hyp_path = os.path.join(RUNS, f"fleurs_hyp_p{prob}.jsonl")
    out = open(hyp_path, "w")
    for uid, flac, ref in utts:
        wav = os.path.join(scratch, uid + ".wav")
        subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-i", flac, "-ar", "16000",
                        "-ac", "1", "-c:a", "pcm_s16le", wav], check=True)
        proc.stdin.write(f"0.0 {wav}\n"); proc.stdin.flush()
        hl, intx = [], False
        for line in proc.stdout:
            s = line.rstrip("\n")
            if s.startswith("=== TRANSCRIPTION"): intx = True; continue
            if s.startswith("<<SEG_END>>"): break
            if intx and s.strip(): hl.append(s.strip())
        out.write(json.dumps({"id": uid, "ref": ref, "hyp": " ".join(hl)}, ensure_ascii=False) + "\n")
        out.flush()
        os.unlink(wav)
    proc.stdin.write("FLUSH\n"); proc.stdin.flush(); proc.stdin.close()
    try: proc.wait(timeout=60)
    except Exception: proc.kill()
    out.close()
    r = subprocess.run([VENV, "-c", KO_SCORE, hyp_path], capture_output=True, text=True)
    return r.stdout.strip()

utts = collect()
print(f"[fleurs] {len(utts)} utts × probs {PROBS}")
results = []
with open(OUTJ, "w") as oj:
    for prob in PROBS:
        t0 = time.time()
        line = run_prob(prob, utts)
        print(f"  VAD_PROB={prob}: {line}  ({time.time()-t0:.0f}s)", flush=True)
        results.append({"prob": prob, "result": line})
        oj.write(json.dumps({"prob": prob, "result": line}) + "\n"); oj.flush()
print("[fleurs] done →", OUTJ)
