import Foundation

/// Immutable identity and deadline for one user-visible assistant operation.
/// Conversation identity remains stable across grounded follow-ups; *uiEpoch*
/// changes whenever presentation starts a new operation so a detached panel
/// can reject updates from an earlier UI lifetime.
struct AssistantUserRequest: Sendable {
    let requestID: UUID
    let conversationID: UUID
    let uiEpoch: UInt64
    let task: AssistantTask
    let prompt: String
    let scope: AssistantScope
    let deadline: ContinuousClock.Instant
}

/// The bounded, verified inputs assembled before a route generates output.
struct PreparedAssistantRequest: Sendable {
    let request: AssistantUserRequest
    let snapshot: NoteContentSnapshot?
    let retrievedPassages: [AssistantSearchResult]
}

enum AssistantPipelineUpdatePayload: Equatable, Sendable {
    case phase(AssistantWorkPhase)
    case quickResult(text: String, kind: AssistantPreliminaryResultKind)
    case partialText(String)
    case sources([AssistantSearchResult])
    case completed
    case stopped
    case failedWithFallback(String)

    var isTerminal: Bool {
        switch self {
        case .completed, .stopped, .failedWithFallback:
            true
        case .phase, .quickResult, .partialText, .sources:
            false
        }
    }
}

struct AssistantPipelineUpdate: Equatable, Sendable {
    let requestID: UUID
    let conversationID: UUID
    let uiEpoch: UInt64
    let sequence: UInt64
    let snapshotIdentity: NoteSnapshotIdentity?
    let payload: AssistantPipelineUpdatePayload
}

struct AssistantJobHandle: Sendable {
    let events: AsyncStream<AssistantPipelineUpdate>

    /// Model generation must not begin until every client-wide cancellation
    /// accepted before this admission has been invoked in process-wide order.
    /// A provider may retain its physical model lane until cancellation-resistant
    /// work really drains; provider admission owns that bounded handoff.
    let modelCancellationBarrier: Task<Void, Never>
}

/// Process-wide admission and lifecycle envelope for foreground assistant work.
/// Route execution is still delegated to the existing presentation pipeline,
/// but every operation enters here first and leaves through exactly one
/// terminal update. Starting a new operation preempts the previous owner.
public actor AssistantPipelineCoordinator {
    typealias Cancellation = @Sendable () -> Void
    typealias ModelCancellation = @Sendable () async -> Void

    private struct ActiveJob {
        let request: AssistantUserRequest
        let continuation: AsyncStream<AssistantPipelineUpdate>.Continuation
        let cancellation: Cancellation
        var nextSequence: UInt64
        var snapshotIdentity: NoteSnapshotIdentity?
    }

    private var activeJob: ActiveJob?
    /// `AssistantModelClient.cancel()` is client-wide, while presentation
    /// models are panel-local. Keeping the tail here makes cancellation and
    /// admission one process-wide order rather than one order per panel.
    private var modelCancellationTail: Task<Void, Never>?

    public init() {}

    func start(
        request: AssistantUserRequest,
        cancellation: @escaping Cancellation,
        modelCancellation: @escaping ModelCancellation = {}
    ) -> AssistantJobHandle {
        if var previous = activeJob {
            emit(.stopped, to: &previous)
            previous.continuation.finish()
            previous.cancellation()
        }

        let pair = AsyncStream<AssistantPipelineUpdate>.makeStream(
            bufferingPolicy: .bufferingNewest(128)
        )
        var job = ActiveJob(
            request: request,
            continuation: pair.continuation,
            cancellation: cancellation,
            nextSequence: 0,
            snapshotIdentity: nil
        )
        emit(.phase(.readingNote), to: &job)
        activeJob = job
        // Enqueue the new owner's cancellation atomically with admission. A
        // stale presenter can no longer insert a client-wide cancel after this
        // barrier because request-scoped cancellation below rejects it. The
        // provider remains responsible for excluding physically undrained work.
        let modelCancellationBarrier = appendModelCancellation(modelCancellation)
        return AssistantJobHandle(
            events: pair.stream,
            modelCancellationBarrier: modelCancellationBarrier
        )
    }

    /// Invokes client-wide cancellation only while `requestID` still owns
    /// foreground admission. Calls from a displaced presenter are deliberately
    /// ignored: the replacement admission already owns the next cancellation
    /// and must never be cancelled by its predecessor after generation begins.
    func cancelModelSession(
        for requestID: UUID,
        cancellation: @escaping ModelCancellation
    ) async {
        guard activeJob?.request.requestID == requestID else { return }
        let barrier = appendModelCancellation(cancellation)
        await barrier.value
    }

    @discardableResult
    func publish(
        payload: AssistantPipelineUpdatePayload,
        requestID: UUID,
        snapshotIdentity: NoteSnapshotIdentity? = nil
    ) -> Bool {
        guard var job = activeJob, job.request.requestID == requestID else { return false }
        if let snapshotIdentity {
            job.snapshotIdentity = snapshotIdentity
        }
        emit(payload, to: &job)
        if payload.isTerminal {
            job.continuation.finish()
            activeJob = nil
        } else {
            activeJob = job
        }
        return true
    }

    @discardableResult
    func recordPrepared(_ prepared: PreparedAssistantRequest) -> Bool {
        guard var job = activeJob, job.request.requestID == prepared.request.requestID else {
            return false
        }
        job.snapshotIdentity = prepared.snapshot?.identity
        if prepared.retrievedPassages.isEmpty == false {
            emit(.sources(prepared.retrievedPassages), to: &job)
        }
        activeJob = job
        return true
    }

    func activeRequestID() -> UUID? {
        activeJob?.request.requestID
    }

    private func appendModelCancellation(
        _ cancellation: @escaping ModelCancellation
    ) -> Task<Void, Never> {
        let predecessor = modelCancellationTail
        let task = Task {
            await predecessor?.value
            await cancellation()
        }
        modelCancellationTail = task
        return task
    }

    private func emit(
        _ payload: AssistantPipelineUpdatePayload,
        to job: inout ActiveJob
    ) {
        let update = AssistantPipelineUpdate(
            requestID: job.request.requestID,
            conversationID: job.request.conversationID,
            uiEpoch: job.request.uiEpoch,
            sequence: job.nextSequence,
            snapshotIdentity: job.snapshotIdentity,
            payload: payload
        )
        job.nextSequence += 1
        job.continuation.yield(update)
    }
}

