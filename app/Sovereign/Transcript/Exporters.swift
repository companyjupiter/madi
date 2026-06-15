// Exporters.swift — render a finalized transcript to Markdown / SRT.
// Markdown carries the interruption markers; matches the runner's saved-.md style.

import Foundation

enum Exporters {
    /// Markdown: low-confidence words become *italic* (markdown has no color) so
    /// the SAVED doc still flags exactly the words to double-check — the export
    /// keeps the live view's confidence signal instead of dropping it.
    static func markdown(_ lines: [Line], names: [Int: String] = [:]) -> String {
        var s = "# Transcript\n\n"
        s += "> *기울임* 표시된 단어는 인식 신뢰도가 낮습니다 — 검토 권장.\n\n"
        for l in lines {
            let who = names[l.speaker] ?? "Speaker \(l.speaker)"
            let body = renderWords(l.words)
            let mark = l.overlapSpeakers
                .map { " ⟨+\(names[$0] ?? "Speaker \($0)") 겹침⟩" }
                .joined()
            s += "- **[\(timecode(l.start))] \(who)** \(body)\(mark)\n"
        }
        return s
    }

    /// Join words; wrap below-threshold ones in markdown italics.
    private static func renderWords(_ words: [Word]) -> String {
        var s = ""
        for (i, w) in words.enumerated() {
            if i > 0, w.text.first.map({ !",.!?…".contains($0) }) ?? true { s += " " }
            let t = w.text.trimmingCharacters(in: .whitespaces)
            s += (w.conf < Theme.confThreshold && !t.isEmpty) ? "*\(t)*" : w.text
        }
        return s
    }

    /// Plain text: `[mm:ss] Speaker: text` per line — clean for pasting into
    /// docs/email, no markup.
    static func plainText(_ lines: [Line], names: [Int: String] = [:]) -> String {
        var s = ""
        for l in lines {
            let who = names[l.speaker] ?? "Speaker \(l.speaker)"
            s += "[\(timecode(l.start))] \(who): \(l.text)\n"
        }
        return s
    }

