import CryptoKit
import Foundation
import SQLite3

/// The durable, note-derived material that may be reused by later assistant
/// requests. Conversational turns deliberately do not have an artifact kind:
/// chat history remains session-local.
enum AssistantArtifactKind: String, CaseIterable, Codable, Hashable, Sendable {
    case answer
    case explanation
    case summary
    case sectionSummary
    case outline
    case concepts
    case entities
    case questions
    case study
    case extractivePreview
}

/// The durable subject an artifact describes. Section subjects retain their
/// parent identifier so a changed page or notebook can discard stale section
/// intelligence without throwing away sections whose hashes are unchanged.
struct AssistantArtifactSubject: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case page
        case notebook
        case library
        case section
    }

    let kind: Kind
    let identifier: String
    let parentIdentifier: String?

    init(kind: Kind, identifier: String, parentIdentifier: String? = nil) {
        self.kind = kind
        self.identifier = identifier
        self.parentIdentifier = parentIdentifier
    }

    static func page(_ id: UUID) -> Self {
        Self(kind: .page, identifier: id.uuidString)
    }

    static func notebook(_ id: UUID) -> Self {
        Self(kind: .notebook, identifier: id.uuidString)
    }

    static var library: Self {
        Self(kind: .library, identifier: "library")
    }

    static func section(id: String, parentID: String) -> Self {
        Self(kind: .section, identifier: id, parentIdentifier: parentID)
    }
}

/// The user-visible boundary within which an artifact was derived. It is
/// deliberately separate from `AssistantArtifactSubject`: a page passage can,
/// for example, participate in a bounded library answer without becoming a
/// library-wide artifact.
struct AssistantArtifactScopeIdentity: Codable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case page
        case notebook
        case library
    }

    let kind: Kind
    let identifier: String

    init(kind: Kind, identifier: String) {
        self.kind = kind
        self.identifier = identifier
    }

    static func page(_ id: UUID) -> Self {
        Self(kind: .page, identifier: id.uuidString)
    }

    static func notebook(_ id: UUID) -> Self {
        Self(kind: .notebook, identifier: id.uuidString)
    }

    static var library: Self {
        Self(kind: .library, identifier: "library")
    }
}

/// V2 cache identity. Every dimension that can change meaning or provenance is
/// explicit so an exact lookup cannot accidentally reuse an artifact produced
/// by another retrieval policy, prompt, model build, scope, or snapshot.
struct AssistantArtifactCacheKeyV2: Codable, Equatable, Hashable, Sendable {
    let subject: AssistantArtifactSubject
    let snapshotHash: String
    let taskIdentifier: String
    let artifactKind: AssistantArtifactKind
    let scope: AssistantArtifactScopeIdentity
    let requestFingerprint: String?
    let promptVersion: String
    let schemaVersion: String
    let retrievalVersion: String
    let derivationVersion: String
    let providerIdentifier: String
    let modelBuild: String
    let localeIdentifier: String
    let outputStyle: String

    init(
        subject: AssistantArtifactSubject,
        snapshotHash: String,
        taskIdentifier: String,
        artifactKind: AssistantArtifactKind,
        scope: AssistantArtifactScopeIdentity,
        requestFingerprint: String? = nil,
        promptVersion: String,
        schemaVersion: String,
        retrievalVersion: String,
        derivationVersion: String,
        providerIdentifier: String,
        modelBuild: String,
        localeIdentifier: String,
        outputStyle: String
    ) {
        self.subject = subject
        self.snapshotHash = snapshotHash
        self.taskIdentifier = taskIdentifier
        self.artifactKind = artifactKind
        self.scope = scope
        self.requestFingerprint = requestFingerprint
        self.promptVersion = promptVersion
        self.schemaVersion = schemaVersion
        self.retrievalVersion = retrievalVersion
        self.derivationVersion = derivationVersion
        self.providerIdentifier = providerIdentifier
        self.modelBuild = modelBuild
        self.localeIdentifier = localeIdentifier
        self.outputStyle = outputStyle
    }
}

struct AssistantArtifactSectionDigest: Codable, Equatable, Sendable {
    let sectionID: String
    let contentHash: String
    let markdown: String
    let sourceIDs: [String]

    init(
        sectionID: String,
        contentHash: String,
        markdown: String,
        sourceIDs: [String] = []
    ) {
        self.sectionID = sectionID
        self.contentHash = contentHash
        self.markdown = markdown
        self.sourceIDs = sourceIDs
    }
}

struct AssistantArtifactCoverage: Codable, Equatable, Sendable {
    let totalSectionCount: Int
    let coveredSectionIDs: [String]
    let missingSectionIDs: [String]

    init(
        totalSectionCount: Int,
        coveredSectionIDs: [String],
        missingSectionIDs: [String] = []
    ) {
        self.totalSectionCount = totalSectionCount
        self.coveredSectionIDs = coveredSectionIDs
        self.missingSectionIDs = missingSectionIDs
    }
}

/// A source-attributed artifact whose key includes the complete provenance and
/// scope needed for safe persistent reuse.
struct AssistantArtifactRecordV2: Codable, Equatable, Sendable {
    let key: AssistantArtifactCacheKeyV2
    let subjectRevision: Int64
    let markdown: String
    let sourceIDs: [String]
    let sectionDigests: [AssistantArtifactSectionDigest]
    let coverage: AssistantArtifactCoverage
    let createdAt: Date

    init(
        key: AssistantArtifactCacheKeyV2,
        subjectRevision: Int64,
        markdown: String,
        sourceIDs: [String] = [],
        sectionDigests: [AssistantArtifactSectionDigest] = [],
        coverage: AssistantArtifactCoverage = AssistantArtifactCoverage(
            totalSectionCount: 0,
            coveredSectionIDs: []
        ),
        createdAt: Date = Date()
    ) {
        self.key = key
        self.subjectRevision = subjectRevision
        self.markdown = markdown
        self.sourceIDs = sourceIDs
        self.sectionDigests = sectionDigests
        self.coverage = coverage
        self.createdAt = createdAt
    }
}

/// One exact-snapshot assertion about which durable intelligence has and has
/// not been derived. Persisting known absence prevents repeated work for notes
/// that legitimately have no entities, concepts, or questions.
struct AssistantIntelligenceManifestKey: Codable, Equatable, Hashable, Sendable {
    let subject: AssistantArtifactSubject
    let snapshotHash: String
    let scope: AssistantArtifactScopeIdentity
    let promptVersion: String
    let schemaVersion: String
    let retrievalVersion: String
    let derivationVersion: String
    let providerIdentifier: String
    let modelBuild: String
    let localeIdentifier: String

    init(
        subject: AssistantArtifactSubject,
        snapshotHash: String,
        scope: AssistantArtifactScopeIdentity,
        promptVersion: String,
        schemaVersion: String,
        retrievalVersion: String,
        derivationVersion: String,
        providerIdentifier: String,
        modelBuild: String,
        localeIdentifier: String
    ) {
        self.subject = subject
        self.snapshotHash = snapshotHash
        self.scope = scope
        self.promptVersion = promptVersion
        self.schemaVersion = schemaVersion
        self.retrievalVersion = retrievalVersion
        self.derivationVersion = derivationVersion
        self.providerIdentifier = providerIdentifier
        self.modelBuild = modelBuild
        self.localeIdentifier = localeIdentifier
    }
}

struct AssistantIntelligenceManifest: Codable, Equatable, Sendable {
    enum ArtifactState: Equatable, Sendable {
        case present
        case absent
        case unknown
    }

    let key: AssistantIntelligenceManifestKey
    let presentArtifactKinds: Set<AssistantArtifactKind>
    let absentArtifactKinds: Set<AssistantArtifactKind>
    let createdAt: Date

    init(
        key: AssistantIntelligenceManifestKey,
        presentArtifactKinds: Set<AssistantArtifactKind>,
        absentArtifactKinds: Set<AssistantArtifactKind>,
        createdAt: Date = Date()
    ) {
        self.key = key
        self.presentArtifactKinds = presentArtifactKinds
        self.absentArtifactKinds = absentArtifactKinds
        self.createdAt = createdAt
    }

