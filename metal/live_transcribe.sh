#!/usr/bin/env bash
# ─────────────────────────────────────────────────────────────────────────────
# live_transcribe.sh — near-real-time meeting transcription
#
# Captures the microphone (or any avfoundation audio device) into rolling
# fixed-length WAV segments via ffmpeg, then transcribes each segment the moment
# it closes — printing a streaming, timestamped, speaker-attributed transcript.
#
# Two quality features over naive chunking:
#   1. SLIDING-WINDOW OVERLAP — each segment is transcribed with OVERLAP seconds
#      of left-context from the previous segment (trailing word held back one
#      round), so words split across a boundary are recovered, not mangled.
#   2. CONSISTENT SPEAKER IDS — a persistent online clusterer keeps the SAME
#      speaker id for the SAME voice across the whole session.
#
# Run `live_transcribe.sh --help` for the full option list.
# ─────────────────────────────────────────────────────────────────────────────
set -euo pipefail
cd "$(dirname "$0")"

VERSION="1.0"

# ── defaults (env vars are honored as defaults; CLI flags override them) ──────
DEVICE="${DEVICE:-2}"
SEG="${SEG:-10}"
OVERLAP="${OVERLAP:-3}"
DIAR="${DIAR:-1}"
DIAR_SIM="${DIAR_SIM:-0.40}"
DIAR_MAXK="${DIAR_MAXK:-8}"
RESIDENT="${RESIDENT:-1}"        # 1 = keep model resident across segments (no reload)
MD_FILE="${MD_FILE:-}"           # append a Markdown transcript here
SRT_FILE="${SRT_FILE:-}"         # append SRT subtitles here
COLOR="${COLOR:-auto}"           # auto|always|never — colourize speakers on the console
SPK_NAMES="${SPK_NAMES:-}"       # "0=Alice,1=Bob" — show real names for speaker ids
VP_DIR="${VP_DIR:-}"             # voiceprint dir: auto-recognize enrolled voices + enroll named ones
LANGTOK="${WHISPER_LANG_ID:-}"   # numeric token; "" = auto. (NOT the locale $LANG)
REPLAY="${REPLAY:-}"
DURATION="${DURATION:-}"
KEEP="${KEEP:-0}"
MODEL="${MODEL:-assets/model.safetensors}"
BPE="${BPE:-assets/WHISPER_BPE.bin}"
BIN="${BIN:-out/transcribe}"
EMB="${EMB:-out/diar_embed_wav}"
CLUST="${CLUST:-out/online_diar}"
DIAR_W="${DIAR_W:-assets/resnet34_diar.bin}"
DIAR_MB="${DIAR_MB:-assets/kaldi_melbank.bin}"
MODE=""

# map a friendly language name (or raw token) → Whisper language token id
resolve_lang() {
  case "$1" in
    ko|kr|korean|한국어) echo 50264 ;;
    en|eng|english|영어)  echo 50259 ;;
    ja|jp|japanese)       echo 50266 ;;
    zh|cn|chinese)        echo 50260 ;;
    auto|"")              echo "" ;;
    *[!0-9]*)             echo "__ERR__" ;;   # not a number and not a known name
    *)                    echo "$1" ;;         # raw numeric token
  esac
}

# apply a scenario preset. Sets the same vars; explicit flags parsed AFTER win.
apply_mode() {
  case "$1" in
    ko|korean)       LANGTOK=50264; DIAR=1; SEG=8 ;;
    en|english)      LANGTOK=50259; DIAR=1; SEG=8 ;;
    meeting)         DIAR=1; SEG=10; OVERLAP=3; DIAR_MAXK=8 ;;          # auto lang, multi-speaker
    ko-meeting)      LANGTOK=50264; DIAR=1; SEG=10; OVERLAP=3; DIAR_MAXK=8 ;;
    en-meeting)      LANGTOK=50259; DIAR=1; SEG=10; OVERLAP=3; DIAR_MAXK=8 ;;
    dictation|mono)  DIAR=0; SEG=8;  OVERLAP=3 ;;                       # single speaker, text only
    fast)            DIAR=0; SEG=5;  OVERLAP=2 ;;                       # lowest latency
    auto)            : ;;                                              # plain defaults
    *) echo "error: unknown --mode '$1' (try: ko, en, meeting, ko-meeting, en-meeting, dictation, fast, auto)"; exit 1 ;;
  esac
}

