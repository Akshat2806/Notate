import CoreGraphics
import Foundation
import Observation
import OSLog

public enum AssistantRequestMode: String, CaseIterable, Sendable {
    case ask
    case find

    public var title: String {
        switch self {
        case .ask: "Ask"
        case .find: "Find"
        }
    }
}

/// Describes the exact boundary reached before retrieval begins.
///
/// Keeping these states distinct prevents a transient Canvas handoff or an
/// index deadline from being presented as though the user's note failed to
/// save or changed underneath the request.
public enum AssistantRequestPreparationResult: Equatable, Sendable {
    case ready
    case canvasTemporarilyBusy
    case saveFailed
    /// The current note was saved and verified, but its on-device retrieval
    /// snapshot could not be published before the request had to stop.
    case retrievalPreparationFailed
}

public enum AssistantExchangePhase: Equatable, Sendable {
    case waiting
    case streaming
    case complete
    case stopped
}

/// Separates authored assistant content from terminal guidance that explains
/// why no answer was produced. Presentation must not infer success from an
/// exchange merely reaching the `.complete` lifecycle phase.
public enum AssistantExchangeOutcome: Equatable, Sendable {
    case content
    case noResult
    case failure

    var presentsCompletionAffordances: Bool {
        self == .content
    }
}

public enum AssistantWorkPhase: Equatable, Hashable, Sendable {
    case readingNote
    case gettingRelevantDetails
    case thinkingThroughNotes
    case writingSummary
    case summarizingSection(current: Int, total: Int)
    case finishingUp

    public var title: String {
        switch self {
        case .readingNote: "Reading your note…"
        case .gettingRelevantDetails: "Getting the relevant details…"
        case .thinkingThroughNotes: "Thinking through your notes…"
        case .writingSummary: "Writing the summary…"
        case let .summarizingSection(current, total):
            "Summarizing section \(current) of \(total)…"
        case .finishingUp: "Finishing up…"
        }
    }

    fileprivate var metricLabel: String {
        switch self {
        case .readingNote: "snapshot"
        case .gettingRelevantDetails: "retrieval"
        case .thinkingThroughNotes: "generation"
        case .writingSummary: "summary-direct"
        case .summarizingSection: "summary-hierarchical"
        case .finishingUp: "validation"
        }
    }
}

enum AssistantResponsePresentationStage: Equatable, Hashable, Sendable {
    case workingOnQuery
}

/// One copy policy owns both the short anti-flash floor and the real
/// pipeline phases. This prevents visual status, VoiceOver announcements, and
/// long-running messaging from describing different work.
enum AssistantProgressCopy {
    static func title(
        task: AssistantTask?,
        scope: AssistantScope?,
        scopeTitle: String?,
        presentationStage: AssistantResponsePresentationStage? = nil,
        workPhase: AssistantWorkPhase? = nil,
        passageCount: Int? = nil,
        isTakingLonger: Bool = false
    ) -> String {
        if let presentationStage {
            return presentationTitle(
                task: task,
                scope: scope,
                scopeTitle: scopeTitle,
                stage: presentationStage
            )
        }

        guard let workPhase else {
            return task == .find
                ? scopedRetrievalTitle(scope: scope, scopeTitle: scopeTitle)
                : scopedReadingTitle(scope: scope, scopeTitle: scopeTitle)
        }
        if isTakingLonger {
            return longerRunningTitle(
                task: task,
                scope: scope,
                scopeTitle: scopeTitle,
                phase: workPhase,
                passageCount: passageCount
            )
        }
        return phaseTitle(
            task: task,
            scope: scope,
            scopeTitle: scopeTitle,
            phase: workPhase,
            passageCount: passageCount
        )
    }

    private static func presentationTitle(
        task: AssistantTask?,
        scope: AssistantScope?,
        scopeTitle: String?,
        stage: AssistantResponsePresentationStage
    ) -> String {
        switch stage {
        case .workingOnQuery:
            switch scope {
            case .page:
                return "Going through this page…"
            case .item:
                return "Going through this \((scopeTitle ?? "notebook").lowercased())…"
            case .library:
                return task == .summarize || task == .study
                    ? "Checking the selected scope…"
                    : "Searching your notes…"
            case nil:
                return "Going through your notes…"
            }
        }
    }

    private static func phaseTitle(
        task: AssistantTask?,
        scope: AssistantScope?,
        scopeTitle: String?,
        phase: AssistantWorkPhase,
        passageCount: Int?
    ) -> String {
        switch phase {
        case .readingNote:
            return scopedReadingTitle(scope: scope, scopeTitle: scopeTitle)
        case .gettingRelevantDetails:
            return evidenceTitle(task: task, passageCount: passageCount)
                ?? scopedRetrievalTitle(scope: scope, scopeTitle: scopeTitle)
        case .thinkingThroughNotes:
            return generationTitle(task: task, passageCount: passageCount)
        case .writingSummary:
            return "Writing the summary…"
        case let .summarizingSection(current, total):
            return "Summarizing section \(current) of \(total)…"
        case .finishingUp:
            return "Checking sources and formatting…"
        }
    }

    private static func longerRunningTitle(
        task: AssistantTask?,
        scope: AssistantScope?,
        scopeTitle: String?,
        phase: AssistantWorkPhase,
        passageCount: Int?
    ) -> String {
        switch phase {
        case .readingNote:
            switch scope {
            case .page:
                return "Still reading this page on this iPad…"
            case .item:
                return "Still reading this \((scopeTitle ?? "notebook").lowercased()) on this iPad…"
            case .library:
                return "Still searching this iPad…"
            case nil:
                return "Still reading your note on this iPad…"
            }
        case .gettingRelevantDetails:
            switch scope {
            case .page:
                return "Still searching this page on this iPad…"
            case .item:
                return "Still searching this \((scopeTitle ?? "notebook").lowercased()) on this iPad…"
            case .library:
                return "Still searching this iPad…"
            case nil:
                return "Still getting the relevant details on this iPad…"
            }
        case .thinkingThroughNotes:
            switch task {
            case .answer:
                return "Still writing a grounded answer on this iPad…"
            case .explain:
                return "Still building an explanation on this iPad…"
            case .study:
                return "Still preparing study material on this iPad…"
            case .summarize:
                return "Still writing the summary on this iPad…"
            case .find:
                return "Still ranking the best matches on this iPad…"
            case nil:
                if let passageCount, passageCount > 0 {
                    return "Still working from \(passageCount) relevant passages on this iPad…"
                }
                return "Still thinking through your notes on this iPad…"
            }
        case .writingSummary:
            return "Still writing the summary on this iPad…"
        case let .summarizingSection(current, total):
            return "Still summarizing section \(current) of \(total) on this iPad…"
        case .finishingUp:
            return "Still checking sources and formatting on this iPad…"
        }
    }

    private static func scopedReadingTitle(
        scope: AssistantScope?,
        scopeTitle: String?
    ) -> String {
        switch scope {
        case .page:
            return "Reading the latest page…"
        case .item:
            return "Reading the latest \((scopeTitle ?? "notebook").lowercased())…"
        case .library:
            // Library work remains bounded retrieval; never imply that every
            // note is being loaded into the model context.
            return "Searching this iPad…"
        case nil:
            return "Reading your note…"
        }
    }

    private static func scopedRetrievalTitle(
        scope: AssistantScope?,
        scopeTitle: String?
    ) -> String {
        switch scope {
        case .page:
            return "Searching this page for relevant details…"
        case .item:
            return "Searching this \((scopeTitle ?? "notebook").lowercased()) for relevant details…"
        case .library:
            return "Searching this iPad…"
        case nil:
            return "Getting the relevant details…"
        }
    }

    private static func evidenceTitle(
        task: AssistantTask?,
        passageCount: Int?
    ) -> String? {
        guard let passageCount, passageCount > 0 else { return nil }
        if task == .find {
            return "Found \(passageCount) \(passageCount == 1 ? "match" : "matches")…"
        }
        return "Found \(passageCount) relevant \(passageCount == 1 ? "passage" : "passages")…"
    }

    private static func generationTitle(
        task: AssistantTask?,
        passageCount: Int?
    ) -> String {
        let evidenceSuffix: String
        if let passageCount, passageCount > 0 {
            evidenceSuffix = " from \(passageCount) \(passageCount == 1 ? "passage" : "passages")"
        } else {
            evidenceSuffix = ""
        }
        switch task {
        case .answer:
            return "Creating an answer\(evidenceSuffix)…"
        case .explain:
            return "Building an explanation\(evidenceSuffix)…"
        case .study:
            return "Preparing study material\(evidenceSuffix)…"
        case .summarize:
            return "Creating a clear summary…"
        case .find:
            return "Ranking the best matches…"
        case nil:
            return "Thinking through your notes…"
        }
    }
}

struct AssistantResponsePresentation: Equatable, Sendable {
    let requestID: UUID
    let exchangeID: UUID
    let stage: AssistantResponsePresentationStage
    let task: AssistantTask
    let scope: AssistantScope
    let scopeTitle: String

    var title: String {
        AssistantProgressCopy.title(
            task: task,
            scope: scope,
            scopeTitle: scopeTitle,
            presentationStage: stage
        )
    }
}

public enum AssistantPreliminaryResultKind: Equatable, Sendable {
    case quickSummary
    case relevantPassages

    public var title: String {
        switch self {
        case .quickSummary: "Quick summary"
        case .relevantPassages: "Relevant passages"
        }
    }
}

/// Identifies how a finished note summary was produced. Keeping this as typed
/// state prevents the UI from guessing from the answer copy (and accidentally
/// labeling an error or timeout message as AI-generated).
public enum AssistantSummaryProvenance: Equatable, Sendable {
    case aiRefined
    case quickSummary

    public var title: String {
        switch self {
        case .aiRefined: "AI refined"
        case .quickSummary: "Quick summary"
        }
    }
}

public enum AssistantStatusSeverity: Equatable, Sendable {
    case information
    case warning
    case error
}

public enum AssistantStatusAction: Equatable, Sendable {
    case retry
    case chooseNotebook
}

public struct AssistantStatus: Equatable, Sendable {
    public let message: String
    public let severity: AssistantStatusSeverity
    public let action: AssistantStatusAction?

    public init(
        message: String,
        severity: AssistantStatusSeverity,
        action: AssistantStatusAction? = nil
    ) {
        self.message = message
        self.severity = severity
        self.action = action
    }
}

public struct AssistantExchange: Identifiable, Equatable, Sendable {
    public let id: UUID
    public let question: String
    public let answer: String
    public let sources: [AssistantSearchResult]
    public let followUps: [String]
    public let isGeneralKnowledge: Bool
    public let mode: AssistantRequestMode
    public let phase: AssistantExchangePhase
    public let outcome: AssistantExchangeOutcome
    public let preliminaryResult: AssistantPreliminaryResultKind?
    public let summaryProvenance: AssistantSummaryProvenance?
    public let task: AssistantTask?
    public let scope: AssistantScope?
    public let scopeTitle: String?

    public init(
        id: UUID = UUID(),
        question: String,
        answer: String,
        sources: [AssistantSearchResult] = [],
        followUps: [String] = [],
        isGeneralKnowledge: Bool = false,
        mode: AssistantRequestMode,
        phase: AssistantExchangePhase = .complete,
        outcome: AssistantExchangeOutcome = .content,
        preliminaryResult: AssistantPreliminaryResultKind? = nil,
        summaryProvenance: AssistantSummaryProvenance? = nil,
        task: AssistantTask? = nil,
        scope: AssistantScope? = nil,
        scopeTitle: String? = nil
    ) {
        self.id = id
        self.question = question
        self.answer = answer
        self.sources = sources
        self.followUps = followUps
        self.isGeneralKnowledge = isGeneralKnowledge
        self.mode = mode
        self.phase = phase
        self.outcome = outcome
        self.preliminaryResult = preliminaryResult
        self.summaryProvenance = summaryProvenance
        self.task = task
        self.scope = scope
        self.scopeTitle = scopeTitle
    }
}

/// Keeps model-only citation identifiers out of presentation text. Source
/// anchors remain structured data and are rendered by the references UI.
enum AssistantAnswerSanitizer {
    private static let minimumDeduplicatedLineLength = 24
    private static let citationLabelPattern =
        #"(?i)^\s*(?:(?::\^|s|#)\d{1,3}|(?:source|citation|ref(?:erence)?|id)\s*(?:[:#=\-]\s*)?(?:\d{1,3}|(?=[a-z0-9_-]*[0-9_])[a-z0-9_-]{2,128}))\s*$"#
    private static let citationPatterns = [
        #"(?i)\[\s*\^\d{1,3}\s*\]"#,
        // Labeled prose such as `[source code]` and `(reference
        // implementation)` is semantic content, not a citation. A generic
        // label is removable only when its payload is numeric or visibly
        // ID-shaped (contains a digit or underscore). Exact app-owned IDs are
        // removed separately below, so this conservative rule loses no known
        // citation while protecting ordinary language.
        #"(?i)(?<![\p{L}\p{N}_])\[\s*(?:(?::\^|s|#)\d{1,3}|(?:source|citation|ref(?:erence)?|id)\s*(?:[:#=\-]\s*)?(?:=[a-z0-9_-]*[0-9_])[a-z0-9_-]{2,128})\s*\]"#,
        #"(?i)\s*\(\s*(?:source|citation|ref(?:erence)?|id)\s*(?:[:#=\-]\s*)?(?:=[a-z0-9_-]*[0-9_])[a-z0-9_-]{2,128})\s*\)"#,
        #"(?i)\s*\[{\?\{?\s*(?:source|citation|ref(?:erence)?|id)\s*(?::\s*[:#=\-]?\s*[a-z0-9_-]{0,128})?(?:\s*\})?)"#,
        #"(?i)\s*<\s*/?s*(?:source|citation|ref(?:erence)?)[^\n]{0,160}?/?>"#,
    ]

    private static let unfinishedStreamingPatterns = [
        // A terminal parenthesis/brace can still become a model-only citation.
        // Buffer the opener and every prefix of the supported labels so none
        // of that wrapper flashes before a numeric/ID payload proves it is
        // metadata. Once a complete label is present, hold its first compact
        // payload token until the wrapper closes: a late digit or underscore
        // can otherwise turn visible natural-looking text into an internal ID
        // and force the cumulative stream to retract it.
        #"(?i)\s*(?:[\[]\s*|\(\s*|\{\s*)?(?:s(?:(?:o(?:u(?:r(?:c(?:e)?)?)?)?)?)?|c(?:i(?:t(?:a(?:t(?:i(?:o(?:n)?)?)?)?)?)?)?|r(?:e(?:f(?:(?:e(?:r(?:e(?:n(?:c(?:e)?)?)?)?)?)?)?)?)?|i(?:d)?)?$"#,
        #"(?i)\s*[\[ []\s*(?:(?::\^|s|#)\d{0,3}|(?:source|citation|ref(?:erence)?|id)(?:\s*[:#=\-]?\s*[a-z0-9_-]{0,128})?)?$"#,
        #"(?i)\s*\(\s*(?:source|citation|ref(?:erence)?|id)(?:\s*[:#=\-]?\s*[a-z0-9_-]{0,128})?$"#,
        #"(?i)\s*\[{\?\{?\s*(?:source|citation|ref(?:erence)?|id)(?:\s*[:#=\-]?\s*[a-z0-9_-]{0,128})?$"#,
        #"(?i)\s*<\s*/?s*(?:source|citation|ref(?:erence)?)[^\n]{0,160}$"#,
    ]

    /// Typed generation uses numeric evidence/source slots internally. Keep
    /// the semantic noun while removing only the implementation suffix, so a
    /// cumulative stream remains forward-only (`EvidenceS…` never flashes an
    /// internal identifier and never has to retract `Evidence`).
    private static let completeInternalSlotPattern =
        #"(?i)\b(evidence|source)\s*slots?\s*(?:[:#=\-]\s*)?(?:\[\s*(?:\d{1,3}(?:,\s*\d{1,3}){0,7})\s*\]|\d{1,3}(?:,\s*\d{1,3}){0,7})"#
    private static let unfinishedInternalSlotPatterns = [
        #"(?i)\b(?:e(?:v(?:i(?:d(?:e(?:n(?:c(?:e)?)?)?)?)?)?)?|s(?:o(?:u(?:r(?:c(?:e)?)?)?)?)?)?\s+$"#,
        #"(?i)\b(?:evidence|source)\s+$"#,
        #"(?i)\b(?:evidence|source)\s+s(?:l(?:o(?:t(?:(?:s)?)?)?)?)?(?:\s*[:#=\-]\s*(?:\[\s*)?(?:\d{0,3}(?:,\s*\d{0,3})*)?)?$"#,
        #"\b(?:[Ee]vidence|[Ss]ource)S(?:l(?:o(?:t(?:(?:s)?)?)?)?)?(?:\s*[:#=\-]\s*(?:\[\s*)?(?:\d{0,3}(?:,\s*\d{0,3})*)?)?$"#,
        #"(?i)\b(?:evidence|source)sl(?:o(?:t(?:(?:s)?)?)?)?(?:\s*[:#=\-]\s*(?:\[\s*)?(?:\d{0,3}(?:,\s*\d{0,3})*)?(?:\s*\])?)?$"#,
        #"(?i)\b(?:evidence|source)\s*[:#=\-]\s*(?:\[\s*)?(?:\d{0,3}(?:,\s*\d{0,3})*)?$"#,
    ]
    private static let completeRepresentedSourceSlotsPattern =
        #"(?i)\b(represented)(?:source)slots?\s*(?:[:#=\-]\s*)?(?:\[\s*(?:\d{1,3}(?:,\s*\d{1,3}){0,127})\s*\]|\d{1,3}(?:,\s*\d{1,3}){0,127})"#
    private static let completeInsufficientEvidenceFieldPattern =
        #"(?i)\b(is)(?:insufficientevidence)\s*(?:[:#=\-]\s*)?(?:true|false)\b"#
    private static let completeLeadingInternalScaffoldPatterns = [
        #"(?i)^\s*(?:evidence|source)\s*slots?\s*(?:[:#=\-]\s*)?(?:\[\s*(?:\d{1,3}(?:,\s*\d{1,3}){0,7})\s*\]|\d{1,3}(?:,\s*\d{1,3}){0,7})"#,
        #"(?i)^\s*represented(?:source)slots?\s*(?:[:#=\-]\s*)?(?:\[\s*(?:\d{1,3}(?:,\s*\d{1,3}){0,127})\s*\]|\d{1,3}(?:,\s*\d{1,3}){0,127})"#,
        #"(?i)^\s*is(?:[:#=\-]\s*)?(?:true|false)\b"#,
    ]

    private static let completeInteriorInternalScaffoldPatterns = [
        #"(?i)(?<=[.!?,;:—])\s+(?:evidence|source)slots?\s*(?:[:#=\-]\s*)?(?:\[\s*(?:\d{0,3}(?:,\s*\d{0,3})*)?)?s*(?:[.,:;]\s*)?"#,
        #"(?i)\s+(?:evidence|source)slots?\s*[:#=\-]\s*(?:\[\s*(?:\d{0,3}(?:,\s*\d{0,3})*)?)?s*(?:[.,:;]\s*)?"#,
        #"(?i)\s+(?:evidence|source)\s+slots?\s*(?:(?:[:#=\-]\s*)?(?:\[\s*(?:\d{0,3}(?:,\s*\d{0,3})*)?)?|(?:\d{0,3}(?:,\s*\d{0,3})*)?)|\[\s*(?:\d{0,3}(?:,\s*\d{0,3})*)?)?s*\]?)?s*(?:[.,:;]\s*)?"#,
        #"(?i)\s*represented(?:source)slots?\s*(?:[:#=\-]\s*)?(?:\[\s*(?:\d{0,3}(?:,\s*\d{0,3})*)?)?s*\]?)?s*(?:[.,:;]\s*)?"#,
        #"(?i)\s*is(?:insufficientevidence)\s*(?:[:#=\-]\s*)?(?:true|false)\b\s*(?:[.,:;]\s*)?"#,
        // A bare, contiguous contract field between sentence separators is
        // never user-facing prose, even when the model omitted its value.
        // Complete valued forms run first so their colon/value cannot remain.
        #"(?i)\s+(?:evidence|source)slots?\s*[.!?,;—]\s*"#,
        #"(?i)\s+representedSourceSlots\s*[.!?,;—]\s*"#,
        #"(?i)\s+isInsufficientEvidence\s*[.!?,;—]\s*"#,
    ]

    private static let trailingTypedInternalScaffoldPatterns = [
        // Complete values are self-identifying schema fields. Matching them
        // after ordinary whitespace also lets fixed-point cleanup remove an
        // adjacent sequence in either order.
        #"(?i)\s*\b(?:evidence|source)\s*slots?\s*(?:[:#=\-]\s*)?(?:\[\s*(?:\d{0,3}(?:,\s*\d{0,3})*)?)?s*\])?s*[.,:;]?\s*$"#,
        #"(?i)\s*\brepresented(?:source)slots?\s*(?:[:#=\-]\s*)?(?:\[\s*(?:\d{0,3}(?:,\s*\d{0,3})*)?)?s*\])?s*[.,:;]?\s*$"#,
        #"(?i)\s*\bbis(?:insufficientevidence)\s*(?:[:#=\-]\s*)?(?:true|false)\b\s*[.,:;]?\s*$"#,
        // Exact camel-cased contract fields are unambiguous even when the
        // model appends them directly after ordinary prose. Code-shaped
        // assignment and statement lines bypass prose sanitation separately.
        #"\s+\b(?:[Ee]vidence|[Ss]ource)Slots?\s*(?:[:#=\-]\s*(?:\[\s*)?)?s*$"#,
        #"(?i)\s+\brepresentedSourceSlots\s*(?:[:#=\-]\s*(?:\[\s*)?)?s*$"#,
        #"(?i)\s+\bbisInsufficientEvidence\s*(?:[:#=\-]\s*)?s*(?:t(?:r(?:u(?:e)?)?)?)?|f(?:a(?:l(?:s(?:e)?)?)?)?)?s*$"#,
        // A capital `S` after the natural noun marks the camel-cased field,
        // while lowercase plurals such as `sources` remain ordinary prose.
        #"(?i:^|(?<=[.!?,;:—]))\s*\b(?:[Ee]vidence|[Ss]ource)S(?:l(?:o(?:t(?:(?:s)?)?)?)?)?(?::\s*(?:\[\s*)?(?:[:#=\-]\s*)?(?:\[\s*)?s*$"#,
        // Lowercase/uppercase terminal prefixes become unambiguous once the
        // `sl` portion of `slots` has arrived.
        #"(?i)(?:^|(?<=[.!?,;:—]))\s*\b(?:evidence|source)sl(?:o(?:t(?:(?:s)?)?)?)?s*(?:[:#=\-]\s*)?(?:\[\s*)?s*$"#,
        // Spaced field names require a schema delimiter when no value arrived.
        #"(?i)(?:^|(?<=[.!?,;:—]))\s*\b(?:evidence|source)\s+slots?\s*[:#=\-]\s*(?:\[\s*)?s*$"#,
        #"(?i)(?:^|(?<=[.!?,;:—]))\s*\brepresenteds(?:o(?:u(?:r(?:c(?:e)?)?)?)?)?(?::\s*u(?:r(?:c(?:e)?)?)?|u(?:r(?:c(?:e(?:s(?:i(?:l(?:o(?:t(?:(?:s)?)?)?)?)?)?)?)?)?)?)?s*(?:[:#=\-]\s*)?(?:\[\s*)?s*$"#,
    ]

    private static let rawSourceIDPattern =
        #"(?i)\b(source)_[0-9a-f]{0,24}(?![a-z0-9_-])"#
    private static let codeIndexOpenSentinel = "\u{E120}"
    private static let codeIndexCloseSentinel = "\u{E121}"
    private static let trailingInternalFieldRules = [
        (
            name: "representedSourceSlots",
            stablePrefix: "represented",
            unfinishedMetadata:
                #"(?:\s*[:#=\-]?\s*(?:\[\s*)?(?:\d{0,3}(?:,\s*\d{0,3})*)?)?$"#
        ),
        (
            name: "isInsufficientEvidence",
            stablePrefix: "is",
            unfinishedMetadata:
                #"(?:\s*[:#=\-]?\s*(?:t(?:r(?:u(?:e)?)?)?)?|f(?:a(?:l(?:s(?:e)?)?)?)?)?$"#
        ),
    ]
    static func sanitize(
        _ value: String,
        removingSourceIDs sourceIDs: Set<String> = [],
        streaming: Bool = false,
        canonicalStudyDocument: Bool = false
    ) -> String {
        let orderedSourceIDs = sourceIDs.sorted(by: { $0.count > $1.count })
        // Strip a provider-authored reference appendix before field/citation
        // sanitation can erase its heading and orphan the duplicate rows.
        let referenceCleanedValue = removingTrailingModelReferenceSection(
            in: value,
            streaming: streaming
        )
        var result = AssistantMarkdownProjection.transformingProseOutsideFences(
            in: referenceCleanedValue
        ) { rawLine in
            if AssistantMarkdownProjection.plainCodeLineFlags(for: [rawLine])
                .first == true || isInternalFieldCodeLine(rawLine) {
                return rawLine
            }
            if rawLine.range(
                of: #"^\s{0,3}\[{[^\]]\n]+\]:\s*\S"#,
                options: .regularExpression
            ) != nil {
                // Preserve the structure until the Markdown projector removes
                // the complete definition. Stripping its label first would
                // leak the destination as ordinary answer text.
                return rawLine
            }
            return AssistantMarkdownProjection.transformingProseOutsideInlineCode(
                in: rawLine
            ) { proseSegment in
                var line = AssistantMarkdownProjection.removingLinks(
                    in: proseSegment
                ) { label in
                    orderedSourceIDs.contains(where: {
                        label.compare(
                            $0,
                            options: [.caseInsensitive, .diacriticInsensitive]
                        ) == .orderedSame
                    }) || label.range(
                        of: citationLabelPattern,
                        options: .regularExpression
                    ) != nil
                }
                line = protectingInternalFieldArrayAccess(in: line)
                line = removingTrailingTypedInternalScaffold(
                    in: line,
                    normalizesTerminalSeparator: streaming == false
                )
                line = removingCompleteInteriorInternalScaffolds(in: line)
                line = removingLeadingInternalScaffolds(in: line)
                for sourceID in orderedSourceIDs {
                    // Remove complete app-owned citation wrappers before their raw
                    // identifier. Exact app-owned IDs are also redacted once more
                    // after semantic projection so inline/fenced code cannot leak
                    // internal metadata.
                    for wrappedSourceID in [
                        "{{\(sourceID)}}",
                        "[\(sourceID)]",
                        " [\(sourceID)] ",
                        "((\(sourceID)))",
                        "{\\\(sourceID)}",
                    ] {
                        line = line.replacingOccurrences(
                            of: wrappedSourceID,
                            with: "",
                            options: [.caseInsensitive, .literal]
                        )
                    }
                }
                line = line.replacingOccurrences(
                    of: completeInternalSlotPattern,
                    with: "$1",
                    options: .regularExpression
                )
                line = line.replacingOccurrences(
                    of: completeRepresentedSourceSlotsPattern,
                    with: "$1",
                    options: .regularExpression
                )
                line = line.replacingOccurrences(
                    of: completeInsufficientEvidenceFieldPattern,
                    with: "$1",
                    options: .regularExpression
                )
                line = line.replacingOccurrences(
                    of: #"(?i)\b(source|citation|ref(?:erence)?)\s*\[\s*\[\s*\d{1,3}\s*\]"#,
                    with: "$1",
                    options: .regularExpression
                )
                for pattern in citationPatterns {
                    line = line.replacingOccurrences(
                        of: pattern,
                        with: "",
                        options: .regularExpression
                    )
                }
                line = redactingTrailingInternalFieldPrefixes(
                    in: line,
                    hidesPrefixes: streaming
                )
                if streaming {
                    // Citation wrappers run first so their opening punctuation is
                    // buffered together with a partial `source` label. Internal
                    // slot cleanup would otherwise remove only the word and leave
                    // a visible `(` or `{` that the completed citation retracts.
                    for pattern in unfinishedStreamingPatterns {
                        line = line.replacingOccurrences(
                            of: pattern,
                            with: "",
                            options: .regularExpression
                        )
                    }
                    for pattern in unfinishedInternalSlotPatterns {
                        line = line.replacingOccurrences(
                            of: pattern,
                            with: "",
                            options: .regularExpression
                        )
                    }
                }
            line = line.replacingOccurrences(
                of: #"[ \t]+([{,.;:!?])"#,
                with: "$1",
                options: .regularExpression
            )
            line = line.replacingOccurrences(
                of: #"[ \t]{2,}"#,
                with: " ",
                options: .regularExpression
            )
            return restoringInternalFieldArrayAccess(in: line)
            }
        }
        result = removingTrailingModelReferenceSection(
            in: result,
            streaming: streaming
        )
        // Preserve the identifier shape until reference-section detection has
        // run. Otherwise `source_` first becomes a terminal `source`, which
        // streaming cleanup can mistake for the prefix of a `Sources:`
        // appendix. Redact before semantic de-duplication, then repeat at the
        // return boundary as defense in depth for projected code/Markdown.
        result = redactingExactSourceIDs(
            in: result,
            sourceIDs: orderedSourceIDs,
            hidesKnownPrefixes: true
        )
        if streaming, canonicalStudyDocument == false {
            result = bufferingRepeatedSemanticTail(in: result)
        }
        if canonicalStudyDocument == false {
            result = deduplicatingExactSemanticContent(in: result)
            if streaming,
            value.contains("\n"),
            result.split(separator: "\n", omittingEmptySubsequences: false)
                .last?
                .trimmingCharacters(in: .whitespaces)
                .hasPrefix("# ") == true {
                // Repetition buffering or de-duplication can leave a lone ATX
                // heading at the streaming boundary. Keep it line-terminated
                // so the projector does not reinterpret already-visible
                // content as an unfinished hash prefix and retract the answer.
                result.append("\n")
            }
        }
        if canonicalStudyDocument {
            // The typed Study contract already projects each generated prompt
            // and answer exactly once before numbering. Re-projecting here
            // would reinterpret literal code punctuation, while global prose
            // de-duplication could tear a multi-paragraph item apart.
            return redactingExactSourceIDs(
                in: result.trimmingCharacters(in: .newlines),
                sourceIDs: orderedSourceIDs,
                hidesKnownPrefixes: true
            )
        }
        // Foundation Models is instructed to return plain text, but model
        // instructions are not a security or presentation boundary. Project
        // any adversarial/legacy Markdown to visible semantic text before it
        // can enter the transcript, pipeline events, or an artifact cache.
        let projected = AssistantMarkdownProjection.streamingText(
            from: result,
            isFinal: streaming == false,
            preservesUnmatchedOperators: true
        )
        .trimmingCharacters(in: .newlines)
        return redactingExactSourceIDs(
            in: projected,
            sourceIDs: orderedSourceIDs,
            hidesKnownPrefixes: true
        )
    }

    ///  Narrowly preserves literal contract identifiers when they are clearly
    ///  used as code. Keeping this exception local avoids classifying arbitrary
    ///  prose assignments (which can still contain Markdown) as verbatim.
    private static func isInternalFieldCodeLine(_ rawLine: String) -> Bool {
        rawLine.trimmingCharacters(in: .whitespaces).range(
            of:
                #"^(?:(?:evidence|source)Slots?|representedSourceSlots|isInsufficientEvidence)\s*(?:(?:=|:=|\+=|-=|\*=|/=)\s*.+|;)\s*$"#,
            options: [.regularExpression, .caseInsensitive]
        ) != nil
    }

    private static func protectingInternalFieldArrayAccess(
        in value: String
    ) -> String {
        value.replacingOccurrences(
            of: #"(?i)\b((?:evidence|source)Slots?|representedSourceSlots)\[(\d{1,3})\]"#,
            with: "$1\(codeIndexOpenSentinel)$2\(codeIndexCloseSentinel)",
            options: .regularExpression
        )
    }

