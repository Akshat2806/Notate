import Foundation

public struct LegacyCanvasMigrationCandidate: Codable, Equatable, Sendable {
    public let legacyDirectory: URL
    public let currentCanvasURL: URL
    public let previousCanvasURL: URL?
    public let preferencesURL: URL?

    public init(
        legacyDirectory: URL,
        currentCanvasURL: URL,
        previousCanvasURL: URL?,
        preferencesURL: URL?
    ) {
        self.legacyDirectory = legacyDirectory
        self.currentCanvasURL = currentCanvasURL
        self.previousCanvasURL = previousCanvasURL
        self.preferencesURL = preferencesURL
    }
}

public enum LegacyCanvasMigrationStatus: Codable, Equatable, Sendable {
    case notNeeded
    case pending(LegacyCanvasMigrationCandidate)
    /// Persisted before the catalog or asset store is mutated. The stable ID
    /// lets launch recovery verify, resume, or discard the same target instead
    /// of creating a duplicate after a crash.
    case inProgress(itemID: UUID, startedAt: Date)
    case completed(itemID: UUID, completedAt: Date)
    case deferred(reason: String, deferredAt: Date)
}

public enum LegacyCanvasMigrationError: Error, Equatable, LocalizedError {
    case corruptMarker
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .corruptMarker:
            "The legacy-canvas migration marker is unreadable."
        case let .io(message):
            "The migration state could not be updated: \(message)"
        }
    }
}

/// Detection and durable bookkeeping for the pre-library `CanvasCoreV2`
/// payload. Payload decoding is intentionally left to the Canvas integration
/// layer; this coordinator never mutates the legacy source.
public actor LegacyCanvasMigrationCoordinator {
    public let legacyDirectory: URL
    public let migrationDirectory: URL

    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(
        legacyDirectory: URL,
        migrationDirectory: URL
    ) {
        self.legacyDirectory = legacyDirectory.standardizedFileURL
        self.migrationDirectory = migrationDirectory.standardizedFileURL
        fileManager = FileManager()
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    public static func live() throws -> LegacyCanvasMigrationCoordinator {
        let fileManager = FileManager.default
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return LegacyCanvasMigrationCoordinator(
            legacyDirectory: applicationSupport.appendingPathComponent(
                "CanvasCoreV2",
                isDirectory: true
            ),
            migrationDirectory: applicationSupport
                .appendingPathComponent("NotateLibrary", isDirectory: true)
                .appendingPathComponent("Migrations", isDirectory: true)
        )
    }

    public func inspect() throws -> LegacyCanvasMigrationStatus {
        if fileManager.fileExists(atPath: markerURL.path) {
            do {
                let data = try LibraryBoundedFileReader.read(
                    at: markerURL,
                    inside: migrationDirectory,
                    maximumByteCount: LibraryAssetReadLimits
                        .legacyMigrationMetadataByteCount
                ).data
                return try decoder.decode(
                    LegacyCanvasMigrationStatus.self,
                    from: data
                )
            } catch {
                throw LegacyCanvasMigrationError.corruptMarker
            }
        }

        let current = legacyDirectory.appendingPathComponent("current.canvas")
        guard fileManager.fileExists(atPath: current.path) else { return .notNeeded }

        let previous = legacyDirectory.appendingPathComponent("previous.canvas")
        let preferences = legacyDirectory.appendingPathComponent("preferences.json")
        return .pending(
            LegacyCanvasMigrationCandidate(
                legacyDirectory: legacyDirectory,
                currentCanvasURL: current,
                previousCanvasURL: fileManager.fileExists(atPath: previous.path) ? previous : nil,
                preferencesURL: fileManager.fileExists(atPath: preferences.path) ? preferences : nil
            )
        )
    }

    public func markCompleted(
        itemID: UUID,
        at date: Date = .now
    ) throws {
        try writeMarker(.completed(itemID: itemID, completedAt: date))
    }

    /// Starts a recoverable migration before callers create the target item.
    /// Pass this same ID to `LibraryRepository.createItem(id:kind:name:...)`.
    public func markInProgress(
        itemID: UUID,
        at date: Date = .now
    ) throws {
        try writeMarker(.inProgress(itemID: itemID, startedAt: date))
    }

    public func markDeferred(
        reason: String,
        at date: Date = .now
    ) throws {
        let resolvedReason = reason.nilIfLibraryBlank ?? "Migration deferred"
        try writeMarker(.deferred(reason: resolvedReason, deferredAt: date))
    }

    /// Removes only the marker, allowing a user-requested retry. Legacy canvas
    /// files are never deleted by this coordinator.
    public func resetMarker() throws {
        guard fileManager.fileExists(atPath: markerURL.path) else { return }
        do {
            try fileManager.removeItem(at: markerURL)
        } catch {
            throw LegacyCanvasMigrationError.io(String(describing: error))
        }
    }

    private var markerURL: URL {
        migrationDirectory.appendingPathComponent("legacy-canvas.json")
    }

    private func writeMarker(_ status: LegacyCanvasMigrationStatus) throws {
        do {
            try fileManager.createDirectory(
                at: migrationDirectory,
                withIntermediateDirectories: true
            )
            let data = try encoder.encode(status)
            guard data.count <= LibraryAssetReadLimits
                .legacyMigrationMetadataByteCount else {
                throw LegacyCanvasMigrationError.io(
                    "The migration marker exceeded its safe byte limit."
                )
            }
            try data.write(to: markerURL, options: [.atomic])
        } catch let error as LegacyCanvasMigrationError {
            throw error
        } catch {
            throw LegacyCanvasMigrationError.io(String(describing: error))
        }
    }
}
