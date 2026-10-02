import CoreGraphics
import Foundation

public enum AssistantScope: String, CaseIterable, Codable, Hashable, Sendable {
    case page
    case item
    case library
}

public extension AssistantScope {
    /// Scope alias used for notebook-level retrieval rows.
    static var notebook: AssistantScope { .item }
}

public enum AssistantSourceKind: String, CaseIterable, Codable, Hashable, Sendable {
    case paperKitText
    case pdfText
    case imageContent
    case metadata
}

/// Everything the local index needs to discover and describe one library item.
/// The Canvas directory points at the verified Canvas Core store; fallback text
/// is used only when that item has no page-level text available.
public struct AssistantIndexedItem: Equatable, Hashable, Sendable {
    public let itemID: UUID
    public let itemName: String
    public let kind: LibraryItemKind
    public let parentID: UUID?
    public let canvasDirectory: URL
    public let fallbackSearchableText: String

    /// The newest verified Canvas Core generation the retrieval index should
    /// represent. Zero generation callers source-compatible and means that
    /// any verified generation is acceptable.
    public let expectedGeneration: Int64

    /// A durable derived-data marker: the catalog/preview claims a generation
    /// whose stamped thumbnail is missed. Persisted retrieval manifests must
    /// not be trusted until Canvas Core verifies and republishes this item.
    public let requiresVerifiedRecovery: Bool

    public init(
        itemID: UUID,
        itemName: String,
        kind: LibraryItemKind,
        parentID: UUID?,
        canvasDirectory: URL,
        fallbackSearchableText: String = "",
        expectedGeneration: Int64 = 0,
        requiresVerifiedRecovery: Bool = false
    ) {
        self.itemID = itemID
        self.itemName = itemName
        self.kind = kind
        self.parentID = parentID
        self.canvasDirectory = Self.stableCanvasDirectoryURL(canvasDirectory)
        self.fallbackSearchableText = fallbackSearchableText
        self.expectedGeneration = max(expectedGeneration, 0)
        self.requiresVerifiedRecovery = requiresVerifiedRecovery
    }

    /// iOS exposes an app-container path through equivalent, /private/var
    /// and /var spellings. Normalize that alias lexicically before consulting
    /// the filesystem, so creating the Canvas directory cannot change this
    /// item's persisted retrieval identity.
    private static func stableCanvasDirectoryURL(_ url: URL) -> URL {
        var components: [String] = []
        for component in url.pathComponents {
            switch component {
            case "", "/", "/var", "/private", "/private/var":
                continue
            case ".", "..":
                if components.isEmpty == false {
                    components.removeLast()
                }
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
            isDirectory: true
        )
    }
}

/// An immutable citation locator. Page number and snippet are presentation
/// metadata; item/page identifiers, kind, and content hash are the authority
/// used to re-resolve the source after a newer verified checkpoint.
public struct AssistantSourceAnchor: Codable, Equatable, Hashable, Sendable, Identifiable {
    public let id: String
    public let itemID: UUID
    public let pageID: UUID?
    public let blockID: UUID?
    public let itemName: String
    public let pageNumber: Int?
    public let kind: AssistantSourceKind
    public let pageBounds: CGRect?
    public let generation: Int64
    public let contentHash: String
    public let snippet: String

    public init(
        id: String = UUID().uuidString,
        itemID: UUID,
        pageID: UUID? = nil,
        blockID: UUID? = nil,
        itemName: String,
        pageNumber: Int? = nil,
        kind: AssistantSourceKind,
        pageBounds: CGRect? = nil,
        generation: Int64,
        contentHash: String,
        snippet: String
    ) {
        self.id = id
        self.itemID = itemID
        self.pageID = pageID
        self.blockID = blockID
        self.itemName = itemName
        self.pageNumber = pageNumber
        self.kind = kind
        self.pageBounds = pageBounds
        self.generation = generation
        self.contentHash = contentHash
        self.snippet = snippet
    }
}

public struct AssistantSearchResult: Equatable, Sendable, Identifiable {
    public let anchor: AssistantSourceAnchor
    public let fullText: String
    public let score: Double

