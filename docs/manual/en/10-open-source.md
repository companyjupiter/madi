# Open-Source Licenses

Madi is almost entirely original code, but it uses five third-party machine-learning models. Every copyright, attribution and change notice those licenses require is reproduced below. License texts are legal documents, so they are kept in their original English rather than translated.

## Components at a glance

| Component | Use in Madi | How it ships | License |
|---|---|---|---|
| **OpenAI Whisper** large-v3-turbo | Speech transcription | Downloaded on first run | MIT |
| **WeSpeaker** ResNet34 | Speaker diarization (voice embedding) | Bundled in the app | Toolkit Apache-2.0 · weights CC BY 4.0 |
| **Silero VAD** | Telling speech from silence | Bundled in the app | MIT |
| **pyannote** segmentation-3.0 | Overlapped-speech detection | Bundled in the app | MIT |
| **DNA3.0-2B / 4B** (dnotitia · Qwen3.5 base) | On-device translation, summary and Q&A | Downloaded when you enable it | Apache-2.0 |

## MIT License components

- **OpenAI Whisper** large-v3-turbo — Copyright (c) 2022 OpenAI — `github.com/openai/whisper`
- **Silero VAD** — Copyright (c) 2020-present Silero Team — `github.com/snakers4/silero-vad`
- **pyannote** segmentation-3.0 — Copyright (c) 2020 CNRS — `github.com/pyannote/pyannote-audio`

```
MIT License

Copyright (c) 2022 OpenAI
Copyright (c) 2020-present Silero Team
Copyright (c) 2020 CNRS

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Apache License 2.0 components

- **DNA3.0-2B / 4B** — Copyright (c) Dnotitia Inc. · base model Copyright (c) Alibaba Cloud (Qwen) — `dnotitia/DNA3.0-4B` (base `Qwen/Qwen3.5-4B`), `dnotitia/DNA3.0-2B` (base `Qwen/Qwen3.5-2B`). On-device LLMs from dnotitia, post-trained from Qwen3.5 with a focus on Korean; they power live translation and meeting summary / Q&A.
- **WeSpeaker** toolkit and model architecture — Copyright (c) the WeSpeaker authors — `wenet-e2e/wespeaker`. For the pretrained weights, see the CC BY 4.0 section below.

Full Apache License 2.0 text: [apache.org/licenses/LICENSE-2.0](https://www.apache.org/licenses/LICENSE-2.0)

## CC BY 4.0 — WeSpeaker pretrained weights

WeSpeaker states that a pretrained model follows the license of the dataset it was trained on, so the VoxCeleb-trained models are **Creative Commons Attribution 4.0 International (CC BY 4.0)**. This applies to the `resnet34_diar.bin` weights bundled with Madi.

```
Creator   : the WeSpeaker authors (https://github.com/wenet-e2e/wespeaker)
Title     : WeSpeaker ResNet34 speaker-embedding model (VoxCeleb-trained)
Copyright : Copyright (c) the WeSpeaker authors
License   : Creative Commons Attribution 4.0 International (CC BY 4.0)
            https://creativecommons.org/licenses/by/4.0/
Modified  : YES — see the change notice below.
Disclaimer: the material is licensed AS-IS, without warranties of any kind.
```

CC BY 4.0 permits commercial use and redistribution as long as the attribution above travels with the material. Separately, VoxCeleb is assembled from YouTube material and its publishers state that copyright in the source videos remains with the original owners.

## Change notice

Required by Apache License 2.0 §4(b) and CC BY 4.0 §3(a)(1)(B). No model's architecture or trained weight values were substantively changed.

- **Whisper** — the inference path was independently reimplemented in Zig + Metal; the weights were quantized to Q8 and converted to safetensors.
- **WeSpeaker ResNet34** — inference was independently reimplemented as Zig CPU code with BatchNorm folded into the preceding convolutions; the weights were converted to a flat binary.
- **Silero VAD** and **pyannote segmentation-3.0** — the weights were converted to a flat binary for the Madi runtime.
- **DNA3.0-2B / 4B** — the weights were quantized to Q4_K_M GGUF; inference runs on our own Metal engine.

> Complete third-party notices and the full license texts are in the repository's `NOTICE` and `THIRD_PARTY_LICENSES.md`.
