# STT 엔진 평가 — Whisper turbo vs Qwen3-ASR-1.7B (2026-08-27)

우리 Whisper large-v3-turbo(현행 STT 엔진) 교체 타당성 A/B. 결론: **Qwen3-ASR-1.7B가
한국어에서 유의하게 정확(−18% rel CER)하나, 8GB 최소사양·엔진 교체 비용·차이의 절반이
숫자 표기 관습**이라 즉시 스왑은 보류. 근거는 아래 실측.

## 세팅 (재현 가능)
- 공통 셋: **FLEURS-ko test 382개** (Qwen 논문·우리 P3 기준선과 동일 벤치)
- 동일 채점: whisper_normalizer(basic) + jiwer **CER** — 양쪽 완전 동일 파이프라인
- Arm A: 우리 `engine/metal/out/transcribe` Metal 엔진 (STREAM, 한국어 강제 50264,
  실제 제품 경로 = gate-only AGC 포함). `STREAM_WAV_ROOTS` 필수(보안 가드).
- Arm B: `Qwen/Qwen3-ASR-1.7B` 공식 가중치, MLX bf16(양자화 무보정 = 품질 천장),
  `mlx-qwen3-asr` 0.3.5, 한국어 강제. 하네스: `bench/wer_runs/run_qwen.py`.
- 속도: Whisper 0.75s/utt(Metal), Qwen 4.30s/utt(MLX bf16, M-series).

## 결과 (382 매칭, 동일 정규화)
| 구간 | n | Whisper turbo | Qwen3-ASR-1.7B | Δ |
|---|---:|---:|---:|---:|
| **전체** | 382 | **5.63%** | **4.60%** | **+1.02pt (−18% rel)** |
| 숫자 포함 | 86 | 9.25% | 6.70% | +2.55pt |
| 숫자 없음 | 296 | 4.56% | 3.99% | **+0.57pt** |

- 부트스트랩 95% CI (Whisper−Qwen): **[+0.67, +1.37]pt** → 0 배제, **통계적으로 유의**.
- utterance별: Qwen 우세 140 / Whisper 우세 64 / 동률 178.

## 핵심 해석 — 차이의 절반은 숫자 표기 관습
Whisper는 숫자를 **한글로 풀어씀**(`천구백사십년`, `열한시 삼십오분`), FLEURS 정답·Qwen은
**아라비아 숫자**(`1940년`, `11시 35분`). 둘 다 "1940"을 정확히 들었지만 표기가 달라 Whisper가
CER 벌점을 받음. 이 관습을 배제한 **숫자 없는 296개에서 Δ는 +0.57pt로 축소**(Qwen 3.99 vs
turbo 4.56). 즉 순수 청취 우위는 실재하나 소폭이고, 전체 −18%의 상당분은 포맷 아티팩트.
→ **함의**: 숫자를 아라비아로 원하면 엔진 교체 없이 turbo 출력에 **숫자 후처리(한글수→digit)**
만 얹어도 CER 격차의 큰 부분을 회수 가능(저비용 P-후보).

## 판정
- **정확도**: Qwen3-ASR-1.7B > turbo, 유의(−18% rel; 숫자 제외 시 −12% rel/+0.57pt).
- **비용**: (a) 엔진 교체 = audio-LLM 신규 추론경로(우리 Zig/Metal Whisper 스택 밖) (b) 8GB
  M1 = 1.7B bf16 4.7GB 상주 불가, 4-bit(~2.5GB)로 turbo 대체 시에만 빠듯 (c) 속도 5.7×
  느림(4.30 vs 0.75s/utt; 라이브 스트리밍 지연 미측정) (d) 단어 타임스탬프 별도 ForcedAligner.
- **미검증**: JA/ZH 미측정(이 A/B는 KO만); 라이브 스트리밍 모드 품질/지연; 4-bit 양자화 후 CER.

## 다음 레버 (권고 순)
1. **저비용**: turbo에 숫자 한글→digit 후처리 — 엔진 무교체로 숫자구간 CER 회수(검증 대상).
2. **중비용**: Qwen3-ASR-**0.6B** 4/8-bit로 동일 A/B — 8GB에 실제로 들어가는 유일 후보의
   정확도 확인(1.7B 대비 얼마 손해인지).
3. **대결단**: 1.7B 4-bit로 turbo 완전 교체 — JA/ZH A/B + 라이브 스트리밍 지연 실측 선행 필수.