print_help() {
  cat <<EOF
live_transcribe.sh v$VERSION — near-real-time meeting transcription (Apple Silicon / Metal)

USAGE
  ./live_transcribe.sh [options]

MODES  (--mode <name>: a preset bundle of sensible defaults; any flag overrides it)
  ko            Korean forced, speakers on, 8s segments
  en            English forced, speakers on, 8s segments
  meeting       multi-speaker, 10s segments, auto language
  ko-meeting    Korean  + meeting preset
  en-meeting    English + meeting preset
  dictation     single speaker (no diarization), text only
  fast          lowest latency (5s segments, 2s overlap, no diarization)
  auto          plain defaults (auto language, speakers on)   [default]

OPTIONS
  -m, --mode <name>     scenario preset (see MODES)
  -d, --device <n>      avfoundation audio device index            (default $DEVICE)
  -s, --seg <sec>       segment length; longer = better diarization (default $SEG)
  -o, --overlap <sec>   left-context per segment; 0 disables boundary recovery (default $OVERLAP)
  -l, --lang <id>       ko|en|ja|zh|auto or a raw token id          (default auto)
      --diar <0|1>      consistent speaker attribution on/off       (default $DIAR)
      --no-diar         shortcut for --diar 0
      --sim <f>         new-speaker cosine threshold (lower=fewer)   (default $DIAR_SIM)
      --maxk <n>        max speakers in the session                 (default $DIAR_MAXK)
      --duration <sec>  stop after N seconds (else run until Ctrl-C)
      --replay <wav>    transcribe a recorded file instead of the mic (no mic needed)
      --md <file>       also write a Markdown transcript
      --srt <file>      also write SRT subtitles
      --color <when>    auto|always|never — colourize speakers on the console (default auto)
      --no-color        shortcut for --color never
      --speakers <map>  name speakers, e.g. "0=Alice,1=Bob" (console + .md + .srt)
      --voiceprints <dir>  voice enrollment: auto-recognize voices enrolled in <dir>
                        ("Speaker 0" → "Alice" by voice alone); speakers you name
                        with --speakers are (re-)enrolled at session end. Resident
                        mode only. Match threshold: env VP_SIM (default 0.40).
      --keep            keep temp WAVs + speaker state on exit
      --model/--bpe/--bin <path>   override asset/binary paths
  -h, --help            show this help and exit
      --list-devices    list avfoundation audio devices and exit
      --version         print version and exit

EXAMPLES
  ./live_transcribe.sh --mode ko-meeting              # Korean multi-speaker meeting
  ./live_transcribe.sh -m ko-meeting --md notes.md --srt notes.srt   # + save files
  ./live_transcribe.sh -m en -s 8 --duration 60       # English, 8s, stop after 60s
  ./live_transcribe.sh -m fast                        # quick low-latency notes
  ./live_transcribe.sh --replay meeting.m4a -m ko     # transcribe a recording in Korean
  ./live_transcribe.sh --list-devices                 # find your mic's index

NOTES
  • Forcing --lang avoids per-segment language mis-detection on short/ambiguous
    audio (e.g. "아아" mis-read as another language). Use it for known-language
    meetings; keep auto only for genuinely mixed-language sessions.
  • A hallucination guard drops invented words in near-silent stretches (loud
    speech is always kept). Tune via env HALLU_RMS (default 0.020), VAD_THRESH
    (0.010), or disable with HALLU_GUARD=0.
  • First run prompts macOS for Microphone access for the app hosting this shell
    (Terminal / iTerm / Claude). Grant it in System Settings → Privacy → Microphone.
EOF
}

