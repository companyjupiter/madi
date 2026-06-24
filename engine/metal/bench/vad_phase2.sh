#!/usr/bin/env bash
# Phase 2: after the GPU-bound DER campaign frees the GPU, run the language-axis
# WER sweep (FLEURS-ko) + the GT-less natural-KO speech-retention probe.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."   # metal/
LOG=bench/runs/vad_phase2.log
: > "$LOG"
say_log() { echo "[phase2 $(date +%H:%M:%S)] $*" | tee -a "$LOG"; }

say_log "waiting for vad_campaign.py to finish…"
while pgrep -f vad_campaign.py >/dev/null 2>&1; do sleep 20; done
say_log "campaign done ($(wc -l < bench/runs/vad_campaign.jsonl) rows). starting WER sweep."

# 1) FLEURS-ko CER vs VAD_PROB (language axis, transcription)
FLEURS_N=80 VAD_PROBS=0.3,0.5,0.7,0.85,0.95 python3 bench/fleurs_vad_sweep.py >>"$LOG" 2>&1
say_log "fleurs sweep done."

# 2) natural KO recordings → 16k mono → one VAD_DUMP pass → offline retention curve
mkdir -p bench/runs/natko
declare -a SRC=(
  "$HOME/Downloads/한국 IT의 어두운 면_ 클라우드 기술, 자만심의 허상.wav|hankit|0"
  "$HOME/Downloads/clova.m4a|clova|600"
  "$HOME/Downloads/devart-.m4a|devart|600"
)
for spec in "${SRC[@]}"; do
  IFS='|' read -r src tag clip <<<"$spec"
  [ -f "$src" ] || { say_log "missing $src"; continue; }
  wav="bench/runs/natko/${tag}.wav"
  if [ "$clip" = "0" ]; then
    ffmpeg -y -loglevel error -i "$src" -ar 16000 -ac 1 -c:a pcm_s16le "$wav"
  else
    ffmpeg -y -loglevel error -t "$clip" -i "$src" -ar 16000 -ac 1 -c:a pcm_s16le "$wav"
  fi
  say_log "transcribe+dump $tag ($(du -h "$wav" | cut -f1))"
  DIAR_ONLY=1 VAD_DUMP="bench/runs/natko/${tag}.bin" \
    ./out/transcribe assets/model.safetensors "$wav" assets/WHISPER_BPE.bin "bench/runs/natko/${tag}.rttm" \
    >>"$LOG" 2>&1
  python3 bench/vad_dump_probe.py "bench/runs/natko/${tag}.bin" "$tag-KO-natural" >>"$LOG" 2>&1
done
say_log "PHASE2_DONE"