    func state(for kind: AssistantArtifactKind) -> ArtifactState {
        if presentArtifactKinds.contains(kind) { return .present }
        if absentArtifactKinds.contains(kind) { return .absent }
        return .unknown
    }
}

struct AssistantArtifactCacheLookupV2: Equatable, Hashable, Sendable {
    let key: AssistantArtifactCacheKeyV2
    let currentSnapshotHash: String

    init(key: AssistantArtifactCacheKeyV2, currentSnapshotHash: String) {
        self.key = key
        self.currentSnapshotHash = currentSnapshotHash
    }
}

struct AssistantArtifactCacheLimits: Equatable, Sendable {
    static let standard = AssistantArtifactCacheLimits(
        maximumBytes: 128 * 1_024 * 1_024,
        trimTargetBytes: 96 * 1_024 * 1_024
    )

    let maximumBytes: Int64
    let trimTargetBytes: Int64

    init(maximumBytes: Int64, trimTargetBytes: Int64) {
        self.maximumBytes = maximumBytes
        self.trimTargetBytes = trimTargetBytes
    }
}

struct AssistantArtifactCacheStatistics: Equatable, Sendable {
    let artifactCount: Int
    let totalBytes: Int64
    /// Main SQLite file allocation, including schema, indexes, and free pages.
    /// Unlike `totalBytes`, this is the physical quota the 128 MB ceiling uses.
    let physicalBytes: Int64
    let maximumBytes: Int64
    let trimTargetBytes: Int64
}

enum AssistantArtifactCacheError: Error, Equatable, LocalizedError, Sendable {
    case invalidLimits(maximumBytes: Int64, trimTargetBytes: Int64)
    case invalidKey(String)
    case invalidArtifact(String)
    case artifactTooLarge(actualBytes: Int64, maximumBytes: Int64)
    case io(String)

    var errorDescription: String? {
        switch self {
        case let .invalidLimits(maximumBytes, trimTargetBytes):
            "Invalid assistant-cache limits (maximum: \(maximumBytes), trim target: \(trimTargetBytes))."
        case let .invalidKey(reason):
            "The assistant artifact key is invalid. \(reason)"
        case let .invalidArtifact(reason):
            "The assistant artifact is invalid. \(reason)"
        case let .artifactTooLarge(actualBytes, maximumBytes):
            "The assistant artifact is \(actualBytes) bytes, exceeding the per-entry limit of \(maximumBytes) bytes."
        case let .io(message):
            "The on-device assistant cache could not be accessed. \(message)"
        }
    }
}

/// A protected, strictly on-device SQLite cache for note-derived intelligence.
///
 /// SQLite transactions make each artifact and its LRU metadata atomic. Stored
