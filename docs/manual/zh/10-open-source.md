# 开源许可

Madi 的代码几乎全部为自研，但使用了五个第三方机器学习模型，并使用 Sparkle 框架实现 App 自动更新。这些许可所要求的著作权声明、署名（attribution）与变更告知，下面全部予以载明。许可原文具有法律效力，因此保留英文原文而不作翻译。

## Madi 的许可

Madi 自身的代码是采用 **GNU Affero General Public License v3.0**（AGPL-3.0-only）的自由软件。任何人都可以使用、研究、修改和再分发；分发修改版或通过网络向他人提供修改版时，必须以相同许可同时提供源代码。源代码位于 `github.com/companyjupiter/madi`，许可全文见 App 内附带的 `LICENSE` 文件。App 中的翻译引擎可执行文件（`translate-engine-2b`、`translate-engine-4b`）是不受 AGPL 约束的独立程序，仅以二进制形式分发。

## 组件一览

| 组件 | 在 Madi 中的用途 | 分发方式 | 许可 |
|---|---|---|---|
| **OpenAI Whisper** large-v3-turbo | 语音转写 | 首次启动时下载 | MIT |
| **WeSpeaker** ResNet34 | 说话人分离（声纹嵌入） | 随 App 打包 | 工具包 Apache-2.0 · 权重 CC BY 4.0 |
| **Silero VAD** | 判定发言段与静音段 | 随 App 打包 | MIT |
| **pyannote** segmentation-3.0 | 检测重叠发言段 | 随 App 打包 | MIT |
| **DNA3.0-2B / 4B**（dnotitia · 基于 Qwen3.5） | 设备端翻译、摘要与问答 | 使用时下载 | Apache-2.0 |
| **Sparkle** | App 自动更新 | 随 App 打包 | MIT |

## MIT License 组件

- **OpenAI Whisper** large-v3-turbo —— Copyright (c) 2022 OpenAI —— `github.com/openai/whisper`
- **Silero VAD** —— Copyright (c) 2020-present Silero Team —— `github.com/snakers4/silero-vad`
- **pyannote** segmentation-3.0 —— Copyright (c) 2020 CNRS —— `github.com/pyannote/pyannote-audio`

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

## Sparkle (MIT) —— App 自动更新

Madi 在检查和安装更新时使用随 App 打包、未经修改的 **Sparkle** 框架（`github.com/sparkle-project/Sparkle`）。其许可条件与上文的 MIT License 全文相同。

```
Copyright (c) 2006-2013 Andy Matuschak.
Copyright (c) 2009-2013 Elgato Systems GmbH.
Copyright (c) 2011-2014 Kornel Lesiński.
Copyright (c) 2015-2017 Mayur Pawashe.
Copyright (c) 2014 C.W. Betts.
Copyright (c) 2014 Petroules Corporation.
Copyright (c) 2014 Big Nerd Ranch.
```

Sparkle 所含外部代码（bsdiff、sais-lite、ed25519、SUSignatureVerifier）的许可原文见 `THIRD_PARTY_LICENSES.md` 的 §F。

## Apache License 2.0 组件

- **DNA3.0-2B / 4B** —— Copyright (c) Dnotitia Inc. · 基础模型 Copyright (c) Alibaba Cloud (Qwen) —— `dnotitia/DNA3.0-4B`（基础模型 `Qwen/Qwen3.5-4B`）、`dnotitia/DNA3.0-2B`（基础模型 `Qwen/Qwen3.5-2B`）。dnotitia 以韩语为重点对 Qwen3.5 进行后训练得到的设备端 LLM，用于实时翻译与会议摘要 / 问答。
- **WeSpeaker** 工具包与模型架构 —— Copyright (c) the WeSpeaker authors —— `wenet-e2e/wespeaker`。关于预训练权重，请见下面的 CC BY 4.0 一节。

Apache License 2.0 全文：[apache.org/licenses/LICENSE-2.0](https://www.apache.org/licenses/LICENSE-2.0)

## CC BY 4.0 —— WeSpeaker 预训练权重

WeSpeaker 明确说明，预训练模型遵循其训练数据集的许可，因此以 VoxCeleb 训练的模型为 **Creative Commons Attribution 4.0 International (CC BY 4.0)**。这适用于随 Madi 一起分发的 `resnet34_diar.bin` 权重。

```
Creator   : the WeSpeaker authors (https://github.com/wenet-e2e/wespeaker)
Title     : WeSpeaker ResNet34 speaker-embedding model (VoxCeleb-trained)
Copyright : Copyright (c) the WeSpeaker authors
License   : Creative Commons Attribution 4.0 International (CC BY 4.0)
            https://creativecommons.org/licenses/by/4.0/
Modified  : YES — see the change notice below.
Disclaimer: the material is licensed AS-IS, without warranties of any kind.
```

只要上述署名信息随材料一并保留，CC BY 4.0 即允许商业使用与再分发。另需说明，VoxCeleb 数据集由 YouTube 素材构成，其发布方声明原始视频的著作权仍属于原著作权人。

## 变更告知

这是 Apache License 2.0 §4(b) 与 CC BY 4.0 §3(a)(1)(B) 所要求的变更告知。任何模型的架构或已训练的权重数值本身都未作实质性改动。

- **Whisper** —— 推理路径以 Zig + Metal 独立重新实现；权重量化为 Q8 并转换为 safetensors 格式。
- **WeSpeaker ResNet34** —— 推理以 Zig CPU 代码独立重新实现，并将 BatchNorm 折叠进前一层卷积；权重转换为扁平二进制。
- **Silero VAD** 与 **pyannote segmentation-3.0** —— 权重转换为供 Madi 运行时使用的扁平二进制。
- **DNA3.0-2B / 4B** —— 权重量化为 Q4_K_M GGUF；推理运行在我们自研的 Metal 引擎上。

> 完整的第三方声明与许可原文位于代码仓库的 `NOTICE` 和 `THIRD_PARTY_LICENSES.md`。
