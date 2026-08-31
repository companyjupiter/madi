# 요약 템플릿 3종 — 상세 설계 (2026-08-31 확정)

정본 상위 문서: `MEETING_INTELLIGENCE.md`. 이 문서는 "AI 요약 카테고리를 복잡하게
하지 않고, 스파인 하나 + 템플릿 3가지"로 확정한 설계의 구현 정본이다.

## 0. 결정

- **스파인 1개**: `[요약] 2–4문장` 머리 + 섹션 태그 2개 + `- ` 불릿.
  모든 템플릿이 이 뼈대를 공유한다 (파서·슬라이드 덱·리캡 카드·내보내기 재사용,
  2B/4B 소형 모델에 유리한 경직 포맷).
- **템플릿 3종** (사용자 노출 카테고리는 이 셋뿐):

| 템플릿 | 모델 출력 태그 | 표시 제목 | 흡수하는 MeetingMode |
|---|---|---|---|
| 회의 (meeting) | `[요약]` `[액션]` `[결정]` | 요약 / 액션 아이템 / 결정 사항 | general · oneOnOne · standup |
| 강의·발표 (lecture) | `[요약]` `[요점]` `[용어]` | 요약 / 핵심 요점 / 용어·개념 | lecture |
| 인터뷰·상담 (interview) | `[요약]` `[문답]` `[후속]` | 요약 / 문답 / 후속 조치 | interview |

- **회의 템플릿 = 현행 그대로 (바이트 동일 기준선)**. 기존 저장본·내보내기와
  하위호환은 공짜다.
- 모델 출력 태그는 **짧은 명사 리터럴**로 고정 (`[핵심 요점]`·`[용어·개념]` 같은
  중점(·) 포함 리터럴은 소형 모델이 흔들린다). 긴 표시 제목은 레지스트리가 매핑.
- 선택 동선: **MeetingMode에서 기본 유도** + 요약 시트에서 3-way 오버라이드.
  새 최상위 UI 없음.

## 1. 코어 타입 — `SummaryTemplate.swift` (신규)

위치 `apps/macos/Sovereign/Transcript/SummaryTemplate.swift`. MeetingMode와 같은
규율: **Foundation-only** (SovereignCore 편입, XCTest 커버), rawValue가 영속 키.

```swift
enum SummaryTemplate: String, CaseIterable, Identifiable, Codable {
    case meeting, lecture, interview          // rawValue = 안정 영속 키
}

/// 섹션 서술자 — 태그 규칙의 단일 정본(레지스트리).
struct SummarySection: Equatable {
    enum Kind { case gist, decision, action, qa, keypoint, term }
    let kind: Kind        // 소비자(리캡/오픈루프/덱) 의미론
    let tag: String       // 모델이 방출하는 리터럴: "요약", "액션", "후속" …
    let aliases: [String] // 파서 관용 키 (SummaryDeck.matchHeader 유도용)
    let canon: String     // 표시 제목: "액션 아이템", "핵심 요점" …
}

extension SummaryTemplate {
    var sections: [SummarySection]            // 순서 보존, gist 선두
    func finalPrompt(transcript: String, styleSuffix: String) -> String
    func condensePrompt(chunk: String) -> String
}
```

Kind 배정 (소비자 의미론이 여기서 결정된다):

- meeting: gist(요약) · decision(결정) · action(액션)
- lecture: gist(요약) · keypoint(요점) · term(용어)
- interview: gist(요약) · qa(문답) · **action(후속)** — 후속 조치는 kind가 action
  이므로 리캡 카드 액션 슬롯·오픈 루프 추적에 **자동으로** 편입된다.

MeetingMode → 기본 템플릿 유도 (MeetingMode.swift에 extension):

```swift
extension MeetingMode {
    var defaultSummaryTemplate: SummaryTemplate {
        switch self {
        case .general, .oneOnOne, .standup: return .meeting
        case .lecture:   return .lecture
        case .interview: return .interview
        }
    }
}
```

## 2. 프롬프트 레이어 — `SummaryEngine.swift`

`summarize(lines:styleSuffix:)` → `summarize(lines:template:styleSuffix:)`.
`finalPrompt(_:_:)`의 default 케이스와 `condensePrompt`가 템플릿으로 분기한다.
화자별(speakers) 뷰 · ask/Q&A · title · live-rail · reconcile은 **템플릿 무관,
무변경**.