/// records retain an application-level SHA-256 checksum as defense in depth;
/// an invalid row is deleted and treated as a cache miss. A corrupt database is
/// discarded because all cached material is reproducible from verified notes.
actor AssistantArtifactCache {
    private static let schemaVersion: Int64 = 2
    private static let v2EntryType = "artifact-v2"
    private static let manifestEntryType = "intelligence-manifest-v2"
    private static let directoryName = "AssistantArtifacts"
    private static let databaseFilename = "assistant-artifacts.sqlite3"

    private let storageRoot: URL
    private let databaseURL: URL
    private let limits: AssistantArtifactCacheLimits
    private let fileManager: FileManager
    private var database: OpaquePointer?
    private var nextAccessSequence: Int64
    /// A cache instance is permanently sealed at a deletion boundary. Tasks
    /// that captured it before the purge can no longer write into the freshly
    /// reopened database after `removeAllAndSeal()` returns.
    private var isSealed = false
    /// Guards delayed maintenance against pruning rows written by a newer
    /// request after that maintenance captured its source snapshot.
    private var contentRevision: UInt64 = 0

    init(
        storageRoot: URL? = nil,
        limits: AssistantArtifactCacheLimits = .standard,
        fileManager: FileManager = FileManager()
    ) throws {
        guard limits.maximumBytes > 0,
            limits.trimTargetBytes > 0,
            limits.trimTargetBytes <= limits.maximumBytes else {
            throw AssistantArtifactCacheError.invalidLimits(
                maximumBytes: limits.maximumBytes,
                trimTargetBytes: limits.trimTargetBytes
            )
        }

        let resolvedRoot: URL
        if let storageRoot {
            resolvedRoot = storageRoot.standardizedFileURL
        } else {
            do {
                resolvedRoot = try fileManager.url(
                    for: .applicationSupportDirectory,
                    in: .userDomainMask,
                    appropriateFor: nil,
                    create: true
                )
                .appendingPathComponent(Self.directoryName, isDirectory: true)
                .standardizedFileURL
            } catch {
                throw AssistantArtifactCacheError.io(error.localizedDescription)
            }
        }

        let databaseURL = resolvedRoot.appendingPathComponent(Self.databaseFilename)
        do {
            try fileManager.createDirectory(at: resolvedRoot, withIntermediateDirectories: true)
            try Self.applyDirectoryAttributes(to: resolvedRoot, fileManager: fileManager)
            let handle = try Self.openRecoveringCorruption(
                at: databaseURL,
                fileManager: fileManager
            )
            database = handle
            nextAccessSequence = try Self.nextSequence(in: handle)
            self.storageRoot = resolvedRoot
            self.databaseURL = databaseURL
            self.limits = limits
            self.fileManager = fileManager

            let trimmed = try Self.trimIfNeeded(database: handle, limits: limits)
            if trimmed {
                try Self.compactAfterTrim(database: handle, limits: limits)
            }
            try Self.applyDatabaseFileAttributes(
                at: databaseURL,
                fileManager: fileManager
            )
            try Self.removeLegacyFileCacheIfPresent(
                at: resolvedRoot,
                fileManager: fileManager
            )
        } catch {
            throw Self.cacheError(from: error)
        }
    }

    isolated deinit {
        if let database {
            sqlite3_close_v2(database)
        }
    }

        func store(_ artifact: AssistantArtifactRecordV2) throws {
            try store([artifact], manifests: [])
        }

        func store(_ artifacts: [AssistantArtifactRecordV2]) throws {
            try store(artifacts, manifests: [])
        }

        func store(_ manifest: AssistantIntelligenceManifest) throws {
            try store([], manifests: [manifest])
        }

        /// Persists V2 artifacts and intelligence manifests in one SQLite
        /// transaction. Any failed row rolls back the artifacts, manifests, and
        /// their LRU sequence changes as one unit.
        func store(
            _ artifacts: [AssistantArtifactRecordV2],
            manifests: [AssistantIntelligenceManifest]
        ) throws {
            guard isSealed == false else {
                throw AssistantArtifactCacheError.io(
                    "This cache generation was invalidated by permanent deletion."
                )
            }
            guard artifacts.isEmpty == false || manifests.isEmpty == false else { return }

            let preparedArtifacts = try artifacts.map { artifact in
                try Self.validate(artifact)
                let digest = try Self.digest(for: artifact.key)
                let data = try Self.encoder.encode(artifact)
                let checksum = Self.sha256(data)
                let byteCount = Self.quotaByteCount(
                    data: data,
                    digest: digest,
                    metadata: Self.metadataStrings(for: artifact.key),
                    checksum: checksum
                )
                guard byteCount <= limits.trimTargetBytes else {
                    throw AssistantArtifactCacheError.artifactTooLarge(
                        actualBytes: byteCount,
                        maximumBytes: limits.trimTargetBytes
                    )
                }
                return (artifact, data, checksum, digest, byteCount)
            }
            let preparedManifests = try manifests.map { manifest in
                try Self.validate(manifest)
                let digest = try Self.digest(for: manifest.key)
                let data = try Self.encoder.encode(manifest)
                let checksum = Self.sha256(data)
                let byteCount = Self.quotaByteCount(
                    data: data,
                    digest: digest,
                    metadata: Self.metadataStrings(for: manifest.key),
                    checksum: checksum
                )
                guard byteCount <= limits.trimTargetBytes else {
                    throw AssistantArtifactCacheError.artifactTooLarge(
                        actualBytes: byteCount,
                        maximumBytes: limits.trimTargetBytes
                    )
                }
                return (manifest, data, checksum, digest, byteCount)
            }
            guard let database else {
                throw AssistantArtifactCacheError.io("The SQLite database is closed.")
            }

            let startingSequence = nextAccessSequence
            do {
                try Self.execute("BEGIN IMMEDIATE", in: database)
                var trimmed = false
                do {
                    for (artifact, data, checksum, digest, byteCount) in preparedArtifacts {
                        try Self.upsert(
                            artifact,
                            data: data,
                            checksum: checksum,
                            digest: digest,
                            byteCount: byteCount,
                            accessSequence: try consumeAccessSequence(),
                            database: database
                        )
                    }
                    for (manifest, data, checksum, digest, byteCount) in preparedManifests {
                        try Self.upsert(
                            manifest,
                            data: data,
                            checksum: checksum,
                            digest: digest,
                            byteCount: byteCount,
                            accessSequence: try consumeAccessSequence(),
                            database: database
                        )
                    }
                    trimmed = try Self.trimIfNeeded(database: database, limits: limits)
                    try Self.execute("COMMIT", in: database)
                    contentRevision &+= 1
                } catch {
                    try? Self.execute("ROLLBACK", in: database)
                    nextAccessSequence = startingSequence
                    throw error
                }
                if trimmed {
                    try Self.compactAfterTrim(database: database, limits: limits)
                }
                try applyDatabaseFileAttributes()
            } catch {
                throw Self.cacheError(from: error)
            }
        }

        func artifact(
            for key: AssistantArtifactCacheKeyV2,
            currentSnapshotHash: String
        ) throws -> AssistantArtifactRecordV2? {
            try artifacts(
                for: [AssistantArtifactCacheLookupV2(
                    key: key,
                    currentSnapshotHash: currentSnapshotHash
                )]
            )[key]
        }

        func artifacts(
            for keys: [AssistantArtifactCacheKeyV2],
            currentSnapshotHash: String
        ) throws -> [AssistantArtifactCacheKeyV2: AssistantArtifactRecordV2] {
            try artifacts(for: keys.map {
                AssistantArtifactCacheLookupV2(
                    key: $0,
                    currentSnapshotHash: currentSnapshotHash
                )
            })
        }

        /// Reads exact-snapshot V2 artifacts and updates their LRU metadata in one
        /// transaction. Mismatched snapshots are misses and are never touched.
        func artifacts(
            for lookups: [AssistantArtifactCacheLookupV2]
        ) throws -> [AssistantArtifactCacheKeyV2: AssistantArtifactRecordV2] {
            guard isSealed == false else { return [:] }
            var exactLookups: [AssistantArtifactCacheLookupV2] = []
            var seenKeys: Set<AssistantArtifactCacheKeyV2> = []
            for lookup in lookups {
                try Self.validate(lookup.key)
                guard lookup.currentSnapshotHash
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                        throw AssistantArtifactCacheError.invalidKey(
                            "The current snapshot hash is empty."
                        )
                    }
                guard lookup.key.snapshotHash == lookup.currentSnapshotHash,
                    seenKeys.insert(lookup.key).inserted else {
                    continue
                }
                exactLookups.append(lookup)
            }
            guard exactLookups.isEmpty == false else { return [:] }
            guard let database else {
                throw AssistantArtifactCacheError.io("The SQLite database is closed.")
            }

            var results: [AssistantArtifactCacheKeyV2: AssistantArtifactRecordV2] = [:]
            let startingSequence = nextAccessSequence
            do {
                try Self.execute("BEGIN IMMEDIATE", in: database)
                do {
                    let selection = try Self.prepare(
                        "SELECT artifact_data, checksum FROM artifacts WHERE key_digest = ?",
                        in: database
                    )
                    defer { sqlite3_finalize(selection) }
                    let update = try Self.prepare(
                        """
                        UPDATE artifacts
                        SET last_access_sequence = ?, last_accessed_at = ?
                        WHERE key_digest = ?
                        """,
                        in: database
                    )
                    defer { sqlite3_finalize(update) }
                    let deletion = try Self.prepare(
                        "DELETE FROM artifacts WHERE key_digest = ?",
                        in: database
                    )
                    defer { sqlite3_finalize(deletion) }

                    for lookup in exactLookups {
                        let digest = try Self.digest(for: lookup.key)
                        sqlite3_reset(selection)
                        sqlite3_clear_bindings(selection)
                        try Self.bind(digest, at: 1, in: selection, database: database)
                        let selectionResult = sqlite3_step(selection)
                        if selectionResult == SQLITE_DONE { continue }
                        guard selectionResult == SQLITE_ROW else {
                            throw Self.failure(for: selectionResult, database: database)
                        }
                        let data = Self.data(in: selection, column: 0)
                        let checksum = Self.text(in: selection, column: 1)

                        let artifact: AssistantArtifactRecordV2
                        do {
                            guard Self.sha256(data) == checksum else {
                                throw AssistantArtifactCacheError.invalidArtifact(
                                    "The checksum does not match."
                                )
                            }
                            artifact = try Self.decoder.decode(
                                AssistantArtifactRecordV2.self,
                                from: data
                            )
                            try Self.validate(artifact)
                            guard artifact.key == lookup.key else {
                                throw AssistantArtifactCacheError.invalidArtifact(
                                    "The stored identity does not match the requested identity."
                                )
                            }
                        } catch {
                            sqlite3_reset(deletion)
                            sqlite3_clear_bindings(deletion)
                            try Self.bind(digest, at: 1, in: deletion, database: database)
                            try Self.stepToCompletion(deletion, database: database)
                            continue
                        }

                        sqlite3_reset(update)
                        sqlite3_clear_bindings(update)
                        try Self.bind(
                            try consumeAccessSequence(),
                            at: 1,
                            in: update,
                            database: database
                        )
                        try Self.bind(
                            Date().timeIntervalSince1970,
                            at: 2,
                            in: update,
                            database: database
                        )
                        try Self.bind(digest, at: 3, in: update, database: database)
                        try Self.stepToCompletion(update, database: database)
                        results[lookup.key] = artifact
                    }
                    try Self.execute("COMMIT", in: database)
                } catch {
                    try? Self.execute("ROLLBACK", in: database)
                    nextAccessSequence = startingSequence
                    throw error
                }
                try applyDatabaseFileAttributes()
                return results
            } catch {
                throw Self.cacheError(from: error)
            }
        }

        func intelligenceManifest(
            for key: AssistantIntelligenceManifestKey,
            currentSnapshotHash: String
        ) throws -> AssistantIntelligenceManifest? {
            guard isSealed == false else { return nil }
            try Self.validate(key)
            guard key.snapshotHash == currentSnapshotHash else { return nil }
            guard let database else {
                throw AssistantArtifactCacheError.io("The SQLite database is closed.")
            }
            let digest = try Self.digest(for: key)

            do {
                guard let stored = try Self.storedPayload(for: digest, database: database) else {
                    return nil
                }
                let manifest: AssistantIntelligenceManifest
                do {
                    guard Self.sha256(stored.data) == stored.checksum else {
                        throw AssistantArtifactCacheError.invalidArtifact(
                            "The checksum does not match."
                        )
                    }
                    manifest = try Self.decoder.decode(
                        AssistantIntelligenceManifest.self,
                        from: stored.data
                    )
                    try Self.validate(manifest)
                    guard manifest.key == key else {
                        throw AssistantArtifactCacheError.invalidArtifact(
                            "The stored manifest identity does not match the requested identity."
                        )
                    }
                } catch {
                    try delete(digest: digest)
                    return nil
                }

                let update = try Self.prepare(
                    """
                    UPDATE artifacts
                    SET last_access_sequence = ?, last_accessed_at = ?
                    WHERE key_digest = ?
                    """,
                    in: database
                )
                defer { sqlite3_finalize(update) }
                try Self.bind(try consumeAccessSequence(), at: 1, in: update, database: database)
                try Self.bind(Date().timeIntervalSince1970, at: 2, in: update, database: database)
                try Self.bind(digest, at: 3, in: update, database: database)
                try Self.stepToCompletion(update, database: database)
                try applyDatabaseFileAttributes()
                return manifest
            } catch {
                throw Self.cacheError(from: error)
            }
        }

        /// Reclaims stale V2 rows only within the supplied subject and scope.
        /// Section rows survive a parent snapshot change when their own exact hash
        /// still appears in `preservingSectionHashes`.
        @discardableResult
        func removeStaleArtifacts(
            for subject: AssistantArtifactSubject,
            in scope: AssistantArtifactScopeIdentity,
            keepingSnapshotHash currentSnapshotHash: String,
            preservingSectionHashes: [String: String] = [:],
            ifContentRevisionIs expectedContentRevision: UInt64? = nil
        ) throws -> Int {
            guard isSealed == false else { return 0 }
            try Self.validate(subject)
            try Self.validate(scope)
            guard subject.kind != .section else {
                throw AssistantArtifactCacheError.invalidKey(
                    "Scoped pruning requires a page, notebook, or library subject."
                )
            }
            guard currentSnapshotHash
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                    throw AssistantArtifactCacheError.invalidKey(
                        "The current snapshot hash is empty."
                    )
                }
            for (sectionID, hash) in preservingSectionHashes {
                guard sectionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                    hash.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                        throw AssistantArtifactCacheError.invalidKey(
                            "A retained section identifier or hash is empty."
                        )
                    }
            }
            guard let database else {
                throw AssistantArtifactCacheError.io("The SQLite database is closed.")
            }
            if let expectedContentRevision,
                expectedContentRevision != contentRevision {
                    // A newer request stored (or another maintenance pass mutated)
                    // cache content after this pass began. Skipping is safe because
                    // every artifact is reproducible and the newest pass will prune.
                    return 0
            }
            do {
                try Self.execute("BEGIN IMMEDIATE", in: database)
                do {
                    let selection = try Self.prepare(
                        """
                        SELECT key_digest, subject_key, subject_kind,
                               subject_identifier, parent_subject_identifier,
                               snapshot_hash
                        FROM artifacts
                        WHERE scope_key = ?
                          AND entry_type IN (?, ?)
                        """,
                        in: database
                    )
                    try Self.bind(
                        Self.storageKey(for: scope),
                        at: 1,
                    in: selection,
                    database: database
                )
                try Self.bind(Self.v2EntryType, at: 2, in: selection, database: database)
                try Self.bind(
                    Self.manifestEntryType,
                    at: 3,
                    in: selection,
                    database: database
                )

                var staleDigests: [String] = []
                while true {
                    let result = sqlite3_step(selection)
                    if result == SQLITE_DONE { break }
                    guard result == SQLITE_ROW else {
                        sqlite3_finalize(selection)
                        throw Self.failure(for: result, database: database)
                    }
                    let digest = Self.text(in: selection, column: 0)
                    let storedSubjectKey = Self.text(in: selection, column: 1)
                    let storedKind = Self.text(in: selection, column: 2)
                    let storedIdentifier = Self.text(in: selection, column: 3)
                    let storedParent = Self.text(in: selection, column: 4)
                    let storedHash = Self.text(in: selection, column: 5)

                    if storedSubjectKey == Self.storageKey(for: subject) {
                        if storedHash != currentSnapshotHash {
                            staleDigests.append(digest)
                        }
                    } else if storedKind == AssistantArtifactSubject.Kind.section.rawValue,
                        storedParent == subject.identifier,
                        preservingSectionHashes[storedIdentifier] != storedHash {
                        staleDigests.append(digest)
                    }
                }
                sqlite3_finalize(selection)

                let deletion = try Self.prepare(
                    "DELETE FROM artifacts WHERE key_digest = ?",
                    in: database
                )
                defer { sqlite3_finalize(deletion) }
                var removed = 0
                for digest in staleDigests {
                    sqlite3_reset(deletion)
                    sqlite3_clear_bindings(deletion)
                    try Self.bind(digest, at: 1, in: deletion, database: database)
                    try Self.stepToCompletion(deletion, database: database)
                    removed += Int(sqlite3_changes(database))
                }
                try Self.execute("COMMIT", in: database)
                if removed > 0 { contentRevision &+= 1 }
                if removed > 0 {
                    try Self.execute("PRAGMA incremental_vacuum", in: database)
                }
                try applyDatabaseFileAttributes()
                return removed
            } catch {
                try? Self.execute("ROLLBACK", in: database)
                throw error
            }
        } catch {
            throw Self.cacheError(from: error)
        }
    }

    /// Captures the cache mutation generation before a caller begins delayed
    /// derivation. `removeStaleArtifacts` consumes it atomically on this actor.
    func stalePruningReceipt() -> UInt64 {
        contentRevision
    }

    /// Removes all reproducible intelligence that can retain content from one
    /// permanently deleted library item. Library-scoped rows are intentionally
    /// invalidated as a group because their bounded evidence may combine the
    /// deleted item with unrelated notes and the compact cache schema does not
    /// duplicate every evidence owner as a queryable column.
    ///
    /// Page identifiers are supplied by the verified Canvas Core snapshots and
    /// deleted-page tombstones captured before the item directory is staged for
    /// deletion. This also removes page-scoped section rows whose parent is a
    /// page rather than the notebook identifier.
    @discardableResult
    func removeArtifacts(
        associatedWith itemID: UUID,
        pageIDs: Set<UUID> = []
    ) throws -> Int {
        guard isSealed == false else { return 0 }
        guard let database else {
            throw AssistantArtifactCacheError.io("The SQLite database is closed.")
        }

        let itemIdentifier = itemID.uuidString
        let pageIdentifiers = Set(pageIDs.map(\.uuidString))
        let notebookScopeKey = Self.storageKey(
            for: AssistantArtifactScopeIdentity.notebook(itemID)
        )
        let pageScopeKeys = Set(pageIDs.map {
            Self.storageKey(for: AssistantArtifactScopeIdentity.page($0))
        })
        let libraryScopeKey = Self.storageKey(
            for: AssistantArtifactScopeIdentity.library
        )

        do {
            try Self.execute("BEGIN IMMEDIATE", in: database)
            do {
                let selection = try Self.prepare(
                    """
                    SELECT key_digest, subject_kind, subject_identifier,
                           parent_subject_identifier, scope_key
                    FROM artifacts
                    WHERE entry_type IN (?, ?)
                    """,
                    in: database
                )
                try Self.bind(Self.v2EntryType, at: 1, in: selection, database: database)
                try Self.bind(
                    Self.manifestEntryType,
                    at: 2,
                    in: selection,
                    database: database
                )

                var doomedDigests: [String] = []
                while true {
                    let result = sqlite3_step(selection)
                    if result == SQLITE_DONE { break }
                    guard result == SQLITE_ROW else {
                        sqlite3_finalize(selection)
                        throw Self.failure(for: result, database: database)
                    }
                    let digest = Self.text(in: selection, column: 0)
                    let subjectKind = Self.text(in: selection, column: 1)
                    let subjectIdentifier = Self.text(in: selection, column: 2)
                    let parentIdentifier = Self.text(in: selection, column: 3)
                    let scopeKey = Self.text(in: selection, column: 4)

                    let isOwnedNotebook = subjectKind
                        == AssistantArtifactSubject.Kind.notebook.rawValue
                        && subjectIdentifier == itemIdentifier
                    let isOwnedPage = subjectKind
                        == AssistantArtifactSubject.Kind.page.rawValue
                        && pageIdentifiers.contains(subjectIdentifier)
                    let isOwnedSection = subjectKind
                        == AssistantArtifactSubject.Kind.section.rawValue
                        && (parentIdentifier == itemIdentifier
                        || pageIdentifiers.contains(parentIdentifier))
                    let isOwnedScope = scopeKey == notebookScopeKey
                        || pageScopeKeys.contains(scopeKey)
                    if scopeKey == libraryScopeKey
                        || isOwnedNotebook
                        || isOwnedPage
                        || isOwnedSection
                        || isOwnedScope {
                        doomedDigests.append(digest)
                    }
                }
                sqlite3_finalize(selection)

                let deletion = try Self.prepare(
                    "DELETE FROM artifacts WHERE key_digest = ?",
                    in: database
                )
                defer { sqlite3_finalize(deletion) }
                var removed = 0
                for digest in doomedDigests {
                    sqlite3_reset(deletion)
                    sqlite3_clear_bindings(deletion)
                    try Self.bind(digest, at: 1, in: deletion, database: database)
                    try Self.stepToCompletion(deletion, database: database)
                    removed += Int(sqlite3_changes(database))
                }
                try Self.execute("COMMIT", in: database)
                if removed > 0 { contentRevision &+= 1 }
                if removed > 0 {
                    try Self.execute("PRAGMA incremental_vacuum", in: database)
                }
                try applyDatabaseFileAttributes()
                return removed
            } catch {
                try? Self.execute("ROLLBACK", in: database)
                throw error
            }
        } catch {
            throw Self.cacheError(from: error)
        }
    }

    @discardableResult
    func removeAll() throws -> Int {
        try removeAll(sealing: false)
    }

    /// Permanently seals this actor instance at the deletion boundary, then
    /// clears and physically compacts the database. A newly opened generation
    /// can be installed for foreground work while delayed tasks holding this
    /// instance are prevented from resurrecting pre-deletion artifacts, even
    /// if the purge itself reports an I/O failure.
    @discardableResult
    func removeAllAndSeal() throws -> Int {
        try removeAll(sealing: true)
    }

    private func removeAll(sealing: Bool) throws -> Int {
        if sealing {
            isSealed = true
        } else {
            guard isSealed == false else { return 0 }
        }
        guard let database else {
            throw AssistantArtifactCacheError.io("The SQLite database is closed.")
        }
        do {
            let count = try Self.rowCount(in: database)
            try Self.execute("DELETE FROM artifacts", in: database)
            if count > 0 { contentRevision &+= 1 }
            try Self.execute("VACUUM", in: database)
            try applyDatabaseFileAttributes()
            return count
        } catch let error as SQLiteCacheFailure {
            throw AssistantArtifactCacheError.io(error.message)
        } catch {
            throw AssistantArtifactCacheError.io(error.localizedDescription)
        }
    }

    func statistics() -> AssistantArtifactCacheStatistics {
        let count = database.flatMap { try? Self.rowCount(in: $0) } ?? 0
        let bytes = database.flatMap { try? Self.logicalByteCount(in: $0) } ?? 0
        let physicalBytes = database.flatMap {
            try? Self.allocatedPhysicalByteCount(in: $0)
        } ?? 0
        return AssistantArtifactCacheStatistics(
            artifactCount: count,
            totalBytes: bytes,
            physicalBytes: physicalBytes,
            maximumBytes: limits.maximumBytes,
            trimTargetBytes: limits.trimTargetBytes
        )
    }

    private func delete(digest: String) throws {
        guard let database else { return }
        let statement = try Self.prepare(
            "DELETE FROM artifacts WHERE key_digest = ?",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try Self.bind(digest, at: 1, in: statement, database: database)
        try Self.stepToCompletion(statement, database: database)
        if sqlite3_changes(database) > 0 { contentRevision &+= 1 }
        try applyDatabaseFileAttributes()
    }

    private func consumeAccessSequence() throws -> Int64 {
        guard let database else {
            throw AssistantArtifactCacheError.io("The SQLite database is closed.")
        }
        if nextAccessSequence == .max {
            try Self.execute(
                "UPDATE artifacts SET last_access_sequence = last_access_sequence / 2",
                in: database
            )
            nextAccessSequence = try Self.nextSequence(in: database)
        }
        let sequence = nextAccessSequence
        nextAccessSequence += 1
        return sequence
    }

    private func applyDatabaseFileAttributes() throws {
        try Self.applyDatabaseFileAttributes(
            at: databaseURL,
            fileManager: fileManager
        )
    }

    private static func applyDatabaseFileAttributes(
        at databaseURL: URL,
        fileManager: FileManager
    ) throws {
        try applyFileAttributesIfPresent(to: databaseURL, fileManager: fileManager)
        for suffix in ["-journal", "-wal", "-shm"] {
            try applyFileAttributesIfPresent(
                to: URL(fileURLWithPath: databaseURL.path + suffix),
                fileManager: fileManager
            )
        }
    }

    private static func removeLegacyFileCacheIfPresent(
        at storageRoot: URL,
        fileManager: FileManager
    ) throws {
        let entries = storageRoot.appendingPathComponent("Entries", isDirectory: true)
        let manifest = storageRoot.appendingPathComponent("manifest.json")
        if fileManager.fileExists(atPath: entries.path) {
            try fileManager.removeItem(at: entries)
        }
        if fileManager.fileExists(atPath: manifest.path) {
            try fileManager.removeItem(at: manifest)
        }
    }

    private static func openRecoveringCorruption(
        at url: URL,
        fileManager: FileManager
    ) throws -> OpaquePointer {
        do {
            return try openAndPrepare(at: url)
        } catch let error as SQLiteCacheFailure where error.isCorruption {
            try removeDatabaseFiles(at: url, fileManager: fileManager)
            return try openAndPrepare(at: url)
        }
    }

    private static func openAndPrepare(at url: URL) throws -> OpaquePointer {
        var database: OpaquePointer?
        let openResult = sqlite3_open_v2(
            url.path,
            &database,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let database else {
            let failure = failure(for: openResult, database: database)
            if let database { sqlite3_close_v2(database) }
            throw failure
        }
        do {
            sqlite3_extended_result_codes(database, 1)
            sqlite3_busy_timeout(database, 2_000)
            try execute("PRAGMA journal_mode = DELETE", in: database)
            try execute("PRAGMA synchronous = FULL", in: database)
            try execute("PRAGMA temp_store = MEMORY", in: database)
            try execute("PRAGMA trusted_schema = OFF", in: database)
            try quickCheck(database)
            try createSchema(database)
            return database
        } catch {
            sqlite3_close_v2(database)
            throw error
        }
    }

    private static func createSchema(_ database: OpaquePointer) throws {
        let currentVersion = try integer(from: "PRAGMA user_version", in: database)
        guard currentVersion >= 0, currentVersion <= schemaVersion else {
            throw SQLiteCacheFailure(
                code: SQLITE_SCHEMA,
                message: "Unsupported assistant-cache schema version \(currentVersion)."
            )
        }
        let autoVacuumMode = try integer(from: "PRAGMA auto_vacuum", in: database)
        if autoVacuumMode != 2 {
            try execute("PRAGMA auto_vacuum = INCREMENTAL", in: database)
            try execute("VACUUM", in: database)
        }
        try execute("BEGIN IMMEDIATE", in: database)
        do {
            try execute(
                """
                CREATE TABLE IF NOT EXISTS artifacts (
                    key_digest TEXT PRIMARY KEY NOT NULL,
                    note_id TEXT NOT NULL,
                    content_hash TEXT NOT NULL,
                    artifact_data BLOB NOT NULL,
                    checksum TEXT NOT NULL,
                    byte_count INTEGER NOT NULL CHECK(byte_count >= 0),
                    last_access_sequence INTEGER NOT NULL,
                    created_at REAL NOT NULL,
                    last_accessed_at REAL NOT NULL
                );
                CREATE INDEX IF NOT EXISTS artifacts_note_hash
                    ON artifacts(note_id, content_hash);
                """,
                in: database
            )
            if currentVersion < 2 {
                try execute(
                    "ALTER TABLE artifacts ADD COLUMN entry_type TEXT NOT NULL DEFAULT 'artifact-v1'",
                    in: database
                )
                try execute(
                    "ALTER TABLE artifacts ADD COLUMN subject_key TEXT",
                    in: database
                )
                try execute(
                    "ALTER TABLE artifacts ADD COLUMN subject_kind TEXT",
                    in: database
                )
                try execute(
                    "ALTER TABLE artifacts ADD COLUMN subject_identifier TEXT",
                    in: database
                )
                try execute(
                    "ALTER TABLE artifacts ADD COLUMN parent_subject_identifier TEXT",
                    in: database
                )
                try execute(
            "ALTER TABLE artifacts ADD COLUMN scope_key TEXT",
            in: database
        )
        try execute(
            "ALTER TABLE artifacts ADD COLUMN snapshot_hash TEXT",
            in: database
        )
        try execute(
            "ALTER TABLE artifacts ADD COLUMN artifact_kind TEXT",
            in: database
        )
        // V1 artifacts are fully reproducible and lack the complete
        // V2 provenance needed for safe reuse. Drop them as part of
        // the one-time schema migration instead of carrying rows that
        // can never satisfy an exact V2 identity.
        try execute(
            "DELETE FROM artifacts WHERE entry_type = 'artifact-v1'",
            in: database
        )
    }
    try execute(
        """
        CREATE INDEX IF NOT EXISTS artifacts_v2_scope
            ON artifacts(entry_type, scope_key, subject_key, snapshot_hash);
        CREATE INDEX IF NOT EXISTS artifacts_v2_parent
            ON artifacts(entry_type, scope_key, parent_subject_identifier);
        PRAGMA user_version = 2;
        """,
        in: database
    )
        try execute("COMMIT", in: database)
    } catch {
        try? execute("ROLLBACK", in: database)
        throw error
    }
    }

    private static func quickCheck(_ database: OpaquePointer) throws {
        let statement = try prepare("PRAGMA quick_check", in: database)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            throw failure(for: result, database: database)
        }
        guard text(in: statement, column: 0) == "ok" else {
            throw SQLiteCacheFailure(
                code: SQLITE_CORRUPT,
                message: "The assistant-cache database failed its integrity check."
            )
        }
    }

    private static func upsert(
        _ artifact: AssistantArtifactRecordV2,
        data: Data,
        checksum: String,
        digest: String,
        byteCount: Int64,
        accessSequence: Int64,
        database: OpaquePointer
    ) throws {
        try upsertV2Payload(
            entryType: v2EntryType,
            subject: artifact.key.subject,
            snapshotHash: artifact.key.snapshotHash,
            scope: artifact.key.scope,
            artifactKind: artifact.key.artifactKind,
            createdAt: artifact.createdAt,
            data: data,
            checksum: checksum,
            digest: digest,
            byteCount: byteCount,
            accessSequence: accessSequence,
            database: database
        )
    }

    private static func upsert(
        _ manifest: AssistantIntelligenceManifest,
        data: Data,
        checksum: String,
        digest: String,
        byteCount: Int64,
        accessSequence: Int64,
        database: OpaquePointer
    ) throws {
        try upsertV2Payload(
            entryType: manifestEntryType,
            subject: manifest.key.subject,
            snapshotHash: manifest.key.snapshotHash,
            scope: manifest.key.scope,
            artifactKind: nil,
            createdAt: manifest.createdAt,
            data: data,
            checksum: checksum,
            digest: digest,
            byteCount: byteCount,
            accessSequence: accessSequence,
            database: database
        )
    }

    private static func upsertV2Payload(
        entryType: String,
        subject: AssistantArtifactSubject,
        snapshotHash: String,
        scope: AssistantArtifactScopeIdentity,
        artifactKind: AssistantArtifactKind?,
        createdAt: Date,
        data: Data,
        checksum: String,
        digest: String,
        byteCount: Int64,
        accessSequence: Int64,
        database: OpaquePointer
    ) throws {
        let statement = try prepare(
            """
            INSERT INTO artifacts (
                key_digest, note_id, content_hash, artifact_data,
                checksum, byte_count, last_access_sequence,
                created_at, last_accessed_at, entry_type,
                subject_key, subject_kind, subject_identifier,
                parent_subject_identifier, scope_key, snapshot_hash,
                artifact_kind
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(key_digest) DO UPDATE SET
                note_id = excluded.note_id,
                content_hash = excluded.content_hash,
                artifact_data = excluded.artifact_data,
                checksum = excluded.checksum,
                byte_count = excluded.byte_count,
                last_access_sequence = excluded.last_access_sequence,
                created_at = excluded.created_at,
                last_accessed_at = excluded.last_accessed_at,
                entry_type = excluded.entry_type,
                subject_key = excluded.subject_key,
                subject_kind = excluded.subject_kind,
                subject_identifier = excluded.subject_identifier,
                parent_subject_identifier = excluded.parent_subject_identifier,
                scope_key = excluded.scope_key,
                snapshot_hash = excluded.snapshot_hash,
                artifact_kind = excluded.artifact_kind
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(digest, at: 1, in: statement, database: database)
        try bind(subject.identifier, at: 2, in: statement, database: database)
        try bind(snapshotHash, at: 3, in: statement, database: database)
        try bind(data, at: 4, in: statement, database: database)
        try bind(checksum, at: 5, in: statement, database: database)
        try bind(byteCount, at: 6, in: statement, database: database)
        try bind(accessSequence, at: 7, in: statement, database: database)
        try bind(createdAt.timeIntervalSince1970, at: 8, in: statement, database: database)
        try bind(Date().timeIntervalSince1970, at: 9, in: statement, database: database)
        try bind(entryType, at: 10, in: statement, database: database)
        try bind(storageKey(for: subject), at: 11, in: statement, database: database)
        try bind(subject.kind.rawValue, at: 12, in: statement, database: database)
        try bind(subject.identifier, at: 13, in: statement, database: database)
        try bind(subject.parentIdentifier, at: 14, in: statement, database: database)
        try bind(storageKey(for: scope), at: 15, in: statement, database: database)
        try bind(snapshotHash, at: 16, in: statement, database: database)
        try bind(artifactKind?.rawValue, at: 17, in: statement, database: database)
        try stepToCompletion(statement, database: database)
    }

    private static func storedPayload(
        for digest: String,
        database: OpaquePointer
    ) throws -> (data: Data, checksum: String)? {
        let statement = try prepare(
            "SELECT artifact_data, checksum FROM artifacts WHERE key_digest = ?",
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try bind(digest, at: 1, in: statement, database: database)
        let result = sqlite3_step(statement)
        if result == SQLITE_DONE { return nil }
        guard result == SQLITE_ROW else {
            throw failure(for: result, database: database)
        }
        return (
            data(in: statement, column: 0),
            text(in: statement, column: 1)
        )
    }

    @discardableResult
    private static func trimIfNeeded(
        database: OpaquePointer,
        limits: AssistantArtifactCacheLimits
    ) throws -> Bool {
        var totalBytes = try logicalByteCount(in: database)
        let allocatedBytes = try allocatedPhysicalByteCount(in: database)
        guard totalBytes > limits.maximumBytes
            || allocatedBytes > limits.maximumBytes else {
            return false
        }
        let crossedOnlyPhysicalCeiling = totalBytes <= limits.maximumBytes
        let statement = try prepare(
            """
            SELECT key_digest, byte_count
            FROM artifacts
            ORDER BY last_access_sequence ASC, key_digest ASC
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }
        var victims: [(String, Int64)] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else {
                throw failure(for: result, database: database)
            }
            victims.append((
                text(in: statement, column: 0),
                sqlite3_column_int64(statement, 1)
            ))
        }
        let deletion = try prepare(
            "DELETE FROM artifacts WHERE key_digest = ?",
            in: database
        )
        defer { sqlite3_finalize(deletion) }
        var deletedCount = 0
        for (digest, byteCount) in victims {
            guard crossedOnlyPhysicalCeiling
                ? deletedCount == 0
                : totalBytes > limits.trimTargetBytes else {
                break
            }
            sqlite3_reset(deletion)
            sqlite3_clear_bindings(deletion)
            try bind(digest, at: 1, in: deletion, database: database)
            try stepToCompletion(deletion, database: database)
            totalBytes = max(totalBytes - byteCount, 0)
            deletedCount += 1
        }
        return true
    }

    /// Reclaims free pages after an LRU trim. Incremental vacuum is cheap in
    /// the normal case; the full rewrite is reserved for the rare fragmented
    /// database that would otherwise remain above the hard physical ceiling.
    private static func compactAfterTrim(
        database: OpaquePointer,
        limits: AssistantArtifactCacheLimits
    ) throws {
        do {
            try execute("PRAGMA incremental_vacuum", in: database)
            if try allocatedPhysicalByteCount(in: database) > limits.maximumBytes {
                try execute("VACUUM", in: database)
            }
            // If fragmentation/index overhead made the estimate optimistic,
            // evict one additional LRU row at a time and remeasure. This keeps
            // newer entries whenever possible instead of clearing the entire
            // reproducible cache after one unusually fragmented write.
            while try allocatedPhysicalByteCount(in: database) > limits.maximumBytes,
                try deleteOldestArtifact(in: database) {
                try execute("VACUUM", in: database)
            }
        } catch {
            // Cached intelligence is reproducible. If compaction itself fails,
            // prefer dropping it over leaving a database beyond the promised
            // device-storage ceiling.
            try? execute("DELETE FROM artifacts", in: database)
            try? execute("VACUUM", in: database)
            throw error
        }

        guard try allocatedPhysicalByteCount(in: database) <= limits.maximumBytes else {
            try execute("DELETE FROM artifacts", in: database)
            try execute("VACUUM", in: database)
            throw SQLiteCacheFailure(
                code: SQLITE_FULL,
                message: "Assistant cache could not be compacted below its physical byte ceiling."
            )
        }
    }

    private static func nextSequence(in database: OpaquePointer) throws -> Int64 {
        let maximum = try integer(
            from: "SELECT COALESCE(MAX(last_access_sequence), 0) FROM artifacts",
            in: database
        )
        return maximum == .max ? .max : maximum + 1
    }

    private static func rowCount(in database: OpaquePointer) throws -> Int {
        Int(try integer(
            from: """
                SELECT COUNT(*) FROM artifacts
                WHERE entry_type <> 'intelligence-manifest-v2'
                """,
            in: database
        ))
    }

    private static func logicalByteCount(in database: OpaquePointer) throws -> Int64 {
        try integer(
            from: "SELECT COALESCE(SUM(byte_count), 0) FROM artifacts",
            in: database
        )
    }

    private static func allocatedPhysicalByteCount(
        in database: OpaquePointer
    ) throws -> Int64 {
        let pageCount = try integer(from: "PRAGMA page_count", in: database)
        let pageSize = try integer(from: "PRAGMA page_size", in: database)
        return pageCount * pageSize
    }

    @discardableResult
    private static func deleteOldestArtifact(
        in database: OpaquePointer
    ) throws -> Bool {
        let statement = try prepare(
            """
            DELETE FROM artifacts
            WHERE key_digest = (
                SELECT key_digest FROM artifacts
                ORDER BY last_access_sequence ASC, key_digest ASC
                LIMIT 1
            )
            """,
            in: database
        )
        defer { sqlite3_finalize(statement) }
        try stepToCompletion(statement, database: database)
        return sqlite3_changes(database) > 0
    }

    private static func integer(from sql: String, in database: OpaquePointer) throws -> Int64 {
        let statement = try prepare(sql, in: database)
        defer { sqlite3_finalize(statement) }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            throw failure(for: result, database: database)
        }
        return sqlite3_column_int64(statement, 0)
    }

    private static func execute(_ sql: String, in database: OpaquePointer) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(database, sql, nil, nil, &errorMessage)
        guard result == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(errorMessage)
            throw SQLiteCacheFailure(code: result, message: message)
        }
    }

    private static func cacheError(from error: any Error) -> AssistantArtifactCacheError {
        if let error = error as? AssistantArtifactCacheError { return error }
        if let error = error as? SQLiteCacheFailure { return .io(error.message) }
        return .io(error.localizedDescription)
    }

    private static func prepare(
        _ sql: String,
        in database: OpaquePointer
    ) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else {
            throw failure(for: result, database: database)
        }
        return statement
    }

    private static func stepToCompletion(
        _ statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else {
            throw failure(for: result, database: database)
        }
    }

    private static func bind(
        _ value: String,
        at index: Int32,
        in statement: OpaquePointer,
        database: OpaquePointer
    ) throws {
        let result = value.withCString {
            sqlite3_bind_text(statement, index, $0, -1, transientDestructor)
        }
        guard result == SQLITE_OK else {
            throw failure(for: result, database: database)
        }
    }

    private static func bind(
        _ value: String?,
        at index: Int32,
        in statement: OpaquePointer,
        database: OpaquePointer
) throws {
    guard let value else {
        let result = sqlite3_bind_null(statement, index)
        guard result == SQLITE_OK else {
            throw failure(for: result, database: database)
        }
        return
    }
    try bind(value, at: index, in: statement, database: database)
}

