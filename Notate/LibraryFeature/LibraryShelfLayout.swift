import SwiftUI

/// Column slots absorb surplus width; the artwork envelope stays the same
/// size across rotations, sidebar changes, and window resizing.
struct LibraryShelfLayout {
    let contentWidth: CGFloat
    let cardWidth: CGFloat
    let columnWidth: CGFloat
    let columnCount: Int

    init(availableWidth: CGFloat, horizontalPadding: CGFloat, zoom: Double) {
        let width = availableWidth.isFinite ? max(0, availableWidth) : 0
        contentWidth = max(0, min(width, NotateLibraryDesign.contentMaximumWidth)
                           - horizontalPadding * 2)
        let preferredWidth = NotateDesign.Library.Shelf.envelopeWidth(for: zoom)
        let gap = NotateDesign.Library.Shelf.columnSpacing
        columnCount = max(1, Int((contentWidth + gap) / (preferredWidth + gap)))
        cardWidth = min(contentWidth, preferredWidth)
        columnWidth = max(0, (contentWidth - gap * CGFloat(columnCount - 1))
                          / CGFloat(columnCount))
    }

    var columns: [GridItem] {
        Array(repeating: GridItem(.fixed(columnWidth),
                                  spacing: NotateDesign.Library.Shelf.columnSpacing,
                                  alignment: .top), count: columnCount)
    }
}

/// Art surfaces publish their actual bounds so badges follow the physical
/// thumbnail rather than the larger square envelope surrounding it.
struct LibraryArtworkBoundsKey: PreferenceKey {
    nonisolated static var defaultValue: [Anchor<CGRect>] { [] }

    nonisolated static func reduce(value: inout [Anchor<CGRect>],
                                  nextValue: () -> [Anchor<CGRect>]) {
        value.append(contentsOf: nextValue())
    }
}

extension View {
    func libraryArtworkBounds() -> some View {
        anchorPreference(key: LibraryArtworkBoundsKey.self, value: .bounds) { [$0] }
    }
}
