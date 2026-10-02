import Foundation

public enum LibraryItemKind: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case folder
    case notebook
    /// Decode-only compatibility for catalogs created while the retired
    /// standalone typed-note experiment was present. It is never surfaced or
    /// accepted as a new library item.
    case legacyTypedNote = "note"
    /// Retained only so older SwiftData stores can be decoded and purged.
    case canvas
    case importedDocument
    case attachment

    public var id: Self { self }

    public var title: String {
        switch self {
        case .folder: "Folder"
        case .notebook: "Notebook"
        case .legacyTypedNote: "Legacy Typed Note"
        case .canvas: "Legacy Canvas"
        case .importedDocument: "File & Doc"
        case .attachment: "Attachment"
        }
    }

    public var isLegacyLibraryItem: Bool {
        self == .canvas || self == .legacyTypedNote
    }
}

public enum LibraryCoverPreset: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    // These raw identifiers predate the current artwork and are persisted in
    // the catalog. Keep them stable when refreshing the visible cover family.
    case softLinen
    case blueprint
    case warmPaper
    case skyComposition
    case peachOrchard
    case butterStripe
    case aquaComposition
    case periwinkleOrchard

    public var id: Self { self }

    public var title: String {
        switch self {
        case .softLinen: "Rose Composition"
        case .blueprint: "Mint Orchard"
        case .warmPaper: "Lavender Stripe"
        case .skyComposition: "Sky Composition"
        case .peachOrchard: "Peach Orchard"
        case .butterStripe: "Butter Stripe"
        case .aquaComposition: "Aqua Composition"
        case .periwinkleOrchard: "Periwinkle Orchard"
        }
    }
}

public enum LibraryCoverChoice: Codable, Equatable, Hashable, Sendable {
    /// Render the first page when available, then fall back to generated artwork.
    case automatic
    case preset(LibraryCoverPreset)
    /// A path relative to the item's asset directory. Absolute paths are never persisted.
    case customAsset(relativePath: String)
}

public enum LibraryPayloadState: String, CaseIterable, Codable, Hashable, Sendable {
    case creating
    case importing
    case ready
    case failed
    case missing
}

public struct LibraryRGBAColor: Codable, Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var isValid: Bool {
        [red, green, blue, alpha].allSatisfy { component in
            component.isFinite && (0...1).contains(component)
        }
    }

    public var clamped: LibraryRGBAColor {
        LibraryRGBAColor(
            red: red.clampedToLibraryColorComponent,
            green: green.clampedToLibraryColorComponent,
            blue: blue.clampedToLibraryColorComponent,
            alpha: alpha.clampedToLibraryColorComponent
        )
    }

    public static let folderBlue = LibraryRGBAColor(
        red: 0.55,
        green: 0.78,
        blue: 1.00
    )
}

public struct LibraryFolderSettings: Codable, Equatable, Hashable, Sendable {
    public var color: LibraryRGBAColor
    public var symbolName: String?

    public init(color: LibraryRGBAColor = .folderBlue, symbolName: String? = nil) {
        self.color = color
        self.symbolName = symbolName?.nilIfLibraryBlank
    }
}

public enum LibraryRecentPeriod: Int, CaseIterable, Identifiable, Sendable {
    case thirtyDays = 30
    case sixtyDays = 60
    case ninetyDays = 90

    public var id: Self { self }

    public var title: String {
        "Past \(rawValue) Days"
    }

    public func cutoff(relativeTo date: Date, calendar: Calendar = .autoupdatingCurrent) -> Date {
        calendar.date(byAdding: .day, value: -rawValue, to: date)
            ?? date.addingTimeInterval(-TimeInterval(rawValue) * 24 * 60 * 60)
    }
}

public enum LibraryPresetTag: String, CaseIterable, Identifiable, Sendable {
    case work
    case study
    case personal
    case ideas

