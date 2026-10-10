import CryptoKit
import CoreGraphics
import Foundation
import PaperKit

/// Metadata sent to the paged editor. Markup and tables are resolved only
/// when the page is visible or otherwise explicitly pinned by a consumer.
public nonisolated struct CanvasPageDescriptor: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let contentRevision: UInt64
    public let viewport: CanvasViewportState
    public let paperTemplate: CanvasPaperTemplate
    public let geometry: CanvasPageGeometry
    public let background: CanvasPageBackgroundReference
    /// A verified immutable content revision to share when adding a duplicate
    /// page. This is a commit hint; committed catalog entries store the
    /// resolved checksum and do not need to retain the hint.
    public let sharedPayloadReference: CanvasPageRevisionReference?

    public init(
        id: UUID,
        contentRevision: UInt64,
        viewport: CanvasViewportState,
        paperTemplate: CanvasPaperTemplate,
        geometry: CanvasPageGeometry,
        background: CanvasPageBackgroundReference = .paper,
        sharedPayloadReference: CanvasPageRevisionReference? = nil
    ) {
        self.id = id
        self.contentRevision = contentRevision
        self.viewport = viewport
        self.paperTemplate = paperTemplate
        self.geometry = geometry
        self.background = background
        self.sharedPayloadReference = sharedPayloadReference
    }

    public init(page: CanvasPageSnapshot, contentRevision: UInt64) throws {
        self.init(
            id: page.id,
            contentRevision: contentRevision,
            viewport: page.viewport,
            paperTemplate: page.paperTemplate,
            geometry: page.geometry,
            background: try CanvasPageBackgroundReference(page.background)
        )
    }
}

/// Persistent, lightweight description of a notebook generation.
public nonisolated struct CanvasPageCatalog: Codable, Equatable, Sendable {
    public let generation: Int64
    public let currentPageID: UUID
    public let pages: [CanvasPageCatalogEntry]
    private let pageIndexByID: [UUID: Int]

    private enum CodingKeys: String, CodingKey {
        case generation
        case currentPageID
        case pages
    }

    public init(generation: Int64, currentPageID: UUID, pages: [CanvasPageCatalogEntry]) {
        self.generation = generation
        self.currentPageID = currentPageID
        self.pages = pages
        var indexByID: [UUID: Int] = [:]
        indexByID.reserveCapacity(pages.count)
        for (index, page) in pages.enumerated() where indexByID[page.id] == nil {
            indexByID[page.id] = index
        }
        pageIndexByID = indexByID
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            generation: try container.decode(Int64.self, forKey: .generation),
            currentPageID: try container.decode(UUID.self, forKey: .currentPageID),
            pages: try container.decode([CanvasPageCatalogEntry].self, forKey: .pages)
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(generation, forKey: .generation)
        try container.encode(currentPageID, forKey: .currentPageID)
        try container.encode(pages, forKey: .pages)
    }

    public var pageIDs: [UUID] { pages.map(\.id) }

    public func page(id: UUID) -> CanvasPageCatalogEntry? {
        guard let index = pageIndexByID[id], pages.indices.contains(index) else { return nil }
        return pages[index]
    }

    public func pageIndex(for id: UUID) -> Int? {
        guard let index = pageIndexByID[id], pages.indices.contains(index) else { return nil }
        return index
    }

    public func reference(for pageID: UUID) -> CanvasPageRevisionReference? {
        guard let page = page(id: pageID) else { return nil }
        return CanvasPageRevisionReference(
            catalogGeneration: generation,
            pageID: page.id,
            contentRevision: page.contentRevision,
            payloadChecksum: page.payloadChecksum
        )
    }

    public static func == (lhs: CanvasPageCatalog, rhs: CanvasPageCatalog) -> Bool {
        lhs.generation == rhs.generation
            && lhs.currentPageID == rhs.currentPageID
            && lhs.pages == rhs.pages
    }
}

public nonisolated struct CanvasPageCatalogEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let order: Int
    public let contentRevision: UInt64
    public let payloadChecksum: String
    public let payloadByteCount: Int
    public let viewport: CanvasViewportState
    public let paperTemplate: CanvasPaperTemplate
    public let geometry: CanvasPageGeometry
    public let background: CanvasPageBackgroundReference

    init(
        descriptor: CanvasPageDescriptor,
        order: Int,
        payloadChecksum: String,
        payloadByteCount: Int
    ) {
        id = descriptor.id
        self.order = order
        contentRevision = descriptor.contentRevision
        self.payloadChecksum = payloadChecksum
        self.payloadByteCount = payloadByteCount
        viewport = descriptor.viewport
        paperTemplate = descriptor.paperTemplate
        geometry = descriptor.geometry
        background = descriptor.background
    }

    var descriptor: CanvasPageDescriptor {
        CanvasPageDescriptor(
            id: id,
            contentRevision: contentRevision,
            viewport: viewport,
            paperTemplate: paperTemplate,
            geometry: geometry,
            background: background
        )
    }
}

public nonisolated struct CanvasPageRevisionReference: Codable, Equatable, Hashable, Sendable {
    public let catalogGeneration: Int64
    public let pageID: UUID
    public let contentRevision: UInt64
    public let payloadChecksum: String
}

public nonisolated struct CanvasVerifiedCommit: Sendable {
    public let catalog: CanvasPageCatalog
    public let changedPageIDs: [UUID]
    public let removedPageIDs: [UUID]
    public let committedRevisions: [UUID: UInt64]
}

public nonisolated struct CanvasPageRepositoryMetrics: Sendable {
    public let catalogOpenCount: UInt64
    public let pageResolveCount: UInt64
    public let markupEncodeCount: UInt64
    public let markupDecodeCount: UInt64
    public let payloadBytesWritten: UInt64
    public let activeCatalogLeaseCount: Int
    public let stagedDirtyPageCount: Int
    /// This implementation has no evictable page or derived-image cache.
    public let evictableEncodedCacheBytes: Int
    public let derivedImageCacheBytes: Int
}

