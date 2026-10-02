import Foundation
import SwiftData

public enum LibraryModelContainerFactory {
    public static let storeFilename = "library.store"

    /// Creates the production catalog at
    /// `Application Support/NotateLibrary/Catalog/library.store`.
    public static func makeLive(
        fileManager: FileManager = .default
    ) throws -> ModelContainer {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return try makePersistent(
            at: applicationSupport
                .appendingPathComponent("NotateLibrary", isDirectory: true)
                .appendingPathComponent("Catalog", isDirectory: true)
                .appendingPathComponent(storeFilename),
            fileManager: fileManager
        )
    }

    public static func makePersistent(
        at catalogDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> ModelContainer {
        try fileManager.createDirectory(
            at: catalogDirectory,
            withIntermediateDirectories: true
        )
        let schema = Schema(versionedSchema: LibrarySchemaV1.self)
        let configuration = ModelConfiguration(
            "NotateLibrary",
            schema: schema,
            url: catalogDirectory.appendingPathComponent(storeFilename),
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: LibrarySchemaMigrationPlan.self,
            configurations: configuration
        )
    }

    /// A fresh, isolated catalog for previews and unit tests.
    public static func makeInMemory() throws -> ModelContainer {
        let schema = Schema(versionedSchema: LibrarySchemaV1.self)
        let configuration = ModelConfiguration(
            "NotateLibraryTests",
            schema: schema,
            isStoredInMemoryOnly: true,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(
            for: schema,
            migrationPlan: LibrarySchemaMigrationPlan.self,
            configurations: configuration
        )
    }
}
