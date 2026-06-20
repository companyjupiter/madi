# Model assets — Sovereign Whisper (Metal)

Whisper **large-v3-turbo**. Large/generated files are git-ignored; regenerate
with the commands below.

## Files
| File | Source | Notes |
|---|---|---|
| `model.safetensors` | HF `openai/whisper-large-v3-turbo` | 1.5 GB, 587 tensors, F16 |
| `tokenizer.json`, `vocab.json`, `merges.txt`, `added_tokens.json` | HF | BPE source |
| `config.json`, `generation_config.json`, `preprocessor_config.json` | HF | |
| `mel_filters.bin` | `gen_assets.py` | [128][201] f32 Slaney mel (== whisper) |
| `suppress_tokens.bin` | `gen_assets.py` | u32[] from generation_config (88 tokens) |
| `WHISPER_BPE.bin` | `gen_assets.py` | u32 vocab_size(51866), then per-id (u32 len + raw bytes) |
| `conv1_w/b.bin`, `conv2_w/b.bin`, `pos_emb.bin` | `export_enc_weights.py` | encoder front-end weights, f32 ([k][in][out] conv layout) |
| `jfk.wav` | whisper.cpp samples | 16 kHz mono 16-bit test clip |
| `enc_input.bin` | `wav_to_enc` on jfk.wav | [1500][1280] f32 encoder input (validation output) |

## Regenerate
```bash
cd assets
# 1. download model + configs/tokenizer
curl -sL -o model.safetensors https://huggingface.co/openai/whisper-large-v3-turbo/resolve/main/model.safetensors
for f in config.json generation_config.json preprocessor_config.json \
         tokenizer.json vocab.json merges.txt added_tokens.json; do
  curl -sL -o $f https://huggingface.co/openai/whisper-large-v3-turbo/resolve/main/$f
done
# 2. auxiliary binaries (pure stdlib, no torch/numpy)
python3 gen_assets.py          # mel_filters / suppress_tokens / WHISPER_BPE
python3 export_enc_weights.py  # conv1/2 + pos_emb (front-end weights)
# 3. test clip
curl -sL -o jfk.wav https://raw.githubusercontent.com/ggerganov/whisper.cpp/master/samples/jfk.wav
```

## Validate the front-end (M1) end-to-end
```bash
cd ..                                  # metal/
bash build.sh wav_to_enc.zig
./out/wav_to_enc assets/jfk.wav assets/enc_input.bin 0 assets
# → enc_input.bin [1500×1280], finite, range ~[-1.2, 3.4]  (verified ✓)
```
