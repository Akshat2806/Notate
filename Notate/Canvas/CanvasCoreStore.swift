import CoreGraphics
import CryptoKit
import Foundation
import PaperKit

public struct CanvasPageSnapshot: Equatable, Sendable, Identifiable {
    public let id: UUID
    public let markup: PaperMarkup
    public let tables: [CanvasTable]
    public let viewport: CanvasViewportState
    public let paperTemplate: CanvasPaperTemplate
    public let geometry: CanvasPageGeometry
    public let background: CanvasPageBackground

    public init(
        id: UUID = UUID(),
        markup: PaperMarkup,
        tables: [CanvasTable] = [],
        viewport: CanvasViewportState = CanvasViewportState(),
        paperTemplate: CanvasPaperTemplate = .default,
        geometry: CanvasPageGeometry? = nil,
        background: CanvasPageBackground = .paper
    ) {
        let resolvedGeometry = geometry ?? CanvasPageGeometry(authoredSize: markup.bounds.size)
        self.id = id
        self.markup = markup
        self.tables = tables
        self.viewport = viewport
        self.paperTemplate = paperTemplate
        self.geometry = resolvedGeometry
        self.background = background
    }

    public var displaySize: CGSize { geometry.displaySize }

    /// PaperKit currently rotates node frames without rotating the nodes'
    /// private orientation state. Restrict quarter-turn page rotation to pages
    /// without editable annotations so text, ink, images, and tables can never
    /// be silently distorted.
    public var supportsLosslessQuarterTurn: Bool {
        let contentFrame = markup.contentsRenderFrame
        return tables.isEmpty && (contentFrame.isNull || contentFrame.isEmpty)
    }

    public func replacing(
        markup: PaperMarkup? = nil,
        tables: [CanvasTable]? = nil,
        viewport: CanvasViewportState? = nil,
        paperTemplate: CanvasPaperTemplate? = nil,
        geometry: CanvasPageGeometry? = nil,
        background: CanvasPageBackground? = nil
    ) -> CanvasPageSnapshot {
        CanvasPageSnapshot(
            id: id,
            markup: markup ?? self.markup,
            tables: tables ?? self.tables,
            viewport: viewport ?? self.viewport,
            paperTemplate: paperTemplate ?? self.paperTemplate,
            geometry: geometry ?? self.geometry,
            background: background ?? self.background
        )
    }
}

public struct CanvasCoreSnapshot: Equatable, Sendable {
    public let generation: Int64
    public let pages: [CanvasPageSnapshot]
    public let currentPageID: UUID

    public init(
        generation: Int64,
        pages: [CanvasPageSnapshot],
        currentPageID: UUID
    ) {
        self.generation = generation
        self.pages = pages
        self.currentPageID = currentPageID
    }

    /// Source-compatible convenience for the original single-page Canvas Core.
    public init(generation: Int64, markup: PaperMarkup) {
        let page = CanvasPageSnapshot(markup: markup)
        self.init(generation: generation, pages: [page], currentPageID: page.id)
    }

    public var currentPage: CanvasPageSnapshot? {
        pages.first { $0.id == currentPageID }
    }

    /// Source-compatible access for callers that have not yet adopted pages.
    public var markup: PaperMarkup {
        currentPage?.markup
            ?? pages.first?.markup
            ?? PaperMarkup(bounds: CGRect(origin: .zero, size: CanvasConstants.a4PortraitSize))
    }
}

/// The index-relevant difference between two snapshots that Canvas Core has
/// durably committed and verified. IDs keep document order so incremental
/// indexers can process a stable, deterministic work list.
public struct CanvasVerifiedIndexDelta: Equatable, Sendable {
    public let baseGeneration: Int64
    public let generation: Int64
    public let changedPageIDs: [UUID]
    public let removedPageIDs: [UUID]
    /// True whenever the complete page-ID sequence changes. Insertions and
    /// removals count because they also change persisted page numbers.
    public let pageOrderChanged: Bool

    public init(
        baseGeneration: Int64,
        generation: Int64,
        changedPageIDs: [UUID],
        removedPageIDs: [UUID],
        pageOrderChanged: Bool
    ) {
        self.baseGeneration = max(baseGeneration, 0)
        self.generation = max(generation, 0)
        self.changedPageIDs = changedPageIDs
        self.removedPageIDs = removedPageIDs
        self.pageOrderChanged = pageOrderChanged
    }
}

public enum CanvasCoreLoadResult: Equatable, Sendable {
    case newDocument
    case restored(CanvasCoreSnapshot)
    /// The caller's task ended before the read could finish. This is not a
    /// statement about whether either persisted checkpoint is valid.
    case cancelled
    case failed(CanvasCoreStoreError)
}

public enum CanvasCoreStoreError: Error, Equatable, LocalizedError, Sendable {
    case invalidSnapshot(String)
    case incompatibleMarkup
    case invalidEnvelope(String)
    case serializationFailed(String)
    case resourceLimitExceeded(String)
    case verificationFailed(String)
    case staleGeneration(attempted: Int64, latest: Int64)
    case staleCheckpointToken(attempted: UInt64, latest: UInt64)
    case unresolvedCorruption(current: String?, previous: String?)
    case fileSystem(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidSnapshot(reason):
            "The canvas checkpoint is invalid: \(reason)"
        case .incompatibleMarkup:
            "The canvas contains PaperKit features this version of Notate cannot edit."
        case let .invalidEnvelope(reason):
            "The canvas file is invalid: \(reason)"
        case let .serializationFailed(reason):
            "The canvas could not be serialized: \(reason)"
        case let .resourceLimitExceeded(reason):
            "The canvas exceeds a supported storage limit: \(reason)"
        case let .verificationFailed(reason):
            "The serialized canvas could not be verified: \(reason)"
        case let .staleGeneration(attempted, latest):
            "Canvas generation \(attempted) is stale; the latest generation is \(latest)."
        case let .staleCheckpointToken(attempted, latest):
            "Canvas checkpoint token \(attempted) is stale; the latest token is \(latest)."
        case let .unresolvedCorruption(current, previous):
            switch (current, previous) {
            case let (.some(current), .some(previous)):
                "Neither canvas checkpoint is valid. Current: \(current) Previous: \(previous)"
            case let (.some(current), .none):
                "The current canvas checkpoint is invalid: \(current)"
            case let (.none, .some(previous)):
                "The previous canvas checkpoint is invalid: \(previous)"
            case (.none, .none):
                "No valid canvas checkpoint could be recovered."
            }
        case let .fileSystem(reason):
            "The canvas files could not be accessed: \(reason)"
        }
    }

    var isTransientCheckpointFailure: Bool {
        switch self {
        case .serializationFailed, .fileSystem:
            true
        case .invalidSnapshot, .incompatibleMarkup, .invalidEnvelope,
             .resourceLimitExceeded, .verificationFailed,
             .staleGeneration, .staleCheckpointToken, .unresolvedCorruption:
            false
        }
    }

}

/// Async boundary around PaperKit's data representation. Tests can inject a
/// controlled implementation without teaching the store about PaperKit internals.
public protocol CanvasCoreMarkupCoding: Sendable {
    func encode(_ markup: PaperMarkup) async throws -> Data
    func decode(_ data: Data) async throws -> PaperMarkup
}

public struct PaperKitCanvasCoreCodec: CanvasCoreMarkupCoding, Sendable {
    public init() {}

    public func encode(_ markup: PaperMarkup) async throws -> Data {
        try await markup.dataRepresentation()
    }

    public func decode(_ data: Data) async throws -> PaperMarkup {
        try PaperMarkup(dataRepresentation: data)
    }
}

/// Narrow persistence seam used by the editor's autosave coordinator.
public protocol CanvasCoreCheckpointing: Sendable {
    func load() async -> CanvasCoreLoadResult
    func checkpoint(_ snapshot: CanvasCoreSnapshot) async throws
    func checkpointAndReturnVerifiedSnapshot(
        _ snapshot: CanvasCoreSnapshot
    ) async throws -> CanvasCoreSnapshot
}

public extension CanvasCoreCheckpointing {
    func checkpointAndReturnVerifiedSnapshot(
        _ snapshot: CanvasCoreSnapshot
    ) async throws -> CanvasCoreSnapshot {
        try await checkpoint(snapshot)
        return snapshot
    }
}

struct CanvasCoreResourceLimits: Equatable, Sendable {
    static let production = CanvasCoreResourceLimits(
        maximumPageCount: 1_000,
        maximumCheckpointEncodedByteCount: 128 * 1_024 * 1_024,
        maximumPageArchiveEncodedByteCount: 48 * 1_024 * 1_024,
        maximumMarkupByteCountPerPage: 32 * 1_024 * 1_024,
        maximumAggregateMarkupByteCount: 96 * 1_024 * 1_024,
        maximumImportedSourceByteCount: 128 * 1_024 * 1_024,
        maximumAggregateImportedSourceByteCount: 128 * 1_024 * 1_024,
        // The raw JSON envelope, its decoded PaperKit payloads, and imported
        // source bytes coexist while a checkpoint is verified or opened. Keep
        // their exact serialized sizes under one operation-wide admission budget
        // instead of treating individually valid maxima as simultaneously safe.
        maximumSerializedWorkingSetByteCount: 256 * 1_024 * 1_024,
        maximumUniqueImportedSourceCount: 64,
        maximumPersistedGeneration: Int64.max - 2
    )

    let maximumPageCount: Int
    let maximumCheckpointEncodedByteCount: Int
    let maximumPageArchiveEncodedByteCount: Int
    let maximumMarkupByteCountPerPage: Int
    let maximumAggregateMarkupByteCount: Int
    let maximumImportedSourceByteCount: Int
    let maximumAggregateImportedSourceByteCount: Int
    let maximumSerializedWorkingSetByteCount: Int
    let maximumUniqueImportedSourceCount: Int
    let maximumPersistedGeneration: Int64

    init(
        maximumPageCount: Int,
        maximumCheckpointEncodedByteCount: Int,
        maximumPageArchiveEncodedByteCount: Int,
        maximumMarkupByteCountPerPage: Int,
        maximumAggregateMarkupByteCount: Int,
        maximumImportedSourceByteCount: Int,
        maximumAggregateImportedSourceByteCount: Int,
        maximumSerializedWorkingSetByteCount: Int = 256 * 1_024 * 1_024,
        maximumUniqueImportedSourceCount: Int,
        maximumPersistedGeneration: Int64 = Int64.max - 2
    ) {
        precondition(maximumPageCount > 0)
        precondition(maximumCheckpointEncodedByteCount > 0)
        precondition(maximumPageArchiveEncodedByteCount > 0)
        precondition(maximumMarkupByteCountPerPage > 0)
        precondition(maximumAggregateMarkupByteCount >= maximumMarkupByteCountPerPage)
        precondition(maximumImportedSourceByteCount > 0)
        precondition(
            maximumAggregateImportedSourceByteCount >= maximumImportedSourceByteCount
        )
        precondition(maximumSerializedWorkingSetByteCount > 0)
        precondition(
            maximumSerializedWorkingSetByteCount >= maximumCheckpointEncodedByteCount
        )
        precondition(
            maximumSerializedWorkingSetByteCount >= maximumAggregateMarkupByteCount
        )
        precondition(
            maximumSerializedWorkingSetByteCount
                >= maximumAggregateImportedSourceByteCount
        )
        precondition(maximumUniqueImportedSourceCount > 0)
        precondition(maximumPersistedGeneration <= Int64.max - 2)
        precondition(maximumPersistedGeneration >= 0)
        self.maximumPageCount = maximumPageCount
        self.maximumCheckpointEncodedByteCount = maximumCheckpointEncodedByteCount
        self.maximumPageArchiveEncodedByteCount = maximumPageArchiveEncodedByteCount
        self.maximumMarkupByteCountPerPage = maximumMarkupByteCountPerPage
        self.maximumAggregateMarkupByteCount = maximumAggregateMarkupByteCount
        self.maximumImportedSourceByteCount = maximumImportedSourceByteCount
        self.maximumAggregateImportedSourceByteCount = maximumAggregateImportedSourceByteCount
        self.maximumSerializedWorkingSetByteCount = maximumSerializedWorkingSetByteCount
        self.maximumUniqueImportedSourceCount = maximumUniqueImportedSourceCount
        self.maximumPersistedGeneration = maximumPersistedGeneration
    }
}

/// Serializes the small publication/recovery critical section for every store
/// instance that resolves to the same on-disk root. Encoding and decoding stay
/// outside this gate; callers use an exact disk-state comparison after
/// acquiring it so work performed against an older head can be retried.
private actor CanvasCoreRootSerializationCoordinator {
    static let shared = CanvasCoreRootSerializationCoordinator()

    private var activeRoots: Set<String> = []
    private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]

    func acquire(_ rootKey: String) async {
        if activeRoots.insert(rootKey).inserted {
            return
        }
        await withCheckedContinuation { continuation in
            waiters[rootKey, default: []].append(continuation)
        }
    }

    func release(_ rootKey: String) {
        guard var queued = waiters[rootKey], queued.isEmpty == false else {
            activeRoots.remove(rootKey)
            waiters[rootKey] = nil
            return
        }
        let next = queued.removeFirst()
        waiters[rootKey] = queued.isEmpty ? nil : queued
        next.resume()
    }
}

