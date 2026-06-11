# Quality Benchmark — 4-axis verification (2026-06-10)

Measured on real recordings + standard references, in the product's priority
order: **diarization → transcription → timestamps → speed**. Every win
candidate below was verified (and counter-candidates reverse-verified) before
being listed. Build: main @ d6b2797 (decode 495 tok/s era).

Assets: AMI **ES2004a** (1049 s, 4-spk far-field) + ref.rttm, **demo4** (46 s,
4-spk clean TTS) + ref.rttm, scored with NIST **md-eval.pl** (collar 0.25);
**devops_ko** (462 s Korean podcast); **jfk** (11 s, known transcript);
whisper.cpp (same large-v3-turbo q8_0) as the cross-engine referee.

---

## 1. Diarization (화자 분리) — biggest verified win lives here

| path | ES2004a (far-field 4spk) | demo4 (clean 4spk) |
|---|---|---|
| **file mode** (batch k-means, end-of-file) | **32.55%** (= history 32.5, no regression) | **24.18%** (= history) |
| **live mode** (online leader-follower) | **38.33%**, K=8 over-split | **51.52%**, K=2 under-merged |
| live, DIAR_SIM=0.30 | 34.78%, still K=8 | 51.52%, still K=2 |

**Finding:** the live online clusterer is fragile in *both directions* — it
over-births speakers on far-field audio (8 vs true 4) and merges similar clean
voices (2 vs true 4). Knob tuning cannot fix both (verified: SIM sweep moves
ES2004a but not demo4; capping MAXK=4 makes ES2004a *worse*, 53.25%, because
early bad anchors get locked). Real 2-speaker close-mic audio (wife_conv
fixture) is fine on both paths.

> **WIN #1 (verified, largest): periodic re-clustering in live mode.**
> Accumulate window embeddings and every N windows re-run the batch k-means +
> silhouette auto-K (already in the binary: `kmeansFit`), remapping session ids
> stably. Ceiling = file-mode quality: **-5.8 pt DER far-field, -27 pt clean
> multi-speaker**. Touches the voiceprint id mapping (needs stable remap).

### WIN #1 — IMPLEMENTED (same day)

`DIAR_RECLUSTER` (default 16, 0=off): first recluster at 8 accepted windows,
then every 16; after the first recluster online births are suppressed (k-means
owns K, honoring a `DIAR_K` hint when given). Clusters remap to stable ids by
**majority vote of each cluster's already-emitted window ids** (continuity with
what the user saw — `--speakers "0=name"` and voiceprint claims stay correct);
tiny clusters (<3 windows) never mint ids. Streaming-emitted labels, measured:

| case | before | after |
|---|---|---|
| ES2004a live (far-field 4spk, auto-K) | 38.33% (K=8) | **35.06% (K=6)** |
| demo4 live + `DIAR_K=4` hint | 51.52% | **45.47%** |
| demo4 live auto-K | 51.52% | 51.52% (silhouette picks K=2 — same in file mode; pre-existing estimator limit, needs the K hint) |
| wife_conv (real 2-spk) | 2 main + 1 stray id | **exactly 2 speakers, ids 0/1, zero strays** |
| voiceprints / jfk file path | — | unchanged (regression PASS) |

Remaining headroom to the file-mode ceiling (~32.5%) is the *streaming penalty*:
labels emitted before early reclusters can't be retro-corrected on a console.

### Session-end relabel — IMPLEMENTED (same day)

On session end the runner sends `FLUSH`; the binary re-clusters the WHOLE
session, re-assigns every diar window to the final centroids (`SPKFIX` lines),
and the runner rewrites `.md`/`.srt` with the corrected speakers (+names). The
console stays streaming; the SAVED transcript gets end-of-session quality:

| saved-transcript labels (SPKFIX windows) | streaming | relabeled |
|---|---|---|
| demo4 + `DIAR_K=4` (short session) | 45.47% | **31.92%** |
| ES2004a (17 min) | 35.06% | 35.13% (≈same — long sessions are already post-recluster stable) |
| wife_conv + `--speakers "0=남편,1=아내"` | — | exactly 남편/아내, names preserved, zero strays |

