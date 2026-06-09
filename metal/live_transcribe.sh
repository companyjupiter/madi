#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# live_transcribe.sh — near-real-time meeting transcription (v2)
#
# Captures the microphone (or any avfoundation audio device) into rolling
# fixed-length WAV segments via ffmpeg, then transcribes each segment the moment
# it closes — printing a streaming, timestamped, speaker-attributed transcript.
#
# Two quality features over naive chunking:
#   1. SLIDING-WINDOW OVERLAP — each segment is transcribed with OVERLAP seconds
#      of left-context carried from the previous segment, and the trailing word
#      is held back one round, so words split across a boundary are recovered
#      instead of mangled ("country" not "company").
#   2. CONSISTENT SPEAKER IDS — a persistent online clusterer (online_diar) keeps
#      the SAME speaker id for the SAME voice across the whole session, unlike the
#      per-file diarizer whose labels reset every segment.
#
# Latency trails live audio by ~ SEG + OVERLAP + decode(~3s).
# True streaming (frame-level partials) is still not implemented.
#
# Usage:
#   ./live_transcribe.sh [device_index] [segment_seconds]
#
# List audio devices:
#   ffmpeg -f avfoundation -list_devices true -i "" 2>&1 | grep -A20 'audio devices'
#
# Environment knobs:
#   DEVICE    avfoundation audio device index           (default 2; 1st arg)
#   SEG       segment length seconds                    (default 10; 2nd arg)
#   OVERLAP   left-context carried per segment, seconds (default 3; 0 disables F1)
#   DIAR      1 → consistent speaker attribution (F2)   (default 1; 0 = text only)
#   DIAR_SIM  new-speaker cosine threshold              (default 0.50)
#   DIAR_MAXK max speakers in the session               (default 8)
#   LANG      Whisper language token id → WHISPER_LANG_ID (default auto)
#   MODEL/BPE/BIN  asset + binary paths
#   KEEP      1 → keep temp WAVs + speaker state on exit (default delete)
#
# Examples:
#   ./live_transcribe.sh                       # mic, 10s seg, overlap+diar on
#   ./live_transcribe.sh 3 8                   # "Microsoft Teams Audio", 8s
#   LANG=50264 ./live_transcribe.sh            # force Korean
#   OVERLAP=0 DIAR=0 ./live_transcribe.sh      # fastest, naive chunking
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"

DEVICE="${1:-${DEVICE:-2}}"
SEG="${2:-${SEG:-10}}"
OVERLAP="${OVERLAP:-3}"
DIAR="${DIAR:-1}"
DIAR_SIM="${DIAR_SIM:-0.40}"
DIAR_MAXK="${DIAR_MAXK:-8}"
MODEL="${MODEL:-assets/model.safetensors}"
BPE="${BPE:-assets/WHISPER_BPE.bin}"
BIN="${BIN:-out/transcribe}"
EMB="${EMB:-out/diar_embed_wav}"
CLUST="${CLUST:-out/online_diar}"
DIAR_W="${DIAR_W:-assets/resnet34_diar.bin}"
DIAR_MB="${DIAR_MB:-assets/kaldi_melbank.bin}"
KEEP="${KEEP:-0}"

# ── sanity checks ────────────────────────────────────────────────────────────
command -v ffmpeg >/dev/null || { echo "error: ffmpeg not found (brew install ffmpeg)"; exit 1; }
[ -x "$BIN" ]   || { echo "error: transcribe not built: $BIN (bash build.sh transcribe.zig)"; exit 1; }
[ -f "$MODEL" ] || { echo "error: model not found: $MODEL"; exit 1; }
[ -f "$BPE" ]   || { echo "error: BPE not found: $BPE"; exit 1; }
if [ "$DIAR" = "1" ]; then
  [ -x "$EMB" ] && [ -x "$CLUST" ] || { echo "error: diar tools missing ($EMB / $CLUST). Build: bash build.sh diar_embed_wav.zig ; zig build-obj -O ReleaseFast -lc --name online_diar -femit-bin=build/online_diar.o online_diar.zig && clang -O2 build/online_diar.o -o out/online_diar"; exit 1; }
  [ -f "$DIAR_W" ] && [ -f "$DIAR_MB" ] || { echo "error: diar assets missing. Run: bash bench/gen_diar_assets.sh"; exit 1; }
