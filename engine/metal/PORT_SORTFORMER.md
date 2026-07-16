# PORT_SORTFORMER — Streaming Sortformer v2를 madi 라이브 diar 백엔드로

상태: **설계 (2026-07-17)** · 선행 증거 수집 완료 · 구현 착수 전
근거 데이터: PERF_LOG `EMBED-SCREEN-2`/`OVL-GATE-NEG`/`CENT-CAP-NEG`/`WIN-ALIGN-NEG`
(현 아키텍처 내부 레버 소진 실증) + 아래 레퍼런스 실측.

## 1. 왜 (Go/No-Go 실측 — 2026-07-17, FluidAudio CoreML 레퍼런스)

포트 전 게이트 관례(EMBED-UPGRADE "gate embedder upgrades before porting")에 따라
FluidAudio(Apache-2.0) + FluidInference CoreML 변환본으로 패널 3파일을 실측:

| 파일 | Sortformer 스트리밍 최종 DER | 즉시(tentative) | madi live 즉시 | madi 최종(+OSD) |
|---|---|---|---|---|
| migzj | **7.99** | 8.27 | 26.32 | 23.33 (causal) |
| jnivh | **1.55** | 3.26 | 16.93 | — |
| gwtwd | **1.19** | 1.17 | 8.55 | 8.32 |
| 평균 | **3.58** | **4.23** | 17.27 | ~10.9 |

- tentative→final 라벨 플립은 프레임의 2.5-6%; 즉시 표시 비용이 최종 대비 ~1pp뿐.
- finalized 프런티어는 오디오 대비 ~0.5-1.1s 지연(0.48s 청크 + 0.56s 우측 컨텍스트),
  tentative는 ~0.1-0.6s — 현행 세그먼트 프런티어(10s)보다 훨씬 빠른 라이브 감각.
- **오염 주의**: VoxConverse-v0.3이 모델 학습셋에 포함 → 위 수치는 상한.
  비오염 교차검증 AMI ES2004a: DER 25.39 = miss 24.5pp + FA 0.2pp +
  **confusion 0.7pp**. miss는 backchannel 억제 성향(단어 단위 GT 특성)이고
  화자 귀속 오류(confusion+FA)는 ~1pp — madi의 핵심 요구(안정된 화자 라벨)에서
  결정적 신호. 참고로 madi 현행 ES2004a live 25.66은 miss가 아니라 confusion 지배.
- 성능(이 머신, Apple Silicon/macOS 26): 0.5s 피드당 평균 17.5ms(p95 31ms, max 85ms),
  RTFx 24-29×, 웜 로드 0.11-0.16s, fp16 229MB, 세션 상태 ~456KB.
- 화자 수 판정: jnivh(3인)에서 4번째 슬롯이 정확히 0.0s — forced-K 불필요.

## 2. 라이선스 경로 (착수 전 결정 필요)

| 경로 | 라이선스 | 비고 |
|---|---|---|
| **A (권장): v2 가중치 자체 변환** — HF `nvidia/diar_streaming_sortformer_4spk-v2` (.nemo) → 자체 CoreML/자체 bin | **CC-BY-4.0** (표기 의무만) | 클린. 변환 1회 오프라인 작업 (NeMo+coremltools venv, 디스크 ~4GB 필요) |
| B: FluidInference CoreML v2.1 재사용 | 저장소 태그는 cc-by-4.0이나 원본 v2.1 카드는 **NVIDIA OML** | 법무 확인 전 출시 금지. v2.1은 AliMeeting 근접장 개선(19.98→12.60)이 장점 |
| (참고) offline Sortformer v1 | CC-BY-**NC**-4.0 | 사용 불가 |

v2 vs v2.1 품질 차이는 회의 근접장에서 v2.1 우위. 1차 포트는 A(v2)로 진행하고,
v2.1은 법무 확인 후 drop-in 교체 가능하게 가중치 로딩을 버전-불문으로 설계.

## 3. 런타임 아키텍처 (권장: 하이브리드)

**mel 프런트엔드(Zig) + 네트워크 forward(CoreML via ObjC 브리지) + 상태머신(Zig).**

