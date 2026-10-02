import Darwin
import Foundation

public enum LibraryAssetCategory: String, CaseIterable, Codable, Sendable {
    case canvas = "Canvas"
    case sources = "Sources"
    case thumbnails = "Thumbnails"
    case freeform = "Freeform"
}

public struct LibraryItemAssetDirectories: Equatable, Hashable, Sendable {
    public let itemRoot: URL
    public let canvas: URL
    public let sources: URL
    public let thumbnails: URL
    public let freeform: URL

    public init(itemRoot: URL) {
        self.itemRoot = itemRoot
        canvas = itemRoot.appendingPathComponent(
            LibraryAssetCategory.canvas.rawValue,
            isDirectory: true
        )
        sources = itemRoot.appendingPathComponent(
            LibraryAssetCategory.sources.rawValue,
            isDirectory: true
        )
        thumbnails = itemRoot.appendingPathComponent(
            LibraryAssetCategory.thumbnails.rawValue,
            isDirectory: true
        )
        freeform = itemRoot.appendingPathComponent(
            LibraryAssetCategory.freeform.rawValue,
            isDirectory: true
        )
    }

    public subscript(category: LibraryAssetCategory) -> URL {
        switch category {
        case .canvas: canvas
        case .sources: sources
        case .thumbnails: thumbnails
        case .freeform: freeform
        }
    }
}

public struct LibraryAssetRecoveryEntry: Codable, Equatable, Hashable, Sendable {
    public let itemID: UUID
    public let relativePath: String
    public let recoveryURL: URL

    public init(itemID: UUID, relativePath: String, recoveryURL: URL) {
        self.itemID = itemID
        self.relativePath = relativePath
        self.recoveryURL = recoveryURL
    }
}

struct LibraryAssetTrashManifest: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    enum Purpose: String, Codable, Sendable {
        case permanentDeletion
        case legacyCanvasRemoval
        case incompletePayloadCleanup
        case deletedPageRestore
    }

    struct CatalogAnchor: Codable, Equatable, Hashable, Sendable {
        enum Kind: String, Codable, Sendable {
            case item
            case deletedPage
        }

        let kind: Kind
        let id: UUID
    }

    struct Entry: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable {
            case itemRoot
            case itemRelativeAsset
        }

        let entryID: UUID
        let kind: Kind
        let itemID: UUID
        let relativePath: String?
        let sourceWasPresent: Bool
        let isRequired: Bool
    }

    let version: Int
    let operationID: UUID
    let createdAt: Date
    let purpose: Purpose
    let catalogAnchors: [CatalogAnchor]
    let entries: [Entry]
}

struct LibraryAssetRecoveryIntent: Equatable, Sendable {
    let entryID: UUID
    let kind: LibraryAssetTrashManifest.Entry.Kind
    let itemID: UUID
    let relativePath: String?
    let isRequired: Bool

    static func itemRoot(
        itemID: UUID,
        entryID: UUID = UUID(),
        isRequired: Bool = false
    ) -> Self {
        Self(
            entryID: entryID,
            kind: .itemRoot,
            itemID: itemID,
            relativePath: nil,
            isRequired: isRequired
        )
    }

    static func itemAsset(
        itemID: UUID,
        relativePath: String,
        entryID: UUID = UUID(),
        isRequired: Bool = true
    ) -> Self {
        Self(
            entryID: entryID,
            kind: .itemRelativeAsset,
            itemID: itemID,
            relativePath: relativePath,
            isRequired: isRequired
        )
    }
}

struct LibraryAssetTrashTransaction: Equatable, Sendable {
    let manifest: LibraryAssetTrashManifest
    let catalogCommitMarked: Bool

    var operationID: UUID { manifest.operationID }
}

enum LibraryAssetRecoveryDiscardAuthority: Sendable {
    /// Used by the normal transaction path after its SwiftData save returned.
    case catalogCommitMarker
    /// Used only by startup reconciliation after every captured catalog record
    /// was independently found to be absent.
    case catalogRecordsAbsent
}

public enum LibraryAssetStoreError: Error, Equatable, LocalizedError {
    case invalidRelativePath(String)
    case sourceNotFound(URL)
    case sourceNotRegularFile(URL)
    case assetTooLarge(URL, actualByteCount: Int, maximumByteCount: Int)
    case itemAlreadyExists(UUID)
    case itemNotFound(UUID)
    case destinationOutsideItem
    case symbolicLinkNotAllowed(URL)
    case invalidRecoveryTransaction(UUID)
    case unsupportedRecoveryTransactionVersion(Int)
    case recoveryTransactionConflict(String)
    case recoveryTransactionNotCommitted(UUID)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidRelativePath(path):
            "\(path) is not a safe item-relative asset path."
        case let .sourceNotFound(url):
            "No import source exists at \(url.path)."
        case let .sourceNotRegularFile(url):
            "The import source at \(url.path) is not a regular file."
        case let .assetTooLarge(url, actualByteCount, maximumByteCount):
            "The asset at \(url.path) is \(actualByteCount) bytes, exceeding the \(maximumByteCount)-byte limit."
        case let .itemAlreadyExists(id):
            "Asset storage already exists for \(id)."
        case let .itemNotFound(id):
            "No asset storage exists for \(id)."
        case .destinationOutsideItem:
            "The requested asset destination is outside the item directory."
        case let .symbolicLinkNotAllowed(url):
            "Symbolic links are not allowed in item storage: \(url.path)."
        case let .invalidRecoveryTransaction(id):
            "The recovery transaction \(id) is invalid or incomplete. Its files were preserved."
        case let .unsupportedRecoveryTransactionVersion(version):
            "Recovery transaction version \(version) is not supported. Its files were preserved."
        case let .recoveryTransactionConflict(message):
            "Recovery stopped to avoid overwriting data: \(message)"
        case let .recoveryTransactionNotCommitted(id):
            "Recovery transaction \(id) has no durable catalog-commit acknowledgement."
        case let .io(message):
            "The item assets could not be updated: \(message)"
        }
    }
}

/// Central byte ceilings for asset reads that can otherwise materialize an
/// entire file in memory. The compatibility APIs remain available, while
/// user-visible restore and cover flows opt into the explicit bounds below.
enum LibraryAssetReadLimits {
    static let recoveryManifestByteCount = 1 * 1_024 * 1_024
    static let recoveryCommitMarkerByteCount = 4 * 1_024
    static let legacyMigrationMetadataByteCount = 1 * 1_024 * 1_024
    static let customCoverEncodedByteCount = 128 * 1_024 * 1_024
    static let deletedPageArchiveEncodedByteCount = 128 * 1_024 * 1_024
}

struct LibraryRegularFileIdentity: Equatable, Sendable {
    let device: UInt64
    let inode: UInt64
    let byteCount: Int
    let modificationSeconds: Int64
    let modificationNanoseconds: Int64
}

struct LibraryBoundedFileRead: Sendable {
    let data: Data
    let identity: LibraryRegularFileIdentity
}

/// Opens the final component with `O_NOFOLLOW`, verifies the opened object with
/// `fstat`, and streams no more than the caller's byte budget. A second
/// descriptor stat rejects in-place changes while reading; atomic replacement
/// remains safe because the open descriptor continues to reference one inode.
enum LibraryBoundedFileReader {
    private static let chunkByteCount = 64 * 1_024
    private static let maximumInitialReservationByteCount = 128 * 1_024 * 1_024

    static func identity(
        at source: URL,
        inside allowedRoot: URL,
        maximumByteCount: Int
    ) throws -> LibraryRegularFileIdentity {
        let descriptor = try openRegularFile(
            at: source,
            inside: allowedRoot,
            maximumByteCount: maximumByteCount
        )
        defer { Darwin.close(descriptor.fileDescriptor) }
        return descriptor.identity
    }

