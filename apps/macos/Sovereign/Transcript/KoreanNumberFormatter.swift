// KoreanNumberFormatter.swift — spelled-out Korean numbers → Arabic digits.
//
// Whisper writes numbers as Hangul ("천구백사십년", "열한시 삼십오분"); a live
// transcript reads better as digits ("1940년", "11시 35분"), and it also closes
// part of the CER gap to Qwen3-ASR (measured 2026-08-27 on FLEURS-ko: turbo
// 5.63% → 5.34% with this converter; the number-heavy segment 9.25% → 7.83%.
// Full validation + the refuted naive versions in docs/ENGINE_EVAL.md).
//
// Korean number words are dangerously ambiguous, which is why a naive converter
// made CER WORSE (5.63 → 6.56). The guards, tuned against real FLEURS-ko errors:
//   1. only unambiguous counters anchor a conversion; the ambiguous ones
//      (번/차/등/위/도/장/대 …) are dropped so 이번(this time) stays "이번".
//   2. a span (and its counter) is split by counter class:
//      · HARD date/time counters (년/월/일/시/분/초/시간/개월/년대) accept even a
//        single Sino digit — 팔월 → 8월, 오분 → 5분 — EXCEPT a bare "이", which is
//        also the determiner "this" (이 시기 must stay, not become "2시기");
//      · SOFT counters (명/원/세/살/호/개/퍼센트) need ≥2 Sino syllables or a
//        native word, so a lone 이/삼 + soft counter never fires.
//   3. a number span preceded by a Hangul letter OR a digit never fires — kills
//      관형사형 `~한` (소중한 일 → NOT "소중1일"), 계열/세포's 열/세, and the
//      digit-merge 1만 년 → NOT "110000년".
//
// Foundation-only + pure, unit-tests headless. Reference impl + the full A/B and
// the refuted v1–v4 variants: engine/metal/bench/wer_runs/ko_num5.py,
// docs/ENGINE_EVAL.md (turbo CER 5.63 → 5.30 on FLEURS-ko, no engine change).

import Foundation

public enum KoreanNumberFormatter {

    private static let sino: [Character: Int] = [
        "영": 0, "공": 0, "일": 1, "이": 2, "삼": 3, "사": 4, "오": 5,
        "육": 6, "륙": 6, "칠": 7, "팔": 8, "구": 9,
    ]
    private static let sinoUnit: [Character: Int] = ["십": 10, "백": 100, "천": 1000]
    private static let sinoBig: [Character: Int] = ["만": 10000, "억": 100_000_000]

    // (word, value) — longest matched first inside each group.
    private static let natTens: [(String, Int)] = [
        ("열", 10), ("스물", 20), ("스무", 20), ("서른", 30), ("마흔", 40),
        ("쉰", 50), ("예순", 60), ("일흔", 70), ("여든", 80), ("아흔", 90),
    ]
    private static let natOnes: [(String, Int)] = [
        ("한", 1), ("두", 2), ("세", 3), ("네", 4), ("다섯", 5),
        ("여섯", 6), ("일곱", 7), ("여덟", 8), ("아홉", 9),
    ]

    // Longest-first so each alternation prefers 년대 over 년, 시간 over 시, 개월
    // over 개/월, 퍼센트 over %.
    private static let hardCounters = "년대|개월|시간|년|월|일|시|분|초"
    private static let softCounters = "퍼센트|명|원|개|％|%|세|살|호"
    private static let allCounters = "\(hardCounters)|\(softCounters)"

    private static let sinoChars = "영공일이삼사오육륙칠팔구십백천만억"
    /// Hangul syllables that can follow "N시" when N시 is a time (guard 5).
    private static let timeContinuation: Set<String> = [
        "에", "까", "부", "반", "쯤", "경", "로", "전", "후", "넘", "정", "간", "마", "대", "께", "도",
    ]   // not 면/는/나/라/고/니/이 — the endings of 오시-/사시- (오시면, 오시는, 오시라고)
    private static let natTensAlt = "열|스물|스무|서른|마흔|쉰|예순|일흔|여든|아흔"
    private static let natOnesAlt = "한|두|세|네|다섯|여섯|일곱|여덟|아홉"

