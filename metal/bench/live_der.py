#!/usr/bin/env python3
"""Live-path DER harness: replay a wav through the resident STREAM pipeline
exactly like live_transcribe.sh (SEG s jobs + OV s left context), collect the
streaming SPK lines and the FLUSH-time SPKFIX lines, score both as RTTM.

Usage: live_der.py <wav> <ref.rttm> [SEG=10] [OV=3]
Outputs: streaming DER (console labels) and relabeled DER (saved transcript).
SPK dedupe: a window re-emitted by the next job's overlap keeps the LATEST
label (recluster-corrected), matching what the saved transcript would use.
"""
import os, re, subprocess, sys, tempfile

wav, ref = sys.argv[1], sys.argv[2]
SEG = float(sys.argv[3]) if len(sys.argv) > 3 else 10.0
OV = float(sys.argv[4]) if len(sys.argv) > 4 else 3.0
M = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # metal/

dur = float(subprocess.run(['ffprobe', '-v', 'error', '-show_entries', 'format=duration',
                            '-of', 'default=nk=1:nw=1', wav], capture_output=True, text=True).stdout)
tmp = tempfile.mkdtemp(prefix='live_der_')
jobs = []
i = 0
while i * SEG < dur:
    s = max(i * SEG - (OV if i > 0 else 0), 0)
    e = min(i * SEG + SEG, dur)
    seg = os.path.join(tmp, f'seg{i:05d}.wav')
    subprocess.run(['ffmpeg', '-y', '-loglevel', 'error', '-ss', str(s), '-t', str(e - s),
                    '-i', wav, '-ar', '16000', '-ac', '1', seg])
    jobs.append((s, seg))
    i += 1

feed = ''.join(f'{s} {p}\n' for s, p in jobs) + 'FLUSH\n'
env = {**os.environ, 'STREAM': '1', 'DIAR': '1'}
out = subprocess.run([f'{M}/out/transcribe', f'{M}/assets/model.safetensors', '/dev/null',
                      f'{M}/assets/WHISPER_BPE.bin'],
                     input=feed, env=env, capture_output=True, text=True, cwd=M).stdout

spk = {}     # piece start -> (id, dur); re-emitted overlap pieces keep the LATEST label
spkfix = {}
for line in out.splitlines():
    m = re.match(r'(SPKFIX|SPK) ([0-9.]+) (\d+)(?: ([0-9.]+))?$', line)
    if m:
        d = (spkfix if m.group(1) == 'SPKFIX' else spk)
        d[round(float(m.group(2)), 2)] = (int(m.group(3)), float(m.group(4) or 1.5))

def rttm_of(labels, path, fid):
    with open(path, 'w') as f:
        for t in sorted(labels):
            sid, dur = labels[t]
            f.write(f'SPEAKER {fid} 1 {t:.3f} {dur:.3f} <NA> <NA> spk{sid} <NA> <NA>\n')

def der(sys_rttm):
    ev = subprocess.run(['perl', f'{M}/bench/md-eval.pl', '-c', '0.25', '-r', ref, '-s', sys_rttm],
                        capture_output=True, text=True).stdout
    m = re.search(r'OVERALL SPEAKER DIARIZATION ERROR = ([0-9.]+)', ev)
    return m.group(1) if m else '?'

fid = os.path.basename(ref).split('.')[0]
rttm_of(spk, f'{tmp}/stream.rttm', fid)
print(f'windows: stream={len(spk)} relabel={len(spkfix)}  (jobs={len(jobs)})')
print(f'STREAMING DER = {der(f"{tmp}/stream.rttm")}%')
if spkfix:
    rttm_of(spkfix, f'{tmp}/relabel.rttm', fid)
    print(f'RELABELED DER = {der(f"{tmp}/relabel.rttm")}%')
print(f'(rttms in {tmp})')