    static func read(
        at source: URL,
        inside allowedRoot: URL,
        maximumByteCount: Int
    ) throws -> LibraryBoundedFileRead {
        let descriptor = try openRegularFile(
            at: source,
            inside: allowedRoot,
            maximumByteCount: maximumByteCount
        )
        defer { Darwin.close(descriptor.fileDescriptor) }

        let handle = FileHandle(
            fileDescriptor: descriptor.fileDescriptor,
            closeOnDealloc: false
        )

        var result = Data()
        result.reserveCapacity(min(
            descriptor.identity.byteCount,
            maximumInitialReservationByteCount
        ))

        do {
            while true {
                let remaining = maximumByteCount - result.count
                let requestCount = min(
                    chunkByteCount,
                    remaining == Int.max ? Int.max : remaining + 1
                )
                guard let chunk = try handle.read(upToCount: requestCount),
                    chunk.isEmpty == false else { break }
                guard chunk.count <= remaining else {
                    let (observedByteCount, overflow) = result.count
                        .addingReportingOverflow(chunk.count)
                    throw LibraryAssetStoreError.assetTooLarge(
                        source,
                        actualByteCount: overflow ? Int.max : observedByteCount,
                        maximumByteCount: maximumByteCount
                    )
                }
                result.append(chunk)
            }
        } catch let error as LibraryAssetStoreError {
            throw error
        } catch {
            throw LibraryAssetStoreError.io(
                "Could not read \(source.path): \(error.localizedDescription)"
            )
        }

        let finalIdentity = try fileIdentity(
            descriptor.fileDescriptor,
            source: source,
            maximumByteCount: maximumByteCount
        )
        guard finalIdentity == descriptor.identity,
            finalIdentity.byteCount == result.count else {
            throw LibraryAssetStoreError.io(
                "The asset at \(source.path) changed while it was being read."
            )
        }

        return LibraryBoundedFileRead(data: result, identity: finalIdentity)
    }

    /// Streams a verified regular file into a new temporary destination. The
    /// caller owns publication of that temporary file after this returns.
    @discardableResult
    static func copy(
        from source: URL,
        inside allowedRoot: URL,
        to destination: URL,
        maximumByteCount: Int
    ) throws -> LibraryRegularFileIdentity {
        let sourceDescriptor = try openRegularFile(
            at: source,
            inside: allowedRoot,
            maximumByteCount: maximumByteCount
        )
        defer { Darwin.close(sourceDescriptor.fileDescriptor) }

        let destinationDescriptor = Darwin.open(
            destination.path,
            O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            S_IRUSR | S_IWUSR
        )
        guard destinationDescriptor >= 0 else {
            throw LibraryAssetStoreError.io(
                "Could not create the staged asset at \(destination.path)."
            )
        }
        defer { Darwin.close(destinationDescriptor) }

        let sourceHandle = FileHandle(
            fileDescriptor: sourceDescriptor.fileDescriptor,
            closeOnDealloc: false
        )
        let destinationHandle = FileHandle(
            fileDescriptor: destinationDescriptor,
            closeOnDealloc: false
        )
        var copiedByteCount = 0
        do {
            while true {
                let remaining = maximumByteCount - copiedByteCount
                let requestCount = min(
                    chunkByteCount,
                    remaining == Int.max ? Int.max : remaining + 1
                )
                guard let chunk = try sourceHandle.read(upToCount: requestCount),
                    chunk.isEmpty == false else { break }
                let (observedByteCount, overflow) = copiedByteCount
                    .addingReportingOverflow(chunk.count)
                guard overflow == false, chunk.count <= remaining else {
                    throw LibraryAssetStoreError.assetTooLarge(
                        source,
                        actualByteCount: overflow ? Int.max : observedByteCount,
                        maximumByteCount: maximumByteCount
                    )
                }
                try destinationHandle.write(contentsOf: chunk)
                copiedByteCount = observedByteCount
            }
            try destinationHandle.synchronize()
        } catch let error as LibraryAssetStoreError {
            throw error
        } catch {
            throw LibraryAssetStoreError.io(
                "Could not copy \(source.path): \(error.localizedDescription)"
            )
        }
        let finalIdentity = try fileIdentity(
            sourceDescriptor.fileDescriptor,
            source: source,
            maximumByteCount: maximumByteCount
        )
        guard finalIdentity == sourceDescriptor.identity,
            finalIdentity.byteCount == copiedByteCount else {
            throw LibraryAssetStoreError.io(
                "The asset at \(source.path) changed while it was being copied."
            )
        }
        return finalIdentity
    }