    /// Derived display data is intentionally excluded from evidence identity.
    /// Presentation normalization fills it once before publication so streaming
    /// updates never reparse the indexed content.
    fileprivate let preparedDisplaySnippet: String?

    public var id: String { anchor.id }

    /// A compact presentation-safe projection for reference cards and
    /// accessibility. The indexed `anchor.snippet` and `fullText` remain
    /// untouched so freshness checks and model grounding always use the
    /// original evidence.
    var displaySnippet: String {
        preparedDisplaySnippet ?? AssistantReferenceNormalizer.displaySnippet(for: self)
    }

    fileprivate init(
        anchor: AssistantSourceAnchor,
        fullText: String,
        score: Double,
        preparedDisplaySnippet: String? = nil
    ) {
        self.anchor = anchor
        self.fullText = fullText
        self.score = score
        self.preparedDisplaySnippet = preparedDisplaySnippet
    }

    public static func == (
        lhs: AssistantSearchResult,
        rhs: AssistantSearchResult
    ) -> Bool {
        lhs.anchor == rhs.anchor
            && lhs.fullText == rhs.fullText
            && lhs.score == rhs.score
    }
}

/// Keeps retrieval evidence exact while presenting one useful reference for
/// each location. The References UI can actually distinguish sources on the
/// same page: model prompting may retain more than one bounded passage from a
/// page; only the presentation rows are collapsed.
enum AssistantReferenceNormalizer {
    private struct LocationKey: Hashable {
        let itemID: UUID
        let pageID: UUID?
    }

    private struct PresentationEvidenceKey: Hashable {
        let itemID: UUID
        let canonicalText: String
    }

    /// A later verified checkpoint may re-derive this anchor from the current
    /// index. Keep its authoritative identity but retain the ranked query
    /// excerpt and score when they still describe the exact same content.
    static func refresh(
        current: AssistantSearchResult,
        ranked: AssistantSearchResult
    ) -> AssistantSearchResult? {
        guard current.id == ranked.id,
              current.anchor.itemID == ranked.anchor.itemID,
              current.anchor.pageID == ranked.anchor.pageID,
              current.anchor.contentHash == ranked.anchor.contentHash,
              current.fullText == ranked.fullText else {
            return nil
        }

        let rankedSnippet = compact(ranked.anchor.snippet, in: current.fullText)
        let snippet = isGrounded(rankedSnippet, in: current.fullText)
            ? ranked.anchor.snippet
            : current.anchor.snippet
        return replacing(current, snippet: snippet, score: ranked.score)
    }

    /// Canonicalizes references for display only. The first occurrence fixes
    /// the location's position, while a later passage may replace it when it
    /// is newer, more relevant, or contains materially better source data.
    static func referencesForPresentation(
        _ sources: [AssistantSearchResult],
        excludingAnswer: String? = nil
    ) -> [AssistantSearchResult] {
        var orderedLocations: [LocationKey] = []
        var representatives: [LocationKey: AssistantSearchResult] = [:]

        for source in sources where source.anchor.kind != .metadata {
            let key = LocationKey(
                itemID: source.anchor.itemID,
                pageID: source.anchor.pageID)

            guard let existing = representatives[key] else {
                orderedLocations.append(key)
                representatives[key] = source
                continue
            }
            if isPreferred(source, over: existing) {
                representatives[key] = source
            }
        }

        var presented: [AssistantSearchResult] = []
        var representationEvidenceKeys = Set<PresentationEvidenceKey>()

        for key in orderedLocations {
            guard let representative = representatives[key] else {
                continue
            }
            let prepared = preparedForPresentation(
                representative,
                excludingAnswer: excludingAnswer)
            let visibleEvidence = compact(prepared.displaySnippet)
            guard visibleEvidence.isEmpty == false else {
                continue
            }
            let evidenceKey = PresentationEvidenceKey(
                itemID: prepared.anchor.itemID,
                canonicalText: canonicalText(visibleEvidence))
            if representationEvidenceKeys.contains(evidenceKey) {
                continue
            }
            representationEvidenceKeys.insert(evidenceKey)
            presented.append(prepared)
        }

        return presented
    }