Reverse-verified: restricting reassignment to the final k-means' ids was WORSE
(31.92→35.64 — stale centroids absorb coherent subsets); all-centroid
reassignment kept.

### Auto-K estimator study (2026-06-11) — silhouette wins, tau 0.10→0.35

Offline shoot-out on VoxConverse-dev (215 files, `diar_embed_wav` dumps,
`bench/k_study_vox.py` / `bench/k_sweep_vox.py`): the shipped silhouette
estimator beats eigengap (27% exact), NME-SC (51%), BIC and raw AHC; the
recursive 2-way split that fixes demo4's K=2 under-estimate offline
(sub-sils 0.55/0.59 on the merged TTS pairs) **over-splits real recordings at
every threshold** → REFUTED; demo4 auto-K stays a `DIAR_K`-hint case.

The verified win is the K=1 gate: **DIAR_SIL_TAU 0.10 → 0.35** flips five
true-single-speaker files to K=1 with ZERO multi-speaker false positives
across all 215 (first FP at 0.40), confirmed at the binary level:

| file (true 1 spk) | tau=0.10 | tau=0.35 |
|---|---|---|
| atgpi | 26.48% (K=2) | **0.38%** |
| qppll | 18.31% (K=2) | **1.40%** |
| qydmg | 57.50% (K=3) | **0.01%** |
| zmndm | 54.78% (K=4) | **0.66%** |
| zvmyn | 9.71% (K=2) | **3.52%** |

≈ −0.75 pt on the VoxConverse 215-file mean (17.50 → ~16.75%). Fixtures
unaffected (all sils ≥ 0.499): ES2004a auto-K 31.85% / forced-4 32.55%,
demo4 forced-4 24.18% — exact match with history; KO+EN fixture PASS.
Also: live reclusters now take the CLAIMED-voiceprint count as a K lower
bound (a claimed print is a voice-matched, present speaker).

### WIN #4 — sovereign Silero-VAD: speech validation (2026-06-11)

The next-win diagnosis (tucrg 26 s file / 4.5 s ref speech → DER 919%; pqmho
138 s / 14.9 s → 149%) exposed a structural flaw: the relative-RMS diar VAD
(>0.4×median) passes ~half the windows even when NOTHING is speech. Five
cheap discriminators were measured and refuted (PERF_LOG SV-1..5): absolute
RMS (music is LOUDER than far-field speech), <|nospeech|> (dead in
large-v3-turbo, P≈1e-10 on pure music), word-span gating (hallucinated words
spread over music; meetings lose overlap speech), embedding speech-direction,
2-8 Hz syllabic modulation (vocal music has it). A trained VAD is the only
separating signal.

**Shipped**: `vad_silero.zig` — sovereign CPU port of Silero-VAD v6 (16 kHz),
weights converted from whisper.cpp's ggml export (`bench/convert_silero.py`),
validated against the wcpp CLI segment-for-segment (±1 frame, 4 assets);
~170× realtime single-thread, run on its own thread overlapping the diar
embed pool. Three gates: diar windows w/o ≥0.25 s speech get RMS zeroed
(drops them on every path), chunks w/ <0.25 s speech skip encode/decode, and
timeline/RTTM segments are clipped to silero speech intervals (sub-window
precision). `DIAR_ONLY=1` mode added for ~25× faster DER sweeps.

| metric | before | after |
|---|---|---|
| **VoxConverse-dev 216-file MEAN DER** | 17.50% | **12.37%** (median 8.63→6.91; pyannote 3.1 ≈ 11.2) |
| K=1 bucket / K=3 bucket | 26.6% / 37.3% | **14.8% / 17.7%** |
| tucrg / pqmho (music-dominant) | 919% / 149% | 229.7% / 77.7% (residual = annotator-conservative refs) |
| ES2004a (far-field meeting, auto-K) | 31.85% | **26.44%** (−5.4 pt) |
| demo4 (K=4) | 24.18% | 24.67% (+0.5, tolerated) |
| KO+EN fixture / jfk word ts / test_decoder | PASS | **PASS** (jfk referee identical 4/5 ms) |
| clova 99 chunks + collapse rescues | 0 corrupted, 5 rescues | unchanged |
| devops_ko wall time | 32.8 s | 34.4 s (+4.6% — VAD threaded over diar, residual is the cost) |