private static func bind(
    _ value: Data,
    at index: Int32,
    in statement: OpaquePointer,
    database: OpaquePointer
) throws {
    let result = value.withUnsafeBytes {
        sqlite3_bind_blob(
            statement,
            index,
            $0.baseAddress,
            Int32($0.count),
            transientDestructor
        )
    }
    guard result == SQLITE_OK else {
        throw failure(for: result, database: database)
    }
}

private static func bind(
    _ value: Int64,
    at index: Int32,
    in statement: OpaquePointer,
    database: OpaquePointer
) throws {
    let result = sqlite3_bind_int64(statement, index, value)
    guard result == SQLITE_OK else {
        throw failure(for: result, database: database)
    }
}

private static func bind(
    _ value: Double,
    at index: Int32,
    in statement: OpaquePointer,
    database: OpaquePointer
) throws {
    let result = sqlite3_bind_double(statement, index, value)
    guard result == SQLITE_OK else {
        throw failure(for: result, database: database)
    }
}

private static func data(in statement: OpaquePointer, column: Int32) -> Data {
    let count = Int(sqlite3_column_bytes(statement, column))
    guard count > 0, let bytes = sqlite3_column_blob(statement, column) else {
        return Data()
    }
    return Data(bytes: bytes, count: count)
}

private static func text(in statement: OpaquePointer, column: Int32) -> String {
    guard let text = sqlite3_column_text(statement, column) else { return "" }
    return String(cString: text)
}

