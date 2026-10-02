import SwiftUI

private func toolGlyphOutline(
    colorScheme: ColorScheme,
    contrast: ColorSchemeContrast,
    isSelected: Bool
) -> Color {
    if contrast == .increased {
        return colorScheme == .dark ? .white : .black
    }
    switch colorScheme {
    case .dark:
        return Color.white.opacity(isSelected ? 1 : 0.94)
    case .light:
        return Color.black.opacity(isSelected ? 0.96 : 0.84)
    @unknown default:
        return Color.primary.opacity(isSelected ? 0.96 : 0.84)
    }
}

/// A deliberately small keyline vocabulary keeps every tool equally crisp.
/// The glyphs render at their authored point size (without a view transform),
/// so these widths resolve consistently on Retina displays in both editors.
private enum ToolGlyphKeyline {
    static let primary: CGFloat = 1.5
    static let detail: CGFloat = 1
    static let emphasis: CGFloat = 2
}

/// Original, app-owned silhouettes for Notate's physical writing tools.
/// These deliberately avoid reproducing Apple's picker artwork.
public struct ToolGlyph: View {
    public let tool: CanvasTool
    public let inkColor: Color
    public let isSelected: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    public init(tool: CanvasTool, inkColor: Color, isSelected: Bool) {
        self.tool = tool
        self.inkColor = inkColor
        self.isSelected = isSelected
    }

