import Foundation
import Observation
import PaperKit
import PDFKit
import PhotosUI
import QuickLook
import SwiftData
import SwiftUI
import UniformTypeIdentifiers
import UIKit

enum NotateAppRoute: Hashable, Sendable {
    case home
    case folder(UUID)
    case favorites
    case recent
    case tag(UUID)
    case trash
    case settings
    case notebook(UUID)
    case document(UUID)
    case attachment(UUID)
}

/// Commits the one durable image that every library card reads. Keeping this
/// path shared by imports and editor refreshes prevents newly added PDFs and
/// photos from showing a semantic placeholder until they have first been
/// opened and closed.
@MainActor
enum LibraryPreviewPipeline {
    struct PreparedPreview: Sendable {
        let data: Data
        let generation: Int64
    }

    static func prepare(
        snapshot: CanvasCoreSnapshot,
        kind: LibraryItemKind
    ) async throws -> PreparedPreview {
        guard let firstPage = snapshot.pages.first else {
            throw CanvasExportError.noPagesSelected
        }

        let image: CGImage
        if kind == .canvas {
            image = try await CanvasDocumentExporter.shared.freeformThumbnail(for: firstPage)
        } else {
            image = try await CanvasDocumentExporter.shared.thumbnail(for: firstPage)
        }
        guard let data = UIImage(cgImage: image).pngData() else {
            throw CanvasExportError.imageEncodingFailed(page: 1)
        }
        try Task.checkCancellation()
        return PreparedPreview(data: data, generation: snapshot.generation)
    }

    static func publish(
        _ preview: PreparedPreview,
        itemID: UUID,
        assetStore: LibraryAssetStore
    ) async throws -> Int64 {
        // This check belongs immediately before the actor-isolated file write.
        // Callers perform their generation-CAS first, then cancellation closes
        // the remaining gap before the request is enqueued on the asset actor.
        try Task.checkCancellation()
        _ = try await assetStore.write(
            preview.data,
            named: "library.png",
            category: .thumbnails,
            for: itemID,
            maximumByteCount: LibraryImageDecodePolicy
                .durableThumbnail.maximumEncodedByteCount
        )
        return preview.generation
    }

    static func commit(
        snapshot: CanvasCoreSnapshot,
        itemID: UUID,
        kind: LibraryItemKind,
        assetStore: LibraryAssetStore
    ) async throws -> Int64 {
        let preview = try await prepare(snapshot: snapshot, kind: kind)
        return try await publish(
            preview,
            itemID: itemID,
            assetStore: assetStore
        )
    }
}

@MainActor
@Observable
final class NotateApplicationCoordinator {
    enum BootstrapState {
        case ready(NotateApplicationCoordinator)
        case unavailable
    }

    struct DerivedCatalogPersistenceFailure: Equatable, Sendable {
        let generation: Int64
        /// Diagnostic size only. The authoritative text remains reproducible
        /// from Canvas Core and retries reload that snapshot, so retaining the
        /// full projection here would amplify a persistent disk failure by up
        /// to eight MiB for every item edited before recovery.
        let searchableTextUTF8ByteCount: Int
        let errorDescription: String
    }

    private struct CompatibilityDerivedRefreshClaim: Equatable, Sendable {
        let id: UUID
        let generation: Int64
        let authorityEpoch: UInt64
    }

    #if DEBUG
    enum CompatibilityDerivedRefreshTestPhase: Equatable, Sendable {
        case beforePreviewPublication
    }
    #endif

    private enum LibraryMutationGateError: LocalizedError {
        case recoveryIncomplete

        var errorDescription: String? {
            "Library recovery must finish before this change can be saved."
        }
    }

    private struct PreparedNotebookCover: Sendable {
        let data: Data
        let canvasSourceRelativePath: String
    }

    private enum NotebookCoverError: LocalizedError {
        case missingCustomImage
        case renderingFailed

        var errorDescription: String? {
            switch self {
            case .missingCustomImage:
                "The custom cover image is no longer available."
            case .renderingFailed:
                "The selected notebook cover could not be rendered."
            }
        }
    }

    struct PreparedFileImport: Sendable {
        let data: Data
        let filename: String
        let contentTypeIdentifier: String
        let nativePDFText: String
    }

    struct ActiveEditor {
        let item: LibraryItemRecord
        let model: CanvasEditorModel

        var itemID: UUID { item.id }
    }

    struct ActiveAttachment {
        let itemID: UUID
        let title: String
        let url: URL
    }

    let modelContainer: ModelContainer
    let repository: LibraryRepository

    @ObservationIgnored let assetStore: LibraryAssetStore
    @ObservationIgnored private let migrationCoordinator: LegacyCanvasMigrationCoordinator?
    @ObservationIgnored private let deletedPageAcknowledgement: (
        LibraryRepository,
        UUID
    ) throws -> Void
    /// Test-injectable boundary for the catalog's reproducible projection.
    /// Canvas Core remains authoritative; a failure here must never cause an
    /// older SwiftData projection to be certified at the latest generation.
    @ObservationIgnored private let compatibilityDerivedPayloadCommit:
        @MainActor (LibraryRepository, UUID, Int, String) throws -> Void
    /// A failed production catalog open must never expose the writable,
    /// in-memory placeholder as though it were the user's empty library.
    /// While this is populated the root UI is blocking, startup maintenance is
    /// skipped, and the entire library action surface is inert.
    private(set) var catalogFailureDescription: String?
    /// Authored files may be temporarily parked in AssetTrash while a crash
    /// journal is reconciled. Keep every library action fail-closed until those
    /// files and interrupted catalog payloads are back in a coherent state.
    private(set) var isLibraryRecoveryComplete = false
    /// XCUITest launches against an isolated, in-memory catalog. This flag is
    /// intentionally scoped to launch configuration so production behavior
    /// cannot depend on a UI-test-only code path.
    @ObservationIgnored private let isUITesting: Bool
    @ObservationIgnored lazy var librarySession = LibraryAppSession(
        repository: repository,
        actions: libraryActions,
        // The reader and writer share the exact injected library root. This
        // also covers recovery/temporary containers instead of reconstructing
        // a production Application Support path inside the card view.
        thumbnailStore: LibraryAutomaticThumbnailStore(
            libraryRoot: assetStore.libraryRoot
        )
    )

    var route: NotateAppRoute = .home
    var activeEditor: ActiveEditor?
    var activeAttachment: ActiveAttachment?
    var importParentID: UUID?
    var isImportChoicePresented = false
    var isFileImporterPresented = false
    var isPhotoPickerPresented = false
    var selectedPhotos: [PhotosPickerItem] = []
    var alertMessage: String?
    var startupNotice: String?

    @ObservationIgnored private var didStart = false
    @ObservationIgnored private var derivedRefreshes: [
        UUID: (id: UUID, task: Task<Void, Never>)
    ] = [:]
    @ObservationIgnored private var compatibilityDerivedRetries: [
        UUID: (id: UUID, task: Task<Void, Never>)
    ] = [:]
    /// MainActor compare-and-swap authority for the reproducible catalog and
    /// card preview. A task retains its immutable snapshot across suspension,
    /// while this claim records which generation is still allowed to publish.
    @ObservationIgnored private var compatibilityDerivedRefreshClaims: [
        UUID: CompatibilityDerivedRefreshClaim
    ] = [:]
    /// Advances as soon as a verified editor checkpoint asks for derivation,
    /// before the debounce or rendering work begins. This closes the interval
    /// in which an older producer is still draining after a newer save.
    @ObservationIgnored private var compatibilityDerivedGenerationFloors: [
        UUID: Int64
    ] = [:]
    /// Changes whenever the generation authority advances or adopts a lower
    /// verified recovery head. A producer must carry the epoch observed before
    /// its authoritative Canvas load, so a stale load cannot reset or reclaim
    /// authority after another save/recovery won that suspension window.
    @ObservationIgnored private var compatibilityDerivedAuthorityEpochs: [
        UUID: UInt64
    ] = [:]
    /// Serializes only the final write to the shared `library.png` path. Text
    /// extraction and rendering remain concurrent, while a newer publisher is
    /// guaranteed to enqueue its physical write after every predecessor.
    @ObservationIgnored private var compatibilityPreviewPublicationTails: [
        UUID: (id: UUID, task: Task<Int64?, Never>)
    ] = [:]
    @ObservationIgnored private var closeHandoffs: [
        UUID: (id: UUID, task: Task<Void, Never>)
    ] = [:]
    /// File and Photos pickers can deliver another selection while a previous
    /// batch is still validating or committing large payloads. Admit exactly
    /// one root import batch at a time instead of cancelling authored-file
    /// work or retaining a queue of picker payloads in memory.
    @ObservationIgnored private var activeRootImportBatchID: UUID?
    /// A close handoff owns the outgoing editor model until its verified
    /// checkpoint and catalog projection have drained. Keep only the latest
    /// requested payload-bearing item ID while that happens; retaining the
    /// library record, constructing its model, or loading a Quick Look payload
    /// here would defeat the memory bound.
    @ObservationIgnored private var pendingPayloadOpenItemID: UUID?
    #if DEBUG
    @ObservationIgnored private var rootImportBatchSuspensionForTesting:
        (@MainActor () async -> Void)?
    @ObservationIgnored private var closeHandoffSuspensionForTesting:
        (@MainActor () async -> Void)?
    @ObservationIgnored private var payloadOpenObserverForTesting:
        (@MainActor (UUID) -> Void)?
    @ObservationIgnored private var compatibilityDerivedRefreshSuspensionForTesting:
        (@MainActor (Int64, CompatibilityDerivedRefreshTestPhase) async -> Void)?
    #endif
    /// Records lightweight diagnostics for a failed fresh projection until a
    /// verified refresh persists it. Retries rebuild from authoritative
    /// Canvas Core.
    @ObservationIgnored private(set) var derivedCatalogPersistenceFailures: [
        UUID: DerivedCatalogPersistenceFailure
    ] = [:]

    init(
        modelContainer: ModelContainer,
        repository: LibraryRepository,
        assetStore: LibraryAssetStore,
        migrationCoordinator: LegacyCanvasMigrationCoordinator?,
        startupNotice: String? = nil,
        catalogFailureDescription: String? = nil,
        isUITesting: Bool = false,
        deletedPageAcknowledgement: ((LibraryRepository, UUID) throws -> Void)? = nil,
        compatibilityDerivedPayloadCommit: (
            @MainActor (LibraryRepository, UUID, Int, String) throws -> Void
        )? = nil
    ) {
        self.modelContainer = modelContainer
        self.repository = repository
        self.assetStore = assetStore
        self.migrationCoordinator = migrationCoordinator
        self.startupNotice = startupNotice
        self.catalogFailureDescription = catalogFailureDescription
        #if DEBUG
        self.isUITesting = isUITesting
        #else
        self.isUITesting = false
        #endif
        self.deletedPageAcknowledgement = deletedPageAcknowledgement ?? { repository, id in
            try repository.acknowledgeDeletedPageRestored(id: id)
        }
        self.compatibilityDerivedPayloadCommit =
            compatibilityDerivedPayloadCommit ?? { repository, itemID, pageCount, text in
                try repository.updateDerivedPayload(
                    itemID: itemID,
                    pageCount: pageCount,
                    searchableText: text
                )
            }
    }

    var isCatalogWritable: Bool {
        catalogFailureDescription == nil && isLibraryRecoveryComplete
    }

    private func requireCatalogWritable() throws {
        guard isCatalogWritable else {
            throw LibraryMutationGateError.recoveryIncomplete
        }
    }

    static func bootstrap() -> BootstrapState {
        #if DEBUG
        if NotateUITestLaunchConfiguration.isEnabled {
            do {
                return .ready(try makeUITestCoordinator())
            } catch {
                return .unavailable
            }
        }
        #endif

        return bootstrap(
            liveFactory: {
                let container = try LibraryModelContainerFactory.makeLive()
                let assetStore = try LibraryAssetStore.live()
                return try NotateApplicationCoordinator(
                    modelContainer: container,
                    repository: LibraryRepository(modelContainer: container),
                    assetStore: assetStore,
                    migrationCoordinator: try? LegacyCanvasMigrationCoordinator.live()
                )
            },
            unavailableFactory: { catalogErrorDescription in
                try makeCatalogUnavailableCoordinator(
                    catalogErrorDescription: catalogErrorDescription
                )
            }
        )
    }

    static func bootstrap(
        liveFactory: () throws -> NotateApplicationCoordinator,
        unavailableFactory: (String) throws -> NotateApplicationCoordinator
    ) -> BootstrapState {
        do {
            return .ready(try liveFactory())
        } catch {
            let catalogError = error
            do {
                return .ready(
                    try unavailableFactory(catalogError.localizedDescription)
                )
            } catch {
                return .unavailable
            }
        }
    }

    static func makeCatalogUnavailableCoordinator(
        catalogErrorDescription: String,
        recoveryRoot: URL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Notate-Recovery-\(UUID().uuidString)")
    ) throws -> NotateApplicationCoordinator {
        let container = try LibraryModelContainerFactory.makeInMemory()
        return try NotateApplicationCoordinator(
            modelContainer: container,
            repository: LibraryRepository(modelContainer: container),
            assetStore: LibraryAssetStore(libraryRoot: recoveryRoot),
            migrationCoordinator: nil,
            catalogFailureDescription: """
            Notate couldn't open your saved library, so editing is disabled to protect it. Your catalog and note files have not been replaced. Quit and reopen Notate, then contact
            support if the problem continues. Details: \(catalogErrorDescription)
            """
        )
    }

    #if DEBUG
    private static func makeUITestCoordinator() throws -> NotateApplicationCoordinator {
        let container = try LibraryModelContainerFactory.makeInMemory()
        let coordinator = try NotateApplicationCoordinator(
            modelContainer: container,
            repository: LibraryRepository(modelContainer: container),
            assetStore: LibraryAssetStore(
                libraryRoot: NotateUITestLaunchConfiguration.isolatedLibraryRoot
            ),
            migrationCoordinator: nil,
            isUITesting: true
        )
        if NotateUITestLaunchConfiguration.seedFixture {
            try coordinator.installUITestFixture()
        }
        return coordinator
    }
    /// A compact, deterministic catalog for UI automation. It has no canvas
    /// payload dependency: UI tests exercise library affordances, while editor
    /// persistence remains covered by the Canvas test suite.
    private func installUITestFixture() throws {
        let courses = try repository.createItem(
            kind: .folder,
            name: "Courses",
            payloadState: .ready,
            folderSettings: LibraryFolderSettings(symbolName: "graduationcap")
        )
        let projects = try repository.createItem(
            kind: .folder,
            name: "Projects",
            payloadState: .ready,
            folderSettings: LibraryFolderSettings(symbolName: "sparkles")
        )
        let notebook = try repository.createItem(
            kind: .notebook,
            name: "Studio Notebook",
            coverChoice: .preset(.softLinen),
            payloadState: .ready,
            searchableText: "fashion silhouette fittings",
            pageCount: 1
        )
        _ = try repository.createItem(
            kind: .notebook,
            name: "Moodboard",
            parentID: projects.id,
            payloadState: .ready,
            searchableText: "textile ideas",
            pageCount: 1
        )
        let document = try repository.createItem(
            kind: .importedDocument,
            name: "Reference PDF",
            payloadState: .ready,
            sourceFilename: "research.pdf",
            searchableText: "fashion silhouettes reference",
            pageCount: 3
        )
        try installUITestDocumentThumbnail(for: document.id)
        _ = try repository.createItem(
            kind: .notebook,
            name: "Concept Board",
            payloadState: .ready,
            searchableText: "collection colors materials",
            pageCount: 1
        )

        var parentID = courses.id
        // Courses is already level one. Four descendants bring the final
        // folder to the supported maximum of five, which lets UI tests prove
        // that the creation menu suppresses a sixth folder.
        for level in 2...5 {
            let folder = try repository.createItem(
                kind: .folder,
                name: "Level \(level)",
                parentID: parentID,
                payloadState: .ready
            )
            parentID = folder.id
        }

        let tag = try repository.createTag(name: "Studio", color: .init(
            red: 0.58,
            green: 0.46,
            blue: 0.88
        ))
        try repository.assignTag(tagID: tag.id, to: notebook.id)
        try repository.setFavorite(itemID: notebook.id, isFavorite: true)

        let archived = try repository.createItem(
            kind: .notebook,
            name: "Archived Notes",
            payloadState: .ready,
            pageCount: 1
        )
        try repository.moveToTrash(itemID: archived.id)
    }

