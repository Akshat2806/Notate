import Foundation

/// Deliberately small launch contract shared by the app and `NotateUITests`.
/// Keeping it environment-based prevents test data from leaking into a real
/// user's persistent catalog and lets each test launch a clean process.
enum NotateUITestLaunchConfiguration {
    enum AssistantBackend: Equatable {
        case deterministicMock
        case foundationModels
    }

    static var isEnabled: Bool {
        #if DEBUG
        isEnabled(environment: ProcessInfo.processInfo.environment)
        #else
        false
        #endif
    }

    static func isEnabled(environment: [String: String]) -> Bool {
        environment["NOTATE_UI_TESTING"] == "1"
    }

    /// UI automation remains deterministic by default. The real model is an
    /// explicit physical-device probe only; it still uses the same isolated
    /// in-memory catalog and process-temporary asset root as every UI test.
    static var assistantBackend: AssistantBackend {
        assistantBackend(environment: ProcessInfo.processInfo.environment)
    }

    static func assistantBackend(
        environment: [String: String]
    ) -> AssistantBackend {
        guard isEnabled(environment: environment) else {
            return .foundationModels
        }
        return environment["NOTATE_UI_TEST_REAL_MODEL"] == "1"
            ? .foundationModels
            : .deterministicMock
    }

    static var usesFoundationModels: Bool {
        isEnabled && assistantBackend == .foundationModels
    }

    static var seedFixture: Bool {
        isEnabled
            && ProcessInfo.processInfo.environment["NOTATE_UI_TEST_SEED"] == "fixture"
    }

    static var forcesDarkAppearance: Bool {
        isEnabled
            && ProcessInfo.processInfo.environment["NOTATE_UI_TEST_APPEARANCE"] == "dark"
    }

    static var suppressesInitialFocus: Bool {
        isEnabled
            && ProcessInfo.processInfo.environment["NOTATE_UI_TEST_SUPPRESS_AUTOFOCUS"] == "1"
    }

    static var delaysAssistantResponse: Bool {
        isEnabled
            && ProcessInfo.processInfo.environment["NOTATE_UI_TEST_ASSISTANT_DELAY"] == "1"
    }

    static var isolatedLibraryRoot: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "Notate-UITests-\(ProcessInfo.processInfo.processIdentifier)",
            isDirectory: true
        )
    }
}

#if DEBUG
/// Keeps assistant UI automation deterministic without changing the live
/// on-device model path. The fixture response also exercises the answer-level
/// agent identity at the smallest supported mark size.
actor NotateUITestAssistantModelClient: OnDeviceLanguageModelProvider {
    func availability() async -> AssistantModelAvailability { .available }

    func prewarm() async throws {}

    func respond(to request: AssistantModelRequest) async throws -> AssistantModelResponse {
        if NotateUITestLaunchConfiguration.delaysAssistantResponse {
            try await Task.sleep(for: .seconds(3))
        }

        let usesGeneralKnowledge = request.allowsGeneralKnowledge
        return AssistantModelResponse(
            answer: "Fashion notes connect silhouette studies with fitting references across the library.",
            sourceIDs: usesGeneralKnowledge
                ? []
                : request.initialSources.prefix(2).map(\.id),
            followUps: [],
            isGeneralKnowledge: usesGeneralKnowledge,
            outcome: usesGeneralKnowledge ? .generalKnowledge : .answered
        )
    }

    func contextSize() async -> Int { 10_000 }

    func tokenCount(for prompt: String) async -> Int {
        max(1, prompt.utf8.count / 4)
    }

    func prewarmSummary() async throws {}

    func summarizeInFreshSession(
        _ request: OnDeviceSummaryRequest
    ) async throws -> OnDeviceSummaryResponse {
        try await generatedSummary(for: request)
    }

    func summarizeInFreshSession(
        _ request: OnDeviceSummaryRequest,
        onPartialMarkdown: @escaping @Sendable (OnDeviceSummaryPartialResponse) async -> Void
    ) async throws -> OnDeviceSummaryResponse {
        let response = try await generatedSummary(for: request)
        let sourceIDs = response.representedSourceSlots.map { request.sourceIDs[$0] }
        await onPartialMarkdown(OnDeviceSummaryPartialResponse(
            text: "The note connects silhouette studies with practical fitting references.",
            representedSourceIDs: sourceIDs
        ))
        await onPartialMarkdown(OnDeviceSummaryPartialResponse(
            text: response.markdown,
            representedSourceIDs: sourceIDs
        ))
        return response
    }

    private func generatedSummary(
        for request: OnDeviceSummaryRequest
    ) async throws -> OnDeviceSummaryResponse {
        if NotateUITestLaunchConfiguration.delaysAssistantResponse {
            try await Task.sleep(for: .seconds(3))
        }
        return OnDeviceSummaryResponse(
            markdown: """
            ## Silhouette direction

            The note connects silhouette studies with practical fitting references, turning the initial observations into a clear direction for the collection.

            - Compare the recorded shapes against the fitting references.
            - Carry the strongest proportions into the next design pass.
            """,
            representedSourceSlots: Array(request.sourceIDs.indices),
            modelIdentifier: "notate-ui-test.refinement-model",
            modelVersion: "1"
        )
    }

    func cancel() async {}
}
#endif
