#!/usr/bin/awk -f
# merge_seg.awk — merge whisper word-timestamps with online speaker labels for
# one live segment, applying overlap dedup + trailing-word holdback, and group
# consecutive same-speaker words into printable lines.
#
# Inputs (concatenated, distinguished by a leading tag column):
#   "S <gtime> <spk>"          speaker label: a 1.5s diar window @ global gtime
#   "W <gtime> <word...>"      a transcribed word at global time gtime
# The caller feeds S-lines first (any order), then W-lines in time order.
#
# Params (-v):
#   emitted=<float>   global time already emitted in prior segments (exclusive)
#   final=<0|1>       1 if this is the last segment (then emit trailing word too)
#   diar=<0|1>        1 → prefix lines with "Speaker K:"; 0 → text only
#   eps=<float>       dedup guard (default 0.05س)
#
# Output:
#   grouped transcript lines, then a final control line:
#     "@EMITTED <new_emitted_until>"   (caller captures this to carry forward)
BEGIN { ns = 0; nw = 0; if (eps == "") eps = 0.05; if (segend == "") segend = 1e9 }

# normalize a word for boundary dedup: lowercase, strip surrounding punctuation
function norm(s) { s = tolower(s); gsub(/^[^a-z0-9가-힣]+|[^a-z0-9가-힣]+$/, "", s); return s }

$1 == "S" { sp_t[ns] = $2 + 0; sp_id[ns] = $3 + 0; ns++; next }

$1 == "W" {
  wt[nw] = $2 + 0
  # rejoin the word (everything after field 2)
  w = ""
  for (i = 3; i <= NF; i++) w = (w == "" ? $i : w " " $i)
  ww[nw] = w
  nw++
  next
}

function spk_of(t,   j, best, bestt) {
  best = -1; bestt = -1e30
  for (j = 0; j < ns; j++) if (sp_t[j] <= t + 0.75 && sp_t[j] > bestt) { bestt = sp_t[j]; best = sp_id[j] }
  return best   # -1 if no diar label (diar disabled / VAD-dropped window)
}

END {
  new_emitted = emitted
  # determine last emit-eligible index (holdback trailing word unless final)
  last_idx = nw - 1
  if (!final) last_idx = nw - 2     # hold back the final (possibly cut) word

  cur_spk = -2; line = ""; line_t = -1
  guard = prevword                                 # last word emitted by prior segment
  lastword = prevword
  last_known = (prevspk == "" ? -1 : prevspk + 0)  # carry speaker across segment boundary
  for (i = 0; i <= last_idx; i++) {
    if (wt[i] <= emitted + eps) continue          # already emitted in overlap (by time)
    if (guard != "" && norm(ww[i]) == norm(guard)) { guard = ""; continue }  # text-level boundary dedup
    guard = ""                                    # only the first eligible word is guarded
    s = (diar == 1) ? spk_of(wt[i]) : -1
    # overlap-region words sit before cur's diar grid → no label; inherit prior speaker
    if (diar == 1 && s < 0) s = last_known
    if (s >= 0) last_known = s
    if (s != cur_spk) {                            # speaker change → flush line
      flush_line(cur_spk, line, line_t, line_end)
      cur_spk = s; line = ww[i]; line_t = wt[i]; line_end = wt[i]
    } else {
      line = (line == "" ? ww[i] : line " " ww[i]); line_end = wt[i]
    }
    # advance the dedup watermark ONLY by plausible (in-window) timestamps —
    # Whisper sometimes hallucinates a far-future time (e.g. 29.9s in a 6s
    # segment); letting that set new_emitted would suppress all later segments.
    if (wt[i] <= segend && wt[i] > new_emitted) new_emitted = wt[i]
    lastword = ww[i]
  }
  flush_line(cur_spk, line, line_t, line_end)
  printf "@EMITTED %.2f\n", new_emitted
  printf "@LASTWORD %s\n", lastword
  printf "@LASTSPK %d\n", last_known
}

# Emit a machine-readable line record; the bash runner renders it for the
# console (with colour), the .md transcript and the .srt subtitles.
#   @LINE <start_sec> <end_sec> <speaker_id|-1> <text…>
function flush_line(spk, txt, t, te) {
  if (txt == "") return
  if (te < t) te = t
  printf "@LINE %.2f %.2f %d %s\n", t, te, (diar == 1 ? spk : -1), txt
}
