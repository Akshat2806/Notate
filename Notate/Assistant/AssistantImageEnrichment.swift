import CoreGraphics
import CryptoKit
import Foundation
import FoundationModels
import ImageIO
import PaperKit
import Vision

private func assistantReadBoundedData(
    at url: URL,
    maximumByteCount: Int
) throws -> Data {
    guard maximumByteCount > 0 else {
        throw CocoaError(.fileReadTooLarge)
    }
    let values = try url.resourceValues(forKeys: [
        .isRegularFileKey,
        .fileSizeKey,
    ])
    guard values.isRegularFile == true,
        let fileSize = values.fileSize,
        fileSize >= 0,
        fileSize <= maximumByteCount else {
        throw CocoaError(.fileReadTooLarge)
    }

    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var data = Data()
    data.reserveCapacity(fileSize)
    var byteCount = 0
    while let chunk = try handle.read(upToCount: 1_024 * 1_024),
        chunk.isEmpty == false {
        let (nextByteCount, overflow) = byteCount.addingReportingOverflow(
            chunk.count
        )
        guard overflow == false, nextByteCount <= maximumByteCount else {
            throw CocoaError(.fileReadTooLarge)
        }
        data.append(chunk)
        byteCount = nextByteCount
    }
    return data
}

/// A cheap byte-level firewall before `JSONDecoder`. Codable validates decoded
/// fields, but Foundation may first allocate a complete scalar or deeply nested
/// container. Bounding encoded string tokens and nesting keeps a corrupted
/// derived cache from using the decoder itself as an allocation amplifier.
func assistantImageJSONHasBoundedStructure(_ data: Data) -> Bool {
    let maximumEncodedStringByteCount = 512 * 1_024
    let maximumNestingDepth = 16
    // Covers the admitted 4,096 record objects, 65,536 label entries,
    // completed-page IDs, and their keyed fields with generous overhead.
    let maximumStructuralTokenCount = 250_000
    let maximumUnquotedScalarByteCount = 256
    var isInsideString = false
    var isEscaped = false
    var encodedStringByteCount = 0
    var nestingDepth = 0
    var structuralTokenCount = 0
    var unquotedScalarByteCount = 0

    for byte in data {
        if isInsideString {
            if isEscaped {
                isEscaped = false
                encodedStringByteCount += 1
            } else if byte == 0x5C { // backslash
                isEscaped = true
                encodedStringByteCount += 1
            } else if byte == 0x22 { // quote
                isInsideString = false
            } else {
                encodedStringByteCount += 1
            }
            guard encodedStringByteCount <= maximumEncodedStringByteCount else {
                return false
            }
            continue
        }

        switch byte {
        case 0x22: // quote
            isInsideString = true
            isEscaped = false
            encodedStringByteCount = 0
            unquotedScalarByteCount = 0
        case 0x5B, 0x7B: // [ or {
            structuralTokenCount += 1
            guard structuralTokenCount <= maximumStructuralTokenCount else {
                return false
            }
            nestingDepth += 1
            unquotedScalarByteCount = 0
            guard nestingDepth <= maximumNestingDepth else { return false }
        case 0x5D, 0x7D: // ] or }
            structuralTokenCount += 1
            guard structuralTokenCount <= maximumStructuralTokenCount else {
                return false
            }
            guard nestingDepth > 0 else { return false }
            nestingDepth -= 1
            unquotedScalarByteCount = 0
        case 0x2C, 0x3A: // comma or colon
            structuralTokenCount += 1
            guard structuralTokenCount <= maximumStructuralTokenCount else {
                return false
            }
            unquotedScalarByteCount = 0
        case 0x09, 0x0A, 0x0D, 0x20: // JSON whitespace
            unquotedScalarByteCount = 0
        default:
            unquotedScalarByteCount += 1
            guard unquotedScalarByteCount <= maximumUnquotedScalarByteCount else {
                return false
            }
        }
    }
    return isInsideString == false && nestingDepth == 0
}

/// One immutable image discovered in a verified Canvas Core snapshot. The
/// image bytes never leave the process; only bounded derived text is persisted
/// in the local assistant cache and Core Spotlight index.
struct AssistantImageAsset: @unchecked Sendable {
    let stableID: String
    let pageID: UUID
    let pageNumber: Int
    let pageBounds: CGRect?
    let contentHash: String
    let image: CGImage
    let orientation: CGImagePropertyOrientation
}

enum AssistantImageAnalysisStage: String, Codable, Hashable, Sendable {
    case textRecognition
    case imageClassification
}

struct AssistantImageAnalysis: Equatable, Sendable {
    let recognizedText: String
    let visualLabels: [String]
    let semanticDescription: String?
    /// A successful Vision request may legitimately produce no text or labels.
    /// Keep that distinct from a provider error so decorative images can be
    /// cached once while transient failures remain restartable.
    let failedStages: Set<AssistantImageAnalysisStage>

    init(
        recognizedText: String,
        visualLabels: [String],
        semanticDescription: String?,
        failedStages: Set<AssistantImageAnalysisStage> = []
    ) {
        self.recognizedText = recognizedText
        self.visualLabels = visualLabels
        self.semanticDescription = semanticDescription
        self.failedStages = failedStages
    }
}

protocol AssistantImageAnalyzing: Sendable {
    func analyze(_ asset: AssistantImageAsset) async -> AssistantImageAnalysis

    /// Request-time enrichment must not reserve Foundation Models while the
    /// user's answer is waiting to use that same process-wide model lane.
    /// Production supplies a Vision-only implementation; test doubles and
    /// alternate analyzers inherit their normal deterministic analysis.
    func analyzeForForegroundRequest(
        _ asset: AssistantImageAsset
    ) async -> AssistantImageAnalysis
}

extension AssistantImageAnalyzing {
    func analyzeForForegroundRequest(
        _ asset: AssistantImageAsset
    ) async -> AssistantImageAnalysis {
        await analyze(asset)
    }
}

/// Interactive answers always win access to Foundation Models. A background
/// image caption is cancelled as soon as the user asks Notate a question; OCR
/// and deterministic retrieval remain independent of this gate.
actor OnDeviceModelWorkArbiter {
    static let shared = OnDeviceModelWorkArbiter()

    private var interactiveOwners = Set<UUID>()
    private var backgroundOwner: UUID?
    private var cancelBackground: (@Sendable () -> Void)?
    /// Once an interactive request has already proved that a cancelled
    /// background Foundation Models task will not drain within its handoff
    /// window, later requests fail over immediately instead of each paying the
    /// same two-second wait. The flag clears only when the raw task exits and
    /// releases its reservation.
    private var backgroundIsQuarantined = false

    func beginInteractive(
        _ id: UUID,
        waitForExistingInteractive waitDuration: Duration = .zero
    ) async -> Bool {
        // This process-wide gate is the final defense against two independent
        // provider instances creating concurrent SystemLanguageModel work.
        // Foreground generation may briefly wait for a cancelled predecessor
        // to really exit. Prewarm and token-counting callers keep the default
        // fail-fast behavior so speculative work never delays user work.
        let clock = ContinuousClock()
        let callerDeadline = clock.now.advanced(by: waitDuration)
        if interactiveOwners.isEmpty == false {
            guard waitDuration > .zero else { return false }
            while interactiveOwners.isEmpty == false {
                let now = clock.now
                guard now < callerDeadline else { return false }
                do {
                    try await clock.sleep(
                        until: min(
                            callerDeadline,
                            now.advanced(by: .milliseconds(20))
                        ),
                        tolerance: .zero
                    )
                } catch {
                    return false
                }
            }
        }
        interactiveOwners.insert(id)
        guard backgroundOwner != nil else { return true }

        guard backgroundIsQuarantined == false else {
            interactiveOwners.remove(id)
            return false
        }
        // The same caller-owned handoff budget covers both an interactive
        // predecessor and a cancelled background caption. Speculative prewarm
        // and token counting pass zero and therefore remain truly fail-fast.
        guard waitDuration > .zero else {
            interactiveOwners.remove(id)
            return false
        }
        guard clock.now < callerDeadline else {
            interactiveOwners.remove(id)
            return false
        }
        cancelBackground?()
        while backgroundOwner != nil {
            let now = clock.now
            guard now < callerDeadline else { break }
            do {
                try await clock.sleep(
                    until: min(
                        callerDeadline,
                        now.advanced(by: .milliseconds(20))
                    ),
                    tolerance: .zero
                )
            } catch {
                interactiveOwners.remove(id)
                return false
            }
        }
        guard backgroundOwner == nil else {
            // Do not pretend a cancelled Foundation Models session has drained.
            // Foreground callers fall back deterministically until release.
            backgroundIsQuarantined = true
            interactiveOwners.remove(id)
            return false
        }
        return true
    }

    func endInteractive(_ id: UUID) {
        interactiveOwners.remove(id)
    }

    func reserveBackground(
        _ id: UUID,
        cancellation: @escaping @Sendable () -> Void
    ) -> Bool {
        guard interactiveOwners.isEmpty, backgroundOwner == nil else { return false }
        backgroundOwner = id
        cancelBackground = cancellation
        backgroundIsQuarantined = false
        return true
    }

    func releaseBackground(_ id: UUID) {
        guard backgroundOwner == id else { return }
        backgroundOwner = nil
        cancelBackground = nil
        backgroundIsQuarantined = false
    }
}

/// Bounds cancellation-resistant render/Vision work by both notebook and
/// process. A timed-out request keeps its reservation until the raw task has
/// actually returned, so repeated prompts cannot accumulate retained images.
actor AssistantImageRawWorkArbiter {
    static let shared = AssistantImageRawWorkArbiter()

    private static let maximumConcurrentOwners = 2
    private var itemOwners: [UUID: UUID] = [:]
    private var owners = Set<UUID>()
    private var releaseWaiters: [UUID: [CheckedContinuation<Void, Never>]] = [:]

    func reserve(itemID: UUID, ownerID: UUID) -> Bool {
        guard itemOwners[itemID] == nil,
            owners.count < Self.maximumConcurrentOwners else {
            return false
        }
        itemOwners[itemID] = ownerID
        owners.insert(ownerID)
        return true
    }

    func release(itemID: UUID, ownerID: UUID) {
        guard itemOwners[itemID] == ownerID else { return }
        itemOwners.removeValue(forKey: itemID)
        owners.remove(ownerID)
        let waiters = releaseWaiters.removeValue(forKey: itemID) ?? []
        for waiter in waiters { waiter.resume() }
    }

    /// Waits for cancellation-resistant provider work for one notebook to
    /// physically return. Callers single-flight these waits per notebook; the
    /// arbiter caps the retained provider work itself process-wide.
    func waitUntilReleased(itemID: UUID) async {
        guard itemOwners[itemID] != nil else { return }
        await withCheckedContinuation { continuation in
            releaseWaiters[itemID, default: []].append(continuation)
        }
    }
}

private final class BackgroundModelTaskHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<String?, Never>?
    private var wasCancelled = false

    func install(_ task: Task<String?, Never>) {
        lock.lock()
        if wasCancelled {
            lock.unlock()
            task.cancel()
        } else {
            self.task = task
            lock.unlock()
        }
    }

    func cancel() {
        lock.lock()
        wasCancelled = true
        let task = task
        lock.unlock()
        task?.cancel()
    }
}

