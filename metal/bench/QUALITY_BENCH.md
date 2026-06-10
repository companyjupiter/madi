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
