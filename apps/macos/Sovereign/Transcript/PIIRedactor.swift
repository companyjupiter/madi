// PIIRedactor.swift — on-device PII masking for transcript exports. Pure,
// deterministic, Foundation-only (no SwiftUI/AppKit) so it joins SovereignCore
// and runs headless under `swift test`.
//
// The transcript never leaves the device, but the EXPORTED .md/.txt often does
// (email, shared drive). This pre-pass masks the obvious personal identifiers —
// email, phone, Korean mobile, Korean RRN (주민등록번호) — replacing each hit
// with a category tag ([이메일]/[전화]/[주민번호]/[번호]) so the shape stays
// readable without leaking the value.
//
// CONSERVATIVE BY DESIGN: it must not nuke ordinary meeting text. Plain years
// ("2026"), clock times ("14:00"), and short loose digit groups are left alone —
// only patterns with PII-grade structure (a phone-like separator/length, an RRN
// checksum-length, an @-domain) match. Order matters: the most specific
// patterns (RRN, email) run before the looser phone pattern so a 13-digit RRN is
// never mis-tagged as a phone number.

import Foundation

enum PIIRedactor {

    /// A detected PII span and the category tag that should replace it.
    struct Hit {
        let range: NSRange      // range in the ORIGINAL string (UTF-16 / NSString)
        let tag: String         // replacement, e.g. "[이메일]"
    }

    // ── Patterns ──────────────────────────────────────────────────────────────
    // Each is paired with its replacement tag. Evaluated in this order; earlier
    // (more specific) matches win and later patterns can't re-cover the same span.
    //
    // · email      — local@domain.tld, standard-ish, ASCII.
    // · rrn        — Korean 주민등록번호: 6 digits - 7 digits (e.g. 900101-1234567).
    //                Validate the date-ish head + the leading gender digit (1-4,5-8)
    //                so a random "123456-1234567" still matches structurally but a
    //                plain "123456-7" (too short) does not.
    // · koMobile   — 010 / 011 / 016-019, with - . or space separators, 3-4 + 4.
    // · phone      — generic 9-11 digit run with phone-grade separators, OR a
    //                parenthesized area code. Requires a separator or length so a
    //                bare "2026" / "1234" never matches.
    private struct Rule {
        let regex: NSRegularExpression
        let tag: String
    }

    private static func rx(_ p: String) -> NSRegularExpression {
        // All patterns are authored to compile; force-try is acceptable for static literals.
        try! NSRegularExpression(pattern: p, options: [.caseInsensitive])
    }

    // Word-boundary-ish guards use lookaround on digit runs so "12:00" / "2026"
    // (no phone separators, too short) are skipped. PCRE-style lookbehind/ahead
    // are supported by NSRegularExpression (ICU).
    private static let rules: [Rule] = [
        // EMAIL — run first; an email's local part can contain digits/dots.
        Rule(regex: rx(#"[A-Z0-9._%+\-]+@[A-Z0-9.\-]+\.[A-Z]{2,}"#),
             tag: "[이메일]"),

        // KOREAN RRN — 6 digits, separator, 7 digits. Head looks like YYMMDD,
        // first back digit is the gender/century code 1-8 (incl. foreigner 5-8).
        Rule(regex: rx(#"(?<![0-9])\d{2}(?:0[1-9]|1[0-2])(?:0[1-9]|[12]\d|3[01])[-]?[1-8]\d{6}(?![0-9])"#),
             tag: "[주민번호]"),

        // KOREAN MOBILE — 010/011/016/017/018/019, 3-4 then 4, sep = - . or space.
        Rule(regex: rx(#"(?<![0-9])01[016789][-.\s]?\d{3,4}[-.\s]?\d{4}(?![0-9])"#),
             tag: "[전화]"),

        // GENERIC PHONE — parenthesized area code OR a separated 9-11 digit run.
        // The separator/length requirement is what keeps "2026" and "14:00" safe.
        Rule(regex: rx(#"(?<![0-9])(?:\(0\d{1,2}\)[-.\s]?|0\d{1,2}[-.\s])\d{3,4}[-.\s]?\d{4}(?![0-9])"#),
             tag: "[번호]"),
    ]

    // ── Public API ──────────────────────────────────────────────────────────────

    /// Detect every PII span in `text`, non-overlapping, earliest-rule-wins.
    /// Returned hits are sorted by range location and never overlap.
    static func detect(_ text: String) -> [Hit] {
        guard !text.isEmpty else { return [] }
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var claimed: [NSRange] = []     // already-tagged spans (specific rules first)
        var hits: [Hit] = []

        func overlaps(_ r: NSRange) -> Bool {
            for c in claimed where NSIntersectionRange(c, r).length > 0 { return true }
            return false
        }

        for rule in rules {
            rule.regex.enumerateMatches(in: text, options: [], range: full) { m, _, _ in
                guard let m = m, m.range.length > 0 else { return }
                if overlaps(m.range) { return }       // a more-specific rule owns it
                claimed.append(m.range)
                hits.append(Hit(range: m.range, tag: rule.tag))
            }
        }
        return hits.sorted { $0.range.location < $1.range.location }
    }

    /// Mask all detected PII in `text`, replacing each span with its category tag.
    /// Idempotent on already-clean text (returns it unchanged). Replacement walks
    /// hits back-to-front so earlier NSRanges stay valid as the string mutates.
    static func redact(_ text: String) -> String {
        let hits = detect(text)
        guard !hits.isEmpty else { return text }
        let ns = NSMutableString(string: text)
        for h in hits.sorted(by: { $0.range.location > $1.range.location }) {
            ns.replaceCharacters(in: h.range, with: h.tag)
        }
        return ns as String
    }
}