    private static func openRegularFile(
        at source: URL,
        inside allowedRoot: URL,
        maximumByteCount: Int
    ) throws -> (fileDescriptor: Int32, identity: LibraryRegularFileIdentity) {
        guard maximumByteCount > 0 else {
            throw LibraryAssetStoreError.io("An asset read requires a positive byte limit.")
        }
        let source = source.standardizedFileURL
        let allowedRoot = allowedRoot.standardizedFileURL
        guard source.path == allowedRoot.path
            || source.path.hasPrefix(allowedRoot.path + "/") else {
            throw LibraryAssetStoreError.destinationOutsideItem
        }
        try validateNoSymbolicLinks(from: allowedRoot, through: source)
        let descriptor = Darwin.open(source.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else {
            if errno == ELOOP {
                throw LibraryAssetStoreError.symbolicLinkNotAllowed(source)
            }
            throw LibraryAssetStoreError.sourceNotRegularFile(source)
        }
        do {
            return (
                descriptor,
                try fileIdentity(
                    descriptor,
                    source: source,
                    maximumByteCount: maximumByteCount
                )
            )
        } catch {
            Darwin.close(descriptor)
            throw error
        }
    }

    private static func fileIdentity(
        _ descriptor: Int32,
        _ source: URL,
        maximumByteCount: Int
    ) throws -> LibraryRegularFileIdentity {
        var information = stat()
        guard Darwin.fstat(descriptor, &information) == 0 else {
            throw LibraryAssetStoreError.io("Could not inspect \(source.path).")
        }
        guard information.st_mode & S_IFMT == S_IFREG,
            information.st_size >= 0,
            UInt64(information.st_size) <= UInt64(Int.max) else {
            throw LibraryAssetStoreError.sourceNotRegularFile(source)
        }
        let byteCount = Int(information.st_size)
        guard byteCount <= maximumByteCount else {
            throw LibraryAssetStoreError.assetTooLarge(
                source,
                actualByteCount: byteCount,
                maximumByteCount: maximumByteCount
            )
        }
        return LibraryRegularFileIdentity(
            device: UInt64(information.st_dev),
            inode: UInt64(information.st_ino),
            byteCount: byteCount,
            modificationSeconds: Int64(information.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(information.st_mtimespec.tv_nsec)
        )
    }

    private static func validateNoSymbolicLinks(
        from root: URL,
        through candidate: URL
    ) throws {
        let fileManager = FileManager.default
        var current = root
        let suffix = candidate.path.dropFirst(root.path.count)
        let components = [""] + suffix.split(separator: "/").map(String.init)
        for component in components {
            if component.isEmpty == false { current.appendPathComponent(component) }
            let attributes: [FileAttributeKey: Any]
            do {
                attributes = try fileManager.attributesOfItem(atPath: current.path)
            } catch {
                throw LibraryAssetStoreError.sourceNotRegularFile(candidate)
            }
            if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
                throw LibraryAssetStoreError.symbolicLinkNotAllowed(current)
            }
        }
    }
}

/// Owns all large payloads outside SwiftData. Every item has the layout:
/// `NotateLibrary/Items/<UUID>/{Canvas,Sources,Thumbnails,Freeform}`
/// New trees are assembled under `Staging` and atomically moved into place.
/// Individual file updates use an adjacent temporary file and atomic replace.
/// ...

public actor LibraryAssetStore {
    private struct RecoveryCommitMarker: Codable, Equatable, Sendable {
        static let currentSchemaVersion = 1

        let version: Int
        let operationID: UUID
    }

    public let libraryRoot: URL
    private let fileManager: FileManager
    public init(libraryRoot: URL) {
        self.libraryRoot = libraryRoot.standardizedFileURL
        fileManager = FileManager()
    }


    public static func live() throws -> LibraryAssetStore {
        let fileManager = FileManager.default
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return LibraryAssetStore(
            libraryRoot: applicationSupport.appendingPathComponent(
                "NotateLibrary",
                isDirectory: true
            )
        )
    }

    public nonisolated func directories(for itemID: UUID) -> LibraryItemAssetDirectories {
        LibraryItemAssetDirectories(
            itemRoot: libraryRoot
                .appendingPathComponent("Items", isDirectory: true)
                .appendingPathComponent(itemID.uuidString, isDirectory: true)
        )
    }



    @discardableResult
    public func prepareItem(
        id itemID: UUID
    ) throws -> LibraryItemAssetDirectories {
        do {
            try prepareLibraryDirectories()
            let directories = directories(for: itemID)
            if try fileType(at: directories.itemRoot) != nil {
                try requireDirectory(directories.itemRoot, inside: itemsDirectory)
                try ensureCategoryDirectories(directories)
                return directories
            }
            let stagingRoot = stagingDirectory.appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
            let stagedDirectories = LibraryItemAssetDirectories(itemRoot: stagingRoot)
            try fileManager.createDirectory(
                at: stagedDirectories.itemRoot,
                withIntermediateDirectories: true
            )
            try ensureCategoryDirectories(stagedDirectories)
            do {
                try fileManager.moveItem(
                    at: stagedDirectories.itemRoot,
                    to: directories.itemRoot
                )
            } catch {
                try? fileManager.removeItem(at: stagedDirectories.itemRoot)
                throw error
            }
            return directories
        } catch let error as LibraryAssetStoreError {
            throw error
        } catch {
            throw LibraryAssetStoreError.io(String(describing: error))
        }
    }
    public func itemExists(id itemID: UUID) -> Bool {
        let root = directories(for: itemID).itemRoot
        return (try? fileType(at: root)) == .typeDirectory
    }

    public func url(
        for relativePath: String,
        itemID: UUID
    ) throws -> URL {
        guard LibraryAssetPath.isSafeRelative(relativePath) else {
            throw LibraryAssetStoreError.invalidRelativePath(relativePath)
        }
        let root = directories(for: itemID).itemRoot.standardizedFileURL
        let candidate = root.appendingPathComponent(relativePath).standardizedFileURL
        try validateNoSymbolicLinks(from: root, through: candidate)
        return candidate
    }

    @discardableResult
    public func write(
        _ data: Data,
        named relativePath: String,
        category: LibraryAssetCategory,
        for itemID: UUID
    ) throws -> URL {
        guard LibraryAssetPath.isSafeRelative(relativePath) else {
            throw LibraryAssetStoreError.invalidRelativePath(relativePath)
        }
        do {
            let directories = try prepareItem(id: itemID)
            let categoryRoot = directories[category].standardizedFileURL
            let destination = categoryRoot
                .appendingPathComponent(relativePath)
                .standardizedFileURL
            try validateNoSymbolicLinks(from: categoryRoot, through: destination)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try validateNoSymbolicLinks(from: categoryRoot, through: destination)
            let temporary = adjacentTemporaryURL(for: destination)
            do {
                try data.write(to: temporary, options: [.atomic])
                try atomicallyInstall(temporary, at: destination)
            } catch {
                try? fileManager.removeItem(at: temporary)
                throw error
            }
            return destination
        } catch let error as LibraryAssetStoreError {
            throw error
        } catch {
            throw LibraryAssetStoreError.io(String(describing: error))
        }
    }


    /// Refuses oversized payloads before staging any bytes on disk.
    @discardableResult
    public func write(
        _ data: Data,
        named relativePath: String,
        category: LibraryAssetCategory,
        for itemID: UUID,
        maximumByteCount: Int
    ) throws -> URL {
        guard LibraryAssetPath.isSafeRelative(relativePath) else {
            throw LibraryAssetStoreError.invalidRelativePath(relativePath)
        }
        let destination = directories(for: itemID)[category]
            .appendingPathComponent(relativePath)
            .standardizedFileURL
        guard maximumByteCount > 0, data.count <= maximumByteCount else {
            throw LibraryAssetStoreError.assetTooLarge(
                destination,
                actualByteCount: data.count,
                maximumByteCount: max(0, maximumByteCount)
            )
        }
        return try write(
            data,
            named: relativePath,
            category: category,
            for: itemID
        )
    }


    /// Copies an app-owned regular file into item storage with constant-size
    /// buffers. This avoids retaining both a decoded document and another full
    /// encoded `Data` during legacy migration.
    @discardableResult
    public func copyFile(
        from source: URL,
        inside sourceRoot: URL,
        named relativePath: String,
        category: LibraryAssetCategory,
        for itemID: UUID,
        maximumByteCount: Int
    ) throws -> URL {
        guard LibraryAssetPath.isSafeRelative(relativePath) else {
            throw LibraryAssetStoreError.invalidRelativePath(relativePath)
        }
        do {
            let directories = try prepareItem(id: itemID)
            let categoryRoot = directories[category].standardizedFileURL
            let destination = categoryRoot
                .appendingPathComponent(relativePath)
                .standardizedFileURL
            try validateNoSymbolicLinks(from: categoryRoot, through: destination)
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try validateNoSymbolicLinks(from: categoryRoot, through: destination)
            let temporary = adjacentTemporaryURL(for: destination)
            do {
                _ = try LibraryBoundedFileReader.copy(
                    from: source.standardizedFileURL,
                    inside: sourceRoot.standardizedFileURL,
                    to: temporary,
                    maximumByteCount: maximumByteCount
                )
                try atomicallyInstall(temporary, at: destination)
            } catch {
                try? fileManager.removeItem(at: temporary)
                throw error
            }
            return destination
        } catch let error as LibraryAssetStoreError {
            throw error
        } catch {
            throw LibraryAssetStoreError.io(String(describing: error))
        }
    }


    public func read(
        named relativePath: String,
        category: LibraryAssetCategory,
        for itemID: UUID
    ) throws -> Data {
        try read(
            named: relativePath,
            category: category,
            for: itemID,
            maximumByteCount: Int.max
        )
    }


    /// Reads an item-category file without ever materializing more than the
    /// supplied byte budget. Callers handling user-visible media should use
    /// this overload instead of the compatibility API above.
    public func read(
        named relativePath: String,
        category: LibraryAssetCategory,
        for itemID: UUID,
        maximumByteCount: Int
    ) throws -> Data {
        guard LibraryAssetPath.isSafeRelative(relativePath) else {
            throw LibraryAssetStoreError.invalidRelativePath(relativePath)
        }
        let root = directories(for: itemID)[category].standardizedFileURL
        let source = root.appendingPathComponent(relativePath).standardizedFileURL
        do {
            try validateNoSymbolicLinks(from: root, through: source)
            guard try fileType(at: source) == .typeRegular else {
                throw LibraryAssetStoreError.sourceNotRegularFile(source)
            }
            return try LibraryBoundedFileReader.read(
                at: source,
                inside: root,
                maximumByteCount: maximumByteCount
            ).data
        } catch let error as LibraryAssetStoreError {
            throw error
        } catch {
            throw LibraryAssetStoreError.io(String(describing: error))
        }
    }


    /// Reads a path relative to the item root, such as
    /// `Canvas/deleted-page-<UUID>.notate-page`.
    public func readItemAsset(
        at relativePath: String,
        for itemID: UUID
    ) throws -> Data {
        try readItemAsset(
            at: relativePath,
            for: itemID,
            maximumByteCount: Int.max
        )
    }


    /// Bounded variant for full item-relative paths such as custom covers and
    /// deleted-page archives.
    public func readItemAsset(
        at relativePath: String,
        for itemID: UUID,
        maximumByteCount: Int
    ) throws -> Data {
        guard LibraryAssetPath.isSafeRelative(relativePath) else {
            throw LibraryAssetStoreError.invalidRelativePath(relativePath)
        }
        do {
            let source = try url(for: relativePath, itemID: itemID)
            guard try fileType(at: source) == .typeRegular else {
                throw LibraryAssetStoreError.sourceNotRegularFile(source)
            }
            return try LibraryBoundedFileReader.read(
                at: source,
                inside: directories(for: itemID).itemRoot,
                maximumByteCount: maximumByteCount
            ).data
        } catch let error as LibraryAssetStoreError {
            throw error
        } catch {
            throw LibraryAssetStoreError.io(String(describing: error))
        }
    }


    /// Copies a security-scoped picker result into the item's Sources folder.
    @discardableResult
    public func importSource(
        from sourceURL: URL,
        suggestedFilename: String? = nil,
        for itemID: UUID
    ) throws -> URL {
        let accessed = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if accessed { sourceURL.stopAccessingSecurityScopedResource() }
        }
        guard fileManager.fileExists(atPath: sourceURL.path) else {
            throw LibraryAssetStoreError.sourceNotFound(sourceURL)
        }
        do {
            guard try fileType(at: sourceURL) == .typeRegular else {
                throw LibraryAssetStoreError.sourceNotRegularFile(sourceURL)
            }
        } catch let error as LibraryAssetStoreError {
            throw error
        } catch {
            throw LibraryAssetStoreError.io(String(describing: error))
        }
        let requestedName = suggestedFilename?.nilIfLibraryBlank
            ?? sourceURL.lastPathComponent.nilIfLibraryBlank
            ?? "Imported File"
        let filename = URL(fileURLWithPath: requestedName).lastPathComponent
        guard LibraryAssetPath.isSafeRelative(filename) else {
            throw LibraryAssetStoreError.invalidRelativePath(requestedName)
        }
        do {
            let directories = try prepareItem(id: itemID)
            let destination = directories.sources.appendingPathComponent(filename)
            try validateNoSymbolicLinks(
                from: directories.sources,
                through: destination
            )
            let temporary = adjacentTemporaryURL(for: destination)
            do {
                try fileManager.copyItem(at: sourceURL, to: temporary)
                try atomicallyInstall(temporary, at: destination)
            } catch {
                try? fileManager.removeItem(at: temporary)
                throw error
            }
            return destination
        } catch let error as LibraryAssetStoreError {
            throw error
        } catch {
            throw LibraryAssetStoreError.io(String(describing: error))
        }
    }


