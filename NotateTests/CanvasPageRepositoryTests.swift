import CoreGraphics
import Foundation
import PaperKit
import XCTest
@testable import Notate

private actor CountingCanvasPageCodec: CanvasCoreMarkupCoding {
    private var encodeCount = 0
    private var decodeCount = 0
    private let base = PaperKitCanvasCoreCodec()

    func encode(_ markup: PaperMarkup) async throws -> Data {
        encodeCount += 1
        return try await base.encode(markup)
    }

    func decode(_ data: Data) async throws -> PaperMarkup {
        decodeCount += 1
        return try await base.decode(data)
    }

    func counts() -> (encodes: Int, decodes: Int) {
        (encodeCount, decodeCount)
    }
}

private actor PausedCanvasPageCodec: CanvasCoreMarkupCoding {
    private let base = PaperKitCanvasCoreCodec()
    private var encodingStarted = false
    private var startedContinuation: CheckedContinuation<Void, Never>?
    private var resumeContinuation: CheckedContinuation<Void, Never>?

    func encode(_ markup: PaperMarkup) async throws -> Data {
        encodingStarted = true
        startedContinuation?.resume()
        startedContinuation = nil
        await withCheckedContinuation { resumeContinuation = $0 }
        return try await base.encode(markup)
    }

    func decode(_ data: Data) async throws -> PaperMarkup {
        try await base.decode(data)
    }

    func waitUntilEncodingStarts() async {
        guard !encodingStarted else { return }
        await withCheckedContinuation { startedContinuation = $0 }
    }

    func resumeEncoding() {
        resumeContinuation?.resume()
        resumeContinuation = nil
    }
}

private actor PauseSecondCanvasPageEncodeCodec: CanvasCoreMarkupCoding {
    private let base = PaperKitCanvasCoreCodec()
    private var encodeCount = 0
    private var secondEncodeContinuation: CheckedContinuation<Void, Never>?
    private var secondEncodeStartedContinuation: CheckedContinuation<Void, Never>?

    func encode(_ markup: PaperMarkup) async throws -> Data {
        encodeCount += 1
        if encodeCount == 2 {
            secondEncodeStartedContinuation?.resume()
            secondEncodeStartedContinuation = nil
            await withCheckedContinuation { secondEncodeContinuation = $0 }
        }
        return try await base.encode(markup)
    }

    func decode(_ data: Data) async throws -> PaperMarkup {
        try await base.decode(data)
    }

    func waitUntilSecondEncodeStarts() async {
        guard encodeCount < 2 else { return }
        await withCheckedContinuation { secondEncodeStartedContinuation = $0 }
    }

    func resumeSecondEncode() {
        secondEncodeContinuation?.resume()
        secondEncodeContinuation = nil
    }
}

private actor CanvasPageResolutionRecorder {
    private var pageIDs: [UUID] = []
    private var mismatchCount = 0

    func record(_ pageID: UUID) { pageIDs.append(pageID) }
    func record(_ pageID: UUID, descriptorID: UUID) {
        pageIDs.append(pageID)
        if pageID != descriptorID { mismatchCount += 1 }
    }
    func recordedPageIDs() -> [UUID] { pageIDs }
    func mismatches() -> Int { mismatchCount }
}

