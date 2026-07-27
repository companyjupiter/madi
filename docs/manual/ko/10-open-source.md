# 오픈소스 라이선스

Madi의 코드는 대부분 자체 개발이지만, 다섯 개의 서드파티 머신러닝 모델을 사용합니다. 각 라이선스가 요구하는 저작권 고지·귀속(attribution)·변경 사실 고지를 아래에 모두 싣습니다. 라이선스 원문은 법적 효력을 갖는 문서이므로 번역하지 않고 영문 그대로 둡니다.

## 구성요소 한눈에

| 구성요소 | Madi에서의 용도 | 배포 형태 | 라이선스 |
|---|---|---|---|
| **OpenAI Whisper** large-v3-turbo | 음성 전사 | 첫 실행 시 다운로드 | MIT |
| **WeSpeaker** ResNet34 | 화자 분리(음성 임베딩) | 앱에 포함 | 툴킷 Apache-2.0 · 가중치 CC BY 4.0 |
| **Silero VAD** | 말한 구간과 침묵 구간 판정 | 앱에 포함 | MIT |
| **pyannote** segmentation-3.0 | 겹쳐 말한 구간 검출 | 앱에 포함 | MIT |
| **DNA3.0-2B / 4B** (dnotitia · Qwen3.5 기반) | 온디바이스 번역·요약·질의응답 | 사용 시 다운로드 | Apache-2.0 |

## MIT License 구성요소

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

## Apache License 2.0 구성요소

- **DNA3.0-2B / 4B** — Copyright (c) Dnotitia Inc. · 베이스 모델 Copyright (c) Alibaba Cloud (Qwen) — `dnotitia/DNA3.0-4B`(베이스 `Qwen/Qwen3.5-4B`), `dnotitia/DNA3.0-2B`(베이스 `Qwen/Qwen3.5-2B`). 디노티시아가 Qwen3.5를 한국어 중심으로 후처리 학습한 온디바이스 LLM으로, 실시간 번역과 회의 요약·질의응답에 사용합니다.
- **WeSpeaker** 툴킷 및 모델 아키텍처 — Copyright (c) the WeSpeaker authors — `wenet-e2e/wespeaker`. 사전학습 가중치는 아래 CC BY 4.0 항목을 보십시오.

Apache License 2.0 전문: [apache.org/licenses/LICENSE-2.0](https://www.apache.org/licenses/LICENSE-2.0)

## CC BY 4.0 — WeSpeaker 사전학습 가중치

WeSpeaker는 사전학습 모델이 학습 데이터셋의 라이선스를 따른다고 명시하고 있으며, VoxCeleb으로 학습된 모델은 그에 따라 **Creative Commons Attribution 4.0 International (CC BY 4.0)** 입니다. Madi에 포함된 `resnet34_diar.bin` 가중치에 적용됩니다.

```
Creator   : the WeSpeaker authors (https://github.com/wenet-e2e/wespeaker)
Title     : WeSpeaker ResNet34 speaker-embedding model (VoxCeleb-trained)
Copyright : Copyright (c) the WeSpeaker authors
License   : Creative Commons Attribution 4.0 International (CC BY 4.0)
            https://creativecommons.org/licenses/by/4.0/
Modified  : YES — see the change notice below.
Disclaimer: the material is licensed AS-IS, without warranties of any kind.
```

CC BY 4.0은 위 귀속 표시를 유지하는 조건으로 상업적 사용과 재배포를 허용합니다. VoxCeleb 데이터셋은 YouTube 자료로 구성되어 있으며, 배포처는 원본 영상의 저작권이 원저작자에게 남는다고 밝히고 있습니다.

## 변경 사실 고지

Apache License 2.0 §4(b)와 CC BY 4.0 §3(a)(1)(B)가 요구하는 변경 고지입니다. 어느 모델도 아키텍처나 학습된 가중치 값 자체는 바꾸지 않았습니다.

- **Whisper** — 추론 경로를 Zig + Metal로 독자 재구현했고, 가중치는 Q8로 양자화한 뒤 safetensors 포맷으로 변환했습니다.
- **WeSpeaker ResNet34** — 추론을 Zig CPU 코드로 독자 재구현하고 BatchNorm을 앞단 합성곱에 접어 넣었으며, 가중치는 플랫 바이너리로 변환했습니다.
- **Silero VAD** · **pyannote segmentation-3.0** — 가중치를 Madi 런타임용 플랫 바이너리로 변환했습니다.
- **DNA3.0-2B / 4B** — 가중치를 Q4_K_M GGUF로 양자화했고, 추론은 자체 Metal 엔진에서 수행합니다.

> 전체 서드파티 고지와 라이선스 원문은 저장소의 `NOTICE` 및 `THIRD_PARTY_LICENSES.md`에 있습니다.