    /// Crash-safe whole-item copy used after a recursive catalog duplicate.
    public func duplicateItemAssets(from sourceID: UUID, to targetID: UUID) throws {
        do {
            try prepareLibraryDirectories()
            let source = directories(for: sourceID).itemRoot
            let target = directories(for: targetID).itemRoot
            guard try fileType(at: source) == .typeDirectory else {
                throw LibraryAssetStoreError.itemNotFound(sourceID)
            }
            try requireDirectory(source, inside: itemsDirectory)
            try validateTreeContainsNoSymbolicLinks(at: source)
            guard try fileType(at: target) == nil else {
                throw LibraryAssetStoreError.itemAlreadyExists(targetID)
            }
            let stagedRoot = stagingDirectory.appendingPathComponent(
                UUID().uuidString,
                isDirectory: true
            )
            do {
                try fileManager.copyItem(at: source, to: stagedRoot)
                try ensureCategoryDirectories(LibraryItemAssetDirectories(itemRoot: stagedRoot))
                try fileManager.moveItem(at: stagedRoot, to: target)
            } catch {
                try? fileManager.removeItem(at: stagedRoot)
                throw error
            }
        } catch let error as LibraryAssetStoreError {
            throw error
        } catch {
            throw LibraryAssetStoreError.io(String(describing: error))
        }
    }