최종 프롬프트 (전부 한국어 지시·단문·"다른 말 없이 이 형식만" 마무리 — 현행 규율).
**2026-08-31 2B/4B CLI 프로브로 문안 확정** (§7) — 정본은
`SummaryTemplate.finalPrompt` 코드 (골든 테스트로 고정):

- **meeting**: 현행 문자열 **바이트 동일 유지** (골든 테스트로 고정).
- **lecture**: "다음 강의/발표 전사를 요약하세요. 전사와 같은 언어로 답하세요.
  형식: [요약] 핵심을 2-4문장. [요점] 각 줄을 - 요점 형태로 3-5개.
  [용어] 전사에 등장한 용어 중 가장 중요한 3개만 각 줄 - 용어: 한 줄 설명
  (없으면 생략). 따옴표 없이, 다른 말 없이 이 형식만. 전사: …"
- **interview**: "다음 인터뷰/상담 전사를 요약하세요. 전사와 같은 언어로 답하세요.
  형식: [요약] 핵심을 2-4문장. [문답] 주요 문답 최대 5쌍, 질문은 - Q: 로 쓰고
  바로 아랫줄에 답변을 - A: 로. [후속] 앞으로 하기로 한 일만 각 줄 - 이름: 할 일
  (없으면 생략). 따옴표 없이, 다른 말 없이 이 형식만. 전사: …"

프로브가 강제한 문안 결정 (원안에서 변경된 지점):
- [문답]은 **한 줄 'Q → A' 짝을 요구하지 않는다** — 2B가 예시의 따옴표를 문자
  그대로 복사하고 →를 못 쓴다. 모델의 자연형(Q 한 줄, 바로 아래 A 한 줄)을
  프롬프트가 그대로 요구; 스파인('- ' 불릿)은 유지되므로 파서 변경 없음.
- "따옴표 없이" 명시 (따옴표 복사 병리 차단), [후속] 플레이스홀더는
  '담당자'→'이름' (2B가 '- 담당자: 김부장'으로 리터럴 복사+역전).
- 개수 제한("최대 5쌍", "3개만")은 2B가 무시하는 **너지**일 뿐 — 강제는
  SummaryReplySanitizer의 섹션별 캡이 담당.

**SummaryReplySanitizer** (PR-B 신설, 프로브가 발견한 2B 병리 3종 가드):
1. **stray `</think>` 누출 + 답안 재진술** (프로브 2/9) — 엔진은 think를
   프리필로 끄지만 2B가 중간에 `</think>`를 방출하고 전체를 다시 쓴다 →
   head marker([요약]/■)를 가진 마지막 세그먼트 채택, 없으면 최장 세그먼트
   (절단된 재진술이 완전한 초안을 이기면 안 됨).
2. **교대 라인 반복 폭주** ([후속]이 같은 2줄을 ~20회 반복) — 정확-중복
   라인 제거 + 빈 줄 run 1로 압축.
3. **환각 꼬리** ([용어]가 65개까지 증식, 근거 14개; 영어 인터뷰에서 문답
   12쌍 지어내기) — 레지스트리 `bulletCap`(요점·용어 5, 문답 10, 후속 6,
   기본 12)으로 섹션 내 **콘텐츠 라인** 절단(불릿 대시가 빠진 'Q:' 라인도
   카운트). 앞쪽 라인이 근거 있는 라인들이라 캡이 곧 품질 필터.
적용 지점: summary/speakers 최종 응답 + fold(condense) 중간 응답(폭주가
다음 라운드로 복리되는 것 차단). 건강한 응답엔 no-op (골든 테스트).

condense (map-reduce 중간 단계 — **템플릿 인지형이 이 설계의 실질 요점**,
현행은 회의 전용 "화자·핵심·결정·할 일 보존"이라 2시간 강의를 접으면 요점·용어가
유실된다):

- meeting: 현행 유지.
- lecture: "주제·핵심 요점·용어(정의) 보존하며 간결히 요약."
- interview: "질문·답변 짝(누가 물었고 뭐라 답했는지)·후속 조치 보존하며 간결히 요약."

