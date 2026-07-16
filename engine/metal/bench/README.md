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

## Focused 3-4 speaker panel gate
`diar_panel_eval.py` compares auto-K against forced-K on the same clip and
prints DER components (miss / false alarm / speaker confusion). This is the
triage harness for YouTube or panel-style failures where a 3-4 speaker clip
collapses to too few speakers.

```bash
# Reproduce known VoxConverse tail cases. Add --live to score the user-visible
# STREAM path; --live-no-recluster is a diagnostic for recluster regressions.
python3 bench/diar_panel_eval.py --vox-id migzj --vox-id jnivh --speakers-from-ref \
  --live --live-no-recluster

# Local or YouTube input needs a reference RTTM for objective DER.
python3 bench/diar_panel_eval.py --audio panel.wav --ref panel.rttm --id panel --speakers 4 --live
python3 bench/diar_panel_eval.py --youtube-url 'https://youtu.be/...' --ref panel.rttm --id panel --speakers 4 --live
```

Outputs are written under `bench/runs/diar_panel_<timestamp>/`:
`results.jsonl`, `summary.md`, and the generated system RTTMs.

### Live time-to-correct / immediate UX gate

`--live` also reconstructs the labels visible after every `SPK` and
mid-session `SPKFIX`. The event clock is the captured-audio frontier of the
segment whose output precedes `<<SEG_END>>`; corrections emitted after the last
segment (`FLUSH`) are excluded from live UX and remain part of the saved-output
DER gate. The summary reports:

- first-label latency p50/p90 and first-seen DER;
- wrong-visible ratio: reference-wrong label exposure integrated until the end
  of the live session;
- time-to-stable-correct p50/p90 and the initially-wrong windows that never
  became correct during the session;
- label churn/minute and peak/final visible speaker count.

System ids are mapped one-to-one to reference speakers by maximum overlap on
the final mid-session visible state. Extra transient ids remain unmapped, so a
3-person panel briefly shown as 4 speakers is penalized instead of hidden by a
many-to-one mapping.

The pinned 3-4 speaker baseline is `bench/live_ux_baseline_3to4spk.jsonl`.
Compare a candidate run with the asymmetric no-regression gate:

```bash
python3 bench/live_ux_gate.py \
  bench/live_ux_baseline_3to4spk.jsonl bench/runs/<candidate> --require-win
```

`WIN` requires a material improvement on at least one immediate UX axis.
Primary correctness is Pareto-strict: mean wrong-visible may regress by at
most 0.05 point and no additional initially-wrong window may remain unresolved.
`REGR` also blocks on per-file tails; `NOISE` exits 2 when `--require-win` is
set. Two identical baseline runs on 2026-07-16 were exactly
deterministic: immediate DER mean 19.38%, wrong-visible mean 13.04%, unresolved
initial errors 65.42%, correction p90 mean 18.03 s, churn 9.44/min, and peak
speaker overcount `0/1/1` for `migzj/jnivh/gwtwd`.

The same gate also stratifies the first visible label by `diarAssign`'s
acoustic margin. On the pinned panel, real margins below `0.20` were wrong in
30/84 windows (35.7%), while margins in `[0.20, 1.0)` were wrong in only 3/181
(1.7%). A margin of exactly `1.0` is reported separately because the engine
uses it as a control-state sentinel before a second centroid exists or when a
speaker is born; it was wrong in 23/52 windows and must not be interpreted as
high acoustic confidence.

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
