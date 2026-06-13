#!/usr/bin/env bash
# wcpp_wer.sh — whisper.cpp referee pass for the WER bench (지피지기).
# Same data, same model+quant (ggml-large-v3-turbo-q8_0) as our engine run.
# Multiple files per invocation = ONE model load per batch (not per utt).
#
# Usage: wcpp_wer.sh <LibriSpeech/test-* dir> <out.jsonl> [batch=200]
set -euo pipefail
ROOT="${1:?LibriSpeech split dir}"
OUT="${2:?output jsonl}"
BATCH="${3:-200}"
WCPP="$HOME/antigravity/whisper.cpp"
CLI="$WCPP/build/bin/whisper-cli"
MODEL="$WCPP/models/ggml-large-v3-turbo-q8_0.bin"
W="$(mktemp -d /tmp/wcpp_wer_XXXX)"

# 16k wavs (wcpp wants wav; flac support varies by build)
echo "[1/3] flac → wav"
find "$ROOT" -name '*.flac' | sort | while read -r f; do
  b="$(basename "$f" .flac)"
  [ -f "$W/$b.wav" ] || ffmpeg -y -loglevel error -i "$f" -ar 16000 -ac 1 "$W/$b.wav"
done
N=$(ls "$W" | wc -l | tr -d ' ')
echo "  $N wavs"

echo "[2/3] wcpp batched transcription (batch=$BATCH, one model load per batch)"
ls "$W"/*.wav | split -l "$BATCH" - "$W/batch_"
for bf in "$W"/batch_*; do
  # -otxt writes <wav>.txt next to each input; -nt no timestamps; -np quiet
  xargs -a "$bf" "$CLI" -m "$MODEL" -l en -nt -np -otxt >/dev/null 2>&1 || true
done

echo "[3/3] collect → $OUT"
: > "$OUT"
find "$ROOT" -name '*.trans.txt' | sort | while read -r tf; do
  while IFS=' ' read -r uid ref; do
    txt="$W/$uid.wav.txt"
    hyp=""
    [ -f "$txt" ] && hyp="$(tr '\n' ' ' < "$txt")"
    python3 -c "import json,sys; print(json.dumps({'id':sys.argv[1],'ref':sys.argv[2],'hyp':sys.argv[3]}, ensure_ascii=False))" \
      "$uid" "$ref" "$hyp" >> "$OUT"
  done < "$tf"
done
echo "done: $(wc -l < "$OUT") rows  (score: python3 bench/wer_bench.py rescore $OUT)"
