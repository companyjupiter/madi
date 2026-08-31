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

최종 프롬프트 (전부 한국어 지시·단문·"다른 말 없이 이 형식만" 마무리 — 현행 규율):

- **meeting**: 현행 문자열 **바이트 동일 유지** (골든 테스트로 고정).
- **lecture**: "다음 강의/발표 전사를 요약하세요. 전사와 같은 언어로 답하세요.
  형식: [요약] 핵심을 2-4문장. [요점] 각 줄 '- 요점'. [용어] 각 줄
  '- 용어: 한 줄 설명'(없으면 생략). 다른 말 없이 이 형식만. 전사: …"
- **interview**: "다음 인터뷰/상담 전사를 요약하세요. 전사와 같은 언어로 답하세요.
  형식: [요약] 핵심을 2-4문장. [문답] 각 줄 '- Q: 질문 → A: 답변 요지'.
  [후속] 각 줄 '- 담당자: 후속 조치'(없으면 생략). 다른 말 없이 이 형식만. 전사: …"

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

1. **PR-A (코어 리팩터, 출력 불변)**: SummaryTemplate + 레지스트리, SummaryDeck
   headers 유도, RecapData/OpenLoops kind 매핑, 테스트. 기존 회의 요약 입력에
   대해 출력 바이트 동일 assert.
2. **PR-B (엔진)**: template 스레딩, 템플릿별 final/condense 프롬프트,
   MeetingMode 서픽스 이관, CLI 검증 로그를 이 문서에 추기.
3. **PR-C (UI·i18n·매뉴얼)**: 시트 3-way picker, L10nJa, 매뉴얼
   ko/en/ja/zh `05-summary` 갱신.

## 7. 리스크 / 반증 포인트 (PR-B 착수 전 프로브)

- **2B 모델의 [문답] Q→A 짝 준수** — 8GB 기기는 DNA3.0-2B다. CLI 프로브 선행;
  실패 시 인터뷰 템플릿 폴백 = `[문답]` 을 일반 불릿("- 질문 요지: 답변 요지")로
  완화. 스파인은 그대로.
- **condense 왕복의 용어 정의 유실** — 골든 강의 전사로 확인. 유실 시 lecture
  condense에 "용어는 '용어: 정의' 짝 그대로" 명시 강화.
- 프롬프트 서픽스 이관 후 oneOnOne/standup 품질 변화 없음 확인 (meeting 프롬프트
  자체는 불변이므로 리스크 낮음).
