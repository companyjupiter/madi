#!/usr/bin/env bash
# verify_capture.sh — Stage-1 audio-capture verification (Layers 0–3).
# Drives the SAME Resampler+Segmenter the mic uses, from files, so the native
# capture path can be compared bit-for-bit against ffmpeg (the engine's
# historical reference) on real benchmark audio with ground-truth RTTM.
#
# Layers:
#   2  Segmenter invariants (synthetic ramp, exact-sample reconstruction)
#   1  Resampler fidelity: AVAudioConverter vs ffmpeg swr on a 48k standin
#   3  E2E DER parity: native-resampled vs ffmpeg-resampled, SAME segmenter,
#      scored against ground-truth RTTM through the resident engine
#
# Usage: verify_capture.sh <16k_source.wav> <ref.rttm>
#   (a 48k "mic-rate" standin is synthesized by upsampling the 16k source;
#    replace with a REAL 48k mic recording for Layer 4.)
set -euo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP="$(cd "$HERE/.." && pwd)"          # apps/macos
ROOT="$(cd "$APP/../.." && pwd)"       # repo root (apps/macos → ..)
SRC="${1:?usage: verify_capture.sh <16k.wav> <ref.rttm>}"
REF="${2:?need ref.rttm}"
W="${W:-/tmp/cv}"; mkdir -p "$W"

echo "[build] capture_verify harness"
swiftc -O "$APP"/Sovereign/Audio/{Resampler,Segmenter,WavWriter}.swift \
  "$APP/Tools/capture_verify.swift" -o "$W/capture_verify"

echo; echo "── Layer 2: Segmenter invariants ──"
"$W/capture_verify" segtest

echo; echo "── Layer 1: Resampler fidelity vs ffmpeg ──"
ffmpeg -y -loglevel error -i "$SRC" -ar 48000 -ac 1 "$W/standin_48k.wav"
ffmpeg -y -loglevel error -i "$W/standin_48k.wav" -ar 16000 -ac 1 "$W/ref16k.wav"
"$W/capture_verify" resample "$W/standin_48k.wav" "$W/nat16k.wav"
"$W/capture_verify" compare "$W/ref16k.wav" "$W/nat16k.wav"

echo; echo "── Layer 3: E2E DER parity (same segmenter, scored vs GT) ──"
rm -rf "$W/seg_nat" "$W/seg_ff"
"$W/capture_verify" segment "$W/nat16k.wav" "$W/seg_nat" 10 3 | tail -1
"$W/capture_verify" segment "$W/ref16k.wav" "$W/seg_ff"  10 3 | tail -1
echo "[native path DER]"
python3 "$ROOT/engine/metal/bench/feed_der.py" "$W/seg_nat/feed.txt" "$REF" | grep -E 'DER|windows'
echo "[ffmpeg path DER]"
python3 "$ROOT/engine/metal/bench/feed_der.py" "$W/seg_ff/feed.txt"  "$REF" | grep -E 'DER|windows'
echo
echo "verdict: native must be acoustically faithful (Layer 1 corr>0.999) and"
echo "its DER within the engine's input-sensitivity band of the ffmpeg path."
