import Foundation
import SwiftData

// MARK: - LibraryItemRecord
@Model
public final class LibraryItemRecord {
    @Attribute(.unique) public var id: UUID
    public var parentID: UUID?
    public var name: String
    public var normalizedName: String
    public var kind: LibraryItemKind
    public var coverChoice: LibraryCoverChoice
    public var payloadState: LibraryPayloadState
    public var payloadFailureDescription: String?
    public var folderSettings: LibraryFolderSettings?
    public var createdAt: Date
    public var modifiedAt: Date?
    public var lastOpenedAt: Date?
    public var isFavorite: Bool
    public var manualOrder: Double
    public var trashMetadata: LibraryTrashMetadata?
    public var sourceFilename: String?
    public var sourceContentTypeIdentifier: String?
    
    /// Normalized text extracted from PDF pages, imported files, or PaperKit
    /// text elements. It is an index, not the canonical document contents.
    public var searchableText: String
    public var pageCount: Int
    
    /// Generation of the verified document represented by the current durable
    /// library item. Zero means that no document has been verified.
    /// library thumbnail: zero means that the verified preview has committed.
    public var previewGeneration: Int64
    
    /// Non-nil only while a staged recursive duplicate is awaiting its asset
    /// transaction. Every member of that duplicate shares the operation ID.
    public var pendingDuplicationID: UUID?
    
    public init(
        id: UUID = UUID(),
        parentID: UUID? = nil,
        name: String,
        kind: LibraryItemKind,
        coverChoice: LibraryCoverChoice = .automatic,
        payloadState: LibraryPayloadState = .creating,
        payloadFailureDescription: String? = nil,
        folderSettings: LibraryFolderSettings? = nil,
        createdAt: Date = .now,
        modifiedAt: Date? = nil,
        lastOpenedAt: Date? = nil,
        isFavorite: Bool = false,
        manualOrder: Double = 0,
        trashMetadata: LibraryTrashMetadata? = nil,
        sourceFilename: String? = nil,
        sourceContentTypeIdentifier: String? = nil,
        searchableText: String = "",
        pageCount: Int = 0,
        previewGeneration: Int64 = 0,
        pendingDuplicationID: UUID? = nil
    ) {
        self.id = id
        self.parentID = parentID
        self.name = name
        let resolvedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.normalizedName = LibraryItemRecord.normalize(resolvedName)
        self.kind = kind
        self.coverChoice = coverChoice
        self.payloadState = payloadState
        self.payloadFailureDescription = payloadFailureDescription
        self.folderSettings = folderSettings
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt
        self.lastOpenedAt = lastOpenedAt
        self.isFavorite = isFavorite
        self.manualOrder = manualOrder
        self.trashMetadata = trashMetadata
        self.sourceFilename = sourceFilename
        self.sourceContentTypeIdentifier = sourceContentTypeIdentifier
        self.searchableText = Self.normalize(searchableText)
        self.pageCount = max(pageCount, 0)
        self.previewGeneration = max(previewGeneration, 0)
        self.pendingDuplicationID = pendingDuplicationID
    }
    
    public var isTrashed: Bool { trashMetadata != nil }
    
    public var activityDate: Date {
        max(modifiedAt, lastOpenedAt ?? createdAt)
    }
    
    static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

// MARK: - TagRecord
@Model
public final class TagRecord {
    @Attribute(.unique) public var id: UUID
    public var name: String
    public var normalizedName: String
    public var color: LibraryRGBAColor
    public var createdAt: Date
    public var modifiedAt: Date
    
    public init(
        id: UUID = UUID(),
        name: String,
        color: LibraryRGBAColor,
        createdAt: Date = .now,
        modifiedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.normalizedName = LibraryItemRecord.normalize(name)
        self.color = color
        self.createdAt = createdAt
        self.modifiedAt = modifiedAt ?? createdAt
    }
    
