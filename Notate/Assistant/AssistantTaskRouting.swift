import Foundation

/// The bounded jobs supported by Notate's on-device assistant pipeline.
///
/// The task deliberately does not carry summary length or presentation style.
/// The current assistant UI does not expose either setting, and an explicitly
/// requested modifier such as "brief" remains available in the original prompt.
public enum AssistantTask: String, CaseIterable, Equatable, Sendable {
    case summarize
    case answer
    case explain
    case study
    case find
}

/// Deterministically separates assistant work before retrieval or generation.
///
/// Routing is intentionally lexical and entirely local. It never sends a prompt
/// to a model merely to decide which pipeline is allowed to read the prompt.
enum AssistantTaskRouter {
    static func task(for prompt: String) -> AssistantTask {
        let command = normalizedCommand(prompt)
        guard command.isEmpty == false else { return .answer }

        if isSummaryRequest(command) {
            return .summarize
        }
        if isExplanationRequest(command) {
            return .explain
        }
        if isStudyRequest(command) {
            return .study
        }
        if isFindRequest(command) {
            return .find
        }
        return .answer
    }

    private static let conversationalPrefixes = [
        "i would like you to",
        "i d like you to",
        "i want you to",
        "could you please",
        "would you please",
        "will you please",
        "can you please",
        "would you mind",
        "do you mind",
        "hey there notate",
        "hello notate",
        "hey notate",
        "hi notate",
        "could you",
        "would you",
        "will you",
        "can you",
        "notate",
        "briefly",
        "quickly",
        "kindly",
        "please",
        "hello",
        "okay",
        "hey",
        "just",
        "hi",
        "ok",
    ]

    private static let directSummaryPrefixes = [
        "summarize",
        "summarise",
        "distill",
        "condense",
        "digest",
        "sum up",
        "recap",
        "tldr",
        "tl dr",
        "overview of",
        "synopsis of",
        "summary of",
        "summary for",
        "summary please",
        "outline the note",
        "outline this note",
        "outline my note",
        "outline these notes",
        "outline the notes",
        "outline this notebook",
        "outline the notebook",
        "review my note",
        "review my notes",
        "review the note",
        "review the notes",
        "review these notes",
        "review this note",
        // Deterministic multilingual coverage keeps Library summary requests
        // inside the product scope gate instead of misclassifying them as a
        // bounded cross-note answer.
        "resume esta nota",
        "resume estas notas",
        "resumen de esta nota",
        "resume cette note",
        "resume ces notes",
        "resumer cette note",
        "fasse diese notiz zusammen",
        "fass diese notiz zusammen",
        "zusammenfassung dieser notiz",
        "このノートを要約",
        "ノートを要約",
        "要約して",
        "इस नोट का सारांश",
        "इन नोट्स का सारांश",
    ]

    private static let scopedDescriptionPrefixes = [
        "describe a note",
        "describe my note",
        "describe my notes",
        "describe our note",
        "describe our notes",
        "describe the current note",
        "describe the note",
        "describe the notes",
        "describe these notes",
        "describe this note",
        "describe this notebook",
        "describe the notebook",
        "describe the current page",
        "describe the page",
        "describe this page",
    ]

    private static let scopedSummaryQuestionPrefixes = [
        "what is in this note",
        "what is in the note",
        "what s in this note",
        "what s in the note",
        "what is this note about",
        "what s this note about",
        "what are these notes about",
        "what are the notes about",
        "what does this note say",
        "what do these notes say",
        "what is this notebook about",
        "what s this notebook about",
        "what are the key points",
        "what are the main points",
        "what are the key ideas",
        "what are the main ideas",
        "what are the highlights",
        "tell me what this note is about",
        "tell me what these notes are about",
        "tell me about this note",
        "tell me about these notes",
        "tell me about this notebook",
        "give me the key points",
        "give me the main points",
        "list the key points",
        "list the main points",
        "list the highlights",
    ]

    private static let explanationPrefixes = [
        "help me understand",
        "help me learn",
        "walk me through",
        "break this down",
        "break down",
        "teach me",
        "explain",
        "explaining",
        "clarify",
        "elaborate",
        "analyze",
        "analyse",
        "compare",
        "contrast",
        "describe",
        "why",
        "how does",
        "how do",
        "how did",
        "how is",
        "how are",
        "how can",
        "how could",
        "how would",
        "how should",
        "explica esta nota",
        "explica estas notas",
        "explique cette note",
        "explique ces notes",
        "erklare diese notiz",
        "erklare diese notizen",
        "このノートを説明",
        "説明して",
        "इस नोट को समझाओ",
    ]

    private static let directStudyPrefixes = [
        "help me study",
        "help me revise",
        "help me review",
        "quiz me",
        "test me",
        "study guide",
        "study plan",
        "flashcards",
        "flash cards",
        "practice questions",
        "revision questions",
        "review questions",
        "ayudame a estudiar",
        "hazme un cuestionario",
        "crea tarjetas didacticas",
        "aide moi a etudier",
        "interroge moi",
        "cree des fiches de revision",
        "hilf mir lernen",
        "teste mich",
        "erstelle lernkarten",
        "クイズを作って",
        "フラッシュカードを作って",
        "勉強を手伝って",
        "मुझे पढ़ने में मदद करो",
        "प्रश्नोत्तरी बनाओ",
        "फ्लैशकार्ड बनाओ",
    ]

