# オープンソースライセンス

Madi のコードはほぼすべて自社開発ですが、一部のサードパーティコンポーネントを **Apache License 2.0** の下で利用しています。ライセンスが求める著作権表示・帰属（attribution）表示はそのまま保持しています。

## Apache License 2.0 のコンポーネント

| コンポーネント | Madi での用途 | 出典 | ライセンス |
|---|---|---|---|
| **DNA3.0-4B**（dnotitia・Qwen3.5-4B ベース） | オンデバイス翻訳および会議の要約・質疑応答 | `dnotitia/DNA3.0-4B`（ベース `Qwen/Qwen3.5-4B`） | Apache-2.0 |
| **WeSpeaker** ResNet34 | 話者分離（音声エンベディング） | `wenet-e2e/wespeaker` | Apache-2.0 |

- **DNA3.0-4B** — dnotitia が Qwen3.5-4B を韓国語中心にポストトレーニングしたオンデバイス LLM です。リアルタイム翻訳と会議の要約・質疑応答に使用します。ベースモデルの Qwen3.5-4B（Alibaba）も Apache-2.0 です。
- **WeSpeaker** — ResNet34 の話者エンベディングモデルで、誰がいつ話したかを区別する話者分離に使用します。

Apache License 2.0 の全文: [apache.org/licenses/LICENSE-2.0](https://www.apache.org/licenses/LICENSE-2.0)

> バンドルされる他のコンポーネントを含む、すべてのサードパーティ表示は、リポジトリの `NOTICE` および `THIRD_PARTY_LICENSES.md` に記載されています。
