// TranscriptReconciler.swift — pure (Foundation-only) core of the post-session
// LLM correction pass (2026-07-05). Speaker diarization (voice embeddings) and
// language locking sometimes fail in ways the ENGINE can't fix but a language
// model reading the DIALOGUE can:
//   • the same person split across two speaker ids (over-segmentation)
//   • a line attributed to the wrong speaker (a patient's answer tagged as staff)
//   • a line decoded in the wrong language → transliteration garble
//
// The LLM sees TEXT only (never audio), so it can reason about turn-taking and
// role but NOT about acoustic boundaries or a genuinely misheard word. This file
// owns the deterministic, testable parts: building the prompt input, and parsing
// the model's reply into a CONSERVATIVE, validated correction plan. Anything
// malformed or out-of-range is dropped — the 4B model's output is untrusted.
//
// Applying the plan (relabel speakers / re-transcribe flagged lines) is done by
// the caller against the live transcript, non-destructively and reversibly.

import Foundation

/// One correction the model may propose.
enum Correction: Equatable {
    case merge(from: Int, into: Int)          // speaker `from` is the same person as `into`
    case relabel(line: Int, speaker: Int)     // line index (0-based) belongs to `speaker`
    case language(line: Int, lang: String)    // line index is garbled; real language name
}

struct ReconcilePlan: Equatable {
    var merges: [Correction] = []             // .merge only
    var relabels: [Correction] = []           // .relabel only
    var languageFlags: [Correction] = []      // .language only
    var isEmpty: Bool { merges.isEmpty && relabels.isEmpty && languageFlags.isEmpty }
}

enum TranscriptReconciler {
    /// Whisper language tokens the model may name, keyed by short code + English.
    static let langByCode: [String: String] = [
        "ko": "Korean", "korean": "Korean", "한국어": "Korean",
        "en": "English", "english": "English", "영어": "English",
        "ja": "Japanese", "japanese": "Japanese", "일본어": "Japanese",
        "zh": "Chinese", "chinese": "Chinese", "중국어": "Chinese",
    ]

    /// The numbered, speaker-labeled transcript the model reads. `speakerName`
    /// maps a speaker id to its display name (e.g. "화자 1" or "김부장").
    /// `uncertain` marks lines whose acoustic speaker-margin was low (S2) —
    /// they get a △ so the model knows which attributions are fair game.
    static func promptInput(lines: [(speaker: Int, text: String)],
                            speakerName: (Int) -> String,
                            uncertain: Set<Int> = []) -> String {
        var out = ""
        for (i, l) in lines.enumerated() {
            let mark = uncertain.contains(i) ? "△" : ""
            out += "\(i + 1)\(mark) [S\(l.speaker)·\(speakerName(l.speaker))] \(l.text)\n"
        }
        return out
    }

    /// The single-line instruction wrapping the transcript. Kept terse and
    /// example-anchored so the 4B follows the command grammar.
    static func instruction() -> String {
        return "다음은 화자별로 라벨된 대화 전사다. △ 표시 줄은 화자 판정이 불확실한 줄이다. 명백히 잘못된 것만 아래 문법으로 한 줄씩 교정하라. "
            + "확실하지 않으면 아무것도 출력하지 마라. 문법: "
            + "MERGE <화자A> <화자B> (같은 사람이면 B를 A로 합침) / "
            + "RELABEL <줄번호> <화자> (그 줄이 다른 화자면) / "
            + "LANG <줄번호> <ko|en|ja|zh> (그 줄이 다른 언어인데 잘못 받아써졌으면). "
            + "예: MERGE 1 3 / RELABEL 5 2 / LANG 4 ja. 교정 없으면 OK 한 줄."
    }

    /// Parse the model reply into a validated plan.
    /// `speakers` = the set of speaker ids that actually exist; `lineCount` = the
    /// number of transcript lines. Out-of-range or malformed commands are dropped.
    /// `maxCorrections` caps the total accepted (a sane bound against a model that
    /// tries to rewrite everything).
    /// `relabelAllowed` (S3 fusion gate): when non-nil, RELABEL is accepted ONLY
    /// for these 0-based line indices — the acoustically-confident lines cannot
    /// be flipped by dialogue context alone.
    static func parse(_ reply: String, speakers: Set<Int>, lineCount: Int,
                      maxCorrections: Int = 24, relabelAllowed: Set<Int>? = nil) -> ReconcilePlan {
        var plan = ReconcilePlan()
        var mergedAway = Set<Int>()   // ids already merged into another (avoid chains/cycles)
        var relabeled = Set<Int>()    // line indices already relabeled (first wins)
        var langged = Set<Int>()      // line indices already language-flagged
        var accepted = 0

        // Split on BOTH newlines and "/" — the 4B often echoes the example's
        // "MERGE 1 3 / RELABEL 5 2" slash-joined form onto a single line.
        let segments = reply.split(whereSeparator: { $0.isNewline || $0 == "/" })
        for rawLine in segments {
            if accepted >= maxCorrections { break }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty || line.uppercased() == "OK" { continue }
            let toks = line.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
            guard toks.count >= 3 else { continue }
            let cmd = toks[0].uppercased()

            switch cmd {
            case "MERGE":
                guard let a = Int(toks[1]), let b = Int(toks[2]),
                      a != b, speakers.contains(a), speakers.contains(b),
                      !mergedAway.contains(a), !mergedAway.contains(b) else { continue }
                // merge the higher id into the lower (deterministic, id-stable)
                let into = min(a, b), from = max(a, b)
                mergedAway.insert(from)
                plan.merges.append(.merge(from: from, into: into))
                accepted += 1
            case "RELABEL":
                guard let n = Int(toks[1]), let sp = Int(toks[2]),
                      n >= 1, n <= lineCount, speakers.contains(sp),
                      !relabeled.contains(n - 1),
                      relabelAllowed?.contains(n - 1) ?? true else { continue }
                relabeled.insert(n - 1)
                plan.relabels.append(.relabel(line: n - 1, speaker: sp))
                accepted += 1
            case "LANG":
                guard let n = Int(toks[1]), n >= 1, n <= lineCount,
                      let lang = langByCode[toks[2].lowercased()],
                      !langged.contains(n - 1) else { continue }
                langged.insert(n - 1)
                plan.languageFlags.append(.language(line: n - 1, lang: lang))
                accepted += 1
            default:
                continue
            }
        }
        return plan
    }

    /// Whisper language token id for a language name (for Phase-2 re-transcription).
    static func languageToken(_ name: String) -> Int? {
        switch name {
        case "Korean": return 50264
        case "English": return 50259
        case "Japanese": return 50266
        case "Chinese": return 50260
        default: return nil
        }
    }
}