@MainActor
final class CanvasPageRepositoryTests: XCTestCase {
    func testCatalogOpenIsMetadataOnlyAndDuplicatePagesSharePayload() async throws {
        let root = temporaryNotebookURL()
        defer { try? FileManager.default.removeItem(at: root) }

        let codec = CountingCanvasPageCodec()
        let repository = CanvasPageRepository(rootURL: root, codec: codec)
        let markup = PaperMarkup(bounds: CGRect(origin: .zero, size: CanvasConstants.a4PortraitSize))
        let first = CanvasPageSnapshot(id: UUID(), markup: markup)
        let second = CanvasPageSnapshot(id: UUID(), markup: markup)
        let descriptors = try [first, second].enumerated().map { index, page in
            try CanvasPageDescriptor(page: page, contentRevision: UInt64(index + 1))
        }

        let firstCommit = try await repository.commit(
            expectedGeneration: 0,
            generation: 1,
            currentPageID: first.id,
            pages: descriptors,
            changedPages: [first.id: first, second.id: second]
        )
        XCTAssertEqual(firstCommit.catalog.pages[0].payloadChecksum, firstCommit.catalog.pages[1].payloadChecksum)
        XCTAssertEqual(firstCommit.committedRevisions[first.id], 1)
        XCTAssertEqual(firstCommit.committedRevisions[second.id], 2)
        let countsAfterCommit = await codec.counts()
        XCTAssertEqual(countsAfterCommit.encodes, 2)

        let lease = try await repository.acquireCatalogLease()
        let countsAfterOpen = await codec.counts()
        XCTAssertEqual(countsAfterOpen.decodes, 0, "Opening a large notebook must not decode all of its pages.")
        let firstReference = try XCTUnwrap(lease.catalog.reference(for: first.id))
        let decoded = try await repository.loadPage(firstReference, using: lease)
        XCTAssertEqual(decoded.id, first.id)
        let countsAfterResolve = await codec.counts()
        XCTAssertEqual(countsAfterResolve.decodes, 1)
        await repository.release(lease)

        let movedViewport = CanvasViewportState(
            normalizedCenterX: 0.5,
            normalizedCenterY: 0.4,
            visibleWidth: Double(CanvasConstants.a4PortraitSize.width),
            usesFitPage: false
        )
        let metadataOnlyDescriptors = [
            CanvasPageDescriptor(
                id: first.id,
                contentRevision: 1,
                viewport: movedViewport,
                paperTemplate: first.paperTemplate,
                geometry: first.geometry,
                background: .paper
            ),
            descriptors[1],
        ]
        let metadataCommit = try await repository.commit(
            expectedGeneration: 1,
            generation: 2,
            currentPageID: first.id,
            pages: metadataOnlyDescriptors,
            changedPages: [:]
        )
        XCTAssertEqual(metadataCommit.catalog.pages[0].payloadChecksum, firstCommit.catalog.pages[0].payloadChecksum)
        let countsAfterMetadata = await codec.counts()
        XCTAssertEqual(countsAfterMetadata.encodes, 2, "Viewport/navigation metadata must reuse the ink payload.")
        let metrics = await repository.metrics()
        XCTAssertEqual(metrics.markupEncodeCount, 2)
        XCTAssertEqual(metrics.markupDecodeCount, 1)
        XCTAssertEqual(metrics.pageResolveCount, 1)
        XCTAssertEqual(metrics.evictableEncodedCacheBytes, 0)
        XCTAssertEqual(metrics.derivedImageCacheBytes, 0)
    }

    func testSharedPayloadReferenceAddsDuplicateWithoutReencodingMarkup() async throws {
        let root = temporaryNotebookURL()
        defer { try? FileManager.default.removeItem(at: root) }

        let codec = CountingCanvasPageCodec()
        let repository = CanvasPageRepository(rootURL: root, codec: codec)
        let markup = PaperMarkup(bounds: CGRect(origin: .zero, size: CanvasConstants.a4PortraitSize))
        let original = CanvasPageSnapshot(id: UUID(), markup: markup)
        let originalDescriptor = try CanvasPageDescriptor(page: original, contentRevision: 1)
        let initial = try await repository.commit(
            expectedGeneration: 0,
            generation: 1,
            currentPageID: original.id,
            pages: [originalDescriptor],
            changedPages: [original.id: original]
        )
        let originalReference = try XCTUnwrap(initial.catalog.reference(for: original.id))

        let duplicateID = UUID()
        let duplicate = CanvasPageDescriptor(
            id: duplicateID,
            contentRevision: 1,
            viewport: original.viewport,
            paperTemplate: original.paperTemplate,
            geometry: original.geometry,
            background: .paper,
            sharedPayloadReference: originalReference
        )
        let committed = try await repository.commitResolvingPages(
            expectedGeneration: 1,
            generation: 2,
            currentPageID: original.id,
            pages: [originalDescriptor, duplicate],
            resolveChangedPage: { _ in nil }
        )

        XCTAssertEqual(committed.catalog.page(id: original.id)?.payloadChecksum,
                       committed.catalog.page(id: duplicateID)?.payloadChecksum)
        let counts = await codec.counts()
        XCTAssertEqual(counts.encodes, 1)
        XCTAssertEqual(committed.committedRevisions[duplicateID], 1)
    }

    func testStreamingCommitResolvesAndEncodesPagesIndividually() async throws {
        let root = temporaryNotebookURL()
        defer { try? FileManager.default.removeItem(at: root) }

        let codec = CountingCanvasPageCodec()
        let repository = CanvasPageRepository(rootURL: root, codec: codec)
        let descriptors = (0..<4).map { _ in
            CanvasPageDescriptor(
                id: UUID(),
                contentRevision: 1,
                viewport: CanvasViewportState(),
                paperTemplate: .default,
                geometry: CanvasPageGeometry(authoredSize: CanvasConstants.a4PortraitSize)
            )
        }
        let recorder = CanvasPageResolutionRecorder()
        let result = try await repository.commitResolvingPages(
            expectedGeneration: 0,
            generation: 1,
            currentPageID: try XCTUnwrap(descriptors.first?.id),
            pages: descriptors
        ) { descriptor in
            await recorder.record(descriptor.id)
            return CanvasPageSnapshot(
                id: descriptor.id,
                markup: PaperMarkup(bounds: CGRect(origin: .zero, size: CanvasConstants.a4PortraitSize)),
                viewport: descriptor.viewport,
                paperTemplate: descriptor.paperTemplate,
                geometry: descriptor.geometry
            )
        }

        let resolvedPageIDs = await recorder.recordedPageIDs()
        let codecCounts = await codec.counts()
        XCTAssertEqual(Set(resolvedPageIDs), Set(descriptors.map(\.id)))
        XCTAssertEqual(result.changedPageIDs.count, descriptors.count)
        XCTAssertEqual(codecCounts.encodes, descriptors.count)
    }

