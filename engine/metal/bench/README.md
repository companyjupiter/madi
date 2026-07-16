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
The latter gate uses the absolute unresolved-window count, not
`unresolved_initial_wrong_pct`: when a candidate removes first-seen errors but
does not yet fix the hard tail, the percentage rises only because its
denominator became smaller.
`REGR` also blocks on per-file tails; `NOISE` exits 2 when `--require-win` is
set. The pinned baseline at source commit `f62e596` includes segment-coherent
output and tentative-birth expiry: immediate DER mean 17.27%, wrong-visible
mean 13.04%, 39 absolute unresolved windows, correction p90 mean 19.73 s,
churn 6.25/min, and peak speaker overcount `0/1/0` for
`migzj/jnivh/gwtwd`.

The same gate also stratifies the first visible label by `diarAssign`'s
acoustic margin. On the pinned panel, real margins below `0.20` were wrong in
30/84 windows (35.7%), while margins in `[0.20, 1.0)` were wrong in only 3/181
(1.7%). A margin of exactly `1.0` is reported separately because the engine
uses it as a control-state sentinel before a second centroid exists or when a
speaker is born; it was wrong in 23/52 windows and must not be interpreted as
high acoustic confidence.

Live output is segment-coherent by default. The engine has already computed
every diarization embedding for the captured segment, so it coalesces any
same-segment tentative-birth/recluster repair before emitting the first `SPK`.
This does not move the captured-audio frontier and is exactly reversible with
`DIAR_SEGMENT_COHERENT=0`. On the pinned panel it reduced immediate DER from
19.38% to 17.27% and churn from 9.44 to 7.00/min while preserving wrong-visible
13.04%, first-label p90 11.0 s, all 39 unresolved windows, peak overcount
`0/1/1`, and final+OSD DER 10.87%.

Tentative auto-speaker evidence also expires after 4.5 seconds by default.
Previously, a singleton centroid could be matched by a different real speaker
tens of seconds later and that unrelated match counted as its second
confirmation. The expiry keeps the already-visible fallback label and starts a
new confirmation streak; `DIAR_CONFIRM_GAP_SEC=0` restores the old lifetime.
On the pinned panel this preserves DER, wrong-visible, all 39 unresolved
windows, first-label latency, correction latency, and final+OSD DER exactly,
while reducing churn from 7.00 to 6.25/min and peak overcount from `0/1/1` to
`0/1/0`. Across all 24 four-speaker VoxConverse-dev files, 23 were exact on
every live metric; only `gwtwd` changed, with churn 6.76→4.51/min and peak
overcount +1→0. File, final relabel, and final+OSD metrics were exact on all 24.

Confirmation evidence must also advance by one full 1.5-second embedding
window. The live runner carries three seconds of left context, so a newly born
speaker at 47.50 s can otherwise be "confirmed" by the next segment rewinding
to 47.00 s over the same audio. The duplicate embedding still updates the raw
centroid and remains available to reclustering; only the user-visible birth
streak ignores it. `DIAR_CONFIRM_MIN_ADV_SEC=0` restores the legacy behavior.
On the pinned panel this preserves DER, wrong-visible, all 39 unresolved
windows, latency, and peak overcount while reducing churn from 6.25 to
5.87/min. Across all 24 four-speaker files, mean DER changed 9.08→9.06,
churn 3.85→3.70/min, and total peak overcount 8→6 with no regression in the
strict correctness or latency gates.

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