private enum CanvasCoreRootSerialization {
    private static func canonicalKey(for rootURL: URL) -> String {
        rootURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    static func withExclusiveAccess<Result: Sendable>(
        to rootURL: URL,
        operation: @Sendable () async -> Result
    ) async -> Result {
        let rootKey = canonicalKey(for: rootURL)
        await CanvasCoreRootSerializationCoordinator.shared.acquire(rootKey)
        let result = await operation()
        await CanvasCoreRootSerializationCoordinator.shared.release(rootKey)
        return result
    }

    static func withExclusiveAccessThrowing<Result: Sendable>(
        to rootURL: URL,
        operation: @Sendable () async throws -> Result
    ) async throws -> Result {
        let rootKey = canonicalKey(for: rootURL)
        await CanvasCoreRootSerializationCoordinator.shared.acquire(rootKey)
        do {
            let result = try await operation()
            await CanvasCoreRootSerializationCoordinator.shared.release(rootKey)
            return result
        } catch {
            await CanvasCoreRootSerializationCoordinator.shared.release(rootKey)
            throw error
        }
    }
}

/// A checkpoint materializes imported source bytes before it publishes the
/// reference-only Canvas envelope. Garbage collection can run concurrently on
/// another `CanvasCoreStore` instance, so every in-flight checkpoint reserves
/// its paths before touching `Sources` and releases them only after publication
/// finishes or fails. Reservation insertion itself uses the root publication
/// gate, preventing a collector from taking a stale reservation snapshot while
/// a new writer starts.
struct CanvasCoreSourceReservation: Sendable {
    fileprivate let id: UUID
    fileprivate let rootKey: String
}

private actor CanvasCoreSourceReservationRegistry {
    static let shared = CanvasCoreSourceReservationRegistry()

    private struct Protection: Sendable {
        let paths: Set<String>
        let blocksCollection: Bool
    }

    private var reservations: [String: [UUID: Protection]] = [:]

    func reserve(
        _ paths: Set<String>,
        blocksCollection: Bool = false,
        id: UUID,
        rootKey: String
    ) {
        reservations[rootKey, default: [:]][id] = Protection(
            paths: paths,
            blocksCollection: blocksCollection
        )
    }

    func release(id: UUID, rootKey: String) {
        reservations[rootKey]?[id] = nil
        if reservations[rootKey]?.isEmpty == true {
            reservations[rootKey] = nil
        }
    }

    func protection(rootKey: String) -> (paths: Set<String>, blocksCollection: Bool) {
        let protections = reservations[rootKey, default: [:]].values
        return (
            Set(protections.flatMap(\.paths)),
            protections.contains(where: \.blocksCollection)
        )
    }
}

/// Crash-resilient storage for the ordered Canvas Core PaperKit document.
///
/// PaperKit remains the live source of truth. The store accepts immutable
/// snapshots, verifies their serialized form, and publishes only the newest
/// request into `current.canvas`, retaining the last verified revision in
/// `previous.canvas`.
public actor CanvasCoreStore: CanvasCoreCheckpointing {
    public static let liveDirectoryName = "CanvasCoreV2"

    /// PaperKit payload coding is CPU-heavy for large notebooks. A small bound
    /// shortens multi-page restores and checkpoints without allowing a large
    /// document to create an unbounded burst of memory or executor work.
    private static let maximumConcurrentPageCodecs = 2
    private static let envelopeVersion = 6
    private static let semanticTableEnvelopeVersion = 6
    private static let sourceReferencedEnvelopeVersion = 5
    private static let importedBackgroundEnvelopeVersion = 4
    private static let paperTemplateEnvelopeVersion = 3
    private static let multiPageEnvelopeVersion = 2
    private static let legacyEnvelopeVersion = 1
    private static let currentFileName = "current.canvas"
    private static let previousFileName = "previous.canvas"

    private let rootURL: URL
    private let codec: any CanvasCoreMarkupCoding
    private let resourceLimits: CanvasCoreResourceLimits

    private var newestRequestedGeneration: Int64?
    private var newestRequestToken: UInt64 = 0
    private var latestPublishedGeneration: Int64?
    private var publicationRevision: UInt64 = 0

    public init(
        rootURL: URL,
        codec: any CanvasCoreMarkupCoding = PaperKitCanvasCoreCodec()
    ) {
        self.init(
            rootURL: rootURL,
            codec: codec,
            resourceLimits: .production
        )
    }

    init(
        rootURL: URL,
        codec: any CanvasCoreMarkupCoding = PaperKitCanvasCoreCodec(),
        resourceLimits: CanvasCoreResourceLimits
    ) {
        self.rootURL = rootURL.standardizedFileURL
        self.codec = codec
        self.resourceLimits = resourceLimits
    }

    /// Encodes one page as a self-verifying payload for the library Trash.
    /// The archive deliberately uses the same PaperKit codec and page
    /// validation rules as a full Canvas Core checkpoint so a page is never
    /// removed from its document unless the restorable copy round-trips first.
    public nonisolated static func encodePageArchive(
        _ page: CanvasPageSnapshot,
        sourceRootURL: URL? = nil,
        codec: any CanvasCoreMarkupCoding = PaperKitCanvasCoreCodec()
    ) async throws -> Data {
        try validate(
            CanvasCoreSnapshot(generation: 1, pages: [page], currentPageID: page.id)
        )
        try materializeArchiveSourceIfNeeded(
            page.background,
            sourceRootURL: sourceRootURL
        )

        let markupData: Data
        do {
            markupData = try await codec.encode(page.markup)
            try validateStoredMarkupResourceLimits(
                [markupData],
                limits: .production,
                error: { CanvasCoreStoreError.serializationFailed($0) }
            )
            let decodedMarkup = try await codec.decode(markupData)
            try validateMarkup(decodedMarkup)
            guard decodedMarkup == page.markup else {
                throw CanvasCoreStoreError.verificationFailed(
                    "The deleted page changed during its validation round-trip."
                )
            }
        } catch let error as CanvasCoreStoreError {
            throw error
        } catch {
            throw CanvasCoreStoreError.serializationFailed(Self.describe(error))
        }

        let storedBackground: StoredCanvasPageBackgroundV5
        do {
            storedBackground = try makeStoredBackground(page.background)
        } catch let error as CanvasCoreStoreError {
            throw error
        } catch {
            throw CanvasCoreStoreError.serializationFailed(Self.describe(error))
        }
        let payload = CanvasPageArchivePayloadV3(
            formatVersion: CanvasPageArchiveEnvelopeV3.currentVersion,
            id: page.id,
            viewport: page.viewport,
            paperTemplate: page.paperTemplate,
            geometry: page.geometry,
            background: storedBackground,
            tables: page.tables,
            paperMarkupData: markupData
        )
        do {
            let envelope = CanvasPageArchiveEnvelopeV3(
                formatVersion: payload.formatVersion,
                id: payload.id,
                viewport: payload.viewport,
                paperTemplate: payload.paperTemplate,
                geometry: payload.geometry,
                background: payload.background,
                tables: payload.tables,
                paperMarkupData: payload.paperMarkupData,
                checksum: sha256(try encode(payload))
            )
            let data = try encode(envelope)
            guard data.count
                <= CanvasCoreResourceLimits.production
                    .maximumPageArchiveEncodedByteCount else {
                throw CanvasCoreStoreError.serializationFailed(
                    "The deleted-page archive exceeds the supported size limit."
                )
            }
            let verification = try JSONDecoder().decode(
                CanvasPageArchiveEnvelopeV3.self,
                from: data
            )
            guard verification == envelope else {
                throw CanvasCoreStoreError.verificationFailed(
                    "The deleted-page archive did not round-trip."
                )
            }
            return data
        } catch let error as CanvasCoreStoreError {
            throw error
        } catch {
            throw CanvasCoreStoreError.serializationFailed(Self.describe(error))
        }
    }

    /// Opens and verifies a page previously produced by
    /// `encodePageArchive(_:sourceRootURL:codec:)`.
    public nonisolated static func decodePageArchive(
        _ data: Data,
        sourceRootURL: URL? = nil,
        codec: any CanvasCoreMarkupCoding = PaperKitCanvasCoreCodec()
    ) async throws -> CanvasPageSnapshot {
        guard data.count
            <= CanvasCoreResourceLimits.production
                .maximumPageArchiveEncodedByteCount else {
            throw CanvasCoreStoreError.invalidEnvelope(
                "The deleted-page archive exceeds the supported size limit."
            )
        }
        let version: StoredVersionProbe
        do {
            version = try JSONDecoder().decode(StoredVersionProbe.self, from: data)
        } catch {
            throw CanvasCoreStoreError.invalidEnvelope(
                "The deleted-page archive could not be decoded."
            )
        }

        let id: UUID
        let viewport: CanvasViewportState
        let paperTemplate: CanvasPaperTemplate
        let geometry: CanvasPageGeometry
        let unresolvedBackground: CanvasPageBackground
        let tables: [CanvasTable]
        let paperMarkupData: Data
        switch version.formatVersion {
        case 1:
            let legacy: CanvasPageArchiveEnvelopeV1
            do {
                legacy = try JSONDecoder().decode(CanvasPageArchiveEnvelopeV1.self, from: data)
            } catch {
                throw CanvasCoreStoreError.invalidEnvelope(
                    "The version 1 deleted-page archive could not be decoded."
                )
            }
            id = legacy.id
            viewport = legacy.viewport
            paperTemplate = legacy.paperTemplate
            geometry = legacy.geometry
            unresolvedBackground = legacyBackground(legacy.background)
            tables = []
            paperMarkupData = legacy.paperMarkupData
        case 2:
            let envelope: CanvasPageArchiveEnvelopeV2
            do {
                envelope = try JSONDecoder().decode(CanvasPageArchiveEnvelopeV2.self, from: data)
            } catch {
                throw CanvasCoreStoreError.invalidEnvelope(
                    "The version 2 deleted-page archive could not be decoded."
                )
            }
            id = envelope.id
            viewport = envelope.viewport
            paperTemplate = envelope.paperTemplate
            geometry = envelope.geometry
            unresolvedBackground = runtimeBackground(envelope.background)
            tables = []
            paperMarkupData = envelope.paperMarkupData
        case CanvasPageArchiveEnvelopeV3.currentVersion:
            let envelope: CanvasPageArchiveEnvelopeV3
            do {
                envelope = try JSONDecoder().decode(CanvasPageArchiveEnvelopeV3.self, from: data)
            } catch {
                throw CanvasCoreStoreError.invalidEnvelope(
                    "The version 3 deleted-page archive could not be decoded."
                )
            }
            guard envelope.checksum.count == 64,
                envelope.checksum.allSatisfy({
                    $0.isHexDigit && $0.isUppercase == false
                }) else {
                throw CanvasCoreStoreError.invalidEnvelope(
                    "The deleted-page archive checksum is malformed."
                )
            }
            let payload = CanvasPageArchivePayloadV3(
                formatVersion: envelope.formatVersion,
                id: envelope.id,
                viewport: envelope.viewport,
                paperTemplate: envelope.paperTemplate,
                geometry: envelope.geometry,
                background: envelope.background,
                tables: envelope.tables,
                paperMarkupData: envelope.paperMarkupData
            )
            try validateChecksum(envelope.checksum, payload: payload)
            id = envelope.id
            viewport = envelope.viewport
            paperTemplate = envelope.paperTemplate
            geometry = envelope.geometry
            unresolvedBackground = runtimeBackground(envelope.background)
            tables = envelope.tables
            paperMarkupData = envelope.paperMarkupData
        default:
            throw CanvasCoreStoreError.invalidEnvelope(
                "Unsupported deleted-page archive version \(version.formatVersion)."
            )
        }

        try validateStoredMarkupResourceLimits(
            [paperMarkupData],
            limits: .production,
            error: { CanvasCoreStoreError.invalidEnvelope($0) }
        )

        let background = try hydrateArchiveBackground(
            unresolvedBackground,
            sourceRootURL: sourceRootURL
        )

        let markup: PaperMarkup
        do {
            markup = try await codec.decode(paperMarkupData)
        } catch {
            throw CanvasCoreStoreError.incompatibleMarkup
        }
        let page = CanvasPageSnapshot(
            id: id,
            markup: markup,
            tables: tables,
            viewport: viewport,
            paperTemplate: paperTemplate,
            geometry: geometry,
            background: background
        )
        try validate(
            CanvasCoreSnapshot(generation: 1, pages: [page], currentPageID: page.id)
        )
        return page
    }

    public nonisolated static func live(
        codec: any CanvasCoreMarkupCoding = PaperKitCanvasCoreCodec()
    ) throws -> CanvasCoreStore {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return CanvasCoreStore(
            rootURL: applicationSupport.appendingPathComponent(
                liveDirectoryName,
                isDirectory: true
            ),
            codec: codec
        )
    }

    public nonisolated static func live(
        itemID: UUID,
        codec: any CanvasCoreMarkupCoding = PaperKitCanvasCoreCodec()
    ) throws -> CanvasCoreStore {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let itemDirectory = applicationSupport
            .appendingPathComponent("NotateLibrary", isDirectory: true)
            .appendingPathComponent("Items", isDirectory: true)
            .appendingPathComponent(itemID.uuidString, isDirectory: true)
        return CanvasCoreStore(
            rootURL: itemDirectory.appendingPathComponent("Canvas", isDirectory: true),
            codec: codec
        )
    }

    public func load() async -> CanvasCoreLoadResult {
        do {
            try ensureRootDirectory()
        } catch {
            return .failed(.fileSystem(Self.describe(error)))
        }

        // A checkpoint may finish while slot decoding is suspended. Retry in
        // that case so recovery never promotes a snapshot read before the
        // newer publication.
        while true {
            let startingRevision = publicationRevision
            let inspection: SlotInspection
            do {
                inspection = try await inspectSlots()
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(.fileSystem(Self.describe(error)))
            }
            guard startingRevision == publicationRevision else { continue }
            guard Task.isCancelled == false else { return .cancelled }

            let finalization = await CanvasCoreRootSerialization.withExclusiveAccess(
                to: rootURL
            ) {
                await self.finalizeLoadIfDiskHeadIsUnchanged(inspection)
            }
            switch finalization {
            case .retry:
                continue
            case let .completed(result):
                return result
            }
        }
    }

    public func checkpoint(_ snapshot: CanvasCoreSnapshot) async throws {
        try Self.validate(snapshot, limits: resourceLimits)
        let requestToken = try beginRequest(for: snapshot.generation)
        try Task.checkCancellation()

        let reservationID = UUID()
        let rootKey = serializationRootKey
        let reservedPaths = Self.importedSourcePaths(in: snapshot.pages)
        await CanvasCoreRootSerialization.withExclusiveAccess(to: rootURL) {
            await CanvasCoreSourceReservationRegistry.shared.reserve(
                reservedPaths,
                id: reservationID,
                rootKey: rootKey
            )
        }

        do {
            try await checkpoint(
                snapshot,
                requestToken: requestToken
            )
            await CanvasCoreSourceReservationRegistry.shared.release(
                id: reservationID,
                rootKey: rootKey
            )
            _ = await reclaimOrphanedImportedSources()
        } catch {
            await CanvasCoreSourceReservationRegistry.shared.release(
                id: reservationID,
                rootKey: rootKey
            )
            throw error
        }
    }

    private func checkpoint(
        _ snapshot: CanvasCoreSnapshot,
        requestToken: UInt64
    ) async throws {
        let importedSourceByteCount: Int
        do {
            try ensureRootDirectory()
            importedSourceByteCount = try prepareImportedSources(for: snapshot.pages)
        } catch {
            if let error = error as? CanvasCoreStoreError { throw error }
            throw CanvasCoreStoreError.fileSystem(Self.describe(error))
        }

        try Task.checkCancellation()
        let envelopeData = try await encodeCheckpointEnvelope(
            snapshot,
            importedSourceByteCount: importedSourceByteCount,
            requestToken: requestToken
        )

        // Re-read both on-disk slots after all serialization suspension points.
        // Publication needs a fully verified recovery baseline, but it does not
        // need to retain that baseline's decoded PaperMarkup tree. Validate its
        // pages and sources sequentially and keep only the exact envelope bytes
        // needed for comparison/rotation.
        var inspection = try await inspectPublicationSlots()
        while true {
            try assertLatestRequest(generation: snapshot.generation, token: requestToken)
            let observedInspection = inspection
            let publication = try await CanvasCoreRootSerialization.withExclusiveAccessThrowing(
                to: rootURL
            ) {
                try await self.publishIfDiskHeadIsUnchanged(
                    snapshot,
                    envelopeData: envelopeData,
                    inspection: observedInspection,
                    requestToken: requestToken
                )
            }
            switch publication {
            case .published:
                return
            case .retry:
                inspection = try await inspectPublicationSlots()
            }
        }
    }

    /// Keeps encoded page payloads and the decoded envelope round-trip inside a
    /// narrow async scope. Once this returns, the caller retains only the final
    /// envelope rather than every page's duplicate serialized `Data` as it opens
    /// and validates the existing recovery baseline.
    private func encodeCheckpointEnvelope(
        _ snapshot: CanvasCoreSnapshot,
        importedSourceByteCount: Int,
        requestToken: UInt64
    ) async throws -> Data {
        let codec = self.codec
        let resourceLimits = self.resourceLimits
        var storedPageSlots = Array<StoredPageV6?>(
            repeating: nil,
            count: snapshot.pages.count
        )
        var admittedMarkupByteCount = 0
        try await withThrowingTaskGroup(of: (Int, StoredPageV6).self) { group in
            let initialCount = min(
                Self.maximumConcurrentPageCodecs,
                snapshot.pages.count
            )
            for index in 0..<initialCount {
                let page = snapshot.pages[index]
                group.addTask {
                    (
                        index,
                        try await Self.encodeAndVerify(
                            page,
                            codec: codec,
                            limits: resourceLimits
                        )
                    )
                }
            }
            var nextIndex = initialCount
        while let (index, storedPage) = try await group.next() {
            try assertLatestRequest(
                generation: snapshot.generation,
                token: requestToken
            )
            let (nextMarkupByteCount, overflowed) = admittedMarkupByteCount
                .addingReportingOverflow(storedPage.paperMarkupData.count)
            guard overflowed == false,
                nextMarkupByteCount
                    <= resourceLimits.maximumAggregateMarkupByteCount else {
                group.cancelAll()
                throw CanvasCoreStoreError.resourceLimitExceeded(
                    "The document exceeds the supported aggregate PaperKit size limit."
                )
            }
            admittedMarkupByteCount = nextMarkupByteCount
            storedPageSlots[index] = storedPage
            if nextIndex < snapshot.pages.count {
                let index = nextIndex
                let page = snapshot.pages[index]
                nextIndex += 1
                group.addTask {
                    (
                        index,
                        try await Self.encodeAndVerify(
                            page,
                            codec: codec,
                            limits: resourceLimits
                        )
                    )
                }
            }
        }
        }

        try assertLatestRequest(generation: snapshot.generation, token: requestToken)
        let storedPages = try storedPageSlots.map { storedPage in
            guard let storedPage else {
                throw CanvasCoreStoreError.serializationFailed(
                    "A page did not finish encoding."
                )
            }
            return storedPage
        }
        let markupByteCount = try Self.validateStoredMarkupResourceLimits(
            storedPages.map(\.paperMarkupData),
            limits: resourceLimits,
            error: { CanvasCoreStoreError.resourceLimitExceeded($0) }
        )
        guard markupByteCount == admittedMarkupByteCount else {
            throw CanvasCoreStoreError.verificationFailed(
                "The admitted PaperKit payload size changed during checkpoint encoding."
            )
        }

        let envelopeData: Data
        do {
            envelopeData = try Self.encodeEnvelope(
                generation: snapshot.generation,
                pages: storedPages,
                currentPageID: snapshot.currentPageID
            )
            guard envelopeData.count <= resourceLimits.maximumCheckpointEncodedByteCount else {
                throw CanvasCoreStoreError.resourceLimitExceeded(
                    "The encoded checkpoint exceeds the supported size limit."
                )
            }
            try Self.validateSerializedWorkingSet(
                checkpointByteCount: envelopeData.count,
                markupByteCount: markupByteCount,
                importedSourceByteCount: importedSourceByteCount,
                limits: resourceLimits,
                error: { CanvasCoreStoreError.resourceLimitExceeded($0) }
            )
            let verifiedEnvelope = try Self.decodeEnvelope(
                envelopeData,
                limits: resourceLimits
            )
            let expectedPages = storedPages.map { page in
                DecodedStoredPage(
                    id: page.id,
                    viewport: page.viewport,
                    paperTemplate: page.paperTemplate,
                    geometry: page.geometry,
                    background: Self.runtimeBackground(page.background),
                    tables: page.tables,
                    paperMarkupData: page.paperMarkupData
                )
            }
            guard verifiedEnvelope.generation == snapshot.generation,
                verifiedEnvelope.pages == expectedPages,
                verifiedEnvelope.currentPageID == snapshot.currentPageID else {
                throw CanvasCoreStoreError.verificationFailed(
                    "The encoded checkpoint did not round-trip."
                )
            }
        } catch let error as CanvasCoreStoreError {
            throw error
        } catch {
            throw CanvasCoreStoreError.verificationFailed(Self.describe(error))
        }
        return envelopeData
    }

    private func finalizeLoadIfDiskHeadIsUnchanged(
        _ inspection: SlotInspection
    ) -> LoadFinalization {
        guard Task.isCancelled == false else {
            return .completed(.cancelled)
        }
        let diskState = readDiskState()
        guard diskState.identity == inspection.diskIdentity else {
            return .retry
        }

        guard inspection.hasStoredFiles else {
            latestPublishedGeneration = nil
            return .completed(.newDocument)
        }
        guard let candidate = inspection.candidate else {
            return .completed(.failed(inspection.unresolvedCorruption))
        }

        if candidate.slot == .previous {
            guard Task.isCancelled == false else {
                return .completed(.cancelled)
            }
            do {
                guard let envelopeData = candidate.envelopeDataForPromotion else {
                    throw CanvasCoreStoreError.verificationFailed(
                        "The recovered checkpoint no longer has promotable bytes."
                    )
                }
                try envelopeData.write(to: currentURL, options: .atomic)
                try Self.verifyExactFileContents(
                    at: currentURL,
                    expectedData: envelopeData,
                    maximumByteCount: resourceLimits.maximumCheckpointEncodedByteCount,
                    description: "The promoted canvas checkpoint",
                    mismatchMessage: "The recovered checkpoint did not round-trip after promotion."
                )
                publicationRevision &+= 1
            } catch let error as CanvasCoreStoreError {
                return .completed(.failed(error))
            } catch {
                return .completed(.failed(.fileSystem(Self.describe(error))))
            }
        }

        latestPublishedGeneration = candidate.snapshot.generation
        newestRequestedGeneration = max(
            newestRequestedGeneration ?? candidate.snapshot.generation,
            candidate.snapshot.generation
        )
        return .completed(.restored(candidate.snapshot))
    }

    private func publishIfDiskHeadIsUnchanged(
        _ snapshot: CanvasCoreSnapshot,
        envelopeData: Data,
        inspection: PublicationSlotInspection,
        requestToken: UInt64
    ) throws -> CheckpointPublication {
        let diskState = readDiskState()
        guard diskState.identity == inspection.diskIdentity else {
            return .retry
        }

        try assertLatestRequest(generation: snapshot.generation, token: requestToken)
        let baseline: PublicationCandidate?
        if inspection.hasStoredFiles {
            guard let valid = inspection.candidate else {
                throw inspection.unresolvedCorruption
            }
            baseline = valid
            latestPublishedGeneration = valid.generation
            newestRequestedGeneration = max(
                newestRequestedGeneration ?? valid.generation,
                valid.generation
            )
        } else {
            baseline = nil
        }

        if let baseline {
            if snapshot.generation < baseline.generation {
                throw CanvasCoreStoreError.staleGeneration(
                    attempted: snapshot.generation,
                    latest: baseline.generation
                )
            }
            if snapshot.generation == baseline.generation {
                // A caller can lose the acknowledgement after current.canvas
                // was atomically published. Accept that replay only when the
                // complete, freshly verified envelope is byte-for-byte the
                // durable candidate; generation equality alone is not proof
                // that two snapshots describe the same checkpoint.
                guard envelopeData == baseline.envelopeData else {
                    throw CanvasCoreStoreError.staleGeneration(
                        attempted: snapshot.generation,
                        latest: baseline.generation
                    )
                }

                // The durable current slot already is the requested result,
                // so acknowledge it without rotating or rewriting either
                // slot. A matching previous candidate still flows through
                // publication below to repair and verify current.canvas.
                if baseline.slot == .current {
                    return .published
                }
            }
        }
        try assertLatestRequest(generation: snapshot.generation, token: requestToken)
        try Task.checkCancellation()

        do {
            // Never rotate unread or corrupt bytes into the recovery slot.
            if let baseline, baseline.slot == .current {
                try baseline.envelopeData.write(to: previousURL, options: .atomic)
                try Self.verifyExactFileContents(
                    at: previousURL,
                    expectedData: baseline.envelopeData,
                    maximumByteCount: resourceLimits.maximumCheckpointEncodedByteCount,
                    description: "The retained recovery checkpoint",
                    mismatchMessage: "The previous checkpoint did not round-trip after retention."
                )
            }
            try envelopeData.write(to: currentURL, options: .atomic)

            try Self.verifyExactFileContents(
                at: currentURL,
                expectedData: envelopeData,
                maximumByteCount: resourceLimits.maximumCheckpointEncodedByteCount,
                description: "The published canvas checkpoint",
                mismatchMessage: "The current checkpoint did not round-trip after publication."
            )
        } catch let error as CanvasCoreStoreError {
            throw error
        } catch {
            throw CanvasCoreStoreError.fileSystem(Self.describe(error))
        }

        latestPublishedGeneration = snapshot.generation
        publicationRevision &+= 1
        return .published
    }

    private var currentURL: URL {
        rootURL.appendingPathComponent(Self.currentFileName, isDirectory: false)
    }

    private var previousURL: URL {
        rootURL.appendingPathComponent(Self.previousFileName, isDirectory: false)
    }

    private func readDiskState() -> CanvasCoreRawDiskState {
        CanvasCoreRawDiskState(
            current: Self.readRawSlot(at: currentURL, limits: resourceLimits),
            previous: Self.readRawSlot(at: previousURL, limits: resourceLimits)
        )
    }

    private var sourcesRootURL: URL {
        rootURL.deletingLastPathComponent().appendingPathComponent(
            LibraryAssetCategory.sources.rawValue,
            isDirectory: true
        )
    }

    private var serializationRootKey: String {
        rootURL.standardizedFileURL.resolvingSymlinksInPath().path
    }

    /// Protects an imported source while a deleted-page archive is encoded and
    /// installed. The page may not exist in either committed checkpoint yet,
    /// so the reservation must precede source materialization.
    func reserveImportedSources(
        forArchivedPage page: CanvasPageSnapshot
    ) async -> CanvasCoreSourceReservation {
        let paths = Self.importedSourcePaths(in: [page])
        return await reserveImportedSources(paths: paths)
    }

    /// Protects every source referenced by an archive while its file is staged
    /// for permanent deletion and the catalog transaction is unresolved. A
    /// malformed archive blocks the whole sweep for this root; leaking until
    /// the transaction finishes is safer than breaking a rollback copy whose
    /// ownership cannot be proven.
    func reserveImportedSources(
        whileDeletingPageArchiveAt archiveURL: URL
    ) async -> CanvasCoreSourceReservation {
        let rootKey = serializationRootKey
        let reservationID = UUID()
        return await CanvasCoreRootSerialization.withExclusiveAccess(to: rootURL) {
            let paths: Set<String>
            let blocksCollection: Bool
            do {
                let data = try Self.readBoundedData(
                    at: archiveURL,
                    maximumByteCount: resourceLimits.maximumPageArchiveEncodedByteCount,
                    description: "The deleted-page archive"
                )
                let ownership = try Self.deletedPageArchiveOwnership(data)
                paths = Set(ownership.sourcePath.map { [$0] } ?? [])
                blocksCollection = false
            } catch {
                paths = []
                blocksCollection = true
            }
            await CanvasCoreSourceReservationRegistry.shared.reserve(
                paths,
                blocksCollection: blocksCollection,
                id: reservationID,
                rootKey: rootKey
            )
            return CanvasCoreSourceReservation(
                id: reservationID,
                rootKey: rootKey
            )
        }
    }

    func releaseImportedSourceReservation(
        _ reservation: CanvasCoreSourceReservation
    ) async {
        guard reservation.rootKey == serializationRootKey else { return }
        await CanvasCoreSourceReservationRegistry.shared.release(
            id: reservation.id,
            rootKey: reservation.rootKey
        )
    }

    private func reserveImportedSources(
        paths: Set<String>
    ) async -> CanvasCoreSourceReservation {
        let rootKey = serializationRootKey
        let reservationID = UUID()
        return await CanvasCoreRootSerialization.withExclusiveAccess(to: rootURL) {
            await CanvasCoreSourceReservationRegistry.shared.reserve(
                paths,
                id: reservationID,
                rootKey: rootKey
            )
            return CanvasCoreSourceReservation(
                id: reservationID,
                rootKey: rootKey
            )
        }
    }

    /// Best-effort garbage collection for app-owned imported image/PDF bytes.
    /// A file is eligible only when a verified current checkpoint exists and
    /// no verified recovery slot, deleted-page archive, or in-flight checkpoint
    /// references its exact item-relative path. Any ambiguous/corrupt metadata
    /// aborts the sweep and leaks safely instead of risking authored content.
    @discardableResult
    public func reclaimOrphanedImportedSources() async -> [String] {
        let rootKey = serializationRootKey
        return await CanvasCoreRootSerialization.withExclusiveAccess(to: rootURL) {
            let protection = await CanvasCoreSourceReservationRegistry.shared.protection(
                rootKey: rootKey
            )
            guard protection.blocksCollection == false else { return [] }
            return await self.reclaimOrphanedImportedSources(
                retaining: protection.paths
            )
        }
    }

    private func ensureRootDirectory() throws {
        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )
    }