    private static func isPreferred(
        _ candidate: AssistantSearchResult,
        over existing: AssistantSearchResult
    ) -> Bool {
        if candidate.anchor.generation != existing.anchor.generation {
            return candidate.anchor.generation > existing.anchor.generation
        }

        let candidateIsSubstantive = candidate.anchor.kind != .metadata
        let existingIsSubstantive = existing.anchor.kind != .metadata
        if candidateIsSubstantive != existingIsSubstantive {
            return candidateIsSubstantive
        }

        let candidateQuality = informationScore(candidate)
        let existingQuality = informationScore(existing)
        if candidateQuality != existingQuality {
            return candidateQuality > existingQuality
        }

        // Kind is only a tie-breaker. A concrete image description or OCR
        // passage is more useful than a thin text block from the same page.
        let candidateContentPriority = contentPriority(candidate)
        let existingContentPriority = contentPriority(existing)
        if candidateContentPriority != existingContentPriority {
            return candidateContentPriority > existingContentPriority
        }

        if abs(candidate.score - existing.score) > 0.000_001 {
            return candidate.score > existing.score
        }

        // Equal evidence keeps the first ranked result. This makes row order
        // and representative selection deterministic without UUID sorting.
        return false
    }

    /// A compact, presentation-safe projection for reference cards and
    /// accessibility. Anchored citations and model operations always use the
    /// untouched `anchor.snippet` and `fullText` so freshness checks and
    /// grounding stay exact.
    static func displaySnippet(
        for source: AssistantSearchResult,
        maximumCharacters: Int = 300
    ) -> String {
        guard maximumCharacters > 0 else {
            return ""
        }
        let content = presentationContent(for: source)
        let preferredAnchor = source.anchor.kind == .imageContent
            ? AssistantSummaryTextCanonicalizer.imageSourceText(source)
            : source.anchor.snippet
        let collapsed = isGrounded(preferredAnchor, in: content)
            ? collapsingConsecutiveRepeatedPhrases(preferredAnchor)
            : usefulExcerpt(
                from: content,
                preferredAnchor: preferredAnchor,
                maximumCharacters: maximumCharacters)
        return collapsed
    }

    private static func preparedForPresentation(
        _ source: AssistantSearchResult,
        excludingAnswer: String? = nil
    ) -> AssistantSearchResult {
        let snippet = source.preparedDisplaySnippet ?? displaySnippet(for: source)
        var visibleSnippet = canonicalText(snippet) == canonicalText(source.fullText)
            ? ""
            : snippet

        if let answer = excludingAnswer {
            let answer = canonicalText(answer)
            // Published answers already crossed the canonical plain-text code,
            // boundary. Re-parsing them as Markdown can corrupt literal code,
            // Unicode bullets, and semantic numeric prefixes.
            if answer.count >= 24 && canonicalText(snippet).contains(answer) {
                visibleSnippet = ""
            }
        }

        return AssistantSearchResult(
            anchor: source.anchor,
            fullText: source.fullText,
            score: source.score,
            preparedDisplaySnippet: visibleSnippet.isEmpty ? nil : visibleSnippet)
    }

    private static func presentationContent(for source: AssistantSearchResult) -> String {
        let content = source.anchor.kind == .imageContent
            ? AssistantSummaryTextCanonicalizer.imageSourceText(source)
            : source.fullText
        return AssistantMarkdownProjection.plainText(from: content)
    }

    private static func contentPriority(_ source: AssistantSearchResult) -> Int {
        switch source.anchor.kind {
        case .paperKitText, .pdfText:
            return 5
        case .metadata:
            return 0
        case .imageContent:
            let normalized = compact(source.fullText).lowercased()
            if normalized.contains("image description:") ||
                normalized.contains("semantic description:") {
                return 4
            }
            if normalized.contains("text visible in image:") ||
                normalized.contains("recognized text:") ||
                normalized.contains("ocr:") {
                return 3
            }
            if normalized.contains("visual subjects:") ||
                normalized.contains("visual labels:") {
                return 2
            }
            return 1
        }
    }

