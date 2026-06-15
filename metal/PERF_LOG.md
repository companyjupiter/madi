# Metal perf optimization loop — log

Autonomous self-paced optimization on branch `feature/metal-perf-loop`.

## Protocol (per iteration)
1. Pick next idea (backlog below, or derive from quark `_perf__measured` bands).
2. Implement (kernel / host edit).
3. **Build** — fail → revert, log FAIL.
4. **Correctness gate** (hard): `test_encoder` + `test_decoder` stay green AND
   `transcribe assets/jfk.wav` text **exactly** == golden:
   `And so, my fellow Americans, ask not what your country can do for you, ask what you can do for your country.`
   Any mismatch → revert, log FAIL.
5. **Measure** encoder/decoder ms (≥3 runs, take min).
6. **Decide**: faster beyond noise (>3%) & correct → keep → regen quark → `git commit`.
   Else → `git revert`(working tree) → log as tried-and-failed (Data).
7. Append a row below. Regenerate quark after any committed `.metal`/`.zig` change.

## Baseline (M4 Pro, jfk 11s) — start of loop
encoder ~565 ms · decoder ~120 tok/s · flash_attention_enc_f16 4.88 ms/layer
front-end conv1d_gelu ~50 ms × 2.

## Idea backlog
- conv1d_gelu: F16 weights (bandwidth), or MPS/im2col GEMM, or better tiling.
- decoder: F16 weights for self/cross/MLP GEMVs (M=1, bandwidth-bound).
- decoder cross-attn (flash_cross_attn): F16 K/V cache.
- logit_gemv_f16: tune threadgroup / 2-row.
- encoder: fuse bias into LN/GEMM epilogue; reduce per-layer sync further.