/// Vision supplies deterministic OCR and image labels on every supported
/// device. On iOS 27, Foundation Models may add one short semantic caption when
/// the device is cool, not in Low Power Mode, and no interactive answer needs
/// the model. Failure in that optional tier never discards the Vision result.
actor OnDeviceAssistantImageAnalyzer: AssistantImageAnalyzing {
    private let languageModel = SystemLanguageModel(useCase: .contentTagging)

    private enum StageResult<Value: Sendable>: Sendable {
        case success(Value)
        case failure

        var value: Value? {
            guard case let .success(value) = self else { return nil }
            return value
        }
    }

    func analyze(_ asset: AssistantImageAsset) async -> AssistantImageAnalysis {
        guard !Task.isCancelled else {
            return AssistantImageAnalysis(
                recognizedText: "",
                visualLabels: [],
                semanticDescription: nil,
                failedStages: [.textRecognition, .imageClassification]
            )
        }

        let textResult = await recognizeText(in: asset)
        let recognizedText = textResult.value ?? ""
        guard !Task.isCancelled else {
            var failedStages: Set<AssistantImageAnalysisStage> = [
                .imageClassification,
            ]
            if case .failure = textResult {
                failedStages.insert(.textRecognition)
            }
            return AssistantImageAnalysis(
                recognizedText: recognizedText,
                visualLabels: [],
                semanticDescription: nil,
                failedStages: failedStages
            )
        }
        let classificationResult = await classify(asset)
        let visualLabels = classificationResult.value ?? []
        var failedStages = Set<AssistantImageAnalysisStage>()
        if case .failure = textResult {
            failedStages.insert(.textRecognition)
        }
        if case .failure = classificationResult {
            failedStages.insert(.imageClassification)
        }
        let semanticDescription = await describeIfResourcesPermit(
            asset,
            recognizedText: recognizedText,
            visualLabels: visualLabels
        )
        return AssistantImageAnalysis(
            recognizedText: recognizedText,
            visualLabels: visualLabels,
            semanticDescription: semanticDescription,
            failedStages: failedStages
        )
    }

    func analyzeForForegroundRequest(
        _ asset: AssistantImageAsset
    ) async -> AssistantImageAnalysis {
        guard !Task.isCancelled else {
            return AssistantImageAnalysis(
                recognizedText: "",
                visualLabels: [],
                semanticDescription: nil,
                failedStages: [.textRecognition, .imageClassification]
            )
        }
        let textResult = await recognizeText(in: asset)
        let recognizedText = textResult.value ?? ""
        guard !Task.isCancelled else {
            var failedStages: Set<AssistantImageAnalysisStage> = [
                .imageClassification,
            ]
            if case .failure = textResult {
                failedStages.insert(.textRecognition)
            }
            return AssistantImageAnalysis(
                recognizedText: recognizedText,
                visualLabels: [],
                semanticDescription: nil,
                failedStages: failedStages
            )
        }
        let classificationResult = await classify(asset)
        var failedStages = Set<AssistantImageAnalysisStage>()
        if case .failure = textResult {
            failedStages.insert(.textRecognition)
        }
        if case .failure = classificationResult {
            failedStages.insert(.imageClassification)
        }
        return AssistantImageAnalysis(
            recognizedText: recognizedText,
            visualLabels: classificationResult.value ?? [],
            semanticDescription: nil,
            failedStages: failedStages
        )
    }

    private func recognizeText(
        in asset: AssistantImageAsset
    ) async -> StageResult<String> {
        do {
            var request = RecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.automaticallyDetectsLanguage = true
            request.usesLanguageCorrection = true
            request.minimumTextHeightFraction = 0.012
            let observations = try await request.perform(
                on: asset.image,
                orientation: asset.orientation
            )
            try Task.checkCancellation()
            var recognizedText = ""
            var remainingBytes = 12_000
            var acceptedObservationCount = 0
            for observation in observations {
                try Task.checkCancellation()
                guard observation.confidence >= 0.22 else { continue }
                guard acceptedObservationCount < 160 else { break }
                let separatorByteCount = recognizedText.isEmpty ? 0 : 1
                guard separatorByteCount < remainingBytes else { break }
                let text = observation.transcript
                    .assistantImageBounded(
                        maximumUTF8Bytes: remainingBytes - separatorByteCount
                    )
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.isEmpty == false else { continue }
                let textByteCount = text.utf8.count
                guard textByteCount <= remainingBytes - separatorByteCount else {
                    break
                }
                if separatorByteCount == 1 { recognizedText.append("\n") }
                recognizedText.append(contentsOf: text)
                remainingBytes -= separatorByteCount + textByteCount
                acceptedObservationCount += 1
                if remainingBytes == 0 { break }
            }
            return .success(recognizedText)
        } catch {
            return .failure
        }
    }

    private func classify(
        _ asset: AssistantImageAsset
    ) async -> StageResult<[String]> {
        do {
            var request = ClassifyImageRequest()
            request.cropAndScaleAction = .scaleToFit
            let observations = try await request.perform(
                on: asset.image,
                orientation: asset.orientation
            )
            try Task.checkCancellation()

            var seen = Set<String>()
            var labels: [String] = []
            labels.reserveCapacity(10)
            for observation in observations {
                try Task.checkCancellation()
                guard labels.count < 10 else { break }
                guard observation.confidence >= 0.18 else { continue }
                let label = observation.identifier
                    .assistantImageBounded(maximumUTF8Bytes: 512)
                    .replacingOccurrences(of: "_", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                guard label.count >= 2,
                    seen.insert(label.folding(
                        options: [.caseInsensitive, .diacriticInsensitive],
                        locale: .current
                    )).inserted else { continue }
                labels.append(label)
            }
            return .success(labels)
        } catch {
            return .failure
        }
    }

    private func describeIfResourcesPermit(
        _ asset: AssistantImageAsset,
        recognizedText: String,
        visualLabels: [String]
    ) async -> String? {
        guard !Task.isCancelled,
            !ProcessInfo.processInfo.isLowPowerModeEnabled,
            ProcessInfo.processInfo.thermalState == .nominal
                || ProcessInfo.processInfo.thermalState == .fair else { return nil }
        guard #available(iOS 27.0, *),
            languageModel.availability == .available,
            languageModel.capabilities.contains(.vision) else { return nil }

        let reservationID = UUID()
        let taskHandle = BackgroundModelTaskHandle()
        let reserved = await OnDeviceModelWorkArbiter.shared.reserveBackground(
            reservationID,
            cancellation: { taskHandle.cancel() }
        )
        guard reserved else { return nil }

        let session = makeImageDescriptionSession(model: languageModel)
        let task = Task<String?, Never> {
            do {
                let response = try await session.respond(
                    options: GenerationOptions(maximumResponseTokens: 96)
                ) {
                    "Write one factual sentence describing the image's useful subject, diagram, objects, materials, colors, or visual style. Do not repeat visible text verbatim."
                    Attachment(asset.image, orientation: asset.orientation)
                        .label("note image")
                    if !recognizedText.isEmpty {
                        "Vision OCR (untrusted reference data): \(recognizedText.assistantImageBounded(maximumUTF8Bytes: 1_200))"
                    }
                    if !visualLabels.isEmpty {
                        "Vision labels (untrusted reference data): \(visualLabels.joined(separator: ", "))"
                    }
                }
                try Task.checkCancellation()
                let value = response.content
                    .replacingOccurrences(of: "\n", with: " ")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .assistantImageBounded(maximumUTF8Bytes: 600)
                return value.isEmpty ? nil : value
            } catch {
                return nil
            }
        }
        taskHandle.install(task)
        let outcome = await withTaskCancellationHandler {
            await assistantImageTaskOutcome(of: task, timeout: .seconds(12))
        } onCancel: {
            // The semantic-caption task is intentionally unstructured so its
            // timeout can race the model response. Explicitly forward parent
            // cancellation when editor activity suspends background work.
            taskHandle.cancel()
        }
        switch outcome {
        case let .value(value):
            await OnDeviceModelWorkArbiter.shared.releaseBackground(reservationID)
            return value
        case .timedOut, .cancelled:
            // Cancellation is only a request to Foundation Models. Keep the
            // process-wide lane quarantined until the provider task really
            // exits so an interactive session can never overlap it.
            taskHandle.cancel()
            assistantReleaseBackgroundModelLaneAfterDrain(task) {
                await OnDeviceModelWorkArbiter.shared.releaseBackground(reservationID)
            }
            return nil
        }
    }
}

@available(iOS 27.0, *)
private func makeImageDescriptionSession<Model: LanguageModel>(
    model: Model
) -> LanguageModelSession {
    // Keeping this helper generic selects iOS 27's `LanguageModel` overload
    // unambiguously; `SystemLanguageModel` also has the legacy iOS 26
    // initializer with an otherwise identical builder signature.
    LanguageModelSession(
        model: model,
        instructions: Instructions(
            "Describe note images for private, on-device search. Be literal, concise, and do not speculate."
        )
    )
}
struct AssistantImageEnrichmentRecord: Codable, Equatable, Sendable {
    private static let maximumIdentityUTF8ByteCount = 4 * 1_024
    private static let maximumRecognizedTextUTF8ByteCount = 64 * 1_024
    private static let maximumSemanticTextUTF8ByteCount = 16 * 1_024
    private static let maximumVisualLabelCount = 256
    private static let maximumVisualLabelUTF8ByteCount = 64 * 1_024

    private enum CodingKeys: String, CodingKey {
        case stableID
        case contentHash
        case pageID
        case pageNumber
        case pageBounds
        case recognizedText
        case visualLabels
        case semanticDescription
        case pendingStages
    }

    let stableID: String
    let contentHash: String
    let pageID: UUID
    let pageNumber: Int
    let pageBounds: CGRect?
    let recognizedText: String
    let visualLabels: [String]
    let semanticDescription: String?
    /// Stages that have not yet produced a trustworthy result for this exact
    /// content hash. Empty successful results deliberately have no pending
    /// stages and are therefore efficient cache hits.
    let pendingStages: Set<AssistantImageAnalysisStage>

    init(
        stableID: String,
        contentHash: String,
        pageID: UUID,
        pageNumber: Int,
        pageBounds: CGRect?,
        recognizedText: String,
        visualLabels: [String],
        semanticDescription: String?,
        pendingStages: Set<AssistantImageAnalysisStage> = []
    ) {
        self.stableID = stableID
        self.contentHash = contentHash
        self.pageID = pageID
        self.pageNumber = pageNumber
        self.pageBounds = pageBounds
        self.recognizedText = recognizedText
        self.visualLabels = visualLabels
        self.semanticDescription = semanticDescription
        self.pendingStages = pendingStages
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let stableID = try container.decode(String.self, forKey: .stableID)
        guard stableID.utf8.count <= Self.maximumIdentityUTF8ByteCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .stableID,
                in: container,
                debugDescription: "Image-enrichment identity exceeds its byte limit."
            )
        }
        let contentHash = try container.decode(String.self, forKey: .contentHash)
        guard contentHash.utf8.count <= Self.maximumIdentityUTF8ByteCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .contentHash,
                in: container,
                debugDescription: "Image-enrichment hash exceeds its byte limit."
            )
        }
        let recognizedText = try container.decode(
            String.self,
            forKey: .recognizedText
        )
        guard recognizedText.utf8.count
            <= Self.maximumRecognizedTextUTF8ByteCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .recognizedText,
                in: container,
                debugDescription: "Recognized image text exceeds its byte limit."
            )
        }
        let semanticDescription = try container.decodeIfPresent(
            String.self,
            forKey: .semanticDescription
        )
        guard (semanticDescription?.utf8.count ?? 0)
            <= Self.maximumSemanticTextUTF8ByteCount else {
            throw DecodingError.dataCorruptedError(
                forKey: .semanticDescription,
                in: container,
                debugDescription: "Image description exceeds its byte limit."
            )
        }

        var labelContainer = try container.nestedUnkeyedContainer(
            forKey: .visualLabels
        )
        if let count = labelContainer.count,
            count > Self.maximumVisualLabelCount {
            throw DecodingError.dataCorrupted(.init(
                codingPath: labelContainer.codingPath,
                debugDescription: "Too many visual-label entries."
            ))
        }
        var visualLabels: [String] = []
        visualLabels.reserveCapacity(
            min(labelContainer.count ?? 0, Self.maximumVisualLabelCount)
        )
        var remainingLabelBytes = Self.maximumVisualLabelUTF8ByteCount
        while labelContainer.isAtEnd == false {
            guard visualLabels.count < Self.maximumVisualLabelCount else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: labelContainer.codingPath,
                    debugDescription: "Too many visual-label entries."
                ))
            }
            let label = try labelContainer.decode(String.self)
            let byteCount = label.utf8.count
            guard byteCount <= remainingLabelBytes else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: labelContainer.codingPath,
                    debugDescription: "Visual labels exceed their byte limit."
                ))
            }
            remainingLabelBytes -= byteCount
            visualLabels.append(label)
        }

        var stageContainer = try container.nestedUnkeyedContainer(
            forKey: .pendingStages
        )
        if let count = stageContainer.count, count > 2 {
            throw DecodingError.dataCorrupted(.init(
                codingPath: stageContainer.codingPath,
                debugDescription: "Too many pending image-analysis stages."
            ))
        }
        var pendingStages = Set<AssistantImageAnalysisStage>()
        var decodedStageCount = 0
        while stageContainer.isAtEnd == false {
            guard decodedStageCount < 2 else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: stageContainer.codingPath,
                    debugDescription: "Too many pending image-analysis stages."
                ))
            }
            decodedStageCount += 1
            pendingStages.insert(
                try stageContainer.decode(AssistantImageAnalysisStage.self)
            )
        }

        self.stableID = stableID
        self.contentHash = contentHash
        pageID = try container.decode(UUID.self, forKey: .pageID)
        pageNumber = try container.decode(Int.self, forKey: .pageNumber)
        pageBounds = try container.decodeIfPresent(CGRect.self, forKey: .pageBounds)
        self.recognizedText = recognizedText
        self.visualLabels = visualLabels
        self.semanticDescription = semanticDescription
        self.pendingStages = pendingStages
    }

    var isAnalysisComplete: Bool { pendingStages.isEmpty }

    var persistenceUTF8ByteCount: Int? {
        guard stableID.utf8.count <= Self.maximumIdentityUTF8ByteCount,
            contentHash.utf8.count <= Self.maximumIdentityUTF8ByteCount,
            recognizedText.utf8.count
                <= Self.maximumRecognizedTextUTF8ByteCount,
            (semanticDescription?.utf8.count ?? 0)
                <= Self.maximumSemanticTextUTF8ByteCount,
            visualLabels.count <= Self.maximumVisualLabelCount else {
            return nil
        }
        var total = 0
        func add(_ byteCount: Int) -> Bool {
            let (next, overflow) = total.addingReportingOverflow(byteCount)
            guard overflow == false else { return false }
            total = next
            return true
        }
        guard add(stableID.utf8.count),
            add(contentHash.utf8.count),
            add(recognizedText.utf8.count),
            add(semanticDescription?.utf8.count ?? 0) else {
            return nil
        }
        var remainingLabelBytes = Self.maximumVisualLabelUTF8ByteCount
        for label in visualLabels {
            let byteCount = label.utf8.count
            guard byteCount <= remainingLabelBytes,
                add(byteCount) else { return nil }
            remainingLabelBytes -= byteCount
        }
        return total
    }

    var isWithinPersistenceBounds: Bool {
        persistenceUTF8ByteCount != nil
    }

    var searchableText: String {
        searchableText(maximumUTF8Bytes: .max) ?? ""
    }

    /// Builds the derived search projection incrementally and stops before
    /// joining attacker-controlled legacy cache fields into a large transient
    /// string. `nil` means this record cannot fit the caller's remaining
    /// aggregate budget.
    func searchableText(maximumUTF8Bytes: Int) -> String? {
        guard maximumUTF8Bytes >= 0 else { return nil }
        var result = ""
        var remainingBytes = maximumUTF8Bytes

        func appendSection(prefix: String, body: String) -> Bool {
            let separatorBytes = result.isEmpty ? 0 : 1
            let prefixBytes = prefix.utf8.count
            let bodyBytes = body.utf8.count
            guard separatorBytes <= remainingBytes,
                prefixBytes <= remainingBytes - separatorBytes,
                bodyBytes <= remainingBytes - separatorBytes - prefixBytes
            else { return false }
            if separatorBytes == 1 { result.append("\n") }
            result.append(contentsOf: prefix)
            result.append(contentsOf: body)
            remainingBytes -= separatorBytes + prefixBytes + bodyBytes
            return true
        }

        if let semanticDescription,
            semanticDescription.contains(where: { $0.isWhitespace == false }),
            appendSection(
                prefix: "Image description: ",
                body: semanticDescription
            ) == false {
            return nil
        }
        if !recognizedText.isEmpty,
            appendSection(
                prefix: "Text visible in image:\n",
                body: recognizedText
            ) == false {
            return nil
        }
        if !visualLabels.isEmpty {
            let separatorBytes = result.isEmpty ? 0 : 1
            let prefix = "Visual subjects: "
            let prefixBytes = prefix.utf8.count
            guard separatorBytes <= remainingBytes,
                prefixBytes <= remainingBytes - separatorBytes else {
                return nil
            }
            if separatorBytes == 1 { result.append("\n") }
            result.append(contentsOf: prefix)
            remainingBytes -= separatorBytes + prefixBytes
            for (index, label) in visualLabels.enumerated() {
                let delimiter = index == 0 ? "" : ", "
                let delimiterBytes = delimiter.utf8.count
                let labelBytes = label.utf8.count
                guard delimiterBytes <= remainingBytes,
                    labelBytes <= remainingBytes - delimiterBytes else {
                    return nil
                }
                result.append(contentsOf: delimiter)
                result.append(contentsOf: label)
                remainingBytes -= delimiterBytes + labelBytes
            }
        }
        return result
    }

    func relocated(to asset: AssistantImageAsset) -> AssistantImageEnrichmentRecord {
        AssistantImageEnrichmentRecord(
            stableID: asset.stableID,
            contentHash: asset.contentHash,
            pageID: asset.pageID,
            pageNumber: asset.pageNumber,
            pageBounds: asset.pageBounds,
            recognizedText: recognizedText,
            visualLabels: visualLabels,
            semanticDescription: semanticDescription,
            pendingStages: pendingStages
        )
    }
}