MeetingMode.summaryPromptSuffix 이관: lecture/interview 서픽스는 템플릿 프롬프트가
흡수하므로 **"" 로 변경** (이중 지시 방지). oneOnOne/standup 서픽스는 meeting
템플릿 위의 너지로 **유지**. general "" 유지 — 기준선 불변.

## 3. 파서·소비자 (태그 레지스트리로 수렴)

- **SummaryDeck.headers** — 하드코딩 테이블을 SummaryTemplate 레지스트리에서
  유도 (RecapCardView 주석의 "토큰 규칙 한 곳 관리" 원칙을 레지스트리로 승격).
  합산 관용 키:

  ```
  ("요약",      ["요약","summary","개요"])            gist
  ("액션 아이템", ["액션","할 일","할일","action","to-do","todo"])  action
  ("결정 사항",  ["결정","decision"])                 decision
  ("핵심 요점",  ["요점","핵심 요점","takeaway","key point"])       keypoint
  ("용어·개념",  ["용어","개념","term"])              term
  ("문답",      ["문답","q&a","질의응답"])            qa
  ("후속 조치",  ["후속","follow-up","followup"])     action
  ```

  `parseSections` 본체는 섹션-불가지라 무변경. `matchHeader`의 prefix 매칭 특성상
  짧은 명사만 alias로 넣는다 (기존 "결정" prefix 리스크와 동수준 용인).
  live-rail의 `[질문]`은 별도 정규식(`LiveActionRail.line`)이라 충돌 없음.
- **slideHTML** — 체크리스트 판정 `s.title.contains("액션")` → kind 기반
  (action이면 checklist). 문답 슬라이드는 일반 불릿.
- **GistExtractor** — 무변경. 우선순위 결정>요약>임의 섹션이므로 강의/인터뷰
  저장본은 [결정] 부재 → [요약] 첫 줄로 자연 폴백 (의도된 동작).
- **RecapData** — `title.contains` 3분기 → kind 기반: gist→tldr,
  decision→decisions, action→actions(후속 포함), **keypoint/term/qa →
  `extras: [(title, items)]`** 신설. 카드/Markdown은 결정·액션이 비면 그 자리에
  extras 섹션을 렌더 (강의 카드가 앙상해지는 것 방지). Markdown 체크박스는
  action kind만.
- **OpenLoopsAggregator** — route 2(SummaryDeck 헤더 경로)에서 "후속 조치" 섹션을
  action으로 편입. 강의 저장본은 루프 0건 = 의도된 동작 (강의엔 후속이 없다).
- **Exporters.markdown** — `## 회의 요약` 헤딩 유지 (Gist/OpenLoops의 파싱 키).
  템플릿 무관.

## 4. SessionController + UI

- `SessionController.summaryTemplate: SummaryTemplate` (@Published) —
  `meetingMode.didSet`에서 `defaultSummaryTemplate`로 재유도. 시트 오버라이드는
  세션 내 일시값 (모드가 영속 신호, 템플릿은 유도값 — 별도 UserDefaults 없음).
  `summarize()` / `summarizeBySpeaker()` / 재생성 경로(≈L1404) 모두 스레딩.
- **요약 시트** — 헤더 아래 3-way segmented Picker (회의/강의/인터뷰),
  기존 전체/화자별 Picker와 나란히 (직교 축: 템플릿=무엇을, 전체/화자별=어느
  관점으로). 템플릿 변경 시 기존 결과 폐기 + 자동 재생성 (다시 생성과 동일 경로,
  busy guard 재사용).
- **i18n** — uiLang(ko,en) 3쌍 + L10nJa: "Lecture"→"講義"·"Interview"→"面談"은
  기존 키 재사용, "Meeting"(→"会議")만 신규 확인 후 추가.
- ⌘K 팔레트·✦ 버튼 동선 무변경 (기본 유도 템플릿으로 생성).

## 5. 검증 (GUI-free — 프로젝트 룰)

- **유닛**: `SummaryTemplateTests` (태그 유일성·모드→템플릿 유도·**meeting 최종
  프롬프트 골든 = 현행 바이트 동일**), `SummaryFormatTests`에 lecture/interview의
  tagged+prose 페어 추가 (덱 + OpenLoops 양쪽 관통), RecapData kind 매핑·extras
  렌더 테스트, MeetingModeTests 서픽스 이관 반영.