    /// Stages every member of a recursive duplicate before publishing target
    /// directories. Missing source directories become valid empty item roots
    /// (for example, folders with metadata only). A caught commit failure rolls
    /// back every target already installed during this call.
    public func duplicateItemAssets(
        using sourceToTargetItemIDs: [UUID: UUID]
    ) throws {
        guard Set(sourceToTargetItemIDs.values).count == sourceToTargetItemIDs.count else {
            throw LibraryAssetStoreError.io("A duplicate target ID was reused.")
        }
        guard sourceToTargetItemIDs.allSatisfy({ $0.key != $0.value }) else {
            throw LibraryAssetStoreError.io("An item cannot duplicate assets onto itself.")
        }
        do {
            try prepareLibraryDirectories()
            let operationRoot = stagingDirectory.appendingPathComponent(
                "Duplicate-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.createDirectory(at: operationRoot, withIntermediateDirectories: true)
            var installedTargets: [URL] = []
            defer { try? fileManager.removeItem(at: operationRoot) }
            for (sourceID, targetID) in sourceToTargetItemIDs.sorted(by: {
                $0.key.uuidString < $1.key.uuidString
            }) {
                let target = directories(for: targetID).itemRoot
                guard try fileType(at: target) == nil else {
                    throw LibraryAssetStoreError.itemAlreadyExists(targetID)
                }
                let staged = operationRoot.appendingPathComponent(
                    targetID.uuidString,
                    isDirectory: true
                )
                let source = directories(for: sourceID).itemRoot
                if try fileType(at: source) == .typeDirectory {
                    try requireDirectory(source, inside: itemsDirectory)
                    try validateTreeContainsNoSymbolicLinks(at: source)
                    try fileManager.copyItem(at: source, to: staged)
                } else {
                    try fileManager.createDirectory(at: staged, withIntermediateDirectories: true)
                    try ensureCategoryDirectories(
                        LibraryItemAssetDirectories(itemRoot: staged)
                    )
                }
            }
            do {
                for targetID in sourceToTargetItemIDs.values.sorted(by: {
                    $0.uuidString < $1.uuidString
                }) {
                    let staged = operationRoot.appendingPathComponent(
                        targetID.uuidString,
                        isDirectory: true
                    )
                    let target = directories(for: targetID).itemRoot
                    guard try fileType(at: target) == nil else {
                        throw LibraryAssetStoreError.itemAlreadyExists(targetID)
                    }
                    try fileManager.moveItem(at: staged, to: target)
                    installedTargets.append(target)
                }
            } catch {
                for target in installedTargets.reversed() {
                    try? fileManager.removeItem(at: target)
                }
                throw error
            }
        } catch let error as LibraryAssetStoreError {
            throw error
        } catch {
            throw LibraryAssetStoreError.io(String(describing: error))
        }
    }

    /// Installs an immutable recovery journal before moving the first authored
    /// byte. A visible transaction therefore always describes how to either
    /// restore its payload or discard it after the catalog save is known to
    /// have committed.
    func stageRecoveryTransaction(
        operationID: UUID = UUID(),
        purpose: LibraryAssetTrashManifest.Purpose,
        catalogAnchors: [LibraryAssetTrashManifest.CatalogAnchor],
        intents: [LibraryAssetRecoveryIntent],
        createdAt: Date = .now
    ) throws -> LibraryAssetTrashTransaction {
        do {
            try prepareLibraryDirectories()
            let anchors = try normalizedRecoveryAnchors(catalogAnchors)
            let normalizedIntents = try normalizedRecoveryIntents(intents)
            let destination = try recoveryTransactionDirectory(operationID: operationID)
            guard try fileType(at: destination) == nil else {
                throw LibraryAssetStoreError.invalidRecoveryTransaction(operationID)
            }
            var entries: [LibraryAssetTrashManifest.Entry] = []
            entries.reserveCapacity(normalizedIntents.count)
            for intent in normalizedIntents {
                let source = try recoverySourceURL(for: intent)
                let type = try fileType(at: source)
                if type == .typeSymbolicLink {
                    throw LibraryAssetStoreError.symbolicLinkNotAllowed(source)
                }
                if let type {
                    switch intent.kind {
                    case .itemRoot:
                        guard type == .typeDirectory else {
                            throw LibraryAssetStoreError.sourceNotRegularFile(source)
                        }
                        try requireDirectory(source, inside: itemsDirectory)
                        try validateTreeContainsNoSymbolicLinks(at: source)
                    case .itemRelativeAsset:
                        if type == .typeDirectory {
                            try validateTreeContainsNoSymbolicLinks(at: source)
                        }
                    }
                } else if intent.isRequired {
                    throw LibraryAssetStoreError.sourceNotFound(source)
                }
                entries.append(LibraryAssetTrashManifest.Entry(
                    entryID: intent.entryID,
                    kind: intent.kind,
                    itemID: intent.itemID,
                    relativePath: intent.relativePath,
                    sourceWasPresent: intent.type != nil,
                    isRequired: intent.isRequired
                ))
            }
            // Match the durable JSON precision so the handle returned to the
            // caller compares exactly with a manifest reopened from disk.
            let durableCreatedAt = Date(
                timeIntervalSince1970: floor(
                    createdAt.timeIntervalSince1970 * 1_000
                ) / 1_000
            )
            let manifest = LibraryAssetTrashManifest(
                version: LibraryAssetTrashManifest.currentSchemaVersion,
                operationID: operationID,
                createdAt: durableCreatedAt,
                purpose: purpose,
                catalogAnchors: anchors,
                entries: entries
            )
            let preparing = stagingDirectory.appendingPathComponent(
                "AssetTrash-\(operationID.uuidString)",
                isDirectory: true
            )
            guard try fileType(at: preparing) == nil else {
                throw LibraryAssetStoreError.invalidRecoveryTransaction(operationID)
            }
            do {
                try fileManager.createDirectory(
                    at: recoveryPayloadDirectory(in: preparing),
                    withIntermediateDirectories: true
                )
                let manifestData = try JSONEncoder.libraryRecoveryEncoder.encode(manifest)
                try writeSynchronized(
                    manifestData,
                    to: recoveryManifestURL(in: preparing)
                )
                try synchronizeDirectory(preparing, to: destination)
                try fileManager.moveItem(at: preparing, to: destination)
                try synchronizeDirectory(recoveryTransactionsDirectory)
            } catch {
                try? fileManager.removeItem(at: preparing)
                throw error
            }
            let transaction = LibraryAssetTrashTransaction(
                manifest: manifest,
                catalogCommitMarked: false
            )
            do {
                for entry in entries where entry.sourceWasPresent {
                    let source = try recoverySourceURL(for: entry)
                    let payload = try recoveryPayloadURL(for: entry, in: destination)
                    guard try fileType(at: payload) == nil else {
                        throw LibraryAssetStoreError.recoveryTransactionConflict(
                            "A staged payload already exists for \(entry.entryID)."
                        )
                    }
                    try fileManager.moveItem(at: source, to: payload)
                    try synchronizeDirectory(payload.deletingLastPathComponent())
                    try synchronizeDirectory(source.deletingLastPathComponent())
                }
            } catch {
                let stagingError = error
                do {
                    try restoreRecoveryTransaction(transaction)
                } catch {
                    throw LibraryAssetStoreError.io(
                        "Recovery staging failed and rollback is still pending in AssetTrash: \(error.localizedDescription)"
                    )
                }
                throw stagingError
            }
            return transaction
        } catch let error as LibraryAssetStoreError {
            throw error
        } catch {
            throw LibraryAssetStoreError.io(String(describing: error))
        }
    }


    /// Records the catalog save as a separate, durable fact. The immutable
    /// manifest is never rewritten, avoiding a corrupt half-updated journal.
    @discardableResult
    func markCatalogCommitted(
        _ transaction: LibraryAssetTrashTransaction
    ) throws -> LibraryAssetTrashTransaction {
        do {
            let directory = try verifiedRecoveryTransactionDirectory(transaction)
            let markerURL = recoveryCommitMarkerURL(in: directory)
            if try fileType(at: markerURL) != nil {
                let marker = try readRecoveryCommitMarker(at: markerURL)
                guard marker.operationID == transaction.operationID else {
                    throw LibraryAssetStoreError.invalidRecoveryTransaction(
                        transaction.operationID
                    )
                }
            } else {
                let marker = RecoveryCommitMarker(
                    version: RecoveryCommitMarker.currentSchemaVersion,
                    operationID: transaction.operationID
                )
                try writeSynchronized(
                    JSONEncoder.libraryRecoveryEncoder.encode(marker),
                    to: markerURL
                )
                try synchronizeDirectory(directory)
            }
            return LibraryAssetTrashTransaction(
                manifest: transaction.manifest,
                catalogCommitMarked: true
            )
        } catch let error as LibraryAssetStoreError {
            throw error
        } catch {
            throw LibraryAssetStoreError.io(String(describing: error))
        }
    }


    /// Restores a pre-commit transaction without overwriting any path that was
    /// recreated independently. The journal is retained on every ambiguity.
    func restoreRecoveryTransaction(
        _ transaction: LibraryAssetTrashTransaction
    ) throws {
        do {
            let directory = try verifiedRecoveryTransactionDirectory(transaction)
            guard try recoveryCommitMarkerIfPresent(in: directory) == nil else {
                throw LibraryAssetStoreError.recoveryTransactionConflict(
                    "Transaction \(transaction.operationID) is already catalog-committed."
                )
            }
            for entry in transaction.manifest.entries.reversed() {
                let source = try recoverySourceURL(for: entry)
                let payload = try recoveryPayloadURL(for: entry, in: directory)
                let sourceType = try fileType(at: source)
                let payloadType = try fileType(at: payload)
                if sourceType == .typeSymbolicLink {
                    throw LibraryAssetStoreError.symbolicLinkNotAllowed(source)
                }
                if payloadType == .typeSymbolicLink {
                    throw LibraryAssetStoreError.symbolicLinkNotAllowed(payload)
                }
                switch (sourceType, payloadType, entry.sourceWasPresent) {
                case (nil, .some, true):
                    try prepareRecoveryRestoreDestination(for: entry, source: source)
                    try fileManager.moveItem(at: payload, to: source)
                    try synchronizeDirectory(source.deletingLastPathComponent())
                    try synchronizeDirectory(payload.deletingLastPathComponent())
                case (.some, nil, true):
                    // A previous recovery pass already restored this entry.
                    continue
                case (.some, .some, _):
                    throw LibraryAssetStoreError.recoveryTransactionConflict(
                        "Both the original and recovery copy exist for \(entry.entryID)."
                    )
                case (nil, nil, true):
                    throw LibraryAssetStoreError.recoveryTransactionConflict(
                        "Both copies are missing for \(entry.entryID)."
                    )
                case (_, .some, false):
                    throw LibraryAssetStoreError.recoveryTransactionConflict(
                        "An originally absent entry unexpectedly has a recovery payload."
                    )
                case (_, nil, false):
                    continue
                }
            }

            try validateTreeContainsNoSymbolicLinks(at: directory)
            try fileManager.removeItem(at: directory)
            try synchronizeDirectory(recoveryTransactionsDirectory)
        } catch let error as LibraryAssetStoreError {
            throw error
        } catch {
            throw LibraryAssetStoreError.io(String(describing: error))
        }
    }


    /// Removes a committed recovery payload. Startup may also authorize this
    /// when every record captured by the manifest is absent from the freshly
    /// opened catalog, covering a crash between the SwiftData save and marker.
    func discardRecoveryTransaction(
        _ transaction: LibraryAssetTrashTransaction,
        authority: LibraryAssetRecoveryDiscardAuthority = .catalogCommitMarker
    ) throws {
        do {
            let directory = try verifiedRecoveryTransactionDirectory(transaction)
            switch authority {
            case .catalogCommitMarker:
                guard try recoveryCommitMarkerIfPresent(in: directory) != nil else {
                    throw LibraryAssetStoreError.recoveryTransactionNotCommitted(
                        transaction.operationID
                    )
                }
            case .catalogRecordsAbsent:
                break
            }

            for entry in transaction.manifest.entries {
                let source = try recoverySourceURL(for: entry)
                let payload = try recoveryPayloadURL(for: entry, in: directory)
                let sourceType = try fileType(at: source)
                let payloadType = try fileType(at: payload)
                if sourceType != nil {
                    throw LibraryAssetStoreError.recoveryTransactionConflict(
                        "The original path still exists for \(entry.entryID)."
                    )
                }
                if payloadType == .typeSymbolicLink {
                    throw LibraryAssetStoreError.symbolicLinkNotAllowed(payload)
                }
                if entry.sourceWasPresent == false, payloadType != nil {
                    throw LibraryAssetStoreError.recoveryTransactionConflict(
                        "An originally absent entry unexpectedly has a recovery payload."
                    )
                }
            }

            try validateTreeContainsNoSymbolicLinks(at: directory)
            try fileManager.removeItem(at: directory)
            try synchronizeDirectory(recoveryTransactionsDirectory)
        } catch let error as LibraryAssetStoreError {
            throw error
        } catch {
            throw LibraryAssetStoreError.io(String(describing: error))
        }
    }


    /// Returns only journaled transactions. Random entries written by older
    /// builds directly under AssetTrash are deliberately ignored and retained.
    func pendingRecoveryTransactions() throws -> [LibraryAssetTrashTransaction] {
        do {
            try prepareLibraryDirectories()
            let candidates = try fileManager.contentsOfDirectory(
                at: recoveryTransactionsDirectory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: []
            ).sorted { $0.lastPathComponent < $1.lastPathComponent }
            var transactions: [LibraryAssetTrashTransaction] = []
            transactions.reserveCapacity(candidates.count)
            for candidate in candidates {
                let values = try candidate.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                guard values.isDirectory == true,
                    values.isSymbolicLink != true,
                    let operationID = UUID(uuidString: candidate.lastPathComponent) else {
                    throw LibraryAssetStoreError.invalidRecoveryTransaction(
                        UUID(uuidString: candidate.lastPathComponent) ?? UUID.zeroLibraryRecovery
                    )
                }
                let manifest = try readRecoveryManifest(
                    at: recoveryManifestURL(in: candidate),
                    expectedOperationID: operationID
                )
                let marker = try recoveryCommitMarkerIfPresent(in: candidate)
                transactions.append(LibraryAssetTrashTransaction(
                    manifest: manifest,
                    catalogCommitMarked: marker != nil
                ))
            }
            return transactions
        } catch let error as LibraryAssetStoreError {
            throw error
        } catch {
            throw LibraryAssetStoreError.io(String(describing: error))
        }
    }


    /// Moves one page or other item-relative payload into recoverable storage.
    /// This is the filesystem half of two-phase page restore/purge operations.
    @discardableResult
    public func moveAssetToRecoveryTrash(
        itemID: UUID,
        relativePath: String
    ) throws -> LibraryAssetRecoveryEntry? {
        do {
            try prepareLibraryDirectories()
            let source = try url(for: relativePath, itemID: itemID)
            guard let type = try fileType(at: source) else { return nil }
            if type == .typeSymbolicLink {
                throw LibraryAssetStoreError.symbolicLinkNotAllowed(source)
            }
            if type == .typeDirectory {
                try validateTreeContainsNoSymbolicLinks(at: source)
            }
            let destination = recoveryDirectory.appendingPathComponent(
                "Asset-\(UUID().uuidString)"
            )
            try fileManager.moveItem(at: source, to: destination)
            return LibraryAssetRecoveryEntry(
                itemID: itemID,
                relativePath: relativePath,
                recoveryURL: destination
            )
        } catch let error as LibraryAssetStoreError {
            throw error
        } catch {
            throw LibraryAssetStoreError.io(String(describing: error))
        }
    }


    /// Recovery-aware delete for a full item-relative path. The returned entry
    /// must be discarded only after the matching catalog mutation commits, or
    /// restored if that mutation fails.
    @discardableResult
    public func deleteItemAsset(
        at relativePath: String,
        for itemID: UUID
    ) throws -> LibraryAssetRecoveryEntry? {
        try moveAssetToRecoveryTrash(itemID: itemID, relativePath: relativePath)
    }


    public func restoreAssetFromRecovery(
        _ entry: LibraryAssetRecoveryEntry
    ) throws {
        do {
            try prepareLibraryDirectories()
            let source = Self.lexicallyStandardizedFileURL(entry.recoveryURL)
            let recoveryRoot = Self.lexicallyStandardizedFileURL(recoveryDirectory)
            guard try isDirectChild(source, of: recoveryRoot) else {
                throw LibraryAssetStoreError.sourceNotFound(entry.recoveryURL)
            }
            let type = try fileType(at: source)
            if type == .typeSymbolicLink {
                throw LibraryAssetStoreError.symbolicLinkNotAllowed(source)
            }
            if type == .typeDirectory {
                try validateTreeContainsNoSymbolicLinks(at: source)
            }
            _ = try prepareItem(id: entry.itemID)
            let destination = try url(
                for: entry.relativePath,
                itemID: entry.itemID
            )
            guard try fileType(at: destination) == nil else {
                throw LibraryAssetStoreError.io(
                    "An asset already exists at \(entry.relativePath)."
                )
            }
            try fileManager.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try validateNoSymbolicLinks(
                from: directories(for: entry.itemID).itemRoot,
                through: destination
            )
            try fileManager.moveItem(at: source, to: destination)
        } catch let error as LibraryAssetStoreError {
            throw error
        } catch {
            throw LibraryAssetStoreError.io(String(describing: error))
        }
    }

    public func discardRecoveryAsset(_ entry: LibraryAssetRecoveryEntry) throws {
        try discardRecoveryItem(at: entry.recoveryURL)
    }

    /// First phase of asset deletion. Moving to recovery storage is atomic on
    /// the same volume and lets callers restore files if later work fails.
    @discardableResult
    public func moveItemAssetsToRecoveryTrash(itemID: UUID) throws -> URL? {
        do {
            try prepareLibraryDirectories()
            let source = directories(for: itemID).itemRoot
            guard try fileType(at: source) != nil else { return nil }
            try requireDirectory(source, inside: itemsDirectory)
            let destination = recoveryDirectory.appendingPathComponent(
                "\(itemID.uuidString)-\(UUID().uuidString)",
                isDirectory: true
            )
            try fileManager.moveItem(at: source, to: destination)
            return destination
        } catch {
            throw LibraryAssetStoreError.io(String(describing: error))
        }
    }

    public func restoreItemAssets(
        from recoveryURL: URL,
        to itemID: UUID
    ) throws {
        do {
            try prepareLibraryDirectories()
            let recoveryRoot = Self.lexicallyStandardizedFileURL(recoveryDirectory)
            let source = Self.lexicallyStandardizedFileURL(recoveryURL)
            guard try isDirectChild(source, of: recoveryRoot),
                try fileType(at: source) != nil else {
                throw LibraryAssetStoreError.sourceNotFound(recoveryURL)
            }
            try requireDirectory(source, inside: recoveryRoot)
            try validateTreeContainsNoSymbolicLinks(at: source)
            try ensureCategoryDirectories(
                LibraryItemAssetDirectories(itemRoot: source)
            )
            let destination = directories(for: itemID).itemRoot
            guard try fileType(at: destination) == nil else {
                throw LibraryAssetStoreError.itemAlreadyExists(itemID)
            }
            try fileManager.moveItem(at: source, to: destination)
        } catch let error as LibraryAssetStoreError {
            throw error
        } catch {
            throw LibraryAssetStoreError.io(String(describing: error))
        }
    }

    /// Finalizes a successful catalog deletion. The URL must be one returned by
    /// moveItemAssetsToRecoveryTrash(id:).
    public func discardRecoveryItem(at recoveryURL: URL) throws {
        let recoveryRoot = Self.lexicallyStandardizedFileURL(recoveryDirectory)
        let candidate = Self.lexicallyStandardizedFileURL(recoveryURL)
        guard try isDirectChild(candidate, of: recoveryRoot) else {
            throw LibraryAssetStoreError.destinationOutsideItem
        }
        guard try fileType(at: candidate) != nil else { return }
        if try fileType(at: candidate) == .typeSymbolicLink {
            throw LibraryAssetStoreError.symbolicLinkNotAllowed(candidate)
        }
        do {
            try fileManager.removeItem(at: candidate)
        } catch {
            throw LibraryAssetStoreError.io(String(describing: error))
        }
    }

    private func normalizedRecoveryAnchors(
        anchors: [LibraryAssetTrashManifest.CatalogAnchor]
    ) throws -> [LibraryAssetTrashManifest.CatalogAnchor] {
        guard anchors.isEmpty == false,
            Set(anchors).count == anchors.count else {
            throw LibraryAssetStoreError.recoveryTransactionConflict(
                "A recovery transaction requires unique catalog anchors."
            )
        }

        return anchors.sorted { lhs, rhs in
            if lhs.kind.rawValue != rhs.kind.rawValue {
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
    }

    private func normalizedRecoveryIntents(
        _ intents: [LibraryAssetRecoveryIntent]
    ) throws -> [LibraryAssetRecoveryIntent] {
        guard intents.isEmpty == false,
            Set(intents.map(\.entryID)).count == intents.count else {
            throw LibraryAssetStoreError.recoveryTransactionConflict(
                "A recovery transaction requires unique asset entries."
            )
        }

        var itemRoots: Set<UUID> = []
        var relativePathsByItem: [UUID: Set<String>] = [:]
        for intent in intents {
            switch intent.kind {
            case .itemRoot:
                guard intent.relativePath == nil,
                    itemRoots.insert(intent.itemID).inserted else {
                    throw LibraryAssetStoreError.recoveryTransactionConflict(
                        "An item-root recovery entry is malformed or duplicated."
                    )
                }
            case .itemRelativeAsset:
                guard let relativePath = intent.relativePath,
                    LibraryAssetPath.isSafeRelative(relativePath) else {
                    throw LibraryAssetStoreError.invalidRecoveryTransaction(
                        intent.relativePath ?? ""
                    )
                }
                guard relativePathsByItem[intent.itemID, default: []]
                    .insert(relativePath).inserted else {
                    throw LibraryAssetStoreError.recoveryTransactionConflict(
                        "The same item-relative asset was staged twice."
                    )
                }
            }
            guard itemRoots.isDisjoint(with: relativePathsByItem.keys) else {
                throw LibraryAssetStoreError.recoveryTransactionConflict(
                    "A whole item and one of its child assets cannot share a transaction."
                )
            }
        }
        for paths in relativePathsByItem.values {
            let sortedPaths = paths.sorted()
            for (index, path) in sortedPaths.enumerated() {
                let prefix = path.hasSuffix("/") ? path : path + "/"
                if sortedPaths.dropFirst(index + 1).contains(where: {
                    $0.hasPrefix(prefix)
                }) {
                    throw LibraryAssetStoreError.recoveryTransactionConflict(
                        "Nested recovery asset paths are not supported."
                    )
                }
            }
        }

        return intents.sorted { lhs, rhs in
            if lhs.itemID != rhs.itemID {
                return lhs.itemID.uuidString < rhs.itemID.uuidString
            }
            if lhs.kind.rawValue != rhs.kind.rawValue {
                return lhs.kind.rawValue < rhs.kind.rawValue
            }
            if lhs.relativePath != rhs.relativePath {
                return (lhs.relativePath ?? "") < (rhs.relativePath ?? "")
            }
            return lhs.entryID.uuidString < rhs.entryID.uuidString
        }
    }

    private func recoverySourceURL(
        for intent: LibraryAssetRecoveryIntent
    ) throws -> URL {
        switch intent.kind {
        case .itemRoot:
            guard intent.relativePath == nil else {
                throw LibraryAssetStoreError.invalidRecoveryTransaction(intent.entryID)
            }
            return directories(for: intent.itemID).itemRoot
        case .itemRelativeAsset:
            guard let relativePath = intent.relativePath else {
                throw LibraryAssetStoreError.invalidRecoveryTransaction(intent.entryID)
            }
            return try url(for: relativePath, itemID: intent.itemID)
        }
    }

    private func recoverySourceURL(
        for entry: LibraryAssetTrashManifest.Entry
    ) throws -> URL {
        switch entry.kind {
        case .itemRoot:
            guard entry.relativePath == nil else {
                throw LibraryAssetStoreError.invalidRecoveryTransaction(entry.entryID)
            }
            return directories(for: entry.itemID).itemRoot
        case .itemRelativeAsset:
            guard let relativePath = entry.relativePath,
                LibraryAssetPath.isSafeRelative(relativePath) else {
                throw LibraryAssetStoreError.invalidRecoveryTransaction(entry.entryID)
            }
            return try url(for: relativePath, itemID: entry.itemID)
        }
    }

    private func prepareRecoveryRestoreDestination(
        for entry: LibraryAssetTrashManifest.Entry,
        source: URL
    ) throws {
        switch entry.kind {
        case .itemRoot:
            try fileManager.createDirectory(
                at: itemsDirectory,
                withIntermediateDirectories: true
            )
            try requireDirectory(itemsDirectory, inside: libraryRoot)
        case .itemRelativeAsset:
            _ = try prepareItem(id: entry.itemID)
            try fileManager.createDirectory(
                at: source.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try validateNoSymbolicLinks(
                from: directories(for: entry.itemID).itemRoot,
                through: source
            )
        }
    }

    private func verifiedRecoveryTransactionDirectory(
        _ transaction: LibraryAssetTrashTransaction
    ) throws -> URL {
        let directory = recoveryTransactionDirectory(
            operationID: transaction.operationID
        )
        guard try fileType(at: directory) == .typeDirectory else {
            throw LibraryAssetStoreError.invalidRecoveryTransaction(
                transaction.operationID
            )
        }
        try requireDirectory(directory, inside: recoveryTransactionsDirectory)
        let stored = try readRecoveryManifest(
            at: recoveryManifestURL(in: directory),
            expectedOperationID: transaction.operationID
        )
        guard stored == transaction.manifest else {
            throw LibraryAssetStoreError.invalidRecoveryTransaction(
                transaction.operationID
            )
        }
        return directory
    }

    private func readRecoveryManifest(
        at url: URL,
        expectedOperationID: UUID
    ) throws -> LibraryAssetTrashManifest {
        guard try fileType(at: url) == .typeRegular else {
            throw LibraryAssetStoreError.invalidRecoveryTransaction(
                expectedOperationID
            )
        }
        let manifest: LibraryAssetTrashManifest
        do {
            // Oversized/corrupt journals remain in AssetTrash as a fail-closed
            // quarantine. Never map them or hand them to JSONDecoder.
            let data = try LibraryBoundedFileReader.read(
                at: url,
                inside: url.deletingLastPathComponent(),
                maximumByteCount: LibraryAssetReadLimits.recoveryManifestByteCount
            ).data
            manifest = try JSONDecoder.libraryRecoveryDecoder.decode(
                LibraryAssetTrashManifest.self,
                from: data
            )
        } catch {
            throw LibraryAssetStoreError.invalidRecoveryTransaction(
                expectedOperationID
            )
        }
        guard manifest.operationID == expectedOperationID else {
            throw LibraryAssetStoreError.invalidRecoveryTransaction(
                expectedOperationID
            )
        }
        guard manifest.version == LibraryAssetTrashManifest.currentSchemaVersion else {
            throw LibraryAssetStoreError.unsupportedRecoveryTransactionVersion(
                manifest.version
            )
        }
        _ = try normalizedRecoveryAnchors(manifest.catalogAnchors)
        let intents = manifest.entries.map {
            LibraryAssetRecoveryIntent(
                entryID: $0.entryID,
                kind: $0.kind,
                itemID: $0.itemID,
                relativePath: $0.relativePath,
                isRequired: $0.isRequired
            )
        }
        _ = try normalizedRecoveryIntents(intents)
        return manifest
    }

    private func readRecoveryCommitMarker(at url: URL) throws -> RecoveryCommitMarker {
        guard try fileType(at: url) == .typeRegular else {
            throw LibraryAssetStoreError.invalidRecoveryTransaction(
                UUID.zeroLibraryRecovery
            )
        }
        let marker: RecoveryCommitMarker
        do {
            let data = try LibraryBoundedFileReader.read(
                at: url,
                inside: url.deletingLastPathComponent(),
                maximumByteCount: LibraryAssetReadLimits.recoveryCommitMarkerByteCount
            ).data
            marker = try JSONDecoder.libraryRecoveryDecoder.decode(
                RecoveryCommitMarker.self,
                from: data
            )
        } catch {
            throw LibraryAssetStoreError.invalidRecoveryTransaction(
                UUID.zeroLibraryRecovery
            )
        }
        guard marker.version == RecoveryCommitMarker.currentSchemaVersion else {
            throw LibraryAssetStoreError.unsupportedRecoveryTransactionVersion(
                marker.version
            )
        }
        return marker
    }

    private func recoveryCommitMarkerIfPresent(
        in directory: URL
    ) throws -> RecoveryCommitMarker? {
        let url = recoveryCommitMarkerURL(in: directory)
        guard try fileType(at: url) != nil else { return nil }
        let marker = try readRecoveryCommitMarker(at: url)
        guard marker.operationID.uuidString == directory.lastPathComponent else {
            throw LibraryAssetStoreError.invalidRecoveryTransaction(
                marker.operationID
            )
        }
        return marker
    }

    private func writeSynchronized(_ data: Data, to destination: URL) throws {
        try data.write(to: destination, options: [.atomic])
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.synchronize()
        try synchronizeDirectory(destination.deletingLastPathComponent())
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw LibraryAssetStoreError.io(
                "Could not open \(directory.path) for durable synchronization."
            )
        }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw LibraryAssetStoreError.io(
                "Could not durably synchronize \(directory.path)."
            )
        }
    }

    private func recoveryTransactionDirectory(operationID: UUID) -> URL {
        recoveryTransactionsDirectory.appendingPathComponent(
            operationID.uuidString,
            isDirectory: true
        )
    }

    private func recoveryManifestURL(in transactionDirectory: URL) -> URL {
        transactionDirectory.appendingPathComponent("manifest.json", isDirectory: false)
    }

    private func recoveryCommitMarkerURL(in transactionDirectory: URL) -> URL {
        transactionDirectory.appendingPathComponent(
            "committed.marker",
            isDirectory: false
        )
    }

    private func recoveryPayloadDirectory(in transactionDirectory: URL) -> URL {
        transactionDirectory.appendingPathComponent("Payloads", isDirectory: true)
    }

    private func recoveryPayloadURL(
        for entry: LibraryAssetTrashManifest.Entry,
        in transactionDirectory: URL
    ) -> URL {
        recoveryPayloadDirectory(in: transactionDirectory).appendingPathComponent(
            entry.entryID.uuidString,
            isDirectory: entry.kind == .itemRoot
        )
    }

    private var itemsDirectory: URL {
        libraryRoot.appendingPathComponent("Items", isDirectory: true)
    }

    private var stagingDirectory: URL {
        libraryRoot.appendingPathComponent("Staging", isDirectory: true)
    }

    private var recoveryDirectory: URL {
        libraryRoot.appendingPathComponent("AssetTrash", isDirectory: true)
    }

    private var recoveryTransactionsDirectory: URL {
        recoveryDirectory.appendingPathComponent("Transactions", isDirectory: true)
    }

    private func prepareLibraryDirectories() throws {
        for directory in [
            libraryRoot,
            itemsDirectory,
            stagingDirectory,
            recoveryDirectory,
            recoveryTransactionsDirectory,
        ] {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
            try requireDirectory(directory, inside: libraryRoot)
        }
    }

    private func ensureCategoryDirectories(
        _ directories: LibraryItemAssetDirectories
    ) throws {
        let rootType = try fileType(at: directories.itemRoot)
        if rootType == .typeSymbolicLink {
            throw LibraryAssetStoreError.symbolicLinkNotAllowed(directories.itemRoot)
        }
        guard rootType == .typeDirectory else {
            throw LibraryAssetStoreError.sourceNotRegularFile(directories.itemRoot)
        }
        for category in LibraryAssetCategory.allCases {
            try fileManager.createDirectory(
                at: directories[category],
                withIntermediateDirectories: true
            )
            try requireDirectory(directories[category], inside: directories.itemRoot)
        }
    }

    private func fileType(at url: URL) throws -> FileAttributeType? {
        do {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            return attributes[.type] as? FileAttributeType
        } catch let error as CocoaError
            where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
            return nil
        }
    }

    private func requireDirectory(_ candidate: URL, inside allowedRoot: URL) throws {
        let candidate = candidate.standardizedFileURL
        let allowedRoot = allowedRoot.standardizedFileURL
        try validateNoSymbolicLinks(from: allowedRoot, through: candidate)
        guard try fileType(at: candidate) == .typeDirectory else {
            throw LibraryAssetStoreError.sourceNotRegularFile(candidate)
        }
    }

    /// Lexical containment alone is insufficient because an existing path
    /// component can redirect through a symlink. Check every existing
    /// component and then compare fully resolved locations as defense in depth.
    private func validateNoSymbolicLinks(from root: URL, through candidate: URL) throws {
        let root = Self.lexicallyStandardizedFileURL(root)
        let candidate = Self.lexicallyStandardizedFileURL(candidate)
        guard Self.isDescendant(candidate, of: root) else {
            throw LibraryAssetStoreError.destinationOutsideItem
        }

        let rootPath = root.path
        let candidatePath = candidate.path
        var current = root
        if try fileType(at: current) == .typeSymbolicLink {
            throw LibraryAssetStoreError.symbolicLinkNotAllowed(current)
        }
        let suffix = candidatePath.dropFirst(rootPath.count)
        for component in suffix.split(separator: "/") {
            current.appendPathComponent(String(component))
            if try fileType(at: current) == .typeSymbolicLink {
                throw LibraryAssetStoreError.symbolicLinkNotAllowed(current)
            }
        }

        // `resolvingSymlinksInPath()` cannot fully canonicalize a path whose
        // final component does not exist yet. On physical iOS devices that can
        // leave the destination under `/private/var/mobile` while its existing
        // root resolves to the equivalent `/var/mobile` spelling, producing a
        // false escape rejection. Resolve the nearest existing ancestor and
        // append only the verified, non-existing suffix before comparing.
        let resolvedRoot = try canonicalContainmentURL(root)
        let resolvedCandidate = try canonicalContainmentURL(candidate)
        guard Self.isDescendant(resolvedCandidate, of: resolvedRoot) else {
            throw LibraryAssetStoreError.destinationOutsideItem
        }
    }

    private func canonicalContainmentURL(_ url: URL) throws -> URL {
        var existingAncestor = Self.lexicallyStandardizedFileURL(url)
        var missingComponents: [String] = []

        while try fileType(at: existingAncestor) == nil {
            let parent = existingAncestor.deletingLastPathComponent()
            guard parent.path != existingAncestor.path else { break }
            missingComponents.append(existingAncestor.lastPathComponent)
            existingAncestor = parent
        }

        var canonical = existingAncestor
            .resolvingSymlinksInPath()
            .standardizedFileURL
        for component in missingComponents.reversed() {
            canonical.appendPathComponent(component)
        }
        return Self.lexicallyStandardizedFileURL(canonical)
    }

    private func isDirectChild(_ candidate: URL, of root: URL) throws -> Bool {
        let canonicalCandidate = try canonicalContainmentURL(candidate)
        let canonicalRoot = try canonicalContainmentURL(root)
        return Self.lexicallyStandardizedFileURL(
            canonicalCandidate.deletingLastPathComponent()
        ) == canonicalRoot
    }

    private func validateTreeContainsNoSymbolicLinks(at root: URL) throws {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: nil,
            options: []
        ) else {
            throw LibraryAssetStoreError.io("Could not inspect \(root.path).")
        }
        while let entry = enumerator.nextObject() as? URL {
            if try fileType(at: entry) == .typeSymbolicLink {
                throw LibraryAssetStoreError.symbolicLinkNotAllowed(entry)
            }
        }
    }