    public var id: UUID {
        switch self {
        case .work:
            UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 1))
        case .study:
            UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 2))
        case .personal:
            UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 3))
        case .ideas:
            UUID(uuid: (0, 0, 0, 0, 0, 0, 0x40, 0, 0x80, 0, 0, 0, 0, 0, 0, 4))
        }
    }

    /// Resolves the preset tag that owns `tagID`, if any. Preset tags are
    /// installed with stable identifiers so they remain recognizable across
    /// launches and cannot be renamed or deleted from the sidebar.
    public static func resolve(tagID: UUID) -> Self? {
        allCases.first { $0.id == tagID }
    }

    public var title: String {
        rawValue.capitalized
    }

    public var color: LibraryRGBAColor {
        switch self {
        case .work:
            LibraryRGBAColor(red: 0.29, green: 0.65, blue: 0.88)
        case .study:
            LibraryRGBAColor(red: 0.58, green: 0.46, blue: 0.88)
        case .personal:
            LibraryRGBAColor(red: 0.89, green: 0.43, blue: 0.67)
        case .ideas:
            LibraryRGBAColor(red: 0.94, green: 0.67, blue: 0.24)
        }
    }
}

public enum LibrarySortField: String, CaseIterable, Codable, Hashable, Identifiable, Sendable {
    case activity
    case name
    case created
    case type

    public var id: Self { self }

    public var title: String {
        switch self {
        case .activity: "Recent"
        case .name: "Name"
        case .created: "Date created"
        case .type: "Type"
        }
    }
}

public enum LibrarySortDirection: String, CaseIterable, Codable, Hashable, Sendable {
    case ascending
    case descending
}

public struct LibrarySort: Codable, Equatable, Hashable, Sendable {
    public var field: LibrarySortField
    public var direction: LibrarySortDirection

    public init(
        field: LibrarySortField = .activity,
        direction: LibrarySortDirection = .descending
    ) {
        self.field = field
        self.direction = direction
    }

    public static let activity = LibrarySort()
    public static let name = LibrarySort(field: .name, direction: .ascending)
    public static let created = LibrarySort(field: .created, direction: .descending)
    public static let type = LibrarySort(field: .type, direction: .ascending)
}

public struct LibraryTrashMetadata: Codable, Equatable, Hashable, Sendable {
    public let deletedAt: Date
    public let purgeAfter: Date
    public let originalParentID: UUID?
    public let originalOrder: Double
    /// Every item in one recursively trashed subtree shares this value.
    public let trashGroupID: UUID

    public init(
        deletedAt: Date,
        purgeAfter: Date,
        originalParentID: UUID?,
        originalOrder: Double,
        trashGroupID: UUID
    ) {
        self.deletedAt = deletedAt
        self.purgeAfter = purgeAfter
        self.originalParentID = originalParentID
        self.originalOrder = originalOrder
        self.trashGroupID = trashGroupID
    }
}

/// A catalog duplicate is prepared before its binary payloads are copied.
/// `sourceToduplicateItemIDs` gives the asset layer an exact mapping for every
/// descendant instead of relying on independently sorted subtree arrays.
public struct LibraryDuplicationPlan: Codable, Equatable, Sendable {
    public var operationID: UUID
    public var rootItemID: UUID
    public var sourceToDuplicateItemIDs: [UUID: UUID]
    public var finalPayloadStates: [UUID: LibraryPayloadState]
    public var finalFailureDescriptions: [UUID: String]

    public init(
        operationID: UUID,
        rootItemID: UUID,
        sourceToDuplicateItemIDs: [UUID: UUID],
        finalPayloadStates: [UUID: LibraryPayloadState],
        finalFailureDescriptions: [UUID: String] = [:]
    ) {
        self.operationID = operationID
        self.rootItemID = rootItemID
        self.sourceToDuplicateItemIDs = sourceToDuplicateItemIDs
        self.finalPayloadStates = finalPayloadStates
        self.finalFailureDescriptions = finalFailureDescriptions
    }
}

/// One immutable catalog observation used to validate startup cleanup. The
/// payload state and duplication operation are included so a record that
/// finishes while cleanup is being prepared is never removed by a stale plan.
public struct LibraryIncompletePayloadEntry: Codable, Equatable, Hashable, Sendable {
    public let itemID: UUID
    public let payloadState: LibraryPayloadState
    public let pendingDuplicationID: UUID?