### WIN #5 — bucket breakthrough: K-floor + speech-gate tuning (2026-06-11)

md-eval component decomposition on the two worst buckets found two separate
failure modes, each with its own fix (full trail in PERF_LOG B-1..B-8):

1. **K=3 bucket (miss-dominated)**: FA ≈ 0 but miss 12-27% while Silero's
   recall floor is 1-5% — the loss was OUR gating. Fixes: silero is now
   AUTHORITATIVE for window selection (crms binarized {0,1} — the old
   relative-RMS gate dropped quiet-speech windows), clip pad 30→200 ms,
   min-speech 250→60 ms (`VAD_PAD_MS`/`VAD_MIN_SPEECH_MS`).
2. **7+ bucket (confusion-dominated, 20-41%)**: the DIAR_MAXK=6 cap (5 of the
   worst 10 saturated at K=6). Raising the cap alone wrecks tiny single-spk
   files (silhouette splits hqyok's 14 windows into 10 "speakers", sil 0.835,
   57→77%); damaged vs helped files separate perfectly by window count
   (m=14-26 vs m≥79) → **windows-per-speaker floor**
   `maxK_eff = clamp(m/8, 2, 10)` (`DIAR_KWIN`, file mode; live stays maxK 8).
3. K=2↔3 estimator residue: margins ±0.03 both directions on cleaned
   embeddings — no safe lever, recursive split re-refuted.

| VoxConverse-dev 216 files | shipped | **now** |
|---|---|---|
| **mean / median** | 12.37% / 6.91% | **8.67% / 4.13%** — beats pyannote 3.1 (≈11.2%) |
| K=1 / K=2 / K=3 | 14.8 / 7.2 / 17.7 | **5.2 / 5.0 / 14.8** |
| K=4 / K=5-6 / K=7+ | 9.4 / 9.6 / 16.9 | **8.5 / 7.9 / 10.2** |
| ES2004a (far-field, auto-K) | 26.44% (K=5) | **18.83%** (forced K=4 identical — the gain is the speech gating, NOT the K pick; legacy-VAD forced-4 reproduces 32.55 exactly. auto-K picking the true 4 is a 0-DER side effect of cleaner embeddings) |
| demo4 (K=4) / KO+EN fixture / jfk | 24.67 / PASS / ok | **24.18 / PASS / unchanged** |

Bench infra hardened after a concurrent-run contamination incident: full_bench
takes an exclusive flock and a private per-run RTTM dir.

### WIN #6 — live silero clipping: saved transcripts reach file-mode quality (2026-06-11)

