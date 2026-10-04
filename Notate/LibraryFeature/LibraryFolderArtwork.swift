import SwiftUI
import UIKit

/// The source artwork measures 584 × 436. Every layer uses that coordinate
/// system, keeping the tab, paper insets, and corner proportions at any size.
struct LibraryFolderArtwork: View {
    let symbolName: String
    let color: Color
    var title: String? = nil
    var itemCount: Int? = nil
    var showsBackdrop = true
    var placesGlyphOnFront = false
    var previewItems: [LibraryFolderPreviewItem] = []
    var thumbnailStore: LibraryAutomaticThumbnailStore = .shared

    var body: some View {
        GeometryReader { geometry in
            let aspect = NotateDesign.Library.Shelf.folderAspectRatio
            let width = min(geometry.size.width * NotateDesign.Library.Shelf.folderWidthFraction,
                            max(0, geometry.size.height - 2) * aspect)
            let height = width / aspect
            ZStack {
                if showsBackdrop {
                    Color(uiColor: .secondarySystemGroupedBackground)
                }
                LibraryFolderSurface(
                    symbolName: symbolName,
                    color: color,
                    hasContents: (itemCount ?? 0) > 0 || !previewItems.isEmpty
                )
                .frame(width: width, height: height)
                .position(x: geometry.size.width / 2,
                          y: geometry.size.height - 2 - height / 2)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The folder's appearance is independent of the shelf layout and persistence.
/// A paper stack is a presence indicator; empty folders draw no paper layers.
struct LibraryFolderSurface: View {
    let symbolName: String
    let color: Color
    let hasContents: Bool

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let palette = LibraryFolderArtworkPalette(color: color, colorScheme: colorScheme)
        let glyphColor = hasContents ? palette.glyph : palette.emptyGlyph
        GeometryReader { geometry in
            ZStack {
                LibraryFolderShell(palette: palette, hasContents: hasContents)
                LibraryFolderEmbeddedSymbol(
                    symbolName: symbolName,
                    color: glyphColor,
                    usesLightEtching: palette.isBlue
                )
                .frame(width: geometry.size.width * 0.42,
                       height: geometry.size.height * 0.36)
                .position(x: geometry.size.width * 0.50,
                          y: geometry.size.height * 0.61)
                // The same surface reflection crosses the symbol and shell,
                // placing the pigment within the frosted front panel.
                LibraryFolderPocketShape()
                    .fill(LinearGradient(
                        colors: [.white.opacity(0.07), .clear, palette.backTop.opacity(0.035)],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
            }
            .compositingGroup()
        }
        .accessibilityHidden(true)
    }
}

/// Uses the exact SF Symbol name saved by the creation/appearance picker.
/// The symbol's tint blends with the folder rather than gaining a badge surface.
private struct LibraryFolderEmbeddedSymbol: View {
    let symbolName: String
    let color: Color
    let usesLightEtching: Bool

    var body: some View {
        Image(systemName: symbolName)
            .resizable()
            .scaledToFit()
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(LinearGradient(
                colors: [color, color.opacity(0.78)],
                startPoint: .top, endPoint: .bottom
            ))
            .opacity(usesLightEtching ? 0.72 : 0.46)
            .blendMode(usesLightEtching ? .screen : .multiply)
    }
}

private struct LibraryFolderShell: View {
    let palette: LibraryFolderArtworkPalette
    let hasContents: Bool

    var body: some View {
        Canvas { context, size in
            let scale = size.width / 584
            context.scaleBy(x: scale, y: size.height / 436)
            let rect = CGRect(x: 0, y: 0, width: 584, height: 436)
            let back = LibraryFolderBackShape().path(in: rect)
            let front = LibraryFolderPocketShape().path(in: rect)
            context.clip(to: back)
            context.fill(back, with: .linearGradient(
                Gradient(colors: [palette.backTop, palette.backBottom]),
                startPoint: .zero, endPoint: CGPoint(x: 0, y: 436)
            ))

            if hasContents {
                // Three exposed edges at (44,43), (60,59), and (78,76)
                // correspond to the sheets in the supplied reference.
                context.drawLayer { exposed in
                    exposed.clip(to: front, options: .inverse)
                    drawPapers(in: &exposed)
                }
                context.drawLayer { frosted in
                    frosted.clip(to: front)
                    frosted.addFilter(.blur(radius: 10 * scale))
                    drawPapers(in: &frosted)
                }
                // Frost scatters the sheets' light, softening their interior
                // edges while their exposed top edges remain crisp.
                context.drawLayer { light in
                    light.clip(to: front)
                    light.addFilter(.blur(radius: 18 * scale))
                    light.fill(Path(CGRect(x: 44, y: 94, width: 510, height: 320)),
                               with: .color(palette.paper.opacity(0.20)))
                }
            }

            context.fill(front, with: .linearGradient(
                Gradient(stops: [
                    .init(color: palette.frontTop, location: 0),
                    .init(color: palette.frontMiddle, location: 0.35),
                    .init(color: palette.frontMiddle, location: 0.84),
                    .init(color: palette.frontBottom, location: 1),
                ]), startPoint: .zero, endPoint: CGPoint(x: 0, y: 436)
            ))
            context.drawLayer { sheen in
                sheen.clip(to: front)
                sheen.fill(front, with: .linearGradient(
                    Gradient(stops: [
                        .init(color: .white.opacity(0.12), location: 0),
                        .init(color: .clear, location: 0.10),
                        .init(color: .clear, location: 0.86),
                        .init(color: .white.opacity(0.08), location: 1),
                    ]), startPoint: .zero, endPoint: CGPoint(x: 584, y: 0)
                ))
                if hasContents {
                    sheen.addFilter(.blur(radius: 16 * scale))
                    sheen.fill(Path(CGRect(x: 55, y: 315, width: 475, height: 95)),
                               with: .color(palette.paper.opacity(0.28)))
                }
            }
            context.stroke(back, with: .color(.white.opacity(0.40)), lineWidth: 1)
            context.stroke(front, with: .color(.white.opacity(0.25)), lineWidth: 1)
        }
    }

    private func drawPapers(in context: inout GraphicsContext) {
        for sheet in LibraryFolderPaperLayer.allCases {
            var rect = sheet.rect
            if !palette.isBlue {
                rect.origin.x = sheet == .back ? 43 : sheet == .middle ? 56 : 71
            }
            context.fill(paperPath(rect, radius: sheet == .back ? 7 : 1), with: .linearGradient(
                Gradient(colors: [palette.paper.opacity(sheet.opacity),
                                  palette.paper.opacity(sheet.opacity * 0.92)]),
                startPoint: CGPoint(x: 0, y: rect.minY), endPoint: CGPoint(x: 0, y: 436)
            ))
        }
    }

    private func paperPath(_ rect: CGRect, radius: CGFloat) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: 436))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addQuadCurve(to: CGPoint(x: rect.minX + radius, y: rect.minY),
                          control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + radius),
                          control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: 436))
        path.closeSubpath()
        return path
    }
}

