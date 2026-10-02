import Foundation
import Observation
import SwiftData

public enum LibraryRepositoryError: Error, Equatable, LocalizedError {
    case invalidName
    case nameTooLong(maximumUTF8Bytes: Int)
    case invalidColor
    case invalidAssetPath
    case itemNotFound(UUID)
    case tagNotFound(UUID)
    case parentNotFound(UUID)
    case parentNotFolder(UUID)
    case itemTrashed(UUID)
    case itemNotTrashed(UUID)
    case itemNotReady(UUID)
    case pageOwnerNotFound(UUID)
    case deletedPageNotFound(UUID)
    case nonFolderSettings
    case duplicateTagName(String)
    case cycleDetected
    case maximumFolderDepthExceeded(maximum: Int)
    case maximumSubtreeItemCountExceeded(maximum: Int)
    case maximumTagAssignmentCountExceeded(maximum: Int)
    case maximumSearchableTextDuplicationByteCountExceeded(maximum: Int)
    case invalidOrderingTarget(UUID)
    case invalidDuplicationPlan
    case invalidIncompletePayloadPlan
    case invalidPurgePlan
    case invalidLegacyCanvasRemovalPlan
    case persistence(String)

    public var errorDescription: String? {
        switch self {
        case .invalidName:
            "A non-empty name is required."
        case let .nameTooLong(maximumUTF8Bytes):
            "Names can use at most \(maximumUTF8Bytes) UTF-8 bytes."
        case .invalidColor:
            "Every color component must be between zero and one."
        case .invalidAssetPath:
            "Asset paths must be safe, item-relative paths."
        case let .itemNotFound(id):
            "No library item exists with identifier \(id)."
        case let .tagNotFound(id):
            "No tag exists with identifier \(id)."
        case let .parentNotFound(id):
            "No destination exists with identifier \(id)."
        case let .parentNotFolder(id):
            "The destination \(id) is not a folder."
        case let .itemTrashed(id):
            "The library item \(id) is in Trash."
        case let .itemNotTrashed(id):
            "The library item \(id) is not in Trash."
        case let .itemNotReady(id):
            "The library item \(id) is not ready yet."
        case let .pageOwnerNotFound(id):
            "No active page owner exists with identifier \(id)."
        case let .deletedPageNotFound(id):
            "No deleted page exists with identifier \(id)."
        case .nonFolderSettings:
            "Folder appearance can only be assigned to a folder."
        case let .duplicateTagName(name):
            "A tag named \(name) already exists."
        case .cycleDetected:
            "A folder cannot be moved into itself or its descendants."
        case let .maximumFolderDepthExceeded(maximum):
            "Folders can be nested at most \(maximum) levels deep."
        case let .maximumSubtreeItemCountExceeded(maximum):
            "Folders can include at most \(maximum) library items."
        case let .maximumTagAssignmentCountExceeded(maximum):
            "This operation can contain at most \(maximum) tag assignments."
        case let .maximumSearchableTextDuplicationByteCountExceeded(maximum):
            "A duplicate can copy at most \(maximum) UTF-8 bytes of searchable text."
        case let .invalidOrderingTarget(id):
            "The ordering target \(id) is not in the destination folder."
        case .invalidDuplicationPlan:
            "The prepared duplicate is no longer available."
        case .invalidIncompletePayloadPlan:
            "Interrupted library work changed before it could be reconciled."
        case .invalidPurgePlan:
            "Trash changed while cleanup was being prepared. No catalog records were removed."
        case .invalidLegacyCanvasRemovalPlan:
            "Legacy Canvas data changed while removal was being prepared. No catalog records were removed."
        case let .persistence(message):
            "The library could not be saved: \(message)"
        }
    }
}

/// Main-actor facade for the persistent library catalog. It deliberately keeps
/// binary canvas/PDF data out of SwiftData; `LibraryAssetStore` owns those
/// item-scoped files.
@MainActor
@Observable
public final class LibraryRepository {
    public static let maximumFolderDepth = 5
    /// Operations that atomically mutate a complete hierarchy retain both the
    /// source records and their validation/rollback metadata. Refuse a
    /// pathological or corrupt legacy hierarchy before those copies can grow
    /// without bound. Read-only subtree queries intentionally remain exact.
    public nonisolated static let maximumSubtreeMutationItemCount = 10_000
    /// Bounds both the persistent relationship cache and growth mutations so a
    /// corrupt store or pathological tagging workload cannot exhaust memory.
    public nonisolated static let maximumTagAssignmentCount = 100_000
    /// Names are repeated in Library rows, search metadata, and Spotlight
    /// records. Bound them at the mutation boundary so one malformed legacy
    /// value cannot be multiplied across thousands of derived search chunks.
    public nonisolated static let maximumNameUTF8ByteCount = 1_024
    /// Search text is a disposable catalog projection, not the canonical
    /// document. Keeping each newly written projection to one MiB preserves
    /// ordinary full-text search while preventing one record from dominating
    /// repository searches or hierarchy duplication.
    public nonisolated static let maximumSearchableTextUTF8ByteCount = 1 * 1_024 * 1_024
    /// A search always evaluates names, filenames, and tags for the complete
    /// scope. Full-text projections are then inspected in result order until
    /// this aggregate source-byte budget is exhausted.
    public nonisolated static let maximumSearchableTextSearchScanUTF8ByteCount =
        4 * 1_024 * 1_024
    /// Recursive duplication preflights source text before inserting any
    /// records. This ceiling bounds both legacy text materialization and the
    /// retained projection copies used by the transaction.
    public nonisolated static let maximumDuplicatedSearchableTextUTF8ByteCount =
        16 * 1_024 * 1_024
    public static let trashRetention: TimeInterval = 30 * 24 * 60 * 60

    @ObservationIgnored private let modelContext: ModelContext
    /// A context does not guarantee the lifetime of the container that owns
    /// its backing store. Retain containers passed through the public factory
    /// initializer so repository-only clients (including tests and previews)
    /// cannot outlive their SwiftData stack.
    @ObservationIgnored private let modelContainer: ModelContainer?
    @ObservationIgnored private let tagAssignmentLimit: Int
    @ObservationIgnored private let searchableTextSearchScanLimit: Int
    @ObservationIgnored private let duplicatedSearchableTextLimit: Int
    @ObservationIgnored private var assignments: [TagAssignment] = []

    public private(set) var items: [LibraryItemRecord] = []
    public private(set) var tags: [TagRecord] = []
    public private(set) var deletedPages: [DeletedPageRecord] = []
    /// A save has already succeeded when this is populated. Mutations do not
    /// throw for a post-commit cache refresh failure because retrying them
    /// could duplicate durable work; callers can explicitly call `refresh()`.
    public private(set) var cacheRefreshFailureDescription: String?

    public init(modelContainer: ModelContainer) throws {
        self.modelContainer = modelContainer
        tagAssignmentLimit = Self.maximumTagAssignmentCount
        searchableTextSearchScanLimit = Self.maximumSearchableTextSearchScanUTF8ByteCount
        duplicatedSearchableTextLimit = Self.maximumDuplicatedSearchableTextUTF8ByteCount
        modelContext = modelContainer.mainContext
        modelContext.autosaveEnabled = false
        try refresh()
        try installPresetTags()
    }

    public init(modelContext: ModelContext) throws {
        modelContainer = nil
        tagAssignmentLimit = Self.maximumTagAssignmentCount
        searchableTextSearchScanLimit = Self.maximumSearchableTextSearchScanUTF8ByteCount
        duplicatedSearchableTextLimit = Self.maximumDuplicatedSearchableTextUTF8ByteCount
        self.modelContext = modelContext
        modelContext.autosaveEnabled = false
        try refresh()
        try installPresetTags()
    }

    /// A small limit keeps boundary and rollback tests fast without weakening
    /// the production-wide assignment ceiling.
    init(modelContainer: ModelContainer, testingTagAssignmentLimit: Int) throws {
        self.modelContainer = modelContainer
        tagAssignmentLimit = min(
            max(testingTagAssignmentLimit, 0),
            Self.maximumTagAssignmentCount
        )
        searchableTextSearchScanLimit = Self.maximumSearchableTextSearchScanUTF8ByteCount
        duplicatedSearchableTextLimit = Self.maximumDuplicatedSearchableTextUTF8ByteCount
        modelContext = modelContainer.mainContext
        modelContext.autosaveEnabled = false
        try refresh()
        try installPresetTags()
    }

    /// Small content budgets let tests exercise aggregate admission without
    /// allocating production-sized strings. Production initializers always
    /// use the fixed limits above.
    init(
        modelContainer: ModelContainer,
        testingSearchableTextSearchScanUTF8ByteLimit searchLimit: Int,
        testingDuplicatedSearchableTextUTF8ByteLimit duplicationLimit: Int
    ) throws {
        self.modelContainer = modelContainer
        tagAssignmentLimit = Self.maximumTagAssignmentCount
        searchableTextSearchScanLimit = min(
            max(searchLimit, 0),
            Self.maximumSearchableTextSearchScanUTF8ByteCount
        )
        duplicatedSearchableTextLimit = min(
            max(duplicationLimit, 0),
            Self.maximumDuplicatedSearchableTextUTF8ByteCount
        )
        modelContext = modelContainer.mainContext
        modelContext.autosaveEnabled = false
        try refresh()
        try installPresetTags()
    }

