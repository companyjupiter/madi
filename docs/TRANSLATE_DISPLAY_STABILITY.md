# 번역 표시 안정성 — 정책 + 근거 (2026-08-05)

사용자 관찰: "번역이 계속 적히고 교정된다 — 상용(Transync AI 등)보다 복잡해 보인다."
검증/역검증(quark 토폴로지 + 코드 전수조사 + 4-way 리서치) 결론과, 그에 따라 구현된
표시 정책의 정본 문서. PERF_LOG.md 2026-08-05 배치가 구현 원장.

## 판정

- **교정 '판단'(가드 체인: 에코/금지스크립트/루프붕괴/리페어)은 정당** — 2B 품질
  게이트(docs/LIVE_TRANSLATE.md)로 필수. 문제는 교정이 화면에 드러나는 **표시 정책**.
- 수리 전 캡션은 문장 하나당 번역 텍스트 상태 20~45회(상수 기반 도출) — 문헌의
  vanilla re-translation(NE≈2.1) 구간. 패널은 7~9회(리비전 시 ~30회).
- **직독직해(청크 모노토닉)는 기각(보류)**: KO→EN은 동사후치 소스라 구조 불리
  (Grissom 2014, STACL — 동사 예측 필요, 3~7 BLEU 손실 + 반복/유예 스타일 비용),
  DNA3에 target-prefix 강제 디코드 없음(stateless 단일턴). 문헌 정본이 "재번역 유지
  + 표시 안정화"가 같은 지연에서 wait-k류보다 품질 우위임을 확립 — 즉 직독직해가
  풀려던 문제는 표시 정책으로 품질 무손실 해결. EN→KO 한정 장기 옵션만.

## 지표 — NE (normalized erasure)

한 업데이트의 erasure `E = |old| − |LCP(old, new)|` (자소 단위), 세션 `NE = ΣE ÷
최종 커밋 번역 자수`. **목표 밴드 NE < 0.2** (업계 low-revision 컨센서스; Google
Translate는 masking+biasing으로 2.1→0.1, BLEU 무손실). `TranslationStability.swift`
의 meter가 caption/panel 두 표면을 계측, finalize+10s에 `[translate-stability]`
한 줄 요약 출력. 회귀는 이 로그 라인의 diff다.

## 표시 정책 (구현 원장)

| 층 | 정책 | 구현 |
|---|---|---|
| 캡션 인터림 | **stable-prefix**: 성장 통과 · 꼬리 ≤12자 즉시 수용 · 깊은 재작성/축소는 2연속 일치 시 수용(LocalAgreement류) · 윈도 경계 리셋 | `StablePrefixFilter`, SessionController 캡션 write 경로 2곳 |
| 캡션 페어링 | 번역은 그것을 생성한 가설(`livePartialSource`)과만 페어 · 커밋 갭엔 페어 유지(역행 점프 금지) · 진짜 번역 도착 시 해체 | CaptionOverlay `caption` 폴백 체인 |
| 캡션 턴 게이트 | 이미터 플랩/축소 skip · 순수 꼬리 성장 ≥6자만 DNA 턴 | `InterimTranslateGate` |
| **인터림 소스 (P8)** | **LocalAgreement-2**: 연속 2회 디코드가 합의한 단어 접두만 번역기로 · 표면형은 커밋 시 고정(append-only) · stall 3회면 최신 꼬리 강제 커밋(이미터 플랩 기아 방지) | `InterimSourceGate`, `livePartial` didSet |
| 패널 | **stale-in-place**: 리비전 무효화는 삭제가 아니라 회색·이탤릭 강등 → 재번역 도착 시 제자리 교체 · 라우팅 탈락만 삭제 · dots는 valid도 stale도 없을 때만 | `Line.staleTranslations`, `refreshTranslationOverlay` |
| 가드 suppress | 기각된 최종은 스트리밍된 partial을 **롤백** + 리비전 귀속 verdict(텍스트 변경 시 해제) — 기각 텍스트가 정식 번역처럼 잔존 금지 | `suppressTranslation` |
| 불변 | `Line.translations`는 리비전-유효만 (export/캡션/블록/요약 소비자 무변경) · user-edited 번역은 롤백/강등 불가침 | — |

## 업계 대조 (리서치 근거, 2026-08-05)

- 상용 표준: **확정 블록 불변 + 진행 중 세그먼트 1개만 mutating(시각 구분) + 번역은
  세그먼트 페어링**. Transync AI(=중국 同言翻译)는 append-only·이력 불변·미확정
  꼬리 이탤릭 — "단순해 보이는" 이유는 교정을 안 해서가 아니라 안 보여줘서.
- 스트리밍+가변 진영(Zoom·Teams·DeepL Voice·Felo)에서 안정성은 경쟁 축: Slator
  프레임 측정에서 Zoom 최악, DeepL은 churn −37~55%를 마케팅. Interprefy만 문장확정
  /즉시 이중 모드를 문서화 — 강의/행사용 "문장확정 프리셋"(P7, 백로그)의 선례.
- 정본 문헌: Arivazhagan 2020 (재번역 vs 스트리밍, biased beam+mask-k → erasure
  20×↓), Yao&Haddow 2020 (dynamic masking, 엔진 불가지론), whisper_streaming
  LocalAgreement-2, CHI 2023 (flicker↔피로 상관 p<0.001, 신뢰도 게이팅은 약함).

## 실측 (2026-08-10, ko1.wav × DNA3-4B, KO→EN — 정본 수치는 PERF_LOG)

| | 표시 상태수 | **NE** |
|---|---:|---:|
| 0.1.6 (수리 전) | 10 | **2.86** |
| 0.1.7 (P1+P2) | 7 | **1.18** |
| 0.1.7 + P8 | 5 | **0.46** |

핵심 교훈: **표시층만으로는 목표 밴드에 도달할 수 없다.** 잔여 churn의 지배항은 프리뷰 재디코드가
원문의 의미를 바꾸는 것이고(`아키테이였습니다`→`아키텍처에 대해 이야기합니다`), 번역은 바뀐 원문을
충실히 따라간 것뿐이다. 그래서 정답은 상류 소스 게이팅(P8)이었다 — 단독으로 −79%, 표시층과 결합해
−84%. 반증된 대안 2건(구두점 무시 *교체* = 2.25로 악화, 프리픽스 고정+꼬리 추가 = 0.96 + 아티팩트)도
PERF_LOG에 기록.

## 남은 것

- NE<0.2까지의 잔여 갭: 남은 erasure는 STT가 의미를 바꾸는 구간(합의 후에도 후속 디코드가 뒤집는
  경우)에 몰려 있다. 다음 후보는 합의 창 확대(LocalAgreement-3) 또는 문장 경계 커밋.
- P7(백로그): 강의/행사 프리셋 = 문장확정 모드(인터림 번역 off).
- EN→KO 한정 직독직해 스타일은 엔진 target-prefix 지원이 생기면 재평가.