private enum LibraryFolderPaperLayer: CaseIterable {
    case back, middle, front

    var rect: CGRect {
        switch self {
        case .back: CGRect(x: 44, y: 43, width: 476, height: 393)
        case .middle: CGRect(x: 60, y: 59, width: 476, height: 377)
        case .front: CGRect(x: 78, y: 76, width: 476, height: 360)
        }
    }

    var opacity: Double {
        switch self {
        case .back: 0.30
        case .middle: 0.50
        case .front: 0.90
        }
    }
}

private struct LibraryFolderBackShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 48))
        path.addCurve(to: CGPoint(x: 48, y: 0), control1: CGPoint(x: 0, y: 21.5),
                      control2: CGPoint(x: 21.5, y: 0))
        path.addLine(to: CGPoint(x: 536, y: 0))
        path.addCurve(to: CGPoint(x: 584, y: 48), control1: CGPoint(x: 562.5, y: 0),
                      control2: CGPoint(x: 584, y: 21.5))
        path.addLine(to: CGPoint(x: 584, y: 388))
        path.addCurve(to: CGPoint(x: 536, y: 436), control1: CGPoint(x: 584, y: 414.5),
                      control2: CGPoint(x: 562.5, y: 436))
        path.addLine(to: CGPoint(x: 48, y: 436))
        path.addCurve(to: CGPoint(x: 0, y: 388), control1: CGPoint(x: 21.5, y: 436),
                      control2: CGPoint(x: 0, y: 414.5))
        path.closeSubpath()
        return path.applying(CGAffineTransform(a: rect.width / 584, b: 0, c: 0,
                                             d: rect.height / 436, tx: rect.minX, ty: rect.minY))
    }
}

private struct LibraryFolderPocketShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: 0, y: 142))
        path.addCurve(to: CGPoint(x: 48, y: 94), control1: CGPoint(x: 0, y: 115.5),
                      control2: CGPoint(x: 21.5, y: 94))
        path.addLine(to: CGPoint(x: 328, y: 94))
        path.addCurve(to: CGPoint(x: 376, y: 48), control1: CGPoint(x: 354.5, y: 94),
                      control2: CGPoint(x: 376, y: 74.5))
        path.addCurve(to: CGPoint(x: 424, y: 0), control1: CGPoint(x: 376, y: 21.5),
                      control2: CGPoint(x: 397.5, y: 0))
        path.addLine(to: CGPoint(x: 536, y: 0))
        path.addCurve(to: CGPoint(x: 584, y: 48), control1: CGPoint(x: 562.5, y: 0),
                      control2: CGPoint(x: 584, y: 21.5))
        path.addLine(to: CGPoint(x: 584, y: 388))
        path.addCurve(to: CGPoint(x: 536, y: 436), control1: CGPoint(x: 584, y: 414.5),
                      control2: CGPoint(x: 562.5, y: 436))
        path.addLine(to: CGPoint(x: 48, y: 436))
        path.addCurve(to: CGPoint(x: 0, y: 388), control1: CGPoint(x: 21.5, y: 436),
                      control2: CGPoint(x: 0, y: 414.5))
        path.closeSubpath()
        return path.applying(CGAffineTransform(a: rect.width / 584, b: 0, c: 0,
                                             d: rect.height / 436, tx: rect.minX, ty: rect.minY))
    }
}