private static var transientDestructor: sqlite3_destructor_type {
    unsafeBitCast(-1, to: sqlite3_destructor_type.self)
}

private static func failure(
    for code: Int32,
    database: OpaquePointer?
) -> SQLiteCacheFailure {
    SQLiteCacheFailure(
        code: code,
        message: database.map { String(cString: sqlite3_errmsg($0)) }
            ?? "SQLite error \(code)."
    )
}

private static func removeDatabaseFiles(
    at url: URL,
    fileManager: FileManager
) throws {
    for path in [url.path, url.path + "-journal", url.path + "-wal", url.path + "-shm"] {
        if fileManager.fileExists(atPath: path) {
            try fileManager.removeItem(atPath: path)
        }
    }
}

private static func applyDirectoryAttributes(
    to url: URL,
    fileManager: FileManager
) throws {
    var mutableURL = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try mutableURL.setResourceValues(values)
#if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    try fileManager.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: url.path
    )
#endif
}

private static func applyFileAttributesIfPresent(
    to url: URL,
    fileManager: FileManager
) throws {
    guard fileManager.fileExists(atPath: url.path) else { return }
    var mutableURL = url
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try mutableURL.setResourceValues(values)
#if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
    try fileManager.setAttributes(
        [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
        ofItemAtPath: url.path
    )
#endif
}

private static func validate(_ artifact: AssistantArtifactRecordV2) throws {
    try validate(artifact.key)
    guard artifact.subjectRevision >= 0 else {
        throw AssistantArtifactCacheError.invalidArtifact(
            "The subject revision is negative."
        )
    }
    guard artifact.markdown
        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
        throw AssistantArtifactCacheError.invalidArtifact("The artifact body is empty.")
    }
    guard artifact.coverage.totalSectionCount >= 0 else {
        throw AssistantArtifactCacheError.invalidArtifact(
            "The total section count is negative."
        )
    }
    guard artifact.coverage.coveredSectionIDs.count
        <= artifact.coverage.totalSectionCount
        || artifact.coverage.totalSectionCount == 0 else {
        throw AssistantArtifactCacheError.invalidArtifact(
            "Coverage contains more sections than the declared total."
        )
    }
    try validateUniqueNonempty(artifact.sourceIDs, field: "source identifiers")
    try validateUniqueNonempty(
        artifact.coverage.coveredSectionIDs,
        field: "covered section identifiers"
    )
    try validateUniqueNonempty(
        artifact.coverage.missingSectionIDs,
        field: "missing section identifiers"
    )
    guard Set(artifact.coverage.coveredSectionIDs)
        .isDisjoint(with: artifact.coverage.missingSectionIDs) else {
        throw AssistantArtifactCacheError.invalidArtifact(
            "A section cannot be both covered and missing."
        )
    }
    try validateUniqueNonempty(
        artifact.sectionDigests.map(\.sectionID),
        field: "section digest identifiers"
    )
    for digest in artifact.sectionDigests {
        guard digest.contentHash
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw AssistantArtifactCacheError.invalidArtifact(
                "Section \(digest.sectionID) has an empty content hash."
            )
        }
        guard digest.markdown
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw AssistantArtifactCacheError.invalidArtifact(
                "Section \(digest.sectionID) has an empty body."
            )
        }
        try validateUniqueNonempty(
            digest.sourceIDs,
            field: "source identifiers for section \(digest.sectionID)"
        )
    }
}

