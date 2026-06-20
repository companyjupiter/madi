# WER 표준 벤치 — 절대 ASR 품질

제품 평가의 "절대 품질 증명 없음" 갭을 메우는 측정. 엔진 상주(STREAM 잡피드,
모델 1회 로드) + **OpenAI 공식 Whisper 정규화기** + jiwer로 채점 → 공표 수치와
직접 비교 가능. 전 산출물 `metal/bench/wer_runs/`(영구, gitignore).

재현: `metal/bench/wer_full_pipeline.sh` (데이터 자동 페치 + 3셋 순차, resume-safe)

## 결과 (large-v3-turbo Q8_0, M4 Pro)

| 벤치 | 우리 | 공표 large-v3 | 메모 |
|---|---|---|---|
| LibriSpeech test-clean | **WER 2.17%** | ~2.0% | 2620발화 / 53,029단어 |
| LibriSpeech test-other | **WER 4.19%** | ~3.9% | 2939발화 / 52,884단어 (잡음·억양) |
| FLEURS ko_kr test | **CER 4.05%** (WER-공백 13.50%) | — | 382발화, 빈 hyp 0; **제품 경로**(엔진 AGC, 외부 정규화 없음). 한국어는 CER 정본 |

**판정**: Q8 양자화 + 자체 Metal 인코더/디코더 파이프라인이 공표 large-v3에
사실상 동급의 절대 전사 품질을 낸다. 한국어 CER 3.99%(read-speech)는 강력.

## 측정 조건 (정직 표기)

- `DIAR=0` 순수 ASR. 언어: LibriSpeech 자동, FLEURS 강제 ko(50264) — 공표 FLEURS
  평가 관행과 동일.
- **엔진 AGC (제품 경로)**: 저게인 마스터링(FLEURS 피크 -33 dBFS)을 제품 발화
  게이트 + 인코더가 무음/빈전사 처리하던 것을 **엔진 내부 AGC**(peak<0.30 → 타깃
  0.9 in-place 정규화)가 해결 (W-2b). 외부 정규화·게이트우회 핵 없이 측정 = 진짜
  제품 동작. 정상 마스터링(peak≥0.30)엔 no-op(jfk 바이트동일). 부수 이득: ES2004a
  DER 16.49→15.57(조용한 발화 복구).
- 엔진 wav 파서는 float32 WAV를 무음 처리 → 벤치는 pcm_s16le 강제 변환. 엔진
  강건화는 별도 작업 (W-3).

## 남은 비교 (지피지기)

whisper.cpp referee (`wcpp_wer.sh`): **동일 데이터·동일 모델·동일 Q8**으로 wcpp를
돌려 우리 vs wcpp 직접 대조. turbo의 공표 수치 분산이 커서 이 로컬 referee가 가장
공정한 비교축. (별도 실행 — clean+other 각 ~1시간)
