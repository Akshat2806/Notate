import CoreGraphics
@preconcurrency import CoreSpotlight
import CryptoKit
import Foundation
import os
import PaperKit
import PDFKit
import SQLite3
import UniformTypeIdentifiers

/// A synchronous invalidation ledger for source sets that have already passed
/// the actor-isolated freshness checks below. The UI's absolute watchdog and
/// Stop action cannot await index or Spotlight I/O, so they claim one of these
/// receipts under the same lock that semantic index mutations advance before
/// making their replacement state visible.
private final class NotebookIndexFreshnessLedger: @unchecked Sendable {
    private let revisions = OSAllocatedUnfairLock(
        initialState: [UUID: UInt64]()
    )

    func invalidate(itemIDs: some Sequence<UUID>) {
        let itemIDs = Set(itemIDs)
        revisions.withLock { current in
            for itemID in itemIDs {
                current[itemID, default: 0] &+= 1
            }
        }
    }

    func snapshot(itemIDs: some Sequence<UUID>) -> [UUID: UInt64] {
        let itemIDs = Set(itemIDs)
        return revisions.withLock { current in
            Dictionary(
                itemIDs.map { itemID in
                    (itemID, current[itemID, default: 0])
                },
                uniquingKeysWith: { current, _ in current }
            )
        }
    }

    func performIfCurrent(
        _ expected: [UUID: UInt64],
        _ body: () -> Void
    ) -> Bool {
        // The body is synchronous and deliberately retains the caller's actor
        // isolation (the only production caller publishes MainActor UI state).
        // `withLockUnchecked` is appropriate because this ledger owns the lock
        // and never lets the closure or protected state escape the critical section.
        revisions.withLockUnchecked { current in
            guard expected.allSatisfy({ itemID, revision in
                current[itemID, default: 0] == revision
            }) else { return false }
            body()
            return true
        }
    }
}

/// Generation-safe, chunk-level retrieval for verified Canvas Core snapshots.
/// The default backend is deterministic in-memory lexical search. Production
/// may opt into a protected Core Spotlight index for ranked semantic retrieval.
public actor NotebookIndex {
    private enum PermanentPurgeError: LocalizedError {
        case spotlightDeletionFailed

        var errorDescription: String? {
            switch self {
            case .spotlightDeletionFailed:
                "The system search index could not verify permanent deletion."
            }
        }
    }

    struct PublicationReceipt: @unchecked Sendable {
        fileprivate let ledger: NotebookIndexFreshnessLedger
        fileprivate let itemRevisions: [UUID: UInt64]

        /// Runs a short, non-suspending publication transaction only while no
        /// represented item's semantic index state has changed since minting.
        func performIfCurrent(_ body: () -> Void) -> Bool {
            ledger.performIfCurrent(itemRevisions, body)
        }

        /// Typed partials cite an exact subset of a broader retrieval result.
        /// Narrowing prevents an unrelated Library item from invalidating an
        /// otherwise current partial while retaining the original epochs.
        func restricted(to itemIDs: Set<UUID>) -> PublicationReceipt? {
            guard itemIDs.isEmpty == false,
                itemIDs.isSubset(of: itemRevisions.keys) else { return nil }
            return PublicationReceipt(
                ledger: ledger,
                itemRevisions: itemRevisions.filter { itemIDs.contains($0.key) }
            )
        }
    }

    struct ValidatedPublication: Sendable {
        let sources: [AssistantSearchResult]
        let receipt: PublicationReceipt
    }

    static let maximumChunkLength = 1_200
    /// Character counts do not bound storage: one extended grapheme can carry
    /// megabytes of combining scalars. Every retained/searchable chunk must
    /// also fit this byte ceiling.
    static let maximumChunkUTF8ByteCount = 16 * 1_024
    static let chunkOverlapLength = 180
    /// Search indexing is a derived convenience, so it must never duplicate a
    /// persistence-sized payload into an attacker-controlled number of token
    /// and posting objects. Match the importer's eight-MiB native-text budget;
    /// the expanded allowance includes the bounded overlap between chunks.
    static let maximumIndexedSourceTextUTF8ByteCount = 8 * 1_024 * 1_024
    static let maximumExpandedTextUTF8ByteCount = 16 * 1_024 * 1_024
    static let maximumIndexedItemNameUTF8ByteCount =
        LibraryRepository.maximumNameUTF8ByteCount
    static let maximumLexicalDistinctTermCount = 65_536
    static let maximumLexicalPostingEntryCount = 262_144
    static let maximumSearchQueryUTF8ByteCount =
        AssistantModelRequest.maximumQuestionUTF8ByteCount
    static let maximumSearchTermCount = 32
    private static let defaultSpotlightMutationTimeout: Duration = .seconds(8)
    private static let focusedHydrationFallbackReserve: Duration = .milliseconds(100)
    private static let maximumCachedItems = 24
    private static let maximumCachedUnits = 8_192
    private static let maximumCachedTextUTF8ByteCount = 32 * 1_024 * 1_024
    private static let maximumSingleCachedUnits = 32_768
    private static let maximumRecentSpotlightUnits = 256
    private static let maximumRecentSpotlightTextUTF8ByteCount = 4 * 1_024 * 1_024
    private static let maximumDeferredMutations = 64
    private static let maximumDeferredPublicationItems = 4
    private static let maximumDeferredPublicationUnits = 4_096
    /// Catalog retry sources are reproducible from SwiftData. Retain only a
    /// small bounded working set when SQLite is temporarily unavailable; all
    /// evicted rows remain invalidated/fail-closed and are reloaded by the next
    /// coordinator maintenance pass.
    private static let maximumDeferredCatalogRegistrationItems = 4
    private static let maximumDeferredCatalogRegistrationTextUTF8ByteCount =
        maximumExpandedTextUTF8ByteCount
    static let maximumLibraryCandidatesPerTier = 24

    private nonisolated static func isIndexableItemName(_ name: String) -> Bool {
        name.utf8.count <= maximumIndexedItemNameUTF8ByteCount
            && name.contains(where: { $0.isWhitespace == false })
    }

    private nonisolated static func isIndexableRegistration(
        _ item: AssistantIndexedItem
    ) -> Bool {
        isIndexableItemName(item.itemName)
    }

    private nonisolated static func textUTF8ByteCount(
        in units: [Unit],
        maximum: Int
    ) -> Int? {
        guard maximum >= 0 else { return nil }
        var total = 0
        for unit in units {
            let byteCount = unit.text.utf8.count
            guard byteCount <= maximum - total else { return nil }
            total += byteCount
        }
        return total
    }

    public struct Unit: Equatable, Sendable, Identifiable {
        public let itemID: UUID
        public let itemName: String
        public let pageID: UUID?
        public let blockID: UUID?
        public let pageNumber: Int?
        public let kind: AssistantSourceKind
        public let pageBounds: CGRect?
        public let generation: Int64
        public let chunkOrdinal: Int
        public let contentHash: String
        public let text: String
        public let id: String
        /// Core Spotlight chunks carry the exact manifest fingerprint that
        /// authorized their publication. In-memory/authored units leave this
        /// nil; only decoded Spotlight evidence may use it for durable-domain
        /// membership validation.
        fileprivate let spotlightManifestFingerprint: String?

        public init(
            itemID: UUID,
            itemName: String,
            pageID: UUID?,
            blockID: UUID? = nil,
            pageNumber: Int?,
            kind: AssistantSourceKind,
            pageBounds: CGRect?,
            generation: Int64,
            chunkOrdinal: Int = 0,
            contentHash: String? = nil,
            text: String
        ) {
            self.itemID = itemID
            self.itemName = itemName
            self.pageID = pageID
            self.blockID = blockID
            self.pageNumber = pageNumber
            self.kind = kind
            self.pageBounds = pageBounds
            self.generation = max(generation, 0)
            let normalizedOrdinal = max(chunkOrdinal, 0)
            let resolvedContentHash = contentHash ?? SearchText.hash(text)
            self.chunkOrdinal = normalizedOrdinal
            self.text = text
            self.contentHash = resolvedContentHash
            spotlightManifestFingerprint = nil
            id = SearchText.anchorID(
                itemID: itemID,
                pageID: pageID,
                blockID: blockID,
                kind: kind,
                ordinal: normalizedOrdinal,
                contentHash: resolvedContentHash
            )
        }

        fileprivate func replacing(
            generation: Int64,
            ordinal: Int,
            text: String
        ) -> Unit {
            Unit(
                itemID: itemID,
                itemName: itemName,
                pageID: pageID,
                blockID: blockID,
                pageNumber: pageNumber,
                kind: kind,
                pageBounds: pageBounds,
                generation: generation,
                chunkOrdinal: ordinal,
                contentHash: SearchText.hash(text),
                text: text
            )
        }

        fileprivate init(
            itemID: UUID,
            itemName: String,
            pageID: UUID?,
            blockID: UUID?,
            pageNumber: Int?,
            kind: AssistantSourceKind,
            pageBounds: CGRect?,
            generation: Int64,
            chunkOrdinal: Int,
            contentHash: String,
            text: String,
            spotlightManifestFingerprint: String
        ) {
            self.itemID = itemID
            self.itemName = itemName
            self.pageID = pageID
            self.blockID = blockID
            self.pageNumber = pageNumber
            self.kind = kind
            self.pageBounds = pageBounds
            self.generation = max(generation, 0)
            self.chunkOrdinal = max(chunkOrdinal, 0)
            self.contentHash = contentHash
            self.text = text
            self.spotlightManifestFingerprint = spotlightManifestFingerprint
            id = SearchText.anchorID(
                itemID: itemID,
                pageID: pageID,
                blockID: blockID,
                kind: kind,
                ordinal: max(chunkOrdinal, 0),
                contentHash: contentHash
            )
        }

    func stampedForSpotlight(manifestFingerprint: String) -> Unit {
        Unit(
            itemID: itemID,
            itemName: itemName,
            pageID: pageID,
            blockID: blockID,
            pageNumber: pageNumber,
            kind: kind,
            pageBounds: pageBounds,
            generation: generation,
            chunkOrdinal: chunkOrdinal,
            contentHash: contentHash,
            text: text,
            spotlightManifestFingerprint: manifestFingerprint
        )
    }
}

    /// A complete, generation-verified view of one focused note, notebook, or
    /// page. Unlike ranked search/context results, this value preserves every
    /// chunk and its authored order so callers can perform full-coverage work
    /// such as hierarchical summarization without silently sampling content.
    public struct ContentSnapshot: Equatable, Sendable {
        public let itemID: UUID
        public let itemName: String
        public let pageID: UUID?
        public let generation: Int64
        public let contentHash: String
        public let units: [Unit]

        public init(
            itemID: UUID,
            itemName: String,
            pageID: UUID?,
            generation: Int64,
            contentHash: String,
            units: [Unit]
        ) {
            self.itemID = itemID
            self.itemName = itemName
            self.pageID = pageID
            self.generation = max(generation, 0)
            self.contentHash = contentHash
            self.units = units
        }
    }

    /// One immutable summary input and its exact source authority. The receipt
    /// advances only for authored note changes; derived catalog/OCR maintenance
    /// may improve the next request without invalidating work already pinned to
    /// this capture.
    struct SummaryCapture: Sendable {
        let contentSnapshot: ContentSnapshot
        let sourceAuthority: [AssistantSearchResult]
        let sourceAuthorityByID: [String: AssistantSearchResult]
        let freshnessReceipt: PublicationReceipt

        func validatedPublication(
            matching expectedSources: [AssistantSearchResult]
        ) -> ValidatedPublication? {
            let sourceIDs = expectedSources.map(\.id)
            guard Set(sourceIDs).count == sourceIDs.count else { return nil }
            let pinnedSources = sourceIDs.compactMap { sourceAuthorityByID[$0] }
            guard NotebookIndex.hasExactPublicationIdentity(
                expectedSources,
                pinnedSources
            ) else { return nil }
            return ValidatedPublication(
                sources: pinnedSources,
                receipt: freshnessReceipt
            )
        }
    }

    /// Opaque compare-and-swap authority for the one exceptional case where
    /// Canvas Core has promoted an older verified recovery checkpoint. Normal
    /// registrations remain monotonic; callers must present the exact actor
    /// state they observed before a lower generation can be installed.
    struct RecoveryRegistrationToken: Sendable {
        fileprivate let itemID: UUID
        fileprivate let registration: AssistantIndexedItem?
        fileprivate let sourceRevision: UInt64
        fileprivate let sourceFingerprint: String?
    }

    struct RecoveryCompletionToken: Sendable {
        fileprivate let itemID: UUID
        fileprivate let registration: AssistantIndexedItem
        fileprivate let sourceRevision: UInt64
        fileprivate let sourceFingerprint: String
        fileprivate let manifestFingerprint: String
        fileprivate let generation: Int64
    }

    /// Captures only the item identities that existed when an exact
    /// whole-library reconciliation began. Callers may then stream full source
    /// projections one at a time without retaining every notebook's fallback
    /// text in a single array. Finishing removes only stale identities from
    /// this snapshot, preserving an item registered concurrently afterward.
    struct RegisteredItemReconciliation: Sendable {
        fileprivate let knownItemIDs: Set<UUID>
    }

    /// A compact second-level index for verified hot data. Core Spotlight is
    /// the persistent, library-wide semantic tier; these sorted posting lists
    /// route exact and prefix matches to a bounded set of chunks without
  /// rescanning every cached page after each keystroke or prompt.
  private struct LexicalPostingIndex: Sendable {
    let postings: [String: [Int]]
    let sortedTerms: [String]

    init() {
      postings = [:]
      sortedTerms = []
    }

    init?(boundedUnits units: [Unit]) {
      guard let built = Self.build(units, observesCancellation: false)
      else { return nil }
      postings = built.postings
      sortedTerms = built.sortedTerms
    }

    init?(cancellableUnits units: [Unit]) {
      guard let built = Self.build(units, observesCancellation: true)
      else { return nil }
      postings = built.postings
      sortedTerms = built.sortedTerms
    }

    private static func build(
      _ units: [Unit],
      observesCancellation: Bool
    ) -> (postings: [String: [Int]], sortedTerms: [String])? {
      var postings: [String: [Int]] = [:]
      var postingEntryCount = 0
      for (index, unit) in units.enumerated() {
        if observesCancellation, Task.isCancelled { return nil }
        for term in Set(SearchText.postingTerms(unit.text)) {
          if postings[term] == nil,
            postings.count
            >= NotebookIndex.maximumLexicalDistinctTermCount {
            return nil
          }
          guard postingEntryCount
            < NotebookIndex.maximumLexicalPostingEntryCount
          else { return nil }
          postings[term, default: []].append(index)
          postingEntryCount += 1
        }
      }
      if observesCancellation, Task.isCancelled { return nil }
      return (postings, postings.keys.sorted())
    }

    func candidateIndices(
      matching queryTerms: [String],
      pageID: UUID?,
      units: [Unit],
      maximumCount: Int
    ) -> [Int] {
      guard maximumCount > 0 else { return [] }
      var matchCounts: [Int: Int] = [:]
      for queryTerm in queryTerms {
        var indicesForTerm = Set<Int>()
        for indexedTerm in indexedTerms(matching: queryTerm) {
          if let indices = postings[indexedTerm] {
            indicesForTerm.formUnion(indices)
          }
        }
        for index in indicesForTerm {
          guard pageID == nil || units[index].pageID == pageID else { continue }
          matchCounts[index, default: 0] += 1
        }
      }
      return matchCounts
        .sorted { lhs, rhs in
          if lhs.value != rhs.value { return lhs.value > rhs.value }
          return lhs.key < rhs.key
        }
        .prefix(maximumCount)
        .map(\.key)
    }

    private func indexedTerms(matching queryTerm: String) -> Set<String> {
      var matches = Set<String>()
      if postings[queryTerm] != nil { matches.insert(queryTerm) }
      guard queryTerm.count >= 4 else { return matches }

      // Find indexed terms for which the query is a prefix using a
      // binary lower bound over the sorted lexicon. This is the same
      // routing property a B+ tree provides, without duplicating the
      // persistent index already maintained by Core Spotlight.
      var index = lowerBound(for: queryTerm)
      while index < sortedTerms.count,
        sortedTerms[index].hasPrefix(queryTerm),
        matches.count < 64 {
        matches.insert(sortedTerms[index])
        index += 1
      }

      // Preserve the scorer's inverse-prefix behavior (for example,
      // "photosynthesis-process" matching "photosynthesis") without a
      // full lexicon scan.
      let characters = Array(queryTerm)
      if characters.count > 4 {
        for length in 4..<min(characters.count, 48) {
          let prefix = String(characters.prefix(length))
          if postings[prefix] != nil { matches.insert(prefix) }
        }
      }
      return matches
    }

    private func lowerBound(for term: String) -> Int {
      var lower = 0
      var upper = sortedTerms.count
      while lower < upper {
        let middle = lower + (upper - lower) / 2
        if sortedTerms[middle] < term {
          lower = middle + 1
        } else {
          upper = middle
        }
      }
      return lower
    }
  }

  private struct ItemIndex: Sendable {
    let generation: Int64
    let units: [Unit]
    let byID: [String: Unit]
    let lexical: LexicalPostingIndex
    let fingerprint: String
    let registrationFingerprint: String?

    init?(
      generation: Int64,
      units: [Unit],
      registrationFingerprint: String? = nil
    ) {
      guard let lexical = LexicalPostingIndex(boundedUnits: units) else {
        return nil
      }
      self.generation = max(generation, 0)
      self.units = units
      byID = Dictionary(
        units.map { ($0.id, $0) },
        uniquingKeysWith: { current, _ in current }
      )
      self.lexical = lexical
      fingerprint = SearchText.fingerprint(generation: generation, units: units)
      self.registrationFingerprint = registrationFingerprint
    }

    var manifest: IndexManifest {
      IndexManifest(
        generation: generation,
        fingerprint: fingerprint,
        unitCount: units.count,
        registrationFingerprint: registrationFingerprint
      )
    }
  }

  private struct InitialProposalBundle: Sendable {
    let replay: ItemIndex
    let authored: ItemIndex
    let authoredWithoutDerivedUnits: [Unit]
    let constructionCount: Int
  }

  private struct ImageEnrichmentProposalBundle: Sendable {
    let proposal: ItemIndex
    let repairProposal: ItemIndex
  }

  private nonisolated static func buildInitialProposalBundle(
    durableReplayUnits: [Unit],
    hasDurableRecords: Bool,
    authoredBaseUnits: [Unit],
    generation: Int64,
    itemID: UUID,
    registrationFingerprint: String
  ) -> InitialProposalBundle? {
    guard !Task.isCancelled else { return nil }
    // Validate the authoritative authored projection before constructing
    // either lexical index. Oversized/corrupt disposable OCR replay must
    // degrade to authored text instead of making the notebook unavailable.
    guard let authoredUnits = expand(
      authoredBaseUnits,
      for: itemID,
      generation: generation
    ) else { return nil }
    guard let authored = ItemIndex(
      generation: generation,
      units: authoredUnits,
      registrationFingerprint: registrationFingerprint
    ) else { return nil }
    guard !Task.isCancelled else { return nil }
    let replay: ItemIndex
    let constructionCount: Int
    if hasDurableRecords,
      let replayUnits = expand(
        durableReplayUnits,
        for: itemID,
        generation: generation
      ),
      let replayIndex = ItemIndex(
        generation: generation,
        units: replayUnits,
        registrationFingerprint: registrationFingerprint
      ) {
      replay = replayIndex
      constructionCount = 2
    } else {
      guard !Task.isCancelled else { return nil }
      replay = authored
      constructionCount = 1
    }
    guard !Task.isCancelled else { return nil }
    return InitialProposalBundle(
      replay: replay,
      authored: authored,
      authoredWithoutDerivedUnits: authored.units.filter {
        $0.kind != .imageContent
      },
      constructionCount: constructionCount
    )
  }

  private nonisolated static func buildAuthoredBaseUnits(
    snapshot: CanvasCoreSnapshot,
    item: AssistantIndexedItem,
    generation: Int64,
    delta: CanvasVerifiedIndexDelta?,
    previousUnits: [Unit]?
  ) async -> [Unit]? {
    let extracted: [Unit]
    if let delta, let previousUnits {
      let changed = Set(delta.changedPageIDs)
      let removed = Set(delta.removedPageIDs)
      guard let changedUnits = await extract(
        snapshot: snapshot,
        item: item,
        pageIDs: changed
      ) else { return nil }
      guard !Task.isCancelled else { return nil }
      let pageNumbers = Dictionary(
        snapshot.pages.enumerated().map {
          ($0.element.id, $0.offset + 1)
        },
        uniquingKeysWith: { current, _ in current }
      )
      let reused = previousUnits.compactMap { unit -> Unit? in
        guard unit.kind != .metadata,
          let pageID = unit.pageID,
          !changed.contains(pageID),
          !removed.contains(pageID),
          let currentPageNumber = pageNumbers[pageID] else {
          return nil
        }
        return Unit(
          itemID: unit.itemID,
          itemName: item.itemName,
          pageID: pageID,
          blockID: unit.blockID,
          pageNumber: delta.pageOrderChanged
            ? currentPageNumber
            : unit.pageNumber,
          kind: unit.kind,
          pageBounds: unit.pageBounds,
          generation: generation,
          chunkOrdinal: unit.chunkOrdinal,
          contentHash: unit.contentHash,
          text: unit.text
        )
      }
      guard !Task.isCancelled else { return nil }
      extracted = reused + changedUnits
    } else {
      guard let completeExtraction = await extract(
        snapshot: snapshot,
        item: item
      ) else { return nil }
      extracted = completeExtraction
      guard !Task.isCancelled else { return nil }
    }
    return includingMetadata(
      in: extracted,
      item: item,
      generation: generation
    )
  }

  private nonisolated static func buildImageEnrichmentProposalBundle(
    records: [AssistantImageEnrichmentRecord],
    baseUnits: [Unit],
    replacingImageContentOn visitedPageIDs: Set<UUID>?,
    generation: Int64,
    item: AssistantIndexedItem
  ) -> ImageEnrichmentProposalBundle? {
    guard !Task.isCancelled,
      isIndexableRegistration(item),
      let repairUnits = expand(
        baseUnits,
        for: item.itemID,
        generation: generation
      ) else { return nil }
    let fingerprint = registrationFingerprint(item)
    guard let repairProposal = ItemIndex(
      generation: generation,
      units: repairUnits,
      registrationFingerprint: fingerprint
    ) else { return nil }

    let retainedBaseUnits = baseUnits.filter { unit in
      guard unit.kind == .imageContent else { return true }
      guard let visitedPageIDs else { return false }
      return unit.pageID.map {
        visitedPageIDs.contains($0) == false
      } ?? false
    }
    var remainingTextBytes = maximumExpandedTextUTF8ByteCount
    for unit in retainedBaseUnits {
      let byteCount = unit.text.utf8.count
      guard byteCount <= remainingTextBytes else {
        return ImageEnrichmentProposalBundle(
          proposal: repairProposal,
          repairProposal: repairProposal
        )
      }
      remainingTextBytes -= byteCount
    }

    var imageUnits: [Unit] = []
    imageUnits.reserveCapacity(min(records.count, maximumSingleCachedUnits))
    for record in records {
      guard !Task.isCancelled else { return nil }
      guard let text = record.searchableText(
        maximumUTF8Bytes: remainingTextBytes
      ) else {
        return ImageEnrichmentProposalBundle(
          proposal: repairProposal,
          repairProposal: repairProposal
        )
      }
      guard !text.isEmpty else { continue }
      let byteCount = text.utf8.count
      guard byteCount <= remainingTextBytes,
        imageUnits.count < maximumSingleCachedUnits else {
        return ImageEnrichmentProposalBundle(
          proposal: repairProposal,
          repairProposal: repairProposal
        )
      }
      remainingTextBytes -= byteCount
      imageUnits.append(Unit(
        itemID: item.itemID,
        itemName: item.itemName,
        pageID: record.pageID,
        blockID: imageBlockID(record.stableID),
        pageNumber: record.pageNumber,
        kind: .imageContent,
        pageBounds: record.pageBounds,
        generation: generation,
        text: text
      ))
    }
    guard !Task.isCancelled else { return nil }
    let units = retainedBaseUnits + imageUnits
    guard let proposalUnits = expand(
      units,
      for: item.itemID,
      generation: generation
    ) else {
      guard !Task.isCancelled else { return nil }
      return ImageEnrichmentProposalBundle(
        proposal: repairProposal,
        repairProposal: repairProposal
      )
    }
    guard let proposal = ItemIndex(
      generation: generation,
      units: proposalUnits,
      registrationFingerprint: fingerprint
    ) else {
      return ImageEnrichmentProposalBundle(
        proposal: repairProposal,
        repairProposal: repairProposal
      )
    }
    guard !Task.isCancelled else { return nil }
    return ImageEnrichmentProposalBundle(
      proposal: proposal,
      repairProposal: repairProposal
    )
  }

    /// A routing index over only the already-hot verified chunks. It is
    /// rebuilt when those chunks change, never during a library query.
    private struct LibraryLexicalIndex: Sendable {
        let units: [Unit]
        let lexical: LexicalPostingIndex

        init(units: [Unit]) {
            if let lexical = LexicalPostingIndex(boundedUnits: units) {
                self.units = units
                self.lexical = lexical
            } else {
                // The eager initializer is used for the actor's empty seed.
                // If a future caller supplies an over-budget corpus, fail
                // closed to an empty routing index instead of allocating it.
                self.units = []
                lexical = LexicalPostingIndex()
            }
        }

        init?(cancellableUnits units: [Unit]) {
            guard let lexical = LexicalPostingIndex(cancellableUnits: units) else {
                return nil
            }
            self.units = units
            self.lexical = lexical
        }
    }

    private struct LibraryLexicalRebuild: Sendable {
        let revision: UInt64
        let task: Task<LibraryLexicalIndex?, Never>
    }

    /// Durable catalog retrieval. The repository may hand the index several
    /// megabytes of imported text for one item; this store chunks and indexes
    /// that projection transactionally, then releases the source string. FTS
    /// queries and exact citation reads touch only bounded rows.
    private final class CatalogFTSIndex: @unchecked Sendable {
        private enum StorageError: LocalizedError {
            case unavailable
            case secureDeleteUnavailable
            case deletionFailed
            case ftsScrubFailed
            case checkpointFailed
            case vacuumFailed
            case verificationFailed

            var errorDescription: String? {
                switch self {
                case .unavailable:
                    "The derived assistant catalog could not be opened safely."
                case .secureDeleteUnavailable:
                    "SQLite secure deletion could not be enabled for the assistant catalog."
                case .deletionFailed:
                    "The deleted item could not be removed from the assistant catalog."
                case .ftsScrubFailed:
                    "The assistant search index could not be rebuilt without the deleted item."
                case .checkpointFailed:
                    "The assistant catalog write-ahead log could not be securely truncated."
                case .vacuumFailed:
                    "The assistant catalog could not be compacted after permanent deletion."
                case .verificationFailed:
                    "Permanent deletion could not be verified in the assistant catalog."
                }
            }
        }

        private static let schemaVersion = 1
        private static let initializationIntegrityBudget: Duration = .seconds(1)
        private static let permanentScrubBudget: Duration = .seconds(5)
        private static let transient = unsafeBitCast(
            -1,
            to: sqlite3_destructor_type.self
        )

        private final class QueryDeadline {
            let instant: ContinuousClock.Instant
            var interruptsSQLite = true

            init(_ instant: ContinuousClock.Instant) { self.instant = instant }
        }

        private static let progressCallback: @convention(c) (
            UnsafeMutableRawPointer?
        ) -> Int32 = { context in
            guard let context else { return 0 }
            let deadline = Unmanaged<QueryDeadline>
                .fromOpaque(context)
                .takeUnretainedValue()
            return deadline.interruptsSQLite
                && ContinuousClock().now >= deadline.instant ? 1 : 0
        }

        private let storagePath: String?
        private var deferredInitialItems: [AssistantIndexedItem]
        private var database: OpaquePointer?
        private var didInitialize = false
        private var persistentDatabaseReady = false
        private var invalidatedItemIDs = Set<UUID>()
        /// Subset fenced by a newer actor registration, distinct from a
        /// transient failed bootstrap/update. A later successful retry may
        /// clear ordinary failures but must preserve this fence until the
        /// current full registration itself is installed.
        private var externallyInvalidatedItemIDs = Set<UUID>()
        private(set) var projectionTokenizationCount = 0
        private(set) var postingVisitsForTesting = 0
#if DEBUG
        private var deferredExpirationItemLimitForTesting: Int?
#endif

        init(storageURL: URL? = nil, items: [AssistantIndexedItem] = []) {
            storagePath = storageURL?.path
            // Keep actor construction constant-time apart from retaining the
            // caller's copy-on-write array. Even deterministic ordering is
            // deferred until the first actor-isolated catalog operation.
            deferredInitialItems = items
        }

        deinit {
            if let database { sqlite3_close(database) }
        }

        /// Deliberately performs no filesystem or SQLite work from `init`.
        /// `CatalogFTSIndex` is owned by `NotebookIndex`, so the first call to
        /// this method occurs only after execution has entered that actor.
    private func ensureDatabase(
            deferredDeadline: ContinuousClock.Instant? = nil
        ) -> Bool {
            guard Task.isCancelled == false else { return false }
            if database == nil {
                return materializeDeferredInitialItems(
                    until: deferredDeadline
                )
            }
            guard didInitialize == false else { return false }
            didInitialize = true

            let requestedPath = storagePath ?? ":memory:"
            var established = false
            if let storagePath {
                do {
                    try FileManager.default.createDirectory(
                        at: URL(fileURLWithPath: storagePath)
                            .deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    established = establishDatabase(
                        at: storagePath,
                        integrityBudget: Self.initializationIntegrityBudget
                    )
                    if established == false,
                       Self.removeDerivedDatabaseFiles(atPath: storagePath) {
                        // Integrity failure and timeout both fail closed. This
                        // catalog is reproducible, so rebuild a new empty store
                        // instead of exposing unchecked rows.
                        established = establishDatabase(
                            at: storagePath,
                            integrityBudget: Self.initializationIntegrityBudget
                        )
                    }
                } catch {
                    established = false
                }
                persistentDatabaseReady = established
            } else {
                established = establishDatabase(
                    at: requestedPath,
                    integrityBudget: Self.initializationIntegrityBudget
                )
            }

            if established == false, storagePath != nil {
                // Search remains available from current in-memory
                // registrations, but permanent purge will throw because an
                // inaccessible durable file cannot be certified as scrubbed.
                established = establishDatabase(
                    at: ":memory:",
                    integrityBudget: Self.initializationIntegrityBudget
                )
                persistentDatabaseReady = false
            }
            guard established else {
                deferredInitialItems.removeAll(keepingCapacity: false)
                return false
            }

            if persistentDatabaseReady, let storagePath {
                try? FileManager.default.setAttributes(
                    [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                    ofItemAtPath: storagePath
                )
            }

            // Database establishment deliberately retains its independent
            // integrity budget. Letting a short interactive deadline abort
            // quick_check/schema validation could classify a valid durable
            // catalog as corrupt and trigger deletion/rebuild. The request
            // deadline is enforced immediately before and after this phase,
            // and throughout the reproducible deferred projection below.
            return materializeDeferredInitialItems(until: deferredDeadline)
        }

        /// A cancelled first query rolls back the startup transaction and
        /// leaves the deferred projection intact for a later retry. This
        /// prevents a request watchdog from turning cancellation into a
        /// permanently empty catalog.
        private func materializeDeferredInitialItems(
            until deadline: ContinuousClock.Instant?
        ) -> Bool {
            guard mayContinue(until: deadline) else { return false }
            guard deferredInitialItems.isEmpty == false else {
                return database != nil
            }
            let initialItems = deferredInitialItems
                .filter(NotebookIndex.isIndexableRegistration)
                .sorted(by: {
                    $0.itemID.uuidString < $1.itemID.uuidString
                })
            guard mayContinue(until: deadline),
                updateInitialItems(initialItems, until: deadline) else {
                return false
            }
            deferredInitialItems.removeAll(keepingCapacity: false)
            return database != nil
        }

        var itemIDs: Set<UUID> {
            guard ensureDatabase() else { return [] }
            guard let statement = prepare(
                "SELECT item_id FROM assistant_catalog_meta_v1"
            ) else { return [] }
            defer { sqlite3_finalize(statement) }
            var result = Set<UUID>()
            while sqlite3_step(statement) == SQLITE_ROW {
                if let value = columnText(statement, 0),
                   let id = UUID(uuidString: value) {
                    result.insert(id)
                }
            }
            return result
        }

        /// Materializes the startup projection in one transaction. Opening is
        /// still lazy and actor-confined, while avoiding thousands of commits
        /// that could consume an interactive request's absolute deadline.
    private func updateInitialItems(
            _ items: [AssistantIndexedItem],
            until deadline: ContinuousClock.Instant?
        ) -> Bool {
            guard items.isEmpty == false,
                mayContinue(until: deadline) else { return items.isEmpty }
            let deadlineBox = deadline.map(QueryDeadline.init)
            if let database, let deadlineBox {
                sqlite3_progress_handler(
                    database,
                    1_000,
                    Self.progressCallback,
                    Unmanaged.passUnretained(deadlineBox).toOpaque()
                )
            }
            defer {
                if let database {
                    sqlite3_progress_handler(database, 0, nil, nil)
                }
                withExtendedLifetime(deadlineBox) {}
            }
            var sourceChangeCount = 0
            let itemIDs = Set(items.map(\.itemID))
            // A foreground registration may have fenced one of these lazy
            // constructor rows after this deferred array was captured. Cold
            // bootstrap may still materialize the stale row transactionally,
            // but it must not clear that newer fail-closed fence; only a
            // subsequent update from current full registration may do so.
            let invalidatedBeforeBootstrap = externallyInvalidatedItemIDs
                .intersection(itemIDs)
            let accepted = transaction(interruptedBy: deadlineBox) {
                for (itemOffset, item) in items.enumerated() {
                    guard self.mayContinue(
                        until: deadline,
                        deferredItemOffset: itemOffset
                    ) else { return false }
                    let fingerprint = Self.sourceFingerprint(item)
                    guard self.mayContinue(until: deadline) else { return false }
                    if let existing = self.metadata(for: item.itemID),
                       existing.fingerprint == fingerprint {
                        guard item.expectedGeneration > existing.generation
                        else { continue }
                        guard self.execute(
                            "UPDATE assistant_catalog_meta_v1 "
                                + "SET generation = ? WHERE item_id = ?",
                            bindings: [
                                .integer(item.expectedGeneration),
                                .text(Self.key(item.itemID)),
                            ]
                        ), self.execute(
                            "UPDATE assistant_catalog_chunks_v1 "
                                + "SET generation = ? WHERE item_id = ?",
                            bindings: [
                                .integer(item.expectedGeneration),
                                .text(Self.key(item.itemID)),
                            ]
                        ) else { return false }
                        continue
                    }

                    guard self.execute(
                        "DELETE FROM assistant_catalog_chunks_v1 WHERE item_id = ?",
                        bindings: [.text(Self.key(item.itemID))]
                    ), self.execute(
                        "DELETE FROM assistant_catalog_meta_v1 WHERE item_id = ?",
                        bindings: [.text(Self.key(item.itemID))]
                    ) else { return false }
                    guard self.mayContinue(until: deadline) else { return false }
                    guard let units = Self.units(for: item) else {
                        return false
                    }
                    guard self.mayContinue(until: deadline) else { return false }
                    for unit in units {
                        guard self.mayContinue(until: deadline),
                            self.insert(unit) else { return false }
                    }
                    guard self.execute(
                        "INSERT INTO assistant_catalog_meta_v1 "
                            + "(item_id, fingerprint, generation, chunk_count) "
                            + "VALUES (?, ?, ?, ?)",
                        bindings: [
                            .text(Self.key(item.itemID)),
                            .text(fingerprint),
                            .integer(item.expectedGeneration),
                            .integer(Int64(units.count)),
                        ]
                    ) else { return false }
                    sourceChangeCount += 1
                }
                return self.mayContinue(until: deadline)
            }
            if accepted {
                projectionTokenizationCount += sourceChangeCount
                invalidatedItemIDs.subtract(
                    itemIDs.subtracting(invalidatedBeforeBootstrap)
                )
            } else {
                invalidatedItemIDs.formUnion(itemIDs)
            }
            return accepted
        }

    private func mayContinue(
            until deadline: ContinuousClock.Instant?,
            deferredItemOffset: Int? = nil
        ) -> Bool {
            guard Task.isCancelled == false else { return false }
#if DEBUG
            if let deferredItemOffset,
               let limit = deferredExpirationItemLimitForTesting,
               deferredItemOffset >= limit {
                return false
            }
#endif
            guard let deadline else { return true }
            return ContinuousClock().now < deadline
        }

#if DEBUG
        func setDeferredExpirationItemLimitForTesting(_ limit: Int?) {
            deferredExpirationItemLimitForTesting = limit.map { max($0, 0) }
        }

        var committedItemCountForTesting: Int {
            guard database != nil else { return 0 }
            return Int(
                scalarInteger(
                    "SELECT COUNT(*) FROM assistant_catalog_meta_v1"
                ) ?? -1
            )
        }
#endif

        @discardableResult
        func update(
            _ item: AssistantIndexedItem,
            certifiesGeneration: Bool = false,
            willMutate: @Sendable () -> Void = {}
        ) -> Bool {
            guard NotebookIndex.isIndexableRegistration(item),
                ensureDatabase() else {
                invalidatedItemIDs.insert(item.itemID)
                return false
            }
            let fingerprint = Self.sourceFingerprint(item)
            let existing = metadata(for: item.itemID)
            if let existing, existing.fingerprint == fingerprint {
                let shouldAdvance = certifiesGeneration
                    && item.expectedGeneration > existing.generation
                guard shouldAdvance else {
                    invalidatedItemIDs.remove(item.itemID)
                    externallyInvalidatedItemIDs.remove(item.itemID)
                    return true
                }
                willMutate()
                let accepted = transaction {
                    self.execute(
                        "UPDATE assistant_catalog_meta_v1 "
                            + "SET generation = ? WHERE item_id = ?",
                        bindings: [
                            .integer(item.expectedGeneration),
                            .text(Self.key(item.itemID)),
                        ]
                    ) && self.execute(
                        "UPDATE assistant_catalog_chunks_v1 "
                            + "SET generation = ? WHERE item_id = ?",
                        bindings: [
                            .integer(item.expectedGeneration),
                            .text(Self.key(item.itemID)),
                        ]
                    )
                }
                if accepted {
                    invalidatedItemIDs.remove(item.itemID)
            externallyInvalidatedItemIDs.remove(item.itemID)
        } else {
            invalidatedItemIDs.insert(item.itemID)
        }
        return accepted
    }

    guard let units = Self.units(for: item) else {
        invalidatedItemIDs.insert(item.itemID)
        return false
    }
    willMutate()
    let accepted = transaction {
        guard self.execute(
            "DELETE FROM assistant_catalog_chunks_v1 WHERE item_id = ?",
            bindings: [.text(Self.key(item.itemID))]
        ), self.execute(
            "DELETE FROM assistant_catalog_meta_v1 WHERE item_id = ?",
            bindings: [.text(Self.key(item.itemID))]
        ) else { return false }
        for unit in units {
            guard self.insert(unit) else { return false }
        }
        return self.execute(
            "INSERT INTO assistant_catalog_meta_v1 "
                + "(item_id, fingerprint, generation, chunk_count) "
                + "VALUES (?, ?, ?, ?)",
            bindings: [
                .text(Self.key(item.itemID)),
                .text(fingerprint),
                .integer(item.expectedGeneration),
                .integer(Int64(units.count)),
            ]
        )
    }
    if accepted {
        projectionTokenizationCount += 1
        invalidatedItemIDs.remove(item.itemID)
        externallyInvalidatedItemIDs.remove(item.itemID)
    } else {
        invalidatedItemIDs.insert(item.itemID)
    }
    return accepted
    }

    /// Recovery is the sole legal generation regression. Rebuild the row
    /// unconditionally so an identical fallback body from a discarded
    /// higher checkpoint cannot retain that higher metadata generation.
    @discardableResult
    func replaceRecoveredProjection(
        _ item: AssistantIndexedItem
    ) -> Bool {
    guard NotebookIndex.isIndexableRegistration(item),
        ensureDatabase() else {
        invalidatedItemIDs.insert(item.itemID)
        return false
    }
    let fingerprint = Self.sourceFingerprint(item)
    guard let units = Self.units(for: item) else {
        invalidatedItemIDs.insert(item.itemID)
        return false
    }
    let accepted = transaction {
        guard self.execute(
            "DELETE FROM assistant_catalog_chunks_v1 WHERE item_id = ?",
            bindings: [.text(Self.key(item.itemID))]
        ), self.execute(
            "DELETE FROM assistant_catalog_meta_v1 WHERE item_id = ?",
            bindings: [.text(Self.key(item.itemID))]
        ) else { return false }
        for unit in units {
            guard self.insert(unit) else { return false }
        }
        return self.execute(
            "INSERT INTO assistant_catalog_meta_v1 "
                + "(item_id, fingerprint, generation, chunk_count) "
                + "VALUES (?, ?, ?, ?)",
            bindings: [
                .text(Self.key(item.itemID)),
                .text(fingerprint),
                .integer(item.expectedGeneration),
                .integer(Int64(units.count)),
            ]
        )
    }
    if accepted {
        invalidatedItemIDs.remove(item.itemID)
        externallyInvalidatedItemIDs.remove(item.itemID)
        projectionTokenizationCount += 1
    } else {
        invalidatedItemIDs.insert(item.itemID)
    }
    return accepted
}

func hasExactProjection(_ item: AssistantIndexedItem) -> Bool {
    guard ensureDatabase(),
        invalidatedItemIDs.contains(item.itemID) == false,
        let existing = metadata(for: item.itemID) else { return false }
        return existing.fingerprint == Self.sourceFingerprint(item)
            && existing.generation == item.expectedGeneration
    }

    /// Immediately fences a stale catalog row without opening SQLite.
    /// Foreground registration uses this before exposing changed identity;
    /// the next successful background `update` clears the fence.
    func invalidate(itemID: UUID) {
        invalidatedItemIDs.insert(itemID)
        externallyInvalidatedItemIDs.insert(itemID)
    }

    @discardableResult
    func certify(itemID: UUID, generation: Int64) -> Bool {
        guard ensureDatabase() else { return false }
        guard invalidatedItemIDs.contains(itemID) == false else { return false }
        guard let existing = metadata(for: itemID),
            generation > existing.generation else { return false }
        let accepted = transaction {
            self.execute(
                "UPDATE assistant_catalog_meta_v1 "
                    + "SET generation = ? WHERE item_id = ?",
                bindings: [
                    .integer(generation),
                    .text(Self.key(itemID)),
                ]
            ) && self.execute(
                "UPDATE assistant_catalog_chunks_v1 "
                    + "SET generation = ? WHERE item_id = ?",
                bindings: [
                    .integer(generation),
                    .text(Self.key(itemID)),
                ]
            )
        }
        if accepted {
            invalidatedItemIDs.remove(itemID)
            externallyInvalidatedItemIDs.remove(itemID)
        } else {
            invalidatedItemIDs.insert(itemID)
        }
        return accepted
    }

    @discardableResult
    func remove(itemID: UUID) -> Bool {
        guard ensureDatabase() else {
            invalidatedItemIDs.insert(itemID)
            return false
        }
        guard metadata(for: itemID) != nil else { return false }
        let removed = transaction {
            self.execute(
                "DELETE FROM assistant_catalog_chunks_v1 WHERE item_id = ?",
                bindings: [.text(Self.key(itemID))]
            ) && self.execute(
                "DELETE FROM assistant_catalog_meta_v1 WHERE item_id = ?",
                bindings: [.text(Self.key(itemID))]
            )
        }
        if removed {
            invalidatedItemIDs.remove(itemID)
            externallyInvalidatedItemIDs.remove(itemID)
        } else {
            invalidatedItemIDs.insert(itemID)
        }
        return removed
    }

    /// Permanently removes one catalog projection and compacts every
    /// durable SQLite surface that may still retain its bytes. Ordinary
    /// unregister intentionally uses `remove(itemID:)`; only irreversible
    /// library deletion pays for FTS rebuild, WAL truncation, and VACUUM.
    func purgePermanently(itemID: UUID) throws {
        guard ensureDatabase(), let database else {
            invalidatedItemIDs.insert(itemID)
            throw StorageError.unavailable
        }
        // `ensureDatabase` may materialize deferred startup projections.
        // Mark the target invalid only after that bootstrap so a purge as
        // the very first catalog operation cannot accidentally clear its
        // own fail-closed fence.
        invalidatedItemIDs.insert(itemID)
        if storagePath != nil, persistentDatabaseReady == false {
            // Falling back to RAM keeps corrupt durable rows invisible,
            // but cannot prove that their backing file was scrubbed.
            throw StorageError.unavailable
        }

        let deadline = QueryDeadline(
            ContinuousClock().now.advanced(by: Self.permanentScrubBudget)
        )
        sqlite3_progress_handler(
            database,
            1_000,
            Self.progressCallback,
            Unmanaged.passUnretained(deadline).toOpaque()
        )
        defer {
            sqlite3_progress_handler(database, 0, nil, nil)
            withExtendedLifetime(deadline) {}
        }

        guard execute("PRAGMA secure_delete = ON"),
            scalarInteger("PRAGMA secure_delete") == 1 else {
        throw StorageError.secureDeleteUnavailable
    }
    // FTS5 secure-delete overwrites obsolete index entries during the
    // delete itself. Rebuild then discards every historical segment,
    // leaving only terms reachable from the external-content table.
    guard execute(
        "INSERT INTO assistant_catalog_fts_v1("
            + "assistant_catalog_fts_v1, rank) "
            + "VALUES('secure-delete', 1)"
    ) else {
        throw StorageError.secureDeleteUnavailable
    }
    guard transaction({
        self.execute(
            "DELETE FROM assistant_catalog_chunks_v1 WHERE item_id = ?",
            bindings: [.text(Self.key(itemID))]
        ) && self.execute(
            "DELETE FROM assistant_catalog_meta_v1 WHERE item_id = ?",
            bindings: [.text(Self.key(itemID))]
        )
    }) else {
        throw StorageError.deletionFailed
    }
    guard execute(
        "INSERT INTO assistant_catalog_fts_v1(assistant_catalog_fts_v1) "
            + "VALUES('rebuild')"
    ), execute(
        "INSERT INTO assistant_catalog_fts_v1(assistant_catalog_fts_v1) "
            + "VALUES('optimize')"
    ), execute(
        "INSERT INTO assistant_catalog_fts_v1("
            + "assistant_catalog_fts_v1, rank) "
            + "VALUES('integrity-check', 1)"
    ) else {
        throw StorageError.ftsScrubFailed
    }
    guard checkpointTruncatingWAL() else {
        throw StorageError.checkpointFailed
    }
    // VACUUM reconstructs the main database from live b-trees. After
    // the FTS rebuild, neither ordinary free pages nor obsolete FTS
    // segments containing deleted prose are copied forward.
    guard execute("VACUUM") else {
        throw StorageError.vacuumFailed
    }
    guard checkpointTruncatingWAL() else {
        throw StorageError.checkpointFailed
    }
    guard count(
        in: "assistant_catalog_chunks_v1",
        itemID: itemID
    ) == 0,
    count(
        in: "assistant_catalog_meta_v1",
        itemID: itemID
    ) == 0,
    integrityIsValid() else {
        throw StorageError.verificationFailed
        }
        invalidatedItemIDs.remove(itemID)
        externallyInvalidatedItemIDs.remove(itemID)
    }

    func candidates(
        matching queryTerms: [String],
        maximumCount: Int,
        itemID: UUID? = nil,
        deadline: ContinuousClock.Instant? = nil
    ) -> [Unit] {
        postingVisitsForTesting = 0
        guard ensureDatabase(deferredDeadline: deadline),
            maximumCount > 0,
            let expression = Self.matchExpression(queryTerms) else {
            return []
        }
        let sql = """
            WITH matches AS (
                SELECT c.anchor_id, c.item_id, c.item_name, c.source_kind,
                    c.generation, c.ordinal, c.content_hash, c.text,
                    bm25(
                        assistant_catalog_fts_v1,
                        0.0, 0.0, 0.0, 1.0
                    ) AS fts_rank
                FROM assistant_catalog_fts_v1 AS f
                JOIN assistant_catalog_chunks_v1 AS c ON c.rowid = f.rowid
                WHERE assistant_catalog_fts_v1 MATCH ?
                \(itemID == nil ? "" : "AND c.item_id = ?")
            ), ranked AS (
                SELECT *, ROW_NUMBER() OVER (
                    PARTITION BY item_id
                    ORDER BY fts_rank, ordinal
                ) AS item_rank
                FROM matches
            )
            SELECT anchor_id, item_id, item_name, source_kind,
                generation, ordinal, content_hash, text
            FROM ranked
            WHERE item_rank <= 2
            ORDER BY fts_rank, item_id, ordinal
            LIMIT ?
            """
        guard let statement = prepare(sql) else { return [] }
        defer { sqlite3_finalize(statement) }
        let deadlineBox = deadline.map(QueryDeadline.init)
        if let database, let deadlineBox {
            sqlite3_progress_handler(
                database,
                1_000,
                Self.progressCallback,
                Unmanaged.passUnretained(deadlineBox).toOpaque()
            )
        }
        defer {
            if let database {
                sqlite3_progress_handler(database, 0, nil, nil)
            }
            withExtendedLifetime(deadlineBox) {}
        }
        var bindingIndex: Int32 = 1
        bind(.text(expression), to: statement, at: bindingIndex)
        bindingIndex += 1
        if let itemID {
            bind(.text(Self.key(itemID)), to: statement, at: bindingIndex)
            bindingIndex += 1
        }
        bind(.integer(Int64(maximumCount)), to: statement, at: bindingIndex)

        var result: [Unit] = []
        result.reserveCapacity(maximumCount)
        while sqlite3_step(statement) == SQLITE_ROW {
            postingVisitsForTesting += 1
            if let unit = unit(from: statement),
                invalidatedItemIDs.contains(unit.itemID) == false {
                result.append(unit)
            }
        }
        return result
    }

    // Searches only one already-retained catalog projection without
    // opening SQLite or materializing the deferred Library. A foreground
    // registration can supply its newer full projection while the
    // durable catalog row remains fenced. Once startup materialization
    // has already completed, the ordinary item-filtered FTS query is
    // safe because `ensureDatabase` has no deferred work left to drain.
    fileprivate func focusedCandidates(
        matching queryTerms: [String],
        maximumCount: Int,
        itemID: UUID,
        currentDeferredItem: AssistantIndexedItem?,
        deadline: ContinuousClock.Instant
    ) -> [Unit] {
        guard maximumCount > 0, mayContinue(until: deadline) else {
            return []
        }

        let source: AssistantIndexedItem?
        if let currentDeferredItem,
            currentDeferredItem.itemID == itemID {
            source = currentDeferredItem
        } else if invalidatedItemIDs.contains(itemID) == false {
            source = deferredInitialItems.first(where: {
                $0.itemID == itemID
            })
        } else {
            source = nil
        }

        if let source {
            let phrase = queryTerms.joined(separator: " ")
            var matches: [(unit: Unit, score: Double)] = []
            guard let projectedUnits = Self.units(for: source) else {
                return []
            }
            for unit in projectedUnits {
                guard mayContinue(until: deadline) else { return [] }
                guard let score = SearchText.score(
                    unit.text,
                    itemName: source.itemName,
                    terms: queryTerms,
                    phrase: phrase
                ) else { continue }
                matches.append((unit, score))
            }
            matches.sort {
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.unit.chunkOrdinal < $1.unit.chunkOrdinal
            }
            return matches.prefix(maximumCount).map(\.unit)
        }

        // An unfinished lazy bootstrap may coexist with older rows in a
        // durable file. Never consult those rows until the exact deferred
        // projection has committed transactionally.
        guard deferredInitialItems.isEmpty,
            database != nil,
            invalidatedItemIDs.contains(itemID) == false else {
            return []
        }
        return candidates(
            matching: queryTerms,
            maximumCount: maximumCount,
            itemID: itemID,
            deadline: deadline
        )
    }

    /// Opens and materializes the reproducible catalog within the same
    /// absolute budget as the interactive query. A timeout rolls the
    /// startup transaction back and preserves its deferred source array so
    /// a later request or background preparation can retry from authority.
    func prepareForQuery(
        until deadline: ContinuousClock.Instant
    ) -> Bool {
        guard mayContinue(until: deadline) else { return false }
        return ensureDatabase(deferredDeadline: deadline)
            && mayContinue(until: deadline)
    }

    func unit(id: String) -> Unit? {
        guard ensureDatabase() else { return nil }
        let sql = """
            SELECT anchor_id, item_id, item_name, source_kind,
                generation, ordinal, content_hash, text
            FROM assistant_catalog_chunks_v1
            WHERE anchor_id = ?
        LIMIT 1
        """
    guard let statement = prepare(sql) else { return nil }
    defer { sqlite3_finalize(statement) }
    bind(id, text: id, to: statement, at: 1)
    guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
    guard let unit = unit(from: statement) else { return nil }
    invalidateCachedUnit(unit.itemID) == false
    return unit
}

func contains(id: String) -> Bool {
    guard ensureDatabaseIsOpen() else { return false }
    guard let statement = prepare(
        "SELECT item_id FROM assistant_catalog_chunks_v1 "
        + "WHERE anchor_id = ? LIMIT 1"
    ) else { return false }
    defer { sqlite3_finalize(statement) }
    bind(id, text: id, to: statement, at: 1)
    guard sqlite3_step(statement) == SQLITE_ROW,
        let value = columnText(statement, 0),
            let itemID = UUID(uuidString: value) else { return false }
        return invalidatedItemIDs.contains(itemID) == false
    }

    func representativeUnits(itemID: UUID, maximumCount: Int) -> [Unit] {
        guard ensureDatabase(), maximumCount > 0 else { return [] }
        let sql = """
                SELECT anchor_id, item_id, item_name, source_kind,
                    generation, ordinal, content_hash, text
                FROM assistant_catalog_chunks_v1
                WHERE item_id = ?
                ORDER BY ordinal
                LIMIT ?
            """
            guard let statement = prepare(sql) else { return [] }
            defer { sqlite3_finalize(statement) }
            bind(.text(Self.key(itemID)), to: statement, at: 1)
            bind(.integer(Int64(maximumCount)), to: statement, at: 2)
            var result: [Unit] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                if let unit = unit(from: statement),
                    invalidatedItemIDs.contains(unit.itemID) == false {
                    result.append(unit)
                }
            }
            return result
        }

        private struct Metadata {
            let fingerprint: String
            let generation: Int64
        }

        private enum Binding {
            case integer(Int64)
            case text(String)
        }

        private func scalarInteger(
            _ sql: String,
            bindings: [Binding] = []
        ) -> Int64? {
            guard let statement = prepare(sql) else { return nil }
            defer { sqlite3_finalize(statement) }
            for (offset, binding) in bindings.enumerated() {
                bind(binding, to: statement, at: Int32(offset + 1))
            }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return sqlite3_column_int64(statement, 0)
        }

        private func scalarText(_ sql: String) -> String? {
            guard let statement = prepare(sql) else { return nil }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return nil }
            return columnText(statement, 0)
        }

        private func count(in table: String, itemID: UUID) -> Int64? {
            scalarInteger(
                "SELECT COUNT(*) FROM \(table) WHERE item_id = ?",
                bindings: [.text(Self.key(itemID))]
            )
        }

        private func checkpointTruncatingWAL() -> Bool {
            guard let statement = prepare("PRAGMA wal_checkpoint(TRUNCATE)") else {
                return false
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { return false }
            let wasBusy = sqlite3_column_int(statement, 0)
            let remainingFrames = sqlite3_column_int(statement, 1)
            // An in-memory database reports -1 because it has no WAL. A
            // durable WAL must report zero frames after TRUNCATE succeeds.
            let expectedFrameCount = storagePath == nil ? -1 : 0
            return wasBusy == 0 && remainingFrames == expectedFrameCount
        }

        private func metadata(for itemID: UUID) -> Metadata? {
            guard let statement = prepare(
                "SELECT fingerprint, generation "
                + "FROM assistant_catalog_meta_v1 WHERE item_id = ?"
            ) else { return nil }
            defer { sqlite3_finalize(statement) }
            bind(.text(Self.key(itemID)), to: statement, at: 1)
            guard sqlite3_step(statement) == SQLITE_ROW,
                let fingerprint = columnText(statement, 0) else { return nil }
            return Metadata(
                fingerprint: fingerprint,
                generation: sqlite3_column_int64(statement, 1)
            )
        }

        private func insert(_ unit: Unit) -> Bool {
            execute(
                "INSERT INTO assistant_catalog_chunks_v1 "
                    + "(anchor_id, item_id, item_name, source_kind, generation, "
                    + "ordinal, content_hash, text) VALUES (?, ?, ?, ?, ?, ?, ?, ?)",
                bindings: [
                    .text(unit.id),
                    .text(Self.key(unit.itemID)),
                    .text(unit.itemName),
                    .text(unit.kind.rawValue),
                    .integer(unit.generation),
                    .integer(Int64(unit.chunkOrdinal)),
                    .text(unit.contentHash),
                    .text(unit.text),
                ]
            )
        }

        private func unit(from statement: OpaquePointer) -> Unit? {
            guard let storedID = columnText(statement, 0),
                let itemIDText = columnText(statement, 1),
                let itemID = UUID(uuidString: itemIDText),
                let itemName = columnText(statement, 2),
                let kindText = columnText(statement, 3),
                let kind = AssistantSourceKind(rawValue: kindText),
                let contentHash = columnText(statement, 6),
                let text = columnText(statement, 7) else { return nil }
            let unit = Unit(
                itemID: itemID,
                itemName: itemName,
                pageID: nil,
                pageNumber: nil,
                kind: kind,
                pageBounds: nil,
                generation: sqlite3_column_int64(statement, 4),
                chunkOrdinal: Int(sqlite3_column_int64(statement, 5)),
                contentHash: contentHash,
                text: text
        )
        return unit.id == storedID ? unit : nil
    }

    private struct CatalogProjection {
        let text: String
        let kind: AssistantSourceKind
    }

    private struct AdmittedCatalogProjection {
        let projection: CatalogProjection
        let chunks: [String]
    }

    /// Defines the exact bounded source represented by both catalog rows
    /// and their fingerprint. Oversized derived bodies intentionally
    /// degrade to title-only metadata; `nil` is reserved for an invalid
    /// identity and must never be persisted as an exact empty projection.
    private static func projection(
        for item: AssistantIndexedItem
    ) -> CatalogProjection? {
        guard NotebookIndex.isIndexableRegistration(item) else {
            return nil
        }
        if item.requiresVerifiedRecovery {
            return CatalogProjection(text: "", kind: .metadata)
        }
        if item.fallbackSearchableText.utf8.count
            <= NotebookIndex.maximumIndexedSourceTextUTF8ByteCount {
            let fallback = item.fallbackSearchableText
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if fallback.isEmpty == false {
                return CatalogProjection(
                    text: fallback,
                    kind: item.kind == .importedDocument
                        ? .pdfText
                        : .paperKitText
                )
            }
    }
    return CatalogProjection(
        itemID: item.itemID,
        itemName: item.itemName,
        kind: item.kind.rawValue,
        text: item.title,
        kind: .metadata
    )
}

/// Chooses the exact projection that can be represented within both
/// chunk-count and expanded-byte budgets. Derived bodies may degrade
private static func admittedProjection(
    for item: AssistantIndexedItem,
    retainingChunks: Bool
) -> AdmittedCatalogProjection? {
    guard let projection = projection(for: item) else { return nil }
    guard projection.text.isEmpty == false else {
        return AdmittedCatalogProjection(
            projection: projection,
            chunks: []
        )
    }

    func chunks(for value: CatalogProjection) -> [String]? {
        SearchText.chunks(
            value.text,
            maximum: NotebookIndex.maximumChunkLength,
            overlap: NotebookIndex.chunkOverlapLength,
            maximumCount: NotebookIndex.maximumSingleCachedUnits,
            maximumUTF8Bytes: NotebookIndex.maximumExpandedTextUTF8ByteCount,
            retainingChunks: retainingChunks
        )
    }

        if let projectedChunks = chunks(for: projection) {
            return AdmittedCatalogProjection(
                projection: projection,
                chunks: projectedChunks
            )
        }
        guard Task.isCancelled == false else { return nil }

        // A bounded source can still exceed the expanded-text budget when
        // overlap repeats unusually large Unicode graphemes. Derived text
        // is optional, so preserve discovery and sibling progress with
        // the already validated title instead.
        guard projection.kind != .metadata else { return nil }
        let metadataProjection = CatalogProjection(
            text: item.itemName.trimmingCharacters(
                in: .whitespacesAndNewlines
            ),
            kind: .metadata
        )
        guard metadataProjection.text.isEmpty == false,
            let titleChunks = chunks(for: metadataProjection) else {
            return nil
        }
        return AdmittedCatalogProjection(
            projection: metadataProjection,
            chunks: titleChunks
        )
    }

    fileprivate static func units(
        for item: AssistantIndexedItem
    ) -> [Unit]? {
        guard let admitted = admittedProjection(
            for: item,
            retainingChunks: true
        ) else {
            return nil
        }
        return admitted.chunks.enumerated().map { ordinal, text in
            Unit(
                itemID: item.itemID,
                itemName: item.itemName,
                pageID: nil,
                pageNumber: nil,
                kind: admitted.projection.kind,
                pageBounds: nil,
                generation: item.expectedGeneration,
                chunkOrdinal: ordinal,
                text: text
            )
        }
    }
    fileprivate static func sourceFingerprint(_ item: AssistantIndexedItem) -> String {
        guard let admitted = admittedProjection(
            for: item,
            retainingChunks: false
        ) else {
            return SearchText.hashComponents([
                "invalid-catalog-projection",
                item.itemID.uuidString.lowercased(),
            ])
        }
        let projection = admitted.projection
        return SearchText.hashComponents([
            "catalog-projection-v2",
            item.itemName,
            item.kind.rawValue,
            projection.kind.rawValue,
            projection.text,
            item.requiresVerifiedRecovery ? "recovery" : "current",
            item.itemID.uuidString.lowercased(),
        ])
    }
    private static func matchExpression(_ terms: [String]) -> String? {
        let bounded = Array(terms.prefix(12))
        guard bounded.isEmpty == false else { return nil }
        var variants = Set<String>()
        for rawTerm in bounded {
            let term = String(rawTerm.prefix(47))
            guard term.isEmpty == false else { continue }
            variants.insert(quoted(term))
            if term.count >= 4 {
                variants.insert("\"\(quoted(term))*\"")
                let characters = Array(term)
                if characters.count > 4 {
                    for length in 4..<characters.count {
                        variants.insert(quoted(String(characters.prefix(length))))
                    }
                }
            }
        }
        guard variants.isEmpty == false else { return nil }
        return variants.sorted().joined(separator: " OR ")
    }

    private static func quoted(_ value: String) -> String {
        "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func key(_ itemID: UUID) -> String {
        itemID.uuidString.lowercased()
    }

    private func establishDatabase(
        at path: String,
        integrityBudget: Duration
    ) -> Bool {
        if let database {
            sqlite3_close(database)
            self.database = nil
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(
    &handle,
    SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
    nil
) == SQLITE_OK,
let handle = handle else {
    return false
}
self.database = handle
sqlite3_busy_timeout(handle, 250)
let deadlineBox = QueryDeadline(
    ContinuousClock().now.advanced(by: integrityBudget)
)
sqlite3_progress_handler(
    handle,
    1_000,
    { _, _, _, _ in
        Self.progressCallback
    },
    Unmanaged.passUnretained(deadlineBox).toOpaque()
)
// This catalog is derived data. Validate it before executing any
// schema DDL, and bound the whole SQLite establishment path so a
// pathological file cannot monopolize the index actor at launch.
let isPersistent = path != ":memory:"
let isValid = integrityIsValid(
    handle: handle,
    deadlineBox: deadlineBox,
    isPersistent: isPersistent
)
        sqlite3_progress_handler(handle, 0, nil, nil)
        withExtendedLifetime(deadlineBox) {}
        guard isValid else {
            sqlite3_close(handle)
            database = nil
            return false
        }
        return true
    }
    private func integrityIsValid() -> Bool {
        guard let statement = prepare("PRAGMA quick_check") else {
            return false
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW,
            let result = columnText(statement, 0) else { return false }
        return result.caseInsensitiveCompare("ok") == .orderedSame
    }

    private func schemaVersionIsCompatible() -> Bool {
        guard let version = scalarInteger("PRAGMA user_version"),
            let objectCount = scalarInteger(
                "SELECT COUNT(*) FROM sqlite_master "
                + "WHERE name NOT LIKE 'sqlite_%'"
            ) else { return false }
        // Version zero is accepted only for a genuinely empty database.
        // A populated zero-version file may contain incompatible objects;
        // this catalog is derived, so rebuilding is safer than migration.
        return version == Int64(Self.schemaVersion)
            || (version == 0 && objectCount == 0)
                || (version == 0 && objectCount == 0)
        }

        private func ftsContentIntegrityIsValid() -> Bool {
            // rank=1 compares the external-content table against every FTS5
            // posting. Core quick_check alone cannot detect a stale-but-valid
            // shadow index that would silently miss or resurrect evidence.
            execute(
                "INSERT INTO assistant_catalog_fts_v1("
                    + "assistant_catalog_fts_v1, rank) "
                    + "VALUES('integrity-check', 1)"
            )
        }

        private static func removeDerivedDatabaseFiles(atPath path: String) -> Bool {
            let manager = FileManager.default
            for candidate in [path, path + "-wal", path + "-shm"] {
                if manager.fileExists(atPath: candidate) {
                    try? manager.removeItem(atPath: candidate)
                }
            }
            return [path, path + "-wal", path + "-shm"].allSatisfy {
                manager.fileExists(atPath: $0) == false
            }
        }

        private func configureSchema(requiresWriteAheadLog: Bool) -> Bool {
            guard let journalMode = scalarText("PRAGMA journal_mode = WAL")?
                .lowercased(),
                requiresWriteAheadLog == false || journalMode == "wal",
                execute("PRAGMA synchronous = NORMAL"),
                execute("PRAGMA temp_store = MEMORY") else { return false }
            let schema = """
            CREATE TABLE IF NOT EXISTS assistant_catalog_meta_v1 (
                item_id TEXT PRIMARY KEY NOT NULL,
                fingerprint TEXT NOT NULL,
                generation INTEGER NOT NULL,
                chunk_count INTEGER NOT NULL
            );
            CREATE TABLE IF NOT EXISTS assistant_catalog_chunks_v1 (
                anchor_id TEXT PRIMARY KEY NOT NULL,
                item_id TEXT NOT NULL,
                item_name TEXT NOT NULL,
                source_kind TEXT NOT NULL,
                generation INTEGER NOT NULL,
                ordinal INTEGER NOT NULL,
                content_hash TEXT NOT NULL,
                text TEXT NOT NULL
            );
            CREATE INDEX IF NOT EXISTS assistant_catalog_chunks_item_v1
                ON assistant_catalog_chunks_v1(item_id, ordinal);
            CREATE VIRTUAL TABLE IF NOT EXISTS assistant_catalog_fts_v1 USING fts5(
                anchor_id UNINDEXED,
                item_id UNINDEXED,
                item_name,
                text,
                content='assistant_catalog_chunks_v1',
                content_rowid='rowid',
                tokenize='unicode61 remove_diacritics 2'
            );
            CREATE TRIGGER IF NOT EXISTS assistant_catalog_chunks_ai_v1
            AFTER INSERT ON assistant_catalog_chunks_v1 BEGIN
                INSERT INTO assistant_catalog_fts_v1(
                    rowid, anchor_id, item_id, item_name, text
                ) VALUES (new.rowid, new.anchor_id, new.item_id, new.item_name, new.text);
            END;
            CREATE TRIGGER IF NOT EXISTS assistant_catalog_chunks_ad_v1
            AFTER DELETE ON assistant_catalog_chunks_v1 BEGIN
                INSERT INTO assistant_catalog_fts_v1(
                    assistant_catalog_fts_v1, rowid,
                    anchor_id, item_id, item_name, text
                ) VALUES (
                    'delete', old.rowid,
                    old.anchor_id, old.item_id, old.item_name, old.text
                );
            END;
            CREATE TRIGGER IF NOT EXISTS assistant_catalog_chunks_au_v1
            AFTER UPDATE OF anchor_id, item_id, item_name, text
            ON assistant_catalog_chunks_v1 BEGIN
                INSERT INTO assistant_catalog_fts_v1(
                    assistant_catalog_fts_v1, rowid,
                    anchor_id, item_id, item_name, text
                ) VALUES (
                    'delete', old.rowid,
                    old.anchor_id, old.item_id, old.item_name, old.text
                );
                INSERT INTO assistant_catalog_fts_v1(
                    rowid, anchor_id, item_id, item_name, text
                ) VALUES (new.rowid, new.anchor_id, new.item_id, new.item_name, new.text);
            END;
            PRAGMA user_version = \(Self.schemaVersion);
            """
            return execute(schema)
                && scalarInteger("PRAGMA user_version")
                    == Int64(Self.schemaVersion)
        }

        private func transaction(
            interruptedBy deadline: QueryDeadline? = nil,
            _ operation: () -> Bool
        ) -> Bool {
            guard execute("BEGIN IMMEDIATE") else { return false }
            if operation() {
                // Once all bounded writes have completed, let COMMIT finish
                // atomically even if the clock crosses its boundary during
                // that final SQLite operation.
                deadline?.interruptsSQLite = false
                if execute("COMMIT") { return true }
            }
            // An expired progress handler must not interrupt ROLLBACK and
            // strand the connection inside a failed transaction.
            deadline?.interruptsSQLite = false
            _ = execute("ROLLBACK")
            return false
        }

        private func prepare(_ sql: String) -> OpaquePointer? {
            guard let database else { return nil }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK
            else { return nil }
            return statement
        }

        private func execute(
            _ sql: String,
            bindings: [Binding] = []
        ) -> Bool {
            if bindings.isEmpty {
                guard let database else { return false }
                return sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK
            }
            guard let statement = prepare(sql) else { return false }
            defer { sqlite3_finalize(statement) }
            for (offset, binding) in bindings.enumerated() {
                bind(binding, to: statement, at: Int32(offset + 1))
            }
            return sqlite3_step(statement) == SQLITE_DONE
        }

        private func bind(
            value: Binding,
            to statement: OpaquePointer,
            at index: Int32
        ) {
            switch value {
            case let .integer(integer):
                sqlite3_bind_int64(statement, index, integer)
            case let .text(text):
                _ = text.withCString { value in
                    sqlite3_bind_text(
                        statement,
                        index,
                        value,
                        -1,
                        Self.transient
                    )
                }
            }
        }

        private func columnText(
            _ statement: OpaquePointer,
            _ index: Int32,
            maximumUTF8ByteCount: Int = NotebookIndex.maximumChunkUTF8ByteCount
        ) -> String? {
            let byteCount = Int(sqlite3_column_bytes(statement, index))
            guard byteCount >= 0,
                byteCount <= maximumUTF8ByteCount else { return nil }
            guard let value = sqlite3_column_text(statement, index) else {
                return nil
            }
            return String(
                bytes: UnsafeBufferPointer(start: value, count: byteCount),
                encoding: .utf8
            )
        }
    }

    private struct Pending {
        let index: ItemIndex
        let task: Task<SpotlightMutationReport, Never>
        let spotlightMutationRevision: UInt64
        /// Foreground derived publication can outlive the bounded hot cache.
        /// Retain the exact pre-enrichment proposal until the provider report
        /// so a rejected/late write can always restore authored authority.
        let repairProposal: ItemIndex?
        var isSearchSuppressed = false
    }

    /// Tracks every actor-reentrant waiter sharing one pending publication.
    /// Cleanup requested by a cancelled owner runs only after the last joined
    /// waiter leaves, so suspension cannot pull state from a resumed peer.
    private struct PublicationWaiters {
        let spotlightMutationRevision: UInt64
        var ids: Set<UUID>
        var removePendingWhenEmpty: Bool
    }

    private struct ImageEnrichmentCommitResult: Sendable {
        let acceptedLocally: Bool
        let durablyPublished: Bool
        let acceptedProposal: ItemIndex?

        static let rejected = ImageEnrichmentCommitResult(
            acceptedLocally: false,
            durablyPublished: false,
            acceptedProposal: nil
        )
    }

    private struct ForegroundImageEnrichmentRequest: Sendable {
        let id: UUID
        let deadline: ContinuousClock.Instant
        let preferredPageIDs: [UUID]
        /// Foreground registration must not hash a potentially multi-megabyte
        /// fallback body on the actor. Capture the exact actor state used to
        /// prepare that hash so a reentrant registration cannot consume a
        /// fingerprint for different bytes.
        let expectedPriorRegistration: AssistantIndexedItem?
        let expectedRegistrationRevision: UInt64
        let preparedRegistration: AssistantIndexedItem
        let catalogProjectionFingerprint: String
        let preservesInstalledCatalogProjection: Bool
    }

    private struct ImageEnrichmentTaskRegistration {
        let generation: Int64
        let retriesAfterSuspension: Bool
        let cancel: @Sendable () -> Void
        let drain: Task<Void, Never>
    }

    private struct ImageEnrichmentTail {
        let taskID: UUID
        let drain: Task<Void, Never>
    }

    private struct RecoveryImageCleanup {
        let id: UUID
        let drain: Task<Void, Never>
    }

    private struct RecoveryRegistrationFence {
        let canvasDirectory: URL
        let recoveredGeneration: Int64
    }

    private struct SearchPreflight {
        let terms: [String]
        let limit: Int
    }

    private nonisolated static func searchPreflight(
        query: String,
        limit: Int
    ) -> SearchPreflight? {
        guard Task.isCancelled == false else { return nil }
        let boundedLimit = min(max(limit, 0), 50)
        guard boundedLimit > 0,
            query.utf8.count <= maximumSearchQueryUTF8ByteCount else {
            return nil
        }
        let terms = SearchText.meaningfulTerms(
            query,
            maximumCount: maximumSearchTermCount
        )
        guard terms.isEmpty == false else { return nil }
        return SearchPreflight(terms: terms, limit: boundedLimit)
    }

    private var registered: [UUID: AssistantIndexedItem] = [:]
    private var indexes: [UUID: ItemIndex] = [:]
    private var indexRecency: [UUID] = []
    private var cachedUnitCount = 0
    private var cachedTextUTF8ByteCount = 0
    private var manifests: [UUID: IndexManifest] = [:]
    private var publishedManifests: [UUID: IndexManifest] = [:]
    private var recentSpotlightUnits: [String: Unit] = [:]
    private var recentSpotlightRecency: [String] = []
    private var recentSpotlightTextUTF8ByteCount = 0
    private var libraryLexicalIndex = LibraryLexicalIndex(units: [])
    private var libraryLexicalRebuildRevision: UInt64 = 0
    private var pendingLibraryLexicalRebuild: LibraryLexicalRebuild?
    private let catalogLexicalIndex: CatalogFTSIndex
    private var extractionEpochs: [UUID: UInt64] = [:]
    private var latestRequested: [UUID: Int64] = [:]
    private var pending: [UUID: Pending] = [:]
    private var publicationWaiters: [UUID: PublicationWaiters] = [:]
    private var failedPublications: [UUID: ItemIndex] = [:]
    /// Oversized repair proposals get one immediate complete-domain attempt
    /// before ordinary deferred-memory caps may convert them to tombstones.
    private var protectedFailedPublicationIDs = Set<UUID>()
    private var failedDeletions = Set<UUID>()
    /// Core Spotlight operations are serialized only when they touch the same
    /// item domain. A provider callback that never returns therefore quarantines
    /// that item without holding every other notebook behind a global tail.
    private let spotlightMutationCoordinator = SpotlightDomainMutationCoordinator()
    private let spotlightMutationTimeout: Duration
    /// A timed-out provider may still finish physically. Remember only the
    /// exact mutation revision that drained until its fail-closed state is
    /// installed. An older callback must never consume or wake repair state
    /// created by a newer publication/deletion for the same notebook.
    private var lateDrainedSpotlightMutationRevisions: [UUID: UInt64] = [:]
    private var spotlightMutationRevisions: [UUID: UInt64] = [:]
    private var spotlightRetryInFlight = false
    private var spotlightRetryRequested = false
    private var foregroundRequestProposals: [
        UUID: (itemID: UUID, proposal: ItemIndex, epoch: UInt64)
    ] = [:]
    /// Foreground registration updates actor-visible identity immediately but
    /// never cold-opens or materializes the SQLite catalog on the user's
    /// answer deadline. Ordinary/background registration drains this bounded
    /// retry cache; invalidated rows remain fail-closed if their reproducible
    /// source is evicted.
    private var deferredCatalogRegistrations: [UUID: AssistantIndexedItem] = [:]
    private var deferredCatalogRegistrationRecency: [UUID] = []
    private var deferredCatalogRegistrationTextUTF8ByteCount = 0
    private var catalogProjectionFingerprints: [UUID: String] = [:]
    /// A foreground base publication may verify a newer generation while an
    /// unchanged catalog row deliberately remains on disk at its prior
    /// generation. This actor-owned certification keeps that exact row usable
    /// without putting synchronous SQLite work on the request deadline.
    private var catalogCertifiedGenerations: [UUID: Int64] = [:]
    /// Fences detached foreground fingerprint work against full-source
    /// registrations whose compact actor representation is identical.
    private var registrationSourceRevisions: [UUID: UInt64] = [:]
    /// The revision above describes semantic source bytes, not registration
    /// calls. Replaying an identical startup/catalog DTO must therefore be a
    /// no-op while a foreground fingerprint is suspended.
    private var registrationSourceFingerprints: [UUID: String] = [:]
    private let spotlight: (any NotebookSpotlightBacking)?
    private let interactiveSpotlight: (any NotebookSpotlightInteractiveQuerying)?
    /// At most one interactive Core Spotlight read may outlive its caller.
    /// Search, exact-anchor loads, and manifest loads share this quarantine so
    /// a cancellation-resistant provider cannot leak one raw task per request.
    private let spotlightInteractiveReadLane = SpotlightInteractiveReadLane()
    /// A cold Canvas/extraction replay can also acknowledge cancellation late.
    /// Keep one pipeline per notebook until its current raw stage really drains
    /// so repeated context/summary requests cannot accumulate detached work.
    private let coldHydrationLane = ColdHydrationLane()
    private let spotlightSearchTimeout: Duration
    private let libraryRetrievalTimeout: Duration
    private let imageAnalyzer: any AssistantImageAnalyzing
    private let imageEnrichmentDelay: Duration
    private var imageEnrichmentTasks: [
        UUID: [UUID: ImageEnrichmentTaskRegistration]
    ] = [:]
    /// A recovered lower checkpoint must never race a cancellation-resistant
    /// writer from the discarded higher generation. While this drain exists,
    /// authored indexing can proceed but every new OCR writer is fenced.
    private var recoveryImageCleanups: [UUID: RecoveryImageCleanup] = [:]
    /// Survives a failed physical cache cleanup and continues rejecting every
    /// new OCR writer until a later recovery attempt verifies both breadcrumb
    /// and cache removal.
    private var recoveryImageFencedItemIDs = Set<UUID>()
    /// Blocks stale whole-library/catalog DTOs from reinstalling the discarded
    /// higher generation between the actor rollback and the durable catalog
    /// repair. Only an index call carrying a verified snapshot may advance it.
    private var recoveryRegistrationFences: [UUID: RecoveryRegistrationFence] = [:]
    /// Volatile companion to the durable breadcrumb. It preserves retry
    /// Intent when file protection or a temporarily missing directory makes
    /// `markPending` fail, without pretending the write reached disk.
    private var imageEnrichmentRetryGenerations: [UUID: Int64] = [:]
    /// Only drains explicitly retained across suspension trigger an automatic
    /// recheck on completion. Ordinary provider failures stay on the bounded
    /// deferred-publication path and must never relaunch Vision in a loop.
    private var suspensionRetainedImageItemIDs = Set<UUID>()
    /// At most one post-drain breadcrumb recheck may wait for a notebook's
    /// cancellation-resistant framework work at a time.
    private var retainedImageDrainRetryItemIDs = Set<UUID>()
    /// Preserve same-notebook write ordering without making an uncooperative
    /// Vision/storage task a process-wide barrier for unrelated notebooks.
    private var imageEnrichmentTails: [UUID: ImageEnrichmentTail] = [:]
#if DEBUG
    private var beforeDurableImageEnrichmentLoadForTesting:
        (@Sendable () async -> Void)?
    private var beforeColdImageBreadcrumbAcknowledgementForTesting:
        (@Sendable () async -> Void)?
    private var beforeColdCanvasLoadForTesting:
        (@Sendable () async -> Void)?
    private var beforeSpotlightPublicationForTesting:
        (@Sendable () async -> Void)?
    private var beforeRegistrationSemanticMutationForTesting:
        (@Sendable () -> Void)?
    private var beforeForegroundCatalogFingerprintForTesting:
        (@Sendable () async -> Void)?
    private var beforeForegroundAuthoredBuildForTesting:
        (@Sendable () async -> Void)?
    private var beforeForegroundIndexRegistrationForTesting:
        (@Sendable () async -> Void)?
    private var beforeImageWorkEligibilityForTesting:
        (@Sendable () async -> Void)?
    private var beforeImageBreadcrumbWriteForTesting:
        (@Sendable () async -> Void)?
    private var beforeLibraryLexicalBuildForTesting:
        (@Sendable () async -> Void)?
#endif
    /// Vision/OCR is reproducible enrichment, never authoritative note data.
    /// Keep it suspended while an editor is visible so Pencil, scrolling, and
    /// canvas restoration always own the device's CPU/GPU/ANE budget.
    private var isBackgroundMaintenanceSuspended = false
    nonisolated private let freshnessLedger = NotebookIndexFreshnessLedger()
    nonisolated private let authoredFreshnessLedger = NotebookIndexFreshnessLedger()

#if DEBUG
    nonisolated static func chunksForTesting(
        _ text: String,
        maximum: Int,
        overlap: Int,
        maximumCount: Int,
        maximumUTF8Bytes: Int = .max
    ) -> [String]? {
        SearchText.chunks(
            text,
            maximum: maximum,
            overlap: overlap,
            maximumCount: maximumCount,
            maximumUTF8Bytes: maximumUTF8Bytes
        )
    }

    private(set) var lexicalUnitInspectionsForTesting = 0
    private(set) var libraryLexicalCandidateCountForTesting = 0
    private(set) var catalogLexicalCandidateCountForTesting = 0
    private(set) var libraryLexicalRebuildCountForTesting = 0
    private(set) var libraryLexicalCancelledRebuildCountForTesting = 0
    private(set) var itemIndexConstructionCountForTesting = 0
    var catalogLexicalProjectionTokenizationsForTesting: Int {
        catalogLexicalIndex.projectionTokenizationCount
    }

    var catalogPostingVisitsForTesting: Int {
        catalogLexicalIndex.postingVisitsForTesting
    }

    var catalogCommittedItemCountForTesting: Int {
        catalogLexicalIndex.committedItemCountForTesting
    }

    var deferredCatalogRegistrationCountForTesting: Int {
        deferredCatalogRegistrations.count
    }

    var deferredCatalogRegistrationTextUTF8ByteCountForTesting: Int {
        deferredCatalogRegistrationTextUTF8ByteCount
    }

    var deferredCatalogRegistrationItemIDsForTesting: Set<UUID> {
        Set(deferredCatalogRegistrations.keys)
    }

    func retainDeferredCatalogRegistrationForTesting(
        _ item: AssistantIndexedItem
    ) {
        retainDeferredCatalogRegistration(item)
    }

    /// Counts registrations materialized through the legacy candidate path by
    /// the most recent Library query. Bounded Library retrieval must remain at
    /// zero; its interactive path searches the maintained lexical/Spotlight
    /// indexes rather than enumerating every registered note.
    private(set) var libraryRegisteredItemEnumerationsForTesting = 0
#endif

    public init(
        items: [AssistantIndexedItem] = [],
        usesCoreSpotlight: Bool = false,
        catalogStorageURL: URL? = nil
    ) {
        imageAnalyzer = OnDeviceAssistantImageAnalyzer()
        imageEnrichmentDelay = .seconds(2)
        spotlightSearchTimeout = .milliseconds(650)
        libraryRetrievalTimeout = .milliseconds(900)
        spotlightMutationTimeout = Self.defaultSpotlightMutationTimeout
        catalogLexicalIndex = CatalogFTSIndex(
            storageURL: catalogStorageURL,
            items: items
        )
        for item in items {
            guard Self.isIndexableRegistration(item) else { continue }
            let catalogFingerprint = CatalogFTSIndex.sourceFingerprint(item)
            registered[item.itemID] = Self.compactRegistration(item)
            catalogProjectionFingerprints[item.itemID] =
                catalogFingerprint
            registrationSourceFingerprints[item.itemID] =
                Self.registrationSourceFingerprint(
                    item,
                    catalogProjectionFingerprint: catalogFingerprint
                )
        }
        let backend: (any NotebookSpotlightBacking)? =
            usesCoreSpotlight && CSSearchableIndex.isIndexingAvailable()
                ? SpotlightBackend()
                : nil
        spotlight = backend
        interactiveSpotlight = backend
    }

    init(
        items: [AssistantIndexedItem] = [],
        usesCoreSpotlight: Bool = false,
        imageAnalyzer: any AssistantImageAnalyzing,
        imageEnrichmentDelay: Duration
    ) {
        self.imageAnalyzer = imageAnalyzer
        self.imageEnrichmentDelay = imageEnrichmentDelay
        spotlightSearchTimeout = .milliseconds(650)
        libraryRetrievalTimeout = .milliseconds(900)
        spotlightMutationTimeout = Self.defaultSpotlightMutationTimeout
        catalogLexicalIndex = CatalogFTSIndex(items: items)
        for item in items {
            guard Self.isIndexableRegistration(item) else { continue }
            let catalogFingerprint = CatalogFTSIndex.sourceFingerprint(item)
            registered[item.itemID] = Self.compactRegistration(item)
            catalogProjectionFingerprints[item.itemID] =
                catalogFingerprint
            registrationSourceFingerprints[item.itemID] =
                Self.registrationSourceFingerprint(
                    item,
                    catalogProjectionFingerprint: catalogFingerprint
                )
        }
        let backend: (any NotebookSpotlightBacking)? =
            usesCoreSpotlight && CSSearchableIndex.isIndexingAvailable()
                ? SpotlightBackend()
                : nil
        spotlight = backend
        interactiveSpotlight = backend
    }

    init(
        items: [AssistantIndexedItem] = [],
        spotlightQuerying: any NotebookSpotlightInteractiveQuerying,
        spotlightSearchTimeout: Duration,
        libraryRetrievalTimeout: Duration
    ) {
        imageAnalyzer = OnDeviceAssistantImageAnalyzer()
        imageEnrichmentDelay = .seconds(2)
        self.spotlightSearchTimeout = max(spotlightSearchTimeout, .zero)
        self.libraryRetrievalTimeout = max(libraryRetrievalTimeout, .zero)
        spotlightMutationTimeout = Self.defaultSpotlightMutationTimeout
        catalogLexicalIndex = CatalogFTSIndex(items: items)
        for item in items {
            guard Self.isIndexableRegistration(item) else { continue }
            let catalogFingerprint = CatalogFTSIndex.sourceFingerprint(item)
            registered[item.itemID] = Self.compactRegistration(item)
            catalogProjectionFingerprints[item.itemID] =
                catalogFingerprint
            registrationSourceFingerprints[item.itemID] =
                Self.registrationSourceFingerprint(
                    item,
                    catalogProjectionFingerprint: catalogFingerprint
                )
        }
        spotlight = nil
        interactiveSpotlight = spotlightQuerying
    }

    init(
        items: [AssistantIndexedItem] = [],
        spotlightBackend: any NotebookSpotlightBacking,
        spotlightSearchTimeout: Duration = .milliseconds(650),
        libraryRetrievalTimeout: Duration = .milliseconds(900),
        spotlightMutationTimeout: Duration = NotebookIndex.defaultSpotlightMutationTimeout,
        imageAnalyzer: any AssistantImageAnalyzing,
        imageEnrichmentDelay: Duration
    ) {
        self.imageAnalyzer = imageAnalyzer
        self.imageEnrichmentDelay = imageEnrichmentDelay
        self.spotlightSearchTimeout = max(spotlightSearchTimeout, .zero)
        self.libraryRetrievalTimeout = max(libraryRetrievalTimeout, .zero)
        self.spotlightMutationTimeout = max(spotlightMutationTimeout, .zero)
        catalogLexicalIndex = CatalogFTSIndex(items: items)
        for item in items {
            guard Self.isIndexableRegistration(item) else { continue }
            let catalogFingerprint = CatalogFTSIndex.sourceFingerprint(item)
            registered[item.itemID] = Self.compactRegistration(item)
            catalogProjectionFingerprints[item.itemID] =
                catalogFingerprint
            registrationSourceFingerprints[item.itemID] =
                Self.registrationSourceFingerprint(
                    item,
                    catalogProjectionFingerprint: catalogFingerprint
                )
        }
        spotlight = spotlightBackend
        interactiveSpotlight = spotlightBackend
    }

    public nonisolated static func production(
        items: [AssistantIndexedItem] = [],
        catalogRootURL: URL? = nil
    ) -> NotebookIndex {
        NotebookIndex(
            items: items,
            usesCoreSpotlight: true,
            catalogStorageURL: catalogRootURL?.appendingPathComponent(
                "Derived/AssistantCatalog-v1.sqlite",
                isDirectory: false
            )
        )
    }

    public func register(_ items: [AssistantIndexedItem]) {
        for proposed in items {
            applyRegistration(proposed, updatesCatalog: true)
        }
    }

    /// Captures the exact actor state that a verified-recovery downgrade must
    /// compare against. The token deliberately carries no permission by itself:
    /// the commit still validates the target path and requires a strictly lower
    /// generation with an empty (not stale) fallback projection.
    func recoveryRegistrationToken(
        itemID: UUID
    ) -> RecoveryRegistrationToken? {
        guard !Task.isCancelled else { return nil }
        return RecoveryRegistrationToken(
            itemID: itemID,
            registration: registered[itemID],
            sourceRevision: registrationSourceRevisions[itemID, default: 0],
            sourceFingerprint: registrationSourceFingerprints[itemID]
        )
    }

    /// Canvas Core may recover `previous.canvas` and promote it as the new
    /// durable head after a newer current checkpoint is found corrupt. In that
    /// explicit recovery case, discard every newer derived retrieval surface
    /// and let the verified snapshot repopulate the hot index. The exact CAS
    /// prevents a reentrant newer save/registration from being downgraded.
    @discardableResult
    func reconcileVerifiedRecoveryRegistration(
        _ item: AssistantIndexedItem,
        expected token: RecoveryRegistrationToken
    ) -> Bool {
        guard Self.isIndexableRegistration(item),
            !Task.isCancelled,
            token.itemID == item.itemID,
            item.fallbackSearchableText.isEmpty,
            registered[item.itemID] == token.registration,
            registrationSourceRevisions[item.itemID, default: 0]
                == token.sourceRevision,
            registrationSourceFingerprints[item.itemID]
                == token.sourceFingerprint else {
            return false
        }
        let previous = registered[item.itemID]
        guard previous.map({
            $0.itemName == item.itemName
                && $0.kind == item.kind
                && $0.parentID == item.parentID
                && $0.canvasDirectory.standardizedFileURL
                    == item.canvasDirectory.standardizedFileURL
        }) ?? true else { return false }

        let compact = Self.compactRegistration(item)
        let catalogFingerprint = CatalogFTSIndex.sourceFingerprint(item)
        let targetSourceFingerprint = Self.registrationSourceFingerprint(
            item,
            catalogProjectionFingerprint: catalogFingerprint
        )
        let isAlreadyRecovered = previous == compact
            && registrationSourceFingerprints[item.itemID]
                == targetSourceFingerprint
        let canInstallRecoveredGeneration = previous.map {
            $0.expectedGeneration > item.expectedGeneration
                || ($0.expectedGeneration == item.expectedGeneration
                    && $0.requiresVerifiedRecovery)
        } ?? true
        guard isAlreadyRecovered || canInstallRecoveredGeneration else {
            return false
        }
        guard AssistantRecoveryMarkerStore.markPending(
            generation: item.expectedGeneration,
            for: item
        ) else { return false }
        if isAlreadyRecovered {
            // A prior attempt may have installed the actor fence before its
            // synchronous catalog transaction failed. Treat that exact state
            // as retryable success; every other regression remains rejected.
            recoveryRegistrationFences[item.itemID] = RecoveryRegistrationFence(
                canvasDirectory: item.canvasDirectory.standardizedFileURL,
                recoveredGeneration: item.expectedGeneration
            )
            if spotlight != nil { failedDeletions.insert(item.itemID) }
            let cancelledImageDrain = cancelImageEnrichment(for: item.itemID)
            beginRecoveryImageCleanup(
                for: item,
                after: cancelledImageDrain
            )
            return true
        }
        invalidateAuthoredContent(itemIDs: [item.itemID])
        registrationSourceRevisions[item.itemID, default: 0] &+= 1
        registrationSourceFingerprints[item.itemID] =
            targetSourceFingerprint
        let cancelledImageDrain = cancelImageEnrichment(for: item.itemID)
        clearMemory(for: item.itemID)
        latestRequested.removeValue(forKey: item.itemID)
        advanceEpoch(for: item.itemID)

        registered[item.itemID] = compact
        retainDeferredCatalogRegistration(item)
        catalogProjectionFingerprints.removeValue(forKey: item.itemID)
        catalogCertifiedGenerations.removeValue(forKey: item.itemID)
        catalogLexicalIndex.invalidateItemID(itemID: item.itemID)
        recoveryRegistrationFences[item.itemID] = RecoveryRegistrationFence(
            canvasDirectory: item.canvasDirectory.standardizedFileURL,
            recoveredGeneration: item.expectedGeneration
        )
        if spotlight != nil { failedDeletions.insert(item.itemID) }

        beginRecoveryImageCleanup(for: item, after: cancelledImageDrain)
        return true
    }

    /// Phase one of recovery completion. This publishes the exact recovered
    /// catalog body and verifies Spotlight plus OCR cleanup before the
    /// coordinator is allowed to lower the durable preview generation.
    func prepareVerifiedRecoveryCompletion(
        _ item: AssistantIndexedItem
    ) async -> RecoveryCompletionToken? {
        guard Self.isIndexableRegistration(item),
            let fence = recoveryRegistrationFences[item.itemID],
            fence.canvasDirectory
                == item.canvasDirectory.standardizedFileURL,
            item.expectedGeneration == fence.recoveredGeneration,
            AssistantRecoveryMarkerStore.isPending(
                in: item.canvasDirectory
            ) else { return nil }

        if recoveryImageFencedItemIDs.contains(item.itemID) {
            if recoveryImageCleanups[item.itemID] == nil {
                let cancelled = cancelImageEnrichment(for: item.itemID)
                beginRecoveryImageCleanup(for: item, after: cancelled)
            }
            let cleanup = recoveryImageCleanups[item.itemID]?.drain
            await cleanup?.value
        }
        guard !Task.isCancelled,
            recoveryImageFencedItemIDs.contains(item.itemID) == false,
            recoveryImageCleanups[item.itemID] == nil,
            recoveryRegistrationFences[item.itemID]?.recoveredGeneration
                == item.expectedGeneration,
            registered[item.itemID] == Self.compactRegistration(item) else {
            return nil
        }

        let catalogFingerprint = CatalogFTSIndex.sourceFingerprint(item)
        let sourceFingerprint = Self.registrationSourceFingerprint(
            item,
            catalogProjectionFingerprint: catalogFingerprint
        )
        if registrationSourceFingerprints[item.itemID] != sourceFingerprint {
            freshnessLedger.invalidate(ids: [item.itemID])
            registrationSourceRevisions[item.itemID, default: 0] &+= 1
        }
        guard catalogLexicalIndex.replaceRecoveredProjection(item) else {
            retainDeferredCatalogRegistration(item)
            catalogProjectionFingerprints.removeValue(forKey: item.itemID)
            return nil
        }
        registrationSourceFingerprints[item.itemID] = sourceFingerprint
        removeDeferredCatalogRegistration(item.itemID)
        catalogProjectionFingerprints[item.itemID] = catalogFingerprint
        catalogCertifiedGenerations.removeValue(forKey: item.itemID)

        await retryFailedSpotlightMutation(
            for: item.itemID,
            until: ContinuousClock().now.advanced(
                by: spotlightMutationTimeout
            )
        )
        guard !Task.isCancelled,
            recoveryRegistrationFences[item.itemID]?.recoveredGeneration
                == item.expectedGeneration,
            registered[item.itemID] == Self.compactRegistration(item),
            registrationSourceFingerprints[item.itemID] == sourceFingerprint,
            catalogLexicalIndex.hasExactProjection(item),
            pending[item.itemID] == nil,
            failedPublications[item.itemID] == nil,
            failedDeletions.contains(item.itemID) == false,
            let manifest = manifests[item.itemID],
            manifest.generation == item.expectedGeneration,
            manifest.registrationFingerprint
                == Self.registrationFingerprint(item),
            isDurablyPublished(manifest, itemID: item.itemID) else {
            return nil
        }
        return RecoveryCompletionToken(
            itemID: item.itemID,
            registration: Self.compactRegistration(item),
            sourceRevision: registrationSourceRevisions[
                item.itemID,
                default: 0
            ],
            sourceFingerprint: sourceFingerprint,
            manifestFingerprint: manifest.fingerprint,
            generation: item.expectedGeneration
        )
    }

    /// Phase two runs only after SwiftData has synchronously committed the
    /// recovered preview generation. Every other derived surface was already
    /// proven durable, so clearing the tiny marker is the final crash boundary.
    @discardableResult
    func completeVerifiedRecoveryRegistration(
        _ item: AssistantIndexedItem,
        expectedToken: RecoveryCompletionToken
    ) -> Bool {
        guard Self.isIndexableRegistration(item) else { return false }
        let compact = Self.compactRegistration(item)
        let catalogFingerprint = CatalogFTSIndex.sourceFingerprint(item)
        let sourceFingerprint = Self.registrationSourceFingerprint(
            item,
            catalogProjectionFingerprint: catalogFingerprint
        )
        guard token.itemID == item.itemID,
              token.generation == item.expectedGeneration,
              let recoveryFence = recoveryRegistrationFences[item.itemID],
              recoveryFence.canvasDirectory
                == item.canvasDirectory.standardizedFileURL,
              recoveryFence.recoveredGeneration == token.generation,
              compact == token.registration,
              sourceFingerprint == token.sourceFingerprint,
              registered[item.itemID] == token.registration,
              registrationSourceRevisions[item.itemID, default: 0]
                == token.sourceRevision,
              registrationSourceFingerprints[item.itemID]
                == token.sourceFingerprint,
              recoveryImageFencedItemIDs.contains(item.itemID) == false,
              catalogLexicalIndex.hasExactProjection(item),
              pending[item.itemID] == nil,
              failedPublications[item.itemID] == nil,
              failedDeletions.contains(item.itemID) == false,
              let manifest = manifests[item.itemID],
              manifest.generation == token.generation,
              manifest.fingerprint == token.manifestFingerprint,
              isDurablyPublished(manifest, itemID: item.itemID),
              AssistantRecoveryMarkerStore.clearPending(
                  throughGeneration: token.generation,
                  for: item
              ) else { return false }
        // Keep the in-memory fence after the durable marker is cleared. A
        // full-library maintenance task may have captured the discarded newer
        // DTO before recovery began and can resume after this method returns.
        // Only a later Canvas-verified generation is allowed to release the
        // fence in `applyRegistration`; ordinary catalog replay is rejected.
        return true
    }

    private func beginRecoveryImageCleanup(
        for item: AssistantIndexedItem,
        after cancelledImageDrain: Task<Void, Never>?
    ) {
        recoveryImageFencedItemIDs.insert(item.itemID)
        imageEnrichmentRetryGenerations[item.itemID] = item.expectedGeneration
        guard recoveryImageCleanups[item.itemID] == nil else { return }

        // The old generation's cache and breadcrumb use a process-wide file
        // lock, but a Vision writer may already be outside that critical
        // section. Drain every captured writer before unlinking its artifacts.
        // A failed unlink leaves the item fenced for a later bounded retry.
        let cleanupID = UUID()
        let cleanup = Task.detached(priority: .utility) {
            await cancelledImageDrain?.value
            return AssistantImageEnrichmentStore.removeVerified(for: item)
        }
        let cleanupDrain = Task { [weak self] in
            let succeeded = await cleanup.value
            await self?.finishRecoveryImageCleanup(
                itemID: item.itemID,
                cleanupID: cleanupID,
                succeeded: succeeded
            )
        }
        recoveryImageCleanups[item.itemID] = RecoveryImageCleanup(
            id: cleanupID,
            drain: cleanupDrain
        )
    }

    private func finishRecoveryImageCleanup(
        itemID: UUID,
        cleanupID: UUID,
        succeeded: Bool
    ) {
        guard recoveryImageCleanups[itemID]?.id == cleanupID else { return }
        recoveryImageCleanups.removeValue(forKey: itemID)
        guard succeeded else { return }
        recoveryImageFencedItemIDs.remove(itemID)
        guard isBackgroundMaintenanceSuspended == false,
              let item = registered[itemID] else { return }
        Task { [weak self] in
            await self?.repairPendingImageEnrichmentIfNeeded(item)
        }
    }

    private func invalidateAuthoredContent(
        itemIDs: some Sequence<UUID>
    ) {
        let itemIDs = Array(itemIDs)
        freshnessLedger.invalidate(itemIDs: itemIDs)
        authoredFreshnessLedger.invalidate(itemIDs: itemIDs)
    }

    private func registerForForeground(
        request: ForegroundImageEnrichmentRequest,
        verifiedGeneration: Int64
    ) -> Bool {
        let itemID = request.preparedRegistration.itemID
        guard registered[itemID] == request.expectedPriorRegistration,
              registrationSourceRevisions[itemID, default: 0]
                == request.expectedRegistrationRevision else { return false }
        let preparedSourceFingerprint = Self.registrationSourceFingerprint(
            request.preparedRegistration,
            catalogProjectionFingerprint: request.catalogProjectionFingerprint
        )
        let expectedRevisionAdvance: UInt64 =
            registrationSourceFingerprints[itemID] == preparedSourceFingerprint
                ? 0
                : 1
        applyRegistration(
            request.preparedRegistration,
            updatesCatalog: false,
            foregroundCatalogFingerprint: request.catalogProjectionFingerprint,
            verifiedGeneration: verifiedGeneration
        )
        return registrationSourceRevisions[itemID, default: 0]
            == request.expectedRegistrationRevision &+ expectedRevisionAdvance
            && registrationSourceFingerprints[itemID] == preparedSourceFingerprint
    }

    private func retainDeferredCatalogRegistration(
        _ item: AssistantIndexedItem
    ) {
        removeDeferredCatalogRegistration(item.itemID)

        // Recovery projections and oversized legacy bodies are represented by
        // metadata only, so retaining their raw fallback text cannot improve a
        // later retry. For ordinary admitted projections, one item's source is
        // independently capped at eight MiB.
        let retainedItem = if item.requiresVerifiedRecovery
            || item.fallbackSearchableText.utf8.count
                > Self.maximumIndexedSourceTextUTF8ByteCount {
            Self.compactRegistration(item)
        } else {
            item
        }
        let retainedBytes = retainedItem.fallbackSearchableText.utf8.count
        guard retainedBytes
            <= Self.maximumDeferredCatalogRegistrationTextUTF8ByteCount
        else { return }

        deferredCatalogRegistrations[item.itemID] = retainedItem
        deferredCatalogRegistrationRecency.append(item.itemID)
        deferredCatalogRegistrationTextUTF8ByteCount += retainedBytes

        while deferredCatalogRegistrations.count
            > Self.maximumDeferredCatalogRegistrationItems
            || deferredCatalogRegistrationTextUTF8ByteCount
                > Self.maximumDeferredCatalogRegistrationTextUTF8ByteCount {
            guard let oldest = deferredCatalogRegistrationRecency.first else {
                deferredCatalogRegistrations.removeAll(keepingCapacity: false)
                deferredCatalogRegistrationTextUTF8ByteCount = 0
                break
            }
            removeDeferredCatalogRegistration(oldest)
        }
    }

    @discardableResult
    private func removeDeferredCatalogRegistration(
        _ itemID: UUID
    ) -> AssistantIndexedItem? {
        deferredCatalogRegistrationRecency.removeAll { $0 == itemID }
        guard let removed = deferredCatalogRegistrations.removeValue(
            forKey: itemID
        ) else { return nil }
        let removedBytes = removed.fallbackSearchableText.utf8.count
        deferredCatalogRegistrationTextUTF8ByteCount = removedBytes
            >= deferredCatalogRegistrationTextUTF8ByteCount
            ? 0
            : deferredCatalogRegistrationTextUTF8ByteCount - removedBytes
        return removed
    }

    private func applyRegistration(
        _ proposed: AssistantIndexedItem,
        updatesCatalog: Bool,
        foregroundCatalogFingerprint: String? = nil,
        verifiedGeneration: Int64? = nil
    ) {
        guard Self.isIndexableRegistration(proposed) else {
            // A legacy/corrupt name must not be multiplied into catalog,
            // lexical, or Spotlight records. Keep any old projection fenced.
            if registered[proposed.itemID] != nil {
                invalidateAuthoredContent(itemIDs: [proposed.itemID])
                cancelImageEnrichment(for: proposed.itemID)
                clearMemory(for: proposed.itemID)
                registered.removeValue(forKey: proposed.itemID)
                registrationSourceFingerprints.removeValue(
                    forKey: proposed.itemID
                )
                registrationSourceRevisions[proposed.itemID, default: 0] &+= 1
                advanceEpoch(for: proposed.itemID)
                catalogLexicalIndex.invalidate(itemID: proposed.itemID)
                catalogProjectionFingerprints.removeValue(
                    forKey: proposed.itemID
                )
                removeDeferredCatalogRegistration(proposed.itemID)
                if spotlight != nil { failedDeletions.insert(proposed.itemID) }
            }
            return
        }
        if let recoveryFence = recoveryRegistrationFences[proposed.itemID] {
            let sameStore = recoveryFence.canvasDirectory
                == proposed.canvasDirectory.standardizedFileURL
            if sameStore == false {
                recoveryRegistrationFences.removeValue(forKey: proposed.itemID)
            } else if proposed.requiresVerifiedRecovery,
                verifiedGeneration == nil {
                return
            } else if proposed.expectedGeneration
                > recoveryFence.recoveredGeneration {
                // Whole-library maintenance still carries the old catalog DTO
                // until the replacement preview commits. Only a snapshot that
                // was verified by Canvas Core may advance beyond the fence.
                guard verifiedGeneration == proposed.expectedGeneration else {
                    return
                }
                recoveryRegistrationFences.removeValue(forKey: proposed.itemID)
            }
        }
        let item = Self.nonRegressingRegistration(
            proposed,
            previous: registered[proposed.itemID]
        )
        let old = registered[item.itemID]
        let isRegression = Self.isRegistrationRegression(
            proposed,
            previous: old
        )
        let catalogFingerprint: String
        if updatesCatalog {
            catalogFingerprint = CatalogFTSIndex.sourceFingerprint(item)
        } else if let foregroundCatalogFingerprint {
            catalogFingerprint = foregroundCatalogFingerprint
        } else {
            // Fail closed if a caller reaches foreground publication without
            // the catalog fingerprint prepared by the registration phase.
            // A debug assertion here used to terminate the app even though
            // safely rejecting this stale/incomplete publication is enough.
            return
        }
        let compact = Self.compactRegistration(item)
        let sourceFingerprint = Self.registrationSourceFingerprint(
            item,
            catalogProjectionFingerprint: catalogFingerprint
        )
        let sourceChanged = registrationSourceFingerprints[item.itemID]
            != sourceFingerprint
        let semanticLedger = freshnessLedger
        let authoredLedger = authoredFreshnessLedger
        #if DEBUG
        let mutationHook = beforeRegistrationSemanticMutationForTesting
        #endif
        let invalidateBeforeSemanticMutation: @Sendable () -> Void = {
            // Publication receipts are synchronously claimable from the
            // MainActor. Advance their shared ledger before SQLite or the
            // actor-owned registration exposes any replacement bytes.
            semanticLedger.invalidate(itemIDs: [item.itemID])
            #if DEBUG
            mutationHook?()
            #endif
        }
        let invalidateBeforeAuthoredMutation: @Sendable () -> Void = {
            // Identity, location, or verified generation changes invalidate
            // both ordinary retrieval and a pinned in-flight summary.
            semanticLedger.invalidate(itemIDs: [item.itemID])
            authoredLedger.invalidate(itemIDs: [item.itemID])
            #if DEBUG
            mutationHook?()
            #endif
        }
        if isRegression == false {
            if updatesCatalog {
                let catalogProjectionChanged =
                    catalogProjectionFingerprints[item.itemID]
                        != catalogFingerprint
                let accepted: Bool
                if old != compact {
                    invalidateBeforeAuthoredMutation()
                    accepted = catalogLexicalIndex.update(item)
                } else if sourceChanged {
                    // Advance logical freshness even if opening or writing the
                    // durable catalog fails. The new full source becomes the
                    // deferred authority and the old row is fenced below.
                    invalidateBeforeSemanticMutation()
                    accepted = catalogLexicalIndex.update(item)
                } else {
                    // Materializing an already-deferred identical source is a
                    // physical catch-up, not another semantic transition.
                    accepted = catalogLexicalIndex.update(item)
                }
                if accepted {
                    removeDeferredCatalogRegistration(item.itemID)
                    catalogProjectionFingerprints[item.itemID] =
                        catalogFingerprint
                    if catalogProjectionChanged {
                        catalogCertifiedGenerations.removeValue(
                            forKey: item.itemID
                        )
                    }
                } else {
                    retainDeferredCatalogRegistration(item)
                    catalogProjectionFingerprints.removeValue(
                        forKey: item.itemID
                    )
                    catalogCertifiedGenerations.removeValue(forKey: item.itemID)
                    catalogLexicalIndex.invalidate(itemID: item.itemID)
                }
            } else {
                let catalogProjectionChanged =
                    catalogProjectionFingerprints[item.itemID]
                        != catalogFingerprint
                if old != compact {
                    invalidateBeforeAuthoredMutation()
                } else if sourceChanged {
                    invalidateBeforeSemanticMutation()
                }
                // Preserve an already-current catalog row when the full source
                // projection is unchanged. A changed projection is fenced in
                // O(1) until ordinary maintenance installs these exact bytes.
                if catalogProjectionChanged {
                    catalogLexicalIndex.invalidate(itemID: item.itemID)
                    catalogProjectionFingerprints.removeValue(
                        forKey: item.itemID
                    )
                    catalogCertifiedGenerations.removeValue(forKey: item.itemID)
                }
                retainDeferredCatalogRegistration(item)
            }
        }
        registered[item.itemID] = compact
        if isRegression == false, sourceChanged {
            registrationSourceFingerprints[item.itemID] = sourceFingerprint
            registrationSourceRevisions[item.itemID, default: 0] &+= 1
        }
        if let old, Self.registrationChanged(old, compact) {
            cancelImageEnrichment(for: item.itemID)
            clearMemory(for: item.itemID)
            advanceEpoch(for: item.itemID)
            // Queue the persisted domain for background repair; interactive
            // read/search paths validate freshness without waiting behind it.
            if spotlight != nil { failedDeletions.insert(item.itemID) }
        }
    }

    func beginRegisteredItemReconciliation() async
        -> RegisteredItemReconciliation {
        let persisted = await spotlight?.persistedItemIDs() ?? []
        let catalogItemIDs = catalogLexicalIndex.itemIDs
        let known = Set(registered.keys)
            .union(indexes.keys)
            .union(manifests.keys)
            .union(persisted)
            .union(catalogItemIDs)
        return RegisteredItemReconciliation(knownItemIDs: known)
    }

    func finishRegisteredItemReconciliation(
        _ reconciliation: RegisteredItemReconciliation,
        desiredItemIDs: Set<UUID>
    ) async {
        guard Task.isCancelled == false else { return }
        await unregister(
            reconciliation.knownItemIDs.subtracting(desiredItemIDs)
        )
        await retryFailedSpotlightMutations()
    }

    public func replaceRegisteredItems(_ items: [AssistantIndexedItem]) async {
        let reconciliation = await beginRegisteredItemReconciliation()
        let ordered = items.sorted { $0.itemID.uuidString < $1.itemID.uuidString }
        for item in ordered {
            guard Task.isCancelled == false else { return }
            register([item])
            // One import is capped by the repository; yielding between items
            // prevents startup reconciliation from monopolizing the actor for
            // total-library hashing/tokenization time.
            await Task.yield()
        }
        guard Task.isCancelled == false else { return }
        let desired = Set(items.map(\.itemID))
        await finishRegisteredItemReconciliation(
            reconciliation,
            desiredItemIDs: desired
        )
    }

    public func reconcile(with items: [AssistantIndexedItem]) async {
        await replaceRegisteredItems(items)
    }

    /// Removes selected items from every searchable surface while preserving
    /// their reproducible files. Trash/restore uses this narrower operation so
    /// one catalog mutation never requires a cancellable full-library pass.
    public func unregister(_ itemIDs: Set<UUID>) async {
        guard itemIDs.isEmpty == false else { return }
        invalidateAuthoredContent(itemIDs: itemIDs)
        for itemID in itemIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            registrationSourceRevisions[itemID, default: 0] &+= 1
            registrationSourceFingerprints.removeValue(forKey: itemID)
            registered.removeValue(forKey: itemID)
            removeDeferredCatalogRegistration(itemID)
            catalogProjectionFingerprints.removeValue(forKey: itemID)
            catalogCertifiedGenerations.removeValue(forKey: itemID)
            _ = catalogLexicalIndex.remove(itemID: itemID)
            let imageTask = cancelImageEnrichment(for: itemID)
            imageTask?.cancel()
            clearMemory(for: itemID)
            latestRequested.removeValue(forKey: itemID)
            advanceEpoch(for: itemID)
        }
        await deleteSpotlightDomains(Array(itemIDs))
        await retryFailedSpotlightMutations()
    }

    public func suspendBackgroundMaintenance() {
        guard isBackgroundMaintenanceSuspended == false else { return }
        isBackgroundMaintenanceSuspended = true
        for (itemID, entries) in imageEnrichmentTasks {
            for entry in entries.values {
                entry.cancel()
                guard entry.retriesAfterSuspension else { continue }
                imageEnrichmentRetryGenerations[itemID] = max(
                    imageEnrichmentRetryGenerations[itemID, default: 0],
                    entry.generation
                )
                suspensionRetainedImageItemIDs.insert(itemID)
            }
        }
        // Keep each item's tail as its own drain barrier. Resumed work awaits
        // that notebook's cancellation-resistant predecessor through its
        // final write without holding unrelated notebooks behind it; task
        // handles remain until completion so purge/invalidation can drain.
    }

    public func resumeBackgroundMaintenance() {
        isBackgroundMaintenanceSuspended = false
    }

    public func prepareLibrary(_ items: [AssistantIndexedItem]) async {
        await reconcile(with: items)
        await prepareRegisteredLibrary(itemIDs: items.map(\.itemID))
    }

    /// Warms durable per-item indexes for registrations that have already
    /// been reconciled on the coordinator's serialized catalog lane. This
    /// phase is disposable and cancellation-safe; it never removes or revives
    /// catalog registrations from a stale full-library snapshot.
    public func prepareRegisteredLibrary(itemIDs: [UUID]) async {
        // An editor may have opened after a library preparation task was
        // FIXME(photo-cutoff): illegible line between 3291 and 3293; needs re-shoot
        // already scheduled reproducible enrichment while interactive canvas work is
        // active.
        guard isBackgroundMaintenanceSuspended == false else { return }
        // In production this is a one-time/background migration pass. A
        // lightweight manifest query skips current items, and each stale item
        // is extracted and released before moving to the next; searches never
        // wait for or recreate this full-library pass.
        for itemID in itemIDs.sorted(by: {
            $0.uuidString < $1.uuidString
        }) {
            guard !Task.isCancelled,
                isBackgroundMaintenanceSuspended == false else { return }
            if let deferred = deferredCatalogRegistrations[itemID] {
                register([deferred])
            }
            guard let item = registered[itemID] else { continue }
            await ensureIndexed(item)
            await Task.yield()
        }
    }

    public func invalidate(itemID: UUID) async {
        invalidateAuthoredContent(itemIDs: [itemID])
        // A detached foreground fingerprint prepared before invalidation must
        // not be allowed to register and republish its older snapshot after
        // this destructive freshness boundary.
        registrationSourceRevisions[itemID, default: 0] &+= 1
        catalogCertifiedGenerations.removeValue(forKey: itemID)
        let item = registered[itemID]
        let imageEnrichmentTask = cancelImageEnrichment(for: itemID)
        clearMemory(for: itemID)
        latestRequested.removeValue(forKey: itemID)
        advanceEpoch(for: itemID)
        let invalidationEpoch = extractionEpochs[itemID, default: 0]
        await deleteSpotlightDomains([itemID])
        if let item {
            // Drain the cancelled writer before unlinking its cache. Actor
            // reentrancy can admit a newer verified save while either awaits is
            // in flight, so recheck epoch/latest state before the synchronous,
            // store-locked removal.
            await imageEnrichmentTask?.value
            guard extractionEpochs[itemID, default: 0] == invalidationEpoch,
                latestRequested[itemID] == nil else { return }
            AssistantImageEnrichmentStore.remove(for: item)
        }
    }

    /// Irreversibly removes every retrieval surface owned by a library item.
    /// This is intentionally stronger than `invalidate(itemID:)`, whose item
    /// registration must survive an edit so catalog fallback remains usable.
    public func purge(
        itemID: UUID,
        deletingArtifactsFor artifactItem: AssistantIndexedItem? = nil
    ) async throws {
        invalidateAuthoredContent(itemIDs: [itemID])
        registrationSourceRevisions[itemID, default: 0] &+= 1
        registrationSourceFingerprints.removeValue(forKey: itemID)
        let registeredItem = registered.removeValue(forKey: itemID)
        removeDeferredCatalogRegistration(itemID)
        catalogProjectionFingerprints.removeValue(forKey: itemID)
        catalogCertifiedGenerations.removeValue(forKey: itemID)
        let catalogPurgeError: (any Error)?
        do {
            try catalogLexicalIndex.purgePermanently(itemID: itemID)
            catalogPurgeError = nil
        } catch {
            // Continue clearing every other retrieval surface, but preserve
            // the durable-catalog failure so the irrecoverable caller cannot
            // report success without a verified physical scrub.
            catalogPurgeError = error
        }
        let imageEnrichmentTask = cancelImageEnrichment(for: itemID)
        clearMemory(for: itemID)
        latestRequested.removeValue(forKey: itemID)
        advanceEpoch(for: itemID)
        let spotlightDeletionSucceeded = await deleteSpotlightDomains([itemID])
        if let item = artifactItem ?? registeredItem {
            try await Task.detached(priority: .background) {
                // A cancelled Vision pass may be inside an atomic cache write.
                // Drain it before unlinking the final enrichment files so a
                // late write cannot resurrect derived data after deletion.
                await imageEnrichmentTask?.value
                try AssistantImageEnrichmentStore.removeForPermanentDeletion(
                    for: item
                )
            }.value
        } else {
            await imageEnrichmentTask?.value
        }
        if let catalogPurgeError { throw catalogPurgeError }
        guard spotlightDeletionSucceeded else {
            throw PermanentPurgeError.spotlightDeletionFailed
        }
    }

    public func generation(for itemID: UUID) -> Int64? {
        manifests[itemID]?.generation ?? indexes[itemID]?.generation
    }

    // Eager indexing hook for a snapshot that has completed verified autosave.
    @discardableResult
    public func index(
        snapshot: CanvasCoreSnapshot,
        item: AssistantIndexedItem
    ) async -> Bool {
        await index(snapshot: snapshot, item: item, delta: nil)
    }

    // Incremental verified-autosave hook. The delta is trusted only while a
    // bounded cached index exactly matches its base generation; cache misses,
    // migrations, and generation gaps automatically take the full path.
    @discardableResult
    public func index(
        snapshot: CanvasCoreSnapshot,
        item: AssistantIndexedItem,
        delta: CanvasVerifiedIndexDelta?
    ) async -> Bool {
        await index(
            snapshot: snapshot,
            item: item,
            delta: delta,
            registersCatalogProjection: true
        )
    }

    /// Publishes the verified authored text first, then opportunistically adds
    /// Vision evidence for the pages most relevant to the open editor. The
    /// absolute deadline is owned by the visible assistant request; if Vision
    /// loses that race, the accepted base publication remains current and the
    /// pending breadcrumb keeps derived enrichment restartable.
    @discardableResult
    public func indexForForegroundRequest(
        snapshot: CanvasCoreSnapshot,
        item: AssistantIndexedItem,
        delta: CanvasVerifiedIndexDelta?,
        preferredPageIDs: [UUID],
        enrichmentDeadline: ContinuousClock.Instant
    ) async -> Bool {
        let clock = ContinuousClock()
        guard Self.isIndexableRegistration(item),
            !Task.isCancelled,
            clock.now < enrichmentDeadline else {
            return false
        }
        let expectedPriorRegistration = registered[item.itemID]
        guard Self.isRegistrationRegression(
            item,
            previous: expectedPriorRegistration
        ) == false else {
            return false
        }
        let expectedRegistrationRevision =
            registrationSourceRevisions[item.itemID, default: 0]
        let fingerprintTask = Task.detached(priority: .userInitiated) {
            CatalogFTSIndex.sourceFingerprint(item)
        }
#if DEBUG
        await beforeForegroundCatalogFingerprintForTesting?()
#endif
        let fingerprintOutcome = await assistantImageTaskOutcome(
            of: fingerprintTask,
            until: enrichmentDeadline
        )
        guard case let .value(catalogProjectionFingerprint) = fingerprintOutcome,
            !Task.isCancelled,
            clock.now < enrichmentDeadline,
            registered[item.itemID] == expectedPriorRegistration,
            registrationSourceRevisions[item.itemID, default: 0]
                == expectedRegistrationRevision else {
            return false
        }
        let preservesInstalledCatalogProjection =
            catalogProjectionFingerprints[item.itemID]
                == catalogProjectionFingerprint
        let request = ForegroundImageEnrichmentRequest(
            id: UUID(),
            deadline: enrichmentDeadline,
            preferredPageIDs: preferredPageIDs,
            expectedPriorRegistration: expectedPriorRegistration,
            expectedRegistrationRevision: expectedRegistrationRevision,
            preparedRegistration: item,
            catalogProjectionFingerprint: catalogProjectionFingerprint,
            preservesInstalledCatalogProjection:
                preservesInstalledCatalogProjection
        )
        let indexingTask = Task { [weak self] in
            await self?.index(
                snapshot: snapshot,
                item: item,
                delta: delta,
                registersCatalogProjection: true,
                foregroundImageEnrichment: request
            ) ?? false
        }
        let outcome = await assistantImageTaskOutcome(
            of: indexingTask,
            until: enrichmentDeadline
        )
        defer { foregroundRequestProposals.removeValue(forKey: request.id) }
        switch outcome {
        case let .value(accepted):
            return accepted
        case .cancelled:
            if let expected = foregroundRequestProposals[request.id],
                expected.itemID == item.itemID {
                abandonTimedOutForegroundImageCommit(
                    itemID: item.itemID,
                    generation: max(snapshot.generation, 0),
                    epoch: expected.epoch
                )
            }
            return false
        case .timedOut:
            // The inner derived-commit race normally performs this transition,
            // but the outer whole-index deadline can resume on the actor first.
            // Hide any non-base pending proposal before reporting readiness so
            // the immediately following assistant search cannot observe OCR
            // that missed the same immutable cutoff.
            guard let expected = foregroundRequestProposals[request.id],
                expected.itemID == item.itemID else { return false }
            abandonTimedOutForegroundImageCommit(
                itemID: item.itemID,
                generation: max(snapshot.generation, 0),
                epoch: expected.epoch
            )
            guard
                let registeredItem = registered[item.itemID],
            Self.registrationFingerprint(registeredItem)
                == Self.registrationFingerprint(item),
            latestRequested[item.itemID] == max(snapshot.generation, 0)
            else { return false }
        return foregroundRequestRemainsAccepted(
            expected: expected.proposal,
            itemID: item.itemID
        )
    }
}

    /// The outer request deadline can win its scheduler race even after the
    /// inner derived commit completed before that deadline. Request state is
    /// updated to that exact successor inside the committing actor turn, so a
    /// timeout must never infer acceptance from a different request's later
    /// same-generation enrichment merely because authored text still matches.
    private func foregroundRequestRemainsAccepted(
        expected: ItemIndex,
        itemID: UUID
    ) -> Bool {
        guard let item = registered[itemID],
            expected.generation >= item.expectedGeneration,
            expected.registrationFingerprint
                == Self.registrationFingerprint(item) else { return false }
        if manifests[itemID] == expected.manifest,
            isDurablyPublished(expected.manifest, itemID: itemID) {
            return true
        }
        guard let current = visibleLocalIndex(for: itemID),
            current.generation == expected.generation,
            current.manifest == expected.manifest,
            proposalMatchesCurrentRegistration(current, itemID: itemID)
            else { return false }
        return true
    }

    private func index(
        snapshot: CanvasCoreSnapshot,
        item proposedItem: AssistantIndexedItem,
        delta: CanvasVerifiedIndexDelta?,
        registersCatalogProjection: Bool,
        foregroundImageEnrichment: ForegroundImageEnrichmentRequest? = nil,
        snapshotHydrationLease: NotebookSnapshotHydrationLease? = nil
    ) async -> Bool {
        guard Self.isIndexableRegistration(proposedItem) else { return false }
        let generation = max(snapshot.generation, 0)
        if let foregroundImageEnrichment {
#if DEBUG
            await beforeForegroundIndexRegistrationForTesting?()
#endif
            guard !Task.isCancelled,
                ContinuousClock().now < foregroundImageEnrichment.deadline,
                registerForForeground(
                    foregroundImageEnrichment,
                    verifiedGeneration: generation
                ) else {
                return false
            }
        } else if registersCatalogProjection {
            applyRegistration(
                proposedItem,
                updatesCatalog: true,
                verifiedGeneration: generation
            )
        }
        guard let item = registered[proposedItem.itemID] else { return false }
        guard generation >= item.expectedGeneration,
            generation >= latestRequested[item.itemID, default: 0] else { return false }
        // A newer verified save supersedes every derived task, even when the
        // new snapshot no longer contains an image. This prevents a cancelled
        // older OCR pass from recreating a cache for deleted content.
        // A second request for the same verified generation is allowed to
        // join the in-flight derived publication. Only an actually newer save
        // supersedes those tasks; cancelling equal-generation work here would
        // prevent the shared-publication waiter state machine from operating.
        let supersededImageTask = cancelImageEnrichment(
            for: item.itemID,
            beforeGeneration: generation
        )
        latestRequested[item.itemID] = generation
        let epoch = extractionEpochs[item.itemID, default: 0]
        let applicableDelta: CanvasVerifiedIndexDelta?
        let previousUnits: [Unit]?
        if let delta,
            delta.generation == generation,
            delta.baseGeneration < delta.generation,
            let previous = indexes[item.itemID],
            previous.generation == delta.baseGeneration {
            applicableDelta = delta
            previousUnits = previous.units
        } else {
            applicableDelta = nil
            previousUnits = nil
        }
#if DEBUG
        let authoredBuildHook = foregroundImageEnrichment == nil
            ? nil
            : beforeForegroundAuthoredBuildForTesting
#endif
        let authoredBuilder = Task.detached(
            priority: foregroundImageEnrichment == nil ? .utility : .userInitiated
        ) { [snapshotHydrationLease] in
            defer { withExtendedLifetime(snapshotHydrationLease) {} }
#if DEBUG
            await authoredBuildHook?()
#endif
            return await Self.buildAuthoredBaseUnits(
                snapshot: snapshot,
                item: item,
                generation: generation,
                delta: applicableDelta,
                previousUnits: previousUnits
            )
        }
        let authoredBaseUnits: [Unit]
        if let foregroundImageEnrichment {
            let outcome = await assistantImageTaskOutcome(
                of: authoredBuilder,
                until: foregroundImageEnrichment.deadline
            )
            guard case let .value(optionalUnits) = outcome,
                let optionalUnits else { return false }
            authoredBaseUnits = optionalUnits
        } else {
            guard let units = await authoredBuilder.value else { return false }
            authoredBaseUnits = units
        }
        guard !Task.isCancelled,
            foregroundImageEnrichment.map({
                ContinuousClock().now < $0.deadline
            }) ?? true,
            registered[item.itemID] == item,
            extractionEpochs[item.itemID, default: 0] == epoch,
            latestRequested[item.itemID] == generation else { return false }
        var enrichmentBaseUnits = authoredBaseUnits
        let durableReplay = await durableImageEnrichmentReplay(
            over: authoredBaseUnits,
            item: item,
            generation: generation
        )
        // The detached cache read above is a suspension point. Registration,
        // a newer verified save, or cancellation may have superseded this
        // proposal while it was off-actor; never let stale pre-rename units
        // acquire the new registration fingerprint inside `replace`.
        guard !Task.isCancelled,
        registered[item.itemID] == item,
        extractionEpochs[item.itemID, default: 0] == epoch,
        latestRequested[item.itemID] == generation else { return false }
        // Chunking, hashing, and lexical-posting construction can be large for
        // imported PDFs. Keep that pure work off the actor and race it against
        // the same immutable foreground cutoff; a late result owns no state
        // and is simply discarded.
        let registrationFingerprint = Self.registrationFingerprint(item)
        let proposalBuilder = Task.detached(
            priority: foregroundImageEnrichment == nil ? .utility : .userInitiated
        ) {
            Self.buildInitialProposalBundle(
                durableReplayUnits: durableReplay.units,
                hasDurableRecords: durableReplay.records.isEmpty == false,
                authoredBaseUnits: authoredBaseUnits,
                generation: generation,
                itemID: item.itemID,
                registrationFingerprint: registrationFingerprint
            )
        }
        let proposalBundle: InitialProposalBundle
        if let foregroundImageEnrichment {
            let outcome = await assistantImageTaskOutcome(
                of: proposalBuilder,
                until: foregroundImageEnrichment.deadline
            )
            guard case let .value(optionalBundle) = outcome,
                let optionalBundle else { return false }
            proposalBundle = optionalBundle
        } else {
            guard let built = await proposalBuilder.value else { return false }
            proposalBundle = built
        }
#if DEBUG
        itemIndexConstructionCountForTesting += proposalBundle.constructionCount
#endif
        guard !Task.isCancelled,
            foregroundImageEnrichment.map({
                ContinuousClock().now < $0.deadline
            }) ?? true,
            registered[item.itemID] == item,
            extractionEpochs[item.itemID, default: 0] == epoch,
            latestRequested[item.itemID] == generation else { return false }
        let replayProposal = proposalBundle.replay
        let authoredProposal = proposalBundle.authored
        var foregroundPromotesDurableReplay = foregroundImageEnrichment != nil
            && durableReplay.records.isEmpty == false
            && isDurablyPublished(
                replayProposal.manifest,
                itemID: item.itemID
            ) == false
        if foregroundPromotesDurableReplay {
            // A cold actor may not yet have hydrated the already-enriched
            // Spotlight manifest. Publishing the authored base first can
            // therefore temporarily demote that physical domain. Persist the
            // repair breadcrumb before doing so; a deadline that wins during
            // cache promotion must leave background maintenance something
            // durable to resume.
            let deferred = await deferImageEnrichment(
                generation: generation,
                item: item,
                deadline: foregroundImageEnrichment?.deadline,
                expectedEpoch: epoch
            )
            guard !Task.isCancelled,
                foregroundImageEnrichment.map({
                    ContinuousClock().now < $0.deadline
                }) ?? true,
                registered[item.itemID] == item,
                extractionEpochs[item.itemID, default: 0] == epoch,
                latestRequested[item.itemID] == generation else { return false }
            if deferred == false {
                // Do not demote an already-enriched durable domain unless the
                // repair intent itself survived storage protection. Fall back
                // to the exact schema-v2 replay proposal: its complete cache
                // is already durable restart authority, so request readiness
                // need not fail merely because the tiny breadcrumb could not
                // be updated.
                foregroundPromotesDurableReplay = false
            }
        }
        let initialProposal = foregroundPromotesDurableReplay
            ? authoredProposal
            : replayProposal
        if let foregroundImageEnrichment {
            foregroundRequestProposals[foregroundImageEnrichment.id] = (
                itemID: item.itemID,
                proposal: initialProposal,
                epoch: epoch
            )
        }
        var replaced = await replace(
            proposal: initialProposal,
            itemID: item.itemID,
            expectedRegistration: item,
            expectedEpoch: epoch
        )
        var replayDurablyPublished = foregroundPromotesDurableReplay == false
            && replaced && isDurablyPublished(
                replayProposal.manifest,
                itemID: item.itemID
            )
        if replaced == false,
            let visible = pending[item.itemID]?.index ?? indexes[item.itemID],
            visible.generation == generation,
            visible.units.contains(where: { $0.kind == .imageContent }) {
            // A prior request may already be publishing page-local Vision
            // evidence, including after writing a complete restart cache.
            // Accept the exact same authored snapshot by comparing only the
            // non-derived projection of that pending/current proposal. A real
            // equal-generation authored conflict still fails below.
            let visibleUnits = visible.units
            let expectedAuthoredUnits = proposalBundle.authoredWithoutDerivedUnits
            let comparison = Task.detached(priority: .userInitiated) {
                visibleUnits.filter { $0.kind != .imageContent }
                    == expectedAuthoredUnits
            }
            let matchesAuthoredProjection: Bool
            if let foregroundImageEnrichment {
                let outcome = await assistantImageTaskOutcome(
                    of: comparison,
                    until: foregroundImageEnrichment.deadline
                )
                guard case let .value(matches) = outcome else { return false }
                matchesAuthoredProjection = matches
            } else {
                matchesAuthoredProjection = await comparison.value
            }
            guard !Task.isCancelled,
                foregroundImageEnrichment.map({
                    ContinuousClock().now < $0.deadline
                }) ?? true,
                registered[item.itemID] == item,
                extractionEpochs[item.itemID, default: 0] == epoch,
                latestRequested[item.itemID] == generation else {
                return false
            }
            if matchesAuthoredProjection,
                authoredProposal.registrationFingerprint
                    == visible.registrationFingerprint {
                replaced = true
                let readinessAuthority = if let pending = pending[item.itemID],
                    pending.index.manifest
                        == visible.manifest,
                    pending.isSearchSuppressed,
                    let repair = pending.repairProposal {
                    repair
                } else {
                    visible
                }
                // A second same-generation targeted request may no longer be
                // able to replay the original delta. The already-visible
                // enriched proposal is exact authored authority, so carry its
                // unvisited OCR forward into this request's partial commit and
                // repair proposal instead of silently dropping it. A suppressed
        // proposal is raw carry-forward input only, however: request
        // readiness must remain anchored to the authored repair that is
        // actually visible to search until the derived write succeeds.
        enrichmentBaseUnits = authoredBaseUnits.filter {
            $0.kind != .imageContent
        } + visible.units.filter { $0.kind == .imageContent }
        if let foregroundImageEnrichment,
            var expected = foregroundRequestProposals[
                foregroundImageEnrichment.id
            ],
            expected.itemID == item.itemID,
            expected.epoch == epoch {
            expected.proposal = readinessAuthority
            foregroundRequestProposals[
                foregroundImageEnrichment.id
            ] = expected
        }
        }
        }
        if replaced == false, durableReplay.records.isEmpty == false {
            guard !Task.isCancelled,
                registered[item.itemID] == item,
                extractionEpochs[item.itemID, default: 0] == epoch,
                latestRequested[item.itemID] == generation else { return false }
            let effective = pending[item.itemID]?.index.manifest
                ?? indexes[item.itemID]?.manifest
                ?? manifests[item.itemID]
            // A complete exact-generation cache may have reached disk just
            // before a crash, while the authoritative text-only manifest is
            // still current. Promote only from that exact base fingerprint;
            // an authored equal-generation conflict remains rejected.
            if effective == authoredProposal.manifest {
                let commit = await replaceImageEnrichment(
                    records: durableReplay.records,
                    baseUnits: enrichmentBaseUnits,
                    generation: generation,
                    itemID: item.itemID,
                    epoch: epoch,
                    allowsSuspendedReplay: true
                )
                replaced = commit.acceptedLocally
                replayDurablyPublished = commit.durablyPublished
            }
        }
        if replaced {
            if let foregroundImageEnrichment {
                if foregroundImageEnrichment.preservesInstalledCatalogProjection,
                    catalogProjectionFingerprints[item.itemID]
                        == foregroundImageEnrichment.catalogProjectionFingerprint {
                    catalogCertifiedGenerations[item.itemID] = max(
                        catalogCertifiedGenerations[item.itemID, default: 0],
                        generation
                    )
                }
            } else {
                certifyCatalogProjectionIfPossible(
                    itemID: item.itemID,
                    generation: generation
                )
            }
            if durableReplay.records.isEmpty == false {
                if let foregroundImageEnrichment,
                    foregroundPromotesDurableReplay {
                    _ = await commitForegroundImageEnrichment(
                        records: durableReplay.records,
                        replacingImageContentOn: nil,
                        hasDurableCache: true,
                        hasCompleteDurableCache: true,
                        item: item,
                        baseUnits: enrichmentBaseUnits,
                        generation: generation,
                        epoch: epoch,
                        request: foregroundImageEnrichment
                    )
                } else if replayDurablyPublished {
                    if imageEnrichmentRetryGenerations[item.itemID]
                        .map({ $0 <= generation }) == true {
                        imageEnrichmentRetryGenerations.removeValue(
                            forKey: item.itemID
                        )
                    }
                    suspensionRetainedImageItemIDs.remove(item.itemID)
                    await Task.detached(priority: .utility) {
                        AssistantImageEnrichmentStore.clearPending(
                            generation: generation,
                            for: item
                        )
                    }.value
                } else if isBackgroundMaintenanceSuspended {
                    await deferImageEnrichment(
                        generation: generation,
                        item: item,
                        deadline: foregroundImageEnrichment?.deadline,
                        expectedEpoch: epoch
                    )
                } else {
                    // The exact OCR cache is already reusable, so this pass is
                    // normally just a fast, complete-domain Spotlight retry.
                    await scheduleImageEnrichment(
                        snapshot: snapshot,
                        item: item,
                        baseUnits: enrichmentBaseUnits,
                        generation: generation,
                        epoch: epoch,
                        snapshotHydrationLease: snapshotHydrationLease
                    )
                }
                return true
            }
            if foregroundImageEnrichment != nil {
                // Record volatile restart intent before the eligibility probe.
                // If that pure probe loses the immutable request deadline, a
                // later preparation still reopens the verified snapshot and
                // determines whether durable Vision work actually exists.
                imageEnrichmentRetryGenerations[item.itemID] = max(
                    imageEnrichmentRetryGenerations[item.itemID, default: 0],
                    generation
                )
            }
#if DEBUG
        let imageWorkHook = beforeImageWorkEligibilityForTesting
#endif
        let workCheck = Task.detached(priority: .utility) {
            [snapshotHydrationLease] in
            defer { withExtendedLifetime(snapshotHydrationLease) {} }
#if DEBUG
            await imageWorkHook?()
#endif
            return AssistantImageEnrichmentWorker.mayHaveWork(
                snapshot: snapshot,
                item: item
            )
        }
        let mayHaveImageWork: Bool
        if let foregroundImageEnrichment {
            let outcome = await assistantImageTaskOutcome(
                of: workCheck,
                until: foregroundImageEnrichment.deadline
            )
            guard case let .value(hasWork) = outcome else {
                // Generation alone is not an ownership token: a newer
                // same-generation request can install its own intent while
                // this cancelled probe unwinds. Destructive freshness
                // boundaries clear old intent; only a definitive current
                // no-work result or complete commit may acknowledge it.
                return true
            }
            mayHaveImageWork = hasWork
        } else {
            mayHaveImageWork = await workCheck.value
        }
        guard !Task.isCancelled,
            foregroundImageEnrichment.map({
                ContinuousClock().now < $0.deadline
            }) ?? true,
            registered[item.itemID] == item,
            extractionEpochs[item.itemID, default: 0] == epoch,
            latestRequested[item.itemID] == generation else {
            return true
        }
        if mayHaveImageWork {
            if let foregroundImageEnrichment {
                // Persist restartability before spending request time. A
                // timeout keeps this breadcrumb and the already-published
                // authored base index; only a complete derived commit may
                // acknowledge it below.
                guard await deferImageEnrichment(
                    generation: generation,
                    item: item,
                    deadline: foregroundImageEnrichment.deadline,
                    expectedEpoch: epoch
                ) else {
                    // Authored text is already accepted. Skip disposable
                    // request-time Vision when its restart contract could
                    // not be persisted; the volatile intent is retried by
                    // later preparation without risking late OCR.
                    return true
                }
                await performForegroundImageEnrichment(
                    snapshot: snapshot,
                    item: item,
                    baseUnits: enrichmentBaseUnits,
                    generation: generation,
                    epoch: epoch,
                    request: foregroundImageEnrichment,
                    snapshotHydrationLease: snapshotHydrationLease
                )
            } else if isBackgroundMaintenanceSuspended {
                await deferImageEnrichment(
                    generation: generation,
                    item: item,
                    deadline: foregroundImageEnrichment?.deadline,
                    expectedEpoch: epoch
                )
            } else {
                await scheduleImageEnrichment(
                    snapshot: snapshot,
                    item: item,
                    baseUnits: enrichmentBaseUnits,
                    generation: generation,
                    epoch: epoch,
                    snapshotHydrationLease: snapshotHydrationLease
                )
            }
        } else {
            if imageEnrichmentRetryGenerations[item.itemID]
                .map({ $0 <= generation }) == true {
                imageEnrichmentRetryGenerations.removeValue(
                    forKey: item.itemID
                )
            }
            suspensionRetainedImageItemIDs.remove(item.itemID)
            // Let a just-cancelled writer leave its critical section
            // before removing all derived files. The cleanup remains
            // detached from the save/open path, but stays in the common
            // drain registry so suspension, invalidation, and tests cannot
            // outrun a cancellation-resistant Vision writer.
        let cleanupTask = Task.detached(priority: .background) {
            await supersededImageTask?.value
            AssistantImageEnrichmentStore.remove(
                throughGeneration: generation,
                for: item
            )
        }
        let cleanupTaskID = UUID()
        let cleanupDrain = Task { [weak self] in
            await cleanupTask.value
            await self?.finishImageEnrichment(
                itemID: item.itemID,
                taskID: cleanupTaskID
            )
        }
        registerImageEnrichmentTask(
            itemID: item.itemID,
            taskID: cleanupTaskID,
            generation: generation,
            retriesAfterSuspension: false,
                    cancel: { cleanupTask.cancel() },
                    drain: cleanupDrain
                )
            }
        }
        return replaced
    }

    /// Image enrichment is deliberately a second commit at the same verified
    /// generation. The public replacement API keeps rejecting conflicting
    /// equal-generation writes; only this generation/epoch-checked path may add
    /// disposable OCR and visual metadata to an already committed text index.
    private func beginPublicationWait(
        itemID: UUID,
        spotlightMutationRevision: UInt64
    ) -> UUID {
        let waiterID = UUID()
        if var waiters = publicationWaiters[itemID],
            waiters.spotlightMutationRevision == spotlightMutationRevision {
            waiters.ids.insert(waiterID)
            publicationWaiters[itemID] = waiters
        } else {
            publicationWaiters[itemID] = PublicationWaiters(
                spotlightMutationRevision: spotlightMutationRevision,
                ids: [waiterID],
                removePendingWhenEmpty: false
            )
        }
        return waiterID
    }

    /// Returns true only when a cancelled owner requested cleanup and every
    /// other waiter sharing that exact publication has also left.
    private func endPublicationWait(
        itemID: UUID,
        waiterID: UUID,
        spotlightMutationRevision: UInt64,
        removePendingWhenEmpty: Bool
    ) -> Bool {
        guard var waiters = publicationWaiters[itemID],
            waiters.spotlightMutationRevision == spotlightMutationRevision,
            waiters.ids.remove(waiterID) != nil else { return false }
        waiters.removePendingWhenEmpty = waiters.removePendingWhenEmpty
            || removePendingWhenEmpty
        guard waiters.ids.isEmpty else {
            publicationWaiters[itemID] = waiters
            return false
        }
        publicationWaiters.removeValue(forKey: itemID)
        return waiters.removePendingWhenEmpty
    }

    private func replaceImageEnrichment(
        records: [AssistantImageEnrichmentRecord],
        baseUnits: [Unit],
        replacingImageContentOn visitedPageIDs: Set<UUID>? = nil,
        generation: Int64,
        itemID: UUID,
        epoch: UInt64,
        allowsSuspendedReplay: Bool = false,
        deadline: ContinuousClock.Instant? = nil
    ) async -> ImageEnrichmentCommitResult {
        guard !Task.isCancelled,
            deadline.map({ ContinuousClock().now < $0 }) ?? true,
            allowsSuspendedReplay || isBackgroundMaintenanceSuspended == false,
            let registeredItem = registered[itemID],
            extractionEpochs[itemID, default: 0] == epoch,
            latestRequested[itemID] == generation else { return .rejected }

        let proposalBuilder = Task.detached(
            priority: deadline == nil ? .utility : .userInitiated
        ) {
            Self.buildImageEnrichmentProposalBundle(
                records: records,
                baseUnits: baseUnits,
                replacingImageContentOn: visitedPageIDs,
                generation: generation,
                item: registeredItem
            )
        }
        let proposalBundle: ImageEnrichmentProposalBundle
        if let deadline {
            let outcome = await assistantImageTaskOutcome(
                of: proposalBuilder,
                until: deadline
            )
            guard case let .value(optionalBundle) = outcome,
                let optionalBundle else { return .rejected }
            proposalBundle = optionalBundle
        } else {
            guard let built = await proposalBuilder.value else {
                return .rejected
            }
            proposalBundle = built
        }
#if DEBUG
            itemIndexConstructionCountForTesting += 2
#endif
        guard !Task.isCancelled,
            deadline.map({ ContinuousClock().now < $0 }) ?? true,
            allowsSuspendedReplay || isBackgroundMaintenanceSuspended == false,
            registered[itemID] == registeredItem,
            extractionEpochs[itemID, default: 0] == epoch,
            latestRequested[itemID] == generation else { return .rejected }
        let proposal = proposalBundle.proposal
        let repairProposal = proposalBundle.repairProposal
        guard let effective = pending[itemID]?.index.manifest
            ?? indexes[itemID]?.manifest
            ?? manifests[itemID],
            effective.generation == generation else { return .rejected }

        if proposal.fingerprint == effective.fingerprint {
            if isDurablyPublished(proposal.manifest, itemID: itemID) {
                return ImageEnrichmentCommitResult(
                    acceptedLocally: true,
                    durablyPublished: true,
                    acceptedProposal: proposal
                )
            }

            // A prior publication may have failed after the enriched proposal
            // became the local source of truth. Retry the complete domain
            // instead of acknowledging the cache and deleting its restart
            // breadcrumb merely because the local fingerprint already matches.
            let task: Task<SpotlightMutationReport, Never>
            let mutationRevision: UInt64
            let ownsPending: Bool
            if let current = pending[itemID],
                current.index.manifest == proposal.manifest {
                task = current.task
                mutationRevision = current.spotlightMutationRevision
                ownsPending = false
            } else {
                let publication = publicationTask(itemID: itemID, proposal: proposal)
                task = publication.task
                mutationRevision = publication.revision
                pending[itemID] = Pending(
                    index: proposal,
                    task: task,
                    spotlightMutationRevision: mutationRevision,
                    repairProposal: repairProposal
                )
                ownsPending = true
            }
            let waiterID = beginPublicationWait(
                itemID: itemID,
                spotlightMutationRevision: mutationRevision
            )
            let report = await task.value
            guard !Task.isCancelled,
                deadline.map({ ContinuousClock().now < $0 }) ?? true,
                allowsSuspendedReplay || isBackgroundMaintenanceSuspended == false,
                registered[itemID] == registeredItem,
                extractionEpochs[itemID, default: 0] == epoch,
                latestRequested[itemID] == generation else {
                let shouldRemovePending = endPublicationWait(
                    itemID: itemID,
                    waiterID: waiterID,
                    spotlightMutationRevision: mutationRevision,
                    removePendingWhenEmpty: ownsPending
                )
                if shouldRemovePending,
                    pending[itemID]?.index.manifest == proposal.manifest,
                    pending[itemID]?.spotlightMutationRevision == mutationRevision {
                    let authoritativeRepair = pending[itemID]?.repairProposal
                    freshnessLedger.invalidate(itemIDs: [itemID])
                    pending.removeValue(forKey: itemID)
                    rebuildLibraryLexicalIndex()
                    quarantineRejectedSpotlightPublication(
                        itemID: itemID,
                        mutationRevision: mutationRevision,
                        authoritativeRepair: authoritativeRepair
                    )
                }
                return .rejected
            }
            _ = endPublicationWait(
                itemID: itemID,
                waiterID: waiterID,
                spotlightMutationRevision: mutationRevision,
                removePendingWhenEmpty: false
            )
            finalize(
                itemID: itemID,
                proposal: proposal,
                publicationSucceeded: report.succeeded,
                spotlightMutationRevision: mutationRevision,
                expectedEpoch: epoch
            )
            let acceptedLocally = manifests[itemID] == proposal.manifest
            return ImageEnrichmentCommitResult(
                acceptedLocally: acceptedLocally,
                durablyPublished: acceptedLocally && isDurablyPublished(
                    proposal.manifest,
                    itemID: itemID
                ),
                acceptedProposal: acceptedLocally ? proposal : nil
            )
        }

        freshnessLedger.invalidate(itemIDs: [itemID])
        let publication = publicationTask(itemID: itemID, proposal: proposal)
        let task = publication.task
        pending[itemID] = Pending(
            index: proposal,
            task: task,
            spotlightMutationRevision: publication.revision,
            repairProposal: repairProposal
        )
        let waiterID = beginPublicationWait(
            itemID: itemID,
            spotlightMutationRevision: publication.revision
        )
        let report = await task.value
        guard !Task.isCancelled,
            deadline.map({ ContinuousClock().now < $0 }) ?? true,
            allowsSuspendedReplay || isBackgroundMaintenanceSuspended == false,
            registered[itemID] == registeredItem,
            extractionEpochs[itemID, default: 0] == epoch,
            latestRequested[itemID] == generation else {
            // The durable publication may have crossed the cancellation
            // boundary, but a suspended/superseded proposal must never become
            // the in-memory source of truth or leak into interactive search.
            let shouldRemovePending = endPublicationWait(
                itemID: itemID,
                waiterID: waiterID,
                spotlightMutationRevision: publication.revision,
                removePendingWhenEmpty: true
            )
            if shouldRemovePending,
                pending[itemID]?.index.fingerprint == proposal.fingerprint,
                pending[itemID]?.spotlightMutationRevision == publication.revision {
                let authoritativeRepair = pending[itemID]?.repairProposal
                freshnessLedger.invalidate(itemIDs: [itemID])
                pending.removeValue(forKey: itemID)
                rebuildLibraryLexicalIndex()
                quarantineRejectedSpotlightPublication(
                    itemID: itemID,
                    mutationRevision: publication.revision,
                    authoritativeRepair: authoritativeRepair
                )
            }
            return .rejected
        }
        _ = endPublicationWait(
            itemID: itemID,
            waiterID: waiterID,
            spotlightMutationRevision: publication.revision,
            removePendingWhenEmpty: false
        )
        finalize(
            itemID: itemID,
            proposal: proposal,
            publicationSucceeded: report.succeeded,
            spotlightMutationRevision: publication.revision,
            expectedEpoch: epoch
        )
        let acceptedLocally = manifests[itemID] == proposal.manifest
        return ImageEnrichmentCommitResult(
            acceptedLocally: acceptedLocally,
            durablyPublished: acceptedLocally && isDurablyPublished(
                proposal.manifest,
                itemID: itemID
            ),
            acceptedProposal: acceptedLocally ? proposal : nil
        )
    }

    /// A provider can finish a complete-domain write after its foreground
    /// owner timed out. Fail every Spotlight read closed immediately, retain
    /// the current local/base proposal as the repair authority, and enqueue a
    /// full replacement. Exact per-chunk manifest stamps cover the actor-
    /// reentrant window before this report returns.
    private func quarantineRejectedSpotlightPublication(
        itemID: UUID,
        mutationRevision: UInt64,
        authoritativeRepair: ItemIndex?
    ) {
        guard spotlight != nil,
            spotlightMutationRevisions[itemID] == mutationRevision else {
            return
        }
        publishedManifests.removeValue(forKey: itemID)
        evictRecentSpotlightUnits(for: itemID)
        let authoritative: ItemIndex? = if let authoritativeRepair,
            manifests[itemID] == authoritativeRepair.manifest,
            proposalMatchesCurrentRegistration(
                authoritativeRepair,
                itemID: itemID
            ) {
            authoritativeRepair
        } else if let cached = indexes[itemID],
            manifests[itemID] == cached.manifest {
            cached
        } else {
            nil
        }
        if let authoritative {
            if canProtectFailedPublication(authoritative, itemID: itemID) {
                failedPublications[itemID] = authoritative
                // Repairs admitted under the fixed deferred-memory ceilings get
                // one immediate complete-domain attempt before ordinary trimming
                // may demote them to UUID tombstones.
                protectedFailedPublicationIDs.insert(itemID)
            } else {
                // Protection must not turn the deferred-publication ceilings
                // into soft limits. Under overload, preserve fail-closed
                // correctness with a compact physical-deletion retry instead of
                // retaining another complete lexical index in memory.
                failedPublications.removeValue(forKey: itemID)
                protectedFailedPublicationIDs.remove(itemID)
                failedDeletions.insert(itemID)
                if manifests[itemID] == authoritative.manifest {
                    manifests.removeValue(forKey: itemID)
                }
                removeCachedIndex(itemID, rebuildLibraryIndex: false)
            }
        } else {
            failedDeletions.insert(itemID)
        }
        trimDeferredMutations()
        rebuildLibraryLexicalIndex()
        Task { [weak self] in
            await self?.retryFailedSpotlightMutations()
        }
    }

    private func isDurablyPublished(
        _ manifest: IndexManifest,
        itemID: UUID
    ) -> Bool {
        guard spotlight != nil else { return manifests[itemID] == manifest }
        return publishedManifests[itemID] == manifest
            && failedPublications[itemID]?.manifest != manifest
            && failedDeletions.contains(itemID) == false
    }

    /// Image enrichment can produce several independent records on one page.
    /// A deterministic local block identity lets chunk de-overlap operate on
    /// one image at a time instead of treating all page images as one stream.
    private nonisolated static func imageBlockID(_ stableID: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data(stableID.utf8)).prefix(16))
        return UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
    }

    /// Adds request-useful Vision evidence without resuming catalog-wide
    /// maintenance. Both analysis and publication race the same immutable
    /// cutoff. Losing either race leaves the accepted authored proposal in
    /// place and the pending breadcrumb intact for later background repair.
    private func performForegroundImageEnrichment(
        snapshot: CanvasCoreSnapshot,
        item: AssistantIndexedItem,
        baseUnits: [Unit],
        generation: Int64,
        epoch: UInt64,
        request: ForegroundImageEnrichmentRequest,
        snapshotHydrationLease: NotebookSnapshotHydrationLease? = nil
    ) async {
        let clock = ContinuousClock()
        guard !Task.isCancelled,
            clock.now < request.deadline,
            registered[item.itemID] == item,
            extractionEpochs[item.itemID, default: 0] == epoch,
            latestRequested[item.itemID] == generation else { return }

        let analyzer = imageAnalyzer
        let analysisTask = Task.detached(priority: .userInitiated) {
            [snapshotHydrationLease] in
            defer { withExtendedLifetime(snapshotHydrationLease) {} }
            return await AssistantImageEnrichmentWorker.enrichForForegroundRequest(
                snapshot: snapshot,
                item: item,
                analyzer: analyzer,
                preferredPageIDs: request.preferredPageIDs,
                deadline: request.deadline,
                snapshotHydrationLease: snapshotHydrationLease
            )
        }
        let analysisTaskID = UUID()
        let analysisDrain = Task { [weak self, snapshotHydrationLease] in
            defer { withExtendedLifetime(snapshotHydrationLease) {} }
            _ = await analysisTask.value
            await self?.finishImageEnrichment(
                itemID: item.itemID,
                taskID: analysisTaskID
            )
        }
        registerImageEnrichmentTask(
            itemID: item.itemID,
            taskID: analysisTaskID,
            generation: generation,
            cancel: { analysisTask.cancel() },
            drain: analysisDrain
        )
        let analysisOutcome = await assistantImageTaskOutcome(
            of: analysisTask,
            until: request.deadline
        )
        guard case let .value(optionalResult) = analysisOutcome,
            let result = optionalResult,
            !Task.isCancelled,
            clock.now < request.deadline,
            registered[item.itemID] == item,
            extractionEpochs[item.itemID, default: 0] == epoch,
            latestRequested[item.itemID] == generation else { return }

        _ = await commitForegroundImageEnrichment(
            records: result.records,
            replacingImageContentOn: result.visitedPageIDs,
            hasDurableCache: result.hasDurableCache,
            hasCompleteDurableCache: result.hasCompleteDurableCache,
            item: item,
            baseUnits: baseUnits,
            generation: generation,
            epoch: epoch,
            request: request
        )
    }

    @discardableResult
    private func commitForegroundImageEnrichment(
        records: [AssistantImageEnrichmentRecord],
        replacingImageContentOn visitedPageIDs: Set<UUID>?,
        hasDurableCache: Bool,
        hasCompleteDurableCache: Bool,
        item: AssistantIndexedItem,
        baseUnits: [Unit],
        generation: Int64,
        epoch: UInt64,
        request: ForegroundImageEnrichmentRequest
    ) async -> Bool {
        let clock = ContinuousClock()
        guard !Task.isCancelled,
            clock.now < request.deadline,
            hasDurableCache else { return false }
        let commitTask = Task { [weak self] in
            await self?.replaceForegroundImageEnrichment(
                records: records,
                baseUnits: baseUnits,
                replacingImageContentOn: visitedPageIDs,
                generation: generation,
                item: item,
                epoch: epoch,
                request: request
            ) ?? .rejected
        }
        let commitOutcome = await assistantImageTaskOutcome(
            of: commitTask,
            until: request.deadline
        )
        guard case let .value(commit) = commitOutcome,
            clock.now < request.deadline,
            commit.acceptedLocally,
            commit.durablyPublished else {
            abandonTimedOutForegroundImageCommit(
                itemID: item.itemID,
                generation: generation,
                epoch: epoch
            )
            return false
        }

        if hasCompleteDurableCache {
            if imageEnrichmentRetryGenerations[item.itemID]
                .map({ $0 <= generation }) == true {
                imageEnrichmentRetryGenerations.removeValue(forKey: item.itemID)
            }
            suspensionRetainedImageItemIDs.remove(item.itemID)
            // Completion is now real, so breadcrumb acknowledgement is safe
            // even if the UI deadline wins immediately after this actor turn.
            _ = Task.detached(priority: .utility) {
                AssistantImageEnrichmentStore.clearPending(
                    generation: generation,
                    for: item
                )
            }
        }
        return true
    }

    // Records the accepted successor before the commit task returns its
    // value to the deadline watcher. Result delivery can lose a scheduler
    // race at the cutoff; this actor turn is the durable commit's timing
    // proof even when the oversized successor is absent from the hot cache.
    private func replaceForegroundImageEnrichment(
        records: [AssistantImageEnrichmentRecord],
        baseUnits: [Unit],
        replacingImageContentOn visitedPageIDs: Set<UUID>?,
        generation: Int64,
        item: AssistantIndexedItem,
        epoch: UInt64,
        request: ForegroundImageEnrichmentRequest
    ) async -> ImageEnrichmentCommitResult {
        let commit = await replaceImageEnrichment(
            records: records,
            baseUnits: baseUnits,
            replacingImageContentOn: visitedPageIDs,
            generation: generation,
            itemID: item.itemID,
            epoch: epoch,
            allowsSuspendedReplay: true,
            deadline: request.deadline
        )
        if let acceptedProposal = commit.acceptedProposal,
            var expected = foregroundRequestProposals[request.id],
            expected.itemID == item.itemID,
            expected.epoch == epoch,
            acceptedProposal.generation == generation {
            expected.proposal = acceptedProposal
            foregroundRequestProposals[request.id] = expected
        }
        return commit
    }

    // The derived proposal becomes `pending` before its physical Spotlight
    // write. If the request deadline wins while that provider call is still
    // suspended, hide the proposal from hot lexical search immediately. The
    // pending publication stays intact until its tracked waiter leaves; a
    // later request sharing the same write may still promote it successfully,
    // while the last rejected waiter removes and quarantines it.
    private func abandonTimedOutForegroundImageCommit(
        itemID: UUID,
        generation: Int64,
        epoch: UInt64
    ) {
        guard extractionEpochs[itemID, default: 0] == epoch,
            latestRequested[itemID] == generation,
            var pending = pending[itemID],
            pending.index.generation == generation,
            pending.repairProposal?.generation == generation else {
            return
        }
        freshnessLedger.invalidate(itemIDs: [itemID])
        pending.isSearchSuppressed = true
        self.pending[itemID] = pending
        rebuildLibraryLexicalIndex()
    }

    private func scheduleImageEnrichment(
        snapshot: CanvasCoreSnapshot,
        item: AssistantIndexedItem,
        baseUnits: [Unit],
        generation: Int64,
        epoch: UInt64,
        snapshotHydrationLease: NotebookSnapshotHydrationLease? = nil
    ) async {
        guard isBackgroundMaintenanceSuspended == false else {
            guard await deferImageEnrichment(
                generation: generation,
                item: item
            ) else { return }
            return
        }
        _ = cancelImageEnrichment(for: item.itemID)
        // Persist restartability off the actor before the expensive task is
        // launched. This never touches the note's authoritative snapshot.
        // This tiny write stays on the index actor so two verified generations
        // cannot race and regress the restart breadcrumb.
        guard await deferImageEnrichment(
            generation: generation,
            item: item
        ) else { return }
        guard !Task.isCancelled,
            isBackgroundMaintenanceSuspended == false,
            registered[item.itemID] == item,
            extractionEpochs[item.itemID, default: 0] == epoch,
            latestRequested[item.itemID] == generation else { return }
        let activeSnapshotHydrationLease: NotebookSnapshotHydrationLease
        if let snapshotHydrationLease = snapshotHydrationLease {
            activeSnapshotHydrationLease = snapshotHydrationLease
        } else {
            guard let acquired = await NotebookSnapshotHydrationArbiter.shared
                .tryAcquire(itemID: item.itemID) else {
                // The durable breadcrumb written above guarantees a later
                // repair. Do not queue another snapshot behind a worker that
                // may acknowledge cancellation late.
                return
            }
            activeSnapshotHydrationLease = acquired
        }
        let predecessor = imageEnrichmentTails[item.itemID]?.drain
        let taskID = UUID()
        let analyzer = imageAnalyzer
        let delay = imageEnrichmentDelay
        let task = Task.detached(priority: .background) {
            [weak self, activeSnapshotHydrationLease] in
            // A snapshot reopened for assistant hydration can contain hundreds
            // of MiB of valid PaperKit/imported-page state. Keep its shared
            // process permit until this detached worker releases the captured
            // snapshot, including while it waits for a cancellation-resistant
            // predecessor or framework callback.
            defer { withExtendedLifetime(activeSnapshotHydrationLease) {} }
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            await predecessor?.value
            guard !Task.isCancelled else { return }
            guard let result = await AssistantImageEnrichmentWorker.enrich(
                snapshot: snapshot,
                item: item,
                analyzer: analyzer,
                snapshotHydrationLease: activeSnapshotHydrationLease
            ) else { return }
            guard !Task.isCancelled else { return }
            let committed = await self?.replaceImageEnrichment(
                records: result.records,
                baseUnits: baseUnits,
                generation: generation,
                itemID: item.itemID,
                epoch: epoch
            ) ?? .rejected
            if result.hasCompleteDurableCache,
                committed.acceptedLocally,
                committed.durablyPublished {
                AssistantImageEnrichmentStore.clearPending(
                    generation: generation,
                    for: item
                )
            }
        }
        // The actor-isolated watcher cannot run its final removal until this
        // method yields, so registration always precedes completion even when
        // a zero-delay detached worker finishes immediately.
        let drain = Task { [weak self] in
            await task.value
            await self?.finishImageEnrichment(
                itemID: item.itemID,
                taskID: taskID
            )
        }
        registerImageEnrichmentTask(
            itemID: item.itemID,
            taskID: taskID,
            generation: generation,
            cancel: { task.cancel() },
            drain: drain
        )
        imageEnrichmentTails[item.itemID] = ImageEnrichmentTail(
            taskID: taskID,
            drain: drain
        )
    }

    @discardableResult
    private func deferImageEnrichment(
        generation: Int64,
        item: AssistantIndexedItem,
        deadline: ContinuousClock.Instant? = nil,
        expectedEpoch: UInt64? = nil
    ) async -> Bool {
        let generation = max(generation, 0)
    let epoch = expectedEpoch
        ?? extractionEpochs[item.itemID, default: 0]
    guard !Task.isCancelled,
        recoveryImageFencedItemIDs.contains(item.itemID) == false,
        deadline.map({ ContinuousClock().now < $0 }) ?? true else {
        return false
    }
    // The store owns a process-wide mutation lock and generation-max
    // fencing. Keep its file I/O off the index actor so a protected or
    // contended filesystem can never pin an interactive deadline.
#if DEBUG
    let breadcrumbHook = beforeImageBreadcrumbWriteForTesting
#endif
    let markerTask = Task.detached(priority: .utility) {
#if DEBUG
        await breadcrumbHook?()
#endif
        return AssistantImageEnrichmentStore.markPending(
            generation: generation,
            for: item
        )
    }
    let markerTaskID = UUID()
    let markerDrain = Task { [weak self] in
        _ = await markerTask.value
        await self?.finishImageEnrichment(
            itemID: item.itemID,
            taskID: markerTaskID
        )
    }
    registerImageEnrichmentTask(
        itemID: item.itemID,
        taskID: markerTaskID,
        generation: generation,
        cancel: { markerTask.cancel() },
        drain: markerDrain
    )
    let stored = await markerTask.value
    guard !Task.isCancelled,
        deadline.map({ ContinuousClock().now < $0 }) ?? true,
        registered[item.itemID] == item,
        extractionEpochs[item.itemID, default: 0] == epoch,
        latestRequested[item.itemID] == generation else {
        return false
        }
        if stored {
            if imageEnrichmentRetryGenerations[item.itemID]
                .map({ $0 <= generation }) == true {
                imageEnrichmentRetryGenerations.removeValue(forKey: item.itemID)
            }
        } else {
            imageEnrichmentRetryGenerations[item.itemID] = max(
        imageEnrichmentRetryGenerations[item.itemID, default: 0],
        generation
    )
}
return stored
}

@discardableResult
private func cancelImageEnrichment(
    for itemID: UUID,
    beforeGeneration: Int64? = nil
) -> Task<Void, Never>? {
    guard let registeredEntries = imageEnrichmentTasks[itemID] else {
        return nil
    }
    let entries = registeredEntries.filter { _, entry in
        beforeGeneration.map { entry.generation < $0 } ?? true
    }
    guard entries.isEmpty == false else { return nil }
    for entry in entries.values { entry.cancel() }
    return Task {
        for entry in entries.values { await entry.drain.value }
    }
}

private func finishImageEnrichment(itemID: UUID, taskID: UUID) {
    if imageEnrichmentTails[itemID]?.taskID == taskID {
        imageEnrichmentTails.removeValue(forKey: itemID)
    }
    guard imageEnrichmentTasks[itemID]?.removeValue(forKey: taskID) != nil else {
        return
    }
    if imageEnrichmentTasks[itemID]?.isEmpty == true {
        imageEnrichmentTasks.removeValue(forKey: itemID)
    guard isBackgroundMaintenanceSuspended == false,
        suspensionRetainedImageItemIDs.remove(itemID) != nil,
        let item = registered[itemID],
        retainedImageDrainRetryItemIDs.insert(itemID).inserted else {
        return
    }
    // The orchestration handle can finish before a cancellation-
    // resistant renderer/provider and its snapshot lease physically
    // drain. Wait for both retained resources before re-checking the
    // durable breadcrumb; otherwise the retry races its predecessor's
    // per-item reservations and can be stranded until another launch.
    Task { [weak self] in
        await AssistantImageReworkArbiter.shared.waitUntilReleased(
            itemID: itemID
        )
        await NotebookSnapshotHydrationArbiter.shared.waitUntilReleased(
            itemID: itemID
        )
        await self?.retryRetainedImageEnrichmentAfterDrain(item)
    }
}
}

private func retryRetainedImageEnrichmentAfterDrain(
    _ item: AssistantIndexedItem
) async {
    guard retainedImageDrainRetryItemIDs.remove(item.itemID) != nil,
        registered[item.itemID] == item else { return }
    await repairPendingImageEnrichmentIfNeeded(item)
}

private func registerImageEnrichmentTask(
    itemID: UUID,
    taskID: UUID,
    generation: Int64,
    retriesAfterSuspension: Bool = true,
    cancel: @escaping @Sendable () -> Void,
    drain: Task<Void, Never>
) {
    imageEnrichmentTasks[itemID, default: [:]][taskID] =
        ImageEnrichmentTaskRegistration(
            generation: generation,
            retriesAfterSuspension: retriesAfterSuspension,
            cancel: cancel,
            drain: drain
        )
}

#if DEBUG
func waitForImageEnrichmentForTesting(itemID: UUID) async {
    let drains = imageEnrichmentTasks[itemID]?.values.map(\.drain) ?? []
    for drain in drains { await drain.value }
    await AssistantImageRawWorkArbiter.shared.waitUntilReleased(
        itemID: itemID
    )
    await NotebookSnapshotHydrationArbiter.shared
        .waitUntilReleased(itemID: itemID)
}

func waitForRecoveryImageCleanupForTesting(itemID: UUID) async {
    await recoveryImageCleanups[itemID]?.drain.value
}

func publicationWaiterCountForTesting(itemID: UUID) -> Int {
    publicationWaiters[itemID]?.ids.count ?? 0
}

func isPendingPublicationSearchSuppressedForTesting(itemID: UUID) -> Bool {
    pending[itemID]?.isSearchSuppressed == true
}

func hasPendingPublicationForTesting(itemID: UUID) -> Bool {
    pending[itemID] != nil
}

var foregroundRequestProposalCountForTesting: Int {
    foregroundRequestProposals.count
}

func enqueueFailedSpotlightDeletionForTesting(itemID: UUID) async {
    publishedManifests.removeValue(forKey: itemID)
    failedPublications.removeValue(forKey: itemID)
    failedDeletions.insert(itemID)
    await retryFailedSpotlightMutations()
}

func evictCachedIndexForTesting(itemID: UUID) {
    removeCachedIndex(itemID)
}

func setBeforeDurableImageEnrichmentLoadForTesting(
    _ hook: (@Sendable () async -> Void)?
) {
    beforeDurableImageEnrichmentLoadForTesting = hook
}

func setBeforeColdImageBreadcrumbAcknowledgementForTesting(
    _ hook: (@Sendable () async -> Void)?
) {
    beforeColdImageBreadcrumbAcknowledgementForTesting = hook
}

func coldHydrationInFlightForTesting(itemID: UUID) async -> Bool {
    await coldHydrationLane.isOccupied(itemID: itemID)
}

func setBeforeColdCanvasLoadForTesting(
    _ hook: (@Sendable () async -> Void)?
) {
    beforeColdCanvasLoadForTesting = hook
}

func catalogCertifiedGenerationForTesting(itemID: UUID) -> Int64? {
    catalogCertifiedGenerations[itemID]
}

func publishedManifestGenerationForTesting(itemID: UUID) -> Int64? {
    publishedManifests[itemID]?.generation
}

func interactiveSpotlightReadInFlightForTesting() async -> Bool {
    await spotlightInteractiveReadLane.isOccupiedForTesting()
}

func hydratePublishedManifestForTesting(
    itemID: UUID,
    until deadline: ContinuousClock.Instant
) async {
    await hydratePublishedManifestIfNeeded(
        for: itemID,
        deadline: deadline
    )
}

func setBeforeSpotlightPublicationForTesting(
    _ hook: (@Sendable () async -> Void)?
) {
    beforeSpotlightPublicationForTesting = hook
}

func setBeforeRegistrationSemanticMutationForTesting(
    _ hook: (@Sendable () -> Void)?
) {
    beforeRegistrationSemanticMutationForTesting = hook
}

func setBeforeForegroundCatalogFingerprintForTesting(
    _ hook: (@Sendable () async -> Void)?
) {
    beforeForegroundCatalogFingerprintForTesting = hook
}

func setBeforeForegroundAuthoredBuildForTesting(
    _ hook: (@Sendable () async -> Void)?
) {
    beforeForegroundAuthoredBuildForTesting = hook
}

func setBeforeForegroundIndexRegistrationForTesting(
    _ hook: (@Sendable () async -> Void)?
) {
    beforeForegroundIndexRegistrationForTesting = hook
}

func setBeforeImageWorkEligibilityForTesting(
    _ hook: (@Sendable () async -> Void)?
) {
    beforeImageWorkEligibilityForTesting = hook
}

func setBeforeImageBreadcrumbWriteForTesting(
    _ hook: (@Sendable () async -> Void)?
) {
    beforeImageBreadcrumbWriteForTesting = hook
}

func setBeforeLibraryLexicalBuildForTesting(
    _ hook: (@Sendable () async -> Void)?
) {
    beforeLibraryLexicalBuildForTesting = hook
}

func waitForLibraryLexicalRebuildForTesting() async {
    while let rebuild = pendingLibraryLexicalRebuild {
        let built = await rebuild.task.value
        finishLibraryLexicalRebuild(built, revision: rebuild.revision)
    }
}

func setDeferredCatalogExpirationAfterItemsForTesting(_ limit: Int?) {
    catalogLexicalIndex.setDeferredExpirationItemLimitForTesting(limit)
}

/// A read-only view used by scale tests to prove an interactive Library
/// request did not open registered notes and rotate new documents into the
/// bounded hot cache.
var cachedItemIDsForTesting: Set<UUID> {
    Set(indexes.keys).union(pending.keys)
}

var recentSpotlightUnitIDsForTesting: Set<String> {
    Set(recentSpotlightUnits.keys)
}
#endif

/// Equal-generation replay is accepted only when the complete chunk
/// fingerprint is identical; conflicting or older replacements are rejected.
@discardableResult
public func replace(
    units: [Unit],
    generation: Int64,
    itemID: UUID
) async -> Bool {
    let generation = max(generation, 0)
    let expectedRegistration = registered[itemID]
    let expectedEpoch = extractionEpochs[itemID, default: 0]
    if let expectedRegistration,
        generation < expectedRegistration.expectedGeneration { return false }
    guard let chunks = Self.expand(
        units,
        for: itemID,
        generation: generation
    ) else { return false }
    guard let proposal = makeItemIndex(
        generation: generation,
        units: chunks,
        registrationFingerprint: expectedRegistration.map(Self.registrationFingerprint)
    ) else { return false }
    return await replace(
        proposal: proposal,
        itemID: itemID,
        expectedRegistration: expectedRegistration,
        expectedEpoch: expectedEpoch
    )
}

private func makeItemIndex(
    generation: Int64,
    units: [Unit],
    registrationFingerprint: String?
) -> ItemIndex? {
    guard let index = ItemIndex(
        generation: generation,
        units: units,
        registrationFingerprint: registrationFingerprint
    ) else { return nil }
#if DEBUG
    itemIndexConstructionCountForTesting += 1
#endif
    return index
}

/// Commits an already-expanded exact proposal. Verified snapshot indexing
/// prepares this value before entering the replacement state machine so it
/// does not repeat chunking, hashing, or lexical-posting construction.
private func replace(
    proposal: ItemIndex,
    itemID: UUID,
    expectedRegistration: AssistantIndexedItem?,
    expectedEpoch: UInt64
) async -> Bool {
    let generation = proposal.generation
    let effective = pending[itemID]?.index.manifest
        ?? indexes[itemID]?.manifest
        ?? manifests[itemID]
    var proposalIsAlreadyVisibleLocally = false
    if let effective {
        if generation < effective.generation { return false }
        if generation == effective.generation {
            guard proposal.fingerprint == effective.fingerprint else { return false }
            proposalIsAlreadyVisibleLocally = true
            if let pending = pending[itemID] {
                let waiterID = beginPublicationWait(
                    itemID: itemID,
                    spotlightMutationRevision: pending.spotlightMutationRevision
                )
                let report = await pending.task.value
                _ = endPublicationWait(
                    itemID: itemID,
                    waiterID: waiterID,
                    spotlightMutationRevision: pending.spotlightMutationRevision,
                    removePendingWhenEmpty: false
                )
                guard registered[itemID] == expectedRegistration,
                    extractionEpochs[itemID, default: 0] == expectedEpoch else {
                    reconcileCompletedPublicationAfterRegistrationChange(
                        itemID: itemID,
                        proposal: proposal,
                        publicationSucceeded: report.succeeded,
                        spotlightMutationRevision:
                            pending.spotlightMutationRevision,
                        expectedEpoch: expectedEpoch
                    )
                    return false
                }
                finalize(
                    itemID: itemID,
                    proposal: proposal,
                    publicationSucceeded: report.succeeded,
                    spotlightMutationRevision: pending.spotlightMutationRevision,
                    expectedEpoch: expectedEpoch
                )
            }
            if manifests[itemID] == proposal.manifest {
                if indexes[itemID] == nil {
                    // A manifest can outlive its bounded hot-cache entry. Once
                    // an exact replay (including durable OCR) proves the same
                    // fingerprint, restore that proposal to memory so content
                    // snapshots and local retrieval are immediately usable.
                    cacheIndex(proposal, itemID: itemID)
                }
                return true
            }
            // A focused cold-read can hydrate an exact bounded fallback
            // before the verified-save publisher runs. The content is
            // already visible locally, but it still needs the ordinary
            // manifest/publication transition below.
        }
    }
    guard registered[itemID] == expectedRegistration,
        extractionEpochs[itemID, default: 0] == expectedEpoch,
        generation >= latestRequested[itemID, default: 0] else { return false }
    latestRequested[itemID] = generation
    if proposalIsAlreadyVisibleLocally == false {
        invalidateAuthoredContent(itemIDs: [itemID])
    }
    let publication = publicationTask(itemID: itemID, proposal: proposal)
    let task = publication.task
    let proposalWasAlreadyCached = indexes[itemID]?.manifest == proposal.manifest
    if proposalWasAlreadyCached == false {
        // `pending` already makes this proposal visible to local search, so
        // enforce the same bounded-cache eviction policy before publishing
        // that view. Finalization can then promote the manifest without
        // rebuilding an identical lexical index a second time.
        cacheIndex(proposal, itemID: itemID, rebuildLibraryIndex: false)
    }
    pending[itemID] = Pending(
        index: proposal,
        task: task,
        spotlightMutationRevision: publication.revision,
        repairProposal: nil
    )
    let waiterID = beginPublicationWait(
        itemID: itemID,
        spotlightMutationRevision: publication.revision
    )
    rebuildLibraryLexicalIndex()
    let report = await task.value
    _ = endPublicationWait(
        itemID: itemID,
        waiterID: waiterID,
        spotlightMutationRevision: publication.revision,
        removePendingWhenEmpty: false
    )
    guard registered[itemID] == expectedRegistration,
        extractionEpochs[itemID, default: 0] == expectedEpoch else {
        reconcileCompletedPublicationAfterRegistrationChange(
            itemID: itemID,
            proposal: proposal,
            publicationSucceeded: report.succeeded,
            spotlightMutationRevision: publication.revision,
            expectedEpoch: expectedEpoch
        )
        return false
    }
        finalize(
            itemID: itemID,
            proposal: proposal,
            publicationSucceeded: report.succeeded,
            spotlightMutationRevision: publication.revision,
            expectedEpoch: expectedEpoch
        )
        return manifests[itemID]?.fingerprint == proposal.fingerprint
    }

    public func search(
        query: String,
        scope: AssistantScope = .item,
        items: [AssistantIndexedItem] = [],
        itemID: UUID? = nil,
        pageID: UUID? = nil,
        limit: Int = 8
    ) async -> [AssistantSearchResult] {
        let clock = ContinuousClock()
        let queryDeadline = clock.now.advanced(by: spotlightSearchTimeout)
        guard let preflight = Self.searchPreflight(
            query: query,
            limit: limit
        ) else { return [] }
        register(items)
        // Only a Library query requires the full catalog. Focused page/item
        // routes retain their zero-hop hot-index path and never pay a
        // whole-library bootstrap merely because a user began typing.
        guard Task.isCancelled == false,
            clock.now < queryDeadline else { return [] }
        return await searchBounded(
            query: query,
            scope: scope,
            items: [],
            itemID: itemID,
            pageID: pageID,
            limit: preflight.limit,
            spotlightDeadline: queryDeadline,
            preflight: preflight
        )
    }

    private func searchBounded(
        query: String,
        scope: AssistantScope,
        items: [AssistantIndexedItem],
        itemID: UUID?,
        pageID: UUID?,
        limit: Int,
        spotlightDeadline: ContinuousClock.Instant,
        preflight: SearchPreflight? = nil
    ) async -> [AssistantSearchResult] {
        register(items)
        guard let preflight = preflight ?? Self.searchPreflight(
            query: query,
            limit: limit
        ) else { return [] }
        let limit = preflight.limit
        let terms = preflight.terms

#if DEBUG
    lexicalUnitInspectionsForTesting = 0
    libraryLexicalCandidateCountForTesting = 0
    catalogLexicalCandidateCountForTesting = 0
    libraryRegisteredItemEnumerationsForTesting = 0
#endif

    // Library search routes through prebuilt catalog/hot-chunk indexes and
    // optionally Core Spotlight. It intentionally does not materialize the
    // registered ID set or open every note on the interactive path.
    let candidateIDs = scope == .library
        ? Set<UUID>()
        : Set(candidates(scope: scope, focused: itemID))
    let focusedHydrationDeadline = spotlightDeadline.advanced(
        by: .zero - Self.focusedHydrationFallbackReserve
    )
    var lexicalResults: [AssistantSearchResult] = []
    // The verified hot index is the zero-hop path for the open page or
    // notebook. Exact and prefix matches should not wait for Core
    // Spotlight's query service, which can be briefly cold after unlock.
    if scope != .library {
        // The focused document is authoritative and bounded. Hydrate it
        // once from its verified store even when Spotlight is available.
        // Every cold stage shares an earlier cutoff, preserving time for
        // catalog/Spotlight fallback when Canvas or extraction stalls.
        for id in candidateIDs where pending[id] == nil {
            guard !Task.isCancelled,
                ContinuousClock().now < focusedHydrationDeadline else {
                break
            }
            if let item = registered[id] {
                let visibleGeneration = visibleLocalIndex(for: id)?.generation
                if visibleGeneration.map({
                    $0 < item.expectedGeneration
                }) ?? true {
                    await cacheVerifiedSnapshotForLexicalFallback(
                        item,
                        deadline: focusedHydrationDeadline
                    )
                }
            }
        }
    }
    let phrase = terms.joined(separator: " ")
    var inspected = 0
    let perItemCandidateLimit = max(64, min(512, limit * 16))
    if scope == .library {
        var hotResults: [AssistantSearchResult] = []
        let installedUnitIndices = libraryLexicalIndex.lexical.candidateIndices(
            matching: terms,
            pageID: nil,
            units: libraryLexicalIndex.units,
            maximumCount: Self.maximumLibraryCandidatesPerTier
        )
        let installedUnits = installedUnitIndices
            .map { libraryLexicalIndex.units[$0] }
            .filter(isCurrentLocalUnit)
        let candidateUnits: [Unit]
        if pendingLibraryLexicalRebuild != nil {
            // A detached rebuild must never turn the previous installed
            // generation into a query barrier. Overlay the bounded current
            // per-item postings and interleave both sources into one fixed
            // candidate budget; stale installed units were removed above.
            let overlayUnits = currentLibraryOverlayCandidateUnits(
                matching: terms,
                maximumCount: Self.maximumLibraryCandidatesPerTier
            )
            candidateUnits = Self.interleavedUniqueUnits(
                sources: [overlayUnits, installedUnits],
                maximumCount: Self.maximumLibraryCandidatesPerTier
            )
        } else {
            candidateUnits = installedUnits
        }
#if DEBUG
        libraryLexicalCandidateCountForTesting = candidateUnits.count
#endif
        for unit in candidateUnits {
            inspected += 1
#if DEBUG
            lexicalUnitInspectionsForTesting += 1
#endif
            if inspected.isMultiple(of: 64), Task.isCancelled { return [] }
            guard isCurrentLocalUnit(unit),
                Self.includes(unit, scope: scope, pageID: pageID),
                let score = SearchText.score(
                    unit.text,
                    itemName: currentName(unit),
                    terms: terms,
                    phrase: phrase
                ) else { continue }
            hotResults.append(result(unit, terms: terms, score: score))
        }

        let catalogUnits = catalogLexicalIndex.candidates(
            matching: terms,
            maximumCount: Self.maximumLibraryCandidatesPerTier,
            deadline: spotlightDeadline
        )
#if DEBUG
        catalogLexicalCandidateCountForTesting = catalogUnits.count
#endif
        let hotItemIDs = Set(hotResults.map(\.anchor.itemID))
        var catalogResults: [AssistantSearchResult] = []
        for unit in catalogUnits {
            inspected += 1
#if DEBUG
            lexicalUnitInspectionsForTesting += 1
#endif
            if inspected.isMultiple(of: 64), Task.isCancelled { return [] }
            guard hotItemIDs.contains(unit.itemID) == false,
                isCurrentLocalUnit(unit),
                let score = SearchText.score(
                    unit.text,
                    itemName: currentName(unit),
                    terms: terms,
                    phrase: phrase
                ) else { continue }
            catalogResults.append(result(
                unit,
                terms: terms,
                score: score,
                catalogAuthority: true
            ))
        }
        lexicalResults = hotResults + catalogResults
    } else {
        for id in candidateIDs {
            guard let index = visibleLocalIndex(for: id) else { continue }
            if indexes[id] != nil { touchIndex(id) }
            let unitIndices = index.lexical.candidateIndices(
                matching: terms,
                pageID: scope == .page ? pageID : nil,
                units: index.units,
                maximumCount: perItemCandidateLimit
            )
            for unitIndex in unitIndices {
                let unit = index.units[unitIndex]
                inspected += 1
#if DEBUG
                lexicalUnitInspectionsForTesting += 1
#endif
                if inspected.isMultiple(of: 64), Task.isCancelled { return [] }
                guard isCurrentLocalUnit(unit),
                    Self.includes(unit, scope: scope, pageID: pageID),
                    let score = SearchText.score(
                        unit.text,
                        itemName: currentName(unit),
                        terms: terms,
                        phrase: phrase
                    ) else { continue }
                lexicalResults.append(result(unit, terms: terms, score: score))
            }
        }
        if scope == .item,
            lexicalResults.isEmpty,
            !Task.isCancelled,
            ContinuousClock().now < spotlightDeadline,
            let focusedID = candidateIDs.count == 1 ? candidateIDs.first : nil,
            pending[focusedID] == nil,
            indexes[focusedID] == nil,
            let item = registered[focusedID],
            item.requiresVerifiedRecovery == false {
            // A focused route must never bootstrap the deferred whole-
            // Library SQLite catalog. Search only this registration's
            // stable, chunked catalog projection so a bounded Canvas
            // timeout can still fall back to repository text without
            // materializing any other note. A durable recovery marker
            // suppresses every such derived unit until Canvas has
            // verified the recovered checkpoint. Once a verified page
            // index is resident, it stays authoritative and a real
            // no-match does not revive the derived projection.
            let focusedCatalogUnits = catalogLexicalIndex.focusedCandidates(
                matching: terms,
                maximumCount: min(2, perItemCandidateLimit),
                itemID: focusedID,
                currentDeferredItem: deferredCatalogRegistrations[focusedID],
                deadline: spotlightDeadline
            )
            let routingUnits = focusedCatalogUnits.isEmpty
                ? Self.fallback(
                    item,
                    item.expectedGeneration,
                    includesDerivedText: false
                )
                : focusedCatalogUnits
        for unit in routingUnits {
            guard !Task.isCancelled,
                ContinuousClock().now < spotlightDeadline,
                unit.itemID == focusedID,
                unit.itemName == item.itemName,
                effectiveCatalogGeneration(for: unit)
                    >= item.expectedGeneration else { continue }
            guard let score = SearchText.score(
                unit.text,
                itemName: item.itemName,
                terms: terms,
                phrase: phrase
            ) else { continue }
            lexicalResults.append(result(
                unit,
                terms: terms,
                score: score
            ))
        }
        }
    }

    if interactiveSpotlight != nil, scope != .library, lexicalResults.isEmpty == false {
        lexicalResults.sort(by: Self.ranksBefore)
        let ranked = Self.deduplicatedCandidates(
            Self.rankedUnique(lexicalResults)
        )
        return Self.diversify(ranked, scope: scope, limit: limit)
    }

    var semanticResults: [AssistantSearchResult] = []
    if let interactiveSpotlight {
        // Core Spotlight is the persistent semantic tier for library-wide
        // retrieval and for local queries without an exact hot-cache hit.
        // It never waits behind background publication or repair work.
        let response = await boundedInteractiveSpotlightValue(
            until: spotlightDeadline
        ) {
            await interactiveSpotlight.search(
                query: query,
                maximumResultCount: scope == .library
                    ? Self.maximumLibraryCandidatesPerTier
                    : min(max(limit * 12, 64), 300),
                itemID: scope == .library
                    ? nil
                    : (candidateIDs.count == 1 ? candidateIDs.first : nil),
                pageID: scope == .page ? pageID : nil
            )
    }
    if let response, response.succeeded {
        var seen = Set<String>()
        var hydratedItems = Set<UUID>()
        for (rank, hit) in response.units.enumerated() {
            guard !Task.isCancelled,
                ContinuousClock().now < spotlightDeadline else { break }
            if publishedManifests[hit.itemID] == nil,
                hydratedItems.insert(hit.itemID).inserted {
                await hydratePublishedManifestIfNeeded(
                    for: hit.itemID,
                    deadline: spotlightDeadline
                )
            }
            let belongsToScope = scope == .library
                ? registered[hit.itemID] != nil
                : candidateIDs.contains(hit.itemID)
            guard belongsToScope,
                Self.includes(hit, scope: scope, pageID: pageID),
                isCurrentSpotlightUnit(hit),
                seen.insert(hit.id).inserted else { continue }
            rememberSpotlightUnit(hit)
            semanticResults.append(
                result(hit, terms: terms, score: -Double(rank))
            )
        }
    } else if response != nil,
        let itemID,
        pending[itemID] == nil,
        indexes[itemID] == nil,
            let item = registered[itemID] {
            // A query-service failure hydrates only the focused verified
            // store. It never turns an interactive request into a full
            // synchronous library scan.
            await cacheVerifiedSnapshotForLexicalFallback(
                item,
                deadline: focusedHydrationDeadline
            )
            if let index = indexes[itemID] {
                let unitIndices = index.lexical.candidateIndices(
                    matching: terms,
                    pageID: scope == .page ? pageID : nil,
                    units: index.units,
                    maximumCount: perItemCandidateLimit
                )
                for unitIndex in unitIndices {
                    let unit = index.units[unitIndex]
                    guard isCurrentLocalUnit(unit),
                        Self.includes(unit, scope: scope, pageID: pageID),
                        let score = SearchText.score(
                            unit.text,
                            itemName: currentName(unit),
                            terms: terms,
                            phrase: phrase
                        ) else { continue }
                    lexicalResults.append(result(unit, terms: terms, score: score))
                }
            }
        }
    }
    if scope == .library, semanticResults.isEmpty == false {
        let detailedItemIDs = Set(semanticResults.map(\.anchor.itemID))
        lexicalResults.removeAll { result in
            detailedItemIDs.contains(result.anchor.itemID)
                && catalogLexicalIndex.contains(id: result.id)
        }
    }
    lexicalResults.sort(by: Self.ranksBefore)
    let uniqueLexical = Self.rankedUnique(lexicalResults)
    let lexicalRanked = scope == .library
        ? Array(uniqueLexical.prefix(Self.maximumLibraryCandidatesPerTier))
        : uniqueLexical
    let ranked = semanticResults.isEmpty
        ? lexicalRanked
        : Self.fuseRankedResults(
            lexical: lexicalRanked,
            semantic: semanticResults
        )
    let deduplicated = Self.deduplicatedCandidates(ranked)
    return Self.diversify(deduplicated, scope: scope, limit: limit)
    }

    private func boundedInteractiveSpotlightValue<Value: Sendable>(
        until deadline: ContinuousClock.Instant,
        operation: @escaping @Sendable () async -> Value
    ) async -> Value? {
        let clock = ContinuousClock()
        guard !Task.isCancelled,
            clock.now < deadline,
            await spotlightInteractiveReadLane.tryAcquire() else {
            return nil
        }
        let lane = spotlightInteractiveReadLane
    let rawTask = Task.detached(priority: .userInitiated) {
        await operation()
    }
    let outcome = await assistantImageTaskOutcome(
        of: rawTask,
        until: deadline
    )
    switch outcome {
    case let .value(value):
        await lane.release()
        // Executor contention can resume this actor after the absolute
        // cutoff even when the raw value narrowly won the race. Never let
        // such a value hydrate actor-visible authority after its deadline.
        guard !Task.isCancelled, clock.now < deadline else { return nil }
        return value
    case .cancelled, .timedOut:
        Task {
            _ = await rawTask.value
            await lane.release()
        }
        return nil
    }
}

/// Returns a prompt-sized, generation-verified evidence set for a
/// Library Find, Answer, and Explain. This contract is always capped at
/// five passages, three notebooks, and two passages from one page.
public func boundedLibraryEvidence(query: String) async -> AssistantLibraryEvidence {
    let clock = ContinuousClock()
    let overallDeadline = clock.now.advanced(by: libraryRetrievalTimeout)
    let requestedLimit = Self.maximumLibraryCandidatesPerTier * 2
    guard let preflight = Self.searchPreflight(
        query: query,
        limit: requestedLimit
    ) else {
        return AssistantLibraryEvidence(passages: [])
    }
    guard Task.isCancelled == false,
          clock.now < overallDeadline else {
        return AssistantLibraryEvidence(passages: [])
    }
    let searchDeadline = min(
        overallDeadline,
        clock.now.advanced(by: spotlightSearchTimeout)
    )
    let candidates = await searchBounded(
        query: query,
        scope: .library,
        items: [],
        itemID: nil,
        pageID: nil,
        limit: preflight.limit,
        spotlightDeadline: searchDeadline,
        preflight: preflight
    )
    let selected = Self.selectLibraryEvidence(from: candidates)
    // Search tiers return locators, never prompt authority. Re-read the
    // bounded selection through the current generation/manifest checks so
    // an edit between ranking and prompt construction cannot contribute
    // stale text. This touches at most five IDs and never scans the catalog.
    let currentPassages = await readBounded(
        anchorIDs: selected.map(\.id),
        spotlightDeadline: overallDeadline
    )
    let currentByID = Dictionary(
        currentPassages.map { ($0.id, $0) },
        uniquingKeysWith: { current, _ in current }
    )
    let rehydrated = selected.compactMap { ranked -> AssistantSearchResult? in
        guard let current = currentByID[ranked.id] else { return nil }
        return AssistantSearchResult(
            anchor: current.anchor,
            fullText: current.fullText,
            score: ranked.score
        )
    }
    return AssistantLibraryEvidence(
        passages: rehydrated
    )
}

    /// Returns representative verified content for a focused item or page
    /// without requiring lexical query terms. This is the fallback for broad
    /// requests such as "describe this note," where query words need not occur
    /// in the note itself.
    public func context(
        scope: AssistantScope = .item,
        itemID: UUID? = nil,
        pageID: UUID? = nil,
        limit: Int = 8,
        deadline: ContinuousClock.Instant? = nil
    ) async -> [AssistantSearchResult] {
        guard scope != .library else { return [] }
        let limit = min(max(limit, 0), 50)
        guard limit > 0 else { return [] }
        let clock = ContinuousClock()
        let hydrationDeadline = deadline ?? clock.now.advanced(
            by: spotlightSearchTimeout
        )

        let candidateIDs = candidates(scope: scope, focused: itemID)
        guard !candidateIDs.isEmpty else { return [] }
        var units: [Unit] = []
        for id in candidateIDs {
            guard !Task.isCancelled, clock.now < hydrationDeadline else {
                return []
            }
            guard let item = registered[id] else { continue }
            let current = visibleLocalIndex(for: id)
            if current.map({ $0.generation < item.expectedGeneration }) ?? true {
                await cacheVerifiedSnapshotForLexicalFallback(
                    item,
                    deadline: hydrationDeadline
                )
            }
            guard !Task.isCancelled, clock.now < hydrationDeadline else {
                return []
            }
            guard let index = visibleLocalIndex(for: id),
                index.generation >= item.expectedGeneration else { continue }
            if indexes[id] != nil { touchIndex(id) }
            units.append(contentsOf: index.units.filter {
                Self.includes($0, scope: scope, pageID: pageID)
            })
        }

        let substantive = units.filter { $0.kind != .metadata }
        let available = substantive.isEmpty ? units : substantive
        // Item indexes already store content in document order. Preserve that
        // order here; sorting note blocks by their UUID would make a broad
        // description depend on random identifier order instead of the note.
        let ordered = available

        struct Locator: Hashable {
            let itemID: UUID
            let pageID: UUID?
            let blockID: UUID?
            let kind: AssistantSourceKind
            let chunkOrdinal: Int
        }
        var representatives: [Unit] = []
        var locators = Set<Locator>()
        for unit in ordered {
            let locator = Locator(
                itemID: unit.itemID,
                pageID: unit.pageID,
                blockID: unit.blockID,
                kind: unit.kind,
                chunkOrdinal: unit.chunkOrdinal
            )
            guard locators.insert(locator).inserted else { continue }
            representatives.append(unit)
        }

        // A broad request should see the shape of the whole document, not
        // only its first few paragraphs. Sample representative blocks evenly
        // when the focused document contains more locators than the budget.
        var selected: [Unit]
        if representatives.count <= limit {
            selected = representatives
        } else if limit == 1 {
            selected = [representatives[0]]
        } else {
            selected = (0..<limit).map { position in
                let index = position * (representatives.count - 1) / (limit - 1)
                return representatives[index]
            }
        }
        var selectedIDs = Set(selected.map(\.id))
        if selected.count < limit {
            for unit in ordered where selectedIDs.insert(unit.id).inserted {
                selected.append(unit)
                if selected.count == limit { break }
            }
        }
        return selected.map { result($0, terms: [], score: 0) }
    }

        /// Returns all verified content for the focused item/page. This is kept
        /// separate from `context`, whose deliberately bounded result is suitable
        /// for interactive Q&A but cannot represent an entire document.
        public func contentSnapshot(
            itemID: UUID,
            pageID: UUID? = nil,
            deadline: ContinuousClock.Instant? = nil
        ) async -> ContentSnapshot? {
            guard let item = registered[itemID] else { return nil }
            let clock = ContinuousClock()
            let hydrationDeadline = deadline ?? clock.now.advanced(
                by: spotlightSearchTimeout
            )
            let current = visibleLocalIndex(for: itemID)
            if current.map({ $0.generation < item.expectedGeneration }) ?? true {
                await cacheVerifiedSnapshotForLexicalFallback(
                    item,
                    deadline: hydrationDeadline
                )
            }
            guard !Task.isCancelled,
                clock.now < hydrationDeadline,
                let index = visibleLocalIndex(for: itemID),
                index.generation >= item.expectedGeneration else {
                return nil
            }
            if indexes[itemID] != nil { touchIndex(itemID) }

            let scoped = index.units.filter { unit in
                pageID == nil || unit.pageID == pageID
            }
            let substantive = scoped.filter { $0.kind != .metadata }
            let units = substantive.isEmpty ? scoped : substantive
            guard !units.isEmpty else { return nil }
            return ContentSnapshot(
                itemID: itemID,
                itemName: item.itemName,
                pageID: pageID,
                generation: index.generation,
                contentHash: SearchText.fingerprint(
                    generation: index.generation,
                    units: units
                ),
                units: units
            )
        }

    /// Atomically pins the complete summary input, its source rows, and an
    /// authored-content receipt after any cold hydration has completed. No
    /// actor suspension occurs between these three values being derived.
    func captureSummary(
        itemID: UUID,
        pageID: UUID? = nil,
        deadline: ContinuousClock.Instant? = nil
    ) async -> SummaryCapture? {
        guard let contentSnapshot = await contentSnapshot(
            itemID: itemID,
            pageID: pageID,
            deadline: deadline
        ) else { return nil }
        let sourceAuthority = contentSnapshot.units.map { unit in
            result(unit, terms: [], score: 0)
        }
        let sourceAuthorityByID = Dictionary(
            sourceAuthority.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        let receipt = PublicationReceipt(
            ledger: authoredFreshnessLedger,
            itemRevisions: authoredFreshnessLedger.snapshot(
                itemIDs: [itemID]
            )
        )
        return SummaryCapture(
            contentSnapshot: contentSnapshot,
            sourceAuthority: sourceAuthority,
            sourceAuthorityByID: sourceAuthorityByID,
            freshnessReceipt: receipt
        )
    }

    public func isCurrent(_ snapshot: ContentSnapshot) async -> Bool {
        guard let current = await contentSnapshot(
            itemID: snapshot.itemID,
            pageID: snapshot.pageID
        ) else { return false }
        return current.generation == snapshot.generation
            && current.contentHash == snapshot.contentHash
    }

    /// Rehydrates every source in a previously captured full-note snapshot in
    /// one hot-index pass. Hierarchical summaries can contain tens of thousands
    /// of chunks; resolving those IDs one at a time would turn a verified local
    /// snapshot into the same number of serial catalog reads before the quick
    /// summary can appear.
    func summaryAuthority(
        matching snapshot: ContentSnapshot
    ) async -> [AssistantSearchResult]? {
        guard let current = await contentSnapshot(
            itemID: snapshot.itemID,
            pageID: snapshot.pageID
        ), current == snapshot else { return nil }

        // No suspension follows the equality check, so the returned authority
        // is derived from one actor-isolated semantic state. Later publication
        // still obtains its normal freshness receipt before touching UI state.
        return current.units.map { unit in
            result(unit, terms: [], score: 0)
        }
    }

    /// Rehydrates an already-bounded source set, performs the final complete
    /// snapshot/anchor comparison, and mints its synchronous receipt as one
    /// actor transaction. No mutation can interleave between the final checks
    /// and epoch capture.
    func validatedPublication(
        matching expectedSources: [AssistantSearchResult],
        contentSnapshot expectedSnapshot: ContentSnapshot?
    ) async -> ValidatedPublication? {
        let sourceIDs = expectedSources.map(\.id)
        guard Set(sourceIDs).count == sourceIDs.count else { return nil }
        let representedItems = Set(expectedSources.map(\.anchor.itemID))
            .union(expectedSnapshot.map { [$0.itemID] } ?? [])
        // Capture before the first suspension. `readBounded` can resolve one
        // local source and then await another in Spotlight; if the first item
        // changes in that window, its old unit must not be paired with a newly
        // minted revision receipt.
        let startingRevisions = freshnessLedger.snapshot(
            itemIDs: representedItems
        )

        let rehydrated: [AssistantSearchResult]
        if sourceIDs.isEmpty {
            rehydrated = []
        } else {
            rehydrated = await readBounded(
                anchorIDs: sourceIDs,
                spotlightDeadline: ContinuousClock().now.advanced(
                    by: spotlightSearchTimeout
                )
            )
        }
        guard Self.hasExactPublicationIdentity(
            expectedSources,
            rehydrated
        ) else { return nil }

        if let expectedSnapshot {
            guard let current = await contentSnapshot(
                itemID: expectedSnapshot.itemID,
                pageID: expectedSnapshot.pageID
            ),
                current.generation == expectedSnapshot.generation,
                current.contentHash == expectedSnapshot.contentHash else {
                return nil
            }
        }

        // The previous await is the last suspension in this method. Require
        // the complete hydration interval to have observed one semantic state.
        guard freshnessLedger.performIfCurrent(startingRevisions, {}) else {
            return nil
        }
        let receipt = PublicationReceipt(
            ledger: freshnessLedger,
            itemRevisions: startingRevisions
        )
        return ValidatedPublication(
            sources: rehydrated,
            receipt: receipt
        )
    }
    public func read(anchorIDs: [String]) async -> [AssistantSearchResult] {
        await readBounded(
            anchorIDs: anchorIDs,
            spotlightDeadline: ContinuousClock().now.advanced(
                by: spotlightSearchTimeout
            )
        )
    }

    private func readBounded(
        anchorIDs: [String],
        spotlightDeadline: ContinuousClock.Instant
    ) async -> [AssistantSearchResult] {
        var resolved: [String: Unit] = [:]
        var missing: [String] = []
        for id in anchorIDs {
            if let unit = exactUnit(id),
                isCurrentLocalUnit(unit) || isCurrentSpotlightUnit(unit) {
                resolved[id] = unit
            } else {
                missing.append(id)
            }
        }

        let missingIDs = missing
        if let interactiveSpotlight, !missingIDs.isEmpty,
            let loaded = await boundedInteractiveSpotlightValue(
            until: spotlightDeadline,
            operation: {
                await interactiveSpotlight.load(anchorIDs: missingIDs)
            }
        ) {
            for unit in loaded {
                guard !Task.isCancelled,
                    ContinuousClock().now < spotlightDeadline else { break }
                await hydratePublishedManifestIfNeeded(
                    for: unit.itemID,
                    deadline: spotlightDeadline
                )
                guard isCurrentSpotlightUnit(unit) else { continue }
                resolved[unit.id] = unit
                rememberSpotlightUnit(unit)
            }
        }
        return anchorIDs.compactMap { id in
            resolved[id].map { result($0, terms: [], score: 0) }
        }
    }

    private static func hasExactPublicationIdentity(
        _ expected: [AssistantSearchResult],
        _ rehydrated: [AssistantSearchResult]
    ) -> Bool {
        guard expected.count == rehydrated.count else { return false }
        return zip(expected, rehydrated).allSatisfy { expected, current in
            expected.id == current.id
            && expected.anchor.itemID == current.anchor.itemID
            && expected.anchor.pageID == current.anchor.pageID
            && expected.anchor.blockID == current.anchor.blockID
            && expected.anchor.itemName == current.anchor.itemName
            && expected.anchor.pageNumber == current.anchor.pageNumber
            && expected.anchor.kind == current.anchor.kind
            && expected.anchor.pageBounds == current.anchor.pageBounds
            && expected.anchor.generation == current.anchor.generation
            && expected.anchor.contentHash == current.anchor.contentHash
            && expected.fullText == current.fullText
            }
        }

    public func resolve(anchor: AssistantSourceAnchor) async -> AssistantSourceResolution {
        if let current = catalogLexicalIndex.unit(id: anchor.id),
        let item = registered[anchor.itemID],
        current.itemID == anchor.itemID,
        effectiveCatalogGeneration(for: current) >= item.expectedGeneration,
        effectiveCatalogGeneration(for: current) >= anchor.generation,
        current.contentHash == anchor.contentHash {
        return .current(
            result(
                current,
                terms: SearchText.meaningfulTerms(anchor.snippet),
                score: 0,
                catalogAuthority: true
            )
        )
        }
        if let item = registered[anchor.itemID],
        let current = visibleLocalIndex(for: anchor.itemID),
        current.generation >= item.expectedGeneration,
        current.generation >= anchor.generation,
        let unit = current.byID[anchor.id],
        unit.contentHash == anchor.contentHash {
        return .current(
            result(
                unit,
                terms: SearchText.meaningfulTerms(anchor.snippet),
                score: 0
            )
        )
        }
        if let interactiveSpotlight {
            if let cached = exactUnit(anchor.id),
            isCurrentSpotlightUnit(cached),
            (publishedManifests[cached.itemID]?.generation ?? cached.generation)
            >= anchor.generation,
            cached.contentHash == anchor.contentHash {
            return .current(result(
                cached,
                    cached,
                    terms: SearchText.meaningfulTerms(anchor.snippet),
                    score: 0
                ))
            }
            let spotlightDeadline = ContinuousClock().now.advanced(
                by: spotlightSearchTimeout
            )
            if let loaded = await boundedInteractiveSpotlightValue(
                until: spotlightDeadline,
                operation: {
                    await interactiveSpotlight.load(anchorIDs: [anchor.id])
                }
            ),
                let unit = loaded.first,
                unit.contentHash == anchor.contentHash {
                await hydratePublishedManifestIfNeeded(
                    for: unit.itemID,
                    deadline: spotlightDeadline
                )
                guard isCurrentSpotlightUnit(unit),
                    (publishedManifests[unit.itemID]?.generation ?? unit.generation)
                        >= anchor.generation else { return .stale(anchor) }
                rememberSpotlightUnit(unit)
                return .current(result(
                    unit,
                    terms: SearchText.meaningfulTerms(anchor.snippet),
                    score: 0
                ))
            }
            return .stale(anchor)
        }
        if let current = indexes[anchor.itemID], current.generation < anchor.generation {
            removeCachedIndex(anchor.itemID)
            manifests.removeValue(forKey: anchor.itemID)
        }
        if indexes[anchor.itemID] == nil, let item = registered[anchor.itemID] {
            await ensureIndexed(item)
        }
        guard let index = indexes[anchor.itemID],
            index.generation >= anchor.generation,
            registered[anchor.itemID].map({
                index.generation >= $0.expectedGeneration
            }) ?? true else {
            return .stale(anchor)
        }
        let unit = index.byID[anchor.id] ?? index.units.first {
            $0.pageID == anchor.pageID && $0.blockID == anchor.blockID && $0.kind == anchor.kind
                && $0.contentHash == anchor.contentHash
        }
        guard let unit, unit.contentHash == anchor.contentHash else { return .stale(anchor) }
        return .current(result(unit, terms: SearchText.meaningfulTerms(anchor.snippet), score: 0))
    }

    private func ensureIndexed(_ item: AssistantIndexedItem) async {
        let registrationFingerprint = Self.registrationFingerprint(item)
        if let current = manifests[item.itemID],
            current.isCurrentSchema,
            current.generation >= item.expectedGeneration,
            current.registrationFingerprint == registrationFingerprint,
            indexes[item.itemID] != nil
                || (spotlight != nil
                    && publishedManifests[item.itemID] == current) {
            certifyCatalogProjectionIfPossible(
                itemID: item.itemID,
                generation: current.generation
            )
            await repairPendingImageEnrichmentIfNeeded(item)
            return
        }
        let epoch = extractionEpochs[item.itemID, default: 0]
        let spotlightRevision = spotlightMutationRevisions[item.itemID, default: 0]
        if let spotlight,
            pending[item.itemID] == nil,
            failedPublications[item.itemID] == nil,
            failedDeletions.contains(item.itemID) == false {
            let manifestDeadline = ContinuousClock().now.advanced(
                by: spotlightSearchTimeout
            )
            let persisted = await boundedInteractiveSpotlightValue(
                until: manifestDeadline
            ) {
                SpotlightManifestLoad(
                    manifest: await spotlight.loadManifest(itemID: item.itemID)
                )
            }?.manifest
            if let persisted,
                persisted.isCurrentSchema,
                persisted.generation >= item.expectedGeneration,
                persisted.registrationFingerprint == registrationFingerprint,
                registered[item.itemID] == item,
                extractionEpochs[item.itemID, default: 0] == epoch,
                spotlightMutationRevisions[item.itemID, default: 0]
                    == spotlightRevision,
                pending[item.itemID] == nil,
                publishedManifests[item.itemID] == nil,
                failedPublications[item.itemID] == nil,
                failedDeletions.contains(item.itemID) == false {
                manifests[item.itemID] = persisted
                publishedManifests[item.itemID] = persisted
                latestRequested[item.itemID] = persisted.generation
                certifyCatalogProjectionIfPossible(
                    itemID: item.itemID,
                    generation: persisted.generation
                )
                await repairPendingImageEnrichmentIfNeeded(item)
                return
            }
        }
        guard !Task.isCancelled, registered[item.itemID] == item,
            extractionEpochs[item.itemID, default: 0] == epoch else { return }
        guard let snapshotHydrationLease = await NotebookSnapshotHydrationArbiter
            .shared.tryAcquire(itemID: item.itemID) else { return }
        let loaded = await CanvasCoreStore(rootURL: item.canvasDirectory).load()
        guard !Task.isCancelled, registered[item.itemID] == item,
            extractionEpochs[item.itemID, default: 0] == epoch else { return }
        switch loaded {
        case let .restored(snapshot):
            _ = await index(
                snapshot: snapshot,
                item: item,
                delta: nil,
                registersCatalogProjection: false,
                snapshotHydrationLease: snapshotHydrationLease
            )
        case .newDocument, .failed:
            _ = await replace(units: Self.fallback(item, 0), generation: 0, itemID: item.itemID)
        }
    }

    private func certifyCatalogProjectionIfPossible(
        itemID: UUID,
        generation: Int64
    ) {
        guard catalogProjectionFingerprints[itemID] != nil else { return }
        if catalogLexicalIndex.certify(
            itemID: itemID,
            generation: generation
        ) {
            catalogCertifiedGenerations.removeValue(forKey: itemID)
        } else {
            // A failed (or conservatively reported no-op) physical update
            // must not erase the volatile proof used by current catalog hits.
            // Keeping it also leaves an explicit retry signal for the next
            // preparation/ensure pass instead of silently accepting stale
            // on-disk generation metadata.
            catalogCertifiedGenerations[itemID] = max(
                catalogCertifiedGenerations[itemID, default: 0],
                generation
            )
        }
    }

    /// Resumes notes whose tiny pending breadcrumb survived suspension, and
    /// repairs a physical cache from an older/corrupt schema even if that
    /// breadcrumb was already lost. Current notes with neither signal do not
    /// reopen Canvas Core, so a large library remains cheap to prepare.
    private func repairPendingImageEnrichmentIfNeeded(
        item: AssistantIndexedItem
    ) async {
        guard isBackgroundMaintenanceSuspended == false,
            recoveryImageFencedItemIDs.contains(item.itemID) == false,
            imageEnrichmentTasks[item.itemID] == nil else { return }
        let durableRepairState = await Task.detached(priority: .background) {
            (
                pendingGeneration:
                    AssistantImageEnrichmentStore.pendingGeneration(for: item),
                requiresCacheRebuild:
                    AssistantImageEnrichmentStore.requiresRebuild(for: item)
            )
        }.value
        let durablePendingGeneration = durableRepairState.pendingGeneration
        let pendingGeneration = [
            durablePendingGeneration,
            imageEnrichmentRetryGenerations[item.itemID],
        ].compactMap { $0 }.max()
        guard !Task.isCancelled,
            isBackgroundMaintenanceSuspended == false,
            pendingGeneration != nil
                || durableRepairState.requiresCacheRebuild else { return }

        let epoch = extractionEpochs[item.itemID, default: 0]
        guard let snapshotHydrationLease = await NotebookSnapshotHydrationArbiter
            .shared.tryAcquire(itemID: item.itemID) else { return }
        let loaded = await CanvasCoreStore(rootURL: item.canvasDirectory).load()
        guard !Task.isCancelled,
            isBackgroundMaintenanceSuspended == false,
            registered[item.itemID] == item,
            extractionEpochs[item.itemID, default: 0] == epoch else { return }
        guard case let .restored(snapshot) = loaded else { return }
        if let pendingGeneration {
            guard pendingGeneration <= snapshot.generation else { return }
        }

        let indexedGeneration = pending[item.itemID]?.index.generation
            ?? indexes[item.itemID]?.generation
            ?? manifests[item.itemID]?.generation
        guard indexedGeneration == snapshot.generation else {
            // The authoritative store advanced while the app was away. Its
            // normal verified-generation path supersedes the old breadcrumb.
            _ = await index(
                snapshot: snapshot,
                item: item,
                delta: nil,
                registersCatalogProjection: false,
                snapshotHydrationLease: snapshotHydrationLease
            )
            return
        }
        guard AssistantImageEnrichmentWorker.mayHaveWork(
            snapshot: snapshot,
            item: item
        ) else {
            guard latestRequested[item.itemID] == snapshot.generation,
                extractionEpochs[item.itemID, default: 0] == epoch else { return }
            await Task.detached(priority: .background) {
                AssistantImageEnrichmentStore.remove(
                    throughGeneration: snapshot.generation,
                    for: item
                )
            }.value
            if let durablePendingGeneration {
                await Task.detached(priority: .background) {
                    AssistantImageEnrichmentStore.clearPending(
                        generation: durablePendingGeneration,
                        for: item
                    )
                }.value
            }
            if imageEnrichmentRetryGenerations[item.itemID]
                .map({ $0 <= snapshot.generation }) == true {
                imageEnrichmentRetryGenerations.removeValue(forKey: item.itemID)
            }
            suspensionRetainedImageItemIDs.remove(item.itemID)
            return
        }

        guard let extracted = await Self.extract(snapshot: snapshot, item: item),
            !Task.isCancelled,
            isBackgroundMaintenanceSuspended == false,
            registered[item.itemID] == item,
            extractionEpochs[item.itemID, default: 0] == epoch,
            latestRequested[item.itemID] == snapshot.generation else { return }
        let baseUnits = Self.includingMetadata(
            in: extracted,
            item: item,
            generation: snapshot.generation
        )
        suspensionRetainedImageItemIDs.remove(item.itemID)
        await scheduleImageEnrichment(
            snapshot: snapshot,
            item: item,
            baseUnits: baseUnits,
            generation: snapshot.generation,
            epoch: epoch,
            snapshotHydrationLease: snapshotHydrationLease
        )
    }

    private func cacheVerifiedSnapshotForLexicalFallback(
        _ item: AssistantIndexedItem,
        deadline: ContinuousClock.Instant
    ) async {
        let clock = ContinuousClock()
        guard !Task.isCancelled,
            clock.now < deadline,
            let hydrationID = await coldHydrationLane.tryAcquire(
                itemID: item.itemID
            ) else { return }
        let hydrationLane = coldHydrationLane
        var releasesLaneOnReturn = true
        defer {
            if releasesLaneOnReturn {
                Task {
                    await hydrationLane.release(
                        itemID: item.itemID,
                        hydrationID: hydrationID
                    )
                }
            }
        }
        guard let snapshotHydrationLease = await NotebookSnapshotHydrationArbiter
            .shared.tryAcquire(itemID: item.itemID) else { return }
        let epoch = extractionEpochs[item.itemID, default: 0]
        let canvasDirectory = item.canvasDirectory
        #if DEBUG
        let coldCanvasLoadHook = beforeColdCanvasLoadForTesting
        #endif
        let loadTask = Task.detached(priority: .userInitiated) {
            #if DEBUG
            await coldCanvasLoadHook?()
            #endif
            return await CanvasCoreStore(rootURL: canvasDirectory).load()
        }
        let loadOutcome = await assistantImageTaskOutcome(
            of: loadTask,
            until: deadline
        )
        guard case let .value(loaded) = loadOutcome else {
            releasesLaneOnReturn = false
            Task { [snapshotHydrationLease] in
                defer { withExtendedLifetime(snapshotHydrationLease) {} }
                _ = await loadTask.value
                await hydrationLane.release(
                    itemID: item.itemID,
                    hydrationID: hydrationID
                )
            }
            return
        }
        guard case let .restored(snapshot) = loaded,
            snapshot.generation >= item.expectedGeneration else { return }
        let generation = snapshot.generation
        let authoredTask = Task.detached(priority: .userInitiated) {
            guard let extracted = await Self.extract(
                snapshot: snapshot,
                item: item
            ), !Task.isCancelled else { return nil as [Unit]? }
            return Self.includingMetadata(
                in: extracted,
                item: item,
                generation: generation
            )
        }
        let authoredOutcome = await assistantImageTaskOutcome(
            of: authoredTask,
            until: deadline
        )
        guard case let .value(optionalAuthoredBaseUnits) = authoredOutcome else {
            releasesLaneOnReturn = false
            Task { [snapshotHydrationLease] in
                defer { withExtendedLifetime(snapshotHydrationLease) {} }
                _ = await authoredTask.value
                await hydrationLane.release(
                    itemID: item.itemID,
                    hydrationID: hydrationID
                )
            }
            return
        }
        guard let authoredBaseUnits = optionalAuthoredBaseUnits else { return }
        guard !Task.isCancelled, clock.now < deadline else { return }

        let allowsDurableReplay = recoveryImageFencedItemIDs
            .contains(item.itemID) == false
        #if DEBUG
        let durableReplayHook = beforeDurableImageEnrichmentLoadForTesting
        #endif
            let replayTask = Task<(
                units: [Unit],
                records: [AssistantImageEnrichmentRecord]
            ), Never>.detached(priority: .userInitiated) {
            guard allowsDurableReplay else {
                return (authoredBaseUnits, [])
            }
            #if DEBUG
            await durableReplayHook?()
            #endif
            return await Self.loadDurableImageEnrichmentReplay(
                over: authoredBaseUnits,
                item: item,
                generation: generation
            )
        }
        let durableReplay: (
            units: [Unit],
            records: [AssistantImageEnrichmentRecord]
        )
        let replayOutcome = await assistantImageTaskOutcome(
            of: replayTask,
            until: deadline
        )
        guard case let .value(replayed) = replayOutcome else {
            releasesLaneOnReturn = false
            Task { [snapshotHydrationLease] in
                defer { withExtendedLifetime(snapshotHydrationLease) {} }
                _ = await replayTask.value
                await hydrationLane.release(
                    itemID: item.itemID,
                    hydrationID: hydrationID
                )
            }
            return
        }
        durableReplay = replayed
        guard !Task.isCancelled, clock.now < deadline else { return }

        let registrationFingerprint = Self.registrationFingerprint(item)
        let proposalTask = Task.detached(priority: .userInitiated) {
            Self.buildInitialProposalBundle(
                durableReplayUnits: durableReplay.units,
                hasDurableRecords: durableReplay.records.isEmpty == false,
                authoredBaseUnits: authoredBaseUnits,
                generation: generation,
                itemID: item.itemID,
                registrationFingerprint: registrationFingerprint
            )
        }
        let proposalOutcome = await assistantImageTaskOutcome(
            of: proposalTask,
            until: deadline
        )
        guard case let .value(optionalBundle) = proposalOutcome else {
            releasesLaneOnReturn = false
            Task { [snapshotHydrationLease] in
                defer { withExtendedLifetime(snapshotHydrationLease) {} }
                _ = await proposalTask.value
                await hydrationLane.release(
                    itemID: item.itemID,
                    hydrationID: hydrationID
                )
            }
            return
        }
        guard let proposalBundle = optionalBundle else { return }
        #if DEBUG
        itemIndexConstructionCountForTesting += proposalBundle.constructionCount
        #endif
        let proposal = proposalBundle.replay
        guard !Task.isCancelled,
            clock.now < deadline,
            registered[item.itemID] == item,
            extractionEpochs[item.itemID, default: 0] == epoch,
            pending[item.itemID] == nil,
            latestRequested[item.itemID, default: 0] <= generation else { return }

        let effective = indexes[item.itemID]?.manifest
            ?? manifests[item.itemID]
        if let effective {
            guard effective.generation <= generation else { return }
            if effective.generation == generation {
                if effective.fingerprint != proposal.fingerprint {
                    let authoredProposal = proposalBundle.authored
                    guard durableReplay.records.isEmpty == false,
                        effective == authoredProposal.manifest,
                        !Task.isCancelled,
                        clock.now < deadline else { return }
                    latestRequested[item.itemID] = generation
                    let promotionTask = Task { [weak self] in
                        await self?.replaceImageEnrichment(
                            records: durableReplay.records,
                            baseUnits: authoredBaseUnits,
                            generation: generation,
                            itemID: item.itemID,
                            epoch: epoch,
                            allowsSuspendedReplay: true,
                            deadline: deadline
                        ) ?? .rejected
                    }
                    let promotionOutcome = await assistantImageTaskOutcome(
                        of: promotionTask,
                        until: deadline
                    )
                    guard case let .value(promoted) = promotionOutcome else {
                        releasesLaneOnReturn = false
                        Task { [snapshotHydrationLease] in
                            defer {
                                withExtendedLifetime(snapshotHydrationLease) {}
                            }
                            _ = await promotionTask.value
                            await hydrationLane.release(
                                itemID: item.itemID,
                                hydrationID: hydrationID
                            )
                        }
                        return
                    }
                    if promoted.durablyPublished {
                        _ = Task.detached(priority: .utility) {
                            AssistantImageEnrichmentStore.clearPending(
                                generation: generation,
                                for: item
                            )
                        }
                    }
                    return
                }
                if indexes[item.itemID] != nil { return }
            }
        }

        if effective?.fingerprint != proposal.fingerprint {
            guard clock.now < deadline else { return }
            invalidateAuthoredContent(itemIDs: [item.itemID])
        }
        guard clock.now < deadline else { return }
        latestRequested[item.itemID] = max(
            latestRequested[item.itemID, default: 0],
            generation
        )
        cacheIndex(proposal, itemID: item.itemID)
        guard durableReplay.records.isEmpty == false,
            isDurablyPublished(proposal.manifest, itemID: item.itemID)
        else { return }

        // A complete exact-generation cache plus the same durable manifest is
        // the crash-window successor the breadcrumb was waiting for. Clear it
        // before reporting the cold replay complete, but keep the visible
        // request deadline bounded and retain this item's hydration lane until
        // a cancellation-resistant filesystem/defaults callback really drains.
        #if DEBUG
        let acknowledgementHook =
            beforeColdImageBreadcrumbAcknowledgementForTesting
        #endif
        let acknowledgementTask = Task.detached(priority: .utility) {
            #if DEBUG
            await acknowledgementHook?()
            #endif
            AssistantImageEnrichmentStore.clearPending(
                generation: generation,
                for: item
            )
        }
        let acknowledgementOutcome = await assistantImageTaskOutcome(
            of: acknowledgementTask,
            until: deadline
        )
        guard case .value = acknowledgementOutcome else {
            releasesLaneOnReturn = false
            Task { [snapshotHydrationLease] in
                defer { withExtendedLifetime(snapshotHydrationLease) {} }
                _ = await acknowledgementTask.value
                await hydrationLane.release(
                    itemID: item.itemID,
                    hydrationID: hydrationID
                )
            }
            return
        }
    }

    /// Merges only a complete, generation-stamped Vision cache into a replayed
    /// authoritative snapshot. Incremental cache checkpoints are never
    private func FIXME6543(
        _ fixmeA: Int,
        _ fixmeB: Int,
        _ fixmeC: Int,
        over baseUnits: [Unit],
        item: AssistantIndexedItem,
        generation: Int64
    ) async -> (
        units: [Unit],
        records: [AssistantImageEnrichmentRecord]
    ) {
        guard recoveryImageFencedItemIDs.contains(item.itemID) == false else {
            return (baseUnits, [])
        }
        #if DEBUG
        await beforeDurableImageEnrichmentLoadForTesting?()
        #endif
        return await Self.loadDurableImageEnrichmentReplay(
            over: baseUnits,
            item: item,
            generation: generation
        )
    }

    /// Performs only immutable store reads and value construction. Keeping the
    /// raw cold-replay task nonisolated ensures a value that drains after its
    /// deadline has no capability to mutate `NotebookIndex` actor state.
    nonisolated private static func loadDurableImageEnrichmentReplay(
        over baseUnits: [Unit],
        item: AssistantIndexedItem,
        generation: Int64
    ) async -> (
        units: [Unit],
        records: [AssistantImageEnrichmentRecord]
    ) {
        await Task.detached(priority: .utility) {
            let records = AssistantImageEnrichmentStore.load(
                for: item,
                generation: generation
            )
            guard records.isEmpty == false,
                Self.isIndexableRegistration(item) else {
                return (baseUnits, [])
            }
            var remainingTextBytes = maximumExpandedTextUTF8ByteCount
            for unit in baseUnits where unit.kind != .imageContent {
                let byteCount = unit.text.utf8.count
                guard byteCount <= remainingTextBytes else {
                    return (baseUnits, [])
                }
                remainingTextBytes -= byteCount
            }
            var imageUnits: [Unit] = []
            imageUnits.reserveCapacity(min(
                records.count,
                maximumSingleCachedUnits
            ))
            for record in records {
                guard !Task.isCancelled,
                    imageUnits.count < maximumSingleCachedUnits,
                    let text = record.searchableText(
                        maximumUTF8Bytes: remainingTextBytes
                    ) else {
                    return (baseUnits, [])
                }
                guard text.isEmpty == false else { continue }
                let byteCount = text.utf8.count
                guard byteCount <= remainingTextBytes else {
                    return (baseUnits, [])
                }
                remainingTextBytes -= byteCount
                imageUnits.append(Unit(
                    itemID: item.itemID,
                    itemName: item.itemName,
                    pageID: record.pageID,
                    blockID: Self.imageBlockID(record.stableID),
                    pageNumber: record.pageNumber,
                    kind: .imageContent,
                    pageBounds: record.pageBounds,
                    generation: generation,
                    text: text
                ))
            }
            return (
                baseUnits.filter { $0.kind != .imageContent } + imageUnits,
                records
            )
        }.value
    }

    private func publicationTask(
        itemID: UUID,
        proposal: ItemIndex
    ) -> (task: Task<SpotlightMutationReport, Never>, revision: UInt64) {
        let revision = advanceSpotlightMutationRevision(for: itemID)
        let backend = spotlight
        let mutationCoordinator = spotlightMutationCoordinator
        let mutationDeadline = ContinuousClock().now.advanced(
            by: spotlightMutationTimeout
        )
        // A differential update is safe only from the exact generation whose
        // manifest was successfully committed. `indexes` also holds bounded
        // lexical fallbacks and failed proposals, while a same-item request
        // may already be queued ahead of this task. Falling back to a complete
        // domain replacement prevents either source from being mistaken for
        // content that is known to exist in Spotlight.
        let previousIndex = indexes[itemID]
        let hasPendingSameItemPublication = pending[itemID] != nil
        let verifiedPreviousUnits: [Unit]?
        if !hasPendingSameItemPublication,
            let previousIndex,
            publishedManifests[itemID] == previousIndex.manifest {
            verifiedPreviousUnits = previousIndex.units
        } else {
            verifiedPreviousUnits = nil
        }
        #if DEBUG
        let publicationHook = beforeSpotlightPublicationForTesting
        #endif
        let task = Task<SpotlightMutationReport, Never> { [weak self] in
            guard !Task.isCancelled else { return .cancelled }
            #if DEBUG
            await publicationHook?()
            #endif
            guard !Task.isCancelled else { return .cancelled }
            guard let backend else { return .success }
            return await mutationCoordinator.perform(
                domains: [itemID],
                until: mutationDeadline,
                shouldBegin: { [weak self] in
                    await self?.spotlightMutationsAreCurrent([
                        itemID: revision,
                    ]) ?? false
                },
                operation: {
                    await backend.replace(
                        itemID: itemID,
                        units: proposal.units,
                        manifest: proposal.manifest,
                        previousUnits: verifiedPreviousUnits
                    )
                },
                onLateDrain: { [weak self] in
                    await self?.spotlightMutationDrainedLate(
                        revisions: [itemID: revision]
                    )
                }
            )
        }
        return (task, revision)
    }

    @discardableResult
    private func deleteSpotlightDomains(_ ids: [UUID]) async -> Bool {
        guard !ids.isEmpty else { return true }
        guard let spotlight else { return true }
        var mutationRevisions: [UUID: UInt64] = [:]
        for id in ids {
            mutationRevisions[id] = advanceSpotlightMutationRevision(for: id)
            failedPublications.removeValue(forKey: id)
            protectedFailedPublicationIDs.remove(id)
        }
        let expectedMutationRevisions = mutationRevisions
        let mutationCoordinator = spotlightMutationCoordinator
        let mutationDeadline = ContinuousClock().now.advanced(
            by: spotlightMutationTimeout
        )
        let itemIDSet = Set(ids)
        let task = Task<SpotlightMutationReport, Never> { [weak self] in
            guard !Task.isCancelled else { return .cancelled }
            return await mutationCoordinator.perform(
                domains: itemIDSet,
                until: mutationDeadline,
                shouldBegin: { [weak self] in
                    await self?.spotlightMutationsAreCurrent(
                        expectedMutationRevisions
                    ) ?? false
                },
                operation: {
                    await spotlight.deleteDomains(for: ids)
                },
                onLateDrain: { [weak self] in
                    await self?.spotlightMutationDrainedLate(
                        revisions: expectedMutationRevisions
                    )
                }
            )
        }
        let report = await task.value
        if report.succeeded {
            for id in ids where spotlightMutationRevisions[id] == mutationRevisions[id] {
                failedDeletions.remove(id)
                publishedManifests.removeValue(forKey: id)
                clearLateSpotlightDrainIfMatching(
                    itemID: id,
                    revision: mutationRevisions[id]
                )
            }
        } else {
            for id in ids where spotlightMutationRevisions[id] == mutationRevisions[id] {
                failedDeletions.insert(id)
                publishedManifests.removeValue(forKey: id)
                consumeLateSpotlightDrainIfNeeded(
                    itemID: id,
                    revision: mutationRevisions[id]
                )
            }
            trimDeferredMutations()
        }
        return report.succeeded && ids.allSatisfy { id in
            spotlightMutationRevisions[id] == mutationRevisions[id]
        }
    }

    private func spotlightMutationDrainedLate(
        revisions: [UUID: UInt64]
    ) {
        var shouldRetry = false
        for (itemID, revision) in revisions {
            guard spotlightMutationRevisions[itemID] == revision else {
                // A newer mutation owns fail-closed state. This old callback is
                // only a physical drain notification and cannot authorize or
                // wake the newer revision's repair.
                continue
            }
            lateDrainedSpotlightMutationRevisions[itemID] = revision
            if failedDeletions.contains(itemID)
               || failedPublications[itemID] != nil {
                lateDrainedSpotlightMutationRevisions.removeValue(
                    forKey: itemID
                )
                shouldRetry = true
            }
        }
        guard shouldRetry else { return }
        Task { [weak self] in
            await self?.retryFailedSpotlightMutations()
        }
    }

    private func clearLateSpotlightDrainIfMatching(
        itemID: UUID,
        revision: UInt64?
    ) {
        guard let revision,
              lateDrainedSpotlightMutationRevisions[itemID] == revision else {
            return
        }
        lateDrainedSpotlightMutationRevisions.removeValue(forKey: itemID)
    }

    private func consumeLateSpotlightDrainIfNeeded(
        itemID: UUID,
        revision: UInt64?
    ) {
        guard let revision,
              lateDrainedSpotlightMutationRevisions[itemID] == revision else {
            return
        }
        lateDrainedSpotlightMutationRevisions.removeValue(forKey: itemID)
        Task { [weak self] in
            await self?.retryFailedSpotlightMutations()
        }
    }

    private func finalize(
        itemID: UUID,
        proposal: ItemIndex,
        publicationSucceeded: Bool,
        spotlightMutationRevision: UInt64,
        expectedEpoch: UInt64
    ) {
        guard let pending = pending[itemID],
              pending.index.generation == proposal.generation,
              pending.index.fingerprint == proposal.fingerprint,
              pending.spotlightMutationRevision == spotlightMutationRevision,
              extractionEpochs[itemID, default: 0] == expectedEpoch,
              latestRequested[itemID] == proposal.generation,
              proposalMatchesCurrentRegistration(
                  proposal,
                  itemID: itemID
              ) else { return }
        manifests[itemID] = proposal.manifest
        let proposalWasAlreadyCached = indexes[itemID]?.manifest == proposal.manifest
        if proposalWasAlreadyCached == false {
            // Image-enrichment and cold-replay publications do not necessarily
            // pre-cache their proposal. Preserve that path, while ordinary
            // replacements avoid rotating and retokenizing the same hot data.
            cacheIndex(proposal, itemID: itemID, rebuildLibraryIndex: false)
        }
        var deferredPublicationStateChanged = false
        if spotlight != nil,
           spotlightMutationRevisions[itemID] == spotlightMutationRevision {
            if publicationSucceeded {
                publishedManifests[itemID] = proposal.manifest
                let removedFailedPublication =
                    failedPublications.removeValue(forKey: itemID) != nil
                let removedProtection =
                    protectedFailedPublicationIDs.remove(itemID) != nil
                deferredPublicationStateChanged =
                    removedFailedPublication || removedProtection
                failedDeletions.remove(itemID)
                clearLateSpotlightDrainIfMatching(
                    itemID: itemID,
                    revision: spotlightMutationRevision
                )
                evictRecentSpotlightUnits(for: itemID)
            } else {
                // A complete-domain replacement may delete stale identifiers
                // before a later indexing step fails. Even if an overlapping
                // retry just acknowledged the same manifest, this failed
                // attempt makes the durable surface uncertain until another
                // complete replacement succeeds.
                publishedManifests.removeValue(forKey: itemID)
                failedPublications[itemID] = proposal
                deferredPublicationStateChanged = true
                consumeLateSpotlightDrainIfNeeded(
                    itemID: itemID,
                    revision: spotlightMutationRevision
                )
            }
        }
        self.pending.removeValue(forKey: itemID)
        if publicationWaiters[itemID]?.spotlightMutationRevision
           == spotlightMutationRevision {
            publicationWaiters.removeValue(forKey: itemID)
        }
        // Trimming while `pending` still owned the same proposal could rebuild
        // the library index from an entry that was supposedly evicted. Remove
        // the transient owner first, then cap and rebuild from final state.
        if publicationSucceeded == false, deferredPublicationStateChanged {
            trimDeferredMutations()
        }
        if proposalWasAlreadyCached == false || deferredPublicationStateChanged {
            rebuildLibraryLexicalIndex()
        }
    }

    // A registration can advance while a complete-domain provider write is
    // suspended. If the proposal is still exact for the new registration,
    // finish it without acknowledging the stale caller. Otherwise remove only
    // the pending/cache state owned by that exact mutation and quarantine any
    // physical bytes the provider may have written.
    private func reconcileCompletedPublicationAfterRegistrationChange(
        itemID: UUID,
        proposal: ItemIndex,
        publicationSucceeded: Bool,
        spotlightMutationRevision: UInt64,
        expectedEpoch: UInt64
    ) {
        if extractionEpochs[itemID, default: 0] == expectedEpoch,
           latestRequested[itemID] == proposal.generation,
           proposalMatchesCurrentRegistration(proposal, itemID: itemID) {
            finalize(
                itemID: itemID,
                proposal: proposal,
                publicationSucceeded: publicationSucceeded,
                spotlightMutationRevision: spotlightMutationRevision,
                expectedEpoch: expectedEpoch
            )
            return
        }

        guard let rejected = pending[itemID],
              rejected.index.manifest == proposal.manifest,
              rejected.spotlightMutationRevision
                  == spotlightMutationRevision else { return }
        freshnessLedger.invalidate(itemIDs: [itemID])
        pending.removeValue(forKey: itemID)
        if publicationWaiters[itemID]?.spotlightMutationRevision
            == spotlightMutationRevision {
            publicationWaiters.removeValue(forKey: itemID)
        }
        if indexes[itemID]?.manifest == proposal.manifest {
            removeCachedIndex(itemID, rebuildLibraryIndex: false)
        }
        if manifests[itemID] == proposal.manifest {
            manifests.removeValue(forKey: itemID)
        }
        if publishedManifests[itemID] == proposal.manifest {
            publishedManifests.removeValue(forKey: itemID)
        }
        rebuildLibraryLexicalIndex()
        quarantineRejectedSpotlightPublication(
            itemID: itemID,
            mutationRevision: spotlightMutationRevision,
            authoritativeRepair: rejected.repairProposal
        )
    }

    private func proposalMatchesCurrentRegistration(
        _ proposal: ItemIndex,
        itemID: UUID
    ) -> Bool {
        guard let item = registered[itemID] else {
            // `replace` is also a package-internal seam for bounded test/local
            // units without a catalog registration. That mode remains valid
            // only while the item stays unregistered across every suspension.
            return proposal.registrationFingerprint == nil
        }
        return proposal.registrationFingerprint == Self.registrationFingerprint(item)
            && proposal.generation >= item.expectedGeneration
    }

    @discardableResult
    private func advanceSpotlightMutationRevision(for itemID: UUID) -> UInt64 {
        // A marker belongs only to the revision that produced it. Advancing
        // semantic intent invalidates any earlier drain notification even when
        // its cancellation-resistant provider callback arrives later.
        lateDrainedSpotlightMutationRevisions.removeValue(forKey: itemID)
        spotlightMutationRevisions[itemID, default: 0] &+= 1
        return spotlightMutationRevisions[itemID, default: 0]
    }

    private func spotlightMutationsAreCurrent(
        _ expectedRevisions: [UUID: UInt64]
    ) -> Bool {
        guard !Task.isCancelled else { return false }
        return expectedRevisions.allSatisfy { itemID, revision in
            spotlightMutationRevisions[itemID] == revision
        }
    }

    private func clearMemory(for id: UUID, rebuildLibraryIndex: Bool = true) {
        _ = advanceSpotlightMutationRevision(for: id)
        removeCachedIndex(id, rebuildLibraryIndex: false)
        manifests.removeValue(forKey: id)
        publishedManifests.removeValue(forKey: id)
        pending.removeValue(forKey: id)
        publicationWaiters.removeValue(forKey: id)
        failedPublications.removeValue(forKey: id)
        protectedFailedPublicationIDs.remove(id)
        imageEnrichmentRetryGenerations.removeValue(forKey: id)
        suspensionRetainedImageItemIDs.remove(id)
        let recentKeys = recentSpotlightRecency.filter {
            recentSpotlightUnits[$0]?.itemID == id
        }
        for key in recentKeys {
            removeRecentSpotlightUnit(key)
        }
        if rebuildLibraryIndex { rebuildLibraryLexicalIndex() }
    }

    private func advanceEpoch(for id: UUID) { extractionEpochs[id, default: 0] &+= 1 }

    private func cacheIndex(
        _ index: ItemIndex,
        itemID: UUID,
        rebuildLibraryIndex: Bool = true
    ) {
        removeCachedIndex(itemID, rebuildLibraryIndex: false)
        guard index.units.count <= Self.maximumSingleCachedUnits,
              let textByteCount = Self.textUTF8ByteCount(
                  in: index.units,
                  maximum: Self.maximumExpandedTextUTF8ByteCount
              ) else {
            if rebuildLibraryIndex { rebuildLibraryLexicalIndex() }
            return
        }
        indexes[itemID] = index
        cachedUnitCount += index.units.count
        cachedTextUTF8ByteCount += textByteCount
        indexRecency.append(itemID)
        while indexes.count > Self.maximumCachedItems
                || ((cachedUnitCount > Self.maximumCachedUnits
                    || cachedTextUTF8ByteCount
                        > Self.maximumCachedTextUTF8ByteCount)
                && indexes.count > 1) {
            guard let oldest = indexRecency.first else { break }
            removeCachedIndex(oldest, rebuildLibraryIndex: false)
        }
        if rebuildLibraryIndex { rebuildLibraryLexicalIndex() }
    }

    private func touchIndex(_ itemID: UUID) {
        guard indexes[itemID] != nil else { return }
        indexRecency.removeAll { $0 == itemID }
        indexRecency.append(itemID)
    }

    private func removeCachedIndex(
        _ itemID: UUID,
        rebuildLibraryIndex: Bool = true
    ) {
        if let removed = indexes.removeValue(forKey: itemID) {
            cachedUnitCount = removed.units.count >= cachedUnitCount
                ? 0
                : cachedUnitCount - removed.units.count
            let removedTextBytes = Self.textUTF8ByteCount(
                in: removed.units,
                maximum: Self.maximumExpandedTextUTF8ByteCount
            ) ?? cachedTextUTF8ByteCount
            cachedTextUTF8ByteCount = removedTextBytes
                >= cachedTextUTF8ByteCount
                ? 0
                : cachedTextUTF8ByteCount - removedTextBytes
        }
        indexRecency.removeAll { $0 == itemID }
        if rebuildLibraryIndex { rebuildLibraryLexicalIndex() }
    }

    private func rebuildLibraryLexicalIndex() {
#if DEBUG
        libraryLexicalRebuildCountForTesting += 1
#endif
        if let pendingLibraryLexicalRebuild {
            pendingLibraryLexicalRebuild.task.cancel()
#if DEBUG
            libraryLexicalCancelledRebuildCountForTesting += 1
#endif
        }
        libraryLexicalRebuildRevision &+= 1
        let revision = libraryLexicalRebuildRevision
        let itemIDs = Set(indexes.keys)
            .union(pending.keys)
            .union(failedPublications.keys)
            .sorted { $0.uuidString < $1.uuidString }
        let unitsByItem = itemIDs.map { itemID in
            visibleLocalIndex(for: itemID)?.units ?? []
        }
#if DEBUG
        let buildHook = beforeLibraryLexicalBuildForTesting
#endif
        let task: Task<LibraryLexicalIndex?, Never> = Task.detached(priority: .utility) {
#if DEBUG
            await buildHook?()
#endif
            guard Task.isCancelled == false else { return nil }
            return Self.buildLibraryLexicalIndex(unitsByItem: unitsByItem)
        }
        pendingLibraryLexicalRebuild = LibraryLexicalRebuild(
            revision: revision,
            task: task
        )
        Task { [weak self] in
            let built = await task.value
            await self?.finishLibraryLexicalRebuild(
                built,
                revision: revision
            )
        }
    }

    private nonisolated static func buildLibraryLexicalIndex(
        unitsByItem: [[Unit]]
    ) -> LibraryLexicalIndex? {
        guard Task.isCancelled == false else { return nil }
        var seen = Set<String>()
        var offsets = Array(repeating: 0, count: unitsByItem.count)
        var units: [Unit] = []
        units.reserveCapacity(unitsByItem.reduce(0) { $0 + $1.count })

        // Interleave documents so a common one-term query does not spend the
        // complete 24-candidate budget on whichever UUID sorts first.
        var appendedInPass = true
        while appendedInPass {
            guard Task.isCancelled == false else { return nil }
            appendedInPass = false
            for itemIndex in unitsByItem.indices {
                guard Task.isCancelled == false else { return nil }
                guard offsets[itemIndex] < unitsByItem[itemIndex].count else { continue }
                let unit = unitsByItem[itemIndex][offsets[itemIndex]]
                offsets[itemIndex] += 1
                appendedInPass = true
                if seen.insert(unit.id).inserted { units.append(unit) }
            }
        }
        guard Task.isCancelled == false else { return nil }
        return LibraryLexicalIndex(cancellableUnits: units)
    }

    private func finishLibraryLexicalRebuild(
        _ rebuilt: LibraryLexicalIndex?,
        revision: UInt64
    ) {
        guard revision == libraryLexicalRebuildRevision,
              pendingLibraryLexicalRebuild?.revision == revision else {
            return
        }
        if let rebuilt {
            libraryLexicalIndex = rebuilt
        }
        pendingLibraryLexicalRebuild = nil
    }

    private func currentLibraryOverlayCandidateUnits(
        matching terms: [String],
        maximumCount: Int
    ) -> [Unit] {
        guard maximumCount > 0 else { return [] }
        let itemIDs = Set(indexes.keys)
            .union(pending.keys)
            .union(failedPublications.keys)
            .sorted { $0.uuidString < $1.uuidString }
        let sources = itemIDs.compactMap { itemID -> [Unit]? in
            guard let index = visibleLocalIndex(for: itemID) else { return nil }
            let units = index.lexical.candidateIndices(
                matching: terms,
                pageID: nil,
                units: index.units,
                maximumCount: maximumCount
            ).map { index.units[$0] }.filter { unit in
                isCurrentLocalUnit(unit)
            }
            return units.isEmpty ? nil : units
        }
        return Self.interleavedUniqueUnits(
            sources: sources,
            maximumCount: maximumCount
        )
    }

    private nonisolated static func interleavedUniqueUnits(
        sources: [[Unit]],
        maximumCount: Int
    ) -> [Unit] {
        guard maximumCount > 0, sources.isEmpty == false else { return [] }
        var offsets = Array(repeating: 0, count: sources.count)
        var seen = Set<String>()
        var units: [Unit] = []
        units.reserveCapacity(maximumCount)
        var advanced = true
        while units.count < maximumCount, advanced {
            advanced = false
            for sourceIndex in sources.indices {
                guard offsets[sourceIndex] < sources[sourceIndex].count else {
                    continue
                }
                let unit = sources[sourceIndex][offsets[sourceIndex]]
                offsets[sourceIndex] += 1
                advanced = true
        if seen.insert(unit.id).inserted {
            units.append(unit)
            if units.count == maximumCount { break }
        }
            }
        }
        return units
    }

    private func rememberSpotlightUnit(_ unit: Unit) {
        guard unit.text.utf8.count <= Self.maximumChunkUTF8ByteCount,
            Self.isIndexableItemName(unit.itemName) else { return }
        removeRecentSpotlightUnit(unit.id)
        recentSpotlightUnits[unit.id] = unit
        recentSpotlightTextUTF8ByteCount += unit.text.utf8.count
        recentSpotlightRecency.append(unit.id)
        while recentSpotlightRecency.count > Self.maximumRecentSpotlightUnits
            || recentSpotlightTextUTF8ByteCount
            > Self.maximumRecentSpotlightTextUTF8ByteCount {
            guard let oldest = recentSpotlightRecency.first else { break }
            removeRecentSpotlightUnit(oldest)
        }
    }

    private func removeRecentSpotlightUnit(_ id: String) {
        if let removed = recentSpotlightUnits.removeValue(forKey: id) {
            let byteCount = removed.text.utf8.count
            recentSpotlightTextUTF8ByteCount = byteCount
                >= recentSpotlightTextUTF8ByteCount
                ? 0
                : recentSpotlightTextUTF8ByteCount - byteCount
        }
        recentSpotlightRecency.removeAll { $0 == id }
    }

    private func evictRecentSpotlightUnits(for itemID: UUID) {
        let keys = recentSpotlightRecency.filter {
            recentSpotlightUnits[$0]?.itemID == itemID
        }
        for key in keys {
            removeRecentSpotlightUnit(key)
        }
    }

    private func isCurrentSpotlightUnit(_ unit: Unit) -> Bool {
        guard let item = registered[unit.itemID],
            unit.itemName == item.itemName,
            let manifest = publishedManifests[unit.itemID],
            isDurablyPublished(manifest, itemID: unit.itemID) else {
            return false
        }
        let expectedRegistration = Self.registrationFingerprint(item)
        if let suppressed = pending[unit.itemID],
            suppressed.isSearchSuppressed,
            unit.kind != .imageContent,
            unit.spotlightManifestFingerprint == suppressed.index.fingerprint,
            let repair = suppressed.repairProposal,
            repair.manifest == manifest,
            let pendingUnit = suppressed.index.byID[unit.id],
            let repairUnit = repair.byID[unit.id],
            pendingUnit.contentHash == unit.contentHash,
            pendingUnit.text == unit.text,
            pendingUnit.kind == unit.kind,
            pendingUnit.pageID == unit.pageID,
            pendingUnit.blockID == unit.blockID,
            pendingUnit.chunkOrdinal == unit.chunkOrdinal,
            pendingUnit.generation == unit.generation,
            pendingUnit.pageNumber == unit.pageNumber,
            pendingUnit.pageBounds == unit.pageBounds,
            repairUnit.contentHash == unit.contentHash,
            repairUnit.text == unit.text,
            repairUnit.kind == unit.kind,
            repairUnit.pageID == unit.pageID,
            repairUnit.blockID == unit.blockID,
            repairUnit.chunkOrdinal == unit.chunkOrdinal,
            repairUnit.generation == unit.generation,
            repairUnit.pageNumber == unit.pageNumber,
            repairUnit.pageBounds == unit.pageBounds {
            // The provider has physically crossed the deadline with a complete
            // derived-domain replacement, but its report is still withheld.
            // Preserve only bytes proved identical to the separately retained
            // authored repair proposal; OCR from that same domain remains
            // categorically ineligible.
            return manifest.isCurrentSchema
                && manifest.registrationFingerprint == expectedRegistration
                && manifest.generation >= item.expectedGeneration
                && unit.generation <= manifest.generation
        }
        guard unit.spotlightManifestFingerprint == manifest.fingerprint else {
            return false
        }
        // A deadline-suppressed derived proposal is deliberately not local
        // search authority. Validate Spotlight against the same visible base
        // projection used by lexical retrieval, otherwise a still-valid base
        // chunk is rejected merely because hidden OCR is pending.
        if let local = visibleLocalIndex(for: unit.itemID) {
            guard local.generation <= manifest.generation else { return false }
            if local.generation == manifest.generation {
                guard local.manifest == manifest,
                    let current = local.byID[unit.id],
                    current.contentHash == unit.contentHash,
                    current.pageNumber == unit.pageNumber,
                    current.pageBounds == unit.pageBounds else { return false }
            }
        }
        return manifest.isCurrentSchema
            && manifest.registrationFingerprint == expectedRegistration
            && manifest.generation >= item.expectedGeneration
            // Differential publications leave unchanged chunks at the
            // generation where their locator/content was last rewritten.
            // The manifest is committed last, so a newer chunk can never be
            // trusted under an older manifest, while an older unchanged chunk
            // is valid after stale identifiers were deleted successfully.
            && unit.generation <= manifest.generation
    }

    private func hydratePublishedManifestIfNeeded(
        for itemID: UUID,
        deadline: ContinuousClock.Instant
    ) async {
        guard publishedManifests[itemID] == nil,
            pending[itemID] == nil,
            failedPublications[itemID] == nil,
            failedDeletions.contains(itemID) == false,
            let item = registered[itemID],
            let spotlight else { return }
        let epoch = extractionEpochs[itemID, default: 0]
        let mutationRevision = spotlightMutationRevisions[itemID, default: 0]
        guard let loaded = await boundedInteractiveSpotlightValue(
            until: deadline,
            operation: {
                SpotlightManifestLoad(
                    manifest: await spotlight.loadManifest(itemID: itemID)
                )
            }
        ) else { return }
        guard let manifest = loaded.manifest else { return }
        let isBeforeDeadline = ContinuousClock().now < deadline
        let isCurrentSchema = manifest.isCurrentSchema
        let registrationMatches = manifest.registrationFingerprint
            == Self.registrationFingerprint(item)
        let generationIsCurrent = manifest.generation >= item.expectedGeneration
        let registrationIsCurrent = registered[itemID] == item
        let epochIsCurrent = extractionEpochs[itemID, default: 0] == epoch
        let mutationIsCurrent = spotlightMutationRevisions[itemID, default: 0]
            == mutationRevision
        let hasNoPendingMutation = pending[itemID] == nil
            && publishedManifests[itemID] == nil
            && failedPublications[itemID] == nil
            && failedDeletions.contains(itemID) == false
        guard isBeforeDeadline,
            isCurrentSchema,
            registrationMatches,
            generationIsCurrent,
            registrationIsCurrent,
            epochIsCurrent,
            mutationIsCurrent,
            hasNoPendingMutation else { return }
        publishedManifests[itemID] = manifest
        if manifests[itemID] == nil { manifests[itemID] = manifest }
    }

    /// Recovery readiness is scoped to one durable subject. Draining the
    /// process-wide deferred queue here could serially spend one full provider
    /// timeout on unrelated deletions and four publications before proving this
    /// notebook. One complete-domain replacement both removes any stale domain
    /// and publishes the recovered manifest under a single absolute deadline.
    private func retryFailedSpotlightMutation(
        for itemID: UUID,
        until deadline: ContinuousClock.Instant
    ) async {
        guard let spotlight,
            !Task.isCancelled,
            ContinuousClock().now < deadline else { return }

        if let proposal = failedPublications[itemID],
            registered[itemID] != nil,
            pending[itemID] == nil,
            manifests[itemID] == proposal.manifest {
            let revision = advanceSpotlightMutationRevision(for: itemID)
            let expectedRevision = [itemID: revision]
            let report = await spotlightMutationCoordinator.perform(
                domains: [itemID],
                until: deadline,
                shouldBegin: { [weak self] in
                    await self?.spotlightMutationsAreCurrent(
                        expectedRevision
                    ) ?? false
                },
                operation: {
                    await spotlight.replace(
                        itemID: itemID,
                        units: proposal.units,
                        manifest: proposal.manifest,
                        previousUnits: nil
                    )
                },
                onLateDrain: { [weak self] in
                    await self?.spotlightMutationDrainedLate(
                        revisions: expectedRevision
                    )
                }
            )
        guard spotlightMutationRevisions[itemID] == revision else { return }
        if failedPublications[itemID]?.manifest == proposal.manifest {
            protectedFailedPublicationIDs.remove(itemID)
        }
        if report.succeeded,
            manifests[itemID] == proposal.manifest {
            failedPublications.removeValue(forKey: itemID)
            failedDeletions.remove(itemID)
            publishedManifests[itemID] = proposal.manifest
            evictRecentSpotlightUnits(for: itemID)
            clearLateSpotlightDrainIfMatching(
                itemID: itemID,
                revision: revision
            )
        } else {
            publishedManifests.removeValue(forKey: itemID)
            consumeLateSpotlightDrainIfNeeded(
                itemID: itemID,
                revision: revision
            )
        }
        trimDeferredMutations()
        rebuildLibraryLexicalIndex()
        return
    }

    guard failedDeletions.contains(itemID) else { return }
    let revision = advanceSpotlightMutationRevision(for: itemID)
    let expectedRevision = [itemID: revision]
    let report = await spotlightMutationCoordinator.perform(
        domains: [itemID],
        until: deadline,
        shouldBegin: { [weak self] in
            await self?.spotlightMutationsAreCurrent(expectedRevision)
                ?? false
        },
        operation: {
            await spotlight.deleteDomains(for: [itemID])
        },
        onLateDrain: { [weak self] in
            await self?.spotlightMutationDrainedLate(
                revisions: expectedRevision
            )
        }
    )
    guard spotlightMutationRevisions[itemID] == revision else { return }
    publishedManifests.removeValue(forKey: itemID)
    if report.succeeded {
        failedDeletions.remove(itemID)
        clearLateSpotlightDrainIfMatching(
            itemID: itemID,
            revision: revision
        )
    } else {
        failedDeletions.insert(itemID)
        consumeLateSpotlightDrainIfNeeded(
            itemID: itemID,
            revision: revision
        )
    }
    trimDeferredMutations()
}

private func retryFailedSpotlightMutations() async {
    guard let spotlight else { return }
    if spotlightRetryInFlight {
        // The single owner re-snapshots deferred state after its current
        // provider batch. Merely awaiting that batch here can lose work
        // enqueued after the owner's original snapshot.
        spotlightRetryRequested = true
        return
    }
    spotlightRetryInFlight = true
    defer {
        spotlightRetryInFlight = false
        spotlightRetryRequested = false
    }

    while Task.isCancelled == false {
        spotlightRetryRequested = false
// A pending publication already owns this item's next Spotlight
// mutation. Reserving a later deletion retry here would invalidate
// its acknowledgement and then erase the newly published domain.
let deletionIDs = Array(
    failedDeletions
        .filter { pending[$0] == nil }
        .sorted(by: { $0.uuidString < $1.uuidString })
        .prefix(Self.maximumDeferredMutations)
)
let publications = failedPublications
    .filter {
        registered[$0.key] != nil
            && pending[$0.key] == nil
            && manifests[$0.key] == $0.value.manifest
    }
    .sorted {
        let leftProtected = protectedFailedPublicationIDs
            .contains($0.key)
        let rightProtected = protectedFailedPublicationIDs
            .contains($1.key)
        if leftProtected != rightProtected { return leftProtected }
        return $0.key.uuidString < $1.key.uuidString
    }
        .prefix(4)
guard !deletionIDs.isEmpty || !publications.isEmpty else { return }

let deletionMutations = deletionIDs.map { itemID in
    (
        itemID: itemID,
        revision: advanceSpotlightMutationRevision(for: itemID)
    )
}
let publicationMutations = publications.map { entry in
    (
        itemID: entry.key,
        proposal: entry.value,
        revision: advanceSpotlightMutationRevision(for: entry.key)
    )
}
let mutationCoordinator = spotlightMutationCoordinator
let mutationTimeout = spotlightMutationTimeout
let deletionDomains = Set(
    deletionMutations.map { $0.itemID }
)
let deletionRevisionMap = Dictionary(
    deletionMutations.map {
        ($0.itemID, $0.revision)
    },
    uniquingKeysWith: { current, _ in current }
)
let task = Task<SpotlightRetryOutcome, Never> { [weak self] in
    guard !Task.isCancelled else {
        return SpotlightRetryOutcome(
            deletionReport: deletionMutations.isEmpty
                ? nil
                : .cancelled,
            deletionMutations: deletionRevisionMap,
            publications: []
        )
    }
    let deletionReport: SpotlightMutationReport?
    if deletionMutations.isEmpty {
        deletionReport = nil
    } else {
        deletionReport = await mutationCoordinator.perform(
            domains: deletionDomains,
            until: ContinuousClock().now.advanced(
                by: mutationTimeout
            ),
            shouldBegin: { [weak self] in
                await self?.spotlightMutationsAreCurrent(
                    deletionRevisionMap
                ) ?? false
            },
            operation: {
                await spotlight.deleteDomains(
                    for: deletionMutations.map { $0.itemID }
                )
            },
            onLateDrain: { [weak self] in
                await self?.spotlightMutationDrainedLate(
                    revisions: deletionRevisionMap
                )
            }
        )
    }
    var publicationReports: [SpotlightRetryOutcome.Publication] = []
    for mutation in publicationMutations {
        guard !Task.isCancelled else { break }
        let itemID = mutation.itemID
        let expectedRevision = [itemID: mutation.revision]
        let report = await mutationCoordinator.perform(
            domains: [itemID],
            until: ContinuousClock().now.advanced(
                by: mutationTimeout
            ),
            shouldBegin: { [weak self] in
                await self?.spotlightMutationsAreCurrent(
                    expectedRevision
                ) ?? false
            },
            operation: {
                await spotlight.replace(
                    itemID: itemID,
                    units: mutation.proposal.units,
                    manifest: mutation.proposal.manifest,
                    previousUnits: nil
                )
            },
            onLateDrain: { [weak self] in
                await self?.spotlightMutationDrainedLate(
                    revisions: expectedRevision
                )
            }
        )
        publicationReports.append(
            .init(
                itemID: mutation.itemID,
                manifest: mutation.proposal.manifest,
                mutationRevision: mutation.revision,
                report: report
            )
        )
    }
    return SpotlightRetryOutcome(
        deletionReport: deletionReport,
        deletionMutations: deletionRevisionMap,
        publications: publicationReports
    )
}
let outcome = await task.value

if let deletionReport = outcome.deletionReport {
    for (itemID, revision) in outcome.deletionMutations
    where spotlightMutationRevisions[itemID] == revision {
        publishedManifests.removeValue(forKey: itemID)
        if deletionReport.succeeded {
            failedDeletions.remove(itemID)
            clearLateSpotlightDrainIfMatching(
                itemID: itemID,
                revision: revision
            )
        } else {
            failedDeletions.insert(itemID)
            consumeLateSpotlightDrainIfNeeded(
                itemID: itemID,
                revision: revision
            )
        }
    }
}
for publication in outcome.publications {
    guard spotlightMutationRevisions[publication.itemID]
        == publication.mutationRevision else { continue }
    if failedPublications[publication.itemID]?.manifest
        == publication.manifest {
        // Protection belongs to this exact first repair attempt.
        // A stale provider continuation must never consume the
        // protection installed by a newer same-item quarantine.
        protectedFailedPublicationIDs.remove(publication.itemID)
    }
    if publication.report.succeeded,
        manifests[publication.itemID] == publication.manifest {
        failedPublications.removeValue(forKey: publication.itemID)
        // Retry publications are complete-domain replacements. A
        // successful replacement supersedes any older deletion
        // tombstone for the same item.
        failedDeletions.remove(publication.itemID)
        publishedManifests[publication.itemID] = publication.manifest
        evictRecentSpotlightUnits(for: publication.itemID)
        clearLateSpotlightDrainIfMatching(
            itemID: publication.itemID,
                    revision: publication.mutationRevision
                )
            } else {
                publishedManifests.removeValue(forKey: publication.itemID)
                consumeLateSpotlightDrainIfNeeded(
                    itemID: publication.itemID,
                    revision: publication.mutationRevision
                )
            }
        }
    trimDeferredMutations()
    rebuildLibraryLexicalIndex()

    let providerMadeProgress = outcome.deletionReport?.succeeded == true
        || outcome.publications.contains(where: { $0.report.succeeded })
    let hasUnattemptedProtectedRepair = failedPublications.contains {
        protectedFailedPublicationIDs.contains($0.key)
            && registered[$0.key] != nil
            && pending[$0.key] == nil
            && manifests[$0.key] == $0.value.manifest
    }
    // A persistent provider failure remains queued and fail-closed,
    // but must not create a tight retry loop. Successful bounded
    // batches immediately drain overflow and any work enqueued while
    // this owner was suspended.
    if providerMadeProgress == false {
        // One fresh snapshot consumes a wakeup that arrived while the
        // provider was suspended. If that batch also fails without a
        // newer wakeup, the next iteration stops instead of spinning.
        guard spotlightRetryRequested || hasUnattemptedProtectedRepair else {
            return
        }
    }
    await Task.yield()
    }
}

private func trimDeferredMutations() {
    while failedPublications.count > Self.maximumDeferredPublicationItems
        || failedPublications.values.reduce(0, { $0 + $1.units.count })
        > Self.maximumDeferredPublicationUnits {
        let candidates = failedPublications.keys
            .filter { protectedFailedPublicationIDs.contains($0) == false }
            .sorted(by: {
                let leftCount = failedPublications[$0]?.units.count ?? 0
                let rightCount = failedPublications[$1]?.units.count ?? 0
                if leftCount != rightCount { return leftCount > rightCount }
                return $0.uuidString > $1.uuidString
            })
        guard let key = candidates.first,
        let removed = failedPublications.removeValue(forKey: key) else { break }
        // Dropping a memory-heavy full repair must retain a fail-closed
        // marker and a bounded physical cleanup path. Otherwise manifest
        // hydration could accept the uncertain provider domain after this
        // proposal is evicted from memory.
        failedDeletions.insert(key)
        protectedFailedPublicationIDs.remove(key)
        if manifests[key] == removed.manifest { manifests.removeValue(forKey: key) }
        removeCachedIndex(key)
    }
    // Keep every fail-closed tombstone until its physical deletion or a
    // newer complete replacement succeeds. Retry work is batch-bounded;
    // truncating this compact UUID set would instead let an uncertain
    // on-disk manifest hydrate and become searchable again
    }
    private func canProtectFailedPublication(
    _ proposal: SpotlightRetryProposal,
    itemID: UUID
) -> Bool {
    // Repair state is volatile, so stale protection keys have no value and
    // must not consume the hard admission ceiling forever.
    let protectedFailedPublicationsCount = protectedFailedPublicationIDs.count
        + (protectedFailedPublicationIDs.contains(itemID) ? 0 : 1)
    guard protectedFailedPublicationsCount <= Self.maximumDeferredPublicationItems else {
        return false
    }

    var protectedUnitCount = 0
    for protectedID in protectedFailedPublicationIDs where protectedID != itemID {
        guard let retained = failedPublications[protectedID],
            retained.units.count
            <= Self.maximumDeferredPublicationUnits - protectedUnitCount else {
            return false
        }
        protectedUnitCount += retained.units.count
    }
    return proposal.units.count
        <= Self.maximumDeferredPublicationUnits - protectedUnitCount
}

private func candidates(scope: AssistantScope, focused: UUID?) -> [UUID] {
    switch scope {
    case .page, .item:
        if let focused {
            return [focused]
        }
        let available = Set(registered.keys).union(indexes.keys).union(pending.keys)
        return available.count == 1 ? Array(available) : []
    case .library:
        #if DEBUG
        LibraryRegisteredItemEnumerationsForTesting += registered.count
        #endif
        return Set(registered.keys)
            .union(indexes.keys)
            .union(pending.keys)
            .sorted { $0.uuidString < $1.uuidString }
    }
}

private func result(
    _ unit: Unit,
    terms: [String],
    score: Double,
    catalogAuthority: Bool = false
) -> AssistantSearchResult {
    let effectiveCatalogGeneration = if catalogAuthority {
        effectiveCatalogGeneration(for: unit)
    } else {
        max(
            effectiveCatalogGeneration(for: unit),
            publishedManifests[unit.itemID]?.generation ?? 0,
            visibleLocalIndex(for: unit.itemID)?.generation ?? 0
        )
    }

return AssistantSearchResult(
    anchor: AssistantSourceAnchor(
        id: unit.id,
        itemID: unit.itemID,
        pageID: unit.pageID,
        blockID: unit.blockID,
        itemName: currentName(unit),
        pageNumber: unit.pageNumber,
        kind: unit.kind,
        pageBounds: unit.pageBounds,
        generation: effectiveCatalogGeneration,
        contentHash: unit.contentHash,
        snippet: SearchText.snippet(unit.text, matching: terms)
    ),
    fullText: unit.text,
    score: score
)
}

private func currentName(_ unit: Unit) -> String { registered[unit.itemID]?.itemName ?? unit.itemName }

private func effectiveCatalogGeneration(for unit: Unit) -> Int64 {
    max(
        unit.generation,
        catalogCertifiedGenerations[unit.itemID] ?? 0
    )
}

private func visibleLocalIndex(for itemID: UUID) -> ItemIndex? {
    if let pending = pendingItems[itemID] {
        if pending.isSearchSuppressed == false { return pending.index }
        // A timed-out derived proposal may be the only in-memory owner of
        // the pre-enrichment domain after normal hot-cache eviction. Keep
        // that separately captured authority visible while OCR is hidden.
        if let repairProposal = pending.repairProposal {
            return repairProposal
        }
    }

    if let index = indexes[itemID] { return index }

    // A rejected late provider write can evict the ordinary hot base just
    // before its complete-domain repair begins. The exact retained repair
    // proposal is still valid local authored authority during that retry;
    // keep it searchable while every uncertain Spotlight byte remains
    if let repair = failedPublications[itemID],
        manifests[itemID] == repair.manifest,
        proposalMatchesCurrentRegistration(repair, itemID: itemID) {
            return repair
        }
        return nil
    }

    private func exactUnit(_ id: String) -> Unit? {
        let itemIDs = Set(indexes.keys)
            .union(pending.keys)
            .union(failedPublications.keys)
            .sorted { $0.uuidString < $1.uuidString }
        for itemID in itemIDs {
            guard let index = visibleLocalIndex(for: itemID) else { continue }
            if let unit = index.byID[id] {
                if indexes[itemID] != nil { touchIndex(itemID) }
                return unit
            }
        }
        if let unit = recentSpotlightUnits[id] {
            recentSpotlightRecency.removeAll { $0 == id }
            recentSpotlightRecency.append(id)
            return unit
        }
        if let unit = catalogLexicalIndex.unit(id: id) { return unit }
        return nil
    }

    private func isCurrentLocalUnit(_ unit: Unit) -> Bool {
        if let index = visibleLocalIndex(for: unit.itemID),
            let current = index.byID[unit.id] {
            if let item = registered[unit.itemID],
                index.generation < item.expectedGeneration {
                return false
            }
            return current.contentHash == unit.contentHash
                && current.pageNumber == unit.pageNumber
                && current.pageBounds == unit.pageBounds
        }
        guard let current = catalogLexicalIndex.unit(id: unit.id),
            let item = registered[unit.itemID],
            effectiveCatalogGeneration(for: current)
            >= item.expectedGeneration else { return false }
        return current.itemID == unit.itemID
            && current.itemName == unit.itemName
            && current.generation >= unit.generation
            && current.contentHash == unit.contentHash
            && current.text == unit.text
    }

    private nonisolated static func registrationFingerprint(
        _ item: AssistantIndexedItem
    ) -> String {
        SearchText.hashComponents([
            item.itemID.uuidString.lowercased(),
            item.itemName,
            item.kind.rawValue,
            item.parentID?.uuidString.lowercased() ?? "root",
            item.canvasDirectory.path,
            item.requiresVerifiedRecovery ? "recovery" : "current",
        ])
    }

    /// Full registration bytes that can affect foreground retrieval. This is
    /// deliberately stronger than the compact registration fingerprint: it
        /// also covers the verified generation and catalog fallback projection.
        private nonisolated static func registrationSourceFingerprint(
            _ item: AssistantIndexedItem,
            catalogProjectionFingerprint: String
        ) -> String {
            SearchText.hashComponents([
        registrationFingerprint(item),
        String(item.expectedGeneration),
        catalogProjectionFingerprint
    ])
}
private static func registrationChanged(_ lhs: AssistantIndexedItem, _ rhs: AssistantIndexedItem) -> Bool {
    lhs.itemName != rhs.itemName || lhs.kind != rhs.kind || lhs.parentID
        || lhs.canvasDirectory != rhs.canvasDirectory || lhs.requiresVerifiedRecovery
}

/// A catalog snapshot can lag the verified editor checkpoint while
/// thumbnail metadata catches up. Never let that stale snapshot lower the
/// generation or searchable fallback already registered for the same
/// content store.
private static func nonRegressionRegistration(
    _ proposed: AssistantIndexedItem,
    previous: AssistantIndexedItem
) -> AssistantIndexedItem {
    guard isRegistrationRegression(proposed, previous: previous)
    else { return proposed }
    return previous
}



    private static func isRegistrationRegression(
        _ proposed: AssistantIndexedItem,
        previous: AssistantIndexedItem?
    ) -> Bool {
        guard let previous else { return false }
        return previous.canvasDirectory == proposed.canvasDirectory
            && previous.expectedGeneration > proposed.expectedGeneration
    }
/// identity/freshness metadata so importing many large PDFs cannot pin a
/// second copy of their extracted text for the process lifetime.
private static func compactRegistration(
    _ item: AssistantIndexedItem
) -> AssistantIndexedItem {
    AssistantIndexedItem(
        itemID: item.itemID,
        itemName: item.itemName,
        kind: item.kind,
        parentID: item.parentID,
        canvasDirectory: item.canvasDirectory,
        fallbackSearchableText: "",
        expectedGeneration: item.expectedGeneration,
        requiresVerifiedRecovery: item.requiresVerifiedRecovery
    )
}


private static func includes(_ unit: Unit, scope: AssistantScope, pageID: UUID?) -> Bool {
    guard scope == .page else { return true }
    return pageID == nil || unit.pageID == pageID
}

private nonisolated static func stableOrder(
    _ lhs: Unit,
    _ rhs: Unit
) -> Bool {
    if lhs.pageNumber != rhs.pageNumber { return (lhs.pageNumber ?? .max) < (rhs.pageNumber ?? .max) }
    if lhs.kind != rhs.kind { return lhs.kind.rawValue < rhs.kind.rawValue }
    let lhsBlock = lhs.blockID?.uuidString ?? ""
    let rhsBlock = rhs.blockID?.uuidString ?? ""
    if lhsBlock != rhsBlock { return lhsBlock < rhsBlock }
    if lhs.chunkOrdinal != rhs.chunkOrdinal { return lhs.chunkOrdinal < rhs.chunkOrdinal }
    if lhs.chunkOrdinal != rhs.chunkOrdinal { return lhs.chunkOrdinal < rhs.chunkOrdinal }
    return lhs.id < rhs.id
}

private static func ranksBefore(_ lhs: AssistantSearchResult, _ rhs: AssistantSearchResult) -> Bool {
    if abs(lhs.score - rhs.score) > 0.000_001 { return lhs.score > rhs.score }
    if name != .orderedSame { return name == .orderedAscending }
    if lhs.anchor.pageNumber != rhs.anchor.pageNumber {
        return (lhs.anchor.pageNumber ?? .max) < (rhs.anchor.pageNumber ?? .max)
    }
    return lhs.id < rhs.id
}

/// Reciprocal-rank fusion combines the independent lexical and semantic
/// orderings without pretending their score scales are comparable. A hit
/// supported by both tiers naturally outranks a high value from only one;
/// the lexical tier receives a small preference because it represents the
/// newest verified in-memory generation.
static func fuseRankedResults(
    lexical: [AssistantSearchResult],
    semantic: [AssistantSearchResult],
    rankConstant: Double = 60
) -> [AssistantSearchResult] {
    let rankConstant = max(rankConstant, 1)
    var representatives: [String: AssistantSearchResult] = [:]
    var fusedScores: [String: Double] = [:]

    func accumulate(
        _ values: [AssistantSearchResult],
        weight: Double,
        preferAsRepresentative: Bool
    ) {
        var seen = Set<String>()
        for (rank, value) in values.enumerated()
            where seen.insert(value.id).inserted {
            if preferAsRepresentative || representatives[value.id] == nil {
                representatives[value.id] = value
            }
            fusedScores[value.id, default: 0] += weight
                / (rankConstant + Double(rank + 1))
        }
    }

    accumulate(lexical, weight: 1.05, preferAsRepresentative: true)
    accumulate(semantic, weight: 1, preferAsRepresentative: false)

    return fusedScores.compactMap { id, score in
        representatives[id].map {
            AssistantSearchResult(
                anchor: $0.anchor,
                fullText: $0.fullText,
                score: score
            )
        }
    }.sorted(by: ranksBefore)
}

private static func rankedUnique(
    _ values: [AssistantSearchResult]
) -> [AssistantSearchResult] {
    var seen = Set<String>()
    return values.filter { seen.insert($0.id).inserted }
}

/// Removes duplicate representations after rank fusion for every scope.
/// Item-level metadata is routing data, not a second factual passage, so
/// it is suppressed whenever the same item also has substantive evidence.
/// Exact copies are collapsed within an item even when OCR and page text
/// gave them different locator IDs. The pairwise overlap check remains
/// bounded by the already-capped retrieval tiers.
private static func deduplicatedCandidates(
    _ ranked: [AssistantSearchResult]
) -> [AssistantSearchResult] {
    let itemsWithSubstantiveEvidence = Set(
        ranked.lazy
            .filter { $0.anchor.kind != .metadata }
            .map { $0.anchor.itemID }
    )
    var chosen: [AssistantSearchResult] = []
    var ids = Set<String>()
    var evidenceKeys = Set<EvidenceKey>()
    for candidate in ranked {
        guard candidate.anchor.kind != .metadata
            || itemsWithSubstantiveEvidence.contains(candidate.anchor.itemID) == false,
            ids.insert(candidate.id).inserted else { continue }
        let evidenceKey = EvidenceKey(
            itemID: candidate.anchor.itemID,
            canonicalText: SearchText.postingTerms(candidate.fullText)
                .joined(separator: " ")
        )
        if evidenceKey.canonicalText.isEmpty == false,
            evidenceKeys.insert(evidenceKey).inserted == false {
            continue
        }
        let overlapsExisting = chosen.contains { existing in
            guard existing.anchor.itemID == candidate.anchor.itemID,
                existing.anchor.pageID == candidate.anchor.pageID else { return false }
            let existingTerms = Set(SearchText.postingTerms(existing.fullText))
            let candidateTerms = Set(SearchText.postingTerms(candidate.fullText))
            let smallerCount = min(existingTerms.count, candidateTerms.count)
            guard smallerCount >= 8 else { return false }
            let sharedCount = existingTerms.intersection(candidateTerms).count
            return Double(sharedCount) / Double(smallerCount) >= 0.82
        }
        if !overlapsExisting { chosen.append(candidate) }
    }
    return chosen
return chosen
}

private struct EvidenceKey: Hashable {
let itemID: UUID
let canonicalText: String
}

static func selectLibraryEvidence(
from ranked: [AssistantSearchResult],
limit: Int = AssistantLibraryEvidence.maximumPassageCount
) -> [AssistantSearchResult] {
let limit = min(max(limit, 0), AssistantLibraryEvidence.maximumPassageCount)
guard limit > 0 else { return [] }
let ranked = deduplicatedCandidates(ranked)
var chosen: [AssistantSearchResult] = []
var chosenIDs = Set<String>()
var notebooks = Set<UUID>()
var pageCounts: [String: Int] = [:]

func pageKey(_ value: AssistantSearchResult) -> String {
"\(value.anchor.itemID.uuidString)|\(value.anchor.pageID?.uuidString ?? "item")"
}

func canAppend(_ value: AssistantSearchResult) -> Bool {
chosenIDs.contains(value.id) == false
	&& pageCounts[pageKey(value), default: 0]
		< AssistantLibraryEvidence.maximumPassagesPerPage
}

func append(_ value: AssistantSearchResult) {
chosen.append(value)
chosenIDs.insert(value.id)
notebooks.insert(value.anchor.itemID)
pageCounts[pageKey(value), default: 0] += 1
}

// Establish document diversity before filling remaining slots from
// the three highest-ranked notebooks.
for value in ranked {
guard chosen.count < limit else { return chosen }
guard notebooks.contains(value.anchor.itemID) == false,
notebooks.count < AssistantLibraryEvidence.maximumNotebookCount,
canAppend(value) else { continue }
append(value)
}

for value in ranked {
guard chosen.count < limit else { break }
guard notebooks.contains(value.anchor.itemID), canAppend(value) else { continue }
append(value)
}
return chosen
}

private static func diversify(
_ranked: [AssistantSearchResult], scope: AssistantScope, limit: Int
) -> [AssistantSearchResult] {
guard scope == .item || scope == .library else { return Array(ranked.prefix(limit)) }
var chosen: [AssistantSearchResult] = []
var ids = Set<String>()
var pages: [String: Int] = [:]
var items: [UUID: Int] = [:]
for value in ranked {
let page = "\(value.anchor.itemID)|\(value.anchor.pageID?.uuidString ?? "item")"
guard pages[page, default: 0] < 2,
scope != .library || items[value.anchor.itemID, default: 0] < 3 else { continue }
chosen.append(value); ids.insert(value.id)
pages[page, default: 0] += 1; items[value.anchor.itemID, default: 0] += 1
if chosen.count == limit { return chosen }
}
for value in ranked where ids.insert(value.id).inserted {
chosen.append(value)
if chosen.count == limit { break }
}
return chosen
}

private nonisolated static func extract(
snapshot: CanvasCoreSnapshot,
item: AssistantIndexedItem,
pageIDs: Set<UUID>? = nil
) async -> [Unit]? {
let extractionID = UUID()
guard await NotebookRawExtractionArbiter.shared.reserve(
itemID: item.itemID,
ownerID: extractionID
) else {
return nil
}
// `PaperMarkup.indexableContent` is framework-owned and may
// acknowledge cancellation late. Keep the reservation until this raw
// extraction actually unwinds, so repeated assistant prompts cannot
// pile up retained page strings for one note or across the process.
let result = await extractWhileHoldingRawReservation(
snapshot: snapshot,
item: item,
pageIDs: pageIDs
)
await NotebookRawExtractionArbiter.shared.release(
itemID: item.itemID,
ownerID: extractionID
)
return result
}

private nonisolated static func extractWhileHoldingRawReservation(
snapshot: CanvasCoreSnapshot,
item: AssistantIndexedItem,
pageIDs: Set<UUID>?
) async -> [Unit]? {
let selectedPages = pageIDs.map { ids in
snapshot.pages.filter { ids.contains($0.id) }
} ?? snapshot.pages
var units: [Unit] = []
// Imported pages normally share one PDF. Retain only the most recent
// document so a malformed/interleaved snapshot cannot keep every
// PDFKit decode graph alive for the whole extraction pass.
var cachedPDFDocument: (key: String, document: PDFDocument)?
var remainingTextByteCount = maximumIndexedSourceTextUTF8ByteCount
let pageNumbers = Dictionary(
snapshot.pages.enumerated().map {
($0.element.id, $0.offset + 1)
},
uniquingKeysWith: { current, _ in current }
)
for page in selectedPages {
guard !Task.isCancelled else { return nil }
guard let pageNumber = pageNumbers[page.id] else { continue }
let bounds = page.displaySize.width > 0 && page.displaySize.height > 0
? CGRect(origin: .zero, size: page.displaySize) : nil
guard let authoredText = await CanvasBoundedPaperTextExtractor.text(
from: page.markup,
maximumUTF8ByteCount: remainingTextByteCount
) else {
return nil
}
guard !Task.isCancelled else { return nil }
if authoredText.contains(where: { $0.isWhitespace == false }) {
let byteCount = authoredText.utf8.count
guard byteCount <= remainingTextByteCount else { return nil }
remainingTextByteCount -= byteCount
units.append(Unit(itemID: item.itemID, itemName: item.itemName, pageID: page.id,
pageNumber: pageNumber, kind: .paperKitText, pageBounds: bounds,
generation: snapshot.generation, text: authoredText))
}
if case let .pdfPage(source, pageIndex, _) = page.background,
let data = source.documentData {
let sourceKey = source.contentChecksum ?? source.relativePath
let document: PDFDocument?
if cachedPDFDocument?.key == sourceKey {
document = cachedPDFDocument?.document
} else {
document = PDFDocument(data: data)
if let document {
cachedPDFDocument = (sourceKey, document)
} else {
cachedPDFDocument = nil
}
}
if let document,
pageIndex >= 0,
pageIndex < document.pageCount,
let pdfPage = document.page(at: pageIndex) {
let characterCount = pdfPage.numberOfCharacters
guard characterCount >= 0,
characterCount <= remainingTextByteCount else {
return nil
}
guard let text = pdfPage.string,
text.contains(where: { $0.isWhitespace == false }) else {
continue
}
let byteCount = text.utf8.count
guard byteCount <= remainingTextByteCount else { return nil }
remainingTextByteCount -= byteCount
units.append(Unit(itemID: item.itemID, itemName: item.itemName, pageID: page.id,
pageNumber: pageNumber, kind: .pdfText, pageBounds: bounds,
generation: snapshot.generation, text: text))
}
}
}
return units
}

private nonisolated static func fallback(
_ item: AssistantIndexedItem,
_ generation: Int64,
includesDerivedText: Bool = true
) -> [Unit] {
var fields: [String] = []
var remainingBytes = maximumIndexedSourceTextUTF8ByteCount
for candidate in includesDerivedText
? [item.itemName, item.fallbackSearchableText]
: [item.itemName] {
guard candidate.contains(where: { $0.isWhitespace == false }) else {
continue
}
let separatorBytes = fields.isEmpty ? 0 : 1
let candidateBytes = candidate.utf8.count
guard separatorBytes <= remainingBytes,
candidateBytes <= remainingBytes - separatorBytes else {
// Derived fallback is optional recovery evidence. Retain any
// already-admitted title instead of copying an oversized body.
continue
}
remainingBytes -= separatorBytes + candidateBytes
fields.append(candidate)
}
let text = fields.joined(separator: "\n")
guard text.isEmpty == false else { return [] }
return [Unit(itemID: item.itemID, itemName: item.itemName, pageID: nil, pageNumber: nil,
kind: .metadata, pageBounds: nil, generation: generation, text: text)]
}

private nonisolated static func includingMetadata(
in extracted: [Unit],
item: AssistantIndexedItem,
generation: Int64
) -> [Unit] {
// Derived fallback text is a recovery source for items with no
// page-level extraction. Storing it beside real page units duplicates
// the whole document and can surface one handwritten phrase as several
// references. A title-only record still supports notebook discovery.
extracted + fallback(
item,
generation,
includesDerivedText: extracted.isEmpty
)
}

private nonisolated static func expand(
_ units: [Unit],
for itemID: UUID,
generation: Int64
) -> [Unit]? {
struct Locator: Hashable {
let item: UUID
let page: UUID?
let block: UUID?
let kind: AssistantSourceKind
}
guard units.count <= maximumSingleCachedUnits else { return nil }
var selectedUnits: [Unit] = []
selectedUnits.reserveCapacity(units.count)
for unit in units where unit.itemID == itemID {
guard selectedUnits.count < maximumSingleCachedUnits,
isIndexableItemName(unit.itemName) else { return nil }
selectedUnits.append(unit)
}
var ordinals: [Locator: Int] = [:]
var result: [Unit] = []
var remainingSourceTextBytes = maximumExpandedTextUTF8ByteCount
var remainingExpandedTextBytes = maximumExpandedTextUTF8ByteCount
for unit in selectedUnits.sorted(by: stableOrder) {
guard !Task.isCancelled else { return nil }
let textByteCount = unit.text.utf8.count
guard textByteCount <= remainingSourceTextBytes else { return nil }
remainingSourceTextBytes -= textByteCount
let key = Locator(item: unit.itemID, page: unit.pageID, block: unit.blockID, kind: unit.kind)
var ordinal = ordinals[key, default: 0]
guard let chunks = SearchText.chunks(
unit.text,
maximum: maximumChunkLength,
overlap: chunkOverlapLength,
maximumCount: maximumSingleCachedUnits - result.count,
maximumUTF8Bytes: remainingExpandedTextBytes
) else { return nil }
for chunk in chunks {
let chunkByteCount = chunk.utf8.count
guard chunkByteCount <= remainingExpandedTextBytes else {
return nil
}
remainingExpandedTextBytes -= chunkByteCount
result.append(unit.replacing(generation: generation, ordinal: ordinal, text: chunk))
ordinal += 1
}
ordinals[key] = ordinal
}
return result.sorted(by: stableOrder)
}
}

struct IndexManifest: Codable, Equatable, Sendable {
// Version 7 stamps every Spotlight chunk with the exact manifest that
// authorized it. Rebuild older domains so a late same-generation write
// cannot be accepted under the previously published base manifest.
static let currentSchemaVersion = 7

let schemaVersion: Int
let generation: Int64
let fingerprint: String
let unitCount: Int
let registrationFingerprint: String?

init(
generation: Int64,
fingerprint: String,
unitCount: Int,
registrationFingerprint: String?
) {
schemaVersion = Self.currentSchemaVersion
self.generation = max(generation, 0)
self.fingerprint = fingerprint
self.unitCount = max(unitCount, 0)
self.registrationFingerprint = registrationFingerprint
}

var isCurrentSchema: Bool { schemaVersion == Self.currentSchemaVersion }
}

private extension String {
var nonblank: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}

private struct SpotlightChunkMetadata: Codable, Sendable {
let itemID: UUID
let itemName: String
let pageID: UUID?
let blockID: UUID?
let pageNumber: Int?
let kind: AssistantSourceKind
let pageBounds: CGRect?
let generation: Int64
let ordinal: Int
let contentHash: String
let manifestFingerprint: String
/// `textContent` is searchable but isn't guaranteed to be returned by all
/// Spotlight query paths. Keep the already-bounded chunk in protected,
/// non-searchable custom metadata for exact source hydration.
let text: String

init(_ unit: NotebookIndex.Unit, manifestFingerprint: String) {
itemID = unit.itemID; itemName = unit.itemName; pageID = unit.pageID
blockID = unit.blockID
pageNumber = unit.pageNumber; kind = unit.kind; pageBounds = unit.pageBounds
generation = unit.generation; ordinal = unit.chunkOrdinal; contentHash = unit.contentHash
self.manifestFingerprint = manifestFingerprint
text = unit.text
}

var isWithinBounds: Bool {
itemName.utf8.count <= NotebookIndex.maximumIndexedItemNameUTF8ByteCount
&& text.utf8.count <= NotebookIndex.maximumChunkUTF8ByteCount
&& contentHash.utf8.count <= 128
&& manifestFingerprint.utf8.count <= 128
}

func unit() -> NotebookIndex.Unit {
NotebookIndex.Unit(
itemID: itemID,
itemName: itemName,
pageID: pageID,
blockID: blockID,
pageNumber: pageNumber,
kind: kind,
pageBounds: pageBounds,
generation: generation,
chunkOrdinal: ordinal,
contentHash: contentHash,
text: text,
spotlightManifestFingerprint: manifestFingerprint
)
}
}

private struct SpotlightManifestLoad: Sendable {
let manifest: IndexManifest?
}

struct SpotlightMutationReport: Sendable {
let succeeded: Bool
let attempts: Int
let errorDescription: String?

static let success = SpotlightMutationReport(
succeeded: true,
attempts: 0,
errorDescription: nil
)
static let cancelled = SpotlightMutationReport(
succeeded: false,
attempts: 0,
errorDescription: "cancelled"
)
static let timedOut = SpotlightMutationReport(
succeeded: false,
attempts: 0,
errorDescription: "timed out"
)
static let superseded = SpotlightMutationReport(
succeeded: false,
attempts: 0,
errorDescription: "superseded"
)
}

/// Reserves only the item domains touched by one Core Spotlight mutation. The
/// visible waiter is deadline-bounded, while a cancellation-resistant provider
/// keeps its domains guaranteed until its raw task actually drains. Operations
/// on disjoint notebooks remain independent.
private actor SpotlightDomainMutationCoordinator {
private var domainOwners: [UUID: UUID] = [:]
private var availabilityWaiters: [
UUID: CheckedContinuation<Bool, Never>
] = [:]

func perform(
domains: Set<UUID>,
until deadline: ContinuousClock.Instant,
shouldBegin: @escaping @Sendable () async -> Bool,
operation: @escaping @Sendable () async -> SpotlightMutationReport,
onLateDrain: @escaping @Sendable () async -> Void
) async -> SpotlightMutationReport {
guard domains.isEmpty == false else { return .success }
guard let operationID = await reserve(domains, until: deadline) else {
return Task.isCancelled ? .cancelled : .timedOut
}

// Reservation makes this mutation the domain's logical owner. Recheck
// its actor-owned revision only now: a stale waiter that wakes after a
// newer delete/publication must release without touching the provider,
// while any newer mutation arriving after this check queues behind the
// already-owned domain and therefore runs physically last.
guard await shouldBegin() else {
release(operationID: operationID, domains: domains)
return Task.isCancelled ? .cancelled : .superseded
}
guard Task.isCancelled == false,
ContinuousClock().now < deadline else {
release(operationID: operationID, domains: domains)
return Task.isCancelled ? .cancelled : .timedOut
}

let rawTask = Task { await operation() }
let drain = Task { [weak self] in
_ = await rawTask.value
await self?.release(operationID: operationID, domains: domains)
}
let outcome = await assistantImageTaskOutcome(
of: rawTask,
until: deadline
)
switch outcome {
case let .value(report):
release(operationID: operationID, domains: domains)
drain.cancel()
return report
case .cancelled:
Task {
await drain.value
await onLateDrain()
}
return .cancelled
case .timedOut:
Task {
await drain.value
await onLateDrain()
}
return .timedOut
}
}

private func reserve(
        domains: Set<UUID>,
        until deadline: ContinuousClock.Instant
    ) async -> UUID? {
        let clock = ContinuousClock()
        while domains.contains(where: { domainOwners[$0] != nil }) {
            guard Task.isCancelled == false,
                clock.now < deadline,
                await waitForAvailabilityChange(until: deadline) else {
                return nil
            }
        }
        guard Task.isCancelled == false, clock.now < deadline else { return nil }
        let operationID = UUID()
        for domain in domains { domainOwners[domain] = operationID }
        return operationID
    }
    private func waitForAvailabilityChange(
        until deadline: ContinuousClock.Instant
    ) async -> Bool {
        guard Task.isCancelled == false,
            ContinuousClock().now < deadline else { return false }
        let waiterID = UUID()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard Task.isCancelled == false else {
                    continuation.resume(returning: false)
                    return
                }
                availabilityWaiters[waiterID] = continuation
                Task { [weak self] in
                    do {
                        try await ContinuousClock().sleep(until: deadline)
                    } catch {
                        return
                    }
                    await self?.resolveAvailabilityWaiter(
                        waiterID,
                        value: false
                    )
                }
            }
        } onCancel: {
            Task { [weak self] in
                await self?.resolveAvailabilityWaiter(waiterID, value: false)
            }
        }
    }
    private func release(operationID: UUID, domains: Set<UUID>) {
        for domain in domains where domainOwners[domain] == operationID {
            domainOwners.removeValue(forKey: domain)
        }
        for domain in domains where domainOwners[domain] == operationID {
            domainOwners.removeValue(forKey: domain)
        }
        let waiters = Array(availabilityWaiters.values)
        for waiter in waiters { waiter.resume(returning: true) }
    }

    private func resolveAvailabilityWaiter(_ waiterID: UUID, value: Bool) {
        availabilityWaiters.removeValue(forKey: waiterID)?.resume(
            returning: value
        )
    }
}

private actor SpotlightInteractiveReadLane {
    private var isOccupied = false

    func tryAcquire() -> Bool {
        guard isOccupied == false else { return false }
        isOccupied = true
        return true
    }

    func release() {
        isOccupied = false
    }

    #if DEBUG
    func isOccupiedForTesting() -> Bool {
        isOccupied
    }
    #endif
}

private actor ColdHydrationLane {
    private var owners: [UUID: UUID] = [:]

    func tryAcquire(itemID: UUID) -> UUID? {
        guard owners[itemID] == nil else { return nil }
        let hydrationID = UUID()
        owners[itemID] = hydrationID
        return hydrationID
    }

    func release(itemID: UUID, hydrationID: UUID) {
        guard owners[itemID] == hydrationID else { return }
        owners.removeValue(forKey: itemID)
    }

    #if DEBUG
    func isOccupied(itemID: UUID) -> Bool {
        owners[itemID] != nil
    }
    #endif
}

private struct NotebookSnapshotHydrationReservation: Hashable, Sendable {
    let itemID: UUID
    let ownerID: UUID
}

/// A process-wide lease for a snapshot reopened by the assistant. The lease is
/// deliberately reference-counted by Swift: if indexing hands the snapshot to
/// a detached Vision worker, that worker captures this same object and the
/// global permit is released only after the final snapshot-owning scope exits.
final class NotebookSnapshotHydrationLease: @unchecked Sendable {
    fileprivate let reservation: NotebookSnapshotHydrationReservation

    fileprivate init(reservation: NotebookSnapshotHydrationReservation) {
        self.reservation = reservation
    }

    deinit {
        let reservation = reservation
        Task {
            await NotebookSnapshotHydrationArbiter.shared.release(reservation)
        }
    }
}

/// Canvas Core accepts individually bounded documents that can still occupy
/// substantial memory while decoded. Cap assistant-owned cold loads across
/// NotebookIndex instances/scenes, while leaving one independent notebook able
/// to make progress when another framework callback ignores cancellation.
private actor NotebookSnapshotHydrationArbiter {
    static let shared = NotebookSnapshotHydrationArbiter()

    private static let maximumConcurrentOwners = 2
    private var owners: [UUID: NotebookSnapshotHydrationReservation] = [:]
    private var releaseWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    func tryAcquire(itemID: UUID) -> NotebookSnapshotHydrationLease? {
        guard owners[itemID] == nil,
            owners.count < Self.maximumConcurrentOwners else { return nil }
        let reservation = NotebookSnapshotHydrationReservation(
            itemID: itemID,
            ownerID: UUID()
        )
        owners[itemID] = reservation
        return NotebookSnapshotHydrationLease(reservation: reservation)
    }

    func release(_ reservation: NotebookSnapshotHydrationReservation) {
        guard owners[reservation.itemID] == reservation else { return }
        owners.removeValue(forKey: reservation.itemID)
        let waiters = releaseWaiters.removeValue(forKey: reservation.itemID) ?? []
        for waiter in waiters { waiter.resume() }
    }

    func waitUntilReleased(itemID: UUID) async {
        guard owners[itemID] != nil else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters[itemID, default: []].append(continuation)
        }
    }
}

/// Caps framework-owned PaperKit text extraction that can outlive a cancelled
/// request. The per-item fence prevents repeated prompts for one notebook from
/// accumulating work; the process ceiling also bounds simultaneous large
/// strings when multiple scenes request different notebooks.
private actor NotebookRawExtractionArbiter {
    static let shared = NotebookRawExtractionArbiter()

    private static let maximumConcurrentOwners = 2
    private static let maximumQueuedOwners = 4
    private static let maximumQueuedOwnersPerItem = 2

    private struct Waiter {
        let ownerID: UUID
        let continuation: CheckedContinuation<Void, Never>
    }

    private var itemOwners: [UUID: UUID] = [:]
    private var owners = Set<UUID>()
    private var waiters: [UUID: [Waiter]] = [:]
    private var queuedOwnerCount = 0

    func reserve(itemID: UUID, ownerID: UUID) async -> Bool {
        if itemOwners[itemID] == nil,
            owners.count < Self.maximumConcurrentOwners {
            itemOwners[itemID] = ownerID
            owners.insert(ownerID)
            return true
        }
        // A few same-notebook foreground requests may legitimately join one
        // publication. Queue only behind that notebook's active extraction,
        // with fixed per-item and process caps; unrelated overload fails fast
        // and no unbounded collection of snapshots can accumulate.
        guard itemOwners[itemID] != nil,
            waiters[itemID, default: []].count
            < Self.maximumQueuedOwnersPerItem,
            queuedOwnerCount < Self.maximumQueuedOwners else {
            return false
        }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard Task.isCancelled == false else {
                    continuation.resume(returning: false)
                    return
                }
                waiters[itemID, default: []].append(
                    Waiter(ownerID: ownerID, continuation: continuation)
                )
                queuedOwnerCount += 1
            }
        } onCancel: {
            Task {
                await self.cancelWaiter(itemID: itemID, ownerID: ownerID)
            }
        }
    }

    func release(itemID: UUID, ownerID: UUID) {
        guard itemOwners[itemID] == ownerID else { return }
        owners.remove(ownerID)
        if var itemWaiters = waiters[itemID], itemWaiters.isEmpty == false {
            let next = itemWaiters.removeFirst()
            queuedOwnerCount -= 1
            if itemWaiters.isEmpty {
                waiters.removeValue(forKey: itemID)
            } else {
                waiters[itemID] = itemWaiters
            }
            itemOwners[itemID] = next.ownerID
            owners.insert(next.ownerID)
            next.continuation.resume(returning: true)
            } else {
                itemOwners.removeValue(forKey: itemID)
            }
        }

    private func cancelWaiter(itemID: UUID, ownerID: UUID) {
        guard var itemWaiters = waiters[itemID],
            let index = itemWaiters.firstIndex(where: {
                $0.ownerID == ownerID
            }) else { return }
        let waiter = itemWaiters.remove(at: index)
        queuedOwnerCount -= 1
        if itemWaiters.isEmpty {
            waiters.removeValue(forKey: itemID)
        } else {
            waiters[itemID] = itemWaiters
        }
        waiter.continuation.resume(returning: false)
    }
}

struct SpotlightSearchResponse: Sendable {
    let units: [NotebookIndex.Unit]
    let succeeded: Bool
}

/// Read-only seam for bounded interactive queries. Persistent publication and
/// repair remain owned by `SpotlightBackend`; tests can inject a slow query
/// source without enabling or mutating the device's real Spotlight index.
protocol NotebookSpotlightInteractiveQuerying: Sendable {
    func search(
        query text: String,
        maximumResultCount: Int,
        itemID: UUID?,
        pageID: UUID?
    ) async -> SpotlightSearchResponse

    func load(anchorIDs: [String]) async -> [NotebookIndex.Unit]
}

protocol NotebookSpotlightBacking: NotebookSpotlightInteractiveQuerying {
    func persistedItemIDs() async -> Set<UUID>
    func replace(
        itemID: UUID,
        units: [NotebookIndex.Unit],
        manifest: IndexManifest,
        previousUnits: [NotebookIndex.Unit]?
    ) async -> SpotlightMutationReport
    func deleteDomains(for itemIDs: [UUID]) async -> SpotlightMutationReport
    func loadManifest(itemID: UUID) async -> IndexManifest?
}

private struct SpotlightRetryOutcome: Sendable {
    struct Publication: Sendable {
        let itemID: UUID
        let manifest: IndexManifest
        let mutationRevision: UInt64
        let report: SpotlightMutationReport
    }

    let deletionReport: SpotlightMutationReport?
    let deletionMutations: [UUID: UInt64]
    let publications: [Publication]

    static let cancelled = SpotlightRetryOutcome(
        deletionReport: .cancelled,
        deletionMutations: [:],
        publications: []
    )
}

/// Core Spotlight stores both the full bounded chunk and Codable locator
/// metadata. NotebookIndex serializes mutations only across overlapping item
/// domains, so one stalled callback cannot wedge every notebook.
private final class SpotlightBackend:
@unchecked Sendable,
NotebookSpotlightBacking {
    private static let chunkPrefix = "notate.assistant.chunk."
    private static let manifestPrefix = "notate.assistant.manifest."
    private static let domainPrefix = "notate.assistant.item."
    private static let trackedItemIDsKey = "com.notate.assistant.retrieval.tracked-item-ids.v2"
    private static let maximumMutationAttempts = 3
    private static let maximumIndexBatchCount = 100
    private static let maximumChunkMetadataEncodedByteCount = 128 * 1_024
    private static let maximumManifestMetadataEncodedByteCount = 16 * 1_024
    private static let chunkMarker = "com.notate.assistant.chunk.v4"
    private struct AttributeKeys {
        let marker: CSCustomAttributeKey
        let itemID: CSCustomAttributeKey
        let pageID: CSCustomAttributeKey
        let metadata: CSCustomAttributeKey
        let manifest: CSCustomAttributeKey

        init?() {
            guard let marker = CSCustomAttributeKey(
                keyName: "com_notate_assistant_chunk_schema", searchable: true,
                searchableByDefault: false, unique: false, multiValued: false
            ), let itemID = CSCustomAttributeKey(
                keyName: "com_notate_assistant_item_id", searchable: true,
                searchableByDefault: false, unique: false, multiValued: false
            ), let pageID = CSCustomAttributeKey(
                keyName: "com_notate_assistant_page_id", searchable: true,
                searchableByDefault: false, unique: false, multiValued: false
            ), let metadata = CSCustomAttributeKey(
                keyName: "com_notate_assistant_chunk_metadata", searchable: false,
                searchableByDefault: false, unique: false, multiValued: false
            ), let manifest = CSCustomAttributeKey(
                keyName: "com_notate_assistant_manifest", searchable: false,
                searchableByDefault: false, unique: false, multiValued: false
            ) else { return nil }
            self.marker = marker
            self.itemID = itemID
            self.pageID = pageID
            self.metadata = metadata
            self.manifest = manifest
        }

        var fetchAttributes: [String] {
            [
              marker.keyName,
                itemID.keyName,
                pageID.keyName,
                metadata.keyName,
                manifest.keyName,
            ]
        }
    }

    private static let attributeKeys = AttributeKeys()
    private static var fetchAttributes: [String] {
          attributeKeys?.fetchAttributes ?? []
    }

    private let index = CSSearchableIndex(
        name: "com.notate.assistant.retrieval",
        protectionClass: .complete
    )
    private let trackedItems: SpotlightTrackedItemStore
    private var preparedUserQuery = false

    init() {
        trackedItems = SpotlightTrackedItemStore(
            suiteName: nil,
            key: Self.trackedItemIDsKey
        )
    }

    func persistedItemIDs() async -> Set<UUID> {
        await trackedItems.itemIDs()
    }

    func replace(
        itemID: UUID,
        units: [NotebookIndex.Unit],
        manifest: IndexManifest,
        previousUnits: [NotebookIndex.Unit]?
    ) async -> SpotlightMutationReport {
        guard manifest.isCurrentSchema else {
            return SpotlightMutationReport(
                succeeded: false,
                attempts: 0,
                errorDescription: "unsupported manifest schema"
            )
        }
        guard !Task.isCancelled else { return .cancelled }
        guard let manifestItem = Self.searchableManifest(
            itemID: itemID,
            manifest: manifest
        ) else {
            return SpotlightMutationReport(
                succeeded: false,
                attempts: 0,
                errorDescription: "metadata encoding failed"
            )
        }
        // Preflight every chunk before deleting any prior publication. The
        // encoded bytes are discarded immediately, keeping validation memory
        // constant while preserving the existing all-or-nothing validation
        // boundary ahead of the first durable mutation.
        for unit in units {
            guard !Task.isCancelled else { return .cancelled }
            guard Self.searchableMetadata(
                unit,
                manifestFingerprint: manifest.fingerprint
            ) != nil else {
                return SpotlightMutationReport(
                succeeded: false,
			attempts: 0,
			errorDescription: "metadata encoding failed"
		)
	}
}
guard !Task.isCancelled else { return .cancelled }

// Track the domain before the first mutation. If the process exits in
// the middle of publication, the next launch can still reconcile and
// delete the incomplete domain.
await trackedItems.update(inserting: [itemID], removing: [])

var totalAttempts = 0
if let previousUnits {
	let previousByID = Dictionary(
		previousUnits.map { ($0.id, $0) },
		uniquingKeysWith: { current, _ in current }
	)
	let currentIDs = Set(units.map(\.id))
	let staleIdentifiers = previousByID.keys
		.filter { !currentIDs.contains($0) }
		.map { "\(Self.chunkPrefix)\($0)" }
	if !staleIdentifiers.isEmpty {
		let deletion = await deleteIdentifiersWithRetry(staleIdentifiers)
		totalAttempts += deletion.attempts
		guard deletion.succeeded else { return deletion }
	}
	// Every surviving chunk must receive the new manifest stamp. This
	// deliberately reindexes unchanged values when a proposal's
	// membership changes; otherwise a reused base chunk could not be
	// proven to belong to the manifest published last.
} else {
	let deletion = await deleteDomainsWithRetry([Self.domain(itemID)])
	totalAttempts += deletion.attempts
	guard deletion.succeeded else { return deletion }
}

for start in stride(
	from: 0,
	to: units.count,
	by: Self.maximumIndexBatchCount
) {
	guard !Task.isCancelled else { return .cancelled }
	let end = min(start + Self.maximumIndexBatchCount, units.count)
	var batch: [CSSearchableItem] = []
	batch.reserveCapacity(end - start)
	for unit in units[start..<end] {
		guard !Task.isCancelled else { return .cancelled }
		guard let searchableItem = Self.searchableItem(
			unit,
			manifestFingerprint: manifest.fingerprint
		) else {
			return SpotlightMutationReport(
				succeeded: false,
				attempts: totalAttempts,
				errorDescription: "metadata encoding failed"
		)
	}
	batch.append(searchableItem)
}
let report = await indexItemsWithRetry(batch)
totalAttempts += report.attempts
guard report.succeeded else { return report }
}

// Publish the manifest last. Readers only accept an old-generation
// chunk after this marker proves the complete delta was committed.
let manifestReport = await indexItemsWithRetry([manifestItem])
totalAttempts += manifestReport.attempts
guard manifestReport.succeeded else { return manifestReport }
return SpotlightMutationReport(
	succeeded: true,
	attempts: totalAttempts,
	errorDescription: nil
)
}

func deleteDomains(for itemIDs: [UUID]) async -> SpotlightMutationReport {
	guard !itemIDs.isEmpty else { return .success }
let report = await deleteDomainsWithRetry(itemIDs.map(Self.domain))
if report.succeeded {
	await trackedItems.update(inserting: [], removing: Set(itemIDs))
}
return report
}

func search(
	query text: String,
	maximumResultCount: Int,
	itemID: UUID?,
	pageID: UUID?
) async -> SpotlightSearchResponse {
	guard let attributeKeys = Self.attributeKeys else {
		return SpotlightSearchResponse(units: [], succeeded: false)
	}
	if !preparedUserQuery {
		CSUserQuery.prepareProtectionClasses([.complete])
		preparedUserQuery = true
	}
    let context = CSUserQueryContext()
context.enableRankedResults = true
context.disableSemanticSearch = false
context.maxResultCount = maximumResultCount
context.maxRankedResultCount = maximumResultCount
context.fetchAttributes = Self.fetchAttributes
var filterQueries = [
"\(attributeKeys.marker.keyName) == \"\(Self.chunkMarker)\""
]
if let itemID {
	filterQueries.append(
		"\(attributeKeys.itemID.keyName) == \"\(itemID.uuidString.lowercased())\""
	)
}
if let pageID {
	filterQueries.append(
		"\(attributeKeys.pageID.keyName) == \"\(pageID.uuidString.lowercased())\""
	)
}
context.filterQueries = filterQueries
let query = CSUserQuery(userQueryString: text, userQueryContext: context)
query.protectionClasses = [.complete]
var result: [NotebookIndex.Unit] = []
return await withTaskCancellationHandler {
do {
for try await response in query.responses {
try Task.checkCancellation()
guard case let .item(found) = response,
let unit = Self.unit(found.item) else { continue }
result.append(unit)
if result.count == maximumResultCount {
query.cancel()
break
}
}
query.cancel()
return SpotlightSearchResponse(units: result, succeeded: true)
} catch {
query.cancel()
return SpotlightSearchResponse(units: result, succeeded: false)
}
} onCancel: {
query.cancel()
}
}

func loadManifest(itemID: UUID) async -> IndexManifest? {
let context = CSSearchQueryContext()
context.fetchAttributes = Self.fetchAttributes
let domain = Self.domain(itemID)
let query = CSSearchQuery(
queryString: "domainIdentifier == \"\(domain)\"",
queryContext: context
)
query.protectionClasses = [.complete]
return await withTaskCancellationHandler {
do {
for try await found in query.results {
try Task.checkCancellation()
if found.item.uniqueIdentifier == Self.manifestIdentifier(itemID),
let manifest = Self.manifest(found.item),
manifest.isCurrentSchema {
query.cancel()
return manifest
}
}
} catch {
query.cancel()
return nil
}
query.cancel()
return nil
} onCancel: {
query.cancel()
}
}

func load(anchorIDs: [String]) async -> [NotebookIndex.Unit] {
var foundByID: [String: NotebookIndex.Unit] = [:]
for anchorID in Set(anchorIDs) {
guard !Task.isCancelled else { break }
let context = CSSearchQueryContext()
context.fetchAttributes = Self.fetchAttributes
let uniqueIdentifier = "\(Self.chunkPrefix)\(anchorID)"
let query = CSSearchQuery(
queryString: "uniqueIdentifier == \"\(uniqueIdentifier)\"",
queryContext: context
)
query.protectionClasses = [.complete]
let loaded: NotebookIndex.Unit = await withTaskCancellationHandler {
do {
for try await found in query.results {
try Task.checkCancellation()
if found.item.uniqueIdentifier == uniqueIdentifier,
let unit = Self.unit(found.item), unit.id == anchorID {
query.cancel()
return unit
}
}
} catch {
query.cancel()
return nil
}
query.cancel()
return nil
} onCancel: {
query.cancel()
}
if let loaded { foundByID[anchorID] = loaded }
}
return anchorIDs.compactMap { foundByID[$0] }
}

private func indexItemsWithRetry(_ values: [CSSearchableItem]) async -> SpotlightMutationReport {
guard !values.isEmpty else { return .success }
return await performMutationWithRetry {
try await self.indexItems(values)
}
}

private func deleteDomainsWithRetry(_ domains: [String]) async -> SpotlightMutationReport {
await performMutationWithRetry {
try await self.deleteDomains(domains)
}
}

private func deleteIdentifiersWithRetry(_ identifiers: [String]) async -> SpotlightMutationReport {
await performMutationWithRetry {
try await self.deleteIdentifiers(identifiers)
}
}

private func performMutationWithRetry(
_ operation: () async throws -> Void
) async -> SpotlightMutationReport {
var lastError: Error?
for attempt in 1...Self.maximumMutationAttempts {
guard !Task.isCancelled else { return .cancelled }
do {
try await operation()
return SpotlightMutationReport(
succeeded: true,
attempts: attempt,
errorDescription: nil
)
} catch {
lastError = error
await Self.retryDelay(after: attempt)
}
}
return SpotlightMutationReport(
succeeded: false,
attempts: Self.maximumMutationAttempts,
errorDescription: lastError.map(String.init(describing:))
)
}

private func indexItems(_ values: [CSSearchableItem]) async throws {
try await withCheckedThrowingContinuation {
(continuation: CheckedContinuation<Void, Error>) in
index.indexSearchableItems(values) { error in
if let error { continuation.resume(throwing: error) }
else { continuation.resume() }
}
}
}

private func deleteDomains(_ domains: [String]) async throws {
try await withCheckedThrowingContinuation {
(continuation: CheckedContinuation<Void, Error>) in
index.deleteSearchableItems(withDomainIdentifiers: domains) { error in
if let error { continuation.resume(throwing: error) }
else { continuation.resume() }
}
}
}

private func deleteIdentifiers(_ identifiers: [String]) async throws {
try await withCheckedThrowingContinuation {
(continuation: CheckedContinuation<Void, Error>) in
index.deleteSearchableItems(withIdentifiers: identifiers) { error in
if let error { continuation.resume(throwing: error) }
else { continuation.resume() }
}
}
}

private static func searchableItem(
_ unit: NotebookIndex.Unit,
manifestFingerprint: String
) -> CSSearchableItem? {
guard let attributeKeys,
let metadata = searchableMetadata(
unit,
manifestFingerprint: manifestFingerprint
) else {
return nil
}
let attributes = CSSearchableItemAttributeSet(contentType: .plainText)
attributes.title = unit.itemName
attributes.displayName = unit.itemName
attributes.textContent = unit.text
attributes.containerTitle = unit.itemName
attributes.containerIdentifier = unit.itemID.uuidString
attributes.version = String(unit.generation)
attributes.setValue(chunkMarker as NSString, forCustomKey: attributeKeys.marker)
attributes.setValue(
unit.itemID.uuidString.lowercased() as NSString,
forCustomKey: attributeKeys.itemID
)
attributes.setValue(
(unit.pageID?.uuidString.lowercased() ?? "item") as NSString,
forCustomKey: attributeKeys.pageID
)
attributes.setValue(metadata as NSData, forCustomKey: attributeKeys.metadata)
let item = CSSearchableItem(
uniqueIdentifier: "\(chunkPrefix)\(unit.id)",
domainIdentifier: domain(unit.itemID),
attributeSet: attributes
)
item.expirationDate = .distantFuture
return item
}

private static func searchableMetadata(
_ unit: NotebookIndex.Unit,
manifestFingerprint: String
) -> Data? {
let value = SpotlightChunkMetadata(
    unit,
manifestFingerprint: manifestFingerprint
)
guard value.isWithinBounds,
let metadata = try? JSONEncoder().encode(value),
metadata.count <= maximumChunkMetadataEncodedByteCount else {
return nil
}
return metadata
}

private static func searchableManifest(itemID: UUID, manifest: IndexManifest) -> CSSearchableItem? {
guard let attributeKeys,
let metadata = try? JSONEncoder().encode(manifest),
metadata.count <= maximumManifestMetadataEncodedByteCount else {
return nil
}
let attributes = CSSearchableItemAttributeSet(contentType: .data)
attributes.title = "Notate retrieval manifest"
attributes.version = String(manifest.generation)
attributes.setValue(metadata as NSData, forCustomKey: attributeKeys.manifest)
let item = CSSearchableItem(
uniqueIdentifier: manifestIdentifier(itemID),
domainIdentifier: domain(itemID),
attributeSet: attributes
)
item.expirationDate = .distantFuture
return item
}

private static func unit(_ item: CSSearchableItem) -> NotebookIndex.Unit? {
guard let attributeKeys,
item.uniqueIdentifier.hasPrefix(chunkPrefix),
item.attributeSet.value(forCustomKey: attributeKeys.marker) as? String == chunkMarker,
let data = data(item.attributeSet.value(forCustomKey: attributeKeys.metadata)),
data.count <= maximumChunkMetadataEncodedByteCount,
let metadata = try? JSONDecoder().decode(
SpotlightChunkMetadata.self,
from: data
),
metadata.isWithinBounds else {
return nil
}
let unit = metadata.unit()
guard item.uniqueIdentifier == "\(chunkPrefix)\(unit.id)",
SearchText.hash(unit.text) == unit.contentHash else { return nil }
return unit
}

private static func manifest(_ item: CSSearchableItem) -> IndexManifest? {
guard let attributeKeys,
let data = data(
item.attributeSet.value(forCustomKey: attributeKeys.manifest)
),
data.count <= maximumManifestMetadataEncodedByteCount else {
return nil
}
return try? JSONDecoder().decode(IndexManifest.self, from: data)
}

private static func data(_ value: (any NSSecureCoding)?) -> Data? {
if let value = value as? Data { return value }
if let value = value as? NSData { return Data(referencing: value) }
return nil
}

private static func domain(_ itemID: UUID) -> String {
"\(domainPrefix)\(itemID.uuidString.lowercased())"
}

private static func manifestIdentifier(_ itemID: UUID) -> String {
"\(manifestPrefix)\(itemID.uuidString.lowercased())"
}

private static func retryDelay(after attempt: Int) async {
guard attempt < maximumMutationAttempts else { return }
let nanoseconds = UInt64(attempt * attempt) * 50_000_000
try? await Task.sleep(nanoseconds: nanoseconds)
}
}

/// Serializes the persistent tracked-domain read/modify/write transaction.
/// Spotlight mutations for disjoint notebooks intentionally run concurrently,
/// but `UserDefaults` offers no atomic set mutation; without one owner, two
/// successful publications can overwrite each other's identifiers.
actor SpotlightTrackedItemStore {
    private let defaults: UserDefaults
    private let key: String

    init(suiteName: String?, key: String) {
        if let suiteName, let suiteDefaults = UserDefaults(suiteName: suiteName) {
            defaults = suiteDefaults
        } else {
            defaults = .standard
        }
        self.key = key
    }

    func itemIDs() -> Set<UUID> {
        Set((defaults.stringArray(forKey: key) ?? []).compactMap(UUID.init))
    }

    func update(inserting: Set<UUID>, removing: Set<UUID>) {
        var values = itemIDs()
        values.formUnion(inserting)
        values.subtract(removing)
        defaults.set(
            values.map(\.uuidString).sorted(),
            forKey: key
        )
    }
}

private enum SearchText {
    private static let stopWords: Set<String> = [
        "a", "an", "and", "are", "about", "can", "do", "find", "for", "from",
        "give", "have", "in", "is", "me", "my", "notes", "of", "on", "please",
        "show", "tell", "that", "the", "this", "to", "what", "where", "which", "with",
    ]

    static func hash(_ text: String) -> String { sha256(text.precomposedStringWithCanonicalMapping) }

    /// Hashes length-delimited components without first joining them into one
    /// large transient `String` / `Data`. This is used for catalog and manifest
    /// identities where the admitted source may be several megabytes.
    static func hashComponents(_ components: some Sequence<String>) -> String {
        var hasher = SHA256()
        for component in components {
            updateComponent(component, hasher: &hasher)
        }
        return finalized(hasher)
    }

    static func anchorID(
        itemID: UUID, pageID: UUID?, blockID: UUID?, kind: AssistantSourceKind,
        ordinal: Int, contentHash: String
    ) -> String {
        let key = [itemID.uuidString.lowercased(), pageID?.uuidString.lowercased() ?? "item",
                   blockID?.uuidString.lowercased() ?? "no-block",
                   kind.rawValue, String(max(ordinal, 0)), contentHash].joined(separator: "|")
        return "source_\(sha256(key).prefix(24))"
    }

    static func fingerprint(generation: Int64, units: [NotebookIndex.Unit]) -> String {
        var hasher = SHA256()
        updateComponent(String(max(generation, 0)), hasher: &hasher)
        for unit in units {
            updateComponent(unit.id, hasher: &hasher)
            updateComponent(unit.itemName, hasher: &hasher)
            updateComponent(String(unit.pageNumber ?? -1), hasher: &hasher)
            updateComponent(
                unit.pageBounds.map { NSCoder.string(for: $0) } ?? "none",
                hasher: &hasher
            )
            updateComponent(unit.contentHash, hasher: &hasher)
        }
        return finalized(hasher)
    }

    /// Produces the same greedy, word-preserving overlap windows without first
    /// materializing every word in the source. `nil` means the caller's output
    /// budget would be exceeded; callers then fail closed before constructing
    /// Unit hashes, lexical postings, or fingerprints.
    static func chunks(
        _ text: String,
        maximum: Int,
        overlap: Int,
        maximumCount: Int,
        maximumUTF8Bytes: Int = .max,
        maximumChunkUTF8Bytes: Int = NotebookIndex.maximumChunkUTF8ByteCount,
        retainingChunks: Bool = true
    ) -> [String]? {
        let maximum = max(maximum, 64)
        let overlap = min(max(overlap, 0), maximum / 2)
        guard maximumCount >= 0,
            maximumUTF8Bytes >= 0,
            maximumChunkUTF8Bytes > 0 else { return nil }

        var scanCursor = text.startIndex
        var splitCursor: String.Index?
        var splitEnd: String.Index?
        var exceededPieceByteLimit = false

        func nextWordPiece() -> String? {
            if let pieceStart = splitCursor,
                let wordEnd = splitEnd {
                let pieceEnd = text.index(
                    pieceStart,
                    offsetBy: maximum,
                    limitedBy: wordEnd
                ) ?? wordEnd
                if pieceEnd < wordEnd {
                    splitCursor = pieceEnd
                } else {
                    splitCursor = nil
                    splitEnd = nil
                }
                let piece = text[pieceStart..<pieceEnd]
                guard piece.utf8.count <= maximumChunkUTF8Bytes else {
                    exceededPieceByteLimit = true
                    return nil
                }
                return String(piece)
            }

            while scanCursor < text.endIndex,
    text[scanCursor].isWhitespace {
    scanCursor = text.index(after: scanCursor)
}
guard scanCursor < text.endIndex else { return nil }
    let wordStart = scanCursor
    while scanCursor < text.endIndex,
          text[scanCursor].isWhitespace {
        scanCursor = text.index(after: scanCursor)
    }
    let wordEnd = scanCursor
    let pieceEnd = text.index(
        offsetBy: maximum,
        limitedBy: wordEnd
    ) ?? wordEnd
    if pieceEnd < wordEnd {
        splitCursor = pieceEnd
        splitEnd = wordEnd
    splitCursor = pieceEnd
    splitEnd = wordEnd
}
let piece = text[wordStart..<pieceEnd]
guard piece.utf8.count <= maximumChunkUTF8Bytes else {
    exceededPieceByteLimit = true
    return nil
}
return String(piece)
}

var result: [String] = []
if retainingChunks {
    result.reserveCapacity(min(maximumCount, 128))
}
var emittedChunkCount = 0
var emittedUTF8Bytes = 0
var overlapSeed: [String] = []
var pendingWord: String?

while true {
    guard Task.isCancelled == false else { return nil }
    var words = overlapSeed
    overlapSeed.removeAll(keepingCapacity: true)
    var length = words.enumerated().reduce(into: 0) { partial, entry in
    partial += entry.element.count + (entry.offset == 0 ? 0 : 1)
}

    while true {
    let candidate: String
    if let pendingWord {
    candidate = pendingWord
} else if let next = nextWordPiece() {
    candidate = next
} else {
    guard exceededPieceByteLimit == false else { return nil }
    break
}
let added = candidate.count + (words.isEmpty ? 0 : 1)
guard length + added <= maximum else {
    pendingWord = candidate
    break
}
words.append(candidate)
length += added
pendingWord = nil
}

guard words.isEmpty == false else { return result }
guard emittedChunkCount < maximumCount else { return nil }
let chunk = words.joined(separator: " ")
let chunkUTF8Bytes = chunk.utf8.count
guard chunkUTF8Bytes <= maximumChunkUTF8Bytes,
    chunkUTF8Bytes <= maximumUTF8Bytes - emittedUTF8Bytes else {
    return nil
}
emittedChunkCount += 1
emittedUTF8Bytes += chunkUTF8Bytes
if retainingChunks {
    result.append(chunk)
}

if pendingWord == nil {
    pendingWord = nextWordPiece()
}
guard exceededPieceByteLimit == false else { return nil }
guard pendingWord != nil else { return result }

var overlapStart = words.count
var overlapCount = 0
while overlapStart > 1 {
    let added = words[overlapStart - 1].count
    + (overlapCount == 0 ? 0 : 1)
guard overlapCount + added <= overlap else { break }
overlapStart -= 1
overlapCount += added
}
if overlapStart < words.count {
    overlapSeed.append(contentsOf: words[overlapStart...])
}
}
}

static func meaningfulTerms(
_ value: String,
maximumCount: Int = .max
) -> [String] {
guard maximumCount > 0 else { return [] }
        let all = tokens(value), preferred = all.filter { !stopWords.contains($0) }
var seen = Set<String>()
var result: [String] = []
for term in preferred.isEmpty ? all : preferred {
guard seen.insert(term).inserted else { continue }
result.append(term)
if result.count == maximumCount { break }
}
return result
}

static func postingTerms(_ value: String) -> [String] {
tokens(value)
}

static func score(_ text: String, itemName: String, terms: [String], phrase: String) -> Double? {
let textTokens = tokens(text), nameTokens = tokens(itemName)
let frequencies = Dictionary(textTokens.map { ($0, 1) }, uniquingKeysWith: +)
var score = 0.0, matches = 0
for term in terms {
var matchedContent = false
if let count = frequencies[term], count > 0 {
matchedContent = true
score += 2 + min(Double(count), 5) * 0.4
} else if term.count >= 6,
textTokens.contains(where: { $0.hasPrefix(term) || term.hasPrefix($0) }) {
matchedContent = true
score += 1
}
if nameTokens.contains(term) {
if matchedContent == false { matches += 1 }
score += 0.75
} else if term.count >= 6,
matchedContent == false,
nameTokens.contains(where: {
$0.hasPrefix(term) || term.hasPrefix($0)
}) {
matches += 1
score += 0.5
}
}
guard matches > 0 else { return nil }
score += Double(matches) / Double(terms.count) * 8
if matches == terms.count { score += 3 }
if !phrase.isEmpty, textTokens.joined(separator: " ").contains(phrase) { score += 10 }
return score
}

static func snippet(_ text: String, matching terms: [String]) -> String {
let text = text.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
guard !text.isEmpty else { return "" }
let center = terms.lazy.compactMap {
text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive])
}.first?.lowerBound ?? text.startIndex
let start = text.index(center, offsetBy: -72, limitedBy: text.startIndex) ?? text.startIndex
let end = text.index(center, offsetBy: 132, limitedBy: text.endIndex) ?? text.endIndex
        return (start == text.startIndex ? "" : "…") + String(text[start..<end])
            + (end == text.endIndex ? "" : "…")
}

    private static func tokens(_ text: String) -> [String] {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")).unicodeScalars
            .split { !CharacterSet.alphanumerics.contains($0) }.map(String.init).filter { !$0.isEmpty }
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func updateComponent(
        _ text: String,
        hasher: inout SHA256
    ) {
        let bytes = text.utf8
        hasher.update(data: Data("\(bytes.count):".utf8))
        var cursor = bytes.startIndex
        while cursor < bytes.endIndex {
            let end = bytes.index(
                cursor,
                offsetBy: 64 * 1_024,
                limitedBy: bytes.endIndex
            ) ?? bytes.endIndex
            hasher.update(data: Data(bytes[cursor..<end]))
            cursor = end
        }
    }

    private static func finalized(_ hasher: SHA256) -> String {
        let hasher = hasher
        return hasher.finalize().map {
            String(format: "%02x", $0)
        }.joined()
    }
}