/// The background points at an item-scoped asset; its bytes are loaded only
/// when the owning page is resolved. No source image or PDF is copied into the
/// catalog manifest.
public nonisolated struct CanvasPageBackgroundReference: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case paper
        case image
        case pdfPage
    }

    public let kind: Kind
    public let relativePath: String?
    public let checksum: String?
    public let pdfPageIndex: Int?
    public let suggestedName: String?

    public static let paper = CanvasPageBackgroundReference(
        kind: .paper, relativePath: nil, checksum: nil, pdfPageIndex: nil, suggestedName: nil
    )

    fileprivate init(
        kind: Kind,
        relativePath: String?,
        checksum: String?,
        pdfPageIndex: Int?,
        suggestedName: String?
    ) {
        self.kind = kind
        self.relativePath = relativePath
        self.checksum = checksum
        self.pdfPageIndex = pdfPageIndex
        self.suggestedName = suggestedName
    }

    fileprivate init(_ background: CanvasPageBackground) throws {
        switch background {
        case .paper:
            self = .paper
        case let .image(source, suggestedName):
            guard source.isValid else { throw CanvasPageRepositoryError.invalidPage("Invalid image reference.") }
            kind = .image
            relativePath = source.relativePath
            checksum = source.contentChecksum ?? source.imageData.map(Self.sha256)
            pdfPageIndex = nil
            self.suggestedName = suggestedName
        case let .pdfPage(source, pageIndex, suggestedName):
            guard source.isValid, pageIndex >= 0 else { throw CanvasPageRepositoryError.invalidPage("Invalid PDF reference.") }
            kind = .pdfPage
            relativePath = source.relativePath
            checksum = source.contentChecksum ?? source.documentData.map(Self.sha256)
            pdfPageIndex = pageIndex
            self.suggestedName = suggestedName
        }
        guard isValid else { throw CanvasPageRepositoryError.invalidPage("Invalid page background.") }
    }

    fileprivate var isValid: Bool {
        switch kind {
        case .paper:
            return relativePath == nil && checksum == nil && pdfPageIndex == nil
        case .image:
            guard let relativePath, let checksum else { return false }
            return CanvasImageSourceReference(relativePath: relativePath, contentChecksum: checksum).isValid
                && pdfPageIndex == nil
        case .pdfPage:
            guard let relativePath, let checksum, let pdfPageIndex else { return false }
            return CanvasPDFSourceReference(relativePath: relativePath, contentChecksum: checksum).isValid
                && pdfPageIndex >= 0
        }
    }

    fileprivate func runtimeBackground(data: Data?) throws -> CanvasPageBackground {
        switch kind {
        case .paper:
            return .paper
        case .image:
            guard let relativePath, let checksum, let data,
                  Self.sha256(data) == checksum else {
                throw CanvasPageRepositoryError.assetUnavailable(relativePath ?? "image")
            }
            return .image(
                source: CanvasImageSourceReference(
                    relativePath: relativePath, imageData: data, contentChecksum: checksum
                ),
                suggestedName: suggestedName
            )
        case .pdfPage:
            guard let relativePath, let checksum, let pdfPageIndex, let data,
                  Self.sha256(data) == checksum else {
                throw CanvasPageRepositoryError.assetUnavailable(relativePath ?? "PDF")
            }
            return .pdfPage(
                source: CanvasPDFSourceReference(
                    relativePath: relativePath, documentData: data, contentChecksum: checksum
                ),
                pageIndex: pdfPageIndex,
                suggestedName: suggestedName
            )
        }
    }

    fileprivate static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

public nonisolated enum CanvasPageRepositoryError: Error, LocalizedError, Equatable, Sendable {
    case noCatalog
    case unsupportedDocument(String)
    case invalidCatalog(String)
    case invalidPage(String)
    case developerImportDestinationNotEmpty(String)
    case developerImportRequiresSeparateNotebookIDs
    case staleGeneration(expected: Int64, actual: Int64)
    case stalePageRevision(UUID)
    case missingChangedPage(UUID)
    case corruptPayload(UUID)
    case assetUnavailable(String)
    case insufficientStorage(required: Int64, available: Int64)
    case fileSystem(String)

    public var errorDescription: String? {
        switch self {
        case .noCatalog: "The notebook has no page catalog."
        case .developerImportDestinationNotEmpty(_): "The developer import destination must be a new or empty directory."
        case .developerImportRequiresSeparateNotebookIDs: "Developer import must write to a different notebook ID."
        case let .unsupportedDocument(reason): "This notebook cannot be opened by the page store: \(reason)"
        case let .invalidCatalog(reason): "The notebook page catalog is invalid: \(reason)"
        case let .invalidPage(reason): "The notebook page is invalid: \(reason)"
        case let .staleGeneration(expected, actual): "The page save is based on generation \(expected), but generation \(actual) is current."
        case let .stalePageRevision(id): "Page \(id) changed while its save was being prepared."
        case let .missingChangedPage(id): "The changed page \(id) was not supplied to the save."
        case let .corruptPayload(id): "Page \(id) failed its content checksum."
        case let .assetUnavailable(path): "The page asset \(path) could not be verified."
        case let .insufficientStorage(required, available): "The save needs \(required) free bytes, but only \(available) are available while preserving the storage reserve."
        case let .fileSystem(reason): "Notebook storage failed: \(reason)"
        }
    }
}

private nonisolated struct CanvasPagePayloadV7: Codable, Sendable {
    let formatVersion: Int
    let markupData: Data
    let tables: [CanvasTable]
}

private nonisolated struct CanvasPageManifestPayloadV7: Codable, Sendable {
    let formatVersion: Int
    let catalog: CanvasPageCatalog
}

private nonisolated struct CanvasPageManifestEnvelopeV7: Codable, Sendable {
    let payload: CanvasPageManifestPayloadV7
    let checksum: String
}

private nonisolated struct CanvasStagedPageChange: Sendable {
    let revision: UInt64
    let snapshot: CanvasPageSnapshot
}

private nonisolated struct CanvasLeaseReferences: Sendable {
    let payloadChecksums: Set<String>
    let sourcePaths: Set<String>
}