fi

WORK="$(mktemp -d -t live_whisper)"
FFLOG="$WORK/ffmpeg.log"
STATE="$WORK/spk_state.bin"      # persistent online-clustering centroids
emitted_until="-1"               # global time already printed (overlap dedup)
last_word=""                     # text of last emitted word (boundary text dedup)

cleanup() {
  [ -n "${FFPID:-}" ] && kill "$FFPID" 2>/dev/null || true
  wait "${FFPID:-}" 2>/dev/null || true
  if [ "$KEEP" = "1" ]; then echo ""; echo "[live] artifacts kept: $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT INT TERM

# REPLAY=<wav> processes a pre-recorded file through the identical
# overlap+diar pipeline (no mic). Useful for recorded meetings and for testing.
REPLAY="${REPLAY:-}"
if [ -n "$REPLAY" ]; then
  [ -f "$REPLAY" ] || { echo "error: REPLAY file not found: $REPLAY"; exit 1; }
  echo "[live] REPLAY=$REPLAY  seg=${SEG}s overlap=${OVERLAP}s diar=$DIAR lang=${LANG:-auto}"
  ffmpeg -hide_banner -loglevel error -i "$REPLAY" -ar 16000 -ac 1 \
    -f segment -segment_time "$SEG" -reset_timestamps 1 "$WORK/seg_%05d.wav" 2>"$FFLOG"
  FFPID=""                 # no live capture → ff_alive always 0 below
else
  echo "[live] device=$DEVICE seg=${SEG}s overlap=${OVERLAP}s diar=$DIAR lang=${LANG:-auto}"
  echo "[live] capturing… (Ctrl-C to stop)  tmp=$WORK"
  echo ""
  ffmpeg -hide_banner -loglevel error \
    -f avfoundation -i ":${DEVICE}" -ar 16000 -ac 1 \
    -f segment -segment_time "$SEG" -reset_timestamps 1 \
    "$WORK/seg_%05d.wav" >"$FFLOG" 2>&1 &
  FFPID=$!
fi

# transcribe one wav and emit "W <global_time> <word>" lines (global = off + local)
words_of() { # $1=wav  $2=global_start_offset
  env ${LANG:+WHISPER_LANG_ID=$LANG} "$BIN" "$MODEL" "$1" "$BPE" 2>/dev/null | awk -v off="$2" '
    /^=== WORD TIMESTAMPS/ { m=1; next }
    /^=== /                { m=0 }
    m && /^[[:space:]]*\[/ {
      t=$0; sub(/^[[:space:]]*\[/,"",t); sub(/s\].*/,"",t);
      w=$0; sub(/^[[:space:]]*\[[^]]*\][[:space:]]*/,"",w);
      if (w!="") printf "W %.2f %s\n", off + t, w
    }'
}

# minimum samples diar_embed_wav needs (one 1.5s window @16kHz) to avoid div-by-0
DIAR_MIN_DUR="1.6"

# speaker labels for a disjoint segment → "S <global_time> <spk>" lines
labels_of() { # $1=wav  $2=global_start_offset  $3=idx
  [ "$DIAR" = "1" ] || return 0
  # too-short segments (final tail) → no diar window; skip (also avoids segfault)
  local dur; dur=$(ffprobe -v error -show_entries format=duration -of default=nk=1:nw=1 "$1" 2>/dev/null || echo 0)
  awk -v d="$dur" -v m="$DIAR_MIN_DUR" 'BEGIN{exit !(d>=m)}' || return 0
  local emb="$WORK/emb_$3.bin"
  "$EMB" "$1" "$DIAR_W" "$DIAR_MB" "$emb" >/dev/null 2>&1 || return 0
  "$CLUST" "$STATE" "$emb" "$2" "$DIAR_SIM" "$DIAR_MAXK" 2>/dev/null \
    | awk '{print "S " $1 " " $2}'
}

process_segment() { # $1=idx  $2=cur.wav  $3=prev.wav  $4=final(0/1)
  local i="$1" cur="$2" prev="$3" final="$4"
  local S=$((i * SEG)) in_wav in_start
  if [ "$i" -eq 0 ] || [ "$OVERLAP" -eq 0 ] || [ ! -f "$prev" ]; then
    in_wav="$cur"; in_start="$S"
  else
    # combined = last OVERLAP s of prev + cur  (left-context for boundary words).
    # per-segment temp names so nothing is reused across iterations.
    local tail="$WORK/tail_$i.wav" comb="$WORK/comb_$i.wav" cat="$WORK/cat_$i.txt"
    ffmpeg -hide_banner -loglevel error -ss $((SEG - OVERLAP)) -i "$prev" -ar 16000 -ac 1 "$tail" 2>/dev/null
    printf "file '%s'\nfile '%s'\n" "$tail" "$cur" > "$cat"
    ffmpeg -hide_banner -loglevel error -f concat -safe 0 -i "$cat" -ar 16000 -ac 1 "$comb" 2>/dev/null
    in_wav="$comb"; in_start=$((S - OVERLAP))
  fi

  local merged new_emit new_last
  merged=$( { labels_of "$cur" "$S" "$i"; words_of "$in_wav" "$in_start"; } \
    | awk -f merge_seg.awk -v emitted="$emitted_until" -v final="$final" \
          -v diar="$DIAR" -v prevword="$last_word" )

  # print transcript lines only; carry control state (emitted time, last word) forward
  printf '%s\n' "$merged" | grep -v '^@' || true
  new_emit=$(printf '%s\n' "$merged" | awk '/^@EMITTED/{print $2}')
  new_last=$(printf '%s\n' "$merged" | sed -n 's/^@LASTWORD //p')
  [ -n "$new_emit" ] && emitted_until="$new_emit"
  [ -n "$new_last" ] && last_word="$new_last"
}

idx=0; processed=-1; waited=0
echo "[live] waiting for first ${SEG}s segment…"
while true; do
  if [ "$processed" -lt 0 ] && [ ! -f "$WORK/seg_00000.wav" ] && [ "$waited" -gt 16 ]; then
    echo "[live] no audio after ~$((waited / 2))s — grant Microphone access to your"
    echo "       terminal: System Settings → Privacy & Security → Microphone, then re-run."
    waited=0
  fi
  next=$(printf '%s/seg_%05d.wav' "$WORK" $((idx + 1)))
  cur=$(printf '%s/seg_%05d.wav'  "$WORK" "$idx")
  prev=$(printf '%s/seg_%05d.wav' "$WORK" $((idx - 1)))
  ff_alive=1; kill -0 "$FFPID" 2>/dev/null || ff_alive=0

  if [ -f "$next" ] || { [ "$ff_alive" -eq 0 ] && [ -f "$cur" ]; }; then
    if [ -f "$cur" ] && [ "$idx" -gt "$processed" ]; then
      final=0; { [ "$ff_alive" -eq 0 ] && [ ! -f "$next" ]; } && final=1
      printf '\n── segment %d @ %02d:%02d ──\n' "$idx" $(( (idx*SEG)/60 )) $(( (idx*SEG)%60 ))
      process_segment "$idx" "$cur" "$prev" "$final"
      processed=$idx
    fi
    idx=$((idx + 1))
    if [ "$ff_alive" -eq 0 ] && [ ! -f "$next" ]; then
      echo ""; echo "[live] capture stopped — transcript complete."; break
    fi
  else
    if [ "$ff_alive" -eq 0 ]; then echo "[live] ffmpeg exited. log:"; cat "$FFLOG" 2>/dev/null; break; fi
    sleep 0.5; waited=$((waited + 1))
  fi
done
