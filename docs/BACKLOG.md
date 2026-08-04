# 고려 기능 백로그 (Madi)

즉시 구현하지 않고 **고려만 해 둔** 기능들. 우선순위가 오거나 선행 조건이 충족되면 착수한다.
(구현/검증 파이프라인: `.claude/workflows/madi-feature-pipeline.mjs` — `Workflow({scriptPath: …})`)

---

## 온디바이스 TTS (텍스트 → 음성)  ⟦고려중⟧

전사/번역/요약은 만들었지만 **글자를 소리로** 읽어주는 기능은 없다. 현재의 오디오 재생
(click-to-play, listen-review)은 전부 *원본 녹음* 재생이지 음성 합성이 아니다.

- **방법**: macOS `AVSpeechSynthesizer` — 온디바이스·무료·다국어(KO/EN/JA/ZH). 클라우드 0,
  sovereign 원칙과 정합.
- **붙일 후보**:
  - 번역 자막 읽어주기 — 외국어 회의의 번역문을 귀로 듣기 (자막 오버레이/줄 옆 재생).
  - 요약 읽어주기 — A.I 요약을 오디오로 (이동 중 듣기).
  - 전사문 읽어주기 — 회의록 전체 오디오.
- **노트**: 줄→오디오 재생(click-to-play)과 UI 패턴을 공유 가능. 언어 선택은 translateTargets/
  source 언어에서 유추.
- 추가: 2026-06-24 (사용자 요청으로 백로그 보류).

---

## 라이브 녹음 재생 (click-to-play v2)  ⟦선행 필요⟧

지금 click-to-play는 **파일 전사 세션**만 지원(원본 파일이 디스크에 있고 타임라인 일치).
라이브 녹음도 줄→오디오 재생하려면 연속 오디오 보존이 필요.

- **선행**: 세션 오디오 보존(AudioCapture의 세그먼트는 temp+overlap → 연속 WAV로 적재) +
  저장공간 관리 정책(어디에·언제까지 보존, 큰 WAV 정리).
- 시작 시 그 보존 정책부터 결정.

---

## 번역 품질 레버 (DNA3 4B → 9B)  ⟦트레이드오프 평가 필요⟧

`Engine/TranslateEngine.swift` 주석의 deferred A/B. 현 4B 모델은 in-target anchor로 KO→KO
재구성을 막고 있으나, 더 큰 9B 모델이 번역 품질을 더 올릴 수 있음.

- **트레이드오프**: 메모리(↑)·속도(↓) vs 품질(↑). ≥16GB 게이트 / 모델 다운로드 정책과 함께 평가.

## 번역 표시 안정성 후속 (2026-08-05 배치의 잔여, 정본 docs/TRANSLATE_DISPLAY_STABILITY.md)

- **NE 베이스라인 실측**: 첫 라이브 세션의 `[translate-stability]` 로그로 수리 전후
  수치를 PERF_LOG에 기록 (목표 밴드 NE < 0.2).
- **P7 — 문장확정 프리셋**: 강의/행사용 옵션 = 인터림 번역 off, 문장 커밋 후 번역만
  (Interprefy standard/instant 이중 모드 선례). 클리닉 기본은 스트리밍 유지.
- **EN→KO 직독직해 스타일**: 엔진 target-prefix 이어쓰기 지원이 생기면 재평가
  (KO→EN은 동사후치 소스라 기각 — 문서 참조).