    private struct PersistedOwnership {
        var sourcePaths: Set<String>
    }

private func persistedOwnership() throws -> PersistedOwnership {
    let diskState = readDiskState()
    guard case .present = diskState.current.identity else {
        throw CanvasCoreStoreError.invalidEnvelope(
            "A verified current checkpoint is required before source cleanup."
        )
    }

    var ownership = PersistedOwnership(
        sourcePaths: try persistedSourcePaths(at: currentURL)
    )

    if case .present = diskState.previous.identity {
        ownership.sourcePaths.formUnion(try persistedSourcePaths(at: previousURL))
    } else if case .inaccessible = diskState.previous.identity {
        throw CanvasCoreStoreError.invalidEnvelope(
            "The recovery checkpoint could not be inspected safely."
        )
    }

    let archiveURLs = try FileManager.default.contentsOfDirectory(
        at: rootURL,
        includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
        options: []
    ).filter { $0.pathExtension == "notate-page" }
    for archiveURL in archiveURLs {
        let values = try archiveURL.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
            values.isSymbolicLink != true else {
            throw CanvasCoreStoreError.invalidEnvelope(
                "A deleted-page archive is not a regular file."
            )
        }
        let archived = try Self.deletedPageArchiveOwnership(
            try Self.readBoundedData(
                at: archiveURL,
                maximumByteCount: resourceLimits.maximumPageArchiveEncodedByteCount,
                description: "The deleted-page archive"
            )
        )
        if let sourcePath = archived.sourcePath {
            ownership.sourcePaths.insert(sourcePath)
        }
    }
    return ownership
}

private func persistedSourcePaths(at url: URL) throws -> Set<String> {
    let data = try Self.readBoundedData(
        at: url,
        maximumByteCount: resourceLimits.maximumCheckpointEncodedByteCount,
        description: "The canvas checkpoint"
    )
    let envelope = try Self.decodeEnvelope(data, limits: resourceLimits)
    return Self.importedSourcePaths(in: envelope.pages)
}

private func reclaimOrphanedImportedSources(
    retaining reservedPaths: Set<String>
) -> [String] {
    guard var ownership = try? persistedOwnership() else { return [] }
    ownership.sourcePaths.formUnion(reservedPaths)

    let fileManager = FileManager.default
    guard fileManager.fileExists(atPath: sourcesRootURL.path) else { return [] }
    let itemRootURL = rootURL.deletingLastPathComponent()
    for directoryURL in [itemRootURL, sourcesRootURL] {
        guard let values = try? directoryURL.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]),
            values.isDirectory == true,
            values.isSymbolicLink != true else { return [] }
    }

    var enumerationFailed = false
    guard let enumerator = fileManager.enumerator(
        at: sourcesRootURL,
        includingPropertiesForKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ],
        options: [],
        errorHandler: { _, _ in
            enumerationFailed = true
            return false
        }
    ) else { return [] }

    let resolvedRoot = sourcesRootURL.resolvingSymlinksInPath()
    let rootPrefix = resolvedRoot.path.hasSuffix("/")
        ? resolvedRoot.path
        : resolvedRoot.path + "/"
    var candidates: [(relativePath: String, url: URL)] = []
    while let url = enumerator.nextObject() as? URL {
        guard let values = try? url.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]) else {
            enumerationFailed = true
            break
        }
        if values.isSymbolicLink == true {
            enumerationFailed = true
            break
        }
        guard values.isRegularFile == true else { continue }
        let resolved = url.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(rootPrefix) else {
            enumerationFailed = true
            break
        }
        let relativePath = String(resolved.path.dropFirst(rootPrefix.count))
        guard CanvasPDFSourceReference(relativePath: relativePath).isValid else {
            enumerationFailed = true
            break
        }
        if ownership.sourcePaths.contains(relativePath) == false {
            candidates.append((relativePath, url.standardizedFileURL))
        }
    }
    guard enumerationFailed == false else { return [] }

    var removed: [String] = []
    for candidate in candidates.sorted(by: {
        $0.relativePath < $1.relativePath
    }) {
        guard let values = try? candidate.url.resourceValues(forKeys: [
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ]),
            values.isRegularFile == true,
            values.isSymbolicLink != true,
            candidate.url.resolvingSymlinksInPath().path.hasPrefix(rootPrefix),
            sourcesRootURL.resolvingSymlinksInPath() == resolvedRoot else { continue }
        do {
            try fileManager.removeItem(at: candidate.url)
            removed.append(candidate.relativePath)
        } catch {
            // Derived cleanup is retryable. Leave a failed file in place
            // rather than making a verified checkpoint appear to fail
            // after its atomic publication has already committed.
        }
    }
    return removed
}