    /// Structured JSON: per-segment speaker/time/text/per-word conf + a speaker
    /// talk-time summary. For programmatic post-processing (the structured
    /// counterpart to the stdout event stream).
    static func json(_ lines: [Line], names: [Int: String] = [:]) -> String {
        let segs: [[String: Any]] = lines.map { l in
            [
                "speaker": l.speaker,
                "name": names[l.speaker] ?? "Speaker \(l.speaker)",
                "start": l.start, "end": l.end,
                "text": l.text,
                "overlap_speakers": l.overlapSpeakers,
                "words": l.words.map { ["text": $0.text, "t0": $0.t0, "t1": $0.t1, "conf": $0.conf] as [String: Any] },
            ]
        }
        var times: [Int: Double] = [:]
        for l in lines { times[l.speaker, default: 0] += max(0, l.end - l.start) }
        let speakers: [[String: Any]] = times.sorted { $0.value > $1.value }.map {
            ["speaker": $0.key, "name": names[$0.key] ?? "Speaker \($0.key)", "talk_seconds": $0.value]
        }
        let fillers = EditorCuts.fillers(lines)
        let fillerJSON: [[String: Any]] = fillers.map {
            ["start": $0.start, "end": $0.end, "text": $0.label] as [String: Any]
        }
        let silences = EditorCuts.silences(lines)
        let silenceJSON: [[String: Any]] = silences.map {
            ["start": $0.start, "end": $0.end] as [String: Any]
        }
        let tighten = EditorCuts.tighten(lines)
        let root: [String: Any] = [
            "segments": segs, "speakers": speakers,
            "fillers": fillerJSON,
            "filler_seconds": fillers.reduce(0) { $0 + $1.duration },
            "silences": silenceJSON,
            "silence_seconds": silences.reduce(0) { $0 + $1.duration },
            "tighten": [
                "cuts": tighten.count,
                "total_seconds": tighten.reduce(0) { $0 + $1.duration },
            ] as [String: Any],
            "chapters": EditorCuts.chapters(lines).map {
                ["start": $0.start, "title": $0.title] as [String: Any]
            },
            "retakes": EditorCuts.retakes(lines).map {
                [
                    "keep_start": $0.keepStart, "keep_text": $0.keepText,
                    "drops": $0.drops.map { ["start": $0.start, "end": $0.end] as [String: Any] },
                ] as [String: Any]
            },
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: root,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
              let str = String(data: data, encoding: .utf8) else { return "{}" }
        return str
    }

    // ── Caption-spec SRT / VTT ────────────────────────────────────────────────
    // Editors need subtitle-grade cues, not one giant block per speaker turn. We
    // re-flow the per-word timestamps into cues that obey broadcast/YouTube norms:
    //   · ≤ maxCharsPerLine per line, ≤ maxLines lines  (Netflix/BBC ~42×2)
    //   · reading speed ≤ maxCPS chars/second            (extend short cues)
    //   · min/max cue duration                           (1.0 s … 7.0 s)
    //   · break a new cue at a speaker change or a > gapBreak silence
    //   · never break mid-word; never overlap the next cue
    struct CaptionSpec {
        var maxCharsPerLine = 42
        var maxLines = 2
        var maxCPS = 17.0
        var minDur = 1.0
        var maxDur = 7.0
        var gapBreak = 1.0       // a silence longer than this starts a fresh cue
        var speakerLabels: Bool? = nil  // nil → auto (label only when >1 speaker)
    }

    struct CaptionCue { var start: Double; var end: Double; var lines: [String] }

    /// Re-flow word-level lines into caption-spec cues.
    static func captionCues(_ lines: [Line], names: [Int: String] = [:], spec: CaptionSpec = .init()) -> [CaptionCue] {
        let distinct = Set(lines.map { $0.speaker })
        let label = spec.speakerLabels ?? (distinct.count > 1)
        var cues: [CaptionCue] = []
        var prevSpeaker: Int? = nil

        for l in lines {
            let words = l.words.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
            if words.isEmpty { continue }
            let prefix = (label && l.speaker != prevSpeaker)
                ? "\(names[l.speaker] ?? "Speaker \(l.speaker)"): " : ""
            var pending: [Word] = []
            var firstCue = true

            func wrapped(_ ws: [Word], _ usePrefix: Bool) -> [String] {
                wordWrap((usePrefix ? prefix : "") + joinWords(ws), spec.maxCharsPerLine)
            }
            func flush() {
                guard !pending.isEmpty else { return }
                let ls = wrapped(pending, firstCue)
                var start = pending.first!.t0
                var end = pending.last!.t1
                if end < start { end = start }
                let chars = ls.reduce(0) { $0 + $1.count }
                let needed = Double(chars) / spec.maxCPS
                if end - start < max(spec.minDur, needed) {
                    end = start + min(max(spec.minDur, needed), spec.maxDur)
                }
                if end - start > spec.maxDur { end = start + spec.maxDur }
                if start < 0 { start = 0 }
                cues.append(CaptionCue(start: start, end: end, lines: ls))
                pending.removeAll()
                firstCue = false
            }

            for w in words {
                if let last = pending.last, w.t0 - last.t1 > spec.gapBreak { flush() }
                if wrapped(pending + [w], firstCue).count > spec.maxLines {
                    flush()
                    pending = [w]
                } else {
                    pending.append(w)
                }
            }
            flush()
            prevSpeaker = l.speaker
        }
        // No-overlap pass: clamp each cue's end to the next cue's start.
        for i in 0..<max(0, cues.count - 1) {
            if cues[i].end > cues[i + 1].start {
                cues[i].end = max(cues[i].start + 0.04, cues[i + 1].start)
            }
        }
        return cues
    }

    /// One-click "tighten" cut-list as CSV — the merged removable ranges
    /// (fillers + silences). Seconds-based so it feeds ffmpeg / Resolve / Premiere
    /// scripts and opens in any spreadsheet. Header documents the totals.
    static func cutListCSV(_ lines: [Line]) -> String {
        let cuts = EditorCuts.tighten(lines)
        let total = cuts.reduce(0) { $0 + $1.duration }
        var s = "# tighten cut-list — \(cuts.count) cuts, \(String(format: "%.1f", total))s removable\n"
        s += "start_sec,end_sec,duration_sec,kind,label\n"
        for c in cuts {
            s += String(format: "%.3f,%.3f,%.3f,%@,%@\n",
                        c.start, c.end, c.duration, c.kind, csvField(c.label))
        }
        return s
    }

    /// YouTube chapters: `m:ss Title` (or `h:mm:ss` past an hour), first at 0:00.
    static func youtubeChapters(_ lines: [Line]) -> String {
        var s = ""
        for c in EditorCuts.chapters(lines) { s += "\(ytTime(c.start)) \(c.title)\n" }
        return s
    }

    private static func ytTime(_ t: Double) -> String {
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60, sec = Int(t) % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec)
                     : String(format: "%d:%02d", m, sec)
    }