private struct AssistantImageEnrichmentEnvelope: Codable, Sendable {
    /// Version 2 could not distinguish a successful empty Vision result from a
    /// provider failure and may therefore contain poisoned empty records.
    /// Version 3 persists pending stages and forces those older records through
    /// one safe rebuild. Version 1 additionally lacked page-membership proof.
    static let currentSchemaVersion = 3

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generation
        case isComplete
        case completedPageIDs
        case records
    }

    let schemaVersion: Int
    /// The verified Canvas generation for which this complete record set was
    /// produced. Optional keeps schema-1 caches readable for analysis reuse,
    /// while exact index replay requires a newly written generation value.
    let generation: Int64?
    /// Incremental checkpoints intentionally retain unvisited old records and
    /// are analysis-reuse only. Only a completed visit may be reconstructed as
    /// exact searchable evidence after a restart.
    let isComplete: Bool?
    /// Same-generation pages whose complete visual asset set reached the
    /// durable checkpoint. This optional schema-3 addition keeps caches written
    /// by earlier builds readable while allowing a cancelled foreground pass
    /// to resume after the last whole page it finished.
    let completedPageIDs: Set<UUID>?
    let records: [AssistantImageEnrichmentRecord]

    init(
        records: [AssistantImageEnrichmentRecord],
        generation: Int64?,
        isComplete: Bool,
        completedPageIDs: Set<UUID> = []
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.generation = generation.map { max($0, 0) }
        self.isComplete = isComplete
        self.completedPageIDs = completedPageIDs
        self.records = records
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let schemaVersion = try container.decode(Int.self, forKey: .schemaVersion)
        guard schemaVersion == Self.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "Unsupported image-enrichment cache schema."
            )
        }

        let completedPageIDs: Set<UUID>?
        if container.contains(.completedPageIDs) {
            if try container.decodeNil(forKey: .completedPageIDs) {
                completedPageIDs = nil
            } else {
                var pageContainer = try container.nestedUnkeyedContainer(
                    forKey: .completedPageIDs
                )
                if let count = pageContainer.count,
                    count > AssistantImageEnrichmentStore.maximumCompletedPageIDCount {
                    throw DecodingError.dataCorrupted(.init(
                        codingPath: pageContainer.codingPath,
                        debugDescription: "Too many completed-page entries."
                    ))
                }
                var decodedPageIDs = Set<UUID>()
                decodedPageIDs.reserveCapacity(
                    min(
                        pageContainer.count ?? 0,
                        AssistantImageEnrichmentStore.maximumCompletedPageIDCount
                    )
                )
                var decodedPageCount = 0
                while pageContainer.isAtEnd == false {
                    guard decodedPageCount
                        < AssistantImageEnrichmentStore.maximumCompletedPageIDCount else {
                        throw DecodingError.dataCorrupted(.init(
                            codingPath: pageContainer.codingPath,
                            debugDescription: "Too many completed-page entries."
                        ))
                    }
                    decodedPageCount += 1
                    decodedPageIDs.insert(try pageContainer.decode(UUID.self))
                }
                completedPageIDs = decodedPageIDs
            }
        } else {
            completedPageIDs = nil
        }

        var recordContainer = try container.nestedUnkeyedContainer(
            forKey: .records
        )
        if let count = recordContainer.count,
            count > AssistantImageEnrichmentStore.maximumRecordCount {
            throw DecodingError.dataCorrupted(.init(
                codingPath: recordContainer.codingPath,
                debugDescription: "Too many image-enrichment records."
            ))
        }
        var records: [AssistantImageEnrichmentRecord] = []
        records.reserveCapacity(
            min(
                recordContainer.count ?? 0,
                AssistantImageEnrichmentStore.maximumRecordCount
            )
        )
        var remainingTextBytes =
            AssistantImageEnrichmentStore.maximumAggregateRecordTextUTF8ByteCount
        var visualLabelCount = 0
        while recordContainer.isAtEnd == false {
            guard records.count < AssistantImageEnrichmentStore.maximumRecordCount else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: recordContainer.codingPath,
                    debugDescription: "Too many image-enrichment records."
                ))
            }
            let record = try recordContainer.decode(
                AssistantImageEnrichmentRecord.self
            )
            guard let byteCount = record.persistenceUTF8ByteCount,
                byteCount <= remainingTextBytes else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: recordContainer.codingPath,
                    debugDescription: "Image-enrichment text exceeds its aggregate limit."
                ))
            }
            remainingTextBytes -= byteCount
            let (nextLabelCount, labelOverflow) = visualLabelCount
                .addingReportingOverflow(record.visualLabels.count)
            guard labelOverflow == false,
                nextLabelCount
                <= AssistantImageEnrichmentStore.maximumAggregateVisualLabelCount else {
                throw DecodingError.dataCorrupted(.init(
                    codingPath: recordContainer.codingPath,
                    debugDescription: "Too many aggregate visual-label entries."
                ))
            }
            visualLabelCount = nextLabelCount
            records.append(record)
        }

        self.schemaVersion = schemaVersion
        generation = try container.decodeIfPresent(Int64.self, forKey: .generation)
        isComplete = try container.decodeIfPresent(Bool.self, forKey: .isComplete)
        self.completedPageIDs = completedPageIDs
        self.records = records
    }
}