    public var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            switch tool {
            case .lasso:
                drawLasso(in: &context)
            case .pen:
                drawPen(in: &context)
            case .ballpoint:
                drawBallpoint(in: &context)
            case .calligraphy:
                drawCalligraphy(in: &context)
            case .pencil:
                drawPencil(in: &context)
            case .fountainPen:
                drawFountainPen(in: &context)
            case .watercolor:
                drawWatercolor(in: &context)
            case .crayon:
                drawCrayon(in: &context)
            case .highlighter:
                drawHighlighter(in: &context)
            case .laserPointer:
                drawLaserPointer(in: &context)
            case .eraser:
                drawEraser(in: &context)
            }
        }
        .frame(width: 22, height: 34)
        .accessibilityHidden(true)
    }

    private var outline: Color {
        toolGlyphOutline(
            colorScheme: colorScheme,
            contrast: colorSchemeContrast,
            isSelected: isSelected
        )
    }

    private var bodyTint: Color {
        inkColor.opacity(isSelected ? 0.34 : 0.22)
    }

    private func drawLasso(in context: inout GraphicsContext) {
        var loop = Path()
        loop.move(to: CGPoint(x: 4, y: 23))
        loop.addCurve(
            to: CGPoint(x: 16.5, y: 6),
            control1: CGPoint(x: -1, y: 13),
            control2: CGPoint(x: 7, y: 3)
        )
        loop.addCurve(
            to: CGPoint(x: 7, y: 27),
            control1: CGPoint(x: 26, y: 12),
            control2: CGPoint(x: 18, y: 31)
        )
        loop.addCurve(
            to: CGPoint(x: 4, y: 23),
            control1: CGPoint(x: 3, y: 28),
            control2: CGPoint(x: 1, y: 25)
        )
        context.stroke(
            loop,
            with: .color(outline),
            style: StrokeStyle(
                lineWidth: ToolGlyphKeyline.primary,
                lineCap: .round,
                dash: [2.5, 2]
            )
        )

        var tail = Path()
        tail.move(to: CGPoint(x: 7, y: 27))
        tail.addCurve(
            to: CGPoint(x: 18.5, y: 31),
            control1: CGPoint(x: 11, y: 29),
            control2: CGPoint(x: 13, y: 31)
        )
        context.stroke(
            tail,
            with: .color(outline),
            style: StrokeStyle(lineWidth: ToolGlyphKeyline.primary, lineCap: .round)
        )
    }

    private func drawPen(in context: inout GraphicsContext) {
        let barrel = Path(roundedRect: CGRect(x: 6.5, y: 2, width: 9, height: 21), cornerRadius: 4)
        context.fill(barrel, with: .color(bodyTint))
        context.stroke(barrel, with: .color(outline), lineWidth: ToolGlyphKeyline.primary)

        var nib = Path()
        nib.move(to: CGPoint(x: 7, y: 22))
        nib.addLine(to: CGPoint(x: 15, y: 22))
        nib.addLine(to: CGPoint(x: 11, y: 32))
        nib.closeSubpath()
        context.fill(nib, with: .color(inkColor))
        context.stroke(nib, with: .color(outline), lineWidth: ToolGlyphKeyline.primary)

        var highlight = Path()
        highlight.move(to: CGPoint(x: 10, y: 5))
        highlight.addLine(to: CGPoint(x: 10, y: 18))
        context.stroke(
            highlight,
            with: .color(Color.white.opacity(0.62)),
            lineWidth: ToolGlyphKeyline.detail
        )
    }

    private func drawBallpoint(in context: inout GraphicsContext) {
        let barrel = Path(roundedRect: CGRect(x: 7.5, y: 2, width: 7, height: 20), cornerRadius: 3.5)
        context.fill(barrel, with: .color(bodyTint))
        context.stroke(barrel, with: .color(outline), lineWidth: ToolGlyphKeyline.primary)

        var clip = Path()
        clip.move(to: CGPoint(x: 15.5, y: 5))
        clip.addLine(to: CGPoint(x: 15.5, y: 13))
        context.stroke(
            clip,
            with: .color(outline),
            style: StrokeStyle(lineWidth: ToolGlyphKeyline.primary, lineCap: .round)
        )

        var cone = Path()
        cone.move(to: CGPoint(x: 8.5, y: 21.5))
        cone.addLine(to: CGPoint(x: 13.5, y: 21.5))
        cone.addLine(to: CGPoint(x: 11.8, y: 30))
        cone.addLine(to: CGPoint(x: 10.2, y: 30))
        cone.closeSubpath()
        context.fill(cone, with: .color(outline.opacity(0.16)))
        context.stroke(cone, with: .color(outline), lineWidth: ToolGlyphKeyline.primary)

        context.fill(
            Path(ellipseIn: CGRect(x: 9.9, y: 29.6, width: 2.2, height: 2.2)),
            with: .color(inkColor)
        )

        var highlight = Path()
        highlight.move(to: CGPoint(x: 10.2, y: 5))
        highlight.addLine(to: CGPoint(x: 10.2, y: 17))
        context.stroke(
            highlight,
            with: .color(Color.white.opacity(0.62)),
            lineWidth: ToolGlyphKeyline.detail
        )
    }

    private func drawCalligraphy(in context: inout GraphicsContext) {
        let barrel = Path(
            roundedRect: CGRect(x: 6.5, y: 2, width: 9, height: 19),
            cornerRadius: 3.8
        )
        context.fill(barrel, with: .color(bodyTint))
        context.stroke(barrel, with: .color(outline), lineWidth: ToolGlyphKeyline.primary)

        var nib = Path()
        nib.move(to: CGPoint(x: 6.7, y: 20))
        nib.addLine(to: CGPoint(x: 15.3, y: 20))
        nib.addLine(to: CGPoint(x: 16.2, y: 25.2))
        nib.addLine(to: CGPoint(x: 12.7, y: 32))
        nib.addLine(to: CGPoint(x: 8.2, y: 29.6))
        nib.addLine(to: CGPoint(x: 5.8, y: 24.2))
        nib.closeSubpath()
        context.fill(nib, with: .color(inkColor.opacity(0.82)))
        context.stroke(nib, with: .color(outline), lineWidth: ToolGlyphKeyline.primary)

        var cut = Path()
        cut.move(to: CGPoint(x: 8.1, y: 22.3))
        cut.addLine(to: CGPoint(x: 13.9, y: 28.3))
        context.stroke(
            cut,
            with: .color(outline.opacity(0.84)),
            style: StrokeStyle(lineWidth: ToolGlyphKeyline.detail, lineCap: .round)
        )
    }

    private func drawPencil(in context: inout GraphicsContext) {
        var barrel = Path()
        barrel.move(to: CGPoint(x: 6, y: 3))
        barrel.addLine(to: CGPoint(x: 14.5, y: 3))
        barrel.addLine(to: CGPoint(x: 16, y: 23))
        barrel.addLine(to: CGPoint(x: 7.5, y: 23))
        barrel.closeSubpath()
        context.fill(barrel, with: .color(bodyTint))
        context.stroke(barrel, with: .color(outline), lineWidth: ToolGlyphKeyline.primary)

        var wood = Path()
        wood.move(to: CGPoint(x: 7.5, y: 23))
        wood.addLine(to: CGPoint(x: 16, y: 23))
        wood.addLine(to: CGPoint(x: 11.5, y: 32))
        wood.closeSubpath()
        context.fill(wood, with: .color(Color(red: 0.84, green: 0.71, blue: 0.53)))
        context.stroke(wood, with: .color(outline), lineWidth: ToolGlyphKeyline.primary)

        var graphite = Path()
        graphite.move(to: CGPoint(x: 9.7, y: 28.2))
        graphite.addLine(to: CGPoint(x: 13.3, y: 28.2))
        graphite.addLine(to: CGPoint(x: 11.5, y: 32))
        graphite.closeSubpath()
        context.fill(graphite, with: .color(inkColor))

        var facet = Path()
        facet.move(to: CGPoint(x: 10, y: 4))
        facet.addLine(to: CGPoint(x: 11, y: 21))
        context.stroke(
            facet,
            with: .color(Color.white.opacity(0.60)),
            lineWidth: ToolGlyphKeyline.detail
        )
    }

    private func drawFountainPen(in context: inout GraphicsContext) {
        let barrel = Path(roundedRect: CGRect(x: 6.5, y: 2, width: 9, height: 18), cornerRadius: 4.5)
        context.fill(barrel, with: .color(bodyTint))
        context.stroke(barrel, with: .color(outline), lineWidth: ToolGlyphKeyline.primary)

        var nib = Path()
        nib.move(to: CGPoint(x: 11, y: 18))
        nib.addCurve(to: CGPoint(x: 17, y: 24), control1: CGPoint(x: 14, y: 19), control2: CGPoint(x: 16, y: 21))
        nib.addLine(to: CGPoint(x: 11, y: 32))
        nib.addLine(to: CGPoint(x: 5, y: 24))
        nib.addCurve(to: CGPoint(x: 11, y: 18), control1: CGPoint(x: 6, y: 21), control2: CGPoint(x: 8, y: 19))
        nib.closeSubpath()
        context.fill(nib, with: .color(inkColor.opacity(0.78)))
        context.stroke(nib, with: .color(outline), lineWidth: ToolGlyphKeyline.primary)

        var slit = Path()
        slit.move(to: CGPoint(x: 11, y: 21))
        slit.addLine(to: CGPoint(x: 11, y: 28.5))
        context.stroke(
            slit,
            with: .color(outline),
            style: StrokeStyle(lineWidth: ToolGlyphKeyline.detail, lineCap: .round)
        )
        context.fill(Path(ellipseIn: CGRect(x: 9.8, y: 22.8, width: 2.4, height: 2.4)), with: .color(outline))
    }

    private func drawWatercolor(in context: inout GraphicsContext) {
        let handle = Path(
            roundedRect: CGRect(x: 8, y: 1.5, width: 6, height: 16),
            cornerRadius: 3
        )
        context.fill(handle, with: .color(bodyTint))
        context.stroke(handle, with: .color(outline), lineWidth: ToolGlyphKeyline.primary)

        let ferrule = Path(
            roundedRect: CGRect(x: 6.3, y: 15.7, width: 9.4, height: 6.8),
            cornerRadius: 1.8
        )
        context.fill(ferrule, with: .color(outline.opacity(0.16)))
        context.stroke(ferrule, with: .color(outline), lineWidth: ToolGlyphKeyline.primary)

        var bristles = Path()
        bristles.move(to: CGPoint(x: 6.9, y: 22))
        bristles.addCurve(
            to: CGPoint(x: 11, y: 32),
            control1: CGPoint(x: 6.9, y: 26.4),
            control2: CGPoint(x: 9.1, y: 29.4)
        )
        bristles.addCurve(
            to: CGPoint(x: 15.1, y: 22),
            control1: CGPoint(x: 12.9, y: 29.4),
            control2: CGPoint(x: 15.1, y: 26.4)
        )
        bristles.closeSubpath()
        context.fill(bristles, with: .color(inkColor.opacity(isSelected ? 0.88 : 0.72)))
        context.stroke(bristles, with: .color(outline), lineWidth: ToolGlyphKeyline.primary)

        var glint = Path()
        glint.move(to: CGPoint(x: 9.8, y: 4.5))
        glint.addLine(to: CGPoint(x: 9.8, y: 13.2))
        context.stroke(
            glint,
            with: .color(Color.white.opacity(0.54)),
            style: StrokeStyle(lineWidth: ToolGlyphKeyline.detail, lineCap: .round)
        )
    }

    private func drawCrayon(in context: inout GraphicsContext) {
        let wax = Path(
            roundedRect: CGRect(x: 6, y: 3, width: 10, height: 24),
            cornerRadius: 2.8
        )
        context.fill(wax, with: .color(inkColor.opacity(isSelected ? 0.78 : 0.62)))
        context.stroke(wax, with: .color(outline), lineWidth: ToolGlyphKeyline.primary)

        let wrapper = Path(
            roundedRect: CGRect(x: 5.7, y: 11, width: 10.6, height: 13),
            cornerRadius: 1.8
        )
        context.fill(wrapper, with: .color(bodyTint))
        context.stroke(wrapper, with: .color(outline), lineWidth: ToolGlyphKeyline.detail)

        var wrapperBand = Path()
        wrapperBand.move(to: CGPoint(x: 6.2, y: 14.2))
        wrapperBand.addLine(to: CGPoint(x: 15.8, y: 14.2))
        wrapperBand.move(to: CGPoint(x: 6.2, y: 20.6))
        wrapperBand.addLine(to: CGPoint(x: 15.8, y: 20.6))
        context.stroke(
            wrapperBand,
            with: .color(outline.opacity(0.70)),
            lineWidth: ToolGlyphKeyline.detail
        )

        var tip = Path()
        tip.move(to: CGPoint(x: 6.3, y: 26.4))
        tip.addLine(to: CGPoint(x: 15.7, y: 26.4))
        tip.addLine(to: CGPoint(x: 13.6, y: 31.2))
        tip.addQuadCurve(
            to: CGPoint(x: 8.4, y: 31.2),
            control: CGPoint(x: 11, y: 32.1)
        )
        tip.closeSubpath()
        context.fill(tip, with: .color(inkColor))
        context.stroke(tip, with: .color(outline), lineWidth: ToolGlyphKeyline.primary)
    }

    private func drawHighlighter(in context: inout GraphicsContext) {
        var body = Path()
        body.move(to: CGPoint(x: 5, y: 3))
        body.addLine(to: CGPoint(x: 15, y: 3))
        body.addLine(to: CGPoint(x: 17, y: 23))
        body.addLine(to: CGPoint(x: 7, y: 23))
        body.closeSubpath()
        context.fill(body, with: .color(inkColor.opacity(isSelected ? 0.52 : 0.36)))
        context.stroke(body, with: .color(outline), lineWidth: ToolGlyphKeyline.primary)

        var chisel = Path()
        chisel.move(to: CGPoint(x: 7, y: 23))
        chisel.addLine(to: CGPoint(x: 17, y: 23))
        chisel.addLine(to: CGPoint(x: 15, y: 31))
        chisel.addLine(to: CGPoint(x: 8.5, y: 31))
        chisel.closeSubpath()
        context.fill(chisel, with: .color(inkColor))
        context.stroke(chisel, with: .color(outline), lineWidth: ToolGlyphKeyline.primary)

        var seam = Path()
        seam.move(to: CGPoint(x: 6.5, y: 8))
        seam.addLine(to: CGPoint(x: 15.5, y: 8))
        context.stroke(
            seam,
            with: .color(outline.opacity(0.72)),
            lineWidth: ToolGlyphKeyline.detail
        )
    }

    private func drawLaserPointer(in context: inout GraphicsContext) {
        context.translateBy(x: 11, y: 17)
        context.rotate(by: .degrees(24))

        let glow = Path(ellipseIn: CGRect(x: -3.75, y: -16.75, width: 7.5, height: 7.5))
        context.fill(
            glow,
            with: .color(inkColor.opacity(isSelected ? 0.20 : 0.12))
        )

        let halo = Path(ellipseIn: CGRect(x: -2.4, y: -15.4, width: 4.8, height: 4.8))
        context.fill(
            halo,
            with: .color(inkColor.opacity(isSelected ? 0.34 : 0.24))
        )

        let point = Path(ellipseIn: CGRect(x: -1.6, y: -14.6, width: 3.2, height: 3.2))
        context.fill(point, with: .color(inkColor))

        var beam = Path()
        beam.move(to: CGPoint(x: 0, y: -10.2))
        beam.addLine(to: CGPoint(x: 0, y: -5.2))
        context.stroke(
            beam,
            with: .color(inkColor.opacity(isSelected ? 0.18 : 0.10)),
            style: StrokeStyle(lineWidth: ToolGlyphKeyline.emphasis, lineCap: .round)
        )
        context.stroke(
            beam,
            with: .color(inkColor.opacity(isSelected ? 0.90 : 0.68)),
            style: StrokeStyle(lineWidth: ToolGlyphKeyline.detail, lineCap: .round)
        )

        let barrel = Path(
            roundedRect: CGRect(x: -3.7, y: -2.8, width: 7.4, height: 18.2),
            cornerRadius: 3.5
        )
        context.fill(
            barrel,
            with: .color(bodyTint)
        )
        context.stroke(barrel, with: .color(outline), lineWidth: ToolGlyphKeyline.primary)

        let emitter = Path(
            roundedRect: CGRect(x: -3.15, y: -4.7, width: 6.3, height: 4.1),
            cornerRadius: 1.8
        )
        context.fill(
            emitter,
            with: .color(inkColor.opacity(isSelected ? 0.92 : 0.76))
        )
        context.stroke(emitter, with: .color(outline), lineWidth: ToolGlyphKeyline.detail)

        let button = Path(ellipseIn: CGRect(x: -1.3, y: 2.1, width: 2.6, height: 2.6))
        context.fill(button, with: .color(inkColor.opacity(isSelected ? 1 : 0.84)))
        context.stroke(
            button,
            with: .color(outline.opacity(0.82)),
            lineWidth: ToolGlyphKeyline.detail
        )

        var highlight = Path()
        highlight.move(to: CGPoint(x: -1.7, y: 5.8))
        highlight.addLine(to: CGPoint(x: -1.7, y: 11.7))
        context.stroke(
            highlight,
            with: .color(Color.white.opacity(0.46)),
            style: StrokeStyle(lineWidth: ToolGlyphKeyline.detail, lineCap: .round)
        )
    }

    private func drawEraser(in context: inout GraphicsContext) {
        context.translateBy(x: 11, y: 17)
        context.rotate(by: .degrees(-32))

        let body = Path(
            roundedRect: CGRect(x: -8.5, y: -5.5, width: 17, height: 11),
            cornerRadius: 2.8
        )
        context.fill(
            body,
            with: .color(Color(red: 0.96, green: 0.95, blue: 0.92))
        )
        context.stroke(body, with: .color(outline), lineWidth: ToolGlyphKeyline.primary)

        let sleeve = Path(
            roundedRect: CGRect(x: -1.4, y: -4.9, width: 9.2, height: 9.8),
            cornerRadius: 2.1
        )
        context.fill(
            sleeve,
            with: .color(
                Color(red: 0.28, green: 0.52, blue: 0.78)
                    .opacity(isSelected ? 0.88 : 0.70)
            )
        )

        var seam = Path()
        seam.move(to: CGPoint(x: -1.4, y: -4.5))
        seam.addLine(to: CGPoint(x: -1.4, y: 4.5))
        context.stroke(
            seam,
            with: .color(outline.opacity(0.78)),
            lineWidth: ToolGlyphKeyline.detail
        )

        var scuffs = Path()
        scuffs.move(to: CGPoint(x: -7.0, y: -1.5))
        scuffs.addLine(to: CGPoint(x: -4.2, y: -2.3))
        scuffs.move(to: CGPoint(x: -6.3, y: 2.0))
        scuffs.addLine(to: CGPoint(x: -3.8, y: 1.2))
        context.stroke(
            scuffs,
            with: .color(outline.opacity(0.54)),
            style: StrokeStyle(lineWidth: ToolGlyphKeyline.detail, lineCap: .round)
        )
    }
}

