# オープンソースライセンス

Madi のコードはほぼすべて自社開発ですが、5 つのサードパーティ機械学習モデルを利用しています。各ライセンスが求める著作権表示・帰属（attribution）表示・変更の告知をすべて以下に記載します。ライセンス原文は法的効力を持つ文書のため、翻訳せず英語のまま掲載します。

## コンポーネント一覧

| コンポーネント | Madi での用途 | 提供形態 | ライセンス |
|---|---|---|---|
| **OpenAI Whisper** large-v3-turbo | 音声の文字起こし | 初回起動時にダウンロード | MIT |
| **WeSpeaker** ResNet34 | 話者分離（音声エンベディング） | アプリに同梱 | ツールキット Apache-2.0 · 重み CC BY 4.0 |
| **Silero VAD** | 発話区間と無音区間の判定 | アプリに同梱 | MIT |
| **pyannote** segmentation-3.0 | 発話が重なった区間の検出 | アプリに同梱 | MIT |
| **DNA3.0-2B / 4B**（dnotitia・Qwen3.5 ベース） | オンデバイス翻訳・要約・質疑応答 | 利用時にダウンロード | Apache-2.0 |

## MIT License のコンポーネント

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

## Apache License 2.0 のコンポーネント

- **DNA3.0-2B / 4B** — Copyright (c) Dnotitia Inc. · ベースモデル Copyright (c) Alibaba Cloud (Qwen) — `dnotitia/DNA3.0-4B`（ベース `Qwen/Qwen3.5-4B`）、`dnotitia/DNA3.0-2B`（ベース `Qwen/Qwen3.5-2B`）。dnotitia が Qwen3.5 を韓国語中心にポストトレーニングしたオンデバイス LLM で、リアルタイム翻訳と会議の要約・質疑応答に使用します。
- **WeSpeaker** ツールキットおよびモデルアーキテクチャ — Copyright (c) the WeSpeaker authors — `wenet-e2e/wespeaker`。事前学習済みの重みについては下の CC BY 4.0 の項をご覧ください。

Apache License 2.0 の全文: [apache.org/licenses/LICENSE-2.0](https://www.apache.org/licenses/LICENSE-2.0)

## CC BY 4.0 — WeSpeaker の事前学習済みモデル

WeSpeaker は、事前学習済みモデルが学習データセットのライセンスに従うと明記しており、VoxCeleb で学習されたモデルは **Creative Commons Attribution 4.0 International (CC BY 4.0)** となります。Madi に同梱される `resnet34_diar.bin` の重みに適用されます。

```
Creator   : the WeSpeaker authors (https://github.com/wenet-e2e/wespeaker)
Title     : WeSpeaker ResNet34 speaker-embedding model (VoxCeleb-trained)
Copyright : Copyright (c) the WeSpeaker authors
License   : Creative Commons Attribution 4.0 International (CC BY 4.0)
            https://creativecommons.org/licenses/by/4.0/
Modified  : YES — see the change notice below.
Disclaimer: the material is licensed AS-IS, without warranties of any kind.
```

CC BY 4.0 は、上記の帰属表示を保持することを条件に商用利用と再配布を許可します。なお VoxCeleb データセットは YouTube 上の素材から構成されており、公開元は元動画の著作権が原著作者に帰属すると明記しています。

## 変更の告知

Apache License 2.0 §4(b) および CC BY 4.0 §3(a)(1)(B) が求める変更告知です。いずれのモデルもアーキテクチャや学習済みの重みの値そのものは変更していません。

- **Whisper** — 推論経路を Zig + Metal で独自に再実装し、重みは Q8 に量子化のうえ safetensors 形式へ変換しました。
- **WeSpeaker ResNet34** — 推論を Zig の CPU コードで独自に再実装し、BatchNorm を直前の畳み込みに畳み込んだうえで、重みをフラットバイナリへ変換しました。
- **Silero VAD** · **pyannote segmentation-3.0** — 重みを Madi ランタイム用のフラットバイナリへ変換しました。
- **DNA3.0-2B / 4B** — 重みを Q4_K_M GGUF に量子化し、推論は自社 Metal エンジンで実行します。

> すべてのサードパーティ表示とライセンス原文は、リポジトリの `NOTICE` および `THIRD_PARTY_LICENSES.md` に記載されています。
