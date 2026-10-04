import XCTest
import SwiftData
@testable import Notate

final class LibraryLaunchPerformanceTests: XCTestCase {
    @MainActor
    func testRepositoryInitializationPerformanceWithEmptyCatalog() throws {
        try measureRepositoryInitialization(itemCount: 0)
    }

    @MainActor
    func testRepositoryInitializationPerformanceWithTypicalCatalog() throws {
        try measureRepositoryInitialization(itemCount: 1_000)
    }

    @MainActor
    func testRepositoryInitializationPerformanceWithLargeCatalog() throws {
        try measureRepositoryInitialization(itemCount: 10_000)
    }

    @MainActor
    func testRepositoryDefersSecondaryCatalogFetchesUntilRequested() throws {
        let container = try LibraryModelContainerFactory.makeInMemory()
        let repository = try LibraryRepository(modelContainer: container)

        XCTAssertFalse(repository.hasLoadedDeferredCatalogMetadataForTesting)

        try repository.loadDeferredCatalogMetadata()

        XCTAssertTrue(repository.hasLoadedDeferredCatalogMetadataForTesting)
    }

    @MainActor
    func testInitialLibraryFetchesRootsAndLoadsChildrenOnDemand() throws {
        let container = try LibraryModelContainerFactory.makeInMemory()
        let rootID = UUID()
        let childID = UUID()
        let context = container.mainContext
        context.autosaveEnabled = false
        context.insert(LibraryItemRecord(
            id: rootID,
            name: "Folder",
            kind: .folder,
            payloadState: .ready
        ))
        context.insert(LibraryItemRecord(
            id: childID,
            parentID: rootID,
            name: "Nested Notebook",
            kind: .notebook,
            payloadState: .ready
        ))
        try context.save()

        let repository = try LibraryRepository(modelContainer: container)
        XCTAssertFalse(repository.hasLoadedAllItemsForTesting)
        XCTAssertEqual(repository.rootItems().map(\.id), [rootID])
        XCTAssertEqual(repository.children(of: rootID).map(\.id), [childID])
        XCTAssertFalse(repository.hasLoadedAllItemsForTesting)

        try repository.loadCompleteItemCatalog()
        XCTAssertTrue(repository.hasLoadedAllItemsForTesting)
        XCTAssertEqual(repository.items.count, 2)
    }

    @MainActor
    func testIncompleteRecoveryUsesTargetedReadsAndKeepsTheCatalogLazy() throws {
        let container = try LibraryModelContainerFactory.makeInMemory()
        let rootID = UUID()
        let interruptedID = UUID()
        let context = container.mainContext
        context.autosaveEnabled = false
        context.insert(LibraryItemRecord(
            id: rootID,
            name: "Library Folder",
            kind: .folder,
            payloadState: .ready
        ))
        for index in 0..<1_000 {
            context.insert(LibraryItemRecord(
                parentID: rootID,
                name: "Ready Notebook \(index)",
                kind: .notebook,
                payloadState: .ready
            ))
        }
        context.insert(LibraryItemRecord(
            id: interruptedID,
            parentID: rootID,
            name: "Interrupted Notebook",
            kind: .notebook,
            payloadState: .creating
        ))
        let tagID = UUID()
        context.insert(TagAssignment(itemID: interruptedID, tagID: tagID))
        let deletedPageID = UUID()
        context.insert(DeletedPageRecord(
            id: deletedPageID,
            pageID: UUID(),
            ownerItemID: interruptedID,
            purgeAfter: .distantFuture,
            originalIndex: 0,
            payloadRelativePath: "deleted/page.data"
        ))
        try context.save()

        let repository = try LibraryRepository(modelContainer: container)
        let plan = try repository.makeIncompletePayloadReconciliationPlan()

        XCTAssertEqual(plan.itemIDs, [interruptedID])
        XCTAssertFalse(repository.hasLoadedAllItemsForTesting)
        XCTAssertFalse(repository.hasLoadedDeferredCatalogMetadataForTesting)

        try repository.commitIncompletePayloadReconciliation(plan)

        XCTAssertFalse(repository.hasLoadedAllItemsForTesting)
        XCTAssertFalse(repository.hasLoadedDeferredCatalogMetadataForTesting)
        XCTAssertNil(repository.item(id: interruptedID))
        XCTAssertThrowsError(try repository.deletedPageAsset(id: deletedPageID))
    }

    @MainActor
    func testLibraryRemainsBrowsableButBlocksDocumentOpenDuringRecovery() throws {
        let container = try LibraryModelContainerFactory.makeInMemory()
        let repository = try LibraryRepository(modelContainer: container)
        let folder = try repository.createItem(
            kind: .folder,
            name: "Folder",
            payloadState: .ready
        )
        let notebook = try repository.createItem(
            kind: .notebook,
            name: "Notebook",
            payloadState: .ready
        )
        var didOpenDocument = false
        let session = LibraryAppSession(
            repository: repository,
            actions: LibraryUIActions(openItem: { _ in didOpenDocument = true }),
            mutationAllowed: { false }
        )

        session.open(folder)
        XCTAssertEqual(session.scope, .folder(folder.id))
        XCTAssertNil(folder.lastOpenedAt)

        session.open(notebook)
        XCTAssertFalse(didOpenDocument)
        XCTAssertFalse(session.canCreateContent)
    }

    @MainActor
    private func measureRepositoryInitialization(itemCount: Int) throws {
        let container = try LibraryModelContainerFactory.makeInMemory()
        let context = container.mainContext
        context.autosaveEnabled = false
        let timestamp = Date(timeIntervalSince1970: 1_700_000_000)
        if itemCount > 0 {
            let rootID = UUID()
            context.insert(LibraryItemRecord(
                id: rootID,
                name: "Library Folder",
                kind: .folder,
                payloadState: .ready,
                createdAt: timestamp
            ))
            for index in 1..<itemCount {
                context.insert(LibraryItemRecord(
                    parentID: rootID,
                    name: "Notebook \(index)",
                    kind: .notebook,
                    payloadState: .ready,
                    createdAt: timestamp
                ))
            }
        }
        try context.save()

        // Install preset tags outside the measured interval. The measurement
        // then isolates repeatable catalog loading at each data size.
        _ = try LibraryRepository(modelContainer: container)
        measure(metrics: [XCTClockMetric()]) {
            _ = try? LibraryRepository(modelContainer: container)
        }
    }
}