    public init(
        itemID: UUID,
        payloadState: LibraryPayloadState,
        pendingDuplicationID: UUID?
    ) {
        self.itemID = itemID
        self.payloadState = payloadState
        self.pendingDuplicationID = pendingDuplicationID
    }
}

/// Catalog half of startup reconciliation for interrupted create/import/copy
/// operations. Callers first stage every listed item directory in recoverable
/// storage and only then commit this exact plan.
public struct LibraryIncompletePayloadReconciliationPlan: Codable, Equatable, Sendable {
    public let rootItemIDs: [UUID]
    public let entries: [LibraryIncompletePayloadEntry]

    public init(
        rootItemIDs: [UUID] = [],
        entries: [LibraryIncompletePayloadEntry] = []
    ) {
        self.rootItemIDs = rootItemIDs
        self.entries = entries
    }

    public var itemIDs: [UUID] { entries.map(\.itemID) }
    public var isEmpty: Bool { entries.isEmpty }
}

/// The file-backed portion of a soft-deleted page. Callers retain this value
/// while restoring or purging the payload and acknowledge the tombstone only
/// after that filesystem work succeeds.
public struct LibraryDeletedPageAsset: Codable, Equatable, Hashable, Sendable {
    public let recordID: UUID
    public let pageID: UUID
    public let ownerItemID: UUID
    public let payloadRelativePath: String

    public init(
        recordID: UUID,
        pageID: UUID,
        ownerItemID: UUID,
        payloadRelativePath: String
    ) {
        self.recordID = recordID
        self.pageID = pageID
        self.ownerItemID = ownerItemID
        self.payloadRelativePath = payloadRelativePath
    }
}

/// Everything the page layer needs to put a soft-deleted page back in place.
/// Taking this value removes the corresponding `DeletedPageRecord` in the
/// same repository transaction.
public struct LibraryDeletedPageRestoration: Codable, Equatable, Hashable, Sendable {
    public let pageID: UUID
    public let ownerItemID: UUID
    public let originalIndex: Int
    public let payloadRelativePath: String
    public let title: String?

    public init(
        pageID: UUID,
        ownerItemID: UUID,
        originalIndex: Int,
        payloadRelativePath: String,
        title: String?
    ) {
        self.pageID = pageID
        self.ownerItemID = ownerItemID
        self.originalIndex = originalIndex
        self.payloadRelativePath = payloadRelativePath
        self.title = title
    }
}

/// A stable snapshot of expired metadata. Physical assets can be moved to
/// recovery storage using this plan before `commitPurge(_:)` removes records.
public struct LibraryPurgePlan: Codable, Equatable, Sendable {
    public let itemIDs: [UUID]
    public let deletedPageAssets: [LibraryDeletedPageAsset]

    public init(
        itemIDs: [UUID] = [],
        deletedPageAssets: [LibraryDeletedPageAsset] = []
    ) {
        self.itemIDs = itemIDs
        self.deletedPageAssets = deletedPageAssets
    }

    public var isEmpty: Bool {
        itemIDs.isEmpty && deletedPageAssets.isEmpty
    }
}

/// The persistent records removed by one retention purge. Item identifiers can
/// be handed to `LibraryAssetStore` after the metadata transaction succeeds.
public struct LibraryPurgeResult: Codable, Equatable, Hashable, Sendable {
    public var itemIDs: [UUID]
    public var deletedPageCount: Int
    public var deletedPageAssets: [LibraryDeletedPageAsset]

    public init(
        itemIDs: [UUID] = [],
        deletedPageCount: Int = 0,
        deletedPageAssets: [LibraryDeletedPageAsset] = []
    ) {
        self.itemIDs = itemIDs
        self.deletedPageCount = deletedPageCount
        self.deletedPageAssets = deletedPageAssets
    }
}

// MARK: - Helper Extensions

private extension Double {
    var clampedToLibraryColorComponent: Double {
        guard isFinite else { return 0 }
        return min(max(self, 0), 1)
    }
}

extension String {
    var nilIfLibraryBlank: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