struct AssistantImageEnrichmentCacheState: Sendable {
    let generation: Int64?
    let isComplete: Bool
    let completedPageIDs: Set<UUID>
    let records: [AssistantImageEnrichmentRecord]
}

enum AssistantImageEnrichmentStore {
    struct PersistenceBudget: Sendable {
        var remainingRecordCount: Int
        var remainingTextUTF8ByteCount: Int
        var remainingVisualLabelCount: Int
    }

    private static let filename = ".assistant-image-index-v1.json"
    private static let quarantinedFilename = ".assistant-image-index-v1.rejected"
    private static let pendingFilename = ".assistant-image-index-pending-v1"
    private static let pendingDefaultsPrefix = "notate.assistant.image-pending.v1."
    // This cache is derived and rebuildable. Keep its encoded and raw ceilings
    // low enough that one hostile JSON string or worst-case escaping cannot
    // create a device-scale transient allocation during decode/encode.
    static let maximumEncodedByteCount = 16 * 1_024 * 1_024
    static let maximumRecordCount = 4_096
    static let maximumCompletedPageIDCount = 4_096
    static let maximumAggregateRecordTextUTF8ByteCount = 2 * 1_024 * 1_024
    static let maximumAggregateVisualLabelCount = 65_536
    private static let maximumPendingMarkerByteCount = 64
    /// Cache and breadcrumb mutations can originate from the index actor and
    /// from a detached Vision worker. One process-wide critical section keeps
    /// conditional clears/removals linearizable across both durable surfaces.
    private static let mutationLock = NSLock()

    private static func withMutationLock<T>(_ body: () throws -> T) rethrows -> T {
        mutationLock.lock()
        defer { mutationLock.unlock() }
        return try body()
    }

    static func cacheURL(for item: AssistantIndexedItem) -> URL {
        item.canvasDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    static func quarantinedCacheURL(for item: AssistantIndexedItem) -> URL {
        item.canvasDirectory.appendingPathComponent(
            quarantinedFilename,
            isDirectory: false
        )
    }

    private static func pendingURL(for item: AssistantIndexedItem) -> URL {
        item.canvasDirectory.appendingPathComponent(pendingFilename, isDirectory: false)
    }

    private static func pendingDefaultsKey(for item: AssistantIndexedItem) -> String {
        pendingDefaultsPrefix + item.itemID.uuidString.lowercased()
    }

    static func hasCache(for item: AssistantIndexedItem) -> Bool {
        withMutationLock {
            FileManager.default.fileExists(atPath: cacheURL(for: item).path)
        }
    }

    /// A physical cache can predate the current failure-aware schema (or be
    /// unreadable after an interrupted write) even when no restart breadcrumb
    /// survived. Treat that file itself as durable repair intent so a current
    /// text manifest cannot strand poisoned empty Vision evidence forever.
    static func requiresRebuild(for item: AssistantIndexedItem) -> Bool {
        withMutationLock {
            let url = cacheURL(for: item)
            if FileManager.default.fileExists(atPath: url.path) {
                return loadEnvelopeUnlocked(for: item) == nil
            }
            return FileManager.default.fileExists(
                atPath: quarantinedCacheURL(for: item).path
            )
        }
    }

    static func pendingGeneration(for item: AssistantIndexedItem) -> Int64? {
        withMutationLock { pendingGenerationUnlocked(for: item) }
    }

    private static func pendingGenerationUnlocked(
        for item: AssistantIndexedItem
    ) -> Int64? {
        let fileGeneration: Int64? = {
            guard let data = try? assistantReadBoundedData(
                at: pendingURL(for: item),
                maximumByteCount: maximumPendingMarkerByteCount
            ),
                let value = String(data: data, encoding: .utf8),
                let generation = Int64(value) else { return nil }
            return max(generation, 0)
        }()
        let defaults = UserDefaults.standard
        let defaultsKey = pendingDefaultsKey(for: item)
        let defaultsGeneration = defaults.object(forKey: defaultsKey) == nil
            ? nil
            : max(Int64(defaults.integer(forKey: defaultsKey)), 0)
        return [fileGeneration, defaultsGeneration].compactMap { $0 }.max()
    }

    /// A tiny durable breadcrumb makes enrichment restartable after suspension
    /// or process termination. It is written only after the verified text
    /// generation commits and is removed only after the derived generation is
    /// also committed.
    @discardableResult
    static func markPending(
        generation: Int64,
        for item: AssistantIndexedItem
    ) -> Bool {
        withMutationLock {
            guard FileManager.default.fileExists(atPath: item.canvasDirectory.path) else {
                return false
            }
            let generation = max(generation, 0)
            // Never let a late writer regress a breadcrumb for a newer verified
            // snapshot. The comparison and both writes share the same lock as
            // conditional clearing, so an older completion cannot erase a
            // newer generation between its read and unlink.
            if let current = pendingGenerationUnlocked(for: item),
                current >= generation {
                return true
            }
            let data = Data(String(generation).utf8)
            let fileWriteSucceeded: Bool
            do {
                try data.write(
                    to: pendingURL(for: item),
                    options: [.atomic, .completeFileProtection]
                )
                fileWriteSucceeded = true
            } catch {
                fileWriteSucceeded = false
            }
            // File protection or a transient volume error must not make a current
            // text manifest permanently suppress restartable Vision work. Keep a
            // second tiny generation-only breadcrumb in preferences; no note text
            // or image-derived content is stored here.
            let defaults = UserDefaults.standard
            let defaultsKey = pendingDefaultsKey(for: item)
            defaults.set(generation, forKey: defaultsKey)
            let defaultsWriteSucceeded = defaults.synchronize()
                && defaults.integer(forKey: defaultsKey) == generation
            return fileWriteSucceeded || defaultsWriteSucceeded
        }
    }

    static func clearPending(
        generation: Int64? = nil,
        for item: AssistantIndexedItem
    ) {
        withMutationLock {
            if let generation,
                pendingGenerationUnlocked(for: item) != max(generation, 0) { return }
            removePendingUnlocked(for: item)
        }
    }

    static func load(for item: AssistantIndexedItem) -> [AssistantImageEnrichmentRecord] {
        withMutationLock { loadEnvelopeUnlocked(for: item)?.records ?? [] }
    }

    static func loadState(
        for item: AssistantIndexedItem
    ) -> AssistantImageEnrichmentCacheState? {
        withMutationLock {
            guard let envelope = loadEnvelopeUnlocked(for: item) else {
                return nil
            }
            return AssistantImageEnrichmentCacheState(
                generation: envelope.generation,
                isComplete: envelope.isComplete == true,
                completedPageIDs: envelope.completedPageIDs ?? [],
                records: envelope.records
            )
        }
    }

    /// Only a current-schema complete cache explicitly stamped with this
    /// verified generation may participate in the authoritative fingerprint.
    /// Pre-v2 caches are rejected because their page-membership completeness
    /// cannot be proven after deletions.
    static func load(
        for item: AssistantIndexedItem,
        generation: Int64
    ) -> [AssistantImageEnrichmentRecord] {
        withMutationLock {
            guard let envelope = loadEnvelopeUnlocked(for: item),
                envelope.generation == max(generation, 0),
                envelope.isComplete == true,
                envelope.records.allSatisfy(\.isAnalysisComplete) else {
                return []
            }
            return envelope.records
        }
    }

    @discardableResult
    static func replace(
        _ proposedRecords: [AssistantImageEnrichmentRecord],
        generation: Int64? = nil,
        isComplete: Bool = true,
        completedPageIDs proposedCompletedPageIDs: Set<UUID> = [],
        for item: AssistantIndexedItem
    ) -> Bool {
        withMutationLock {
            guard proposedRecords.count <= maximumRecordCount,
                proposedCompletedPageIDs.count
                <= maximumCompletedPageIDCount else {
                return false
            }
            let url = cacheURL(for: item)
            let generation = generation.map { max($0, 0) }
            var records = proposedRecords
            var completedPageIDs = proposedCompletedPageIDs
            // Never certify an exact-generation replay while any Vision stage
            // still needs a retry, even if a caller accidentally requests a
            // complete envelope. Partial successful evidence remains reusable.
            let isComplete = isComplete
                && records.allSatisfy(\.isAnalysisComplete)
            if let generation {
                // A cancellation-resistant worker may reach this critical
                // section after a newer verified save has already queued or
                // persisted its own OCR. The cache and breadcrumb share this
                // lock, so reject the stale writer before it can overwrite-or
                // delete-the newer generation.
                let durableGeneration = loadEnvelopeUnlocked(for: item)?.generation
                let newestGeneration = [
                    pendingGenerationUnlocked(for: item),
                    durableGeneration,
                ].compactMap { $0 }.max()
                guard newestGeneration.map({ $0 <= generation }) ?? true else {
                    return false
                }
                if let existing = loadEnvelopeUnlocked(for: item),
                    existing.generation == generation,
                    existing.isComplete == true,
                    isComplete == false {
                    // Checkpoints are monotonic too: a late partial pass must
                    // not downgrade a complete cache for the same snapshot.
                    return false
                }
                if isComplete == false,
                    let existing = loadEnvelopeUnlocked(for: item),
                    existing.generation == generation,
                    existing.isComplete != true {
                    // Equal-generation foreground requests may overlap. Each
                    // incoming completed page is authoritative for that page,
                    // while pages completed only by the other request must not
                    // be lost by a stale whole-envelope rewrite.
                    let existingCompleted = existing.completedPageIDs ?? []
                    let preservedExistingPages = existingCompleted.subtracting(
                        completedPageIDs
                    )
                    records.removeAll {
                        preservedExistingPages.contains($0.pageID)
                    }
                    records.append(contentsOf: existing.records.filter {
                        preservedExistingPages.contains($0.pageID)
                    })
                    completedPageIDs.formUnion(existingCompleted)
                }
            }
            guard records.count <= maximumRecordCount,
                completedPageIDs.count <= maximumCompletedPageIDCount else {
                return false
            }
            guard records.allSatisfy(\.isWithinPersistenceBounds) else {
                return false
            }
            records = deduplicated(records)
            guard isWithinAggregatePersistenceBounds(
                records,
                completedPageIDs: completedPageIDs
            ) else { return false }
            // A completed-page frontier is meaningful even when every visual
            // record on those pages was outside the derived-cache budget. Keep
            // that empty envelope so reopen/resume does not retry the same
            // permanently inadmissible assets forever. A truly empty cache has
            // no frontier to preserve and can still be removed.
            guard !records.isEmpty || !completedPageIDs.isEmpty else {
                do {
                    for candidate in [url, quarantinedCacheURL(for: item)]
                        where FileManager.default.fileExists(atPath: candidate.path) {
                        try FileManager.default.removeItem(at: candidate)
                    }
                    return FileManager.default.fileExists(atPath: url.path) == false
                        && FileManager.default.fileExists(
                            atPath: quarantinedCacheURL(for: item).path
                        ) == false
                } catch {
                    return false
                }
            }
            guard FileManager.default.fileExists(atPath: item.canvasDirectory.path),
                let data = try? JSONEncoder().encode(
                    AssistantImageEnrichmentEnvelope(
                        records: records,
                        generation: generation,
                        isComplete: isComplete,
                        completedPageIDs: completedPageIDs
                    )
                ),
                data.count <= maximumEncodedByteCount else { return false }
            do {
                try data.write(to: url, options: [.atomic, .completeFileProtection])
                try? FileManager.default.removeItem(at: quarantinedCacheURL(for: item))
                return true
            } catch {
                return false
            }
        }
    }

    private static func deduplicated(
        _ records: [AssistantImageEnrichmentRecord]
    ) -> [AssistantImageEnrichmentRecord] {
        var byStableID: [String: AssistantImageEnrichmentRecord] = [:]
        byStableID.reserveCapacity(records.count)
        for record in records {
            byStableID[record.stableID] = record
        }
        return byStableID.values.sorted {
            if $0.pageNumber != $1.pageNumber {
                return $0.pageNumber < $1.pageNumber
            }
            return $0.stableID < $1.stableID
        }
    }

    private static func isWithinAggregatePersistenceBounds(
        _ records: [AssistantImageEnrichmentRecord],
        completedPageIDs: Set<UUID>
    ) -> Bool {
        guard records.count <= maximumRecordCount,
            completedPageIDs.count <= maximumCompletedPageIDCount else {
            return false
        }
        return remainingPersistenceBudget(after: records) != nil
    }

    /// Returns the notebook-wide capacity left after retaining an already
    /// admitted record set. Page workers consume this exact remainder instead
    /// of each assuming that the entire cache budget is still available.
    static func remainingPersistenceBudget(
        after records: [AssistantImageEnrichmentRecord]
    ) -> PersistenceBudget? {
        guard records.count <= maximumRecordCount else { return nil }
        var remainingTextBytes = maximumAggregateRecordTextUTF8ByteCount
        var remainingVisualLabelCount = maximumAggregateVisualLabelCount
        for record in records {
            guard let byteCount = record.persistenceUTF8ByteCount,
                byteCount <= remainingTextBytes else { return nil }
            remainingTextBytes -= byteCount
            guard record.visualLabels.count <= remainingVisualLabelCount else {
                return nil
            }
            remainingVisualLabelCount -= record.visualLabels.count
        }
        return PersistenceBudget(
            remainingRecordCount: maximumRecordCount - records.count,
            remainingTextUTF8ByteCount: remainingTextBytes,
            remainingVisualLabelCount: remainingVisualLabelCount
        )
    }

    static func remove(for item: AssistantIndexedItem) {
        withMutationLock { removeUnlocked(for: item) }
    }

    /// Recovery cannot acknowledge a lower verified checkpoint while cache or
    /// breadcrumb bytes from the discarded generation remain. Unlike ordinary
    /// best-effort invalidation, this verifies all three durable surfaces and
    /// reports failure so NotebookIndex can keep its writer fence installed.
    @discardableResult
    static func removeVerified(for item: AssistantIndexedItem) -> Bool {
        withMutationLock {
            do {
                try removeVerifiedUnlocked(for: item)
                return true
            } catch {
                return false
            }
        }
    }

    /// Removes only derived state owned by this or an older verified save.
    /// A superseded image-free cleanup may run after a newer save has already
    /// persisted work; generation fencing preserves that newer cache/breadcrumb.
    static func remove(
        throughGeneration generation: Int64,
        for item: AssistantIndexedItem
    ) {
        withMutationLock {
            let generation = max(generation, 0)
            if pendingGenerationUnlocked(for: item).map({ $0 <= generation }) ?? true {
                removePendingUnlocked(for: item)
            }
            let envelope = loadEnvelopeUnlocked(for: item)
            if envelope?.generation.map({ $0 <= generation }) ?? true {
                try? FileManager.default.removeItem(at: cacheURL(for: item))
                try? FileManager.default.removeItem(at: quarantinedCacheURL(for: item))
            }
        }
    }

    private static func loadEnvelopeUnlocked(
        for item: AssistantIndexedItem
    ) -> AssistantImageEnrichmentEnvelope? {
        let url = cacheURL(for: item)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        guard let data = try? assistantReadBoundedData(
            at: url,
            maximumByteCount: maximumEncodedByteCount
        ) else {
            quarantineCacheUnlocked(for: item)
            return nil
        }
        guard assistantImageJSONHasBoundedStructure(data) else {
            quarantineCacheUnlocked(for: item)
            return nil
        }
        guard let envelope = try? JSONDecoder().decode(
            AssistantImageEnrichmentEnvelope.self,
            from: data
        ) else {
            quarantineCacheUnlocked(for: item)
            return nil
        }
        guard envelope.schemaVersion
            == AssistantImageEnrichmentEnvelope.currentSchemaVersion,
            envelope.records.allSatisfy(\.isWithinPersistenceBounds),
            isWithinAggregatePersistenceBounds(
                envelope.records,
                completedPageIDs: envelope.completedPageIDs ?? []
            ) else {
            quarantineCacheUnlocked(for: item)
            return nil
        }
        return envelope
    }

    private static func quarantineCacheUnlocked(for item: AssistantIndexedItem) {
        let source = cacheURL(for: item)
        guard FileManager.default.fileExists(atPath: source.path) else { return }
        let destination = quarantinedCacheURL(for: item)
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: source, to: destination)
        } catch {
            // Leave the original in place. Future reads continue to reject it
            // from metadata without mapping its contents.
        }
    }

    private static func removePendingUnlocked(for item: AssistantIndexedItem) {
        try? FileManager.default.removeItem(at: pendingURL(for: item))
        UserDefaults.standard.removeObject(forKey: pendingDefaultsKey(for: item))
    }

    private static func removeUnlocked(for item: AssistantIndexedItem) {
        try? FileManager.default.removeItem(at: cacheURL(for: item))
        try? FileManager.default.removeItem(at: quarantinedCacheURL(for: item))
        removePendingUnlocked(for: item)
    }

    /// Permanent deletion must not acknowledge success while derived OCR or a
    /// restart breadcrumb remains on disk. Ordinary invalidation stays
    /// best-effort; this verified variant propagates unlink failures to the
    /// caller so the authoritative tombstone/assets can be retained for retry.
    static func removeForPermanentDeletion(
        for item: AssistantIndexedItem
    ) throws {
        try withMutationLock {
            try removeVerifiedUnlocked(for: item)
        }
    }

    private static func removeVerifiedUnlocked(
        for item: AssistantIndexedItem
    ) throws {
        let fileManager = FileManager.default
        for url in [
            cacheURL(for: item),
            quarantinedCacheURL(for: item),
            pendingURL(for: item),
        ] {
            if fileManager.fileExists(atPath: url.path) {
                try fileManager.removeItem(at: url)
            }
            guard fileManager.fileExists(atPath: url.path) == false else {
                throw CocoaError(.fileWriteUnknown)
            }
        }
        let defaults = UserDefaults.standard
        let defaultsKey = pendingDefaultsKey(for: item)
        defaults.removeObject(forKey: defaultsKey)
        guard defaults.synchronize(),
            defaults.object(forKey: defaultsKey) == nil else {
            throw CocoaError(.fileWriteUnknown)
        }
    }

}
/// A tiny durable tombstone bridges recovery across process termination. The
/// catalog's preview generation cannot be lowered safely until every derived
/// retrieval surface is verified, so startup registrations use this marker to
/// reject persisted manifests even when a fresh thumbnail has already landed.
enum AssistantRecoveryMarkerStore {
    private static let filename = ".assistant-index-recovery-pending-v1"
    private static let maximumMarkerByteCount = 64
    private static let mutationLock = NSLock()