New harness `bench/live_der.py` replays the exact runner job structure (10 s
segments + 3 s left context) and scores both label streams. Diagnosis: live
SPK windows were raw 1.5 s grid blocks while file mode got silero interval
clipping — far-field silence became live FA (44.65% vs file 18.83%). Fix:
`SPK`/`SPKFIX` now emit silero-clipped pieces (4th duration field; the
runner's awk ignores it — backward compatible), and speech intervals
accumulate in stream mode too.

| ES2004a live | before | after |
|---|---|---|
| streaming console labels | 44.65% | **25.66%** |
| relabeled saved transcript | 37.54% | **18.43%** (= file mode 18.83%) |

KO+EN fixture PASS; file mode byte-identical. Overlap study (PERF_LOG
O-1..4): ES2004a ref overlap = **14.7% of scored time = the single-label miss
floor** (our 1-spk-region miss is just 7.2%); centroid-ambiguity and
transition-window detectors both refuted (precision ≤46% < break-even) — a
trained OSD (pyannote-segmentation-class port) is the recorded path.

### WIN #7 — sovereign OSD: pyannote segmentation-3.0 port (2026-06-11)

The single-label overlap floor (WIN #6 study) is now half-open. `osd_pyannote.zig`
ports pyannote segmentation-3.0 (SincNet → 4× BiLSTM → powerset-7) from the
sherpa-onnx ONNX export (`bench/convert_pyannote_seg.py`), validated against
onnxruntime to max |Δlogp| 3.5e-5 / 0 argmax mismatches, Accelerate-accelerated
413→90 ms per 10 s window (threaded over the diar pool).

Emission (file mode, default ON, `OSD=0` disables; live off for latency):
overlap frames (P(2-spk classes) ≥ 0.25) become SECOND-speaker RTTM rows.
Identity = **local-track mapping**: each local speaker's SOLO frames vote for
a global speaker, so the powerset pair names the global pair directly (the
turn-taking prior was the limiter — refuted at ~17.1%). Rows are clipped to
silero speech intervals and require an asserted primary (without those guards
the crowd-noise file tucrg exploded 232→462%; with them it residues at 356% —
real multi-voice the refs don't label, a known pathology). Crowd run-length
gating was reverse-verified harmful (ES 16.5→16.9) and rolled back.

| metric | before | after |
|---|---|---|
| ES2004a (4-spk far-field meeting) | 18.83% | **16.49%** (miss 16.0→12.5) |
| VoxConverse-dev 216 mean / median | 8.67 / 4.13% | **8.49 / 3.72%** |
| VoxConverse mean excl. tucrg | 7.63% | **6.87%** |
| K=2 / K=4 / K=5-6 / K=7+ buckets | 5.0 / 8.5 / 7.9 / 10.2 | **4.4 / 7.3 / 6.8 / 10.1** |
| demo4 (no overlap) / KO+EN fixture / jfk | 24.18 / PASS / ok | **24.18 (0 rows) / PASS / unchanged** |

Full refutation trail in PERF_LOG P-1..7 (sliding aggregation ≈ no gain,
probability-threshold saturation, crowd guard rollback).

## 2. Transcription quality (전사 품질)

- jfk: **WER 0.0%** (22/22 words).
- devops_ko 120 s, 3-way char-diff: ours-vs-wcpp-beam5 **2.7%**,
  wcpp-greedy-vs-beam5 9.4%, ours-vs-wcpp-greedy 10.0%.
  → **our greedy already sits at beam-5 level**; the residual 2.7% is
  punctuation/spacing/particles (spot-checked; substantive errors like
  "맘캐스트"=memcached are wrong in *both* engines — model-level).

> **Beam search: REFUTED as a win candidate** — ~0 quality headroom on clean
> speech for ~5× decode cost. Remaining candidates are model-level
> (code-switch vocabulary) or the SHARE-style n-gram repetition detector for
> noisy audio (no repro case in our assets; keep as a watch item, not a win).

### WIN #3 — hybrid collapse-rescue decode (2026-06-11, quark-led)

The repeat-loop watch item got its repro: clova (47 min KO meeting) has
**5/99 chunks fully destroyed** by greedy loops ("Q. Q. Q."×55) — ~2.5 min of
meeting content. The quark cross-reference against the new
`whisper_cpp/quality` tree (host-logic taxonomy) plus engine isolation found
the real mechanism: **NOT fallback/beam** (wcpp greedy `-nf -bs 1` transcribes
those chunks perfectly) but **timestamp-token decoding** — `whisper-cli -nt`
reproduces our identical collapse. The `<|t0|>…<|t1|>` segment structure is
the regularizer.

ts-mode is not a free lunch (each step measured, two shortcuts refuted):
- ts-mode **transliterates code-switch terms** ("architecture"→"아키텍츄럴",
  engine-independent — wcpp ts-greedy does it too), breaking the KO+EN fixture;
- ts-mode may close the window early (EOT at a pause) → OpenAI answers with
  seek + RE-ENCODE. Banning EOT instead → junk filler (". . . ~~", measured);
  re-decoding the same window with forced initial ts (± <|startofprev|>
  prompt) → out-of-distribution, re-transcribes the window start (measured);
- pure ts-mode even collapses on a DIFFERENT chunk set (11/99 tails like
  "네."×22 — disjoint from the no-ts set {4,63,65,80,86}).

**Shipped hybrid**: plain no-ts greedy by default (code-switch fidelity,
bit-identical text on clean assets) + token-periodicity collapse detector
(`tokenCollapse`: run ≥ max(16, 4p) of tok[i]==tok[i−p], p ≤ 8) + on
detection, re-decode the chunk with ts rules (`ts_rules_indirect`: OpenAI
R1-R4 incl. the logsumexp(ts) > max(text) mass rule on raw logits) and
OpenAI-faithful seek with re-encode of the remaining window.

| metric | before | after |
|---|---|---|
| clova repeat-corrupted chunks | 5/99 (×44-55 loops) | **0/99** (5 rescues fire, exactly the bad set) |
| rescued text vs wcpp reference | — | matches (NCM/LFP/모델링 content recovered) |
| KO+EN fixture | PASS | **PASS** (plain path preserved) |
| devops_ko / jfk text + word ts | — | bit-identical; acoustic referee unchanged (4/5 ms) |
| decode tok/s (devops_ko) | 497-521 | 495-511 (wall time +0.2% = noise) |
| false rescues on clean assets | — | 0 (jfk, devops_ko, wife, ES2004a) |

## 3. Word timestamps (타임스탬프)

Cross-engine on jfk (both DTW, same alignment heads): 22/22 words matched, both
monotonic, mean |Δ| 349 ms — but the bias is systematic (ours later on 20/22).
**Acoustic referee** (energy onsets after pauses, 20 ms resolution):

| word | acoustic onset | ours | whisper.cpp |
|---|---|---|---|
| "ask" #1 | 3.28 s | 3.68 (**+400 ms**) | 3.29 (**+10 ms**) |
| "ask" #2 | 8.18 s | 8.50 (**+320 ms**) | 8.19 (**+10 ms**) |

> **WIN #2 (verified): our DTW lags acoustic truth by ~350 ms; wcpp achieves
> ±10 ms.** Likely cause: OpenAI/wcpp z-normalize each alignment head's
> attention (and medfilt-7) *before* averaging + DTW; we average raw softmax
> rows (medfilt-3). The per-head scores are already available in the
> `flash_cross_attn` scratch (`ca_sc`), so per-head normalization is
> implementable (~16 MB to keep per-head rows for text tokens).

### WIN #2 — IMPLEMENTED (same day)

The z-norm hypothesis was only part of it; reverse-verification found the real
culprit chain (each step measured against the acoustic referee):

1. **OFF-BY-ONE (the big one):** the attention that *emits* text token i lives
   at decode position `SEED.len-1+i` (query = previous token); we read
   `SEED.len+i` — the attention emitting the NEXT token → ~one-token (~350 ms)
   systematic late bias. Confirmed by dumping per-position attention argmax
   (`TS_DIAG=1`): row p consistently sits on the audio of token p+1.
2. **Faithful OpenAI pipeline:** per-head planes ([6][MAX_TOK][ENC_SEQ], ca_accumulate
   now keeps heads separate), per-frame z-norm across tokens *per head* before
   averaging (the averaged-matrix shortcut was reverse-verified worse), median-7,
   frame clipping to actual audio, forced-endpoint (0,0)→(N-1,F-1) DTW.
3. **Pause-gated onset snap:** when a word's onset sits ≥160 ms before its raw
   attention rises to 15% of segment peak (i.e., the DTW boundary fell inside a
   pause), snap forward to the rise point. Normal words untouched.

| jfk vs whisper.cpp (acoustically ±10 ms) | before | after |
|---|---|---|
| mean abs Δ | 349 ms | **195 ms** |
| median | 320 ms | **160 ms** |
| max | 820 ms | **470 ms** |
| "ask"#1 / #2 vs acoustic onset | +400 / +320 ms | **+60 / −200 ms** |

Monotonicity preserved; transcript text unchanged; test_decoder OK; KO+EN live
regression PASS. Decode 495→~473 tok/s (−4%, per-head plane writes — accepted
for the accuracy). Residual vs wcpp's ±10 ms: pause/punctuation territory
splits; their batched forced-alignment pass remains slightly better.

### CORRECTION (2026-06-11) — the "wcpp DTW" referee was never DTW

`whisper-cli --dtw large.v3.turbo -ml 1` console spans are NOT DTW: flash-attn
(default on) silently disables DTW (`dtw_token_timestamps is not supported with
flash_attn`), and even with `--no-flash-attn` the console/`t0` numbers come
from the ENERGY-heuristic pass (`whisper_exp_compute_token_level_timestamps`);
`t_dtw` only surfaces in `-ojf` JSON. Re-run with real DTW shows **our DTW is
already at parity**: wcpp `t_dtw` end-times match our onsets token-shifted,
0–20 ms on 19/22 jfk words. wcpp's famous ±10 ms onsets are the energy snap,
not the alignment. And the heuristic itself is provably wrong where DTW isn't:
it puts jfk "And" at 0.10 s — inside silence (voice starts 0.33 s).

### WIN #2b — DTW + acoustic energy snap (2026-06-11)

New referee: `bench/acoustic_ref.py` derives an engine-independent voiced-
region table from the waveform (±2 ms envelope, 0.5×mean threshold) — six jfk
word onsets are acoustically decidable. `bench/ts_compare.py` automates the
word-by-word diff. The win: snap word ONSETS to voiced-region edges:

- onset in clear silence (<0.25×chunk-mean env) → snap RIGHT to the voice
  onset, capped at 400 ms (longer "pauses" are usually sustained soft speech);
- onset mid-voice whose voiced region starts after the previous word's onset
  → DTW was late, snap LEFT to the region start;
- ambiguous (0.25–0.5×mean, soft tails like jfk "so,") or region shared with
  the previous word (continuous speech) → keep DTW.

Threshold is CHUNK-global: a word-local window gets inflated by loud neighbors
(reverse-verified: local window read the "so," tail as silence → cascaded 3
words wrong). The attention-rise pause snap (WIN #2 step 3) stays: it composes
with the energy snap (reverse-verified: without it, raw DTW drops "ask"#2 to
7.78 s and the 400 ms cap blocks the energy fix). The eot-emitting attention
row (query = last text token) joins the DTW matrix per OpenAI/wcpp so the
forced endpoint lands on eot, not the last word (no jfk change; matters for
trailing-silence chunks). Per-slot 1 ms energy envelopes are computed at
gather time (`samples` is reused across the encoder batch).

| acoustically decidable onset | truth | before | after | wcpp console |
|---|---|---|---|---|
| And | 0.33 | 0.00 (−330) | **0.33 (0)** | 0.10 (−230) |
| my | 0.69 | 1.08 (+390) | **0.69 (0)** | 0.68 (−10) |
| Americans | 1.37 | 1.54 (+170) | **1.37 (0)** | 1.22 (−150) |
| ask #1 | 3.28 | 3.34 (+60) | **3.29 (+10)** | 3.29 (+10) |
| not | 4.03 | 3.80 (−230) | **4.03 (0)** | 4.01 (−20) |
| ask #2 | 8.18 | 7.98 (−200) | **8.20 (+20)** | 8.19 (+10) |

All six within ±20 ms — wcpp-level (and beating wcpp's console on 3/6).
Korean cross-check (devops_ko chunk 1): every pause-adjacent onset lands
exactly on its voiced-region start — 안녕하세요 0.03, 데바츠의 4.21, 데브옵스
5.24, Q&A 5.83 (0 ms each). Mid-voice boundaries keep DTW (energy cannot
split a continuous voiced run; that is model territory). jfk transcript/WER unchanged, test_decoder OK, KO+EN
fixture PASS, devops_ko 775 words 0 non-monotonic, decode ~495–514 tok/s
(envelope cost invisible). Diagnostic toggle: `TS_NOATTSNAP=1` disables the
attention snap.

### WIN #2c — word END times + automated acoustic referee (2026-06-11)

Word ends now flow through the whole pipeline. The DTW end (= next word's
refined onset) contracts LEFT out of trailing silence (min-envelope probe in
the 40-10 ms window before the boundary; clear-silence hysteresis 0.25×mean;
80 ms span floor for soft words). Console prints `[t0s-t1s]`, the live runner
parses both, `merge_seg.awk` carries ends into `@LINE`, and **.srt subtitles
now end when the voice stops** instead of at the last word's onset (verified:
wife_conv line ends no longer span pauses; a 750 ms gap stays subtitle-free).

`bench/acoustic_score.py` automates the referee at scale: every voiced-region
edge adjacent to a ≥150 ms pause is matched to the nearest word boundary
(±400 ms). Mid-voice boundaries stay unscored (energy can't adjudicate them).

| asset | pause-adjacent onsets | ends |
|---|---|---|
| jfk (11 s EN) | n=7, median **4 ms** | n=7, median **5 ms** |
| devops_ko (462 s KO podcast) | n=223, median **4 ms** | n=236, median **10 ms** |
| clova (47 min KO real meeting) | n=851, median 77 ms | n=857, median 140 ms |

clova includes overlapping speech + a known repeat-loop hallucination stretch;
sub-150 ms median on that audio is the honest hard-case number. jfk onsets
unchanged (ask#1 +10 ms / ask#2 +20 ms); transcript identical; KO+EN fixture
PASS; test_decoder OK.

### decode −4% — CLOSED, not reproducible (2026-06-11)

3-run paired A/B on devops_ko (batch 4): pre-WIN#2 (bff9b1c) 488/470/479 vs
current 494/480/479 tok/s — current ≥ pre on every pair. The recorded
495→473 was run-to-run variance (±2%), not a real regression. No recovery
work needed.

### WIN #8 — Metal-4 tensor-ops encoder, phase 1 (2026-06-11)

The "no cheap speed wins left / Metal-4 = endgame" item has begun. MSL 4
tensor views over raw device pointers (non-const — the mpp headers have no
const overloads) mean ZERO runtime changes: the in-shader `mpp::tensor_ops`
GEMM slots into the existing dispatch path. Untuned 64×64/4-simdgroup matmul
already edges MPS (3.64 vs 3.83 ms on the fc1 shape, max|Δ|=0), and the real
win is the fused epilogue: GEMM+bias and GEMM+bias+erf-GELU apply while the
tile is cache-hot, deleting the separate bias_add_f16/gelu_f16 full passes.
All 6 encoder GEMMs replaced; `ENC_M4=0` reverts to MPS.

| encoder ms/chunk | MPS | **Metal-4** |
|---|---|---|
| batch 4 (file mode, 3-run) | 569/568/569 | **511/512/511 (−10.1%)** |
| batch 1 (live-shaped) | 643-647 | **588** |
| whisper.cpp same model | 571 | — (first clear win) |

jfk words + spans byte-identical across paths; KO+EN fixture PASS;
test_decoder OK. Phase 2 roadmap (PERF_LOG M4-roadmap): Q8-direct GEMM
(half×int8 is a first-class tensor-ops combo — kills the 77 ms dequant and
halves weight traffic), then a tensor-ops rewrite of flash_attention_enc
(160 ms), and the int4 path when a Q4 model lands.

## 4. Speed (성능) — measured earlier this session

decode 233→**495 tok/s** (+112%, ahead of whisper.cpp ~1.3×); encoder
**597–650 ms/chunk** (batched file mode; wcpp 571); steady-state transcription
~tied/ahead. Remaining encoder gap is MPS-bound (Metal-4 tensor-ops would be
the endgame, multi-day). **No further cheap speed wins** — verified dead ends:
whole-layer fusion, concurrent dispatch, NR0 blocking, tiled dequant.

---

## Ranked win candidates (priority-ordered, all evidence-backed)

| # | dimension | win | size | effort |
|---|---|---|---|---|
| 1 | diarization | live periodic re-clustering (kmeans refresh + stable id remap) | **-6…-27 pt DER live** | medium |
| 2 | timestamps | per-head z-norm (+medfilt-7) before DTW | **~350 ms → ~10 ms onsets** | small-medium |
| 3 | quality | (watch) repetition detector for noisy audio | unproven here | small |
| — | speed | none cheap left (Metal-4 = endgame) | — | large |

Reproduce: `perl bench/md-eval.pl -c 0.25 -r bench/ES2004a.ref.rttm -s <sys.rttm>`;
live-path RTTM via `STREAM=1 DIAR=1` SPK lines → merge 1.5 s windows.
