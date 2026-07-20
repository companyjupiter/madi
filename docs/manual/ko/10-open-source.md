# 오픈소스 라이선스

Madi는 대부분 자체 개발한 코드로 이루어져 있지만, 일부 서드파티 구성요소를 **Apache License 2.0** 하에 사용합니다. 라이선스가 요구하는 저작권·귀속(attribution) 고지는 그대로 유지합니다.

## Apache License 2.0 구성요소

| 구성요소 | Madi에서의 용도 | 출처 | 라이선스 |
|---|---|---|---|
| **DNA3.0-2B** (dnotitia · Qwen3.5-2B 기반) | 8GB Mac 온디바이스 번역 및 회의 요약·질의응답 | `dnotitia/DNA3.0-2B` (베이스 `Qwen/Qwen3.5-2B`) | Apache-2.0 |
| **DNA3.0-4B** (dnotitia · Qwen3.5-4B 기반) | 온디바이스 번역 및 회의 요약·질의응답 | `dnotitia/DNA3.0-4B` (베이스 `Qwen/Qwen3.5-4B`) | Apache-2.0 |
| **WeSpeaker** ResNet34 | 화자 분리(음성 임베딩) | `wenet-e2e/wespeaker` | Apache-2.0 |

- **DNA3.0-2B / 4B** — 디노티시아(dnotitia)가 Qwen3.5를 한국어 중심으로 후처리 학습한 온디바이스 LLM입니다. 실시간 번역과 회의 요약·질의응답에 사용되며, 각 베이스 모델(Alibaba)도 Apache-2.0입니다.
- **WeSpeaker** — ResNet34 화자 임베딩 모델로, 누가 언제 말했는지 구분하는 화자 분리에 사용됩니다.

Apache License 2.0 전문: [apache.org/licenses/LICENSE-2.0](https://www.apache.org/licenses/LICENSE-2.0)

> 그 밖에 번들되는 구성요소를 포함한 전체 서드파티 고지는 저장소의 `NOTICE` 및 `THIRD_PARTY_LICENSES.md`에서 확인할 수 있습니다.