# ── parse CLI (flags override env/defaults; --mode preset applies first) ──────
# pre-scan for --mode so explicit flags after it still win
_args=("$@")
for ((_i=0; _i<${#_args[@]}; _i++)); do
  case "${_args[_i]}" in
    -m|--mode) MODE="${_args[_i+1]:-}";;
    --mode=*)  MODE="${_args[_i]#*=}";;
  esac
done
[ -n "$MODE" ] && apply_mode "$MODE"

while [ $# -gt 0 ]; do
  case "$1" in
    -h|--help)      print_help; exit 0 ;;
    --version)      echo "live_transcribe.sh v$VERSION"; exit 0 ;;
    --list-devices)
      echo "avfoundation audio devices (use the index with --device):"
      { ffmpeg -f avfoundation -list_devices true -i "" 2>&1 \
        | awk '/audio devices:/{a=1;next} /video devices:/{a=0} a && /\] \[[0-9]+\]/{sub(/^\[[^]]*\] /,"  "); print}'; } || true
      exit 0 ;;
    -m|--mode)      shift 2 ;;                       # already applied in pre-scan
    --mode=*)       shift ;;
    -d|--device)    DEVICE="$2"; shift 2 ;;
    --device=*)     DEVICE="${1#*=}"; shift ;;
    -s|--seg)       SEG="$2"; shift 2 ;;
    --seg=*)        SEG="${1#*=}"; shift ;;
    -o|--overlap)   OVERLAP="$2"; shift 2 ;;
    --overlap=*)    OVERLAP="${1#*=}"; shift ;;
    -l|--lang)      LANGTOK="$(resolve_lang "$2")"; shift 2 ;;
    --lang=*)       LANGTOK="$(resolve_lang "${1#*=}")"; shift ;;
    --diar)         DIAR="$2"; shift 2 ;;
    --diar=*)       DIAR="${1#*=}"; shift ;;
    --no-diar)      DIAR=0; shift ;;
    --no-resident)  RESIDENT=0; shift ;;
    --md)           MD_FILE="$2"; shift 2 ;;   --md=*)    MD_FILE="${1#*=}"; shift ;;
    --srt)          SRT_FILE="$2"; shift 2 ;;  --srt=*)   SRT_FILE="${1#*=}"; shift ;;
    --color)        COLOR="$2"; shift 2 ;;     --color=*) COLOR="${1#*=}"; shift ;;
    --speakers)     SPK_NAMES="$2"; shift 2 ;; --speakers=*) SPK_NAMES="${1#*=}"; shift ;;
    --voiceprints)  VP_DIR="$2"; shift 2 ;;    --voiceprints=*) VP_DIR="${1#*=}"; shift ;;
    --no-color)     COLOR="never"; shift ;;
    --sim)          DIAR_SIM="$2"; shift 2 ;;
    --sim=*)        DIAR_SIM="${1#*=}"; shift ;;
    --maxk)         DIAR_MAXK="$2"; shift 2 ;;
    --maxk=*)       DIAR_MAXK="${1#*=}"; shift ;;
    --duration)     DURATION="$2"; shift 2 ;;
    --duration=*)   DURATION="${1#*=}"; shift ;;
    --replay)       REPLAY="$2"; shift 2 ;;
    --replay=*)     REPLAY="${1#*=}"; shift ;;
    --keep)         KEEP=1; shift ;;
    --model)        MODEL="$2"; shift 2 ;;   --model=*) MODEL="${1#*=}"; shift ;;
    --bpe)          BPE="$2"; shift 2 ;;     --bpe=*)   BPE="${1#*=}"; shift ;;
    --bin)          BIN="$2"; shift 2 ;;     --bin=*)   BIN="${1#*=}"; shift ;;
    --)             shift; break ;;
    -*)             echo "error: unknown option '$1' (see --help)"; exit 1 ;;
    *)              echo "error: unexpected argument '$1' (see --help)"; exit 1 ;;
  esac
done

if [ "$LANGTOK" = "__ERR__" ]; then
  echo "error: --lang expects ko|en|ja|zh|auto or a numeric token id"; exit 1
fi
# snapshot the USER-given speaker names (voiceprint SPKNAME lines append to
# SPK_NAMES during the session; only user-named speakers get enrolled at end)
USER_SPK_NAMES="$SPK_NAMES"
[ -n "$VP_DIR" ] && mkdir -p "$VP_DIR"

# ── sanity checks ────────────────────────────────────────────────────────────
command -v ffmpeg >/dev/null || { echo "error: ffmpeg not found (brew install ffmpeg)"; exit 1; }
[ -x "$BIN" ]   || { echo "error: transcribe not built: $BIN (bash build.sh transcribe.zig)"; exit 1; }
[ -f "$MODEL" ] || { echo "error: model not found: $MODEL"; exit 1; }
[ -f "$BPE" ]   || { echo "error: BPE not found: $BPE"; exit 1; }
if [ "$DIAR" = "1" ]; then
  # diar weights are always needed (resident binary + external tools both load them)
  [ -f "$DIAR_W" ] && [ -f "$DIAR_MB" ] || { echo "error: diar assets missing. Run: bash bench/gen_diar_assets.sh"; exit 1; }
  # the standalone diar tools are only used in the --no-resident fallback
  if [ "$RESIDENT" != "1" ]; then
    [ -x "$EMB" ] && [ -x "$CLUST" ] || { echo "error: diar tools missing ($EMB / $CLUST). Build: bash build.sh diar_embed_wav.zig ; zig build-obj -O ReleaseFast -lc --name online_diar -femit-bin=build/online_diar.o online_diar.zig && clang -O2 build/online_diar.o -o out/online_diar"; exit 1; }
  fi