    public static func makeRelationshipKey(itemID: UUID, tagID: UUID) -> String {
        "\(itemID.uuidString.lowercased())::\(tagID.uuidString.lowercased())"
    }
}

// MARK: - TagAssignment
@Model
public final class TagAssignment {
    @Attribute(.unique) public var id: UUID
    @Attribute(.unique) public var relationshipKey: String
    public var itemID: UUID
    public var tagID: UUID
    public var createdAt: Date
    
    public init(
        id: UUID = UUID(),
        itemID: UUID,
        tagID: UUID,
        createdAt: Date = .now
    ) {
        self.id = id
        self.relationshipKey = Self.makeRelationshipKey(itemID: itemID, tagID: tagID)
        self.itemID = itemID
        self.tagID = tagID
        self.createdAt = createdAt
    }
    
    public static func makeRelationshipKey(itemID: UUID, tagID: UUID) -> String {
        "\(itemID.uuidString.lowercased())::\(tagID.uuidString.lowercased())"
    }
}

// MARK: - DeletedPageRecord
@Model
public final class DeletedPageRecord {
    @Attribute(.unique) public var id: UUID
    public var pageID: UUID
    public var ownerItemID: UUID
    public var deletedAt: Date
    public var purgeAfter: Date
    public var originalIndex: Int
    public var payloadRelativePath: String
    public var title: String?
    
    public init(
        id: UUID = UUID(),
        pageID: UUID,
        ownerItemID: UUID,
        deletedAt: Date = .now,
        purgeAfter: Date,
        originalIndex: Int,
        payloadRelativePath: String,
        title: String? = nil
    ) {
        self.id = id
        self.pageID = pageID
        self.ownerItemID = ownerItemID
        self.deletedAt = deletedAt
        self.purgeAfter = purgeAfter
        self.originalIndex = max(originalIndex, 0)
        self.payloadRelativePath = payloadRelativePath
        self.title = title?.nilIfLibraryBlank
    }
}

// MARK: - Library Schema Versions
public enum LibrarySchemaV1: VersionedSchema {
    public static var versionIdentifier = Schema.Version(1, 0, 0)
    public static var models: [any PersistentModel.Type] {
        [
            LibraryItemRecord.self,
            TagRecord.self,
            TagAssignment.self,
            DeletedPageRecord.self,
        ]
    }
}

public enum LibrarySchemaMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [VersionedSchema.Type] { [LibrarySchemaV1.self] }
    public static var stages: [MigrationStage] { [] }
}

// MARK: - Supporting Types
public enum LibraryItemKind: String, Codable, CaseIterable {
    case folder
    case document
    case page
}

public enum LibraryCoverChoice: String, Codable {
    case automatic
    case custom
}

public enum LibraryPayloadState: String, Codable {
    case creating
    case ready
    case error
}

public struct LibraryFolderSettings: Codable {
    public var sortOrder: SortOrder?
    
    public init(sortOrder: SortOrder? = nil) {
        self.sortOrder = sortOrder
    }
}

public enum SortOrder: String, Codable {
    case nameAscending
    case nameDescending
    case dateCreatedAscending
    case dateCreatedDescending
    case dateModifiedAscending
    case dateModifiedDescending
    case manual
}

public struct LibraryTrashMetadata: Codable {
    public var deletedAt: Date
    public var deletedBy: String?
    
    public init(deletedAt: Date = .now, deletedBy: String? = nil) {
        self.deletedAt = deletedAt
        self.deletedBy = deletedBy
    }
}

public struct LibraryRGBAColor: Codable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double
    
    public init(red: Double, green: Double, blue: Double, alpha: Double = 1.0) {
        self.red = max(0, min(1, red))
        self.green = max(0, min(1, green))
        self.blue = max(0, min(1, blue))
        self.alpha = max(0, min(1, alpha))
    }
}

// MARK: - Helper Extensions
private extension String {
    var nilIfLibraryBlank: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