    private static let findPrefixes = [
        "find",
        "finding",
        "search",
        "searching",
        "locate",
        "locating",
        "look for",
        "look through my notes for",
        "look through the notes for",
        "take me to",
        "navigate to",
        "point me to",
        "bring up the note",
        "bring up my note",
        "go to the note",
        "go to the page",
        "open the note where",
        "open the page where",
        "show me where",
        "show me the note where",
        "show me the page where",
        "tell me where",
        "show me notes about",
        "show me my notes about",
        "show notes about",
        "which page",
        "which section",
        "which part",
        "which note",
        "which notes",
        "which notebook",
        "what page",
        "what note contains",
        "what note mentions",
        "where did i",
        "where have i",
        "where do my notes",
        "where do these notes",
        "where does this note",
        "where in my notes",
        "where in the notes",
        "where is my note",
        "where is the note",
        "where are my notes",
        "where are the notes",
        "where was this mentioned",
        "where were these mentioned",
    ]

    private static let artifactProducerWords: Set<Substring> = [
        "create", "draft", "generate", "give", "make", "prepare", "provide", "write",
    ]

    private static let summaryArtifactWords: Set<Substring> = [
        "digest", "outline", "overview", "recap", "summary", "synopsis",
    ]

    private static let studyArtifactWords: Set<Substring> = [
        "flashcard", "flashcards", "quiz", "questions",
    ]

    private static func isSummaryRequest(_ command: String) -> Bool {
        if command.hasAnyPhrasePrefix(directSummaryPrefixes)
            || command.hasAnyPhrasePrefix(scopedDescriptionPrefixes)
            || command.hasAnyPhrasePrefix(scopedSummaryQuestionPrefixes) {
            return true
        }

        if command.hasPhrasePrefix("summarizing")
            || command.hasPhrasePrefix("summarising")
            || command.hasPhrasePrefix("distilling")
            || command.hasPhrasePrefix("condensing")
            || command.containsPhrase("into a summary")
            || command.containsPhrase("into an overview")
            || command.containsPhrase("into a synopsis") {
            return true
        }

        let words = command.split(separator: " ")
        guard let first = words.first else { return false }

        if ["brief", "concise", "detailed", "short"].contains(first),
            words.prefix(5).contains(where: summaryArtifactWords.contains) {
            return true
        }

        return artifactProducerWords.contains(first)
            && words.prefix(8).contains(where: summaryArtifactWords.contains)
    }

    private static func isExplanationRequest(_ command: String) -> Bool {
        if command.hasPhrasePrefix("find out why")
            || command.hasPhrasePrefix("find out how") {
            return true
        }

        if command.hasAnyPhrasePrefix(explanationPrefixes) {
            return true
        }

        let words = command.split(separator: " ")
        guard let first = words.first else { return false }
        return artifactProducerWords.contains(first)
            && words.prefix(8).contains("explanation")
    }

    private static func isStudyRequest(_ command: String) -> Bool {
        if command.hasAnyPhrasePrefix(directStudyPrefixes)
            || command.containsPhrase("into flashcards")
            || command.containsPhrase("into flash cards")
            || command.containsPhrase("into a quiz")
            || command.containsPhrase("into practice questions")
            || command.containsPhrase("into review questions")
            || command.containsPhrase("into a study guide")
            || command.containsPhrase("into a study plan") {
            return true
        }

        let words = command.split(separator: " ")
        guard let first = words.first,
            artifactProducerWords.contains(first) else {
            return false
        }

        if words.prefix(8).contains(where: studyArtifactWords.contains) {
            return true
        }
        return command.containsPhrase("study guide")
            || command.containsPhrase("study plan")
            || command.containsPhrase("practice questions")
            || command.containsPhrase("revision questions")
            || command.containsPhrase("review questions")
    }

    private static func isFindRequest(_ command: String) -> Bool {
        // "Find out" asks for an answer or explanation rather than navigation.
        guard command.hasPhrasePrefix("find out") == false else { return false }
        return command.hasAnyPhrasePrefix(findPrefixes)
    }

    private static func normalizedCommand(_ prompt: String) -> String {
        var result = prompt
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
            .lowercased()
            .split(whereSeparator: { character in
                character.isLetter == false && character.isNumber == false
            })
            .joined(separator: " ")

        var removedPrefix = true
        while removedPrefix, result.isEmpty == false {
            removedPrefix = false
            for prefix in conversationalPrefixes where result.hasPhrasePrefix(prefix) {
                result.removeFirst(prefix.count)
                result = result.trimmingCharacters(in: .whitespaces)
                removedPrefix = true
                break
            }
        }
        return result
    }
}

private extension String {
    func hasPhrasePrefix(_ phrase: String) -> Bool {
        self == phrase || hasPrefix("\(phrase) ")
    }

    func hasAnyPhrasePrefix(_ phrases: [String]) -> Bool {
        phrases.contains(where: hasPhrasePrefix)
    }

    func containsPhrase(_ phrase: String) -> Bool {
        self == phrase
            || hasPrefix("\(phrase) ")
            || hasSuffix(" \(phrase)")
            || contains(" \(phrase) ")
    }
}