private nonisolated static func importedSourcePaths(
    in pages: [CanvasPageSnapshot]
) -> Set<String> {
    Set(pages.compactMap { importedSourcePath(in: $0.background) })
}

private nonisolated static func importedSourcePaths(
    in pages: [DecodedStoredPage]
) -> Set<String> {
    Set(pages.compactMap { importedSourcePath(in: $0.background) })
}

private nonisolated static func importedSourcePath(
    in background: CanvasPageBackground
) -> String? {
    switch background {
    case .paper:
        nil
    case let .image(source, _):
        source.relativePath
    case let .pdfPage(source, _, _):
        source.relativePath
    }
}

private nonisolated static func deletedPageArchiveOwnership(
    _ data: Data
) throws -> (pageID: UUID, sourcePath: String?) {
    let version: StoredVersionProbe
    do {
        version = try JSONDecoder().decode(StoredVersionProbe.self, from: data)
    } catch {
        throw CanvasCoreStoreError.invalidEnvelope(
            "A deleted-page archive could not be decoded."
        )
    }

    let pageID: UUID
    let background: CanvasPageBackground
    switch version.formatVersion {
    case 1:
        let archive = try JSONDecoder().decode(
            CanvasPageArchiveEnvelopeV1.self,
            from: data
        )
        pageID = archive.id
        // Version 1 archives embed imported bytes and do not depend on a
        // file in the item-scoped Sources directory.
        background = .paper
    case CanvasPageArchiveEnvelopeV2.currentVersion:
        let archive = try JSONDecoder().decode(
            CanvasPageArchiveEnvelopeV2.self,
            from: data
        )
        guard archive.background.isValid else {
            throw CanvasCoreStoreError.invalidEnvelope(
                "A deleted-page archive has an invalid source reference."
            )
        }
        pageID = archive.id
        background = runtimeBackground(archive.background)
    case CanvasPageArchiveEnvelopeV3.currentVersion:
        let archive = try JSONDecoder().decode(
            CanvasPageArchiveEnvelopeV3.self,
            from: data
        )
        guard archive.background.isValid else {
            throw CanvasCoreStoreError.invalidEnvelope(
                "A deleted-page archive has an invalid source reference."
            )
        }
        let payload = CanvasPageArchivePayloadV3(
            formatVersion: archive.formatVersion,
            id: archive.id,
            viewport: archive.viewport,
            paperTemplate: archive.paperTemplate,
            geometry: archive.geometry,
            background: archive.background,
            tables: archive.tables,
            paperMarkupData: archive.paperMarkupData
        )
        try validateChecksum(archive.checksum, payload: payload)
        pageID = archive.id
        background = runtimeBackground(archive.background)
    default:
        throw CanvasCoreStoreError.invalidEnvelope(
            "A deleted-page archive uses an unsupported version."
        )
    }
    return (pageID, importedSourcePath(in: background))
}

// Materializes each unique imported source before publishing a
// reference-only checkpoint. Import snapshots carry bytes transiently;
// subsequent saves verify the already-durable item-scoped source.
private func prepareImportedSources(for pages: [CanvasPageSnapshot]) throws -> Int {
    var fingerprintByPath: [String: String] = [:]
    var aggregateSourceByteCount = 0
    for page in pages {
        let relativePath: String
        let transientData: Data?
        let sourceDescription: String
        switch page.background {
        case .paper:
            continue
        case let .image(source, _):
            relativePath = source.relativePath
            transientData = source.imageData
            sourceDescription = "image"
        case let .pdfPage(source, _, _):
            relativePath = source.relativePath
            transientData = source.documentData
            sourceDescription = "PDF"
        }
        if let data = transientData {
            guard data.isEmpty == false else {
                throw CanvasCoreStoreError.invalidSnapshot(
                    "The \(sourceDescription) source \(relativePath) is empty."
                )
            }
            let fingerprint = Self.sha256(data)
            let expectedChecksum: String?
            switch page.background {
            case let .image(source, _): expectedChecksum = source.contentChecksum
            case let .pdfPage(source, _, _): expectedChecksum = source.contentChecksum
            case .paper: expectedChecksum = nil
            }
            guard expectedChecksum == nil || expectedChecksum == fingerprint else {
                throw CanvasCoreStoreError.verificationFailed(
                    "The imported source \(relativePath) failed checksum verification."
                )
            }
            if let preparedFingerprint = fingerprintByPath[relativePath] {
                guard preparedFingerprint == fingerprint else {
                    throw CanvasCoreStoreError.verificationFailed(
                        "Two imported sources use \(relativePath) with different contents."
                    )
                }
                continue
            }
            try Self.accumulateImportedSource(
                data,
                relativePath: relativePath,
                aggregateByteCount: &aggregateSourceByteCount,
                uniqueSourceCount: fingerprintByPath.count + 1,
                limits: resourceLimits,
                error: { CanvasCoreStoreError.invalidSnapshot($0) }
            )
            try Self.persistImportedSource(
                data,
                relativePath: relativePath,
                sourceRootURL: sourcesRootURL,
                limits: resourceLimits
            )
            fingerprintByPath[relativePath] = fingerprint
        } else {
            guard fingerprintByPath[relativePath] == nil else { continue }
            let existing = try Self.readImportedSource(
                relativePath: relativePath,
                sourceRootURL: sourcesRootURL,
                limits: resourceLimits
            )
            try Self.accumulateImportedSource(
                existing,
                relativePath: relativePath,
                aggregateByteCount: &aggregateSourceByteCount,
                uniqueSourceCount: fingerprintByPath.count + 1,
                limits: resourceLimits,
            error: { CanvasCoreStoreError.invalidSnapshot($0) }
        )
        fingerprintByPath[relativePath] = Self.sha256(existing)
        }
    }
    return aggregateSourceByteCount
}

// Resolves v5-or-later references and externalizes embedded v4 sources while
// opening a verified checkpoint. A per-path cache avoids repeated reads.
private func hydrateImportedSources(
    in pages: [DecodedStoredPage],
    checkpointByteCount: Int,
    markupByteCount: Int
) throws -> [DecodedStoredPage] {
    var dataByRelativePath: [String: Data] = [:]
    var aggregateSourceByteCount = 0
    var hydrated: [DecodedStoredPage] = []
    hydrated.reserveCapacity(pages.count)
    for page in pages {
        let background: CanvasPageBackground
        switch page.background {
        case .paper:
            background = .paper
        case let .image(source, suggestedName):
            let data = try resolvedImportedSourceData(
                relativePath: source.relativePath,
                embeddedData: source.imageData,
                expectedChecksum: source.contentChecksum,
                sourceDescription: "image",
                cache: &dataByRelativePath,
                aggregateSourceByteCount: &aggregateSourceByteCount,
                checkpointByteCount: checkpointByteCount,
                markupByteCount: markupByteCount
            )
            background = .image(
                source: source.resolving(imageData: data),
                suggestedName: suggestedName
            )
        case let .pdfPage(source, pageIndex, suggestedName):
            let data = try resolvedImportedSourceData(
                relativePath: source.relativePath,
                embeddedData: source.documentData,
                expectedChecksum: source.contentChecksum,
                sourceDescription: "PDF",
                cache: &dataByRelativePath,
                aggregateSourceByteCount: &aggregateSourceByteCount,
                checkpointByteCount: checkpointByteCount,
                markupByteCount: markupByteCount
            )
            background = .pdfPage(
                source: source.resolving(documentData: data),
                pageIndex: pageIndex,
                suggestedName: suggestedName
            )
        }
        hydrated.append(DecodedStoredPage(
            id: page.id,
            viewport: page.viewport,
            paperTemplate: page.paperTemplate,
            geometry: page.geometry,
            background: background,
            tables: page.tables,
            paperMarkupData: page.paperMarkupData
        ))
    }
    return hydrated
}

private func resolvedImportedSourceData(
    relativePath: String,
    embeddedData: Data?,
    expectedChecksum: String?,
    sourceDescription: String,
    cache: inout [String: Data],
    aggregateSourceByteCount: inout Int,
    checkpointByteCount: Int,
    markupByteCount: Int
) throws -> Data {
    if let cached = cache[relativePath] {
        guard expectedChecksum == nil || Self.sha256(cached) == expectedChecksum else {
            throw CanvasCoreStoreError.invalidEnvelope(
                "The \(sourceDescription) source failed checksum verification."
            )
        }
        return cached
    }
    if let embeddedData {
        guard embeddedData.isEmpty == false else {
            throw CanvasCoreStoreError.invalidEnvelope(
                "The embedded \(sourceDescription) source \(relativePath) is empty."
            )
        }
        try Self.accumulateImportedSource(
            embeddedData,
            relativePath: relativePath,
            aggregateByteCount: &aggregateSourceByteCount,
            uniqueSourceCount: cache.count + 1,
            limits: resourceLimits,
            error: { CanvasCoreStoreError.invalidEnvelope($0) }
        )
        try Self.validateSerializedWorkingSet(
            checkpointByteCount: checkpointByteCount,
            markupByteCount: markupByteCount,
            importedSourceByteCount: aggregateSourceByteCount,
            limits: resourceLimits,
            error: { CanvasCoreStoreError.invalidEnvelope($0) }
        )
        try Self.persistImportedSource(
            embeddedData,
            relativePath: relativePath,
            sourceRootURL: sourcesRootURL,
            limits: resourceLimits
        )
        guard expectedChecksum == nil || Self.sha256(embeddedData) == expectedChecksum else {
            throw CanvasCoreStoreError.invalidEnvelope(
                "The embedded \(sourceDescription) source failed checksum verification."
            )
        }
        cache[relativePath] = embeddedData
        return embeddedData
    }
    let loaded = try Self.readImportedSource(
        relativePath: relativePath,
        sourceRootURL: sourcesRootURL,
        limits: resourceLimits,
        maximumAllowedByteCount: Self.remainingSerializedWorkingSetByteCount(
            checkpointByteCount: checkpointByteCount,
            markupByteCount: markupByteCount,
            importedSourceByteCount: aggregateSourceByteCount,
            limits: resourceLimits
        )
    )
    try Self.accumulateImportedSource(
        loaded,
        relativePath: relativePath,
        aggregateByteCount: &aggregateSourceByteCount,
        uniqueSourceCount: cache.count + 1,
        limits: resourceLimits,
        error: { CanvasCoreStoreError.invalidEnvelope($0) }
    )
    try Self.validateSerializedWorkingSet(
        checkpointByteCount: checkpointByteCount,
        markupByteCount: markupByteCount,
        importedSourceByteCount: aggregateSourceByteCount,
        limits: resourceLimits,
        error: { CanvasCoreStoreError.invalidEnvelope($0) }
    )
    guard expectedChecksum == nil || Self.sha256(loaded) == expectedChecksum else {
        throw CanvasCoreStoreError.invalidEnvelope(
            "The \(sourceDescription) source failed checksum verification."
        )
    }
    cache[relativePath] = loaded
    return loaded
}

private func beginRequest(for generation: Int64) throws -> UInt64 {
    // Equality may be an exact replay whose original durability
    // acknowledgement was lost. The publication gate validates its full
    // encoded bytes against the verified disk candidate before accepting
    // it; strictly older generations remain stale here.
    if let latestPublishedGeneration, generation < latestPublishedGeneration {
        throw CanvasCoreStoreError.staleGeneration(
            attempted: generation,
            latest: latestPublishedGeneration
        )
    }
    if let newestRequestedGeneration, generation < newestRequestedGeneration {
        throw CanvasCoreStoreError.staleGeneration(
            attempted: generation,
            latest: newestRequestedGeneration
        )
    }

    newestRequestToken &+= 1
    newestRequestedGeneration = max(newestRequestedGeneration ?? generation, generation)
    return newestRequestToken
}

private func assertLatestRequest(generation: Int64, token: UInt64) throws {
    try Task.checkCancellation()
    let latestGeneration = newestRequestedGeneration ?? generation
    guard generation >= latestGeneration else {
        throw CanvasCoreStoreError.staleGeneration(
            attempted: generation,
            latest: latestGeneration
        )
    }
    guard token == newestRequestToken else {
        throw CanvasCoreStoreError.staleCheckpointToken(
            attempted: token,
            latest: newestRequestToken
        )
    }
}

private func inspectSlots() async throws -> SlotInspection {
    while true {
        let diskState = readDiskState()
        var currentFailure: String?
        var previousFailure: String?
        if case let .inaccessible(reason) = diskState.current.identity {
            currentFailure = reason
        }
        if case let .inaccessible(reason) = diskState.previous.identity {
            previousFailure = reason
        }

        let slots: [(slot: StoredSlot, url: URL, raw: CanvasCoreRawSlot)] = [
            (.current, currentURL, diskState.current),
            (.previous, previousURL, diskState.previous),
        ].filter { entry in
            if case .present = entry.raw.identity { return true }
            return false
        }.sorted { lhs, rhs in
            switch (lhs.raw.generation, rhs.raw.generation) {
            case let (.some(lhsGeneration), .some(rhsGeneration))
                where lhsGeneration != rhsGeneration:
                return lhsGeneration > rhsGeneration
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return lhs.slot == .current && rhs.slot == .previous
            }
        }

        var candidate: LoadedCandidate?
        var observedRace = false
        for entry in slots {
            try Task.checkCancellation()
            do {
                candidate = try await loadCandidate(
                    at: entry.url,
                    slot: entry.slot,
                    expectedIdentity: entry.raw.identity
                )
                // Generation probes let the newest plausible slot be fully
                // decoded first. Stop after the first verified candidate so
                // two hydrated PaperKit snapshots never coexist in memory.
                break
            } catch is CanvasCoreSlotReadRace {
                observedRace = true
                break
            } catch {
                if error is CancellationError { throw error }
                switch entry.slot {
                case .current: currentFailure = Self.describe(error)
                case .previous: previousFailure = Self.describe(error)
                }
            }
        }
        if observedRace { continue }

        return SlotInspection(
            hasStoredFiles: diskState.identity.hasStoredFiles,
            candidate: candidate,
            currentFailure: currentFailure,
            previousFailure: previousFailure,
            diskIdentity: diskState.identity
        )
    }
}

// Checkpoint publication needs proof that the current disk head is a valid
// recovery candidate, but retaining its complete runtime snapshot beside
// the new snapshot can approximately double the document's high-water
// memory. This inspection decodes one PaperKit page at a time and retains
// only the verified envelope bytes required by the atomic rotation.
private func inspectPublicationSlots() async throws -> PublicationSlotInspection {
    while true {
        let diskState = readDiskState()
        var currentFailure: String?
        var previousFailure: String?
        if case let .inaccessible(reason) = diskState.current.identity {
            currentFailure = reason
        }
        if case let .inaccessible(reason) = diskState.previous.identity {
            previousFailure = reason
        }

        let slots: [(slot: StoredSlot, url: URL, raw: CanvasCoreRawSlot)] = [
            (.current, currentURL, diskState.current),
            (.previous, previousURL, diskState.previous),
        ].filter { entry in
            if case .present = entry.raw.identity { return true }
            return false
        }.sorted { lhs, rhs in
            switch (lhs.raw.generation, rhs.raw.generation) {
            case let (.some(lhsGeneration), .some(rhsGeneration))
                where lhsGeneration != rhsGeneration:
                return lhsGeneration > rhsGeneration
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            default:
                return lhs.slot == .current && rhs.slot == .previous
            }
        }

        var candidate: PublicationCandidate?
        var observedRace = false
        for entry in slots {
            try Task.checkCancellation()
            do {
                candidate = try await validatePublicationCandidate(
                    at: entry.url,
                    slot: entry.slot,
                    expectedIdentity: entry.raw.identity
                )
                break
            } catch is CanvasCoreSlotReadRace {
                observedRace = true
                break
            } catch {
                if error is CancellationError { throw error }
                switch entry.slot {
                case .current: currentFailure = Self.describe(error)
                case .previous: previousFailure = Self.describe(error)
                }
            }
        }
        if observedRace { continue }

        return PublicationSlotInspection(
            hasStoredFiles: diskState.identity.hasStoredFiles,
            candidate: candidate,
            currentFailure: currentFailure,
            previousFailure: previousFailure,
            diskIdentity: diskState.identity
        )
    }
}

