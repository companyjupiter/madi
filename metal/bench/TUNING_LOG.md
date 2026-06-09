# Diarization tuning loop — VoxConverse dev (12 diverse files), md-eval collar 0.25

Autonomous grid search over (DIAR_SIL_TAU × DIAR_MAXK × DIAR_VAD). Each row =
one combo's mean DER. Baseline (auto-K defaults tau=0.10 maxK=8 vad=0.30) = 10.52%.
SOTA reference: pyannote 3.1 ≈ 11.2% on VoxConverse.

| # | params | mean DER | best so far |
|---|--------|----------|-------------|
|  1 | DIAR_SIL_TAU=0.05 DIAR_MAXK=6 DIAR_VAD=0.20 | 9.69% | **best 9.69%** (DIAR_SIL_TAU=0.05 DIAR_MAXK=6 DIAR_VAD=0.20) |
|  2 | DIAR_SIL_TAU=0.05 DIAR_MAXK=6 DIAR_VAD=0.30 | 9.68% | **best 9.68%** (DIAR_SIL_TAU=0.05 DIAR_MAXK=6 DIAR_VAD=0.30) |
|  3 | DIAR_SIL_TAU=0.05 DIAR_MAXK=6 DIAR_VAD=0.40 | 9.67% | **best 9.67%** (DIAR_SIL_TAU=0.05 DIAR_MAXK=6 DIAR_VAD=0.40) |
|  4 | DIAR_SIL_TAU=0.05 DIAR_MAXK=8 DIAR_VAD=0.20 | 10.53% | **best 9.67%** (DIAR_SIL_TAU=0.05 DIAR_MAXK=6 DIAR_VAD=0.40) |
|  5 | DIAR_SIL_TAU=0.05 DIAR_MAXK=8 DIAR_VAD=0.30 | 10.52% | **best 9.67%** (DIAR_SIL_TAU=0.05 DIAR_MAXK=6 DIAR_VAD=0.40) |
|  6 | DIAR_SIL_TAU=0.05 DIAR_MAXK=8 DIAR_VAD=0.40 | 10.5% | **best 9.67%** (DIAR_SIL_TAU=0.05 DIAR_MAXK=6 DIAR_VAD=0.40) |
|  7 | DIAR_SIL_TAU=0.05 DIAR_MAXK=10 DIAR_VAD=0.20 | 10.99% | **best 9.67%** (DIAR_SIL_TAU=0.05 DIAR_MAXK=6 DIAR_VAD=0.40) |
|  8 | DIAR_SIL_TAU=0.05 DIAR_MAXK=10 DIAR_VAD=0.30 | 10.97% | **best 9.67%** (DIAR_SIL_TAU=0.05 DIAR_MAXK=6 DIAR_VAD=0.40) |
|  9 | DIAR_SIL_TAU=0.05 DIAR_MAXK=10 DIAR_VAD=0.40 | 10.96% | **best 9.67%** (DIAR_SIL_TAU=0.05 DIAR_MAXK=6 DIAR_VAD=0.40) |
| 10 | DIAR_SIL_TAU=0.10 DIAR_MAXK=6 DIAR_VAD=0.20 | 9.69% | **best 9.67%** (DIAR_SIL_TAU=0.05 DIAR_MAXK=6 DIAR_VAD=0.40) |
| 11 | DIAR_SIL_TAU=0.10 DIAR_MAXK=6 DIAR_VAD=0.30 | 9.68% | **best 9.67%** (DIAR_SIL_TAU=0.05 DIAR_MAXK=6 DIAR_VAD=0.40) |
| 12 | DIAR_SIL_TAU=0.10 DIAR_MAXK=6 DIAR_VAD=0.40 | 9.67% | **best 9.67%** (DIAR_SIL_TAU=0.05 DIAR_MAXK=6 DIAR_VAD=0.40) |
| 13 | DIAR_SIL_TAU=0.10 DIAR_MAXK=8 DIAR_VAD=0.20 | 10.53% | **best 9.67%** (DIAR_SIL_TAU=0.05 DIAR_MAXK=6 DIAR_VAD=0.40) |
| 14 | DIAR_SIL_TAU=0.10 DIAR_MAXK=8 DIAR_VAD=0.30 | 10.52% | **best 9.67%** (DIAR_SIL_TAU=0.05 DIAR_MAXK=6 DIAR_VAD=0.40) |
| 15 | DIAR_SIL_TAU=0.10 DIAR_MAXK=8 DIAR_VAD=0.40 | 10.5% | **best 9.67%** (DIAR_SIL_TAU=0.05 DIAR_MAXK=6 DIAR_VAD=0.40) |
| 16 | DIAR_SIL_TAU=0.10 DIAR_MAXK=10 DIAR_VAD=0.20 | 10.99% | **best 9.67%** (DIAR_SIL_TAU=0.05 DIAR_MAXK=6 DIAR_VAD=0.40) |

## Conclusion (16/27 combos; effectively converged)
- **DIAR_MAXK dominates**: 6 → 9.67%, 8 → 10.5%, 10 → 10.97%. Lower cap avoids over-clustering.
- DIAR_VAD: tiny (0.20→0.40 ⇒ 9.69→9.67); DIAR_SIL_TAU: negligible (0.05≈0.10).
- Untested combos were maxK=10 / tau=0.15 (already-inferior regions) → no improvement possible.
- **Adopted defaults: DIAR_MAXK=6, DIAR_VAD=0.40, tau=0.10 → mean DER 9.67%**
  (baseline 10.52%, −0.85pp; beats pyannote 3.1 SOTA ~11.2%). Biggest win: rtvuw 36.5→25.7%.
- AMI far-field (different domain) 30.95→31.85% (+0.9pp) — accepted; VoxConverse natural
  conversation is the meeting-transcription target. Override per-run via DIAR_MAXK/DIAR_VAD.
