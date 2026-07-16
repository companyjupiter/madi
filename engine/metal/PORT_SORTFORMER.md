# PORT_SORTFORMER — Streaming Sortformer v2를 madi 라이브 diar 백엔드로

상태: **보류 (2026-07-17) — 미래 플랜. 구현 착수 안 함.**
품질/성능 게이트는 통과했으나 **§2 메모리 예산 게이트에서 탈락** (최소사양
M1 8GB Air). 아래는 그때까지의 증거와 설계를 보존한 문서이며, 재개 조건은
§2에 명시. 근거 데이터: PERF_LOG `EMBED-SCREEN-2`/`OVL-GATE-NEG`/
`CENT-CAP-NEG`/`WIN-ALIGN-NEG` (현 아키텍처 내부 레버 소진 실증) + §1 실측.

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

## 2. 메모리 예산 게이트 — **현재 탈락 (보류 사유)**

최소사양 = **M1 MacBook Air 8GB (통합 메모리, CPU/GPU/ANE 공유)**.
라이브 번역까지 켠 최악 시나리오의 상주 가중치:

| 구성요소 | 상주 | 비고 |
|---|---|---|
| Whisper large-v3-turbo q8 | 1.51 GB | STT, 상시 |
| DNA3.0-4B Q4_K_M | 2.59 GB | 라이브 번역 시 |
| ResNet34 diar + OSD + VAD | 0.03 GB | 현행 diar 일습 |
| **소계 (현행)** | **≈ 4.13 GB** | + KV 캐시 / Metal 버퍼 / 앱 / OS(~2 GB) |
| **+ Sortformer fp16** | **+0.22 GB** (순증 +0.21, OSD 6 MB만 은퇴) | → **≈ 4.35 GB** |

8 GB에서 OS와 버퍼를 빼면 여유가 이미 얇습니다. **실측 선례**: 2nd DNA3
인스턴스 추가(+2.6 GB)가 8-16 GB 머신에서 OOM (PERF_LOG O4 DROPPED) — 이
예산이 이미 한계선에 있다는 증거. +229 MB 상주를 **최소사양 기기에서 무조건
켜지는 경로**에 넣는 것은 이 선례에 정면으로 어긋남.

**재개 조건 (하나 이상 충족 시 재평가):**
1. **6-bit 팔레타이즈 변형** — ~90 MB (fp16 대비 −60%), 대가 DER +0.9pp
   (레퍼런스 보고 기준, 미검증). 순증 +84 MB면 재검토 가치. **다음 측정 후보 1순위**
   (변환만 하면 되고 코드 불필요).
2. **더 작은 아키텍처** — LS-EEND (MIT, causal conformer 4블록/256-dim,
   단일 CPU 스레드 RTF 0.028). 파라미터/가중치 크기 **미확인 — 측정 필요**.
   Sortformer(117M) 대비 훨씬 작을 것으로 추정되나, AMI 스트리밍 20.76%로
   품질 마진은 작고 (현행 ES2004a live 25.66), FluidAudio 실사용 보고상
   FA↑·ID 안정성↓. 8 GB 제약 하에서는 오히려 이쪽이 현실적 후보.
3. **수명주기 분리** — diar 활성 구간에만 로드/언로드, 번역 엔진과 상호배타.
   복잡도 대비 이득이 불확실하고 세션 중 언로드는 화자 상태(AOSC) 파괴.
4. **기기별 티어링** (8 GB=현행 파이프라인 / 16 GB+=sortformer) — 제품 분기가
   생기고 "최소사양에서 품질 병목 그대로"라 목적을 못 이룸. 권장 안 함.

즉 **품질(§1)은 증명됐고 남은 문제는 순전히 상주 메모리**. 재개 시 순서는
①6-bit 변환 → 메모리/DER 실측 → 8 GB 실기 부하 테스트 → 그다음 §6 게이트.

