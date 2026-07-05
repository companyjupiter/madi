// BrandLogo.swift — loads the Madi wordmark PNG bundled at Contents/Resources/logo_madi.png
// (swiftc build has no asset catalog, so resources are loaded by file path; see make_app.sh).

import SwiftUI

struct BrandLogo: View {
    let width: CGFloat

    var body: some View {
        if let url = Bundle.main.url(forResource: "logo_madi", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            // The wordmark PNG is solid black on transparent — render it as a
            // template tinted by textPrimary so it stays black in light mode but
            // turns near-white in dark (a raw black PNG vanishes on a dark card).
            let templ = { image.isTemplate = true; return image }()
            Image(nsImage: templ)
                .renderingMode(.template)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: width)
                .foregroundStyle(Theme.Colors.textPrimary)
        } else {
            Text("madi").font(Theme.Fonts.appTitle).foregroundStyle(Theme.Colors.brandMark)
        }
    }
}
