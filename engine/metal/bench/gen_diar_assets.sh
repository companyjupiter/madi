#!/bin/bash
# Regenerate the sovereign diarization assets (git-ignored, ~25MB) from the
# Apache-2.0 wespeaker ResNet34 onnx. Verified bit-for-bit vs onnxruntime.
#   produces: assets/resnet34_diar.bin  (36 convs + gemm + mean_vec)
#             assets/kaldi_melbank.bin  (80x257 mel filterbank)
set -euo pipefail
cd "$(dirname "$0")/.."   # metal/
VENV=/tmp/diarvenv
WESPEAKER_ONNX=bench/wespeaker_en_voxceleb_resnet34.onnx
WESPEAKER_ONNX_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34.onnx"
WESPEAKER_ONNX_SHA256=5ef208a9da1453335308a6b6f4e6dfbd7e183a38b604de0a57664f45d257fe94
TMP_ROOT=${TMPDIR:-/tmp}
TMP_ROOT=${TMP_ROOT%/}
PYANNOTE_BASE=sherpa-onnx-pyannote-segmentation-3-0
PYANNOTE_DIR="$TMP_ROOT/$PYANNOTE_BASE"
PYANNOTE_MODEL="$PYANNOTE_DIR/model.onnx"
PYANNOTE_TBZ="$TMP_ROOT/pyannote_seg.tar.bz2"
PYANNOTE_TBZ_URL="https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-segmentation-models/sherpa-onnx-pyannote-segmentation-3-0.tar.bz2"
PYANNOTE_TBZ_SHA256=24615ee884c897d9d2ba09bb4d30da6bb1b15e685065962db5b02e76e4996488
PYANNOTE_MODEL_SHA256=220ad67ca923bef2fa91f2390c786097bf305bceb5e261d4af67b38e938e1079

sha256_file() {
  shasum -a 256 "$1" | awk '{print $1}'
}

verify_sha256() {
  local path="$1" expected="$2" actual
  actual=$(sha256_file "$path")
  if [ "$actual" != "$expected" ]; then
    echo "error: sha256 mismatch for $path" >&2
    echo "  expected: $expected" >&2
    echo "  actual:   $actual" >&2
    return 1
  fi
}

download_verified() {
  local url="$1" dst="$2" sha="$3" tmp
  tmp="${dst}.download"
  rm -f "$tmp"
  curl --fail --location --silent --show-error --proto '=https' --tlsv1.2 -o "$tmp" "$url"
  verify_sha256 "$tmp" "$sha"
  mv "$tmp" "$dst"
}

ensure_verified_file() {
  local path="$1" url="$2" sha="$3"
  if [ -f "$path" ] && verify_sha256 "$path" "$sha"; then
    return
  fi
  echo "fetching verified asset: $path"
  download_verified "$url" "$path" "$sha"
}

safe_extract_pyannote() {
  local archive="$1" parent
  parent=$(dirname "$PYANNOTE_DIR")
  tar tjf "$archive" | while IFS= read -r entry; do
    case "$entry" in
      ""|/*|../*|*/../*|*/..|..)
        echo "error: unsafe archive entry: $entry" >&2
        exit 1
        ;;
    esac
    case "$entry" in
      "$PYANNOTE_BASE"|"$PYANNOTE_BASE"/*) ;;
      *)
        echo "error: unexpected archive entry: $entry" >&2
        exit 1
        ;;
    esac
  done
  rm -rf "$PYANNOTE_DIR"
  tar xjf "$archive" -C "$parent"
  verify_sha256 "$PYANNOTE_MODEL" "$PYANNOTE_MODEL_SHA256"
}

[ -d "$VENV" ] || python3 -m venv "$VENV"
"$VENV"/bin/pip install --disable-pip-version-check --only-binary=:all: -q \
  numpy==2.4.6 onnx==1.22.0 onnxruntime==1.27.0 kaldi-native-fbank==1.22.3
ensure_verified_file "$WESPEAKER_ONNX" "$WESPEAKER_ONNX_URL" "$WESPEAKER_ONNX_SHA256"
# dump weights (resnet34_ref.py verifies vs onnxruntime, cosine 1.0) + melbank
"$VENV"/bin/python - <<'PY'
import numpy as np, wave
seg=(np.frombuffer(wave.open("bench/ES2004a.wav").readframes(24000),"<i2").astype(np.float32)/32768.0)
seg.tofile("/tmp/seg.f32")
PY
"$VENV"/bin/python -c "import sys; sys.path.insert(0,'bench'); import kaldi_fbank_ref as k; k.melbank().tofile('/tmp/kaldi_melbank.f32')"
"$VENV"/bin/python bench/resnet34_ref.py /tmp/resnet34_weights.bin
cp /tmp/resnet34_weights.bin assets/resnet34_diar.bin
cp /tmp/kaldi_melbank.f32   assets/kaldi_melbank.bin
echo "✅ assets/resnet34_diar.bin + assets/kaldi_melbank.bin regenerated"

# Silero-VAD v6 (16k) weights: whisper.cpp ggml export → our flat f32 bin.
# (트레인드 VAD가 필요한 이유는 PERF_LOG 'Speech-validation study' 참조 —
#  에너지/nospeech/단어스팬 전부 음악 분리 실패 측정 기각.)
WCPP=${WCPP:-$HOME/antigravity/whisper.cpp}
if [ -f "$WCPP/models/for-tests-silero-v6.2.0-ggml.bin" ]; then
  "$VENV"/bin/python bench/convert_silero.py \
    "$WCPP/models/for-tests-silero-v6.2.0-ggml.bin" assets/silero_vad.bin
  echo "✅ assets/silero_vad.bin regenerated"
else
  echo "⚠️  silero ggml not found at $WCPP/models — skipping VAD asset"
fi

# pyannote segmentation-3.0 (OSD): sherpa-onnx export → flat f32 bin
if [ ! -f "$PYANNOTE_MODEL" ] || ! verify_sha256 "$PYANNOTE_MODEL" "$PYANNOTE_MODEL_SHA256"; then
  ensure_verified_file "$PYANNOTE_TBZ" "$PYANNOTE_TBZ_URL" "$PYANNOTE_TBZ_SHA256"
  safe_extract_pyannote "$PYANNOTE_TBZ"
fi
"$VENV"/bin/python bench/convert_pyannote_seg.py "$PYANNOTE_MODEL" assets/pyannote_osd.bin
echo "✅ assets/pyannote_osd.bin regenerated"