private func validatePublicationCandidate(
    at url: URL,
    slot: StoredSlot,
    expectedIdentity: CanvasCoreDiskSlotIdentity
) async throws -> PublicationCandidate {
    let envelopeData = try Self.readBoundedData(
        at: url,
        maximumByteCount: resourceLimits.maximumCheckpointEncodedByteCount,
        description: "The canvas checkpoint"
    )

    let observedIdentity = CanvasCoreDiskSlotIdentity.present(
        byteCount: envelopeData.count,
        digest: Self.sha256(envelopeData)
    )
    guard observedIdentity == expectedIdentity else {
        throw CanvasCoreSlotReadRace.changed
    }

    let envelope = try Self.decodeEnvelope(envelopeData, limits: resourceLimits)
    let markupByteCount = try Self.validateStoredMarkupResourceLimits(
        envelope.pages.map(\.paperMarkupData),
        limits: resourceLimits,
        error: { CanvasCoreStoreError.invalidEnvelope($0) }
    )
    try Self.validateSerializedWorkingSet(
        checkpointByteCount: envelopeData.count,
        markupByteCount: markupByteCount,
        importedSourceByteCount: 0,
        limits: resourceLimits,
        error: { CanvasCoreStoreError.invalidEnvelope($0) }
    )
    try validatePublicationImportedSources(
        in: envelope.pages,
        checkpointByteCount: envelopeData.count,
        markupByteCount: markupByteCount
    )

    for page in envelope.pages {
        try Task.checkCancellation()
        let markup: PaperMarkup
        do {
            markup = try await codec.decode(page.paperMarkupData)
        } catch {
            if error is CancellationError { throw error }
            throw CanvasCoreStoreError.invalidEnvelope(
                "Page \(page.id.uuidString) could not be decoded: \(Self.describe(error))"
            )
        }
        do {
            try Self.validateMarkup(markup)
            guard markup.bounds.size == page.geometry.displaySize else {
                throw CanvasCoreStoreError.invalidSnapshot(
                    "Paper bounds do not match the stored page geometry."
                )
            }
        } catch {
            throw CanvasCoreStoreError.invalidEnvelope(
                "Page \(page.id.uuidString): \(Self.describe(error))"
            )
        }
    }

    return PublicationCandidate(
        slot: slot,
        generation: envelope.generation,
        envelopeData: envelopeData
    )
}

// Verifies source availability/checksums one unique path at a time. Only a
// compact path-to-digest map survives each iteration; source `Data` does not
// accumulate merely to prove that an older checkpoint is recoverable.
private func validatePublicationImportedSources(
    in pages: [DecodedStoredPage],
    checkpointByteCount: Int,
    markupByteCount: Int
) throws {
    var fingerprintByPath: [String: String] = [:]
    var aggregateSourceByteCount = 0

    for page in pages {
        let relativePath: String
        let embeddedData: Data?
        let expectedChecksum: String?
        let sourceDescription: String
        switch page.background {
        case .paper:
            continue
        case let .image(source, _):
            relativePath = source.relativePath
            embeddedData = source.imageData
            expectedChecksum = source.contentChecksum
            sourceDescription = "image"
        case let .pdfPage(source, _, _):
            relativePath = source.relativePath
            embeddedData = source.documentData
            expectedChecksum = source.contentChecksum
            sourceDescription = "PDF"
        }

        if let fingerprint = fingerprintByPath[relativePath] {
            guard expectedChecksum == nil || expectedChecksum == fingerprint else {
                throw CanvasCoreStoreError.invalidEnvelope(
                    "The \(sourceDescription) source failed checksum verification."
                )
            }
            continue
        }

        let data: Data
        if let embeddedData {
            data = embeddedData
        } else {
            data = try Self.readImportedSource(
                relativePath: relativePath,
                sourceRootURL: sourcesRootURL,
                limits: resourceLimits,
                maximumAllowedByteCount: Self.remainingSerializedWorkingSetByteCount(
                    checkpointByteCount: checkpointByteCount,
                    markupByteCount: markupByteCount,
                    importedSourceByteCount: aggregateSourceByteCount,
                    limits: resourceLimits
                )
            )
        }
        try Self.accumulateImportedSource(
            data,
            relativePath: relativePath,
            aggregateByteCount: &aggregateSourceByteCount,
            uniqueSourceCount: fingerprintByPath.count + 1,
            limits: resourceLimits,
            error: { CanvasCoreStoreError.invalidEnvelope($0) }
        )
        try Self.validateSerializedWorkingSet(
            checkpointByteCount: checkpointByteCount,
            markupByteCount: markupByteCount,
            importedSourceByteCount: aggregateSourceByteCount,
            limits: resourceLimits,
            error: { CanvasCoreStoreError.invalidEnvelope($0) }
        )
        let fingerprint = Self.sha256(data)
        guard expectedChecksum == nil || expectedChecksum == fingerprint else {
            throw CanvasCoreStoreError.invalidEnvelope(
                "The \(sourceDescription) source failed checksum verification."
            )
        }
        if embeddedData != nil {
            try Self.persistImportedSource(
                data,
                relativePath: relativePath,
                sourceRootURL: sourcesRootURL,
                limits: resourceLimits
            )
        }
        fingerprintByPath[relativePath] = fingerprint
    }
}

private func loadCandidate(
    at url: URL,
    slot: StoredSlot,
    expectedIdentity: CanvasCoreDiskSlotIdentity
) async throws -> LoadedCandidate {
    let envelopeData = try Self.readBoundedData(
        at: url,
        maximumByteCount: resourceLimits.maximumCheckpointEncodedByteCount,
        description: "The canvas checkpoint"
    )

    let observedIdentity = CanvasCoreDiskSlotIdentity.present(
        byteCount: envelopeData.count,
        digest: Self.sha256(envelopeData)
    )
    guard observedIdentity == expectedIdentity else {
        throw CanvasCoreSlotReadRace.changed
    }
    let envelope = try Self.decodeEnvelope(envelopeData, limits: resourceLimits)
    let markupByteCount = try Self.validateStoredMarkupResourceLimits(
        envelope.pages.map(\.paperMarkupData),
        limits: resourceLimits,
        error: { CanvasCoreStoreError.invalidEnvelope($0) }
    )
    try Self.validateSerializedWorkingSet(
        checkpointByteCount: envelopeData.count,
        markupByteCount: markupByteCount,
        importedSourceByteCount: 0,
        limits: resourceLimits,
        error: { CanvasCoreStoreError.invalidEnvelope($0) }
    )
    let hydratedPages = try hydrateImportedSources(
        in: envelope.pages,
        checkpointByteCount: envelopeData.count,
        markupByteCount: markupByteCount
    )
    let pages = try await Self.decodePages(hydratedPages, codec: codec)

    let snapshot = CanvasCoreSnapshot(
        generation: envelope.generation,
        pages: pages,
        currentPageID: envelope.currentPageID
    )
    do {
        try Self.validate(snapshot, limits: resourceLimits)
    } catch {
        throw CanvasCoreStoreError.invalidEnvelope(Self.describe(error))
    }
    return LoadedCandidate(
        slot: slot,
        snapshot: snapshot,
        envelopeDataForPromotion: slot == .previous ? envelopeData : nil
    )
}

private nonisolated static func readRawSlot(
    at url: URL,
    limits: CanvasCoreResourceLimits
) -> CanvasCoreRawSlot {
    guard FileManager.default.fileExists(atPath: url.path) else {
        return CanvasCoreRawSlot(identity: .missing, generation: nil)
    }
    do {
        // Mapping bounds virtual address space: only the bytes touched by
        // hashing/JSON probing need become resident, and the mapped data is
        // released before the other slot is inspected.
        let data = try readBoundedData(
            at: url,
            maximumByteCount: limits.maximumCheckpointEncodedByteCount,
            description: "The canvas checkpoint"
        )
        return CanvasCoreRawSlot(
            identity: .present(byteCount: data.count, digest: sha256(data)),
            generation: try? JSONDecoder().decode(
                StoredGenerationProbe.self,
                from: data
            ).generation
        )
    } catch {
        return CanvasCoreRawSlot(
            identity: .inaccessible(describe(error)),
            generation: nil
        )
    }
}

private nonisolated static func encodeAndVerify(
    _ page: CanvasPageSnapshot,
    codec: any CanvasCoreMarkupCoding,
    limits: CanvasCoreResourceLimits
) async throws -> StoredPageV6 {
    let markupData: Data
    do {
        markupData = try await codec.encode(page.markup)
    } catch {
        if error is CancellationError { throw error }
        throw CanvasCoreStoreError.serializationFailed(
            "Page \(page.id.uuidString): \(Self.describe(error))"
        )
    }
    try Task.checkCancellation()
    guard markupData.isEmpty == false else {
        throw CanvasCoreStoreError.verificationFailed(
            "PaperKit produced an empty payload for page \(page.id.uuidString)."
        )
    }
    guard markupData.count <= limits.maximumMarkupByteCountPerPage else {
        throw CanvasCoreStoreError.resourceLimitExceeded(
            "Page \(page.id.uuidString) exceeds the supported PaperKit payload limit."
        )
    }

    do {
        let decodedMarkup = try await codec.decode(markupData)
        try Self.validateMarkup(decodedMarkup)
        guard decodedMarkup == page.markup else {
            throw CanvasCoreStoreError.verificationFailed(
                "Page \(page.id.uuidString) changed during its validation round-trip."
            )
        }
    } catch {
        if error is CancellationError { throw error }
        if let error = error as? CanvasCoreStoreError { throw error }
        throw CanvasCoreStoreError.verificationFailed(
            "Page \(page.id.uuidString): \(Self.describe(error))"
        )
    }
    try Task.checkCancellation()
    return StoredPageV6(
        id: page.id,
        viewport: page.viewport,
        paperTemplate: page.paperTemplate,
        geometry: page.geometry,
        background: try Self.makeStoredBackground(page.background),
        tables: page.tables,
        paperMarkupData: markupData
    )
}

private nonisolated static func decodePages(
    _ storedPages: [DecodedStoredPage],
    codec: any CanvasCoreMarkupCoding
) async throws -> [CanvasPageSnapshot] {
    var pageSlots = Array<CanvasPageSnapshot?>(
        repeating: nil,
        count: storedPages.count
    )
    try await withThrowingTaskGroup(of: (Int, CanvasPageSnapshot).self) { group in
        let initialCount = min(maximumConcurrentPageCodecs, storedPages.count)
        for index in 0..<initialCount {
            let storedPage = storedPages[index]
            group.addTask {
                (index, try await decodePage(storedPage, codec: codec))
            }
        }

        var nextIndex = initialCount
        while let (index, page) = try await group.next() {
            pageSlots[index] = page
            if nextIndex < storedPages.count {
                let index = nextIndex
                let storedPage = storedPages[index]
                nextIndex += 1
                group.addTask {
                    (index, try await decodePage(storedPage, codec: codec))
                }
            }
        }
    }

    return try pageSlots.map { page in
        guard let page else {
            throw CanvasCoreStoreError.invalidEnvelope(
                "A page did not finish decoding."
            )
        }
        return page
    }
}

private nonisolated static func decodePage(
    _ storedPage: DecodedStoredPage,
    codec: any CanvasCoreMarkupCoding
) async throws -> CanvasPageSnapshot {
    let markup: PaperMarkup
    do {
        markup = try await codec.decode(storedPage.paperMarkupData)
    } catch {
        if error is CancellationError { throw error }
        throw CanvasCoreStoreError.invalidEnvelope(
            "Page \(storedPage.id.uuidString) could not be decoded: \(Self.describe(error))"
        )
    }
    try Task.checkCancellation()
    do {
        try Self.validateMarkup(markup)
    } catch {
        throw CanvasCoreStoreError.invalidEnvelope(
            "Page \(storedPage.id.uuidString): \(Self.describe(error))"
        )
    }
    return CanvasPageSnapshot(
        id: storedPage.id,
        markup: markup,
        tables: storedPage.tables,
        viewport: storedPage.viewport,
        paperTemplate: storedPage.paperTemplate,
        geometry: storedPage.geometry,
        background: storedPage.background
    )
}

private nonisolated static func makeStoredBackground(
    _ background: CanvasPageBackground
) throws -> StoredCanvasPageBackgroundV5 {
    switch background {
    case .paper:
        return .paper
    case let .image(source, suggestedName):
        guard source.isValid, source.imageData?.isEmpty != true else {
            throw CanvasCoreStoreError.invalidSnapshot(
                "An imported image has an invalid source reference."
            )
        }
        guard let sourceChecksum = source.imageData.map(sha256)
            ?? source.contentChecksum else {
            throw CanvasCoreStoreError.invalidSnapshot(
                "The imported image source has no verified checksum."
            )
        }
        return .image(
            sourceRelativePath: source.relativePath,
            sourceChecksum: sourceChecksum,
            suggestedName: suggestedName
        )
    case let .pdfPage(source, pageIndex, suggestedName):
        guard source.isValid, pageIndex >= 0 else {
            throw CanvasCoreStoreError.invalidSnapshot(
                "An imported PDF page has an invalid source reference."
            )
        }
        guard let sourceChecksum = source.documentData.map(sha256)
            ?? source.contentChecksum else {
            throw CanvasCoreStoreError.invalidSnapshot(
                "The imported PDF source has no verified checksum."
            )
        }
        return .pdfPage(
            sourceRelativePath: source.relativePath,
            sourceChecksum: sourceChecksum,
            pageIndex: pageIndex,
            suggestedName: suggestedName
        )
    }
}

private nonisolated static func runtimeBackground(
    _ background: StoredCanvasPageBackgroundV5
) -> CanvasPageBackground {
    switch background {
    case .paper:
        .paper
    case let .image(sourceRelativePath, sourceChecksum, suggestedName):
        .image(
            source: CanvasImageSourceReference(
                relativePath: sourceRelativePath,
                contentChecksum: sourceChecksum
            ),
            suggestedName: suggestedName
        )
    case let .pdfPage(sourceRelativePath, sourceChecksum, pageIndex, suggestedName):
        .pdfPage(
            source: CanvasPDFSourceReference(
                relativePath: sourceRelativePath,
                contentChecksum: sourceChecksum
            ),
            pageIndex: pageIndex,
            suggestedName: suggestedName
        )
    }
}

private nonisolated static func legacyBackground(
    _ background: LegacyCanvasPageBackgroundV4
) -> CanvasPageBackground {
    switch background {
    case .paper:
        .paper
    case let .image(data, suggestedName):
        .image(
            source: CanvasImageSourceReference(
                relativePath: legacyImageSourcePath(
                    data,
                    suggestedName: suggestedName
                ),
                imageData: data,
                contentChecksum: sha256(data)
            ),
            suggestedName: suggestedName
        )
    case let .pdfPage(documentData, pageIndex, suggestedName):
        .pdfPage(
            source: CanvasPDFSourceReference(
                relativePath: "legacy-pdf-\(sha256(documentData)).pdf",
                documentData: documentData,
                contentChecksum: sha256(documentData)
            ),
            pageIndex: pageIndex,
            suggestedName: suggestedName
        )
    }
}