    func testReaderStyleEnumerationResolvesPagesInCatalogOrderOneAtATime() async throws {
        let root = temporaryNotebookURL()
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = CanvasPageRepository(rootURL: root)
        let pages = (0..<3).map { _ in
            CanvasPageSnapshot(
                id: UUID(),
                markup: PaperMarkup(bounds: CGRect(origin: .zero, size: CanvasConstants.a4PortraitSize))
            )
        }
        let descriptors = try pages.enumerated().map { index, page in
            try CanvasPageDescriptor(page: page, contentRevision: UInt64(index + 1))
        }
        _ = try await repository.commit(
            expectedGeneration: 0,
            generation: 1,
            currentPageID: pages[0].id,
            pages: descriptors,
            changedPages: Dictionary(uniqueKeysWithValues: pages.map { ($0.id, $0) })
        )
        let lease = try await repository.acquireCatalogLease()
        let recorder = CanvasPageResolutionRecorder()

        try await repository.forEachPage(using: lease) { descriptor, page in
            await recorder.record(page.id, descriptorID: descriptor.id)
        }

        let resolvedIDs = await recorder.recordedPageIDs()
        XCTAssertEqual(resolvedIDs, pages.map(\.id))
        let mismatchCount = await recorder.mismatches()
        XCTAssertEqual(mismatchCount, 0)
        let metrics = await repository.metrics()
        XCTAssertEqual(metrics.pageResolveCount, 3)
        XCTAssertEqual(metrics.markupDecodeCount, 3)
        await repository.release(lease)
    }

