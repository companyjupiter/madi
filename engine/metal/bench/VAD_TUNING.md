# VAD threshold tuning — per-language × per-speaker (2026-06-25)

Goal: find the right Silero speech-probability threshold (`VAD_PROB`) per **language**
and per **speaker setting**, with objective WER/DER. The threshold was previously
**hardcoded 0.5** (whisper.cpp default) at three sites; this study exposed it as an
env knob and swept it.

## Engine change (this study)
`VAD_PROB` / `VAD_NEG` env (default 0.5 / prob−0.15) now drive all three Silero
gate sites — chunk-skip ([transcribe.zig](../transcribe.zig) ~1341), diar window
selection (~1391), and the segment state machine ([vad_silero.zig](../vad_silero.zig) ~232).
`VAD_DUMP=<path>` dumps per-window embeddings + **raw per-frame silero probs** so a
threshold/sp_gate sweep is reproducible offline from one encoder pass.

## Method
- **DER** (diarization): real engine, DIAR_ONLY, auto-K, md-eval collar 0.25, per-file.
  Sweep `VAD_PROB ∈ {0.2,0.35,0.5,0.65,0.8,0.9}`.
  Assets: VoxConverse-dev **216** (bucketed 1-spk=22 / 2-spk=44 / multi=150) +
  AMI **ES2004a** (far-field 4-spk) + KO TTS fixtures ko1/ko2/ko4.
  MISS/FA/CONF decomposed by re-scoring all 1320 saved RTTMs.
- **CER/WER** (transcription): FLEURS-ko 80 utts × prob (KO read-speech, language axis).
- **Retention** (GT-less natural KO): hankit/clova/devart — speech kept vs threshold.
- Drivers: `vad_campaign.py`, `vad_rescore_components.py`, `fleurs_vad_sweep.py`,
  `vad_dump_probe.py`, `vad_analyze.py`. Parallel cell analysis + adversarial
  critique via `vad_workflow.mjs`.

## Faithfulness check
VoxConverse-216 mean DER @ prob=0.5 = **7.82%** (reproduces shipped history ~8.5%
band); AMI 15.57% (history 15.57 w/ AGC). Harness reproduces the production pipeline.

## Results

### DER vs VAD_PROB (mean % of scored time)
| cell | n | 0.2 | 0.35 | 0.5 | 0.65 | 0.8 | 0.9 | shape |
|---|---|---|---|---|---|---|---|---|
| EN close-mic 1-spk | 22 | 2.27 | 1.94 | 1.84 | **1.84** | 1.87 | 1.91 | flat basin |
| EN close-mic 2-spk | 44 | 4.82 | 4.45 | 4.41 | **4.38** | 4.87 | 4.01* | flat; 0.9 = praxo outlier |
| EN close-mic multi | 150 | 10.37 | 9.99 | 9.70 | 9.21 | 9.08 | 8.61* | mean ↓ but tucrg-driven |
| **EN far-field (AMI)** | 1 | **15.25** | 15.27 | 15.57 | 15.81 | 17.89 | 18.72 | **monotone ↑ (miss-dominated)** |
| KO clean TTS | 3 | 1.04 | 1.04 | 1.04 | 1.04 | 1.04 | 1.04 | dead flat (FA=conf=0) |

\* outlier-driven — see robustness below.

### VoxConverse-216 robust view (median kills outliers)
| | 0.2 | 0.35 | 0.5 | 0.65 | 0.8 | 0.9 |
|---|---|---|---|---|---|---|
| mean | 8.41 | 8.04 | 7.82 | 7.48 | 7.49 | 6.99 |
| **median** | 3.62 | 3.49 | 3.51 | 3.57 | 3.57 | 3.51 |
| mean excl tucrg | 6.79 | 6.48 | 6.40 | 6.32 | 6.42 | 6.29 |

