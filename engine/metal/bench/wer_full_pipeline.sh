#!/usr/bin/env bash
# wer_full_pipeline.sh — one-shot durable WER bench: fetch datasets if missing,
# run test-clean + test-other + FLEURS-ko sequentially (engine resident per
# split, resume-safe), score everything. All artifacts in bench/wer_runs/
# (gitignored, durable — /tmp got wiped by macOS cleanup and cost a day).
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # metal/
R=bench/wer_runs
D=$R/data
mkdir -p "$D"

fetch() { # url, dest-marker, extract-cmd
  local url=$1 marker=$2
  if [ ! -e "$marker" ]; then
    echo "[fetch] $url"
    curl -sL "$url" -o "$D/$(basename "$url")"
    tar xzf "$D/$(basename "$url")" -C "$D"
  fi
}

fetch https://www.openslr.org/resources/12/test-clean.tar.gz "$D/LibriSpeech/test-clean"
fetch https://www.openslr.org/resources/12/test-other.tar.gz "$D/LibriSpeech/test-other"
if [ ! -e "$D/fleurs_ko/test.tsv" ]; then
  mkdir -p "$D/fleurs_ko"
  curl -sL -o "$D/fleurs_ko/test.tsv" "https://huggingface.co/datasets/google/fleurs/resolve/main/data/ko_kr/test.tsv"
  curl -sL -o "$D/fleurs_ko/audio.tar.gz" "https://huggingface.co/datasets/google/fleurs/resolve/main/data/ko_kr/audio/test.tar.gz"
  tar xzf "$D/fleurs_ko/audio.tar.gz" -C "$D/fleurs_ko"
fi
echo "[data] clean=$(find "$D/LibriSpeech/test-clean" -name '*.flac' | wc -l) other=$(find "$D/LibriSpeech/test-other" -name '*.flac' | wc -l) fleurs=$(ls "$D/fleurs_ko/test" | wc -l)"

echo "═══ test-clean ═══"
python3 bench/wer_bench.py librispeech "$D/LibriSpeech/test-clean" --out "$R/test_clean.jsonl"
echo "═══ test-other ═══"
python3 bench/wer_bench.py librispeech "$D/LibriSpeech/test-other" --out "$R/test_other.jsonl"
echo "═══ FLEURS-ko ═══"
python3 bench/wer_bench.py fleurs "$D/fleurs_ko" --out "$R/fleurs_ko.jsonl"
echo "ALL-SPLITS-DONE"