/// Serial executor for deterministic work that can be proportional to note
/// size. Keeping hashing, snapshot shaping, and local intelligence off
/// `MainActor` prevents a long notebook from stalling editor input while still
/// avoiding an unbounded collection of detached tasks.
public actor AssistantCPUWorker {
    public init() {}

    func summarySnapshot(
        from indexed: NotebookIndex.ContentSnapshot
    ) throws -> NoteContentSnapshot {
        try AssistantPresentationModel.summarySnapshot(from: indexed)
    }

    func localIntelligence(
        from snapshot: NoteContentSnapshot,
        localeIdentifier: String
    ) -> [AssistantLocalArtifact] {
        AssistantLocalIntelligenceBuilder.artifacts(
            from: snapshot,
            localeIdentifier: localeIdentifier
        )
    }

    func followUpSuggestions(
        from snapshot: NoteContentSnapshot,
        excluding prompt: String
    ) -> [String] {
        AssistantFollowUpSuggestionBuilder.suggestions(
            from: AssistantLocalIntelligenceBuilder.followUpArtifacts(from: snapshot),
            excluding: prompt
        )
    }
}

/// Owns low-priority, reproducible assistant persistence preparation. The app
/// invokes this only after its idle delay; SQLite integrity work, trimming,
/// and compaction therefore execute outside `MainActor` and never gate a
/// foreground answer.
public actor AssistantMaintenanceCoordinator {
    private var artifactCache: AssistantArtifactCache?

    public init() {}

    func prepareArtifactCache(at storageRoot: URL) -> AssistantArtifactCache? {
        if let artifactCache { return artifactCache }
        let prepared = try? AssistantArtifactCache(storageRoot: storageRoot)
        artifactCache = prepared
        return prepared
    }

    /// Releases the process-wide reference after permanent deletion seals the
    /// old generation. A later launch can reopen the reproducible cache; this
    /// process deliberately keeps caching disabled so no pre-purge producer
    /// can switch to a fresh actor and resurrect deleted content.
    func discardArtifactCacheAfterDeletion() {
        artifactCache = nil
    }
}
