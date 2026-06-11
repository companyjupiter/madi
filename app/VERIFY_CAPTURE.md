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

## Layer 4 — 진짜 48k 마이크 (합성 스탠드인 아님)

내장 마이크(MacBook Pro Microphone)로 62s KO+EN 기술발화 녹음(ffmpeg avfoundation
`:2`, 48k mono). 합성 업샘플이 아닌 **광대역 실제 마이크**.

| 측정 | 결과 |
|---|---|
| Layer 1 리샘플 (AVAudioConverter vs ffmpeg swr) | lag=0, RMS **−60.9 dBFS**, 상관 **0.999931** |
| 전사 파리티 (native vs ffmpeg) | 258 vs 250 단어, 본문 거의 동일, 경계 단어 몇 개만 상이 |

합성(−84.9)보다 오차 큰 건 진짜 48k엔 8kHz 위 고주파가 있어 안티앨리어스 필터차가
드러난 것 — 그래도 신호 −60dB 아래로 지각불가.

### 결정적 역검증 — AVAudioConverter 무죄

native가 한 단어("성능 향상"→"홍영상")를 ffmpeg보다 못 잡아서, **세 리샘플러를 같은
마이크48k에 돌려** native가 체계적으로 나쁜지 확인:

| 리샘플러 | 해당 구간 | swr 대비 |
|---|---|---|
| ffmpeg swr | 성능**형상** | 기준 |
| ffmpeg soxr(p28) | 성능 **향상** ✓ | −67.7 dBFS |
| AVAudioConverter | **홍영상** ✗ | −60.9 dBFS |

**두 레퍼런스 리샘플러(swr vs soxr)끼리도 native만큼/이상 갈린다** ("토큰" 유무,
성능형상/향상, 역전형상/형상이 셋 다 제각각). native는 오히려 "토큰 스포 세컨드"·
"역전 형상"에서 soxr와 **일치**. → "성능 향상"은 **모델 자체의 경계 단어**(세 리샘플러
전부 다르게 인식)이지 AVAudioConverter 결함이 아니다. native의 전사 분기는 ffmpeg의
리샘플러를 바꿨을 때 생기는 노이즈와 구별불가.

**최종 판정**: AVAudioConverter(.max) = 음향 충실 + 전사 분기가 리샘플러-선택 노이즈
이내. **제품 캡처 경로로 적합**(외부 의존 0). 단 경계 단어 정확도가 critical해지면
soxr급 고정밀 리샘플러가 알려진 레버(의존성 비용 있음).

## 남은 것

- **Layer 4 GUI 부분**: 권한 다이얼로그·레벨미터·체감지연은 Xcode 앱 빌드 후 실기
  확인(오디오 캡처 코어는 위에서 검증 완료).
- **백로그**: diar의 −80 dBFS 민감성 — 크로스-리샘플러 DER 재현성 한계를 규정.
  silero 게이트 임계/임베딩 클러스터 경계의 강건화 후보.
- **소소**: `Resampler`/`AudioCapture.feedFile`에 변환기 드레인 추가(끝단 12ms 보존).
