// SVGIcon.swift — loads a bundled .svg (Contents/Resources) as a resizable Image.
// The swiftc build has no asset catalog, so icons are loaded by file path (see
// make_app.sh, which copies Resources/*.svg into the bundle).
//
// Most icons are monochrome (stroke/fill "black") — rendered as adaptive TEMPLATE
// images tinted by `tint` so they invert in dark mode instead of vanishing on a
// dark panel. The few icons with baked colors (folder = indigo) opt out with
// `tint: nil` to keep their SVG colors.

import SwiftUI

struct SVGIcon: View {
    let name: String
    let size: CGFloat
    var tint: Color? = Theme.Colors.textPrimary   // nil = keep the SVG's baked colors

    private var nsImage: NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "svg"),
              let image = NSImage(contentsOf: url) else { return nil }
        image.isTemplate = (tint != nil)   // template → SwiftUI tints with foregroundStyle
        return image
    }

    var body: some View {
        Group {
            if let image = nsImage {
                if let tint {
                    Image(nsImage: image).resizable().interpolation(.high)
                        .renderingMode(.template).foregroundStyle(tint)
                } else {
                    Image(nsImage: image).resizable().interpolation(.high)
                }
            } else {
                Color.clear
            }
        }
        .frame(width: size, height: size)
    }
}