fi

WORK="$(mktemp -d -t live_whisper)"
FFLOG="$WORK/ffmpeg.log"
STATE="$WORK/spk_state.bin"      # persistent online-clustering centroids
emitted_until="-1"               # global time already printed (overlap dedup)
last_word=""                     # text of last emitted word (boundary text dedup)
last_spk=""                      # last emitted speaker id (carry over unlabeled overlap)
TX_PID=""                        # resident transcribe coprocess (FIFO-based)

cleanup() {
  [ -n "${FFPID:-}" ] && kill "$FFPID" 2>/dev/null || true
  wait "${FFPID:-}" 2>/dev/null || true
  exec 7>&- 8<&- 2>/dev/null || true            # close FIFO fds (signals EOF → binary exits)
  # let the resident binary exit gracefully (it dumps speaker centroids on EOF)
  if [ -n "${TX_PID:-}" ]; then
    local _i=0
    while kill -0 "$TX_PID" 2>/dev/null && [ "$_i" -lt 20 ]; do sleep 0.1; _i=$((_i + 1)); done
    kill "$TX_PID" 2>/dev/null || true
    wait "$TX_PID" 2>/dev/null || true
  fi
  # voiceprint enrollment: user-named speakers → <vp_dir>/<name>.vec for next session
  if [ -n "${VP_DIR:-}" ] && [ -n "${USER_SPK_NAMES:-}" ]; then
    local _pair _id _name
    local IFS=,
    for _pair in $USER_SPK_NAMES; do
      _id="${_pair%%=*}"; _name="${_pair#*=}"
      if [ -f "$VP_DIR/.last/spk$_id.vec" ]; then
        cp "$VP_DIR/.last/spk$_id.vec" "$VP_DIR/$_name.vec"
        echo "[live] enrolled voiceprint: $_name (speaker $_id)"
      fi
    done
    unset IFS
  fi
  if [ "$KEEP" = "1" ]; then echo ""; echo "[live] artifacts kept: $WORK"; else rm -rf "$WORK"; fi
}
trap cleanup EXIT INT TERM

# ── resident transcribe (bash 3.2-compatible: FIFOs + fixed fds 7/8) ──────────
# Loads the 1.6 GB model ONCE; segments are fed as "<offset> <wav>" lines and
# transcribed without reload. RESIDENT=0 falls back to one process per segment.
start_resident() {
  [ "${RESIDENT:-1}" = "1" ] || return 0
  mkfifo "$WORK/tx_in" "$WORK/tx_out" 2>/dev/null || { RESIDENT=0; return 0; }
  env ${LANGTOK:+WHISPER_LANG_ID=$LANGTOK} STREAM=1 \
    DIAR="$DIAR" DIAR_SIM="$DIAR_SIM" DIAR_MAXK="$DIAR_MAXK" \
    ${VP_DIR:+VOICEPRINTS=$VP_DIR} ${VP_SIM:+VP_SIM=$VP_SIM} \
    "$BIN" "$MODEL" "$BPE" "$BPE" <"$WORK/tx_in" >"$WORK/tx_out" 2>>"$FFLOG" &
  TX_PID=$!
  exec 7>"$WORK/tx_in"     # hold the write end open (else binary sees EOF on stdin)
  exec 8<"$WORK/tx_out"
  # drain one-time setup output until the model is resident and ready
  local line
  while IFS= read -r line <&8; do
    case "$line" in *"[stream] ready"*) return 0 ;; esac
    if ! kill -0 "$TX_PID" 2>/dev/null; then   # binary died during load → fall back
      echo "[live] resident transcribe failed to start; falling back (see $FFLOG)"
      RESIDENT=0; TX_PID=""; return 0
    fi
  done
  RESIDENT=0; TX_PID=""   # EOF before ready → fall back
}