## Results (newest first)
| # | idea | result | metric | commit |
|---|------|--------|--------|--------|
| LOAD-mmap | **mmap 빠른로드(파일모드) — whisper.cpp 로드격차(~1.3s) 닫기 시도** | ❌ 반증 (측정) | Sf 로더를 파일모드서 pread→mmap zero-copy로(라이브는 RSS 위해 pread 유지). 측정: devops_ko wall **mmap 15.7s == pread 15.7s (차이 0)**. 가설(로드 I/O-bound) 반증: 모델 파일이 **page-cache-warm**이라 mmap·pread 둘 다 디스크 I/O 동일, ~1.3s 로드의 실체는 **Q8 dequant→GPU 복사 CPU 작업**(I/O 아님). mmap은 CPU dequant 안 줄임. whisper.cpp 로드 0.2s는 ggml이 **dequant 없는 load-ready 포맷**이라서 — 우리 격차는 근본적(로드시 dequant). revert(이득0+RSS만 +827MB). 교훈: 로드 격차는 I/O 아닌 텐서 처리. 진짜 닫으려면 load-ready 포맷 or GPU-side dequant(별건). PROF상 로드+IO 23% 중 모델로드는 ~1.3s(8%)뿐이라 ROI도 낮음 | — |
| MEL | **멜 스펙트로그램 twiddle 미리계산 + 멀티스레드 — 숨은 최대 병목** | ✅ commit (비트동일, ~2× end-to-end) | whisper.cpp head-to-head(devops_ko 7.7분) 중 **wall 갭 규명**: ours 33s vs whisper.cpp 14.5s인데 [perf](인코더+디코드) 합은 12.5s뿐 → **~20s가 [perf] 밖**. 추적: [enc] 배치마다 +7.3s 갭, 인코더 forward는 2s뿐 → 나머지 5s/배치 = **멜 계산**. mel.zig `rfft`가 **naive O(N²) DFT + 매 반복 @cos/@sin**(twiddle 미리계산 없음, 단일스레드) → **청크당 ~482M trig = ~1.3s/청크**(whisper.cpp mel 3.6ms!). 해결: ① twiddle factor(cos/sin) f64 테이블 1회 미리계산 → 매프레임 trig 제거(비트동일: f64=옛 @cos) ② 프레임 루프(3000, 완전독립) 멀티스레드(≤8코어). 결과: **devops_ko wall 33s→~16s(~2×)**, jfk 전사 비트동일, 2회 sha 동일(race-free 결정적). **whisper.cpp(14.5s)와 박빙으로 좁힘** — 인코드·디코드는 원래 동률이었고 갭의 전부가 멜이었음. 교훈: [perf]가 GPU만 재서 host CPU 병목(멜)이 가려졌다. quark atom `fn__rfftTw`·`fn__ensureTwiddles` | feat(mel) |
| P5 | **배치 cross-attention 커널 (J 미완 레버 구현)** — multichunk 디코드의 per-slot cross-attn B-loop을 1 dispatch로 | ✅ commit (커널·프리미티브 검증, 1.27× 배치블록) | **probe(test_p5probe)로 GO 판정**: 배치 디코드(B=8) 시간 분해 = self-attn **6.5%** / **cross-attn 43%**(4.18ms/step) / 나머지 50%. cross-attn은 KV 대역폭천장(245MB/step÷400GB/s=0.61ms)의 **6.8× off = occupancy-bound**(NH=20 threadgroup B개 별도 dispatch가 GPU 저활용). **`flash_cross_attn_f16kv_batched`**(grid B*NH, contiguous cross-KV [B][ENC_SEQ][D], tgid→slot b·head h)로 B개를 1 dispatch에. 결과: decodeBlockBatched **9.68→7.66ms/step = 1.27×**(cross-attn 4.18→2.16ms = **1.94×**). 정확성 PASS(test_decblock_batch·test_decloop_batch rel 7.6e-4). self-attn(6.5%)은 per-slot 유지. **J 부활의 토대** — multichunk 재통합 시 nb=8 win이 7%→실질로 커지고 크로스오버↓. (현재는 프리미티브만 — 라이브/파일 디코드는 per-slot decodeBlock 유지, multichunk 재통합이 다음 단계.) quark atom `metal_kernel__flash_cross_attn_f16kv_batched`·`fn__kCAbatched` | feat(decode) |
| AUTO-perf-recon | **자율주행 perf 표적 일괄 판정 — 대역폭 절감류 전부 반증(분석), P5만 생존** | ✅ 분석 판정 (구현 전 EV 컷) | 기존 측정(J-recon: logit GEMV **14%**·디코더 레이어 **86%**, 대역폭천장 180MB/tok의 **5.8× off = occupancy-bound**)으로 후보 일괄 판정: **P1 self-KV F32→F16** = self-attn은 occupancy-bound 86%의 작은 일부, 대역폭 비묶임 커널서 KV 반감 → marginal(PERF_LOG row3 "proj GEMV→f16 3.4× 느림" 동근원) → **반증, 미구현**. **P3 logit vocab prune** = logit 14%뿐 + 이미 batch 9.5× → ≤14% 천장, 약함. **P4 int4 공격적** = occupancy-bound에 대역폭 절감 → marginal. **인코더(P2)** = MPS GEMM 이미 "hand-MSL 불가"(Q8-3a 2.39× 느림)·과거 conv F16/dequant fuse 다 neutral/revert → 헤드룸 낮음, silence-skip은 seq 압축 필요(품질 위험). **결론: occupancy-bound 86% 레이어를 직격하는 P5(배치 attention)만 실 레버** — J가 가리킨 미완 커널. 교훈: 측정-우선이 4개 표적 중 3개를 구현 전 컷(점유-바운드 디코드에 대역폭 절감은 무효) | analysis |
| J | **멀티청크 배치 디코드 — 통합 완성·정확, 속도 반증** (PR#39 프리미티브·#41 decodeBlockBatched·#42 KV성장 검증, 통합 revert) | ✅ 정확성 검증 / ❌ 속도 반증 (측정) | **전체 end-to-end 통합 구현·검증**: BATCHDEC 경로가 nb 슬롯을 배치 디코드(cross-KV·seed·per-token 루프·per-slot argmax/EOT). **전사 품질-등가**(jfk3 2청크 byte-identical, devops_ko 한국어 775단어 동일). **그러나 속도 반증**: nb=2 배치 **704ms vs per-slot 576ms(22% 느림)**, nb=8서야 525 vs 492 tok/s(~7% 빠름), 크로스오버 ~nb=5-6. recon의 projection 6-9× 여유가 전체로 안 옮겨옴 — **attention이 per-slot B-loop(미배치, 디코더 비용 큰 부분)** + **F32↔F16 변환 오버헤드**(projection마다 cvt 2회) + cross-KV 셋업 오버헤드가 projection 이득을 상쇄. "default-ON은 좋을 때만" 제약상 부적격 → **통합 revert**. **진짜 레버=배치 attention 커널**(per-slot B-loop 제거, 상당한 Metal 작업). **유지**: 검증된 decodeBlockBatched(decoder.zig)·cvt_f32_f16·프리미티브/루프 테스트(미래 배치-attention 토대). 교훈: 부분(projection) 배치로는 부족 — 디코드 per-token 비용에서 attention+변환이 projection만큼 큼 | docs(J) |
| J-recon | **추측 디코딩 레버 정찰** — 디코드 병목·배치 verify 효율·draft 실현성 (test_specgemm.zig) | ✅ 정찰·**메커니즘 검증 / draft 반증 / redirect** | **레버 확정**: 강제160토큰 디코드 3.86ms/tok, logit GEMV 14%·디코더레이어 86%, 대역폭천장(~180MB/tok)의 **5.8× off = occupancy-bound**(단일토큰 GEMV가 GPU 저활용). **make-or-break(GEMM batch-scaling)**: FFN(1280×5120) M=1→8 토큰당 **387→64µs(6.0×)**, logit(1280×51866) **1227→129µs(9.5×)**, M=16서 22×/8.8× → 배치 forward가 6-9× 효율(점유 여유 확정). **그러나 draft가 full logit(토큰당 지배비용)을 못 피해 partial-depth self-draft는 ~break-even**(별도 draft 모델/Medusa 헤드=학습 필요, 범위 밖) → **순수 추측 디코딩 보류**. **Redirect: 멀티청크 배치 디코드** — 같은 occupancy 여유를 draft 없이, 긴 파일의 독립 청크들 token-t를 배치 forward로(바이트동일, 파일모드). test_specgemm.zig 보존 | docs(J-recon) |
| L | **diarization-aware 디코딩** — 화자 전환서 디코더 context 리셋(교차화자 누수 차단 의도) | ❌ 반증 (통제실험) | **FLEURS 두 발화(1662+1672, 다른화자) 연결 → 합동 vs 개별 디코드 CER 비교(정답 보유)**. 1차 합동이 B 통째 누락처럼 보였으나 **자가 적발: `concat:` 바이트연결이 이중 WAV 헤더 생성 → 엔진이 A 헤더만 읽음**(측정 버그, early-EOT 아님). `-f concat` 재인코딩(유효 22.4s WAV)으로 재측정 시 **A·B 둘 다 완전·정확 디코드**("…잊지 마라 원단이…" 경계 깨끗), A 부분은 개별 디코드와 동일=**교차화자 bleed 0**. 실제 연속 2화자(devops_ko 16분)도 전체 정상. **결론: diar-aware 디코딩은 실재 문제 미해결 — 엔진이 멀티화자를 이미 완전 디코드, 잔여 오류=confident-substitution(P3 외부지식 레버, G와 일치).** 틀린 결론 직전 측정 아티팩트를 잡은 것이 핵심 | docs(L) |
| H | **OSD-confidence 게이트 (P2b 후속)** — overlap 행 P(overlap) 임계 상향(file-mode diarizeEmb `OSD_THR` 0.25→0.45)으로 노이즈 클립의 저신뢰 false overlap 컷, 고신뢰 실제 overlap 보존 | ✅ commit·**측정된 순개선** | **VoxConverse-dev 216 매칭 A/B(같은 바이너리)**: OSD_THR 0.25 MEAN 8.03%(med 3.54) → **0.45 MEAN 7.82%(med 3.51) = −0.21pt**. **tucrg 356→315(−42pt)**, jiqvr −1.4·sqkup −1.0 개선. **5 개선 / 1만 >0.5 악화**(cwryz +0.8 — 실제 overlap 약간 손실, 수용가능). 라이브 emitOsdOverlap은 **0.25 유지**(L-3 ES2004a 튜닝값, 재측정 없이 불변 — 파일/라이브 default 분리). P2b가 "tucrg만 보고 OSD 끄기"를 막은 뒤, 임계 스윕으로 실제 게이트를 찾은 흐름. jfk 전사 불변 | docs(H) |
| G | **다중-forward / TTA 합의 신뢰도** — N회/섭동 디코드 불일치를 오류신호로(단일-forward conf의 confident-error 약점 직격 의도) | ❌ 반증 (측정) | **2단 측정**: (1) 자연 GPU 비결정 — FLEURS 1660 **5회 바이트동일**(다양성 0). (2) 입력 augmentation(속도±4%·게인·대역통과) — 실제 confident 오류 utts(1660 피이테·1667·1669·1672) **TTA 다양성 0%**(섭동 강건). 전체 12.9%는 대부분 속도섭동 **위치-시프트 정렬 아티팩트**(1705 80%=노이즈), 오류상관 신호 아님. **삼중 확인(CONF-2·P1·G): confident 오류는 비결정·섭동 모두에 강건 → 어떤 self-agreement도 못 잡음**(모델이 안정적으로 확신하며 틀림). 결론: 진짜 레버는 **외부 지식**(LM 재점수/큰모델/도메인 prior=P3 바이어싱)이지 self-agreement 아님. bench/tta_agreement.py 보존 | docs(G) |
| F | **스트리밍 부분가설 + 라이브 브릿지** (quark atoms: `fn evPartial`, seg-loop partial emit, `var g_bpe_cache`) — 디코드 8-batch마다 진행중 텍스트를 `partial` 이벤트로(opt-in PARTIALS=1). Node SSE 브릿지(web/bridge/server.mjs)가 엔진 stream 모드 spawn+EVENTS_FILE tail→SSE, 대시보드 EventSource 라이브 소스+▶라이브 토글+● 인식중 렌더. 부산물: **vocab 64MB 전역 캐시**(bpeDecode 매콜 재로드 제거 — 단어/부분 디코드 가속) | ✅ commit·검증 | jfk3 partial 11개(점진 성장 확인), **seg 텍스트 PARTIALS 유무 바이트동일**(부가적·무회귀), bench 경로(PARTIALS 미설정) jfk 전사 불변. **브릿지 SSE 실측**(60s 클립): meta/ready/38 partial/109 word/2 seg/flush_end 스트림. 대시보드 라이브 스크린샷: 전사·메트릭·perf(496 tok/s) 라이브 채워짐. **알려진 갭**: stream 모드는 diar/spk_seg 미emit(파일모드 diarizeEmb 전용)→라이브 화자패널은 후속(SPK 라벨 이벤트 배선 필요) | docs(F) |
| P2b | **OSD 중첩 행 순효과 A/B** (P2 진단 후속: "OSD가 노이즈 클립서 +124pt → 파일모드 비활성 후보") | ❌ 반증 — OSD 유지(현 기본값 최적) | **매칭 A/B(같은 diar 코드, VoxConverse-dev 216, OSD=1 vs 0)**: OSD-on **8.03%**(median 3.54) vs OSD-off **8.22%**(median 3.92) = **OSD-off가 +0.19pt 악화**. tucrg는 OSD-off로 -123.8 개선되나 **55파일 악화 vs 12 개선**(mevkw +16.0·vbjlx +12.9·nxgad +10.4 — 진짜 중첩 감지 손실). **결론: OSD 중첩은 순효과 +, 전역 비활성화는 55파일 회귀. tucrg OSD 페널티는 광범위 중첩 가치의 수용가능 비용.** 매칭 A/B가 "tucrg만 보고 OSD 끄는" 함정을 차단(55파일 회귀할 뻔). 향후: per-file OSD-confidence 게이트(tucrg 컷 + 55승 보존)는 임계 스윕 필요 — 보류 | docs(P2b) |
| P3 | **용어 바이어싱 (initial-prompt 컨디셔닝)** (quark atoms: `fn bpeEncode`, seed `STARTOFPREV` 프리픽스, `fn evSeg` bias_hits) — env PROMPT=도메인 어휘를 `<|startofprev|>`+토큰으로 시드 앞에 붙여 디코더를 고유명사/전문용어로 편향. 엔진에 없던 **BPE 인코더 신설**(greedy longest-match; vocab이 raw UTF-8 저장이라 한국어 직접 매칭) | ✅ commit·**실증+무회귀** | **FLEURS-ko #1660 ground-truth A/B**: baseline "괴테나 **피이테**, 슐레겔"(오인) → PROMPT="괴테 피히테 슐레겔" "괴테나 **피히테** 슐레겔"(교정), **CER 3.33%→1.67%(반감)**, 피히테 정확 False→True. **안전성 2종**: (1) PROMPT 미설정/빈값 → no-prompt 바이트동일(미사용 무회귀), (2) 무관 한국어 prompt를 영어 jfk에 → **환각 주입 0**(영어 전사 유지, 모델이 무관 context 무시). bias_hits 계약필드(세그먼트에 등장한 prompt 용어) + 대시보드 "적용된 용어 바이어싱" 칩 패널(devops_ko_biased: 데브옵스·제로트러스트 검출). 제품차별: 회의 전사 커스텀 용어집 | docs(P3) |
| P2 | **gt=3 DER 16.76% 버킷 진단** — gt=2(4.43%)의 3.8배 이상치로 보였으나 표적 재정의 | ✅ 진단 / ❌ 단일 수정 불가(2원인 분리) | **핵심: 평균(16.76%)이 오도 — median은 4.58%**(gt=2와 동급, 3화자 diar은 건강). 평균은 **tucrg(356%) 단독 지배**(제외 시 6.76%, 상위3 제외 5.48%). tucrg 분해: 26.2s 중 **ref speech 4.5s(17%)** — near-continuous 크로스토크 TV클립(Trump 토론)을 ref가 희소 annotate → 시스템이 실제 음성 9.6s 올바로 감지해도 232% 과방출, OSD 중첩이 +124pt(356%). **silero 게이트 시도→무효**(silero도 노이즈를 speech 판정, 8/17 동일) → revert(byte-clean). 나머지 꼬리(paibn 99%·jnivh 120%·uatlu 88%·rtvuw 114% speech)는 정반대 **dense overlap-heavy** = 진짜 3화자 중첩 클러스터링 오류(20-28%, 깊은 연구과제). **결론: gt=3는 systematic 문제 아님 — tucrg=희소-ref 아티팩트(수정시 215파일 회귀), dense-overlap 꼬리=별도 deep work 보류. OSD가 노이즈 클립서 +124pt(향후 OSD-confidence 게이팅 후보)** | docs(진단) |
| P1 | **temperature/logprob 폴백 디코딩** (quark atoms: `seg`-loop `pass_avg_lp` 트리거 + `fn evSeg` avg_logprob/fallback 필드) — 그리디 단일패스에 Whisper 표준 강건성 신호 추가. **측정 선행**(bench/logprob_probe.py, test-other worst/best 각 15): avg_logprob가 WER와 상관(best 평균 −0.07 vs worst −0.44)이나 표준 임계 −1.0은 worst 15개 중 **1개만** 포착 — 잔여 실패는 −0.15~−0.72 "확신하며 틀림"(CONF-2 재확인, 재디코드 불가). 유일 −1.0 초과 1건이 진짜 퇴화(REF "WELL"→HYP "Well, I'm going to", WER 400%). 결정: **full temperature-sampling 커널 기각**(WER 무버 아님 + 비용 큼), 대신 **avg_logprob<−1.0 → 기존 ts_mode rescue 트리거**(값싼 안전망, 새 커널 0) + avg_logprob/fallback **계약 필드 실값화** | ✅ commit·**무회귀 +미세개선** / ❌ temperature sampling 기각 | **깨끗한 A/B(같은 바이너리, LOGPROB_RESCUE −1.0 vs −99, test-other 300)**: rescue OFF **6.19%**(I=37) → ON **6.09%**(I=32) = **삽입 5개 제거, S/D 불변, WER −0.10pt**. **정확히 2/300 발화만 변경**(파탄 400%→0% 1건 + ZARATHUSTRA 오인 1건 중립), 오탐 0. 정상 반복음성 안전(jfk3 3× 진짜반복 avg_lp −0.024 ≫ −1.0 → 미발동, byte 영향 0). **핵심 반증: temperature 폴백은 이 벤치들서 WER 무버 아님** — 퇴화/무음환각은 기존 tokenCollapse+hallucination-guard가 이미 커버, 잔여는 confident-substitution. 부수익: avg_logprob/fallback이 출력계약+대시보드 품질신호로 실값화(예약 temp만 잔존). bench/logprob_probe.py 보존 |
| SOLO-1 | **솔로 화자 과분할 게이트** (quark atom: `fn__maxCentroidCosDist`, diarizeEmb+liveRecluster 양 경로) — silhouette는 상대지표((b−a)/max)라 단일화자가 발성변이로 고-silhouette 서브클러스터로 쪼개짐. **절대 분리 게이트**: 선택된 분할의 **max 쌍별 centroid 코사인거리 < DIAR_MIN_SEP(0.50)** → K=1 붕괴. file·live 동일 적용(보이스프린트 하한 전) | ✅ commit·**깨끗한 A/B 무회귀** | 동기: jfk3 단일화자가 K=2 과분할(silhouette 0.530>tau 0.35). 측정: 단일 max=0.326 vs 실멀티 전부 ≥0.727 → 0.50이 갭 한가운데. **동일 바이너리 A/B(게이트 OFF=DIAR_MIN_SEP −1 vs ON, VoxConverse-dev 216파일)**: gt=1 버킷 **4.93→1.84%(−3.09pt)**, **gt=2/3/4/5-6/7+ 전부 Δ+0.00pt 바이트동일**(멀티 0개 변경), MEAN 8.35→**8.03%(−0.31pt)**. 게이트 발동=정확히 5파일 전부 gt=1 단일화자(pqmho 39.72→6.56, hqyok 21.85→3.63), **실멀티 거짓붕괴 0건**. stale baseline(maxK=10)의 gt=3 "악화"는 config차(maxK 10→6)였음을 매칭 A/B로 확정. jfk3 K=2→K=1 검증, devops 2화자 K=2 불변. bench/gate_ab.py 보존 |
| 1 | conv1d_gelu F16 weights | ❌ revert | conv 23–47ms/call, no clear gain (weights cached across time axis → compute-bound, not bandwidth) | — |
| 2 | decoder cross-attn F16 K/V cache | ✅ commit (memory) | decode 120→123 tok/s (speed neutral, within noise); cross-KV cache 61→30 MB; correct | flash_cross_attn_f16kv + extract_ca_head_f16kv |
| 3 | decoder proj GEMVs → custom F16 GEMV (replace MPS M=1) | ❌ revert | decode 212→712ms (3.4× SLOWER); MPS M=1 GEMV is already well-optimized, naive 1-thread/col kernel far worse | — |
| 4 | logit_gemv F16 coalesced (warp/row + simd_sum) | ✅ commit | decode 118→128 tok/s (~8%); logit kernel 882→640us; correct | logit_gemv_f16_cg |
| 5 | flash_cross_attn phase1 warp-per-key (coalesced) | ❌ revert | decode 128→121 tok/s (slower); coalescing gained but parallelism dropped (256 threads→8 warps) for seq=1500 | — |
| 6 | conv1d → im2col + MPS F16 GEMM | ✅ commit | conv front-end ~95→22ms (~4×); total 3.22→3.15s; correct | im2col_f16, gelu_transpose, gelu_pos |
| 7 | MPS object caching (shape-keyed descriptors+op) | ✅ commit | decode 120→130 tok/s (~8%); encoder neutral; correct | backend mps_cache_get |
| 8 | decoder QKV 3→1 batched GEMM | ✅ commit | decode 130→134 tok/s (~3%); 8 fewer GEMM calls/token; correct | (stacked qkvw) |
| 9 | encoder all-layers single command buffer | ❌ revert | encoder 590→589ms (~0%); compute-bound, sync overhead negligible vs GPU work | — |

## Q8 quantization phase (memory + bandwidth)
| # | idea | result | metric | commit |
|---|------|--------|--------|--------|
| Q8-1 | embed_tokens → Q8_0 (int8 + per-32 fp16 scale); logit/emb lookups Q8 | ✅ commit | decode 134→140 tok/s; peak RSS 4.78→3.40GB; text exact | logit_gemv_q8, emb_lookup_indirect_q8, gpu_emb_lookup_q8 |
| Q8-2 | decoder proj GEMVs (q/k/v/o/cq/co/m0/m2) → Q8 warp-per-row GEMV | ✅ commit | decode 140→188 tok/s (~34%!); RSS 3.40→3.13GB; text exact. (iter3's custom GEMV lost only due to bad uncoalesced design; coalesced Q8 beats MPS M=1) | gemv_q8 |
| Q8-3a (de-risk) | direct custom Q8 tile GEMM (mul_mm_q8, 32×32 tile/4 simdgroups) vs MPS F16 @ encoder shape 1500×1280×1280 | ❌ data | correctness OK (max_abs_err 1e-3); **2.10ms vs MPS 0.88ms = 2.39x SLOWER**. compute-bound M=1500 ≠ decoder M=1 GEMV; vendor MPS GEMM unbeatable by hand-MSL here. ⇒ direct-Q8-GEMM rejected for encoder | mul_mm_q8 (test_q8gemm.zig) |
| Q8-3b | **encoder proj weights → Q8 (out-major) + JIT transposing dequant→F16 scratch + MPS F16 GEMM** (qkv/o/fc1/fc2, 32 layers) | ✅ commit (memory) | **peak RSS 3.13→2.54GB (−0.59GB!)**; encoder 587→627ms (+7%, dequant launches, acceptable: encoder is 1×/30s-chunk); decode unchanged 193 tok/s; jfk text **exact**. test_encoder/decoder green. Keeps MPS GEMM speed while dropping F16 weights 1.26GB→0.67GB | dequant_q8_f16 |
| Q8-3c | recover +7%: fuse q/k/v dequant 3→1 launch (dequant_q8_f16_qkv, 192→128 launches/forward) | ❌ revert | encoder 627→630ms (neutral, within noise). The +7% dequant cost is **bandwidth-bound** (F16 scratch round-trip ~1.9GB write + MPS read), NOT launch-bound — cutting 64 launches changed nothing (cf iter9: encoder sync overhead negligible). Irreducible w/ MPS: only fused dequant+GEMM avoids the round-trip, but that's the 2.39x-slower mul_mm_q8. +7% accepted as cost of memory win | — |
| Q8-4 | cross-attn K/V proj weights (ckw/cvw, 4 layers) → Q8 + JIT dequant→MPS (per-chunk cross-KV is M=1500, same as encoder; reuses dequant_q8_f16) | ✅ commit (memory) | clean A/B same thermal window: encoder/decode **identical** (~658ms/~188 tok/s — perf-neutral); peak RSS 2.543→2.531GB (−12MB, F16 cross-KV weights 26→14MB); jfk text exact; test_encoder/decoder green | deqW16 (reuses dequant_q8_f16) |

## Accuracy / quality
Gate (in addition to jfk exact): silence must produce EMPTY output.
Repro: `python3 -c "import wave;w=wave.open('/tmp/sil.wav','w');w.setnchannels(1);w.setsampwidth(2);w.setframerate(16000);w.writeframes(b'\x00\x00'*16000*30)"` then transcribe /tmp/sil.wav.
| # | issue | result | metric | commit |
|---|------|--------|--------|--------|
| ACC-1a (data) | silence hallucination: 30s digital silence → "you. You. You."; tried <|nospeech|>(50363) prob gate at SOT & first-pred positions | ❌ data | P(nospeech)≈0 for silence at BOTH positions (logit_ns even *lower* for silence than jfk) — large-v3-turbo doesn't fire nospeech on OOD digital/near-silence. Token-prob gate unreliable here | — |
| ACC-1b | **energy VAD**: skip a chunk whose loudest 1s-window RMS < 0.01 (speech≈0.14, silence/ambient≲0.001). Skips mel+encode+decode entirely | ✅ commit | silence30 & lownoise30 → **empty** (was hallucinated text); jfk **exact**; jfk3 both chunks full (chunk2's 3s speech kept via max-1s-window metric). Bonus: silent chunks now ~free | hasSpeech VAD |
| ACC-2a (data) | diarization on Whisper **encoder** features (old k=2/≤30s stub, and a new global variable-K AHC) | ❌ data | DER measured on AMI ES2004a (4-spk, md-eval.pl, collar 0.25): all clustering ≥90% ≈ single-spk baseline. Direct proof: intra-speaker cosine 0.006 ≈ inter 0.001 → **encoder output is speaker-invariant** (ASR discards speaker id). Analysis of CUDA reference: it clusters **mel** features, not encoder; final stage is 2-way Fiedler bisection | — |
| ACC-3 | **language auto-detection** (arg-max over language tokens 50259..50358 at the SOT-position logits; env WHISPER_LANG_ID override) + verified Korean | ✅ commit | jfk→en(50259), Korean DevOps 7m42s→ko(50264); fluent Korean across all 16 chunks incl @450s; word timestamps monotonic/aligned; 462s in 36.5s (~12.7× RT); 2-spk timeline alternates with the dialogue. Records in bench/MULTILINGUAL_TEST.md | lang-detect probe |
| ACC-2b | **mel-feature diarization**: pool RAW (unnormalized) log-mel per 1.5s segment → energy VAD → per-dim z-score → k-means (K = CLI arg / DIAR_K, default 2) → global RTTM. mel carries timbre/pitch (intra−inter separation **0.22** vs encoder 0.007) | ✅ commit | **AMI DER 90%→65% (K=2)**; K param exposed (K=4 runs, 76% on hard far-field AMI, better on clean audio); jfk text exact; runs globally on any length (old stub was ≤30s/≤2spk). Oracle ceiling 24% (1.5s seg) — SOTA would need a dedicated speaker-embedding model | melSpectrogramRaw, diarizeMel; bench/ DER harness |

| ACC-4 | **WIN: sovereign ResNet34 speaker-embedding diarization** — hand-ported wespeaker ResNet34 (Apache-2.0) to Zig (kaldi 80-fbank + conv2d via Accelerate sgemm + stats pool + FC), 256-d embeddings per 1.5s window → L2-norm + k-means(K) | ✅ commit | **AMI ES2004a K=4 DER 32.5%** (was 90% encoder / 67% mel; oracle 28.8%). Verified bit-for-bit vs onnxruntime (cosine 1.000000) at every stage. jfk text exact; silence→no spurious speakers. K = CLI/DIAR_K (default 2). No runtime dep (onnxruntime only offline). +~34s/17min for embeds (CPU), RSS +~0.1GB | diar_resnet.zig, bench/ |

## Diarization perf (quark-decomposed, measured)
quark atoms: `file__diar_resnet.zig/{fn__embed,conv2d,fbank,fft512,relu}`.
Per-stage profile (608 AMI embeds) revealed the bottleneck is NOT matmul FLOP:
| stage | share | | conv internal | share |
|---|---|---|---|---|
| stage1 (80×150, 32ch) | 40% | | **im2col** | **77%** |
| stage2 | 26% | | sgemm (Accelerate) | 23% |
| stage3 | 21% | | | |
| stage4 / fbank / pool+gemm | 13% | | | |
| # | idea | result | metric | commit |
|---|------|--------|--------|--------|
| DIAR-OPT1 | im2col: element-by-element strided copy + full @memset → @memcpy of contiguous valid spans (stride-1 path) | ✅ commit | **68→28 ms/embed (2.4×)**; AMI 17min total 100→83s; DER unchanged 32.49% (cosine 1.0 preserved); im2col 15.9s→7.6s | conv2d im2col |
| DIAR-OPT2 | multithread embeds across segments (std.Thread pool over a chunk's ~20 windows; Accelerate pinned to 1 thread/worker via VECLIB_MAXIMUM_THREADS=1 to avoid oversubscription) | ✅ commit | AMI 17min total 83→71s; diar embed ~2.4× (12 cores). NOT Ncore× — im2col is memory-bandwidth-bound, threads share bandwidth → sublinear. DER unchanged 32.49%; jfk exact; silence safe | DiarJob/diarWorker |
| (next) | F16 convs or MPS GPU (compute, not bandwidth) for true scaling; or fuse im2col into a direct conv to cut data movement | backlog | total now transcription-bound (diar ~7s of 71s) | — |

## Memory architecture
| # | idea | result | metric | commit |
|---|------|--------|--------|--------|
| MEM-1a (data) | reclaim mmap'd safetensors via madvise(MADV_DONTNEED, then FREE_REUSABLE) per-tensor after quantize | ❌ data | **no effect** on macOS: peak AND steady RSS flat at 2.53/2.40GB. macOS doesn't drop read-once clean file-backed pages from the resident set (DONTNEED is lazy/deactivate-only; FREE_REUSABLE is for anon malloc pages). ru_maxrss high-water never decreases. ⇒ madvise can't fix it | — |
| MEM-1b | **mmap → pread streaming loader**: never map the 1.6GB data section; pread each tensor into one reusable scratch buffer, consume, overwrite; free scratch+fd after load | ✅ commit (memory, **headline**) | **peak RSS 2.53→1.02GB (−1.5GB, −59%!)**; steady ~0.94GB; jfk text **exact**; encoder/decode unchanged (653ms/188 tok/s); load time unchanged (3.82 vs 3.90s, 2 chunks). Biggest single memory win — exceeds all Q8 work combined | Sf pread + g_rd scratch |

## Auto-K estimator study (2026-06-11, VoxConverse-dev offline)
Harness: `bench/k_study_vox.py` + `bench/k_sweep_vox.py` on `diar_embed_wav`
embedding dumps (215 files, gt speaker counts from ref RTTM). Goal: fix the
demo4 K=2 under-estimate (true 4) without breaking the rest.
| # | idea | result | metric |
|---|------|--------|--------|
| K-EST1 | eigengap (normalized-Laplacian, cosine affinity) | ❌ data | exact 27% vs sil 63% (51-file prelim) — under-estimates far-field badly |
| K-EST2 | BIC elbow (spherical k-means) | ❌ data | demo4 K=3, es K=6 — no better than sil anywhere |
| K-EST3 | raw-pairwise AHC (cosine threshold sweep 0.30-0.60) | ❌ data | far-field explodes (es: 81-469 clusters) — pairwise cosine too noisy without affinity refinement |
| K-EST4 | NME-SC (p-binarized affinity eigengap, simplified Park et al.) | ❌ data | exact 51% vs sil 63%; under-estimates K≥5 |
| K-EST5 | recursive 2-way split (split cluster when its sub-silhouette ≥ sub_tau) — fixes demo4 at sub_tau=0.5 (sub-sils: true-pair 0.55/0.59 vs noise 0.39-0.41) | ❌ data | VoxConverse over-split at EVERY sub_tau (0.45-0.80): best case = no-op, worst exact 50.6% vs 55.1% baseline. demo4's crisp TTS sub-structure is common in real single speakers |
| K-EST6 | silhouette tau bump 0.10→0.25-0.40 (K=1 gate) | 🔬 candidate | K1-recall 0→14% with 0 false positives (89-file prelim) — pending full-set + DER check |
Conclusion: shipped silhouette remains the best estimator measured; demo4
stays a `DIAR_K` hint case. Claimed-voiceprint count now feeds auto-K as a
lower bound in live reclusters (product safety net, no estimator change).

## Hybrid collapse-rescue decode (2026-06-11, quark 품질 후보 발굴)
quark atoms: `metal_kernel__ts_rules_indirect`, `fn__tokenCollapse`,
`fn__main` (seek loop). 교차 대조 트리: `whisper_cpp/quality/large-v3-turbo`
(신규 config, src/whisper.cpp 호스트 품질 로직 taxonomy).
| # | idea | result | metric |
|---|------|--------|--------|
| Q-1 | temperature fallback 사다리 (wcpp entropy/logprob) | ❌ 불필요 | wcpp greedy -nf 도 clova 붕괴 청크를 완벽 전사 — 구원자는 fallback이 아님 |
| Q-2 | **ts-토큰 디코딩이 루프 붕괴의 결정 변수** | ✅ 증명 | wcpp -nt 가 우리와 동일한 "Q. Q. Q." 붕괴 재현 (엔진 독립) |
| Q-3 | EOT 게이트 (유성 잔여 시 EOT 금지) | ❌ 역검증 | 모델이 junk 텍스트로 채움 (wife ". . . ~~") |
| Q-4 | 재인코드 없는 seek (forced initial ts ± startofprev 프롬프트) | ❌ 역검증 | 분포 밖 — 윈도 시작부 재전사 (jfk "and so," 중복) |
| Q-5 | 순수 ts-모드 상시 적용 | ❌ data | 코드스위치 음차("아키텍츄럴", wcpp도 동일) + 다른 11/99 청크 꼬리 붕괴 ("네."×22) |
| Q-6 | **하이브리드: plain 기본 + 토큰 주기성 감지 시 ts+재인코드 seek 재디코드** | ✅ commit | clova 5/99→0/99 (정확히 그 5청크만 구조), 픽스처 PASS, 클린 자산 텍스트 bit-identical, tok/s 495-511(=기준), 오발동 0 |

## Speech-validation study (2026-06-11, 후속: VAD 거짓 경보)
재현: tucrg(26s 중 발화 4.5s) DER 919%, pqmho(138s 중 14.9s) 149% — 거짓
경보가 채점 발화의 수 배. diar VAD가 상대 임계(>0.4×median)라 음악/잡음만
있어도 절반가량 통과.
| # | idea | result | metric |
|---|------|--------|--------|
| SV-1 | 절대 RMS 하한 | ❌ data | pqmho 음악 RMS p25=0.154 > wife 실발화 med 0.052 > ES2004a far-field med 0.0067 — 에너지로 음악/발화 분리 불가 |
| SV-2 | no_speech_prob (모델측, OpenAI 공식) | ❌ data | **large-v3-turbo에서 <|nospeech|>는 죽어있음**: 순수 음악(pqmho)과 실발화(jfk) 모두 P≈1e-11~1e-10. 디지털 침묵 한정이 아니라 전면적 (증류 캘리브레이션 소실 추정). SOT 프로브는 lang-detect와 공용으로 유지 |
| SV-3 | 단어 스팬 게이팅 (Whisper 자체 = VAD) | 🔬 측정 중 | tucrg 전사가 정확히 희소 발화만 검출 — RTTM을 단어 스팬 합집합으로 게이트 |
| SV-3 | 단어 스팬 게이팅 (Whisper=VAD) | ❌ 역검증 | 양방향 실패: 음악 위 환각 단어가 DTW로 퍼져 마스크 미축소(tucrg 25s/26s), 회의 중첩 발화 잘림(ES2004a 31.9→47.8% 역회귀) |
| SV-4 | 임베딩 발화-방향 분리 (ResNet 코사인) | ❌ data | tucrg 진짜 발화가 음악보다 낮음 (-0.04 vs +0.03) — far-field 전이 실패 |
| SV-5 | 2-8Hz 음절 변조 비율 | ❌ data | 보컬 음악이 음절 대역 변조 보유 (pqmho 음악 0.582 ≈ 발화 0.578) |
| SV-6 | **Silero-VAD v6 소버린 포팅** (vad_silero.zig, wcpp ggml 가중치 + CLI 교차검증 ±1프레임) | ✅ commit | 윈도 게이트(crms 0화) + 청크 스킵 + RTTM 서브윈도 클리핑. tucrg 919→230%, pqmho 149→78%, **ES2004a 31.85→26.44%(-5.4pt)**, demo4 24.18→24.67, 픽스처 PASS, clova 99/99 + rescue 5 정상. diar 스레드풀과 병행 실행으로 벽시계 비용 ~0 |

## K=3 / 7+ 버킷 돌파 (2026-06-11, 진단 주도)
md-eval 성분 분해(/tmp/dg 하네스)로 두 버킷의 실패 모드 분리:
| # | 발견/아이디어 | 결과 | 근거 |
|---|------|--------|--------|
| B-1 | K=3 버킷: FA≈0인데 **miss 12-27%** — Silero 커버리지는 95-99% (mevkw: floor 0.9% vs 실측 miss 23.4%) → 손실은 우리 게이팅 | ✅ 진단 | 상대 RMS 게이트가 조용한 발화 윈도를 버림 + 클리핑 pad 30ms 과소 |
| B-2 | **silero 권위화**: 윈도 keep을 {0,1} 이진화 (RMS 게이트 자연 퇴화) | ✅ commit | 12-파일 서브셋 22.7→19.5% |
| B-3 | **클리핑 pad 30→200ms, min_speech 250→60ms** (env: VAD_PAD_MS/VAD_MIN_SPEECH_MS) | ✅ commit | 서브셋 19.5→17.5% (pad 250 동률, 300 반전); ES2004a 26.44→**18.83%** + auto-K가 진실 K=4 적중(이전 5), demo4 24.18 완전 복원 |
| B-4 | 7+ 버킷: **confusion 20-41% 지배** — DIAR_MAXK=6 캡 (최악 10중 5파일이 K=6 포화) | ✅ 진단 | maxK 스윕: 7+ 서브셋 31.6→22.0(K8)→**18.0(K10)**→18.1(K12, 포화) |
| B-5 | maxK=10 부작용: **K=1 파일 악화** (hqyok 57→77%, sil이 캡까지 상승) + K=3 서브셋 +1.5pt | ⚠️ 트레이드 | 전수 벤치로 판정 (진행 중) |
| B-6 | K=2↔3 추정기 잔여: 정화된 임베딩에서 일부 자가수정(bravd 2→3), 잔여는 마진 ±0.03 양방향 한계 케이스 (paibn sil2=0.65 vs sil3=0.62; mevkw 역방향 과분할) | ❌ 보류 | 안전한 레버 없음 — 재귀분할 재기각 |
| B-7 | 벤치 인프라: 동시 full_bench 레이스로 결과 오염 사고 → **flock 단일 인스턴스 가드 + 런별 전용 rttm 디렉토리** | ✅ commit | 오염 jsonl 폐기 후 클린 재실행 |
| B-8 | **윈도-퍼-화자 K 하한** `maxK_eff=clamp(m/8,2,maxK)` + maxK 6→10 (파일 모드) | ✅ commit | 손상/수혜 파일이 m으로 완벽 분리 (K1 손상 m=14-26 vs 7+ 수혜 m≥79). 혼합 서브셋 K6 40.7/K10 35.8 → **16.65**. 전수 216: **12.37→8.67%** (med 4.13), 전 버킷 개선: K1 14.8→5.2, K2 7.2→5.0, K3 17.7→14.8, K4 9.4→8.5, K5-6 9.6→7.9, K7+ 16.9→10.2. **pyannote 3.1(≈11.2%) 추월**. ES2004a 18.83%(auto-K=4 정답), demo4 24.18, 픽스처 PASS |

## 라이브 페널티 + 중첩 발화 (2026-06-11)
새 하네스 `bench/live_der.py` (러너 동일 잡 구조 10s+3s 좌측컨텍스트, SPK/SPKFIX 채점):
| # | idea | result | metric |
|---|------|--------|--------|
| L-1 | 라이브 재측정 (현 바이너리): 스트리밍 44.65 / 저장본 37.54 vs 파일 18.83 — 갭 주범 = 파일만 받던 Silero 구간 클리핑 | ✅ 진단 | far-field 침묵이 1.5s 그리드 통짜 SPK로 FA화 |
| L-2 | **SPK/SPKFIX 소스 클리핑** (4번째 dur 필드, 러너 awk 하위호환) + 스트림에서도 g_vad_iv 누적 | ✅ commit | ES2004a 라이브: 스트리밍 44.65→**25.66%**, 저장본 37.54→**18.43%** (파일 18.83 동급). 픽스처 PASS, 파일 모드 18.83 불변 |
| O-1 | 중첩 정량화: ES2004a ref 중첩 추가화자시간 = 채점시간 14.7% = 단일라벨 miss 바닥. 우리 1화자 구간 miss는 7.2%뿐 — **miss의 본체가 중첩** | ✅ 진단 | 천장: ES2004a -13pt급 |
| O-2 | 중첩 탐지 #1: 센트로이드 모호도 cos2/cos1 | ❌ data | 재현 20%/오탐 6% (1.5s 풀링이 중첩 구조를 뭉갬) |
| O-3 | 중첩 탐지 #2: 화자 전환 인접 윈도 (±모호도 결합) | ❌ data | 최선 재현 35%/정밀 46% — 2차 화자 방출 손익분기 미달 |
| O-4 | 결론: 학습 OSD 필요 (pyannote segmentation급 포팅 = Silero급 이상 별도 프로젝트) | 📋 백로그 | 단일 라벨 구조 한계로 기록 |

## 학습 OSD 포팅: pyannote segmentation-3.0 (2026-06-11)
소버린 포팅 공식 재적용: sherpa-onnx ONNX → bench/convert_pyannote_seg.py →
osd_pyannote.zig (SincNet+BiLSTM×4+파워셋7), onnxruntime 심판 검증
max|Δlogp|=3.5e-5, argmax 불일치 0/589. Accelerate sgemm/sgemv로 413→90ms/10s.
| # | idea | result | metric |
|---|------|--------|--------|
| P-1 | 파워셋 argmax 중첩 검출 + 턴테이킹 prior 2차 화자 | ✅ 1차 | ES2004a 18.83→17.16% (miss 16.0→12.7) |
| P-2 | 확률 임계(P(ov)≥θ) 검출 | ✅ 미세 | θ 스윕 포화 ~17.1 |
| P-3 | 5s 슬라이딩+프레임 평균 집계 (pyannote식) | ❌ 무익 | 17.05 vs 17.12 — 디스조인트로 회귀 |
| P-4 | **로컬 트랙 정체성**: 파워셋 페어 + 로컬 솔로 프레임의 전역 투표 | ✅ commit | ES2004a **16.47%** (θ=0.25 포화; miss 12.5/fa 1.8/conf 2.2) |
| P-5 | OSD 행의 silero 클리핑 우회 → tucrg 232→462% 사고 | ✅ 수정 | emitOverlapRow가 g_vad_iv 교차로만 방출 + prim≥0 가드 (1차 화자 위에만 2차) |
| P-6 | 군중 가드 (중첩 런 ≥3s 차단) | ❌ 역검증 | tucrg 불변(런이 원래 짧음), ES만 16.49→16.92 손상 — 롤백 |
| P-7 | tucrg 잔차 (229.7→356%) | 📋 수용 | 군중 함성 = 진짜 다성인데 ref 미라벨 — 알려진 병리 파일 |

## Metal-4 tensor-ops 인코더 — Phase 1 (2026-06-11)
quark atoms: `metal_kernel__m4_gemm_nn`, `metal_kernel__m4_gemm_bias`,
`metal_kernel__m4_gemm_bias_gelu`, `fn__forward`(encoder dual-path).
toolchain: Xcode 26.5, -std=metal4.0 (m4_*.metal만), MPP tensor_ops.
| # | idea | result | metric |
|---|------|--------|--------|
| M4-1 | 셰이더 내 raw 포인터 tensor 뷰 (런타임 MTLTensor 불필요) | ✅ 검증 | **비-const 필수** (mpp 헤더에 const 오버로드 없음 — "Unsupported type" 정적 단언의 정체) |
| M4-2 | 순수 tensor-ops GEMM vs MPS (fc1 형상 1500×5120×1280, 64×64타일/4SG/동적K) | ✅ data | **3.64ms vs 3.83ms (1.05×)**, max|Δ|=0 — 미튜닝으로 MPS 동급+ |
| M4-3 | mode::multiply가 기본(덮어쓰기) — zero-init 패스 불필요 | ✅ 확인 | descriptor 7번째 인자 |
| M4-4 | **융합 에필로그**: GEMM+bias, GEMM+bias+erf-GELU (타일 cache-hot 상태서 적용; bias_add_f16/gelu_f16 전체 패스 제거) | ✅ commit | run()은 lvalue 슬라이스 요구 |
| M4-5 | 인코더 6 GEMM 전부 교체 (ENC_M4=0 = MPS 폴백 이중 경로) | ✅ commit | **배치4 569→511ms(-10.1%), 배치1 647→588ms**; jfk 단어·스팬 바이트 동일; wcpp 571ms 최초 추월 |
| M4-roadmap | Phase 2: Q8 직행 GEMM (half×int8 네이티브 — dequant 77ms+가중치 트래픽 ½ 제거, k-loop+coop tensor로 블록 스케일), Phase 3: flash_attention_enc tensor-ops 재작성 (160ms), int4 경로 (모델 Q4 시) | 📋 | 지원표: half×int8→half/float, int4b_format까지 1급 |
| M4-6 | **Q8 직행 GEMM (Phase 2)** — A: 32-K coop 스케일 패스, B: TG 타일 dequant(tilek 128/256) | ❌ 기각 (M4급) | A 0.57× / B(128) 0.84× / B(256) 0.56× vs dequant+f16GEMM 4.3ms. 원인: 열당 24 TG가 동일 가중치 타일 중복 dequant — legacy의 레이어 단위 1회 dequant+SLC 상주 왕복이 사실상 최적. 정확성은 검증(max|Δ|=0.0005). **M5 GPU neural accelerator(네이티브 int8 matmul)에서 뒤집힐 후보** — 커널·하네스 보존 |
| W-1 | **WER 표준 벤치 — 절대 ASR 품질 (최종)** (resident STREAM 잡피드 + 공식 Whisper 정규화기 + jiwer, 영구 bench/wer_runs/) | ✅ **확정** | **test-clean WER 2.17%** (2620발화/53k단어), **test-other WER 4.19%** (2939발화/52.9k단어), **FLEURS-ko CER 3.99% / WER(공백토큰) 13.32%** (382발화, 빈hyp 0). 공표 large-v3(clean 2.0 / other 3.9) 사실상 동급 — **Q8 양자화 + 자체 Metal 파이프라인이 레퍼런스급 절대 품질**임을 입증. 한국어 CER 3.99%는 강력(read-speech). 게이트-프리(VAD_THRESH=0)+피크정규화(-1dBFS) 측정 |
| W-2 | **발화 게이트의 절대 진폭 민감성** — FLEURS-ko(피크 −33 dBFS)에서 222/382 청크 무음 스킵 (에너지 게이트 + silero 둘 다 저게인서 침묵) | ✅ 진단 | 제품 함의: 저게인 마이크면 제품 전체 침묵 가능. +20dB 부스트 → 완벽 전사로 진폭 원인 확정 |
| W-2b | **AGC 구현 + 자기수정** (transcribe.zig) — 1차: 게이트 전용(인코더 불변) → **CER 5.54%/5빈값으로 역검증 실패**. 진단: 빈값 5파일 peak 0.11~0.23(중간게인)인데도 빈전사 = **인코더도 저게인서 실패** (앞선 3.99%는 외부 부스트값이었지 raw 아님 — 전제 정정). 2차: peak<0.30일 때만 타깃 0.9(−1dBFS)로 **in-place 정규화(게이트+인코더 동시)**, 정상(peak≥0.30) 불변. AGC=0 롤백 | ✅ commit | **제품경로 FLEURS-ko 0빈값 CER 4.05%**(외부정규화 3.99%와 동일, 핵 없이). 회귀: jfk **바이트동일**, ES2004a DER **16.49→15.57 개선**(조용한 발화 4개 복구, 무음청크 40× 부스트해도 게이트가 헛전사 차단). devops 타임스탬프 흔들림은 AGC 무관(AGC=0 2회도 다름=기존 비결정성, 백로그). 벤치는 제품경로로 단순화(게이트우회·외부정규화 제거) |
| CONF-2 | **신뢰도 메트릭 A/B + 임계 정밀화** — prob vs margin(top1−top2) vs entropy, FLEURS 정답 단어별 align(jiwer) precision/recall | ✅ data·결정 | 동기: Speaker0(명료)에서도 과다플래그. **세 메트릭 측정상 등가**(최고 F1≈0.41, precision 0.33-0.44, 하위15% 플래그) — 단일-forward 신뢰도는 **확신하며 틀린 오류를 못 잡는** 본질 한계. margin/entropy 가설 반증. 결정: **prob 유지(margin/entropy 디코드비용만↑ → 커널 prob-only 복원, 토큰 바이트동일), 임계 0.65→0.55**(플래그 ~20%→~7%, precision 0.44→0.50, 과다플래그 완화). 포지셔닝: 약한 검토 힌트. conf_eval.py 보존. 별건: 솔로 화자 과분할(Speaker 0/1/2) 백로그 |
| CONF-1 | **단어별 신뢰도 (기능+품질 Super Win)** (quark atom: `metal_kernel__argmax_conf`) — argmax에 logsumexp pass 추가 → 토큰 softmax 확률, 단어=토큰 min | ✅ commit·바이트동일·**Super Win 검증** | 토큰 경로 바이트동일(같은 argmax). 거의 공짜(logits 207KB 재읽기 vs gemv 66MB). **검증: 저신뢰가 실오류와 상관** — FLEURS "섹스는"0.36(정답 색스/Sacks), "빛공예가"0.54(정답 빛공해), 외래지명 비슈케크0.38·가지안테프0.45 정당불확실; 정답단어 0.94-1.00로 명확분리. 장식 아닌 품질신호. CONF=1 덤프(기본 출력 불변). 다음: 러너/앱 색상·밑줄 렌더 |
| FUSE-2 | **디코드 융합 #2: qkv gemv+bias×2+store×2 → 1** (quark atom: `metal_kernel__gemv_q8_qkv`) + **가설 반증** | ✅ commit·바이트동일 | self-attn qkv를 단일커널로(q=acc+qb, k=acc→캐시, v=acc+vb→캐시). FUSE-1+2 누적 **24런치/토큰 제거(80→56)**. **jfk 원본 바이트동일**. 깨끗한 A/B(같은 머신): gpu-sync 281→268ms = **~4.6% 디코드 가속**. **핵심 발견: 24런치 제거가 4.6%뿐 → 런치 레이턴시 ~95%는 GPU 파이프라이닝으로 이미 숨겨져 있었다.** "launch-bound→1.85×" 가설 반증 — 디코드는 **GEMV/어텐션 대역폭-bound**. tiny-커널 융합은 체감↓. 진짜 디코드 레버는 GEMV 대역폭(in-memory sub-Q8=int4, 제로리스크로 보류) |
| FUSE-1 | **디코드 융합 #1: MLP gelu/residual을 gemv 에필로그로** (quark atom: `metal_kernel__gemv_q8_bias_gelu`/`_res`) — decode dispatch-bound 근본 표적 | ✅ commit·바이트동일 | 측정 선행: DBATCH 8vs1 동일(276/268ms)=**CPU sync 아닌 GPU 런치레이턴시** 병목, 토큰당 ~80 tiny 커널. 단일-threadgroup persistent는 기각(한 코어가 273GB/s 못채움 ~3.6× 느림 + Metal grid-barrier 없음) → 정답은 **풀-그리드 유지 융합**. 1라운드: kGelu+kRes 폴딩 → 레이어당 2커널↓ × 4 = **8런치/토큰↓**. **jfk baseline 바이트동일**(결정적 경로, gelu 공식 정확복제+residual 동일산술). 속도는 단일융합(8/80=6.5%)이 노이즈 이내 → 집계는 풀셋(80→~25) 후 조용한 머신서. 다음: bias×2+store×2 폴딩 |
| BC-1 | **flash_cross_attn_f16kv 뱅크충돌 (quark `_axon/bank_conflict_suspect/...s_part`)** — 21% 디코더 커널 표적 | ❌ false-positive (분석 역검증) | s_part 읽기 `[od]+[64+od]+[128+od]+[192+od]`에서 64/128/192=32배수 → simdgroup이 뱅크 0-31 정확매핑, **충돌 구조적 불가**. 게다가 s_part 1KB = 커널 30MB/token(cross-KV 재읽기) 트래픽의 0.003%. 실측 A/B는 디코드 ±40% 머신노이즈로 불가 → 분석 판정. **커널 21%는 뱅크충돌 아닌 KV 대역폭(어텐션 본질)**. quark suspect는 "32정렬 파티션 리덕션" 흔한 오탐 패턴. 코드변경 없음(non-conflict 수정은 churn). 진짜 디코드 레버는 dispatch 융합(P0 dispatch-bound) |
| INT4-2 | **Q8 파일 출하 (제로리스크 다운로드 1.86×)** — quantize_q8.py가 F16 safetensors→Q8(233 큰행렬을 K.qs/K.scales, 나머지 F16 복사), 엔진 로더가 K.qs 존재 시 직접 로드(readQ8, 4 로더 분기) | ✅ commit·**비트동일 증명** | 1618MB→867MB. **무위험 증명(가중치 레벨)**: WHASH 해시(tok_emb+dec qkv+dec ow+enc o_w+enc qkv, 4 로더 전부) F16==Q8파일 일치 . 전사 바이트동일은 불가(엔진 GPU FP가 모델무관 run-to-run 비결정 — F16 2회도 단어 흔들림 실측) → 증명은 가중치로. jfk 파일모드 전사도 동일. Python 양자화가 Zig quantInto와 바이트일치(round-away+f16스케일) |
| INT4-1 | **양자화 비트폭 품질 곡선** — q4r 프로브(Q8 양자화 직전 N-bit 라운드, 디폴트 off=무위험), WER 하네스로 측정 | ✅ data | **test-other 300-subset, 같은 발화, 검증 바이너리(md5 distinct)**: Q8 6.19% / Q6 6.21%(+0.02) / Q5 6.45%(+0.26) / Q4 6.51%(+0.32). test-clean·FLEURS-ko는 전 비트폭 ~0. 무릎=Q6. 다운로드(근사): Q8 1.9× / Q6 2.4× / Q4 3.5×. **교훈: 빌드 u5/u6 시프트 에러를 `rg error\|head` 필터가 먹어 구 바이너리로 Q5/Q6를 측정(전부 Q4) → md5동일 적신호로 적발. 이후 "✅ Built+mtime 갱신" 확인 규칙.** 출하 결정: **Q8(제로리스크 — 엔진이 이미 Q8 in-memory, 품질변화 0 + 다운로드 1.9×)** |
| T-1 | **라이브 번역 (Whisper translate 토큰)** — SEED 태스크 토큰 transcribe(50360)↔translate(50359) 런타임 분기(TRANSLATE=1), 파일/스트림/seek 전 경로 | ✅ 배선 / ❌ turbo 불가 | 토큰 배선 정확·무해(기본 transcribe 회귀 클린). **그러나 large-v3-turbo는 번역 못 함** — 지피지기: wcpp turbo `--translate`도 KO 입력에 KO 출력(동일). OpenAI가 turbo 파인튜닝서 번역 데이터 제외(공표). 배선은 번역가능 모델(full v3 / 텍스트 MT) 물리면 즉시 작동 — **미래 대비 보존**. 번역 기능은 보류 |
| W-3 | **엔진 wav 파서 강건화** (mel.zig wavFmt/loadWavChunk + transcribe.zig 가드) | ✅ commit | **float32(tag 3/0xFFFE, 32bit) 네이티브 지원** — FLEURS 원본 무변환 전사 확인. 빈/미지원 파일은 **segfault→명시 스킵**("empty or truncated"/"unsupported WAV format", stream은 빈 SEG_END 후 continue). 회귀: jfk PCM16 경로 산술 불변, devops 멀티청크 정상. 4케이스(PCM16/빈/float32/8bit) 검증 |
| M4-7 | **flash attention tensor-ops 재작성 (Phase 3)** — 64-q 타일(기존 32), strided device tensor 뷰로 Q/K/V 제자리 소비(TG 스테이징 0), QK^T/P·V matmul2d + coop 누산, S는 coop→TG f32 | ✅ commit | 격리 5.19→**3.84ms (1.25×)**, max|Δ|=6e-5 bad=0; 인코더 배치4 494→**462ms (flash 단독 -32ms)**, 배치1 570→545ms; MPS 대비 전체 M4 스택 548→462 = **-15.7%**; devops_ko/jfk 전사·단어 바이트 동일, KO+EN 픽스처 PASS. ENC_M4F=0 = flash 단독 롤백 |
| M4-8 | 진단: 1-thread/row 소프트맥스가 병목 (스테이지 프로브: QK만 1.65ms / +scatter 1.80 / +softmax 4.61 / full 6.35) | ✅ data | 2-thread/row + float4 벡터화로 6.31→3.84ms. 교훈: tensor-ops 도입 시 matmul 바닥(1.65×2)이 빨라져 비-matmul 직렬 구간이 즉시 지배 |
| M4-9 | strided tensor 생성자 발견: tensor(ptr, dextents, array<int,2>{1, row_stride}) — mpp matmul2d와 호환 | ✅ 검증 | TG 복사 불필요 → TG 25KB로 한도(32KB) 통과; 단 64-타일 꼬리가 seq 너머를 읽으므로 버퍼 +64행 패딩 필수 (qkv 스크래치) |
| L-3 | **라이브 경로 OSD** (스트림 기본 ON, FLUSH에서 SPKOV 행 — relabel 윈도 기반 로컬트랙 정체성 + silero 클리핑) + 러너 끼어들기 마커 "⟨+Speaker N 겹침⟩" | ✅ commit | ES2004a 라이브 저장본 18.43→**17.41%** (116 겹침 행); 지연 +26ms/세그먼트(+2.4%, 2분 리플레이 A/B); ES 2분 양성대조 .md 마커 2건 확인; wife(무중첩) 마커 0 ✓; 픽스처 PASS |
