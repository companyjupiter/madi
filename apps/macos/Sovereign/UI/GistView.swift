// GistView.swift — the one-line "what was this meeting about" preview shown
// under a transcript .md filename in the workspace explorer. Reads the gist from
// the shared GistCache (mtime-memoised, parsed once) off the main thread so the
// explorer never re-parses on every render, then fades it in.
//
// Self-contained on purpose: it pulls everything it needs from GistCache.shared,
// so the explorer only has to drop `GistView(url: node.url)` under the filename —
// one integration line wires GistExtractor + GistCache into the @main graph.

import SwiftUI

struct GistView: View {
    let url: URL

    @State private var gist: String? = nil
    @State private var loaded = false

    var body: some View {
        Group {
            if let gist, !gist.isEmpty {
                Text(gist)
                    .font(Theme.Fonts.status)
                    .foregroundStyle(Theme.Colors.textTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .help(gist)
            }
        }
        .opacity(loaded ? 1 : 0)
        // OutlineGroup recycles a row's @State when it's reused for a DIFFERENT file.
        // Clear the previous file's gist immediately on URL change so the stale text
        // doesn't flicker through until .task(id:) re-runs and repopulates it.
        .onChange(of: url) { _, _ in gist = nil; loaded = false }
        // Re-run whenever the row is reused for a different file.
        .task(id: url) {
            // Read + parse off the main thread; cache memoises by mtime so this
            // is a cheap dictionary hit after the first read.
            let resolved = await Task.detached(priority: .utility) {
                GistCache.shared.gist(for: url)
            }.value
            await MainActor.run {
                gist = resolved
                withAnimation(.easeIn(duration: 0.15)) { loaded = true }
            }
        }
    }
}