/// Page-oriented checkpoint store. Its manifest operations never decode
/// PaperMarkup; callers request a specific revision when a page becomes
/// visible. Payload files are immutable and shared by checksum.
public actor CanvasPageRepository {
    public static let formatVersion = 7
    public static let maximumPageCount = 1_000
    public static let maximumMarkupBytesPerPage = 32 * 1_024 * 1_024
    public static let maximumPagePayloadBytes = 48 * 1_024 * 1_024
    public static let maximumManifestBytes = 8 * 1_024 * 1_024
    public static let minimumFreeStorageReserve: Int64 = 256 * 1_024 * 1_024

    private let rootURL: URL
    private let pagesURL: URL
    private let sourcesURL: URL
    private let codec: any CanvasCoreMarkupCoding
    private let storageCapacityProvider: @Sendable (URL) -> Int64
    private var commitInProgress = false
    private var commitWaiters: [CheckedContinuation<Void, Never>] = []
    private var activeLeases: [UUID: CanvasLeaseReferences] = [:]
    private var inFlightPageLoads: [UUID: CanvasLeaseReferences] = [:]
    private var pendingPayloadChecksums: Set<String> = []
    private var pendingSourcePaths: Set<String> = []
    private var stagedPages: [UUID: CanvasStagedPageChange] = [:]
    private var codecInProgress = false
    private var codecWaiters: [CheckedContinuation<Void, Never>] = []
    private var catalogOpenCount: UInt64 = 0
    private var pageResolveCount: UInt64 = 0
    private var markupEncodeCount: UInt64 = 0
    private var markupDecodeCount: UInt64 = 0
    private var payloadBytesWritten: UInt64 = 0

    public init(
        rootURL: URL,
        codec: any CanvasCoreMarkupCoding = PaperKitCanvasCoreCodec(),
        storageCapacityProvider: (@Sendable (URL) -> Int64)? = nil
    ) {
        let standardizedRoot = rootURL.standardizedFileURL
        self.rootURL = standardizedRoot
        pagesURL = standardizedRoot.appendingPathComponent("Pages", isDirectory: true)
        sourcesURL = standardizedRoot.appendingPathComponent("Sources", isDirectory: true)
        self.codec = codec
        self.storageCapacityProvider = storageCapacityProvider ?? Self.availableStorage(at:)
    }

    /// Opens either the current or previous verified manifest. Payload bytes
    /// remain unread until `loadPage` is called.
    public func acquireCatalogLease() throws -> CanvasPageCatalogLease {
        try ensureDirectories()
        let current = try readManifest(at: currentURL)
        let previous = try readManifest(at: previousURL)
        let catalog: CanvasPageCatalog
        if let current, referencedPayloadsExist(for: current) {
            catalog = current
        } else if let previous, referencedPayloadsExist(for: previous) {
            catalog = previous
        } else if current == nil && previous == nil {
            if FileManager.default.fileExists(atPath: currentURL.path)
                || FileManager.default.fileExists(atPath: previousURL.path) {
                throw CanvasPageRepositoryError.invalidCatalog("Neither recovery manifest is valid.")
            }
            throw CanvasPageRepositoryError.noCatalog
        } else {
            throw CanvasPageRepositoryError.invalidCatalog("Both recovery manifests reference unavailable payloads.")
        }
        let leaseID = UUID()
        activeLeases[leaseID] = CanvasLeaseReferences(
            payloadChecksums: Set(catalog.pages.map(\.payloadChecksum)),
            sourcePaths: Set(catalog.pages.compactMap(\.background.relativePath))
        )
        catalogOpenCount &+= 1
        return CanvasPageCatalogLease(id: leaseID, catalog: catalog)
    }

    public func release(_ lease: CanvasPageCatalogLease) {
        activeLeases[lease.id] = nil
    }

    public func metrics() -> CanvasPageRepositoryMetrics {
        CanvasPageRepositoryMetrics(
            catalogOpenCount: catalogOpenCount,
            pageResolveCount: pageResolveCount,
            markupEncodeCount: markupEncodeCount,
            markupDecodeCount: markupDecodeCount,
            payloadBytesWritten: payloadBytesWritten,
            activeCatalogLeaseCount: activeLeases.count,
            stagedDirtyPageCount: stagedPages.count,
            evictableEncodedCacheBytes: 0,
            derivedImageCacheBytes: 0
        )
    }

    /// Retains only the newest unsaved value for a page. The staged revision is
    /// acknowledged only if the exact revision is included in a verified commit.
    public func stageChangedPage(
        _ page: CanvasPageSnapshot,
        contentRevision: UInt64
    ) throws {
        guard contentRevision > 0 else {
            throw CanvasPageRepositoryError.invalidPage("A dirty page revision must be positive.")
        }
        if let existing = stagedPages[page.id], existing.revision > contentRevision {
            throw CanvasPageRepositoryError.stalePageRevision(page.id)
        }
        stagedPages[page.id] = CanvasStagedPageChange(
            revision: contentRevision,
            snapshot: page
        )
    }

    public func commitStagedPages(
        expectedGeneration: Int64,
        generation: Int64,
        currentPageID: UUID,
        pages descriptors: [CanvasPageDescriptor]
    ) async throws -> CanvasVerifiedCommit {
        guard Set(descriptors.map(\.id)).count == descriptors.count else {
            throw CanvasPageRepositoryError.invalidCatalog("Page identities must be unique.")
        }
        let descriptorRevisions = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0.contentRevision) })
        let included = stagedPages.filter { descriptorRevisions[$0.key] == $0.value.revision }
        let snapshots = Dictionary(uniqueKeysWithValues: included.map { ($0.key, $0.value.snapshot) })
        let commit = try await commit(
            expectedGeneration: expectedGeneration,
            generation: generation,
            currentPageID: currentPageID,
            pages: descriptors,
            changedPages: snapshots
        )
        for (pageID, revision) in commit.committedRevisions where stagedPages[pageID]?.revision == revision {
            stagedPages[pageID] = nil
        }
        return commit
    }

    public func loadPage(
        _ reference: CanvasPageRevisionReference,
        using lease: CanvasPageCatalogLease
    ) async throws -> CanvasPageSnapshot {
        guard activeLeases[lease.id] != nil,
              reference.catalogGeneration == lease.catalog.generation,
              let entry = lease.catalog.page(id: reference.pageID),
              entry.contentRevision == reference.contentRevision,
              entry.payloadChecksum == reference.payloadChecksum else {
            throw CanvasPageRepositoryError.stalePageRevision(reference.pageID)
        }
        let loadID = UUID()
        inFlightPageLoads[loadID] = CanvasLeaseReferences(
            payloadChecksums: [entry.payloadChecksum],
            sourcePaths: Set(entry.background.relativePath.map { [$0] } ?? [])
        )
        defer { inFlightPageLoads[loadID] = nil }
        let (markup, tables) = try await decodePagePayload(entry)
        let backgroundData = try readBackgroundData(entry.background)
        let background = try entry.background.runtimeBackground(data: backgroundData)
        let page = CanvasPageSnapshot(
            id: entry.id,
            markup: markup,
            tables: tables,
            viewport: entry.viewport,
            paperTemplate: entry.paperTemplate,
            geometry: entry.geometry,
            background: background
        )
        try Self.validate(page)
        pageResolveCount &+= 1
        return page
    }

    /// Processes the leased generation in catalog order while resolving one
    /// page at a time. The repository holds an internal generation lease for
    /// the whole operation, so callers may release their catalog lease without
    /// allowing garbage collection to remove content still being exported.
    /// The callback should finish its work before returning and avoid retaining
    /// the supplied page if bounded memory is required.
    public func forEachPage(
        using lease: CanvasPageCatalogLease,
        operation: @Sendable (CanvasPageDescriptor, CanvasPageSnapshot) async throws -> Void
    ) async throws {
        guard activeLeases[lease.id] != nil else {
            throw CanvasPageRepositoryError.staleGeneration(
                expected: lease.catalog.generation,
                actual: (try? readManifest(at: currentURL)?.generation) ?? 0
            )
        }
        let streamID = UUID()
        activeLeases[streamID] = CanvasLeaseReferences(
            payloadChecksums: Set(lease.catalog.pages.map(\.payloadChecksum)),
            sourcePaths: Set(lease.catalog.pages.compactMap(\.background.relativePath))
        )
        let streamLease = CanvasPageCatalogLease(id: streamID, catalog: lease.catalog)
        defer { activeLeases[streamID] = nil }

        for entry in lease.catalog.pages {
            try Task.checkCancellation()
            guard let reference = lease.catalog.reference(for: entry.id) else {
                throw CanvasPageRepositoryError.invalidCatalog("A leased page has no revision reference.")
            }
            let page = try await loadPage(reference, using: streamLease)
            try await operation(entry.descriptor, page)
        }
    }

    /// Commits only changed markup revisions. Metadata and ordering can change
    /// independently; unchanged page payloads are reused by reference.
    public func commit(
        expectedGeneration: Int64,
        generation: Int64,
        currentPageID: UUID,
        pages descriptors: [CanvasPageDescriptor],
        changedPages: [UUID: CanvasPageSnapshot]
    ) async throws -> CanvasVerifiedCommit {
        let descriptorIDs = Set(descriptors.map(\.id))
        guard Set(changedPages.keys).isSubset(of: descriptorIDs) else {
            throw CanvasPageRepositoryError.invalidCatalog("A changed page is absent from the catalog draft.")
        }
        return try await commitResolvingPages(
            expectedGeneration: expectedGeneration,
            generation: generation,
            currentPageID: currentPageID,
            pages: descriptors,
            resolveChangedPage: { descriptor in changedPages[descriptor.id] }
        )
    }

    /// Streaming commit entry point for imports and large-document producers.
    /// The resolver is called only for new pages or revisions whose content
    /// changed. Each returned page is encoded and released before the next is
    /// requested, so callers can generate or decode pages one at a time.
    public func commitResolvingPages(
        expectedGeneration: Int64,
        generation: Int64,
        currentPageID: UUID,
        pages descriptors: [CanvasPageDescriptor],
        resolveChangedPage: @escaping @Sendable (CanvasPageDescriptor) async throws -> CanvasPageSnapshot?
    ) async throws -> CanvasVerifiedCommit {
        await acquireCommitPermit()
        defer { releaseCommitPermit() }
        try Task.checkCancellation()
        try ensureDirectories()
        let currentManifestExists = FileManager.default.fileExists(atPath: currentURL.path)
        let previousManifestExists = FileManager.default.fileExists(atPath: previousURL.path)
        let parsedCurrentCatalog = try readManifest(at: currentURL)
        let parsedPreviousCatalog = try readManifest(at: previousURL)
        let currentCatalog = parsedCurrentCatalog.flatMap {
            referencedPayloadsExist(for: $0) ? $0 : nil
        }
        let previousCatalog = parsedPreviousCatalog.flatMap {
            referencedPayloadsExist(for: $0) ? $0 : nil
        }
        guard (!currentManifestExists && !previousManifestExists)
                || currentCatalog != nil
                || previousCatalog != nil else {
            throw CanvasPageRepositoryError.invalidCatalog(
                "Neither recovery manifest can be used; refusing to replace the existing notebook."
            )
        }
        let oldCatalog = currentCatalog ?? previousCatalog
        let hasInvalidRecoveryManifest = (currentManifestExists && currentCatalog == nil)
            || (previousManifestExists && previousCatalog == nil)
        let actualGeneration = oldCatalog?.generation ?? 0
        guard expectedGeneration == actualGeneration else {
            throw CanvasPageRepositoryError.staleGeneration(
                expected: expectedGeneration, actual: actualGeneration
            )
        }
        guard generation > actualGeneration else {
            throw CanvasPageRepositoryError.staleGeneration(
                expected: actualGeneration + 1, actual: generation
            )
        }
        try Self.validateCatalogInputs(generation: generation, currentPageID: currentPageID, pages: descriptors)
        let descriptorIDs = Set(descriptors.map(\.id))
        let reservedSourcePaths = Set(descriptors.compactMap { $0.background.relativePath })
        for relativePath in reservedSourcePaths { _ = try sourceURL(relativePath) }
        pendingSourcePaths.formUnion(reservedSourcePaths)

        let previousByID = Dictionary(uniqueKeysWithValues: (oldCatalog?.pages ?? []).map { ($0.id, $0) })
        var entries: [CanvasPageCatalogEntry] = []
        entries.reserveCapacity(descriptors.count)
        var changedIDs: [UUID] = []
        var createdPayloadChecksums: Set<String> = []
        var createdSourceURLs: Set<URL> = []
        var reservedPayloadChecksums: Set<String> = []
        var published = false
        var publicationStarted = false
        defer {
            pendingPayloadChecksums.subtract(reservedPayloadChecksums)
            pendingSourcePaths.subtract(reservedSourcePaths)
            if !published && !publicationStarted && !hasInvalidRecoveryManifest {
                let protected = Set((currentCatalog?.pages ?? []).map(\.payloadChecksum))
                    .union((previousCatalog?.pages ?? []).map(\.payloadChecksum))
                    .union(activeLeases.values.flatMap { $0.payloadChecksums })
                for checksum in createdPayloadChecksums where !protected.contains(checksum) {
                    let url = payloadURL(checksum)
                    try? FileManager.default.removeItem(at: url)
                }
                let referencedPaths = Set((currentCatalog?.pages ?? []).compactMap(\.background.relativePath))
                    .union((previousCatalog?.pages ?? []).compactMap(\.background.relativePath))
                    .union(activeLeases.values.flatMap { $0.sourcePaths })
                for url in createdSourceURLs {
                    let relativePath = String(url.path.dropFirst(sourcesURL.path.count + 1))
                    if !referencedPaths.contains(relativePath) {
                        try? FileManager.default.removeItem(at: url)
                    }
                }
            }
        }

        for (order, descriptor) in descriptors.enumerated() {
            try Task.checkCancellation()
            let previous = previousByID[descriptor.id]
            if let previous, descriptor.contentRevision < previous.contentRevision {
                throw CanvasPageRepositoryError.stalePageRevision(descriptor.id)
            }
            if let sharedReference = descriptor.sharedPayloadReference {
                guard previous == nil,
                      let source = oldCatalog?.page(id: sharedReference.pageID),
                      sharedReference.catalogGeneration <= (oldCatalog?.generation ?? 0),
                      source.contentRevision == sharedReference.contentRevision,
                      source.payloadChecksum == sharedReference.payloadChecksum else {
                    throw CanvasPageRepositoryError.stalePageRevision(descriptor.id)
                }
                try verifyPayload(
                    at: payloadURL(source.payloadChecksum),
                    checksum: source.payloadChecksum,
                    byteCount: source.payloadByteCount,
                    pageID: descriptor.id
                )
                try validateExistingBackground(descriptor.background)
                entries.append(CanvasPageCatalogEntry(
                    descriptor: descriptor,
                    order: order,
                    payloadChecksum: source.payloadChecksum,
                    payloadByteCount: source.payloadByteCount
                ))
                changedIDs.append(descriptor.id)
                continue
            }
            let needsPayload = previous.map { $0.contentRevision != descriptor.contentRevision } ?? true
            if needsPayload {
                guard let page = try await resolveChangedPage(descriptor) else {
                    throw CanvasPageRepositoryError.missingChangedPage(descriptor.id)
                }
                let preparedBackground = try prepareBackground(page.background)
                guard page.id == descriptor.id,
                      page.viewport == descriptor.viewport,
                      page.paperTemplate == descriptor.paperTemplate,
                      page.geometry == descriptor.geometry,
                      preparedBackground.reference == descriptor.background else {
                    throw CanvasPageRepositoryError.stalePageRevision(descriptor.id)
                }
                try Self.validate(page)
                if let stagedSource = preparedBackground.stagedSource {
                    try writeSource(stagedSource, createdSourceURLs: &createdSourceURLs)
                }
                let markupData = try await encodeMarkup(page.markup)
                try Task.checkCancellation()
                guard markupData.count <= Self.maximumMarkupBytesPerPage else {
                    throw CanvasPageRepositoryError.invalidPage("Page markup exceeds the per-page safety limit.")
                }
                let payloadData = try Self.encode(CanvasPagePayloadV7(
                    formatVersion: Self.formatVersion,
                    markupData: markupData,
                    tables: page.tables
                ))
                guard payloadData.count <= Self.maximumPagePayloadBytes else {
                    throw CanvasPageRepositoryError.invalidPage("Page content exceeds the per-page safety limit.")
                }
                let checksum = Self.sha256(payloadData)
                // Keep a new or deduplicated payload pinned until manifest
                // publication completes, including across later codec awaits.
                pendingPayloadChecksums.insert(checksum)
                reservedPayloadChecksums.insert(checksum)
                entries.append(CanvasPageCatalogEntry(
                    descriptor: descriptor, order: order,
                    payloadChecksum: checksum, payloadByteCount: payloadData.count
                ))
                let url = payloadURL(checksum)
                if FileManager.default.fileExists(atPath: url.path) {
                    try verifyPayload(
                        at: url, checksum: checksum, byteCount: payloadData.count, pageID: descriptor.id
                    )
                } else {
                    try requireFreeStorage(forAdditionalBytes: Int64(payloadData.count))
                    try payloadData.write(to: url, options: .atomic)
                    do {
                        try verifyPayload(
                            at: url, checksum: checksum, byteCount: payloadData.count, pageID: descriptor.id
                        )
                    } catch {
                        try? FileManager.default.removeItem(at: url)
                        throw error
                    }
                    createdPayloadChecksums.insert(checksum)
                    payloadBytesWritten &+= UInt64(payloadData.count)
                }
                changedIDs.append(descriptor.id)
            } else if let previous {
                if previous.background != descriptor.background {
                    try validateExistingBackground(descriptor.background)
                }
                entries.append(CanvasPageCatalogEntry(
                    descriptor: descriptor, order: order,
                    payloadChecksum: previous.payloadChecksum,
                    payloadByteCount: previous.payloadByteCount
                ))
            } else {
                throw CanvasPageRepositoryError.missingChangedPage(descriptor.id)
            }
        }

        let catalog = CanvasPageCatalog(
            generation: generation, currentPageID: currentPageID, pages: entries
        )
        let manifestData = try Self.encodeManifest(catalog)
        guard manifestData.count <= Self.maximumManifestBytes else {
            throw CanvasPageRepositoryError.invalidCatalog("The catalog exceeds its size limit.")
        }
        let oldManifestSize = (try? Data(contentsOf: currentURL, options: .mappedIfSafe).count) ?? 0
        let required = Int64(manifestData.count * 2 + oldManifestSize)
            + Self.minimumFreeStorageReserve
        let available = storageCapacityProvider(rootURL)
        guard available >= required else {
            throw CanvasPageRepositoryError.insufficientStorage(required: required, available: available)
        }

        try Task.checkCancellation()
        if let currentData = try? Data(contentsOf: currentURL, options: .mappedIfSafe),
           let currentManifest = readManifestData(currentData),
           referencedPayloadsExist(for: currentManifest) {
            try currentData.write(to: previousURL, options: .atomic)
        }
        publicationStarted = true
        try manifestData.write(to: currentURL, options: .atomic)
        guard let verifiedCatalog = try readManifest(at: currentURL),
              verifiedCatalog == catalog else {
            throw CanvasPageRepositoryError.invalidCatalog("The published manifest failed verification.")
        }
        published = true
        let currentIDs = Set(descriptorIDs)
        let removedIDs = (oldCatalog?.pages.map(\.id) ?? []).filter { !currentIDs.contains($0) }
        let committedRevisions = Dictionary(uniqueKeysWithValues: changedIDs.compactMap { id in
            descriptors.first(where: { $0.id == id }).map { (id, $0.contentRevision) }
        })
        return CanvasVerifiedCommit(
            catalog: catalog,
            changedPageIDs: changedIDs,
            removedPageIDs: removedIDs,
            committedRevisions: committedRevisions
        )
    }

    /// Removes only page payloads unreachable from both recovery manifests,
    /// active catalog leases, or a checkpoint currently being published.
    public func collectUnreferencedPayloads() throws -> [String] {
        try ensureDirectories()
        let current = try readManifest(at: currentURL)
        let previous = try readManifest(at: previousURL)
        if (FileManager.default.fileExists(atPath: currentURL.path) && current == nil)
            || (FileManager.default.fileExists(atPath: previousURL.path) && previous == nil) {
            throw CanvasPageRepositoryError.invalidCatalog("Garbage collection stopped because a recovery manifest is invalid.")
        }
        let protected = Set((current?.pages ?? []).map(\.payloadChecksum))
            .union((previous?.pages ?? []).map(\.payloadChecksum))
            .union(activeLeases.values.flatMap { $0.payloadChecksums })
            .union(inFlightPageLoads.values.flatMap { $0.payloadChecksums })
            .union(pendingPayloadChecksums)
        let urls = try FileManager.default.contentsOfDirectory(
            at: pagesURL, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        var removed: [String] = []
        for url in urls where url.pathExtension == "page" {
            let checksum = url.deletingPathExtension().lastPathComponent
            guard Self.isChecksum(checksum), !protected.contains(checksum) else { continue }
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            try FileManager.default.removeItem(at: url)
            removed.append(checksum)
        }
        return removed.sorted()
    }

    /// Removes source assets only after both recovery manifests and all active
    /// catalog readers have released their references.
    public func collectUnreferencedSources() throws -> [String] {
        try ensureDirectories()
        let current = try readManifest(at: currentURL)
        let previous = try readManifest(at: previousURL)
        if (FileManager.default.fileExists(atPath: currentURL.path) && current == nil)
            || (FileManager.default.fileExists(atPath: previousURL.path) && previous == nil) {
            throw CanvasPageRepositoryError.invalidCatalog(
                "Asset cleanup stopped because a recovery manifest is invalid."
            )
        }
        let protected = Set((current?.pages ?? []).compactMap(\.background.relativePath))
            .union((previous?.pages ?? []).compactMap(\.background.relativePath))
            .union(activeLeases.values.flatMap { $0.sourcePaths })
            .union(inFlightPageLoads.values.flatMap { $0.sourcePaths })
            .union(pendingSourcePaths)
        guard let enumerator = FileManager.default.enumerator(
            at: sourcesURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        var removed: [String] = []
        while let url = enumerator.nextObject() as? URL {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            guard values.isRegularFile == true else { continue }
            let standardizedPath = url.standardizedFileURL.path
            let sourcePrefix = sourcesURL.standardizedFileURL.path + "/"
            guard standardizedPath.hasPrefix(sourcePrefix) else { continue }
            let relativePath = String(standardizedPath.dropFirst(sourcePrefix.count))
            guard !protected.contains(relativePath) else { continue }
            try FileManager.default.removeItem(at: url)
            removed.append(relativePath)
        }
        return removed.sorted()
    }

    /// Returns a v7 directory that is separate from the legacy Canvas directory.
    public nonisolated static func developerRootURL(
        for itemID: UUID,
        applicationSupportURL: URL? = nil
    ) throws -> URL {
        let applicationSupport: URL
        if let applicationSupportURL {
            applicationSupport = applicationSupportURL
        } else {
            applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        return applicationSupport
            .appendingPathComponent("NotateLibrary", isDirectory: true)
            .appendingPathComponent("Items", isDirectory: true)
            .appendingPathComponent(itemID.uuidString, isDirectory: true)
            .appendingPathComponent("CanvasV7", isDirectory: true)
    }

    /// Item-ID entry point for the developer importer. The destination item
    /// gets its own CanvasV7 directory; the existing v1-v6 Canvas directory
    /// remains untouched and continues to open in the production editor.
    public nonisolated static func makeDeveloperCopy(
        fromItemID sourceItemID: UUID,
        toItemID destinationItemID: UUID,
        applicationSupportURL: URL? = nil,
        codec: any CanvasCoreMarkupCoding = PaperKitCanvasCoreCodec()
    ) async throws -> CanvasPageRepository {
        guard sourceItemID != destinationItemID else {
            throw CanvasPageRepositoryError.developerImportRequiresSeparateNotebookIDs
        }
        let applicationSupport: URL
        if let applicationSupportURL {
            applicationSupport = applicationSupportURL
        } else {
            applicationSupport = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
        }
        let itemsRoot = applicationSupport
            .appendingPathComponent("NotateLibrary", isDirectory: true)
            .appendingPathComponent("Items", isDirectory: true)
        let sourceRoot = itemsRoot
            .appendingPathComponent(sourceItemID.uuidString, isDirectory: true)
            .appendingPathComponent("Canvas", isDirectory: true)
        let sourceStore = CanvasCoreStore(rootURL: sourceRoot, codec: codec)
        return try await makeDeveloperCopy(
            from: sourceStore,
            to: try developerRootURL(for: destinationItemID, applicationSupportURL: applicationSupport),
            codec: codec
        )
    }

    /// Developer-only, copy-on-import bridge for existing v1-v6 notebooks.
    /// It reads the source store and writes into a new, empty v7 directory.
    public static func makeDeveloperCopy(
        from legacyStore: CanvasCoreStore,
        to destinationRoot: URL,
        codec: any CanvasCoreMarkupCoding = PaperKitCanvasCoreCodec()
    ) async throws -> CanvasPageRepository {
        let destinationRoot = destinationRoot.standardizedFileURL
        var destinationIsDirectory: ObjCBool = false
        if FileManager.default.fileExists(
            atPath: destinationRoot.path,
            isDirectory: &destinationIsDirectory
        ) {
            let values = try destinationRoot.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard destinationIsDirectory.boolValue,
                  values.isDirectory == true,
                  values.isSymbolicLink != true else {
                throw CanvasPageRepositoryError.developerImportDestinationNotEmpty(destinationRoot.path)
            }
            do {
                let existingEntries = try FileManager.default.contentsOfDirectory(atPath: destinationRoot.path)
                guard existingEntries.isEmpty else {
                    throw CanvasPageRepositoryError.developerImportDestinationNotEmpty(destinationRoot.path)
                }
            } catch let error as CanvasPageRepositoryError {
                throw error
            } catch {
                throw CanvasPageRepositoryError.fileSystem(error.localizedDescription)
            }
        }

        let repository = CanvasPageRepository(rootURL: destinationRoot, codec: codec)
        guard await legacyStore.hasCheckpointForDeveloperImport() else {
            throw CanvasPageRepositoryError.noCatalog
        }
        let loadResult = await legacyStore.load()
        guard case let .restored(snapshot) = loadResult else {
            if case let .failed(error) = loadResult { throw error }
            throw CanvasPageRepositoryError.noCatalog
        }
        let descriptors = try snapshot.pages.enumerated().map { index, page in
            try CanvasPageDescriptor(page: page, contentRevision: UInt64(index + 1))
        }
        let pageIndices = Dictionary(uniqueKeysWithValues: snapshot.pages.enumerated().map {
            ($0.element.id, $0.offset)
        })
        _ = try await repository.commitResolvingPages(
            expectedGeneration: 0,
            generation: max(1, snapshot.generation),
            currentPageID: snapshot.currentPageID,
            pages: descriptors
        ) { descriptor in
            guard let index = pageIndices[descriptor.id] else { return nil }
            return try await legacyStore.pageForDeveloperImport(snapshot.pages[index])
        }
        return repository
    }

    private var currentURL: URL { rootURL.appendingPathComponent("current.canvas") }
    private var previousURL: URL { rootURL.appendingPathComponent("previous.canvas") }

    private func payloadURL(_ checksum: String) -> URL {
        pagesURL.appendingPathComponent(checksum).appendingPathExtension("page")
    }

    private func ensureDirectories() throws {
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pagesURL, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourcesURL, withIntermediateDirectories: true)
    }

    private func prepareBackground(
        _ background: CanvasPageBackground
    ) throws -> (reference: CanvasPageBackgroundReference, stagedSource: (url: URL, data: Data)?) {
        let reference = try CanvasPageBackgroundReference(background)
        guard reference.kind != .paper,
              let relativePath = reference.relativePath,
              let checksum = reference.checksum else { return (reference, nil) }
        let data: Data
        switch background {
        case let .image(source, _):
            if let imageData = source.imageData { data = imageData }
            else { return try validateAndReturnExistingSource(reference) }
        case let .pdfPage(source, _, _):
            if let documentData = source.documentData { data = documentData }
            else { return try validateAndReturnExistingSource(reference) }
        case .paper:
            return (reference, nil)
        }
        guard data.count <= 128 * 1_024 * 1_024, Self.sha256(data) == checksum else {
            throw CanvasPageRepositoryError.assetUnavailable(relativePath)
        }
        let url = try sourceURL(relativePath)
        if FileManager.default.fileExists(atPath: url.path) {
            let existing = try Data(contentsOf: url, options: .mappedIfSafe)
            guard existing.count == data.count, Self.sha256(existing) == checksum else {
                throw CanvasPageRepositoryError.assetUnavailable(relativePath)
            }
            return (reference, nil)
        }
        return (reference, (url, data))
    }

    private func validateAndReturnExistingSource(
        _ reference: CanvasPageBackgroundReference
    ) throws -> (reference: CanvasPageBackgroundReference, stagedSource: (url: URL, data: Data)?) {
        _ = try readBackgroundData(reference)
        return (reference, nil)
    }

    private func validateExistingBackground(_ reference: CanvasPageBackgroundReference) throws {
        guard reference.kind != .paper else { return }
        _ = try readBackgroundData(reference)
    }

    private func writeSource(
        _ source: (url: URL, data: Data),
        createdSourceURLs: inout Set<URL>
    ) throws {
        try Task.checkCancellation()
        try requireFreeStorage(forAdditionalBytes: Int64(source.data.count))
        try FileManager.default.createDirectory(
            at: source.url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let sourcePrefix = sourcesURL.standardizedFileURL.path + "/"
        let relativePath = String(source.url.standardizedFileURL.path.dropFirst(sourcePrefix.count))
        pendingSourcePaths.insert(relativePath)
        do {
            try source.data.write(to: source.url, options: .atomic)
            let verified = try Data(contentsOf: source.url, options: .mappedIfSafe)
            guard verified.count == source.data.count, Self.sha256(verified) == Self.sha256(source.data) else {
                try? FileManager.default.removeItem(at: source.url)
                throw CanvasPageRepositoryError.assetUnavailable(source.url.lastPathComponent)
            }
            createdSourceURLs.insert(source.url)
        } catch {
            pendingSourcePaths.remove(relativePath)
            throw error
        }
    }

    private func verifyPayload(
        at url: URL,
        checksum: String,
        byteCount: Int,
        pageID: UUID
    ) throws {
        let verified = try Data(contentsOf: url, options: .mappedIfSafe)
        guard verified.count == byteCount, Self.sha256(verified) == checksum else {
            throw CanvasPageRepositoryError.corruptPayload(pageID)
        }
    }

    private func decodePagePayload(
        _ entry: CanvasPageCatalogEntry
    ) async throws -> (PaperMarkup, [CanvasTable]) {
        await acquireCodecPermit()
        defer { releaseCodecPermit() }
        try Task.checkCancellation()
        let url = payloadURL(entry.payloadChecksum)
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw CanvasPageRepositoryError.assetUnavailable(url.lastPathComponent) }
        guard data.count == entry.payloadByteCount,
              Self.sha256(data) == entry.payloadChecksum else {
            throw CanvasPageRepositoryError.corruptPayload(entry.id)
        }
        let payload: CanvasPagePayloadV7
        do { payload = try JSONDecoder().decode(CanvasPagePayloadV7.self, from: data) }
        catch { throw CanvasPageRepositoryError.corruptPayload(entry.id) }
        guard payload.formatVersion == Self.formatVersion,
              payload.markupData.count <= Self.maximumMarkupBytesPerPage else {
            throw CanvasPageRepositoryError.corruptPayload(entry.id)
        }
        do {
            markupDecodeCount &+= 1
            let markup = try await codec.decode(payload.markupData)
            try Task.checkCancellation()
            return (markup, payload.tables)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw CanvasPageRepositoryError.corruptPayload(entry.id)
        }
    }

    private func encodeMarkup(_ markup: PaperMarkup) async throws -> Data {
        await acquireCodecPermit()
        defer { releaseCodecPermit() }
        try Task.checkCancellation()
        markupEncodeCount &+= 1
        return try await codec.encode(markup)
    }

    private func requireFreeStorage(forAdditionalBytes bytes: Int64) throws {
        let required = bytes + Self.minimumFreeStorageReserve
            + Int64(Self.maximumManifestBytes * 2)
        let available = storageCapacityProvider(rootURL)
        guard available >= required else {
            throw CanvasPageRepositoryError.insufficientStorage(required: required, available: available)
        }
    }

    private func readManifest(at url: URL) throws -> CanvasPageCatalog? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw CanvasPageRepositoryError.fileSystem(error.localizedDescription) }
        guard data.count <= Self.maximumManifestBytes else { return nil }
        return readManifestData(data)
    }

    private func readManifestData(_ data: Data) -> CanvasPageCatalog? {
        guard let envelope = try? JSONDecoder().decode(CanvasPageManifestEnvelopeV7.self, from: data),
              envelope.payload.formatVersion == Self.formatVersion,
              let payloadData = try? Self.encode(envelope.payload),
              Self.sha256(payloadData) == envelope.checksum,
              Self.isValidCatalog(envelope.payload.catalog) else { return nil }
        return envelope.payload.catalog
    }

    private func referencedPayloadsExist(for catalog: CanvasPageCatalog) -> Bool {
        catalog.pages.allSatisfy { entry in
            let url = payloadURL(entry.payloadChecksum)
            guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { return false }
            return values.isRegularFile == true && values.isSymbolicLink != true
                && values.fileSize == entry.payloadByteCount
        }
    }

    private func readBackgroundData(_ background: CanvasPageBackgroundReference) throws -> Data? {
        guard background.kind != .paper,
              let relativePath = background.relativePath,
              let expectedChecksum = background.checksum else { return nil }
        let url = try sourceURL(relativePath)
        let data: Data
        do { data = try Data(contentsOf: url, options: .mappedIfSafe) }
        catch { throw CanvasPageRepositoryError.assetUnavailable(relativePath) }
        guard data.count <= 128 * 1_024 * 1_024,
              Self.sha256(data) == expectedChecksum else {
            throw CanvasPageRepositoryError.assetUnavailable(relativePath)
        }
        return data
    }

    private func sourceURL(_ relativePath: String) throws -> URL {
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"),
              !relativePath.hasPrefix("~"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else {
            throw CanvasPageRepositoryError.invalidPage("The asset path is not item-relative.")
        }
        let url = components.reduce(sourcesURL) { $0.appendingPathComponent(String($1)) }
        let resolvedRoot = sourcesURL.resolvingSymlinksInPath().standardizedFileURL.path

        // The final file may not exist yet, and Foundation can then retain a
        // `/private/var/...` spelling for it while resolving the existing
        // Sources directory to `/var/...`. Validate each existing component
        // instead of comparing that incomplete final path with the canonical
        // root. This still rejects symlink traversal within the notebook.
        var traversedURL = sourcesURL
        for component in components {
            traversedURL.appendPathComponent(String(component))
            guard FileManager.default.fileExists(atPath: traversedURL.path) else { break }
            let values = try? traversedURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            let resolvedComponent = traversedURL.resolvingSymlinksInPath().standardizedFileURL.path
            guard values?.isSymbolicLink != true,
                  resolvedComponent == resolvedRoot
                    || resolvedComponent.hasPrefix(resolvedRoot + "/") else {
                #if DEBUG
                throw CanvasPageRepositoryError.invalidPage(
                    "The asset path escapes the notebook directory (relative: \(relativePath), component: \(traversedURL.path), root: \(resolvedRoot), resolved: \(resolvedComponent), symlink: \(String(describing: values?.isSymbolicLink)))."
                )
                #else
                throw CanvasPageRepositoryError.invalidPage("The asset path escapes the notebook directory.")
                #endif
            }
        }
        return url
    }

    private func acquireCommitPermit() async {
        if !commitInProgress { commitInProgress = true; return }
        await withCheckedContinuation { commitWaiters.append($0) }
    }

    private func releaseCommitPermit() {
        if commitWaiters.isEmpty {
            commitInProgress = false
        } else {
            commitWaiters.removeFirst().resume()
        }
    }

    private func acquireCodecPermit() async {
        if !codecInProgress { codecInProgress = true; return }
        await withCheckedContinuation { codecWaiters.append($0) }
    }

    private func releaseCodecPermit() {
        if codecWaiters.isEmpty {
            codecInProgress = false
        } else {
            codecWaiters.removeFirst().resume()
        }
    }

    private nonisolated static func validateCatalogInputs(
        generation: Int64,
        currentPageID: UUID,
        pages: [CanvasPageDescriptor]
    ) throws {
        guard generation > 0, !pages.isEmpty, pages.count <= maximumPageCount else {
            throw CanvasPageRepositoryError.invalidCatalog("The page count or generation is outside supported bounds.")
        }
        let ids = Set(pages.map(\.id))
        guard ids.count == pages.count, ids.contains(currentPageID) else {
            throw CanvasPageRepositoryError.invalidCatalog("Page identities must be unique and include the current page.")
        }
        for page in pages {
            guard page.contentRevision > 0,
                  page.viewport.isValid,
                  page.geometry.isValid,
                  page.background.isValid else {
                throw CanvasPageRepositoryError.invalidPage(
                    "A page has an invalid content revision, geometry, viewport, or background metadata."
                )
            }
        }
    }

    private nonisolated static func validate(_ page: CanvasPageSnapshot) throws {
        guard page.viewport.isValid, page.geometry.isValid, page.background.isValid,
              !page.markup.bounds.isNull, !page.markup.bounds.isInfinite,
              page.markup.bounds.width.isFinite, page.markup.bounds.height.isFinite,
              page.markup.bounds.width > 0, page.markup.bounds.height > 0,
              page.markup.bounds.width <= CanvasConstants.maximumPersistedCanvasDimension,
              page.markup.bounds.height <= CanvasConstants.maximumPersistedCanvasDimension,
              page.tables.allSatisfy({ $0.isValid(in: page.markup.bounds) }) else {
            throw CanvasPageRepositoryError.invalidPage("A page contains invalid PaperKit or table geometry.")
        }
    }

    private nonisolated static func isValidCatalog(_ catalog: CanvasPageCatalog) -> Bool {
        guard catalog.generation > 0, !catalog.pages.isEmpty,
              catalog.pages.count <= maximumPageCount,
              catalog.pages.indices.allSatisfy({ catalog.pages[$0].order == $0 }),
              Set(catalog.pages.map(\.id)).count == catalog.pages.count,
              catalog.pages.contains(where: { $0.id == catalog.currentPageID }) else { return false }
        return catalog.pages.allSatisfy { entry in
            entry.contentRevision > 0
                && isChecksum(entry.payloadChecksum)
                && entry.payloadByteCount > 0
                && entry.payloadByteCount <= maximumPagePayloadBytes
                && entry.viewport.isValid && entry.geometry.isValid && entry.background.isValid
        }
    }

    private nonisolated static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private nonisolated static func encodeManifest(_ catalog: CanvasPageCatalog) throws -> Data {
        let payload = CanvasPageManifestPayloadV7(formatVersion: formatVersion, catalog: catalog)
        let checksum = sha256(try encode(payload))
        return try encode(CanvasPageManifestEnvelopeV7(payload: payload, checksum: checksum))
    }

    private nonisolated static func sha256(_ data: Data) -> String {
        CanvasPageBackgroundReference.sha256(data)
    }

    private nonisolated static func isChecksum(_ value: String) -> Bool {
        value.count == 64 && value.allSatisfy { $0.isHexDigit && !$0.isUppercase }
    }

    private nonisolated static func availableStorage(at url: URL) -> Int64 {
        let path = FileManager.default.fileExists(atPath: url.path) ? url.path : NSTemporaryDirectory()
        let bytes = (try? FileManager.default.attributesOfFileSystem(forPath: path)[.systemFreeSize] as? NSNumber)?.int64Value
        return max(0, bytes ?? 0)
    }
}

public nonisolated struct CanvasPageCatalogLease: Sendable {
    fileprivate let id: UUID
    public let catalog: CanvasPageCatalog
}