/// App-owned glyphs for the expanded Add tray.
///
/// These use the same outline, accent wash, rounded joins, and authored-vector
/// rendering as Notate's physical writing tools. Keeping them here prevents
/// the tray from drifting into a second, stock-symbol visual language.
enum CanvasTrayGlyphKind: Hashable {
    case text
    case shape
    case table
    case wand
    case image
}

struct CanvasTrayGlyph: View {
    let kind: CanvasTrayGlyphKind
    var isSelected = false
    var size: CGFloat = 22

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, canvasSize in
            context.scaleBy(x: canvasSize.width / 24, y: canvasSize.height / 24)
            switch kind {
            case .text: drawText(in: &context)
            case .shape: drawShape(in: &context)
            case .table: drawTable(in: &context)
            case .wand: drawWand(in: &context)
            case .image: drawImage(in: &context)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var outline: Color {
        toolGlyphOutline(
            colorScheme: colorScheme,
            contrast: colorSchemeContrast,
            isSelected: isSelected
        )
    }

    private var wash: Color {
        NotateDesign.Palette.accent.opacity(
            isSelected
                ? (colorScheme == .dark ? 0.40 : 0.28)
                : (colorScheme == .dark ? 0.28 : 0.18)
        )
    }

    private var strongWash: Color {
        NotateDesign.Palette.accent.opacity(isSelected ? 1 : 0.82)
    }

    private var warmWash: Color {
        NotateDesign.Palette.favorite.opacity(isSelected ? 1 : 0.86)
    }

    private var stroke: StrokeStyle {
        StrokeStyle(
            lineWidth: ToolGlyphKeyline.primary,
            lineCap: .round,
            lineJoin: .round
        )
    }

    private func drawText(in context: inout GraphicsContext) {
        let page = Path(
            roundedRect: CGRect(x: 3.2, y: 2.2, width: 17.6, height: 19.6),
            cornerRadius: 3.2
        )
        context.fill(page, with: .color(wash))
        context.stroke(page, with: .color(outline), style: stroke)

        var letter = Path()
        letter.move(to: CGPoint(x: 7.1, y: 7.1))
        letter.addLine(to: CGPoint(x: 16.9, y: 7.1))
        letter.move(to: CGPoint(x: 12, y: 7.1))
        letter.addLine(to: CGPoint(x: 12, y: 16.8))
        context.stroke(
            letter,
            with: .color(strongWash),
            style: StrokeStyle(lineWidth: 2.25, lineCap: .round)
        )

        var baseline = Path()
        baseline.move(to: CGPoint(x: 8.7, y: 17.5))
        baseline.addLine(to: CGPoint(x: 15.3, y: 17.5))
        context.stroke(
            baseline,
            with: .color(outline.opacity(0.48)),
            style: StrokeStyle(lineWidth: ToolGlyphKeyline.detail, lineCap: .round)
        )
    }

    private func drawShape(in context: inout GraphicsContext) {
        var diamond = Path()
        diamond.move(to: CGPoint(x: 8.7, y: 3.1))
        diamond.addLine(to: CGPoint(x: 15.5, y: 9.9))
        diamond.addLine(to: CGPoint(x: 8.7, y: 16.7))
        diamond.addLine(to: CGPoint(x: 1.9, y: 9.9))
        diamond.closeSubpath()
        context.fill(diamond, with: .color(wash))
        context.stroke(diamond, with: .color(outline), style: stroke)

        let circle = Path(ellipseIn: CGRect(x: 10.5, y: 3.6, width: 11.2, height: 11.2))
        context.fill(circle, with: .color(warmWash.opacity(0.72)))
        context.stroke(circle, with: .color(outline), style: stroke)

        let square = Path(
            roundedRect: CGRect(x: 5.4, y: 12.1, width: 10.2, height: 9.6),
            cornerRadius: 2.3
        )
        context.fill(square, with: .color(strongWash.opacity(0.78)))
        context.stroke(square, with: .color(outline), style: stroke)
    }

    private func drawTable(in context: inout GraphicsContext) {
        let frame = CGRect(x: 2.3, y: 3.1, width: 19.4, height: 17.8)
        let table = Path(roundedRect: frame, cornerRadius: 3)
        context.fill(table, with: .color(wash))

        let header = Path(
            roundedRect: CGRect(x: 3.1, y: 3.9, width: 17.8, height: 4.5),
            cornerRadius: 2.1
        )
        context.fill(header, with: .color(strongWash.opacity(0.74)))

        var grid = Path()
        grid.move(to: CGPoint(x: 2.8, y: 9))
        grid.addLine(to: CGPoint(x: 21.2, y: 9))
        grid.move(to: CGPoint(x: 2.8, y: 14.8))
        grid.addLine(to: CGPoint(x: 21.2, y: 14.8))
        grid.move(to: CGPoint(x: 8.6, y: 3.6))
        grid.addLine(to: CGPoint(x: 8.6, y: 20.4))
        grid.move(to: CGPoint(x: 15.4, y: 3.6))
        grid.addLine(to: CGPoint(x: 15.4, y: 20.4))
        context.stroke(
            grid,
            with: .color(outline.opacity(0.74)),
            style: StrokeStyle(lineWidth: ToolGlyphKeyline.detail, lineCap: .round)
        )
        context.stroke(table, with: .color(outline), style: stroke)
    }

    private func drawWand(in context: inout GraphicsContext) {
        var shaft = Path()
        shaft.move(to: CGPoint(x: 4.6, y: 20.2))
        shaft.addLine(to: CGPoint(x: 15.6, y: 9.2))
        context.stroke(
            shaft,
            with: .color(outline),
            style: StrokeStyle(lineWidth: 5.4, lineCap: .round)
        )
        context.stroke(
            shaft,
            with: .color(strongWash),
            style: StrokeStyle(lineWidth: 3.2, lineCap: .round)
        )

        var handle = Path()
        handle.move(to: CGPoint(x: 4.8, y: 20))
        handle.addLine(to: CGPoint(x: 8.1, y: 16.7))
        context.stroke(
            handle,
            with: .color(warmWash),
            style: StrokeStyle(lineWidth: 3.2, lineCap: .round)
        )

        let star = sparklePath(
            center: CGPoint(x: 18.2, y: 5.8),
            outerRadius: 4.3,
            innerRadius: 1.55
        )
        context.fill(star, with: .color(warmWash))
        context.stroke(star, with: .color(outline), lineWidth: 1.2)

        var glints = Path()
        glints.move(to: CGPoint(x: 10.3, y: 2.2))
        glints.addLine(to: CGPoint(x: 10.3, y: 5.3))
        glints.move(to: CGPoint(x: 8.8, y: 3.75))
        glints.addLine(to: CGPoint(x: 11.8, y: 3.75))
        context.stroke(
            glints,
            with: .color(strongWash),
            style: StrokeStyle(lineWidth: 1.35, lineCap: .round)
        )
        context.fill(
            Path(ellipseIn: CGRect(x: 19.5, y: 11.4, width: 2.8, height: 2.8)),
            with: .color(strongWash)
        )
    }

    private func drawImage(in context: inout GraphicsContext) {
        let frame = Path(
            roundedRect: CGRect(x: 2.2, y: 3, width: 19.6, height: 18),
            cornerRadius: 3.3
        )
        context.fill(frame, with: .color(wash))

        context.fill(
            Path(ellipseIn: CGRect(x: 14.8, y: 5.5, width: 4.2, height: 4.2)),
            with: .color(warmWash)
        )

        var landscape = Path()
        landscape.move(to: CGPoint(x: 3.1, y: 18.8))
        landscape.addLine(to: CGPoint(x: 8.7, y: 11.5))
        landscape.addLine(to: CGPoint(x: 12.9, y: 16))
        landscape.addLine(to: CGPoint(x: 16.1, y: 12.8))
        landscape.addLine(to: CGPoint(x: 20.9, y: 18.4))
        landscape.addLine(to: CGPoint(x: 20.9, y: 20.1))
        landscape.addLine(to: CGPoint(x: 3.1, y: 20.1))
        landscape.closeSubpath()
        context.fill(landscape, with: .color(strongWash.opacity(0.78)))
        context.stroke(
            landscape,
            with: .color(outline.opacity(0.76)),
            style: StrokeStyle(lineWidth: ToolGlyphKeyline.detail, lineJoin: .round)
        )
        context.stroke(frame, with: .color(outline), style: stroke)
    }

    private func sparklePath(
        center: CGPoint,
        outerRadius: CGFloat,
        innerRadius: CGFloat
    ) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: center.x, y: center.y - outerRadius))
        path.addLine(to: CGPoint(x: center.x + innerRadius, y: center.y - innerRadius))
        path.addLine(to: CGPoint(x: center.x + outerRadius, y: center.y))
        path.addLine(to: CGPoint(x: center.x + innerRadius, y: center.y + innerRadius))
        path.addLine(to: CGPoint(x: center.x, y: center.y + outerRadius))
        path.addLine(to: CGPoint(x: center.x - innerRadius, y: center.y + innerRadius))
        path.addLine(to: CGPoint(x: center.x - outerRadius, y: center.y))
        path.addLine(to: CGPoint(x: center.x - innerRadius, y: center.y - innerRadius))
        path.closeSubpath()
        return path
    }
}