    // guard 3 = (?<![가-힣0-9]); the counter split is guard 2; the dropped
    // ambiguous counters are guard 1.
    private static let boundary = "(?<![가-힣0-9])"
    private static let sinoHardRegex = try! NSRegularExpression(
        pattern: "\(boundary)([\(sinoChars)]+?)\\s?(\(hardCounters))")
    private static let sinoSoftRegex = try! NSRegularExpression(
        pattern: "\(boundary)([\(sinoChars)]{2,}?)\\s?(\(softCounters))")
    private static let natRegex = try! NSRegularExpression(
        pattern: "\(boundary)((?:\(natTensAlt))?(?:\(natOnesAlt))?)\\s?(\(allCounters))")

    /// Convert every counter-anchored Korean number in `text` to digits.
    /// Non-Korean text is a no-op: the patterns only match Hangul number words.
    public static func format(_ text: String) -> String {
        var out = replace(text, sinoHardRegex) { span, counter in
            span == "이" ? nil : parseSino(span).map { "\($0)\(counter)" }
        }
        out = replace(out, sinoSoftRegex) { span, counter in
            parseSino(span).map { "\($0)\(counter)" }
        }
        return replace(out, natRegex) { span, counter in
            let (value, consumed) = parseNative(span)
            guard let value, consumed == span.count else { return nil }  // full-span only
            return "\(value)\(counter)"
        }
    }

    // MARK: - number parsing

    static func parseSino(_ s: String) -> Int? {
        var total = 0, section = 0, cur = 0
        for ch in s {
            if let d = sino[ch] { cur = d }
            else if let u = sinoUnit[ch] { section += (cur == 0 ? 1 : cur) * u; cur = 0 }
            else if let b = sinoBig[ch] {
                section += cur
                total += (section == 0 ? 1 : section) * b
                section = 0; cur = 0
            } else { return nil }
        }
        return total + section + cur
    }

    /// Returns the value and how many characters of `s` it consumed. A trailing
    /// mismatch (consumed < s.count) means `s` wasn't a clean native number.
    static func parseNative(_ s: String) -> (Int?, Int) {
        var value = 0, consumed = 0
        for (word, v) in natTens where s.hasPrefix(word) { value = v; consumed = word.count; break }
        let rest = String(s.dropFirst(consumed))
        for (word, v) in natOnes where rest.hasPrefix(word) { value += v; consumed += word.count; break }
        return consumed == 0 ? (nil, 0) : (value, consumed)
    }

    // MARK: - regex apply (right-to-left so replacement lengths never shift ranges)

    private static func replace(
        _ text: String, _ regex: NSRegularExpression,
        _ transform: (_ span: String, _ counter: String) -> String?
    ) -> String {
        let ns = text as NSString
        let matches = regex.matches(in: text, range: NSRange(location: 0, length: ns.length))
        guard !matches.isEmpty else { return text }
        var out = text
        for m in matches.reversed() {
            let span = ns.substring(with: m.range(at: 1))
            let counter = ns.substring(with: m.range(at: 2))
            // guard 4 (2026-09-11): the counter must END the word. "어서 오십시오."
            // (the polite imperative -십시오) matched 오십+시 and became
            // "어서 50시오." in a live session; a real time never runs
            // straight into 오/옵/십 ("5시 오분" has a space, "5시에/부터/까지/쯤"
            // are particles). Only these verb-ending syllables are refused.
            let end = m.range.location + m.range.length
            if end < ns.length {
                let next = ns.substring(with: NSRange(location: end, length: 1))
                if ["오", "옵", "십", "시"].contains(next) { continue }
                // guard 5 (2026-09-11): a SINGLE Sino digit before 시 is a time
                // only when what follows reads as one — end, space, punctuation
                // or a time particle. "놀러 오시면" (the honorific stem 오시-)
                // became "놀러 5시면" on a file transcript; 사시면, 일시적,
                // 구시가지, 사시사철 fail the same way. "오시에/까지/부터/반/쯤"
                // still convert.
                if counter == "시", span.count == 1,
                   let ch = next.unicodeScalars.first, (0xAC00...0xD7A3).contains(ch.value),
                   !Self.timeContinuation.contains(next) { continue }
            }
            guard !span.isEmpty, let repl = transform(span, counter),
                  let r = Range(m.range, in: out) else { continue }
            out.replaceSubrange(r, with: repl)
        }
        return out
    }
}