    func testGarbageCollectionKeepsPayloadsPinnedUntilManifestPublication() async throws {
        let root = temporaryNotebookURL()
        defer { try? FileManager.default.removeItem(at: root) }

        let codec = PauseSecondCanvasPageEncodeCodec()
        let repository = CanvasPageRepository(rootURL: root, codec: codec)
        let firstPage = CanvasPageSnapshot(
            id: UUID(),
            markup: PaperMarkup(bounds: CGRect(origin: .zero, size: CanvasConstants.a4PortraitSize)),
            background: .image(data: Data([0x01, 0x02]), suggestedName: "pending.png", sourceRelativePath: "pending.png")
        )
        let secondPage = CanvasPageSnapshot(
            id: UUID(),
            markup: PaperMarkup(bounds: CGRect(origin: .zero, size: CanvasConstants.a4PortraitSize))
        )
        let pagesByID = [firstPage.id: firstPage, secondPage.id: secondPage]
        let descriptors = try [firstPage, secondPage].map {
            try CanvasPageDescriptor(page: $0, contentRevision: 1)
        }
        let saving = Task {
            try await repository.commitResolvingPages(
                expectedGeneration: 0,
                generation: 1,
                currentPageID: try XCTUnwrap(descriptors.first?.id),
                pages: descriptors
            ) { descriptor in
                pagesByID[descriptor.id]
            }
        }

        await codec.waitUntilSecondEncodeStarts()
        let payloadDirectory = root.appendingPathComponent("Pages", isDirectory: true)
        let filesBeforeCollection = try FileManager.default.contentsOfDirectory(atPath: payloadDirectory.path)
        XCTAssertEqual(filesBeforeCollection.filter { $0.hasSuffix(".page") }.count, 1)
        let removedPayloads = try await repository.collectUnreferencedPayloads()
        XCTAssertTrue(removedPayloads.isEmpty)
        let filesAfterCollection = try FileManager.default.contentsOfDirectory(atPath: payloadDirectory.path)
        XCTAssertEqual(filesAfterCollection.filter { $0.hasSuffix(".page") }.count, 1)
        let removedSources = try await repository.collectUnreferencedSources()
        XCTAssertTrue(removedSources.isEmpty)
        let sourceURL = root.appendingPathComponent("Sources/pending.png")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sourceURL.path))

        await codec.resumeSecondEncode()
        _ = try await saving.value
    }

    func testDenseFixtureBuilderProducesSharedAndDistinctPageSets() async throws {
        let sharedRoot = temporaryNotebookURL()
        let distinctRoot = temporaryNotebookURL()
        defer {
            try? FileManager.default.removeItem(at: sharedRoot)
            try? FileManager.default.removeItem(at: distinctRoot)
        }

        let shared = try await CanvasPageRepositoryStressFixtureBuilder.build(
            at: sharedRoot,
            pageCount: 3,
            strokesPerPage: 24,
            usesDistinctPageContent: false
        )
        let distinct = try await CanvasPageRepositoryStressFixtureBuilder.build(
            at: distinctRoot,
            pageCount: 3,
            strokesPerPage: 24,
            usesDistinctPageContent: true
        )

        XCTAssertEqual(shared.pageCount, 3)
        XCTAssertEqual(shared.strokesPerPage, 24)
        XCTAssertEqual(shared.uniquePayloadCount, 1)
        XCTAssertEqual(distinct.uniquePayloadCount, 3)
    }

    func testFiveHundredPageSharedFixtureKeepsOneThousandStrokePayload() async throws {
        let root = temporaryNotebookURL()
        defer { try? FileManager.default.removeItem(at: root) }

        let receipt = try await CanvasPageRepositoryStressFixtureBuilder.build(
            at: root,
            pageCount: 500,
            strokesPerPage: 1_000,
            usesDistinctPageContent: false
        )

        XCTAssertEqual(receipt.pageCount, 500)
        XCTAssertEqual(receipt.strokesPerPage, 1_000)
        XCTAssertEqual(receipt.uniquePayloadCount, 1)
        let repository = CanvasPageRepository(rootURL: root)
        let lease = try await repository.acquireCatalogLease()
        XCTAssertEqual(lease.catalog.pages.count, 500)
        XCTAssertEqual(Set(lease.catalog.pages.map(\.payloadChecksum)).count, 1)
        for (index, entry) in lease.catalog.pages.enumerated() {
            XCTAssertEqual(lease.catalog.pageIndex(for: entry.id), index)
            XCTAssertEqual(lease.catalog.page(id: entry.id)?.id, entry.id)
        }
        XCTAssertNil(lease.catalog.pageIndex(for: UUID()))

        // The lookup index is an in-memory acceleration only; the persisted
        // catalog remains the compact, stable generation schema.
        let encodedCatalog = try JSONEncoder().encode(lease.catalog)
        let decodedCatalog = try JSONDecoder().decode(
            CanvasPageCatalog.self,
            from: encodedCatalog
        )
        XCTAssertEqual(decodedCatalog, lease.catalog)
        XCTAssertEqual(decodedCatalog.pageIndex(for: lease.catalog.pages[499].id), 499)
        await repository.release(lease)
    }

    func testFiveHundredDistinctDensePagesDoNotHideStorageBehindDeduplication() async throws {
        let root = temporaryNotebookURL()
        defer { try? FileManager.default.removeItem(at: root) }

        let receipt = try await CanvasPageRepositoryStressFixtureBuilder.build(
            at: root,
            pageCount: 500,
            strokesPerPage: 1_000,
            usesDistinctPageContent: true
        )

        XCTAssertEqual(receipt.pageCount, 500)
        XCTAssertEqual(receipt.strokesPerPage, 1_000)
        XCTAssertEqual(receipt.uniquePayloadCount, 500)
        let repository = CanvasPageRepository(rootURL: root)
        let lease = try await repository.acquireCatalogLease()
        XCTAssertEqual(lease.catalog.pages.count, 500)
        XCTAssertEqual(Set(lease.catalog.pages.map(\.payloadChecksum)).count, 500)
        let metricsAfterOpen = await repository.metrics()
        XCTAssertEqual(metricsAfterOpen.markupDecodeCount, 0,
                       "Opening the distinct-content fixture must remain metadata-only.")

        let firstReference = try XCTUnwrap(lease.catalog.reference(for: lease.catalog.pages[0].id))
        let firstPage = try await repository.loadPage(firstReference, using: lease)
        if #available(iOS 27.0, *) {
            XCTAssertEqual(firstPage.markup.subelements.strokes.count, 1_000)
        }
        let metricsAfterResolve = await repository.metrics()
        XCTAssertEqual(metricsAfterResolve.markupDecodeCount, 1)
        await repository.release(lease)
    }

    func testStagedRevisionIsClearedOnlyAfterVerifiedCommit() async throws {
        let root = temporaryNotebookURL()
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = CanvasPageRepository(rootURL: root)
        let page = CanvasPageSnapshot(
            id: UUID(),
            markup: PaperMarkup(bounds: CGRect(origin: .zero, size: CanvasConstants.a4PortraitSize))
        )
        let descriptor = try CanvasPageDescriptor(page: page, contentRevision: 1)
        try await repository.stageChangedPage(page, contentRevision: 1)

        let commit = try await repository.commitStagedPages(
            expectedGeneration: 0,
            generation: 1,
            currentPageID: page.id,
            pages: [descriptor]
        )
        XCTAssertEqual(commit.committedRevisions[page.id], 1)

        let next = try await repository.commitStagedPages(
            expectedGeneration: 1,
            generation: 2,
            currentPageID: page.id,
            pages: [CanvasPageDescriptor(
                id: page.id,
                contentRevision: 1,
                viewport: CanvasViewportState(),
                paperTemplate: page.paperTemplate,
                geometry: page.geometry,
                background: .paper
            )]
        )
        XCTAssertTrue(next.changedPageIDs.isEmpty)
    }

    func testNewerStagedRevisionSurvivesOlderCommitAcknowledgement() async throws {
        let root = temporaryNotebookURL()
        defer { try? FileManager.default.removeItem(at: root) }

        let codec = PausedCanvasPageCodec()
        let repository = CanvasPageRepository(rootURL: root, codec: codec)
        let markup = PaperMarkup(bounds: CGRect(origin: .zero, size: CanvasConstants.a4PortraitSize))
        let page = CanvasPageSnapshot(id: UUID(), markup: markup)
        let descriptor = try CanvasPageDescriptor(page: page, contentRevision: 1)
        try await repository.stageChangedPage(page, contentRevision: 1)

        let saving = Task {
            try await repository.commitStagedPages(
                expectedGeneration: 0,
                generation: 1,
                currentPageID: page.id,
                pages: [descriptor]
            )
        }
        await codec.waitUntilEncodingStarts()
        try await repository.stageChangedPage(page, contentRevision: 2)
        await codec.resumeEncoding()
        let committed = try await saving.value

        XCTAssertEqual(committed.committedRevisions[page.id], 1)
        let metrics = await repository.metrics()
        XCTAssertEqual(metrics.stagedDirtyPageCount, 1,
                       "A newer edit arriving during encoding must remain dirty after the older save commits.")
    }

    func testLowStorageKeepsCurrentManifestUnpublished() async throws {
        let root = temporaryNotebookURL()
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = CanvasPageRepository(
            rootURL: root,
            storageCapacityProvider: { _ in 0 }
        )
        let page = CanvasPageSnapshot(
            id: UUID(),
            markup: PaperMarkup(bounds: CGRect(origin: .zero, size: CanvasConstants.a4PortraitSize))
        )
        let descriptor = try CanvasPageDescriptor(page: page, contentRevision: 1)
        do {
            _ = try await repository.commit(
                expectedGeneration: 0,
                generation: 1,
                currentPageID: page.id,
                pages: [descriptor],
                changedPages: [page.id: page]
            )
            XCTFail("The storage reserve must prevent publication when available space is insufficient.")
        } catch let error as CanvasPageRepositoryError {
            guard case .insufficientStorage = error else {
                return XCTFail("Expected an insufficient-storage error, received \(error).")
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("current.canvas").path
        ))
    }

    func testPageRevisionsCannotBeZeroOrMoveBackwards() async throws {
        let root = temporaryNotebookURL()
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = CanvasPageRepository(rootURL: root)
        let page = CanvasPageSnapshot(
            id: UUID(),
            markup: PaperMarkup(bounds: CGRect(origin: .zero, size: CanvasConstants.a4PortraitSize))
        )
        let initialDescriptor = try CanvasPageDescriptor(page: page, contentRevision: 2)
        _ = try await repository.commit(
            expectedGeneration: 0,
            generation: 1,
            currentPageID: page.id,
            pages: [initialDescriptor],
            changedPages: [page.id: page]
        )

        let regressedDescriptor = try CanvasPageDescriptor(page: page, contentRevision: 1)
        do {
            _ = try await repository.commit(
                expectedGeneration: 1,
                generation: 2,
                currentPageID: page.id,
                pages: [regressedDescriptor],
                changedPages: [page.id: page]
            )
            XCTFail("A page revision older than the committed revision must not publish.")
        } catch let error as CanvasPageRepositoryError {
            XCTAssertEqual(error, .stalePageRevision(page.id))
        }

        let zeroRevision = CanvasPageDescriptor(
            id: page.id,
            contentRevision: 0,
            viewport: page.viewport,
            paperTemplate: page.paperTemplate,
            geometry: page.geometry,
            background: .paper
        )
        do {
            _ = try await repository.commit(
                expectedGeneration: 1,
                generation: 2,
                currentPageID: page.id,
                pages: [zeroRevision],
                changedPages: [:]
            )
            XCTFail("A zero page revision must not publish.")
        } catch let error as CanvasPageRepositoryError {
            guard case .invalidPage = error else {
                return XCTFail("Expected invalidPage, received \(error).")
            }
        }

        let lease = try await repository.acquireCatalogLease()
        XCTAssertEqual(lease.catalog.generation, 1)
        XCTAssertEqual(lease.catalog.pages.first?.contentRevision, 2)
        await repository.release(lease)
    }

    func testInvalidRecoverySlotsAreNeverReplacedByAnEmptyNotebook() async throws {
        let root = temporaryNotebookURL()
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = CanvasPageRepository(rootURL: root)
        let invalidCurrent = Data("unreadable v7 recovery slot".utf8)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try invalidCurrent.write(to: root.appendingPathComponent("current.canvas"))
        do {
            _ = try await repository.commit(
                expectedGeneration: 0,
                generation: 1,
                currentPageID: UUID(),
                pages: [],
                changedPages: [:]
            )
            XCTFail("An unreadable existing recovery slot must fail closed.")
        } catch let error as CanvasPageRepositoryError {
            guard case .invalidCatalog = error else {
                return XCTFail("Expected invalidCatalog, received \(error).")
            }
        }
        XCTAssertEqual(
            try Data(contentsOf: root.appendingPathComponent("current.canvas")),
            invalidCurrent
        )
    }

    func testRecoveryFallsBackToPreviousManifestAndRejectsCorruptPageBytes() async throws {
        let root = temporaryNotebookURL()
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = CanvasPageRepository(rootURL: root)
        let page = CanvasPageSnapshot(
            id: UUID(),
            markup: PaperMarkup(bounds: CGRect(origin: .zero, size: CanvasConstants.a4PortraitSize))
        )
        let original = try CanvasPageDescriptor(page: page, contentRevision: 1)
        _ = try await repository.commit(
            expectedGeneration: 0,
            generation: 1,
            currentPageID: page.id,
            pages: [original],
            changedPages: [page.id: page]
        )
        _ = try await repository.commit(
            expectedGeneration: 1,
            generation: 2,
            currentPageID: page.id,
            pages: [CanvasPageDescriptor(
                id: page.id,
                contentRevision: 1,
                viewport: CanvasViewportState(),
                paperTemplate: page.paperTemplate,
                geometry: page.geometry,
                background: .paper
            )],
            changedPages: [:]
        )

        try Data("interrupted manifest".utf8).write(to: root.appendingPathComponent("current.canvas"))
        let lease = try await repository.acquireCatalogLease()
        XCTAssertEqual(lease.catalog.generation, 1)

        let reference = try XCTUnwrap(lease.catalog.reference(for: page.id))
        let payloadURL = root.appendingPathComponent("Pages", isDirectory: true)
            .appendingPathComponent(reference.payloadChecksum).appendingPathExtension("page")
        try Data("corrupt".utf8).write(to: payloadURL)
        do {
            _ = try await repository.loadPage(reference, using: lease)
            XCTFail("A payload with bytes that do not match its checksum must be rejected.")
        } catch let error as CanvasPageRepositoryError {
            XCTAssertEqual(error, .corruptPayload(page.id))
        }
        await repository.release(lease)
    }

    func testInlineBackgroundIsPublishedBeforeCatalogAndLoadedByPageReference() async throws {
        let root = temporaryNotebookURL()
        defer { try? FileManager.default.removeItem(at: root) }

        let repository = CanvasPageRepository(rootURL: root)
        let bytes = Data([0x01, 0x02, 0x03, 0x04])
        let page = CanvasPageSnapshot(
            id: UUID(),
            markup: PaperMarkup(bounds: CGRect(origin: .zero, size: CanvasConstants.a4PortraitSize)),
            background: .image(data: bytes, suggestedName: "fixture.png", sourceRelativePath: "fixture.png")
        )
        let descriptor = try CanvasPageDescriptor(page: page, contentRevision: 1)
        _ = try await repository.commit(
            expectedGeneration: 0,
            generation: 1,
            currentPageID: page.id,
            pages: [descriptor],
            changedPages: [page.id: page]
        )

        let lease = try await repository.acquireCatalogLease()
        let reference = try XCTUnwrap(lease.catalog.reference(for: page.id))
        let orphanURL = root.appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent("orphan.bin")
        try Data([0x09]).write(to: orphanURL)
        let removedSources = try await repository.collectUnreferencedSources()
        XCTAssertEqual(removedSources, ["orphan.bin"])
        let resolved = try await repository.loadPage(
            reference,
            using: lease
        )
        guard case let .image(source, _) = resolved.background else {
            return XCTFail("The imported page background was not resolved.")
        }
        XCTAssertEqual(source.imageData, bytes)
        await repository.release(lease)
    }

    func testDeveloperImportWritesSeparateV7CopyAndLeavesLegacyCheckpointUntouched() async throws {
        let legacyRoot = temporaryNotebookURL()
        let v7Root = temporaryNotebookURL()
        defer {
            try? FileManager.default.removeItem(at: legacyRoot)
            try? FileManager.default.removeItem(at: v7Root)
        }

        let page = CanvasPageSnapshot(
            id: UUID(),
            markup: PaperMarkup(bounds: CGRect(origin: .zero, size: CanvasConstants.a4PortraitSize))
        )
        let legacyStore = CanvasCoreStore(rootURL: legacyRoot)
        try await legacyStore.checkpoint(CanvasCoreSnapshot(
            generation: 1,
            pages: [page],
            currentPageID: page.id
        ))
        let legacyCheckpointURL = legacyRoot.appendingPathComponent("current.canvas")
        let legacyBytesBeforeImport = try Data(contentsOf: legacyCheckpointURL)

        let repository = try await CanvasPageRepository.makeDeveloperCopy(
            from: legacyStore,
            to: v7Root
        )
        let legacyBytesAfterImport = try Data(contentsOf: legacyCheckpointURL)
        XCTAssertEqual(legacyBytesAfterImport, legacyBytesBeforeImport)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: v7Root.appendingPathComponent("current.canvas").path
        ))

        let lease = try await repository.acquireCatalogLease()
        XCTAssertEqual(lease.catalog.pages.map(\.id), [page.id])
        let reference = try XCTUnwrap(lease.catalog.reference(for: page.id))
        let loaded = try await repository.loadPage(reference, using: lease)
        XCTAssertEqual(loaded.id, page.id)
        await repository.release(lease)
    }

    func testDeveloperImportRefusesNonemptyDestinationWithoutChangingEitherStore() async throws {
        let legacyRoot = temporaryNotebookURL()
        let v7Root = temporaryNotebookURL()
        defer {
            try? FileManager.default.removeItem(at: legacyRoot)
            try? FileManager.default.removeItem(at: v7Root)
        }

        let page = CanvasPageSnapshot(
            id: UUID(),
            markup: PaperMarkup(bounds: CGRect(origin: .zero, size: CanvasConstants.a4PortraitSize))
        )
        let legacyStore = CanvasCoreStore(rootURL: legacyRoot)
        try await legacyStore.checkpoint(CanvasCoreSnapshot(
            generation: 1,
            pages: [page],
            currentPageID: page.id
        ))
        let legacyCheckpointURL = legacyRoot.appendingPathComponent("current.canvas")
        let legacyBytesBeforeImport = try Data(contentsOf: legacyCheckpointURL)

        try FileManager.default.createDirectory(at: v7Root, withIntermediateDirectories: true)
        let sentinelURL = v7Root.appendingPathComponent("do-not-overwrite.txt")
        let sentinelBytes = Data("existing destination content".utf8)
        try sentinelBytes.write(to: sentinelURL)

        do {
            _ = try await CanvasPageRepository.makeDeveloperCopy(from: legacyStore, to: v7Root)
            XCTFail("Developer import must refuse to write into an existing nonempty destination.")
        } catch let error as CanvasPageRepositoryError {
            XCTAssertEqual(error, .developerImportDestinationNotEmpty(v7Root.standardizedFileURL.path))
        }

        XCTAssertEqual(try Data(contentsOf: legacyCheckpointURL), legacyBytesBeforeImport)
        XCTAssertEqual(try Data(contentsOf: sentinelURL), sentinelBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: v7Root.appendingPathComponent("current.canvas").path))
    }

    func testItemScopedDeveloperImportUsesSeparateCanvasV7Directory() async throws {
        let applicationSupport = temporaryNotebookURL()
        defer { try? FileManager.default.removeItem(at: applicationSupport) }

        let sourceID = UUID()
        let destinationID = UUID()
        let itemsRoot = applicationSupport
            .appendingPathComponent("NotateLibrary", isDirectory: true)
            .appendingPathComponent("Items", isDirectory: true)
        let sourceItemRoot = itemsRoot.appendingPathComponent(sourceID.uuidString, isDirectory: true)
        let legacyRoot = sourceItemRoot.appendingPathComponent("Canvas", isDirectory: true)
        let page = CanvasPageSnapshot(
            id: UUID(),
            markup: PaperMarkup(bounds: CGRect(origin: .zero, size: CanvasConstants.a4PortraitSize))
        )
        let legacyStore = CanvasCoreStore(rootURL: legacyRoot)
        try await legacyStore.checkpoint(CanvasCoreSnapshot(
            generation: 1,
            pages: [page],
            currentPageID: page.id
        ))
        let legacyCheckpointURL = legacyRoot.appendingPathComponent("current.canvas")
        let legacyBytesBeforeImport = try Data(contentsOf: legacyCheckpointURL)

        let v7Root = try CanvasPageRepository.developerRootURL(
            for: destinationID,
            applicationSupportURL: applicationSupport
        )
        XCTAssertNotEqual(v7Root.standardizedFileURL, legacyRoot.standardizedFileURL)
        XCTAssertEqual(v7Root.lastPathComponent, "CanvasV7")

        let repository = try await CanvasPageRepository.makeDeveloperCopy(
            fromItemID: sourceID,
            toItemID: destinationID,
            applicationSupportURL: applicationSupport
        )
        XCTAssertEqual(try Data(contentsOf: legacyCheckpointURL), legacyBytesBeforeImport)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: v7Root.appendingPathComponent("current.canvas").path
        ))

        let lease = try await repository.acquireCatalogLease()
        XCTAssertEqual(lease.catalog.pages.map(\.id), [page.id])
        await repository.release(lease)
    }

    func testDeveloperImportOfMissingSourceDoesNotCreateSourceOrDestination() async throws {
        let applicationSupport = temporaryNotebookURL()
        defer { try? FileManager.default.removeItem(at: applicationSupport) }

        let sourceID = UUID()
        let destinationID = UUID()
        let sourceRoot = applicationSupport
            .appendingPathComponent("NotateLibrary", isDirectory: true)
            .appendingPathComponent("Items", isDirectory: true)
            .appendingPathComponent(sourceID.uuidString, isDirectory: true)
            .appendingPathComponent("Canvas", isDirectory: true)
        let destinationRoot = try CanvasPageRepository.developerRootURL(
            for: destinationID,
            applicationSupportURL: applicationSupport
        )

        do {
            _ = try await CanvasPageRepository.makeDeveloperCopy(
                fromItemID: sourceID,
                toItemID: destinationID,
                applicationSupportURL: applicationSupport
            )
            XCTFail("A missing source checkpoint must not create an empty v7 copy.")
        } catch let error as CanvasPageRepositoryError {
            XCTAssertEqual(error, .noCatalog)
        }

        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceRoot.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destinationRoot.path))
    }

    func testDeveloperImportCopiesReferencedAssetsWithoutWritingToTheLegacySource() async throws {
        // Canvas Core keeps item-scoped sources next to the canvas directory.
        // Give each fixture its own item root so the test exercises the same
        // layout as a real library item and cannot collide with other tests.
        let legacyItemRoot = temporaryNotebookItemURL()
        let legacyRoot = legacyItemRoot.appendingPathComponent("Canvas", isDirectory: true)
        let v7ItemRoot = temporaryNotebookItemURL()
        let v7Root = v7ItemRoot.appendingPathComponent("Canvas", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: legacyItemRoot)
            try? FileManager.default.removeItem(at: v7ItemRoot)
        }

        let sourceBytes = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let page = CanvasPageSnapshot(
            id: UUID(),
            markup: PaperMarkup(bounds: CGRect(origin: .zero, size: CanvasConstants.a4PortraitSize)),
            background: .image(
                data: sourceBytes,
                suggestedName: "fixture.png",
                sourceRelativePath: "fixture.png"
            )
        )
        let legacyStore = CanvasCoreStore(rootURL: legacyRoot)
        try await legacyStore.checkpoint(CanvasCoreSnapshot(
            generation: 1,
            pages: [page],
            currentPageID: page.id
        ))

        let legacyLoad = await legacyStore.load()
        guard case let .restored(legacySnapshot) = legacyLoad,
              let persistedPage = legacySnapshot.pages.first,
              case let .image(persistedSource, _) = persistedPage.background else {
            return XCTFail("The legacy fixture did not retain its source image reference.")
        }
        let legacySourceURL = legacyItemRoot.appendingPathComponent("Sources", isDirectory: true)
            .appendingPathComponent(persistedSource.relativePath)
        let sourceBytesBefore = try Data(contentsOf: legacySourceURL)

        let repository = try await CanvasPageRepository.makeDeveloperCopy(
            from: legacyStore,
            to: v7Root
        )

        XCTAssertEqual(try Data(contentsOf: legacySourceURL), sourceBytesBefore)
        let lease = try await repository.acquireCatalogLease()
        let reference = try XCTUnwrap(lease.catalog.reference(for: page.id))
        let imported = try await repository.loadPage(reference, using: lease)
        guard case let .image(source, _) = imported.background else {
            return XCTFail("The imported page background was not retained.")
        }
        XCTAssertEqual(source.imageData, sourceBytes)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: v7Root.appendingPathComponent("Sources", isDirectory: true)
                .appendingPathComponent(source.relativePath).path
        ))
        await repository.release(lease)
    }

    private func temporaryNotebookURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Notate-v7-test-\(UUID().uuidString)", isDirectory: true)
    }

    private func temporaryNotebookItemURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("Notate-v7-item-test-\(UUID().uuidString)", isDirectory: true)
    }
}
