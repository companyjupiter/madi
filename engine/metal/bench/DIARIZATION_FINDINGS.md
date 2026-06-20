# Diarization findings — feature/embedding study (AMI ES2004a, collar 0.25s)

Rigorous, measured comparison of what actually separates speakers. md-eval.pl DER.

## DER by embedding source
| embedding | intra−inter sep | best K-means DER | note |
|---|---|---|---|
| Whisper **encoder** output | 0.007 ≈ 0 | ~90% (K=2) | speaker-invariant (ASR discards speaker id) — useless |
| raw **log-mel** (current Metal) | 0.22 | 65% (K=2), 67% (K=4) | works to ~2 speakers; can't count >2 (eigengap always ~2) |
| **CAM++** speaker embedding (onnx, offline) | (cos 0.57/0.45) | **47% (K=4)** | K-means elbow correctly at K=4 (73→62→**47**→50); real multi-speaker |
| oracle (true labels, 1.5s seg) | — | 29% | segmentation/VAD ceiling |

**Conclusion:** a dedicated speaker-embedding model is required for 4+ speakers.
CAM++ at K=4 (47%) beats mel (67%) and encoder (90%), and — unlike mel —
its cluster structure identifies the true speaker count. The 47%→29% gap is
our crude 1.5s segmentation (finer/overlapping windows + better clustering
would close it; production AMI systems reach ~20%).

## Speaker-count estimation
- **mel** eigengap → always ~2 (the mel ceiling), regardless of truth.
- **CAM++** silhouette/elbow correctly peaks near the true K.
- clova.wav (49 min Korean): CAM++ silhouette peaks at **K=2** (0.310,
  balanced 949/893) → ~2-person interview, not a 4+ speaker meeting.
  No ground-truth labels → qualitative only.

## Next Win: port a speaker-embedding model to Metal
CAM++ (D-TDNN + context-aware masking, 80-fbank → 512-d, 28 MB onnx) or
ECAPA-TDNN (Res2Net+SE+ASP, 192-d). Both are conv1d-stack networks — a
self-contained Metal port like the encoder/decoder. Objective target: beat
mel's 67% on AMI K=4 (CAM++ python baseline 47%). Validate with
`bench/ecapa_validate.py` (onnx reference) before/after the port.

## Qualitative 4-speaker demo (controlled, clean)
`bench/gen_demo4.py` builds a 4-speaker clip via macOS `say` (Alex/Samantha/
Daniel/Karen, 12 interleaved turns) + ground-truth RTTM. With the shipped
ResNet34 diarizer (K=4):
- **Global speaker identity is consistent** across all 3 rounds: Alex→spk0,
  Samantha→spk1, Daniel→spk2, Karen→spk3 (system timeline 0,1,2,3 ×3 == GT
  turn order). The Win: right speaker count + stable IDs over the whole clip.
- **DER 24.2%** (clean voices < AMI far-field 32.5%). Error is almost entirely
  one short-turn boundary (Samantha's first 4s window absorbed into Alex) —
  the 1.5s window granularity; finer/turn-aware windows would lower it.
```bash
python3 bench/gen_demo4.py
./out/transcribe assets/model.safetensors bench/demo4.wav assets/WHISPER_BPE.bin /tmp/d.rttm 4
perl bench/md-eval.pl -c 0.25 -r bench/demo4.ref.rttm -s /tmp/d.rttm | grep OVERALL
```

## Repro
```bash
python3 -m venv /tmp/diarvenv
/tmp/diarvenv/bin/pip install numpy scikit-learn onnxruntime kaldi-native-fbank
curl -sL https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/3dspeaker_speech_campplus_sv_en_voxceleb_16k.onnx -o bench/campplus.onnx
/tmp/diarvenv/bin/python bench/ecapa_validate.py bench/ES2004a.wav bench/ES2004a.ref.rttm ES2004a
```
