import SwiftUI
import UIKit

enum NotateAgentMarkAsset {
    static let name = "NotateAgentMark"

    /// UIKit controls cannot size an asset-catalog vector the way SwiftUI's
    /// resizable Image can. Rasterize it at the requested display size while
    /// retaining template rendering so every host owns its semantic tint.
    @MainActor
    static func image(pointSize: CGFloat) -> UIImage? {
        guard pointSize > 0,
              let source = UIImage(named: name) else { return nil }

        let size = CGSize(width: pointSize, height: pointSize)
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            source.withRenderingMode(.alwaysOriginal).draw(
                in: CGRect(origin: .zero, size: size)
            )
        }
        return image.withRenderingMode(.alwaysTemplate)
    }
}

/// Notate's single AI-agent identity mark.
///
/// Keep this decorative and let the containing control or response provide
/// the accessible name. The same template SVG scales from inline responses to
/// the canvas launcher without introducing a second AI visual language.
struct NotateAgentMark: View {
    var tint: Color = NotateDesign.Palette.accent
    var size: CGFloat = 18

    var body: some View {
        Image(NotateAgentMarkAsset.name)
            .resizable()
            .renderingMode(.template)
            .interpolation(.high)
            .scaledToFit()
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// The shared assistant identity used by both the canvas launcher and the
/// conversation rail. Keeping the complete mark in the design system prevents
/// the two entry points from drifting into separate AI visual languages.
struct NotateAssistantIdentityMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(
                cornerRadius: min(NotateDesign.Radius.option, size * 0.34),
                style: .continuous
            )
            .fill(Color.primary.opacity(0.040))

            NotateAgentMark(
                tint: Color.primary.opacity(0.76),
                size: size * 0.54
            )

            node(
                color: NotateDesign.Palette.assistantViolet,
                diameter: size * 0.17,
                x: size * 0.29,
                y: -size * 0.27
            )
            node(
                color: NotateDesign.Palette.assistantCoral,
                diameter: size * 0.13,
                x: size * 0.31,
                y: size * 0.24
            )
            node(
                color: NotateDesign.Palette.assistantAmber,
                diameter: size * 0.10,
                x: -size * 0.30,
                y: size * 0.28
            )
        }
        .frame(width: size, height: size)
        .overlay {
            RoundedRectangle(
                cornerRadius: min(NotateDesign.Radius.option, size * 0.34),
                style: .continuous
            )
            .strokeBorder(Color.primary.opacity(0.060), lineWidth: 0.75)
        }
    }

    private func node(
        color: Color,
        diameter: CGFloat,
        x: CGFloat,
        y: CGFloat
    ) -> some View {
        Circle()
            .fill(color)
            .frame(width: diameter, height: diameter)
            .overlay {
                Circle().stroke(Color(uiColor: .systemBackground), lineWidth: 1)
            }
            .offset(x: x, y: y)
    }
}

/// Notate's app-owned navigation and library pictograms.
///
/// The canvas toolbar deliberately uses physical, outlined tools instead of
/// stock symbols. These glyphs carry that same visual language through the
/// library: a dark/light aware outline, a quiet accent wash, rounded ends, and
/// a few intentionally human details. They are decorative; the containing
/// control owns the accessible label and hit target.
enum NotateAppGlyphKind: Hashable {
    case home
    case favorite
    case recent
    case tag
    case trash
    case settings
    case search
    case filter
    case grid
    case list
    case select
    case add
    case close
    case confirm
    case sidebar
    case folder
    case notebook
    case quickNote
    case canvas
    case document
    case importDocument
    case study
    case work
    case art
    case music
    case travel
    case code
    case idea
    case personal

    init(folderSymbolName: String) {
        self = Self.customFolderGlyph(for: folderSymbolName) ?? .folder
    }

    /// Returns an app-drawn glyph only when Notate owns a matching pictogram.
    /// Callers can fall back to the persisted SF Symbol for custom values
    /// instead of silently replacing it with the generic folder.
    static func customFolderGlyph(for folderSymbolName: String) -> Self? {
        switch folderSymbolName {
        case "folder": .folder
        case "graduationcap": .study
        case "briefcase", "shippingbox": .work
        case "paintpalette": .art
        case "music.note": .music
        case "airplane": .travel
        case "chevron.left.forwardslash.chevron.right": .code
        case "lightbulb", "sparkles": .idea
        case "person.crop.circle": .personal
        default: nil
        }
    }
}

