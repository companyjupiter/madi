# 화자 과분할 수정 설계 (P4-3 후속)

2026-09-03. 라이브 0.3.6(유튜브 한국어 1인 진행, 40분)에서 화자가 10명까지 늘고 거의 모든 줄이
"화자분리중…"으로 남은 현상의 설계. 실측·반증은 `PERF_LOG.md` P4 절, 파급 차단(번역 run)은 이미
`TranslationCoalescer`에 반영됨(커밋 b837ee4).

---

## 0. 무엇이 측정됐나

| 케이스 | 참조 | 오프라인 `auto` | 라이브 `live_stream` | overcount peak | churn/min |
|---|---:|---|---|---:|---:|
| xypdm (1인, 417 s — 관측과 같은 형태) | 1 | **1명 / DER 6.24** | **5명** / DER 6.49 | 3 | 5.69 |
| ufpel (10인, 401 s — 위험 케이스) | 10 | 6명 / 10.92 | 9명 / 11.29 | −2 | 7.93 |
| ko4 | 4 | 1명 / 2.51 | 1명 / 6.47 | −3 | 0 |

`bench/diar_panel_eval.py --audio … --ref … --id … --mode auto --live`.

**핵심**: 같은 오디오에서 오프라인 auto-K는 1명을 정확히 맞춘다. 즉 임베딩도 클러스터링 알고리즘도
멀쩡하고, **틀리는 것은 라이브 경로뿐**이다. 그래서 임베딩 창·VAD·모델을 건드리는 방향은 시작점이 아니다.

반증된 레버 두 개(다시 시도하지 말 것):
- **recluster id 발행 상한**(`transcribe.zig:948`의 리터럴 32 → `max_k`): 계약은 지키지만
  (ufpel 9→8명) xypdm은 5명 그대로. 참조 화자가 상한을 넘는 파일에서 relabel DER +0.64 pt.
  패치 보관 `bench/runs/p4/d1_recluster_cap.patch`.
- **`DIAR_SIM` 하향**(0.40 → 0.35/0.30): xypdm 5→4명(DER −0.15)인 대신 ufpel DER 11.29 → 11.85/12.67.
  상수 하나로는 두 케이스를 동시에 만족시킬 수 없다.

---

## 1. 구조 — 화자 수를 세 층이 따로 정한다

| 층 | 코드 | 결정 방식 | 판정 |
|---|---|---|---|
| ① 온라인 출생 | `diarAssign` `transcribe.zig:722-800` | 기존 centroid와 코사인 `best < DIAR_SIM(0.40)`인 창 **하나**로 즉시 새 centroid 출생 (`:771-786`) | **유령 생산자** |
| ② 주기적 재클러스터 | `liveRecluster` `:811-955`, 가속 창 16개(≈발화 24초)마다 | 전체 임베딩에 k-means + silhouette auto-K. `sil < DIAR_SIL_TAU(0.35)`(`:863`) 또는 centroid 최대 코사인거리 `< DIAR_MIN_SEP(0.50)`(`:866`)이면 **K=1로 접음** | **정상 동작** |
| ③ 표시·라벨링 | livefix `:2058-2140` | ②가 살린 active centroid로 과거 창을 재배정하고 `SPKFIX` 방출. 단 `active < 3`이면 **`count ≥ 3`인 모든 centroid로 되펼침** (`:2094-2097`) | **유령 소생자** |

②가 "이건 1명"이라고 판정해도 ③이 그 판정을 버리고 유령 centroid를 다시 라벨 후보로 세운다.
이것이 오프라인 1명 / 라이브 5명의 정확한 간극이다.

**이미 있는 자산**: `DiarConfirmState`(`:645-650`) + `liveVisibleSpeaker`(`:658-718`)가 신생 화자를
`DIAR_CONFIRM_WIN`(2)개의 독립 창까지 **표시에서만** 격리한다(`DIAR_CONFIRM_MIN_ADV_SEC=1.5`로
좌측 문맥 중복을 독립 근거에서 제외). 그런데 격리된 centroid는 여전히
① `diarAssign`의 최적 스캔(`:731-739`)에 참여해 진짜 화자의 창을 빼앗고,
③ livefix broad 목록에 `count ≥ 3`이면 들어간다.
**즉 격리가 "보이지 않게"까지만 가고 "관여하지 못하게"까지 가지 않는다.** 세 후보는 모두 이 간극을 메운다.