private static func validate(_ key: AssistantArtifactCacheKeyV2) throws {
    try validate(key.subject)
    try validate(key.scope)
    let values: [(String, String)] = [
        ("snapshot hash", key.snapshotHash),
        ("task identifier", key.taskIdentifier),
        ("prompt version", key.promptVersion),
        ("schema version", key.schemaVersion),
        ("retrieval version", key.retrievalVersion),
        ("derivation version", key.derivationVersion),
        ("provider identifier", key.providerIdentifier),
        ("model build", key.modelBuild),
        ("locale identifier", key.localeIdentifier),
        ("output style", key.outputStyle),
    ]
    try validateNonempty(values)
    if let requestFingerprint = key.requestFingerprint,
        requestFingerprint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw AssistantArtifactCacheError.invalidKey(
            "The request fingerprint is empty."
        )
    }
}

private static func validate(_ subject: AssistantArtifactSubject) throws {
    try validateNonempty([("subject identifier", subject.identifier)])
    switch subject.kind {
    case .section:
        guard let parentIdentifier = subject.parentIdentifier,
            parentIdentifier
                .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
            throw AssistantArtifactCacheError.invalidKey(
                "A section subject requires a parent identifier."
            )
        }
    case .page, .notebook, .library:
        guard subject.parentIdentifier == nil else {
            throw AssistantArtifactCacheError.invalidKey(
                "Only a section subject may have a parent identifier."
            )
        }
    }
}

