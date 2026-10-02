import CryptoKit
import Foundation
import NaturalLanguage

/// Small deterministic artifacts derived from a verified note snapshot. They
/// are orientation aids, never authoritative evidence: answer generation must
/// still receive current raw passages before making factual claims.
struct AssistantLocalArtifact: Equatable, Sendable {
    let kind: AssistantArtifactKind
    let markdown: String
    let sourceIDs: [String]
}

enum AssistantLocalIntelligenceBuilder {
    static let promptVersion = "local-intelligence-v1"
    static let schemaVersion = "1"

    private static let maximumAnalyzedCharacters = 64_000
    private static let maximumConcepts = 16
    private static let maximumEntities = 16
    private static let maximumQuestions = 10
    private static let maximumFollowUpSections = 6
    private static let maximumFollowUpChunksPerSection = 3
    private static let maximumFollowUpChunkCharacters = 320
    private static let maximumFollowUpTitleCharacters = 160
    private static let maximumFollowUpCueCharacters = 64

    static func artifacts(
        from snapshot: NoteContentSnapshot,
        localeIdentifier: String = Locale.current.identifier
    ) -> [AssistantLocalArtifact] {
        let boundedChunks = bounded(snapshot.sections.flatMap(\.chunks))
        let outline = outlineArtifact(snapshot: snapshot)
        let concepts = conceptArtifact(
            chunks: boundedChunks,
            localeIdentifier: localeIdentifier
        )
        let entities = entityArtifact(
            chunks: boundedChunks,
            localeIdentifier: localeIdentifier
        )
        let questions = questionArtifact(
            snapshot: snapshot,
            concepts: concepts?.markdown
        )
        return [outline, concepts, entities, questions].compactMap { $0 }
    }

    /// Builds only the small artifact needed to populate fresh-note follow-up
    /// suggestions. Unlike `artifacts(from:)`, this path never tokenizes or
    /// tags the complete note: it inspects a fixed number of leading sections
    /// and chunks and is therefore safe to run beside an interactive request.
    static func followUpArtifacts(
        from snapshot: NoteContentSnapshot
    ) -> [AssistantLocalArtifact] {
        [followUpQuestionArtifact(snapshot: snapshot)].compactMap { $0 }
    }

