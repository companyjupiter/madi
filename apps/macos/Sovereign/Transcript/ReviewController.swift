// ReviewController.swift — "귀로 검토(listen-to-review)" 상태 머신. 저신뢰
// (low-confidence) 단어를 하나씩 자동 재생하며 검토 큐를 핸즈프리로 진행한다.
//
// 설계: 이 코어는 Foundation-only(헤드리스 테스트 가능)이다. 오디오 재생은
// LinePlayer(AVFoundation)에 있으므로 이 컨트롤러는 직접 재생하지 않는다.
// 대신 "다음에 어떤 span을 재생해야 하는가"라는 순수 상태만 관리하고, 뷰가
// LinePlayer.toggle(...) 호출 + currentLine 종료 감지를 담당해 advance()로
// 되돌려준다. 이렇게 하면 AVFoundation 없이도 큐 구성·진행 로직을 단위
// 테스트할 수 있다.
//
// 단어 단위 정밀도: ContentView.flaggedWords 는 단어를 라인으로 합치지만,
// 여기서는 각 저신뢰 단어의 t0/t1 을 그대로 보존해 단어 한 개씩 들려준다.

import Foundation
import Observation

/// 재생 대상 한 개 — 저신뢰 단어 하나의 오디오 구간.
struct ReviewSpan: Identifiable, Equatable {
    let id = UUID()
    let lineID: UUID        // 어떤 라인에 속하는지 (스크롤/하이라이트 동기화용)
    let text: String        // 표시용 단어 텍스트
    let t0: Double          // 단어 시작(초)
    let t1: Double          // 단어 끝(초)

    static func == (a: ReviewSpan, b: ReviewSpan) -> Bool {
        a.lineID == b.lineID && a.text == b.text && a.t0 == b.t0 && a.t1 == b.t1
    }
}

@Observable
@MainActor
final class ReviewController {
    /// 귀로 검토 모드 on/off. off면 수동(chevron) 검토만.
    private(set) var isListening = false
    /// 현재 재생 중인 큐 인덱스(리뷰 인덱스와 동기). 비어 있으면 의미 없음.
    private(set) var index = 0
    /// 자동 재생용으로 구성된 저신뢰 단어 큐(단어 단위, transcript 순서).
    private(set) var queue: [ReviewSpan] = []

    // MARK: 순수 큐 구성 (테스트 대상)

    /// 라인들에서 conf < threshold 인 단어를 transcript 순서로 펼친 큐를 만든다.
    /// 공백뿐인 단어는 제외. 단어 한 개 = 큐 항목 한 개(라인 단위로 뭉치지 않음).
    static func buildQueue(_ lines: [Line], threshold: Double) -> [ReviewSpan] {
        var out: [ReviewSpan] = []
        for l in lines {
            for w in l.words where w.conf < threshold {
                let t = w.text.trimmingCharacters(in: .whitespaces)
                guard !t.isEmpty else { continue }
                out.append(ReviewSpan(lineID: l.id, text: t, t0: w.t0, t1: w.t1))
            }
        }
        return out
    }

    /// 순환(wrap) 이동 후의 인덱스. 빈 큐는 0.
    static func wrapped(_ i: Int, by delta: Int, count: Int) -> Int {
        guard count > 0 else { return 0 }
        return ((i + delta) % count + count) % count
    }

    // MARK: 상태 전이

    /// 최신 라인으로 큐를 재구성한다. 인덱스는 유효 범위로 클램프.
    /// 큐가 비면 듣기 모드는 자동 종료(검토할 단어가 없음).
    func refresh(lines: [Line], threshold: Double) {
        queue = Self.buildQueue(lines, threshold: threshold)
        if queue.isEmpty {
            index = 0
            isListening = false
        } else if index >= queue.count {
            index = queue.count - 1
        }
    }

    /// 지금 재생해야 할 span(없으면 nil — 큐 비었거나 인덱스 범위 밖).
    var current: ReviewSpan? {
        guard queue.indices.contains(index) else { return nil }
        return queue[index]
    }

    /// 듣기 모드 토글. 켤 때 재생 가능 여부(canPlay)가 false거나 큐가 비면
    /// 켜지지 않는다(파일 모드 아님 / 검토할 단어 없음). 반환값 = 켜진 직후
    /// 재생해야 할 span(없으면 nil).
    @discardableResult
    func toggleListening(canPlay: Bool) -> ReviewSpan? {
        if isListening { stop(); return nil }
        guard canPlay, !queue.isEmpty else { return nil }
        isListening = true
        return current
    }

    /// 듣기 모드 종료(소스 소실·모드 전환·수동 점프 등에서 호출).
    func stop() { isListening = false }

    /// 수동 점프(chevron). 듣기 모드 중이면 충돌 방지를 위해 듣기를 멈춘다
    /// (사용자가 직접 운전대를 잡았으므로). 이동 후 인덱스로 갱신.
    func manualJump(_ delta: Int) {
        if isListening { isListening = false }
        index = Self.wrapped(index, by: delta, count: queue.count)
    }

    /// 한 단어 재생이 끝났을 때(LinePlayer가 경계 시각에서 정지) 호출. 듣기
    /// 모드일 때만 다음 단어로 전진하고, 끝에 도달하면 정지 후 nil 반환.
    /// 끝나지 않았으면 다음에 재생할 span 반환. 반환값을 뷰가 LinePlayer로
    /// 재생한다.
    @discardableResult
    func advance() -> ReviewSpan? {
        guard isListening else { return nil }
        guard !queue.isEmpty else { stop(); return nil }
        if index >= queue.count - 1 {     // 마지막 단어였음 → 깔끔히 종료
            isListening = false
            return nil
        }
        index += 1
        return current
    }
}