    // MARK: - Queries

    public func refresh() throws {
        do {
            items = try modelContext.fetch(FetchDescriptor<LibraryItemRecord>())
            tags = try modelContext.fetch(FetchDescriptor<TagRecord>())
                .sorted { $0.normalizedName < $1.normalizedName }
            var assignmentDescriptor = FetchDescriptor<TagAssignment>()
            assignmentDescriptor.fetchLimit = tagAssignmentLimit + 1
            let fetchedAssignments = try modelContext.fetch(assignmentDescriptor)
            guard fetchedAssignments.count <= tagAssignmentLimit else {
                throw LibraryRepositoryError.maximumTagAssignmentCountExceeded(
                    maximum: tagAssignmentLimit
                )
            }
            assignments = fetchedAssignments
            deletedPages = try modelContext.fetch(FetchDescriptor<DeletedPageRecord>())
                .sorted { $0.deletedAt > $1.deletedAt }
            cacheRefreshFailureDescription = nil
        } catch {
            cacheRefreshFailureDescription = String(describing: error)
            throw map(error)
        }
    }

    public func item(id: UUID) -> LibraryItemRecord? {
        items.first { $0.id == id }
    }

    public func tag(id: UUID) -> TagRecord? {
        tags.first { $0.id == id }
    }

    public func rootItems(sort: LibrarySort = .activity) -> [LibraryItemRecord] {
        sorted(activeItems.filter { $0.parentID == nil }, by: sort)
    }

    public func children(
        of parentID: UUID,
        sort: LibrarySort = .activity
    ) -> [LibraryItemRecord] {
        sorted(activeItems.filter { $0.parentID == parentID }, by: sort)
    }

    public func subtree(
        of itemID: UUID,
        includingRoot: Bool = true,
        includeTrashed: Bool = false
    ) -> [LibraryItemRecord] {
        let candidates = includeTrashed ? items : activeItems
        let ordered = subtreeRecords(rootID: itemID, candidates: candidates)
        return includingRoot ? ordered : Array(ordered.dropFirst())
    }

    public func favorites(sort: LibrarySort = .activity) -> [LibraryItemRecord] {
        sorted(activeItems.filter(\.isFavorite), by: sort)
    }

    public func recentItems(
        activeSince cutoff: Date,
        sort: LibrarySort = .activity
    ) -> [LibraryItemRecord] {
        sorted(
            activeItems.filter { item in
                item.kind != .folder && item.activityDate >= cutoff
            },
            by: sort
        )
    }

    public func items(
        taggedWith tagID: UUID,
        sort: LibrarySort = .activity
    ) -> [LibraryItemRecord] {
        let itemIDs = Set(assignments.lazy.filter { $0.tagID == tagID }.map(\.itemID))
        return sorted(activeItems.filter { itemIDs.contains($0.id) }, by: sort)
    }

    public func tags(for itemID: UUID) -> [TagRecord] {
        let tagIDs = Set(assignments.lazy.filter { $0.itemID == itemID }.map(\.tagID))
        return tags.filter { tagIDs.contains($0.id) }
            .sorted { $0.normalizedName < $1.normalizedName }
    }

    /// With 'includeDescendants == false', only the root card for each Trash
    /// operation is returned. The expanded mode is useful to management UI.
    public func trashedItems(
        includeDescendants: Bool = false,
        sort: LibrarySort = .activity
    ) -> [LibraryItemRecord] {
        let trashed = items.filter { item in
            guard item.kind.isLegacyLibraryItem == false else { return false }
            guard let metadata = item.trashMetadata else { return false }
            return includeDescendants || metadata.trashGroupID == item.id
        }
        return sorted(trashed, by: sort)
    }

    public func deletedPages(ownerItemID: UUID? = nil) -> [DeletedPageRecord] {
        deletedPages.filter { ownerItemID == nil || $0.ownerItemID == ownerItemID }
            .sorted { lhs, rhs in
                if lhs.deletedAt != rhs.deletedAt { return lhs.deletedAt > rhs.deletedAt }
                return lhs.originalIndex < rhs.originalIndex
            }
    }

    public func deletedPageAsset(id: UUID) throws -> LibraryDeletedPageAsset {
        guard let record = deletedPages.first(where: { $0.id == id }) else {
            throw LibraryRepositoryError.deletedPageNotFound(id)
        }
        return record.assetDescriptor
    }

    /// A nil scope performs a global search. A folder scope searches its direct
    /// children or complete descendant tree without including the folder card.
    public func search(
        _ query: String,
        within folderID: UUID? = nil,
        includeDescendants: Bool = true,
        sort: LibrarySort = .activity
    ) -> [LibraryItemRecord] {
        let normalizedQuery = LibraryItemRecord.normalize(
            query.trimmingCharacters(in: .whitespacesAndNewlines)
        )

        let scope: [LibraryItemRecord]
        if let folderID {
            scope = includeDescendants
                ? subtree(of: folderID)
                : children(of: folderID)
        } else {
            scope = activeItems
        }

        return search(normalizedQuery: normalizedQuery, among: scope, sort: sort)
    }

