// SummaryDeck.swift — render the on-device meeting summary as a self-contained,
// presentation-style HTML deck (no external assets/JS libs; works offline, opens
// in any browser, prints to PDF). Pure (Foundation only) → unit-tested.
//
// The summary text is the structured [요약]/[액션]/[결정] block (model output);
// it's parsed tolerantly into sections → one slide each, plus a title slide and
// (optional) per-speaker slide from the 화자별 breakdown.

import Foundation

enum SummaryDeck {

    struct Section { let title: String; let bullets: [String]; let paras: [String] }

    /// Build the full HTML document. `title` is the meeting name, `dateText` the
    /// display date; `speakerSummary` (■ 이름: …) is appended as a slide if present.
    static func html(summary: String, speakerSummary: String?, title: String, dateText: String) -> String {
        var slides: [String] = []
        // title slide
        slides.append("""
            <section class="slide title">
              <div class="brand">◍ Madi · 온디바이스 생성</div>
              <h1>\(esc(title))</h1>
              <div class="date">\(esc(dateText))</div>
            </section>
            """)
        for sec in parseSections(summary) { slides.append(slideHTML(sec)) }
        if let sp = speakerSummary, !sp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            slides.append(speakerSlideHTML(sp))
        }
        let body = slides.joined(separator: "\n")
        return document(title: title, dateText: dateText, slidesHTML: body, count: slides.count)
    }

    /// Default filename `summary-YYYY-MM-DD-<n>.html`; n is the first integer that
    /// doesn't collide in `dir`.
    static func filename(in dir: URL, date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.calendar = calendar
        let d = f.string(from: date)
        var n = 1
        let fm = FileManager.default
        while fm.fileExists(atPath: dir.appendingPathComponent("summary-\(d)-\(n).html").path) { n += 1 }
        return "summary-\(d)-\(n).html"
    }

    // ── parsing ──────────────────────────────────────────────────────────────
    // Derived from the section registry (SummaryTemplate.swift) — the single
    // source of tag rules, shared with RecapData + OpenLoopsAggregator. Registry
    // order IS matching precedence (legacy 요약/액션/결정 first).
    private static let headers: [(canon: String, keys: [String])] =
        SummarySection.registry.map { ($0.canon, $0.aliases) }

    /// Split tolerant of the model's formatting (brackets, **bold**, headings).
    static func parseSections(_ text: String) -> [Section] {
        var out: [(String, [String], [String])] = []
        var curTitle = "요약"; var bullets: [String] = []; var paras: [String] = []
        var started = false
        func flush() {
            if started || !bullets.isEmpty || !paras.isEmpty {
                out.append((curTitle, bullets, paras))
            }
            bullets = []; paras = []
        }
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }
            if let h = matchHeader(line) {
                flush(); curTitle = h.canon; started = true
                // a header line can carry inline content after the marker
                if let rest = inlineAfterHeader(line), !rest.isEmpty { paras.append(rest) }
                continue
            }
            if let b = bulletText(line) { bullets.append(b) } else { paras.append(stripMarks(line)) }
        }
        flush()
        return out.map { Section(title: $0.0, bullets: $0.1, paras: $0.2) }
            .filter { !$0.bullets.isEmpty || !$0.paras.isEmpty }
    }

    private static func matchHeader(_ line: String) -> (canon: String, key: String)? {
        let low = stripMarks(line).lowercased()
        for h in headers {
            for k in h.keys where low.hasPrefix(k) || low.hasPrefix("[\(k)]") {
                return (h.canon, k)
            }
        }
        return nil
    }
    private static func inlineAfterHeader(_ line: String) -> String? {
        // "[요약] 내용…" → "내용…"
        if let close = line.firstIndex(of: "]") { return String(line[line.index(after: close)...]).trimmingCharacters(in: .whitespaces) }
        return nil
    }
    private static func bulletText(_ line: String) -> String? {
        for m in ["- ", "* ", "• ", "■ ", "● ", "▪ ", "· "] where line.hasPrefix(m) {
            return String(line.dropFirst(m.count)).trimmingCharacters(in: .whitespaces)
        }
        return nil
    }
    private static func stripMarks(_ s: String) -> String {
        s.replacingOccurrences(of: "**", with: "")
            .replacingOccurrences(of: "#", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: " \t*#[]:"))
    }

    // ── per-section slide ──────────────────────────────────────────────────────
    private static func slideHTML(_ s: Section) -> String {
        var inner = ""
        for p in s.paras { inner += "<p>\(esc(p))</p>\n" }
        if !s.bullets.isEmpty {
            // action-kind sections (액션 아이템 + 후속 조치) render as checklists.
            let isAction = SummarySection.kind(forCanon: s.title) == .action
            inner += "<ul class=\"\(isAction ? "checklist" : "")\">\n"
            for b in s.bullets { inner += "<li>\(esc(b))</li>\n" }
            inner += "</ul>\n"
        }
        return "<section class=\"slide\">\n<h2>\(esc(s.title))</h2>\n\(inner)</section>"
    }

    private static func speakerSlideHTML(_ sp: String) -> String {
        var items = ""
        for raw in sp.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            let t = line.hasPrefix("■") ? String(line.dropFirst()).trimmingCharacters(in: .whitespaces) : line
            items += "<li>\(esc(t))</li>\n"
        }
        return "<section class=\"slide\">\n<h2>화자별</h2>\n<ul class=\"speakers\">\n\(items)</ul>\n</section>"
    }

    private static func esc(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    // ── document shell (inline CSS + minimal arrow-key nav, Warm Focus palette) ──
    private static func document(title: String, dateText: String, slidesHTML: String, count: Int) -> String {
        """
        <!doctype html>
        <html lang="ko"><head>
        <meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>회의 요약 — \(esc(title))</title>
        <style>
          :root{ --accent:#5A67D8; --ink:#1c1c1e; --muted:#6b6b73; --bg:#f7f7fb; --card:#fff; }
          @media (prefers-color-scheme: dark){ :root{ --ink:#f2f2f7; --muted:#a0a0a8; --bg:#16161a; --card:#1f1f25; } }
          *{ box-sizing:border-box; margin:0; }
          html,body{ height:100%; }
          body{ font-family:-apple-system,"Apple SD Gothic Neo","Pretendard",system-ui,sans-serif;
                 background:var(--bg); color:var(--ink); }
          .deck{ height:100vh; overflow-y:scroll; scroll-snap-type:y mandatory; scroll-behavior:smooth; }
          .slide{ min-height:100vh; scroll-snap-align:start; display:flex; flex-direction:column;
                   justify-content:center; padding:8vw 9vw; gap:0.6em; }
          .slide h2{ font-size:clamp(28px,5vw,52px); font-weight:800; color:var(--accent);
                     letter-spacing:-0.02em; margin-bottom:0.3em; }
          .slide p{ font-size:clamp(18px,2.6vw,30px); line-height:1.55; max-width:32ch; color:var(--ink); }
          .slide ul{ list-style:none; display:flex; flex-direction:column; gap:0.55em; }
          .slide li{ font-size:clamp(17px,2.3vw,27px); line-height:1.5; padding-left:1.4em; position:relative; }
          .slide li::before{ content:"•"; color:var(--accent); position:absolute; left:0; font-weight:800; }
          ul.checklist li::before{ content:"☐"; }
          ul.speakers li::before{ content:"●"; }
          .title{ align-items:flex-start; }
          .title .brand{ font-size:15px; color:var(--muted); letter-spacing:0.04em; margin-bottom:1.2em; }
          .title h1{ font-size:clamp(36px,7vw,72px); font-weight:850; letter-spacing:-0.03em; line-height:1.1; }
          .title .date{ margin-top:0.6em; font-size:clamp(16px,2.4vw,24px); color:var(--muted); }
          nav{ position:fixed; bottom:18px; right:22px; display:flex; gap:10px; align-items:center;
               font-size:13px; color:var(--muted); background:var(--card); padding:7px 12px;
               border-radius:999px; box-shadow:0 2px 12px rgba(0,0,0,.12); user-select:none; }
          nav button{ border:0; background:var(--accent); color:#fff; width:26px; height:26px;
                       border-radius:50%; cursor:pointer; font-size:14px; line-height:1; }
          @media print{ .deck{ height:auto; overflow:visible; } .slide{ min-height:auto; page-break-after:always; padding:6vw; } nav{ display:none; } }
        </style></head>
        <body>
          <main class="deck" id="deck">
        \(slidesHTML)
          </main>
          <nav><button id="prev">↑</button><span id="pos">1 / \(count)</span><button id="next">↓</button></nav>
          <script>
            const deck=document.getElementById('deck'), slides=[...deck.children], pos=document.getElementById('pos');
            let i=0;
            function go(n){ i=Math.max(0,Math.min(slides.length-1,n)); slides[i].scrollIntoView({behavior:'smooth'}); pos.textContent=(i+1)+' / '+slides.length; }
            document.getElementById('next').onclick=()=>go(i+1);
            document.getElementById('prev').onclick=()=>go(i-1);
            addEventListener('keydown',e=>{ if(e.key==='ArrowDown'||e.key==='ArrowRight'||e.key===' '){e.preventDefault();go(i+1);} if(e.key==='ArrowUp'||e.key==='ArrowLeft'){e.preventDefault();go(i-1);} });
            deck.addEventListener('scroll',()=>{ const n=Math.round(deck.scrollTop/innerHeight); if(n!==i){i=n; pos.textContent=(i+1)+' / '+slides.length;} },{passive:true});
          </script>
        </body></html>
        """
    }
}
