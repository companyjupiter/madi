// SVGIcon.swift — loads a bundled .svg (Contents/Resources) as a resizable Image.
// The swiftc build has no asset catalog, so icons are loaded by file path (see
// make_app.sh, which copies Resources/*.svg into the bundle). Colors/opacity are
// baked into the SVGs, so isTemplate is forced off to preserve them.

import SwiftUI

struct SVGIcon: View {
    let name: String
    let size: CGFloat

    private var nsImage: NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = false
        return image
    }

    var body: some View {
        Group {
            if let image = nsImage {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
    }
}
