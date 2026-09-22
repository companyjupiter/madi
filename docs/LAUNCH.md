# Madi open-source launch kit

This page contains ready-to-publish launch copy and the final non-notarization
checks. Keep product claims aligned with [PRIVACY.md](../PRIVACY.md) and the mixed
distribution boundary in [docs/PROVENANCE.md](PROVENANCE.md).

## Canonical links

- Landing page: https://madi-apple-silicon.jupitersong47.chatgpt.site/
- Repository: https://github.com/companyjupiter/madi
- Latest release: https://github.com/companyjupiter/madi/releases/latest
- Korean README: https://github.com/companyjupiter/madi/blob/main/README_KR.md
- Contributing: https://github.com/companyjupiter/madi/blob/main/CONTRIBUTING.md

## Positioning

**One line:** Madi is open-source, on-device meeting intelligence for Apple Silicon.

**Short paragraph:** Madi records microphone or system audio and turns it into live,
speaker-aware transcripts, translation, summaries, action items, and searchable
meeting memory. Inference stays on the Mac; the network is used only for explicit
model downloads and update checks.

## X — English

Madi is now open source.

It is an on-device meeting intelligence app for Apple Silicon: live transcription,
speaker separation, translation, summaries, action items, and recall — without
sending meeting content to a cloud processing service.

AGPL source, public roadmap, reproducible source-only build, 688 core tests.

https://madi-apple-silicon.jupitersong47.chatgpt.site/

## X — Korean

Madi를 오픈소스로 공개했습니다.

Apple Silicon에서 회의 음성을 실시간 전사하고, 화자를 나누고, 번역·요약·액션
아이템·검색 가능한 회의 기억까지 모두 로컬에서 처리합니다. 회의 내용을 클라우드
처리 서비스로 보내지 않습니다.

AGPL 소스, 공개 로드맵, 재현 가능한 source-only 빌드, 코어 테스트 688개.

https://madi-apple-silicon.jupitersong47.chatgpt.site/

## LinkedIn — Korean

Madi를 오픈소스로 공개합니다.

회의 도구가 편리해질수록 가장 민감한 대화가 외부 처리 경로에 들어가는 역설이
생깁니다. Madi는 그 경계를 반대로 설계했습니다. 마이크·시스템 오디오 캡처부터
실시간 전사, 화자 분리, 번역, 요약, 액션 아이템, 과거 회의 검색까지 Apple
Silicon 위에서 처리합니다.

이번 공개에는 앱 소스만 올린 것이 아니라 다음 운영 표면도 함께 포함했습니다.

- AGPL-3.0 애플리케이션 소스와 명시적인 바이너리 라이선스 경계
- 별도 번역 엔진을 제외하는 재현 가능한 source-only 빌드
- 개인정보·보안·거버넌스·지원·기여 가이드
- 고정된 GitHub Actions 의존성, CodeQL, dependency review, SPDX SBOM과 빌드 증명
- Swift 코어 테스트 688개와 macOS 전체 앱 빌드 검증

직접 써보고, 코드를 읽고, 개선에 참여해 주세요.

Landing: https://madi-apple-silicon.jupitersong47.chatgpt.site/
GitHub: https://github.com/companyjupiter/madi

## Hacker News

**Title:** Show HN: Madi – open-source, on-device meeting intelligence for Apple Silicon

**Body:**

I built Madi, a native macOS app that handles live transcription, speaker separation,
translation, summaries, action items, and meeting recall on Apple Silicon. Meeting
content is processed locally; network access is limited to explicit model downloads
and update checks.

The application source is AGPL-3.0. Product release bundles may additionally include
small, separately licensed redistributable translation-engine binaries, and the repo
documents that boundary. `MADI_BUNDLE_TRANSLATE_ENGINES=0` builds an AGPL-only app
bundle from the public tree.

The stack is SwiftUI + Zig + Metal. The repository includes 688 headless core tests,
license/provenance documentation, and release supply-chain controls.

Source: https://github.com/companyjupiter/madi
Landing: https://madi-apple-silicon.jupitersong47.chatgpt.site/

Feedback on the local-first architecture, Metal/Zig implementation, and contributor
onboarding is especially welcome.

## Launch gate

- [x] Public repository metadata and topics are set.
- [x] Source license and bundled-binary boundary are explicit.
- [x] Privacy, security, governance, support, roadmap, and contribution docs exist.
- [x] Source-only and standard application bundles build and verify.
- [x] Core, release-tooling, and dashboard checks pass.
- [x] Landing page and 1200×630 social preview are published.
- [x] CodeQL, dependency review, Dependabot, SBOM, and provenance workflows exist.
- [ ] Owner-managed notarization is complete for the promoted DMG.
- [ ] Replace the unchecked line above with `[x]` immediately before posting.