    private static func informationScore(_ source: AssistantSearchResult) -> Int {
        let text = compact(presentationContent(for: source))
        let words = text.split(whereSeparator: \.isWhitespace)
            .map { $0.lowercased() }
            .filter { $0.count > 2 && genericWords.contains($0) == false }
        return min(text.count, 600) + Set(words).count * 12
    }

    private static func usefulExcerpt(
        from rawText: String,
        preferredAnchor: String,
        maximumCharacters: Int
    ) -> String {
        let text = compact(rawText)
        guard text.isEmpty == false, maximumCharacters > 0 else {
            return ""
        }
        guard text.count > maximumCharacters else {
            return text
        }

        let anchor = compact(preferredAnchor)
            .trimmingCharacters(
                in: CharacterSet.whitespacesAndNewlines
                    .union(CharacterSet(charactersIn: "…")))

        let anchoredRange = anchor.isEmpty
            ? nil
            : text.range(
                of: anchor,
                options: [.caseInsensitive, .diacriticInsensitive])
        let fallbackRange = anchoredRange ?? longestGroundedPhrase(
            from: anchor,
            in: text
        ).flatMap {
            text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive])
        }

        let center: Int
        if let fallbackRange {
            let lower = text.distance(from: text.startIndex, to: fallbackRange.lowerBound)
            let upper = text.distance(from: text.startIndex, to: fallbackRange.upperBound)
            center = (lower + upper) / 2
        } else {
            center = maximumCharacters / 2
        }

        let initialStart = min(
            max(center - maximumCharacters / 2, 0),
            max(text.count - maximumCharacters, 0))
        let initialEnd = min(initialStart + maximumCharacters, text.count)
        let startIndex = text.index(text.startIndex, offsetBy: initialStart)
        let endIndex = text.index(text.startIndex, offsetBy: initialEnd)
        var excerpt = String(text[startIndex ..< endIndex])

        // Avoid exposing chopped OCR words or partial prose at either edge.
        if initialStart > 0, let whitespace = excerpt.firstIndex(where: \.isWhitespace) {
            excerpt = String(excerpt[excerpt.index(after: whitespace)...])
        }
        if initialEnd < text.count, let whitespace = excerpt.lastIndex(where: \.isWhitespace) {
            excerpt = String(excerpt[text.startIndex ..< whitespace])
        }