- **CoreML 브리지**: `metal_backend.m` 선례대로 ObjC 하나 추가 (`coreml_sortformer.m`).
  OS 프레임워크라 외부 의존성 0, ANE에서 17.5ms/청크 실증. 정적 shape:
  in `chunk` fp32 [1,112,128] + `fifo` [1,40,512] + `spkcache` [1,188,512] (+lengths),
  out `speaker_preds` [T',4] sigmoid (+ pre-encoder embs). 출력 프레임 80ms,
  기본 레이턴시 (6코어+7RC)×80ms = 1.04s.
- **mel (Zig 재사용)**: NeMo 로그멜 128빈, win 400 / hop 160 / nFFT 512 — madi
  `mel.zig`(whisper large-v3)와 bin 수·win·hop 동일. 차이: preemphasis 0.97, Hann
  (Povey 아님), per-feature 정규화 → 별도 경량 경로로 추가. **hop-정확 스트리밍
  누적 필수**: FluidAudio의 피드 경로는 호출마다 center-pad로 ~1 프레임을 유령
  생성해 타임라인이 ~2-3% 빨라지는 버그 실측(migzj 47.6 → 보정 후 6.9).
  자체 프런트엔드가 이 버그 클래스를 원천 회피.
- **상태머신 (Zig 포트)**: FluidAudio `SortformerStateUpdater.swift` 586줄 —
  FIFO append/pop, speaker-cache 압축(top-k log-prob + recency boost, 화자별 슬롯,
  침묵 프로파일). GPU 무관, 순수 CPU 로직.
- 2차(선택): 완전 sovereign Zig+Metal forward 포트 — 117M 파라미터
  (17-layer Fast-Conformer + 18-layer Transformer, d=512). Accelerate/Metal로
  청크당 수십 GFLOP → 실시간 가능 추정이나 포트 규모가 ResNet34(6.6M)의 ~18배.
  CoreML 경로 검증 후 필요 시.

## 4. 통합 계약 (기존 stdout/이벤트 계약 유지)

- `DIAR_BACKEND=sortformer` opt-in knob. 게이트 통과 전 기본 off.
- **슬롯→세션 id**: Sortformer의 4개 activity 스트림은 도착순(AOSC)으로 세션 내
  안정 → 슬롯 0-3을 세션 id로 1:1 사용. 재클러스터/출생확인(TTL) 기계 불필요
  (해당 경로 비활성), `SPK`는 finalized 프레임에서, tentative는
  후속 논의(현 계약은 즉시 `SPK`+`SPKFIX` 교정 — tentative를 `SPK`로 내보내고
  finalized 변경분을 `SPKFIX`로 내보내면 **기존 앱 계약 그대로** 재사용 가능,
  플립률 2.5-6%는 현행 churn 게이트로 측정).
- **겹침**: 멀티라벨 출력에서 2위 활성 스트림 = `SPKOV` 무료 획득 → sortformer
  모드에서 pyannote OSD 비활성 (모델·스레드 제거, 청크당 ~410ms 절약).
- **보이스프린트/SPKNAME**: ResNet34 임베더는 유지하되 슬롯-귀속 솔로 구간만
  임베딩해 등록 프린트와 대조 (Sortformer는 identity 임베딩을 노출하지 않음).
  FluidAudio에 화자 enrollment API(스피커 캐시 웜스타트) 존재 — v2 검토.
- **5인 이상**: 하드 캡 4 → `DIAR_MAXK>4`/auto-K가 5+ 감지 시 기존 파이프라인
  폴백 (세션 시작 시 백엔드 고정; 중도 전환은 하지 않음 — id 네임스페이스 파괴).
- **Unknown(255)**: 슬롯 모델에선 불필요. 폴백 경로에서만 기존 의미 유지.

## 5. 게이트 계획 (수용 기준)

1. `diar_panel_eval.py --live` 3케이스 + `live_ux_gate.py` vs 현행 베이스라인:
   immediate DER·wrong-visible·unresolved·churn·latency **전 축 Pareto 우위** 요구
   (오염 상한 감안, 실제 게이트는 현행 대비 상대 개선으로 판정).
2. 24파일 4화자 전수: per-file tail 게이트 (bwzyf +5.39 기각 선례 기준).
3. 비오염 검증: ES2004a(+ ko1/ko2/ko4 한국어 픽스처) — confusion/FA 축 중심.
4. >4인 폴백: 5인 이상 파일에서 폴백 경로 자동 선택 + 기존 수치 보존.
5. 성능: 청크 처리 p95 < 100ms, 웜 로드 < 1s, 메모리 상한 확인 (STT 동시 부하).
6. 라이선스: NOTICE/THIRD_PARTY_LICENSES.md에 CC-BY-4.0 표기 추가.

## 6. 작업 분해 (예상 순서)

1. v2 .nemo → CoreML 변환 스크립트 (오프라인, 재현 가능하게 커밋) + 수치 검증
   (변환본 vs 레퍼런스 활성값 비트 근사 확인).
2. `coreml_sortformer.m` ObjC 브리지 + Zig extern (load/predict/state I/O).
3. NeMo-mel Zig 경로 (hop-정확 스트리밍, 골든 벡터 대조 테스트).
4. 상태머신 Zig 포트 (`sortformer_state.zig`) + 단위 테스트 (Swift 구현 대조).
5. `transcribe.zig` 통합: `DIAR_BACKEND=sortformer` 분기, SPK/SPKFIX/SPKOV 방출,
   폴백 라우팅.
6. 게이트 5종 통과 → 기본 on 논의.

## 7. 레퍼런스 실측 재현

스크래치 하네스: (세션 스크래치) `b1_sortformer/` — `bin/fluidaudiocli`,
`bin/StreamProbe`(0.5s 라이브 피드 프로브, mel 드리프트 보정 포함), `json2rttm.py`.
모델 캐시: `~/Library/Application Support/FluidAudio/Models` (재다운로드 가능).
