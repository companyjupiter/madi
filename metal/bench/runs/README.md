# bench/runs/ — durable bench artifacts (contents gitignored, this README tracked)

**Rule: anything you'd be sad to lose goes here, never `/tmp`.**

A macOS periodic `/tmp` cleanup once deleted a full day of WER results
(datasets, venv, jsonls) mid-run. `/tmp` and `$TMPDIR` (`/var/folders/...`) are
both volatile — files can vanish during a long run and crash the next write.

This dir lives on the repo's real disk. Long-run harnesses default their
results / locks / caches / scratch here:

| harness | artifact |
|---|---|
| `wer_bench.py` / `wer_full_pipeline.sh` | `../wer_runs/`: datasets, venv, result jsonls, scratch |
| `full_bench.py` | `full_bench_results.jsonl`, lock, RTTM scratch (`scratch/`) |
| `k_sweep_vox.py` | `voxk_cache.jsonl` |

Results are append-only + resume-safe where the run is long (skip ids already
present). Scratch dirs are created under `scratch/` so a mid-run cleanup can't
crash them either.

Exploratory one-off tools (mel_validate, diar_sweep, estimate_k, asset-gen
gen_*) still use `/tmp` for transient scratch — losing it just reruns a quick
step, no durable result at stake.
