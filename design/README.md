# Sovereign Whisper — 디자이너 워크플로 (Figma ↔ 앱)

이 디렉터리가 디자이너와 코드 사이의 다리다. 핵심 사실 하나를 먼저:
**Figma는 SwiftUI를 직접 편집하거나 생성하지 못한다.** 그래서 업계 표준
방식인 **디자인 토큰 파이프라인**으로 묶는다 — 디자이너는 Figma에서 값(색·
폰트·간격·크기)을 바꾸고, 그 값이 JSON으로 내려와 앱 전체를 다시 칠한다.
레이아웃 구조 변경(새 화면, 배치 변경)은 Figma 시안 → 엔지니어가 SwiftUI
반영, 이 두 트랙이다.

```
┌── 디자이너 (Figma) ─────────────────────────┐
│ 1. figma/*.svg 임포트 → 편집가능 벡터 캔버스 │
│ 2. 토큰을 Figma Variables/Tokens Studio로 관리│
│ 3. 자유롭게 리디자인                          │
└──────────────┬──────────────────────────────┘
               │ 토큰 export (JSON)
               ▼
┌── 엔지니어 (이 리포) ───────────────────────┐
│ 4. tokens.json 갱신                          │
│ 5. ./sync_tokens.sh  → Theme.swift 재생성     │
│    → 앱 재빌드 → 전체 리스타일 완료           │
└─────────────────────────────────────────────┘
```

## 파일

| 파일 | 역할 |
|---|---|
| `tokens.json` | **단일 진실 원천** — 색(화자 팔레트 8 + 시맨틱), 폰트 6, 간격, 크기, 라운드. 현재 앱 UI에서 추출한 실값 |
| `gen_theme.py` | tokens.json → `app/Sovereign/UI/Theme.swift` 코드젠 |
| `sync_tokens.sh` | 토큰 반영 원커맨드 (gen + 앱 재빌드) |
| `figma/main-recording.svg` | 메인 윈도(녹음 중) — 화자 라인 3종 + 겹침 마커 + 컨트롤바 |
| `figma/file-editor.svg` | **파일 전사 + 편집자 UI** — 내용/상세 토글, 내용모드 문단, 리뷰 바(상세), **편집 도구 패널**(토글+슬라이더), 타이튼 stat, 내보내기 |
| `figma/model-gate.svg` | 첫 실행 모델 다운로드 화면 |
| `figma/settings.svg` | 설정(Transcription 탭) |
| `figma/components.svg` | **컴포넌트 시트** — 팔레트 스와치(토큰명 라벨), TranscriptLine 해부도, 버튼 상태, 레벨미터 상태 |

### 2026-06 추가된 편집자/리더 컴포넌트 (`file-editor.svg`)

이번 라운드 신규 UI. **모두 기존 시맨틱 토큰 재사용 — 새 토큰 0개.** 디자이너가
토큰만 바꾸면 이 컴포넌트들도 함께 리스타일된다. 동작·파라미터 정본은
`docs/EDITOR_FEATURES.md`.

| 컴포넌트 | 쓰는 토큰 | 비고 |
|---|---|---|
| 내용/상세 토글 | `color.accent`, `font.status` | 기본=내용(평문). 일반인용 |
| 리뷰 바 (검토 N개 ▲▼) | `color.lowConf`, `font.status` | **상세 모드에서만** |
| 편집 도구 패널 (토글+슬라이더) | `color.accent`, `color.text*`, `font.status` | 사이드패널 DisclosureGroup |
| 타이튼 stat (✂︎ N컷·M초) | `color.accent`, `font.status` | 컷 있을 때만 |
| 내보내기 신규 항목 (.vtt/.csv/챕터) | 기존 메뉴 스타일 | export 메뉴 |

> **원칙(고정 계약):** 편집자 디테일은 상세 뷰 / 사이드패널 / export에만. **기본
> 내용(평문) 뷰는 건드리지 않는다.** 리디자인 시 이 격리를 유지할 것.

## 디자이너 온보딩 (이대로 전달)

1. **임포트**: Figma 새 파일 → 4개 SVG를 드래그&드롭. 모든 도형·텍스트가
   편집가능 레이어로 들어온다 (SVG `id` = 레이어 이름).
2. **토큰 등록**: `components.svg`의 스와치들을 Figma **Variables**로 등록
   (또는 Tokens Studio 플러그인 사용). 이름은 시트의 라벨 그대로:
   `color.speaker.0` … `color.accent`, `space.window=16`, `size.meterH=10` 등.
   **이 이름들이 코드와의 계약이다 — 이름을 바꾸면 매핑이 깨진다.**
3. **리디자인**: 화면 SVG들을 컴포넌트화해서 자유롭게. 단,
   - 색/폰트/간격은 **반드시 Variables를 참조** (raw 값 박지 말 것)
   - 새 시맨틱 색이 필요하면 추가하고 이름을 알려줄 것 (tokens.json에 추가)
4. **내보내기**: Tokens Studio → "Export to JSON" (또는 Variables를 수동
   정리). 엔지니어에게 전달.
5. 엔지니어: 전달받은 값을 `tokens.json`에 반영 → `./sync_tokens.sh` → 끝.

> Tokens Studio JSON과 우리 `tokens.json`의 스키마가 1:1은 아니다 — 현재는
> 값만 옮겨 적으면 된다(토큰 수십 개 수준). 토큰이 수백 개로 늘면
> gen_theme.py에 Tokens Studio 포맷 파서를 추가하는 게 다음 단계.

## 레이아웃 변경 (토큰 너머)

새 화면·재배치·신규 컴포넌트는 토큰으로 자동 반영되지 않는다:
1. 디자이너가 Figma 시안 완성 (기존 컴포넌트명 재사용 권장)
2. Figma **Dev Mode**로 스펙(간격·크기) 확인 가능하게 공유
3. 엔지니어(또는 Claude)가 SwiftUI로 구현 — 시안 프레임 스크린샷/링크를
   이슈에 첨부하면 그대로 구현한다

## 검증

토큰 반영 후 앱 빌드가 곧 검증이다 (`sync_tokens.sh`가 빌드까지 돌림).
시각 회귀가 걱정되면 변경 전후 스크린샷 비교 — 현재는 수동, 필요해지면
스냅샷 테스트 추가.