    private static func restoringInternalFieldArrayAccess(
        in value: String
    ) -> String {
        value
            .replacingOccurrences(of: codeIndexOpenSentinel, with: "[")
            .replacingOccurrences(of: codeIndexCloseSentinel, with: "]")
    }

    private static func removingTrailingModelReferenceSection(
        in value: String,
        streaming: Bool
    ) -> String {
        let lines = value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard lines.isEmpty == false else { return value }

        let inferredCode = AssistantMarkdownProjection.plainCodeLineFlags(for: lines)
        var verbatim = Array(repeating: false, count: lines.count)
        var activeFence: (marker: Character, length: Int)?
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if let fence = activeFence {
                verbatim[index] = true
                if AssistantMarkdownParser.isFenceClosing(
                    trimmed,
                    marker: fence.marker,
                    minimumLength: fence.length
                ) {
                    activeFence = nil
                }
            } else if let fence = AssistantMarkdownParser.fenceOpening(in: trimmed) {
                verbatim[index] = true
                activeFence = (fence.marker, fence.length)
            } else {
                verbatim[index] = inferredCode[index]
            }
        }

        let inlineAppendixPattern =
            #"(?i)(?<=[.!?;])\s+(?:\*{1,2}|_{1,2})?(?:sources?|references?|citations?)\s*:\s*\s*(?:\*{1,2}|_{1,2})?.*$"#
        for index in lines.indices.reversed() where verbatim[index] == false {
            guard let appendixRange = lines[index].range(
                of: inlineAppendixPattern,
                options: .regularExpression
            ), lines.indices.allSatisfy({ candidate in
                candidate <= index || verbatim[candidate] == false
            }) else { continue }
            var retained = Array(lines[..<index])
            retained.append(String(lines[index][..<appendixRange.lowerBound]))
            return retained.joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
        }
        if let lastIndex = lines.indices.last,
        verbatim[lastIndex] == false {
            if streaming,
            let suffixRange = lines[lastIndex].range(
                of: #"(?i)(?<=[.!?;])\s+[*_~A-Za-z: \t]*$"#,
                options: .regularExpression
            ) {
                let suffix = lines[lastIndex][suffixRange]
                    .filter { $0.isWhitespace == false && "*_~".contains($0) == false }
                    .lowercased()
                let headingPrefixes = [
                    "source:", "sources:",
                    "reference:", "references:",
                    "citation:", "citations:",
                ]
                if suffix.isEmpty == false,
                headingPrefixes.contains(where: { $0.hasPrefix(suffix) }) {
                    var retained = lines
                    retained[lastIndex] = String(lines[lastIndex][..<suffixRange.lowerBound])
                    return retained.joined(separator: "\n")
                        .trimmingCharacters(in: .newlines)
                }
            }
        }

    func normalizedHeadingLine(_ raw: String) -> String {
        AssistantMarkdownProjection.streamingText(
            from: raw,
            isFinal: true,
            preservesUnmatchedOperators: true
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased()
    }

    let headings = [
        "source", "sources",
        "reference", "references",
        "citation", "citations",
    ]
    func beginsReferenceHeading(_ raw: String) -> Bool {
        let line = normalizedHeadingLine(raw).replacingOccurrences(
            of: #"\s+:"#,
            with: ":",
            options: .regularExpression
        )
        return headings.contains { heading in
            line == heading || line.hasPrefix("\(heading):")
        }
    }

    for index in lines.indices.reversed() where verbatim[index] == false {
        guard beginsReferenceHeading(lines[index]) else { continue }
        let hasPriorAnswer = lines[..<index].indices.contains { candidate in
            lines[candidate]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
        }
        guard hasPriorAnswer,
              lines.indices.allSatisfy({ candidate in
                candidate < index || verbatim[candidate] == false
              }) else { continue }
        return lines[..<index]
            .joined(separator: "\n")
            .trimmingCharacters(in: .newlines)
    }

    if streaming,
    let lastIndex = lines.indices.last,
    verbatim[lastIndex] == false {
        let hasPriorAnswer = lines[..<lastIndex].indices.contains { candidate in
            lines[candidate]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty == false
        }
        var candidate = lines[lastIndex]
            .trimmingCharacters(in: .whitespaces)
        while candidate.hasPrefix("#") { candidate.removeFirst() }
        candidate = candidate.trimmingCharacters(in: .whitespaces)
        candidate = candidate.trimmingCharacters(in: CharacterSet(charactersIn: "*_"))
        let lowered = candidate.lowercased().replacingOccurrences(
            of: #"\s+:"#,
            with: ":",
            options: .regularExpression
        )
        let headingPrefixes = [
            "source:", "sources:",
            "reference:", "references:",
            "citation:", "citations:",
        ]
        if hasPriorAnswer,
        lowered.isEmpty == false,
        headingPrefixes.contains(where: { $0.hasPrefix(lowered) }) {
            return lines[..<lastIndex]
                .joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
        }
    }
    return value
}

    private static func removingCompleteInteriorInternalScaffolds(
        in value: String
    ) -> String {
        var result = value
        for pattern in completeInteriorInternalScaffoldPatterns {
            result = result.replacingOccurrences(
                of: pattern,
                with: " ",
                options: .regularExpression
            )
        }
        return result
    }

    private static func removingTrailingTypedInternalScaffold(
        in value: String,
        normalizesTerminalSeparator: Bool
    ) -> String {
        var result = value
        var previous: String
        repeat {
            previous = result
            for pattern in trailingTypedInternalScaffoldPatterns {
                result = result.replacingOccurrences(
                    of: pattern,
                    with: "",
                    options: .regularExpression
                )
            }
            result = removingBareTrailingInternalFieldPrefix(in: result)
        } while result != previous
        if result != value {
            result = result.trimmingCharacters(in: .whitespaces)
            if normalizesTerminalSeparator,
            let terminal = result.last,
            ",;:".contains(terminal) {
                result.removeLast()
                result = result.trimmingCharacters(in: .whitespaces)
                if result.isEmpty == false { result.append(".") }
            }
        }
        return result
    }

    private static func removingBareTrailingInternalFieldPrefix(
        in value: String
    ) -> String {
        let valueWithoutMetadata = value.replacingOccurrences(
            of: #"\s*[:#\-]\s*((?:t(?:r(?:u(?:e)?)?)?)|f(?:a(?:l(?:s(?:e)?)?)?)?)\s*$"#,
            with: "",
            options: .regularExpression
        )
        guard let tokenRange = valueWithoutMetadata.range(
            of: #"[A-Za-z]+$"#,
            options: .regularExpression
        ) else { return value }

        let token = valueWithoutMetadata[tokenRange].lowercased()
        guard trainingInternalFieldRules.contains(where: { rule in
            token.count > rule.stablePrefix.count
            && rule.name.lowercased().hasPrefix(token)
        }) else { return value }

        let prefix = valueWithoutMetadata[..<tokenRange.lowerBound]
        let trimmedPrefix = prefix.trimmingCharacters(in: .whitespaces)
        guard trimmedPrefix.isEmpty
            || trimmedPrefix.last.map({ ",!?,;:—".contains($0) }) == true else {
            return value
        }
        return String(prefix)
    }

    private static func removingLeadingInternalScaffolds(
        in value: String
    ) -> String {
        var result = value
        while true {
            let next = removingLeadingInternalScaffold(in: result)
            guard next != result else { return result }
            result = next
        }
    }

    private static func removingLeadingInternalScaffold(in value: String) -> String {
        for pattern in completeLeadingInternalScaffoldPatterns {
            guard let fieldRange = value.range(
                of: pattern,
                options: .regularExpression
            ) else { continue }

            let field = String(value[fieldRange])
            var tail = String(value[fieldRange.upperBound...])
            let trimmedTail = tail.trimmingCharacters(in: .whitespaces)
            let isEntireLine = trimmedTail.isEmpty
            let isTypedField = field.range(
                of: #"(?i)(?:evidence|source)slots?|representedSourceSlots|isInsufficientEvidence"#,
                options: .regularExpression
            ) != nil
            let hasSchemaDelimiter = field.contains("[")
                || field.contains(":")
                || field.contains("=")
                || field.contains("#")
            let hasSentenceSeparator = trimmedTail.first.map {
                ".,;!?—".contains($0)
            } ?? false
            guard isEntireLine || isTypedField || hasSchemaDelimiter
                || hasSentenceSeparator else {
                return value
            }

            tail = trimmedTail
            if let separator = tail.first,
                ".,;:!?".contains(separator) {
                tail.removeFirst()
            }
            tail = tail.trimmingCharacters(in: .whitespaces)
            return tail
        }
        return value
    }

    private static func redactingTrailingInternalFieldPrefixes(
        in value: String,
        hidesPrefixes: Bool
    ) -> String {
        var result = value
        for rule in trailingInternalFieldRules {
            let completeFieldAtTail = #"(?i)\b"#
                + rule.name
                + rule.unfinishedMetadata
                + "$"
            if result.range(
                of: completeFieldAtTail,
                options: .regularExpression
            ) != nil {
                result = result.replacingOccurrences(
                    of: completeFieldAtTail,
                    with: hidesPrefixes ? "" : rule.stablePrefix,
                    options: .regularExpression
                )
                continue
            }

            guard let tokenRange = result.range(
                of: #"[A-Za-z]+$"#,
                options: .regularExpression
            ) else { continue }
            let token = result[tokenRange].lowercased()
            let field = rule.name.lowercased()
            guard field.hasPrefix(token) else { continue }
            if hidesPrefixes == false,
            token.count < rule.stablePrefix.count {
                continue
            }
            result.replaceSubrange(
                tokenRange,
                with: hidesPrefixes ? "" : rule.stablePrefix
            )
        }
        return result
    }

    private static func redactingExactSourceIDs(
        in value: String,
        sourceIDs: [String],
        hidesKnownPrefixes: Bool
    ) -> String {
        // Inline/fenced code delimiters have already been projected away at
        // this boundary. Apply the shape-based redaction again so wrapping a
        // complete or truncated internal ID as code cannot bypass Summary's
        // no-known-ID path.
        let genericRedacted = value.replacingOccurrences(
            of: rawSourceIDPattern,
            with: "$1",
            options: .regularExpression
        )
        let exactRedacted = sourceIDs.reduce(into: genericRedacted) { result, sourceID in
            result = result.replacingOccurrences(
                of: sourceID,
                with: sourceID.lowercased().hasPrefix("source_")
                ? "source"
                : "",
                options: [.caseInsensitive, .literal]
            )
        }
        guard hidesKnownPrefixes else { return exactRedacted }
        return redactingKnownSourceIDPrefixes(
            in: exactRedacted,
            sourceIDs: sourceIDs
        )
    }

    private static func redactingKnownSourceIDPrefixes(
        in value: String,
        sourceIDs: [String]
    ) -> String {
        let known = sourceIDs.map { sourceID -> (id: String, minimum: Int) in
            let lowered = sourceID.lowercased()
            if let separator = lowered.firstIndex(where: { $0 == "_" || $0 == "-" }) {
                return (lowered, lowered.distance(from: lowered.startIndex, to: separator) + 1)
            }
            return (lowered, min(8, lowered.count))
        }
        var output = ""
        var cursor = value.startIndex
        while cursor < value.endIndex {
            let character = value[cursor]
            guard character.isLetter || character.isNumber
                || character == "_" || character == "-" else {
                output.append(character)
                cursor = value.index(after: cursor)
                continue
            }
            let tokenStart = cursor
            while cursor < value.endIndex {
                let current = value[cursor]
                guard current.isLetter || current.isNumber
                    || current == "_" || current == "-" else { break }
                cursor = value.index(after: cursor)
            }
            let token = String(value[tokenStart..<cursor])
            let loweredToken = token.lowercased()
            if let match = known.first(where: {
                loweredToken.count >= $0.minimum && $0.id.hasPrefix(loweredToken)
            }) {
                output += match.id.hasPrefix("source_") ? "source" : ""
            } else {
                output += token
            }
        }
        return output
    }

    /// Normalizes presentation-only list chrome for semantic comparison while
    /// leaving the originally generated line untouched for publication.
    /// `numberedBody` deliberately rejects four-or-more digit prefixes, so
    /// factual years such as `2024. Revenue grew` remain distinct content.
    private static func normalizedSemanticComparison(_ value: String) -> String {
        var normalized = value.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
        for marker in ["• ", "- ", "* ", "+ "] where normalized.hasPrefix(marker) {
            normalized.removeFirst(marker.count)
            break
        }
        if let numberedBody = AssistantMarkdownParser.numberedBody(in: normalized) {
            normalized = numberedBody.split(whereSeparator: \.isWhitespace)
                .joined(separator: " ")
        }
        return normalized
    }

    private static func isGloballyDeduplicableSemanticLine(
        raw: String,
        comparisonKey: String
    ) -> Bool {
        let trimmedRaw = raw.trimmingCharacters(in: .whitespaces)
        if trimmedRaw.hasPrefix("• ")
            || AssistantMarkdownParser.bulletBody(in: trimmedRaw) != nil
            || AssistantMarkdownParser.numberedBody(in: trimmedRaw) != nil {
            return true
        }
        if comparisonKey.count >= minimumDeduplicatedLineLength {
            return true
        }

        var ending = comparisonKey.trimmingCharacters(in: .whitespaces)
        let sentenceClosers: Set<Character> = [
            "\"", "'", "'", "\"", ")", "]", "}", "*", "_", "~", "'",
        ]
        while let last = ending.last, sentenceClosers.contains(last) {
            ending.removeLast()
        }
        guard let terminal = ending.last else { return false }
        return ".!?…".contains(terminal)
    }

    /// Holds an ordinal while it is still only a one-to-three digit marker.
    /// Once the body diverges from prior prose, the reveal layer can publish
    /// the complete line forward-only; if it repeats prior prose, semantic
    /// holdback removes it without ever flashing the ordinal.
    private static func isPotentialNumberedMarkerPrefix(_ value: String) -> Bool {
        let candidate = value.trimmingCharacters(in: .whitespaces)
        guard candidate.isEmpty == false else { return false }

        var cursor = candidate.startIndex
        while cursor < candidate.endIndex, candidate[cursor].isNumber {
            cursor = candidate.index(after: cursor)
        }
        let digitCount = candidate.distance(from: candidate.startIndex, to: cursor)
        guard (1...3).contains(digitCount) else { return false }
        if cursor == candidate.endIndex { return true }
        guard candidate[cursor] == "," || candidate[cursor] == ")" else {
            return false
        }
        cursor = candidate.index(after: cursor)
        return candidate[cursor...].allSatisfy(\.isWhitespace)
    }

    /// Removes only exact, whitespace-normalized prose repetitions at final
    /// publication. Streaming snapshots are intentionally left untouched so
    /// their cumulative prefix remains stable, and fenced code is copied
    /// verbatim because repeated code lines may be semantically meaningful.
    static func deduplicatingExactSemanticContent(in value: String) -> String {
        let lines = value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let plainCodeLines = AssistantMarkdownProjection.plainCodeLineFlags(for: lines)
        var output: [String] = []
        var paragraph: [String] = []
        var seenParagraphs: Set<String> = []
        var seenLines: Set<String> = []
        var observedLines: Set<String> = []
        var activeFence: (marker: Character, length: Int)?

        func normalizedSemanticText(_ line: String) -> String {
            normalizedSemanticComparison(line)
        }

        func flushParagraph() {
            guard paragraph.isEmpty == false else { return }
            defer { paragraph.removeAll(keepingCapacity: true) }

            // Semantic projection is used only to compare content. Publishing
            // the projected comparison value here would make `sanitize`
            // project it a second time below, corrupting literals that came
            // from inline code (for example `__init__` and `*ptr`).
            let publicationLines = paragraph.map(deduplicatingConsecutiveSentences)
            let projectedParagraph = AssistantMarkdownProjection.streamingText(
                from: publicationLines.joined(separator: "\n"),
                preservesUnmatchedOperators: true
            )
            let paragraphKey = normalizedSemanticText(projectedParagraph)
            if paragraphKey.isEmpty {
                // A paragraph made entirely of structural Markdown metadata
                // (for example reference-link definitions) has no standalone
                // semantic projection, but the final whole-document pass still
                // needs it to resolve presentation that appeared earlier.
                output.append(contentsOf: publicationLines)
                return
            }

            guard seenParagraphs.insert(paragraphKey).inserted else { return }

            var previousNormalized: String?
            let filteredLines = publicationLines.compactMap { original -> String? in
                let semantic = AssistantMarkdownProjection.streamingText(
                    from: original,
                    preservesUnmatchedOperators: true
                )
                let normalized = normalizedSemanticText(semantic)
                // Structural syntax such as a Setext underline can project to
                // an empty comparison line. Retain it for the one final whole-
                // document projection, which will remove it correctly.
                guard normalized.isEmpty == false else { return original }
                defer { previousNormalized = normalized }
                if normalized == previousNormalized { return nil }
                if seenLines.contains(normalized) { return nil }
                let isGloballyDeduplicable = isGloballyDeduplicableSemanticLine(
                    raw: original,
                    comparisonKey: normalized
                )
                if isGloballyDeduplicable,
                    observedLines.contains(normalized) {
                    return nil
                }
                observedLines.insert(normalized)
                guard isGloballyDeduplicable else {
                    return original
                }
                seenLines.insert(normalized)
                return original
            }
            guard filteredLines.isEmpty == false else { return }
            output.append(contentsOf: filteredLines)
        }

        for (lineIndex, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let openFence = activeFence {
                output.append(line)
                if AssistantMarkdownParser.isFenceClosing(
                    trimmed,
                    marker: openFence.marker,
                    minimumLength: openFence.length
                ) {
                    activeFence = nil
                }
                continue
            }

            if let fence = AssistantMarkdownParser.fenceOpening(in: trimmed) {
                flushParagraph()
                activeFence = (fence.marker, fence.length)
                output.append(line)
            } else if plainCodeLines[lineIndex] {
                flushParagraph()
                output.append(line)
            } else if trimmed.isEmpty {
                flushParagraph()
                if output.isEmpty == false, output.last?.isEmpty == false {
                    output.append("")
                }
            } else {
                paragraph.append(line)
            }
        }
        flushParagraph()

        while output.last?.isEmpty == true {
            output.removeLast()
        }
        return output.joined(separator: "\n")
    }

    /// Holds only a trailing prose fragment that is still an exact semantic
    /// prefix of content immediately before it. When the fragment completes as
    /// a duplicate, final de-duplication removes it; when it diverges, the full
    /// suffix can be revealed without changing any already-visible character.
    /// Fenced and strongly inferred code never enters this path.
    private static func bufferingRepeatedSemanticTail(in value: String) -> String {
        let lines = value
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        guard let lastIndex = lines.indices.last,
              lines[lastIndex].isEmpty == false else { return value }
        let codeLines = AssistantMarkdownProjection.plainCodeLineFlags(for: lines)
        var activeFence: (marker: Character, length: Int)?
        var verbatim = Array(repeating: false, count: lines.count)
        for index in lines.indices {
            let trimmed = lines[index].trimmingCharacters(in: .whitespaces)
            if let fence = activeFence {
                verbatim[index] = true
                if AssistantMarkdownParser.isFenceClosing(
                    trimmed,
                    marker: fence.marker,
                    minimumLength: fence.length
                ) {
                    activeFence = nil
                }
            } else if let fence = AssistantMarkdownParser.fenceOpening(in: trimmed) {
                verbatim[index] = true
                activeFence = (fence.marker, fence.length)
            } else {
                verbatim[index] = codeLines[index]
            }
        }
        guard verbatim[lastIndex] == false else { return value }

        func semanticKey(_ raw: String) -> String {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            let comparisonValue = trimmed.hasPrefix("# ")
                ? raw + "\n"
                : raw
            let key = AssistantMarkdownProjection.streamingText(
                from: comparisonValue,
                isFinal: false,
                preservesUnmatchedOperators: true
            )
            return normalizedSemanticComparison(key)
        }

        // First protect a repeated trailing sentence within the last line.
        let bufferedLastLine = bufferingRepeatedSentenceTail(
            in: lines[lastIndex],
            semanticKey: semanticKey
        )
        if bufferedLastLine != lines[lastIndex] {
            var result = lines
            result[lastIndex] = bufferedLastLine
            return result.joined(separator: "\n")
        }

        if lastIndex > lines.startIndex,
            isPotentialNumberedMarkerPrefix(lines[lastIndex]) {
            return lines[..<lastIndex]
                .joined(separator: "\n")
                .trimmingCharacters(in: .newlines)
        }

        let lastKey = semanticKey(lines[lastIndex])
        guard lastKey.isEmpty == false else { return value }

        // Then protect a trailing line that is still a prefix of adjacent
        // prose, or of any earlier globally de-duplicable line. Final cleanup
        // removes adjacent repetitions regardless of their length, so the
        // streaming horizon must include short headings and labels too.
        if lastIndex > lines.startIndex {
            for previous in lines.indices where previous < lastIndex {
                guard verbatim[previous] == false,
                    lines[previous]
                        .trimmingCharacters(in: .whitespaces)
                        .isEmpty == false else { continue }
                let previousKey = semanticKey(lines[previous])
                let matchesFinalDeduplicationHorizon = previous == lastIndex - 1
                    || isGloballyDeduplicableSemanticLine(
                        raw: lines[previous],
                        comparisonKey: previousKey
                    )
                    || isGloballyDeduplicableSemanticLine(
                        raw: lines[lastIndex],
                        comparisonKey: lastKey
                    )
                if previousKey.isEmpty == false,
                    matchesFinalDeduplicationHorizon,
                    previousKey.hasPrefix(lastKey) {
                    return lines[..<lastIndex]
                        .joined(separator: "\n")
                        .trimmingCharacters(in: .newlines)
                }
            }
        }

        // A repeated paragraph may span several individually distinct lines.
        // Hold its entire trailing prefix until it either diverges or can be
        // removed as one exact semantic paragraph.
        var currentParagraphStart = lastIndex
        while currentParagraphStart > lines.startIndex,
                lines[currentParagraphStart - 1]
                .trimmingCharacters(in: .whitespaces)
                .isEmpty == false {
            currentParagraphStart -= 1
        }
        if currentParagraphStart > lines.startIndex,
            verbatim[currentParagraphStart...lastIndex].contains(true) == false {
            let currentParagraph = lines[currentParagraphStart...lastIndex]
                .joined(separator: "\n")
            let currentKey = semanticKey(currentParagraph)
            if currentKey.isEmpty == false {
                var paragraphEnd = currentParagraphStart - 1
                while paragraphEnd >= lines.startIndex {
                    while paragraphEnd >= lines.startIndex,
                            lines[paragraphEnd]
                            .trimmingCharacters(in: .whitespaces)
                            .isEmpty {
                        if paragraphEnd == lines.startIndex {
                            paragraphEnd = -1
                            break
                        }
                        paragraphEnd -= 1
                    }
                    guard paragraphEnd >= lines.startIndex else { break }
                    var paragraphStart = paragraphEnd
                    while paragraphStart > lines.startIndex,
                            lines[paragraphStart - 1]
                            .trimmingCharacters(in: .whitespaces)
                            .isEmpty == false {
                        paragraphStart -= 1
                    }
                    if verbatim[paragraphStart...paragraphEnd].contains(true) == false {
                        let previousKey = semanticKey(
                            lines[paragraphStart...paragraphEnd]
                            .joined(separator: "\n")
                        )
                        if previousKey.isEmpty == false,
                            previousKey.hasPrefix(currentKey) {
                            return lines[..<currentParagraphStart]
                                .joined(separator: "\n")
                                .trimmingCharacters(in: .newlines)
                        }
                    }
                    if paragraphStart == lines.startIndex { break }
                    paragraphEnd = paragraphStart - 1
                }
            }
        }
        return value
    }
    private static func bufferingRepeatedSentenceTail(
        in line: String,
        semanticKey: (String) -> String
    ) -> String {
        let characters = Array(line)
        let terminators: Set<Character> = [".", "!", "?", "\u{2026}"]
        let closers: Set<Character> = [
            "\"", "'", "\u{2018}", "\u{201C}", ")", "]", "}", "*", "_", "~", "`",
        ]
        var ranges: [Range<Int>] = []
        var segmentStart = 0
        while segmentStart < characters.count,
              characters[segmentStart].isWhitespace {
            segmentStart += 1
        }
        var index = segmentStart
        while index < characters.count {
            guard terminators.contains(characters[index]) else {
                index += 1
                continue
            }
            var boundary = index
            while boundary + 1 < characters.count,
                  closers.contains(characters[boundary + 1]) {
                boundary += 1
            }
            let next = boundary + 1
            guard next == characters.count || characters[next].isWhitespace else {
                index += 1
                continue
            }
            ranges.append(segmentStart..<next)
            segmentStart = next
            while segmentStart < characters.count,
                  characters[segmentStart].isWhitespace {
                segmentStart += 1
            }
            index = segmentStart
        }
        if segmentStart < characters.count {
            ranges.append(segmentStart..<characters.count)
        }
        guard ranges.count >= 2 else { return line }
        let keys = ranges.map { semanticKey(String(characters[$0])) }

        // Hold a trailing sentence sequence while it is an exact prefix of
        // the immediately preceding block. This covers both A-A and longer
        // model loops such as A-B-A-B without publishing A-B and retracting it
        // during terminal de-duplication.
        for suffixStart in 1..<ranges.count {
            let suffixCount = ranges.count - suffixStart
            guard suffixCount <= suffixStart else { continue }
            for blockLength in suffixCount...suffixStart {
                let blockStart = suffixStart - blockLength
                var matches = true
                for offset in 0..<suffixCount {
                    let earlier = keys[blockStart + offset]
                    let current = keys[suffixStart + offset]
                    let isTrailingFragment = offset == suffixCount - 1
                    if earlier.isEmpty || current.isEmpty
                        || (isTrailingFragment
                            ? earlier.hasPrefix(current) == false
                            : earlier != current) {
                        matches = false
                        break
                    }
                }
                if matches {
                    // Keep the separator after the settled sentence. Without
                    // it, punctuation such as `!` becomes a terminal Markdown
                    // image opener and can be reinterpreted by projection.
                    return String(characters[..<ranges[suffixStart].lowerBound])
                }
            }
        }
        return line
    }

    /// Collapses only adjacent, exactly repeated complete sentences. This
    /// closes the common one-line model repetition without fuzzy matching or
    /// touching fenced code, which bypasses paragraph processing entirely.
    private static func deduplicatingConsecutiveSentences(in line: String) -> String {
        let hadTrailingWhitespace = line.last?.isWhitespace == true
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty == false else { return line }
        let characters = Array(trimmed)
        let terminators: Set<Character> = [".", "!", "?", "\u{2026}"]
        let closers: Set<Character> = [
            "\"", "'", "\u{2018}", "\u{201C}", ")", "]", "}", "*", "_", "~", "`",
        ]
        var segments: [String] = []
        var segmentStart = 0
        var index = 0

        while index < characters.count {
            guard terminators.contains(characters[index]) else {
                index += 1
                continue
            }
            var boundary = index
            while boundary + 1 < characters.count,
                  closers.contains(characters[boundary + 1]) {
                boundary += 1
            }
            let next = boundary + 1
            guard next == characters.count || characters[next].isWhitespace else {
                index += 1
                continue
            }
            let segment = String(characters[segmentStart...boundary])
                .trimmingCharacters(in: .whitespaces)
            if segment.isEmpty == false { segments.append(segment) }
            segmentStart = next
            while segmentStart < characters.count, characters[segmentStart].isWhitespace {
                segmentStart += 1
            }
            index = segmentStart
        }
        if segmentStart < characters.count {
            let tail = String(characters[segmentStart...])
                .trimmingCharacters(in: .whitespaces)
            if tail.isEmpty == false { segments.append(tail) }
        }
        guard segments.count > 1 else { return line }

        func semanticKey(_ segment: String) -> String {
            normalizedSemanticComparison(
                AssistantMarkdownProjection.streamingText(
                    from: segment,
                    preservesUnmatchedOperators: true
                )
            )
        }

        var result: [String] = []
        var previousKey: String?
        for segment in segments {
            let key = semanticKey(segment)
            if key == previousKey { continue }
            result.append(segment)
            previousKey = key
        }

        // Collapse exact adjacent sentence blocks wherever they occur. A-B-A
        // remains meaningful; A-B-A-B (including A-B-A-B-C) is a model loop.
        var blockStart = 0
        while blockStart < result.count {
            var removedRepeatedBlock = false
            let maximumBlockLength = (result.count - blockStart) / 2
            if maximumBlockLength > 0 {
                for blockLength in stride(
                    from: maximumBlockLength,
                    through: 1,
                    by: -1
                ) {
                    let first = result[blockStart..<(blockStart + blockLength)]
                        .map(semanticKey)
                    let secondStart = blockStart + blockLength
                    let second = result[secondStart..<(secondStart + blockLength)]
                        .map(semanticKey)
                    guard first == second else { continue }
                    result.removeSubrange(secondStart..<(secondStart + blockLength))
                    removedRepeatedBlock = true
                    break
                }
            }
            if removedRepeatedBlock == false { blockStart += 1 }
        }
        let deduplicated = result.joined(separator: " ")
        return hadTrailingWhitespace ? deduplicated + " " : deduplicated
    }
}

/// Expands only genuinely referential follow-ups for retrieval. The model still
/// receives the user's original question; this deterministic query uses the
/// prior user subject and verified source snippets, never generated answer text.
enum AssistantRetrievalQueryBuilder {
    private static let referentialTerms: Set<String> = [
        "earlier", "former", "it", "its", "latter", "previous", "same",
        "that", "their", "them", "these", "they", "this", "those",
    ]
    private static let continuationPrefixes = [
        "and ", "how about", "what about", "why is that", "why does that",
    ]
    private static let shortQuestionPrefixes: Set<String> = [
        "are", "can", "could", "does", "how", "is", "what", "when",
        "where", "which", "why",
    ]

    static func query(
        for prompt: String,
        recentExchanges: [AssistantExchange]
    ) -> String {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard prompt.isEmpty == false,
              let previous = recentExchanges.last(where: { $0.phase == .complete }),
              isReferential(prompt, recentExchanges: recentExchanges) else {
            return prompt
        }

        var fragments = [
            String(previous.question.prefix(220)),
            String(prompt.prefix(220)),
        ]
        fragments.append(contentsOf: previous.sources.prefix(2).compactMap { source in
            let evidence = source.anchor.snippet.assistantTrimmedNonempty
                ?? source.fullText.assistantTrimmedNonempty
            return evidence.map { String($0.prefix(180)) }
        })
        let expanded = fragments
            .flatMap { $0.split(whereSeparator: \Character.isWhitespace) }
            .joined(separator: " ")
        return String(expanded.prefix(640))
    }

    static func isReferential(
        _ prompt: String,
        recentExchanges: [AssistantExchange]
    ) -> Bool {
        recentExchanges.contains(where: { $0.phase == .complete })
            && needsPriorSubject(prompt)
    }

    private static func needsPriorSubject(_ prompt: String) -> Bool {
        let normalized = prompt
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .split { $0.isWhitespace || $0.isPunctuation }
            .map(String.init)
        guard normalized.isEmpty == false else { return false }

        let phrase = normalized.joined(separator: " ")
        if continuationPrefixes.contains(where: phrase.hasPrefix) { return true }
        if normalized.contains(where: referentialTerms.contains) { return true }
        if normalized.count <= 3,
           let first = normalized.first,
           shortQuestionPrefixes.contains(first) {
            return true
        }
        return false
    }
}

/// Converts exact-snapshot, deterministic note intelligence into compact next
/// questions. These strings are presentation affordances, not model output and
/// not durable cache artifacts of their own.
enum AssistantFollowUpSuggestionBuilder {
    static let maximumSuggestionCount = 3
    static let maximumSuggestionLength = 96

