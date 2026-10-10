#if DEBUG || NOTATE_INK_PROFILING
import Foundation
import PaperKit
import PencilKit
import UIKit

struct CanvasPageRepositoryStressFixtureReceipt: Sendable {
    let rootURL: URL
    let generation: Int64
    let pageCount: Int
    let strokesPerPage: Int
    let uniquePayloadCount: Int
    let usesDistinctPageContent: Bool
}

/// Builds dense v7 fixtures with one page resident during each encode. The
/// shared variant checks payload deduplication; the distinct variant prevents
/// deduplication from hiding storage and decode costs.
@MainActor
enum CanvasPageRepositoryStressFixtureBuilder {
    static func build(
        at rootURL: URL,
        pageCount: Int = 500,
        strokesPerPage: Int = 1_000,
        usesDistinctPageContent: Bool
    ) async throws -> CanvasPageRepositoryStressFixtureReceipt {
        guard (1...CanvasPageRepository.maximumPageCount).contains(pageCount),
              (1...10_000).contains(strokesPerPage) else {
            throw CanvasPageRepositoryError.invalidCatalog(
                "Stress fixtures support 1–1,000 pages and 1–10,000 strokes per page."
            )
        }

        let pageIDs = (0..<pageCount).map { _ in UUID() }
        let indicesByID = Dictionary(uniqueKeysWithValues: pageIDs.enumerated().map { ($0.element, $0.offset) })
        let styles: [CanvasPaperStyle] = [.blank, .ruled, .grid, .dotted]
        let templates = pageIDs.enumerated().map { index, _ in
            CanvasPaperTemplate(style: styles[index % styles.count])
        }
        let geometry = CanvasPageGeometry(authoredSize: CanvasConstants.a4PortraitSize)
        let descriptors = pageIDs.enumerated().map { index, pageID in
            CanvasPageDescriptor(
                id: pageID,
                contentRevision: 1,
                viewport: CanvasViewportState(),
                paperTemplate: templates[index],
                geometry: geometry
            )
        }
        let sharedMarkup = usesDistinctPageContent
            ? nil
            : try makeMarkup(strokesPerPage: strokesPerPage, pageIndex: 0)
        let repository = CanvasPageRepository(rootURL: rootURL)
        let commit: CanvasVerifiedCommit
        if usesDistinctPageContent {
            commit = try await repository.commitResolvingPages(
                expectedGeneration: 0,
                generation: 1,
                currentPageID: pageIDs[0],
                pages: descriptors
            ) { descriptor in
                guard let index = indicesByID[descriptor.id] else { return nil }
                return try await makePage(
                    descriptor: descriptor,
                    strokesPerPage: strokesPerPage,
                    pageIndex: index,
                    sharedMarkup: nil
                )
            }
        } else {
            let firstDescriptor = descriptors[0]
            let firstPage = try makePage(
                descriptor: firstDescriptor,
                strokesPerPage: strokesPerPage,
                pageIndex: 0,
                sharedMarkup: sharedMarkup
            )
            let initial = try await repository.commit(
                expectedGeneration: 0,
                generation: 1,
                currentPageID: pageIDs[0],
                pages: [firstDescriptor],
                changedPages: [firstPage.id: firstPage]
            )
            guard pageCount > 1 else {
                commit = initial
                return CanvasPageRepositoryStressFixtureReceipt(
                    rootURL: rootURL,
                    generation: initial.catalog.generation,
                    pageCount: initial.catalog.pages.count,
                    strokesPerPage: strokesPerPage,
                    uniquePayloadCount: 1,
                    usesDistinctPageContent: false
                )
            }
            guard let sharedReference = initial.catalog.reference(for: firstPage.id) else {
                throw CanvasPageRepositoryError.invalidCatalog("The first stress-fixture payload could not be referenced.")
            }
            let duplicateDescriptors = [firstDescriptor] + descriptors.dropFirst().map { descriptor in
                CanvasPageDescriptor(
                    id: descriptor.id,
                    contentRevision: descriptor.contentRevision,
                    viewport: descriptor.viewport,
                    paperTemplate: descriptor.paperTemplate,
                    geometry: descriptor.geometry,
                    background: descriptor.background,
                    sharedPayloadReference: sharedReference
                )
            }
            commit = try await repository.commitResolvingPages(
                expectedGeneration: 1,
                generation: 2,
                currentPageID: pageIDs[0],
                pages: duplicateDescriptors,
                resolveChangedPage: { _ in nil }
            )
        }
        return CanvasPageRepositoryStressFixtureReceipt(
            rootURL: rootURL,
            generation: commit.catalog.generation,
            pageCount: commit.catalog.pages.count,
            strokesPerPage: strokesPerPage,
            uniquePayloadCount: Set(commit.catalog.pages.map(\.payloadChecksum)).count,
            usesDistinctPageContent: usesDistinctPageContent
        )
    }

    private static func makePage(
        descriptor: CanvasPageDescriptor,
        strokesPerPage: Int,
        pageIndex: Int,
        sharedMarkup: PaperMarkup?
    ) throws -> CanvasPageSnapshot {
        let markup = try sharedMarkup ?? makeMarkup(
            strokesPerPage: strokesPerPage,
            pageIndex: pageIndex
        )
        return CanvasPageSnapshot(
            id: descriptor.id,
            markup: markup,
            viewport: descriptor.viewport,
            paperTemplate: descriptor.paperTemplate,
            geometry: descriptor.geometry
        )
    }

    private static func makeMarkup(strokesPerPage: Int, pageIndex: Int) throws -> PaperMarkup {
        let bounds = CGRect(origin: .zero, size: CanvasConstants.a4PortraitSize)
        var strokes: [PKStroke] = []
        strokes.reserveCapacity(strokesPerPage)
        let columnCount = 32
        let offsetX = Double(pageIndex) * 0.01
        for strokeIndex in 0..<strokesPerPage {
            if strokeIndex.isMultiple(of: 256) { try Task.checkCancellation() }
            let column = strokeIndex % columnCount
            let row = strokeIndex / columnCount
            let originX = 28.0 + Double(column) * 17.2 + offsetX
            let originY = 88.0 + Double(row % 42) * 18.0
            var points: [PKStrokePoint] = []
            points.reserveCapacity(6)
            for pointIndex in 0..<6 {
                let x = originX + Double(pointIndex) * 1.2
                let y = originY + sin(Double(pointIndex) * 0.65 + Double(strokeIndex % 31)) * 1.1
                points.append(PKStrokePoint(
                    location: CGPoint(x: x, y: y),
                    timeOffset: Double(pointIndex) / 120,
                    size: CGSize(width: 0.7, height: 0.7),
                    opacity: 1,
                    force: 1,
                    azimuth: 0,
                    altitude: .pi / 2
                ))
            }
            let path = PKStrokePath(
                controlPoints: points,
                creationDate: Date(timeIntervalSince1970: 0)
            )
            strokes.append(PKStroke(ink: PKInk(.pen, color: .black), path: path))
        }
        var markup = PaperMarkup(bounds: bounds)
        markup.append(contentsOf: PKDrawing(strokes: strokes))
        return markup
    }
}
#endif