    private static func markerURL(in canvasDirectory: URL) -> URL {
        canvasDirectory.appendingPathComponent(filename, isDirectory: false)
    }

    static func isPending(in canvasDirectory: URL) -> Bool {
        mutationLock.withLock {
            FileManager.default.fileExists(
                atPath: markerURL(in: canvasDirectory).path
            )
        }
    }

    static func pendingGeneration(in canvasDirectory: URL) -> Int64? {
        mutationLock.withLock {
            guard let data = try? assistantReadBoundedData(
                at: markerURL(in: canvasDirectory),
                maximumByteCount: maximumMarkerByteCount
            ),
            let value = String(data: data, encoding: .utf8),
            let generation = Int64(value) else { return nil }
            return max(generation, 0)
        }
    }

    /// Filesystem marker discovery can touch every item in a large library.
    /// Callers run this helper from a detached utility task so those metadata
    /// reads never monopolize MainActor during startup registration.
    static func pendingItemIDs(
        for items: [AssistantIndexedItem]
    ) -> Set<UUID> {
        var pending = Set<UUID>()
        pending.reserveCapacity(min(items.count, 16))
        for item in items {
            guard Task.isCancelled == false else { break }
            if isPending(in: item.canvasDirectory) {
                pending.insert(item.itemID)
            }
        }
        return pending
    }

    @discardableResult
    static func markPending(
        generation: Int64,
        for item: AssistantIndexedItem
    ) -> Bool {
        mutationLock.withLock {
            guard FileManager.default.fileExists(
                atPath: item.canvasDirectory.path
            ) else { return false }
            let generation = max(generation, 0)
            let url = markerURL(in: item.canvasDirectory)
            do {
                try Data(String(generation).utf8).write(
                    to: url,
                    options: [.atomic, .completeFileProtection]
                )
                guard let stored = try? assistantReadBoundedData(
                    at: url,
                    maximumByteCount: maximumMarkerByteCount
                ),
                    String(data: stored, encoding: .utf8)
                    == String(generation) else { return false }
                return true
            } catch {
                return false
            }
        }
    }

    @discardableResult
    static func clearPending(
        throughGeneration generation: Int64,
        for item: AssistantIndexedItem
    ) -> Bool {
        mutationLock.withLock {
            let url = markerURL(in: item.canvasDirectory)
            guard FileManager.default.fileExists(atPath: url.path) else {
                return true
            }
            guard let data = try? assistantReadBoundedData(
                at: url,
                maximumByteCount: maximumMarkerByteCount
            ),
                let value = String(data: data, encoding: .utf8),
                let current = Int64(value) else {
                // An unreadable marker is uncertain recovery state. Keep it
                // fail-closed instead of silently declaring recovery complete.
                return false
            }
            if current > max(generation, 0) {
                return false
            }
            do {
                try FileManager.default.removeItem(at: url)
                return FileManager.default.fileExists(atPath: url.path) == false
            } catch {
                return false
            }
        }
    }
}

enum AssistantImageEnrichmentWorker {
    private static let maximumForegroundPreferredPageCount = 4
    private static let maximumForegroundContinuationPageCount = 2
    /// A provider that ignores cooperative cancellation must not pin Canvas
    /// invalidation or every later notebook. This is a per-page cap; foreground
    /// work additionally inherits the request's earlier absolute cutoff.
    private static let maximumBackgroundPageDuration: Duration = .seconds(12)
    private static let maximumAssetAnalysisDuration: Duration = .seconds(8)

