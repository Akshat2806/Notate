import Foundation

public actor CanvasPreferencesStore {
    private static let fileName = "preferences.json"
    private static let maximumEncodedByteCount = 1 * 1_024 * 1_024

    private let rootURL: URL

    public init(rootURL: URL) {
        self.rootURL = rootURL.standardizedFileURL
    }

    public nonisolated static func live() throws -> CanvasPreferencesStore {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return CanvasPreferencesStore(
            rootURL: applicationSupport.appendingPathComponent("CanvasCoreV2", isDirectory: true)
        )
    }

    public nonisolated static func live(itemID: UUID) throws -> CanvasPreferencesStore {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let canvasDirectory = applicationSupport
            .appendingPathComponent("NotateLibrary", isDirectory: true)
            .appendingPathComponent("Items", isDirectory: true)
            .appendingPathComponent(itemID.uuidString, isDirectory: true)
            .appendingPathComponent("Canvas", isDirectory: true)
        return CanvasPreferencesStore(rootURL: canvasDirectory)
    }

    public func load() -> CanvasPreferences {
        do {
            let values = try preferencesURL.resourceValues(forKeys: [
                .isRegularFileKey,
                .fileSizeKey,
            ])
            guard values.isRegularFile == true,
                  let fileSize = values.fileSize,
                  fileSize >= 0,
                  fileSize <= Self.maximumEncodedByteCount else {
                return NotatePreferences.defaultCanvasPreferences
            }
            let data = try Data(contentsOf: preferencesURL, options: .mappedIfSafe)
            guard data.count <= Self.maximumEncodedByteCount else {
                return NotatePreferences.defaultCanvasPreferences
            }
            let preferences = try JSONDecoder().decode(CanvasPreferences.self, from: data)
            return preferences.isValid
                ? preferences
                : NotatePreferences.defaultCanvasPreferences
        } catch CocoaError.fileReadNoSuchFile {
            return NotatePreferences.defaultCanvasPreferences
        } catch {
            return NotatePreferences.defaultCanvasPreferences
        }
    }

    public func save(_ preferences: CanvasPreferences) throws {
        guard preferences.isValid else {
            throw CanvasPreferencesStoreError.invalidPreferences
        }

        try FileManager.default.createDirectory(
            at: rootURL,
            withIntermediateDirectories: true
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(preferences)
        guard data.count <= Self.maximumEncodedByteCount else {
            throw CanvasPreferencesStoreError.invalidPreferences
        }
        try data.write(to: preferencesURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private var preferencesURL: URL {
        rootURL.appendingPathComponent(Self.fileName, isDirectory: false)
    }
}

public enum CanvasPreferencesStoreError: Error, LocalizedError, Sendable {
    case invalidPreferences

    public var errorDescription: String? {
        "Canvas preferences are invalid."
    }
}