    static func suggestions(
        from artifacts: [AssistantLocalArtifact],
        excluding currentPrompt: String
    ) -> [String] {
        let artifactsByKind = Dictionary(
            artifacts.map { ($0.kind, $0.markdown) },
            uniquingKeysWith: { first, _ in first }
        )
        let currentFingerprint = fingerprint(currentPrompt)
        let questionCandidates = contentLines(
            in: artifactsByKind[.questions]
        ).compactMap(questionSuggestion)
        let conceptCandidates = contentLines(
            in: artifactsByKind[.concepts]
        ).compactMap(conceptSuggestion)

        // Prefer two authored review questions, then use a concept to provide
        // useful variety. If either artifact is sparse, fill from the other.
        let candidates = Array(questionCandidates.prefix(2))
            + Array(questionCandidates.dropFirst(2))
        var seen = Set<String>()
        var result: [String] = []
        for candidate in candidates {
            let candidateFingerprint = fingerprint(candidate)
            guard candidateFingerprint.isEmpty == false,
                  candidateFingerprint != currentFingerprint,
                  seen.insert(candidateFingerprint).inserted else { continue }
            result.append(candidate)
            if result.count == maximumSuggestionCount { break }
        }
        return result
    }

    private static func contentLines(in markdown: String?) -> [String] {
        guard let markdown else { return [] }
        return markdown.split(whereSeparator: \Character.isNewline).compactMap { rawLine in
            var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.isEmpty == false, line.hasPrefix("#") == false else { return nil }
            line = line.replacingOccurrences(
                of: #"^(?:[-*•]\s+|\d+[.(])\s+"#,
                with: "",
                options: .regularExpression
            )
            line = line
                .replacingOccurrences(of: "\\*", with: "*")
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "`", with: "")
                .split(whereSeparator: \Character.isWhitespace)
                .joined(separator: " ")
            return line.isEmpty ? nil : line
        }
    }

    private static func questionSuggestion(_ value: String) -> String? {
        var suggestion = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard suggestion.isEmpty == false else { return nil }
        if suggestion.last?.isPunctuation == false {
            suggestion += "?"
        }
        guard suggestion.count <= maximumSuggestionLength else { return nil }
        return suggestion
    }

    private static func conceptSuggestion(_ value: String) -> String? {
        let concept = value.trimmingCharacters(
            in: .whitespacesAndNewlines.union(.punctuationCharacters)
        )
        guard concept.isEmpty == false else { return nil }
        let suggestion = "Explain \(concept) using these notes."
        guard suggestion.count <= maximumSuggestionLength else { return nil }
        return suggestion
    }

    private static func fingerprint(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .lowercased()
        .filter { $0.isLetter || $0.isNumber }
    }
}

private struct AssistantPendingStreamUpdate {
    let targetAnswer: String
    let exchangeID: UUID
    let workID: UUID
    let preliminaryResult: AssistantPreliminaryResultKind?
}

/// The immutable authority against which note-derived UI is checked at the
/// last possible suspension point before publication. Page and notebook work
/// owns a complete snapshot; Library work owns only the bounded anchors it is
/// about to show.
private struct AssistantPublicationContext: Sendable {
    let workID: UUID
    let scope: AssistantScope
    let contentSnapshot: NotebookIndex.ContentSnapshot?
    let summaryCapture: NotebookIndex.SummaryCapture?
}

/// A quick-result action may only promote app-derived content. Model stream
/// snapshots deliberately never enter this slot because their evidence schema
/// has not been validated yet.
private struct AssistantDeterministicPreview: Sendable {
    let workID: UUID
    let exchangeID: UUID
    let answer: String
    let sources: [AssistantSearchResult]
    let kind: AssistantPreliminaryResultKind
    let freshnessReceipt: NotebookIndex.PublicationReceipt
}

/// One cumulative model snapshot captured atomically on MainActor before any
/// terminal-path suspension. Answer text, attribution mode, and exact evidence
/// therefore cannot be mixed with fields from a newer callback while source
/// freshness is being checked.
private struct AssistantActivePartialSnapshot: Sendable {
    let answer: String
    let sources: [AssistantSearchResult]
    let isGeneralKnowledge: Bool
    let freshnessReceipt: NotebookIndex.PublicationReceipt?
}

private struct AssistantValidatedSourceSet: Sendable {
    let sources: [AssistantSearchResult]
    let freshnessReceipt: NotebookIndex.PublicationReceipt
}

private struct AssistantValidatedPartialSourceSet: Sendable {
    let sources: [AssistantSearchResult]
    let freshnessReceipt: NotebookIndex.PublicationReceipt?
}

private struct AssistantValidatedTerminalContent: Sendable {
    let answer: String
    let sources: [AssistantSearchResult]
    let isGeneralKnowledge: Bool
    let preliminaryResult: AssistantPreliminaryResultKind?
    let freshnessReceipt: NotebookIndex.PublicationReceipt?

    func performIfCurrent(_ body: () -> Void) -> Bool {
        if let freshnessReceipt {
            return freshnessReceipt.performIfCurrent(body)
        }
        body()
        return true
    }
}

private struct AssistantImmediateTerminalContent: Sendable {
    let answer: String
    let sources: [AssistantSearchResult]
    let isGeneralKnowledge: Bool
    let preliminaryResult: AssistantPreliminaryResultKind?
    let freshnessReceipt: NotebookIndex.PublicationReceipt?

    func performIfCurrent(_ body: () -> Void) -> Bool {
        if let freshnessReceipt {
            return freshnessReceipt.performIfCurrent(body)
        }
        body()
        return true
    }
}

/// Session-local state for the contextual assistant. The canvas remains the
/// authored source of truth; this model owns only presentation, retrieval, and
/// cancellable model work.
enum AssistantProgressPresentationPolicy {
    /// Leave enough time for retrieval to publish a deterministic preview,
    /// while making the escape hatch useful well before the 9-second initial
    /// no-progress watchdog.
    static let deterministicEscapeDelay: Duration = .seconds(3)
}