    struct BackgroundResult: Equatable, Sendable {
        let records: [AssistantImageEnrichmentRecord]
        let hasCompleteDurableCache: Bool
    }

    struct ForegroundResult: Sendable {
        let records: [AssistantImageEnrichmentRecord]
        /// Pages whose complete visual asset set was revisited. A foreground
        /// commit replaces derived units only on these pages and preserves
        /// still-valid OCR carried by an incremental delta for other pages.
        let visitedPageIDs: Set<UUID>
        /// The partial or complete generation reached the restart cache.
        let hasDurableCache: Bool
        /// True only when the request visited every page in the verified
        /// snapshot and durably stored that complete generation. A targeted
        /// or interrupted pass remains restartable background work.
        let hasCompleteDurableCache: Bool
    }

    static func mayHaveWork(
        snapshot: CanvasCoreSnapshot,
        item _: AssistantIndexedItem
    ) -> Bool {
        // A cache is derived evidence, not proof that the current verified
        // snapshot still contains visual work. Returning true solely because
        // a stale cache exists would rewrite an empty cache after the final
        // image is removed instead of taking NotebookIndex's drain-then-delete
        // path. Visual pages still replay/rebuild their exact cache below.
        return snapshot.pages.contains(where: pageMayHaveVisualWork)
    }