struct NotateAppGlyph: View {
    let kind: NotateAppGlyphKind
    var tint: Color = NotateDesign.Palette.accent
    var isSelected = false
    var usesTintedOutline = false
    var size: CGFloat = 24

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Canvas(opaque: false, rendersAsynchronously: false) { context, canvasSize in
            context.scaleBy(x: canvasSize.width / 24, y: canvasSize.height / 24)
            draw(kind, in: &context)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var outline: Color {
        if contrast == .increased {
            return colorScheme == .dark ? .white : .black
        }
        if isSelected || usesTintedOutline {
            return tint.opacity(colorScheme == .dark ? 1 : 0.92)
        }
        return Color.primary.opacity(colorScheme == .dark ? 0.88 : 0.76)
    }

    private var wash: Color {
        tint.opacity(isSelected ? (colorScheme == .dark ? 0.34 : 0.20) : 0.12)
    }

    private var strongWash: Color {
        tint.opacity(isSelected ? 0.96 : 0.78)
    }

    private var stroke: StrokeStyle {
        StrokeStyle(lineWidth: 1.65, lineCap: .round, lineJoin: .round)
    }

    private func draw(_ kind: NotateAppGlyphKind, in context: inout GraphicsContext) {
        switch kind {
        case .home: drawHome(in: &context)
        case .favorite: drawFavorite(in: &context)
        case .recent: drawRecent(in: &context)
        case .tag: drawTag(in: &context)
        case .trash: drawTrash(in: &context)
        case .settings: drawSettings(in: &context)
        case .search: drawSearch(in: &context)
        case .filter: drawFilter(in: &context)
        case .grid: drawGrid(in: &context)
        case .list: drawList(in: &context)
        case .select: drawSelect(in: &context)
        case .add: drawCross(in: &context, rotated: false)
        case .close: drawCross(in: &context, rotated: true)
        case .confirm: drawConfirm(in: &context)
        case .sidebar: drawSidebar(in: &context)
        case .folder: drawFolder(in: &context)
        case .notebook: drawNotebook(in: &context)
        case .quickNote: drawQuickNote(in: &context)
        case .canvas: drawCanvas(in: &context)
        case .document: drawDocument(in: &context)
        case .importDocument: drawImportDocument(in: &context)
        case .study: drawStudy(in: &context)
        case .work: drawWork(in: &context)
        case .art: drawArt(in: &context)
        case .music: drawMusic(in: &context)
        case .travel: drawTravel(in: &context)
        case .code: drawCode(in: &context)
        case .idea: drawIdea(in: &context)
        case .personal: drawPersonal(in: &context)
        }
    }

    private func drawHome(in context: inout GraphicsContext) {
        var roof = Path()
        roof.move(to: CGPoint(x: 3, y: 11))
        roof.addLine(to: CGPoint(x: 11.9, y: 3.4))
        roof.addLine(to: CGPoint(x: 21, y: 11))
        context.stroke(roof, with: .color(outline), style: stroke)

        var house = Path()
        house.move(to: CGPoint(x: 5.3, y: 10))
        house.addLine(to: CGPoint(x: 5.3, y: 20.2))
        house.addQuadCurve(to: CGPoint(x: 7.1, y: 22), control: CGPoint(x: 5.3, y: 22))
        house.addLine(to: CGPoint(x: 16.9, y: 22))
        house.addQuadCurve(to: CGPoint(x: 18.7, y: 20.2), control: CGPoint(x: 18.7, y: 22))
        house.addLine(to: CGPoint(x: 18.7, y: 10))
        house.closeSubpath()
        context.fill(house, with: .color(wash))
        context.stroke(house, with: .color(outline), style: stroke)

        let door = Path(roundedRect: CGRect(x: 9.7, y: 15, width: 4.6, height: 7), cornerRadius: 1.5)
        context.stroke(door, with: .color(strongWash), lineWidth: 1.45)
    }

    private func drawFavorite(in context: inout GraphicsContext) {
        let points = [
            CGPoint(x: 12, y: 2.8), CGPoint(x: 14.7, y: 8.8),
            CGPoint(x: 21.2, y: 9.4), CGPoint(x: 16.2, y: 13.8),
            CGPoint(x: 17.8, y: 20.3), CGPoint(x: 12, y: 16.8),
            CGPoint(x: 6.2, y: 20.3), CGPoint(x: 7.8, y: 13.8),
            CGPoint(x: 2.8, y: 9.4), CGPoint(x: 9.3, y: 8.8),
        ]
        var star = Path()
        star.move(to: points[0])
        for point in points.dropFirst() { star.addLine(to: point) }
        star.closeSubpath()
        context.fill(star, with: .color(isSelected ? strongWash : wash))
        context.stroke(star, with: .color(outline), style: stroke)
    }

    private func drawRecent(in context: inout GraphicsContext) {
        let clock = Path(ellipseIn: CGRect(x: 3, y: 3, width: 18, height: 18))
        context.fill(clock, with: .color(wash))
        context.stroke(clock, with: .color(outline), style: stroke)

        var hands = Path()
        hands.move(to: CGPoint(x: 12, y: 6.7))
        hands.addLine(to: CGPoint(x: 12, y: 12))
        hands.addLine(to: CGPoint(x: 16.2, y: 14.4))
        context.stroke(
            hands,
            with: .color(strongWash),
            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawTag(in context: inout GraphicsContext) {
        var tag = Path()
        tag.move(to: CGPoint(x: 3, y: 9.1))
        tag.addQuadCurve(to: CGPoint(x: 8.8, y: 3.3), control: CGPoint(x: 5.6, y: 4.2))
        tag.addLine(to: CGPoint(x: 16, y: 3.3))
        tag.addQuadCurve(to: CGPoint(x: 20.7, y: 8), control: CGPoint(x: 20.7, y: 3.3))
        tag.addLine(to: CGPoint(x: 20.7, y: 12.4))
        tag.addLine(to: CGPoint(x: 11.1, y: 21.2))
        tag.addQuadCurve(to: CGPoint(x: 8.7, y: 21.1), control: CGPoint(x: 9.9, y: 22.2))
        tag.addLine(to: CGPoint(x: 3, y: 15.4))
        tag.addQuadCurve(to: CGPoint(x: 3, y: 9.1), control: CGPoint(x: 1, y: 12.2))
        tag.closeSubpath()
        context.fill(tag, with: .color(wash))
        context.stroke(tag, with: .color(outline), style: stroke)
        context.fill(Path(ellipseIn: CGRect(x: 14.2, y: 6.2, width: 3.2, height: 3.2)), with: .color(strongWash))
    }

    private func drawTrash(in context: inout GraphicsContext) {
        let body = Path(roundedRect: CGRect(x: 5.5, y: 7.3, width: 13, height: 14.2), cornerRadius: 2.4)
        context.fill(body, with: .color(wash))
        context.stroke(body, with: .color(outline), style: stroke)
        var lid = Path()
        lid.move(to: CGPoint(x: 3.5, y: 6.3))
        lid.addLine(to: CGPoint(x: 20.5, y: 6.3))
        lid.move(to: CGPoint(x: 9, y: 3.2))
        lid.addQuadCurve(to: CGPoint(x: 15, y: 3.2), control: CGPoint(x: 12, y: 1.8))
        context.stroke(lid, with: .color(outline), style: stroke)
        for x in [9.2, 14.8] {
            var slot = Path()
            slot.move(to: CGPoint(x: x, y: 10.3))
            slot.addLine(to: CGPoint(x: x, y: 18.5))
            context.stroke(slot, with: .color(strongWash), lineWidth: 1.35)
        }
    }

    private func drawSettings(in context: inout GraphicsContext) {
        for index in 0..<8 {
            let angle = Double(index) * .pi / 4
            let inner = CGPoint(x: 12 + cos(angle) * 7, y: 12 + sin(angle) * 7)
            let outer = CGPoint(x: 12 + cos(angle) * 9.4, y: 12 + sin(angle) * 9.4)
            var tooth = Path()
            tooth.move(to: inner)
            tooth.addLine(to: outer)
            context.stroke(tooth, with: .color(outline), style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
        }
        context.fill(Path(ellipseIn: CGRect(x: 4.7, y: 4.7, width: 14.6, height: 14.6)), with: .color(wash))
        context.stroke(Path(ellipseIn: CGRect(x: 4.7, y: 4.7, width: 14.6, height: 14.6)), with: .color(outline),
                       style: stroke)
        context.stroke(Path(ellipseIn: CGRect(x: 9.3, y: 9.3, width: 5.4, height: 5.4)), with: .color(strongWash),
                       lineWidth: 1.7)
    }

    private func drawSearch(in context: inout GraphicsContext) {
        let lens = Path(ellipseIn: CGRect(x: 3.2, y: 3.1, width: 13.2, height: 13.2))
        context.fill(lens, with: .color(wash))
        context.stroke(lens, with: .color(outline), style: stroke)
        var handle = Path()
        handle.move(to: CGPoint(x: 15.2, y: 15.1))
        handle.addLine(to: CGPoint(x: 21, y: 21))
        context.stroke(handle, with: .color(outline), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
    }

    private func drawFilter(in context: inout GraphicsContext) {
        let widths: [(CGFloat, CGFloat)] = [(3, 21), (5.5, 18.5), (8, 16)]
        for (index, pair) in widths.enumerated() {
            let y = CGFloat(6 + index * 6)
            var line = Path()
            line.move(to: CGPoint(x: pair.0, y: y))
            line.addLine(to: CGPoint(x: pair.1, y: y))
            context.stroke(line, with: .color(index == 0 ? outline : strongWash), style: stroke)
        }
    }

    private func drawGrid(in context: inout GraphicsContext) {
        for rect in [
            CGRect(x: 3.2, y: 3.2, width: 7, height: 7),
            CGRect(x: 13.8, y: 3.2, width: 7, height: 7),
            CGRect(x: 3.2, y: 13.8, width: 7, height: 7),
            CGRect(x: 13.8, y: 13.8, width: 7, height: 7),
        ] {
            let tile = Path(roundedRect: rect, cornerRadius: 1.8)
            context.fill(tile, with: .color(wash))
            context.stroke(tile, with: .color(outline), lineWidth: 1.45)
        }
    }

    private func drawList(in context: inout GraphicsContext) {
        for index in 0..<3 {
            let y = 5.5 + CGFloat(index) * 6.4
            context.fill(Path(ellipseIn: CGRect(x: 3, y: y - 1.2, width: 2.4, height: 2.4)), with: .color(strongWash))
            var line = Path()
            line.move(to: CGPoint(x: 8, y: y))
            line.addLine(to: CGPoint(x: 21, y: y))
            context.stroke(line, with: .color(outline), style: stroke)
        }
    }

    private func drawSelect(in context: inout GraphicsContext) {
        let circle = Path(ellipseIn: CGRect(x: 2.8, y: 2.8, width: 18.4, height: 18.4))
        if isSelected {
            context.fill(circle, with: .color(wash))
        }
        context.stroke(circle, with: .color(outline), style: stroke)
        if isSelected {
            drawConfirm(in: &context)
        }
    }

    private func drawCross(in context: inout GraphicsContext, rotated: Bool) {
        if rotated { context.rotate(by: .degrees(45), around: CGPoint(x: 12, y: 12)) }
        var path = Path()
        path.move(to: CGPoint(x: 12, y: 4))
        path.addLine(to: CGPoint(x: 12, y: 20))
        path.move(to: CGPoint(x: 4, y: 12))
        path.addLine(to: CGPoint(x: 20, y: 12))
        context.stroke(path, with: .color(outline), style: StrokeStyle(lineWidth: 2, lineCap: .round))
    }

    private func drawConfirm(in context: inout GraphicsContext) {
        var check = Path()
        check.move(to: CGPoint(x: 6.2, y: 12.2))
        check.addLine(to: CGPoint(x: 10.3, y: 16.4))
        check.addLine(to: CGPoint(x: 18.3, y: 7.8))
        context.stroke(check, with: .color(outline), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin:
            .round))
    }

    private func drawSidebar(in context: inout GraphicsContext) {
        let shell = Path(roundedRect: CGRect(x: 2.5, y: 4, width: 19, height: 16), cornerRadius: 3.2)
        context.fill(shell, with: .color(wash))
        context.stroke(shell, with: .color(outline), style: stroke)
        var divider = Path()
        divider.move(to: CGPoint(x: 8.6, y: 4.5))
        divider.addLine(to: CGPoint(x: 8.6, y: 19.5))
        context.stroke(divider, with: .color(strongWash), lineWidth: 1.5)
    }

    private func drawFolder(in context: inout GraphicsContext) {
        var back = Path()
        back.move(to: CGPoint(x: 2.4, y: 7))
        back.addQuadCurve(to: CGPoint(x: 4.6, y: 4.8), control: CGPoint(x: 2.4, y: 4.8))
        back.addLine(to: CGPoint(x: 10, y: 4.8))
        back.addLine(to: CGPoint(x: 12.2, y: 7))
        back.addLine(to: CGPoint(x: 19.4, y: 7))
        back.addQuadCurve(to: CGPoint(x: 21.6, y: 9.2), control: CGPoint(x: 21.6, y: 7))
        back.addLine(to: CGPoint(x: 21.6, y: 19.4))
        back.addQuadCurve(to: CGPoint(x: 19.4, y: 21.6), control: CGPoint(x: 21.6, y: 21.6))
        back.addLine(to: CGPoint(x: 4.6, y: 21.6))
        back.addQuadCurve(to: CGPoint(x: 2.4, y: 19.4), control: CGPoint(x: 2.4, y: 21.6))
        back.closeSubpath()
        context.fill(back, with: .color(wash))
        context.stroke(back, with: .color(outline), style: stroke)
        var lip = Path()
        lip.move(to: CGPoint(x: 2.7, y: 10.2))
        lip.addLine(to: CGPoint(x: 21.3, y: 10.2))
        context.stroke(lip, with: .color(strongWash), lineWidth: 1.4)
    }

    private func drawNotebook(in context: inout GraphicsContext) {
        let cover = Path(roundedRect: CGRect(x: 4.2, y: 2.4, width: 15.8, height: 19.2), cornerRadius: 2.7)
        context.fill(cover, with: .color(wash))
        context.stroke(cover, with: .color(outline), style: stroke)
        var binding = Path()
        binding.move(to: CGPoint(x: 7.7, y: 3))
        binding.addLine(to: CGPoint(x: 7.7, y: 21))
        binding.move(to: CGPoint(x: 11, y: 7.2))
        binding.addLine(to: CGPoint(x: 17.4, y: 7.2))
        binding.move(to: CGPoint(x: 11, y: 11))
        binding.addLine(to: CGPoint(x: 16, y: 11))
        context.stroke(binding, with: .color(strongWash), style: StrokeStyle(lineWidth: 1.25, lineCap: .round))
    }

    private func drawCanvas(in context: inout GraphicsContext) {
        let board = Path(roundedRect: CGRect(x: 2.8, y: 4, width: 18.4, height: 16), cornerRadius: 3)
        context.fill(board, with: .color(wash))
        context.stroke(board, with: .color(outline), style: stroke)
        var line = Path()
        line.move(to: CGPoint(x: 6, y: 14.7))
        line.addCurve(to: CGPoint(x: 18, y: 9), control1: CGPoint(x: 8, y: 4.7), control2: CGPoint(x: 10.7, y: 18.5))
        context.stroke(line, with: .color(strongWash), style: StrokeStyle(lineWidth: 2, lineCap: .round))
        context.fill(Path(ellipseIn: CGRect(x: 5.1, y: 7.3, width: 2.2, height: 2.2)), with:
            .color(outline.opacity(0.66)))
    }

    private func drawDocument(in context: inout GraphicsContext) {
        var page = Path()
        page.move(to: CGPoint(x: 5, y: 2.5))
        page.addLine(to: CGPoint(x: 14.8, y: 2.5))
        page.addLine(to: CGPoint(x: 20, y: 7.7))
        page.addLine(to: CGPoint(x: 20, y: 21.5))
        page.addLine(to: CGPoint(x: 5, y: 21.5))
        page.closeSubpath()
        context.fill(page, with: .color(wash))
        context.stroke(page, with: .color(outline), style: stroke)
        var fold = Path()
        fold.move(to: CGPoint(x: 14.7, y: 3))
        fold.addLine(to: CGPoint(x: 14.7, y: 8))
        fold.addLine(to: CGPoint(x: 19.5, y: 8))
        fold.move(to: CGPoint(x: 8.5, y: 12))
        fold.addLine(to: CGPoint(x: 16.7, y: 12))
        fold.move(to: CGPoint(x: 8.5, y: 16))
        fold.addLine(to: CGPoint(x: 15, y: 16))
        context.stroke(fold, with: .color(strongWash), style: StrokeStyle(lineWidth: 1.25, lineCap: .round, lineJoin:
            .round))
    }

    private func drawQuickNote(in context: inout GraphicsContext) {
        let note = Path(
            roundedRect: CGRect(x: 3.1, y: 3.1, width: 14.7, height: 17.8),
            cornerRadius: 3
        )
        context.fill(note, with: .color(wash))
        context.stroke(note, with: .color(outline), style: stroke)

        var noteLines = Path()
        noteLines.move(to: CGPoint(x: 6.3, y: 8))
        noteLines.addLine(to: CGPoint(x: 13.8, y: 8))
        noteLines.move(to: CGPoint(x: 6.3, y: 11.5))
        noteLines.addLine(to: CGPoint(x: 11.3, y: 11.5))
        context.stroke(
            noteLines,
            with: .color(strongWash.opacity(0.72)),
            style: StrokeStyle(lineWidth: 1.2, lineCap: .round)
        )

        var pencil = Path()
        pencil.move(to: CGPoint(x: 10.3, y: 17.6))
        pencil.addLine(to: CGPoint(x: 19.4, y: 8.5))
        context.stroke(
            pencil,
            with: .color(outline),
            style: StrokeStyle(lineWidth: 3.4, lineCap: .round)
        )
        context.stroke(
            pencil,
            with: .color(strongWash),
            style: StrokeStyle(lineWidth: 1.7, lineCap: .round)
        )

        var nib = Path()
        nib.move(to: CGPoint(x: 9.3, y: 18.7))
        nib.addLine(to: CGPoint(x: 10.4, y: 15.9))
        nib.addLine(to: CGPoint(x: 12.1, y: 17.6))
        nib.closeSubpath()
        context.fill(nib, with: .color(strongWash))
        context.stroke(nib, with: .color(outline), lineWidth: 1)
    }

    private func drawImportDocument(in context: inout GraphicsContext) {
        let page = Path(
            roundedRect: CGRect(x: 7.2, y: 5.1, width: 9.6, height: 13.8),
            cornerRadius: 2.1
        )
        context.fill(page, with: .color(wash))
        context.stroke(page, with: .color(strongWash), lineWidth: 1.35)

        var arrow = Path()
        arrow.move(to: CGPoint(x: 12, y: 8))
        arrow.addLine(to: CGPoint(x: 12, y: 14.3))
        arrow.move(to: CGPoint(x: 9.7, y: 12.2))
        arrow.addLine(to: CGPoint(x: 12, y: 14.6))
        arrow.addLine(to: CGPoint(x: 14.3, y: 12.2))
        context.stroke(
            arrow,
            with: .color(outline),
            style: StrokeStyle(lineWidth: 1.55, lineCap: .round, lineJoin: .round)
        )

        var corners = Path()
        corners.move(to: CGPoint(x: 3, y: 8))
        corners.addLine(to: CGPoint(x: 3, y: 4.8))
        corners.addQuadCurve(to: CGPoint(x: 4.8, y: 3), control: CGPoint(x: 3, y: 3))
        corners.addLine(to: CGPoint(x: 8, y: 3))

        corners.move(to: CGPoint(x: 16, y: 3))
        corners.addLine(to: CGPoint(x: 19.2, y: 3))
        corners.addQuadCurve(to: CGPoint(x: 21, y: 4.8), control: CGPoint(x: 21, y: 3))
        corners.addLine(to: CGPoint(x: 21, y: 8))

        corners.move(to: CGPoint(x: 21, y: 16))
        corners.addLine(to: CGPoint(x: 21, y: 19.2))
        corners.addQuadCurve(to: CGPoint(x: 19.2, y: 21), control: CGPoint(x: 21, y: 21))
        corners.addLine(to: CGPoint(x: 16, y: 21))

        corners.move(to: CGPoint(x: 8, y: 21))
        corners.addLine(to: CGPoint(x: 4.8, y: 21))
        corners.addQuadCurve(to: CGPoint(x: 3, y: 19.2), control: CGPoint(x: 3, y: 21))
        corners.addLine(to: CGPoint(x: 3, y: 16))
        context.stroke(
            corners,
            with: .color(outline),
            style: StrokeStyle(lineWidth: 1.75, lineCap: .round, lineJoin: .round)
        )
    }

    private func drawStudy(in context: inout GraphicsContext) {
        var cap = Path()
        cap.move(to: CGPoint(x: 2.3, y: 9))
        cap.addLine(to: CGPoint(x: 12, y: 4))
        cap.addLine(to: CGPoint(x: 21.7, y: 9))
        cap.addLine(to: CGPoint(x: 12, y: 14))
        cap.closeSubpath()
        context.fill(cap, with: .color(wash))
        context.stroke(cap, with: .color(outline), style: stroke)
        var base = Path()
        base.move(to: CGPoint(x: 6.2, y: 12))
        base.addLine(to: CGPoint(x: 6.2, y: 17.5))
        base.addQuadCurve(to: CGPoint(x: 17.8, y: 17.5), control: CGPoint(x: 12, y: 21))
        base.addLine(to: CGPoint(x: 17.8, y: 12))
        base.move(to: CGPoint(x: 19, y: 10))
        base.addLine(to: CGPoint(x: 19, y: 18.5))
        context.stroke(base, with: .color(outline), style: stroke)
        context.fill(Path(ellipseIn: CGRect(x: 17.8, y: 18, width: 2.4, height: 2.4)), with: .color(strongWash))
    }

    private func drawWork(in context: inout GraphicsContext) {
        let body = Path(roundedRect: CGRect(x: 2.6, y: 7.2, width: 18.8, height: 13.8), cornerRadius: 2.8)
        context.fill(body, with: .color(wash))
        context.stroke(body, with: .color(outline), style: stroke)
        var handle = Path()
        handle.move(to: CGPoint(x: 8.2, y: 7.1))
        handle.addLine(to: CGPoint(x: 8.2, y: 4.2))
        handle.addLine(to: CGPoint(x: 15.8, y: 4.2))
        handle.addLine(to: CGPoint(x: 15.8, y: 7.1))
        handle.move(to: CGPoint(x: 3.1, y: 13))
        handle.addLine(to: CGPoint(x: 20.9, y: 13))
        context.stroke(handle, with: .color(outline), style: stroke)
        context.fill(Path(roundedRect: CGRect(x: 10.3, y: 11.5, width: 3.4, height: 3), cornerRadius: 0.8), with:
            .color(strongWash))
    }

    private func drawArt(in context: inout GraphicsContext) {
        var palette = Path()
        palette.move(to: CGPoint(x: 12, y: 2.5))
        palette.addCurve(to: CGPoint(x: 21, y: 11), control1: CGPoint(x: 13, y: 1.5), control2: CGPoint(x: 22, y: 5))
        palette.addCurve(to: CGPoint(x: 15, y: 15), control1: CGPoint(x: 21, y: 15), control2: CGPoint(x: 18, y: 15))
        palette.addCurve(to: CGPoint(x: 11.5, y: 21.5), control1: CGPoint(x: 13, y: 15), control2: CGPoint(x: 15.2, y:
            21.5))
        palette.addCurve(to: CGPoint(x: 2.8, y: 12), control1: CGPoint(x: 5.5, y: 22), control2: CGPoint(x: 1.8, y:
            21))
        palette.addCurve(to: CGPoint(x: 12, y: 2.5), control1: CGPoint(x: 2.8, y: 6), control2: CGPoint(x: 7, y: 2.5))
        palette.closeSubpath()
        context.fill(palette, with: .color(wash))
        context.stroke(palette, with: .color(outline), style: stroke)
        for center in [CGPoint(x: 8, y: 7), CGPoint(x: 13, y: 6), CGPoint(x: 17, y: 9), CGPoint(x: 7, y: 13)] {
            context.fill(Path(ellipseIn: CGRect(x: center.x - 1.1, y: center.y - 1.1, width: 2.2, height: 2.2)), with:
                .color(strongWash))
        }
    }

    private func drawMusic(in context: inout GraphicsContext) {
        var stem = Path()
        stem.move(to: CGPoint(x: 9, y: 17))
        stem.addLine(to: CGPoint(x: 9, y: 6))
        stem.addLine(to: CGPoint(x: 19, y: 3.8))
        stem.addLine(to: CGPoint(x: 19, y: 15))
        stem.move(to: CGPoint(x: 9, y: 9.3))
        stem.addLine(to: CGPoint(x: 19, y: 7.1))
        context.stroke(stem, with: .color(outline), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin:
            .round))
        context.fill(Path(ellipseIn: CGRect(x: 3.8, y: 15.2, width: 6.8, height: 5.2)), with: .color(wash))
        context.stroke(Path(ellipseIn: CGRect(x: 3.8, y: 15.2, width: 6.8, height: 5.2)), with: .color(outline),
                       lineWidth: 1.5)
        context.fill(Path(ellipseIn: CGRect(x: 13.8, y: 13.2, width: 6.8, height: 5.2)), with: .color(wash))
        context.stroke(Path(ellipseIn: CGRect(x: 13.8, y: 13.2, width: 6.8, height: 5.2)), with: .color(outline),
                       lineWidth: 1.5)
    }

    private func drawTravel(in context: inout GraphicsContext) {
        var plane = Path()
        plane.move(to: CGPoint(x: 2.8, y: 13))
        plane.addLine(to: CGPoint(x: 21.5, y: 3.5))
        plane.addLine(to: CGPoint(x: 15.3, y: 20.5))
        plane.addLine(to: CGPoint(x: 11.3, y: 14.2))
        plane.addLine(to: CGPoint(x: 2.8, y: 13))
        plane.closeSubpath()
        context.fill(plane, with: .color(wash))
        context.stroke(plane, with: .color(outline), style: stroke)
        var fold = Path()
        fold.move(to: CGPoint(x: 11.3, y: 14.2))
        fold.addLine(to: CGPoint(x: 21.5, y: 3.5))
        context.stroke(fold, with: .color(strongWash), lineWidth: 1.3)
    }

    private func drawCode(in context: inout GraphicsContext) {
        var code = Path()
        code.move(to: CGPoint(x: 8.5, y: 5))
        code.addLine(to: CGPoint(x: 3.2, y: 12))
        code.addLine(to: CGPoint(x: 8.5, y: 19))
        code.move(to: CGPoint(x: 15.5, y: 5))
        code.addLine(to: CGPoint(x: 20.8, y: 12))
        code.addLine(to: CGPoint(x: 15.5, y: 19))
        code.move(to: CGPoint(x: 14, y: 3.5))
        code.addLine(to: CGPoint(x: 10, y: 20.5))
        context.stroke(code, with: .color(outline), style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin:
            .round))
    }

    private func drawIdea(in context: inout GraphicsContext) {
        let bulb = Path(ellipseIn: CGRect(x: 5.2, y: 2.5, width: 13.6, height: 13.6))
        context.fill(bulb, with: .color(wash))
        context.stroke(bulb, with: .color(outline), style: stroke)
        var base = Path()
        base.move(to: CGPoint(x: 8.7, y: 14.2))
        base.addLine(to: CGPoint(x: 9.8, y: 18))
        base.addLine(to: CGPoint(x: 14.2, y: 18))
        base.addLine(to: CGPoint(x: 15.3, y: 14.2))
        base.move(to: CGPoint(x: 9.5, y: 20.8))
        base.addLine(to: CGPoint(x: 14.5, y: 20.8))
        context.stroke(base, with: .color(outline), style: stroke)
        var filament = Path()
        filament.move(to: CGPoint(x: 9.5, y: 9.3))
        filament.addLine(to: CGPoint(x: 12, y: 12.2))
        filament.addLine(to: CGPoint(x: 14.5, y: 9.3))
        context.stroke(filament, with: .color(strongWash), lineWidth: 1.3)
    }

    private func drawPersonal(in context: inout GraphicsContext) {
        let head = Path(ellipseIn: CGRect(x: 8, y: 3, width: 8, height: 8))
        context.fill(head, with: .color(wash))
        context.stroke(head, with: .color(outline), style: stroke)
        var shoulders = Path()
        shoulders.move(to: CGPoint(x: 3.3, y: 21))
        shoulders.addCurve(to: CGPoint(x: 20.7, y: 21), control1: CGPoint(x: 4.5, y: 13), control2: CGPoint(x: 19.5,
            y: 13))
        context.fill(shoulders, with: .color(wash))
        context.stroke(shoulders, with: .color(outline), style: stroke)
    }
}

/// One rendering path for folder symbols across the editor, library artwork,
/// previews, and move destinations. Notate-owned pictograms are preferred;
/// persisted custom SF Symbols remain visible rather than collapsing to the
/// generic folder glyph.
struct NotateFolderGlyph: View {
    let symbolName: String
    var tint: Color = NotateDesign.Palette.accent
    var isSelected = false
    var size: CGFloat = 24
    var fallbackForeground: Color?

    var body: some View {
        Group {
            if let kind = NotateAppGlyphKind.customFolderGlyph(for: symbolName) {
                NotateAppGlyph(
                    kind: kind,
                    tint: tint,
                    isSelected: isSelected,
                    size: size
                )
            } else {
                Image(systemName: symbolName)
                    .symbolRenderingMode(.monochrome)
                    .font(.system(size: size * 0.84, weight: .semibold))
                    .foregroundStyle(fallbackForeground ?? tint)
                    .frame(width: size, height: size)
                    .accessibilityHidden(true)
            }
        }
    }
}

private extension GraphicsContext {
    mutating func rotate(by angle: Angle, around point: CGPoint) {
        translateBy(x: point.x, y: point.y)
        rotate(by: angle)
        translateBy(x: -point.x, y: -point.y)
    }
}