    static func requestFingerprint(_ request: String) -> String {
        let normalized = request
            .precomposedStringWithCanonicalMapping
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let digest = SHA256.hash(data: Data(normalized.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func outlineArtifact(
        snapshot: NoteContentSnapshot
    ) -> AssistantLocalArtifact? {
        var lines: [String] = []
        var sourceIDs: [String] = []
        for section in snapshot.sections {
            guard let first = section.chunks.first else { continue }
            let label = section.title?.trimmedNonempty ?? "Section \(section.ordinal + 1)"
            let excerpt = firstSentence(first.text, maximum: 180)
            guard !excerpt.isEmpty else { continue }
            lines.append("- **\(escaped(label))** — \(excerpt)")
            sourceIDs.append(first.sourceID)
        }
        guard !lines.isEmpty else { return nil }
        return AssistantLocalArtifact(
            kind: .outline,
            markdown: "## Outline\n\n" + lines.joined(separator: "\n"),
            sourceIDs: orderedUnique(sourceIDs)
        )
    }

    private static func conceptArtifact(
        chunks: [NoteSummaryChunk],
        localeIdentifier: String
    ) -> AssistantLocalArtifact? {
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        var sources: [String: [String]] = [:]
        let tokenizer = NLTokenizer(unit: .word)
        tokenizer.setLanguage(NLLanguage(rawValue: localeIdentifier))

        for chunk in chunks {
            tokenizer.string = chunk.text
            tokenizer.enumerateTokens(in: chunk.text.startIndex..<chunk.text.endIndex) { range, _ in
                let raw = String(chunk.text[range])
                let key = normalizedTerm(raw)
                guard isUsefulConcept(key) else { return true }
                counts[key, default: 0] += 1
                display[key] = display[key] ?? raw
                if sources[key]?.last != chunk.sourceID {
                    sources[key, default: []].append(chunk.sourceID)
                }
                return true
            }
        }

        let ranked = counts.keys.sorted {
            let left = counts[$0, default: 0]
            let right = counts[$1, default: 0]
            return left == right ? $0 < $1 : left > right
        }.prefix(maximumConcepts)
        guard !ranked.isEmpty else { return nil }
        let terms = ranked.map { display[$0] ?? $0 }
        return AssistantLocalArtifact(
            kind: .concepts,
            markdown: "## Concepts\n\n" + terms.map { "- \(escaped($0))" }.joined(separator: "\n"),
            sourceIDs: orderedUnique(ranked.flatMap { sources[$0] ?? [] })
        )
    }

    private static func entityArtifact(
        chunks: [NoteSummaryChunk],
        localeIdentifier: String
    ) -> AssistantLocalArtifact? {
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        var sources: [String: [String]] = [:]
        let tagger = NLTagger(tagSchemes: [.nameType])
        let language = NLLanguage(rawValue: localeIdentifier)

        for chunk in chunks {
            tagger.string = chunk.text
            tagger.setLanguage(language, range: chunk.text.startIndex..<chunk.text.endIndex)
            tagger.enumerateTags(
                in: chunk.text.startIndex..<chunk.text.endIndex,
                unit: .word,
                scheme: .nameType,
                options: [.joinNames, .omitWhitespace, .omitPunctuation]
            ) { tag, range in
                guard tag == .personalName || tag == .placeName || tag == .organizationName else {
                    return true
                }
                let raw = String(chunk.text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
                let key = normalizedTerm(raw)
                guard !key.isEmpty else { return true }
                counts[key, default: 0] += 1
                display[key] = display[key] ?? raw
                if sources[key]?.last != chunk.sourceID {
                    sources[key, default: []].append(chunk.sourceID)
                }
                return true
            }
        }

        let ranked = counts.keys.sorted {
            let left = counts[$0, default: 0]
            let right = counts[$1, default: 0]
            return left == right ? $0 < $1 : left > right
        }.prefix(maximumEntities)
        guard !ranked.isEmpty else { return nil }
        return AssistantLocalArtifact(
            kind: .entities,
            markdown: "## Entities\n\n" + ranked.map {
                "- \(escaped(display[$0] ?? $0))"
            }.joined(separator: "\n"),
            sourceIDs: orderedUnique(ranked.flatMap { sources[$0] ?? [] })
        )
    }

    private static func questionArtifact(
        snapshot: NoteContentSnapshot,
        concepts: String?
    ) -> AssistantLocalArtifact? {
        var questions: [String] = []
        var sourceIDs: [String] = []
        for section in snapshot.sections {
            guard let sourceID = section.chunks.first?.sourceID else { continue }
            if let title = section.title?.trimmedNonempty {
                questions.append("What are the most important ideas in \(title)?")
            } else if let text = section.chunks.first?.text {
                let subject = firstSentence(text, maximum: 80)
                if !subject.isEmpty {
                    questions.append("How would you explain this point: \(subject)?")
                }
            }
            sourceIDs.append(sourceID)
            if questions.count == maximumQuestions { break }
        }
        if questions.isEmpty, let concepts {
            let firstConcept = concepts.split(separator: "\n")
                .first(where: { $0.hasPrefix("- ") })?
                .dropFirst(2)
            if let firstConcept, !firstConcept.isEmpty {
                questions.append("How does \(firstConcept) connect to the rest of this note?")
                sourceIDs.append(contentsOf: snapshot.sourceIDs.prefix(1))
            }
        }
        guard !questions.isEmpty else { return nil }
        return AssistantLocalArtifact(
            kind: .questions,
            markdown: "## Review questions\n\n" + questions.enumerated().map {
                "\($0.offset + 1). \($0.element)"
            }.joined(separator: "\n"),
            sourceIDs: orderedUnique(sourceIDs)
        )
    }

    private static func followUpQuestionArtifact(
        snapshot: NoteContentSnapshot
    ) -> AssistantLocalArtifact? {
        var questions: [String] = []
        var sourceIDs: [String] = []
        var seen = Set<String>()

        func append(_ question: String, sourceID: String) {
            let normalized = normalizedFollowUpValue(question)
            guard normalized.isEmpty == false,
                seen.insert(normalized).inserted,
                questions.count < maximumQuestions else { return }
            questions.append(question)
            sourceIDs.append(sourceID)
        }

        for section in snapshot.sections.prefix(maximumFollowUpSections) {
            guard questions.count < maximumQuestions,
                let content = firstMeaningfulFollowUpContent(in: section) else { continue }

            if let title = usefulFollowUpTitle(section.title) {
                append("What are the key ideas in \(title)?", sourceID: content.sourceID)
                append("Explain this idea: \(content.cue)", sourceID: content.sourceID)
            } else {
                append("Explain this idea: \(content.cue)", sourceID: content.sourceID)
                append("Give me an example of this idea: \(content.cue)", sourceID: content.sourceID)
            }
        }

        guard questions.isEmpty == false else { return nil }
        return AssistantLocalArtifact(
            kind: .questions,
            markdown: "## Review questions\n\n" + questions.enumerated().map {
                "\($0.offset + 1). \($0.element)"
            }.joined(separator: "\n"),
            sourceIDs: orderedUnique(sourceIDs)
        )
    }

    private static func firstMeaningfulFollowUpContent(
        in section: NoteSummarySection
    ) -> (cue: String, sourceID: String)? {
        let titleFingerprint = usefulFollowUpTitle(section.title).map(normalizedFollowUpValue)
        for chunk in section.chunks.prefix(maximumFollowUpChunksPerSection) {
            let bounded = String(chunk.text.prefix(maximumFollowUpChunkCharacters))
            let cue = plainFollowUpCue(bounded)
            guard isMeaningfulFollowUpValue(cue),
                normalizedFollowUpValue(cue) != titleFingerprint else { continue }
            return (cue, chunk.sourceID)
        }
        return nil
    }

    private static func usefulFollowUpTitle(_ title: String?) -> String? {
        guard let title else { return nil }
        let cue = plainFollowUpCue(String(title.prefix(maximumFollowUpTitleCharacters)))
        guard isMeaningfulFollowUpValue(cue),
            isStructuralFollowUpLabel(cue) == false else { return nil }
        return cue
    }

    private static func plainFollowUpCue(_ value: String) -> String {
        let plainLines = value.split(whereSeparator: \Character.isNewline).compactMap { rawLine -> String? in
            var line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            while let first = line.first, "#*_`\\".contains(first) {
                line.removeFirst()
                line = line.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if line.hasPrefix("- ") || line.hasPrefix("+ ") || line.hasPrefix("• ") {
                line.removeFirst(2)
            }
            line = line
                .replacingOccurrences(of: "**", with: "")
                .replacingOccurrences(of: "__", with: "")
                .replacingOccurrences(of: "`", with: "")
                .replacingOccurrences(of: "\\", with: "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return line.isEmpty ? nil : line
        }
        let compact = plainLines.joined(separator: " ")
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
        guard compact.isEmpty == false else { return "" }
        let sentence = firstSentence(compact, maximum: maximumFollowUpCueCharacters)
        return sentence.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isMeaningfulFollowUpValue(_ value: String) -> Bool {
        value.unicodeScalars.lazy.filter(CharacterSet.letters.contains).prefix(3).count == 3
            && isStructuralFollowUpLabel(value) == false
    }

    private static func isStructuralFollowUpLabel(_ value: String) -> Bool {
        let normalized = value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .lowercased()
        .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
        let words = normalized.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard let first = words.first else { return true }
        if ["page", "section"].contains(first),
            words.dropFirst().allSatisfy({ $0.allSatisfy(\.isNumber) }) {
            return true
        }
        return [
            "recognized text",
            "transcription",
            "untitled",
            "visual subject",
        ].contains(normalized)
    }

    private static func normalizedFollowUpValue(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .lowercased()
        .filter { $0.isLetter || $0.isNumber }
    }

    private static func bounded(_ chunks: [NoteSummaryChunk]) -> [NoteSummaryChunk] {
        var remaining = maximumAnalyzedCharacters
        var result: [NoteSummaryChunk] = []
        for chunk in chunks where remaining > 0 {
            if chunk.text.count <= remaining {
                result.append(chunk)
                remaining -= chunk.text.count
            } else {
                let prefix = String(chunk.text.prefix(remaining))
                if let bounded = try? NoteSummaryChunk(
                    sourceID: chunk.sourceID,
                    ordinal: chunk.ordinal,
                    text: prefix
                ) {
                    result.append(bounded)
                }
                break
            }
        }
        return result
    }

    private static func normalizedTerm(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .lowercased()
        .trimmingCharacters(in: .punctuationCharacters.union(.whitespacesAndNewlines))
    }

    private static func isUsefulConcept(_ value: String) -> Bool {
        guard value.count >= 3,
            value.count <= 48,
            value.unicodeScalars.contains(where: CharacterSet.letters.contains) else {
            return false
        }
        return !stopWords.contains(value)
    }

    private static let stopWords: Set<String> = [
        "about", "after", "again", "also", "and", "are", "because", "been", "before",
        "being", "between", "both", "but", "can", "could", "did", "does", "each",
        "for", "from", "had", "has", "have", "into", "its", "more", "most", "not",
        "note", "notes", "only", "other", "our", "out", "over", "same", "should",
        "some", "such", "than", "that", "the", "their", "them", "then", "there",
        "these", "they", "this", "through", "under", "very", "was", "were", "what",
        "when", "where", "which", "while", "with", "would", "you", "your",
    ]

    private static func firstSentence(_ value: String, maximum: Int) -> String {
        let compact = value.split(whereSeparator: \Character.isWhitespace).joined(separator: " ")
        guard !compact.isEmpty else { return "" }
        var end = compact.endIndex
        for index in compact.indices where ".!?".contains(compact[index]) {
            end = compact.index(after: index)
            break
        }
        let sentence = String(compact[..<end])
        guard sentence.count > maximum else { return sentence }
        return String(sentence.prefix(maximum - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    private static func escaped(_ value: String) -> String {
        value.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "*", with: "\\*")
    }

    private static func orderedUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }
}

enum AssistantFollowUpSuggestionBuilder {
    private static let maximumSuggestions = 6

    static func suggestions(
        from artifacts: [AssistantLocalArtifact],
        excluding prompt: String
    ) -> [String] {
        let excluded = normalized(prompt)
        var seen = Set<String>()
        var results: [String] = []
        for artifact in artifacts {
            for rawLine in artifact.markdown.split(whereSeparator: \.isNewline) {
                guard let suggestion = suggestion(from: String(rawLine)) else { continue }
                let key = normalized(suggestion)
                guard key.isEmpty == false,
                    key != excluded,
                    seen.insert(key).inserted else { continue }
                results.append(suggestion)
                if results.count == maximumSuggestions { return results }
            }
        }
        return results
    }

    private static func suggestion(from line: String) -> String? {
        var text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("- ") {
            text.removeFirst(2)
        }
        if let dot = text.firstIndex(of: "."),
            text[..<dot].allSatisfy({ $0.isNumber || $0.isWhitespace }) {
            text = String(text[text.index(after: dot)...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return text.isEmpty ? nil : text
    }

    private static func normalized(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        .lowercased()
        .filter { $0.isLetter || $0.isNumber }
    }
}

private extension String {
    var trimmedNonempty: String? {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }
}