# ── output rendering: console colour + .md transcript + .srt subtitles ───────
case "$COLOR" in
  always) USE_COLOR=1 ;;
  never)  USE_COLOR=0 ;;
  *)      [ -t 1 ] && USE_COLOR=1 || USE_COLOR=0 ;;   # auto: only when stdout is a TTY
esac
ESC=$(printf '\033'); RESET="${ESC}[0m"; DIM="${ESC}[2m"
SPK_COLORS=( "${ESC}[96m" "${ESC}[92m" "${ESC}[93m" "${ESC}[95m" "${ESC}[94m" "${ESC}[91m" "${ESC}[36m" "${ESC}[35m" )
SRT_N=0
[ -n "$MD_FILE" ] && printf '# Transcript\n\n' > "$MD_FILE"
[ -n "$SRT_FILE" ] && : > "$SRT_FILE"

srt_tc() { # seconds(float) → HH:MM:SS,mmm
  awk -v s="$1" 'BEGIN{h=int(s/3600);m=int((s%3600)/60);se=int(s)%60;ms=int((s-int(s))*1000+0.5);printf "%02d:%02d:%02d,%03d",h,m,se,ms}'
}

# map a speaker id to its display label (real name from --speakers, else "Speaker N")
spk_name() { # $1=id
  local id="$1" pair
  if [ -n "$SPK_NAMES" ]; then
    local IFS=,
    for pair in $SPK_NAMES; do
      case "$pair" in "$id="*) printf '%s' "${pair#*=}"; return ;; esac
    done
  fi
  printf 'Speaker %s' "$id"
}

# write one record to the .md/.srt files (shared by live render + final relabel)
render_files() { # $1=start  $2=end  $3=spk  $4..=text
  local start="$1" end="$2" spk="$3"; shift 3; local text="$*"
  local si="${start%.*}" mm ss tc who
  mm=$((si / 60)); ss=$((si % 60)); tc=$(printf '%02d:%02d' "$mm" "$ss")
  if [ "$DIAR" = "1" ]; then
    if [ "$spk" -ge 0 ] 2>/dev/null; then who="$(spk_name "$spk"): "; else who="Speaker ?: "; fi
  else who=""; fi
  if [ -n "$MD_FILE" ]; then
    if [ "$DIAR" = "1" ]; then printf -- '- **[%s] %s** %s\n' "$tc" "${who%: }" "$text" >> "$MD_FILE"
    else                       printf -- '- **[%s]** %s\n' "$tc" "$text" >> "$MD_FILE"; fi
  fi
  if [ -n "$SRT_FILE" ]; then
    local e; e=$(awk -v s="$start" -v e="$end" 'BEGIN{if(e<=s+0.2)e=s+1.2;print e}')
    SRT_N=$((SRT_N + 1))
    printf '%s\n%s --> %s\n%s%s\n\n' "$SRT_N" "$(srt_tc "$start")" "$(srt_tc "$e")" "$who" "$text" >> "$SRT_FILE"
  fi
}

