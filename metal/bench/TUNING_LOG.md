# Diarization tuning loop — VoxConverse dev (12 diverse files), md-eval collar 0.25

Autonomous grid search over (DIAR_SIL_TAU × DIAR_MAXK × DIAR_VAD). Each row =
one combo's mean DER. Baseline (auto-K defaults tau=0.10 maxK=8 vad=0.30) = 10.52%.
SOTA reference: pyannote 3.1 ≈ 11.2% on VoxConverse.

| # | params | mean DER | best so far |
|---|--------|----------|-------------|