- **엔진 CLI** (요약 v1과 동일 방식): 템플릿별 실전사 각 1건 —
  한국어 강의 전사 → [요약]/[요점]/[용어] 구조 + 같은 언어 응답;
  2인 인터뷰 전사 → Q→A 짝 형식 준수. map-reduce 경로는 >800자 강의 전사에서
  condense 왕복 후 요점·용어 보존 확인.
- **quark v9**: `./q.sh complete configs/sovereign_whisper_app.mjs` —
  SummaryTemplate.swift wired 확인.

## 6. PR 슬라이스 (순서 고정)

1. **PR-A (코어 리팩터, 출력 불변)** — **PR#253**: SummaryTemplate + 레지스트리,
   SummaryDeck headers 유도, RecapData/OpenLoops kind 매핑, 테스트. 기존 회의
   요약 입력에 대해 출력 바이트 동일 assert.
2. **PR-B (엔진)** — **완료 (PR#253 위 stacked)**: template 스레딩, 템플릿별
   final/condense 프롬프트(§2 확정 문안), SummaryReplySanitizer,
   MeetingMode 서픽스 이관, SessionController.summaryTemplate 유도·스레딩,
   CLI 프로브 로그(§7).
3. **PR-C (UI·i18n·매뉴얼)**: 시트 3-way picker, L10nJa, 매뉴얼
   ko/en/ja/zh `05-summary` 갱신.

## 7. 2B/4B CLI 프로브 로그 (2026-08-31 — PR-B 착수 전, 완료)

방법: `sovereignLLM` CLI 직접 구동 (`out/metal-dna3-{2b,4b}-q4km` + 로컬 gguf,
stdin 1줄=1턴, `[perf] generation` 종결). 픽스처 = KO 인터뷰 3(채용/고객상담/
코칭) + EN 인터뷰 1 + KO 강의 2 + 현행 회의 프롬프트 회귀 1 + condense 2 +
map-reduce 왕복 1. 판정 자동화(정규식), 최종 라운드는 **Swift 실물**
(SummaryTemplate 프롬프트 바이트 동일 검증 + SummaryReplySanitizer 바이너리)로
원시 응답 재판정.

**v1 프로브 (설계 원안 문안) — 2B 전 인터뷰 케이스 FAIL, 원인 발견:**
- 예시의 작은따옴표를 출력에 문자 그대로 복사 (`'- Q: …'` → 불릿 파싱 깨짐)
- `→ A:` 대신 `- A:` (한 줄 짝 형식 자체가 비자연)
- `담당자` 플레이스홀더 리터럴 복사·역전 (`- 담당자: 김부장`)
- stray `</think>` + 전체 재진술 (2/9), [후속] 교대 반복 폭주 (~20회),
  [용어] 65개 증식(전사 근거 14개)
- 강의 구조([요약]/[요점]/[용어])와 회의 현행 프롬프트는 2B에서도 건강

**v3 확정 문안 + 새니타이저 → 전 케이스 PASS (Swift 실물 판정):**

| 케이스 | 2B | 4B |
|---|---|---|
| KO 인터뷰 ×3 | QA 4/3/2쌍 ✓ | QA 4/4/5쌍 ✓ |
| EN 인터뷰 | QA 5쌍(캡 절단)·914자 ✓ | QA 5쌍·460자 ✓ |
| KO 강의 ×2 | 용어 5(캡 절단) ✓ | 용어 3(근거 3/3) ✓ |
| 회의 현행 프롬프트 회귀 | ✓ | ✓ |
| map-reduce 왕복(2청크 condense→final) | QA 5쌍 ✓ | QA 5쌍 ✓ |

**폴백 판정: 불필요** — 원안의 "[문답] 일반 불릿 완화" 폴백은 쓰지 않는다.
Q/A 2줄 자연형 + 새니타이저로 2B가 성립.

**알려진 한계 (백로그, 이 설계 스코프 외):**
- 2B가 영어 전사에서 [요약]을 한국어로 내는 경향 — 프롬프트가 한국어 지시라서
  생기는 현행 회의 요약과 동등한 수준의 한계 (신규 회귀 아님).
- oneOnOne/standup 서픽스 이관 후 품질: meeting 프롬프트 불변이라 리스크 낮음,
  미계측.