render_line() { # $1=start  $2=end  $3=spk  $4..=text
  local start="$1" end="$2" spk="$3"; shift 3; local text="$*"
  [ -n "$text" ] || return 0
  local si="${start%.*}" mm ss tc who
  mm=$((si / 60)); ss=$((si % 60)); tc=$(printf '%02d:%02d' "$mm" "$ss")
  if [ "$DIAR" = "1" ]; then
    if [ "$spk" -ge 0 ] 2>/dev/null; then who="$(spk_name "$spk"): "; else who="Speaker ?: "; fi
  else who=""; fi
  # console
  if [ "$USE_COLOR" = "1" ] && [ "$DIAR" = "1" ]; then
    local idx=$(( (spk < 0 ? 0 : spk) % ${#SPK_COLORS[@]} )) c
    c="${SPK_COLORS[$idx]}"
    printf '  %s[%s]%s %s%s%s\n' "$DIM" "$tc" "$RESET" "$c" "$who$text" "$RESET"
  else
    printf '  [%s] %s%s\n' "$tc" "$who" "$text"
  fi
  printf '%s %s %s %s\n' "$start" "$end" "$spk" "$text" >> "$WORK/lines.log"
  render_files "$start" "$end" "$spk" "$text"
}

# session-end relabel: ask the resident binary to re-cluster the WHOLE session
# and re-assign every diar window (SPKFIX lines), then rewrite .md/.srt with the
# corrected speakers — the saved transcript gets file-mode quality while the
# console stays streaming.
final_relabel() {
  [ "${RESIDENT:-0}" = "1" ] && [ -n "${TX_PID:-}" ] || return 0
  [ "$DIAR" = "1" ] || return 0
  { [ -n "$MD_FILE" ] || [ -n "$SRT_FILE" ]; } || return 0
  [ -s "$WORK/lines.log" ] || return 0
  printf 'FLUSH\n' >&7 2>/dev/null || return 0
  : > "$WORK/spkfix.log"
  local line
  while IFS= read -r line <&8; do
    case "$line" in
      "<<FLUSH_END>>") break ;;
      "SPKFIX "*) printf '%s\n' "${line#SPKFIX }" >> "$WORK/spkfix.log" ;;
    esac
  done
  [ -s "$WORK/spkfix.log" ] || return 0
  # correct each line's speaker: the SPKFIX window covering its start time
  awk -v fixfile="$WORK/spkfix.log" '
    BEGIN { nf = 0; while ((getline l < fixfile) > 0) { split(l, a, " "); ft[nf] = a[1]; fid[nf] = a[2]; nf++ } }
    { st = $1 + 0; best = -1; bt = -1e9
      for (i = 0; i < nf; i++) if (ft[i] <= st + 0.76 && ft[i] > bt) { bt = ft[i]; best = fid[i] }
      if (best >= 0) $3 = best
      print }
  ' "$WORK/lines.log" > "$WORK/lines_fixed.log"
  [ -n "$MD_FILE" ] && printf '# Transcript\n\n' > "$MD_FILE"
  [ -n "$SRT_FILE" ] && : > "$SRT_FILE"
  SRT_N=0
  local rec
  set -f
  while IFS= read -r rec; do render_files $rec; done < "$WORK/lines_fixed.log"
  set +f
  echo "[live] saved transcript relabeled with final speaker clustering"
}

# spin up the resident model now (loads while ffmpeg captures the first segment)
start_resident

# --replay <wav> processes a pre-recorded file through the identical
# overlap+diar pipeline (no mic). Useful for recorded meetings and for testing.
if [ -n "$REPLAY" ]; then
  [ -f "$REPLAY" ] || { echo "error: replay file not found: $REPLAY"; exit 1; }
  echo "[live] replay=$REPLAY  seg=${SEG}s overlap=${OVERLAP}s diar=$DIAR lang=${LANGTOK:-auto}"
  ffmpeg -hide_banner -loglevel error -i "$REPLAY" -ar 16000 -ac 1 \
    -f segment -segment_time "$SEG" -reset_timestamps 1 "$WORK/seg_%05d.wav" 2>"$FFLOG"
  FFPID=""                 # no live capture → ff_alive always 0 below
else
  echo "[live] device=$DEVICE seg=${SEG}s overlap=${OVERLAP}s diar=$DIAR lang=${LANGTOK:-auto}${DURATION:+ duration=${DURATION}s}"
  echo "[live] capturing… (Ctrl-C to stop)  tmp=$WORK"
  echo ""
  # DURATION=<sec> → bounded live run (ffmpeg self-terminates, loop then drains)
  ffmpeg -hide_banner -loglevel error \
    -f avfoundation -i ":${DEVICE}" -ar 16000 -ac 1 ${DURATION:+-t "$DURATION"} \
    -f segment -segment_time "$SEG" -reset_timestamps 1 \
    "$WORK/seg_%05d.wav" >"$FFLOG" 2>&1 &
  FFPID=$!
fi

# transcribe one wav and emit "W <global_time> <word>" lines.
# RESIDENT: feed "<offset> <wav>" to fd 7, read the binary's reply on fd 8 until
# "<<SEG_END>>" (the binary already globalizes word times, so awk adds 0).
# Fallback: spawn one transcribe process and add the offset in awk.
# NOTE: must run in the MAIN shell (not a $()/pipe subshell) so fds 7/8 are live.
words_of() { # $1=wav  $2=global_start_offset
  if [ "${RESIDENT:-0}" = "1" ] && [ -n "${TX_PID:-}" ]; then
    printf '%s %s\n' "$2" "$1" >&7
    local line buf="" vp_id vp_name
    while IFS= read -r line <&8; do
      [ "$line" = "<<SEG_END>>" ] && break
      case "$line" in
        "SPKNAME "*)   # voiceprint recognized: append id=name (user names win — first match)
          vp_id="${line#SPKNAME }"; vp_name="${vp_id#* }"; vp_id="${vp_id%% *}"
          SPK_NAMES="${SPK_NAMES:+$SPK_NAMES,}$vp_id=$vp_name"
          echo "[live] speaker $vp_id recognized by voice: $vp_name" >&2
          continue ;;
      esac
      buf="$buf$line
"
    done
    printf '%s' "$buf" | awk '
      /^SPK /                { print "S " $2 " " $3; next }   # in-process speaker label
      /^=== WORD TIMESTAMPS/ { m=1; next }
      /^=== /                { m=0 }
      m && /^[[:space:]]*\[/ {
        t=$0; sub(/^[[:space:]]*\[/,"",t); sub(/s[-\]].*/,"",t);
        e=$0; sub(/^[[:space:]]*\[[^-\]]*/,"",e);
        if (e ~ /^-/) { sub(/^-/,"",e); sub(/s\].*/,"",e) } else e=t
        w=$0; sub(/^[[:space:]]*\[[^]]*\][[:space:]]*/,"",w);
        if (w!="") printf "W %.2f %.2f %s\n", t, e, w
      }'
  else
    env ${LANGTOK:+WHISPER_LANG_ID=$LANGTOK} "$BIN" "$MODEL" "$1" "$BPE" 2>/dev/null | awk -v off="$2" '
      /^=== WORD TIMESTAMPS/ { m=1; next }
      /^=== /                { m=0 }
      m && /^[[:space:]]*\[/ {
        t=$0; sub(/^[[:space:]]*\[/,"",t); sub(/s[-\]].*/,"",t);
        e=$0; sub(/^[[:space:]]*\[[^-\]]*/,"",e);
        if (e ~ /^-/) { sub(/^-/,"",e); sub(/s\].*/,"",e) } else e=t
        w=$0; sub(/^[[:space:]]*\[[^]]*\][[:space:]]*/,"",w);
        if (w!="") printf "W %.2f %.2f %s\n", off + t, off + e, w
      }'
  fi
}

