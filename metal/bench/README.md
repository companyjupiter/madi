# Diarization benchmark harness

Objective DER (Diarization Error Rate) measurement against AMI ground truth.
Large data files (`*.wav`, `*.rttm`, `md-eval.pl`, `*.bin`) are git-ignored —
regenerate with the commands below.

## Setup
```bash
cd metal
# ground-truth RTTM (AMI ES2004a, 4 speakers, 17.5 min)
curl -sL https://raw.githubusercontent.com/pyannote/AMI-diarization-setup/main/only_words/rttms/test/ES2004a.rttm -o bench/ES2004a.ref.rttm
# audio (16 kHz mono, 32 MB)
curl -sL "https://groups.inf.ed.ac.uk/ami/AMICorpusMirror/amicorpus/ES2004a/audio/ES2004a.Mix-Headset.wav" -o bench/ES2004a.wav
# NIST scorer
curl -sL https://raw.githubusercontent.com/nryant/dscore/master/scorelib/md-eval-22.pl -o bench/md-eval.pl
```

## Run + score
```bash
# diarize → system RTTM (4th arg), K speakers (5th arg)
./out/transcribe assets/model.safetensors bench/ES2004a.wav assets/WHISPER_BPE.bin /tmp/sys.rttm 2
perl bench/md-eval.pl -c 0.25 -r bench/ES2004a.ref.rttm -s /tmp/sys.rttm | grep "OVERALL SPEAKER DIARIZATION ERROR"
```

## Offline clustering sweep (fast iteration without the encoder pass)
`DIAR_DUMP=/tmp/raw.bin ./out/transcribe ... ` dumps raw-mel segment features;
`bench/mel_k.py`, `bench/mel_validate.py` sweep clustering params + score DER via
a venv with numpy/scikit-learn:
```bash
python3 -m venv /tmp/diarvenv && /tmp/diarvenv/bin/pip install numpy scikit-learn
/tmp/diarvenv/bin/python bench/mel_k.py
```

## Asset regeneration integrity
`bench/gen_diar_assets.sh` pins its direct Python build dependencies and verifies
the downloaded wespeaker ONNX, pyannote archive, and extracted pyannote ONNX with
SHA-256 before generating assets. Update those hashes in the script only after
manually reviewing the upstream artifact change.

## Results (AMI ES2004a, collar 0.25s)
| approach | DER |
|---|---|
| single-speaker baseline | 87.5% |
| encoder-feature clustering (old) | ~90% (encoder is speaker-invariant) |
| **mel k-means K=2 (this build)** | **65%** |
| mel k-means K=4 | 76% (feature-limited on far-field; better on clean audio) |
| oracle (true labels, our 1.5s segmentation) | 24% (segmentation ceiling) |

Raw log-mel carries speaker timbre/pitch (intra−inter cosine separation 0.22)
vs the Whisper encoder output (0.007 ≈ none). For SOTA DER a dedicated speaker
embedding model (ECAPA/x-vector) would be needed.