    static func enrich(
        snapshot: CanvasCoreSnapshot,
        item: AssistantIndexedItem,
        analyzer: any AssistantImageAnalyzing,
        snapshotHydrationLease: NotebookSnapshotHydrationLease? = nil
    ) async -> BackgroundResult? {
        guard !Task.isCancelled else { return nil }
        let cacheState = AssistantImageEnrichmentStore.loadState(for: item)
        let cachedRecords = cacheState?.records ?? []
        let cached = Dictionary(
            cachedRecords.map {
                (cacheKey(stableID: $0.stableID, contentHash: $0.contentHash), $0)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let snapshotPageIDs = Set(snapshot.pages.map(\.id))
        var durableRecordsByStableID = Dictionary(
            cachedRecords
                .filter { snapshotPageIDs.contains($0.pageID) }
                .map { ($0.stableID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        var completedPageIDs: Set<UUID> = if cacheState?.generation
            == max(snapshot.generation, 0) {
            cacheState?.completedPageIDs.intersection(snapshotPageIDs) ?? []
        } else {
            []
        }
        let cachedPageIDs = Set(durableRecordsByStableID.values.map(\.pageID))
        let requiredPageIDs = Set(
            snapshot.pages.lazy
                .filter(pageMayHaveVisualWork)
                .map(\.id)
        ).union(cachedPageIDs)
        let pagesWithPendingAnalysis = Set(
            durableRecordsByStableID.values.lazy
                .filter { $0.isAnalysisComplete == false }
                .map(\.pageID)
        )
        let settledPageIDs = completedPageIDs.subtracting(
            pagesWithPendingAnalysis
        )

        for pageID in snapshot.pages.lazy.map(\.id).filter({
            requiredPageIDs.contains($0) && settledPageIDs.contains($0) == false
        }) {
            guard !Task.isCancelled else { return nil }
            let retainedRecords = durableRecordsByStableID.values.filter {
                $0.pageID != pageID
            }
            guard completedPageIDs.contains(pageID)
                || completedPageIDs.count
                < AssistantImageEnrichmentStore.maximumCompletedPageIDCount,
                let persistenceBudget = AssistantImageEnrichmentStore
                .remainingPersistenceBudget(after: retainedRecords) else {
                return nil
            }
            let deadline = ContinuousClock().now.advanced(
                by: maximumBackgroundPageDuration
            )
            guard let pageRecords = await recordsForPage(
                snapshot: snapshot,
                itemID: item.itemID,
                pageID: pageID,
                cached: cached,
                analyzer: analyzer,
                usesForegroundAnalysis: false,
                deadline: deadline,
                persistenceBudget: persistenceBudget,
                snapshotHydrationLease: snapshotHydrationLease
            ) else {
                // Prior whole-page checkpoints remain durable. This page stays
                // outside the completed frontier, so reopen/resume retries it.
                return nil
            }
            replaceRecords(
                on: pageID,
                with: pageRecords,
                in: &durableRecordsByStableID
            )
            completedPageIDs.insert(pageID)
            let durableRecords = ordered(
                Array(durableRecordsByStableID.values)
            )
            let cacheIsComplete = requiredPageIDs.isSubset(
                of: completedPageIDs
            ) && durableRecords.allSatisfy(\.isAnalysisComplete)
            guard AssistantImageEnrichmentStore.replace(
                durableRecords,
                generation: snapshot.generation,
                isComplete: cacheIsComplete,
                completedPageIDs: completedPageIDs,
                for: item
            ) else { return nil }
        }

        guard !Task.isCancelled else { return nil }
        let finalRecords = ordered(Array(durableRecordsByStableID.values))
        let isComplete = finalRecords.allSatisfy(\.isAnalysisComplete)
            && requiredPageIDs.isSubset(of: completedPageIDs)
        // Do not let NotebookIndex publish and acknowledge a derived
        // generation unless its restart cache reached disk too. Keeping the
        // pending breadcrumb causes a later maintenance pass to retry after a
        // transient storage/protection failure instead of silently accepting
        // a non-durable Vision result.
        guard AssistantImageEnrichmentStore.replace(
            finalRecords,
            generation: snapshot.generation,
            isComplete: isComplete,
            completedPageIDs: completedPageIDs,
            for: item
        ) else {
            return nil
        }
        return BackgroundResult(
            records: finalRecords,
            hasCompleteDurableCache: isComplete
        )
    }

    /// Performs the urgent pages plus a tiny rotating continuation window.
    /// Each whole page reaches the restart cache before the next page begins,
    /// so a request deadline can cancel disposable UI publication without
    /// throwing away OCR that already finished. Same-generation reopen/retry
    /// resumes from the durable page frontier and never scans the library.
    static func enrichForForegroundRequest(
        snapshot: CanvasCoreSnapshot,
        item: AssistantIndexedItem,
        analyzer: any AssistantImageAnalyzing,
        preferredPageIDs: [UUID],
        deadline: ContinuousClock.Instant,
        snapshotHydrationLease: NotebookSnapshotHydrationLease? = nil
    ) async -> ForegroundResult? {
        guard !Task.isCancelled, ContinuousClock().now < deadline else {
            return nil
        }
        let cacheState = AssistantImageEnrichmentStore.loadState(for: item)
        let cachedRecords = cacheState?.records ?? []
        let cached = Dictionary(
            cachedRecords.map {
                (cacheKey(stableID: $0.stableID, contentHash: $0.contentHash), $0)
            },
            uniquingKeysWith: { first, _ in first }
        )
        let snapshotPageIDs = Set(snapshot.pages.map(\.id))
        var durableRecordsByStableID = Dictionary(
            cachedRecords
                .filter { snapshotPageIDs.contains($0.pageID) }
                .map { ($0.stableID, $0) },
            uniquingKeysWith: { _, latest in latest }
        )
        var completedPageIDs: Set<UUID> = if cacheState?.generation
            == max(snapshot.generation, 0) {
            cacheState?.completedPageIDs.intersection(snapshotPageIDs) ?? []
        } else {
            []
        }
        let cachedPageIDs = Set(durableRecordsByStableID.values.map(\.pageID))
        let requiredPageIDs = Set(
            snapshot.pages.lazy
                .filter(pageMayHaveVisualWork)
                .map(\.id)
        ).union(cachedPageIDs)
        let pagesWithPendingAnalysis = Set(
            durableRecordsByStableID.values.lazy
                .filter { $0.isAnalysisComplete == false }
                .map(\.pageID)
        )
        let settledPageIDs = completedPageIDs.subtracting(
            pagesWithPendingAnalysis
        )
        let preferred = Array(
            orderedUniquePageIDs(preferredPageIDs, presentIn: snapshot)
                .prefix(maximumForegroundPreferredPageCount)
        )
        let preferredSet = Set(preferred)
        let continuation = Array(
            snapshot.pages.lazy
                .map(\.id)
                .filter {
                    requiredPageIDs.contains($0)
                        && settledPageIDs.contains($0) == false
                        && preferredSet.contains($0) == false
                }
                .prefix(maximumForegroundContinuationPageCount)
        )
        let pendingPreferred = preferred.filter {
            settledPageIDs.contains($0) == false
        }
        let selectedPageIDs: [UUID]
        if let firstPreferred = pendingPreferred.first {
            selectedPageIDs = [firstPreferred]
                + continuation
                + Array(pendingPreferred.dropFirst())
        } else {
            selectedPageIDs = continuation
        }
        var cacheStored = cacheState?.generation == max(snapshot.generation, 0)
            && AssistantImageEnrichmentStore.hasCache(for: item)

        for pageID in selectedPageIDs {
            let retainedRecords = durableRecordsByStableID.values.filter {
                $0.pageID != pageID
            }
            guard !Task.isCancelled, ContinuousClock().now < deadline,
                completedPageIDs.contains(pageID)
                || completedPageIDs.count
                < AssistantImageEnrichmentStore.maximumCompletedPageIDCount,
                let persistenceBudget = AssistantImageEnrichmentStore
                        .remainingPersistenceBudget(after: retainedRecords),
                    let pageRecords = await recordsForPage(
                        snapshot: snapshot,
                        itemID: item.itemID,
                        pageID: pageID,
                        cached: cached,
                        analyzer: analyzer,
                        usesForegroundAnalysis: true,
                        deadline: deadline,
                        persistenceBudget: persistenceBudget,
                        snapshotHydrationLease: snapshotHydrationLease
                    ) else { return nil }

                replaceRecords(
                    on: pageID,
                    with: pageRecords,
                    in: &durableRecordsByStableID
                )
                completedPageIDs.insert(pageID)

                let durableRecords = ordered(
                    Array(durableRecordsByStableID.values)
                )
                let cacheIsComplete = requiredPageIDs.isSubset(
                    of: completedPageIDs
                ) && durableRecords.allSatisfy(\.isAnalysisComplete)
                cacheStored = AssistantImageEnrichmentStore.replace(
                    durableRecords,
                    generation: snapshot.generation,
                    isComplete: cacheIsComplete,
                    completedPageIDs: completedPageIDs,
                    for: item
                )
                guard cacheStored else { return nil }
            }

            let durableRecords = ordered(Array(durableRecordsByStableID.values))
            let cacheIsComplete = requiredPageIDs.isSubset(of: completedPageIDs)
                && durableRecords.allSatisfy(\.isAnalysisComplete)
            if selectedPageIDs.isEmpty,
                cacheState?.generation == max(snapshot.generation, 0),
                cacheState?.isComplete != cacheIsComplete {
                cacheStored = AssistantImageEnrichmentStore.replace(
                    durableRecords,
                    generation: snapshot.generation,
                    isComplete: cacheIsComplete,
                    completedPageIDs: completedPageIDs,
                    for: item
                )
            }
            let publishableRecords = durableRecords.filter {
                completedPageIDs.contains($0.pageID)
            }
            return ForegroundResult(
                records: publishableRecords,
                visitedPageIDs: completedPageIDs,
                hasDurableCache: cacheStored,
                hasCompleteDurableCache: cacheIsComplete && cacheStored
            )
        }

    /// Produces one side-effect-free page result. Both page hydration/rendering
    /// and each provider call race absolute cutoffs through unstructured tasks;
    /// a cancellation-resistant provider may drain later, but it owns no cache
    /// or index mutation and therefore cannot publish after the fence moves.
    private static func recordsForPage(
        snapshot: CanvasCoreSnapshot,
        itemID: UUID,
        pageID: UUID,
        cached: [String: AssistantImageEnrichmentRecord],
        analyzer: any AssistantImageAnalyzing,
        usesForegroundAnalysis: Bool,
        deadline: ContinuousClock.Instant,
        persistenceBudget: AssistantImageEnrichmentStore.PersistenceBudget,
        snapshotHydrationLease: NotebookSnapshotHydrationLease?
    ) async -> [AssistantImageEnrichmentRecord]? {
        guard !Task.isCancelled, ContinuousClock().now < deadline else {
            return nil
        }
        // No amount of provider work can produce an admissible record once the
        // notebook-wide cache is full. Treat the page as a terminal empty
        // projection; its completed frontier is persisted by the caller.
        guard persistenceBudget.remainingRecordCount > 0,
            persistenceBudget.remainingTextUTF8ByteCount > 0 else {
            return []
        }
        let workID = UUID()
        guard await AssistantImageRawWorkArbiter.shared.reserve(
            itemID: itemID,
            ownerID: workID
        ) else {
            return nil
        }
        let task: Task<[AssistantImageEnrichmentRecord]?, Never> = Task.detached(
            priority: usesForegroundAnalysis ? .userInitiated : .background
        ) {
            var pageRecords: [AssistantImageEnrichmentRecord] = []
            var remainingRecordCount = persistenceBudget.remainingRecordCount
            var remainingRecordTextBytes =
                persistenceBudget.remainingTextUTF8ByteCount
            var remainingVisualLabelCount =
                persistenceBudget.remainingVisualLabelCount
            var reachedPersistenceLimit = false

            func appendRecord(_ record: AssistantImageEnrichmentRecord) -> Bool {
                guard remainingRecordCount > 0,
                    let byteCount = record.persistenceUTF8ByteCount,
                    byteCount <= remainingRecordTextBytes else {
                    reachedPersistenceLimit = true
                    return false
                }
                guard record.visualLabels.count <= remainingVisualLabelCount else {
                    reachedPersistenceLimit = true
                    return false
                }
                remainingRecordCount -= 1
                remainingRecordTextBytes -= byteCount
                remainingVisualLabelCount -= record.visualLabels.count
                pageRecords.append(record)
                return true
            }

            let completed = await AssistantImageAssetExtractor.visitAssets(
                in: snapshot,
                pageIDs: [pageID]
            ) { asset in
                guard !Task.isCancelled else { return false }
                let key = cacheKey(
                    stableID: asset.stableID,
                    contentHash: asset.contentHash
                )
                if let existing = cached[key], existing.isAnalysisComplete {
                    return appendRecord(existing.relocated(to: asset))
                }

                let analysisDeadline = min(
                    deadline,
                    ContinuousClock().now.advanced(
                        by: maximumAssetAnalysisDuration
                    )
                )
                let analysisTask = Task.detached(
                    priority: usesForegroundAnalysis
                        ? .userInitiated
                        : .background
                ) {
                    if usesForegroundAnalysis {
                        return await analyzer.analyzeForForegroundRequest(asset)
                    }
                    return await analyzer.analyze(asset)
                }
                let outcome = await assistantImageTaskOutcome(
                    of: analysisTask,
                    until: analysisDeadline
                )
                guard case let .value(analysis) = outcome,
                    !Task.isCancelled else {
                    // Cancellation is advisory for Vision and alternate
                    // providers. Keep the page task and therefore its bounded
                    // permit alive until the raw analyzer really releases the
                    // rendered image it may retain.
                    _ = await analysisTask.value
                    // No record is stronger than a successful-empty record:
                    // the page remains outside the durable completed frontier
                    // and is retried after reopen/resume.
                    return false
                }
                guard appendRecord(
                    mergedRecord(
                        for: asset,
                        analysis: analysis,
                        preserving: cached[key]
                    )
                ) else {
                    return false
                }
                await Task.yield()
                return !Task.isCancelled
            }
            if reachedPersistenceLimit, !Task.isCancelled {
                return pageRecords
            }
            guard completed, !Task.isCancelled else { return nil }
            return pageRecords
        }
        let outcome = await assistantImageTaskOutcome(
            of: task,
            until: deadline
        )
        guard case let .value(records) = outcome else {
            // Cancellation-resistant framework/provider work must not block
            // invalidation or an interactive request. Transfer ownership of
            // both resource permits to a bounded late drain: the raw-work
            // arbiter prevents another page for this note from starting, and
            // a cold-load lease stays alive until the snapshot really leaves
            // the provider callback.
            Task.detached(priority: .utility) { [snapshotHydrationLease] in
                _ = await task.value
                await AssistantImageRawWorkArbiter.shared.release(
                    itemID: itemID,
                    ownerID: workID
                )
                withExtendedLifetime(snapshotHydrationLease) {}
            }
            return nil
        }
        await AssistantImageRawWorkArbiter.shared.release(
            itemID: itemID,
            ownerID: workID
        )
        return records
    }

    private static func replaceRecords(
        on pageID: UUID,
        with pageRecords: [AssistantImageEnrichmentRecord],
        in recordsByStableID: inout [String: AssistantImageEnrichmentRecord]
    ) {
        let supersededStableIDs = recordsByStableID.values
            .filter { $0.pageID == pageID }
            .map(\.stableID)
        for stableID in supersededStableIDs {
            recordsByStableID.removeValue(forKey: stableID)
        }
        for record in pageRecords {
            recordsByStableID[record.stableID] = record
        }
    }

    /// Merge independent Vision stages for unchanged bytes. If this attempt
    /// fails one stage but a prior partial record had already completed it,
    /// retain that trustworthy value and certify the combined record once all
    /// required stages have succeeded at least once.
    private static func mergedRecord(
        for asset: AssistantImageAsset,
        analysis: AssistantImageAnalysis,
        preserving existing: AssistantImageEnrichmentRecord?
    ) -> AssistantImageEnrichmentRecord {
        var pendingStages = Set<AssistantImageAnalysisStage>()

        let recognizedText: String
        if analysis.failedStages.contains(.textRecognition) {
            if let existing,
                existing.pendingStages.contains(.textRecognition) == false {
                recognizedText = existing.recognizedText
            } else {
                recognizedText = existing?.recognizedText
                    ?? analysis.recognizedText
                pendingStages.insert(.textRecognition)
            }
        } else {
            recognizedText = analysis.recognizedText
        }

        let visualLabels: [String]
        if analysis.failedStages.contains(.imageClassification) {
            if let existing,
                existing.pendingStages.contains(.imageClassification) == false {
                visualLabels = existing.visualLabels
            } else {
                visualLabels = existing?.visualLabels
                    ?? analysis.visualLabels
                pendingStages.insert(.imageClassification)
            }
        } else {
            visualLabels = analysis.visualLabels
        }

        return AssistantImageEnrichmentRecord(
            stableID: asset.stableID,
            contentHash: asset.contentHash,
            pageID: asset.pageID,
            pageNumber: asset.pageNumber,
            pageBounds: asset.pageBounds,
            recognizedText: recognizedText,
            visualLabels: visualLabels,
            semanticDescription: analysis.semanticDescription
                ?? existing?.semanticDescription,
            pendingStages: pendingStages
        )
    }

    private static func orderedUniquePageIDs(
        _ candidates: [UUID],
        presentIn snapshot: CanvasCoreSnapshot
    ) -> [UUID] {
        let available = Set(snapshot.pages.map(\.id))
        var seen = Set<UUID>()
        return candidates.filter {
            available.contains($0) && seen.insert($0).inserted
        }
    }

    private static func pageMayHaveVisualWork(
        _ page: CanvasPageSnapshot
    ) -> Bool {
        if page.background.isImported { return true }
        let contentFrame = page.markup.contentsRenderFrame
        if contentFrame.isNull == false,
            contentFrame.isInfinite == false,
            contentFrame.isEmpty == false {
            // PaperKit's indexableContent covers native text, but not
            // handwritten strokes on every supported OS. A deferred,
            // bounded page raster gives Vision an explicit handwriting path.
            return true
        }
        if #available(iOS 27.0, *),
            page.markup.subelements.contains(where: { $0 is ImageMarkup }) {
            return true
        }
        return false
    }

    private static func ordered(
        _ records: [AssistantImageEnrichmentRecord]
    ) -> [AssistantImageEnrichmentRecord] {
        records.sorted {
            if $0.pageNumber != $1.pageNumber { return $0.pageNumber < $1.pageNumber }
            return $0.stableID < $1.stableID
        }
    }

    private static func cacheKey(stableID: String, contentHash: String) -> String {
        "\(stableID)|\(contentHash)"
    }

    private enum AssistantImageAssetExtractor {
        private static let maximumWorkingPixelDimension: CGFloat = 2_048

        static func visitAssets(
            in snapshot: CanvasCoreSnapshot,
            pageIDs: [UUID]? = nil,
            visit: (AssistantImageAsset) async -> Bool
        ) async -> Bool {
            let pagesByID = Dictionary(
                snapshot.pages.enumerated().map {
                    ($0.element.id, (offset: $0.offset, page: $0.element))
                },
                uniquingKeysWith: { current, _ in current }
            )
            let pages = pageIDs.map { ids in
                ids.compactMap { pagesByID[$0] }
            } ?? snapshot.pages.enumerated().map {
                (offset: $0.offset, page: $0.element)
            }
            for (offset, page) in pages {
                guard !Task.isCancelled else { return false }
                let pageNumber = offset + 1
                let pageFrame = page.displaySize.width > 0 && page.displaySize.height > 0
                    ? CGRect(origin: .zero, size: page.displaySize)
                    : nil

                switch page.background {
                case .paper:
                    break

                case let .image(source, _):
                    guard let data = source.imageData,
                        let image = preparedBackgroundImage(for: page) else {
                        // This snapshot says an imported visual exists. Missing
                        // hydrated bytes or a failed bounded render is therefore
                        // an interrupted visit, not an image-free page. Failing
                        // closed keeps the previous cache incomplete/reusable and
                        // preserves the pending breadcrumb for a later retry.
                        return false
                    }
                    let asset = AssistantImageAsset(
                        stableID: "\(page.id.uuidString.lowercased())|background",
                        pageID: page.id,
                        pageNumber: pageNumber,
                        pageBounds: pageFrame,
                        contentHash: source.contentChecksum ?? hash(data),
                        image: image,
                        orientation: .up
                    )
                    guard await visit(asset) else { return false }

                case let .pdfPage(source, pageIndex, _):
                    guard let data = source.documentData,
                        let image = preparedBackgroundImage(for: page) else {
                        return false
                    }
                    let sourceHash = source.contentChecksum ?? hash(data)
                    let asset = AssistantImageAsset(
                        stableID: "\(page.id.uuidString.lowercased())|background",
                        pageID: page.id,
                        pageNumber: pageNumber,
                        pageBounds: pageFrame,
                        contentHash: "\(sourceHash)|pdf-page:\(pageIndex)",
                        image: image,
                        orientation: .up
                    )
                    guard await visit(asset) else { return false }
                }

                // On iOS 27 each ImageMarkup is emitted below as its own stable
        // classification never see the same pixels twice. On iOS 26 the
        // subelement API is unavailable, so the single page raster remains
        // the only supported image-markup representation.
        if #available(iOS 27.0, *),
            page.markup.subelements.count
            > CanvasBoundedPaperTextExtractor.maximumVisitedElementCount {
            // Derived Vision may be retried after the source is simplified;
            // never copy or scan a pathological element collection here.
            return false
        }
        let rasterMarkup = markupForPageRaster(page.markup)
        let contentFrame = rasterMarkup.contentsRenderFrame
        if contentFrame.isNull == false,
            contentFrame.isInfinite == false,
            contentFrame.isEmpty == false {
            guard let image = await preparedMarkupImage(
                rasterMarkup,
                displaySize: page.displaySize
            ) else {
                return false
            }
            let asset = AssistantImageAsset(
                stableID: "\(page.id.uuidString.lowercased())|paper-markup",
                pageID: page.id,
                pageNumber: pageNumber,
                pageBounds: pageFrame,
                // Vision analyzes the bounded raster, so its pixel hash is
                // the exact cache identity and avoids serializing up to a
                // persistence-sized PaperKit archive a second time.
                contentHash: hash(image, orientation: .up),
                image: image,
                orientation: .up
            )
            guard await visit(asset) else { return false }
        }

        if #available(iOS 27.0, *) {
            for element in page.markup.subelements {
                guard !Task.isCancelled else { return false }
                guard let imageMarkup = element as? ImageMarkup else {
                    continue
                }
                guard let image = await preparedImage(
                    from: imageMarkup
                ) else {
                    return false
                }
                let stableID = imageMarkup.id.rawValue.base64EncodedString()
                let asset = AssistantImageAsset(
                    stableID: "\(page.id.uuidString.lowercased())|\(stableID)",
                    pageID: page.id,
                    pageNumber: pageNumber,
                    pageBounds: imageMarkup.renderFrame,
                    contentHash: hash(
                        image,
                        orientation: imageMarkup.orientation
                    ),
                    image: image,
                    orientation: imageMarkup.orientation
                )
                guard await visit(asset) else { return false }
            }
        }
        await Task.yield()
    }
    return true
    }

    /// Imported backgrounds use the same orientation- and rotation-aware
    /// renderer as the canvas, but at a fixed Vision working size. PDF pages
    /// remain vector until this one bounded bitmap is requested, so a scanned
    /// page does not need a lossy preview persisted beside the source.
    private static func preparedBackgroundImage(
        for page: CanvasPageSnapshot
    ) -> CGImage? {
        guard let pixelSize = boundedPixelSize(for: page.displaySize),
            let context = bitmapContext(size: pixelSize) else { return nil }
        fillWhite(context, size: pixelSize)
        context.saveGState()
        prepareTopLeftCoordinates(
            context,
            pixelSize: pixelSize,
            logicalSize: page.displaySize
        )
        let didDraw = CanvasPageBackgroundRenderer.draw(
            page.background,
            geometry: page.geometry,
            in: context,
            destinationRect: CGRect(origin: .zero, size: page.displaySize),
            maximumImagePixelDimension: maximumWorkingPixelDimension
        )
        context.restoreGState()
        guard didDraw else { return nil }
        return context.makeImage()
    }

    /// Renders only editable PaperKit content on white. This catches strokes
    /// and iOS 26 image markups that are absent from `indexableContent`, while
    /// keeping decorative paper templates out of OCR and visual classification.
    private static func preparedMarkupImage(
        _ markup: PaperMarkup,
        displaySize: CGSize
    ) async -> CGImage? {
        guard let pixelSize = boundedPixelSize(for: displaySize),
            let context = bitmapContext(size: pixelSize) else { return nil }
        fillWhite(context, size: pixelSize)
        context.saveGState()
        prepareTopLeftCoordinates(
            context,
            pixelSize: pixelSize,
            logicalSize: displaySize
        )
        await markup.draw(
            in: context,
            frame: CGRect(origin: .zero, size: displaySize),
            options: CanvasPaperRenderingEnvironment.lightOptions
        )
        context.restoreGState()
        guard !Task.isCancelled else { return nil }
        return context.makeImage()
    }

    private static func markupForPageRaster(
        _ markup: PaperMarkup
    ) -> PaperMarkup {
        guard #available(iOS 27.0, *) else { return markup }
        var rasterMarkup = markup
        rasterMarkup.subelements.removeAll { $0 is ImageMarkup }
        return rasterMarkup
    }

    private static func boundedPixelSize(for logicalSize: CGSize) -> CGSize? {
        guard logicalSize.width.isFinite,
            logicalSize.height.isFinite,
            logicalSize.width > 0,
            logicalSize.height > 0 else { return nil }
        let scale = min(
            2,
            maximumWorkingPixelDimension / max(logicalSize.width, logicalSize.height)
        )
        guard scale.isFinite, scale > 0 else { return nil }
        return CGSize(
            width: max(ceil(logicalSize.width * scale), 1),
            height: max(ceil(logicalSize.height * scale), 1)
        )
    }

    private static func bitmapContext(size: CGSize) -> CGContext? {
        guard size.width < CGFloat(Int.max),
            size.height < CGFloat(Int.max) else { return nil }
        return CGContext(
            data: nil,
            width: Int(size.width),
            height: Int(size.height),
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )
    }

    private static func fillWhite(_ context: CGContext, size: CGSize) {
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(origin: .zero, size: size))
    }

    private static func prepareTopLeftCoordinates(
        _ context: CGContext,
        pixelSize: CGSize,
        logicalSize: CGSize
    ) {
        context.translateBy(x: 0, y: pixelSize.height)
        context.scaleBy(
            x: pixelSize.width / logicalSize.width,
            y: -pixelSize.height / logicalSize.height
        )
    }

    private static func prepareImage(from data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 2_048,
            kCGImageSourceShouldCacheImmediately: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// End the original PaperKit image's lifetime before the bounded raster is
    /// handed to Vision. Keeping both images in the caller's async scope would
    /// otherwise retain a full-resolution photo for the entire analysis wait.
    @available(iOS 27.0, *)
    private static func preparedImage(
        from imageMarkup: ImageMarkup
    ) async -> CGImage? {
        guard let rawImage = await imageMarkup.image else { return nil }
        return preparedImage(rawImage)
    }

    private static func preparedImage(_ image: CGImage) -> CGImage? {
        let maximumDimension = max(image.width, image.height)
        guard maximumDimension > 2_048 else { return image }

        let scale = 2_048.0 / CGFloat(maximumDimension)
        let width = max(Int((CGFloat(image.width) * scale).rounded()), 1)
        let height = max(Int((CGFloat(image.height) * scale).rounded()), 1)
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func hash(
        _ image: CGImage,
        orientation: CGImagePropertyOrientation
    ) -> String {
        var hasher = SHA256()
        withUnsafeBytes(of: UInt64(image.width).littleEndian) { hasher.update(bufferPointer: $0) }
        withUnsafeBytes(of: UInt64(image.height).littleEndian) { hasher.update(bufferPointer: $0) }
        withUnsafeBytes(of: orientation.rawValue.littleEndian) { hasher.update(bufferPointer: $0) }
        if let bytes = image.dataProvider?.data {
            hasher.update(data: bytes as Data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
}

enum AssistantImageTaskOutcome<Value: Sendable>: Sendable {
    case value(Value)
    case timedOut
    case cancelled
}

/// A cancellation handler is synchronous, so the winner must be recorded by
/// a synchronous primitive too. An actor hop here lets a cooperative child
/// return and publish `.value` before the queued `.cancelled` message runs.
private final class AssistantImageTaskRace<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<AssistantImageTaskOutcome<Value>, Never>?
    private var storedOutcome: AssistantImageTaskOutcome<Value>?
    private var isResolved = false

    func value() async -> AssistantImageTaskOutcome<Value> {
        return await withCheckedContinuation { continuation in
            lock.lock()
            if let storedOutcome {
                lock.unlock()
                continuation.resume(returning: storedOutcome)
            } else {
                self.continuation = continuation
                lock.unlock()
            }
        }
    }

    func resolve(_ outcome: AssistantImageTaskOutcome<Value>) {
        let continuation: CheckedContinuation<
            AssistantImageTaskOutcome<Value>, Never
        >?
        lock.lock()
        guard isResolved == false else {
            lock.unlock()
            return
        }
        isResolved = true
        continuation = self.continuation
        storedOutcome = outcome
        if continuation != nil {
            self.continuation = nil
        }
        lock.unlock()
        continuation?.resume(returning: outcome)
    }
}

/// Resolves the visible deadline without entering a structured task-group
/// scope. Task groups must drain cancelled children before returning, while a
/// Foundation Models request is allowed to acknowledge cancellation late.
func assistantImageTaskOutcome<Value: Sendable>(
    of task: Task<Value, Never>,
    timeout: Duration
) async -> AssistantImageTaskOutcome<Value> {
    await assistantImageTaskOutcome(
        of: task,
        until: ContinuousClock().now.advanced(by: max(timeout, .zero))
    )
}

/// Uses the caller's immutable product deadline instead of granting image
/// work a fresh duration after checkpointing or base-index publication.
func assistantImageTaskOutcome<Value: Sendable>(
    of task: Task<Value, Never>,
    until deadline: ContinuousClock.Instant
) async -> AssistantImageTaskOutcome<Value> {
    let clock = ContinuousClock()
    let race = AssistantImageTaskRace<Value>()
    let resultWatcher = Task {
        let value = await task.value
        guard Task.isCancelled == false, clock.now < deadline else {
            race.resolve(.timedOut)
            return
        }
        race.resolve(.value(value))
    }
    let timeoutWatcher = Task {
        do {
            try await clock.sleep(until: deadline, tolerance: .zero)
        } catch {
            return
        }
        task.cancel()
        race.resolve(.timedOut)
    }

    let outcome = await withTaskCancellationHandler {
        await race.value()
    } onCancel: {
        // Record cancellation before waking the cooperative child. Otherwise
        // that child can return a value and win while a queued actor message
        // carrying `.cancelled` is still waiting to execute.
        race.resolve(.cancelled)
        task.cancel()
        timeoutWatcher.cancel()
    }
    timeoutWatcher.cancel()
    resultWatcher.cancel()
    // Covers cancellation delivered at the boundary after a value resolved
    // but before this task returned to its caller.
    guard Task.isCancelled == false else {
        task.cancel()
        return .cancelled
    }
    return outcome
}

/// Releases a background-model reservation only after the provider task has
/// actually returned. The returned handle exists so deterministic tests can
/// observe the ordering without constructing a real language-model session.
@discardableResult
func assistantReleaseBackgroundModelLaneAfterDrain<Value: Sendable>(
    _ task: Task<Value, Never>,
    releaseModelLane: @escaping @Sendable () async -> Void
) -> Task<Void, Never> {
    Task {
        _ = await task.value
        await releaseModelLane()
    }
}

private extension String {
    func assistantImageBounded(maximumUTF8Bytes: Int) -> String {
        guard maximumUTF8Bytes > 0 else { return "" }
        guard utf8.count > maximumUTF8Bytes else { return self }
        var byteCount = 0
        let bounded = prefix { character in
            let characterByteCount = String(character).utf8.count
            guard byteCount + characterByteCount <= maximumUTF8Bytes else {
                return false
            }
            byteCount += characterByteCount
            return true
        }
        return String(bounded)
    }
}
