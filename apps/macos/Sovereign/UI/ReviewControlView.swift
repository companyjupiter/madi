// ReviewControlView.swift — 검토바(reviewBar)에 들어가는 "귀로 검토" 컨트롤.
// 듣기 모드를 켜면 저신뢰 단어의 오디오 구간을 하나씩 자동 재생하고, 한 단어
// 재생이 끝나면 다음으로 자동 전진한다(핸즈프리). 파일 전사 세션
// (sourceMediaURL 존재)에서만 활성화된다.
//
// 동작 결합: 코어(ReviewController)는 Foundation-only 상태 머신이라 오디오를
// 직접 못 만진다. 이 뷰가 LinePlayer.toggle(...)로 단어 구간을 재생하고,
// linePlayer.currentLine 이 경계 시각에서 nil 로 떨어지는 것을 감지해
// controller.advance()로 다음 단어를 물려준다.

import SwiftUI

struct ReviewControlView: View {
    @Bindable var session: SessionController
    @Bindable var controller: ReviewController
    /// reviewBar 의 진실원본(현재 검토 인덱스) — 듣기 진행과 양방향 동기화.
    @Binding var reviewIndex: Int
    /// 현재 단어 라인으로 스크롤 트리거(기존 reviewBar 와 동일 메커니즘).
    @Binding var scrollTarget: UUID?
    @Binding var scrollTick: Int
    /// transcript 순서의 저신뢰 단어 라인 목록(reviewBar 가 이미 계산해 전달).
    let flaggedCount: Int
    @AppStorage("uiLanguage") private var uiLang = UILanguage.ko

    /// 파일 전사 세션에서만 귀로 검토 가능(원본 미디어 URL 필요).
    private var canPlay: Bool { session.sourceMediaURL != nil }

    var body: some View {
        Group {
            if canPlay && flaggedCount > 0 {
                Button(action: toggle) {
                    Image(systemName: controller.isListening ? "pause.circle.fill" : "play.circle")
                        .foregroundStyle(controller.isListening ? Theme.Colors.lowConf : Theme.Colors.textSecondary)
                }
                .buttonStyle(.plain)
                .help(controller.isListening ? uiLang("귀로 검토 멈춤", "Stop listen-review") : uiLang("저신뢰 단어 귀로 검토", "Listen-review low-confidence words"))

                if controller.isListening, !controller.queue.isEmpty {
                    Text(uiLang("재생 \(controller.index + 1)/\(controller.queue.count)", "Playing \(controller.index + 1)/\(controller.queue.count)", "再生 \(controller.index + 1)/\(controller.queue.count)"))
                        .font(Theme.Fonts.status)
                        .foregroundStyle(Theme.Colors.lowConf)
                        .monospacedDigit()
                }
            }
        }
        // 큐 재구성: 전사가 갱신되거나 신뢰도 임계값이 바뀌면 따라간다.
        .onAppear { controller.refresh(lines: session.transcript.lines, threshold: Theme.confThreshold) }
        .onChange(of: flaggedCount) { _, _ in
            controller.refresh(lines: session.transcript.lines, threshold: Theme.confThreshold)
        }
        // 소스 미디어가 사라지면(아카이브 재오픈/파일 삭제) 듣기 자동 종료.
        .onChange(of: session.sourceMediaURL) { _, url in
            if url == nil { controller.stop(); session.linePlayer.stop() }
        }
        // 한 단어 재생이 끝나면 LinePlayer.currentLine 이 nil 로 떨어진다 →
        // 듣기 모드면 다음 단어로 전진해 재생. (사용자가 다른 라인을 직접
        // 누르면 currentLine 이 다른 id 로 바뀌므로 nil 전이만 처리해 충돌 회피.)
        .onChange(of: session.linePlayer.currentLine) { old, new in
            guard controller.isListening, old != nil, new == nil else { return }
            if let next = controller.advance() { play(next) }
            else { syncIndex() }   // 끝에서 깔끔히 정지 — 인덱스만 맞춰둠
        }
        // 듣기 진행이 reviewBar 인덱스를 끌고 가도록 동기화.
        .onChange(of: controller.index) { _, _ in syncIndex() }
    }

    /// 듣기 모드 토글. 켜지면 첫 단어를 즉시 재생.
    private func toggle() {
        controller.refresh(lines: session.transcript.lines, threshold: Theme.confThreshold)
        if let span = controller.toggleListening(canPlay: canPlay) {
            syncIndex()
            play(span)
        } else {
            session.linePlayer.stop()   // 껐으면 진행 중 재생도 멈춤
        }
    }

    /// 한 단어 구간을 원본 미디어에서 재생(라인 단위가 아닌 단어 단위 span).
    private func play(_ span: ReviewSpan) {
        guard let url = session.sourceMediaURL else { controller.stop(); return }
        // 같은 lineID 의 연속 단어면 toggle 의 "같은 line=정지" 규칙에 걸리므로,
        // 먼저 정지시켜 매 단어가 확실히 새로 재생되게 한다.
        session.linePlayer.stop()
        session.linePlayer.toggle(url: url, line: span.lineID, from: span.t0, to: span.t1)
    }

    /// 컨트롤러의 큐 인덱스를 reviewBar 의 reviewIndex + 스크롤에 반영.
    private func syncIndex() {
        guard let span = controller.current else { return }
        reviewIndex = controller.index
        scrollTarget = span.lineID
        scrollTick += 1
    }
}