    /// Applies the same bounded full-text policy to precomputed Library UI
    /// scopes such as Favorites, Recent, a tag, or Trash. Keeping this in the
    /// repository prevents those views from accidentally reintroducing an
    /// unbounded 'searchableText' loop.
    func search(
        _ query: String,
        among scope: [LibraryItemRecord],
        sort: LibrarySort = .activity
    ) -> [LibraryItemRecord] {
        let normalizedQuery = LibraryItemRecord.normalize(
            query.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        return search(normalizedQuery: normalizedQuery, among: scope, sort: sort)
    }

    private func search(
        normalizedQuery: String,
        among scope: [LibraryItemRecord],
        sort: LibrarySort
    ) -> [LibraryItemRecord] {
        let orderedScope = sorted(scope, by: sort)
        guard !normalizedQuery.isEmpty else { return orderedScope }

        let matchingTagIDs = Set(tags.lazy
            .filter { $0.normalizedName.localizedStandardContains(normalizedQuery) }
            .map(\.id))
        let tagMatchedItemIDs = Set(assignments.lazy
            .filter { matchingTagIDs.contains($0.tagID) }
            .map(\.itemID))

        // Metadata remains exact over the complete scope even after the
        // aggregate full-text budget is spent. This is both the safest
        // fallback for legacy rows and the behavior users rely on most.
        var matchingItemIDs = Set(orderedScope.lazy.filter { item in
            item.normalizedName.localizedStandardContains(normalizedQuery)
                || LibraryItemRecord.normalize(item.sourceFilename ?? "").localizedStandardContains(normalizedQuery)
                || tagMatchedItemIDs.contains(item.id)
        }.map(\.id))

        var remainingSourceBytes = searchableTextSearchScanLimit
        for item in orderedScope where matchingItemIDs.contains(item.id) == false {
            guard remainingSourceBytes > 0 else { break }
            // SwiftData may fault this entire legacy string when the property
            // is read. Charge inspected source bytes, not retained prefix
            // bytes, so one oversized fault exhausts the budget and no second
            // legacy payload is materialized by this search.
            let inspection = Self.inspectSearchableText(
                item.searchableText,
                maximumProjectionBytes: min(
                    Self.maximumSearchableTextUTF8ByteCount,
                    remainingSourceBytes
                ),
                maximumSourceBytes: remainingSourceBytes
            )

            if inspection.projection.localizedStandardContains(normalizedQuery) {
                matchingItemIDs.insert(item.id)
            }
            if inspection.exceededSourceLimit {
                remainingSourceBytes = 0
            } else {
                remainingSourceBytes -= inspection.inspectedSourceUTF8ByteCount
            }
        }

        return orderedScope.filter { matchingItemIDs.contains($0.id) }
    }

    /// Returns the number of folder ancestors, including the item itself when
    /// it is a folder. Root documents therefore have depth zero and root
    /// folders have depth one.
    public func folderDepth(of itemID: UUID) throws -> Int {
        guard let item = item(id: itemID) else {
            throw LibraryRepositoryError.itemNotFound(itemID)
        }
        return try folderDepth(of: item, index: itemIndex)
    }

    // MARK: - Item mutations

    @discardableResult
    public func createItem(
        id: UUID = UUID(),
        kind: LibraryItemKind,
        name: String,
        parentID: UUID? = nil,
        coverChoice: LibraryCoverChoice = .automatic,
        payloadState: LibraryPayloadState = .creating,
        folderSettings: LibraryFolderSettings? = nil,
        sourceFilename: String? = nil,
        sourceContentTypeIdentifier: String? = nil,
        searchableText: String = "",
        pageCount: Int = 0,
        now: Date = .now
    ) throws -> LibraryItemRecord {
        let resolvedName = try validatedName(name)
        try validateCover(coverChoice)
        if let folderSettings {
            guard kind == .folder else { throw LibraryRepositoryError.nonFolderSettings }
            try validate(folderSettings)
        }

        let index = itemIndex
        let destinationDepth = try validatedDestinationDepth(parentID, index: index)
        if kind == .folder,
            destinationDepth + 1 > Self.maximumFolderDepth {
            throw LibraryRepositoryError.maximumFolderDepthExceeded(
                maximum: Self.maximumFolderDepth
            )
        }
        let searchableTextProjection = Self.storedSearchableTextProjection(searchableText)
        let record = LibraryItemRecord(
            id: id,
            parentID: parentID,
            name: resolvedName,
            kind: kind,
            coverChoice: coverChoice,
            payloadState: payloadState,
            folderSettings: folderSettings,
            createdAt: now,
            manualOrder: nextOrder(in: parentID),
            sourceFilename: sourceFilename,
            sourceContentTypeIdentifier: sourceContentTypeIdentifier,
            searchableText: searchableTextProjection,
            pageCount: pageCount
        )

        return try mutate {
            modelContext.insert(record)
            return record
        }
    }

    public func renameItem(id: UUID, to name: String, now: Date = .now) throws {
        let record = try requireActiveItem(id)
        let resolvedName = try validatedName(name)
        try mutate {
            record.name = resolvedName
            record.normalizedName = LibraryItemRecord.normalize(resolvedName)
            record.modifiedAt = now
        }
    }

    public func markOpened(id: UUID, at date: Date = .now) throws {
        let record = try requireActiveItem(id)
        try mutate {
            record.lastOpenedAt = date
        }
    }
    public func updateCover(
        itemID: UUID,
        choice: LibraryCoverChoice,
        now: Date = .now
    ) throws {
        let record = try requireActiveItem(itemID)
        try validateCover(choice)
        try mutate {
            record.coverChoice = choice
            record.modifiedAt = now
        }
    }

    /// Applies the user-visible folder edit as one validated catalog mutation.
    /// Validating both values before changing the model prevents a failed
    /// appearance update from leaving a successful rename behind.
    public func updateFolder(
        id: UUID,
        name: String,
        settings: LibraryFolderSettings,
        now: Date = .now
    ) throws {
        let folder = try requireActiveItem(id)
        guard folder.kind == .folder else { throw LibraryRepositoryError.nonFolderSettings }
        let resolvedName = try validatedName(name)
        try validate(settings)
        try mutate {
            folder.name = resolvedName
            folder.normalizedName = LibraryItemRecord.normalize(resolvedName)
            folder.folderSettings = settings
            folder.modifiedAt = now
        }
    }

    public func updatePayload(
        itemID: UUID,
        state: LibraryPayloadState,
        failureDescription: String? = nil,
        pageCount: Int? = nil,
        searchableText: String? = nil,
        previewGeneration: Int64? = nil,
        now: Date = .now
    ) throws {
        let record = try requireActiveItem(itemID)
        let searchableTextProjection = searchableText.map(Self.storedSearchableTextProjection)
        try mutate {
            record.payloadState = state
            record.payloadFailureDescription = state == .failed
                ? failureDescription?.nilIfLibraryBlank
                : nil
            if let pageCount { record.pageCount = max(pageCount, 0) }
            if let searchableTextProjection {
                record.searchableText = searchableTextProjection
            }
            if let previewGeneration {
                record.previewGeneration = max(previewGeneration, 0)
            }
            record.modifiedAt = now
        }
    }

    /// Commits reproducible search/preview metadata without making the note
    /// look user-edited. Recovery and ordinary background derivation both use
    /// this path so opening an old note never moves it to Recent.
    public func updateDerivedPayload(
        itemID: UUID,
        pageCount: Int? = nil,
        searchableText: String? = nil,
        previewGeneration: Int64? = nil
    ) throws {
        let record = try requireActiveItem(itemID)
        let searchableTextProjection = searchableText.map(Self.storedSearchableTextProjection)
        try mutate {
            if let pageCount { record.pageCount = max(pageCount, 0) }
            if let searchableTextProjection {
                record.searchableText = searchableTextProjection
            }
            if let previewGeneration {
                record.previewGeneration = max(previewGeneration, 0)
            }
        }
    }

    /// Marks disposable catalog projections for repair after Canvas Core has
    /// promoted an older verified checkpoint. The intentionally higher preview
    /// generation remains as a durable recovery marker until a fresh thumbnail
    /// commits; a crash cannot otherwise distinguish recovery from an ordinary
    /// current note on the next launch. Authored data and 'modifiedAt' are never
    /// changed, while stale searchable text is fenced immediately.
    @discardableResult
    public func reconcileRecoveredPayload(
        itemID: UUID,
        verifiedGeneration: Int64,
        pageCount: Int
    ) throws -> Bool {
        let record = try requireActiveItem(itemID)
        let verifiedGeneration = max(verifiedGeneration, 0)
        guard record.previewGeneration > verifiedGeneration else { return false }
        try mutate {
            record.pageCount = max(pageCount, 0)
            record.searchableText = ""
        }
        return true
    }

    /// Reconciles the catalog projection after a soft-deleted page becomes
    /// permanently unrecoverable. Unlike ordinary payload edits this accepts a
    /// trashed owner: restoring that note later must not resurrect searchable
    /// text derived from the discarded page.
    public func reconcileDerivedPayloadAfterPageDeletion(
        itemID: UUID,
        pageCount: Int,
        searchableText: String,
        verifiedGeneration: Int64
    ) throws {
        let record = try requireItem(itemID)
        let searchableTextProjection = Self.storedSearchableTextProjection(searchableText)
        try mutate {
            record.pageCount = max(pageCount, 0)
            record.searchableText = searchableTextProjection
            record.previewGeneration = max(verifiedGeneration, 0)
        }
    }

    /// Moves an item and optionally places it before another destination child.
    /// Passing no ordering target appends it to the destination.
    public func moveItem(
        id: UUID,
        toParentID parentID: UUID?,
        beforeItemID: UUID? = nil,
        now: Date = .now
    ) throws {
        let record = try requireActiveItem(id)
        let subtree: [LibraryItemRecord]?
        if record.kind == .folder {
            if parentID == id { throw LibraryRepositoryError.cycleDetected }
            subtree = try boundedSubtreeRecords(
                rootID: id,
                candidates: activeItems,
                maximumCount: Self.maximumSubtreeMutationItemCount
            )
        } else {
            subtree = nil
        }

        let index = itemIndex
        let destinationDepth = try validatedDestinationDepth(parentID, index: index)

        if let subtree {
            let descendants = Set(subtree.dropFirst().map(\.id))
            if let parentID, descendants.contains(parentID) {
                throw LibraryRepositoryError.cycleDetected
            }

        let span = maximumFolderSpan(root: record, subtree: subtree)
        if destinationDepth + span > Self.maximumFolderDepth {
            throw LibraryRepositoryError.maximumFolderDepthExceeded(
                maximum: Self.maximumFolderDepth
            )
        }
        }

        let order = try destinationOrder(
            parentID: parentID,
            excluding: id,
            beforeItemID: beforeItemID
        )

        try mutate {
            record.parentID = parentID
            record.manualOrder = order
            record.modifiedAt = now
        }
    }

    /// Moves a selection with all hierarchy checks evaluated against the final
    /// graph, then persists every parent/order update in one save. This avoids
    /// the partial result produced by repeatedly calling 'moveItem'.
    public func moveItems(
        ids: Set<UUID>,
        toParentID parentID: UUID?,
        now: Date = .now
    ) throws {
        guard !ids.isEmpty else { return }
        let records = try ids.map(requireActiveItem)
        let index = itemIndex
        _ = try validatedDestinationDepth(parentID, index: index)

        func projectedParent(of id: UUID) -> UUID? {
            ids.contains(id) ? parentID : index[id]?.parentID
        }

        for record in activeItems {
            var visited: Set<UUID> = [record.id]
            var currentID = record.id
            var folderDepth = record.kind == .folder ? 1 : 0
            while let nextID = projectedParent(of: currentID) {
                guard visited.insert(nextID).inserted else {
                    throw LibraryRepositoryError.cycleDetected
                }
                guard let parent = index[nextID] else {
                    throw LibraryRepositoryError.parentNotFound(nextID)
                }
                guard !parent.isTrashed else {
                    throw LibraryRepositoryError.itemTrashed(nextID)
                }
                guard parent.kind == .folder else {
                    throw LibraryRepositoryError.parentNotFolder(nextID)
                }
                folderDepth += 1
                currentID = nextID
            }
            if record.kind == .folder,
                folderDepth > Self.maximumFolderDepth {
                throw LibraryRepositoryError.maximumFolderDepthExceeded(
                    maximum: Self.maximumFolderDepth
                )
            }
        }

        var order = activeItems.lazy
            .filter { $0.parentID == parentID && !ids.contains($0.id) }
            .map(\.manualOrder)
            .max()
            .map { $0 + 1 } ?? 0
        let orderedRecords = records.sorted(by: stableOrder)
        try mutate {
            for record in orderedRecords {
                record.parentID = parentID
                record.manualOrder = order
                record.modifiedAt = now
                order += 1
            }
        }
    }

    @discardableResult
    public func duplicateItem(
        id: UUID,
        now: Date = .now
    ) throws -> LibraryItemRecord {
        let source = try requireActiveItem(id)
        return try duplicateItem(id: id, into: source.parentID, now: now)
    }

    /// Metadata-only compatibility API. New integrations should use
    /// 'prepareDuplicateItem', atomically copy every mapped asset directory,
    /// and then call 'completeDuplication'. This wrapper preserves the original
    /// payload states for callers that manage readiness themselves.
    @discardableResult
    public func duplicateItem(
        id: UUID,
        into parentID: UUID?,
        now: Date = .now
    ) throws -> LibraryItemRecord {
        try cloneSubtree(
            id: id,
            into: parentID,
            stagedForAssetCopy: false,
            now: now
        ).root
    }

    /// Creates a complete catalog clone with exact source-to-target IDs while
    /// keeping every clone in 'creating'. The clone cannot appear ready before
    /// its staged binary payload copy has succeeded.
    @discardableResult
    public func prepareDuplicateItem(
        id: UUID,
        now: Date = .now
    ) throws -> LibraryDuplicationPlan {
        let source = try requireActiveItem(id)
        return try prepareDuplicateItem(id: id, into: source.parentID, now: now)
    }

    @discardableResult
    public func prepareDuplicateItem(
        id: UUID,
        into parentID: UUID?,
        now: Date = .now
    ) throws -> LibraryDuplicationPlan {
        return try cloneSubtree(
            id: id,
            into: parentID,
            stagedForAssetCopy: true,
            now: now
        ).plan
    }

    /// Publishes the source payload states after the asset store has committed
    /// every mapped directory. The entire catalog transition uses one save.
    @discardableResult
    public func completeDuplication(
        _ plan: LibraryDuplicationPlan,
        now: Date = .now
    ) throws -> LibraryItemRecord {
        guard plan.sourceToDuplicateItemIDs.count <= Self.maximumSubtreeMutationItemCount,
            plan.finalPayloadStates.count <= Self.maximumSubtreeMutationItemCount,
            plan.finalFailureDescriptions.count <= Self.maximumSubtreeMutationItemCount else {
            throw LibraryRepositoryError.maximumSubtreeItemCountExceeded(
                maximum: Self.maximumSubtreeMutationItemCount
            )
        }
        let duplicateIDs = Set(plan.sourceToDuplicateItemIDs.values)
        guard duplicateIDs.contains(plan.rootItemID),
            duplicateIDs.count == plan.sourceToDuplicateItemIDs.count,
            Set(plan.finalPayloadStates.keys) == duplicateIDs,
            Set(plan.finalFailureDescriptions.keys).isSubset(of: duplicateIDs) else {
            throw LibraryRepositoryError.invalidDuplicationPlan
        }
        let recordsByID = Dictionary(
            items
                .filter { duplicateIDs.contains($0.id) }
                .map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        guard recordsByID.count == duplicateIDs.count,
            let root = recordsByID[plan.rootItemID] else {
            throw LibraryRepositoryError.itemNotFound(plan.rootItemID)
        }
        guard recordsByID.values.allSatisfy({
            !$0.isTrashed && $0.pendingDuplicationID == plan.operationID
        }) else {
            throw LibraryRepositoryError.invalidDuplicationPlan
        }
        try mutate {
            for (duplicateID, finalState) in plan.finalPayloadStates {
                guard let record = recordsByID[duplicateID] else {
                    throw LibraryRepositoryError.itemNotFound(duplicateID)
                }
                record.payloadState = finalState
                record.payloadFailureDescription = finalState == .failed
                    ? plan.finalFailureDescriptions[duplicateID]
                    : nil
                record.pendingDuplicationID = nil
                record.modifiedAt = now
            }
        }
        return root
    }

    /// Removes a prepared clone when its staged asset copy fails. Returned IDs
    /// let the caller discard any directories that had already been committed.
    @discardableResult
    public func cancelDuplication(
        _ plan: LibraryDuplicationPlan
    ) throws -> [UUID] {
        guard plan.sourceToDuplicateItemIDs.count <= Self.maximumSubtreeMutationItemCount else {
            throw LibraryRepositoryError.maximumSubtreeItemCountExceeded(
                maximum: Self.maximumSubtreeMutationItemCount
            )
        }
        let duplicateIDs = Set(plan.sourceToDuplicateItemIDs.values)
        let records = items.filter { duplicateIDs.contains($0.id) }
        guard records.count == duplicateIDs.count,
            records.allSatisfy({ $0.pendingDuplicationID == plan.operationID }) else {
            throw LibraryRepositoryError.invalidDuplicationPlan
        }
        let linkedPages = deletedPages.filter { duplicateIDs.contains($0.ownerItemID) }
        try mutate {
            for assignment in assignments where duplicateIDs.contains(assignment.itemID) {
                modelContext.delete(assignment)
            }
            linkedPages.forEach(modelContext.delete)
            records.forEach(modelContext.delete)
        }
        return duplicateIDs.sorted { $0.uuidString < $1.uuidString }
    }

    private func cloneSubtree(
        id: UUID,
        into parentID: UUID?,
        stagedForAssetCopy: Bool,
        now: Date
    ) throws -> (root: LibraryItemRecord, plan: LibraryDuplicationPlan) {
        let source = try requireActiveItem(id)
        let originals = try boundedSubtreeRecords(
            rootID: id,
            candidates: activeItems,
            maximumCount: Self.maximumSubtreeMutationItemCount
        )
        let index = itemIndex
        let destinationDepth = try validatedDestinationDepth(parentID, index: index)
        if source.kind == .folder {
            let span = maximumFolderSpan(root: source, subtree: originals)
            if destinationDepth + span > Self.maximumFolderDepth {
                throw LibraryRepositoryError.maximumFolderDepthExceeded(
                    maximum: Self.maximumFolderDepth
                )
            }
        }
        var validatedNames: [UUID: String] = [:]
        validatedNames.reserveCapacity(originals.count)
        for original in originals {
            validatedNames[original.id] = try validatedName(original.name)
        }
        var searchableTextProjections: [UUID: String] = [:]
        searchableTextProjections.reserveCapacity(originals.count)
        var remainingSearchableTextBytes = duplicatedSearchableTextLimit
        for original in originals {
            let inspection = Self.inspectSearchableText(
                original.searchableText,
                maximumProjectionBytes: min(
                    Self.maximumSearchableTextUTF8ByteCount,
                    remainingSearchableTextBytes
                ),
                maximumSourceBytes: remainingSearchableTextBytes
            )
            guard inspection.exceededSourceLimit == false else {
                throw LibraryRepositoryError
                    .maximumSearchableTextDuplicationByteCountExceeded(
                        maximum: duplicatedSearchableTextLimit
                    )
            }
            searchableTextProjections[original.id] = inspection.projection
            remainingSearchableTextBytes -= inspection.inspectedSourceUTF8ByteCount
        }
        let originalIDs = Set(originals.map(\.id))
        try validateTagAssignmentCapacityForClone(itemIDs: originalIDs)
        let rootName = uniqueCopyName(
            for: try validatedName(source.name),
            parentID: parentID
        )
        let operationID = UUID()
        var clonesByOriginalID: [UUID: LibraryItemRecord] = [:]
        var finalPayloadStates: [UUID: LibraryPayloadState] = [:]
        var finalFailureDescriptions: [UUID: String] = [:]
        var clonedRoot: LibraryItemRecord?

        try mutate {
            for original in originals {
                let isRoot = original.id == source.id
                let clonedParentID: UUID?
                if isRoot {
                    clonedParentID = parentID
                } else if let originalParentID = original.parentID {
                    clonedParentID = clonesByOriginalID[originalParentID]?.id
                } else {
                    clonedParentID = parentID
                }

                guard let originalName = validatedNames[original.id] else {
                    throw LibraryRepositoryError.invalidName
                }
                guard let searchableTextProjection = searchableTextProjections[original.id] else {
                    throw LibraryRepositoryError.invalidDuplicationPlan
                }
                let clone = LibraryItemRecord(
                    parentID: clonedParentID,
                    name: isRoot ? rootName : originalName,
                    kind: original.kind,
                    coverChoice: original.coverChoice,
                    payloadState: stagedForAssetCopy ? .creating : original.payloadState,
                    payloadFailureDescription: stagedForAssetCopy ? nil : original.payloadFailureDescription,
                    folderSettings: original.folderSettings,
                    createdAt: now,
                    modifiedAt: now,
                    isFavorite: false,
                    manualOrder: isRoot ? nextOrder(in: parentID) : original.manualOrder,
                    sourceFilename: original.sourceFilename,
                    sourceContentTypeIdentifier: original.sourceContentTypeIdentifier,
                    searchableText: searchableTextProjection,
                    pageCount: original.pageCount,
                    previewGeneration: original.previewGeneration,
                    pendingDuplicationID: stagedForAssetCopy ? operationID : nil
                )
                modelContext.insert(clone)
                clonesByOriginalID[original.id] = clone
                finalPayloadStates[clone.id] = original.payloadState
                if let description = original.payloadFailureDescription {
                    finalFailureDescriptions[clone.id] = description
                }
                if isRoot { clonedRoot = clone }
            }
            for assignment in assignments where originalIDs.contains(assignment.itemID) {
                guard let clone = clonesByOriginalID[assignment.itemID] else { continue }
                modelContext.insert(TagAssignment(
                    itemID: clone.id,
                    tagID: assignment.tagID,
                    createdAt: now
                ))
            }
        }
        guard let clonedRoot else {
            throw LibraryRepositoryError.persistence("The duplicate was not created.")
        }
        return (
            clonedRoot,
            LibraryDuplicationPlan(
                operationID: operationID,
                rootItemID: clonedRoot.id,
                sourceToDuplicateItemIDs: clonesByOriginalID.mapValues(\.id),
                finalPayloadStates: finalPayloadStates,
                finalFailureDescriptions: finalFailureDescriptions
            )
        )
    }

    public func setFavorite(
        itemID: UUID,
        isFavorite: Bool,
        now: Date = .now
    ) throws {
        let record = try requireActiveItem(itemID)
        guard record.isFavorite != isFavorite else { return }
        try mutate {
            record.isFavorite = isFavorite
            record.modifiedAt = now
        }
    }

    // MARK: - Tags

    public func installPresetTags(now: Date = .now) throws {
        let existingIDs = Set(tags.map(\.id))
        let existingNames = Set(tags.map(\.normalizedName))
        let missing = LibraryPresetTag.allCases.filter { preset in
            existingIDs.contains(preset.id) == false
                && existingNames.contains(LibraryItemRecord.normalize(preset.title)) == false
        }
        guard missing.isEmpty == false else { return }

        try mutate {
            for preset in missing {
                modelContext.insert(
                    TagRecord(
                        id: preset.id,
                        name: preset.title,
                        color: preset.color,
                        createdAt: now
                    )
                )
            }
        }
    }

    @discardableResult
    public func createTag(
        name: String,
        color: LibraryRGBAColor,
        now: Date = .now
    ) throws -> TagRecord {
        let resolvedName = try validatedName(name)
        guard color.isValid else { throw LibraryRepositoryError.invalidColor }
        let normalizedName = LibraryItemRecord.normalize(resolvedName)
        guard !tags.contains(where: { $0.normalizedName == normalizedName })
            else { throw LibraryRepositoryError.duplicateTagName(resolvedName) }
        let record = TagRecord(name: resolvedName, color: color, createdAt: now)
        return try mutate {
            modelContext.insert(record)
            return record
        }
    }

    public func updateTag(
        id: UUID,
        name: String,
        color: LibraryRGBAColor,
        now: Date = .now
    ) throws {
        guard let record = tag(id: id) else { throw LibraryRepositoryError.tagNotFound(id) }
        let resolvedName = try validatedName(name)
        guard color.isValid else { throw LibraryRepositoryError.invalidColor }
        let normalizedName = LibraryItemRecord.normalize(resolvedName)
        guard !tags.contains(where: {
            $0.id != id && $0.normalizedName == normalizedName
        }) else {
            throw LibraryRepositoryError.duplicateTagName(resolvedName)
        }

        try mutate {
            record.name = resolvedName
            record.normalizedName = normalizedName
            record.color = color
            record.modifiedAt = now
        }
    }

    public func deleteTag(id: UUID) throws {
        guard let record = tag(id: id) else { throw LibraryRepositoryError.tagNotFound(id) }
        try mutate {
            for assignment in assignments where assignment.tagID == id {
                modelContext.delete(assignment)
            }

            modelContext.delete(record)
        }
    }

    public func assignTag(
        tagID: UUID,
        to itemID: UUID,
        now: Date = .now
    ) throws {
        _ = try requireActiveItem(itemID)
        guard tag(id: tagID) != nil else { throw LibraryRepositoryError.tagNotFound(tagID) }
        guard !assignments.contains(where: {
            $0.itemID == itemID && $0.tagID == tagID
        }) else { return }
        try validateTagAssignmentCapacity(adding: 1)

        try mutate {
            modelContext.insert(TagAssignment(itemID: itemID, tagID: tagID, createdAt: now))
        }
    }

    public func removeTag(tagID: UUID, from itemID: UUID) throws {
        guard tag(id: tagID) != nil else { throw LibraryRepositoryError.tagNotFound(tagID) }
        _ = try requireItem(itemID)
        guard let assignment = assignments.first(where: {
            $0.itemID == itemID && $0.tagID == tagID
        }) else { return }

        try mutate {
            modelContext.delete(assignment)
        }
    }

    // MARK: - Trash

    public func moveToTrash(itemID: UUID, now: Date = .now) throws {
        try moveToTrash(itemIDs: [itemID], now: now)
    }

    /// Moves a selection to Trash in one catalog transaction. Descendants of
    /// another selected folder are normalized away before groups are formed,
    /// so an overlapping folder/child selection cannot split a subtree across
    /// multiple Trash operations or leave a partially mutated result.
    public func moveToTrash(itemIDs: Set<UUID>, now: Date = .now) throws {
        guard !itemIDs.isEmpty else { return }
        for itemID in itemIDs {
            _ = try requireActiveItem(itemID)
        }

        let roots = topmostSelectedItems(itemIDs)
        var recordsByRootID: [UUID: [LibraryItemRecord]] = [:]
        var remainingItemCount = Self.maximumSubtreeMutationItemCount
        for root in roots {
            let records = try boundedSubtreeRecords(
                rootID: root.id,
                candidates: activeItems,
                maximumCount: remainingItemCount
            )

            recordsByRootID[root.id] = records
            remainingItemCount -= records.count
        }
        let purgeAfter = now.addingTimeInterval(Self.trashRetention)
        try mutate {
            for root in roots {
                for record in recordsByRootID[root.id] ?? [] {
                    record.trashMetadata = LibraryTrashMetadata(
                        deletedAt: now,
                        purgeAfter: purgeAfter,
                        originalParentID: record.parentID,
                        originalOrder: record.manualOrder,
                        trashGroupID: root.id
                    )
                    record.isFavorite = false
                    record.modifiedAt = now
                }
            }
        }
    }

    // MARK: - Interrupted payload reconciliation

    /// Captures interrupted create/import/duplicate records without mutating
    /// the catalog. A folder anchor includes its complete subtree to prevent
    /// ready descendants from becoming orphans when an unpublished parent is
    /// removed.
    public func makeIncompletePayloadReconciliationPlan()
        -> LibraryIncompletePayloadReconciliationPlan {
        let anchors = Set(activeItems.lazy.filter {
            $0.pendingDuplicationID != nil
                || $0.payloadState == .creating
                || $0.payloadState == .importing
        }.map(\.id))
        guard anchors.isEmpty == false else {
            return LibraryIncompletePayloadReconciliationPlan()
        }

        let roots = topmostSelectedItems(anchors)
        let itemIDs = Set(roots.flatMap { root in
            subtreeRecords(rootID: root.id, candidates: activeItems).map(\.id)
        })
        let entries = activeItems
            .filter { itemIDs.contains($0.id) }
            .map {
                LibraryIncompletePayloadEntry(
                    itemID: $0.id,
                    payloadState: $0.payloadState,
                    pendingDuplicationID: $0.pendingDuplicationID
                )
            }
            .sorted { $0.itemID.uuidString < $1.itemID.uuidString }

        return LibraryIncompletePayloadReconciliationPlan(
            rootItemIDs: roots.map(\.id).sorted { $0.uuidString < $1.uuidString },
            entries: entries
        )
    }

    /// Removes exactly the interrupted records captured by `plan` in one save.
    /// Asset directories should already be in recoverable storage; validation
    /// rejects a stale plan if any record became ready in the meantime.
    @discardableResult
    public func commitIncompletePayloadReconciliation(
        _ plan: LibraryIncompletePayloadReconciliationPlan
    ) throws -> [UUID] {
        guard plan.isEmpty == false else { return [] }
        guard makeIncompletePayloadReconciliationPlan() == plan else {
            throw LibraryRepositoryError.invalidIncompletePayloadPlan
        }

        let itemIDs = Set(plan.itemIDs)
        let records = items.filter { itemIDs.contains($0.id) }
        let linkedPages = deletedPages.filter { itemIDs.contains($0.ownerItemID) }
        guard records.count == itemIDs.count else {
            throw LibraryRepositoryError.invalidIncompletePayloadPlan
        }
        try mutate {
            for assignment in assignments where itemIDs.contains(assignment.itemID) {
                modelContext.delete(assignment)
            }
            linkedPages.forEach(modelContext.delete)
            records.forEach(modelContext.delete)
        }
        return plan.itemIDs
    }

    public func restoreFromTrash(itemID: UUID, now: Date = .now) throws {
        let requested = try requireItem(itemID)
        guard let requestedMetadata = requested.trashMetadata else {
            throw LibraryRepositoryError.itemNotTrashed(itemID)
        }

        let groupID = requestedMetadata.trashGroupID
        var group: [LibraryItemRecord] = []
        group.reserveCapacity(min(items.count, Self.maximumSubtreeMutationItemCount))
        for record in items where record.trashMetadata?.trashGroupID == groupID {
            guard group.count < Self.maximumSubtreeMutationItemCount else {
                throw LibraryRepositoryError.maximumSubtreeItemCountExceeded(
                    maximum: Self.maximumSubtreeMutationItemCount
                )
            }
            group.append(record)
        }
        guard let root = group.first(where: { $0.id == groupID }) ?? group.first,
            let rootMetadata = root.trashMetadata else {
            throw LibraryRepositoryError.itemNotTrashed(itemID)
        }

        var restoredParentID = rootMetadata.originalParentID
        if let candidateID = restoredParentID {
            let parent = item(id: candidateID)
            if parent == nil || parent?.kind != .folder || parent?.isTrashed == true {
                restoredParentID = nil
            }
        }

        if let candidateParentID = restoredParentID {
            let destinationDepth = try validatedDestinationDepth(
                candidateParentID,
                index: itemIndex
            )
            let span = maximumFolderSpan(root: root, subtree: group)
            if root.kind == .folder,
                destinationDepth + span > Self.maximumFolderDepth {
                // The original hierarchy may have changed while this was in
                // Trash; root is the safe, deterministic fallback.
                restoredParentID = nil
            }
        }

        let fallbackOrder = nextOrder(in: restoredParentID)
        try mutate {
            for record in group {
                guard let metadata = record.trashMetadata else { continue }
                if record.id == root.id {
                    record.parentID = restoredParentID
                    record.manualOrder = restoredParentID == metadata.originalParentID
                        ? metadata.originalOrder
                        : fallbackOrder
                } else {
                    record.parentID = metadata.originalParentID
                    record.manualOrder = metadata.originalOrder
                }
                record.trashMetadata = nil
                record.modifiedAt = now
            }
        }
    }

    /// Deletes one Trash group and returns item IDs whose asset directories may
    /// now be removed. Separately trashed descendants are intentionally kept.
    @discardableResult
    public func permanentlyDelete(itemID: UUID) throws -> [UUID] {
        try commitPurge(makePermanentDeletionPlan(itemID: itemID)).itemIDs
    }

    /// Captures one Trash group without deleting metadata. Move its item and
    /// page assets to recovery first, then pass the plan to `commitPurge(_)`.
    public func makePermanentDeletionPlan(
        itemID: UUID
    ) throws -> LibraryPurgePlan {
        let requested = try requireItem(itemID)
        guard let metadata = requested.trashMetadata else {
            throw LibraryRepositoryError.itemNotTrashed(itemID)
        }
        let group = items.filter { $0.trashMetadata?.trashGroupID == metadata.trashGroupID }
        let ids = Set(group.map(\.id))
        let linkedDeletedPages = deletedPages.filter { ids.contains($0.ownerItemID) }
        return LibraryPurgePlan(
            itemIDs: ids.sorted { $0.uuidString < $1.uuidString },
            deletedPageAssets: linkedDeletedPages.map(\.assetDescriptor)
        )
    }

    @discardableResult
    public func purgeExpiredTrash(now: Date = .now) throws -> LibraryPurgeResult {
        try commitPurge(makePurgePlan(now: now))
    }

    /// Captures every catalog record and page payload that is eligible for
    /// retention cleanup without mutating SwiftData. Callers can first move
    /// those assets to recoverable storage, then acknowledge with
    /// `commitPurge(_)`.
    public func makePurgePlan(now: Date = .now) -> LibraryPurgePlan {
        let expiredGroups = Set(items.compactMap { record -> UUID? in
            guard let metadata = record.trashMetadata,
                metadata.purgeAfter <= now else { return nil }
            return metadata.trashGroupID
        })
        let doomedItems = items.filter { record in
            guard let groupID = record.trashMetadata?.trashGroupID else { return false }
            return expiredGroups.contains(groupID)
        }
        let doomedIDs = Set(doomedItems.map(\.id))
        let expiredPages = deletedPages.filter {
            $0.purgeAfter <= now || doomedIDs.contains($0.ownerItemID)
        }

        return LibraryPurgePlan(
            itemIDs: doomedIDs.sorted { $0.uuidString < $1.uuidString },
            deletedPageAssets: expiredPages.map(\.assetDescriptor)
                .sorted { $0.recordID.uuidString < $1.recordID.uuidString }
        )
    }

    /// Captures obsolete freeform Canvas records without mutating the catalog.
    /// Callers stage complete item directories in recovery storage first.
    public func makeLegacyCanvasRemovalPlan() -> LibraryPurgePlan {
        let doomedItems = items.filter { $0.kind == .canvas }
        let doomedIDs = Set(doomedItems.map(\.id))
        let linkedPages = deletedPages.filter { doomedIDs.contains($0.ownerItemID) }
        return LibraryPurgePlan(
            itemIDs: doomedIDs.sorted { $0.uuidString < $1.uuidString },
            deletedPageAssets: linkedPages.map(\.assetDescriptor)
                .sorted { $0.recordID.uuidString < $1.recordID.uuidString }
        )
    }

    /// Removes the exact migration-sentinel set in one SwiftData save,
    /// including tag assignments and deleted-page tombstones.
    @discardableResult
    public func commitLegacyCanvasRemoval(
        _ plan: LibraryPurgePlan
    ) throws -> LibraryPurgeResult {
        guard !plan.isEmpty else { return LibraryPurgeResult() }
        guard makeLegacyCanvasRemovalPlan() == plan else {
            throw LibraryRepositoryError.invalidLegacyCanvasRemovalPlan
        }
        let doomedIDs = Set(plan.itemIDs)
        let pageIDs = Set(plan.deletedPageAssets.map(\.recordID))
        let doomedItems = items.filter { doomedIDs.contains($0.id) && $0.kind == .canvas }
        let doomedPages = deletedPages.filter { pageIDs.contains($0.id) }
        guard doomedItems.count == doomedIDs.count,
            doomedPages.count == pageIDs.count else {
            throw LibraryRepositoryError.invalidLegacyCanvasRemovalPlan
        }

        try mutate {
            for assignment in assignments where doomedIDs.contains(assignment.itemID) {
                modelContext.delete(assignment)
            }
            doomedPages.forEach(modelContext.delete)
            doomedItems.forEach(modelContext.delete)
        }
        return LibraryPurgeResult(
            itemIDs: plan.itemIDs,
            deletedPageCount: doomedPages.count,
            deletedPageAssets: plan.deletedPageAssets
        )
    }

    /// Removes only the records captured by a previously prepared plan. Asset
    /// cleanup should already be staged so a save failure can restore files.
    @discardableResult
    public func commitPurge(_ plan: LibraryPurgePlan) throws -> LibraryPurgeResult {
        guard !plan.isEmpty else { return LibraryPurgeResult() }

        let doomedIDs = Set(plan.itemIDs)
        let pageRecordIDs = Set(plan.deletedPageAssets.map(\.recordID))
        let doomedItems = items.filter { doomedIDs.contains($0.id) && $0.isTrashed }
        let actualDoomedIDs = Set(doomedItems.map(\.id))
        let expiredPages = deletedPages.filter { pageRecordIDs.contains($0.id) }

        guard actualDoomedIDs == doomedIDs,
            Set(expiredPages.map(\.id)) == pageRecordIDs else {
            throw LibraryRepositoryError.invalidPurgePlan
        }

        guard !doomedItems.isEmpty || !expiredPages.isEmpty else {
            return LibraryPurgeResult()
        }

        try mutate {
            for assignment in assignments where actualDoomedIDs.contains(assignment.itemID) {
                modelContext.delete(assignment)
            }
            expiredPages.forEach(modelContext.delete)
            doomedItems.forEach(modelContext.delete)
        }
        return LibraryPurgeResult(
            itemIDs: actualDoomedIDs.sorted { $0.uuidString < $1.uuidString },
            deletedPageCount: expiredPages.count,
            deletedPageAssets: expiredPages.map(\.assetDescriptor)
        )
    }

    // MARK: - Soft-deleted pages

    @discardableResult
    public func registerDeletedPage(
        pageID: UUID,
        ownerItemID: UUID,
        originalIndex: Int,
        payloadRelativePath: String,
        title: String? = nil,
        now: Date = .now
    ) throws -> DeletedPageRecord {
        let owner = try requireActiveItem(ownerItemID)
        guard LibraryAssetPath.isSafeRelative(payloadRelativePath) else {
            throw LibraryRepositoryError.invalidAssetPath
        }
        let record = DeletedPageRecord(
            pageID: pageID,
            ownerItemID: ownerItemID,
            deletedAt: now,
            purgeAfter: now.addingTimeInterval(Self.trashRetention),
            originalIndex: originalIndex,
            payloadRelativePath: payloadRelativePath,
            title: title
        )

        return try mutate {
            modelContext.insert(record)
            owner.pageCount = Self.pageCountAfterRemovingPage(owner.pageCount)
            owner.modifiedAt = now
            return record
        }
    }

    @discardableResult
    public func takeDeletedPageForRestore(
        id: UUID,
        now: Date = .now
    ) throws -> LibraryDeletedPageRestoration {
        let restoration = try deletedPageRestoration(id: id)
        try acknowledgeDeletedPageRestored(id: id, now: now)
        return restoration
    }

    /// Reads restoration metadata without consuming it. Restore and verify the
    /// physical page first, then call `acknowledgeDeletedPageRestored`.
    public func deletedPageRestoration(
        id: UUID
    ) throws -> LibraryDeletedPageRestoration {
        guard let record = deletedPages.first(where: { $0.id == id }) else {
            throw LibraryRepositoryError.deletedPageNotFound(id)
        }
        guard let owner = item(id: record.ownerItemID), !owner.isTrashed else {
            throw LibraryRepositoryError.pageOwnerNotFound(record.ownerItemID)
        }

        return LibraryDeletedPageRestoration(
            pageID: record.pageID,
            ownerItemID: record.ownerItemID,
            originalIndex: record.originalIndex,
            payloadRelativePath: record.payloadRelativePath,
            title: record.title
        )
    }

    /// Consumes a page tombstone only after the page layer has successfully
    /// restored and verified its payload.
    public func acknowledgeDeletedPageRestored(
        id: UUID,
        now: Date = .now
    ) throws {
        guard let record = deletedPages.first(where: { $0.id == id }) else {
            throw LibraryRepositoryError.deletedPageNotFound(id)
        }
        guard let owner = item(id: record.ownerItemID), !owner.isTrashed else {
            throw LibraryRepositoryError.pageOwnerNotFound(record.ownerItemID)
        }
        try mutate {
            modelContext.delete(record)
            owner.pageCount = Self.pageCountAfterRestoringPage(owner.pageCount)
            owner.modifiedAt = now
        }
    }

    /// Reverses page registration when the live editor rejects removal after
    /// the archive and tombstone were committed. The page archive remains the
    /// caller's responsibility so filesystem and catalog work can be staged in
    /// recoverable storage around this transaction.
    @discardableResult
    public func cancelDeletedPageRegistration(
        id: UUID,
        now: Date = .now
    ) throws -> LibraryDeletedPageAsset {
        guard let record = deletedPages.first(where: { $0.id == id }) else {
            throw LibraryRepositoryError.deletedPageNotFound(id)
        }
        guard let owner = item(id: record.ownerItemID), !owner.isTrashed else {
            throw LibraryRepositoryError.pageOwnerNotFound(record.ownerItemID)
        }
        let descriptor = record.assetDescriptor
        try mutate {
            modelContext.delete(record)
            owner.pageCount = Self.pageCountAfterRestoringPage(owner.pageCount)
            owner.modifiedAt = now
        }
        return descriptor
    }

    /// Permanently removes one page tombstone after its archived payload has
    /// been moved to recovery storage. The returned descriptor can be retained
    /// until that recovery entry is safely discarded.
    @discardableResult
    public func permanentlyDeletePage(
        id: UUID
    ) throws -> LibraryDeletedPageAsset {
        guard let record = deletedPages.first(where: { $0.id == id }) else {
            throw LibraryRepositoryError.deletedPageNotFound(id)
        }
        let descriptor = record.assetDescriptor
        try mutate {
            modelContext.delete(record)
        }
        return descriptor
    }

    // MARK: - Validation and mechanics

    private var activeItems: [LibraryItemRecord] {
        items.filter { !$0.isTrashed && $0.kind.isLegacyLibraryItem == false }
    }

    private var itemIndex: [UUID: LibraryItemRecord] {
        Dictionary(
            items.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
    }

    private static func pageCountAfterRemovingPage(_ pageCount: Int) -> Int {
        guard pageCount > 0 else { return 0 }
        return pageCount - 1
    }

    private static func pageCountAfterRestoringPage(_ pageCount: Int) -> Int {
        let nonnegativePageCount = max(pageCount, 0)
        let (incrementedPageCount, overflowed) = nonnegativePageCount.addingReportingOverflow(1)
        return overflowed ? Int.max : incrementedPageCount
    }

    private func validateTagAssignmentCapacity(adding additionalCount: Int) throws {
        guard additionalCount >= 0,
            assignments.count <= tagAssignmentLimit,
            additionalCount <= tagAssignmentLimit - assignments.count else {
            throw LibraryRepositoryError.maximumTagAssignmentCountExceeded(
                maximum: tagAssignmentLimit
            )
        }
    }

    private func validateTagAssignmentCapacityForClone(itemIDs: Set<UUID>) throws {
        try validateTagAssignmentCapacity(adding: 0)
        var remainingCapacity = tagAssignmentLimit - assignments.count
        for assignment in assignments where itemIDs.contains(assignment.itemID) {
            guard remainingCapacity > 0 else {
                throw LibraryRepositoryError.maximumTagAssignmentCountExceeded(
                    maximum: tagAssignmentLimit
                )
            }
            remainingCapacity -= 1
        }
    }

    private func requireItem(_ id: UUID) throws -> LibraryItemRecord {
        guard let record = item(id: id) else {
            throw LibraryRepositoryError.itemNotFound(id)
        }
        return record
    }

    private func requireActiveItem(_ id: UUID) throws -> LibraryItemRecord {
        let record = try requireItem(id)
        guard !record.isTrashed else { throw LibraryRepositoryError.itemTrashed(id) }
        return record
    }

    /// Returns selected records that have no selected ancestor. All IDs must
    /// already have been validated as active by the caller.
    private func topmostSelectedItems(_ selectedIDs: Set<UUID>) -> [LibraryItemRecord] {
        let index = itemIndex
        return selectedIDs.compactMap { index[$0] }.filter { record in
            var parentID = record.parentID
            var visited: Set<UUID> = []
            while let candidateID = parentID,
                visited.insert(candidateID).inserted,
                let candidate = index[candidateID] {
                if selectedIDs.contains(candidateID) { return false }
                parentID = candidate.parentID
            }
            return true
        }.sorted(by: stableOrder)
    }

    private struct SearchableTextInspection {
        let projection: String
        let inspectedSourceUTF8ByteCount: Int
        let exceededSourceLimit: Bool
    }

    /// Produces a valid Unicode prefix while independently bounding how much
    /// source text is inspected. Charging source bytes (rather than only the
    /// much smaller retained prefix) is important for legacy rows that predate
    /// the per-record projection limit.
    private static func inspectSearchableText(
        _ value: String,
        maximumProjectionBytes: Int,
        maximumSourceBytes: Int
    ) -> SearchableTextInspection {
        let projectionLimit = max(maximumProjectionBytes, 0)
        let sourceLimit = max(maximumSourceBytes, 0)
        let scalars = value.unicodeScalars
        var position = scalars.startIndex
        var projectionEnd = scalars.startIndex
        var inspectedBytes = 0

        while position != scalars.endIndex {
            let scalar = scalars[position]
            let scalarByteCount = scalar.utf8.count
            guard scalarByteCount <= sourceLimit - inspectedBytes else {
                return SearchableTextInspection(
                    projection: String(value[..<projectionEnd]),
                    inspectedSourceUTF8ByteCount: inspectedBytes,
                    exceededSourceLimit: true
                )
            }
            inspectedBytes += scalarByteCount
            position = scalars.index(after: position)
            if inspectedBytes <= projectionLimit {
                projectionEnd = position
            }
        }

        return SearchableTextInspection(
            projection: projectionEnd == value.endIndex
                ? value
                : String(value[..<projectionEnd]),
            inspectedSourceUTF8ByteCount: inspectedBytes,
            exceededSourceLimit: false
        )
    }

    private static func storedSearchableTextProjection(_ value: String) -> String {
        // Fold only a bounded raw prefix. Unicode folding can allocate a new
        // buffer and may expand some representations, so normalizing an
        // attacker-sized or corrupt caller string before truncating would
        // defeat the storage boundary's transient-memory guarantee.
        let rawInspection = inspectSearchableText(
            value,
            maximumProjectionBytes: maximumSearchableTextUTF8ByteCount,
            maximumSourceBytes: maximumSearchableTextUTF8ByteCount
        )
        let boundedRawValue = rawInspection.exceededSourceLimit
            ? rawInspection.projection
            : value
        let normalized = LibraryItemRecord.normalize(boundedRawValue)
        let normalizedInspection = inspectSearchableText(
            normalized,
            maximumProjectionBytes: maximumSearchableTextUTF8ByteCount,
            maximumSourceBytes: maximumSearchableTextUTF8ByteCount
        )
        return normalizedInspection.exceededSourceLimit
            ? normalizedInspection.projection
            : normalized
    }

    private func validatedName(_ value: String) throws -> String {
        guard value.utf8.count <= Self.maximumNameUTF8ByteCount else {
            throw LibraryRepositoryError.nameTooLong(
                maximumUTF8Bytes: Self.maximumNameUTF8ByteCount
            )
        }
        guard let value = value.nilIfLibraryBlank else {
            throw LibraryRepositoryError.invalidName
        }
        return value
    }

    private func validate(_ settings: LibraryFolderSettings) throws {
        guard settings.color.isValid else { throw LibraryRepositoryError.invalidColor }
    }

    private func validateCover(_ cover: LibraryCoverChoice) throws {
        if case let .customAsset(relativePath) = cover,
            !LibraryAssetPath.isSafeRelative(relativePath) {
            throw LibraryRepositoryError.invalidAssetPath
        }
    }

    private func validatedDestinationDepth(
        _ parentID: UUID?,
        index: [UUID: LibraryItemRecord]
    ) throws -> Int {
        guard let parentID else { return 0 }
        guard let parent = index[parentID] else {
            throw LibraryRepositoryError.parentNotFound(parentID)
        }
        guard !parent.isTrashed else { throw LibraryRepositoryError.itemTrashed(parentID) }
        guard parent.kind == .folder else {
            throw LibraryRepositoryError.parentNotFolder(parentID)
        }
        return try folderDepth(of: parent, index: index)
    }

    private func folderDepth(
        of record: LibraryItemRecord,
        index: [UUID: LibraryItemRecord]
    ) throws -> Int {
        var depth = record.kind == .folder ? 1 : 0
        var parentID = record.parentID
        var visited: Set<UUID> = [record.id]
        while let currentID = parentID {
            guard visited.insert(currentID).inserted else {
                throw LibraryRepositoryError.cycleDetected
            }
            guard let parent = index[currentID] else { break }
            if parent.kind == .folder { depth += 1 }
            parentID = parent.parentID
        }
        return depth
    }

    private func subtreeRecords(
        rootID: UUID,
        candidates: [LibraryItemRecord]
    ) -> [LibraryItemRecord] {
        guard let root = candidates.first(where: { $0.id == rootID }) else { return [] }
        let byParent = Dictionary(grouping: candidates) { $0.parentID }
        var result: [LibraryItemRecord] = []
        var visited: Set<UUID> = []
        var pending = [root]
        while let record = pending.popLast() {
            guard visited.insert(record.id).inserted else { continue }
            result.append(record)
            // Push in reverse so the iterative traversal preserves the same
            // stable preorder as the former recursive walk without making
            // corrupt or migrated hierarchy depth consume the call stack.
            pending.append(
                contentsOf: (byParent[record.id] ?? [])
                .sorted(by: stableOrder)
                .reversed()
            )
        }
        return result
    }

    /// Builds only the requested hierarchy and refuses before a mutating
    /// operation can retain an unbounded number of records and validation
    /// maps. Unlike `subtreeRecords`, this intentionally avoids grouping the
    /// complete catalog: breadth-first discovery scans each hierarchy level
    /// and stores adjacency only for descendants that pass the cap.
    private func boundedSubtreeRecords(
        rootID: UUID,
        candidates: [LibraryItemRecord],
        maximumCount: Int
    ) throws -> [LibraryItemRecord] {
        guard maximumCount > 0 else {
            throw LibraryRepositoryError.maximumSubtreeItemCountExceeded(
                maximum: Self.maximumSubtreeMutationItemCount
            )
        }
        guard let root = candidates.first(where: { $0.id == rootID }) else { return [] }

        var discoveredIDs: Set<UUID> = [root.id]
        discoveredIDs.reserveCapacity(min(candidates.count, maximumCount))
        var childrenByParentID: [UUID: [LibraryItemRecord]] = [:]
        var frontier = [root]
        var descendantLevel = 0

        while frontier.isEmpty == false {
            // A valid hierarchy has at most five folder levels and documents
            // are leaves. This also bounds scans of a corrupt legacy graph to
            // five descendant levels plus one leaf-verification pass.
            guard descendantLevel <= Self.maximumFolderDepth else {
                throw LibraryRepositoryError.maximumFolderDepthExceeded(
                    maximum: Self.maximumFolderDepth
                )
            }
            let childLevel = descendantLevel + 1
            let parentIDs = Set(frontier.map(\.id))
            let folderParentIDs = Set(frontier.lazy
                .filter { $0.kind == .folder }
                .map(\.id))
            var nextFrontier: [LibraryItemRecord] = []
            for candidate in candidates {
                guard let parentID = candidate.parentID,
                    parentIDs.contains(parentID),
                    discoveredIDs.contains(candidate.id) == false else {
                    continue
                }
                guard folderParentIDs.contains(parentID) else {
                    throw LibraryRepositoryError.parentNotFolder(parentID)
                }
                if candidate.kind == .folder,
                    childLevel >= Self.maximumFolderDepth {
                    throw LibraryRepositoryError.maximumFolderDepthExceeded(
                        maximum: Self.maximumFolderDepth
                    )
                }
                guard discoveredIDs.count < maximumCount else {
                    throw LibraryRepositoryError.maximumSubtreeItemCountExceeded(
                        maximum: maximumCount
                    )
                }
                discoveredIDs.insert(candidate.id)
                childrenByParentID[parentID, default: []].append(candidate)
                nextFrontier.append(candidate)
            }
        frontier = nextFrontier
        descendantLevel = childLevel
        }

        for parentID in Array(childrenByParentID.keys) {
            childrenByParentID[parentID]?.sort(by: stableOrder)
        }

        var result: [LibraryItemRecord] = []
        result.reserveCapacity(discoveredIDs.count)
        var pending = [root]
        while let record = pending.popLast() {
            result.append(record)
            pending.append(
                contentsOf: (childrenByParentID[record.id] ?? []).reversed()
            )
        }
        return result
    }

    private func maximumFolderSpan(
        root: LibraryItemRecord,
        subtree: [LibraryItemRecord]
    ) -> Int {
        guard root.kind == .folder else { return 0 }
        let subtreeIndex = Dictionary(
            subtree.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        var maximum = 1
        for folder in subtree where folder.kind == .folder {
            var depth = 1
            var parentID = folder.parentID
            var visited: Set<UUID> = [folder.id]
            while let currentID = parentID,
                let parent = subtreeIndex[currentID] {
                guard visited.insert(currentID).inserted,
                    parent.kind == .folder else {
                    return Self.maximumFolderDepth + 1
                }
                depth += 1
                guard depth <= Self.maximumFolderDepth else { return depth }
                parentID = parent.parentID
            }
            maximum = max(maximum, depth)
        }
        return maximum
    }

    private func nextOrder(in parentID: UUID?) -> Double {
        activeItems.lazy
            .filter { $0.parentID == parentID }
            .map(\.manualOrder)
            .max()
            .map { $0 + 1 } ?? 0
    }

    private func destinationOrder(
        parentID: UUID?,
        excluding itemID: UUID,
        beforeItemID: UUID?
    ) throws -> Double {
        let siblings = activeItems
            .filter { $0.parentID == parentID && $0.id != itemID }
            .sorted(by: stableOrder)
        guard let beforeItemID else {
            return siblings.last.map { $0.manualOrder + 1 } ?? 0
        }
        guard let index = siblings.firstIndex(where: { $0.id == beforeItemID }) else {
            throw LibraryRepositoryError.invalidOrderingTarget(beforeItemID)
        }
        guard index > 0 else { return siblings[index].manualOrder - 1 }
        return (siblings[index - 1].manualOrder + siblings[index].manualOrder) / 2
    }

    private func uniqueCopyName(for name: String, parentID: UUID?) -> String {
        let siblingNames = Set(activeItems.lazy
            .filter { $0.parentID == parentID }
            .map(\.normalizedName))
        func candidate(_ ordinal: Int?) -> String {
            let suffix = ordinal.map { " Copy \($0)" } ?? " Copy"
            let availableStemBytes = max(
                Self.maximumNameUTF8ByteCount - suffix.utf8.count,
                0
            )
            return utf8SafePrefix(name, maximumBytes: availableStemBytes)
                + suffix
        }
        let base = candidate(nil)
        if !siblingNames.contains(LibraryItemRecord.normalize(base)) { return base }
        var suffix = 2
        while siblingNames.contains(
            LibraryItemRecord.normalize(candidate(suffix))
        ) {
            let (next, overflow) = suffix.addingReportingOverflow(1)
            guard overflow == false else {
                return candidate(nil)
            }
            suffix = next
        }
        return candidate(suffix)
    }

    private func utf8SafePrefix(
        _ value: String,
        maximumBytes: Int
    ) -> String {
        guard maximumBytes > 0 else { return "" }
        var result = ""
        result.reserveCapacity(min(value.utf8.count, maximumBytes))
        var usedBytes = 0
        for character in value {
            let characterText = String(character)
            let byteCount = characterText.utf8.count
            guard byteCount <= maximumBytes - usedBytes else { break }
            result.append(character)
            usedBytes += byteCount
        }
        return result
    }

    private func sorted(
        _ records: [LibraryItemRecord],
        by sort: LibrarySort
    ) -> [LibraryItemRecord] {
        records.sorted { lhs, rhs in
            let ascending: Bool
            let equal: Bool
            switch sort.field {
            case .activity:
                ascending = lhs.activityDate < rhs.activityDate
                equal = lhs.activityDate == rhs.activityDate
            case .name:
                let comparison = lhs.normalizedName.localizedStandardCompare(rhs.normalizedName)
                ascending = comparison == .orderedAscending
                equal = comparison == .orderedSame
            case .created:
                ascending = lhs.createdAt < rhs.createdAt
                equal = lhs.createdAt == rhs.createdAt
            case .type:
                if lhs.kind.rawValue == rhs.kind.rawValue {
                    let comparison = lhs.normalizedName.localizedStandardCompare(rhs.normalizedName)
                    ascending = comparison == .orderedAscending
                    equal = comparison == .orderedSame
                } else {
                    ascending = lhs.kind.rawValue < rhs.kind.rawValue
                    equal = false
                }
            }
            if equal {
                if lhs.manualOrder != rhs.manualOrder {
                    return lhs.manualOrder < rhs.manualOrder
                }
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return sort.direction == .ascending ? ascending : !ascending
        }
    }


    private func stableOrder(_ lhs: LibraryItemRecord, _ rhs: LibraryItemRecord) -> Bool {
        if lhs.manualOrder != rhs.manualOrder { return lhs.manualOrder < rhs.manualOrder }
        if lhs.createdAt != rhs.createdAt { return lhs.createdAt < rhs.createdAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }

    @discardableResult
    private func mutate<Result>(_ work: () throws -> Result) throws -> Result {
        let result: Result
        do {
            // One explicit SwiftData save is the transaction boundary. All
            // semantic validation happens before this method; if either the
            // mutation closure or store save fails, rollback restores the
            // complete pre-mutation graph.
            result = try work()
            try modelContext.save()
        } catch {
            modelContext.rollback()
            try? refresh()
            throw map(error)
        }

        // The save above is already durable. A fetch failure must not make the
        // mutation look unsuccessful, because retrying could duplicate work.
        // `refresh()` records the diagnostic for the host to surface/retry.
        try? refresh()
        return result
    }

    private func map(_ error: Error) -> LibraryRepositoryError {
        if let error = error as? LibraryRepositoryError { return error }
        return .persistence(String(describing: error))
    }
}

private extension DeletedPageRecord {
    var assetDescriptor: LibraryDeletedPageAsset {
        LibraryDeletedPageAsset(
            recordID: id,
            pageID: pageID,
            ownerItemID: ownerItemID,
            payloadRelativePath: payloadRelativePath
        )
    }
}