**margin이 안 풀리는 이유도 같다**: 같은 목소리를 가리키는 centroid가 여러 개면 best와 second가
붙어 margin ≈ 0 → `SpeakerID.isDeciding`의 `settledMargin`(0.35)을 영원히 못 넘음 →
전 줄 "화자분리중…". 관측된 라벨 자체가 centroid 중복의 증거다.

---

## 후보 A — 잠정 centroid를 **배정**에서도 격리 (1순위)

### 변경
`diarAssign`(`transcribe.zig:722`)에 `confirmed: []const bool`를 넘기고, 최적 스캔을 2단으로 나눈다.

1. **확정** centroid만으로 `best_c` 계산.
2. `best_c ≥ eff_thr` → 확정 centroid에 배정. **끝.** (잠정 centroid는 확정을 이길 수 없다.)
3. 아니면 전체(잠정 포함)로 `best_a` 계산. `best_a ≥ sim_thr`면 그 잠정 centroid에 배정 — 이때만
   잠정이 근거를 쌓는다.
4. 둘 다 미달이면 기존대로 출생(`:771-786`).

`margin`은 지금처럼 `best − second`로 계산하되 **확정 집합 안에서** 계산한다(잠정과의 근접이
margin을 깎아 "화자분리중"을 고착시키는 경로를 끊는다).

호출부는 `:1932`. `live_confirm`(`:1934-1942`)이 이미 centroid별 확정 상태를 들고 있으므로
`confirmed` 슬라이스는 그대로 파생된다.

### 사망 규칙 (같이 들어가야 함)
잠정 centroid가 `DIAR_PROV_TTL_WIN`(기본 64창) 안에 `DIAR_CONFIRM_WIN`에 도달하지 못하면 폐기한다.
폐기 = `cents`에서 제거하지 않고(인덱스가 stable id라 흔들 수 없다) `count = 0`으로 비우고
`confirmed = false` 유지 → 스캔에서 영구 제외. 그 창들은 이미 fallback id로 보여지고 있었으므로
사용자 화면은 변하지 않는다.

### 불변식
> 잠정 centroid는 **확정된 어떤 화자도 받아들이지 않을 창만** 받는다.

이것이 "독립 근거"의 조작적 정의다. 진행자 목소리가 조명·톤·웃음으로 흔들려 유령이 태어나도,
이후 창이 여전히 주 centroid에 0.40 이상이면 주 centroid로 가므로 유령은 굶어 죽는다.
진짜 다른 목소리만 계속 확정 집합에서 탈락하며 유령을 먹여 살린다.

### 위험과 완화
주 화자와 음향적으로 가까운(≥0.40) 진짜 2번 화자가 온라인에서 영구 흡수될 수 있다
(`QUALITY_BENCH`의 demo4 K=2/51.5% 실패 모드). **완화는 이미 존재한다**: ②
`liveRecluster`는 원본 임베딩에 k-means를 돌리며 온라인 배정을 참조하지 않으므로,
흡수된 2번 화자는 다음 재클러스터(≈24초)에서 다시 갈라지고 `SPKFIX`로 소급 교정된다.
즉 후보 A의 최악 비용은 **첫 24초의 라벨 지연**이지 영구 오류가 아니다.

### 계측
```bash
cd engine/metal
for c in xypdm ufpel; do
  python3 bench/diar_panel_eval.py --audio "$MADI_BENCH_SAMPLES/audio/$c.wav" \
    --ref "$MADI_BENCH_SAMPLES/voxconverse/dev/$c.rttm" \
    --id $c --mode auto --live --out-dir bench/runs/provA_$c
done
python3 bench/diar_panel_eval.py --audio bench/ko4.wav --ref bench/ko4.ref.rttm --id ko4 \
  --mode auto --live --out-dir bench/runs/provA_ko4
python3 bench/live_ux_gate.py bench/runs/p4/p4base_xypdm bench/runs/provA_xypdm --require-win
```