private static func validate(_ scope: AssistantArtifactScopeIdentity) throws {
    try validateNonempty([("scope identifier", scope.identifier)])
}

private static func validate(_ manifest: AssistantIntelligenceManifest) throws {
    try validate(manifest.key)
    guard manifest.presentArtifactKinds
        .isDisjoint(with: manifest.absentArtifactKinds) else {
        throw AssistantArtifactCacheError.invalidArtifact(
            "An artifact kind cannot be both present and absent."
        )
    }
}

private static func validate(_ key: AssistantIntelligenceManifestKey) throws {
    try validate(key.subject)
    try validate(key.scope)
    try validateNonempty([
        ("snapshot hash", key.snapshotHash),
        ("prompt version", key.promptVersion),
        ("schema version", key.schemaVersion),
        ("retrieval version", key.retrievalVersion),
        ("derivation version", key.derivationVersion),
        ("provider identifier", key.providerIdentifier),
        ("model build", key.modelBuild),
        ("locale identifier", key.localeIdentifier),
    ])
}

private static func validateNonempty(_ values: [(String, String)]) throws {
    for (name, value) in values
    where value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        throw AssistantArtifactCacheError.invalidKey("The \(name) is empty.")
    }
}

private static func validateUniqueNonempty(_ values: [String], field: String) throws {
    guard values.allSatisfy({
        $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }) else {
        throw AssistantArtifactCacheError.invalidArtifact("The \(field) contain an empty value.")
    }
    guard Set(values).count == values.count else {
        throw AssistantArtifactCacheError.invalidArtifact("The \(field) are not unique.")
    }
}

