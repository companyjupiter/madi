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
