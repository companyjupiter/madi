#!/usr/bin/env python3
"""feed_der.py — score the live STREAM pipeline from a PRE-MADE feed file.

Unlike live_der.py (which slices segments with ffmpeg), this takes a feed.txt
produced by the NATIVE capture path (app/Tools/capture_verify segment), so the
ONLY difference vs the ffmpeg reference is how the 16 kHz segments were made
(AVAudioConverter resample + native Segmenter vs ffmpeg). This is the Stage-1
audio-capture parity gate: native-path DER must match the ffmpeg-path DER and
the established baseline.

Usage: feed_der.py <feed.txt> <ref.rttm>
  feed.txt lines: "<offset> <segment.wav>" ... then "FLUSH"
"""
import os, re, subprocess, sys, tempfile

feed_path, ref = sys.argv[1], sys.argv[2]
M = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # metal/
tmp = tempfile.mkdtemp(prefix='feed_der_')

feed = open(feed_path).read()
if 'FLUSH' not in feed:
    feed = feed.rstrip() + '\nFLUSH\n'

env = {**os.environ, 'STREAM': '1', 'DIAR': '1'}
out = subprocess.run([f'{M}/out/transcribe', f'{M}/assets/model.safetensors', '/dev/null',
                      f'{M}/assets/WHISPER_BPE.bin'],
                     input=feed, env=env, capture_output=True, text=True, cwd=M).stdout

spk, spkfix, spkov = {}, {}, []
for line in out.splitlines():
    m = re.match(r'(SPKFIX|SPKOV|SPK) ([0-9.]+) (\d+)(?: ([0-9.]+))?$', line)
    if not m:
        continue
    if m.group(1) == 'SPKOV':
        spkov.append((float(m.group(2)), int(m.group(3)), float(m.group(4) or 1.5)))
    else:
        d = spkfix if m.group(1) == 'SPKFIX' else spk
        d[round(float(m.group(2)), 2)] = (int(m.group(3)), float(m.group(4) or 1.5))

fid = os.path.basename(ref).split('.')[0].split('_')[0]

def rttm_of(labels, path):
    with open(path, 'w') as f:
        for t in sorted(labels):
            sid, dur = labels[t]
            f.write(f'SPEAKER {fid} 1 {t:.3f} {dur:.3f} <NA> <NA> spk{sid} <NA> <NA>\n')

def der(sys_rttm):
    ev = subprocess.run(['perl', f'{M}/bench/md-eval.pl', '-c', '0.25', '-r', ref, '-s', sys_rttm],
                        capture_output=True, text=True).stdout
    m = re.search(r'OVERALL SPEAKER DIARIZATION ERROR = ([0-9.]+)', ev)
    return m.group(1) if m else '?'

rttm_of(spk, f'{tmp}/stream.rttm')
print(f'windows: stream={len(spk)} relabel={len(spkfix)}')
print(f'STREAMING DER = {der(f"{tmp}/stream.rttm")}%')
if spkfix:
    rttm_of(spkfix, f'{tmp}/relabel.rttm')
    print(f'RELABELED DER = {der(f"{tmp}/relabel.rttm")}%')
print(f'(rttms in {tmp})')