    private func adjacentTemporaryURL(for destination: URL) -> URL {
        destination.deletingLastPathComponent().appendingPathComponent(
            ".\(destination.lastPathComponent).\(UUID().uuidString).tmp"
        )
    }

    private func atomicallyInstall(_ temporary: URL, at destination: URL) throws {
        if fileManager.fileExists(atPath: destination.path) {
            _ = try fileManager.replaceItemAt(
                destination,
                withItemAt: temporary,
                backupItemName: nil,
                options: []
            )
        } else {
            try fileManager.moveItem(at: temporary, to: destination)
        }
    }

    private static func isDescendant(_ candidate: URL, of root: URL) -> Bool {
        let rootPath = lexicallyStandardizedFileURL(root).path
        let candidatePath = lexicallyStandardizedFileURL(candidate).path
        return candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/")
    }

    /// Normalizes `.` and `..` without consulting the filesystem. Foundation's
    /// `standardizedFileURL` can canonicalize an existing physical-device path
    /// from `/private/var/mobile` to `/var/mobile` while leaving a sibling that
    /// does not exist yet under the original spelling. Containment must not
    /// depend on whether the final component has been created.
    private static func lexicallyStandardizedFileURL(_ url: URL) -> URL {
        var components: [String] = []
        for component in url.pathComponents {
            switch component {
            case "", "/", ".":
                continue
            case "..":
                if components.isEmpty == false { components.removeLast() }
            default:
                components.append(component)
            }
        }
        if components.count >= 2,
            components[0] == "private",
            components[1] == "var" {
            components.removeFirst()
        }
        return URL(
            fileURLWithPath: "/" + components.joined(separator: "/"),
            isDirectory: url.hasDirectoryPath
        )
    }
}

private extension JSONEncoder {
    static var libraryRecoveryEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }
}

private extension JSONDecoder {
    static var libraryRecoveryDecoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }
}

private extension UUID {
    static let zeroLibraryRecovery = UUID(
        uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    )
}