Median is **flat (~3.5%) across the whole sweep**. Only `tucrg` (DER ~357%, the
known crowd-noise / annotator-conservative pathology from QUALITY_BENCH WIN#7)
exceeds 50%; it alone manufactures the mean's downward slope.

### KO transcription (FLEURS-ko, 80 utts)
CER = **4.23%**, WER 15.30%, empty 0 — **identical at every prob 0.3→0.95**. Hyps
byte-identical through 0.7; clean loud read-speech never trips the chunk-skip gate,
so `VAD_PROB` is a no-op for KO dictation.

### Natural KO speech-retention (no GT — % windows kept)
| | 0.1 | 0.3 | 0.5 | 0.7 | 0.9 | 90%-keep knee |
|---|---|---|---|---|---|---|
| hankit (clean monologue) | 100 | 100 | 100 | 100 | 100 | none |
| clova (49-min real meeting) | 92.5 | 91.2 | 90.2 | 89.0 | 82.5 | 0.9 |
| **devart (real podcast)** | 93.5 | 85.8 | 78.8 | 71.8 | 51.2 | **0.4** |

## Findings

1. **The optimum splits by ACOUSTIC CONDITION, not by language.** Clean / close-mic
   / read-speech (EN 1/2/multi, KO clean, KO read) is FA-dominated or VAD-insensitive
   — DER/CER spread ≤0.5pp across the whole sweep, median dead flat. Far-field /
   quiet / reverberant real audio (AMI, natural KO podcast) is **miss-dominated**:
   a stricter gate drops quiet/distant real speech. AMI miss% rises 9.9→15.9 across
   the sweep (DER monotone 15.25→18.72) — the exact opposite slope from the clean
   cells. devart loses real speech above its 0.4 retention knee.

2. **`VAD_PROB` barely matters for the common path.** For everything close-mic/clean
   the current 0.5 sits in a flat basin; the apparent EN "0.8–0.9 wins" are single
   pathological files (praxo −39pp in 2-spk; tucrg in multi) — per-file win-rate of
   those optima vs 0.5 is <0.5 (they lose on the majority of files).

3. **Korean has no language-specific optimum.** KO clean and KO read are insensitive;
   KO *natural* behaves like a fragile far-field case (retention, not DER).

## AMI far-field validation — n=1 → n=6 (the critique's load-bearing follow-up)

`bench/ami_validate.py` fetched Array1-01 (far-field mic) audio + manual word
annotations for 5 more meetings and swept VAD_PROB DER. **Result: far-field is
HETEROGENEOUS — there is no safe single far-field threshold.**

| meeting | 0.2 | 0.35 | 0.5 | 0.65 | 0.8 | 0.9 | best |
|---|---|---|---|---|---|---|---|
| ES2004a | 15.2 | 15.3 | 15.6 | 15.8 | 17.9 | 18.7 | **0.2** |
| ES2004b | 36.2 | 36.3 | 36.4 | 12.0 | 12.8 | 13.5 | **0.65** (cliff) |
| ES2004c | 27.9 | 28.1 | 28.4 | 28.6 | 28.9 | 29.4 | **0.2** |
| ES2004d | 43.7 | 43.3 | 43.4 | 43.8 | 44.6 | 45.7 | **0.35** |
| IS1000a | 53.0 | 51.4 | 51.1 | 51.2 | 52.1 | 53.2 | **0.5** |
| TS3003a | 25.4 | 28.1 | 30.0 | 32.1 | 35.0 | 38.0 | **0.2** |
| MEAN | 33.6 | 33.7 | 34.1 | 30.6 | 31.9 | 33.1 | (0.65*) |
| MEAN excl ES2004b | 33.0 | 33.2 | 33.7 | 34.3 | 35.7 | 37.0 | **0.2** |

- **5/6 prefer ≤0.5** (4 strictly 0.2–0.35; TS3003a strong: 25.4@0.2 → 38.0@0.9).
  Excluding ES2004b the mean is **monotone increasing** → the original "far-field →
  looser gate" direction holds for the majority. The n=1 finding is corroborated *in
  direction* but its exact 0.2 value is session-dependent.
- **ES2004b is a stark counterexample:** a looser gate (≤0.5 all ≈36%) collapses to
  12% only at ≥0.65 — a diarization clustering / auto-K artifact (loose gate admits
  noise windows → phantom speakers → confusion explosion), NOT pure VAD miss/FA. So
  `VAD_PROB` is **entangled with the clusterer** on far-field audio.
- The aggregate-mean "0.65 wins" is **entirely** the ES2004b cliff.

## Recommendation (revised after AMI n=6)

### Shipped: per-speaker-count default (app)
The app maps the user's 화자 수 setting to each bucket's outlier-robust optimum
(`SpeakerCount.vadProb` → env `VAD_PROB`):

| 화자 수 setting | VAD_PROB | basis |
|---|---|---|
| auto / 1명 | **0.5** | flat basin; 1-spk K=1 is VAD-irrelevant |
| 2명 | **0.65** | 2-spk DER optimum (raw 0.9 was a praxo outlier) |
| 3명 / 4명+ | **0.8** | multi optimum (outlier-excluded curve bottoms 0.65–0.8) |

Rationale: more speakers ⇒ more cross-talk/backchannel false-speech ⇒ a stricter
gate trims FA. **Validated under forced-K** (the app forces DIAR_MAXK=count, not the
sweep's auto-K): multi maxK=8 0.5→0.8 = 4.89→4.58 (−0.31pp); 2-spk maxK=2 neutral
(1.29=1.29); 1-spk K=1 VAD-irrelevant. No regression; clean-audio gains are within
noise (≤~0.3pp) — the mapping sits each setting on its measured min, costing nothing.

| Other condition | VAD_PROB | Confidence |
|---|---|---|
| **Far-field / meeting** | **no fixed value** | heterogeneous (see AMI n=6) |

- **Keep the global default 0.5 for all conditions.** Clean/close-mic/read is
  VAD-insensitive; far-field is heterogeneous with no safe single shift (a 0.3
  "meeting profile" helps 5/6 by ~0.7pp mean but is **catastrophic on ES2004b**:
  36% vs 12%). 0.5 is the best single value: within-noise-best for IS1000a, near-best
  for ES2004c/d, only modestly behind 0.2 for ES2004a/TS3003a.
- **Do NOT ship a fixed far-field profile.** No low value escapes the ES2004b collapse
  (it persists across 0.2–0.5). Tried-and-reverted: a `farFieldMode → VAD_PROB=0.3`
  app toggle (EngineProcess/SessionController/SettingsView) — refuted by this data.
- `VAD_PROB`/`VAD_NEG` remain exposed as **engine env knobs** for per-recording expert
  tuning, not auto-applied. `VAD_DUMP` enables offline per-recording sweeps.
- **Do not** adopt 0.65/0.8 for EN conversational — ties within noise, outlier-driven.

## Caveats / follow-up
1. **`VAD_PROB` is entangled with auto-K diarization on far-field audio** (ES2004b
   cliff). The real far-field lever is likely the *clusterer's* noise robustness
   (DIAR_VAD_SP / min-window-per-speaker), not the speech threshold alone. Highest-value
   next step: decompose ES2004b's 0.5→0.65 cliff (does K-count / confusion% jump?) and
   test whether a fixed clustering floor removes the VAD sensitivity.
2. KO real-audio rec is from **retention, not DER** (no KO diarization ground truth;
   natko/*.rttm are the system's own hypotheses, never score DER against them).
3. KO clean fixtures are synthetic TTS (n=3), prob-insensitive — zero pull on the default.
4. FLEURS read-speech is single-chunk → structurally insensitive to `VAD_PROB`; it
   confirms a *keep*, cannot justify a *change*.