합격 기준
- xypdm `engine_speakers` 5 → **≤2**, `speaker_overcount_peak` 3 → **≤1**, `label_churn_per_min` 5.69 → 하락, DER 6.49 대비 **+0.3 pt 이내**.
- ufpel DER 11.29 대비 **+0.5 pt 이내**, `engine_speakers` ≥7 유지.
- ko4 DER 6.47 **불변**.
- 첫 라벨 지연 `first_label_latency_p90_sec`(현재 11.5 s) **+5 s 이내**.

셋 중 하나라도 어기면 후보 A 기각하고 후보 B로 간다.

---

## 후보 B — auto-K가 **의도적으로** 접었을 때 broad 폴백 금지 (2순위, 위험 최대)

### 변경
`liveRecluster`에 out-param `collapse: *CollapseReason`(`.none` / `.silhouette` / `.min_sep`)를 추가하고
(`:863`, `:866`에서 세팅), livefix의 되펼침 조건(`:2094`, 아래 `nbroad_livefix` 블록)과 FLUSH 경로(`:1587-1590`)를

```zig
if (diar_k == 0 and n_anchor == 0 and collapse != .min_sep and
    ncl < livefix_min_active and nbroad_livefix >= livefix_min_active)
```

로 좁힌다. **`.min_sep`만 막고 `.silhouette`은 그대로 둔다.**

### 왜 `.min_sep`만인가
`DIAR_MIN_SEP` 붕괴는 "살아있는 centroid들이 서로 0.50 코사인거리 안에 있다" = **같은 목소리라는
직접 증거**다. `.silhouette` 붕괴는 "좋은 분할을 못 찾았다"는 약한 신호이고, broad 폴백이 도입된
근거인 패널 under-split(ES2004a K=8/38.3% DER)이 바로 이쪽에 해당한다. 둘을 구분하지 않고 막으면
패널 회귀가 확실하다.

### 불변식
> 라벨링은 재클러스터가 **직접 증거로** 부정한 화자 구분을 되살리지 않는다.

### 위험
세 후보 중 회귀 위험이 가장 크다. `DIAR_MIN_SEP` 붕괴가 다인 패널에서도 발생하면 그 세션은 전원
1명으로 접힌다. 그래서 **후보 A가 목표를 달성하면 B는 착수하지 않는다.**

### 계측
후보 A와 동일 + 패널 회귀 전용:
```bash
python3 bench/diar_panel_eval.py --vox-all --speakers-from-ref --live --mode auto \
  --out-dir bench/runs/provB_vox        # 216파일. 무거우면 --vox-id로 20개 서브셋
python3 bench/live_ux_gate.py bench/runs/vox_base bench/runs/provB_vox --require-win
python3 bench/ko_diar_eval.py --kit-root "$MADI_DIAR_KIT" --out-dir bench/runs/provB_ko
python3 bench/ko_diar_gate.py bench/runs/ko_base bench/runs/provB_ko
```
합격 기준: VoxConverse 서브셋 **평균 DER 무회귀(+0.2 pt 이내)** 그리고 **DER이 2 pt 이상 악화된
파일 0건**. `ko_diar_gate.py`는 `speaker_overcount_peak` 한계 0.00을 하드로 들고 있으므로 그대로 게이트.

---

## 후보 C — centroid 병합 패스 + `SPKMERGE` 이벤트 (3순위, 표시 정합)

### 변경
**엔진**: `liveRecluster` write-back 직후(`:955`)에 병합 패스를 넣는다. 모든 centroid 쌍 (i, j),
i < j 에 대해 코사인거리 `< DIAR_MIN_SEP`이면 j를 i에 접는다(`sum`/`count` 합산). 접힌 j는
`count = 0`, 스캔 제외. 각 병합마다 `SPKMERGE <from> <into>` 한 줄 방출.