    private static func csvField(_ s: String) -> String {
        (s.contains(",") || s.contains("\"")) ? "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\"" : s
    }

    /// Caption-spec SRT (per-word re-flow). Replaces the old one-block-per-turn SRT.
    static func srt(_ lines: [Line], names: [Int: String] = [:], spec: CaptionSpec = .init()) -> String {
        var s = ""
        for (i, c) in captionCues(lines, names: names, spec: spec).enumerated() {
            s += "\(i + 1)\n"
            s += "\(srtTime(c.start)) --> \(srtTime(c.end))\n"
            s += c.lines.joined(separator: "\n") + "\n\n"
        }
        return s
    }

    /// Caption-spec WebVTT (`.` ms separator + `WEBVTT` header).
    static func vtt(_ lines: [Line], names: [Int: String] = [:], spec: CaptionSpec = .init()) -> String {
        var s = "WEBVTT\n\n"
        for (i, c) in captionCues(lines, names: names, spec: spec).enumerated() {
            s += "\(i + 1)\n"
            s += "\(vttTime(c.start)) --> \(vttTime(c.end))\n"
            s += c.lines.joined(separator: "\n") + "\n\n"
        }
        return s
    }

    /// Join words with the engine's spacing rule (no space before punctuation).
    private static func joinWords(_ words: [Word]) -> String {
        var s = ""
        for w in words {
            if !s.isEmpty, w.text.first.map({ !",.!?…".contains($0) }) ?? true { s += " " }
            s += w.text.trimmingCharacters(in: .whitespaces)
        }
        return s
    }

    /// Greedy word-wrap at spaces into lines ≤ maxLen (never splits a token).
    private static func wordWrap(_ text: String, _ maxLen: Int) -> [String] {
        var out: [String] = []
        var cur = ""
        for tok in text.split(separator: " ") {
            if cur.isEmpty { cur = String(tok) }
            else if cur.count + 1 + tok.count <= maxLen { cur += " " + tok }
            else { out.append(cur); cur = String(tok) }
        }
        if !cur.isEmpty { out.append(cur) }
        return out.isEmpty ? [""] : out
    }

    private static func timecode(_ t: Double) -> String {
        let m = Int(t) / 60, s = Int(t) % 60
        return String(format: "%02d:%02d", m, s)
    }

    private static func srtTime(_ t: Double) -> String {
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60, s = Int(t) % 60
        let ms = Int((t - t.rounded(.down)) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }

    private static func vttTime(_ t: Double) -> String {
        let h = Int(t) / 3600, m = (Int(t) % 3600) / 60, s = Int(t) % 60
        let ms = Int((t - t.rounded(.down)) * 1000)
        return String(format: "%02d:%02d:%02d.%03d", h, m, s, ms)
    }
}