@MainActor
@Observable
public final class AssistantPresentationModel {
    private static let pipelineLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "Notate",
        category: "AssistantPipeline"
    )
    private static let pipelineSignposter = OSSignposter(logger: pipelineLogger)
    private static let prewarmLease: Duration = .seconds(45)
    /// Streaming progress is activity, not failure. Once useful model text is
    /// arriving, allow a short quiet period for the next cumulative snapshot
    /// while retaining the route's absolute request cap.
    private static let streamInactivityGrace: Duration = .seconds(8)
    /// Keep presentation and direct-summary liveness on the same quiet-period
    /// contract. The absolute route cap remains an independent safety bound.
    private static let summaryPresentationInactivityGrace: Duration = .seconds(8)
    /// Caps authoritative transcript replacement below the display refresh
    /// rate while the leaf renderer supplies display-linked motion between
    /// cumulative model snapshots.
    private static let streamPresentationInterval: Duration = .milliseconds(66)
    private static let generationNoOutputGrace: Duration = .seconds(9)
    private static let generationAdmissionWindow = AssistantFoundationTimeoutPolicy.minimumGenerationTime
    static let maximumRetainedExchangeCount = 64

    public private(set) var isPresented = false
    public var scope: AssistantScope = .item
    public var requestMode: AssistantRequestMode = .ask
    public var draft = ""
    public private(set) var exchanges: [AssistantExchange] = []
    public private(set) var isWorking = false
    public private(set) var status: AssistantStatus?
    public var statusMessage: String? { status?.message }
    public private(set) var workPhase: AssistantWorkPhase? {
        didSet {
            guard let workPhase, workPhase != oldValue else { return }
            Self.pipelineSignposter.emitEvent("Phase", "stage=\(workPhase.metricLabel, privacy: .public)")
            publishPipelineUpdate(.phase(workPhase))
        }
    }

    public private(set) var showsProgress = false
    public private(set) var isTakingLonger = false
    public private(set) var showsLongRunningActions = false
    private(set) var responsePresentation: AssistantResponsePresentation?
    public private(set) var modelAvailability: AssistantModelAvailability?
    public private(set) var composerFocusRequest = UUID()
    public private(set) var currentPageID: UUID?
    public private(set) var itemKind: LibraryItemKind
    @ObservationIgnored private(set) var pipelineJobHandle: AssistantJobHandle?

    public private(set) var itemID: UUID
    public private(set) var itemName: String

    @ObservationIgnored public let index: NotebookIndex
    @ObservationIgnored private let modelClient: any AssistantModelClient
    @ObservationIgnored private let pipelineCoordinator: AssistantPipelineCoordinator
    @ObservationIgnored private let cpuWorker: AssistantCPUWorker
    @ObservationIgnored private var artifactCache: AssistantArtifactCache?
    @ObservationIgnored private var navigateToSource: @MainActor (AssistantSourceAnchor) -> Void
    @ObservationIgnored private var prepareForRequest: (
        @MainActor () async -> AssistantRequestPreparationResult
    )?

    @ObservationIgnored private var itemsSnapshot: [AssistantIndexedItem]
    @ObservationIgnored private var workTask: Task<Void, Never>?
    /// Orders every coordinator operation emitted by this presentation model.
    /// New admission awaits the tail, so terminal cancellation registration or
    /// publication cannot be overtaken by an immediate retry in this panel.
    @ObservationIgnored private var pipelinePublicationTail: Task<Void, Never>?
    @ObservationIgnored private var activeWorkID: UUID?
    @ObservationIgnored private var activeExchangeID: UUID?
    @ObservationIgnored private var pendingIndexInvalidationTask: Task<Void, Never>?
    /// Source resolution is user navigation, so only its newest request may
    /// reach the application coordinator. Closing the editor cancels this task
    /// before an old index lookup can reopen or replace a later editor.
    @ObservationIgnored private var sourceNavigationTask: Task<Void, Never>?
    @ObservationIgnored private var sourceNavigationRequestID: UUID?
    @ObservationIgnored private var streamPresentationTask: Task<Void, Never>?
    @ObservationIgnored private var pendingStreamUpdate: AssistantPendingStreamUpdate?
    @ObservationIgnored private var lastStreamPresentationAt: ContinuousClock.Instant?
    @ObservationIgnored private var progressPresentationTask: Task<Void, Never>?
    @ObservationIgnored private var responsePresentationTask: Task<Void, Never>?
    @ObservationIgnored private var longerRunningTask: Task<Void, Never>?
    @ObservationIgnored private var longRunningActionsTask: Task<Void, Never>?
    @ObservationIgnored private var requestDeadlineTask: Task<Void, Never>?
    @ObservationIgnored private var activeWatchdogDeadline: ContinuousClock.Instant?
    /// Monotonically identifies the currently authoritative watchdog. A timer
    /// may already be inside async fallback validation when stream progress
    /// rearms the lease; the token prevents that retired timer from committing
    /// a timeout after the new progress has been accepted.
    @ObservationIgnored private var activeWatchdogToken: UInt64 = 0
    @ObservationIgnored private var activeFollowUpTask: Task<[String], Never>?
    /// Supplemental chips are published only if their independent local work
    /// has already completed. A finished answer never waits for them.
    @ObservationIgnored private var activeFollowUpSuggestions: [String] = []
    @ObservationIgnored private var prewarmTask: Task<Void, Never>?
    @ObservationIgnored private var maintenanceTask: Task<Void, Never>?
    @ObservationIgnored private var lastPrewarmAt: ContinuousClock.Instant?
    @ObservationIgnored private let prewarmClock = ContinuousClock()
    @ObservationIgnored private var indexRevision: UInt64 = 0
    @ObservationIgnored private var conversationContextStartIndex = 0
    @ObservationIgnored private var activeDidReceiveModelText = false
    @ObservationIgnored private var activePartialSourceIDs: [String] = []
    @ObservationIgnored private var activePartialIsGeneralKnowledge = false
    @ObservationIgnored private var activePartialFreshnessReceipt: NotebookIndex.PublicationReceipt?
    /// Request-scoped source rows from which typed cumulative provenance can be
    /// reconstructed synchronously for Stop and captured before async terminal
    /// validation. Summary authority is complete even though its UI preview is
    /// deliberately sampled to eight rows.
    @ObservationIgnored private var activePartialSourceAuthority: [String: AssistantSearchResult] = [:]
    @ObservationIgnored private var activeDidPublishUsefulContent = false
    @ObservationIgnored private var activePublicationContext: AssistantPublicationContext?
    @ObservationIgnored private var activeDeterministicPreview: AssistantDeterministicPreview?
    @ObservationIgnored private var activePipelineRequest: AssistantUserRequest?
    @ObservationIgnored private var conversationID = UUID()
    @ObservationIgnored private var uiEpoch: UInt64 = 0
    /// A deterministic test seam placed after source/follow-up hydration and
    /// immediately before the final snapshot validation. Production never
    /// installs this closure.
    @ObservationIgnored private var beforeResultPublicationForTesting: (@Sendable () async -> Void)?
    /// Pauses a fired watchdog before it validates and commits fallback. This
    /// deterministic seam exercises rearming while the old timer is suspended.
    @ObservationIgnored private var beforeDeadlineFallbackForTesting: (@Sendable () async -> Void)?
    /// Suspends only after the deadline has captured one immutable partial.
    /// Tests use it to prove a newer callback cannot alter that tuple.
    @ObservationIgnored private var beforePartialProvenanceValidationForTesting: (@Sendable () async -> Void)?
    /// Lets focused tests exercise end-to-end deadline behavior without
    /// waiting for a production route timeout.
    @ObservationIgnored private var requestDeadlineOverrideForTesting: Duration?
    /// Lets tests distinguish the initial no-progress watchdog from the
    /// absolute request cap. When unset, the historical single override still
    /// controls both values for backwards compatibility.
    @ObservationIgnored private var initialWatchdogDeadlineOverrideForTesting: Duration?
    @ObservationIgnored private var streamInactivityGraceOverrideForTesting: Duration?
    @ObservationIgnored private var generationNoOutputGraceOverrideForTesting: Duration?

    public init(
        itemID: UUID,
        itemName: String,
        itemKind: LibraryItemKind = .notebook,
        items: [AssistantIndexedItem],
        currentPageID: UUID? = nil,
        navigateToSource: @escaping @MainActor (AssistantSourceAnchor) -> Void,
        prepareForRequest: (
            @MainActor () async -> AssistantRequestPreparationResult
        )? = nil,
        index sharedIndex: NotebookIndex? = nil,
        modelClient: (any AssistantModelClient)? = nil,
        pipelineCoordinator: AssistantPipelineCoordinator? = nil,
        cpuWorker: AssistantCPUWorker? = nil
    ) {
        self.itemID = itemID
        self.itemName = itemName
        self.itemKind = itemKind
        self.currentPageID = currentPageID
        self.navigateToSource = navigateToSource
        if let prepareForRequest {
            let adapted: @MainActor (
                AssistantTask,
                ContinuousClock.Instant
            ) async -> AssistantRequestPreparationResult = { _, _ in
                await prepareForRequest()
            }
            self.prepareForRequest = adapted
        } else {
            self.prepareForRequest = nil
        }
        itemsSnapshot = items

        let index = sharedIndex ?? NotebookIndex(items: items)
        self.index = index
        self.modelClient = modelClient
            ?? FoundationModelAssistantClient()
        self.pipelineCoordinator = pipelineCoordinator
            ?? AssistantPipelineCoordinator()
        self.cpuWorker = cpuWorker ?? AssistantCPUWorker()
        artifactCache = nil
    }

    deinit {
        workTask?.cancel()
        pendingIndexInvalidationTask?.cancel()
        streamPresentationTask?.cancel()
        progressPresentationTask?.cancel()
        responsePresentationTask?.cancel()
        longerRunningTask?.cancel()
        longRunningActionsTask?.cancel()
        requestDeadlineTask?.cancel()
        prewarmTask?.cancel()
        maintenanceTask?.cancel()
    }

    public func open() {
        isPresented = true
        requestPrewarmIfNeeded()
    }

    /// Starts the on-device model warmup before the assistant panel is opened.
    /// The call is intentionally idempotent so an editor can anticipate likely
    /// use without creating duplicate model work.
    public func prepare() {
        requestPrewarmIfNeeded()
    }

    public func close() {
        isPresented = false
    }

    public func updateCurrentPage(_ pageID: UUID?) {
        // A submitted request owns an immutable snapshot of its page and
        // retrieval scope. Moving around the notebook must not cancel that
        // work; the new page becomes the scope only for the next submission.
        currentPageID = pageID
    }

    public func updateFocusedItem(
        itemID: UUID,
        itemName: String,
        itemKind: LibraryItemKind? = nil,
        currentPageID: UUID?
    ) {
        if self.itemID != itemID {
            // Keep the visible transcript, but never feed turns grounded in a
            // different document into the next document's model request.
            beginFreshConversationContext()
        }
        self.itemID = itemID
        self.itemName = itemName
        if let itemKind {
            self.itemKind = itemKind
        }
        self.currentPageID = currentPageID
        if availableScopes.contains(scope) == false { scope = .item }
    }

    public var availableScopes: [AssistantScope] {
        AssistantScope.allCases
    }

    public func displayTitle(for scope: AssistantScope) -> String {
        guard scope == .item else { return scope.displayTitle }
        return switch itemKind {
        case .notebook: "Notebook"
        case .importedDocument: "Document"
        case .attachment: "File"
        case .folder: "Folder"
        default: "Item"
        }
    }

    public func register(items: [AssistantIndexedItem]) {
        guard itemsSnapshot != items else { return }
        beginFreshConversationContext()
        itemsSnapshot = items
        Task { [index] in
            await index.replaceRegisteredItems(items)
        }
    }

    /// Installs editor-specific work that must finish before retrieval starts.
    /// Notebook editors use this to flush the live document into a verified
    /// checkpoint, so an immediate question cannot race the autosave delay.
    public func setRequestPreparation(
        _ action: (
            @MainActor () async -> AssistantRequestPreparationResult
        )?
    ) {
        if let action {
            let adapted: @MainActor (
                AssistantTask,
                ContinuousClock.Instant
            ) async -> AssistantRequestPreparationResult = { _, _ in
                await action()
            }
            prepareForRequest = adapted
        } else {
            prepareForRequest = nil
        }
    }

    /// Installs preparation that shares the visible request's immutable
    /// absolute deadline. Editor integrations use this to bound foreground
    /// Vision work without granting it a new timeout after checkpointing.
    func setDeadlineAwareRequestPreparation(
        _ action: (
            @MainActor (
                AssistantTask,
                ContinuousClock.Instant
            ) async -> AssistantRequestPreparationResult
        )?
    ) {
        prepareForRequest = action
    }

    /// Installs the process-wide, protected on-device intelligence cache.
    /// Keeping this separate from the public initializer avoids exposing the
    /// cache implementation as application API while allowing every editor to
    /// share one serialized store.
    func setArtifactCache(_ cache: AssistantArtifactCache?) {
        artifactCache = cache
    }

    func setBeforeResultPublicationForTesting(
        _ action: (@Sendable () async -> Void)?
    ) {
        beforeResultPublicationForTesting = action
    }

    func setBeforeDeadlineFallbackForTesting(
        _ action: (@Sendable () async -> Void)?
    ) {
        beforeDeadlineFallbackForTesting = action
    }

    func setBeforePartialProvenanceValidationForTesting(
        _ action: (@Sendable () async -> Void)?
    ) {
        beforePartialProvenanceValidationForTesting = action
    }

    func setRequestDeadlineOverrideForTesting(_ duration: Duration?) {
        requestDeadlineOverrideForTesting = duration
    }

    func setInitialWatchdogDeadlineOverrideForTesting(_ duration: Duration?) {
        initialWatchdogDeadlineOverrideForTesting = duration
    }

    func setStreamInactivityGraceOverrideForTesting(_ duration: Duration?) {
        streamInactivityGraceOverrideForTesting = duration
    }

    func setGenerationNoOutputGraceOverrideForTesting(_ duration: Duration?) {
        generationNoOutputGraceOverrideForTesting = duration
    }

    public func invalidateIndex(for itemID: UUID) {
        beginFreshConversationContext()
        let previousInvalidation = pendingIndexInvalidationTask
        pendingIndexInvalidationTask = Task { [index] in
            await previousInvalidation?.value
            guard Task.isCancelled == false else { return }
            await index.invalidate(itemID: itemID)
        }
    }

    /// Invalidates request identity immediately when the live editor changes,
    /// before its debounced save or verified-index publication completes.
    /// Stale streamed prose and source rows are removed rather than preserved
    /// as a stopped response.
    public func noteContentDidChange() {
        let exchangeID = activeExchangeID
        let hadActiveWork = activeWorkID != nil
        let requestID = activePipelineRequest?.requestID
        let invalidationMessage = "The note changed while I was working, so I discarded the earlier result. Ask again to use the latest content."
        requestDeadlineTask?.cancel()
        requestDeadlineTask = nil
        activeWatchdogDeadline = nil
        activeFollowUpTask?.cancel()
        activeFollowUpTask = nil
        activeFollowUpSuggestions = []
        cancelResponsePresentation()
        activeWorkID = nil
        workTask?.cancel()
        workTask = nil
        discardPendingStreamUpdate()
        activePublicationContext = nil
        activePartialSourceAuthority = [:]
        activePartialFreshnessReceipt = nil
        activeDeterministicPreview = nil

        if hadActiveWork, let exchangeID {
            replaceExchange(
                id: exchangeID,
                with: AssistantExchange(
                    id: exchangeID,
                    question: exchanges.first(where: { $0.id == exchangeID })?.question ?? "",
                    answer: invalidationMessage,
                    mode: exchanges.first(where: { $0.id == exchangeID })?.mode ?? .ask,
                    phase: .complete,
                    outcome: .failure
                )
            )
        }
        status = AssistantStatus(
            message: "The in-progress response was invalidated by a note edit.",
            severity: .information,
            action: .retry
        )
        activeExchangeID = nil
        activePipelineRequest = nil
        isWorking = false
        workPhase = nil
        cancelProgressPresentation()
        indexRevision &+= 1
        conversationContextStartIndex = exchanges.count
        if let requestID {
            // Register cancellation ahead of the terminal publication on this
            // presenter's ordered coordinator lane. Replacement admission in
            // another panel either observes this barrier or rejects this call
            // as stale and owns the next cancellation invocation; the provider
            // continues fencing any cancellation-resistant physical drain.
            enqueueModelCancellation(requestID: requestID)
            enqueuePipelineUpdate(
                .failedWithFallback(invalidationMessage),
                requestID: requestID
            )
        }
    }

    /// True only when an app-derived preview--not unvalidated model prose--can
    /// safely be selected as the terminal response.
    public var canUseQuickResult: Bool {
        guard let preview = activeDeterministicPreview else { return false }
        return activeWorkID == preview.workID
            && activeExchangeID == preview.exchangeID
    }

    public var canShowRelevantPassages: Bool {
        canUseQuickResult && activeDeterministicPreview?.kind == .relevantPassages
    }

    /// Deterministic extraction is a safety net, not the visible answer while
    /// Foundation Models is still refining the response. Keeping this policy
    /// in the model prevents old transcript rows from being hidden merely
    /// because a newer request is active.
    func shouldHoldPreliminaryResult(for exchangeID: UUID) -> Bool {
        guard isWorking,
              activeExchangeID == exchangeID,
              let exchange = exchanges.first(where: { $0.id == exchangeID }) else {
            return false
        }
        return exchange.phase == .streaming && exchange.preliminaryResult != nil
    }

    public func focusComposer() {
        isPresented = true
        composerFocusRequest = UUID()
        requestPrewarmIfNeeded()
    }

    /// Routes a free-form composer request without requiring a visible Ask/Find
    /// mode switch. Only explicit requests to locate note content use the local
    /// Find path; everything else remains a grounded Ask request.
    public func submitDraftAutomatically() {
        guard acceptsPromptByteCount(draft) else { return }
        guard let prompt = draft.assistantTrimmedNonempty else { return }
        draft = ""
        requestMode = automaticRequestMode(for: prompt)
        submit(prompt: prompt)
    }

    public func submitSuggestion(_ prompt: String) {
        draft = ""
        submit(prompt: prompt)
    }

    public func submitSuggestionAutomatically(_ prompt: String) {
        draft = ""
        submit(prompt: prompt)
    }

    public func submit(prompt: String, searchScope: AssistantScope? = nil) {
        let resolvedScope = searchScope ?? scope
        startSubmission(prompt: prompt, scope: resolvedScope, mode: requestMode)
    }

    private func acceptsPromptByteCount(_ prompt: String) -> Bool {
        let byteCount = prompt.utf8.count
        let limit = AssistantFoundationSizeLimits.maximumPromptByteCount
        if byteCount > limit {
            Self.pipelineLogger.warning("Prompt too large: \(byteCount) bytes")
            return false
        }
        return true
    }

    private func startSubmission(
        prompt: String,
        scope resolvedScope: AssistantScope,
        mode: AssistantRequestMode
    ) {
        let displacedPipelineRequestID = activePipelineRequest?.requestID
        cancelResponsePresentation()
        workTask?.cancel()
        requestDeadlineTask?.cancel()
        requestDeadlineTask = nil
        activeWatchdogDeadline = nil
        activeFollowUpTask?.cancel()
        activeFollowUpTask = nil
        activeFollowUpSuggestions = []
        maintenanceTask?.cancel()
        maintenanceTask = nil
        discardPendingStreamUpdate()
        activePublicationContext = nil
        activePartialSourceAuthority = [:]
        activePartialFreshnessReceipt = nil
        activeDeterministicPreview = nil
        activeWorkID = nil
        if let displacedPipelineRequestID {
            // Do not rely on the replacement reaching coordinator admission to
            // close its predecessor. A user can submit and immediately tap
            // Stop while this task is still queued behind publication.
            enqueuePipelineUpdate(
                .stopped,
                requestID: displacedPipelineRequestID
            )
        }
        // The prior lifecycle is now terminalized on the ordered publication
        // lane. Clear the presentation pointer so phase changes made while
        // constructing the replacement cannot target the superseded request.
        activePipelineRequest = nil
        if let activeExchangeID {
            removeIncompleteExchange(id: activeExchangeID)
        }
        isPresented = true
        isWorking = true
        status = nil
        workPhase = .readingNote
        showsProgress = false
        isTakingLonger = false
        showsLongRunningActions = false
        activeDidReceiveModelText = false
        activePartialSourceIDs = []
        activePartialIsGeneralKnowledge = false
        activePartialSourceAuthority = [:]
        activePartialFreshnessReceipt = nil
        activeDidPublishUsefulContent = false

        let assistantTask: AssistantTask = mode == .find
            ? .find
            : AssistantTaskRouter.task(for: prompt)
        let submittedAt = ContinuousClock().now
        let requestDuration = requestDeadlineOverrideForTesting
            ?? assistantTask.requestHardDeadline
        let requestDeadline = submittedAt.advanced(by: requestDuration)
        // Production generation stops before the absolute request cap so
        // evidence validation and fallback publication always have a reserve.
        // Tiny test deadlines keep their historical exact value.
        let modelDeadline = requestDeadlineOverrideForTesting == nil
            ? requestDeadline.advanced(by: .seconds(-1))
            : requestDeadline
        let initialWatchdogDeadline = submittedAt.advanced(
            by: initialWatchdogDeadlineOverrideForTesting
                ?? requestDeadlineOverrideForTesting
                ?? assistantTask.initialWatchdogDeadline
        )
        uiEpoch &+= 1
        let request = AssistantUserRequest(
            requestID: UUID(),
            conversationID: conversationID,
            uiEpoch: uiEpoch,
            task: assistantTask,
            prompt: prompt,
            scope: resolvedScope,
            deadline: requestDeadline
        )
        let workID = request.requestID
        activePipelineRequest = request
        let requestSignpostID = Self.pipelineSignposter.makeSignpostID()
        let requestSignpost = Self.pipelineSignposter.beginInterval(
            "AssistantRequest",
            id: requestSignpostID
        )
        let exchangeID = appendPendingExchange(
            question: prompt,
            mode: mode,
            task: assistantTask,
            scope: resolvedScope,
            scopeTitle: displayTitle(for: resolvedScope)
        )
        activeWorkID = workID
        activeExchangeID = exchangeID
        startResponsePresentation(
            requestID: workID,
            exchangeID: exchangeID,
            task: assistantTask,
            scope: resolvedScope,
            scopeTitle: displayTitle(for: resolvedScope)
        )
        scheduleRequestDeadline(
            task: assistantTask,
            scope: resolvedScope,
            prompt: prompt,
            deadline: initialWatchdogDeadline,
            exchangeID: exchangeID,
            workID: workID
        )
        scheduleProgressPresentation(for: workID)
        let focusedItemID = itemID
        let pageID = currentPageID
        let pendingIndexInvalidation = pendingIndexInvalidationTask

        workTask = Task { [weak self] in
            defer {
                Self.pipelineSignposter.endInterval(
                    "AssistantRequest",
                    requestSignpost
                )
            }
            guard let self else { return }
            await self.pipelinePublicationTail?.value
            guard let self else { return }
            await self.pipelinePublicationTail?.value
            guard self.isCurrentWork(workID) else { return }
            let handle = await self.pipelineCoordinator.start(
                request,
                cancellation: { [weak self] in
                    Task { @MainActor [weak self] in
                        self?.cancelFromPipelinePreemption(requestID: request.requestID)
                    }
                },
                modelCancellation: { [modelClient = self.modelClient] in
                    await modelClient.cancel()
                }
            )
            guard self.isCurrentWork(workID) else {
                await self.enqueuePipelineUpdate(
                    .stopped,
                    requestID: request.requestID
                ).value
                return
            }
            self.pipelineJobHandle = handle
            // The process-wide coordinator admitted this request and queued
            // its client-wide cancellation in one actor transaction. No
            // displaced panel can enqueue a late cancel beyond this barrier;
            // the provider separately fences any physically undrained work.
            await handle.modelCancellationBarrier.value
            guard self.isCurrentWork(workID) else { return }
            await pendingIndexInvalidation?.value
            guard self.isCurrentWork(workID) else { return }
            let checkpointSignpost = Self.pipelineSignposter.beginInterval(
                "SnapshotCheckpoint",
                id: requestSignpostID
            )
            let preparation = await self.prepareForRequest?(
                request.task,
                request.deadline
            ) ?? .ready
            Self.pipelineSignposter.endInterval(
                "SnapshotCheckpoint",
                checkpointSignpost
            )
            guard self.isCurrentWork(workID) else { return }
            if self.finishRequestPreparationFailure(
                preparation,
                prompt: prompt,
                mode: mode,
                exchangeID: exchangeID,
                workID: workID
            ) {
                return
            }

            // The continuously maintained index is the request-time catalog.
            // Never rebuild or enumerate a library DTO here; `register(items:)`
            // and idle application maintenance own catalog changes.
            if resolvedScope == .library,
            (assistantTask == .summarize || assistantTask == .study) {
                self.replaceExchange(
                    id: exchangeID,
                    with: AssistantExchange(
                        id: exchangeID,
                        question: prompt,
                        answer: assistantTask == .summarize
                            ? "Choose a page or notebook to create a complete summary. Library scope is optimized for fast Find, Answer, and Explain requests."
                            : "Choose a page or notebook to create study material. Library scope is optimized for fast Find, Answer, and Explain requests.",
                        mode: .ask,
                        phase: .complete,
                        outcome: .failure
                    )
                )
                self.status = AssistantStatus(
                    message: "Complete summaries and study sets use a bounded page or notebook scope.",
                    severity: .information,
                    action: .chooseNotebook
                )
                self.completeWork(workID)
                return
            }
            let completedExchanges = self.exchanges
                .dropFirst(min(self.conversationContextStartIndex, self.exchanges.count))
                .filter { $0.phase == .complete && $0.id != exchangeID }
            let retrievalQuery = AssistantRetrievalQueryBuilder.query(
                for: prompt,
                recentExchanges: Array(completedExchanges)
            )
            let priorTurns = completedExchanges
                .flatMap { exchange in
                    [
                        AssistantModelTurn(role: .user, text: exchange.question),
                        AssistantModelTurn(role: .assistant, text: exchange.answer),
                    ]
                }
            let revision = self.indexRevision

            if assistantTask == .find {
                let findSnapshot = resolvedScope == .library
                    ? nil
                    : await self.index.contentSnapshot(
                        itemID: focusedItemID,
                        pageID: resolvedScope == .page ? pageID : nil,
                        deadline: modelDeadline
                    )
                guard self.isCurrentWork(workID) else { return }
                self.installPublicationContext(
                    workID: workID,
                    scope: resolvedScope,
                    contentSnapshot: findSnapshot
                )
                self.workPhase = .gettingRelevantDetails
                let retrievedResults: [AssistantSearchResult]
                if resolvedScope == .library {
                    retrievedResults = await self.index.boundedLibraryEvidence(
                        query: retrievalQuery
                    ).passages
                } else {
                    retrievedResults = await self.index.search(
                        query: retrievalQuery,
                        scope: resolvedScope,
                        itemID: focusedItemID,
                        pageID: pageID,
                        limit: 8
                    )
                }
                guard let prepared = await self.validatedPublication(
                    retrievedResults,
                    workID: workID
                ) else {
                    guard self.isCurrentWork(workID) else { return }
                    self.finishStaleGroundedWork(
                        prompt: prompt,
                        exchangeID: exchangeID,
                        workID: workID
                    )
                    return
                }
                let results = prepared.sources
                await self.recordPreparedRequest(
                    snapshot: nil,
                    passages: results
                )
                guard self.isCurrentWork(workID) else { return }
                guard let finalPublication = await self.validatedPublication(
                    results,
                    workID: workID
                ) else {
                    guard self.isCurrentWork(workID) else { return }
                    self.finishStaleGroundedWork(
                        prompt: prompt,
                        exchangeID: exchangeID,
                        workID: workID
                    )
                    return
                }
                guard self.commitValidatedPublication(
                    finalPublication,
                    workID: workID,
                    { finalResults in
                        self.finishFind(
                            prompt: prompt,
                            results: finalResults,
                            exchangeID: exchangeID,
                            workID: workID
                        )
                    }
                ) else {
                    guard self.isCurrentWork(workID) else { return }
                    self.finishStaleGroundedWork(
                        prompt: prompt,
                        exchangeID: exchangeID,
                        workID: workID
                    )
                    return
                }
                return
            }

            if assistantTask == .summarize {
                await self.finishSummary(
                    prompt: prompt,
                    // A summary always covers a complete authored unit. The
                    // Library scope remains a discovery surface rather than
                    // silently turning a top-ranked sample into a purported
                    // whole-library summary.
                    scope: resolvedScope,
                    focusedItemID: focusedItemID,
                    pageID: pageID,
                    directDeadline: modelDeadline,
                    requestDeadline: requestDeadline,
                    modelDeadline: modelDeadline,
                    exchangeID: exchangeID,
                    workID: workID
                )
                return
            }

            let requestContentSnapshot: NotebookIndex.ContentSnapshot?
            if resolvedScope == .library {
                requestContentSnapshot = nil
            } else {
                let snapshotSignpost = Self.pipelineSignposter.beginInterval(
                    "SnapshotCapture",
                    id: requestSignpostID
                )
                requestContentSnapshot = await self.index.contentSnapshot(
                    itemID: focusedItemID,
                    pageID: resolvedScope == .page ? pageID : nil,
                    deadline: modelDeadline
                )
                Self.pipelineSignposter.endInterval(
                    "SnapshotCapture",
                    snapshotSignpost
                )
            }
            guard self.isCurrentWork(workID) else { return }
            self.installPublicationContext(
                workID: workID,
                scope: resolvedScope,
                contentSnapshot: requestContentSnapshot
            )
            let requestSummarySnapshot: NoteContentSnapshot?
            if let requestContentSnapshot,
                requestContentSnapshot.units.contains(where: { $0.kind != .metadata }) {
                requestSummarySnapshot = try? await self.cpuWorker.summarySnapshot(
                    from: requestContentSnapshot
                )
            } else {
                requestSummarySnapshot = nil
            }
            let requestArtifactContext = requestSummarySnapshot.map {
                Self.artifactContext(
                    noteID: $0.noteID,
                    scope: resolvedScope,
                    pageID: pageID
                )
            }
            let allowsGeneralKnowledge = Self.explicitlyRequestsGeneralKnowledge(prompt)
            let isReferentialRequest = AssistantRetrievalQueryBuilder.isReferential(
                prompt,
                recentExchanges: Array(completedExchanges)
            )
            let canPublishFollowUps = resolvedScope != .library
                && allowsGeneralKnowledge == false
                && isReferentialRequest == false
                && (assistantTask == .answer
                    || assistantTask == .explain
                    || assistantTask == .study)
            // Start the exact-current cache read and a bounded deterministic
            // fallback together. A fresh note should have useful follow-ups;
            // it must not wait for post-response cache maintenance.
            let cachedIntelligenceTask: Task<[AssistantLocalArtifact], Never>? = if let requestSummarySnapshot,
                let requestArtifactContext {
                Task { @MainActor [weak self] in
                    guard let self else { return [] }
                    let artifacts = await self.cachedLocalIntelligence(
                        for: requestSummarySnapshot,
                        context: requestArtifactContext
                    )
                    guard self.isCurrentWork(workID), canPublishFollowUps else {
                        return artifacts
                    }
                    let cached = AssistantFollowUpSuggestionBuilder.suggestions(
                        from: artifacts.filter {
                            $0.kind == .concepts || $0.kind == .questions
                        },
                        excluding: prompt
                    )
                    if cached.isEmpty == false {
                        self.activeFollowUpSuggestions = cached
                    }
                    return artifacts
                }
            } else {
                nil
            }
            let generatedFollowUpTask: Task<[String], Never>? = if canPublishFollowUps,
                let requestSummarySnapshot {
                Task { @MainActor [weak self, cpuWorker] in
                    let generated = await cpuWorker.followUpSuggestions(
                        from: requestSummarySnapshot,
                        excluding: prompt
                    )
                    guard let self, self.isCurrentWork(workID) else { return generated }
                    if self.activeFollowUpSuggestions.isEmpty,
                        generated.isEmpty == false {
                        self.activeFollowUpSuggestions = generated
                    }
                    return generated
                }
            } else {
                nil
            }
            self.activeFollowUpTask = generatedFollowUpTask
            let canReuseGroundedArtifact = completedExchanges.isEmpty
                && allowsGeneralKnowledge == false
                && (assistantTask == .answer || assistantTask == .explain)
            let canReuseStudyArtifact = completedExchanges.isEmpty
                && allowsGeneralKnowledge == false
                && assistantTask == .study
            async let scopedGroundedArtifactRequest = self.cachedGroundedArtifact(
                task: assistantTask,
                prompt: prompt,
                snapshotHash: requestSummarySnapshot?.contentHash,
                context: requestArtifactContext,
                isEligible: canReuseGroundedArtifact
            )
            if canReuseStudyArtifact,
                let requestSummarySnapshot,
                let requestArtifactContext,
                let cached = await self.cachedStudyArtifact(
                    prompt: prompt,
                    snapshot: requestSummarySnapshot,
                    context: requestArtifactContext
                ) {
                let snapshotSourceIDs = Set(
                    requestSummarySnapshot.sections
                        .flatMap(\.chunks)
                        .map(\.sourceID)
                )
                let cachedSourceIDSet = Set(cached.sourceIDs)
                let cachedIDsAreValid = cached.sourceIDs.isEmpty == false
                    && cachedSourceIDSet.count == cached.sourceIDs.count
                    && cachedSourceIDSet.isSubset(of: snapshotSourceIDs)
                let cachedSources = cachedIDsAreValid
                    ? await self.index.read(anchorIDs: cached.sourceIDs)
                    : []
                let snapshotIsCurrent = if let requestContentSnapshot {
                    await self.index.isCurrent(requestContentSnapshot)
                } else {
                    true
                }
                guard self.isCurrentWork(workID) else { return }
                guard snapshotIsCurrent else {
                    self.finishStaleGroundedWork(
                        prompt: prompt,
                        exchangeID: exchangeID,
                        workID: workID
                    )
                    return
                }
                if cachedIDsAreValid,
                    cachedSources.count == cached.sourceIDs.count,
                    let cachedAnswer = cached.markdown.assistantCanonicalNonempty {
                    let followUps = canPublishFollowUps
                        ? self.activeFollowUpSuggestions
                        : []
                    guard self.isCurrentWork(workID) else { return }
                    await self.beforeResultPublicationForTesting?()
                    guard self.isCurrentWork(workID) else { return }
                    guard let publication = await self.validatedPublication(
                        cachedSources,
                        workID: workID
                    ) else {
                        guard self.isCurrentWork(workID) else { return }
                        self.finishStaleGroundedWork(
                            prompt: prompt,
                            exchangeID: exchangeID,
                            workID: workID
                        )
                        return
                    }
                    guard self.commitValidatedPublication(
                        publication,
                        workID: workID,
                        { publicationSources in
                            self.replaceExchange(
                                id: exchangeID,
                                with: AssistantExchange(
                                    id: exchangeID,
                                    question: prompt,
                                    answer: cachedAnswer,
                                    sources: publicationSources,
                                    followUps: followUps,
                                    mode: .ask,
                                    phase: .complete
                                )
                            )
                            self.completeWork(workID)
                        }
                    ) else {
                        guard self.isCurrentWork(workID) else { return }
                        self.finishStaleGroundedWork(
                            prompt: prompt,
                            exchangeID: exchangeID,
                            workID: workID
                        )
                        return
                    }
                    return
                }
            }

            self.workPhase = .gettingRelevantDetails
            // Availability, cache orientation, and retrieval are independent.
            // Starting them together removes serial hops from every grounded Ask.
            async let availabilityRequest = self.modelClient.availability()
            async let orientationRequest = self.cachedOrientation(
                task: assistantTask,
                snapshot: requestSummarySnapshot,
                context: requestArtifactContext,
                cachedIntelligenceTask: cachedIntelligenceTask
            )
            let retrievalStartedAt = Date()
            let retrievalSignpost = Self.pipelineSignposter.beginInterval(
                "Retrieval",
                id: requestSignpostID
            )
            var results: [AssistantSearchResult]
            if resolvedScope == .library {
                results = await self.index.boundedLibraryEvidence(
                    query: retrievalQuery
                ).passages
            } else {
                results = await self.index.search(
                    query: retrievalQuery,
                    scope: resolvedScope,
                    itemID: focusedItemID,
                    pageID: pageID,
                    limit: assistantTask.retrievalPassageLimit
                )
            }
            // The metadata row exists so Find can discover a notebook by its
            // title. It is not authored note content and must never become
            // evidence for Answer, Explain, or Study.
            results = Self.substantiveGroundingEvidence(results)
            let requestsBroadContext = Self.requestsBroadScopedContext(prompt)
            let requestsScopedOverview = Self.requestsExplicitScopedOverview(prompt)
            let needsOverviewContext = resolvedScope != .library
                && requestsBroadContext
                && (allowsGeneralKnowledge == false || requestsScopedOverview)
            let shouldLoadScopedContext = resolvedScope != .library
                && (
                    needsOverviewContext
                    || (
                        results.isEmpty
                        && (allowsGeneralKnowledge == false || requestsScopedOverview)
                    )
                )
            if shouldLoadScopedContext {
                let scopedContext = Self.substantiveGroundingEvidence(
                    await self.index.context(
                        scope: resolvedScope,
                        itemID: focusedItemID,
                        pageID: pageID,
                        limit: assistantTask.retrievalPassageLimit,
                        deadline: modelDeadline
                    )
                )
                if needsOverviewContext {
                    var seen = Set<String>()
                    results = Array((scopedContext + results).filter {
                        seen.insert($0.id).inserted
                    }.prefix(assistantTask.retrievalPassageLimit))
                } else {
                    results = scopedContext
                }
            }
            Self.pipelineSignposter.endInterval("Retrieval", retrievalSignpost)
            let retrievalMilliseconds = Int(
                Date().timeIntervalSince(retrievalStartedAt) * 1_000
            )
            Self.pipelineLogger.debug(
                "retrieval_ms=\(retrievalMilliseconds) sources=\(results.count)"
            )
            let orientation = await orientationRequest
            let availability = await availabilityRequest
            guard self.isCurrentWork(workID) else { return }
            self.modelAvailability = availability
            guard let preparedPublication = await self.validatedPublication(
                results,
                workID: workID
            ) else {
                guard self.isCurrentWork(workID) else { return }
                self.finishStaleGroundedWork(
                    prompt: prompt,
                    exchangeID: exchangeID,
                    workID: workID
                )
                return
            }
            results = preparedPublication.sources
            await self.recordPreparedRequest(
                snapshot: requestSummarySnapshot,
                passages: results
            )
            guard self.isCurrentWork(workID) else { return }

            if results.isEmpty, allowsGeneralKnowledge == false {
                guard let publication = await self.validatedPublication(
                    results,
                    workID: workID
                ) else {
                    guard self.isCurrentWork(workID) else { return }
                    self.finishStaleGroundedWork(
                        prompt: prompt,
                        exchangeID: exchangeID,
                        workID: workID
                    )
                    return
                }
                guard self.commitValidatedPublication(
                    publication,
                    workID: workID,
                    { _ in
                        self.replaceExchange(
                            id: exchangeID,
                            with: AssistantExchange(
                                id: exchangeID,
                                question: prompt,
                                answer: "I couldn't find enough information in your notes. Try a more specific term or choose a notebook.",
                                mode: .ask,
                                phase: .complete,
                                outcome: .noResult
                            )
                        )
                        self.completeWork(workID)
                    }
                ) else {
                    guard self.isCurrentWork(workID) else { return }
                    self.finishStaleGroundedWork(
                        prompt: prompt,
                        exchangeID: exchangeID,
                        workID: workID
                    )
                    return
                }
                return
            }

            let groundedCacheContext: AssistantArtifactContext
            let groundedSnapshotHash: String
            let cachedGroundedArtifact: AssistantArtifactRecordV2?
            if resolvedScope == .library {
                groundedCacheContext = AssistantArtifactContext(
                    subject: .library,
                    scope: .library
                )
                groundedSnapshotHash = Self.evidenceSnapshotHash(results)
                cachedGroundedArtifact = await self.cachedGroundedArtifact(
                    task: assistantTask,
                    prompt: prompt,
                    snapshotHash: groundedSnapshotHash,
                    context: groundedCacheContext,
                    isEligible: canReuseGroundedArtifact
                )
            } else {
                groundedCacheContext = requestArtifactContext
                    ?? Self.artifactContext(
                        noteID: focusedItemID,
                        scope: resolvedScope,
                        pageID: pageID
                    )
                groundedSnapshotHash = requestSummarySnapshot?.contentHash
                    ?? Self.evidenceSnapshotHash(results)
                cachedGroundedArtifact = await scopedGroundedArtifactRequest
            }

            if let cachedGroundedArtifact {
                let currentSourceIDs = Set(results.map(\.id))
                let cachedSourceIDSet = Set(cachedGroundedArtifact.sourceIDs)
                let cachedIDsAreCurrent = cachedGroundedArtifact.sourceIDs.isEmpty == false
                    && cachedSourceIDSet.count == cachedGroundedArtifact.sourceIDs.count
                    && (resolvedScope != .library
                        || cachedSourceIDSet.isSubset(of: currentSourceIDs))
                let cachedSources = cachedIDsAreCurrent
                    ? await self.index.read(anchorIDs: cachedGroundedArtifact.sourceIDs)
                    : []
                let snapshotIsCurrent = if let requestContentSnapshot {
                    await self.index.isCurrent(requestContentSnapshot)
                } else {
                    true
                }
                guard self.isCurrentWork(workID) else { return }
                guard snapshotIsCurrent else {
                    self.finishStaleGroundedWork(
                        prompt: prompt,
                        exchangeID: exchangeID,
                        workID: workID
                    )
                    return
                }
                if cachedIDsAreCurrent,
                    cachedSources.count == cachedGroundedArtifact.sourceIDs.count,
                    let cachedAnswer = cachedGroundedArtifact.markdown
                        .assistantCanonicalNonempty {
                    let followUps = canPublishFollowUps
                        ? self.activeFollowUpSuggestions
                        : []
                    guard self.isCurrentWork(workID) else { return }
                    await self.beforeResultPublicationForTesting?()
                    guard self.isCurrentWork(workID) else { return }
                    guard let publication = await self.validatedPublication(
                        cachedSources,
                        workID: workID
                    ) else {
                        guard self.isCurrentWork(workID) else { return }
                        self.finishStaleGroundedWork(
                            prompt: prompt,
                            exchangeID: exchangeID,
                            workID: workID
                        )
                        return
                    }
                    guard self.commitValidatedPublication(
                        publication,
                        workID: workID,
                        { publicationSources in
                            self.replaceExchange(
                                id: exchangeID,
                                with: AssistantExchange(
                                    id: exchangeID,
                                    question: prompt,
                                    answer: cachedAnswer,
                                    sources: publicationSources,
                                    followUps: followUps,
                                    mode: .ask,
                                    phase: .complete
                                )
                            )
                            self.completeWork(workID)
                        }
                    ) else {
                        guard self.isCurrentWork(workID) else { return }
                        self.finishStaleGroundedWork(
                            prompt: prompt,
                            exchangeID: exchangeID,
                            workID: workID
                        )
                        return
                    }
                    return
                }
            }
            ) else {
                guard self.isCurrentWork(workID) else { return }
                self.finishStaleGroundedWork(
                    prompt: prompt,
                    exchangeID: exchangeID,
                    workID: workID
                )
                return
            }
            return
        }

        if results.isEmpty == false {
            guard let publication = await self.validatedPublication(
                results,
                workID: workID
            ) else {
                guard self.isCurrentWork(workID) else { return }
                self.finishStaleGroundedWork(
                    prompt: prompt,
                    exchangeID: exchangeID,
                    workID: workID
                )
                return
            }
            results = publication.sources
            let previewAnswer = Self.relevantPassagesPreview(from: results)
            guard self.commitValidatedPublication(
                publication,
                workID: workID,
                { publicationSources in
                    self.activePartialFreshnessReceipt = publication.freshnessReceipt
                    self.replaceExchange(
                        id: exchangeID,
                        with: AssistantExchange(
                            id: exchangeID,
                            question: prompt,
                            answer: previewAnswer,
                            sources: publicationSources,
                            mode: .ask,
                            phase: .streaming,
                            preliminaryResult: .relevantPassages
                        )
                    )
                    self.rememberDeterministicPreview(
                        answer: previewAnswer,
                        sources: publicationSources,
                        kind: .relevantPassages,
                        freshnessReceipt: publication.freshnessReceipt,
                        exchangeID: exchangeID,
                        workID: workID
                    )
                }
            ) else {
                guard self.isCurrentWork(workID) else { return }
                self.finishStaleGroundedWork(
                    prompt: prompt,
                    exchangeID: exchangeID,
                    workID: workID
                )
                return
            }
        }

        guard availability == .available else {
            guard let publication = await self.validatedPublication(
                results,
                workID: workID
            ) else {
                guard self.isCurrentWork(workID) else { return }
                self.finishStaleGroundedWork(
                    prompt: prompt,
                    exchangeID: exchangeID,
                    workID: workID
                )
                return
            }
            guard self.commitValidatedPublication(
                publication,
                workID: workID,
                { publicationSources in
                    self.finishUnavailableAsk(
                        prompt: prompt,
                        results: publicationSources,
                        availability: availability,
                        canPublishFollowUps: canPublishFollowUps,
                        exchangeID: exchangeID,
                        workID: workID
                    )
                }
            ) else {
                guard self.isCurrentWork(workID) else { return }
                self.finishStaleGroundedWork(
                    prompt: prompt,
                    exchangeID: exchangeID,
                    workID: workID
                )
                return
            }
            return
        }

        self.activePartialSourceAuthority = Dictionary(
            results.map { ($0.id, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        self.armGenerationWatchdog(exchangeID: exchangeID, workID: workID)
        if self.requestDeadlineOverrideForTesting == nil,
            ContinuousClock().now.advanced(
                by: Self.generationAdmissionWindow
            ) >= modelDeadline {
            // Do not begin a model stream that cannot possibly finish and
            // validate before the hard cap. The verified quick result is a
            // complete, calm outcome rather than a flash of doomed prose.
            await self.finishRequestAtDeadline(
                task: assistantTask,
                scope: resolvedScope,
                prompt: prompt,
                exchangeID: exchangeID,
                workID: workID
            )
            return
        }

        let generationStartedAt = Date()
        do {
            let generationSignpost = Self.pipelineSignposter.beginInterval(
                "Generation",
                id: requestSignpostID
            )
            defer {
                Self.pipelineSignposter.endInterval(
                    "Generation",
                    generationSignpost
                )
            }
            self.workPhase = .thinkingThroughNotes
            let initialSourceIDs = Set(results.map(\.id))
            let request = self.makeModelRequest(
                task: assistantTask,
                question: prompt,
                scope: resolvedScope,
                itemID: focusedItemID,
                pageID: pageID,
                revision: revision,
                results: results,
                priorTurns: Array(priorTurns.suffix(4)),
                cachedOrientation: orientation,
                allowsGeneralKnowledge: allowsGeneralKnowledge,
                deadline: modelDeadline
            )
            let response = try await self.modelClient.respond(
                to: request,
                onPartialAnswer: { [weak self] partialAnswer in
                    await self?.queuePartialAnswer(
                        partialAnswer,
                        hiding: initialSourceIDs,
                        allowsGeneralKnowledge: allowsGeneralKnowledge,
                        exchangeID: exchangeID,
                        workID: workID
                    )
                }
            )
            self.armFinalizationWatchdog(
                exchangeID: exchangeID,
                workID: workID
            )
            try Task.checkCancellation()
            if let requestContentSnapshot,
                await self.index.isCurrent(requestContentSnapshot) == false {
                guard self.isCurrentWork(workID) else { return }
                self.finishStaleGroundedWork(
                    prompt: prompt,
                    exchangeID: exchangeID,
                    workID: workID
                )
                return
            }
            let cited = await self.index.read(anchorIDs: response.sourceIDs)
            guard self.isCurrentWork(workID) else { return }
            self.workPhase = .finishingUp
            let responseSourceIDs = Set(response.sourceIDs)
            let citedSourceIDs = Set(cited.map(\.id))
            let groundedAnswerIsValid = response.sourceIDs.isEmpty == false
                && responseSourceIDs.count == response.sourceIDs.count
                && responseSourceIDs.isSubset(of: initialSourceIDs)
                && citedSourceIDs == responseSourceIDs
            let responseProvenanceIsValid: Bool
            let normalizedOutcome: AssistantAnswerOutcome
            if response.isGeneralKnowledge {
                // The production client emits `.generalKnowledge`, while
                // alternate/test clients may retain the legacy `.answered`
                // outcome. The explicit provenance bit is authoritative,
                // but general-knowledge text must be opted into and carry
                // no note citations.
                responseProvenanceIsValid = allowsGeneralKnowledge
                    && response.sourceIDs.isEmpty
                    && response.outcome != .insufficientEvidence
                normalizedOutcome = .generalKnowledge
            } else if response.outcome == .generalKnowledge {
                responseProvenanceIsValid = false
                normalizedOutcome = .insufficientEvidence
            } else {
                responseProvenanceIsValid = response.outcome != .answered
                    || groundedAnswerIsValid
                normalizedOutcome = response.outcome
            }
            let effectiveOutcome: AssistantAnswerOutcome = responseProvenanceIsValid
                ? normalizedOutcome
                : .insufficientEvidence
            let rankedSourcesByID = Dictionary(
                results.map { ($0.id, $0) },
                uniquingKeysWith: { current, _ in current }
            )
            let answerSources: [AssistantSearchResult] = effectiveOutcome == .answered
                ? cited.map { current in
                    guard let ranked = rankedSourcesByID[current.id] else { return current }
                    return AssistantReferenceNormalizer.refreshing(
                        current: current,
                        preserving: ranked
                    )
                }
                : []
            let hiddenSourceIDs = initialSourceIDs.union(response.sourceIDs)
            let answer: String
            let exchangeOutcome: AssistantExchangeOutcome
            if effectiveOutcome == .insufficientEvidence {
                answer = "I couldn't find enough information in your notes. Try a more specific term or choose a notebook."
                exchangeOutcome = .noResult
            } else {
                let readableAnswer = AssistantAnswerSanitizer.sanitize(
                    response.answer,
                    removingSourceIDs: hiddenSourceIDs,
                    canonicalStudyDocument: response.textAuthority == .appCanonicalStudy
                ).assistantCanonicalNonempty
                answer = readableAnswer
                    ?? "I couldn't produce a readable answer. Try asking in a different way."
                exchangeOutcome = readableAnswer == nil ? .failure : .content
            }
            // Follow-up chips are opportunistic. The complete, validated
            // model answer is always committed immediately even if local
            // suggestion work is still queued behind another CPU task.
            let followUps = effectiveOutcome == .answered && canPublishFollowUps
                ? self.activeFollowUpSuggestions
                : []
            await self.beforeResultPublicationForTesting?()
            guard self.isCurrentWork(workID) else { return }
            let publicationEvidence = effectiveOutcome == .answered
                ? answerSources
                : results
            guard let publication = await self.validatedPublication(
                publicationEvidence,
                workID: workID
            ) else {
                guard self.isCurrentWork(workID) else { return }
                self.finishStaleGroundedWork(
                    prompt: prompt,
                    exchangeID: exchangeID,
                    workID: workID
                )
                return
            }
            let publicationAnswerSources = effectiveOutcome == .answered
                ? publication.sources
                : []
            guard self.commitValidatedPublication(
                publication,
                workID: workID,
                { _ in
                    self.drainStreamPresentation(
                        toward: answer,
                        exchangeID: exchangeID,
                        workID: workID
                    )
                    self.discardPendingStreamUpdate()
                    self.replaceExchange(
                        id: exchangeID,
                        with:
                        AssistantExchange(
                            id: exchangeID,
                            question: prompt,
                            answer: answer,
                            sources: publicationAnswerSources,
                            followUps: followUps,
                            isGeneralKnowledge: effectiveOutcome == .generalKnowledge,
                            mode: .ask,
                            phase: .complete,
                            outcome: exchangeOutcome
                        )
                    )
                }
            ) else {
                guard self.isCurrentWork(workID) else { return }
                self.finishStaleGroundedWork(
                    prompt: prompt,
                    exchangeID: exchangeID,
                    workID: workID
                )
                return
            }
            let generationMilliseconds = Int(
                Date().timeIntervalSince(generationStartedAt) * 1_000
            )
            Self.pipelineLogger.debug(
                "generation_ms=\(generationMilliseconds) cited_sources=\(publicationAnswerSources.count)"
            )
            let hasCacheableGroundedAnswer = effectiveOutcome == .answered
                && exchangeOutcome == .content
            let shouldStoreStudy = canReuseStudyArtifact
                && hasCacheableGroundedAnswer
                && publicationAnswerSources.isEmpty == false
                && requestSummarySnapshot != nil
                && requestArtifactContext != nil
            let shouldStoreGrounded = canReuseGroundedArtifact
                && shouldStoreStudy == false
                && hasCacheableGroundedAnswer
                && publicationAnswerSources.isEmpty == false
            let intelligenceSnapshot = hasCacheableGroundedAnswer
                ? requestSummarySnapshot
                : nil
            let intelligenceContext = hasCacheableGroundedAnswer
                ? requestArtifactContext
                : nil
            let sourceIDs = publicationAnswerSources.map(\.id)
            let groundedSubjectRevision = requestSummarySnapshot?.revision
                ?? Int64(results.map(\.anchor.generation).max() ?? 0)
            self.completeWork(workID)
            self.scheduleGroundedCompletionMaintenance(
                assistantTask: assistantTask,
                prompt: prompt,
                answer: answer,
                sourceIDs: sourceIDs,
                shouldStoreStudy: shouldStoreStudy,
                shouldStoreGrounded: shouldStoreGrounded,
                intelligenceSnapshot: intelligenceSnapshot,
                intelligenceContext: intelligenceContext,
                groundedSnapshotHash: groundedSnapshotHash,
                groundedSubjectRevision: groundedSubjectRevision,
                groundedCacheContext: groundedCacheContext
            )
        } catch is CancellationError {
            await self.finishCancelledWork(workID, exchangeID: exchangeID)
        } catch AssistantModelClientError.cancelled {
            await self.finishCancelledWork(workID, exchangeID: exchangeID)
        } catch AssistantModelClientError.timedOut {
            guard self.isCurrentWork(workID) else { return }
            self.flushPendingStreamUpdate()
            let partialSnapshot = self.activePartialSnapshot(
                exchangeID: exchangeID,
                workID: workID
            )
            // Preserve the newest complete streamed sentence. The source
            // tuple is validated before the broader retrieval preview, so
            // unrelated evidence churn cannot discard a still-current
            // cited passage (or explicit general-knowledge response).
            let validatedPartial: AssistantValidatedPartialSourceSet?
            if let partialSnapshot {
                await self.beforePartialProvenanceValidationForTesting?()
                validatedPartial = await self.validatedSourcesForActivePartial(
                    partialSnapshot,
                    workID: workID
                )
            } else {
                validatedPartial = nil
            }
            guard self.isCurrentWork(workID) else { return }
            let partialSources = validatedPartial?.sources ?? []
            // The exchange may still contain the app-owned quick preview.
            // Preserve it through the dedicated fallback path, never by
            // mistaking it for model-authored streamed prose.
            let partialAnswer = validatedPartial != nil
                ? Self.preservedDeadlineAnswer(
                    from: partialSnapshot?.answer
                )
                : nil
            self.discardPendingStreamUpdate()
            let fallbackPublication: AssistantValidatedSourceSet?
            if partialAnswer == nil {
                guard let validated = await self.validatedPublication(
                    results,
                    workID: workID
                ) else {
                    guard self.isCurrentWork(workID) else { return }
                    self.finishStaleGroundedWork(
                        prompt: prompt,
                        exchangeID: exchangeID,
                        workID: workID
                    )
                    return
                }
                fallbackPublication = validated
            } else {
                fallbackPublication = nil
            }
            guard self.isCurrentWork(workID) else { return }
            let publicationSources = fallbackPublication?.sources ?? []
            let answer = partialAnswer ?? Self.groundedFallbackAnswer(
                from: publicationSources,
                timedOut: true
            )
            let finalSources = partialAnswer == nil
                ? publicationSources
                : partialSources
            let followUps = partialAnswer != nil
                && partialSnapshot?.isGeneralKnowledge == false
                && finalSources.isEmpty == false
                && canPublishFollowUps
                ? self.activeFollowUpSuggestions
                : []
            guard self.isCurrentWork(workID) else { return }
            let terminal = AssistantImmediateTerminalContent(
                answer: answer,
                sources: finalSources,
                isGeneralKnowledge: partialAnswer != nil
                    && partialSnapshot?.isGeneralKnowledge == true,
                preliminaryResult: partialAnswer == nil
                    && publicationSources.isEmpty == false
                    ? .relevantPassages
                    : nil,
                freshnessReceipt: partialAnswer != nil
                    ? validatedPartial?.freshnessReceipt
                    : fallbackPublication?.freshnessReceipt
            )
            guard terminal.performIfCurrent({
                guard self.isCurrentWork(workID) else { return }
                self.replaceExchange(
                    id: exchangeID,
                    with: AssistantExchange(
                        id: exchangeID,
                        question: prompt,
                        answer: terminal.answer,
                        sources: terminal.sources,
                        followUps: followUps,
                        isGeneralKnowledge: terminal.isGeneralKnowledge,
                        mode: .ask,
                        phase: .complete,
                        outcome: partialAnswer == nil ? .failure : .content,
                        preliminaryResult: terminal.preliminaryResult
                    )
                )
            }) else {
                guard self.isCurrentWork(workID) else { return }
                self.finishStaleGroundedWork(
                    prompt: prompt,
                    exchangeID: exchangeID,
                    workID: workID
                )
                return
            }
            if partialAnswer == nil {
                Self.pipelineLogger.notice("generation timed out; local fallback shown")
            } else {
                Self.pipelineLogger.notice("generation timed out; complete streamed prose retained")
            }
            self.status = AssistantStatus(
                message: partialAnswer != nil
                    ? "Generation ended early, so I kept the completed part of the response and any verified passages already available."
                    : publicationSources.isEmpty
                        ? AssistantModelClientError.timedOut.localizedDescription
                        : "Generation ended early, so I kept the verified passages already available on this iPad.",
                severity: partialAnswer != nil || publicationSources.isEmpty == false
                    ? .information
                    : .warning,
                action: .retry
            )
            self.completeWork(workID)
            self.refreshPrewarmAfterFailure()
        } catch {
            guard self.isCurrentWork(workID) else { return }
            self.flushPendingStreamUpdate()
            let partialSnapshot = self.activePartialSnapshot(
                exchangeID: exchangeID,
                workID: workID
            )
            let validatedPartial: AssistantValidatedPartialSourceSet?
            if let partialSnapshot {
                await self.beforePartialProvenanceValidationForTesting?()
                validatedPartial = await self.validatedSourcesForActivePartial(
                    partialSnapshot,
                    workID: workID
                )
            } else {
                validatedPartial = nil
            }
            guard self.isCurrentWork(workID) else { return }
            let partialSources = validatedPartial?.sources ?? []
            let partialAnswer = validatedPartial != nil
                ? Self.preservedInterruptedAnswer(
                    from: partialSnapshot?.answer,
                    hasSources: partialSources.isEmpty == false
                )
                : nil
            let fallbackPublication: AssistantValidatedSourceSet?
            if partialAnswer == nil {
                guard let validated = await self.validatedPublication(
                    results,
                    workID: workID
                ) else {
                    guard self.isCurrentWork(workID) else { return }
                    self.finishStaleGroundedWork(
                        prompt: prompt,
                        exchangeID: exchangeID,
                        workID: workID
                    )
                    return
                }
                fallbackPublication = validated
            } else {
                fallbackPublication = nil
            }
            let publicationSources = fallbackPublication?.sources ?? []
            let finalSources = partialAnswer == nil
                ? publicationSources
                : partialSources
            let followUps = finalSources.isEmpty
                || partialSnapshot?.isGeneralKnowledge == true
                || canPublishFollowUps == false
                ? []
                : self.activeFollowUpSuggestions
            guard self.isCurrentWork(workID) else { return }
            self.discardPendingStreamUpdate()
            let terminal = AssistantImmediateTerminalContent(
                answer: partialAnswer ?? Self.groundedFallbackAnswer(
                    from: publicationSources,
                    timedOut: false
                ),
                sources: finalSources,
                isGeneralKnowledge: partialAnswer != nil
                    && partialSnapshot?.isGeneralKnowledge == true,
                preliminaryResult: partialAnswer == nil
                    && publicationSources.isEmpty == false
                    ? .relevantPassages
                    : nil,
                freshnessReceipt: partialAnswer != nil
                    ? validatedPartial?.freshnessReceipt
                    : fallbackPublication?.freshnessReceipt
            )
            guard terminal.performIfCurrent({
                guard self.isCurrentWork(workID) else { return }
                self.replaceExchange(
                    id: exchangeID,
                    with: AssistantExchange(
                        id: exchangeID,
                        question: prompt,
                        answer: terminal.answer,
                        sources: terminal.sources,
                        followUps: followUps,
                        isGeneralKnowledge: terminal.isGeneralKnowledge,
                        mode: .ask,
                        phase: .complete,
                        outcome: partialAnswer == nil ? .failure : .content,
                        preliminaryResult: terminal.preliminaryResult
                    )
                )
            }) else {
                guard self.isCurrentWork(workID) else { return }
                self.finishStaleGroundedWork(
                    prompt: prompt,
                    exchangeID: exchangeID,
                    workID: workID
                )
                return
            }
            if partialAnswer != nil {
                Self.pipelineLogger.notice(
                    "generation failed after streaming; complete prose retained"
                )
            } else {
                Self.pipelineLogger.error("generation failed; local fallback shown")
            }
            self.status = if partialAnswer != nil {
                AssistantStatus(
                    message: "Generation stopped, so I kept the complete response text and any verified passages already available.",
                    severity: .information
                )
            } else if publicationSources.isEmpty {
                AssistantStatus(
                    message: error.localizedDescription,
                    severity: .error,
                    action: .retry
                )
            } else {
                AssistantStatus(
                    message: "I kept the verified passages after on-device generation stopped.",
                    severity: .information
                )
            }
            self.completeWork(workID)
            self.refreshPrewarmAfterFailure()
        }
    }

    public func cancel() {
        // Editor teardown also calls cancel when no response is active. Warmup
        // and post-response maintenance can otherwise retain this presentation,
        // its index, and model resources after the editor has been dismissed.
        cancelDisposableBackgroundWork()
        guard let workID = activeWorkID,
              let exchangeID = activeExchangeID else { return }
        finishManualStopImmediately(workID: workID, exchangeID: exchangeID)
    }

    private func cancelDisposableBackgroundWork() {
        prewarmTask?.cancel()
        prewarmTask = nil
        maintenanceTask?.cancel()
        maintenanceTask = nil
        sourceNavigationTask?.cancel()
        sourceNavigationTask = nil
        sourceNavigationRequestID = nil
    }

    /// Registers one request-scoped client-wide cancellation on this panel's
    /// ordered coordinatorlane. The coordinator owns the process-wide tell
    /// ordered coordinator lane. The coordinator owns the process-wide tail
    /// and rejects this operation if another panel already owns admission.
    @discardableResult
    private func enqueueModelCancellation(requestID: UUID) -> Task<Void, Never> {
        let predecessor = pipelinePublicationTail
        let task = Task { [pipelineCoordinator, modelClient] in
            await predecessor?.value
            await pipelineCoordinator.cancelModelSession(
                for: requestID,
                cancellation: {
                    await modelClient.cancel()
                }
            )
        }
        pipelinePublicationTail = task
        return task
    }

    private func cancelFromPipelinePreemption(requestID: UUID) {
        guard activePipelineRequest?.requestID == requestID else { return }
        // Admission of the replacement request owns client-wide cancellation
        // ordering. The provider independently fences its physical model lane;
        // scheduling another cancel from the displaced panel can otherwise
        // arrive late and cancel the newly admitted generation.
        cancelLocallyForPipelinePreemption()
    }

    private func cancelLocallyForPipelinePreemption() {
        if activeWorkID != nil {
            Self.pipelineSignposter.emitEvent("Cancellation")
        }
        requestDeadlineTask?.cancel()
        requestDeadlineTask = nil
        activeWatchdogDeadline = nil
        activeFollowUpTask?.cancel()
        activeFollowUpTask = nil
        activeFollowUpSuggestions = []
        cancelResponsePresentation()
        let exchangeID = activeExchangeID
        activeWorkID = nil
        workTask?.cancel()
        workTask = nil
        discardPendingStreamUpdate()
        activePublicationContext = nil
        activeDeterministicPreview = nil
        activePartialSourceAuthority = [:]
        activePartialFreshnessReceipt = nil
        if let exchangeID,
            let current = exchanges.first(where: { $0.id == exchangeID }),
            current.phase != .complete,
            current.phase != .stopped {
            replaceExchange(
                id: exchangeID,
                with: AssistantExchange(
                    id: exchangeID,
                    question: current.question,
                    answer: "Stopped.",
                    sources: [],
                    followUps: [],
                    mode: current.mode,
                    phase: .stopped,
                    outcome: .failure
                )
            )
        }
        status = AssistantStatus(
            message: "Response stopped. You can retry when you're ready.",
            severity: .information,
            action: .retry
        )
        activeExchangeID = nil
        activePipelineRequest = nil
        isWorking = false
        workPhase = nil
        cancelProgressPresentation()
    }

    private func finishManualStopImmediately(
        workID: UUID,
        exchangeID: UUID
    ) {
        guard isCurrentWork(workID), activeExchangeID == exchangeID else { return }
        Self.pipelineSignposter.emitEvent("Cancellation")
        requestDeadlineTask?.cancel()
        requestDeadlineTask = nil
        activeWatchdogDeadline = nil
        activeFollowUpTask?.cancel()
        activeFollowUpTask = nil
        activeFollowUpSuggestions = []
        cancelResponsePresentation()
        flushPendingStreamUpdate()

        let partial = activePartialSnapshot(
            exchangeID: exchangeID,
            workID: workID
        )
        let preview = activeDeterministicPreview.flatMap {
            $0.workID == workID && $0.exchangeID == exchangeID ? $0 : nil
        }
        let pipelineRequestID = activePipelineRequest?.requestID
        workTask?.cancel()
        workTask = nil
        if let pipelineRequestID {
            enqueueModelCancellation(requestID: pipelineRequestID)
        }
        guard let current = exchanges.first(where: { $0.id == exchangeID }) else { return }
        discardPendingStreamUpdate()
        var candidates: [AssistantImmediateTerminalContent] = []
        if let partial {
            let sources = current.task == .summarize && partial.sources.count > 8
                ? Self.evenlySampled(partial.sources, limit: 8)
                : partial.sources
            candidates.append(AssistantImmediateTerminalContent(
                answer: partial.answer,
                sources: sources,
                isGeneralKnowledge: partial.isGeneralKnowledge,
                preliminaryResult: nil,
                freshnessReceipt: partial.freshnessReceipt
            ))
        }
        if let preview {
            candidates.append(AssistantImmediateTerminalContent(
                answer: preview.answer,
                sources: preview.sources,
                isGeneralKnowledge: false,
                preliminaryResult: preview.kind,
                freshnessReceipt: preview.freshnessReceipt
            ))
        }

        var retainedContent: AssistantImmediateTerminalContent?
        for candidate in candidates where retainedContent == nil {
            let published = candidate.performIfCurrent {
                replaceExchange(
                    id: exchangeID,
                    with: AssistantExchange(
                        id: exchangeID,
                        question: current.question,
                        answer: candidate.answer,
                        sources: candidate.sources,
                        followUps: [],
                        isGeneralKnowledge: candidate.isGeneralKnowledge,
                        mode: current.mode,
                        phase: .stopped,
                        outcome: .content,
                        preliminaryResult: candidate.preliminaryResult,
                        summaryProvenance: Self.retainedSummaryProvenance(
                            task: current.task,
                            preliminaryResult: candidate.preliminaryResult
                        ),
                        task: current.task,
                        scope: current.scope,
                        scopeTitle: current.scopeTitle
                    )
                )
            }
            if published { retainedContent = candidate }
        }
        if retainedContent == nil {
            replaceExchange(
                id: exchangeID,
                with: AssistantExchange(
                    id: exchangeID,
                    question: current.question,
                    answer: "Stopped.",
                    sources: [],
                    followUps: [],
                    mode: current.mode,
                    phase: .stopped,
                    outcome: .failure,
                    task: current.task,
                    scope: current.scope,
                    scopeTitle: current.scopeTitle
                )
            )
        }
        status = AssistantStatus(
            message: "Response stopped. You can retry when you're ready.",
            severity: .information,
            action: .retry
        )
        if let pipelineRequestID {
            enqueuePipelineUpdate(.stopped, requestID: pipelineRequestID)
        }
        activePublicationContext = nil
        activePartialSourceAuthority = [:]
        activePartialFreshnessReceipt = nil
        activeDeterministicPreview = nil
        activeWorkID = nil
        activeExchangeID = nil
        activePipelineRequest = nil
        isWorking = false
        workPhase = nil
        cancelProgressPresentation()
    }

    public func useQuickResult() {
        Task { @MainActor [weak self] in
            await self?.finishWithDeterministicPreview(requiredKind: nil)
        }
    }

    /// Stops generation and replaces any unvalidated model prose with the
    /// bounded, currently rehydrated evidence already attached to the active
    /// exchange. This is the deterministic escape hatch offered during a
    /// long-running grounded request.
    public func showRelevantPassages() {
        Task { @MainActor [weak self] in
            await self?.finishWithDeterministicPreview(
                requiredKind: .relevantPassages
            )
        }
    }

    private func finishWithDeterministicPreview(
        requiredKind: AssistantPreliminaryResultKind?
    ) async {
        guard let preview = activeDeterministicPreview,
              activeWorkID == preview.workID,
              activeExchangeID == preview.exchangeID,
              requiredKind == nil || preview.kind == requiredKind,
              let current = exchanges.first(where: { $0.id == preview.exchangeID }) else {
            return
        }
        guard let publication = await validatedPublication(
            preview.sources,
            workID: preview.workID
        ) else {
            guard isCurrentWork(preview.workID) else { return }
            finishStaleGroundedWork(
                prompt: current.question,
                exchangeID: preview.exchangeID,
                workID: preview.workID
            )
            return
        }

        let followUps = activeFollowUpSuggestions
        guard isCurrentWork(preview.workID) else { return }
        let requestID = activePipelineRequest?.requestID
        guard commitValidatedPublication(
            publication,
            workID: preview.workID,
            { publicationSources in
                requestDeadlineTask?.cancel()
                requestDeadlineTask = nil
                activeWatchdogDeadline = nil
                activeFollowUpTask?.cancel()
                activeFollowUpTask = nil
                activeFollowUpSuggestions = []
                workTask?.cancel()
                workTask = nil
                discardPendingStreamUpdate()
                replaceExchange(
                    id: preview.exchangeID,
                    with: AssistantExchange(
                        id: preview.exchangeID,
                        question: current.question,
                        answer: preview.answer,
                        sources: publicationSources,
                        followUps: followUps,
                        mode: current.mode,
                        phase: .complete,
                        preliminaryResult: preview.kind,
                        summaryProvenance: preview.kind == .quickSummary
                            ? .quickSummary
                            : nil
                    )
                )
            }
        ) else {
            guard isCurrentWork(preview.workID) else { return }
            finishStaleGroundedWork(
                prompt: current.question,
                exchangeID: preview.exchangeID,
                workID: preview.workID
            )
            return
        }
        activePublicationContext = nil
        activePartialSourceAuthority = [:]
        activePartialFreshnessReceipt = nil
        activeDeterministicPreview = nil
        activeWorkID = nil
        activeExchangeID = nil
        activePipelineRequest = nil
        isWorking = false
        workPhase = nil
        status = AssistantStatus(
            message: preview.kind == .relevantPassages
                ? "Showing the relevant passages found on this iPad."
                : "Using the verified quick summary.",
            severity: .information
        )
        cancelProgressPresentation()
        if let requestID {
            enqueueModelCancellation(requestID: requestID)
            enqueuePipelineUpdate(.completed, requestID: requestID)
        }
    }

    public func performStatusAction(_ action: AssistantStatusAction) {
        guard isWorking == false else { return }
        switch action {
        case .retry:
            guard let exchange = exchanges.last else { return }
            requestMode = exchange.mode
            submitSuggestion(exchange.question)
        case .chooseNotebook:
            scope = .item
            status = nil
            focusComposer()
        }
    }

    public func openSource(_ anchor: AssistantSourceAnchor) {
        status = nil
        sourceNavigationTask?.cancel()
        let requestID = UUID()
        sourceNavigationRequestID = requestID
        sourceNavigationTask = Task { @MainActor [weak self, index] in
            let resolution = await index.resolve(anchor: anchor)
            guard let self,
                Task.isCancelled == false,
                self.sourceNavigationRequestID == requestID else { return }
            self.sourceNavigationTask = nil
            self.sourceNavigationRequestID = nil
            switch resolution {
            case let .current(result):
                self.navigateToSource(result.anchor)
            case .stale:
                self.status = AssistantStatus(
                    message: "That source changed after this answer was created. Search again to refresh it.",
                    severity: .warning,
                    action: .retry
                )
            }
        }
    }

    private func requestPrewarmIfNeeded(force: Bool = false) {
        guard prewarmTask == nil else { return }
        let now = prewarmClock.now
        if force == false,
            let lastPrewarmAt,
            now - lastPrewarmAt < Self.prewarmLease {
            return
        }

        prewarmTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer { self.prewarmTask = nil }
            let availability = await self.modelClient.availability()
            guard Task.isCancelled == false else { return }
            self.modelAvailability = availability
            guard availability == .available else {
                return
            }
            do {
                try await self.modelClient.prewarm()
                guard Task.isCancelled == false else { return }
                self.lastPrewarmAt = self.prewarmClock.now
            } catch {
                // A later focus/open signal may retry after model assets or the
                // single-session actor becomes available again.
            }
        }
    }

    private func refreshPrewarmAfterFailure() {
        guard isPresented else { return }
        requestPrewarmIfNeeded(force: true)
    }

    /// A retrieval result is still valuable when generation is interrupted.
    /// The answer stays a concise status because the verbatim evidence is
    /// already available in the structured reference rows below it.
    static func groundedFallbackAnswer(
        from results: [AssistantSearchResult],
        timedOut: Bool
    ) -> String {
        let references = AssistantReferenceNormalizer.referencesForPresentation(results)
        guard references.isEmpty == false else {
            return timedOut
                ? "The on-device answer is taking longer than expected. Try a shorter question or use Find for an immediate local search."
                : "I couldn't finish the on-device answer. Try a shorter question or use Find for an immediate local search."
        }

        let countDescription = references.count == 1
            ? "1 relevant passage"
            : "\(references.count) relevant passages"
        return timedOut
            ? "The on-device answer took too long. I kept \(countDescription) below."
            : "The on-device answer stopped. I kept \(countDescription) below."
    }

    static func relevantPassagesPreview(
        from results: [AssistantSearchResult]
    ) -> String {
        let references = AssistantReferenceNormalizer.referencesForPresentation(results)
        guard references.isEmpty == false else {
            return "I'm checking the current note for supporting details."
        }
        return references.count == 1
            ? "Found 1 relevant passage in your notes."
            : "Found \(references.count) relevant passages in your notes."
    }

    private static func explicitlyRequestsGeneralKnowledge(_ prompt: String) -> Bool {
        let normalized = prompt
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
        let phrases = [
            "general knowledge", "outside my notes", "outside the notes",
            "not limited to my notes", "use what you know", "from your knowledge",
        ]
        return phrases.contains(where: normalized.contains)
    }

    private func automaticRequestMode(for prompt: String) -> AssistantRequestMode {
        var normalized = prompt
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split { $0.isWhitespace || $0.isPunctuation }
            .joined(separator: " ")

        let conversationalPrefixes = [
            "please",
            "can you",
            "could you",
            "would you",
            "will you",
        ]
        var removedPrefix = true
        while removedPrefix {
            removedPrefix = false
            for prefix in conversationalPrefixes where normalized.hasPhrasePrefix(prefix) {
                normalized.removeFirst(prefix.count)
                normalized = normalized.trimmingCharacters(in: .whitespaces)
                removedPrefix = true
                break
            }
        }

        let answerPrefixes = [
            "explain",
            "summarize",
            "summarise",
            "analyze",
            "analyse",
            "compare",
            "why",
            "how",
            "what is",
            "what are",
            "tell me about",
        ]
        if answerPrefixes.contains(where: normalized.hasPhrasePrefix) {
            return .ask
        }

        let findPrefixes = [
            "find",
            "search",
            "locate",
            "where did i",
            "where have i",
            "which page",
            "take me to",
            "show me where",
        ]
        return findPrefixes.contains(where: normalized.hasPhrasePrefix) ? .find : .ask
    }

    private func modelScopeLabel(
        scope: AssistantScope,
        itemID: UUID,
        pageID: UUID?,
        revision: UInt64
    ) -> String {
        var components = [scope.rawValue, itemID.uuidString, "revision-\(revision)"]
        if scope == .page {
            components.append(pageID?.uuidString ?? "no-page")
        }
        return components.joined(separator: ":")
    }

    private static func requestsBroadScopedContext(_ prompt: String) -> Bool {
        let normalized = prompt
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let overviewPhrases = [
            "describe",
            "summarize",
            "summary",
            "overview",
            "what is this",
            "what are these",
            "tell me about",
            "main points",
            "key points",
            "main ideas",
        ]
        return overviewPhrases.contains(where: normalized.localizedCaseInsensitiveContains)
    }

    /// Explicit general-knowledge prompts should not silently pull the active
    /// notebook into a broad-context request just because they contain a phrase
    /// such as "tell me about." Only an actual reference to the selected note,
    /// notebook, or page opts that request back into scoped context.
    private static func requestsExplicitScopedOverview(_ prompt: String) -> Bool {
        let normalized = prompt
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
        let scopedReferences = [
            "this note", "these notes", "my notes", "current note",
            "this notebook", "my notebook", "current notebook",
            "this page", "current page", "on this page", "written here",
        ]
        return scopedReferences.contains(where: normalized.contains)
    }

    private static func substantiveGroundingEvidence(
        _ results: [AssistantSearchResult]
    ) -> [AssistantSearchResult] {
        results.filter { $0.anchor.kind != .metadata }
    }

    private func beginFreshConversationContext() {
        cancel()
        indexRevision &+= 1
        conversationID = UUID()
        // Keep the transcript visible, but do not feed answers grounded in an
        // older index revision back into a fresh model session.
        conversationContextStartIndex = exchanges.count
    }

    @discardableResult
    private func appendPendingExchange(
        question: String,
        mode: AssistantRequestMode,
        task: AssistantTask,
        scope: AssistantScope,
        scopeTitle: String
    ) -> UUID {
        trimTerminalExchangesToMakeRoomForSubmission()
        let exchange = AssistantExchange(
            question: question,
            answer: "",
            mode: mode,
            phase: .waiting,
            task: task,
            scope: scope,
            scopeTitle: scopeTitle
        )
        exchanges.append(exchange)
        return exchange.id
    }

    /// Makes one transcript slot available without discarding work that is
    /// still waiting or streaming. Removing rows before the current model
    /// context boundary shifts that boundary left by the same amount so a
    /// fresh conversation does not accidentally skip newer retained turns.
    private func trimTerminalExchangesToMakeRoomForSubmission() {
        let removalTarget = exchanges.count - Self.maximumRetainedExchangeCount + 1
        guard removalTarget > 0 else { return }

        var retained: [AssistantExchange] = []
        retained.reserveCapacity(exchanges.count - min(removalTarget, exchanges.count))
        var remainingRemovalCount = removalTarget
        var removalsBeforeContext = 0

        for (index, exchange) in exchanges.enumerated() {
            let isTerminal = exchange.phase == .complete || exchange.phase == .stopped
            if remainingRemovalCount > 0, isTerminal {
                remainingRemovalCount -= 1
                if index < conversationContextStartIndex {
                    removalsBeforeContext += 1
                }
            } else {
                retained.append(exchange)
            }
        }

        guard retained.count != exchanges.count else { return }
        exchanges = retained
        conversationContextStartIndex = min(
            conversationContextStartIndex - removalsBeforeContext,
            exchanges.count
        )
    }

    private func scheduleProgressPresentation(for workID: UUID) {
        progressPresentationTask?.cancel()
        longerRunningTask?.cancel()
        longRunningActionsTask?.cancel()
        progressPresentationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
            guard let self, self.isCurrentWork(workID) else { return }
            self.showsProgress = true
        }
        longerRunningTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch {
                return
            }
            guard let self, self.isCurrentWork(workID) else { return }
            self.isTakingLonger = true
        }
        longRunningActionsTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(
                    for: AssistantProgressPresentationPolicy.deterministicEscapeDelay
                )
            } catch {
                return
            }
            guard let self, self.isCurrentWork(workID) else { return }
            self.showsLongRunningActions = true
        }
    }

    /// Gives the submitted row a brief anti-flash floor without describing
    /// synthetic stages or delaying any underlying work. Real pipeline phases
    /// take over after 180 ms; a cache hit can settle underneath this floor.
    private func startResponsePresentation(
        requestID: UUID,
        exchangeID: UUID,
        task: AssistantTask,
        scope: AssistantScope,
        scopeTitle: String
    ) {
        responsePresentationTask?.cancel()
        responsePresentationTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(180))
            } catch {
                return
            }
            guard let self,
                self.responsePresentation?.requestID == requestID,
                self.responsePresentation?.exchangeID == exchangeID else { return }
            self.responsePresentation = nil
            self.responsePresentationTask = nil
        }
    }

    /// Stop, note invalidation, and request replacement reveal whatever is
    /// already safe to show instead of leaving a cosmetic delay behind.
    private func cancelResponsePresentation() {
        responsePresentationTask?.cancel()
        responsePresentationTask = nil
        responsePresentation = nil
    }

    private func cancelProgressPresentation() {
        progressPresentationTask?.cancel()
        progressPresentationTask = nil
        longerRunningTask?.cancel()
        longerRunningTask = nil
        longRunningActionsTask?.cancel()
        longRunningActionsTask = nil
        showsProgress = false
        isTakingLonger = false
        showsLongRunningActions = false
    }

    /// Enforces the route deadline from the moment the user submits, rather
    /// than only around model generation. Snapshotting, cache reads, retrieval,
    /// and save checkpoints are therefore unable to strand the UI indefinitely.
    private func scheduleRequestDeadline(
        task: AssistantTask,
        scope: AssistantScope,
        prompt: String,
        deadline: ContinuousClock.Instant,
        exchangeID: UUID,
        workID: UUID
    ) {
        requestDeadlineTask?.cancel()
        activeWatchdogToken &+= 1
        let watchdogToken = activeWatchdogToken
        activeWatchdogDeadline = deadline
        requestDeadlineTask = Task { @MainActor [weak self] in
            let clock = ContinuousClock()
            do {
                try await clock.sleep(until: deadline)
            } catch {
                return
            }
            guard let self,
                self.activeWorkID == workID,
                self.activeWatchdogToken == watchdogToken,
                self.activeWatchdogDeadline == deadline else { return }
            await self.finishRequestAtDeadline(
                task: task,
                scope: scope,
                prompt: prompt,
                exchangeID: exchangeID,
                workID: workID,
                expectedWatchdogToken: watchdogToken
            )
        }
    }

    /// Preparation can consume a meaningful part of the submission budget.
    /// Once generation is actually admitted, ensure it has a real first-token
    /// window without ever moving beyond the request's absolute cap.
    private func armGenerationWatchdog(exchangeID: UUID, workID: UUID) {
        guard isCurrentWork(workID),
            activeExchangeID == exchangeID,
            let request = activePipelineRequest,
            request.requestID == workID else { return }
        let candidate = min(
            request.deadline,
            ContinuousClock().now.advanced(
                by: generationNoOutputGraceOverrideForTesting
                    ?? Self.generationNoOutputGrace
            )
        )
        guard ContinuousClock().now < candidate else { return }
        if let current = activeWatchdogDeadline, candidate <= current { return }
        scheduleRequestDeadline(
            task: request.task,
            scope: request.scope,
            prompt: request.prompt,
            deadline: candidate,
            exchangeID: exchangeID,
            workID: workID
        )
    }

    /// A cumulative stream snapshot proves that the session is alive. The
    /// watchdog therefore tracks a short period of inactivity after real text,
    /// while the immutable request deadline remains the hard upper bound.
    private func refreshWatchdogAfterStreamProgress(
        exchangeID: UUID,
        workID: UUID
    ) {
        guard isCurrentWork(workID),
            activeExchangeID == exchangeID,
            let request = activePipelineRequest,
            request.requestID == workID else { return }
        let now = ContinuousClock().now
        let inactivityGrace = streamInactivityGraceOverrideForTesting
            ?? (request.task == .summarize
                ? Self.summaryPresentationInactivityGrace
                : Self.streamInactivityGrace)
        let progressCandidate = min(
            request.deadline,
            now.advanced(by: inactivityGrace)
        )
        guard now < progressCandidate else { return }

        // A fast first token must never shorten the longer no-output lease
        // already in force. Later activity begins extending that lease once
        // its rolling quiet-period deadline moves farther out.
        let candidate = min(
            request.deadline,
            max(activeWatchdogDeadline ?? now, progressCandidate)
        )
        if let current = activeWatchdogDeadline {
            // Cumulative snapshots can arrive many times per second. Rearm
            // only when progress extends the lease by a meaningful amount.
            guard candidate > current,
                current.duration(to: candidate) >= .milliseconds(400) else {
                return
            }
        }
        scheduleRequestDeadline(
            task: request.task,
            scope: request.scope,
            prompt: request.prompt,
            deadline: candidate,
            exchangeID: exchangeID,
            workID: workID
        )
    }

    /// Once the structured model result exists, stream inactivity is no
    /// longer the right failure signal. Citation freshness checks and final UI
    /// publication get the remainder of the absolute request budget.
    private func armFinalizationWatchdog(exchangeID: UUID, workID: UUID) {
        guard isCurrentWork(workID),
            activeExchangeID == exchangeID,
            let request = activePipelineRequest,
            request.requestID == workID,
            ContinuousClock().now < request.deadline else { return }
        if let current = activeWatchdogDeadline, current >= request.deadline { return }
        scheduleRequestDeadline(
            task: request.task,
            scope: request.scope,
            prompt: request.prompt,
            deadline: request.deadline,
            exchangeID: exchangeID,
            workID: workID
        )
    }

    private func finishRequestAtDeadline(
        task: AssistantTask,
        scope: AssistantScope,
        prompt: String,
        exchangeID: UUID,
        workID: UUID,
        expectedWatchdogToken: UInt64? = nil
    ) async {
        guard deadlineFallbackIsAuthoritative(
            workID: workID,
            expectedWatchdogToken: expectedWatchdogToken
        ),
            exchanges.contains(where: { $0.id == exchangeID }) else {
            return
        }

        await beforeDeadlineFallbackForTesting?()
        guard deadlineFallbackIsAuthoritative(
            workID: workID,
            expectedWatchdogToken: expectedWatchdogToken
        ) else { return }

        // A watchdog fallback never starts fresh source/index I/O. Model work
        // ends one second before the absolute cap in production so normal
        // terminal paths can revalidate there. When any initial, inactivity,
        // or hard-cap watchdog fires, atomically consume only the most recent
        // immutable receipt that already crossed a freshness gate, or fall
        // back to a source-free message.
        flushPendingStreamUpdate()
        guard let latest = exchanges.first(where: { $0.id == exchangeID }) else {
            return
        }
        let partialSnapshot = activePartialSnapshot(
            exchangeID: exchangeID,
            workID: workID
        )
        let preview = activeDeterministicPreview.flatMap {
            $0.workID == workID && $0.exchangeID == exchangeID ? $0 : nil
        }
        discardPendingStreamUpdate()

        var candidates: [AssistantImmediateTerminalContent] = []
        if let partialSnapshot,
            let preservedAnswer = Self.preservedDeadlineAnswer(
                from: partialSnapshot.answer
            ) {
            let sources = task == .summarize && partialSnapshot.sources.count > 8
                ? Self.evenlySampled(partialSnapshot.sources, limit: 8)
                : partialSnapshot.sources
            candidates.append(AssistantImmediateTerminalContent(
                answer: preservedAnswer,
                sources: sources,
                isGeneralKnowledge: partialSnapshot.isGeneralKnowledge,
                preliminaryResult: nil,
                freshnessReceipt: partialSnapshot.freshnessReceipt
            ))
        }
        if let preview {
            candidates.append(AssistantImmediateTerminalContent(
                answer: preview.kind == .relevantPassages
                    ? Self.groundedFallbackAnswer(
                        from: preview.sources,
                        timedOut: true
                    )
                    : preview.answer,
                sources: preview.sources,
                isGeneralKnowledge: false,
                preliminaryResult: preview.kind,
                freshnessReceipt: preview.freshnessReceipt
            ))
        }

        // A hard-deadline fallback must release the UI immediately. Follow-up
        // generation is supplemental and may be queued behind other CPU work,
        // so never await it on this terminal path.
        let followUps: [String] = []
        guard deadlineFallbackIsAuthoritative(
            workID: workID,
            expectedWatchdogToken: expectedWatchdogToken
        ) else { return }
        var retainedContent: AssistantImmediateTerminalContent?
        var rejectedStaleCandidate = false
        for candidate in candidates where retainedContent == nil {
            let published = candidate.performIfCurrent {
                guard deadlineFallbackIsAuthoritative(
                    workID: workID,
                    expectedWatchdogToken: expectedWatchdogToken
                ) else { return }
                replaceExchange(
                    id: exchangeID,
                    with: AssistantExchange(
                        id: exchangeID,
                        question: latest.question,
                        answer: candidate.answer,
                        sources: candidate.sources,
                        followUps: followUps,
                        isGeneralKnowledge: candidate.isGeneralKnowledge,
                        mode: latest.mode,
                        phase: .complete,
                        outcome: .content,
                        preliminaryResult: candidate.preliminaryResult,
                        summaryProvenance: Self.retainedSummaryProvenance(
                            task: task,
                            preliminaryResult: candidate.preliminaryResult
                        ),
                        task: latest.task,
                        scope: latest.scope,
                        scopeTitle: latest.scopeTitle
                    )
                )
            }
            if published == false {
                rejectedStaleCandidate = true
            }
            if published,
                deadlineFallbackIsAuthoritative(
                    workID: workID,
                    expectedWatchdogToken: expectedWatchdogToken
                ) {
                retainedContent = candidate
            }
        }

        let fallbackAnswer: String
        if rejectedStaleCandidate {
            fallbackAnswer = "The note changed while I was answering, so I discarded the stale result. "
                + "Ask again to use the saved revision now on screen."
        } else {
            fallbackAnswer = switch task {
            case .find:
                "I couldn't finish searching within the on-device time limit. Try a more specific term or a narrower scope."
            case .summarize:
                "I couldn't finish the summary within the on-device time limit. Try again, or choose a smaller page or notebook."
            case .answer, .explain, .study:
                scope == .library
                    ? "I couldn't finish checking the bounded library results within the on-device time limit. Try a more specific term or choose a notebook."
                    : "I couldn't finish this on-device request within the time limit. Try again, or choose a smaller page or notebook."
            }
        }
        if retainedContent == nil {
            replaceExchange(
                id: exchangeID,
                with: AssistantExchange(
                    id: exchangeID,
                    question: latest.question,
                    answer: fallbackAnswer,
                    sources: [],
                    followUps: followUps,
                    mode: latest.mode,
                    phase: .complete,
                    outcome: .failure,
                    task: latest.task,
                    scope: latest.scope,
                    scopeTitle: latest.scopeTitle
                )
            )
        }
        let hasUsefulLocalResult = retainedContent != nil
        let terminalAnswer = retainedContent?.answer ?? fallbackAnswer
        Self.pipelineSignposter.emitEvent(
            "DeadlineFallback",
            "route=\(task.rawValue, privacy: .public) scope=\(String(describing: scope), privacy: .public)"
        )
        Self.pipelineLogger.notice(
            "request deadline reached; best local result published route=\(task.rawValue, privacy: .public)"
        )
        status = if hasUsefulLocalResult {
            AssistantStatus(
                message: retainedContent?.preliminaryResult == nil
                    ? "Generation ended early, so I kept the completed part of the response and any verified passages already available."
                    : "Generation ended early, so I kept the verified result already available on this iPad.",
                severity: .information,
                action: .retry
            )
        } else if rejectedStaleCandidate {
            AssistantStatus(
                message: "A stale answer was discarded.",
                severity: .warning,
                action: .retry
            )
        } else {
            AssistantStatus(
                message: "The on-device request reached its time limit before a useful result was ready.",
                severity: .warning,
                action: .retry
            )
        }
        let terminalUpdate: AssistantPipelineUpdatePayload = hasUsefulLocalResult
            ? .completed
            : .failedWithFallback(terminalAnswer)

        let pipelineRequestID = activePipelineRequest?.requestID
        requestDeadlineTask = nil
        activeWatchdogDeadline = nil
        activeFollowUpTask?.cancel()
        activeFollowUpTask = nil
        activeFollowUpSuggestions = []
        activePublicationContext = nil
        activePartialSourceAuthority = [:]
        activePartialFreshnessReceipt = nil
        activeDeterministicPreview = nil
        activeWorkID = nil
        activeExchangeID = nil
        activePipelineRequest = nil
        isWorking = false
        workPhase = nil
        cancelProgressPresentation()
        let expiredWorkTask = workTask
        workTask = nil
        expiredWorkTask?.cancel()
        // UI completion is immediate. The coordinator orders this request's
        // cancellation against every panel's replacement admission.
        if let pipelineRequestID {
            enqueueModelCancellation(requestID: pipelineRequestID)
            enqueuePipelineUpdate(terminalUpdate, requestID: pipelineRequestID)
        }
    }

    private func deadlineFallbackIsAuthoritative(
        workID: UUID,
        expectedWatchdogToken: UInt64?
    ) -> Bool {
        guard isCurrentWork(workID) else { return false }
        guard let expectedWatchdogToken else { return true }
        return activeWatchdogToken == expectedWatchdogToken
            && activeWatchdogDeadline != nil
    }

    private static func isUsefulDeadlineText(_ value: String) -> Bool {
        let normalized = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
        let rejected = Set([
            "", "answer", "concise notes", "here is a summary",
            "here's a summary", "notes", "notes summary", "response", "summary",
        ])
        return rejected.contains(normalized) == false
    }

    /// Keeps only complete streamed prose at a hard deadline. An unfinished
    /// sentence remains visible while generation is live, but it is never
    /// promoted as a terminal answer after the provider stops.
    static func preservedDeadlineAnswer(
        from value: String?
    ) -> String? {
        preservedTerminalAnswer(
            from: value,
            terminalNote: nil
        )
    }

    private static func preservedInterruptedAnswer(
        from value: String?,
        hasSources: Bool
    ) -> String? {
        preservedTerminalAnswer(
            from: value,
            terminalNote: hasSources
                ? "The on-device model stopped before finishing. The verified passages below remain available."
                : "The on-device model stopped before finishing."
        )
    }

    private static func preservedTerminalAnswer(
        from value: String?,
        terminalNote: String?
    ) -> String? {
        // Every exchange answer has already crossed the single canonical
        // plain-text boundary. Re-projecting it here would reinterpret literal
        // code after its fence provenance was intentionally removed.
        guard let plainText = value?.assistantCanonicalNonempty else { return nil }
        guard isUsefulDeadlineText(plainText) else { return nil }

        let scalars = Array(plainText.unicodeScalars)
        guard let boundary = scalars.indices.last(where: {
            isStableSentenceBoundary(at: $0, in: scalars)
        }) else {
            return nil
        }
        var stableBoundary = boundary
        let closing = CharacterSet(charactersIn: "\"'`")
        while stableBoundary + 1 < scalars.count,
            closing.contains(scalars[stableBoundary + 1]) {
            stableBoundary += 1
        }
        let stable = String(String.UnicodeScalarView(scalars[...stableBoundary]))
            .trimmingCharacters(in: .newlines)
        guard isUsefulDeadlineText(stable) else { return nil }

        guard let terminalNote else { return stable }
        return "\(stable)\n\n\(terminalNote)"
    }

    /// A provider snapshot can stop immediately after a decimal point or an
    /// abbreviation. Treating every period as a completed sentence can turn
    /// `3.14` into the false claim `3.`. This deliberately conservative check
    /// accepts punctuation only at a textual boundary and rejects common
    /// abbreviation/initialism/number tokens.
    private static func isStableSentenceBoundary(
        at index: Int,
        in scalars: [UnicodeScalar]
    ) -> Bool {
        let scalar = scalars[index]
        guard ".!?…".unicodeScalars.contains(scalar) else { return false }

        var next = index + 1
        let closing = CharacterSet(charactersIn: "\"'`")
        while next < scalars.count, closing.contains(scalars[next]) {
            next += 1
        }
        if next < scalars.count,
            CharacterSet.whitespacesAndNewlines.contains(scalars[next]) == false {
            return false
        }
        guard scalar == "." else { return true }

        var nextContent = next
        while nextContent < scalars.count,
            CharacterSet.whitespacesAndNewlines.contains(scalars[nextContent]) {
            nextContent += 1
        }

        if index > 0,
            index + 1 < scalars.count,
            CharacterSet.decimalDigits.contains(scalars[index - 1]),
            CharacterSet.decimalDigits.contains(scalars[index + 1]) {
            return false
        }

        var tokenStart = index
        while tokenStart > 0,
            CharacterSet.whitespacesAndNewlines.contains(scalars[tokenStart - 1]) == false {
            tokenStart -= 1
        }
        let token = String(String.UnicodeScalarView(scalars[tokenStart...index]))
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`([{"))
            .lowercased()
        let abbreviations: Set<String> = [
            "apr.", "approx.", "aug.", "co.", "corp.", "dec.", "dr.",
            "e.g.", "eq.", "etc.", "feb.", "fig.", "i.e.", "inc.", "jan.",
            "jr.", "jul.", "jun.", "ltd.", "mar.", "mr.", "mrs.", "ms.",
            "no.", "nov.", "oct.", "prof.", "sep.", "sept.", "sr.", "st.",
            "vs.",
        ]
        if abbreviations.contains(token) { return false }

        let tokenWithoutPeriod = token.dropLast()
        let initialismParts = tokenWithoutPeriod.split(
            separator: ".",
            omittingEmptySubsequences: false
        )
        if initialismParts.count > 1,
            initialismParts.allSatisfy({
                $0.count == 1 && $0.allSatisfy(\.isLetter)
            }) {
            return false
        }

        if nextContent < scalars.count {
            let nextCharacter = Character(String(scalars[nextContent]))
            // A short token followed by a lowercase word or value can be an
            // abbreviation even when it is not in the bounded list above.
            // Do not apply that heuristic to ordinary words: a complete
            // sentence may legitimately be followed by an unfinished
            // lowercase stream tail at the deadline.
            if (nextCharacter.isLowercase || nextCharacter.isNumber),
                tokenWithoutPeriod.count <= 4 {
                return false
            }
        }
        return true
    }

    private func queuePartialAnswer(
        _ partial: AssistantModelPartialResponse,
        hiding sourceIDs: Set<String>,
        allowsGeneralKnowledge: Bool,
        exchangeID: UUID,
        workID: UUID
    ) {
        let proposedSourceIDs = Set(partial.sourceIDs)
        let hasValidProvenance = partial.isGeneralKnowledge
            ? allowsGeneralKnowledge && proposedSourceIDs.isEmpty
            : proposedSourceIDs.isEmpty == false
                && proposedSourceIDs.count == partial.sourceIDs.count
                && proposedSourceIDs.isSubset(of: sourceIDs)
        let answer = AssistantAnswerSanitizer.sanitize(
            partial.answer,
            removingSourceIDs: sourceIDs,
            streaming: true
        )
        guard isCurrentWork(workID),
            activeExchangeID == exchangeID,
            let current = exchanges.first(where: { $0.id == exchangeID }),
            current.phase != .complete,
            hasValidProvenance,
            answer.isEmpty == false,
            Self.isUsefulDeadlineText(answer) else {
            return
        }

        activePartialSourceIDs = partial.isGeneralKnowledge ? [] : partial.sourceIDs
        activePartialIsGeneralKnowledge = partial.isGeneralKnowledge

        let isFirstUsefulSnapshot = activeDidReceiveModelText == false
        if isFirstUsefulSnapshot {
            activeDidReceiveModelText = true
            Self.pipelineSignposter.emitEvent("ModelTTFT")
        }

        refreshWatchdogAfterStreamProgress(
            exchangeID: exchangeID,
            workID: workID
        )

        // Structured generation can keep filling evidence fields after the
        // visible Markdown stops changing. That is still live model activity,
        // but it should not enqueue a duplicate UI frame.
        guard answer != current.answer else { return }

        enqueueStreamTarget(
            answer,
            exchangeID: exchangeID,
            workID: workID,
            preliminaryResult: nil
        )
    }

    private func queuePartialSummary(
        _ partial: OnDeviceSummaryPartialResponse,
        hiding sourceIDs: Set<String>,
        exchangeID: UUID,
        workID: UUID
    ) {
        let representedSourceIDs = Set(partial.representedSourceIDs)
        let markdown = AssistantAnswerSanitizer.sanitize(
            partial.text,
            removingSourceIDs: sourceIDs,
            streaming: true
        )
        guard isCurrentWork(workID),
            activeExchangeID == exchangeID,
            let current = exchanges.first(where: { $0.id == exchangeID }),
            current.phase != .complete,
            representedSourceIDs.isEmpty == false,
            representedSourceIDs.count == partial.representedSourceIDs.count,
            representedSourceIDs.isSubset(of: sourceIDs),
            markdown.isEmpty == false,
            Self.isUsefulDeadlineText(markdown) else { return }

        activePartialSourceIDs = partial.representedSourceIDs
        activePartialIsGeneralKnowledge = false

        let isFirstUsefulSnapshot = activeDidReceiveModelText == false
        if isFirstUsefulSnapshot {
            activeDidReceiveModelText = true
            Self.pipelineSignposter.emitEvent("ModelTTFT")
        }

        refreshWatchdogAfterStreamProgress(
            exchangeID: exchangeID,
            workID: workID
        )

        guard markdown != current.answer else { return }

        enqueueStreamTarget(
            markdown,
            exchangeID: exchangeID,
            workID: workID,
            // The extractive preview is complete Markdown. The first model
            // partial begins a different, unstable presentation state so the
            // view can stop labeling generated text as a "Quick summary."
            preliminaryResult: nil
        )
    }

    /// Model snapshots often arrive in uneven token bursts. Bound publication
    /// to roughly 15 Hz so MainActor sanitization, transcript replacement, and
    /// layout never restart several times in one display frame. The leaf view
    /// independently advances toward this authoritative cumulative snapshot at
    /// 30 Hz, preserving immediacy without exposing provider-sized chunks.
    private func enqueueStreamTarget(
        _ targetAnswer: String,
        exchangeID: UUID,
        workID: UUID,
        preliminaryResult: AssistantPreliminaryResultKind? = nil
    ) {
        guard isCurrentWork(workID),
            activeExchangeID == exchangeID,
            let current = exchanges.first(where: { $0.id == exchangeID }),
            current.phase != .complete,
            targetAnswer.isEmpty == false,
            targetAnswer != current.answer else { return }

        pendingStreamUpdate = AssistantPendingStreamUpdate(
            targetAnswer: targetAnswer,
            exchangeID: exchangeID,
            workID: workID,
            preliminaryResult: preliminaryResult
        )
        guard let lastStreamPresentationAt else {
            flushPendingStreamUpdate()
            return
        }
        let elapsed = prewarmClock.now - lastStreamPresentationAt
        if elapsed >= Self.streamPresentationInterval {
            flushPendingStreamUpdate()
        } else {
            startStreamPresentationIfNeeded(
                after: Self.streamPresentationInterval - elapsed
            )
        }
    }

    private func startStreamPresentationIfNeeded(after delay: Duration) {
        guard streamPresentationTask == nil else { return }
        streamPresentationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await Task.sleep(for: delay)
            } catch {
                return
            }
            self.streamPresentationTask = nil
            self.flushPendingStreamUpdate()
        }
    }

    private func drainStreamPresentation(
        toward finalAnswer: String,
        exchangeID: UUID,
        workID: UUID
    ) {
        guard isCurrentWork(workID), activeExchangeID == exchangeID else { return }
        enqueueStreamTarget(
            finalAnswer,
            exchangeID: exchangeID,
            workID: workID
        )
        flushPendingStreamUpdate()
    }

    private func flushPendingStreamUpdate() {
        streamPresentationTask?.cancel()
        streamPresentationTask = nil
        guard let pendingStreamUpdate else { return }
        self.pendingStreamUpdate = nil
        guard isCurrentWork(pendingStreamUpdate.workID),
            activeExchangeID == pendingStreamUpdate.exchangeID,
            let current = exchanges.first(where: { $0.id == pendingStreamUpdate.exchangeID }),
            current.phase != .complete,
            pendingStreamUpdate.targetAnswer != current.answer else { return }

        replaceExchange(
            id: pendingStreamUpdate.exchangeID,
            with: AssistantExchange(
                id: pendingStreamUpdate.exchangeID,
                question: current.question,
                answer: pendingStreamUpdate.targetAnswer,
                sources: current.sources,
                followUps: current.followUps,
                isGeneralKnowledge: current.isGeneralKnowledge,
                mode: current.mode,
                phase: .streaming,
                outcome: current.outcome,
                preliminaryResult: pendingStreamUpdate.preliminaryResult
            )
        )
        lastStreamPresentationAt = prewarmClock.now
    }

    private func discardPendingStreamUpdate() {
        streamPresentationTask?.cancel()
        streamPresentationTask = nil
        pendingStreamUpdate = nil
        lastStreamPresentationAt = nil
    }

    private func replaceExchange(id: UUID, with replacement: AssistantExchange) {
        guard let index = exchanges.firstIndex(where: { $0.id == id }) else { return }
        let current = exchanges[index]
        let carried = AssistantExchange(
            id: replacement.id,
            question: replacement.question,
            answer: replacement.answer,
            sources: replacement.sources,
            followUps: replacement.followUps,
            isGeneralKnowledge: replacement.isGeneralKnowledge,
            mode: replacement.mode,
            phase: replacement.phase,
            outcome: replacement.outcome,
            preliminaryResult: replacement.preliminaryResult,
            summaryProvenance: replacement.summaryProvenance,
            task: replacement.task ?? current.task,
            scope: replacement.scope ?? current.scope,
            scopeTitle: replacement.scopeTitle ?? current.scopeTitle
        )
        let currentSources = current.sources
        // Presentation normalization is deliberately outside retrieval,
        // grounding validation, and cache storage. Reuse the already prepared
        // rows during streaming so repeated model snapshots do no source-text
        // work on MainActor.
        let displaySources: [AssistantSearchResult]
        if carried.phase == .complete || carried.phase == .stopped {
            displaySources = AssistantReferenceNormalizer.referencesForPresentation(
                carried.sources,
                excludingAnswer: carried.answer
            )
        } else if carried.sources == currentSources {
            displaySources = currentSources
        } else {
            displaySources = AssistantReferenceNormalizer.referencesForPresentation(
                carried.sources
            )
        }
        // AssistantSearchResult equality intentionally compares retrieval
        // evidence only, not presentation-only text. Always carry the
        // normalized rows forward so title/snippet cleanup is not discarded
        // merely because the underlying source identity is unchanged.
        let presented = AssistantExchange(
            id: carried.id,
            question: carried.question,
            answer: carried.answer,
            sources: displaySources,
            followUps: carried.followUps,
            isGeneralKnowledge: carried.isGeneralKnowledge,
            mode: carried.mode,
            phase: carried.phase,
            outcome: carried.outcome,
            preliminaryResult: carried.preliminaryResult,
            summaryProvenance: carried.summaryProvenance,
            task: carried.task,
            scope: carried.scope,
            scopeTitle: carried.scopeTitle
        )
        exchanges[index] = presented
        if id == activeExchangeID,
            activeDidPublishUsefulContent == false,
            presented.answer.assistantTrimmedNonempty != nil {
            activeDidPublishUsefulContent = true
            Self.pipelineSignposter.emitEvent(
                "FirstUseful",
                "preliminary=\(presented.preliminaryResult != nil, privacy: .public)"
            )
        }
        guard id == activeExchangeID else { return }
        if presented.sources.isEmpty == false,
            presented.sources != current.sources {
            publishPipelineUpdate(.sources(presented.sources))
        }
        switch presented.phase {
        case .streaming:
            if let preliminaryResult = presented.preliminaryResult {
                publishPipelineUpdate(
                    .quickResult(text: presented.answer, kind: preliminaryResult)
                )
            } else if presented.answer.isEmpty == false {
                publishPipelineUpdate(.partialText(presented.answer))
            }
        case .waiting, .complete, .stopped:
            break
        }
    }

    private func publishPipelineUpdate(
        _ payload: AssistantPipelineUpdatePayload,
        snapshotIdentity: NoteSnapshotIdentity? = nil
    ) {
        guard let requestID = activePipelineRequest?.requestID else { return }
        enqueuePipelineUpdate(
            payload,
            requestID: requestID,
            snapshotIdentity: snapshotIdentity
        )
    }

    @discardableResult
    private func enqueuePipelineUpdate(
        _ payload: AssistantPipelineUpdatePayload,
        requestID: UUID,
        snapshotIdentity: NoteSnapshotIdentity? = nil
    ) -> Task<Void, Never> {
        let predecessor = pipelinePublicationTail
        let task = Task { [pipelineCoordinator] in
            await predecessor?.value
            _ = await pipelineCoordinator.publish(
                payload,
                requestID: requestID,
                snapshotIdentity: snapshotIdentity
            )
        }
        pipelinePublicationTail = task
        return task
    }

    private func recordPreparedRequest(
        snapshot: NoteContentSnapshot?,
        passages: [AssistantSearchResult]
    ) async {
        guard let request = activePipelineRequest else { return }
        let predecessor = pipelinePublicationTail
        let prepared = PreparedAssistantRequest(
            request: request,
            snapshot: snapshot,
            retrievedPassages: passages
        )
        let task = Task { [pipelineCoordinator] in
            await predecessor?.value
            _ = await pipelineCoordinator.recordPrepared(prepared)
        }
        pipelinePublicationTail = task
        await task.value
    }

    private func removeIncompleteExchange(id: UUID) {
        exchanges.removeAll { exchange in
            exchange.id == id && exchange.phase != .complete
        }
    }

    private func finishFind(
        prompt: String,
        results: [AssistantSearchResult],
        exchangeID: UUID,
        workID: UUID
    ) {
        guard isCurrentWork(workID) else { return }
        let references = AssistantReferenceNormalizer.referencesForPresentation(results)
        let answer = if references.isEmpty {
            "I couldn't find a match here. Try a shorter phrase or widen the scope."
        } else if references.count == 1 {
            "Found one match."
        } else {
            "Found \(references.count) matches."
        }
        replaceExchange(
            id: exchangeID,
            with:
            AssistantExchange(
                id: exchangeID,
                question: prompt,
                answer: answer,
                sources: references,
                mode: .find,
                phase: .complete,
                outcome: references.isEmpty ? .noResult : .content
            )
        )
        completeWork(workID)
    }

    private func finishUnavailableAsk(
        prompt: String,
        results: [AssistantSearchResult],
        availability: AssistantModelAvailability,
        canPublishFollowUps: Bool,
        exchangeID: UUID,
        workID: UUID
    ) {
        // Model availability is independent from local note intelligence.
        // Suggestions are supplemental and never delay this terminal path.
        let followUps = canPublishFollowUps
            ? activeFollowUpSuggestions
            : []
        guard isCurrentWork(workID) else { return }
        let explanation = availability.userFacingDescription
        let answer = results.isEmpty
            ? "\(explanation) Local Find is still available."
            : "\(explanation) I've kept the grounded matches below so you can open the relevant pages."
        replaceExchange(
            id: exchangeID,
            with:
            AssistantExchange(
                id: exchangeID,
                question: prompt,
                answer: answer,
                sources: results,
                followUps: followUps,
                mode: .ask,
                phase: .complete,
                outcome: .failure
            )
        )
        completeWork(workID)
    }

    private func makeModelRequest(
        task: AssistantTask,
        question: String,
        scope: AssistantScope,
        itemID: UUID,
        pageID: UUID?,
        revision: UInt64,
        results: [AssistantSearchResult],
        priorTurns: [AssistantModelTurn],
        cachedOrientation: String?,
        allowsGeneralKnowledge: Bool,
        deadline: ContinuousClock.Instant
    ) -> AssistantModelRequest {
        let scopeLabel = modelScopeLabel(
            scope: scope,
            itemID: itemID,
            pageID: pageID,
            revision: revision
        )
        return AssistantModelRequest(
            question: question,
            scopeLabel: scopeLabel,
            scope: scope,
            task: task,
            cachedOrientation: scope == .library ? nil : cachedOrientation,
            initialSources: results.map(\.evidenceSource),
            priorTurns: priorTurns,
            allowsGeneralKnowledge: allowsGeneralKnowledge,
            deadline: deadline
        )
    }

    private func cachedOrientation(
        task: AssistantTask,
        snapshot: NoteContentSnapshot?,
        context: AssistantArtifactContext?,
        cachedIntelligenceTask: Task<[AssistantLocalArtifact], Never>? = nil
    ) async -> String? {
        guard let snapshot, let context else { return nil }
        let artifacts: [AssistantLocalArtifact]
        if let cachedIntelligenceTask {
            artifacts = await cachedIntelligenceTask.value
        } else {
            artifacts = await cachedLocalIntelligence(
                for: snapshot,
                context: context
            )
        }
        let preferredKinds: [AssistantArtifactKind] = task == .study
            ? [.outline, .concepts, .questions, .entities]
            : [.outline, .concepts, .entities]
        let byKind = Dictionary(
            artifacts.map { ($0.kind, $0) },
            uniquingKeysWith: { current, _ in current }
        )
        var pieces = preferredKinds.compactMap { byKind[$0]?.markdown }

        if let cache = artifactCache {
            let key = Self.summaryCacheKeyV2(
                snapshot: snapshot,
                kind: .summary,
                context: context,
                identity: .systemModel,
                localeIdentifier: Locale.current.identifier,
                outputStyle: "balanced"
            )
            if let summary = try? await cache.artifact(
                for: key,
                currentSnapshotHash: snapshot.contentHash
            ) {
                pieces.append("## Cached summary orientation\n\n\(summary.markdown)")
            }
        }
        let orientation = pieces.joined(separator: "\n\n")
        return orientation.assistantTrimmedNonempty
    }

    /// Interactive requests only read intelligence that already exists. Missing
    /// artifacts are built after the visible answer has been published.
    private func cachedLocalIntelligence(
        for snapshot: NoteContentSnapshot,
        context: AssistantArtifactContext
    ) async -> [AssistantLocalArtifact] {
        guard let artifactCache else { return [] }
        let localeIdentifier = Locale.current.identifier
        let identity = AssistantSummaryCacheIdentity.localIntelligence
        let kinds: [AssistantArtifactKind] = [.outline, .concepts, .entities, .questions]
        let keys = kinds.map { kind in
            Self.localIntelligenceCacheKeyV2(
                snapshot: snapshot,
                kind: kind,
                context: context,
                identity: identity,
                localeIdentifier: localeIdentifier
            )
        }
        let records = (try? await artifactCache.artifacts(
            for: keys,
            currentSnapshotHash: snapshot.contentHash
        )) ?? [:]
        return kinds.compactMap { kind in
            guard let key = keys.first(where: { $0.artifactKind == kind }),
                let record = records[key] else { return nil }
            return AssistantLocalArtifact(
                kind: kind,
                markdown: record.markdown,
                sourceIDs: record.sourceIDs
            )
        }
    }

    private func localIntelligence(
        for snapshot: NoteContentSnapshot,
        context: AssistantArtifactContext
    ) async -> [AssistantLocalArtifact] {
        let localeIdentifier = Locale.current.identifier
        let identity = AssistantSummaryCacheIdentity.localIntelligence
        let kinds: [AssistantArtifactKind] = [.outline, .concepts, .entities, .questions]
        let cached = await cachedLocalIntelligence(for: snapshot, context: context)
        if cached.count == kinds.count { return cached }
        if let cache = artifactCache {
            let manifestKey = Self.intelligenceManifestKey(
                snapshot: snapshot,
                context: context,
                localeIdentifier: localeIdentifier
            )
            if let manifest = try? await cache.intelligenceManifest(
                for: manifestKey,
                currentSnapshotHash: snapshot.contentHash
            ) {
                let cachedKinds = Set(cached.map(\.kind))
                let manifestIsComplete = kinds.allSatisfy { kind in
                    switch manifest.state(for: kind) {
                    case .absent:
                        true
                    case .present:
                        cachedKinds.contains(kind)
                    case .unknown:
                        false
                    }
                }
                if manifestIsComplete { return cached }
            }
        }

        let built = await cpuWorker.localIntelligence(
            from: snapshot,
            localeIdentifier: localeIdentifier
        )
        if let cache = artifactCache {
            let records = built.map { artifact in
                let key = Self.localIntelligenceCacheKeyV2(
                    snapshot: snapshot,
                    kind: artifact.kind,
                    context: context,
                    identity: identity,
                    localeIdentifier: localeIdentifier
                )
                return AssistantArtifactRecordV2(
                    key: key,
                    subjectRevision: snapshot.revision,
                    markdown: artifact.markdown,
                    sourceIDs: artifact.sourceIDs,
                    coverage: AssistantArtifactCoverage(
                        totalSectionCount: snapshot.sections.count,
                        coveredSectionIDs: snapshot.sections.compactMap { section in
                            section.chunks.contains(where: {
                                artifact.sourceIDs.contains($0.sourceID)
                            }) ? section.id : nil
                        }
                    )
                )
            }
            let presentKinds = Set(built.map(\.kind))
            let manifest = AssistantIntelligenceManifest(
                key: Self.intelligenceManifestKey(
                    snapshot: snapshot,
                    context: context,
                    localeIdentifier: localeIdentifier
                ),
                presentArtifactKinds: presentKinds,
                absentArtifactKinds: Set(kinds).subtracting(presentKinds)
            )
            try? await cache.store(records, manifests: [manifest])
        }
        return built
    }

    private func cachedStudyArtifact(
        prompt: String,
        snapshot: NoteContentSnapshot,
        context: AssistantArtifactContext
    ) async -> AssistantArtifactRecordV2? {
        guard let artifactCache else { return nil }
        let key = Self.studyCacheKeyV2(
            prompt: prompt,
            snapshot: snapshot,
            context: context
        )
        return try? await artifactCache.artifact(
            for: key,
            currentSnapshotHash: snapshot.contentHash
        )
    }

    private func cachedGroundedArtifact(
        task: AssistantTask,
        prompt: String,
        snapshotHash: String?,
        context: AssistantArtifactContext?,
        isEligible: Bool
    ) async -> AssistantArtifactRecordV2? {
        guard isEligible,
            let artifactCache,
            let snapshotHash,
            let context else { return nil }
        let signpost = Self.pipelineSignposter.beginInterval("CacheLookup")
        defer { Self.pipelineSignposter.endInterval("CacheLookup", signpost) }
        let key = Self.groundedCacheKeyV2(
            task: task,
            prompt: prompt,
            snapshotHash: snapshotHash,
            context: context
        )
        let record = try? await artifactCache.artifact(
            for: key,
            currentSnapshotHash: snapshotHash
        )
        if record == nil {
            Self.pipelineSignposter.emitEvent("CacheMiss")
        } else {
            Self.pipelineSignposter.emitEvent("CacheHit")
        }
        return record
    }

    private func storeGroundedArtifact(
        task: AssistantTask,
        prompt: String,
        answer: String,
        sourceIDs: [String],
        snapshotHash: String,
        subjectRevision: Int64,
        context: AssistantArtifactContext
    ) async throws {
        guard let artifactCache,
            let answer = answer.assistantCanonicalNonempty,
            sourceIDs.isEmpty == false else { return }
        let key = Self.groundedCacheKeyV2(
            task: task,
            prompt: prompt,
            snapshotHash: snapshotHash,
            context: context
        )
        try await artifactCache.store(AssistantArtifactRecordV2(
            key: key,
            subjectRevision: subjectRevision,
            markdown: answer,
            sourceIDs: sourceIDs
        ))
    }

    private func storeStudyArtifact(
        prompt: String,
        answer: String,
        sourceIDs: [String],
        snapshot: NoteContentSnapshot,
        context: AssistantArtifactContext
    ) async throws {
        guard let artifactCache,
            answer.assistantTrimmedNonempty != nil else { return }
        let covered = Set(sourceIDs)
        let coveredSections = snapshot.sections.compactMap { section in
            section.chunks.contains(where: { covered.contains($0.sourceID) })
                ? section.id
                : nil
        }
        try await artifactCache.store(AssistantArtifactRecordV2(
            key: Self.studyCacheKeyV2(
                prompt: prompt,
                snapshot: snapshot,
                context: context
            ),
            subjectRevision: snapshot.revision,
            markdown: answer,
            sourceIDs: sourceIDs,
            coverage: AssistantArtifactCoverage(
                totalSectionCount: snapshot.sections.count,
                coveredSectionIDs: coveredSections,
                missingSectionIDs: snapshot.sections.map(\.id).filter {
                    !coveredSections.contains($0)
                }
            )
        ))
    }

    private func scheduleLocalIntelligence(
        for snapshot: NoteContentSnapshot,
        context: AssistantArtifactContext
    ) {
        maintenanceTask?.cancel()
        maintenanceTask = Task(priority: .utility) { [weak self] in
            guard let self, Task.isCancelled == false else { return }
            await self.performLocalIntelligenceMaintenance(
                for: snapshot,
                context: context
            )
        }
    }

    /// Persists answer-derived artifacts only after the validated answer has
    /// been published and the composer has been released. A new foreground
    /// request cancels this maintenance task instead of waiting on SQLite or
    /// local intelligence derivation.
    private func scheduleGroundedCompletionMaintenance(
        assistantTask: AssistantTask,
        prompt: String,
        answer: String,
        sourceIDs: [String],
        shouldStoreStudy: Bool,
        shouldStoreGrounded: Bool,
        intelligenceSnapshot: NoteContentSnapshot?,
        intelligenceContext: AssistantArtifactContext?,
        groundedSnapshotHash: String,
        groundedSubjectRevision: Int64,
        groundedCacheContext: AssistantArtifactContext
    ) {
        guard shouldStoreStudy
            || shouldStoreGrounded
            || (intelligenceSnapshot != nil && intelligenceContext != nil) else {
            return
        }
        maintenanceTask?.cancel()
        maintenanceTask = Task(priority: .utility) { [weak self] in
            guard let self, Task.isCancelled == false else { return }
            if shouldStoreStudy,
                let intelligenceSnapshot,
                let intelligenceContext {
                try? await self.storeStudyArtifact(
                    prompt: prompt,
                    answer: answer,
                    sourceIDs: sourceIDs,
                    snapshot: intelligenceSnapshot,
                    context: intelligenceContext
                )
            } else if shouldStoreGrounded {
                try? await self.storeGroundedArtifact(
                    task: assistantTask,
                    prompt: prompt,
                    answer: answer,
                    sourceIDs: sourceIDs,
                    snapshotHash: groundedSnapshotHash,
                    subjectRevision: groundedSubjectRevision,
                    context: groundedCacheContext
                )
            }
            guard Task.isCancelled == false,
                let intelligenceSnapshot,
                let intelligenceContext else { return }
            await self.performLocalIntelligenceMaintenance(
                for: intelligenceSnapshot,
                context: intelligenceContext
            )
        }
    }

    private func scheduleSummaryMaintenance(
        artifact: SummaryArtifact,
        snapshot: NoteContentSnapshot,
        context: AssistantArtifactContext
    ) {
        maintenanceTask?.cancel()
        maintenanceTask = Task(priority: .utility) { [weak self] in
            guard let self, Task.isCancelled == false else { return }
            try? await self.storeSummaryArtifact(artifact, context: context)
            guard Task.isCancelled == false else { return }
            await self.performLocalIntelligenceMaintenance(
                for: snapshot,
                context: context
            )
        }
    }

    private func performLocalIntelligenceMaintenance(
        for snapshot: NoteContentSnapshot,
        context: AssistantArtifactContext
    ) async {
        guard Task.isCancelled == false else { return }
        let pageID: UUID? = context.scope.kind == .page
            ? UUID(uuidString: context.scope.identifier)
            : nil
        guard let indexed = await index.contentSnapshot(
            itemID: snapshot.noteID,
            pageID: pageID
        ) else { return }
        guard let current = try? await cpuWorker.summarySnapshot(from: indexed),
            current.contentHash == snapshot.contentHash,
            current.revision == snapshot.revision,
            Task.isCancelled == false else { return }

        _ = await localIntelligence(for: snapshot, context: context)
        guard let artifactCache else { return }
        let pruningReceipt = await artifactCache.stalePruningReceipt()
        guard Task.isCancelled == false,
            await index.isCurrent(indexed) else { return }
        let sectionHashes = Dictionary(
            snapshot.sections.map { ($0.id, $0.contentHash) },
            uniquingKeysWith: { current, _ in current }
        )
        _ = try? await artifactCache.removeStaleArtifacts(
            for: context.subject,
            in: context.scope,
            keepingSnapshotHash: snapshot.contentHash,
            preservingSectionHashes: sectionHashes,
            ifContentRevisionIs: pruningReceipt
        )
    }

    /// Summaries bypass ranked retrieval entirely. They are built from a
    /// complete, ordered, generation-verified snapshot and are published only
    /// while that exact snapshot remains current.
    private func finishSummary(
        prompt: String,
        scope: AssistantScope,
        focusedItemID: UUID,
        pageID: UUID?,
        directDeadline: ContinuousClock.Instant,
        requestDeadline: ContinuousClock.Instant,
        modelDeadline: ContinuousClock.Instant,
        exchangeID: UUID,
        workID: UUID
    ) async {
        let scopedPageID = scope == .page ? pageID : nil

        for attempt in 0..<2 {
            guard isCurrentWork(workID) else { return }
            let snapshotSignpost = Self.pipelineSignposter.beginInterval(
                "SnapshotCapture"
            )
            let capturedSummary = await index.captureSummary(
                itemID: focusedItemID,
                pageID: scopedPageID,
                deadline: directDeadline
            )
            Self.pipelineSignposter.endInterval(
                "SnapshotCapture",
                snapshotSignpost
            )
            guard let capturedSummary else {
                guard isCurrentWork(workID) else { return }
                replaceExchange(
                    id: exchangeID,
                    with: AssistantExchange(
                        id: exchangeID,
                        question: prompt,
                        answer: "I couldn't read a complete verified snapshot of this note yet. Your note was not replaced with partial or stale content; try again after it finishes saving.",
                        mode: .ask,
                        phase: .complete,
                        outcome: .failure
                    )
                )
                status = AssistantStatus(
                    message: "A complete current note snapshot was not available.",
                    severity: .warning,
                    action: .retry
                )
                completeWork(workID)
                return
            }
            let indexedSnapshot = capturedSummary.contentSnapshot
            installPublicationContext(
                workID: workID,
                scope: scope,
                contentSnapshot: indexedSnapshot,
                summaryCapture: capturedSummary
            )

            do {
                let hashingSignpost = Self.pipelineSignposter.beginInterval(
                    "SnapshotHashing"
                )
                let snapshot: NoteContentSnapshot
                do {
                    snapshot = try await cpuWorker.summarySnapshot(
                        from: indexedSnapshot
                    )
                } catch {
                    Self.pipelineSignposter.endInterval(
                        "SnapshotHashing",
                        hashingSignpost
                    )
                    throw error
                }
                Self.pipelineSignposter.endInterval(
                    "SnapshotHashing",
                    hashingSignpost
                )
                guard isCurrentWork(workID) else { return }
                // Keep the complete verified source authority for typed direct
                // summary partials. The visible quick-summary references remain
                // capped separately, but Stop/failure/deadline can now preserve
                // a partial that represents any chunk in a large note.
                let summaryAuthority = capturedSummary.sourceAuthority
                let summaryAuthorityByID = capturedSummary.sourceAuthorityByID
                guard summaryAuthorityByID.count == summaryAuthority.count,
                    snapshot.sourceIDs.count == summaryAuthority.count,
                    snapshot.sourceIDs.allSatisfy({
                        summaryAuthorityByID[$0] != nil
                    }) else {
                    throw AssistantSummaryPipelineError.staleSnapshot
                }
                activePartialSourceAuthority = summaryAuthorityByID
                await recordPreparedRequest(
                    snapshot: snapshot,
                    passages: []
                )
                guard isCurrentWork(workID) else { return }
                workPhase = .gettingRelevantDetails
                let verifier = NotebookIndexSummarySnapshotVerifier(
                    expectedIdentity: snapshot.identity,
                    freshnessReceipt: capturedSummary.freshnessReceipt
                )
                try await runSummary(
                    prompt: prompt,
                    scope: scope,
                    snapshot: snapshot,
                    verifier: verifier,
                    cacheContext: Self.artifactContext(
                        noteID: snapshot.noteID,
                        scope: scope,
                        pageID: scopedPageID
                    ),
                    directDeadline: directDeadline,
                    deadline: modelDeadline,
                    uiDeadline: requestDeadline,
                    exchangeID: exchangeID,
                    workID: workID
                )
                return
            } catch AssistantSummaryPipelineError.staleSnapshot where attempt == 0 {
                guard isCurrentWork(workID) else { return }
                resetSummaryAttemptForRetry(
                    prompt: prompt,
                    exchangeID: exchangeID,
                    workID: workID
                )
                let preparation = await prepareForRequest?(
                    .summarize,
                    requestDeadline
                ) ?? .ready
                guard isCurrentWork(workID) else { return }
                if finishRequestPreparationFailure(
                    preparation,
                    prompt: prompt,
                    mode: .ask,
                    exchangeID: exchangeID,
                    workID: workID
                ) {
                    return
                }
                continue
            } catch AssistantSummaryPipelineError.staleSnapshot {
                guard isCurrentWork(workID) else { return }
                replaceExchange(
                    id: exchangeID,
                    with: AssistantExchange(
                        id: exchangeID,
                        question: prompt,
                        answer: "The note changed while I was summarizing it, so I stopped before showing a stale result. Please try again now that the latest revision is saved.",
                        mode: .ask,
                        phase: .complete,
                        outcome: .failure
                    )
                )
                status = AssistantStatus(
                    message: "A stale summary was discarded.",
                    severity: .warning,
                    action: .retry
                )
                completeWork(workID)
                return
            } catch is CancellationError {
                await finishCancelledWork(workID, exchangeID: exchangeID)
                return
            } catch {
                guard isCurrentWork(workID) else { return }
                flushPendingStreamUpdate()
                let partialSnapshot = activePartialSnapshot(
                    exchangeID: exchangeID,
                    workID: workID
                )
                let preview = activeDeterministicPreview.flatMap { preview in
                    preview.workID == workID
                        && preview.exchangeID == exchangeID
                        && preview.kind == .quickSummary
                        ? preview
                        : nil
                }
                let validatedPartial: AssistantValidatedPartialSourceSet?
                if let partialSnapshot {
                    await beforePartialProvenanceValidationForTesting?()
                    validatedPartial = await validatedSourcesForActivePartial(
                        partialSnapshot,
                        workID: workID
                    )
                } else {
                    validatedPartial = nil
                }
                guard isCurrentWork(workID) else { return }
                let presentedPartialSources = validatedPartial.map {
                    $0.sources.count > 8
                        ? Self.evenlySampled($0.sources, limit: 8)
                        : $0.sources
                }
                // A provider can fail while decoding the final structured tail
                // after useful typed snapshots were already visible. Preserve
                // their last complete sentence; otherwise restore the verified
                // extractive preview.
                let partialAnswer = presentedPartialSources != nil
                    ? Self.preservedInterruptedAnswer(
                        from: partialSnapshot?.answer,
                        hasSources: presentedPartialSources?.isEmpty == false
                    )
                    : nil
                let fallbackPublication: AssistantValidatedSourceSet?
                if partialAnswer == nil {
                    let expectedSources = preview?.sources ?? []
                    guard let validated = await validatedPublication(
                        expectedSources,
                        workID: workID
                    ) else {
                        guard isCurrentWork(workID) else { return }
                        replaceExchange(
                            id: exchangeID,
                            with: AssistantExchange(
                                id: exchangeID,
                                question: prompt,
                                answer: "The note changed while I was summarizing it, so I stopped before showing a stale result. Please try again now that the latest revision is saved.",
                                mode: .ask,
                                phase: .complete,
                                outcome: .failure
                            )
                        )
                        status = AssistantStatus(
                            message: "A stale summary was discarded.",
                            severity: .warning,
                            action: .retry
                        )
                        completeWork(workID)
                        return
                    }
                    fallbackPublication = validated
                } else {
                    fallbackPublication = nil
                }
                guard isCurrentWork(workID) else { return }
                let publicationSources = fallbackPublication?.sources ?? []
                let answer = partialAnswer ?? preview?.answer
                    ?? "I couldn't finish the summary on this iPad. Try again, or choose a smaller page or notebook."
                let finalSources = partialAnswer == nil
                    ? publicationSources
                    : presentedPartialSources ?? []
                let followUps = partialAnswer == nil && preview == nil
                    ? []
                    : activeFollowUpSuggestions
                guard isCurrentWork(workID) else { return }
                let terminal = AssistantImmediateTerminalContent(
                    answer: answer,
                    sources: finalSources,
                    isGeneralKnowledge: false,
                    preliminaryResult: partialAnswer == nil ? preview?.kind : nil,
                    freshnessReceipt: partialAnswer != nil
                        ? validatedPartial?.freshnessReceipt
                        : fallbackPublication?.freshnessReceipt
                )
                guard terminal.performIfCurrent({
                    guard isCurrentWork(workID) else { return }
                    replaceExchange(
                        id: exchangeID,
                        with: AssistantExchange(
                            id: exchangeID,
                            question: prompt,
                            answer: terminal.answer,
                            sources: terminal.sources,
                            followUps: followUps,
                            mode: .ask,
                            phase: .complete,
                            outcome: partialAnswer == nil && preview == nil
                                ? .failure
                                : .content,
                            preliminaryResult: terminal.preliminaryResult,
                            summaryProvenance: partialAnswer == nil
                                ? (preview == nil ? nil : .quickSummary)
                                : .aiRefined
                        )
                    )
                }) else {
                    guard isCurrentWork(workID) else { return }
                    replaceExchange(
                        id: exchangeID,
                        with: AssistantExchange(
                            id: exchangeID,
                            question: prompt,
                            answer: "The note changed while I was summarizing it, so I stopped before showing a stale result. Please try again now that the latest revision is saved.",
                            mode: .ask,
                            phase: .complete,
                            outcome: .failure
                        )
                    )
                    status = AssistantStatus(
                        message: "A stale summary was discarded.",
                        severity: .warning,
                        action: .retry
                    )
                    completeWork(workID)
                    return
                }
                status = partialAnswer != nil
                    ? AssistantStatus(
                        message: "AI refinement stopped, so I kept the complete summary text and verified references already available.",
                        severity: .information
                    )
                    : preview == nil
                    ? AssistantStatus(
                        message: error.localizedDescription,
                        severity: .error,
                        action: .retry
                    )
                    : AssistantStatus(
                        message: "Generation paused, so I kept the complete quick summary from this iPad.",
                        severity: .information
                    )
                completeWork(workID)
                return
            }
        }
    }

    /// A stale summary retries within the same request/deadline. Retire every
    /// attempt-owned callback and provenance tuple before request preparation
    /// suspends so an earlier revision cannot repaint the waiting row or be
    /// retained by Stop/the watchdog during the next attempt.
    private func resetSummaryAttemptForRetry(
        prompt: String,
        exchangeID: UUID,
        workID: UUID
    ) {
        guard isCurrentWork(workID), activeExchangeID == exchangeID else { return }
        discardPendingStreamUpdate()
        activeFollowUpTask?.cancel()
        activeFollowUpTask = nil
        activeFollowUpSuggestions = []
        activePublicationContext = nil
        activePartialSourceAuthority = [:]
        activePartialFreshnessReceipt = nil
        activeDeterministicPreview = nil
        activeDidReceiveModelText = false
        activePartialSourceIDs = []
        activePartialIsGeneralKnowledge = false
        workPhase = .readingNote
        replaceExchange(
            id: exchangeID,
            with: AssistantExchange(
                id: exchangeID,
                question: prompt,
                answer: "",
                mode: .ask,
                phase: .waiting
            )
        )
    }

    private func runSummary(
        prompt: String,
        scope: AssistantScope,
        snapshot: NoteContentSnapshot,
        verifier: any NoteSnapshotVerifying,
        cacheContext: AssistantArtifactContext,
        directDeadline: ContinuousClock.Instant,
        deadline: ContinuousClock.Instant,
        uiDeadline: ContinuousClock.Instant,
        exchangeID: UUID,
        workID: UUID
    ) async throws {
        let localeIdentifier = Locale.current.identifier
        let outputStyle = Self.summaryOutputStyle(for: prompt)
        let followUpTask = Task { @MainActor [weak self, cpuWorker] in
            let generated = await cpuWorker.followUpSuggestions(
                from: snapshot,
                excluding: prompt
            )
            guard Task.isCancelled == false,
                let self,
                self.isCurrentWork(workID) else { return generated }
            self.activeFollowUpSuggestions = generated
            return generated
        }
        activeFollowUpTask = followUpTask
        let summaryProvider = modelClient as? any OnDeviceNoteSummarizing
        let availability = await modelClient.availability()
        guard isCurrentWork(workID) else { throw CancellationError() }
        modelAvailability = availability

        let preferredIdentity = availability == .available && summaryProvider != nil
            ? AssistantSummaryCacheIdentity.systemModel
            : .deterministic
        let exactKey = Self.summaryCacheKeyV2(
            snapshot: snapshot,
            kind: .summary,
            context: cacheContext,
            identity: preferredIdentity,
            localeIdentifier: localeIdentifier,
            outputStyle: outputStyle
        )
        if let cached = try? await artifactCache?.artifact(
            for: exactKey,
            currentSnapshotHash: snapshot.contentHash
        ),
            await verifier.isCurrent(snapshot.identity) {
            try await publishSummary(
                markdown: cached.markdown,
                sourceIDs: cached.sourceIDs,
                snapshot: snapshot,
                verifier: verifier,
                prompt: prompt,
                exchangeID: exchangeID,
                workID: workID,
                preliminaryResult: preferredIdentity == .deterministic
                    ? .quickSummary
                    : nil,
                summaryProvenance: preferredIdentity == .deterministic
                    ? .quickSummary
                    : .aiRefined
            )
            completeWork(workID)
            scheduleLocalIntelligence(for: snapshot, context: cacheContext)
            return
        }

        // The deterministic preview guarantees useful content even if the
        // system model later times out, is unavailable, or is cancelled.
        let preview = try await AssistantSummaryPipeline(
            summarizer: ExtractiveOnlyNoteSummarizer(),
            snapshotVerifier: verifier
        ).summarize(
            snapshot: snapshot,
            localeIdentifier: localeIdentifier,
            outputStyle: outputStyle
        )
        guard isCurrentWork(workID) else { throw CancellationError() }
        let previewSources = summarySources(
            sourceIDs: preview.coverage.coveredSourceIDs,
            snapshot: snapshot
        )
        guard isCurrentWork(workID) else { throw CancellationError() }
        await beforeResultPublicationForTesting?()
        guard isCurrentWork(workID) else { throw CancellationError() }
        guard await verifier.isCurrent(snapshot.identity) else {
            throw AssistantSummaryPipelineError.staleSnapshot
        }
        guard let publication = await validatedPublication(
            previewSources,
            workID: workID
        ) else {
            guard isCurrentWork(workID) else { throw CancellationError() }
            throw AssistantSummaryPipelineError.staleSnapshot
        }
        guard commitValidatedPublication(
            publication,
            workID: workID,
            { publicationSources in
                activePartialFreshnessReceipt = publication.freshnessReceipt
                replaceExchange(
                    id: exchangeID,
                    with: AssistantExchange(
                        id: exchangeID,
                        question: prompt,
                        answer: preview.markdown,
                        sources: publicationSources,
                        mode: .ask,
                        phase: .streaming,
                        preliminaryResult: .quickSummary,
                        summaryProvenance: .quickSummary
                    )
                )
                rememberDeterministicPreview(
                    answer: preview.markdown,
                    sources: publicationSources,
                    kind: .quickSummary,
                    freshnessReceipt: publication.freshnessReceipt,
                    exchangeID: exchangeID,
                    workID: workID
                )
            }
        ) else {
            guard isCurrentWork(workID) else { throw CancellationError() }
            throw AssistantSummaryPipelineError.staleSnapshot
        }

        guard availability == .available, let summaryProvider else {
            guard await verifier.isCurrent(snapshot.identity) else {
                throw AssistantSummaryPipelineError.staleSnapshot
            }
            try await publishSummary(
                markdown: preview.markdown,
                sourceIDs: preview.coverage.coveredSourceIDs,
                snapshot: snapshot,
                verifier: verifier,
                prompt: prompt,
                exchangeID: exchangeID,
                workID: workID,
                preliminaryResult: .quickSummary,
                summaryProvenance: .quickSummary
            )
            completeWork(workID)
            status = AssistantStatus(
                message: availability.userFacingDescription,
                severity: .information
            )
            scheduleSummaryMaintenance(
                artifact: preview,
                snapshot: snapshot,
                context: cacheContext
            )
            return
        }

        // The provider prewarms the exact fresh summary session it immediately
        // consumes. Avoid a separate awaited warm-up here: it would sit on the
        // foreground deadline before any generation and could duplicate work.
        let reusable = await reusableSectionDigests(
            for: snapshot,
            context: cacheContext,
            identity: .systemModel,
            localeIdentifier: localeIdentifier,
            outputStyle: outputStyle
        )
        armGenerationWatchdog(exchangeID: exchangeID, workID: workID)
        let summarySourceIDs = Set(snapshot.sourceIDs)
        let artifact = try await AssistantSummaryPipeline(
            summarizer: summaryProvider,
            snapshotVerifier: verifier
        ).summarize(
            snapshot: snapshot,
            localeIdentifier: localeIdentifier,
            outputStyle: outputStyle,
            reusableSectionDigests: reusable,
            deadline: deadline,
            directDeadline: directDeadline,
            hierarchicalWorkBegan: { [weak self] in
                await self?.extendSummaryDeadlineForHierarchicalWork(
                    prompt: prompt,
                    scope: scope,
                    deadline: uiDeadline,
                    exchangeID: exchangeID,
                    workID: workID
                )
            },
            directPartialMarkdown: { [weak self] partial in
                await self?.queuePartialSummary(
                    partial,
                    hiding: summarySourceIDs,
                    exchangeID: exchangeID,
                    workID: workID
                )
            },
            progress: { [weak self] event in
                await self?.updateSummaryProgress(
                    event,
                    workID: workID
                )
            }
        )
        armFinalizationWatchdog(exchangeID: exchangeID, workID: workID)
        guard isCurrentWork(workID), await verifier.isCurrent(snapshot.identity) else {
            throw AssistantSummaryPipelineError.staleSnapshot
        }
        workPhase = .finishingUp
        let isWhollyExtractive = artifact.strategy == .extractive
        try await publishSummary(
            markdown: artifact.markdown,
            sourceIDs: artifact.coverage.coveredSourceIDs,
            snapshot: snapshot,
            verifier: verifier,
            prompt: prompt,
            exchangeID: exchangeID,
            workID: workID,
            preliminaryResult: isWhollyExtractive
                ? .quickSummary
                : nil,
            summaryProvenance: isWhollyExtractive
                ? .quickSummary
                : .aiRefined
        )
        completeWork(workID)
        if artifact.usedExtractiveFallback {
            status = AssistantStatus(
                message: isWhollyExtractive
                    ? "AI refinement didn't complete, so I kept the verified Quick summary."
                    : "AI refinement completed with verified extractive text for the sections it could not finish.",
                severity: .information,
                action: .retry
            )
        }
        scheduleSummaryMaintenance(
            artifact: artifact,
            snapshot: snapshot,
            context: cacheContext
        )
    }

    private func extendSummaryDeadlineForHierarchicalWork(
        prompt: String,
        scope: AssistantScope,
        deadline: ContinuousClock.Instant,
        exchangeID: UUID,
        workID: UUID
    ) {
        guard isCurrentWork(workID), ContinuousClock().now < deadline else { return }
        scheduleRequestDeadline(
            task: .summarize,
            scope: scope,
            prompt: prompt,
            deadline: deadline,
            exchangeID: exchangeID,
            workID: workID
        )
    }

    private func updateSummaryProgress(
        _ event: AssistantSummaryProgressEvent,
        workID: UUID
    ) {
        guard isCurrentWork(workID) else { return }
        switch event.stage {
        case .direct:
            workPhase = .writingSummary
        case .section, .chunk:
            workPhase = .summarizingSection(
                current: min(max(event.sectionIndex ?? event.unitIndex, 1), max(event.sectionCount, 1)),
                total: max(event.sectionCount, 1)
            )
        case .reduce:
            workPhase = .finishingUp
        }
    }

    private func publishSummary(
        markdown: String,
        sourceIDs: [String],
        snapshot: NoteContentSnapshot,
        verifier: any NoteSnapshotVerifying,
        prompt: String,
        exchangeID: UUID,
        workID: UUID,
        preliminaryResult: AssistantPreliminaryResultKind? = nil,
        summaryProvenance: AssistantSummaryProvenance
    ) async throws {
        let sources = summarySources(sourceIDs: sourceIDs, snapshot: snapshot)
        guard isCurrentWork(workID) else { throw CancellationError() }
        let followUps = activeFollowUpSuggestions
        guard isCurrentWork(workID) else { throw CancellationError() }
        await beforeResultPublicationForTesting?()
        guard isCurrentWork(workID) else { throw CancellationError() }
        guard await verifier.isCurrent(snapshot.identity) else {
            throw AssistantSummaryPipelineError.staleSnapshot
        }
        guard let publication = await validatedPublication(
            sources,
            workID: workID
        ) else {
            guard isCurrentWork(workID) else { throw CancellationError() }
            throw AssistantSummaryPipelineError.staleSnapshot
        }
        discardPendingStreamUpdate()
        // SummaryPipeline schema 4 stores only canonical semantic plain text.
        // Re-projecting that text would reinterpret literal code and list data
        // after their fence/structure provenance has intentionally been shed.
        let readableMarkdown = markdown.assistantCanonicalNonempty
        guard commitValidatedPublication(
            publication,
            workID: workID,
            { publicationSources in
                replaceExchange(
                    id: exchangeID,
                    with: AssistantExchange(
                        id: exchangeID,
                        question: prompt,
                        answer: readableMarkdown
                            ?? "No readable note content was available to summarize.",
                        sources: publicationSources,
                        followUps: followUps,
                        mode: .ask,
                        phase: .complete,
                        outcome: readableMarkdown == nil ? .noResult : .content,
                        preliminaryResult: preliminaryResult,
                        summaryProvenance: summaryProvenance
                    )
                )
            }
        ) else {
            guard isCurrentWork(workID) else { throw CancellationError() }
            throw AssistantSummaryPipelineError.staleSnapshot
        }
    }

    private func summarySources(
        sourceIDs: [String],
        snapshot: NoteContentSnapshot
    ) -> [AssistantSearchResult] {
        let available = Set(sourceIDs)
        var representativeIDs = snapshot.sections.compactMap { section in
            section.chunks.first(where: { available.contains($0.sourceID) })?.sourceID
        }
        if representativeIDs.count > 8 {
            representativeIDs = Self.evenlySampled(representativeIDs, limit: 8)
        }
        if representativeIDs.isEmpty {
            representativeIDs = Array(sourceIDs.prefix(8))
        }
        return representativeIDs.compactMap { activePartialSourceAuthority[$0] }
    }

    private func reusableSectionDigests(
        for snapshot: NoteContentSnapshot,
        context: AssistantArtifactContext,
        identity: AssistantSummaryCacheIdentity,
        localeIdentifier: String,
        outputStyle: String
    ) async -> [SummarySectionDigest] {
        guard let artifactCache else { return [] }
        let keyedSections = snapshot.sections.map { section in
            let key = Self.summaryCacheKeyV2(
                subject: .section(
                    id: section.id,
                    parentID: context.subject.identifier
                ),
                snapshotHash: section.contentHash,
                kind: .sectionSummary,
                scope: context.scope,
                identity: identity,
                localeIdentifier: localeIdentifier,
                outputStyle: outputStyle
            )
            return (section: section, key: key)
        }
        let lookups = keyedSections.map {
            AssistantArtifactCacheLookupV2(
                key: $0.key,
                currentSnapshotHash: $0.section.contentHash
            )
        }
        let cachedByKey = (try? await artifactCache.artifacts(for: lookups)) ?? [:]
        return keyedSections.compactMap { entry in
            let section = entry.section
            let key = entry.key
            guard let cached = cachedByKey[key] else { return nil }
            return SummarySectionDigest(
                sectionID: section.id,
                ordinal: section.ordinal,
                contentHash: section.contentHash,
                promptVersion: key.promptVersion,
                schemaVersion: Int(key.schemaVersion) ?? SummaryArtifact.currentSchemaVersion,
                localeIdentifier: localeIdentifier,
                outputStyle: outputStyle,
                modelIdentifier: key.providerIdentifier,
                modelBuild: key.modelBuild,
                sourceIDs: section.chunks.map(\.sourceID),
                representedSourceIDs: cached.sourceIDs,
                markdown: cached.markdown,
                usedExtractiveFallback: false
            )
        }
    }

    private func storeSummaryArtifact(
        _ artifact: SummaryArtifact,
        context: AssistantArtifactContext
    ) async throws {
        guard let artifactCache else { return }
        let covered = Set(artifact.coverage.coveredSourceIDs)
        let sectionRecords = artifact.sectionDigests.compactMap { digest -> AssistantArtifactSectionDigest? in
            guard let markdown = digest.markdown?.assistantCanonicalNonempty else { return nil }
            return AssistantArtifactSectionDigest(
                sectionID: digest.sectionID,
                contentHash: digest.contentHash,
                markdown: markdown,
                sourceIDs: digest.representedSourceIDs
            )
        }
        let coveredSections = artifact.sectionDigests.compactMap { digest in
            digest.sourceIDs.contains(where: { covered.contains }) ? digest.sectionID : nil
        }
        let allSections = artifact.sectionDigests.map(\.sectionID)
        let isWhollyExtractive = artifact.strategy == .extractive
        let shouldStoreParent = artifact.usedExtractiveFallback == false
            || isWhollyExtractive
        var records: [AssistantArtifactRecordV2] = []
        if shouldStoreParent {
            let identity = isWhollyExtractive
                ? AssistantSummaryCacheIdentity.deterministic
                : AssistantSummaryCacheIdentity(
                    modelIdentifier: artifact.modelIdentifier,
                    modelVersion: artifact.modelVersion
                )
            let key = Self.summaryCacheKeyV2(
                subject: context.subject,
                snapshotHash: artifact.contentHash,
                kind: .summary,
                scope: context.scope,
                identity: identity,
                localeIdentifier: artifact.localeIdentifier,
                outputStyle: artifact.outputStyle
            )
            records.append(AssistantArtifactRecordV2(
                key: key,
                subjectRevision: artifact.revision,
                markdown: artifact.markdown,
                sourceIDs: artifact.coverage.coveredSourceIDs,
                sectionDigests: sectionRecords,
                coverage: AssistantArtifactCoverage(
                    totalSectionCount: allSections.count,
                    coveredSectionIDs: coveredSections,
                    missingSectionIDs: allSections.filter { !coveredSections.contains($0) }
                )
            ))
        }

        // Mixed generated-plus-extractive parents have no truthful reusable
        // identity: deterministic reuse would promote model prose to a Quick
        // summary, while system-model reuse would suppress a complete retry.
        // Keep only their independently generated sections. Section records use
        // section hashes so unchanged generated work survives the next run.
        for digest in artifact.sectionDigests {
            guard digest.usedExtractiveFallback == false,
                let markdown = digest.markdown?.assistantCanonicalNonempty else { continue }
            let sectionKey = Self.summaryCacheKeyV2(
                subject: .section(
                    id: digest.sectionID,
                    parentID: context.subject.identifier
                ),
                snapshotHash: digest.contentHash,
                kind: .sectionSummary,
                scope: context.scope,
                identity: AssistantSummaryCacheIdentity(
                    modelIdentifier: digest.modelIdentifier,
                    modelVersion: digest.modelVersion
                ),
                localeIdentifier: artifact.localeIdentifier,
                outputStyle: artifact.outputStyle
            )
            records.append(AssistantArtifactRecordV2(
                key: sectionKey,
                subjectRevision: artifact.revision,
                markdown: markdown,
                sourceIDs: digest.representedSourceIDs,
                sectionDigests: [AssistantArtifactSectionDigest(
                    sectionID: digest.sectionID,
                    contentHash: digest.contentHash,
                    markdown: markdown,
                    sourceIDs: digest.representedSourceIDs
                )],
                coverage: AssistantArtifactCoverage(
                    totalSectionCount: 1,
                    coveredSectionIDs: [digest.sectionID]
                )
            ))
        }
        try await artifactCache.store(records, manifests: [])
    }

    nonisolated static func summarySnapshot(
        from indexed: NotebookIndex.ContentSnapshot
    ) throws -> NoteContentSnapshot {
        struct DraftSection {
            var id: String
            var title: String?
            var units: [NotebookIndex.Unit]
        }

        var drafts: [DraftSection] = []
        var draftOffsets: [String: Int] = [:]
        for unit in indexed.units {
            let sectionID: String
            let title: String?
            // Page is the authored presentation unit. Paper text, PDF text,
            // OCR, captions, and future block-aware sources from the same page
            // must feed one page summary instead of creating repeated Page N
            // sections based on index adjacency.
            if let pageID = unit.pageID {
                sectionID = "page:\(pageID.uuidString)"
                title = unit.pageNumber.map { "Page \($0)" }
            } else if let blockID = unit.blockID {
                sectionID = "block:\(blockID.uuidString)"
                title = nil
            } else {
                sectionID = "source:\(unit.id)"
                title = nil
            }

            if let offset = draftOffsets[sectionID] {
                drafts[offset].units.append(unit)
                continue
            }
            draftOffsets[sectionID] = drafts.count
            drafts.append(DraftSection(
                id: sectionID,
                title: title,
                units: [unit]
            ))
        }

        let sections = try drafts.enumerated().map { sectionOffset, draft in
            var previousUnit: NotebookIndex.Unit?
            let orderedUnits = draft.units.sorted(by: summaryUnitOrder)
            let chunks = try orderedUnits.enumerated().map { chunkOffset, unit in
                var text = unit.text
                if let previousUnit, summaryUnitsShareChunkStream(previousUnit, unit) {
                    text = removingChunkOverlap(
                        previous: previousUnit.text,
                        current: unit.text
                    )
                }
                previousUnit = unit
                if unit.kind == .imageContent {
                    text = AssistantSummaryTextCanonicalizer.imageSourceText(text)
                }
                return try NoteSummaryChunk(
                    sourceID: unit.id,
                    ordinal: chunkOffset,
                    text: text
                )
            }
            return try NoteSummarySection(
                id: draft.id,
                ordinal: sectionOffset,
                title: draft.title,
                chunks: chunks
            )
        }
        return try NoteContentSnapshot(
            noteID: indexed.itemID,
            revision: indexed.generation,
            title: indexed.itemName,
            sections: sections
        )
    }

    nonisolated private static func summaryUnitOrder(
        _ lhs: NotebookIndex.Unit,
        _ rhs: NotebookIndex.Unit
    ) -> Bool {
        func priority(_ kind: AssistantSourceKind) -> Int {
            switch kind {
            case .paperKitText: 0
            case .pdfText: 1
            case .imageContent: 2
            case .metadata: 3
            }
        }
        let lhsPriority = priority(lhs.kind)
        let rhsPriority = priority(rhs.kind)
        if lhsPriority != rhsPriority { return lhsPriority < rhsPriority }
        let lhsBlock = lhs.blockID?.uuidString ?? ""
        let rhsBlock = rhs.blockID?.uuidString ?? ""
        if lhsBlock != rhsBlock { return lhsBlock < rhsBlock }
        if lhs.chunkOrdinal != rhs.chunkOrdinal {
            return lhs.chunkOrdinal < rhs.chunkOrdinal
        }
        return lhs.id < rhs.id
    }

    nonisolated private static func summaryUnitsShareChunkStream(
        _ previous: NotebookIndex.Unit,
        _ current: NotebookIndex.Unit
    ) -> Bool {
        guard previous.itemID == current.itemID,
            previous.pageID == current.pageID,
            previous.kind == current.kind,
            current.chunkOrdinal == previous.chunkOrdinal + 1 else {
            return false
        }
        if previous.blockID != nil || current.blockID != nil {
            return previous.blockID != nil && previous.blockID == current.blockID
        }
        // Page text and PDF text each originate in one source stream per page.
        // Image records receive a stable block identity during indexing; an
        // older block-less image index is deliberately not de-overlapped,
        // because separate images on one page must never be merged by guess.
        return current.kind == .paperKitText || current.kind == .pdfText
    }

    nonisolated private static func removingChunkOverlap(
        previous: String,
        current: String
    ) -> String {
        let maximum = min(NotebookIndex.chunkOverlapLength, previous.count, current.count)
        let minimumMeaningfulOverlap = 8
        guard maximum >= minimumMeaningfulOverlap else { return current }
        for length in stride(from: maximum, through: minimumMeaningfulOverlap, by: -1) {
            if previous.suffix(length) == current.prefix(length) {
                let remainder = current.dropFirst(length)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return remainder.isEmpty ? current : remainder
            }
        }
        return current
    }

    private static func summaryOutputStyle(for prompt: String) -> String {
        let normalized = prompt.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
        if ["brief", "concise", "short", "quick", "tldr", "tl;dr"].contains(where: normalized.contains) {
            return "concise"
        }
        if ["detailed", "comprehensive", "thorough", "in depth", "in-depth"].contains(where: normalized.contains) {
            return "detailed"
        }
        return "balanced"
    }

    private static func summaryCacheKeyV2(
        snapshot: NoteContentSnapshot,
        kind: AssistantArtifactKind,
        context: AssistantArtifactContext,
        identity: AssistantSummaryCacheIdentity,
        localeIdentifier: String,
        outputStyle: String
    ) -> AssistantArtifactCacheKeyV2 {
        summaryCacheKeyV2(
            subject: context.subject,
            snapshotHash: snapshot.contentHash,
            kind: kind,
            scope: context.scope,
            identity: identity,
            localeIdentifier: localeIdentifier,
            outputStyle: outputStyle
        )
    }

    private static func localIntelligenceCacheKeyV2(
        snapshot: NoteContentSnapshot,
        kind: AssistantArtifactKind,
        context: AssistantArtifactContext,
        identity: AssistantSummaryCacheIdentity,
        localeIdentifier: String
    ) -> AssistantArtifactCacheKeyV2 {
        AssistantArtifactCacheKeyV2(
            subject: context.subject,
            snapshotHash: snapshot.contentHash,
            taskIdentifier: kind.rawValue,
            artifactKind: kind,
            scope: context.scope,
            promptVersion: AssistantLocalIntelligenceBuilder.promptVersion,
            schemaVersion: AssistantLocalIntelligenceBuilder.schemaVersion,
            retrievalVersion: "not-applicable",
            derivationVersion: "local-intelligence-v2",
            providerIdentifier: identity.modelIdentifier,
            modelBuild: identity.modelVersion,
            localeIdentifier: localeIdentifier,
            outputStyle: "balanced"
        )
    }

    private static func groundedCacheKeyV2(
        task: AssistantTask,
        prompt: String,
        snapshotHash: String,
        context: AssistantArtifactContext
    ) -> AssistantArtifactCacheKeyV2 {
        let kind: AssistantArtifactKind = task == .explain ? .explanation : .answer
        return AssistantArtifactCacheKeyV2(
            subject: context.subject,
            snapshotHash: snapshotHash,
            taskIdentifier: task.rawValue,
            artifactKind: kind,
            scope: context.scope,
            requestFingerprint: AssistantLocalIntelligenceBuilder.requestFingerprint(prompt),
            promptVersion: "grounded-response-v5",
            schemaVersion: "3",
            retrievalVersion: "bounded-rag-v2",
            derivationVersion: "grounded-response-v5",
            providerIdentifier: AssistantSummaryCacheIdentity.systemModel.modelIdentifier,
            modelBuild: AssistantSummaryCacheIdentity.systemModel.modelVersion,
            localeIdentifier: Locale.current.identifier,
            outputStyle: "balanced"
        )
    }

    private static func evidenceSnapshotHash(
        _ results: [AssistantSearchResult]
    ) -> String {
        let identity = results.map { result in
            [
                result.id,
                result.anchor.itemID.uuidString,
                result.anchor.pageID?.uuidString ?? "no-page",
                String(result.anchor.generation),
                result.anchor.contentHash,
            ].joined(separator: "\u{1f}")
        }.joined(separator: "\u{1e}")
        return AssistantLocalIntelligenceBuilder.requestFingerprint(identity)
    }

    private static func studyCacheKeyV2(
        prompt: String,
        snapshot: NoteContentSnapshot,
        context: AssistantArtifactContext
    ) -> AssistantArtifactCacheKeyV2 {
        AssistantArtifactCacheKeyV2(
            subject: context.subject,
            snapshotHash: snapshot.contentHash,
            taskIdentifier: AssistantTask.study.rawValue,
            artifactKind: .study,
            scope: context.scope,
            requestFingerprint: AssistantLocalIntelligenceBuilder.requestFingerprint(prompt),
            promptVersion: "study-v6",
            schemaVersion: "4",
            retrievalVersion: "bounded-rag-v2",
            derivationVersion: "study-v6",
            providerIdentifier: AssistantSummaryCacheIdentity.systemModel.modelIdentifier,
            modelBuild: AssistantSummaryCacheIdentity.systemModel.modelVersion,
            localeIdentifier: Locale.current.identifier,
            outputStyle: "balanced"
        )
    }

    private static func summaryCacheKeyV2(
        subject: AssistantArtifactSubject,
        snapshotHash: String,
        kind: AssistantArtifactKind,
        scope: AssistantArtifactScopeIdentity,
        identity: AssistantSummaryCacheIdentity,
        localeIdentifier: String,
        outputStyle: String
    ) -> AssistantArtifactCacheKeyV2 {
        AssistantArtifactCacheKeyV2(
            subject: subject,
            snapshotHash: snapshotHash,
            taskIdentifier: AssistantTask.summarize.rawValue,
            artifactKind: kind,
            scope: scope,
            promptVersion: "summary-v6",
            schemaVersion: String(SummaryArtifact.currentSchemaVersion),
            retrievalVersion: "not-applicable",
            derivationVersion: "hierarchical-summary-v6",
            providerIdentifier: identity.modelIdentifier,
            modelBuild: identity.modelVersion,
            localeIdentifier: localeIdentifier,
            outputStyle: outputStyle
        )
    }

    private static func intelligenceManifestKey(
        snapshot: NoteContentSnapshot,
        context: AssistantArtifactContext,
        localeIdentifier: String
    ) -> AssistantIntelligenceManifestKey {
        AssistantIntelligenceManifestKey(
            subject: context.subject,
            snapshotHash: snapshot.contentHash,
            scope: context.scope,
            promptVersion: AssistantLocalIntelligenceBuilder.promptVersion,
            schemaVersion: AssistantLocalIntelligenceBuilder.schemaVersion,
            retrievalVersion: "not-applicable",
            derivationVersion: "local-intelligence-v2",
            providerIdentifier: AssistantSummaryCacheIdentity.localIntelligence.modelIdentifier,
            modelBuild: AssistantSummaryCacheIdentity.localIntelligence.modelVersion,
            localeIdentifier: localeIdentifier
        )
    }

    private static func artifactContext(
        noteID: UUID,
        scope: AssistantScope,
        pageID: UUID?
    ) -> AssistantArtifactContext {
        switch scope {
        case .page:
            if let pageID {
                return AssistantArtifactContext(
                    subject: .page(pageID),
                    scope: .page(pageID)
                )
            }
            return AssistantArtifactContext(
                subject: .notebook(noteID),
                scope: .notebook(noteID)
            )
        case .item:
            return AssistantArtifactContext(
                subject: .notebook(noteID),
                scope: .notebook(noteID)
            )
        case .library:
            return AssistantArtifactContext(subject: .library, scope: .library)
        }
    }

    private static func evenlySampled<Element>(
        _ values: [Element],
        limit: Int
    ) -> [Element] {
        guard values.count > limit else { return values }
        guard limit > 1 else { return [values[0]] }
        return (0..<limit).map { offset in
            values[offset * (values.count - 1) / (limit - 1)]
        }
    }

    private func isCurrentWork(_ workID: UUID) -> Bool {
        Task.isCancelled == false && activeWorkID == workID
    }

    private func installPublicationContext(
        workID: UUID,
        scope: AssistantScope,
        contentSnapshot: NotebookIndex.ContentSnapshot?,
        summaryCapture: NotebookIndex.SummaryCapture? = nil
    ) {
        guard isCurrentWork(workID) else { return }
        activePublicationContext = AssistantPublicationContext(
            workID: workID,
            scope: scope,
            contentSnapshot: contentSnapshot,
            summaryCapture: summaryCapture
        )
    }

    /// The sole freshness gate for grounded presentation. It is intentionally
    /// the final awaited operation before callers synchronously replace an
    /// exchange. A complete page/notebook snapshot is checked both before and
    /// after source hydration. Library work rehydrates only its already-bounded
    /// anchors and requires an exact locator/content match in the same order.
    private func validatedPublication(
        _ expectedSources: [AssistantSearchResult],
        workID: UUID
    ) async -> AssistantValidatedSourceSet? {
        guard isCurrentWork(workID),
            let context = activePublicationContext,
            context.workID == workID else { return nil }

        if let summaryCapture = context.summaryCapture {
            guard let contextSnapshot = context.contentSnapshot,
                contextSnapshot.itemID
            == summaryCapture.contentSnapshot.itemID,
            contextSnapshot.pageID
                == summaryCapture.contentSnapshot.pageID,
            contextSnapshot.generation
                == summaryCapture.contentSnapshot.generation,
            contextSnapshot.contentHash
                == summaryCapture.contentSnapshot.contentHash,
            let validation = summaryCapture.validatedPublication(
                matching: expectedSources
            ),
            isCurrentWork(workID) else { return nil }
        let sources = zip(expectedSources, validation.sources).map {
            expected, current in
            AssistantReferenceNormalizer.refreshing(
                current: current,
                preserving: expected
            )
        }
        return AssistantValidatedSourceSet(
            sources: sources,
            freshnessReceipt: validation.receipt
        )
    }

    if context.contentSnapshot == nil,
        context.scope != .library,
        expectedSources.isEmpty == false {
        // Never publish note-derived rows without a complete scoped
        // authority. Empty local/no-answer and explicit general-knowledge
        // outcomes contain no note data and remain safe.
        return nil
    }

    guard let validation = await index.validatedPublication(
        matching: expectedSources,
        contentSnapshot: context.contentSnapshot
    ),
        isCurrentWork(workID) else { return nil }
    let sources = zip(expectedSources, validation.sources).map { expected, current in
        AssistantReferenceNormalizer.refreshing(
            current: current,
            preserving: expected
        )
    }
    return AssistantValidatedSourceSet(
        sources: sources,
        freshnessReceipt: validation.receipt
    )
}

/// Claims a previously awaited validation receipt and performs the actual
/// exchange mutation under the index's synchronous semantic-epoch lock.
/// This closes the final check-to-publication race without ever holding a
/// lock across an async operation.
private func commitValidatedPublication(
    _ publication: AssistantValidatedSourceSet,
    workID: UUID,
    _ body: ([AssistantSearchResult]) -> Void
) -> Bool {
    var didPublish = false
    let claimed = publication.freshnessReceipt.performIfCurrent {
        guard isCurrentWork(workID) else { return }
        body(publication.sources)
        didPublish = true
    }
    return claimed && didPublish
}

/// A deterministic preview retains its Quick summary provenance. Once a
/// summarize request has accepted model text, its terminal candidate has no
/// preliminary-result marker and must remain visibly identified as an AI
/// refinement even when Stop, the hard watchdog, or async cancellation
/// publishes that partial instead of the normal completion path.
private static func retainedSummaryProvenance(
    task: AssistantTask?,
    preliminaryResult: AssistantPreliminaryResultKind?
) -> AssistantSummaryProvenance? {
    guard task == .summarize else { return nil }
    switch preliminaryResult {
    case .quickSummary:
        return .quickSummary
    case nil:
        return .aiRefined
    case .relevantPassages:
        return nil
    }
}

/// Captures answer and typed provenance as one MainActor transaction. The
/// source authority was installed before generation from the bounded
/// retrieval set or the complete summary snapshot, so Stop needs no await
/// and async terminal paths can validate an immutable tuple.
private func activePartialSnapshot(
    exchangeID: UUID,
    workID: UUID
) -> AssistantActivePartialSnapshot? {
    guard isCurrentWork(workID),
            activeExchangeID == exchangeID,
            activeDidReceiveModelText,
            let current = exchanges.first(where: { $0.id == exchangeID }),
            current.phase != .complete,
            current.phase != .stopped,
            let answer = current.answer.assistantCanonicalNonempty else {
        return nil
    }

    if activePartialIsGeneralKnowledge {
        guard activePartialSourceIDs.isEmpty else { return nil }
        return AssistantActivePartialSnapshot(
            answer: answer,
            sources: [],
            isGeneralKnowledge: true,
            freshnessReceipt: nil
        )
    }

    let sourceIDs = activePartialSourceIDs
    guard sourceIDs.isEmpty == false,
            Set(sourceIDs).count == sourceIDs.count else { return nil }
    let sources = sourceIDs.compactMap { activePartialSourceAuthority[$0] }
    let representedItems = Set(sources.map(\.anchor.itemID))
    guard sources.count == sourceIDs.count,
            let freshnessReceipt = activePartialFreshnessReceipt?
                .restricted(to: representedItems) else { return nil }
    return AssistantActivePartialSnapshot(
        answer: answer,
        sources: sources,
        isGeneralKnowledge: false,
        freshnessReceipt: freshnessReceipt
    )
}

/// Revalidates the exact source rows captured with a cumulative answer.
/// Empty evidence is accepted only for the snapshot's explicit
/// general-knowledge mode; grounded snapshots always carry at least one row.
private func validatedSourcesForActivePartial(
    _ snapshot: AssistantActivePartialSnapshot,
    workID: UUID
) async -> AssistantValidatedPartialSourceSet? {
    guard snapshot.isGeneralKnowledge == snapshot.sources.isEmpty else {
        return nil
    }
    if snapshot.isGeneralKnowledge {
        // Explicit general-knowledge output carries no note provenance;
        // unrelated retrieval/index churn cannot make it stale.
        return isCurrentWork(workID)
            ? AssistantValidatedPartialSourceSet(
                sources: [],
                freshnessReceipt: nil
            )
            : nil
    }
    guard let publication = await validatedPublication(
        snapshot.sources,
        workID: workID
    ) else { return nil }
    return AssistantValidatedPartialSourceSet(
        sources: publication.sources,
        freshnessReceipt: publication.freshnessReceipt
    )
}

/// Chooses one terminal receipt and makes its freshness check the final
/// suspension before publication. Exact typed partial provenance wins;
/// the broader deterministic preview is checked only if that tuple cannot
/// be retained, preventing unrelated-source churn and validation TOCTOUs.
private func validatedTerminalContent(
    partial: AssistantActivePartialSnapshot?,
    preview: AssistantDeterministicPreview?,
    task: AssistantTask?,
    workID: UUID
) async -> AssistantValidatedTerminalContent? {
    if let partial,
        let validatedPartial = await validatedSourcesForActivePartial(
            partial,
            workID: workID
        ),
        isCurrentWork(workID) {
        let freshSources = validatedPartial.sources
        let presentedSources = task == .summarize && freshSources.count > 8
            ? Self.evenlySampled(freshSources, limit: 8)
            : freshSources
        return AssistantValidatedTerminalContent(
            answer: partial.answer,
            sources: presentedSources,
            isGeneralKnowledge: partial.isGeneralKnowledge,
            preliminaryResult: nil,
            freshnessReceipt: validatedPartial.freshnessReceipt
        )
    }

    if let preview,
        let publication = await validatedPublication(
            preview.sources,
            workID: workID
        ),
        isCurrentWork(workID) {
        return AssistantValidatedTerminalContent(
            answer: preview.answer,
            sources: publication.sources,
            isGeneralKnowledge: false,
            preliminaryResult: preview.kind,
            freshnessReceipt: publication.freshnessReceipt
        )
    }
    return nil
}

private func rememberDeterministicPreview(
    answer: String,
    sources: [AssistantSearchResult],
    kind: AssistantPreliminaryResultKind,
    freshnessReceipt: NotebookIndex.PublicationReceipt,
    exchangeID: UUID,
    workID: UUID
) {
    guard isCurrentWork(workID), activeExchangeID == exchangeID else { return }
    activeDeterministicPreview = AssistantDeterministicPreview(
        workID: workID,
        exchangeID: exchangeID,
        answer: answer,
        sources: sources,
        kind: kind,
        freshnessReceipt: freshnessReceipt
    )
}

/// Finishes a request that could not cross the save-and-retrieval
/// boundary. The copy deliberately describes the observed failure instead
/// of inferring that the note changed.
@discardableResult
private func finishRequestPreparationFailure(
    _ result: AssistantRequestPreparationResult,
    prompt: String,
    mode: AssistantRequestMode,
    exchangeID: UUID,
    workID: UUID
) -> Bool {
    let answer: String
    let terminalStatus: AssistantStatus
    switch result {
    case .ready:
        return false
    case .canvasTemporarilyBusy:
        answer = "The canvas is temporarily busy, so I paused before reading it. Please try again in a moment."
        terminalStatus = AssistantStatus(
            message: "The canvas is temporarily busy.",
            severity: .information,
            action: .retry
        )
    case .saveFailed:
        answer = "I couldn't save this note for the assistant, so I stopped before using older content. Resolve the save error, then try again."
        terminalStatus = AssistantStatus(
            message: "The note could not be saved for the assistant.",
            severity: .error,
            action: .retry
        )
    case .retrievalPreparationFailed:
        answer = "Your latest note was saved, but its on-device search index wasn't ready before this request ended. Please try again."
        terminalStatus = AssistantStatus(
            message: "The note was saved, but on-device retrieval was not ready in time.",
            severity: .warning,
            action: .retry
        )
    }
    replaceExchange(
        id: exchangeID,
        with: AssistantExchange(
            id: exchangeID,
            question: prompt,
            answer: answer,
            mode: mode,
            phase: .complete,
            outcome: .failure
        )
    )
    status = terminalStatus
    completeWork(workID, terminal: .failedWithFallback(answer))
    return true
}

private func finishStaleGroundedWork(
    prompt: String,
    exchangeID: UUID,
    workID: UUID
) {
    guard isCurrentWork(workID) else { return }
    let fallback = "The note changed while I was answering, so I discarded the stale result. "
        + "Ask again to use the saved revision now on screen."
    discardPendingStreamUpdate()
    replaceExchange(
        id: exchangeID,
        with: AssistantExchange(
            id: exchangeID,
            question: prompt,
            answer: fallback,
            mode: .ask,
            phase: .complete,
            outcome: .failure
        )
    )
    status = AssistantStatus(
        message: "A stale answer was discarded.",
        severity: .warning,
        action: .retry
    )
    completeWork(workID, terminal: .failedWithFallback(fallback))
}

private func completeWork(
    _ workID: UUID,
    terminal: AssistantPipelineUpdatePayload = .completed
) {
    guard activeWorkID == workID else { return }
    let pipelineRequestID = activePipelineRequest?.requestID
    let completedExchangeID = activeExchangeID
    let deferredFollowUpTask: Task<[String], Never>? = if activeFollowUpSuggestions.isEmpty {
        activeFollowUpTask
    } else {
        nil
    }
    if let pipelineRequestID {
        enqueuePipelineUpdate(terminal, requestID: pipelineRequestID)
    }
    requestDeadlineTask?.cancel()
    requestDeadlineTask = nil
    activeWatchdogDeadline = nil
    if deferredFollowUpTask == nil {
        activeFollowUpTask?.cancel()
    }
    activeFollowUpTask = nil
    activeFollowUpSuggestions = []
    discardPendingStreamUpdate()
    activePublicationContext = nil
    activePartialSourceAuthority = [:]
    activePartialFreshnessReceipt = nil
    activeDeterministicPreview = nil
    activeWorkID = nil
    activeExchangeID = nil
    activePipelineRequest = nil
    isWorking = false
    workPhase = nil
    cancelProgressPresentation()
    workTask = nil
    if let deferredFollowUpTask, let completedExchangeID {
        scheduleDeferredFollowUpEnrichment(
            from: deferredFollowUpTask,
            exchangeID: completedExchangeID
        )
    }
}

private func scheduleDeferredFollowUpEnrichment(
    from task: Task<[String], Never>,
    exchangeID: UUID
) {
    Task { @MainActor [weak self] in
        let suggestions = await task.value
        guard let self,
            suggestions.isEmpty == false,
            let exchange = self.exchanges.first(where: { $0.id == exchangeID }),
            exchange.phase == .complete,
            exchange.followUps.isEmpty,
            exchange.sources.isEmpty == false,
            exchange.isGeneralKnowledge == false else { return }
        self.replaceExchange(
            id: exchangeID,
            with: AssistantExchange(
                id: exchange.id,
                question: exchange.question,
                answer: exchange.answer,
                sources: exchange.sources,
                followUps: suggestions,
                isGeneralKnowledge: exchange.isGeneralKnowledge,
                mode: exchange.mode,
                phase: exchange.phase,
                outcome: exchange.outcome,
                preliminaryResult: exchange.preliminaryResult,
                summaryProvenance: exchange.summaryProvenance,
                task: exchange.task,
                scope: exchange.scope,
                scopeTitle: exchange.scopeTitle
            )
        )
    }
}

private func finishCancelledWork(_ workID: UUID, exchangeID: UUID) async {
    guard activeWorkID == workID else { return }
    flushPendingStreamUpdate()
    let partial = activePartialSnapshot(
        exchangeID: exchangeID,
        workID: workID
    )
    let preview = activeDeterministicPreview.flatMap {
        $0.workID == workID && $0.exchangeID == exchangeID ? $0 : nil
    }
    let task = exchanges.first(where: { $0.id == exchangeID })?.task
    let validated = await validatedTerminalContent(
        partial: partial,
        preview: preview,
        task: task,
        workID: workID
    )
    guard isCurrentWork(workID) else { return }
    if let current = exchanges.first(where: { $0.id == exchangeID }) {
        let retained = validated?.performIfCurrent {
            replaceExchange(
                id: exchangeID,
                with: AssistantExchange(
                    id: exchangeID,
                    question: current.question,
                    answer: validated?.answer ?? "Stopped.",
                    sources: validated?.sources ?? [],
                    isGeneralKnowledge: validated?.isGeneralKnowledge ?? false,
                    mode: current.mode,
                    phase: .stopped,
                    outcome: .content,
                    preliminaryResult: validated?.preliminaryResult,
                    summaryProvenance: Self.retainedSummaryProvenance(
                        task: task,
                        preliminaryResult: validated?.preliminaryResult
                    )
                )
            )
        } ?? false
        if retained == false {
            replaceExchange(
                id: exchangeID,
                with: AssistantExchange(
                    id: exchangeID,
                    question: current.question,
                    answer: "Stopped.",
                    sources: [],
                    mode: current.mode,
                    phase: .stopped,
                    outcome: .failure
                )
            )
        }
    }
    completeWork(workID, terminal: .stopped)
}

private struct AssistantArtifactContext: Equatable, Sendable {
    let subject: AssistantArtifactSubject
    let scope: AssistantArtifactScopeIdentity
}

private struct AssistantSummaryCacheIdentity: Equatable, Sendable {
    let modelIdentifier: String
    let modelVersion: String

    static let systemModel = AssistantSummaryCacheIdentity(
        modelIdentifier: "apple.system-language-model.general",
        modelVersion: ProcessInfo.processInfo.operatingSystemVersionString
    )
    static let deterministic = AssistantSummaryCacheIdentity(
        modelIdentifier: "deterministic-extractive",
        modelVersion: "1"
    )
    static let localIntelligence = AssistantSummaryCacheIdentity(
        modelIdentifier: "apple-natural-language-deterministic",
        modelVersion: "1"
    )
}

private struct NotebookIndexSummarySnapshotVerifier: NoteSnapshotVerifying {
    let expectedIdentity: NoteSnapshotIdentity
    let freshnessReceipt: NotebookIndex.PublicationReceipt

    func isCurrent(_ identity: NoteSnapshotIdentity) async -> Bool {
        guard identity == expectedIdentity else { return false }
        return freshnessReceipt.performIfCurrent {}
    }
}

private struct ExtractiveOnlyNoteSummarizer: OnDeviceNoteSummarizing {
    func contextSize() async -> Int { 0 }
    func tokenCount(for _: String) async -> Int { 0 }

    func summarizeInFreshSession(
        _: OnDeviceSummaryRequest
    ) async throws -> OnDeviceSummaryResponse {
        throw AssistantModelClientError.unavailable(.deviceNotEligible)
    }
}

private extension AssistantSearchResult {
    var evidenceSource: AssistantEvidenceSource {
        let location = if let pageNumber = anchor.pageNumber {
            "\(anchor.itemName), page \(pageNumber)"
        } else {
            anchor.itemName
        }
        return AssistantEvidenceSource(
            id: anchor.id,
            displayLocation: location,
            snippet: anchor.snippet,
            fullText: fullText
        )
    }
}

public extension AssistantScope {
    var displayTitle: String {
        switch self {
        case .page: "Page"
        case .item: "Item"
        case .library: "Library"
        }
    }

    var systemImage: String {
        switch self {
        case .page: "doc"
        case .item: "note.text"
        case .library: "books.vertical"
        }
    }
}

private extension AssistantModelAvailability {
    var userFacingDescription: String {
        switch self {
        case .available:
            "Apple Intelligence is available."
        case .unavailable(.deviceNotEligible):
            "On-device answers require an Apple Intelligence-capable iPad."
        case .unavailable(.appleIntelligenceNotEnabled):
            "Turn on Apple Intelligence in Settings to generate an answer."
        case .unavailable(.modelNotReady):
            "The on-device language model is still becoming ready."
        case .unavailable(.unsupportedLanguageOrLocale):
            "The current language is not supported for on-device answers."
        }
    }
}

private extension AssistantTask {
    var requestHardDeadline: Duration {
        AssistantFoundationTimeoutPolicy.defaultDuration(for: self)
    }

    /// Requests without useful progress settle quickly. Once a generation is
    /// alive, its rolling liveness watchdog can extend toward the independent
    /// absolute request cap.
    var initialWatchdogDeadline: Duration {
        AssistantFoundationTimeoutPolicy.initialWatchdogDuration(for: self)
    }

    var retrievalPassageLimit: Int {
        switch self {
        case .answer: 4
        case .explain: 5
        case .study: 6
        case .summarize, .find: 5
        }
    }
}

private extension String {
    var assistantTrimmedNonempty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// Current assistant cache/summary schemas contain semantic plain text,
    /// not provider Markdown. Remove only framing newlines and preserve every
    /// meaningful space in code or aligned text.
    var assistantCanonicalNonempty: String? {
        let value = trimmingCharacters(in: .newlines)
        return value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : value
    }

    func hasPhrasePrefix(_ phrase: String) -> Bool {
        self == phrase || hasPrefix("\(phrase) ")
    }
}
