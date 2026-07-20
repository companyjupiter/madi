# Open-Source Licenses

Madi is almost entirely original code, but it uses a few third-party components under the **Apache License 2.0**. Their copyright and attribution notices are retained as the license requires.

## Apache License 2.0 components

| Component | Use in Madi | Source | License |
|---|---|---|---|
| **DNA3.0-2B** (dnotitia · Qwen3.5-2B base) | 8 GB Mac on-device translation and meeting summary / Q&A | `dnotitia/DNA3.0-2B` (base `Qwen/Qwen3.5-2B`) | Apache-2.0 |
| **DNA3.0-4B** (dnotitia · Qwen3.5-4B base) | On-device translation and meeting summary / Q&A | `dnotitia/DNA3.0-4B` (base `Qwen/Qwen3.5-4B`) | Apache-2.0 |
| **WeSpeaker** ResNet34 | Speaker diarization (voice embedding) | `wenet-e2e/wespeaker` | Apache-2.0 |

- **DNA3.0-2B / 4B** — on-device LLMs from dnotitia, post-trained from Qwen3.5 with a focus on Korean. They power live translation and meeting summary / Q&A; both Alibaba base models are also Apache-2.0.
- **WeSpeaker** — a ResNet34 speaker-embedding model, used for diarization (telling who spoke when).

Full Apache License 2.0 text: [apache.org/licenses/LICENSE-2.0](https://www.apache.org/licenses/LICENSE-2.0)

> Complete third-party notices, including all other bundled components, are in the repository's `NOTICE` and `THIRD_PARTY_LICENSES.md`.