/// App-owned drafting-tool artwork that shares the writing-tool keyline system.
public struct CanvasGeometryToolGlyph: View {
    public let tool: CanvasGeometryTool
    public let isSelected: Bool

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast

    public init(tool: CanvasGeometryTool, isSelected: Bool) {
        self.tool = tool
        self.isSelected = isSelected
    }

    public var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, _ in
            switch tool {
            case .ruler:
                drawRuler(in: &context)
            case .protractor:
                drawProtractor(in: &context)
            case .compass:
                drawCompass(in: &context)
            }
        }
        .frame(width: 28, height: 22)
        .accessibilityHidden(true)
    }

    private var outline: Color {
        toolGlyphOutline(
            colorScheme: colorScheme,
            contrast: colorSchemeContrast,
            isSelected: isSelected
        )
    }

    private var instrumentFill: Color {
        Color(red: 0.94, green: 0.68, blue: 0.20)
            .opacity(isSelected ? 0.86 : 0.68)
    }

    private func drawRuler(in context: inout GraphicsContext) {
        context.translateBy(x: 14, y: 11)
        context.rotate(by: .degrees(-10))

        let body = Path(
            roundedRect: CGRect(x: -12.5, y: -4.5, width: 25, height: 9),
            cornerRadius: 2.4
        )
        context.fill(body, with: .color(instrumentFill))
        context.stroke(body, with: .color(outline), lineWidth: ToolGlyphKeyline.primary)

        var ticks = Path()
        for index in -4...4 {
            let x = CGFloat(index) * 2.8
            let length: CGFloat
            if index == 0 {
                length = 5.3
            } else if index.isMultiple(of: 2) {
                length = 4
            } else {
                length = 2.7
            }
            ticks.move(to: CGPoint(x: x, y: -4.5))
            ticks.addLine(to: CGPoint(x: x, y: -4.5 + length))
        }
        context.stroke(
            ticks,
            with: .color(outline.opacity(0.82)),
            style: StrokeStyle(lineWidth: ToolGlyphKeyline.detail, lineCap: .round)
        )

        var highlight = Path()
        highlight.move(to: CGPoint(x: -10.5, y: 3.1))
        highlight.addLine(to: CGPoint(x: 10.5, y: 3.1))
        context.stroke(
            highlight,
            with: .color(Color.white.opacity(colorScheme == .dark ? 0.30 : 0.48)),
            style: StrokeStyle(lineWidth: ToolGlyphKeyline.detail, lineCap: .round)
        )
    }

    private func drawProtractor(in context: inout GraphicsContext) {
        var body = Path()
        body.move(to: CGPoint(x: 2, y: 18.5))
        body.addCurve(
            to: CGPoint(x: 26, y: 18.5),
            control1: CGPoint(x: 4.2, y: 3.2),
            control2: CGPoint(x: 23.8, y: 3.2)
        )
        body.addLine(to: CGPoint(x: 2, y: 18.5))
        body.closeSubpath()
        context.fill(body, with: .color(instrumentFill.opacity(0.72)))
        context.stroke(body, with: .color(outline), lineWidth: ToolGlyphKeyline.primary)

        var innerArc = Path()
        innerArc.move(to: CGPoint(x: 7.2, y: 17.5))
        innerArc.addCurve(
            to: CGPoint(x: 20.8, y: 17.5),
            control1: CGPoint(x: 8.8, y: 8.7),
            control2: CGPoint(x: 19.2, y: 8.7)
        )
        context.stroke(
            innerArc,
            with: .color(outline.opacity(0.76)),
            style: StrokeStyle(lineWidth: ToolGlyphKeyline.detail, lineCap: .round)
        )

        var ticks = Path()
        ticks.move(to: CGPoint(x: 14, y: 5.8))
        ticks.addLine(to: CGPoint(x: 14, y: 9.1))
        ticks.move(to: CGPoint(x: 7.2, y: 9.4))
        ticks.addLine(to: CGPoint(x: 9.2, y: 11.8))
        ticks.move(to: CGPoint(x: 20.8, y: 9.4))
        ticks.addLine(to: CGPoint(x: 18.8, y: 11.8))
        ticks.move(to: CGPoint(x: 3.7, y: 15.3))
        ticks.addLine(to: CGPoint(x: 7, y: 15.8))
        ticks.move(to: CGPoint(x: 24.3, y: 15.3))
        ticks.addLine(to: CGPoint(x: 21, y: 15.8))
        context.stroke(
            ticks,
            with: .color(outline.opacity(0.82)),
            style: StrokeStyle(lineWidth: ToolGlyphKeyline.detail, lineCap: .round)
        )
    }

    private func drawCompass(in context: inout GraphicsContext) {
        var legs = Path()
        legs.move(to: CGPoint(x: 14, y: 5.5))
        legs.addLine(to: CGPoint(x: 5.5, y: 19.5))
        legs.move(to: CGPoint(x: 14, y: 5.5))
        legs.addLine(to: CGPoint(x: 22.5, y: 19.5))
        context.stroke(
            legs,
            with: .color(outline),
            style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round)
        )
        context.stroke(
            legs,
            with: .color(instrumentFill),
            style: StrokeStyle(lineWidth: 2.8, lineCap: .round, lineJoin: .round)
        )

        let hinge = Path(ellipseIn: CGRect(x: 10.5, y: 1.5, width: 7, height: 7))
        context.fill(hinge, with: .color(instrumentFill))
        context.stroke(hinge, with: .color(outline), lineWidth: ToolGlyphKeyline.primary)
        context.fill(
            Path(ellipseIn: CGRect(x: 12.8, y: 3.8, width: 2.4, height: 2.4)),
            with: .color(outline)
        )

        var brace = Path()
        brace.move(to: CGPoint(x: 9.4, y: 12.5))
        brace.addLine(to: CGPoint(x: 18.6, y: 12.5))
        context.stroke(
            brace,
            with: .color(outline.opacity(0.76)),
            style: StrokeStyle(lineWidth: ToolGlyphKeyline.detail, lineCap: .round)
        )

        var point = Path()
        point.move(to: CGPoint(x: 4.5, y: 19))
        point.addLine(to: CGPoint(x: 6.4, y: 19))
        point.addLine(to: CGPoint(x: 5.1, y: 21.2))
        point.closeSubpath()
        context.fill(point, with: .color(outline))

        var pencil = Path()
        pencil.move(to: CGPoint(x: 21.4, y: 19))
        pencil.addLine(to: CGPoint(x: 23.3, y: 19))
        pencil.addLine(to: CGPoint(x: 22.8, y: 21.2))
        pencil.closeSubpath()
        context.fill(pencil, with: .color(outline))
    }
}
