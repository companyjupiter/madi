// LiveActionRail.swift — pure parse + prompt for the live "action rail": during a
// meeting the on-device LLM periodically reads the recent transcript and extracts
// decisions / action items (with owner) / open questions, which fill a side rail
// in real time. Foundation-only (→ SovereignCore + XCTest); the engine call +
// throttling + the 16 GB hardware gate live in SessionController.

import Foundation

struct RailItem: Identifiable, Hashable {
    enum Kind: String, CaseIterable { case decision = "결정", action = "액션", question = "질문" }
    let kind: Kind
    let owner: String?      // action items: who owns it (nil otherwise)
    let text: String
    /// Content-derived id so re-extraction of an unchanged item keeps its identity
    /// (SwiftUI doesn't re-animate the whole rail every refresh).
    var id: String { "\(kind.rawValue)|\(owner ?? "")|\(text)" }
}

enum LiveActionRail {
    /// The extraction prompt over a recent transcript window. Asks for one item
    /// per line in a fixed, parseable shape; "없음" when nothing actionable yet.
    static func prompt(_ transcript: String) -> String {
        "다음 회의 전사에서 (1) 결정된 사항, (2) 해야 할 일과 담당자, (3) 미결 질문을 추출하세요. "
        + "각 항목을 정확히 한 줄씩, 다음 형식으로만 답하세요:\n"
        + "[결정] 내용\n[액션] 담당자 · 내용\n[질문] 내용\n"
        + "해당 항목이 없으면 그 줄은 생략하세요. 추출할 게 전혀 없으면 '없음'이라고만 답하세요.\n\n전사:\n"
        + transcript
    }

    private static let line = try! NSRegularExpression(pattern: #"^\s*\[(결정|액션|질문)\]\s*(.+?)\s*$"#)

    /// Parse the LLM reply into rail items. Lines not matching the tagged shape
    /// (and a bare "없음") are ignored. Action items split "담당자 · 내용".
    static func parse(_ reply: String) -> [RailItem] {
        var out: [RailItem] = []
        var seen = Set<String>()
        for raw in reply.components(separatedBy: .newlines) {
            let r = NSRange(raw.startIndex..<raw.endIndex, in: raw)
            guard let m = line.firstMatch(in: raw, range: r),
                  let kr = Range(m.range(at: 1), in: raw),
                  let br = Range(m.range(at: 2), in: raw) else { continue }
            guard let kind = RailItem.Kind(rawValue: String(raw[kr])) else { continue }
            let body = String(raw[br]).trimmingCharacters(in: .whitespaces)
            guard !body.isEmpty else { continue }

            var owner: String? = nil
            var text = body
            if kind == .action {
                // "이수민 · 부하 테스트…" → owner "이수민", text "부하 테스트…"
                for sep in [" · ", " — ", " - ", ": "] where body.contains(sep) {
                    let parts = body.components(separatedBy: sep)
                    if parts.count >= 2, parts[0].count <= 20 {
                        owner = parts[0].trimmingCharacters(in: .whitespaces)
                        text = parts.dropFirst().joined(separator: sep).trimmingCharacters(in: .whitespaces)
                    }
                    break
                }
            }
            let item = RailItem(kind: kind, owner: owner, text: text)
            if seen.insert(item.id).inserted { out.append(item) }
        }
        return out
    }
}
