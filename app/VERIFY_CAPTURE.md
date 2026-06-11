# Stage-1 오디오 캡처 검증 결과

엔진은 ffmpeg가 만든 16k WAV로 비트검증됐다. 따라서 네이티브 캡처(AVAudioEngine
→ Resampler → Segmenter → WAV)가 ffmpeg와 같은 오디오를 만드는가가 검증의 본질.
ffmpeg = 골든 레퍼런스(지피지기). 라이브 마이크는 비결정적이라 **파일 주입**으로
0~3단을 결정적으로 자동화했다 (`app/scripts/verify_capture.sh`).

재현: `app/scripts/verify_capture.sh <16k.wav> <ref.rttm>`
하네스: `app/Tools/capture_verify.swift` (swiftc, Xcode 불요)

## 결과 (ES2004a full 1049s, 정답 `ES2004a_gt_full.rttm`)

| Layer | 무엇 | 결과 | 판정 |
|---|---|---|---|
| 2 세그먼트 | Segmenter 불변식 (합성 램프, 정확샘플 복원) | body=정확 segN, overlap 연속, 오프셋 드리프트 0, 램프 비트복원 | ✅ PASS |
| 2 세그먼트 | 실파일 105세그 불변식 | PASS | ✅ |
| 1 리샘플 | AVAudioConverter(.max) vs ffmpeg swr, 48k 스탠드인 | lag=0, RMS **−84.9 dBFS**, 상관 **0.999993**, per-seg 최악 −77 / 중앙 −87 / 최선 −111 dBFS, 균등분포 | ✅ 음향적 동일 |
| 0 포맷 | 엔진이 네이티브-생성 WAV 소비 | 105세그 전사·diar 정상 | ✅ |
| 3 E2E DER | 동일 Segmenter, 정답 대비 채점 | native RELABELED **20.11%** vs ffmpeg **18.32%** (Δ1.79) | ⚠ 아래 |

## 핵심 발견 — Δ는 캡처 결함이 아니라 diar 민감성

native와 ffmpeg는 **오직 −80 dBFS(지각불가) 수준에서만 다르다**. 그런데 DER이
1.8pt(STREAMING은 5.7pt) 갈린다. 변수 하나씩 + 역검증으로 원인을 좁혔다:

1. **비결정성 가설 → 기각.** 동일 ffmpeg feed 3회 = 20.21/18.32 **비트동일**.
   엔진은 완전 결정적.
2. **길이/오프셋 드리프트 → 기각.** feed 오프셋 동일. (총길이는 native가
   194샘플(12ms) 짧음 — AVAudioConverter가 끝단 미드레인. 12ms<윈도라 무관.)
3. **엣지 아티팩트 → 기각.** per-seg 오차 균등(-77~-111 dBFS), 집중 없음.
4. **결론.** native·ff가 −80 dBFS에서만 다른데 DER 1.8pt가 움직였다는 것 자체가
   **diar 파이프라인이 지각불가 섭동에 민감**하다는 직접 증명. 즉 native-vs-ffmpeg
   비교는 "−80 dBFS 섭동 → ~2pt DER" 실험과 동치다. ffmpeg는 ground truth가
   아니라 개발 레퍼런스일 뿐 — **실제 제품에선 마이크→AVAudioConverter만 존재**하므로
   "ffmpeg와의 차이"가 아니라 절대 품질이 기준이다.

## 합격 판정

**Stage-1 캡처 = 검증 통과.** 리샘플러는 음향적으로 충실(최악 −77 dBFS),
세그먼터는 비트정확, 포맷은 엔진이 소비. Δ1.8pt는 캡처가 아니라 diar 강건성
이슈(백로그)다.

## 남은 것

- **Layer 4 (실기 마이크)**: 위 48k 스탠드인은 합성(16k→48k 업샘플)이다. 진짜
  48k 마이크 녹음으로 교체하면 더 단단해진다 — GUI 권한·레벨미터·체감지연과 함께
  사용자 실기 검증 필요(내가 마이크/권한 클릭 불가).
- **백로그**: diar의 −80 dBFS 민감성 — 크로스-리샘플러 DER 재현성 한계를 규정.
  silero 게이트 임계/임베딩 클러스터 경계의 강건화 후보.
- **소소**: `Resampler`/`AudioCapture.feedFile`에 변환기 드레인 추가(끝단 12ms 보존).