        excerpt = excerpt.trimmingCharacters(in: .whitespacesAndNewlines)
        return excerpt.isEmpty
            ? ""
            : excerpt + (initialEnd == text.count ? "" : "…")
    }

    /// Compresses runs of whitespace so content-derived keys compare stably
    /// across OCR re-runs and presentation reflows.
    private static func compact(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func compact(_ excerpt: String, in text: String) -> String {
        let compressed = compact(excerpt)
        let compressedText = compact(text)
        guard compressed.contains(compressed) == false else {
            return compressed
        }
        if let grounded = longestGroundedPhrase(from: compressed, in: compressedText) {
            return grounded
        }
        return compressed
    }

    private static func longestGroundedPhrase(
        from anchor: String,
        in text: String
    ) -> String? {
        let candidates = anchor
            .split(omittingEmptySubsequences: true) { !$0.isLetter && !$0.isNumber }
            .map(String.init)
            .filter {
                $0.count >= 4 && genericWords.contains($0.lowercased()) == false
            }
            .sorted { $0.count != $1.count
                ? $0.count > $1.count
                : $0.localizedStandardCompare($1) == .orderedAscending }
        return candidates.first {
            text.range(
                of: $0,
                options: [.caseInsensitive, .diacriticInsensitive]) != nil
        }
    }

    private static func isGrounded(
        _ snippet: String,
        in fullText: String
    ) -> Bool {
        let needle = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard needle.isEmpty == false else {
            return false
        }
        return compact(fullText).range(
            of: needle,
            options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }

    private static func replacing(
        _ source: AssistantSearchResult,
        snippet: String,
        score: Double
    ) -> AssistantSearchResult {
        AssistantSearchResult(
            anchor: AssistantSourceAnchor(
                id: source.anchor.id,
                itemID: source.anchor.itemID,
                pageID: source.anchor.pageID,
                blockID: source.anchor.blockID,
                itemName: source.anchor.itemName,
                pageNumber: source.anchor.pageNumber,
                kind: source.anchor.kind,
                pageBounds: source.anchor.pageBounds,
                generation: source.anchor.generation,
                contentHash: source.anchor.contentHash,
                snippet: snippet),
            fullText: source.fullText,
            score: score)
    }

    private static func canonicalText(_ value: String) -> String {
        let folded = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX"))

        let semanticOperators: Set<Unicode.Scalar> = [
            "\u{2022}", "\u{203B}", "\u{203C}", "\u{2047}", "\u{2048}", "\u{2049}",
            "\u{00A7}", "\u{00B6}", "\u{2021}", "\u{2022}", "\u{25CF}",
            "\u{25A0}", "\u{25A1}", "\u{2713}", "\u{2714}", "\u{2022}"
        ]
        var tokens: [String] = []
        var word = ""

        func flushWord() {
            guard word.isEmpty == false else {
                return
            }
            tokens.append(word)
            word.removeAll(keepingCapacity: true)
        }

        for scalar in folded.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                word.unicodeScalars.append(scalar)
            } else if semanticOperators.contains(scalar) {
                flushWord()
                tokens.append(String(scalar))
            } else {
                flushWord()
            }
        }
        flushWord()

        return tokens.joined(separator: " ")
    }

    /// Handwriting/OCR aggregation can occasionally repeat the same short
    /// phrase several times inside one source. Collapse only consecutive exact
    /// word sequences and keep the authoritative indexed evidence untouched.
    private static func collapsingConsecutiveRepeatedPhrases(
        _ value: String
    ) -> String {
        let words = value.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 4 else {
            return value
        }

        var output: [String] = []
        var index = 0

        while index < words.count {
            var collapsed = false
            let maximumPhraseLength = min(words.count - index, 32 / 2)

            if maximumPhraseLength >= 2 {
                for phraseLength in stride(
                    from: maximumPhraseLength,
                    through: 2,
                    by: -1
                ) {
                    let phrase = words[index ..< (index + phraseLength)]
                    guard phrase.count <= words.count else {
                        continue
                    }

                    var repetitionCount = 1
                    var cursor = index + phraseLength

                    while cursor + phraseLength <= words.count,
                          words[cursor ..< (cursor + phraseLength)] == phrase {
                        repetitionCount += 1
                        cursor += phraseLength
                    }

                    guard repetitionCount > 1 else {
                        continue
                    }
                    output.append(contentsOf: phrase)
                    index = cursor
                    collapsed = true
                    break
                }
            }
            if collapsed == false {
                output.append(words[index])
                index += 1
            }
        }

        return output.joined(separator: " ")
    }

    private static let genericWords: Set<String> = [
        "image", "description", "text", "visual", "subject",
        "subjects", "recognized", "page", "source", "chunk", "block",
        "passage", "part", "the", "and", "with", "from", "this", "that"
    ]

    /// A deliberately small evidence bundle shared by Library Find, Answer, and
    /// Explain. Prompt size, source UI, and model work therefore do not grow with
    /// the number of notebooks in the library.
    struct AssistantLibraryEvidence: Equatable, Sendable {
        static let maximumPassageCount = 5
        static let maximumNotebookCount = 3
        static let maximumPassagesPerPage = 2

        let passages: [AssistantSearchResult]

        enum AssistantSourceResolution: Equatable, Sendable {
            case current(AssistantSearchResult)
            case stale(AssistantSourceAnchor)
        }
    }
}
