#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# live_transcribe.sh — near-real-time meeting transcription
#
# Captures the microphone (or any avfoundation audio device) into rolling
# fixed-length WAV segments via ffmpeg, then feeds each finalized segment to the
# sovereign-whisper `transcribe` binary as soon as it closes. Prints a running,
# timestamped transcript — useful for live meetings / lectures.
#
# This is the "near-real-time" path: each N-second segment is transcribed after
# it closes, so the transcript trails live audio by roughly N + (~3s decode).
# True streaming (sliding window, partial results, online diarization) is NOT
# implemented — see README "실시간으로 쓰려면".
#
# Usage:
#   ./live_transcribe.sh [device_index] [segment_seconds]
#
#   device_index     avfoundation audio device index (default: env DEVICE or 2)
#   segment_seconds  segment length in seconds      (default: env SEG or 10)
#
# List audio devices:
#   ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -A20 'audio devices'
#
# Environment knobs:
#   MODEL   path to model.safetensors      (default: assets/model.safetensors)
#   BPE     path to WHISPER_BPE.bin        (default: assets/WHISPER_BPE.bin)
#   BIN     path to transcribe binary      (default: out/transcribe)
#   DIAR    1 → also print per-segment speaker-attributed lines (labels are
#           per-segment only; Speaker 0 in segment A ≠ Speaker 0 in segment B)
#   LANG    Whisper language token id, forwarded as WHISPER_LANG_ID
#           (e.g. 50264 Korean, 50259 English; default: auto-detect)
#   KEEP    1 → keep the temp segment WAVs on exit (default: deleted)
#
# Examples:
#   ./live_transcribe.sh                 # mic [2], 10s segments, auto language
#   ./live_transcribe.sh 3 8             # capture "Microsoft Teams Audio", 8s
#   LANG=50264 DIAR=1 ./live_transcribe.sh   # Korean + per-segment speakers
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail

cd "$(dirname "$0")"

DEVICE="${1:-${DEVICE:-2}}"
SEG="${2:-${SEG:-10}}"
MODEL="${MODEL:-assets/model.safetensors}"
BPE="${BPE:-assets/WHISPER_BPE.bin}"
BIN="${BIN:-out/transcribe}"
DIAR="${DIAR:-0}"
KEEP="${KEEP:-0}"

# ── sanity checks ────────────────────────────────────────────────────────────
command -v ffmpeg >/dev/null || { echo "error: ffmpeg not found (brew install ffmpeg)"; exit 1; }
[ -x "$BIN" ]   || { echo "error: transcribe binary not built: $BIN (run: bash build.sh transcribe.zig)"; exit 1; }
[ -f "$MODEL" ] || { echo "error: model not found: $MODEL"; exit 1; }
[ -f "$BPE" ]   || { echo "error: BPE not found: $BPE"; exit 1; }

WORK="$(mktemp -d -t live_whisper)"
FFLOG="$WORK/ffmpeg.log"

cleanup() {
  # stop the capture, then optionally wipe segments
  [ -n "${FFPID:-}" ] && kill "$FFPID" 2>/dev/null || true
  wait "${FFPID:-}" 2>/dev/null || true
  if [ "$KEEP" = "1" ]; then
    echo ""
    echo "[live] segments kept in: $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT INT TERM

echo "[live] device=$DEVICE  segment=${SEG}s  diar=$DIAR  lang=${LANG:-auto}"
echo "[live] capturing… (Ctrl-C to stop)  tmp=$WORK"
echo ""

# ── start the rolling capture ────────────────────────────────────────────────
# 16 kHz mono PCM (what whisper expects), one WAV per SEG seconds. Each file is
# finalized when the next segment begins, so we process file i once i+1 appears.
ffmpeg -hide_banner -loglevel error \
  -f avfoundation -i ":${DEVICE}" \
  -ar 16000 -ac 1 \
  -f segment -segment_time "$SEG" -reset_timestamps 1 \
  "$WORK/seg_%05d.wav" >"$FFLOG" 2>&1 &
FFPID=$!

# extract just the spoken text (and optional speaker lines) from transcribe out.
# awk captures the TRANSCRIPTION block and, if DIAR=1, the speaker-attributed one.
parse_out() {
  awk -v diar="$DIAR" '
    /^=== TRANSCRIPTION/        { mode="txt"; next }
    /^=== SPEAKER-ATTRIBUTED/   { mode=(diar=="1"?"spk":"off"); next }
    /^=== /                     { mode="off"; next }
    mode=="txt" && NF           { sub(/^ +/,""); print "  " $0 }
    mode=="spk" && /Speaker/    { sub(/^ +/,""); print "    " $0 }
  '
}

idx=0
processed=-1
waited=0
echo "[live] waiting for first ${SEG}s segment…"
while true; do
  # macOS mic-permission guard: if nothing is captured well past the first
  # segment boundary, the controlling terminal almost certainly lacks the
  # Microphone privacy grant (ffmpeg blocks silently on the TCC prompt).
  if [ "$processed" -lt 0 ] && [ ! -f "$WORK/seg_00000.wav" ] && [ "$waited" -gt 16 ]; then
    echo "[live] no audio after ~$((waited / 2))s — grant Microphone access to your"
    echo "       terminal: System Settings → Privacy & Security → Microphone,"
    echo "       then re-run. (ffmpeg log: $FFLOG)"
    waited=0
  fi
  # a segment is safe to read once the *next* one exists (ffmpeg finalized it),
  # or once ffmpeg has exited (flush the final, possibly-short segment).
  next=$(printf '%s/seg_%05d.wav' "$WORK" $((idx + 1)))
  cur=$(printf '%s/seg_%05d.wav'  "$WORK" "$idx")

  if [ -f "$next" ] || { ! kill -0 "$FFPID" 2>/dev/null && [ -f "$cur" ]; }; then
    if [ -f "$cur" ] && [ "$idx" -gt "$processed" ]; then
      start=$((idx * SEG))
      printf '\n── [%02d:%02d] segment %d ──\n' $((start / 60)) $((start % 60)) "$idx"
      env ${LANG:+WHISPER_LANG_ID=$LANG} \
        "$BIN" "$MODEL" "$cur" "$BPE" 2>/dev/null | parse_out || \
        echo "  (transcribe failed for segment $idx)"
      processed=$idx
    fi
    idx=$((idx + 1))
    # ffmpeg gone and we've drained every produced segment → done
    if ! kill -0 "$FFPID" 2>/dev/null && [ ! -f "$next" ]; then
      echo ""
      echo "[live] capture stopped — transcript complete."
      break
    fi
  else
    # nothing new yet; if ffmpeg died early, surface its log
    if ! kill -0 "$FFPID" 2>/dev/null; then
      echo "[live] ffmpeg exited. log:"; cat "$FFLOG" 2>/dev/null
      break
    fi
    sleep 0.5
    waited=$((waited + 1))   # ~0.5s per tick; coarse but enough for the guard
  fi
done
