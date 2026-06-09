#!/usr/bin/env bash
# check.sh — regression check for the live pipeline on the KO+EN fixture.
# Runs the resident replay and asserts key properties. Skips (exit 0) when the
# local-only WAV is absent, so CI without the fixture stays green.
set -euo pipefail
cd "$(dirname "$0")/.."   # → metal/

WAV="testdata/wife_conv_3min.wav"
if [ ! -f "$WAV" ]; then
  echo "SKIP: fixture $WAV not present (local-only recording)"; exit 0
fi

echo "[check] replaying $WAV through ko-meeting pipeline…"
OUT=$(./live_transcribe.sh --replay "$WAV" -m ko-meeting --color never 2>/dev/null)

fail=0
# 1) KO + EN technical vocabulary must survive transcription + code-switching
for kw in 온디바이스 SLM 디코딩 architecture inference; do
  printf '%s' "$OUT" | grep -q -- "$kw" || { echo "  MISS keyword: $kw"; fail=1; }
done
# 2) diarization must find at least two speakers
spk=$(printf '%s' "$OUT" | grep -oE 'Speaker [0-9]' | sort -u | wc -l | tr -d ' ')
[ "${spk:-0}" -ge 2 ] || { echo "  FAIL: expected >=2 speakers, got ${spk:-0}"; fail=1; }
# 3) transcript should have a reasonable number of attributed lines
lines=$(printf '%s' "$OUT" | grep -cE '^[[:space:]]*\[[0-9]+:[0-9]+\]' || true)
[ "${lines:-0}" -ge 18 ] || { echo "  FAIL: expected >=18 lines, got ${lines:-0}"; fail=1; }

if [ "$fail" = "0" ]; then
  echo "[check] PASS — KO+EN live pipeline OK (${spk} speakers, ${lines} lines)"
else
  echo "[check] FAIL"; exit 1
fi