**앱**: 3곳만 손대면 된다 — 앱 쪽 병합 구현은 **이미 완성돼 있고 라이브 생산자만 없다**.
- `EngineProtocol.swift:20-40` — `case speakerMerge(from: Int, into: Int)` 추가
- `EngineProtocol.swift:142` 근처 — `SPKMERGE` 파싱 한 줄
- `TranscriptStore.ingest`(`:662-700`) — `case .speakerMerge(let f, let i): mergeSpeaker(from: f, into: i)`

`mergeSpeaker`(`TranscriptStore.swift:556`)가 `speakerMerges` 경로압축 + `speakerNumbers.merge`
(`SpeakerDisplayNumber.swift:47-60`, **낮은 번호가 생존**)까지 이미 처리한다. 지금 이 경로의 유일한
호출자는 세션 종료 후 LLM reconcile이다.

### 불변식
> 살아있는 두 centroid는 auto-K가 이미 "분할 거부" 기준으로 쓰는 `DIAR_MIN_SEP`보다 가까울 수 없다.

새 판정 상수를 만들지 않고 기존 상수를 재사용하므로, 병합 패스가 auto-K의 K 결정보다 엄격해지는 일은
구조적으로 불가능하다.

### 위험
동성·동채널 근접 화자의 병합. `DIAR_MIN_SEP` 공유가 상한을 걸고,
`--env DIAR_MIN_SEP=0.45/0.50/0.55` 스윕으로 계측 가능.

### 계측
후보 A와 같은 3케이스 + `speaker_overcount_peak`, 그리고 **앱 단위 테스트**:
`SpeakerDisplayNumber.merge`의 "낮은 번호 생존"과 `mergeSpeaker` 경로압축은 기존 테스트가 있으므로,
`SPKMERGE` 파싱 왕복 테스트만 `EngineProtocolTests`에 추가한다.

### 부가 이득
후보 A/B가 성공해도 이미 화면에 나간 번호는 되돌아오지 않는다. 후보 C는 **표시번호를 접는 유일한
라이브 수단**이므로, A가 통과하더라도 사용자 체감("Speaker 4가 갑자기 Speaker 1로 합쳐짐")을 위해
독립적으로 가치가 있다.

---

## 순서와 중단 규칙

```
A 구현 → 3케이스 계측
  ├─ 합격  → 머지. C로 진행(표시 정합). B는 착수하지 않음.
  └─ 불합격 → A 기각(패치 보관) → B 구현 → VoxConverse 서브셋까지 계측
        ├─ 합격  → 머지 → C
        └─ 불합격 → 둘 다 기각. 남는 선택지는 임베딩 창 확대(`DIAR_WIN_MS` 1500 → 2500-3000,
                   `transcribe.zig:1385`)뿐이며 이는 지연·정확도 트레이드오프라 별도 설계가 필요하다.
```

각 단계는 **오프라인 수치가 나오기 전에는 머지하지 않는다.** 반증되면 `bench/runs/p4/`에 패치를
보관하고 `PERF_LOG.md`에 반증으로 기록한다 — D1과 `DIAR_SIM`이 이미 그 자리에 있다.

## 계측 환경 메모

- VoxConverse 실데이터(공개 코퍼스, 저장소에 포함하지 않음): `$MADI_BENCH_SAMPLES/voxconverse/dev/*.rttm`(216)
  + `$MADI_BENCH_SAMPLES/audio/*.wav`. `diar_panel_eval.py`의 `--vox-id/--vox-all`이 그 변수를 읽는다
  (기본값 `bench/data`, `bench/README.md` 참고). `--audio/--ref`를 직접 주면 변수 없이도 동작한다(위 명령은 그 형태).
- `diar_panel_eval.py`는 엔진 경로 `out/transcribe`를 하드코딩한다. A/B는 후보 바이너리를
  `out/transcribe`로 복사해 돌리고 끝나면 되돌린다(`bench/runs/p4/chain.sh` 참고).
- 단일 파일 스모크: `python3 bench/live_der.py bench/ko1.wav bench/ko1.ref.rttm 10 3` (1화자 22.6 s).
- 재현 트레이스: `DIAR_ASSIGN_TRACE=1 DIAR_K_TRACE=1`로 `SPKTRACE … birth` / `[auto-k-candidate]` /
  `[recluster-final]` / `[livefix-candidate]` 확인.