private nonisolated static func materializeArchiveSourceIfNeeded(
    _ background: CanvasPageBackground,
    sourceRootURL: URL?
) throws {
    let relativePath: String
    let transientData: Data?
    let expectedChecksum: String?
    switch background {
    case .paper:
        return
    case let .image(source, _):
        relativePath = source.relativePath
        transientData = source.imageData
        expectedChecksum = source.contentChecksum
    case let .pdfPage(source, _, _):
        relativePath = source.relativePath
        transientData = source.documentData
        expectedChecksum = source.contentChecksum
    }
    guard let sourceRootURL else {
        throw CanvasCoreStoreError.invalidSnapshot(
            "Imported pages require their item-scoped Sources directory before archival."
        )
    }
    if let transientData {
        guard expectedChecksum == nil || sha256(transientData) == expectedChecksum else {
            throw CanvasCoreStoreError.verificationFailed(
                "The imported page source failed checksum verification."
            )
        }
        try persistImportedSource(
            transientData,
            relativePath: relativePath,
            sourceRootURL: sourceRootURL
        )
    } else {
        let storedData = try readImportedSource(
            relativePath: relativePath,
            sourceRootURL: sourceRootURL
        )
        guard expectedChecksum == nil || sha256(storedData) == expectedChecksum else {
            throw CanvasCoreStoreError.verificationFailed(
                "The imported page source failed checksum verification."
            )
        }
    }
}

private nonisolated static func hydrateArchiveBackground(
    _ background: CanvasPageBackground,
    sourceRootURL: URL?
) throws -> CanvasPageBackground {
    switch background {
    case .paper:
        return .paper
    case let .image(source, suggestedName):
        if let imageData = source.imageData {
            guard source.contentChecksum == nil
                || sha256(imageData) == source.contentChecksum else {
                throw CanvasCoreStoreError.invalidEnvelope(
                    "The archived image source failed checksum verification."
                )
            }
            if let sourceRootURL {
                try persistImportedSource(
                    imageData,
                    relativePath: source.relativePath,
                    sourceRootURL: sourceRootURL
                )
            }
            return background
        }
        guard let sourceRootURL else {
            throw CanvasCoreStoreError.invalidEnvelope(
                "The archived image page requires its item-scoped Sources directory."
            )
        }
        let imageData = try readImportedSource(
            relativePath: source.relativePath,
            sourceRootURL: sourceRootURL
        )
        guard source.contentChecksum == nil
            || sha256(imageData) == source.contentChecksum else {
            throw CanvasCoreStoreError.invalidEnvelope(
                "The archived image source failed checksum verification."
            )
        }
        return .image(
            source: source.resolving(imageData: imageData),
            suggestedName: suggestedName
        )
    case let .pdfPage(source, pageIndex, suggestedName):
        if let documentData = source.documentData {
            guard source.contentChecksum == nil
                || sha256(documentData) == source.contentChecksum else {
                throw CanvasCoreStoreError.invalidEnvelope(
                    "The archived PDF source failed checksum verification."
                )
            }
            if let sourceRootURL {
                try persistImportedSource(
                    documentData,
                    relativePath: source.relativePath,
                    sourceRootURL: sourceRootURL
                )
            }
            return background
        }
        guard let sourceRootURL else {
            throw CanvasCoreStoreError.invalidEnvelope(
                "The archived PDF page requires its item-scoped Sources directory."
            )
        }
        let documentData = try readImportedSource(
            relativePath: source.relativePath,
            sourceRootURL: sourceRootURL
        )
        guard source.contentChecksum == nil
            || sha256(documentData) == source.contentChecksum else {
            throw CanvasCoreStoreError.invalidEnvelope(
                "The archived PDF source failed checksum verification."
            )
        }
        return .pdfPage(
            source: source.resolving(documentData: documentData),
            pageIndex: pageIndex,
            suggestedName: suggestedName
        )
    }
}