    /// Gives visual-reference UI tests the same cover-first document behavior
    /// as a completed import without coupling library tests to PDF rendering.
    /// The deterministic item-scoped path is visible to the thumbnail loader
    /// only while the opt-in UI-test launch contract is active.
    private func installUITestDocumentThumbnail(for itemID: UUID) throws {
        let size = CGSize(width: 612, height: 792)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: size, format: format)
        let data = renderer.pngData { context in
            let bounds = CGRect(origin: .zero, size: size)
            UIColor(red: 0.98, green: 0.97, blue: 0.93, alpha: 1).setFill()
            context.cgContext.fill(bounds)

            UIColor(red: 0.20, green: 0.43, blue: 0.88, alpha: 1).setFill()
            context.cgContext.fill(CGRect(x: 48, y: 54, width: 92, height: 9))

            let title = "Material research" as NSString
            title.draw(
                at: CGPoint(x: 48, y: 86),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 32, weight: .semibold),
                    .foregroundColor: UIColor(red: 0.12, green: 0.13, blue: 0.16, alpha: 1),
                ]
            )
            let subtitle = "Studio reference · silhouettes & texture" as NSString
            subtitle.draw(
                at: CGPoint(x: 48, y: 132),
                withAttributes: [
                    .font: UIFont.systemFont(ofSize: 17, weight: .regular),
                    .foregroundColor: UIColor(red: 0.42, green: 0.43, blue: 0.46, alpha: 1),
                ]
            )

            let swatches: [(CGRect, UIColor)] = [
                (CGRect(x: 48, y: 206, width: 238, height: 208), UIColor(red: 0.82, green: 0.70, blue: 0.57, alpha: 1)),
                (CGRect(x: 326, y: 206, width: 238, height: 208), UIColor(red: 0.35, green: 0.47, blue: 0.68, alpha: 1)),
                (CGRect(x: 48, y: 450, width: 516, height: 170), UIColor(red: 0.78, green: 0.82, blue: 0.79, alpha: 1)),
            ]
            for (rect, color) in swatches {
                color.setFill()
                UIBezierPath(roundedRect: rect, cornerRadius: 20).fill()
            }

            UIColor.white.withAlphaComponent(0.82).setStroke()
            let line = UIBezierPath()
            line.lineWidth = 7
            line.lineCapStyle = .round
            line.move(to: CGPoint(x: 90, y: 355))
            line.addCurve(
                to: CGPoint(x: 244, y: 262),
                controlPoint1: CGPoint(x: 124, y: 276),
                controlPoint2: CGPoint(x: 200, y: 369)
            )
            line.stroke()

            let footer = "01 / REFERENCE" as NSString
            footer.draw(
                at: CGPoint(x: 48, y: 714),
                withAttributes: [
                    .font: UIFont.monospacedSystemFont(ofSize: 15, weight: .medium),
                    .foregroundColor: UIColor(red: 0.38, green: 0.39, blue: 0.42, alpha: 1),
                ]
            )
        }

        let thumbnailDirectory = assetStore.directories(for: itemID).thumbnails
        try FileManager.default.createDirectory(
            at: thumbnailDirectory,
            withIntermediateDirectories: true
        )
        try data.write(
            to: thumbnailDirectory.appendingPathComponent("library.png"),
            options: .atomic
        )
    }
    #endif

    var libraryActions: LibraryUIActions {
        LibraryUIActions(
            openItem: { [weak self] item in
                guard let self, self.isCatalogWritable else { return }
                self.open(item)
            },
            importDocuments: { [weak self] parentID in
                guard let self, self.isCatalogWritable else { return }
                self.requestImport(parentID: parentID)
            },
            createFolder: { [weak self] parentID, draft in
                guard let self, self.isCatalogWritable else { return }
                self.createFolder(parentID: parentID, draft: draft)
            },
            createNotebook: { [weak self] parentID, draft in
                guard let self, self.isCatalogWritable else { return }
                self.createNotebook(parentID: parentID, draft: draft)
            },
            renameItem: { [weak self] id, name in
                guard let self, self.isCatalogWritable else { return }
                self.renameItem(id: id, name: name)
            },
            updateFolder: { [weak self] id, draft in
                guard let self, self.isCatalogWritable else { return }
                self.updateFolder(id: id, draft: draft)
            },
            setCover: { [weak self] id, cover, customCover in
                guard let self, self.isCatalogWritable else { return }
                self.setCover(id: id, cover: cover, customCover: customCover)
            },
            toggleFavorite: { [weak self] id in
                guard let self, self.isCatalogWritable else { return }
                self.toggleFavorite(id: id)
            },
            duplicateItem: { [weak self] id in
                guard let self, self.isCatalogWritable else { return }
                self.duplicateItem(id: id)
            },
            moveItems: { [weak self] ids, parentID in
                guard let self, self.isCatalogWritable else { return false }
                return self.moveItems(ids, to: parentID)
            },
            moveToTrash: { [weak self] ids in
                guard let self, self.isCatalogWritable else { return }
                self.moveToTrash(ids)
            },
            restoreItems: { [weak self] ids in
                guard let self, self.isCatalogWritable else { return }
                self.restoreItems(ids)
            },
            deletePermanently: { [weak self] ids in
                guard let self, self.isCatalogWritable else { return }
                self.deletePermanently(ids)
            },
            restoreDeletedPage: { [weak self] id in
                guard let self, self.isCatalogWritable else { return }
                self.restoreDeletedPage(id: id)
            },
            deleteDeletedPagePermanently: { [weak self] id in
                guard let self, self.isCatalogWritable else { return }
                self.deleteDeletedPagePermanently(id: id)
            },
            createTag: { [weak self] draft in
                guard let self, self.isCatalogWritable else { return }
                self.createTag(draft)
            },
            updateTag: { [weak self] id, draft in
                guard let self, self.isCatalogWritable else { return }
                self.updateTag(id: id, draft: draft)
            },
            deleteTag: { [weak self] id in
                guard let self, self.isCatalogWritable else { return }
                self.deleteTag(id: id)
            },
            assignTag: { [weak self] tagID, itemID in
                guard let self, self.isCatalogWritable else { return }
                self.assignTag(tagID: tagID, itemID: itemID)
            },
            removeTag: { [weak self] tagID, itemID in
                guard let self, self.isCatalogWritable else { return }
                self.removeTag(tagID: tagID, itemID: itemID)
            }
        )
    }

    func start() async {
        guard didStart == false else { return }
        didStart = true
        defer {
            // A view-scoped startup task can be cancelled during a future
            // cancellation-aware recovery operation. Allow the next `.task`
            // invocation to retry unless startup reached either its coherent
            // writable state or an explicit fail-closed terminal state.
            if isLibraryRecoveryComplete == false,
                catalogFailureDescription == nil {
                didStart = false
            }
        }
        guard catalogFailureDescription == nil else { return }
        guard await reconcileAssetTrashTransactions() else { return }
        await reconcileIncompletePayloads()
        guard catalogFailureDescription == nil else { return }
        isLibraryRecoveryComplete = true
        await purgeExpiredTrash()
        guard isCatalogWritable else { return }
        await migrateLegacyCanvasIfNeeded()
        await removeLegacyCanvasItems()
    }

    func closeActiveItem(
        beforeNavigation: @escaping @MainActor () -> Void = {}
    ) {
        if let editor = activeEditor,
            closeHandoffs[editor.itemID] != nil {
            // A repeated close gesture must join the existing durable
            // handoff instead of starting a competing flush for this model.
            return
        }

        if let editor = activeEditor {
            let itemID = editor.itemID
            let editorModel = editor.model
            let previousDerivedRefresh = derivedRefreshes
                .removeValue(forKey: itemID)?.task
            previousDerivedRefresh?.cancel()
            let handoffID = UUID()
            let task = Task { @MainActor [weak self, editorModel] in
                var didClose = false
                defer {
                    self?.finishCloseHandoff(
                        itemID: itemID,
                        handoffID: handoffID,
                        resumesPendingOpen: didClose
                    )
                }
                #if DEBUG
                await self?.closeHandoffSuspensionForTesting?()
                #endif
                guard !Task.isCancelled,
                    let self,
                    self.closeHandoffs[itemID]?.id == handoffID,
                    self.activeEditor?.model === editorModel else { return }

                await editorModel.flushForLifecycle()
                guard !Task.isCancelled,
                    self.closeHandoffs[itemID]?.id == handoffID,
                    self.activeEditor?.model === editorModel else { return }
                guard editorModel.saveState == .saved else {
                    self.presentCloseSaveFailure(editorModel.saveState)
                    return
                }

                // Canvas Core is authoritative. Only after its verified flush
                // may the visible editor disappear and navigation return to
                // Library. Catalog/index maintenance remains best effort.
                beforeNavigation()
                self.activeEditor = nil
                self.synchronizeRoute(with: self.librarySession.scope)
                didClose = true

                guard self.isCatalogWritable else { return }
                try? self.repository.markOpened(id: itemID)

                // A cancelled typing refresh may already be inside rendering.
                // Drain it before this handoff publishes the final projection.
                _ = await previousDerivedRefresh?.result
                guard !Task.isCancelled,
                    self.closeHandoffs[itemID]?.id == handoffID,
                    self.isCatalogWritable,
                    let generation = await self.verifiedGenerationForDerivedRefresh(
                        itemID: itemID,
                        model: editorModel
                    ) else { return }
                // Closing the editor is the durable handoff to Library. Do
                // not schedule through the typing debounce or weakly retain
                // the model: persist the catalog projection now so a later
                // Library query cannot miss the note that just closed.
                await self.refreshCompatibilityDerivedData(
                    itemID: itemID,
                    minimumGeneration: generation
                )
            }
            closeHandoffs[itemID] = (handoffID, task)
            return
        }

        let itemID = activeAttachment?.itemID
        activeAttachment = nil
        synchronizeRoute(with: librarySession.scope)
        if isCatalogWritable, let itemID {
            try? repository.markOpened(id: itemID)
        }
    }

    private func presentCloseSaveFailure(_ saveState: CanvasEditorModel.SaveState) {
        switch saveState {
        case let .failed(description):
            alertMessage = description
        case .saving:
            alertMessage = "The latest canvas edit is still being saved. Try closing the note again."
        case .saved:
            break
        }
    }

    private func finishCloseHandoff(
        itemID: UUID,
        handoffID: UUID,
        resumesPendingOpen: Bool
    ) {
        guard closeHandoffs[itemID]?.id == handoffID else { return }
        closeHandoffs.removeValue(forKey: itemID)
        if resumesPendingOpen {
            schedulePendingPayloadOpenResume()
        }
    }

    private func schedulePendingPayloadOpenResume() {
        guard closeHandoffs.isEmpty,
            pendingPayloadOpenItemID != nil else { return }
        // This must not run inline from the outgoing task's `defer': that task
        // still captures its CanvasEditorModel until its closure returns. A
        // separate turn plus an explicit yield lets the old task and model be
        // released before constructing the requested replacement (or asking
        // Quick Look to load an attachment).
        Task { @MainActor [weak self] in
            await Task.yield()
            self?.resumePendingPayloadOpenIfPossible()
        }
    }

    private func resumePendingPayloadOpenIfPossible() {
        guard closeHandoffs.isEmpty,
            let itemID = pendingPayloadOpenItemID else { return }
        pendingPayloadOpenItemID = nil
        guard isCatalogWritable,
            let item = repository.item(id: itemID),
            item.payloadState == .ready,
            item.isTrashed == false,
            item.kind == .notebook
            || item.kind == .importedDocument
            || item.kind == .attachment else {
            return
        }
        open(item)
    }

    /// Keeps the typed application route aligned with the library surface.
    /// The session owns view-specific state such as sorting and selection,
    /// while this route remains the semantic description used by transitions,
    /// restoration, and future deep links.
    func synchronizeRoute(with scope: LibraryScope) {
        guard activeEditor == nil, activeAttachment == nil else { return }
        switch scope {
        case .home:
            route = .home
        case .favorites:
            route = .favorites
        case .recent:
            route = .recent
        case let .tag(id):
            route = .tag(id)
        case .trash:
            route = .trash
        case .settings:
            route = .settings
        case let .folder(id):
            route = .folder(id)
        }
    }

    /// Refreshes derived catalog data only after Canvas Core reports a
    /// verified checkpoint. The previous durable preview remains in place if
    /// rendering or indexing fails.
    func refreshDerivedLibraryData(itemID: UUID, model: CanvasEditorModel) async {
        guard isCatalogWritable, model.saveState == .saved else { return }
        scheduleDerivedLibraryRefresh(itemID: itemID, model: model)
    }

    func requestImport(parentID: UUID?) {
        guard isCatalogWritable else { return }
        guard activeRootImportBatchID == nil else {
            showRootImportBusyMessage()
            return
        }
        importParentID = parentID
        isImportChoicePresented = true
    }

    func handleFileImporter(_ result: Result<[URL], any Error>) {
        guard isCatalogWritable else { return }
        switch result {
        case let .success(urls):
            guard let batchID = beginRootImportBatch() else { return }
            let parentID = importParentID
            Task { @MainActor [weak self] in
                guard let self else { return }
                defer { self.finishRootImportBatch(batchID) }
                #if DEBUG
                await self.rootImportBatchSuspensionForTesting?()
                #endif
                var latestSuccessfulItemID: UUID?
                for url in urls {
                    guard self.isCatalogWritable else { return }
                    if let importedID = await self.importFile(
                        at: url,
                        parentID: parentID,
                        opensOnSuccess: false
                    ) {
                        latestSuccessfulItemID = importedID
                    }
                }
                if let latestSuccessfulItemID,
                    let imported = self.repository.item(id: latestSuccessfulItemID) {
                    self.open(imported)
                }
            }
        case let .failure(error):
            alertMessage = error.localizedDescription
        }
    }

    func handleSelectedPhotos() {
        guard selectedPhotos.isEmpty == false else { return }
        let selections = selectedPhotos
        let parentID = importParentID
        // Release the PhotosUI selection immediately even when startup
        // recovery or another batch rejects this request. The admitted task
        // owns the only remaining copy until its sequential loop completes.
        selectedPhotos = []
        guard isCatalogWritable,
            let batchID = beginRootImportBatch() else { return }
        Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.finishRootImportBatch(batchID) }
            #if DEBUG
            await self.rootImportBatchSuspensionForTesting?()
            #endif
            var latestSuccessfulItemID: UUID?
            for (index, selection) in selections.enumerated() {
                do {
                    guard self.isCatalogWritable else { return }
                    guard let transfer = try await selection.loadTransferable(
                        type: CanvasImageTransfer.self
                    ) else {
                        throw CanvasDocumentImportError.unreadableImage
                    }
                    defer { transfer.discard() }
                    try self.requireCatalogWritable()
                    let data = try await CanvasImageIngestor.shared.validatedOriginalData(
                        fileURL: transfer.fileURL
                    )
                    try self.requireCatalogWritable()
                    let contentType = selection.supportedContentTypes.first ?? .image
                    let filenameExtension = contentType.preferredFilenameExtension ?? "image"
                    let name = "Photo \(index + 1).\(filenameExtension)"
                    if let importedID = await self.importImageData(
                        data,
                        filename: name,
                        contentType: contentType,
                        parentID: parentID,
                        opensOnSuccess: false
                    ) {
                        latestSuccessfulItemID = importedID
                    }
                } catch {
                    guard self.isCatalogWritable else { return }
                    self.alertMessage = error.localizedDescription
                }
            }
            if let latestSuccessfulItemID,
                let imported = self.repository.item(id: latestSuccessfulItemID) {
                self.open(imported)
            }
        }
    }

    private func beginRootImportBatch() -> UUID? {
        guard activeRootImportBatchID == nil else {
            showRootImportBusyMessage()
            return nil
        }
        let batchID = UUID()
        activeRootImportBatchID = batchID
        return batchID
    }

    private func finishRootImportBatch(_ batchID: UUID) {
        guard activeRootImportBatchID == batchID else { return }
        activeRootImportBatchID = nil
    }

    private func showRootImportBusyMessage() {
        alertMessage = "An import is already in progress. Let it finish before adding more files or photos."
    }

    #if DEBUG
    func setRootImportBatchSuspensionForTesting(
        _ suspension: (@MainActor () async -> Void)?
    ) {
        rootImportBatchSuspensionForTesting = suspension
    }

    func setCloseHandoffSuspensionForTesting(
        _ suspension: (@MainActor () async -> Void)?
    ) {
        closeHandoffSuspensionForTesting = suspension
    }

    func setPayloadOpenObserverForTesting(
        _ observer: (@MainActor (UUID) -> Void)?
    ) {
        payloadOpenObserverForTesting = observer
    }

    func setCompatibilityDerivedRefreshSuspensionForTesting(
        _ suspension: (
            @MainActor (Int64, CompatibilityDerivedRefreshTestPhase) async -> Void
        )?
    ) {
        compatibilityDerivedRefreshSuspensionForTesting = suspension
    }

    var hasActiveRootImportBatchForTesting: Bool {
        activeRootImportBatchID != nil
    }

    var activeCloseHandoffCountForTesting: Int {
        closeHandoffs.count
    }

    var pendingPayloadOpenItemIDForTesting: UUID? {
        pendingPayloadOpenItemID
    }

    #endif

    private func open(_ item: LibraryItemRecord) {
        guard isCatalogWritable else { return }
        if item.kind == .notebook
            || item.kind == .importedDocument
            || item.kind == .attachment {
            guard closeHandoffs.isEmpty else {
                // The ID is a bounded value snapshot. Replacing it implements
                // latest-request-wins without retaining another SwiftData
                // record or constructing a second CanvasEditorModel while the
                // outgoing model is still completing its durable handoff.
                pendingPayloadOpenItemID = item.id
                return
            }
            pendingPayloadOpenItemID = nil
        } else {
            // A later non-payload request supersedes an editor or attachment
            // tap that was waiting behind a close handoff.
            pendingPayloadOpenItemID = nil
        }
        #if DEBUG
        if item.kind == .notebook
            || item.kind == .importedDocument
            || item.kind == .attachment {
            payloadOpenObserverForTesting?(item.id)
        }
        #endif
        do {
            guard item.payloadState == .ready else {
                throw LibraryRepositoryError.itemNotReady(item.id)
            }
            switch item.kind {
            case .folder:
                try repository.markOpened(id: item.id)
                librarySession.selectScope(.folder(item.id))
                synchronizeRoute(with: librarySession.scope)
            case .notebook:
                activeEditor = makeActiveEditor(for: item)
                route = .notebook(item.id)
            case .canvas, .legacyTypedNote:
                throw LibraryAssetStoreError.itemNotFound(item.id)
            case .importedDocument:
                activeEditor = makeActiveEditor(for: item)
                route = .document(item.id)
            case .attachment:
                guard let filename = item.sourceFilename else {
                    throw LibraryAssetStoreError.itemNotFound(item.id)
                }
                let url = assetStore.directories(for: item.id).sources
                    .appendingPathComponent(filename)
                activeAttachment = ActiveAttachment(
                    itemID: item.id,
                    title: item.name,
                    url: url
                )
                route = .attachment(item.id)
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func makeActiveEditor(for item: LibraryItemRecord) -> ActiveEditor {
        ActiveEditor(item: item, model: makeEditorModel(for: item))
    }

    private func makeEditorModel(for item: LibraryItemRecord) -> CanvasEditorModel {
        let model = CanvasEditorModel.live(
            itemID: item.id,
            documentKind: item.kind,
            storageRootURL: assetStore.directories(for: item.id).canvas
        )
        model.configureDeletedPageArchiver(
            { [weak self] page, originalIndex in
                guard let self else { throw CanvasPageTrashError.unavailable }
                return try await self.archiveDeletedPage(
                    page,
                    originalIndex: originalIndex,
                    ownerItemID: item.id
                )
            },
            rollback: { [weak self] recordID in
                guard let self else { throw CanvasPageTrashError.unavailable }
                try await self.rollbackArchivedPage(recordID: recordID)
            }
        )
        return model
    }

    private func archiveDeletedPage(
        _ page: CanvasPageSnapshot,
        originalIndex: Int,
        ownerItemID: UUID
    ) async throws -> UUID {
        try requireCatalogWritable()
        let directories = assetStore.directories(for: ownerItemID)
        let store = CanvasCoreStore(rootURL: directories.canvas)
        let sourceReservation = await store.reserveImportedSources(
            forArchivedPage: page
        )
        do {
            let data = try await CanvasCoreStore.encodePageArchive(
                page,
                sourceRootURL: directories.sources
            )
            let filename = "deleted-page-\(page.id.uuidString).notate-page"
            _ = try await assetStore.write(
                data,
                named: filename,
                category: .canvas,
                for: ownerItemID
            )
            do {
                try requireCatalogWritable()
                let record = try repository.registerDeletedPage(
                    pageID: page.id,
                    ownerItemID: ownerItemID,
                    originalIndex: originalIndex,
                    payloadRelativePath: "Canvas/\(filename)",
                    title: "Page \(originalIndex + 1)"
                )
                await store.releaseImportedSourceReservation(sourceReservation)
                return record.id
            } catch {
                if let recovery = try? await assetStore.deleteItemAsset(
                    at: "Canvas/\(filename)",
                    for: ownerItemID
                ) {
                    try? await assetStore.discardRecoveryAsset(recovery)
                }
                throw error
            }
        } catch {
            await store.releaseImportedSourceReservation(sourceReservation)
            throw error
        }
    }

    /// Compensates the durable archive phase when PaperKit rejects the live
    /// page removal. The payload is staged first so a catalog save failure can
    /// put it back and retain the existing tombstone as the authority.
    private func rollbackArchivedPage(recordID: UUID) async throws {
        let asset = try repository.deletedPageAsset(id: recordID)
        // Failure to remove the now-redundant archive must not leave a
        // tombstone for a page PaperKit kept. In that case the catalog/live
        // document is restored and the orphan archive is harmless cleanup.
        let recovery = try? await assetStore.deleteItemAsset(
            at: asset.payloadRelativePath,
            for: asset.ownerItemID
        )
        do {
            _ = try repository.cancelDeletedPageRegistration(id: recordID)
        } catch {
            if let recovery {
                try? await assetStore.restoreAssetFromRecovery(recovery)
            }
            throw error
        }
        if let recovery {
            try? await assetStore.discardRecoveryAsset(recovery)
        }
    }

    private func createFolder(parentID: UUID?, draft: LibraryFolderDraft) {
        perform {
            _ = try repository.createItem(
                kind: .folder,
                name: draft.name,
                parentID: parentID,
                payloadState: .ready,
                folderSettings: LibraryFolderSettings(
                    color: draft.color.libraryRGBAColor,
                    symbolName: draft.symbolName
                )
            )
        }
    }

    private func createNotebook(parentID: UUID?, draft: LibraryNotebookDraft) {
        Task { [weak self] in
            guard let self, self.isCatalogWritable else { return }
            do {
                let preparedCover = try await self.prepareNotebookCover(
                    choice: draft.coverChoice,
                    customCover: draft.customCover,
                    title: draft.name,
                    itemID: nil
                )
                try self.requireCatalogWritable()
                await self.createEditableItem(
                    kind: .notebook,
                    name: draft.name,
                    parentID: parentID,
                    cover: draft.coverChoice
                ) { itemID in
                    try await CanvasDocumentImporter.createBlankNotebook(
                        itemID: itemID,
                        storageRootURL: self.assetStore.directories(for: itemID).canvas,
                        coverImageData: preparedCover?.data,
                        coverSourceRelativePath: preparedCover?.canvasSourceRelativePath
                    )
                }
            } catch {
                self.alertMessage = error.localizedDescription
            }
        }
    }

    private func createEditableItem(
        kind: LibraryItemKind,
        name: String,
        parentID: UUID?,
        cover: LibraryCoverChoice,
        buildPayload: @escaping @MainActor (UUID) async throws -> CanvasCoreSnapshot
    ) async {
        var createdID: UUID?
        do {
            try requireCatalogWritable()
            let item = try repository.createItem(
                kind: kind,
                name: name,
                parentID: parentID,
                coverChoice: cover,
                payloadState: .creating,
                pageCount: 0
            )
            createdID = item.id
            try requireCatalogWritable()
            _ = try await assetStore.prepareItem(id: item.id)
            try requireCatalogWritable()
            let snapshot = try await buildPayload(item.id)
            try requireCatalogWritable()
            let previewGeneration = try? await LibraryPreviewPipeline.commit(
                snapshot: snapshot,
                itemID: item.id,
                kind: kind,
                assetStore: assetStore
            )
            try requireCatalogWritable()
            try repository.updatePayload(
                itemID: item.id,
                state: .ready,
                pageCount: snapshot.pages.count,
                previewGeneration: previewGeneration
            )
            if let refreshed = repository.item(id: item.id) {
                open(refreshed)
            }
        } catch {
            if isCatalogWritable, let createdID { await discardFailedItem(createdID) }
            if isCatalogWritable { alertMessage = error.localizedDescription }
        }
    }

    private func renameItem(id: UUID, name: String) {
        perform { try renameEditorItem(id: id, to: name) }
    }

    func renameEditorItem(id: UUID, to name: String) throws {
        try requireCatalogWritable()
        try repository.renameItem(id: id, to: name)
    }

    private func updateFolder(id: UUID, draft: LibraryFolderDraft) {
        perform {
            try repository.updateFolder(
                id: id,
                name: draft.name,
                settings: LibraryFolderSettings(
                    color: draft.color.libraryRGBAColor,
                    symbolName: draft.symbolName
                )
            )
        }
    }

    private func setCover(
        id: UUID,
        cover: LibraryCoverChoice,
        customCover: LibraryCustomCoverDraft?
    ) {
        Task { [weak self] in
            guard let self, self.isCatalogWritable else { return }
            do {
                guard let item = repository.item(id: id) else {
                    throw LibraryRepositoryError.itemNotFound(id)
                }
                guard item.kind == .notebook, isUITesting == false else {
                    try repository.updateCover(itemID: id, choice: cover)
                    return
                }

                let preparedCover = try await prepareNotebookCover(
                    choice: cover,
                    customCover: customCover,
                    title: item.name,
                    itemID: id
                )
                try requireCatalogWritable()
                try await reconcileNotebookCover(
                    item: item,
                    choice: cover,
                    preparedCover: preparedCover
                )
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    private func prepareNotebookCover(
        choice: LibraryCoverChoice,
        customCover: LibraryCustomCoverDraft?,
        title: String,
        itemID: UUID?
    ) async throws -> PreparedNotebookCover? {
        switch choice {
        case .automatic:
            return nil

        case .preset:
            let pageSize = CanvasConstants.a4PortraitSize
            let renderer = ImageRenderer(
                content: LibraryCoverArtwork(choice: choice, title: title)
                    .frame(width: pageSize.width, height: pageSize.height)
            )
            renderer.scale = 2
            guard let data = renderer.uiImage?.pngData(), data.isEmpty == false else {
                throw NotebookCoverError.renderingFailed
            }
            return PreparedNotebookCover(
                data: data,
                canvasSourceRelativePath:
                    "\(CanvasDocumentImporter.managedNotebookCoverSourcePrefix)"
                    + "preset-\(UUID().uuidString).png"
            )
        case let .customAsset(itemRelativePath):
            if let customCover {
                guard customCover.itemRelativePath == itemRelativePath else {
                    throw NotebookCoverError.missingCustomImage
                }
                return PreparedNotebookCover(
                    data: customCover.data,
                    canvasSourceRelativePath: customCover.canvasSourceRelativePath
                )
            }
            guard let itemID else { throw NotebookCoverError.missingCustomImage }
            let data = try await assetStore.readItemAsset(
                at: itemRelativePath,
                for: itemID,
                maximumByteCount: LibraryAssetReadLimits.customCoverEncodedByteCount
            )
            let sourcesPrefix = "\(LibraryAssetCategory.sources.rawValue)/"
            guard itemRelativePath.hasPrefix(sourcesPrefix) else {
                throw NotebookCoverError.missingCustomImage
            }
            let sourceRelativePath = String(itemRelativePath.dropFirst(sourcesPrefix.count))
            return PreparedNotebookCover(
                data: data,
                canvasSourceRelativePath: sourceRelativePath
            )
        }
    }

    private func reconcileNotebookCover(
        item: LibraryItemRecord,
        choice: LibraryCoverChoice,
        preparedCover: PreparedNotebookCover?
    ) async throws {
        try requireCatalogWritable()
        let store = CanvasCoreStore(rootURL: assetStore.directories(for: item.id).canvas)
        let previousSnapshot: CanvasCoreSnapshot
        switch await store.load() {
        case let .restored(snapshot):
            previousSnapshot = snapshot
        case .newDocument:
            throw CanvasCoreStoreError.invalidSnapshot(
                "The notebook has no saved pages to update."
            )
        case let .failed(error):
            throw error
        }
        try requireCatalogWritable()

        let previousChoice = item.coverChoice
        let existingCover = previousSnapshot.pages.first(
            where: CanvasDocumentImporter.isManagedNotebookCover
        )
        var pages = previousSnapshot.pages.filter {
            CanvasDocumentImporter.isManagedNotebookCover($0) == false
        }
        if pages.isEmpty {
            pages.append(
                CanvasPageSnapshot(
                    markup: PaperMarkup(
                        bounds: CGRect(
                            origin: .zero,
                            size: CanvasConstants.a4PortraitSize
                        )
                    )
                )
            )
        }
        if let preparedCover {
            let coverPage = CanvasPageSnapshot(
                id: existingCover?.id ?? UUID(),
                markup: PaperMarkup(
                    bounds: CGRect(
                        origin: .zero,
                        size: CanvasConstants.a4PortraitSize
                    )
                ),
                geometry: CanvasPageGeometry(
                    authoredSize: CanvasConstants.a4PortraitSize
                ),
                background: .image(
                    data: preparedCover.data,
                    suggestedName: "Notebook Cover",
                    sourceRelativePath: preparedCover.canvasSourceRelativePath
                )
            )
            pages.insert(coverPage, at: 0)
        }
        let remainingIDs = Set(pages.map(\.id))
        guard let fallbackPageID = pages.first?.id else {
            throw CanvasCoreStoreError.invalidSnapshot(
                "A notebook cover update must preserve at least one page."
            )
        }
        let currentPageID = remainingIDs.contains(previousSnapshot.currentPageID)
            ? previousSnapshot.currentPageID
            : fallbackPageID
        let updatedSnapshot = CanvasCoreSnapshot(
            generation: previousSnapshot.generation + 1,
            pages: pages,
            currentPageID: currentPageID
        )

        try requireCatalogWritable()
        try await store.checkpoint(updatedSnapshot)
        guard isCatalogWritable else {
            let rollback = CanvasCoreSnapshot(
                generation: updatedSnapshot.generation + 1,
                pages: previousSnapshot.pages,
                currentPageID: previousSnapshot.currentPageID
            )
            try? await store.checkpoint(rollback)
            throw LibraryMutationGateError.recoveryIncomplete
        }
        do {
            try repository.updateCover(itemID: item.id, choice: choice)
        } catch {
            let rollback = CanvasCoreSnapshot(
                generation: updatedSnapshot.generation + 1,
                pages: previousSnapshot.pages,
                currentPageID: previousSnapshot.currentPageID
            )
            try? await store.checkpoint(rollback)
            try? repository.updateCover(itemID: item.id, choice: previousChoice)
            throw error
        }
        let searchableText = await CanvasDocumentSearchIndexer.searchableText(
            for: updatedSnapshot.pages
        )
        try requireCatalogWritable()
        let previewGeneration = try? await LibraryPreviewPipeline.commit(
            snapshot: updatedSnapshot,
            itemID: item.id,
            kind: .notebook,
            assetStore: assetStore
        )
        try requireCatalogWritable()
        try repository.updatePayload(
            itemID: item.id,
            state: .ready,
            pageCount: updatedSnapshot.pages.count,
            searchableText: searchableText,
            previewGeneration: previewGeneration
        )
    }

    private func toggleFavorite(id: UUID) {
        perform {
            guard let item = repository.item(id: id) else {
                throw LibraryRepositoryError.itemNotFound(id)
            }
            try repository.setFavorite(itemID: id, isFavorite: !item.isFavorite)
        }
    }

    private func duplicateItem(id: UUID) {
        Task { [weak self] in
            guard let self, self.isCatalogWritable else { return }
            var plan: LibraryDuplicationPlan?
            do {
                try requireCatalogWritable()
                let prepared = try repository.prepareDuplicateItem(id: id)
                plan = prepared
                try await assetStore.duplicateItemAssets(
                    using: prepared.sourceToDuplicateItemIDs
                )
                try requireCatalogWritable()
                _ = try repository.completeDuplication(prepared)
            } catch {
                if isCatalogWritable, let plan {
                    let targetIDs = (try? repository.cancelDuplication(plan))
                        ?? Array(plan.sourceToDuplicateItemIDs.values)
                    for targetID in targetIDs {
                        if let recovery = try? await assetStore.moveItemAssetsToRecoveryTrash(
                            itemID: targetID
                        ) {
                            try? await assetStore.discardRecoveryItem(at: recovery)
                        }
                    }
                }
                if isCatalogWritable { alertMessage = error.localizedDescription }
            }
        }
    }

    private func moveItems(_ ids: Set<UUID>, to parentID: UUID?) -> Bool {
        guard isCatalogWritable else { return false }
        do {
            if let pendingID = ids.first(where: {
                repository.item(id: $0)?.payloadState != .ready
            }) {
                throw LibraryRepositoryError.itemNotReady(pendingID)
            }
            if let parentID,
                repository.item(id: parentID)?.payloadState != .ready {
                throw LibraryRepositoryError.itemNotReady(parentID)
            }
            try repository.moveItems(ids: ids, toParentID: parentID)
            return true
        } catch {
            alertMessage = error.localizedDescription
            return false
        }
    }

    private func moveToTrash(_ ids: Set<UUID>) {
        guard isCatalogWritable else { return }
        do {
            try repository.moveToTrash(itemIDs: ids)
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func restoreItems(_ ids: Set<UUID>) {
        guard isCatalogWritable else { return }
        do {
            for id in ids { try repository.restoreFromTrash(itemID: id) }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func deletePermanently(_ ids: Set<UUID>) {
        Task { [weak self] in
            guard let self, self.isCatalogWritable else { return }
            do {
                for id in ids.sorted(by: { $0.uuidString < $1.uuidString }) {
                    try requireCatalogWritable()
                    try await permanentlyDeleteItem(id: id)
                }
            } catch {
                if isCatalogWritable { alertMessage = error.localizedDescription }
            }
        }
    }

    private func permanentlyDeleteItem(id: UUID) async throws {
        try requireCatalogWritable()
        let plan = try repository.makePermanentDeletionPlan(itemID: id)
        try requireCatalogWritable()
        try await commitDeletionPlan(plan)
    }

    private func restoreDeletedPage(id recordID: UUID) {
        Task { [weak self] in
            guard let self, self.isCatalogWritable else { return }
            do {
                try await restoreDeletedPageTransaction(id: recordID)
            } catch {
                if isCatalogWritable { alertMessage = error.localizedDescription }
            }
        }
    }

    /// Restores one archived page across the checkpoint, archive file, and
    /// SwiftData tombstone. If catalog acknowledgement fails, a later verified
    /// checkpoint removes the page again and the archived payload is restored,
    /// leaving the tombstone as the single durable authority for retry.
    func restoreDeletedPageTransaction(id recordID: UUID) async throws {
        try requireCatalogWritable()
        let restoration = try repository.deletedPageRestoration(id: recordID)
        let archiveData = try await assetStore.readItemAsset(
            at: restoration.payloadRelativePath,
            for: restoration.ownerItemID,
            maximumByteCount: LibraryAssetReadLimits.deletedPageArchiveEncodedByteCount
        )
        let page = try await CanvasCoreStore.decodePageArchive(
            archiveData,
            sourceRootURL: assetStore.directories(for: restoration.ownerItemID).sources
        )
        try requireCatalogWritable()
        guard page.id == restoration.pageID else {
            throw CanvasCoreStoreError.invalidEnvelope(
                "The archived page identity does not match its Trash record."
            )
        }
        let canvasRoot = assetStore.directories(for: restoration.ownerItemID).canvas
        let store = CanvasCoreStore(rootURL: canvasRoot)
        let loaded = await store.load()
        let snapshot: CanvasCoreSnapshot
        switch loaded {
        case let .restored(restored):
            snapshot = restored
        case .newDocument:
            throw CanvasCoreStoreError.invalidSnapshot(
                "The page's document is no longer available."
            )
        case let .failed(error):
            throw error
        }
        try requireCatalogWritable()

        // Reserve one generation for publish and one for compensation before
        // touching either durable store.
        guard snapshot.generation <= Int64.max - 2 else {
            throw CanvasCoreStoreError.invalidSnapshot(
                "The document generation cannot be advanced safely."
            )
        }
        let pagesWithoutRestoredPage = snapshot.pages.filter { $0.id != page.id }
        guard let fallbackCurrentPageID = pagesWithoutRestoredPage.first?.id else {
            throw CanvasCoreStoreError.invalidSnapshot(
                "A document must retain at least one page."
            )
        }
        let rollbackCurrentPageID = pagesWithoutRestoredPage.contains(where: {
            $0.id == snapshot.currentPageID
        }) ? snapshot.currentPageID : fallbackCurrentPageID
        let archiveURL = assetStore.directories(for: restoration.ownerItemID)
            .itemRoot
            .appendingPathComponent(restoration.payloadRelativePath)
        let sourceReservation = await store.reserveImportedSources(
            whileDeletingPageArchiveAt: archiveURL
        )
        let transaction: LibraryAssetTrashTransaction
        do {
            transaction = try await assetStore.stageRecoveryTransaction(
                purpose: .deletedPageRestore,
                catalogAnchors: [
                    LibraryAssetTrashManifest.CatalogAnchor(
                        kind: .deletedPage,
                        id: recordID
                    )
                ],
                intents: [
                    .itemAsset(
                        itemID: restoration.ownerItemID,
                        relativePath: restoration.payloadRelativePath,
                        isRequired: true
                    )
                ]
            )
        } catch {
            await store.releaseImportedSourceReservation(sourceReservation)
            throw error
        }
        var publishedGeneration = snapshot.generation
        if snapshot.pages.contains(where: { $0.id == page.id }) == false {
            var pages = snapshot.pages
            pages.insert(page, at: min(restoration.originalIndex, pages.count))
            publishedGeneration += 1
            let restoredSnapshot = CanvasCoreSnapshot(
                generation: publishedGeneration,
                pages: pages,
                currentPageID: snapshot.currentPageID
            )
            do {
                try await store.checkpoint(restoredSnapshot)
                guard case let .restored(verified) = await store.load(),
                    verified.generation == publishedGeneration,
                    verified.pages.contains(where: { $0.id == page.id }) else {
                    throw CanvasCoreStoreError.verificationFailed(
                        "The restored page was not present after checkpoint verification."
                    )
                }
            } catch {
                // Publication can fail after the atomic rename but before the
                // caller observes verification. Keep the journal intact; the
                // next startup resolves it from the verified page identity.
                await store.releaseImportedSourceReservation(sourceReservation)
                blockLibraryForRecoveryFailure(error)
                throw error
            }
        }
        @MainActor
        func rollbackPublishedCheckpoint() async throws {
            let rollbackSnapshot = CanvasCoreSnapshot(
                generation: publishedGeneration + 1,
                pages: pagesWithoutRestoredPage,
                currentPageID: rollbackCurrentPageID
            )
            try await store.checkpoint(rollbackSnapshot)
            guard case let .restored(verifiedRollback) = await store.load(),
                verifiedRollback.generation == rollbackSnapshot.generation,
                verifiedRollback.pages.contains(where: { $0.id == page.id }) == false else {
                throw CanvasCoreStoreError.verificationFailed(
                    "The failed page restore could not be rolled back."
                )
            }
        }
        do {
            try deletedPageAcknowledgement(repository, recordID)
        } catch {
            let acknowledgementError = error
            do {
                try await rollbackPublishedCheckpoint()
            } catch {
                await store.releaseImportedSourceReservation(sourceReservation)
                blockLibraryForRecoveryFailure(error)
                throw CanvasCoreStoreError.verificationFailed(
                    "Page restoration acknowledgement failed and the checkpoint rollback is pending recovery: \(error.localizedDescription)"
                )
            }
            do {
                try await assetStore.restoreRecoveryTransaction(transaction)
            } catch {
                await store.releaseImportedSourceReservation(sourceReservation)
                blockLibraryForRecoveryFailure(error)
                throw CanvasCoreStoreError.verificationFailed(
                    "Page restoration acknowledgement failed and the archive rollback is pending recovery: \(error.localizedDescription)"
                )
            }
            await store.releaseImportedSourceReservation(sourceReservation)
            throw acknowledgementError
        }
        _ = await finishCommittedRecoveryTransaction(transaction)
        await store.releaseImportedSourceReservation(sourceReservation)
        await refreshCompatibilityDerivedData(
            itemID: restoration.ownerItemID,
            minimumGeneration: publishedGeneration
        )
    }

    private func deleteDeletedPagePermanently(id recordID: UUID) {
        Task { [weak self] in
            guard let self, self.isCatalogWritable else { return }
            do {
                let asset = try repository.deletedPageAsset(id: recordID)
                try requireCatalogWritable()
                try await commitDeletionPlan(
                    LibraryPurgePlan(deletedPageAssets: [asset])
                )
            } catch {
                if isCatalogWritable { alertMessage = error.localizedDescription }
            }
        }
    }

    private func createTag(_ draft: LibraryTagDraft) {
        perform {
            _ = try repository.createTag(name: draft.name, color: draft.color.libraryRGBAColor)
        }
    }

    private func updateTag(id: UUID, draft: LibraryTagDraft) {
        perform {
            try repository.updateTag(
                id: id,
                name: draft.name,
                color: draft.color.libraryRGBAColor
            )
        }
    }

    private func deleteTag(id: UUID) {
        perform { try repository.deleteTag(id: id) }
    }

    private func assignTag(tagID: UUID, itemID: UUID) {
        perform { try repository.assignTag(tagID: tagID, to: itemID) }
    }

    private func removeTag(tagID: UUID, itemID: UUID) {
        perform { try repository.removeTag(tagID: tagID, from: itemID) }
    }

    private func importFile(
        at url: URL,
        parentID: UUID?,
        opensOnSuccess: Bool = true
    ) async -> UUID? {
        guard isCatalogWritable else { return nil }
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }
        do {
            let prepared = try await Self.prepareFileImport(at: url)
            try requireCatalogWritable()
            let contentType = UTType(prepared.contentTypeIdentifier) ?? .data
            if contentType.conforms(to: .pdf) {
                return await importEditableData(
                    prepared.data,
                    filename: prepared.filename,
                    contentType: contentType,
                    parentID: parentID,
                    searchableText: prepared.nativePDFText,
                    opensOnSuccess: opensOnSuccess,
                    importer: { data, name, itemID, sourceRelativePath in
                        try await CanvasDocumentImporter.importPDF(
                            data: data,
                            suggestedName: name,
                            into: itemID,
                            storageRootURL: self.assetStore.directories(for: itemID).canvas,
                            sourceRelativePath: sourceRelativePath
                        )
                    }
                )
            } else if contentType.conforms(to: .image) {
                return await importImageData(
                    prepared.data,
                    filename: prepared.filename,
                    contentType: contentType,
                    parentID: parentID,
                    opensOnSuccess: opensOnSuccess
                )
            } else {
                return await importAttachmentData(
                    prepared.data,
                    filename: prepared.filename,
                    contentType: contentType,
                    parentID: parentID,
                    opensOnSuccess: opensOnSuccess
                )
            }
        } catch {
            if isCatalogWritable { alertMessage = error.localizedDescription }
            return nil
        }
    }
    /// File coordination, byte loading, PDF validation, and native text
    /// extraction can all be proportional to the imported file size. Keep
    /// that work off the main actor so the library remains interactive while
    /// the item is prepared.
    nonisolated static func prepareFileImport(
        at url: URL,
        policy: CanvasDocumentIngestionPolicy = .canvasDefault
    ) async throws -> PreparedFileImport {
        try await Task.detached(priority: .userInitiated) {
            let values = try url.resourceValues(forKeys: [.contentTypeKey, .nameKey])
            let filename = values.name ?? url.lastPathComponent
            let contentType = values.contentType
                ?? UTType(filenameExtension: url.pathExtension)
                ?? .data
            let data: Data
            if contentType.conforms(to: .image) {
                data = try await CanvasImageIngestor.shared.validatedOriginalData(
                    fileURL: url
                )
            } else if contentType.conforms(to: .pdf) {
                data = try CanvasBoundedFileReader.read(
                    from: url,
                    maximumByteCount: policy.maximumPDFEncodedByteCount
                )
            } else {
                data = try CanvasBoundedFileReader.read(
                    from: url,
                    maximumByteCount: policy.maximumAttachmentEncodedByteCount
                )
            }
            var nativePDFText = ""

            if contentType.conforms(to: .pdf) {
                nativePDFText = try CanvasPDFSourceValidator.validate(
                    data: data,
                    policy: policy
                ).nativeText
            }

            return PreparedFileImport(
                data: data,
                filename: filename,
                contentTypeIdentifier: contentType.identifier,
                nativePDFText: nativePDFText
            )
        }.value
    }

    private func importImageData(
        _ data: Data,
        filename: String,
        contentType: UTType,
        parentID: UUID?,
        opensOnSuccess: Bool = true
    ) async -> UUID? {
        guard isCatalogWritable else { return nil }
        return await importEditableData(
            data,
            filename: filename,
            contentType: contentType,
            parentID: parentID,
            opensOnSuccess: opensOnSuccess,
            importer: { data, name, itemID, sourceRelativePath in
                try await CanvasDocumentImporter.importImage(
                    data: data,
                    suggestedName: name,
                    into: itemID,
                    storageRootURL: self.assetStore.directories(for: itemID).canvas,
                    sourceRelativePath: sourceRelativePath
                )
            }
        )
    }

    private func importEditableData(
        _ data: Data,
        filename: String,
        contentType: UTType,
        parentID: UUID?,
        searchableText: String = "",
        opensOnSuccess: Bool = true,
        importer: @escaping @MainActor (
            Data,
            String,
            UUID,
            String
        ) async throws -> CanvasCoreSnapshot
    ) async -> UUID? {
        var createdID: UUID?
        do {
            try requireCatalogWritable()
            let item = try repository.createItem(
                kind: .importedDocument,
                name: displayName(for: filename),
                parentID: parentID,
                payloadState: .importing,
                sourceFilename: filename,
                sourceContentTypeIdentifier: contentType.identifier
            )
            createdID = item.id
            let storedName = safeFilename(filename)
            try requireCatalogWritable()
            _ = try await assetStore.write(
                data,
                named: storedName,
                category: .sources,
                for: item.id
            )
            try requireCatalogWritable()
            let snapshot = try await importer(data, filename, item.id, storedName)
            try requireCatalogWritable()
            // Preview rendering is derived and best effort: the imported
            // document remains valid if thumbnail generation fails, while a
            // successful render is published before the item becomes ready.
            let previewGeneration = try? await LibraryPreviewPipeline.commit(
                snapshot: snapshot,
                itemID: item.id,
                kind: .importedDocument,
                assetStore: assetStore
            )
            try requireCatalogWritable()
            try repository.updatePayload(
                itemID: item.id,
                state: .ready,
                pageCount: snapshot.pages.count,
                searchableText: searchableText,
                previewGeneration: previewGeneration
            )
            if opensOnSuccess,
                let refreshed = repository.item(id: item.id) {
                open(refreshed)
            }
            return item.id
        } catch {
            if isCatalogWritable, let createdID { await discardFailedItem(createdID) }
            if isCatalogWritable { alertMessage = error.localizedDescription }
            return nil
        }
    }

    private func importAttachmentData(
        _ data: Data,
        filename: String,
        contentType: UTType,
        parentID: UUID?,
        opensOnSuccess: Bool = true
    ) async -> UUID? {
        var createdID: UUID?
        do {
            try requireCatalogWritable()
            let storedName = safeFilename(filename)
            let item = try repository.createItem(
                kind: .attachment,
                name: displayName(for: filename),
                parentID: parentID,
                payloadState: .importing,
                sourceFilename: storedName,
                sourceContentTypeIdentifier: contentType.identifier
            )
            createdID = item.id
            try requireCatalogWritable()
            _ = try await assetStore.write(
                data,
                named: storedName,
                category: .sources,
                for: item.id
            )
            try requireCatalogWritable()
            try repository.updatePayload(itemID: item.id, state: .ready, pageCount: 0)
            if opensOnSuccess,
                let refreshed = repository.item(id: item.id) {
                open(refreshed)
            }
            return item.id
        } catch {
            if isCatalogWritable, let createdID { await discardFailedItem(createdID) }
            if isCatalogWritable { alertMessage = error.localizedDescription }
            return nil
        }
    }

    private func discardFailedItem(_ itemID: UUID) async {
        guard isCatalogWritable else { return }
        do {
            try repository.moveToTrash(itemID: itemID)
            try await permanentlyDeleteItem(id: itemID)
        } catch {
            // Leave the failed payload in recoverable Trash when coordinated
            // catalog and filesystem cleanup cannot complete safely.
        }
    }

    /// Resolves the editor's latest verified checkpoint and, when Canvas Core
    /// promoted an older recovery head, fences the stale preview and catalog
    /// generation before derived data is rebuilt. Returns the verified
    /// generation, or nil when the checkpoint is not safe to publish from.
    private func verifiedGenerationForDerivedRefresh(
        itemID: UUID,
        model: CanvasEditorModel
    ) async -> Int64? {
        guard !Task.isCancelled,
            isCatalogWritable,
            let initialItem = repository.item(id: itemID),
            initialItem.payloadState == .ready,
            initialItem.isTrashed == false,
            initialItem.kind == .notebook
            || initialItem.kind == .importedDocument else { return nil }

        let snapshot: CanvasCoreSnapshot
        if let verified = model.latestVerifiedIndexSnapshot,
            verified.generation == model.verifiedCheckpointGeneration {
            snapshot = verified
        } else {
            // Recovery-only fallback when the in-memory verified snapshot is
            // unavailable.
            let store = CanvasCoreStore(
                rootURL: assetStore.directories(for: itemID).canvas
            )
            let loadResult = await Task.detached(priority: .utility) {
                await store.load()
            }.value
            guard case let .restored(restored) = loadResult else { return nil }
            snapshot = restored
        }

        guard !Task.isCancelled,
            isCatalogWritable,
            let item = repository.item(id: itemID),
            item.payloadState == .ready,
            item.isTrashed == false,
            item.kind == .notebook
            || item.kind == .importedDocument else { return nil }

        if item.previewGeneration > snapshot.generation {
            // Canvas Core has already promoted this recovered checkpoint as
            // the durable head. The higher preview generation remains a
            // durable recovery marker until the replacement thumbnail commits.
            guard model.saveState == .saved,
                model.verifiedCheckpointGeneration == snapshot.generation,
                !Task.isCancelled else { return nil }

            // `library.png` has no embedded generation stamp. Its physical
            // removal is therefore part of the recovery fence, not a
            // best-effort cache hint.
            let thumbnailURL = assetStore.directories(for: itemID)
                .thumbnails
                .appendingPathComponent("library.png", isDirectory: false)
            let thumbnailFenced: Bool
            do {
                if FileManager.default.fileExists(atPath: thumbnailURL.path) {
                    try FileManager.default.removeItem(at: thumbnailURL)
                }
                thumbnailFenced = FileManager.default.fileExists(
                    atPath: thumbnailURL.path
                ) == false
            } catch {
                thumbnailFenced = false
            }
            guard thumbnailFenced else { return nil }

            do {
                _ = try repository.reconcileRecoveredPayload(
                    itemID: itemID,
                    verifiedGeneration: snapshot.generation,
                    pageCount: snapshot.pages.count
                )
            } catch {
                return nil
            }
            await librarySession.thumbnailStore.invalidate(itemIDs: [itemID])
            guard model.saveState == .saved,
                model.verifiedCheckpointGeneration == snapshot.generation,
                !Task.isCancelled else { return nil }
        }

        guard !Task.isCancelled,
            isCatalogWritable,
            let current = repository.item(id: itemID),
            current.payloadState == .ready,
            current.isTrashed == false,
            model.verifiedCheckpointGeneration == snapshot.generation else {
            return nil
        }
        return snapshot.generation
    }

    /// Coalesces the complete post-checkpoint pipeline. A successor drains its cancelled predecessor before starting,
    /// so frequent autosaves cannot build a queue of extraction and thumbnail
    /// work while the user is still writing.
    private func scheduleDerivedLibraryRefresh(
        itemID: UUID,
        model: CanvasEditorModel
    ) {
        guard isCatalogWritable else { return }
        advanceCompatibilityDerivedGenerationFloor(
            itemID: itemID,
            generation: model.verifiedCheckpointGeneration
        )
        let previous = derivedRefreshes[itemID]?.task
        previous?.cancel()
        let refreshID = UUID()
        let task = Task(priority: .utility) { @MainActor [weak self, weak model] in
            _ = await previous?.result
            guard !Task.isCancelled else { return }
            // A verified save does not mean the writer is finished. Give
            // Pencil and keyboard input a genuine quiet window before doing
            // disposable indexing/preview work.
            try? await Task.sleep(for: .milliseconds(1_500))
            guard !Task.isCancelled, let self, let model,
                self.isCatalogWritable,
                model.saveState == .saved else { return }
            defer {
                if self.derivedRefreshes[itemID]?.id == refreshID {
                    self.derivedRefreshes.removeValue(forKey: itemID)
                }
            }
            guard let generation = await self.verifiedGenerationForDerivedRefresh(
                itemID: itemID,
                model: model
            ) else { return }
            guard !Task.isCancelled, self.isCatalogWritable else { return }
            await self.refreshCompatibilityDerivedData(
                itemID: itemID,
                minimumGeneration: generation
            )
        }
        derivedRefreshes[itemID] = (refreshID, task)
    }

    private func advanceCompatibilityDerivedGenerationFloor(
        itemID: UUID,
        generation: Int64
    ) {
        let generation = max(generation, 0)
        guard let currentFloor = compatibilityDerivedGenerationFloors[itemID]
        else {
            compatibilityDerivedGenerationFloors[itemID] = generation
            if generation > 0 {
                compatibilityDerivedAuthorityEpochs[itemID, default: 0] &+= 1
            }
            return
        }
        guard generation > currentFloor else { return }
        compatibilityDerivedGenerationFloors[itemID] = generation
        compatibilityDerivedAuthorityEpochs[itemID, default: 0] &+= 1
    }

    private func compatibilityDerivedAuthorityEpoch(itemID: UUID) -> UInt64 {
        compatibilityDerivedAuthorityEpochs[itemID, default: 0]
    }

    /// Admits the Canvas head loaded by this invocation. A lower generation is
    /// valid only when the authority epoch stayed unchanged throughout the
    /// load; in that case Canvas Core has promoted an older verified recovery
    /// slot. Bumping the epoch before accepting it makes every producer that
    /// loaded before this recovery permanently stale.
    private func reconcileCompatibilityDerivedAuthority(
        itemID: UUID,
        loadedGeneration: Int64,
        epochBeforeLoad: UInt64
    ) -> (epoch: UInt64, recoveredLowerHead: Bool)? {
        guard compatibilityDerivedAuthorityEpoch(itemID: itemID)
            == epochBeforeLoad else { return nil }
        let floor = compatibilityDerivedGenerationFloors[itemID] ?? 0
        guard loadedGeneration < floor else {
            return (epochBeforeLoad, false)
        }
        compatibilityDerivedRefreshClaims.removeValue(forKey: itemID)
        compatibilityDerivedGenerationFloors[itemID] = max(loadedGeneration, 0)
        compatibilityDerivedAuthorityEpochs[itemID, default: 0] &+= 1
        return (
            compatibilityDerivedAuthorityEpoch(itemID: itemID),
            true
        )
    }

    private func beginCompatibilityDerivedRefresh(
        itemID: UUID,
        generation: Int64,
        authorityEpoch: UInt64
    ) -> CompatibilityDerivedRefreshClaim? {
        guard compatibilityDerivedAuthorityEpoch(itemID: itemID)
            == authorityEpoch,
            generation >= (compatibilityDerivedGenerationFloors[itemID] ?? 0),
            generation >= (
                compatibilityDerivedRefreshClaims[itemID]?.generation ?? 0
            ) else {
            return nil
        }
        let claimEpoch: UInt64
        if generation > (compatibilityDerivedGenerationFloors[itemID] ?? 0) {
            advanceCompatibilityDerivedGenerationFloor(
                itemID: itemID,
                generation: generation
            )
            claimEpoch = compatibilityDerivedAuthorityEpoch(itemID: itemID)
        } else {
            // Generation zero is a valid first checkpoint. Seed its absent
            // floor without changing the epoch captured before the load.
            if compatibilityDerivedGenerationFloors[itemID] == nil {
                compatibilityDerivedGenerationFloors[itemID] = 0
            }
            claimEpoch = authorityEpoch
        }
        let claim = CompatibilityDerivedRefreshClaim(
            id: UUID(),
            generation: generation,
            authorityEpoch: claimEpoch
        )
        compatibilityDerivedRefreshClaims[itemID] = claim
        return claim
    }

    private func compatibilityDerivedRefreshIsCurrent(
        _ claim: CompatibilityDerivedRefreshClaim,
        itemID: UUID
    ) -> Bool {
        !Task.isCancelled
            && isCatalogWritable
            && compatibilityDerivedRefreshClaims[itemID] == claim
            && compatibilityDerivedGenerationFloors[itemID] == claim.generation
            && compatibilityDerivedAuthorityEpoch(itemID: itemID)
            == claim.authorityEpoch
    }

    private func finishCompatibilityDerivedRefresh(
        _ claim: CompatibilityDerivedRefreshClaim,
        itemID: UUID
    ) {
        guard compatibilityDerivedRefreshClaims[itemID] == claim else { return }
        compatibilityDerivedRefreshClaims.removeValue(forKey: itemID)
    }

    @discardableResult
    private func failCloseCompatibilityDerivedProjection(
        itemID: UUID,
        claim: CompatibilityDerivedRefreshClaim,
        pageCount: Int?
    ) async -> Bool {
        guard compatibilityDerivedRefreshIsCurrent(claim, itemID: itemID) else {
            return false
        }
        let catalogWasFenced: Bool
        do {
            try repository.updateDerivedPayload(
                itemID: itemID,
                pageCount: pageCount,
                searchableText: ""
            )
            if derivedCatalogPersistenceFailures[itemID]?.generation
                == claim.generation {
                derivedCatalogPersistenceFailures.removeValue(forKey: itemID)
            }
            catalogWasFenced = true
        } catch {
            derivedCatalogPersistenceFailures[itemID] =
                DerivedCatalogPersistenceFailure(
                    generation: claim.generation,
                    searchableTextUTF8ByteCount: 0,
                    errorDescription: error.localizedDescription
                )
            catalogWasFenced = false
        }
        return catalogWasFenced
    }

    private func compatibilityDerivedHeadIsCurrent(
        store: CanvasCoreStore,
        claim: CompatibilityDerivedRefreshClaim,
        itemID: UUID,
        retryAttempt: Int,
        fencesPublishedProjectionOnMismatch: Bool = false
    ) async -> Bool {
        guard compatibilityDerivedRefreshIsCurrent(claim, itemID: itemID) else {
            return false
        }
        let loadResult = await store.load()
        guard compatibilityDerivedRefreshIsCurrent(claim, itemID: itemID) else {
            return false
        }
        guard case let .restored(head) = loadResult else {
            if fencesPublishedProjectionOnMismatch {
                _ = await failCloseCompatibilityDerivedProjection(
                    itemID: itemID,
                    claim: claim,
                    pageCount: nil
                )
            }
            guard compatibilityDerivedRefreshIsCurrent(
                claim,
                itemID: itemID
            ) else { return false }
            scheduleCompatibilityDerivedRetry(
                itemID: itemID,
                minimumGeneration: claim.generation,
                nextAttempt: retryAttempt + 1
            )
            return false
        }
        guard head.generation == claim.generation else {
            if fencesPublishedProjectionOnMismatch == false,
                derivedCatalogPersistenceFailures[itemID]?.generation
                == claim.generation {
                derivedCatalogPersistenceFailures.removeValue(forKey: itemID)
            }
            if fencesPublishedProjectionOnMismatch {
                _ = await failCloseCompatibilityDerivedProjection(
                    itemID: itemID,
                    claim: claim,
                    pageCount: head.pages.count
                )
            }
            guard compatibilityDerivedRefreshIsCurrent(
                claim,
                itemID: itemID
            ) else { return false }
            // A higher head is an ordinary successor. A lower head means
            // Canvas Core promoted its previous verified slot after corruption;
            // adopt a new authority epoch so pre-recovery producers stay stale.
            if head.generation > claim.generation {
                advanceCompatibilityDerivedGenerationFloor(
                    itemID: itemID,
                    generation: head.generation
                )
            } else {
                guard reconcileCompatibilityDerivedAuthority(
                    itemID: itemID,
                    loadedGeneration: head.generation,
                    epochBeforeLoad: claim.authorityEpoch
                ) != nil else { return false }
            }
            scheduleCompatibilityDerivedRetry(
                itemID: itemID,
                minimumGeneration: head.generation,
                nextAttempt: retryAttempt + 1
            )
            return false
        }
        return true
    }

    /// Orders the one shared thumbnail filename without serializing extraction
    /// or rendering. The successor waits for the predecessor's physical write,
    /// then rechecks its epoch-stamped claim before enqueueing its own write.
    private func publishCompatibilityPreview(
        _ preview: LibraryPreviewPipeline.PreparedPreview,
        itemID: UUID,
        claim: CompatibilityDerivedRefreshClaim
    ) async -> Int64? {
        guard compatibilityDerivedRefreshIsCurrent(claim, itemID: itemID) else {
            return nil
        }
        let predecessor = compatibilityPreviewPublicationTails[itemID]?.task
        let publicationID = UUID()
        let publication = Task { @MainActor [weak self] () -> Int64? in
            _ = await predecessor?.value
            guard let self,
                self.compatibilityDerivedRefreshIsCurrent(
                    claim,
                    itemID: itemID
                ) else { return nil }
            return try? await LibraryPreviewPipeline.publish(
                preview,
                itemID: itemID,
                assetStore: self.assetStore
            )
        }
        compatibilityPreviewPublicationTails[itemID] = (
            publicationID,
            publication
        )
        let generation = await withTaskCancellationHandler {
            await publication.value
        } onCancel: {
            publication.cancel()
        }
        if compatibilityPreviewPublicationTails[itemID]?.id == publicationID {
            compatibilityPreviewPublicationTails.removeValue(forKey: itemID)
        }
        return generation
    }

    private func refreshCompatibilityDerivedData(
        itemID: UUID,
        minimumGeneration: Int64,
        retryAttempt: Int = 0
    ) async {
        guard isCatalogWritable,
            let initialItem = repository.item(id: itemID),
            initialItem.payloadState == .ready,
            initialItem.isTrashed == false,
            initialItem.kind == .notebook
            || initialItem.kind == .importedDocument else { return }
        let canvasDirectory = assetStore.directories(for: itemID).canvas
        let store = CanvasCoreStore(rootURL: canvasDirectory)
        let authorityEpochBeforeLoad = compatibilityDerivedAuthorityEpoch(
            itemID: itemID
        )
        guard case let .restored(snapshot) = await store.load(),
            isCatalogWritable,
            !Task.isCancelled,
            let currentItem = repository.item(id: itemID),
            currentItem.payloadState == .ready,
            currentItem.isTrashed == false else { return }
        guard let authority = reconcileCompatibilityDerivedAuthority(
            itemID: itemID,
            loadedGeneration: snapshot.generation,
            epochBeforeLoad: authorityEpochBeforeLoad
        ),
        authority.recoveredLowerHead
            || snapshot.generation >= minimumGeneration,
        let refreshClaim = beginCompatibilityDerivedRefresh(
            itemID: itemID,
            generation: snapshot.generation,
            authorityEpoch: authority.epoch
        ) else { return }
        defer {
            finishCompatibilityDerivedRefresh(refreshClaim, itemID: itemID)
        }
        let searchableText = await CanvasDocumentSearchIndexer.searchableText(
            for: snapshot.pages
        )
        guard await compatibilityDerivedHeadIsCurrent(
            store: store,
            claim: refreshClaim,
            itemID: itemID,
            retryAttempt: retryAttempt
        ),
        compatibilityDerivedRefreshIsCurrent(
            refreshClaim,
            itemID: itemID
        ),
        let itemBeforeCommit = repository.item(id: itemID),
        itemBeforeCommit.payloadState == .ready,
        itemBeforeCommit.isTrashed == false else { return }
        let kind = itemBeforeCommit.kind
        // Keep the previous verified thumbnail until a replacement succeeds.
        // Publish search/page metadata before attempting the disposable card
        // preview. A slow or failed thumbnail must never keep saved note text
        // out of the durable catalog retrieval tier.
        let derivedProjectionPersisted: Bool
        do {
            try compatibilityDerivedPayloadCommit(
                repository,
                itemID,
                snapshot.pages.count,
                searchableText
            )
            derivedCatalogPersistenceFailures.removeValue(forKey: itemID)
            compatibilityDerivedRetries.removeValue(forKey: itemID)?.task.cancel()
            derivedProjectionPersisted = true
        } catch {
            // Do not reload and certify repository.searchableText here: that
            // value is the older projection precisely because this write
            // failed. Retries reload the authoritative Canvas snapshot, so diagnostic
            // state retains only its size rather than another full text copy.
            derivedCatalogPersistenceFailures[itemID] =
                DerivedCatalogPersistenceFailure(
                    generation: snapshot.generation,
                    searchableTextUTF8ByteCount: searchableText.utf8.count,
                    errorDescription: error.localizedDescription
                )
            scheduleCompatibilityDerivedRetry(
                itemID: itemID,
                minimumGeneration: snapshot.generation,
                nextAttempt: retryAttempt + 1
            )
            derivedProjectionPersisted = false
        }
        guard await compatibilityDerivedHeadIsCurrent(
            store: store,
            claim: refreshClaim,
            itemID: itemID,
            retryAttempt: retryAttempt,
            fencesPublishedProjectionOnMismatch: true
        ) else { return }
        let preparedPreview = try? await LibraryPreviewPipeline.prepare(
            snapshot: snapshot,
            kind: kind
        )
        #if DEBUG
        await compatibilityDerivedRefreshSuspensionForTesting?(
            snapshot.generation,
            .beforePreviewPublication
        )
        #endif
        guard compatibilityDerivedRefreshIsCurrent(
            refreshClaim,
            itemID: itemID
        ) else { return }

        // Re-read the verified head after all expensive extraction/rendering.
        // If a newer checkpoint landed while this task was suspended, the old
        // bytes never reach the stable thumbnail path. Metadata already
        // published by this producer is fenced too.
        guard await compatibilityDerivedHeadIsCurrent(
            store: store,
            claim: refreshClaim,
            itemID: itemID,
            retryAttempt: retryAttempt,
            fencesPublishedProjectionOnMismatch: true
        ),
        let preparedPreview,
        preparedPreview.generation == snapshot.generation else { return }
        let committedPreviewGeneration = await publishCompatibilityPreview(
            preparedPreview,
            itemID: itemID,
            claim: refreshClaim
        )
        guard compatibilityDerivedRefreshIsCurrent(
            refreshClaim,
            itemID: itemID
        ) else { return }
        if let committedPreviewGeneration {
            // The Canvas file and the thumbnail live in separate atomic stores.
            // Validate the authoritative head again after the write and never
            // certify a preview if a checkpoint won that interval. The normal
            // verified-checkpoint callback (or bounded retry below) rebuilds it.
            guard await compatibilityDerivedHeadIsCurrent(
                store: store,
                claim: refreshClaim,
                itemID: itemID,
                retryAttempt: retryAttempt,
                fencesPublishedProjectionOnMismatch: true
            ) else { return }
            // The card image is disposable, but its catalog generation also
            // certifies the searchable projection after restart. Never advance
            // that fence while SwiftData still contains older text.
            guard derivedProjectionPersisted else { return }
            do {
                try repository.updateDerivedPayload(
                    itemID: itemID,
                    previewGeneration: committedPreviewGeneration
                )
            } catch {
                return
            }
            await librarySession.thumbnailStore.invalidate(itemIDs: [itemID])
        }
    }

    private func scheduleCompatibilityDerivedRetry(
        itemID: UUID,
        minimumGeneration: Int64,
        nextAttempt: Int
    ) {
        guard nextAttempt <= 3, isCatalogWritable else { return }
        compatibilityDerivedRetries.removeValue(forKey: itemID)?.task.cancel()
        let retryID = UUID()
        let delay: Duration
        switch nextAttempt {
        case 1:
            delay = .seconds(5)
        case 2:
            delay = .seconds(15)
        default:
            delay = .seconds(30)
        }
        let task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            guard let self,
                self.isCatalogWritable,
                self.compatibilityDerivedRetries[itemID]?.id == retryID else {
                return
            }
            self.compatibilityDerivedRetries.removeValue(forKey: itemID)
            await self.refreshCompatibilityDerivedData(
                itemID: itemID,
                minimumGeneration: minimumGeneration,
                retryAttempt: nextAttempt
            )
        }
        compatibilityDerivedRetries[itemID] = (retryID, task)
    }

    #if DEBUG
    func refreshCompatibilityDerivedDataForTesting(
        itemID: UUID,
        minimumGeneration: Int64
    ) async {
        await refreshCompatibilityDerivedData(
            itemID: itemID,
            minimumGeneration: minimumGeneration
        )
    }
    #endif

    /// Resolves authored bytes that were durably staged before an earlier
    /// catalog transaction was interrupted. This must run before any Canvas
    /// load, source collection, retention purge, or migration: an unmarked
    /// journal whose records still exist belongs back in `Items`, while a
    /// marker (or the absence of every captured record) proves that its
    /// recovery payload may be discarded.
    private func reconcileAssetTrashTransactions() async -> Bool {
        do {
            let transactions = try await assetStore.pendingRecoveryTransactions()
            for transaction in transactions {
                if transaction.catalogCommitMarked {
                    try await assetStore.discardRecoveryTransaction(transaction)
                    continue
                }
                if transaction.manifest.purpose == .deletedPageRestore {
                    try await reconcileDeletedPageRestoreTransaction(transaction)
                    continue
                }

                let recordPresence = transaction.manifest.catalogAnchors.map {
                    anchor -> Bool in
                    switch anchor.kind {
                    case .item:
                        repository.item(id: anchor.id) != nil
                    case .deletedPage:
                        repository.deletedPages().contains { $0.id == anchor.id }
                    }
                }
                if recordPresence.allSatisfy({ $0 }) {
                    try await assetStore.restoreRecoveryTransaction(transaction)
                } else if recordPresence.allSatisfy({ !$0 }) {
                    try await assetStore.discardRecoveryTransaction(
                        transaction,
                        authority: .catalogRecordsAbsent
                    )
                } else {
                    throw LibraryAssetStoreError.recoveryTransactionConflict(
                        "Catalog records for transaction \(transaction.operationID) are only partly present. Its recovery files were preserved."
                    )
                }
            }
            return true
        } catch {
            enterCatalogFailure("""
            Notate found interrupted library cleanup that it could not reconcile safely, so editing is disabled and every recovery copy was preserved. Quit and reopen Notate, then
            contact support if the problem continues. Details: \(error.localizedDescription)
            """)
            return false
        }
    }

    /// Page restoration spans a Canvas checkpoint and a tombstone save. Its
    /// journal is staged first, so after a crash the verified checkpoint tells
    /// us which side won: a present page completes the tombstone acknowledgement;
    /// an absent page restores the archive and keeps Trash authoritative.
    private func reconcileDeletedPageRestoreTransaction(
        _ transaction: LibraryAssetTrashTransaction
    ) async throws {
        let anchors = transaction.manifest.catalogAnchors
        guard anchors.count == 1,
            anchors[0].kind == .deletedPage else {
            throw LibraryAssetStoreError.invalidRecoveryTransaction(
                transaction.operationID
            )
        }
        let recordID = anchors[0].id
        guard repository.deletedPages().contains(where: { $0.id == recordID }) else {
            try await assetStore.discardRecoveryTransaction(
                transaction,
                authority: .catalogRecordsAbsent
            )
            return
        }

        let asset = try repository.deletedPageAsset(id: recordID)
        let store = CanvasCoreStore(
            rootURL: assetStore.directories(for: asset.ownerItemID).canvas
        )
        switch await store.load() {
        case let .restored(snapshot):
            guard snapshot.pages.contains(where: { $0.id == asset.pageID }) else {
                try await assetStore.restoreRecoveryTransaction(transaction)
                return
            }
            try deletedPageAcknowledgement(repository, recordID)
            _ = await finishCommittedRecoveryTransaction(transaction)
            await refreshCompatibilityDerivedData(
                itemID: asset.ownerItemID,
                minimumGeneration: snapshot.generation
            )
        case .newDocument:
            try await assetStore.restoreRecoveryTransaction(transaction)
        case let .failed(error):
            throw error
        }
    }

    private func blockLibraryForRecoveryFailure(_ error: Error) {
        enterCatalogFailure("""
        Notate could not finish an authored-file recovery transaction safely, so editing is disabled and every remaining recovery copy was preserved. Quit and reopen Notate, then
        contact support if the problem continues. Details: \(error.localizedDescription)
        """)
    }

    private func enterCatalogFailure(_ message: String) {
        catalogFailureDescription = message
        activeEditor = nil
        activeAttachment = nil
        pendingPayloadOpenItemID = nil
        importParentID = nil
        isImportChoicePresented = false
        isFileImporterPresented = false
        isPhotoPickerPresented = false
        selectedPhotos = []
    }

    /// Once the catalog save succeeds, recovery must never run backward. A
    /// marker or discard failure is left as a retryable startup journal and is
    /// reported as pending cleanup rather than as a failed deletion.
    @discardableResult
    private func finishCommittedRecoveryTransaction(
        _ transaction: LibraryAssetTrashTransaction
    ) async -> Bool {
        do {
            let marked = try await assetStore.markCatalogCommitted(transaction)
            try await assetStore.discardRecoveryTransaction(marked)
            return true
        } catch {
            startupNotice = "Library changes were saved, but protected cleanup is pending and will retry the next time Notate opens. \(error.localizedDescription)."
            return false
        }
    }

    /// Removes catalog work left unpublished by an interrupted create, import,
    /// or recursive duplicate. Item directories move to same-volume recovery
    /// storage before the single SwiftData commit and are restored if that
    /// commit rejects the captured plan.
    private func reconcileIncompletePayloads() async {
        let plan = repository.makeIncompletePayloadReconciliationPlan()
        guard plan.isEmpty == false else { return }

        let transaction: LibraryAssetTrashTransaction
        do {
            transaction = try await assetStore.stageRecoveryTransaction(
                purpose: .incompletePayloadCleanup,
                catalogAnchors: plan.itemIDs.map {
                    LibraryAssetTrashManifest.CatalogAnchor(kind: .item, id: $0)
                },
                intents: plan.itemIDs.map {
                    .itemRoot(itemID: $0, isRequired: false)
                }
            )
        } catch {
            blockLibraryForRecoveryFailure(error)
            return
        }

        do {
            _ = try repository.commitIncompletePayloadReconciliation(plan)
        } catch {
            do {
                try await assetStore.restoreRecoveryTransaction(transaction)
            } catch {
                blockLibraryForRecoveryFailure(error)
                return
            }
            startupNotice = "Notate could not finish recovering interrupted library work. \(error.localizedDescription)"
            return
        }
        await finishCommittedRecoveryTransaction(transaction)
    }

    private func purgeExpiredTrash() async {
        do {
            let plan = repository.makePurgePlan()
            guard plan.isEmpty == false else { return }
            try await commitDeletionPlan(plan)
        } catch {
            startupNotice = error.localizedDescription
        }
    }

    /// Stages every filesystem mutation in recoverable storage before the
    /// SwiftData transaction commits. A catalog save failure therefore puts
    /// the original item/page assets back instead of producing a partial
    /// permanent deletion.

    private func commitDeletionPlan(_ plan: LibraryPurgePlan) async throws {
        // If this deletion cancels the sole outgoing editor handoff, resume a
        // still-valid latest open only after the entire deletion transaction
        // has committed or rolled back. Opening during the transaction could
        // race the authored-file recovery boundary.
        defer { schedulePendingPayloadOpenResume() }
        let wholeItemIDs = Set(plan.itemIDs)
        let survivingPageAssets = plan.deletedPageAssets.filter {
            wholeItemIDs.contains($0.ownerItemID) == false
        }
        let survivingPageAssetsByOwner = Dictionary(
            grouping: survivingPageAssets,
            by: \.ownerItemID
        )
        let affectedItemIDs = wholeItemIDs.union(survivingPageAssetsByOwner.keys)

        // Stop disposable producers before clearing their durable output.
        // The coordinator guards in the refresh path prevent a cancelled task
        // from recreating a deleted item directory.
        var producerTasks: [Task<Void, Never>] = []
        var previewPublicationTasks: [Task<Int64?, Never>] = []
        for itemID in affectedItemIDs {
            if let task = derivedRefreshes.removeValue(forKey: itemID)?.task {
                task.cancel()
                producerTasks.append(task)
            }
            if let task = compatibilityDerivedRetries
                .removeValue(forKey: itemID)?.task {
                task.cancel()
                producerTasks.append(task)
            }
            compatibilityDerivedRefreshClaims.removeValue(forKey: itemID)
            compatibilityDerivedGenerationFloors.removeValue(forKey: itemID)
            compatibilityDerivedAuthorityEpochs.removeValue(forKey: itemID)
            if let publication = compatibilityPreviewPublicationTails
                .removeValue(forKey: itemID) {
                publication.task.cancel()
                previewPublicationTasks.append(publication.task)
            }
            derivedCatalogPersistenceFailures.removeValue(forKey: itemID)
            if let task = closeHandoffs.removeValue(forKey: itemID)?.task {
                task.cancel()
                producerTasks.append(task)
            }
        }
        for task in producerTasks {
            _ = await task.result
        }
        for task in previewPublicationTasks {
            _ = await task.result
        }

        // A page tombstone can outlive the debounce that refreshes the owner's
        // catalog projection. Rebuild from the verified page-deleted snapshot
        // before discarding the only recovery archive, including for trashed
        // owners that may later be restored.
        var survivingOwnerItemIDs = Set<UUID>()
        survivingOwnerItemIDs.reserveCapacity(survivingPageAssetsByOwner.count)
        for (ownerItemID, pageAssets) in survivingPageAssetsByOwner {
            let store = CanvasCoreStore(
                rootURL: assetStore.directories(for: ownerItemID).canvas
            )
            let restoredSnapshot: CanvasCoreSnapshot
            switch await store.load() {
            case let .restored(restored):
                restoredSnapshot = restored
            case .newDocument:
                throw CanvasCoreStoreError.verificationFailed(
                    "A verified checkpoint is required before permanently deleting a page."
                )
            case let .failed(error):
                throw error
            }
            let deletedPageIDs = Set(pageAssets.map(\.pageID))
            guard deletedPageIDs.isDisjoint(with: restoredSnapshot.pages.map(\.id)) else {
                throw CanvasCoreStoreError.verificationFailed(
                    "A page selected for permanent deletion is still present in the committed note."
                )
            }
            let (nextGeneration, overflow) = restoredSnapshot.generation
                .addingReportingOverflow(1)
            guard overflow == false else {
                throw CanvasCoreStoreError.verificationFailed(
                    "The note generation cannot advance for permanent page deletion."
                )
            }
            // Rotate a second verified page-deleted snapshot into both durable
            // recovery slots. Otherwise a corrupt current file could promote a
            // pre-deletion `previous.canvas` after the archive is discarded.
            let snapshot = CanvasCoreSnapshot(
                generation: nextGeneration,
                pages: restoredSnapshot.pages,
                currentPageID: restoredSnapshot.currentPageID
            )
            try await store.checkpoint(snapshot)
            let searchableText = await CanvasDocumentSearchIndexer.searchableText(
                for: snapshot.pages
            )
            try repository.reconcileDerivedPayloadAfterPageDeletion(
                itemID: ownerItemID,
                pageCount: snapshot.pages.count,
                searchableText: searchableText,
                verifiedGeneration: snapshot.generation
            )
            // The verified checkpoint is now durable. Keep only its owner ID;
            // retaining every decoded PaperMarkup snapshot until a bulk purge
            // commits can otherwise multiply the per-document 256 MiB markup
            // ceiling by thousands of deleted-page owners.
            survivingOwnerItemIDs.insert(ownerItemID)
        }

        // Once an archive moves to recovery storage it is invisible to the
        // Canvas mark phase. Hold its imported-source reference through the
        // catalog commit/rollback decision so a concurrent checkpoint sweep
        // cannot break the recovery copy.
        var sourceReservations: [(
            canvasDirectory: URL,
            reservation: CanvasCoreSourceReservation
        )] = []
        for pageAsset in survivingPageAssets {
            guard survivingOwnerItemIDs.contains(pageAsset.ownerItemID) else {
                continue
            }
            let directories = assetStore.directories(for: pageAsset.ownerItemID)
            let store = CanvasCoreStore(rootURL: directories.canvas)
            let archiveURL = directories.itemRoot
                .appendingPathComponent(pageAsset.payloadRelativePath)
            let reservation = await store.reserveImportedSources(
                whileDeletingPageArchiveAt: archiveURL
            )
            sourceReservations.append((directories.canvas, reservation))
        }

        var recoveryTransaction: LibraryAssetTrashTransaction?
        do {
            await librarySession.thumbnailStore.invalidate(itemIDs: affectedItemIDs)

            let anchors = plan.itemIDs.map {
                LibraryAssetTrashManifest.CatalogAnchor(kind: .item, id: $0)
            } + plan.deletedPageAssets.map {
                LibraryAssetTrashManifest.CatalogAnchor(
                    kind: .deletedPage,
                    id: $0.recordID
                )
            }
            let intents = plan.itemIDs.map {
                LibraryAssetRecoveryIntent.itemRoot(
                    itemID: $0,
                    isRequired: false
                )
            } + survivingPageAssets.map {
                LibraryAssetRecoveryIntent.itemAsset(
                    itemID: $0.ownerItemID,
                    relativePath: $0.payloadRelativePath,
                    isRequired: true
                )
            } + survivingPageAssetsByOwner.keys.map {
                LibraryAssetRecoveryIntent.itemAsset(
                    itemID: $0,
                    relativePath: "Thumbnails/library.png",
                    isRequired: false
                )
            }
            let staged = try await assetStore.stageRecoveryTransaction(
                purpose: .permanentDeletion,
                catalogAnchors: anchors,
                intents: intents
            )
            recoveryTransaction = staged
            _ = try repository.commitPurge(plan)
        } catch {
            let transactionError = error
            if let recoveryTransaction {
                do {
                    try await assetStore.restoreRecoveryTransaction(recoveryTransaction)
                } catch {
                    for held in sourceReservations {
                        await CanvasCoreStore(rootURL: held.canvasDirectory)
                            .releaseImportedSourceReservation(held.reservation)
                    }
                    blockLibraryForRecoveryFailure(error)
                    throw error
                }
            } else if await reconcileAssetTrashTransactions() == false {
                for held in sourceReservations {
                    await CanvasCoreStore(rootURL: held.canvasDirectory)
                        .releaseImportedSourceReservation(held.reservation)
                }
                throw transactionError
            }
            for held in sourceReservations {
                await CanvasCoreStore(rootURL: held.canvasDirectory)
                    .releaseImportedSourceReservation(held.reservation)
            }
            throw transactionError
        }

        if let recoveryTransaction {
            await finishCommittedRecoveryTransaction(recoveryTransaction)
        }
        for held in sourceReservations {
            await CanvasCoreStore(rootURL: held.canvasDirectory)
                .releaseImportedSourceReservation(held.reservation)
        }
        for itemID in survivingOwnerItemIDs {
            _ = await CanvasCoreStore(
                rootURL: assetStore.directories(for: itemID).canvas
            ).reclaimOrphanedImportedSources()
        }
    }

    private func removeLegacyCanvasItems() async {
        let plan = repository.makeLegacyCanvasRemovalPlan()
        guard plan.isEmpty == false else { return }
        var recoveryTransaction: LibraryAssetTrashTransaction?
        do {
            let staged = try await assetStore.stageRecoveryTransaction(
                purpose: .legacyCanvasRemoval,
                catalogAnchors: plan.itemIDs.map {
                    LibraryAssetTrashManifest.CatalogAnchor(kind: .item, id: $0)
                } + plan.deletedPageAssets.map {
                    LibraryAssetTrashManifest.CatalogAnchor(
                        kind: .deletedPage,
                        id: $0.recordID
                    )
                },
                intents: plan.itemIDs.map {
                    .itemRoot(itemID: $0, isRequired: false)
                }
            )
            recoveryTransaction = staged
            let result = try repository.commitLegacyCanvasRemoval(plan)
            let cleanupCompleted = await finishCommittedRecoveryTransaction(staged)
            if cleanupCompleted {
                startupNotice = result.itemIDs.count == 1
                    ? "1 legacy Canvas was removed as part of the Notes upgrade."
                    : "\(result.itemIDs.count) legacy Canvases were removed as part of the Notes upgrade."
            }
        } catch {
            let transactionError = error
            if let recoveryTransaction {
                do {
                    try await assetStore.restoreRecoveryTransaction(recoveryTransaction)
                } catch {
                    blockLibraryForRecoveryFailure(error)
                    return
                }
            } else if await reconcileAssetTrashTransactions() == false {
                return
            }
            startupNotice = "Notate could not finish removing legacy Canvases. It will retry next time. \(transactionError.localizedDescription)"
        }
    }

    private func migrateLegacyCanvasIfNeeded() async {
        guard let migrationCoordinator else { return }
        do {
            var status = try await migrationCoordinator.inspect()
            // A deferred marker describes the last launch attempt, not a
            // permanent opt-out. The legacy source is intentionally retained,
            // so a later launch can succeed after a transient I/O or decode
            // failure without requiring an otherwise unreachable UI action.
            if case .deferred = status {
                try await migrationCoordinator.resetMarker()
                status = try await migrationCoordinator.inspect()
            }
            let candidate: LegacyCanvasMigrationCandidate
            let itemID: UUID
            switch status {
            case let .pending(pendingCandidate):
                candidate = pendingCandidate
                itemID = UUID()
                try await migrationCoordinator.markInProgress(itemID: itemID)
            case let .inProgress(existingItemID, _):
                itemID = existingItemID
                let legacyDirectory = migrationCoordinator.legacyDirectory
                let current = legacyDirectory.appendingPathComponent("current.canvas")
                guard FileManager.default.fileExists(atPath: current.path) else {
                    try await migrationCoordinator.markDeferred(
                        reason: "The previous canvas source is no longer available."
                    )
                    return
                }
                let previous = legacyDirectory.appendingPathComponent("previous.canvas")
                let preferences = legacyDirectory.appendingPathComponent("preferences.json")
                candidate = LegacyCanvasMigrationCandidate(
                    legacyDirectory: legacyDirectory,
                    currentCanvasURL: current,
                    previousCanvasURL: FileManager.default.fileExists(atPath: previous.path) ? previous : nil,
                    preferencesURL: FileManager.default.fileExists(atPath: preferences.path) ? preferences : nil
                )

                if repository.item(id: itemID) != nil {
                    let migratedStore = CanvasCoreStore(
                        rootURL: assetStore.directories(for: itemID).canvas
                    )
                    if case .restored = await migratedStore.load() {
                        try await migrationCoordinator.markCompleted(itemID: itemID)
                        return
                    }
                    await discardFailedItem(itemID)
                }
            case .notNeeded, .completed, .deferred:
                return
            }
            let legacyStore = CanvasCoreStore(rootURL: candidate.legacyDirectory)
            guard case let .restored(snapshot) = await legacyStore.load() else {
                try await migrationCoordinator.markDeferred(
                    reason: "The previous canvas could not be verified."
                )
                return
            }

            let item = try repository.createItem(
                id: itemID,
                kind: .notebook,
                name: "Untitled notebook",
                payloadState: .creating,
                pageCount: snapshot.pages.count
            )
            do {
                _ = try await assetStore.prepareItem(id: item.id)
                _ = try await assetStore.copyFile(
                    from: candidate.currentCanvasURL,
                    inside: candidate.legacyDirectory,
                    named: "current.canvas",
                    category: .canvas,
                    for: item.id,
                    maximumByteCount: CanvasCoreResourceLimits.production
                        .maximumCheckpointEncodedByteCount
                )
                if let previousURL = candidate.previousCanvasURL {
                    _ = try await assetStore.copyFile(
                        from: previousURL,
                        inside: candidate.legacyDirectory,
                        named: "previous.canvas",
                        category: .canvas,
                        for: item.id,
                        maximumByteCount: CanvasCoreResourceLimits.production
                            .maximumCheckpointEncodedByteCount
                    )
                }
                if let preferencesURL = candidate.preferencesURL {
                    _ = try await assetStore.copyFile(
                        from: preferencesURL,
                        inside: candidate.legacyDirectory,
                        named: "preferences.json",
                        category: .canvas,
                        for: item.id,
                        maximumByteCount: LibraryAssetReadLimits
                            .legacyMigrationMetadataByteCount
                    )
                }

                let migratedStore = CanvasCoreStore(
                    rootURL: assetStore.directories(for: item.id).canvas
                )
                guard case .restored = await migratedStore.load() else {
                    throw CanvasCoreStoreError.verificationFailed(
                        "The copied legacy notebook did not reopen."
                    )
                }
                try repository.updatePayload(
                    itemID: item.id,
                    state: .ready,
                    pageCount: snapshot.pages.count
                )
                try await migrationCoordinator.markCompleted(itemID: item.id)
            } catch {
                await discardFailedItem(item.id)
                try await migrationCoordinator.markDeferred(reason: error.localizedDescription)
            }
        } catch {
            startupNotice = "Your previous canvas is still safe, but Notate could not migrate it yet. \(error.localizedDescription)"
        }
    }

    private func perform(_ work: () throws -> Void) {
        guard isCatalogWritable else { return }
        do {
            try work()
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    private func displayName(for filename: String) -> String {
        let base = URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent
        return base.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "Imported file"
            : base
    }

    private func safeFilename(_ filename: String) -> String {
        let lastComponent = URL(fileURLWithPath: filename).lastPathComponent
        return lastComponent.isEmpty ? "Imported file" : lastComponent
    }
    }

private enum NotateImportSource {
    case files
    case photos
}

private struct NotateImportSourceSheet: View {
    let onSelect: (NotateImportSource) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    sourceButton(
                        title: "Choose Files",
                        detail: "Import PDFs, images, and other documents from Files.",
                        systemImage: "folder",
                        source: .files,
                        identifier: "import.choice.files"
                    )

                    sourceButton(
                        title: "Choose Photos",
                        detail: "Add up to 20 images from your photo library.",
                        systemImage: "photo.on.rectangle",
                        source: .photos,
                        identifier: "import.choice.photos"
                    )
                } footer: {
                    Text("PDFs and images become annotatable. Other files open with Quick Look.")
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Files & Photos")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { dismiss() }
                        .accessibilityIdentifier("import.choice.cancel")
                }
            }
        }
        .presentationSizing(.form)
    }

    private func sourceButton(
        title: String,
        detail: String,
        systemImage: String,
        source: NotateImportSource,
        identifier: String
    ) -> some View {
        Button {
            onSelect(source)
            dismiss()
        } label: {
            Label {
                VStack(alignment: .leading, spacing: NotateDesign.Spacing.tight) {
                    Text(title)
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.primary)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                } icon: {
                    Image(systemName: systemImage)
                        .font(.title3)
                        .foregroundStyle(NotateDesign.Palette.accent)
                        .frame(width: 30)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityHint(detail)
            .accessibilityIdentifier(identifier)
        }
    }

struct NotateRootView: View {
    @Bindable var application: NotateApplicationCoordinator
    @Namespace private var editorTransitionNamespace
    @State private var editorNavigationPath: [NotateAppRoute] = []
    @State private var pendingImportSource: NotateImportSource?

    var body: some View {
        Group {
            if let catalogFailureDescription = application.catalogFailureDescription {
                NotateCatalogUnavailableView(message: catalogFailureDescription)
            } else if application.isLibraryRecoveryComplete == false {
                NotateLibraryRecoveryView()
            } else {
                NavigationStack(path: $editorNavigationPath) {
                    LibraryShellView(
                        session: application.librarySession,
                        itemTransitionNamespace: editorTransitionNamespace
                    )
                    .navigationDestination(for: NotateAppRoute.self) { route in
                        editorDestination(for: route)
                    }
                }
            }
        }
        .onChange(of: application.route, initial: true) { _, route in
            synchronizeEditorNavigation(with: route)
        }
        .onChange(of: application.librarySession.scope) { _, scope in
            application.synchronizeRoute(with: scope)
        }
        .task { await application.start() }
        .sheet(
            isPresented: $application.isImportChoicePresented,
            onDismiss: presentPendingImportSource
        ) {
            NotateImportSourceSheet { source in
                pendingImportSource = source
            }
        }
        .fileImporter(
            isPresented: $application.isFileImporterPresented,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true,
            onCompletion: application.handleFileImporter
        )
        .photosPicker(
            isPresented: $application.isPhotoPickerPresented,
            selection: $application.selectedPhotos,
            maxSelectionCount: 20,
            matching: .images,
            preferredItemEncoding: .current
        )
        .onChange(of: application.selectedPhotos) { _, _ in
            application.handleSelectedPhotos()
        }
        .alert(
            "Notate Couldn't Complete That",
            isPresented: Binding(
                get: { application.alertMessage != nil || application.startupNotice != nil },
                set: { presented in
                    if presented == false {
                        application.alertMessage = nil
                        application.startupNotice = nil
                    }
                }
            )
        ) {
            Button("OK", role: .cancel) {
                application.alertMessage = nil
                application.startupNotice = nil
            }
        } message: {
            Text(application.alertMessage ?? application.startupNotice ?? "Please try again.")
        }
        .modelContainer(application.modelContainer)
    }

    private func presentPendingImportSource() {
        guard application.catalogFailureDescription == nil,
            application.isLibraryRecoveryComplete,
            let pendingImportSource else {
            self.pendingImportSource = nil
            return
        }

        self.pendingImportSource = nil
        switch pendingImportSource {
        case .files:
            application.isFileImporterPresented = true
        case .photos:
            application.isPhotoPickerPresented = true
        }
    }

    @ViewBuilder
    private func editorDestination(for route: NotateAppRoute) -> some View {
        switch route {
        case let .notebook(itemID), let .document(itemID):
            if let editor = application.activeEditor, editor.itemID == itemID {
                NotateCanvasEditorDestination(
                    editor: editor,
                    transitionNamespace: editorTransitionNamespace,
                    onClose: { beforeNavigation in
                        closeEditor(
                            route,
                            beforeNavigation: beforeNavigation
                        )
                    },
                    onRename: { name in
                        try application.renameEditorItem(id: editor.itemID, to: name)
                    },
                    onVerifiedCheckpoint: {
                        await application.refreshDerivedLibraryData(
                            itemID: editor.itemID,
                            model: editor.model
                        )
                    },
                    onDidDisappear: {
                        finishClosing(route, itemID: editor.itemID)
                    }
                )
            } else {
                missingDestination(for: route)
            }
        case let .attachment(itemID):
            if let attachment = application.activeAttachment,
                attachment.itemID == itemID {
                NotateAttachmentDestination(
                    attachment: attachment,
                    transitionNamespace: editorTransitionNamespace,
                    onClose: {
                        closeEditor(route)
                    },
                    onDidDisappear: {
                        finishClosing(route, itemID: attachment.itemID)
                    }
                )
            } else {
                missingDestination(for: route)
            }
        case .home, .folder, .favorites, .recent, .tag, .trash, .settings:
            missingDestination(for: route)
        }
    }
    private func synchronizeEditorNavigation(with route: NotateAppRoute) {
        guard route.editorItemID != nil else {
            if editorNavigationPath.isEmpty == false {
                editorNavigationPath.removeAll()
            }
            return
        }
        guard editorNavigationPath.last != route else { return }
        editorNavigationPath = [route]
    }

    private func closeEditor(
        _ route: NotateAppRoute,
        beforeNavigation: @escaping @MainActor () -> Void = {}
    ) {
        guard editorNavigationPath.last == route else { return }
        application.closeActiveItem(beforeNavigation: beforeNavigation)
    }

    private func finishClosing(_ route: NotateAppRoute, itemID: UUID) {
        guard editorNavigationPath.contains(route) == false else { return }
        let activeItemID = application.activeEditor?.itemID
            ?? application.activeAttachment?.itemID
        guard activeItemID == itemID else { return }
        application.closeActiveItem()
    }

    private func missingDestination(for route: NotateAppRoute) -> some View {
        ContentUnavailableView(
            "This item is unavailable",
            systemImage: "doc.questionmark",
            description: Text("Return to the library and try opening it again.")
        )
        .task {
            guard editorNavigationPath.contains(route) else { return }
            editorNavigationPath.removeAll { $0 == route }
            application.closeActiveItem()
        }
    }
}

private struct NotateLibraryRecoveryView: View {
    var body: some View {
        ContentUnavailableView {
            ProgressView("Recovering Your Library")
        } description: {
            Text("Notate is safely finishing interrupted file changes before editing is enabled.")
        }
        .accessibilityIdentifier("library-recovery-in-progress")
        .padding(32)
    }
}

private struct NotateCatalogUnavailableView: View {
    let message: String

    var body: some View {
        ContentUnavailableView {
            Label("Library Unavailable", systemImage: "externaldrive.badge.exclamationmark")
        } description: {
            Text(message)
                .textSelection(.enabled)
        }
        .accessibilityIdentifier("catalog-unavailable")
        .padding(32)
    }
}

private extension NotateAppRoute {
    var editorItemID: UUID? {
        switch self {
        case let .notebook(id), let .document(id), let .attachment(id):
            id
        case .home, .folder, .favorites, .recent, .tag, .trash, .settings:
            nil
        }
    }
}

private struct NotateCanvasEditorDestination: View {
    let editor: NotateApplicationCoordinator.ActiveEditor
    let transitionNamespace: Namespace.ID
    let onClose: @MainActor (
        _ beforeNavigation: @escaping @MainActor () -> Void
    ) -> Void
    let onRename: @MainActor (String) throws -> Void
    let onVerifiedCheckpoint: @MainActor () async -> Void
    let onDidDisappear: @MainActor () -> Void
    @State private var navigationPolicy = NotateBackButtonOnlyNavigationGuard.Policy()

    var body: some View {
        CanvasEditorView(
            model: editor.model,
            item: editor.item,
            onRename: onRename,
            onClose: close,
            onVerifiedCheckpoint: onVerifiedCheckpoint,
            flushesOnDisappear: false
        )
        // The canvas owns full-screen drawing and zoom gestures. Requiring the
        // explicit back button avoids an accidental navigation pop while a
        // document is being edited. The navigation policy restores SwiftUI's
        // original transition before this button performs the pop, preserving
        // the native reverse zoom.
        .navigationBarBackButtonHidden(true)
        .background {
            NotateBackButtonOnlyNavigationGuard(policy: navigationPolicy)
                .allowsHitTesting(false)
        }
        .toolbar(.hidden, for: .navigationBar)
        .onDisappear(perform: onDidDisappear)
        .notateEditorNavigationTransition(
            itemID: editor.itemID,
            in: transitionNamespace
        )
    }

    private func close() {
        onClose {
            navigationPolicy.prepareForProgrammaticClose()
        }
    }
}

/// SwiftUI's zoom transition owns edge, content-swipe, and pinch dismissal
/// interactions that are separate from a navigation controller's ordinary pop
/// gestures. While the editor is visible, replace only its preferred transition
/// with the public UIKit zoom policy that rejects interactive dismissal. The
/// exact SwiftUI transition is restored synchronously before an explicit Back
/// action, preserving its matched zoom and source view.
@MainActor
private struct NotateBackButtonOnlyNavigationGuard: UIViewControllerRepresentable {
    let policy: Policy

    func makeUIViewController(context: Context) -> Controller {
        Controller(policy: policy)
    }

    func updateUIViewController(_ controller: Controller, context: Context) {
        controller.refresh()
    }

    static func dismantleUIViewController(_ controller: Controller, coordinator: ()) {
        controller.deactivate()
    }

    @MainActor
    final class Policy {
        fileprivate weak var controller: Controller?

        fileprivate func attach(_ controller: Controller) {
            guard self.controller !== controller else { return }
            self.controller?.deactivate()
            self.controller = controller
        }

        func prepareForProgrammaticClose() {
            controller?.prepareForProgrammaticClose()
        }
    }

    final class Controller: UIViewController {
        private weak var policy: Policy?
        private var isVisible = false
        private var isActive = true
        private var isProgrammaticClosePrepared = false
        private weak var installedNavigationController: UINavigationController?
        private weak var installedDestinationController: UIViewController?
        private var originalPreferredTransition: UIViewController.Transition?
        private var blockingTransition: UIViewController.Transition?

        init(policy: Policy) {
            self.policy = policy
            super.init(nibName: nil, bundle: nil)
            policy.attach(self)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            return nil
        }

        override func loadView() {
            let view = UIView(frame: .zero)
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.accessibilityElementsHidden = true
            self.view = view
        }

        override func viewDidAppear(_ animated: Bool) {
            super.viewDidAppear(animated)
            isVisible = true
            installIfPossible()
        }

        override func viewDidLayoutSubviews() {
            super.viewDidLayoutSubviews()
            installIfPossible()
        }

        override func viewDidDisappear(_ animated: Bool) {
            super.viewDidDisappear(animated)
            isVisible = false
            restorePreferredTransition()
        }

        func refresh() {
            installIfPossible()
        }

        func deactivate() {
            isActive = false
            isVisible = false
            restorePreferredTransition()
            if policy?.controller === self {
                policy?.controller = nil
            }
        }

        func prepareForProgrammaticClose() {
            isProgrammaticClosePrepared = true
            restorePreferredTransition()
        }

        private func installIfPossible() {
            guard isActive,
                isVisible,
                isProgrammaticClosePrepared == false,
                let navigationController = enclosingNavigationController else {
                return
            }
            guard let destinationController = owningDestinationController(
                in: navigationController
            ), navigationController.topViewController == destinationController else {
                restorePreferredTransition()
                return
            }

            if installedNavigationController != navigationController
                || installedDestinationController != destinationController {
                restorePreferredTransition()
                installedNavigationController = navigationController
                installedDestinationController = destinationController
                originalPreferredTransition = destinationController.preferredTransition
            } else if destinationController.preferredTransition != blockingTransition {
                // SwiftUI can refresh its source-provider transition as the
                // library layout changes behind the editor. Preserve the most
                // recent one for the button-driven reverse animation.
                originalPreferredTransition = destinationController.preferredTransition
            }

            if blockingTransition == nil {
                let options = UIViewController.Transition.ZoomOptions()
                options.interactiveDismissShouldBegin = { _ in false }
                blockingTransition = .zoom(
                    options: options,
                    sourceViewProvider: { _ in nil }
                )
            }

            if destinationController.preferredTransition != blockingTransition {
                destinationController.preferredTransition = blockingTransition
            }
        }

        private var enclosingNavigationController: UINavigationController? {
            if let navigationController { return navigationController }

            var ancestor = parent
            while let current = ancestor {
                if let navigationController = current as? UINavigationController {
                    return navigationController
                }
                if let navigationController = current.navigationController {
                    return navigationController
                }
                ancestor = current.parent
            }
            return nil
        }

        private func owningDestinationController(
            in navigationController: UINavigationController
        ) -> UIViewController? {
            var candidate: UIViewController? = self
            while let current = candidate {
                if current.parent == navigationController {
                    return current
                }
                candidate = current.parent
            }
            return nil
        }

        private func restorePreferredTransition() {
            if let installedDestinationController,
                installedDestinationController.preferredTransition == blockingTransition {
                installedDestinationController.preferredTransition = originalPreferredTransition
            }
            installedDestinationController = nil
            installedNavigationController = nil
            originalPreferredTransition = nil
            blockingTransition = nil
        }
    }
    }

private struct NotateAttachmentDestination: View {
    let attachment: NotateApplicationCoordinator.ActiveAttachment
    let transitionNamespace: Namespace.ID
    let onClose: @MainActor () -> Void
    let onDidDisappear: @MainActor () -> Void

    var body: some View {
        NotateAttachmentView(
            attachment: attachment,
            onClose: onClose
        )
        .onDisappear(perform: onDidDisappear)
        .notateEditorNavigationTransition(
            itemID: attachment.itemID,
            in: transitionNamespace
        )
    }
}

private struct NotateAttachmentView: View {
    let attachment: NotateApplicationCoordinator.ActiveAttachment
    let onClose: @MainActor () -> Void

    var body: some View {
        QuickLookPreview(url: attachment.url)
            .ignoresSafeArea(edges: .bottom)
            .navigationTitle(attachment.title)
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(true)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Library", systemImage: "chevron.backward", action: onClose)
                }
            }
    }
}

private struct QuickLookPreview: UIViewControllerRepresentable {
    let url: URL

    func makeCoordinator() -> Coordinator { Coordinator(url: url) }

    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController()
        controller.dataSource = context.coordinator
        return controller
    }

    func updateUIViewController(_ controller: QLPreviewController, context: Context) {
        guard context.coordinator.url != url else { return }
        context.coordinator.url = url
        controller.reloadData()
    }

    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        var url: URL

        init(url: URL) { self.url = url }

        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

        func previewController(
            _ controller: QLPreviewController,
            previewItemAt index: Int
        ) -> any QLPreviewItem {
            url as NSURL
        }
    }
}