private struct LibraryFolderArtworkPalette {
    let base: UIColor
    let isBlue: Bool

    init(color: Color, colorScheme: ColorScheme) {
        let traits = UITraitCollection(userInterfaceStyle: colorScheme == .dark ? .dark : .light)
        let input = UIColor(color).resolvedColor(with: traits)
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        input.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        isBlue = saturation > 0.15 && (0.48...0.67).contains(hue)
        if isBlue {
            base = UIColor(hue: 0.568 + (hue - 0.60) * 0.25,
                           saturation: 0.46, brightness: 0.906, alpha: 1)
        } else if saturation > 0.15 && (0.67...0.82).contains(hue) {
            base = UIColor(hue: 0.720 + (hue - 0.73) * 0.30,
                           saturation: 0.41, brightness: 0.65, alpha: 1)
        } else {
            base = UIColor(hue: hue, saturation: saturation * 0.65,
                           brightness: 0.78 + brightness * 0.12, alpha: 1)
        }
    }

    var backTop: Color { Color(uiColor: base) }
    var backBottom: Color { mixed(with: .black, fraction: 0.04) }
    var paper: Color {
        isBlue ? Color(red: 0.94, green: 0.99, blue: 1)
            : Color(red: 1, green: 0.94, blue: 0.98)
    }
    var frontTop: Color { mixed(with: .white, fraction: 0.40).opacity(0.52) }
    var frontMiddle: Color {
        mixed(with: .white, fraction: isBlue ? 0.25 : 0.40).opacity(isBlue ? 0.72 : 0.60)
    }
    var frontBottom: Color {
        if !isBlue {
            var hue: CGFloat = 0
            var saturation: CGFloat = 0
            var brightness: CGFloat = 0
            base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
            return Color(uiColor: UIColor(hue: hue + 0.03, saturation: saturation * 0.92,
                                           brightness: min(1, brightness + 0.13), alpha: 0.94))
        }
        return mixed(with: .white, fraction: 0.20).opacity(0.94)
    }
    var glyph: Color {
        if isBlue { return .white.opacity(0.75) }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        base.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return Color(uiColor: UIColor(hue: hue + 0.04, saturation: saturation * 0.70,
                                      brightness: brightness + 0.09, alpha: 0.94))
    }

    var emptyGlyph: Color {
        isBlue ? glyph : mixed(with: .black, fraction: 0.12).opacity(0.80)
    }

    private func mixed(with other: UIColor, fraction: CGFloat) -> Color {
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0
        var tr: CGFloat = 0, tg: CGFloat = 0, tb: CGFloat = 0
        base.getRed(&r, green: &g, blue: &b, alpha: nil)
        other.getRed(&tr, green: &tg, blue: &tb, alpha: nil)
        return Color(red: Double(r + (tr - r) * fraction),
                     green: Double(g + (tg - g) * fraction),
                     blue: Double(b + (tb - b) * fraction))
    }
}

#if DEBUG
struct LibraryFolderReferenceComposition: View {
    var hasContents = true

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255)
            LibraryFolderSurface(symbolName: "book.closed.fill", color: LibraryColorDraft.folderBlue.color,
                                 hasContents: hasContents)
                .frame(width: 584, height: 436)
                .offset(x: 124, y: 100)
            LibraryFolderSurface(symbolName: "sparkles", color: LibraryColorDraft.folderViolet.color,
                                 hasContents: hasContents)
                .frame(width: 584, height: 436)
                .offset(x: 976, y: 101)
        }
        .frame(width: 1740, height: 718)
        .environment(\.colorScheme, .dark)
    }
}

/// A DEBUG-only visual fixture. It never loads or changes the real library.
struct LibraryFolderDebugPreview: View {
    var body: some View {
        GeometryReader { geometry in
            let scale = min(geometry.size.width / 1740, geometry.size.height / 1436)
            VStack(spacing: 0) {
                LibraryFolderReferenceComposition()
                LibraryFolderReferenceComposition(hasContents: false)
            }
            .frame(width: 1740, height: 1436)
            .scaleEffect(scale)
            .position(x: geometry.size.width / 2, y: geometry.size.height / 2)
        }
        .background(Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255))
        .task { @MainActor in
            for hasContents in [true, false] {
                let renderer = ImageRenderer(content: LibraryFolderReferenceComposition(hasContents: hasContents))
                renderer.scale = 1
                if let data = renderer.uiImage?.pngData() {
                    let filename = hasContents ? "FolderReferencePreview.png" : "FolderEmptyPreview.png"
                    try? data.write(to: FileManager.default.temporaryDirectory.appendingPathComponent(filename))
                }
            }
        }
    }
}

#Preview("Folder reference · populated", traits: .fixedLayout(width: 1740, height: 718)) {
    LibraryFolderReferenceComposition()
}

#Preview("Folder reference · empty", traits: .fixedLayout(width: 1740, height: 718)) {
    LibraryFolderReferenceComposition(hasContents: false)
}
#endif