private nonisolated static func persistImportedSource(
    _ data: Data,
    relativePath: String,
    sourceRootURL: URL,
    limits: CanvasCoreResourceLimits = .production
) throws {
    guard data.isEmpty == false,
        data.count <= limits.maximumImportedSourceByteCount else {
        throw CanvasCoreStoreError.invalidEnvelope(
            "The imported source \(relativePath) exceeds the supported size limit."
        )
    }
    let destination = try importedSourceURL(
        relativePath: relativePath,
        sourceRootURL: sourceRootURL
    )
    do {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
            if FileManager.default.fileExists(atPath: destination.path) {
                let existing = try readBoundedData(
                    at: destination,
                    maximumByteCount: limits.maximumImportedSourceByteCount,
                    description: "The imported source \(relativePath)"
                )
                guard existing == data else {
                    throw CanvasCoreStoreError.verificationFailed(
                        "The imported source \(relativePath) conflicts with the existing item asset."
                    )
                }
                return
            }
            try data.write(to: destination, options: .atomic)
            let verified = try readBoundedData(
                at: destination,
                maximumByteCount: limits.maximumImportedSourceByteCount,
                description: "The imported source \(relativePath)"
            )
            guard verified == data else {
                throw CanvasCoreStoreError.verificationFailed(
                    "The imported source \(relativePath) did not round-trip."
                )
            }
        } catch let error as CanvasCoreStoreError {
            throw error
        } catch {
            throw CanvasCoreStoreError.fileSystem(describe(error))
        }
    }

    private nonisolated static func readImportedSource(
        relativePath: String,
        sourceRootURL: URL,
        limits: CanvasCoreResourceLimits = .production,
        maximumAllowedByteCount: Int? = nil
    ) throws -> Data {
        let sourceURL = try importedSourceURL(
            relativePath: relativePath,
            sourceRootURL: sourceRootURL
        )
        do {
            let data = try readBoundedData(
                at: sourceURL,
                maximumByteCount: min(
                    limits.maximumImportedSourceByteCount,
                    maximumAllowedByteCount ?? limits.maximumImportedSourceByteCount
                ),
                description: "The imported source \(relativePath)"
            )
            guard data.isEmpty == false else {
                throw CanvasCoreStoreError.invalidEnvelope(
                    "The imported source \(relativePath) is empty."
                )
            }
            return data
        } catch let error as CanvasCoreStoreError {
            throw error
        } catch {
            throw CanvasCoreStoreError.invalidEnvelope(
                "The imported source \(relativePath) could not be read: \(describe(error))"
            )
        }
    }

    private nonisolated static func accumulateImportedSource<Failure: Error>(
        _ data: Data,
        relativePath: String,
        aggregateByteCount: inout Int,
        uniqueSourceCount: Int,
        limits: CanvasCoreResourceLimits,
        error: (String) -> Failure
    ) throws {
        guard data.isEmpty == false else {
            throw error("The imported source \(relativePath) is empty.")
        }
        guard data.count <= limits.maximumImportedSourceByteCount else {
            throw error(
                "The imported source \(relativePath) exceeds the supported per-source size limit."
            )
        }
        guard uniqueSourceCount <= limits.maximumUniqueImportedSourceCount else {
            throw error(
                "The document exceeds the supported imported-source count limit."
            )
        }
        let (nextByteCount, overflow) = aggregateByteCount.addingReportingOverflow(data.count)
        guard overflow == false,
            nextByteCount <= limits.maximumAggregateImportedSourceByteCount else {
            throw error(
                "The document exceeds the supported aggregate imported-source size limit."
            )
        }
        aggregateByteCount = nextByteCount
    }

    private nonisolated static func readBoundedData(
        at url: URL,
        maximumByteCount: Int,
        description: String
    ) throws -> Data {
        let values = try url.resourceValues(forKeys: [
            .isRegularFileKey,
            .fileSizeKey,
        ])
        guard values.isRegularFile == true else {
            throw CanvasCoreStoreError.invalidEnvelope(
                "\(description) is not a regular file."
            )
        }
        if let advertisedByteCount = values.fileSize {
            guard advertisedByteCount >= 0,
                  advertisedByteCount <= maximumByteCount else {
                throw CanvasCoreStoreError.invalidEnvelope(
                    "\(description) exceeds the supported size limit."
                )
            }
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumByteCount else {
            throw CanvasCoreStoreError.invalidEnvelope(
                "\(description) exceeds the supported size limit."
            )
        }
        return data
    }

    /// Keeps the mapped verification read inside a narrow scope so rotating a
    /// large checkpoint never carries both verification mappings into the next
    /// publication phase.
    private nonisolated static func verifyExactFileContents(
        at url: URL,
        expectedData: Data,
        maximumByteCount: Int,
        description: String,
        mismatchMessage: String
    ) throws {
        let storedData = try readBoundedData(
            at: url,
            maximumByteCount: maximumByteCount,
            description: description
        )
        guard storedData == expectedData else {
            throw CanvasCoreStoreError.verificationFailed(mismatchMessage)
        }
    }

    private nonisolated static func importedSourceURL(
        relativePath: String,
        sourceRootURL: URL
    ) throws -> URL {
        let reference = CanvasPDFSourceReference(relativePath: relativePath)
        guard reference.isValid else {
            throw CanvasCoreStoreError.invalidEnvelope(
                "The imported source path \(relativePath) is invalid."
            )
        }
        let root = sourceRootURL.standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        let resolvedRoot = root.resolvingSymlinksInPath()
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        let rootPrefix = resolvedRoot.path.hasSuffix("/")
            ? resolvedRoot.path
            : resolvedRoot.path + "/"
        guard resolvedCandidate.path.hasPrefix(rootPrefix) else {
            throw CanvasCoreStoreError.invalidEnvelope(
                "The imported source path escapes its item directory."
            )
        }
        return resolvedCandidate
    }

    private nonisolated static func validate(
        _ snapshot: CanvasCoreSnapshot,
        limits: CanvasCoreResourceLimits = .production
    ) throws {
        guard (0...limits.maximumPersistedGeneration).contains(snapshot.generation) else {
            throw CanvasCoreStoreError.invalidSnapshot(
                "The generation is outside the supported range."
            )
        }
        guard snapshot.pages.isEmpty == false else {
            throw CanvasCoreStoreError.invalidSnapshot("The document must contain at least one page.")
        }
        guard snapshot.pages.count <= limits.maximumPageCount else {
            throw CanvasCoreStoreError.invalidSnapshot(
                "The document exceeds the supported page limit of \(limits.maximumPageCount)."
            )
        }
        let pageIDs = Set(snapshot.pages.map(\.id))
        guard pageIDs.count == snapshot.pages.count else {
            throw CanvasCoreStoreError.invalidSnapshot("Page identifiers must be unique.")
        }
        guard pageIDs.contains(snapshot.currentPageID) else {
            throw CanvasCoreStoreError.invalidSnapshot(
                "The current page identifier is not present in the document."
            )
        }
        for page in snapshot.pages {
            guard page.viewport.isValid else {
                throw CanvasCoreStoreError.invalidSnapshot(
                    "Page \(page.id.uuidString) has an invalid viewport."
                )
            }
            guard page.geometry.isValid,
                  page.background.isValid,
                  page.markup.bounds.origin == .zero,
                  page.markup.bounds.size == page.geometry.displaySize else {
                throw CanvasCoreStoreError.invalidSnapshot(
                    "Page \(page.id.uuidString) has invalid geometry or background content."
                )
            }
            let tableIDs = Set(page.tables.map(\.id))
            guard tableIDs.count == page.tables.count,
                  page.tables.allSatisfy({ $0.isValid(in: page.markup.bounds) }) else {
                throw CanvasCoreStoreError.invalidSnapshot(
                    "Page \(page.id.uuidString) has invalid or duplicate tables."
                )
            }
            try validateMarkup(page.markup)
        }
    }

    private nonisolated static func validateMarkup(_ markup: PaperMarkup) throws {
        let bounds = markup.bounds
        guard bounds.origin.x.isFinite,
              bounds.origin.y.isFinite,
              bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.origin == .zero,
              bounds.width > 0,
              bounds.height > 0 else {
            throw CanvasCoreStoreError.invalidSnapshot(
                "Paper bounds must be a finite, positive, zero-origin canvas."
            )
        }
        guard PaperFeatureSetFactory.canEdit(markup) else {
            throw CanvasCoreStoreError.incompatibleMarkup
        }
    }

    private nonisolated static func encodeEnvelope(
        generation: Int64,
        pages: [StoredPageV6],
        currentPageID: UUID
    ) throws -> Data {
        let payload = StoredPayloadV6(
            formatVersion: envelopeVersion,
            generation: generation,
            featureFingerprint: PaperFeatureSetFactory.fingerprint,
            pages: pages,
            currentPageID: currentPageID
        )
        let envelope = StoredEnvelopeV6(
            formatVersion: payload.formatVersion,
            generation: payload.generation,
            featureFingerprint: payload.featureFingerprint,
            pages: payload.pages,
            currentPageID: payload.currentPageID,
            checksum: sha256(try encode(payload))
        )
        return try encode(envelope)
    }

    private nonisolated static func decodeEnvelope(
        _ data: Data,
        limits: CanvasCoreResourceLimits = .production
    ) throws -> DecodedEnvelope {
        guard data.count <= limits.maximumCheckpointEncodedByteCount else {
            throw CanvasCoreStoreError.invalidEnvelope(
                "The checkpoint exceeds the supported size limit."
            )
        }
        let version: StoredVersionProbe
        do {
            version = try JSONDecoder().decode(StoredVersionProbe.self, from: data)
        } catch {
            throw CanvasCoreStoreError.invalidEnvelope(
                "The envelope could not be decoded: \(describe(error))"
            )
        }

        switch version.formatVersion {
        case legacyEnvelopeVersion:
            return try decodeLegacyEnvelope(data, limits: limits)
        case multiPageEnvelopeVersion:
            return try decodeVersionTwoEnvelope(data, limits: limits)
        case paperTemplateEnvelopeVersion:
            return try decodeVersionThreeEnvelope(data, limits: limits)
        case importedBackgroundEnvelopeVersion:
            return try decodeVersionFourEnvelope(data, limits: limits)
        case sourceReferencedEnvelopeVersion:
            return try decodeVersionFiveEnvelope(data, limits: limits)
        case semanticTableEnvelopeVersion:
            return try decodeCurrentEnvelope(data, limits: limits)
        default:
            throw CanvasCoreStoreError.invalidEnvelope(
                "Unsupported format version \(version.formatVersion)."
            )
        }
    }

    private nonisolated static func decodeLegacyEnvelope(
        _ data: Data,
        limits: CanvasCoreResourceLimits
    ) throws -> DecodedEnvelope {
        let envelope = try decodeStoredEnvelope(StoredEnvelopeV1.self, from: data, version: 1)

        try validateEnvelopeHeader(
            generation: envelope.generation,
            featureFingerprint: envelope.featureFingerprint,
            checksum: envelope.checksum,
            limits: limits
        )
        try validateStoredMarkupResourceLimits(
            [envelope.paperMarkupData],
            limits: limits,
            error: { CanvasCoreStoreError.invalidEnvelope($0) }
        )

        let payload = StoredPayloadV1(
            formatVersion: envelope.formatVersion,
            generation: envelope.generation,
            featureFingerprint: envelope.featureFingerprint,
            paperMarkupData: envelope.paperMarkupData
        )
        try validateChecksum(envelope.checksum, payload: payload)
        let pageID = try legacyPageID(forChecksum: envelope.checksum)

        return DecodedEnvelope(
            formatVersion: envelope.formatVersion,
            generation: envelope.generation,
            featureFingerprint: envelope.featureFingerprint,
            pages: [
                DecodedStoredPage(
                    id: pageID,
                    viewport: CanvasViewportState(),
                    paperTemplate: .default,
                    geometry: CanvasPageGeometry(),
                    background: .paper,
                    tables: [],
                    paperMarkupData: envelope.paperMarkupData
                )
            ],
            currentPageID: pageID
        )
    }

    private nonisolated static func decodeVersionTwoEnvelope(
        _ data: Data,
        limits: CanvasCoreResourceLimits
    ) throws -> DecodedEnvelope {
        let envelope = try decodeStoredEnvelope(StoredEnvelopeV2.self, from: data, version: 2)

        try validateEnvelopeHeader(
            generation: envelope.generation,
            featureFingerprint: envelope.featureFingerprint,
            checksum: envelope.checksum,
            limits: limits
        )
        try validateStoredPagesV2(
            envelope.pages,
            currentPageID: envelope.currentPageID,
            limits: limits
        )

        let payload = StoredPayloadV2(
            formatVersion: envelope.formatVersion,
            generation: envelope.generation,
            featureFingerprint: envelope.featureFingerprint,
            pages: envelope.pages,
            currentPageID: envelope.currentPageID
        )
        try validateChecksum(envelope.checksum, payload: payload)

        return DecodedEnvelope(
            formatVersion: envelope.formatVersion,
            generation: envelope.generation,
            featureFingerprint: envelope.featureFingerprint,
            pages: envelope.pages.map { page in
                DecodedStoredPage(
                    id: page.id,
                    viewport: page.viewport.canvasViewportState,
                    paperTemplate: .default,
                    geometry: CanvasPageGeometry(),
                    background: .paper,
                    tables: [],
                    paperMarkupData: page.paperMarkupData
                )
            },
            currentPageID: envelope.currentPageID
        )
    }

    private nonisolated static func decodeVersionThreeEnvelope(
        _ data: Data,
        limits: CanvasCoreResourceLimits
    ) throws -> DecodedEnvelope {
        let envelope = try decodeStoredEnvelope(StoredEnvelopeV3.self, from: data, version: 3)

        try validateEnvelopeHeader(
            generation: envelope.generation,
            featureFingerprint: envelope.featureFingerprint,
            checksum: envelope.checksum,
            limits: limits
        )
        try validateStoredPagesV3(
            envelope.pages,
            currentPageID: envelope.currentPageID,
            limits: limits
        )

        let payload = StoredPayloadV3(
            formatVersion: envelope.formatVersion,
            generation: envelope.generation,
            featureFingerprint: envelope.featureFingerprint,
            pages: envelope.pages,
            currentPageID: envelope.currentPageID
        )
        try validateChecksum(envelope.checksum, payload: payload)

        return DecodedEnvelope(
            formatVersion: envelope.formatVersion,
            generation: envelope.generation,
            featureFingerprint: envelope.featureFingerprint,
            pages: envelope.pages.map { page in
                DecodedStoredPage(
                    id: page.id,
                    viewport: page.viewport,
                    paperTemplate: page.paperTemplate,
                    geometry: CanvasPageGeometry(),
                    background: .paper,
                    tables: [],
                    paperMarkupData: page.paperMarkupData
                )
            },
            currentPageID: envelope.currentPageID
        )
    }

    private nonisolated static func decodeVersionFourEnvelope(
        _ data: Data,
        limits: CanvasCoreResourceLimits
    ) throws -> DecodedEnvelope {
        let envelope = try decodeStoredEnvelope(StoredEnvelopeV4.self, from: data, version: 4)

        try validateEnvelopeHeader(
            generation: envelope.generation,
            featureFingerprint: envelope.featureFingerprint,
            checksum: envelope.checksum,
            limits: limits
        )
        try validateStoredPagesV4(
            envelope.pages,
            currentPageID: envelope.currentPageID,
            limits: limits
        )

        let payload = StoredPayloadV4(
            formatVersion: envelope.formatVersion,
            generation: envelope.generation,
            featureFingerprint: envelope.featureFingerprint,
            pages: envelope.pages,
            currentPageID: envelope.currentPageID
        )
        try validateChecksum(envelope.checksum, payload: payload)

        return DecodedEnvelope(
            formatVersion: envelope.formatVersion,
            generation: envelope.generation,
            featureFingerprint: envelope.featureFingerprint,
            pages: envelope.pages.map { page in
                DecodedStoredPage(
                    id: page.id,
                    viewport: page.viewport,
                    paperTemplate: page.paperTemplate,
                    geometry: page.geometry,
                    background: legacyBackground(page.background),
                    tables: [],
                    paperMarkupData: page.paperMarkupData
                )
            },
            currentPageID: envelope.currentPageID
        )
    }

    private nonisolated static func decodeVersionFiveEnvelope(
        _ data: Data,
        limits: CanvasCoreResourceLimits
    ) throws -> DecodedEnvelope {
        let envelope = try decodeStoredEnvelope(StoredEnvelopeV5.self, from: data, version: 5)

        try validateEnvelopeHeader(
            generation: envelope.generation,
            featureFingerprint: envelope.featureFingerprint,
            checksum: envelope.checksum,
            limits: limits
        )
        try validateStoredPagesV5(
            envelope.pages,
            currentPageID: envelope.currentPageID,
            limits: limits
        )

        let payload = StoredPayloadV5(
            formatVersion: envelope.formatVersion,
            generation: envelope.generation,
            featureFingerprint: envelope.featureFingerprint,
            pages: envelope.pages,
            currentPageID: envelope.currentPageID
        )
        try validateChecksum(envelope.checksum, payload: payload)

        return DecodedEnvelope(
            formatVersion: envelope.formatVersion,
            generation: envelope.generation,
            featureFingerprint: envelope.featureFingerprint,
            pages: envelope.pages.map { page in
                DecodedStoredPage(
                    id: page.id,
                    viewport: page.viewport,
                    paperTemplate: page.paperTemplate,
                    geometry: page.geometry,
                    background: runtimeBackground(page.background),
                    tables: [],
                    paperMarkupData: page.paperMarkupData
                )
            },
            currentPageID: envelope.currentPageID
        )
    }

    private nonisolated static func decodeCurrentEnvelope(
        _ data: Data,
        limits: CanvasCoreResourceLimits
    ) throws -> DecodedEnvelope {
        let envelope = try decodeStoredEnvelope(StoredEnvelopeV6.self, from: data, version: 6)

        try validateEnvelopeHeader(
            generation: envelope.generation,
            featureFingerprint: envelope.featureFingerprint,
            checksum: envelope.checksum,
            limits: limits
        )
        try validateStoredPages(
            envelope.pages,
            currentPageID: envelope.currentPageID,
            limits: limits
        )

        let payload = StoredPayloadV6(
            formatVersion: envelope.formatVersion,
            generation: envelope.generation,
            featureFingerprint: envelope.featureFingerprint,
            pages: envelope.pages,
            currentPageID: envelope.currentPageID
        )
        try validateChecksum(envelope.checksum, payload: payload)

        return DecodedEnvelope(
            formatVersion: envelope.formatVersion,
            generation: envelope.generation,
            featureFingerprint: envelope.featureFingerprint,
            pages: envelope.pages.map { page in
                DecodedStoredPage(
                    id: page.id,
                    viewport: page.viewport,
                    paperTemplate: page.paperTemplate,
                    geometry: page.geometry,
                    background: runtimeBackground(page.background),
                    tables: page.tables,
                    paperMarkupData: page.paperMarkupData
                )
            },
            currentPageID: envelope.currentPageID
        )
    }

    private nonisolated static func decodeStoredEnvelope<Envelope: Decodable>(
        _ type: Envelope.Type,
        from data: Data,
        version: Int
    ) throws -> Envelope {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw CanvasCoreStoreError.invalidEnvelope(
                "The version \(version) envelope could not be decoded: \(describe(error))"
            )
        }
    }

    private nonisolated static func validateEnvelopeHeader(
        generation: Int64,
        featureFingerprint: String,
        checksum: String,
        limits: CanvasCoreResourceLimits
    ) throws {
        guard (0...limits.maximumPersistedGeneration).contains(generation) else {
            throw CanvasCoreStoreError.invalidEnvelope(
                "The generation is outside the supported range."
            )
        }
        guard PaperFeatureSetFactory.canRead(fingerprint: featureFingerprint) else {
            throw CanvasCoreStoreError.invalidEnvelope(
                "The PaperKit feature fingerprint is incompatible."
            )
        }
        guard checksum.count == 64,
              checksum.allSatisfy({ $0.isHexDigit && $0.isUppercase == false }) else {
            throw CanvasCoreStoreError.invalidEnvelope("The checksum is malformed.")
        }
    }

    private nonisolated static func validateStoredPages(
        _ pages: [StoredPageV6],
        currentPageID: UUID,
        limits: CanvasCoreResourceLimits
    ) throws {
        try validateStoredDocumentPages(
            pages,
            currentPageID: currentPageID,
            pageID: { $0.id },
            markupData: { $0.paperMarkupData },
            limits: limits
        ) { page in
            guard page.viewport.isValid else {
                throw CanvasCoreStoreError.invalidEnvelope(
                    "Page \(page.id.uuidString) has an invalid viewport."
                )
            }
            guard page.geometry.isValid, page.background.isValid else {
                throw CanvasCoreStoreError.invalidEnvelope(
                    "Page \(page.id.uuidString) has invalid geometry or background content."
                )
            }
            let tableIDs = Set(page.tables.map(\.id))
            let pageBounds = CGRect(origin: .zero, size: page.geometry.displaySize)
            guard tableIDs.count == page.tables.count,
                  page.tables.allSatisfy({ $0.isValid(in: pageBounds) }) else {
                throw CanvasCoreStoreError.invalidEnvelope(
                    "Page \(page.id.uuidString) has invalid or duplicate tables."
                )
            }
            try validateStoredPaperMarkupData(page.paperMarkupData, pageID: page.id)
        }
    }

    private nonisolated static func validateStoredPagesV5(
        _ pages: [StoredPageV5],
        currentPageID: UUID,
        limits: CanvasCoreResourceLimits
    ) throws {
        try validateStoredDocumentPages(
            pages,
            currentPageID: currentPageID,
            pageID: { $0.id },
            markupData: { $0.paperMarkupData },
            limits: limits
        ) { page in
            guard page.viewport.isValid else {
                throw CanvasCoreStoreError.invalidEnvelope(
                    "Page \(page.id.uuidString) has an invalid viewport."
                )
            }
            guard page.geometry.isValid, page.background.isValid else {
                throw CanvasCoreStoreError.invalidEnvelope(
                    "Page \(page.id.uuidString) has invalid geometry or background content."
                )
            }
            try validateStoredPaperMarkupData(page.paperMarkupData, pageID: page.id)
        }
    }

    private nonisolated static func validateStoredPagesV4(
        _ pages: [StoredPageV4],
        currentPageID: UUID,
        limits: CanvasCoreResourceLimits
    ) throws {
        try validateStoredDocumentPages(
            pages,
            currentPageID: currentPageID,
            pageID: { $0.id },
            markupData: { $0.paperMarkupData },
            limits: limits
        ) { page in
            guard page.viewport.isValid else {
                throw CanvasCoreStoreError.invalidEnvelope(
                    "Page \(page.id.uuidString) has an invalid viewport."
                )
            }
            let background = legacyBackground(page.background)
            guard page.geometry.isValid, background.isValid else {
                throw CanvasCoreStoreError.invalidEnvelope(
                    "Page \(page.id.uuidString) has invalid geometry or background content."
                )
            }
            try validateStoredPaperMarkupData(page.paperMarkupData, pageID: page.id)
        }
    }

    private nonisolated static func validateStoredPagesV3(
        _ pages: [StoredPageV3],
        currentPageID: UUID,
        limits: CanvasCoreResourceLimits
    ) throws {
        try validateStoredDocumentPages(
            pages,
            currentPageID: currentPageID,
            pageID: { $0.id },
            markupData: { $0.paperMarkupData },
            limits: limits
        ) { page in
            guard page.viewport.isValid, page.paperMarkupData.isEmpty == false else {
                throw CanvasCoreStoreError.invalidEnvelope(
                    "Page \(page.id.uuidString) has invalid stored content."
                )
            }
        }
    }

    private nonisolated static func validateStoredPagesV2(
        _ pages: [StoredPageV2],
        currentPageID: UUID,
        limits: CanvasCoreResourceLimits
    ) throws {
        try validateStoredDocumentPages(
            pages,
            currentPageID: currentPageID,
            pageID: { $0.id },
            markupData: { $0.paperMarkupData },
            limits: limits
        ) { page in
            guard page.viewport.isValid else {
                throw CanvasCoreStoreError.invalidEnvelope(
                    "Page \(page.id.uuidString) has an invalid viewport."
                )
            }
            try validateStoredPaperMarkupData(page.paperMarkupData, pageID: page.id)
        }
    }

    private nonisolated static func validateStoredDocumentPages<Page>(
        _ pages: [Page],
        currentPageID: UUID,
        pageID: (Page) -> UUID,
        markupData: (Page) -> Data,
        limits: CanvasCoreResourceLimits,
        validatePage: (Page) throws -> Void
    ) throws {
        guard pages.isEmpty == false else {
            throw CanvasCoreStoreError.invalidEnvelope(
                "The document must contain at least one page."
            )
        }
        guard pages.count <= limits.maximumPageCount else {
            throw CanvasCoreStoreError.invalidEnvelope(
                "The document exceeds the supported page limit of \(limits.maximumPageCount)."
            )
        }
        let pageIDs = Set(pages.map(pageID))
        guard pageIDs.count == pages.count else {
            throw CanvasCoreStoreError.invalidEnvelope("Page identifiers must be unique.")
        }
        guard pageIDs.contains(currentPageID) else {
            throw CanvasCoreStoreError.invalidEnvelope(
                "The current page identifier is not present in the document."
            )
        }
        try validateStoredMarkupResourceLimits(
            pages.map(markupData),
            limits: limits,
            error: { CanvasCoreStoreError.invalidEnvelope($0) }
        )
        try pages.forEach(validatePage)
    }

    @discardableResult
    private nonisolated static func validateStoredMarkupResourceLimits<Failure: Error>(
        _ payloads: [Data],
        limits: CanvasCoreResourceLimits,
        error: (String) -> Failure
    ) throws -> Int {
        var aggregateByteCount = 0
        for payload in payloads {
            guard payload.isEmpty == false else {
                throw error("A PaperKit payload is empty.")
            }
            guard payload.count <= limits.maximumMarkupByteCountPerPage else {
                throw error("A PaperKit payload exceeds the supported per-page size limit.")
            }
            let (nextByteCount, overflow) = aggregateByteCount.addingReportingOverflow(
                payload.count
            )
            guard overflow == false,
                  nextByteCount <= limits.maximumAggregateMarkupByteCount else {
                throw error("The document exceeds the supported aggregate PaperKit size limit.")
            }
            aggregateByteCount = nextByteCount
        }
        return aggregateByteCount
    }

    private nonisolated static func validateSerializedWorkingSet<Failure: Error>(
        checkpointByteCount: Int,
        markupByteCount: Int,
        importedSourceByteCount: Int,
        limits: CanvasCoreResourceLimits,
        error: (String) -> Failure
    ) throws {
        var total = 0
        for byteCount in [
            checkpointByteCount,
            markupByteCount,
            importedSourceByteCount,
        ] {
            guard byteCount >= 0 else {
                throw error("The document has an invalid serialized resource size.")
            }
            let (next, overflowed) = total.addingReportingOverflow(byteCount)
            guard overflowed == false else {
                throw error("The document's serialized working set is too large.")
            }
            total = next
        }
        guard total <= limits.maximumSerializedWorkingSetByteCount else {
            throw error(
                "The document exceeds the supported combined checkpoint, PaperKit, and imported-source size limit."
            )
        }
    }

    private nonisolated static func remainingSerializedWorkingSetByteCount(
        checkpointByteCount: Int,
        markupByteCount: Int,
        importedSourceByteCount: Int,
        limits: CanvasCoreResourceLimits
    ) -> Int {
        var used = 0
        for byteCount in [
            checkpointByteCount,
            markupByteCount,
            importedSourceByteCount,
        ] {
            guard byteCount >= 0 else { return 0 }
            let (next, overflowed) = used.addingReportingOverflow(byteCount)
            guard overflowed == false else { return 0 }
            used = next
        }
        return max(0, limits.maximumSerializedWorkingSetByteCount - min(
            used,
            limits.maximumSerializedWorkingSetByteCount
        ))
    }

    private nonisolated static func validateStoredPaperMarkupData(
        _ data: Data,
        pageID: UUID
    ) throws {
        guard data.isEmpty == false else {
            throw CanvasCoreStoreError.invalidEnvelope(
                "The PaperKit payload for page \(pageID.uuidString) is empty."
            )
        }
    }

    private nonisolated static func validateChecksum<T: Encodable>(
        _ checksum: String,
        payload: T
    ) throws {
        let expectedChecksum: String
        do {
            expectedChecksum = sha256(try encode(payload))
        } catch {
            throw CanvasCoreStoreError.invalidEnvelope(
                "The checksum payload could not be encoded: \(describe(error))"
            )
        }
        guard checksum == expectedChecksum else {
            throw CanvasCoreStoreError.invalidEnvelope("The checksum does not match.")
        }
    }

    private nonisolated static func legacyPageID(forChecksum checksum: String) throws -> UUID {
        let hexadecimal = String(checksum.prefix(32))
        let part1 = String(hexadecimal.prefix(8))
        let part2 = String(hexadecimal.dropFirst(8).prefix(4))
        let part3 = String(hexadecimal.dropFirst(12).prefix(4))
        let part4 = String(hexadecimal.dropFirst(16).prefix(4))
        let part5 = String(hexadecimal.dropFirst(20).prefix(12))
        let uuidString = "\(part1)-\(part2)-\(part3)-\(part4)-\(part5)"
        guard let pageID = UUID(uuidString: uuidString) else {
            throw CanvasCoreStoreError.invalidEnvelope(
                "The legacy checkpoint could not produce a stable page identifier."
            )
        }
        return pageID
    }

    private nonisolated static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }

    private nonisolated static func legacyImageSourcePath(
        _ data: Data,
        suggestedName: String?
    ) -> String {
        let pathExtension = URL(fileURLWithPath: suggestedName ?? "")
            .pathExtension
            .lowercased()
        let safeExtension = pathExtension.isEmpty
            || pathExtension.count > 12
            || pathExtension.allSatisfy({ $0.isLetter || $0.isNumber }) == false
            ? "image"
            : pathExtension
        return "legacy-image-\(sha256(data)).\(safeExtension)"
    }

    private nonisolated static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private nonisolated static func describe(_ error: any Error) -> String {
        if let localized = error as? any LocalizedError,
           let description = localized.errorDescription,
           description.isEmpty == false {
            return description
        }
        return String(describing: error)
    }
}

