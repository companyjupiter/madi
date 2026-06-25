// BrandLogo.swift — loads the Madi wordmark PNG bundled at Contents/Resources/logo_madi.png
// (swiftc build has no asset catalog, so resources are loaded by file path; see make_app.sh).

import SwiftUI

struct BrandLogo: View {
    let width: CGFloat

    var body: some View {
        if let url = Bundle.main.url(forResource: "logo_madi", withExtension: "png"),
           let image = NSImage(contentsOf: url) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: width)
        } else {
            Text("madi").font(Theme.Fonts.appTitle).foregroundStyle(Theme.Colors.brandMark)
        }
    }
}