## 3. 라이선스 경로 (착수 전 결정 필요)

| 경로 | 라이선스 | 비고 |
|---|---|---|
| **A (권장): v2 가중치 자체 변환** — HF `nvidia/diar_streaming_sortformer_4spk-v2` (.nemo) → 자체 CoreML/자체 bin | **CC-BY-4.0** (표기 의무만) | 클린. 변환 1회 오프라인 작업 (NeMo+coremltools venv, 디스크 ~4GB 필요) |
| B: FluidInference CoreML v2.1 재사용 | 저장소 태그는 cc-by-4.0이나 원본 v2.1 카드는 **NVIDIA OML** | 법무 확인 전 출시 금지. v2.1은 AliMeeting 근접장 개선(19.98→12.60)이 장점 |
| (참고) offline Sortformer v1 | CC-BY-**NC**-4.0 | 사용 불가 |

v2 vs v2.1 품질 차이는 회의 근접장에서 v2.1 우위. 1차 포트는 A(v2)로 진행하고,
v2.1은 법무 확인 후 drop-in 교체 가능하게 가중치 로딩을 버전-불문으로 설계.

## 4. 런타임 아키텍처 (권장: 하이브리드)

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

## 5. 통합 계약 (기존 stdout/이벤트 계약 유지)

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

## 6. 게이트 계획 (수용 기준)

1. `diar_panel_eval.py --live` 3케이스 + `live_ux_gate.py` vs 현행 베이스라인:
   immediate DER·wrong-visible·unresolved·churn·latency **전 축 Pareto 우위** 요구
   (오염 상한 감안, 실제 게이트는 현행 대비 상대 개선으로 판정).
2. 24파일 4화자 전수: per-file tail 게이트 (bwzyf +5.39 기각 선례 기준).
3. 비오염 검증: ES2004a(+ ko1/ko2/ko4 한국어 픽스처) — confusion/FA 축 중심.
4. >4인 폴백: 5인 이상 파일에서 폴백 경로 자동 선택 + 기존 수치 보존.
5. 성능: 청크 처리 p95 < 100ms, 웜 로드 < 1s.
6. **메모리 (§2, 선행 게이트)**: M1 8GB Air 실기에서 STT+번역+diar 동시 부하로
   OOM/스왑 없음. 이 게이트를 못 넘으면 나머지는 의미 없음 — 재개 시 최우선.
7. 라이선스: NOTICE/THIRD_PARTY_LICENSES.md에 CC-BY-4.0 표기 추가.

## 7. 작업 분해 (예상 순서 — **§2 해소 후에만 유효**)

0. **(선행) 6-bit 팔레타이즈 변환 + 8GB 메모리/DER 실측** — 여기서 탈락하면 종료.
1. v2 .nemo → CoreML 변환 스크립트 (오프라인, 재현 가능하게 커밋) + 수치 검증
   (변환본 vs 레퍼런스 활성값 비트 근사 확인).
2. `coreml_sortformer.m` ObjC 브리지 + Zig extern (load/predict/state I/O).
3. NeMo-mel Zig 경로 (hop-정확 스트리밍, 골든 벡터 대조 테스트).
4. 상태머신 Zig 포트 (`sortformer_state.zig`) + 단위 테스트 (Swift 구현 대조).
5. `transcribe.zig` 통합: `DIAR_BACKEND=sortformer` 분기, SPK/SPKFIX/SPKOV 방출,
   폴백 라우팅.
6. 게이트 5종 통과 → 기본 on 논의.

## 8. 레퍼런스 실측 재현

스크래치 하네스: (세션 스크래치) `b1_sortformer/` — `bin/fluidaudiocli`,
`bin/StreamProbe`(0.5s 라이브 피드 프로브, mel 드리프트 보정 포함), `json2rttm.py`.
모델 캐시: `~/Library/Application Support/FluidAudio/Models` (재다운로드 가능).