private enum StoredSlot: Equatable, Sendable {
    case current
    case previous
}

private enum CanvasCoreDiskSlotIdentity: Equatable, Sendable {
    case missing
    case present(byteCount: Int, digest: String)
    case inaccessible(String)
}

private struct CanvasCoreDiskIdentity: Equatable, Sendable {
    let current: CanvasCoreDiskSlotIdentity
    let previous: CanvasCoreDiskSlotIdentity

    var hasStoredFiles: Bool {
        current != .missing || previous != .missing
    }
}

private struct CanvasCoreRawSlot: Sendable {
    let identity: CanvasCoreDiskSlotIdentity
    let generation: Int64?
}

private struct CanvasCoreRawDiskState: Sendable {
    let current: CanvasCoreRawSlot
    let previous: CanvasCoreRawSlot

    var identity: CanvasCoreDiskIdentity {
        CanvasCoreDiskIdentity(
            current: current.identity,
            previous: previous.identity
        )
    }
}

private enum CanvasCoreSlotReadRace: Error {
    case changed
}

private enum CheckpointPublication: Sendable {
    case published
    case retry
}

private enum LoadFinalization: Sendable {
    case completed(CanvasCoreLoadResult)
    case retry
}

private struct LoadedCandidate: Sendable {
    let slot: StoredSlot
    let snapshot: CanvasCoreSnapshot
    /// Only a previous-slot load needs its exact bytes for atomic promotion.
    /// A current-slot load releases the mapped envelope as soon as decoding
    /// finishes instead of carrying it beside the full runtime snapshot.
    let envelopeDataForPromotion: Data?
}

private struct SlotInspection: Sendable {
    let hasStoredFiles: Bool
    let candidate: LoadedCandidate?
    let currentFailure: String?
    let previousFailure: String?
    let diskIdentity: CanvasCoreDiskIdentity

    var unresolvedCorruption: CanvasCoreStoreError {
        .unresolvedCorruption(current: currentFailure, previous: previousFailure)
    }
}

/// Publication validates the durable baseline page-by-page, but deliberately
/// does not retain its decoded runtime snapshot while the new snapshot and
/// envelope are already live.
private struct PublicationCandidate: Sendable {
    let slot: StoredSlot
    let generation: Int64
    let envelopeData: Data
}

private struct PublicationSlotInspection: Sendable {
    let hasStoredFiles: Bool
    let candidate: PublicationCandidate?
    let currentFailure: String?
    let previousFailure: String?
    let diskIdentity: CanvasCoreDiskIdentity

    var unresolvedCorruption: CanvasCoreStoreError {
        .unresolvedCorruption(current: currentFailure, previous: previousFailure)
    }
}

private struct StoredVersionProbe: Decodable, Sendable {
    let formatVersion: Int
}

private struct StoredGenerationProbe: Decodable, Sendable {
    let generation: Int64
}

/// Frozen representation used only to validate and migrate Canvas Core v2.
private struct StoredPageV2: Codable, Equatable, Sendable {
    let id: UUID
    let viewport: StoredViewportV2
    let paperMarkupData: Data
}

/// Canvas Core v2 shipped with `usesFitWidth`. A later v2 build wrote the
/// renamed `usesFitPage` key. The checksum covers the JSON spelling, so this
/// DTO remembers and reproduces the exact key that was decoded. Do not replace
/// it with the current `CanvasViewportState` Codable representation.
private struct StoredViewportV2: Codable, Equatable, Sendable {
    let normalizedCenterX: Double
    let normalizedCenterY: Double
    let visibleWidth: Double
    let usesAutomaticFit: Bool
    private let fitKey: FitKey

    var isValid: Bool {
        normalizedCenterX.isFinite && (0...1).contains(normalizedCenterX)
            && normalizedCenterY.isFinite && (0...1).contains(normalizedCenterY)
            && visibleWidth.isFinite && visibleWidth > 0
    }

    var canvasViewportState: CanvasViewportState {
        CanvasViewportState(
            normalizedCenterX: normalizedCenterX,
            normalizedCenterY: normalizedCenterY,
            visibleWidth: visibleWidth,
            usesFitPage: usesAutomaticFit
        )
    }

    private enum FitKey: Equatable, Sendable {
        case usesFitWidth
        case usesFitPage
    }

    private enum CodingKeys: String, CodingKey {
        case normalizedCenterX
        case normalizedCenterY
        case visibleWidth
        case usesFitWidth
        case usesFitPage
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        normalizedCenterX = try container.decode(Double.self, forKey: .normalizedCenterX)
        normalizedCenterY = try container.decode(Double.self, forKey: .normalizedCenterY)
        visibleWidth = try container.decode(Double.self, forKey: .visibleWidth)

        let usesFitWidth = try container.decodeIfPresent(Bool.self, forKey: .usesFitWidth)
        let usesFitPage = try container.decodeIfPresent(Bool.self, forKey: .usesFitPage)
        switch (usesFitWidth, usesFitPage) {
        case let (.some(value), .none):
            usesAutomaticFit = value
            fitKey = .usesFitWidth
        case let (.none, .some(value)):
            usesAutomaticFit = value
            fitKey = .usesFitPage
        case (.some, .some):
            throw DecodingError.dataCorruptedError(
                forKey: .usesFitPage,
                in: container,
                debugDescription: "A version 2 viewport cannot contain both fit-mode keys."
            )
        case (.none, .none):
            throw DecodingError.keyNotFound(
                CodingKeys.usesFitWidth,
                DecodingError.Context(
                    codingPath: container.codingPath,
                    debugDescription: "A version 2 viewport is missing its fit-mode key."
                )
            )
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(normalizedCenterX, forKey: .normalizedCenterX)
        try container.encode(normalizedCenterY, forKey: .normalizedCenterY)
        try container.encode(visibleWidth, forKey: .visibleWidth)
        switch fitKey {
        case .usesFitWidth:
            try container.encode(usesAutomaticFit, forKey: .usesFitWidth)
        case .usesFitPage:
            try container.encode(usesAutomaticFit, forKey: .usesFitPage)
        }
    }
}

private struct StoredPageV3: Codable, Equatable, Sendable {
    let id: UUID
    let viewport: CanvasViewportState
    let paperTemplate: CanvasPaperTemplate
    let paperMarkupData: Data
}

private struct StoredPageV4: Codable, Equatable, Sendable {
    let id: UUID
    let viewport: CanvasViewportState
    let paperTemplate: CanvasPaperTemplate
    let geometry: CanvasPageGeometry
    let background: LegacyCanvasPageBackgroundV4
    let paperMarkupData: Data
}

private struct StoredPageV5: Codable, Equatable, Sendable {
    let id: UUID
    let viewport: CanvasViewportState
    let paperTemplate: CanvasPaperTemplate
    let geometry: CanvasPageGeometry
    let background: StoredCanvasPageBackgroundV5
    let paperMarkupData: Data
}

private struct StoredPageV6: Codable, Equatable, Sendable {
    let id: UUID
    let viewport: CanvasViewportState
    let paperTemplate: CanvasPaperTemplate
    let geometry: CanvasPageGeometry
    let background: StoredCanvasPageBackgroundV5
    let tables: [CanvasTable]
    let paperMarkupData: Data
}

private enum LegacyCanvasPageBackgroundV4: Codable, Equatable, Sendable {
    case paper
    case image(data: Data, suggestedName: String?)
    case pdfPage(documentData: Data, pageIndex: Int, suggestedName: String?)
}

private enum StoredCanvasPageBackgroundV5: Codable, Equatable, Sendable {
    case paper
    case image(
        sourceRelativePath: String,
        sourceChecksum: String,
        suggestedName: String?
    )
    case pdfPage(
        sourceRelativePath: String,
        sourceChecksum: String,
        pageIndex: Int,
        suggestedName: String?
    )

    var isValid: Bool {
        switch self {
        case .paper:
            true
        case let .image(sourceRelativePath, sourceChecksum, _):
            CanvasImageSourceReference(relativePath: sourceRelativePath).isValid
                && Self.isValidChecksum(sourceChecksum)
        case let .pdfPage(sourceRelativePath, sourceChecksum, pageIndex, _):
            CanvasPDFSourceReference(relativePath: sourceRelativePath).isValid
                && Self.isValidChecksum(sourceChecksum)
                && pageIndex >= 0
        }
    }

    private static func isValidChecksum(_ checksum: String) -> Bool {
        checksum.count == 64
            && checksum.allSatisfy { $0.isHexDigit && $0.isUppercase == false }
    }
}

private struct CanvasPageArchiveEnvelopeV1: Codable, Equatable, Sendable {
    let formatVersion: Int
    let id: UUID
    let viewport: CanvasViewportState
    let paperTemplate: CanvasPaperTemplate
    let geometry: CanvasPageGeometry
    let background: LegacyCanvasPageBackgroundV4
    let paperMarkupData: Data
}

private struct CanvasPageArchiveEnvelopeV2: Codable, Equatable, Sendable {
    static let currentVersion = 2

    let formatVersion: Int
    let id: UUID
    let viewport: CanvasViewportState
    let paperTemplate: CanvasPaperTemplate
    let geometry: CanvasPageGeometry
    let background: StoredCanvasPageBackgroundV5
    let paperMarkupData: Data
}

private struct CanvasPageArchiveEnvelopeV3: Codable, Equatable, Sendable {
    static let currentVersion = 3

    let formatVersion: Int
    let id: UUID
    let viewport: CanvasViewportState
    let paperTemplate: CanvasPaperTemplate
    let geometry: CanvasPageGeometry
    let background: StoredCanvasPageBackgroundV5
    let tables: [CanvasTable]
    let paperMarkupData: Data
    let checksum: String
}

private struct CanvasPageArchivePayloadV3: Codable, Equatable, Sendable {
    let formatVersion: Int
    let id: UUID
    let viewport: CanvasViewportState
    let paperTemplate: CanvasPaperTemplate
    let geometry: CanvasPageGeometry
    let background: StoredCanvasPageBackgroundV5
    let tables: [CanvasTable]
    let paperMarkupData: Data
}

private struct DecodedStoredPage: Equatable, Sendable {
    let id: UUID
    let viewport: CanvasViewportState
    let paperTemplate: CanvasPaperTemplate
    let geometry: CanvasPageGeometry
    let background: CanvasPageBackground
    let tables: [CanvasTable]
    let paperMarkupData: Data
}

private struct DecodedEnvelope: Sendable {
    let formatVersion: Int
    let generation: Int64
    let featureFingerprint: String
    let pages: [DecodedStoredPage]
    let currentPageID: UUID
}

private struct StoredPayloadV1: Codable, Sendable {
    let formatVersion: Int
    let generation: Int64
    let featureFingerprint: String
    let paperMarkupData: Data
}

private struct StoredEnvelopeV1: Codable, Sendable {
    let formatVersion: Int
    let generation: Int64
    let featureFingerprint: String
    let paperMarkupData: Data
    let checksum: String
}

private struct StoredPayloadV2: Codable, Sendable {
    let formatVersion: Int
    let generation: Int64
    let featureFingerprint: String
    let pages: [StoredPageV2]
    let currentPageID: UUID
}

private struct StoredEnvelopeV2: Codable, Sendable {
    let formatVersion: Int
    let generation: Int64
    let featureFingerprint: String
    let pages: [StoredPageV2]
    let currentPageID: UUID
    let checksum: String
}

private struct StoredPayloadV3: Codable, Sendable {
    let formatVersion: Int
    let generation: Int64
    let featureFingerprint: String
    let pages: [StoredPageV3]
    let currentPageID: UUID
}

private struct StoredEnvelopeV3: Codable, Sendable {
    let formatVersion: Int
    let generation: Int64
    let featureFingerprint: String
    let pages: [StoredPageV3]
    let currentPageID: UUID
    let checksum: String
}

private struct StoredPayloadV4: Codable, Sendable {
    let formatVersion: Int
    let generation: Int64
    let featureFingerprint: String
    let pages: [StoredPageV4]
    let currentPageID: UUID
}

private struct StoredEnvelopeV4: Codable, Sendable {
    let formatVersion: Int
    let generation: Int64
    let featureFingerprint: String
    let pages: [StoredPageV4]
    let currentPageID: UUID
    let checksum: String
}

private struct StoredPayloadV5: Codable, Sendable {
    let formatVersion: Int
    let generation: Int64
    let featureFingerprint: String
    let pages: [StoredPageV5]
    let currentPageID: UUID
}

private struct StoredEnvelopeV5: Codable, Sendable {
    let formatVersion: Int
    let generation: Int64
    let featureFingerprint: String
    let pages: [StoredPageV5]
    let currentPageID: UUID
    let checksum: String
}

private struct StoredPayloadV6: Codable, Sendable {
    let formatVersion: Int
    let generation: Int64
    let featureFingerprint: String
    let pages: [StoredPageV6]
    let currentPageID: UUID
}

private struct StoredEnvelopeV6: Codable, Sendable {
    let formatVersion: Int
    let generation: Int64
    let featureFingerprint: String
    let pages: [StoredPageV6]
    let currentPageID: UUID
    let checksum: String
}