# minimum samples diar_embed_wav needs (one 1.5s window @16kHz) to avoid div-by-0
DIAR_MIN_DUR="1.6"

# speaker labels for a disjoint segment → "S <global_time> <spk>" lines
labels_of() { # $1=wav  $2=global_start_offset  $3=idx
  [ "$DIAR" = "1" ] || return 0
  # resident binary diarizes in-process and emits SPK lines → skip external tools
  [ "${RESIDENT:-0}" = "1" ] && [ -n "${TX_PID:-}" ] && return 0
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

  # collect speaker labels + word lines into a feed file IN THE MAIN SHELL (the
  # resident fds 7/8 are not inherited by $()/pipe subshells), then merge.
  local feed="$WORK/feed_$i.txt" merged new_emit new_last new_spk
  { labels_of "$cur" "$S" "$i"; words_of "$in_wav" "$in_start"; } > "$feed"
  merged=$(awk -f merge_seg.awk -v emitted="$emitted_until" -v final="$final" \
          -v diar="$DIAR" -v prevword="$last_word" -v prevspk="$last_spk" \
          -v segend="$((S + SEG))" "$feed")

  # render @LINE records (console colour + .md + .srt) and carry control state.
  # MUST be a main-shell while-loop (here-string, no subshell) so SRT_N persists.
  local ln rest
  set -f                       # no globbing when word-splitting $rest into args
  while IFS= read -r ln; do
    case "$ln" in
      "@LINE "*)     rest="${ln#@LINE }"; render_line $rest ;;
      "@EMITTED "*)  emitted_until="${ln#@EMITTED }" ;;
      "@LASTWORD "*) last_word="${ln#@LASTWORD }" ;;
      "@LASTSPK "*)  new_spk="${ln#@LASTSPK }"; [ "$new_spk" -ge 0 ] 2>/dev/null && last_spk="$new_spk" ;;
    esac
  done <<< "$merged"
  set +f
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
      echo ""; echo "[live] capture stopped — transcript complete."
      final_relabel
      break
    fi
  else
    if [ "$ff_alive" -eq 0 ]; then echo "[live] ffmpeg exited. log:"; cat "$FFLOG" 2>/dev/null; break; fi
    sleep 0.5; waited=$((waited + 1))
  fi
done
