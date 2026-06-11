#!/bin/bash
# Regenerate the sovereign diarization assets (git-ignored, ~25MB) from the
# Apache-2.0 wespeaker ResNet34 onnx. Verified bit-for-bit vs onnxruntime.
#   produces: assets/resnet34_diar.bin  (36 convs + gemm + mean_vec)
#             assets/kaldi_melbank.bin  (80x257 mel filterbank)
set -e
cd "$(dirname "$0")/.."   # metal/
VENV=/tmp/diarvenv
[ -d "$VENV" ] || python3 -m venv "$VENV"
"$VENV"/bin/pip install -q numpy onnx onnxruntime kaldi-native-fbank
[ -f bench/wespeaker_en_voxceleb_resnet34.onnx ] || \
  curl -sL "https://github.com/k2-fsa/sherpa-onnx/releases/download/speaker-recongition-models/wespeaker_en_voxceleb_resnet34.onnx" \
       -o bench/wespeaker_en_voxceleb_resnet34.onnx
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
