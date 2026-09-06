# 디버그 모드 — 세션 번들 (2026-09-06)

## 왜

2026-09-03~06 라이브 검증에서 결함 하나를 잡는 데 세션 한 번씩이 들었다. 매번 부족했던 정보가 달랐다.

| 결함 | 세션 수 | 없어서 헤맨 정보 | 이 번들의 스트림 |
|---|---|---|---|
| 독일어 오염(P6) | 4 | 엔진이 **실제로 받은 바이트**(env·stdin·WAV). 오프라인 재생은 글로서리 PROMPT가 빠져 깨끗했다 | `env.txt` `stdin.log` `wav/` `stdout.log` |
| 프리뷰 레인 죽음(P5) | 2 | 프리뷰 작업 수 | `stdin.log`(PREVIEW 줄), `session.json` |
| 메모리 누수(M2·M3) | 3 | 프로세스별 RSS/footprint 시계열 | `mem.jsonl` |
| 줄 파편화(L1) | 2 | **경계 판정 이유**(화자 잠정값·간격·문장부호·상한·원장 재생) | `store.jsonl` boundary/join/ledger-flip |
| 접합부 중복(L2) | 2 | 병합기의 창별 결정(held·교체·제거 규칙) | `store.jsonl` merge |
| 번역 폭주·에코 절단(T7·T8) | 2 | 턴별 **프롬프트(예시 쌍)·원응답·정제 규칙**·상한·큐 깊이 | `translate.jsonl` |
| 엔진 재시작(W2) | 1 | 그 순간의 세그먼트 큐·마지막 활동 | `watchdog.jsonl` |
| 화자 번호 상승 | 3 | SPK/SPKFIX 흐름 + 앱의 번호 배정·합침 | `stdout.log` + `store.jsonl` |

## 무엇을 남기나

`~/Library/Application Support/Madi/debug/<yyyyMMdd-HHmmss>/` (세션당 1개, 설정 "디버그 캡처" ON 또는 `MADI_DEBUG=1`)

| 파일 | 내용 | 쓰는 곳 |
|---|---|---|
| `session.json` | 앱 버전·빌드, 칩·RAM·macOS, 설정(번역 대상·글로서리 수·화자 수·diar·프리뷰), 엔진 경로·모델, 시작/종료 시각, 종료 시 `@final` 태그 | SessionController |
| `env.txt` | transcribe 엔진에 넘긴 환경변수 전부 | EngineProcess |
| `stdin.log` | 엔진에 쓴 모든 줄: `<초>\t<wav 스냅샷명>\t<줄>` (tee 심과 동일 포맷) | EngineProcess |
| `wav/` | 투입 시점의 WAV 스냅샷(프리뷰 슬롯은 회전하므로 그 순간 복사). 총 400 MB 초과 시 프리뷰 스냅샷만 중단 | EngineProcess |
| `stdout.log` | 엔진 stdout 바이트 그대로 | EngineProcess |
| `engine.events.jsonl` | 엔진 EVENTS_FILE(단어·seg·partial) 사본 — 종료 시 삭제 대신 이동 | EngineProcess |
| `store.jsonl` | `boundary`(첫 인접 판정: cont, 이유 필드), `join`, `ledger-flip`, `spkfix`, `merge`(창별 held/교체/제거 수), `finalize` | TranscriptStore·WordMerger |
| `translate.jsonl` | `turn`(id·lang·kind·source·example·cap·큐 깊이), `result`(raw·clean·echo_stripped·runaway·retry·ms), `discard` | TranslateEngine |
| `watchdog.jsonl` | W1 누락 의심, W2 재시작(큐 깊이·마지막 활동 경과), 엔진 종료 코드 | SessionController |
| `mem.jsonl` | 10 s마다 앱(footprint·RSS)·transcribe·translate RSS, CPU% | SessionController |
| `stability.log` 사본 줄 | `[translate-stability] … @final …` | SessionController |

모든 JSONL 줄은 `{"t": <세션 초>, "w": <ISO 벽시계>, "ev": …}`.

## 어떻게 쓰나 (한 번에 고치기)

1. **엔진 결함 의심**(오염·언어·rescue·diar): `python3 engine/metal/bench/live_capture/replay_capture.py <bundle>` — 번들이 tee 캡처와 같은 파일명(`env.txt`/`stdin.log`/`wav/`/`stdout.log`)이라 그대로 재생·비교된다. `--env K=V`로 한 변수씩 끄며 이분 탐색.
2. **앱 구조 결함**(줄·중복·화자 번호): `MADI_CAPTURE_STDOUT=<bundle>/stdout.log swift test --filter CaptureFragmentationGateTests` — 앱이 받은 스트림을 그대로 스토어에 재생. `store.jsonl`로 라이브에서 실제 내린 판정과 대조.
3. **번역 결함**: `translate.jsonl`의 `turn`을 t1_harness에 그대로 넣어 재현(예시 쌍·상한 포함).
4. **성능/메모리**: `mem.jsonl` 추세, `watchdog.jsonl`.

## 비용·주의

- 꺼져 있으면 `DebugLog.shared == nil` 검사 한 번(무비용). 켜면 디스크 I/O만(직렬 큐, 메인 스레드 아님).
- 번들에는 **세션 오디오와 전사·번역 전문**이 들어간다. 로컬 전용, 자동 삭제 없음 — 설정 화면에 폴더 열기 버튼과 용량 표시.
- 프리뷰 WAV는 크다(10 s×2,000/47분 ≈ 600 MB). 400 MB 상한 뒤엔 프리뷰 스냅샷만 건너뛰고 `stdin.log`에 `COPYSKIP` 표기.