private static func digest(for key: AssistantArtifactCacheKeyV2) throws -> String {
    try validate(key)
    return sha256(taggedData("artifact-v2", payload: try encoder.encode(key)))
}

private static func digest(for key: AssistantIntelligenceManifestKey) throws -> String {
    try validate(key)
    return sha256(taggedData("intelligence-manifest-v2", payload: try encoder.encode(key)))
}

private static func taggedData(_ tag: String, payload: Data) -> Data {
    var data = Data(tag.utf8)
    data.append(0)
    data.append(payload)
    return data
}

private static func storageKey(for subject: AssistantArtifactSubject) -> String {
    let parent = subject.parentIdentifier ?? ""
    return "\(subject.kind.rawValue):\(parent.utf8.count):\(parent):\(subject.identifier.utf8.count):\(subject.identifier)"
}

private static func storageKey(for scope: AssistantArtifactScopeIdentity) -> String {
    "\(scope.kind.rawValue):\(scope.identifier.utf8.count):\(scope.identifier)"
}

private static func metadataStrings(
    for key: AssistantArtifactCacheKeyV2
) -> [String] {
    [
        storageKey(for: key.subject),
        key.snapshotHash,
        key.taskIdentifier,
        key.artifactKind.rawValue,
        storageKey(for: key.scope),
        key.requestFingerprint ?? "",
        key.promptVersion,
        key.schemaVersion,
        key.retrievalVersion,
        key.derivationVersion,
        key.providerIdentifier,
        key.modelBuild,
        key.localeIdentifier,
        key.outputStyle,
    ]
}

private static func metadataStrings(
    for key: AssistantIntelligenceManifestKey
) -> [String] {
    [
        storageKey(for: key.subject),
        key.snapshotHash,
        storageKey(for: key.scope),
        key.promptVersion,
        key.schemaVersion,
        key.retrievalVersion,
        key.derivationVersion,
        key.providerIdentifier,
        key.modelBuild,
        key.localeIdentifier,
    ]
}

private static var encoder: JSONEncoder {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    encoder.dateEncodingStrategy = .millisecondsSince1970
    return encoder
}

private static var decoder: JSONDecoder {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .millisecondsSince1970
    return decoder
}

private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

private static func quotaByteCount(
    data: Data,
    digest: String,
    metadata: [String],
    checksum: String
) -> Int64 {
    let metadataBytes = metadata.reduce(
        digest.utf8.count + checksum.utf8.count + 128
    ) { partial, value in
        partial + value.utf8.count
    }
    let (total, overflow) = Int64(data.count).addingReportingOverflow(
        Int64(metadataBytes)
    )
    return overflow ? .max : total
}

private struct SQLiteCacheFailure: Error {
    let code: Int32
    let message: String

    var isCorruption: Bool {
        let primaryCode = code & 0xFF
        return primaryCode == SQLITE_CORRUPT || primaryCode == SQLITE_NOTADB
    }
}
}
