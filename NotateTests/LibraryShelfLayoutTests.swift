import XCTest
@testable import Notate

@MainActor
final class LibraryShelfLayoutTests: XCTestCase {
    private typealias Shelf = NotateDesign.Library.Shelf

    func testDefaultArtworkDimensionsAndSpacing() {
        let envelope = Shelf.envelopeWidth(for: Shelf.comfortableZoom)
        let bounds = LibraryArtworkGeometry.artworkFitBounds(inside: CGSize(width: envelope, height: envelope))
        let notebook = LibraryArtworkGeometry.aspectFitSize(
            source: CGSize(width: Shelf.notebookAspectRatio, height: 1), inside: bounds)
        XCTAssertEqual(envelope, 168)
        XCTAssertEqual(notebook.width, 129 * 168 / 184, accuracy: 0.001)
        XCTAssertEqual(notebook.height, 172 * 168 / 184, accuracy: 0.001)
        let folder = LibraryArtworkGeometry.folderSize(inside: CGSize(width: envelope, height: envelope))
        XCTAssertEqual(folder.width, 160 * 168 / 184, accuracy: 0.001)
        XCTAssertEqual(folder.height, (160 * 168 / 184) / Shelf.folderAspectRatio, accuracy: 0.001)
        XCTAssertEqual(Shelf.artworkInset + Shelf.labelSpacing, 12)
        XCTAssertEqual(Shelf.metadataSpacing, 4)
        XCTAssertEqual(Shelf.rowSpacing, 32)
    }

    func testColumnBoundariesAtEveryTileSize() {
        for zoom in [Shelf.smallZoom, Shelf.comfortableZoom, Shelf.largeZoom] {
            let width = Shelf.envelopeWidth(for: zoom)
            for count in 2...6 {
                let threshold = CGFloat(count) * width
                    + CGFloat(count - 1) * Shelf.columnSpacing + 56
                guard threshold <= NotateLibraryDesign.contentMaximumWidth else { continue }
                let below = layout(threshold - 0.01, zoom: zoom)
                let exact = layout(threshold, zoom: zoom)
                let above = layout(threshold + 0.01, zoom: zoom)
                XCTAssertEqual(below.columnCount, count - 1)
                XCTAssertEqual(exact.columnCount, count)
                XCTAssertEqual(above.columnCount, count)
                XCTAssertEqual(exact.cardWidth, width)
                XCTAssertEqual(above.cardWidth, width)
            }
        }
    }

    func testRotationAndSidebarWidthsKeepArtworkStable() {
        for width: CGFloat in [744, 1_032, 1_376, 1_312, 400] {
            let value = layout(width)
            XCTAssertEqual(value.cardWidth, 168)
            XCTAssertGreaterThanOrEqual(value.columnWidth, value.cardWidth)
            XCTAssertEqual(CGFloat(value.columnCount) * value.columnWidth
                           + CGFloat(value.columnCount - 1) * Shelf.columnSpacing,
                           value.contentWidth, accuracy: 0.001)
        }
        XCTAssertGreaterThan(layout(1_520).columnCount, 5)
    }

    func testNarrowWidthsOnlyShrinkWhenOneCardCannotFit() {
        let phone = LibraryShelfLayout(availableWidth: 390, horizontalPadding: 16,
                                       zoom: Shelf.comfortableZoom)
        XCTAssertEqual(phone.columnCount, 1)
        XCTAssertEqual(phone.cardWidth, 168)
        let narrow = layout(200)
        XCTAssertEqual(narrow.columnCount, 1)
        XCTAssertEqual(narrow.cardWidth, 144)
        XCTAssertEqual(layout(0).cardWidth, 0)
        XCTAssertEqual(layout(.infinity).cardWidth, 0)
        XCTAssertEqual(layout(2_000).contentWidth, 1_464)
    }

    func testZoomInterpolationClampingAndMenuMidpoints() {
        XCTAssertEqual(Shelf.envelopeWidth(for: 0.72), 144)
        XCTAssertEqual(Shelf.envelopeWidth(for: 0.84), 168)
        XCTAssertEqual(Shelf.envelopeWidth(for: 1.48), 200)
        XCTAssertEqual(Shelf.envelopeWidth(for: 0.78), 156, accuracy: 0.001)
        XCTAssertEqual(Shelf.envelopeWidth(for: 1.16), 184, accuracy: 0.001)
        XCTAssertEqual(Shelf.envelopeWidth(for: -1), 144)
        XCTAssertEqual(Shelf.envelopeWidth(for: 2), 200)
        XCTAssertEqual(Shelf.envelopeWidth(for: .nan), 168)
        XCTAssertEqual(Shelf.tileSizeSelection(for: 0.779), 0)
        XCTAssertEqual(Shelf.tileSizeSelection(for: 0.781), 1)
        XCTAssertEqual(Shelf.tileSizeSelection(for: 0.84), 1)
        XCTAssertEqual(Shelf.tileSizeSelection(for: 1.159), 1)
        XCTAssertEqual(Shelf.tileSizeSelection(for: 1.161), 2)
        for preset in 0...2 {
            XCTAssertEqual(Shelf.tileSizeSelection(for: Shelf.zoom(for: preset)), preset)
        }
    }

    func testAspectFitKeepsPortraitLandscapeAndDocumentRatios() {
        let bounds = CGSize(width: 172, height: 172)
        for source in [CGSize(width: 595, height: 842), CGSize(width: 4, height: 3),
                       CGSize(width: 3, height: 4), CGSize(width: 16, height: 9)] {
            let fit = LibraryArtworkGeometry.aspectFitSize(source: source, inside: bounds)
            XCTAssertLessThanOrEqual(fit.width, bounds.width)
            XCTAssertLessThanOrEqual(fit.height, bounds.height)
            XCTAssertEqual(fit.width / fit.height, source.width / source.height,
                           accuracy: 0.001)
        }
        XCTAssertEqual(LibraryArtworkGeometry.aspectFitSize(source: .zero, inside: bounds), .zero)
        XCTAssertEqual(LibraryArtworkGeometry.aspectFitSize(
            source: CGSize(width: CGFloat.infinity, height: 1), inside: bounds), .zero)
    }

    func testArtworkProportionsScaleWithEveryEnvelope() {
        for envelope in [Shelf.smallEnvelope, Shelf.comfortableEnvelope, Shelf.largeEnvelope] {
            let bounds = CGSize(width: envelope, height: envelope)
            let fit = LibraryArtworkGeometry.aspectFitSize(
                source: CGSize(width: 3, height: 4),
                inside: LibraryArtworkGeometry.artworkFitBounds(inside: bounds))
            XCTAssertEqual(fit.width, 129 * envelope / 184, accuracy: 0.001)
            XCTAssertEqual(fit.height, 172 * envelope / 184, accuracy: 0.001)
            XCTAssertEqual(LibraryArtworkGeometry.folderSize(inside: bounds).width,
                           160 * envelope / 184, accuracy: 0.001)
            XCTAssertEqual(Shelf.artworkInset + Shelf.labelSpacing, 12)
        }
    }

    private func layout(_ width: CGFloat, zoom: Double = Shelf.comfortableZoom) -> LibraryShelfLayout {
        LibraryShelfLayout(availableWidth: width, horizontalPadding: 28, zoom: zoom)
    }
}
