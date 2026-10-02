import Foundation
import SwiftUI

enum AssistantMarkdownInlineStyle: Hashable {
    case bold
    case italic
    case underline
    case strikethrough
    case code
}

struct AssistantMarkdownTextRun {
    var text: String
    var styles: Set<AssistantMarkdownInlineStyle>
    var link: URL?
    init(
        text: String,
        styles: Set<AssistantMarkdownInlineStyle> = [],
        link: URL? = nil
        ) {
        self.text = text
        self.styles = styles
        self.link = link
    }
}

struct AssistantMarkdownRichText {
    var runs: [AssistantMarkdownTextRun]
    init(runs: [AssistantMarkdownTextRun] = []) {
        self.runs = runs
    }
    init(_ plainText: String) {
        runs = plainText.isEmpty ? [] : [AssistantMarkdownTextRun(text: plainText)]
    }
    var semanticPlainText: String {
        // `richText(from:)` has already converted Markdown to semantic runs.
        // Projecting those characters a second time corrupts escaped literals
        // such as `\*ptr` and inline-code content such as `__init__`.
        runs.map(\.text).joined()
    }
    var displayAttributedString: AttributedString {
        runs.reduce(into: AttributedString()) { result, run in
            var segment = AttributedString(run.text)
            segment.link = run.link
            var intent: InlinePresentationIntent = []
            if run.styles.contains(.bold) { intent.insert(.stronglyEmphasized) }
            if run.styles.contains(.italic) { intent.insert(.emphasized) }
            if run.styles.contains(.code) { intent.insert(.code) }
            if intent.isEmpty == false { segment.inlinePresentationIntent = intent }
            if run.styles.contains(.underline) { segment.underlineStyle = .single }
            if run.styles.contains(.strikethrough) { segment.strikethroughStyle = .single }
            result.append(segment)
        }
    }
}

/// Compatibility projections for assistant text.
///
/// New model output is normalized to semantic plain text before publication.
/// These helpers also safely project legacy cached Markdown, deterministic
/// authored formatting, and incomplete provider snapshots without exposing
/// presentation punctuation to the transcript, VoiceOver, or insertion.
enum AssistantMarkdownProjection {
    /// Generated or imported Markdown is untrusted. A maliciously deep chain
    /// of nested link labels must not turn semantic projection into equivalent
    /// call-stack depth. Ordinary Markdown rarely nests more than a couple of
    /// labels; beyond this ceiling we preserve the remaining literal label so
    /// presentation can degrade safely instead of exhausting the process stack.
    private static let maximumInlineLinkNestingDepth = 16

    /// Produces semantic plain text while preserving paragraph, list-item, and
    /// code boundaries. Markdown headings, list markers, links, and inline
    /// emphasis are projected to their visible content.
    static func plainText(from markdown: String) -> String {
        projectedText(from: markdown, accessibility: false)
    }

    /// Produces a VoiceOver-friendly variant that verbalizes checklist state.
    static func accessibilityText(from markdown: String) -> String {
        projectedText(from: markdown, accessibility: true)
    }

    /// The insertion boundary intentionally aliases the semantic projection so
    /// Markdown syntax cannot be reinserted and subsequently indexed as note
    /// content.
    static func plainInsertionText(from markdown: String) -> String {
        plainText(from: markdown)
    }

    /// A lightweight projection for cumulative model snapshots. It avoids an
    /// attributed-Markdown parse on every stream update, hides incomplete
    /// presentation delimiters, and keeps code/path/regular-expression text
    /// literal.
    static func streamingText(
        from markdown: String,
        isFinal: Bool = true,
        preservesUnmatchedOperators: Bool = false
        ) -> String {
        let normalized = normalizeLineEndings(markdown)
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let trailingLineIndex = lines.indices.last
        var plainCodeLines = plainCodeLineFlags(for: lines)
        if isFinal == false {
            // A hash-prefixed line cannot be classified as a heading or a code
            // comment from a later cumulative snapshot without changing text
            // that may already be visible. Keep its streaming interpretation
            // stable; the terminal crossfade can restore a comment marker once
            // adjacent code establishes provenance.
            for index in lines.indices
            where lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("# ")
            && isStrongPlainCodeLine(lines[index]) == false {
                plainCodeLines[index] = false
            }
        }
        let referenceLinkLabels = streamingReferenceLinkLabels(
            in: lines,
            plainCodeLines: plainCodeLines
            )
        var projectedLines: [StreamingProjectionLine] = []
        var openFence: (marker: Character, length: Int)?
        var htmlCommentState: StreamingHTMLCommentState?
        var cdataState: StreamingCDATAState?
        var openMultilineHTMLTag: StreamingHTMLTagState?
        for (lineIndex, unbufferedLine) in lines.enumerated() {
            var effectiveLine = unbufferedLine
            let unbufferedTrimmed = effectiveLine.trimmingCharacters(in: .whitespaces)
            if let fence = openFence {
                if AssistantMarkdownParser.isFenceClosing(
                    unbufferedTrimmed,
                    marker: fence.marker,
                    minimumLength: fence.length
                    ) {
                    openFence = nil
                } else if isFinal == false,
                    lineIndex == trailingLineIndex,
                    isPartialFenceClosing(
                        unbufferedTrimmed,
                        marker: fence.marker,
                        minimumLength: fence.length
                    ) {
                    // A closing fence arrives one marker at a time. Holding a
                    // shorter trailing run prevents literal backticks/tildes
                    // from flashing and then retracting when the run closes.
                } else {
                    projectedLines.append(
                        StreamingProjectionLine(text: unbufferedLine, isVerbatim: true)
                        )
                }
                continue
            }
            var resumedAfterHTMLComment = false
            if htmlCommentState != nil {
                let enteredInsideHTMLComment = true
                let hadLineContent = effectiveLine.isEmpty == false
                effectiveLine = removingStreamingHTMLComments(
                    from: effectiveLine,
                    state: &htmlCommentState,
                    releasesMalformedTail: isFinal
                    && lineIndex == trailingLineIndex
                    )
                resumedAfterHTMLComment = true
                if effectiveLine.isEmpty,
                    enteredInsideHTMLComment || hadLineContent {
                    continue
                }
            }
            if cdataState != nil || plainCodeLines[lineIndex] == false {
                let enteredInsideCDATA = cdataState != nil
                let containedCDATAOpening = effectiveLine.range(
                    of: "<![CDATA[",
                    options: .caseInsensitive
                    ) != nil
                effectiveLine = removingStreamingCDATASections(
                    from: effectiveLine,
                    state: &cdataState,
                    buffersTrailingTerminator: isFinal == false
                    && lineIndex == trailingLineIndex
                    )
                if effectiveLine.isEmpty,
                    enteredInsideCDATA || containedCDATAOpening {
                    continue
                }
            }
            if openMultilineHTMLTag != nil || plainCodeLines[lineIndex] == false {
                let enteredInsideHTMLTag = openMultilineHTMLTag != nil
                let hadLineContent = effectiveLine.isEmpty == false
                effectiveLine = removingStreamingMultilineHTMLTag(
                    from: effectiveLine,
                    state: &openMultilineHTMLTag,
                    releasesMalformedTail: isFinal
                    && lineIndex == trailingLineIndex
                    )
                if effectiveLine.isEmpty,
                    enteredInsideHTMLTag || hadLineContent {
                    continue
                }
            }
            let effectiveTrimmed = effectiveLine.trimmingCharacters(in: .whitespaces)
            if let fence = AssistantMarkdownParser.fenceOpening(in: effectiveTrimmed) {
                openFence = (fence.marker, fence.length)
                continue
            }
            if plainCodeLines[lineIndex], resumedAfterHTMLComment == false {
                projectedLines.append(
                    StreamingProjectionLine(text: effectiveLine, isVerbatim: true)
                    )
                continue
            }
            var rawLine = effectiveLine
            if isFinal == false, lineIndex == trailingLineIndex {
                rawLine = bufferingIncompleteTrailingAngleConstruct(in: rawLine)
                rawLine = bufferingIncompleteTrailingEscape(in: rawLine)
                rawLine = bufferingIncompleteTrailingImageOpening(in: rawLine)
                rawLine = bufferingIncompleteTrailingLinkOpening(in: rawLine)
                rawLine = bufferingIncompleteTrailingChecklist(in: rawLine)
                rawLine = bufferingIncompleteReferenceDefinition(in: rawLine)
                rawLine = bufferingIncompleteOuterRailedTableRow(in: rawLine)
                rawLine = bufferingIncompleteTrailingEntity(in: rawLine)
                rawLine = bufferingIncompleteTrailingInlineDelimiter(in: rawLine)
            }
            let proseLine = removingStreamingHTMLComments(
                from: rawLine,
                state: &htmlCommentState,
                releasesMalformedTail: isFinal
                && lineIndex == trailingLineIndex
                )
            let proseTrimmed = proseLine.trimmingCharacters(in: .whitespaces)
            if isFinal == false,
                lineIndex == trailingLineIndex,
                (isAmbiguousTrailingBlockMarker(proseTrimmed)
                || proseTrimmed.hasPrefix("# ")) {
                continue
            }
            // Reference-link definitions are presentation metadata, not
            // visible answer content. Keep four-space-indented definitions
            // verbatim via the code path above, matching CommonMark's rule
            // that definitions may be indented by at most three spaces.
            if isReferenceLinkDefinition(proseTrimmed) {
                continue
            }
            if isSetextUnderline(proseTrimmed) || isTableSeparator(proseTrimmed) {
                continue
            }
            guard let body = streamingBlockBody(from: proseLine) else {
                continue
            }
            let inline = projectInlinePresentation(
                body,
                hidesOpenDelimiter: isFinal == false,
                referenceLinkLabels: referenceLinkLabels,
                buffersAmbiguousTrailingLink: isFinal == false
                && lineIndex == trailingLineIndex,
                preservesLiteralOperators: preservesUnmatchedOperators
                )
            let visibleInline = body.hasPrefix("* ")
            && inline.trimmingCharacters(in: .whitespaces) == "*"
            ? ""
            : inline
            projectedLines.append(
                StreamingProjectionLine(
                    text: removingAutolinkDelimiters(in: visibleInline),
                    isVerbatim: false
                    )
                )
        }
        return normalizedWhitespaceLines(projectedLines)
    }

    /// Applies prose-only cleanup while retaining fenced code byte-for-byte.
    /// Fence markers remain so the semantic projection can remove them after
    /// prose transforms have completed.
    static func transformingProseOutsideFences(
        in value: String,
        _ transform: (String) -> String
        ) -> String {
        let normalized = normalizeLineEndings(value)
        let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        let plainCodeLines = plainCodeLineFlags(for: lines)
        var result: [String] = []
        var openFence: (marker: Character, length: Int)?
        for (lineIndex, rawLine) in lines.enumerated() {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
            if let fence = openFence {
                result.append(rawLine)
                if AssistantMarkdownParser.isFenceClosing(
                    trimmed,
                    marker: fence.marker,
                    minimumLength: fence.length
                    ) {
                    openFence = nil
                }
                continue
            }
            if let fence = AssistantMarkdownParser.fenceOpening(in: trimmed) {
                openFence = (fence.marker, fence.length)
                result.append(rawLine)
                continue
            }
            result.append(
                plainCodeLines[lineIndex] ? rawLine : transform(rawLine)
                )
        }
        return result.joined(separator: "\n")
    }

    /// Applies cleanup only to prose outside inline-code spans while retaining
    /// both code bytes and their delimiters for the later semantic projection.
    static func transformingProseOutsideInlineCode(
        in line: String,
        _ transform: (String) -> String
        ) -> String {
        var result = ""
        var cursor = line.startIndex
        var proseStart = cursor
        while cursor < line.endIndex {
            guard line[cursor] == "`",
                isEscaped(at: cursor, in: line) == false else {
                cursor = line.index(after: cursor)
                continue
            }
            let markerEnd = endOfRun(of: "`", from: cursor, in: line)
            let marker = String(line[cursor..<markerEnd])
            result += transform(String(line[proseStart..<cursor]))
            guard let closing = line.range(
                of: marker,
                range: markerEnd..<line.endIndex
                ) else {
                // An unmatched backtick is ordinary prose under CommonMark.
                // Keep its marker for the semantic projector while applying
                // safety cleanup to the remainder.
                result += transform(String(line[cursor...]))
                return result
            }
            result += String(line[cursor..<closing.upperBound])
            cursor = closing.upperBound
            proseStart = cursor
        }
        result += transform(String(line[proseStart...]))
        return result
    }

    /// Identifies strong, line-oriented code signals without treating ordinary
    /// punctuation or prose as code. Comment-only lines inherit code context
    /// from an adjacent strong line, preserving Python comments while still
    /// allowing a standalone Markdown heading to be projected.
    static func plainCodeLineFlags(for lines: [String]) -> [Bool] {
        var flags = lines.map(isStrongPlainCodeLine)

        func isHashComment(_ index: Int) -> Bool {
            lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("# ")
        }
        // Flood code provenance through a contiguous comment run. Checking
        // only an immediately strong neighbor corrupts the first line of
        // `# first\n# second\nlet x = 1` as a Markdown heading.
        for index in lines.indices where flags[index] == false && isHashComment(index) {
            if index > lines.startIndex, flags[index - 1] {
                flags[index] = true
            }
        }
        for index in lines.indices.reversed()
        where flags[index] == false && isHashComment(index) {
            if index + 1 < lines.endIndex, flags[index + 1] {
                flags[index] = true
            }
        }
        return flags
    }

    private static func isStrongPlainCodeLine(_ rawLine: String) -> Bool {
        let trimmed = rawLine.trimmingCharacters(in: .whitespaces)
        guard trimmed.isEmpty == false,
            AssistantMarkdownParser.fenceOpening(in: trimmed) == nil else {
            return false
        }
        let leadingWhitespace = rawLine.prefix(while: { $0 == " " || $0 == "\t" })
        if leadingWhitespace.contains("\t") || leadingWhitespace.count >= 4 {
            // Nested Markdown lists are commonly indented by four spaces.
            // They still need semantic projection; only genuinely indented
            // code should bypass it.
            if AssistantMarkdownParser.checklist(in: trimmed) != nil
                || AssistantMarkdownParser.bulletBody(in: trimmed) != nil
                || AssistantMarkdownParser.numberedBody(in: trimmed) != nil
                || isPotentialIndentedListPrefix(trimmed) {
                return false
            }
            return true
        }
        if trimmed.hasPrefix("//") || trimmed.hasPrefix("/*")
            || trimmed.hasPrefix("*/") || trimmed.hasPrefix("#!") {
            return true
        }
        let hasBalancedLeadingEmphasis = (trimmed.hasPrefix("**")
            && trimmed.hasSuffix("**") && trimmed.count > 4)
            || (trimmed.hasPrefix("__")
            && trimmed.hasSuffix("__") && trimmed.count > 4)
        if hasBalancedLeadingEmphasis { return false }
        if trimmed.range(
            of: #"&(?:#[0-9]+|#[xX][0-9A-Fa-f]+|[A-Za-z][A-Za-z0-9]+);"#,
            options: .regularExpression
            ) != nil {
            return false
        }
        let patterns = [
            #"^(?:\*|&&|&)[A-Za-z_][A-Za-z0-9_.\[\]]*\s*(?:=|:=|\+=|-=|\*=|/=|=>)\s*\S+"#,
            #"^(?:let|var|const)\s+[A-Za-z_][A-Za-z0-9_]*\s*(?::[^=]+)?="#,
            #"^(?:func|function|def|class|struct|enum|protocol|extension)\s+[A-Za-z_][A-Za-z0-9_]*\b.*(?:[:;{]|\([^\n]*\))\s*$"#,
            #"^(?:if|guard|while|for|switch|case|catch)\b.*(?:[:;{])\s*$"#,
            #"^(?:else|do)\s*(?:[:;{}])\s*$"#,
            #"^from\s+\S+\s+import\s+\S+\s*$"#,
            #"^import\s+[A-Za-z_][A-Za-z0-9_.]*(?:\s*;)?\s*$"#,
            #"^(?:return|throw|await|try)\s+.*(?:\([^\n]*\)|[;{}])\s*$"#,
            #"^(?:return|throw|await|try)\s+[A-Za-z_][A-Za-z0-9_.\[\]]*\s*$"#,
            #"^select\s+(?:\*|[A-Za-z_][A-Za-z0-9_.]*(?:\s*,\s*[A-Za-z_][A-Za-z0-9_.]*)*)\s+from\s+[A-Za-z_][A-Za-z0-9_.]*(?:\s+(?:where|join|left|right|inner|outer|group|order|limit)\b.*)?\s*;?\s*$"#,
            #"^insert\s+into\s+[A-Za-z_][A-Za-z0-9_.]*\s*(?:\([^\n]+\)\s*)?values\s*\([^\n]+\)\s*;?\s*$"#,
            #"^update\s+[A-Za-z_][A-Za-z0-9_.]*\s+set\s+[A-Za-z_][A-Za-z0-9_.]*\s*=.+\s*;?\s*$"#,
            #"^delete\s+from\s+[A-Za-z_][A-Za-z0-9_.]*(?:\s+where\b.*)?\s*;?\s*$"#,
            #"^create\s+(?:table|index|view)\s+[A-Za-z_][A-Za-z0-9_.]*\b.*(?:[;)])\s*$"#,
            #"^(?:(?:const|static|volatile|unsigned|signed|long|short)\s+)*(?:void|char|int|float|double|bool|size_t|[A-Z][A-Za-z0-9_:<>]*)\s+[*&]+\s*[A-Za-z_][A-Za-z0-9_]*\s*(?:=|;|\[\])"#,
            #"^\^(?=.*(?:\\[dDsSwWbB]|[.+?()\[\]{}|])).*\$$"#,
            #"^/\^(?=.*(?:\\[dDsSwWbB]|[.+?()\[\]{}|])).*\$\/[A-Za-z]*$"#,
            #"^"[^"]+"\s*:\s*.+[,]?$"#,
            ]
        return patterns.contains { pattern in
            trimmed.range(
                of: pattern,
                options: [.regularExpression, .caseInsensitive]
                ) != nil
        }
    }

    private static func isPotentialIndentedListPrefix(_ text: String) -> Bool {
        if ["-", "*", "+", "•", "–", "* ", "+ ", "• "]
            .contains(text) {
            return true
        }
        return text.range(
            of: #"^(?:[:-*+•]\s+\[[ xX]?|\d{1,3}(?:[.\)]\s*)?)$"#,
            options: .regularExpression
            ) != nil
    }

    fileprivate static func protectVerbatimBackslashes(in markdown: String) -> String {
        var result = ""
        var token = ""

        func flushToken() {
            guard token.isEmpty == false else { return }
            if shouldProtectBackslashes(in: token) {
                result += token.replacingOccurrences(
                    of: "\\",
                    with: String(verbatimBackslashSentinel)
                    )
            } else {
                result += token
            }
            token.removeAll(keepingCapacity: true)
        }
        for character in markdown {
            if character.isWhitespace {
                flushToken()
                result.append(character)
            } else {
                token.append(character)
            }
        }
        flushToken()
        return result
    }

    fileprivate static func restoreVerbatimBackslashes(in text: String) -> String {
        text.replacingOccurrences(of: String(verbatimBackslashSentinel), with: "\\")
    }

    static func projectInlinePresentation(
        _ text: String,
        hidesOpenDelimiter: Bool = false,
        referenceLinkLabels: Set<String> = [],
        buffersAmbiguousTrailingLink: Bool = false,
        preservesLiteralOperators: Bool = false,
        remainingLinkNestingDepth: Int = maximumInlineLinkNestingDepth
        ) -> String {
        let protected = projectingCDATASections(
            in: protectVerbatimBackslashes(in: text)
            )
        let codeProjected = projectingInlineCode(
            in: protected,
            hidesIncompleteClosingRuns: hidesOpenDelimiter
            ) { segment in
            projectingQuotedLiterals(in: segment) { prose in
                // XML processing instructions and CDATA wrappers must be
                // projected before Markdown links. Otherwise `![CDATA[` is
                // misclassified as an image opener and the wrapper is damaged
                // before the HTML/XML projector can recognize it.
                let xmlProjected = projectingXMLPresentation(in: prose)
                var value = removingLinkDestinations(
                    in: xmlProjected,
                    referenceLinkLabels: referenceLinkLabels,
                    buffersAmbiguousTrailingLink: buffersAmbiguousTrailingLink,
                    preservesReferenceLinks: hidesOpenDelimiter,
                    remainingLinkNestingDepth: max(remainingLinkNestingDepth, 0)
                    )
                value = removingHTMLPresentation(
                    in: value,
                    buffersAmbiguousAdjacentTags: hidesOpenDelimiter
                    )
                value = decodingHTMLCharacterReferences(in: value)
                value = deescapingPresentationPunctuation(in: value)
                for delimiter in ["**", "__", "~~", "*", "_"] {
                    value = removingPresentationDelimiter(
                        delimiter,
                        from: value,
                        hidesOpenDelimiter: hidesOpenDelimiter,
                        preservesLiteralOperators: preservesLiteralOperators
                        )
                }
                return value
            }
        }
        return restoreEscapedPresentationPunctuation(
            in: restoreVerbatimBackslashes(in: codeProjected)
            )
    }

    private static let verbatimBackslashSentinel: Character = "\u{E000}"

    private static let escapedPresentationSentinels: [Character: Character] = [
        "*": "\u{E001}", "_": "\u{E002}", "~": "\u{E003}",
        "#": "\u{E004}", ">": "\u{E005}", "-": "\u{E006}",
        "+": "\u{E007}", "!": "\u{E008}", "=": "\u{E009}",
        "[": "\u{E00A}", "]": "\u{E00B}",
        "(": "\u{E00C}", ")": "\u{E00D}",
        "<": "\u{E00E}", "|": "\u{E00F}",
        "{": "\u{E010}", "}": "\u{E011}",
        ":": "\u{E012}", ".": "\u{E013}",
        "`": "\u{E014}", "/": "\u{E015}",
        "?": "\u{E016}", "&": "\u{E017}",
        "$": "\u{E018}", "%": "\u{E019}",
        "^": "\u{E01A}", ";": "\u{E01B}",
        ",": "\u{E01C}", "\"": "\u{E01D}",
        "'": "\u{E01E}", "@": "\u{E01F}",
        ]

    private struct StreamingProjectionLine {
        let text: String
        let isVerbatim: Bool
    }

    private struct BlockProjection {
        let text: String
        let isListItem: Bool
    }

    private struct StreamingHTMLTagState {
        var quote: Character?
        var consumedCharacterCount: Int
        var continuationLineCount: Int
    }

    private struct StreamingHTMLCommentState {
        var consumedCharacterCount: Int
        var continuationLineCount: Int
    }

    private struct StreamingCDATAState {}

    private static let htmlTagNames: Set<String> = [
        "a", "abbr", "address", "area", "article", "aside", "audio",
        "b", "base", "bdi", "bdo", "blockquote", "body", "br", "button",
        "canvas", "caption", "cite", "code", "col", "colgroup",
        "data", "datalist", "dd", "del", "details", "dfn", "dialog",
        "div", "dl", "dt", "em", "embed", "fieldset", "figcaption",
        "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5",
        "h6", "head", "header", "hgroup", "hr", "html", "i", "iframe",
        "img", "input", "ins", "kbd", "label", "legend", "li", "link",
        "main", "map", "mark", "menu", "meta", "meter", "nav", "noscript",
        "object", "ol", "optgroup", "option", "output", "p", "picture",
        "pre", "progress", "q", "rp", "rt", "ruby", "s", "samp",
        "script", "search", "section", "select", "slot", "small", "source",
        "span", "strong", "style", "sub", "summary", "sup", "table",
        "tbody", "td", "template", "textarea", "tfoot", "th", "thead",
        "time", "title", "tr", "track", "u", "ul", "var", "video", "wbr",
        ]

    private static let htmlCharacterReferences: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "nbsp": "\u{00A0}", "ensp": "\u{2002}", "emsp": "\u{2003}",
        "ndash": "\u{2013}", "mdash": "\u{2014}", "minus": "\u{2212}", "hellip": "\u{2026}",
        "copy": "\u{00A9}", "reg": "\u{00AE}", "trade": "\u{2122}", "laquo": "\u{00AB}", "raquo": "\u{00BB}",
        "lsquo": "\u{2018}", "rsquo": "\u{2019}", "ldquo": "\u{201C}", "rdquo": "\u{201D}",
        "lsaquo": "\u{2039}", "rsaquo": "\u{203A}", "sbquo": "\u{201A}", "bdquo": "\u{201E}",
        "bull": "\u{2022}", "middot": "\u{00B7}", "deg": "\u{00B0}", "times": "\u{00D7}",
        "divide": "\u{00F7}", "plusmn": "\u{00B1}", "le": "\u{2264}", "leq": "\u{2264}",
        "ge": "\u{2265}", "geq": "\u{2265}", "ne": "\u{2260}", "micro": "\u{00B5}",
        "larr": "\u{2190}", "rarr": "\u{2192}", "uarr": "\u{2191}", "darr": "\u{2193}",
        "cent": "\u{00A2}", "pound": "\u{00A3}", "yen": "\u{00A5}", "euro": "\u{20AC}",
        "sect": "\u{00A7}", "para": "\u{00B6}", "sup2": "\u{00B2}", "sup3": "\u{00B3}",
        "frac12": "\u{00BD}", "frac14": "\u{00BC}", "frac34": "\u{00BE}",
        ]

    private static func projectedText(
        from markdown: String,
        accessibility: Bool
        ) -> String {
        var result = ""
        var previousWasListItem = false
        for block in AssistantMarkdownParser.parse(markdown) {
            let projection = projection(for: block, accessibility: accessibility)
            guard projection.text.isEmpty == false else { continue }
            if result.isEmpty == false {
                result += previousWasListItem && projection.isListItem ? "\n" : "\n\n"
            }
            result += projection.text
            previousWasListItem = projection.isListItem
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func projection(
        for block: AssistantMarkdownBlock,
        accessibility: Bool
        ) -> BlockProjection {
        switch block.content {
            case .text(let textBlock):
            return BlockProjection(
                text: textBlock.text.semanticPlainText,
                isListItem: textBlock.style.isListItem
                )
            case .checklist(let checklist):
            let body = checklist.text.semanticPlainText
            let text: String
            if accessibility {
                text = checklist.isChecked ? "Completed: \(body)" : "Not completed: \(body)"
            } else {
                text = body
            }
            return BlockProjection(text: text, isListItem: true)
            case .divider:
            return BlockProjection(text: "", isListItem: false)
            case .code(let code):
            return BlockProjection(text: code.code, isListItem: false)
        }
    }

    private static func normalizeLineEndings(_ text: String) -> String {
        text
        .replacingOccurrences(of: "\r\n", with: "\n")
        .replacingOccurrences(of: "\r", with: "\n")
    }

    private static func normalizedWhitespaceLines(
        _ lines: [StreamingProjectionLine]
        ) -> String {
        var normalized: [String] = []
        var previousWasEmpty = true
        for line in lines {
            if line.isVerbatim {
                normalized.append(line.text)
                previousWasEmpty = line.text.isEmpty
                continue
            }
            let visible = line.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let isEmpty = visible.isEmpty
            if isEmpty {
                guard previousWasEmpty == false else { continue }
                normalized.append("")
            } else {
                normalized.append(visible)
            }
            previousWasEmpty = isEmpty
        }
        while normalized.last?.isEmpty == true { normalized.removeLast() }
        return normalized.joined(separator: "\n")
    }

    private static func streamingBlockBody(from rawLine: String) -> String? {
        var line = rawLine.trimmingCharacters(in: .whitespaces)
        guard line.isEmpty == false else { return "" }
        // Strip rails only after the line itself proves a multi-cell
        // outer-railed row. A leading pipe alone may be a shell pipeline,
        // logical operator, or regular expression and must remain literal.
        if line.hasPrefix("|"),
        line.hasSuffix("|"),
        line.dropFirst().dropLast().contains("|") {
            line.removeFirst()
            line = line.trimmingCharacters(in: .whitespaces)
            line.removeLast()
            line = line.trimmingCharacters(in: .whitespaces)
        }
        // An ATX marker arrives before its separating space and body. Treat
        // the marker-only prefix as presentation metadata from the first
        // cumulative snapshot so it can never flash and then retract.
        if line.count <= 6, line.allSatisfy({ $0 == "#" }) { return "" }
        while isLeadingComparison(line) == false,
        let body = AssistantMarkdownParser.quoteBody(in: line) {
            line = body.trimmingCharacters(in: .whitespaces)
        }
        if AssistantMarkdownParser.isDivider(line) { return nil }
        if let heading = AssistantMarkdownParser.heading(in: line) { return heading.body }
        if let checklist = AssistantMarkdownParser.checklist(in: line) { return checklist.body }
        if let body = AssistantMarkdownParser.bulletBody(in: line) {
            // Canonical output uses one semantic Unicode bullet regardless of
            // which Markdown list marker a non-compliant provider emitted.
            return "• \(body)"
        }
        if AssistantMarkdownParser.numberedBody(in: line) != nil {
            // Digits are semantic data, not disposable presentation chrome.
            // Keeping the complete line avoids corrupting factual openings
            // such as '2024. Revenue grew' while remaining readable for lists.
            return line
        }
        return line
    }

    private static func isLeadingComparison(_ line: String) -> Bool {
        if line.hasPrefix(">=") { return true }
        guard line.hasPrefix("> ") else { return false }
        let value = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        guard let first = value.first else { return false }
        if first.isNumber { return true }
        if first == "." || first == "+" || first == "-" {
            return value.dropFirst().first?.isNumber == true
        }
        return false
    }

    private static func isSetextUnderline(_ line: String) -> Bool {
        let compact = line.filter { $0.isWhitespace == false }
        guard compact.count >= 3, let marker = compact.first,
        marker == "=" || marker == "-" else { return false }
        return compact.allSatisfy { $0 == marker }
    }

    private static func isReferenceLinkDefinition(_ line: String) -> Bool {
        referenceLinkDefinitionID(line) != nil
    }

    private static func referenceLinkDefinitionID(_ line: String) -> String? {
        guard line.hasPrefix("["),
        let close = line.firstIndex(of: "]"),
        close > line.startIndex else { return nil }
        let colon = line.index(after: close)
        guard colon < line.endIndex, line[colon] == ":" else { return nil }
        let destinationStart = line.index(after: colon)
        let destination = line[destinationStart...]
        .trimmingCharacters(in: .whitespaces)
        guard destination.isEmpty == false else { return nil }
        return normalizedReferenceLabel(
            String(line[line.index(after: line.startIndex)..<close])
            )
    }

    private static func normalizedReferenceLabel(_ label: String) -> String {
        label
        .split(whereSeparator: \Character.isWhitespace)
        .joined(separator: " ")
        .folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
            )
        .lowercased()
    }

    private static func isTableSeparator(_ line: String) -> Bool {
        guard line.contains("|") else { return false }
        let cells = line
            .trimmingCharacters(in: CharacterSet(charactersIn: "|"))
            .split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard cells.count >= 2 else { return false }
        return cells.allSatisfy { cell in
            let compact = cell.filter { $0 != ":" && $0.isWhitespace == false }
            return compact.count >= 3 && compact.allSatisfy { $0 == "-" }
        }
    }

    /// Hides the unfinished tail of an angle-bracket presentation construct.
    /// Once it closes, HTML/comments are removed and autolinks are projected;
    /// generic/comparison text is revealed as one forward-only suffix. Inline
    /// code remains literal even while its closing backticks are still absent.
    private static func bufferingIncompleteTrailingAngleConstruct(
        in line: String
        ) -> String {
        guard let opening = line.lastIndex(of: "<"),
        containsAngleCloseOutsideQuotes(
            in: line[line.index(after: opening)...]
            ) == false else {
            return line
        }
        let contentStart = line.index(after: opening)
        let content = line[contentStart...]
        let isHTMLCommentPrefix = "!--".hasPrefix(content)
        || content.hasPrefix("!--")
        guard (isInsideUnclosedInlineCode(at: opening, in: line) == false
            || isHTMLCommentPrefix),
        isPotentialStreamingAngleConstruct(at: opening, in: line) else {
            return line
        }
        if content.count > 96, isLikelyAutolinkContent(content) {
            // Do not leave a long URL behind an invisible ambiguity gate. The
            // leading presentation bracket can be omitted immediately because
            // both a completed autolink and the terminal fallback expose the
            // same useful URL/email content.
            return String(line[..<opening]) + content
        }
        return String(line[..<opening])
    }

    private static func isLikelyAutolinkContent(_ content: Substring) -> Bool {
        guard content.contains(where: \Character.isWhitespace) == false else {
            return false
        }
        if content.contains("@") { return true }
        guard let colon = content.firstIndex(of: ":") else { return false }
        let scheme = content[..<colon]
        return scheme.count >= 2
        && scheme.first?.isLetter == true
        && scheme.allSatisfy {
            $0.isLetter || $0.isNumber || "+.-".contains($0)
        }
    }

    private static func containsAngleCloseOutsideQuotes(
        in suffix: Substring
        ) -> Bool {
        var quote: Character?
        for character in suffix {
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == ">" {
                return true
            }
        }
        return false
    }

    /// A terminal backslash may be the first half of an escaped presentation
    /// marker. Keep it behind the reveal boundary for one snapshot so '\*'
    /// appears atomically as its literal asterisk.
    private static func bufferingIncompleteTrailingEscape(in line: String) -> String {
        guard line.last == "\\" else { return line }
        var slashCount = 0
        var cursor = line.endIndex
        while cursor > line.startIndex {
            let previous = line.index(before: cursor)
            guard line[previous] == "\\" else { break }
            slashCount += 1
            cursor = previous
        }
        return slashCount.isMultiple(of: 2) ? line : String(line[..<cursor])
    }

    /// '!' is semantic punctuation until an immediately following '[' proves
    /// an image opener. Hold only the unescaped trailing marker for that one
    /// ambiguous cumulative snapshot; escaped punctuation and inline code are
    /// always literal.
    private static func bufferingIncompleteTrailingImageOpening(
        in line: String
        ) -> String {
        guard let marker = line.indices.last,
        line[marker] == "!",
        isEscaped(at: marker, in: line) == false,
        isInsideUnclosedInlineCode(at: marker, in: line) == false else {
            return line
        }
        return String(line[..<marker])
    }

    /// A boundary '[' is ambiguous for one cumulative snapshot. Holding that
    /// single marker prevents it flashing before an alphabetic Markdown link
    /// label, while subscripts such as 'array[' remain literal immediately.
    private static func bufferingIncompleteTrailingLinkOpening(
        in line: String
        ) -> String {
        guard line.hasSuffix("[") else { return line }
        let opening = line.index(before: line.endIndex)
        guard isInsideUnclosedInlineCode(at: opening, in: line) == false else {
            return line
        }
        guard opening == line.startIndex else {
            let previousIndex = line.index(before: opening)
            let previous = line[previousIndex]
            if previous == "!" {
                // '!' is presentation only when the bang itself is not
                // escaped. Remove the two-character opener atomically so the
                // bang cannot flash for one cumulative snapshot.
                return isEscaped(at: previousIndex, in: line)
                ? line
                : String(line[..<previousIndex])
            }
            guard previous.isWhitespace
            || ".,:;!?(){}<>\"'“”‘’—".contains(previous) else {
                return line
            }
            return String(line[..<opening])
        }
        return ""
    }

    /// Holds a checklist marker until either its body begins or the prefix
    /// diverges. Without this gate, '- [x' first projects as a bullet and then
    /// retracts when '- [x]' becomes a checklist.
    private static func bufferingIncompleteTrailingChecklist(
        in line: String
        ) -> String {
        let candidate = String(line.drop(while: { $0 == " " || $0 == "\t" }))
        guard candidate.isEmpty == false else { return line }
        let prefixes = ["-", "*", "+", ">"].flatMap { marker in
            ["\(marker) [ ", "\(marker) [x] ", "\(marker) [X] "]
        }
        return prefixes.contains(where: { $0.hasPrefix(candidate) }) ? "" : line
    }

    /// A reference definition is invisible metadata. Its colon used to flash
    /// for the one snapshot between a complete label and the first destination
    /// character, after which the completed definition disappeared.
    private static func bufferingIncompleteReferenceDefinition(
        in line: String
        ) -> String {
        let candidate = line.trimmingCharacters(in: .whitespaces)
        guard candidate.hasPrefix("[") else { return line }
        guard let close = candidate.firstIndex(of: "]") else {
            // A definition label at the beginning of the current line is
            // ambiguous until ']' and its following character arrive.
            return candidate.count <= 64 ? "" : line
        }
        guard close > candidate.startIndex else { return line }
        let colon = candidate.index(after: close)
        guard colon < candidate.endIndex else {
            return candidate.count <= 66 ? "" : line
        }
        guard candidate[colon] == ":" else {
            return line
        }
        let suffix = candidate[candidate.index(after: colon)...]
        return suffix.allSatisfy(\.isWhitespace) && candidate.count <= 128
        ? ""
        : line
    }

    /// An outer table rail cannot be distinguished from a shell pipe until a
    /// complete multi-cell row exists. Buffer that short ambiguity instead of
    /// publishing '|' and later removing it when the closing rail arrives.
    private static func bufferingIncompleteOuterRailedTableRow(
        in line: String
        ) -> String {
        let candidate = line.drop(while: { $0 == " " || $0 == "\t" })
        guard candidate.first == "|" else { return line }
        let afterRail = candidate.index(after: candidate.startIndex)
        guard afterRail < candidate.endIndex,
        candidate[afterRail].isWhitespace else { return line }
        let trimmed = candidate.trimmingCharacters(in: .whitespaces)
        let isCompleteOuterRailedRow = trimmed.hasSuffix("|")
        && trimmed.dropFirst().dropLast().contains("|")
        return isCompleteOuterRailedRow || candidate.count > 96 ? line : ""
    }

    /// Holds a possible HTML character reference until its semicolon arrives.
    /// Otherwise '&am' would briefly become visible and then retract when the
    /// completed '&amp;' settles to one semantic ampersand.
    private static func bufferingIncompleteTrailingEntity(
        in line: String
        ) -> String {
        guard let opening = line.lastIndex(of: "&") else { return line }
        let suffixStart = line.index(after: opening)
        let suffix = String(line[suffixStart...])
        guard suffix.contains(";") == false else { return line }
        let lowered = suffix.lowercased()
        let isNamedPrefix = lowered.isEmpty
            || htmlCharacterReferences.keys.contains(where: {
                $0.hasPrefix(lowered)
            })
        let isNumericPrefix: Bool
        if lowered.hasPrefix("#x") {
            let digits = lowered.dropFirst(2)
            isNumericPrefix = digits.count <= 6
                && digits.allSatisfy(\.isHexDigit)
        } else if lowered.hasPrefix("#") {
            let digits = lowered.dropFirst()
            isNumericPrefix = digits.count <= 7
                && digits.allSatisfy(\.isNumber)
        } else {
            isNumericPrefix = false
        }
        guard isNamedPrefix || isNumericPrefix else { return line }
        return String(line[..<opening])
    }

    /// Holds an unmatched inline-presentation delimiter only while it is the
    /// trailing token at a prose boundary. Intraword operators (`5*3`,
    /// `snake_case`), escaped punctuation, and inline code remain literal.
    private static func bufferingIncompleteTrailingInlineDelimiter(
        in line: String
        ) -> String {
        guard let last = line.indices.last,
            "_*-".contains(line[last]) else { return line }
        let marker = line[last]
        var runStart = last
        while runStart > line.startIndex {
            let previous = line.index(before: runStart)
            guard line[previous] == marker else { break }
            runStart = previous
        }
        let runLength = line.distance(from: runStart, to: line.endIndex)
        guard runLength <= 2,
            isEscaped(at: runStart, in: line) == false,
            isInsideUnclosedInlineCode(at: runStart, in: line) == false else {
            return line
        }
        if hasCompleteOpeningDelimiter(
            marker: marker,
            trailingRunLength: runLength,
            before: runStart,
            in: line
            ) {
            // The closing run is complete, so semantic projection can consume
            // both sides atomically. Buffering it would turn balanced emphasis
            // into an unmatched provider operator and leak the opening marker.
            return line
        }
        if runStart > line.startIndex {
            let previous = line[line.index(before: runStart)]
            let couldClosePresentation = hasPotentialOpeningDelimiter(
                marker: marker,
                trailingRunLength: runLength,
                before: runStart,
                in: line
                )
            guard (previous.isLetter == false && previous.isNumber == false)
                || couldClosePresentation else {
                return line
            }
        }
        return String(line[..<runStart])
    }

    private static func hasCompleteOpeningDelimiter(
        marker: Character,
        trailingRunLength: Int,
        before end: String.Index,
        in line: String
        ) -> Bool {
        let delimiter = String(repeating: marker, count: trailingRunLength)
        guard end > line.startIndex,
            line[line.index(before: end)].isWhitespace == false else {
            return false
        }
        var cursor = line.startIndex
        while let opening = line.range(of: delimiter, range: cursor..<end) {
            let before = opening.lowerBound > line.startIndex
                ? line[line.index(before: opening.lowerBound)]
                : nil
            let after = opening.upperBound < end
                ? line[opening.upperBound]
                : nil
            let isPartOfLongerRun = trailingRunLength == 1
                && (before == marker || after == marker)
            let canOpen = after?.isWhitespace == false
                && !(isLetterOrNumber(before) && isLetterOrNumber(after))
                && (marker != "_" || isLetterOrNumber(before) == false)
                && isPartOfLongerRun == false
            if canOpen { return true }
            cursor = opening.upperBound
        }
        return false
    }

    private static func hasPotentialOpeningDelimiter(
        marker: Character,
        trailingRunLength: Int,
        before end: String.Index,
        in line: String
        ) -> Bool {
        let lengths: [Int]
        if marker == "~" {
            lengths = [2]
        } else if trailingRunLength == 1 {
            // The first trailing `*`/`_` may close either an italic or a strong
            // run. Buffer it when either opener is already present.
            lengths = [1, 2]
        } else {
            lengths = [2]
        }

        for length in lengths {
            let delimiter = String(repeating: marker, count: length)
            var cursor = line.startIndex
            while let opening = line.range(
                of: delimiter,
                range: cursor..<end
                ) {
                let before = opening.lowerBound > line.startIndex
                    ? line[line.index(before: opening.lowerBound)]
                    : nil
                let after = opening.upperBound < end
                    ? line[opening.upperBound]
                    : nil
                let isPartOfLongerRun = length == 1
                    && (before == marker || after == marker)
                let canOpen = after?.isWhitespace == false
                    && !(isLetterOrNumber(before) && isLetterOrNumber(after))
                    && (marker != "_" || isLetterOrNumber(before) == false)
                    && isPartOfLongerRun == false
                if canOpen { return true }
                cursor = opening.upperBound
            }
        }
        return false
    }

    private static func isPartialFenceClosing(
        _ line: String,
        marker: Character,
        minimumLength: Int
        ) -> Bool {
        let compact = line.trimmingCharacters(in: .whitespaces)
        return compact.isEmpty == false
            && compact.count < minimumLength
            && compact.allSatisfy { $0 == marker }
    }

    private static func isPotentialStreamingAngleConstruct(
        at opening: String.Index,
        in line: String
        ) -> Bool {
        let contentStart = line.index(after: opening)
        // Hold a lone boundary marker for one cumulative update. As soon as a
        // following space proves an ordinary comparison (`x < y`), the marker
        // and all subsequent prose are released without waiting for `>`.
        guard contentStart < line.endIndex else { return true }
        if line[contentStart].isWhitespace { return false }

        let first = line[contentStart]
        if first == "!" || first == "?" || first == "/" { return true }

        // `Data<Source` and similar generic/type prose is not presentation
        // markup. HTML tags, comments, and autolinks begin at a text boundary.
        guard first.isLetter else { return false }

        let originalContent = String(line[contentStart...])
        let content = originalContent.lowercased()
        let namePrefix = String(content.prefix { $0.isLetter || $0.isNumber })
        let emailLocalCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!#$%&'*+/=?^_`{|}~-"
            )
        if originalContent.unicodeScalars.allSatisfy(emailLocalCharacters.contains) {
            // An email autolink cannot be proven until `@` arrives. Buffer the
            // compact angle expression from its first local-part character;
            // generic/comparison text is released atomically when it closes or
            // at the terminal boundary.
            return true
        }
        let htmlTags = [
            "a", "abbr", "address", "area", "article", "aside", "audio",
            "b", "base", "bdi", "bdo", "blockquote", "body", "br", "button",
            "canvas", "caption", "cite", "code", "col", "colgroup",
            "data", "datalist", "dd", "del", "details", "dfn", "dialog",
            "div", "dl", "dt", "em", "embed", "fieldset", "figcaption",
            "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5",
            "h6", "head", "header", "hgroup", "hr", "html", "i", "iframe",
            "img", "input", "ins", "kbd", "label", "legend", "li", "link",
            "main", "map", "mark", "menu", "meta", "meter", "nav", "noscript",
            "object", "ol", "optgroup", "option", "output", "p", "picture",
            "pre", "progress", "q", "rp", "rt", "ruby", "s", "samp",
            "script", "search", "section", "select", "slot", "small", "source",
            "span", "strong", "style", "sub", "summary", "sup", "table",
            "tbody", "td", "template", "textarea", "tfoot", "th", "thead",
            "time", "title", "tr", "track", "u", "ul", "var", "video", "wbr",
            ]
        let beginsWithLowercaseName = originalContent.first?.isLowercase == true
        if namePrefix.isEmpty == false,
            htmlTags.contains(where: { $0.hasPrefix(namePrefix) }),
            beginsWithLowercaseName
            || opening == line.startIndex
            || line[line.index(before: opening)].isWhitespace {
            return true
        }

        if opening != line.startIndex,
            line[line.index(before: opening)].isWhitespace == false {
            return false
        }

        // Only URI prefixes that the final autolink projector recognizes are
        // held. An ordinary compact comparison such as `x<y` or `<theta`
        // diverges quickly and streams normally instead of waiting for settle.
        let schemes = ["http://", "https://", "mailto:"]
        if schemes.contains(where: {
                $0.hasPrefix(content) || content.hasPrefix($0)
            }) {
            return true
        }
        if let colon = content.firstIndex(of: ":") {
            let scheme = content[..<colon]
            if scheme.count >= 2,
                scheme.first?.isLetter == true,
                scheme.allSatisfy({
                    $0.isLetter || $0.isNumber || "+-.".contains($0)
                }) {
                return true
            }
        }
        return content.contains("@")
            && content.contains(where: \Character.isWhitespace) == false
    }

    private static func isInsideUnclosedInlineCode(
        at target: String.Index,
        in text: String
        ) -> Bool {
        var cursor = text.startIndex
        while cursor < target {
            guard text[cursor] == "`" else {
                cursor = text.index(after: cursor)
                continue
            }
            let markerEnd = endOfRun(of: "`", from: cursor, in: text)
            let marker = String(text[cursor..<markerEnd])
            guard let closing = text.range(
                of: marker,
                range: markerEnd..<text.endIndex
                ) else {
                return markerEnd <= target
            }
            if target >= markerEnd, target < closing.lowerBound { return true }
            cursor = closing.upperBound
        }
        return false
    }

    private static func isAmbiguousTrailingBlockMarker(_ line: String) -> Bool {
        guard line.isEmpty == false else { return false }
        let markerCharacters = CharacterSet(charactersIn: "#>_-*+`|:- ")
        return line.unicodeScalars.allSatisfy(markerCharacters.contains)
    }

    private static func streamingReferenceLinkLabels(
        in lines: [String],
        plainCodeLines: [Bool]
        ) -> Set<String> {
        var labels: Set<String> = []
        var openFence: (marker: Character, length: Int)?
        var htmlCommentState: StreamingHTMLCommentState?
        var cdataState: StreamingCDATAState?
        var openMultilineHTMLTag: StreamingHTMLTagState?

        for (index, originalLine) in lines.enumerated() {
            var line = originalLine
            let originalTrimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = openFence {
                if AssistantMarkdownParser.isFenceClosing(
                    originalTrimmed,
                    marker: fence.marker,
                    minimumLength: fence.length
                    ) {
                    openFence = nil
                }
                continue
            }

            var resumedAfterHTMLComment = false
            if htmlCommentState != nil {
                line = removingStreamingHTMLComments(
                    from: line,
                    state: &htmlCommentState
                    )
                resumedAfterHTMLComment = true
                if line.isEmpty { continue }
            }
            if cdataState != nil || plainCodeLines[index] == false {
                let enteredInsideCDATA = cdataState != nil
                let containedCDATAOpening = line.range(
                    of: "<![CDATA[",
                    options: .caseInsensitive
                    ) != nil
                line = removingStreamingCDATASections(
                    from: line,
                    state: &cdataState,
                    buffersTrailingTerminator: false
                    )
                if line.isEmpty, enteredInsideCDATA || containedCDATAOpening {
                    continue
                }
            }
            if openMultilineHTMLTag != nil || plainCodeLines[index] == false {
                line = removingStreamingMultilineHTMLTag(
                    from: line,
                    state: &openMultilineHTMLTag
                    )
                if line.isEmpty { continue }
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if let fence = AssistantMarkdownParser.fenceOpening(in: trimmed) {
                openFence = (fence.marker, fence.length)
                continue
            }
            if plainCodeLines[index], resumedAfterHTMLComment == false {
                continue
            }

            let prose = removingStreamingHTMLComments(
                from: line,
                state: &htmlCommentState
                )
            if let label = referenceLinkDefinitionID(
                prose.trimmingCharacters(in: .whitespaces)
                ) {
                labels.insert(label)
            }
        }
        return labels
    }

    private static func removingAutolinkDelimiters(in text: String) -> String {
        text.replacingOccurrences(
            of: #"<(https?://[^<>\s]+)>"#,
            with: "$1",
            options: [.regularExpression, .caseInsensitive]
            )
        .replacingOccurrences(
            of: #"<mailto:([^<>\s]+)>"#,
            with: "$1",
            options: [.regularExpression, .caseInsensitive]
            )
        .replacingOccurrences(
            of: #"<([A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+@[A-Za-z0-9]?(?:[A-Za-z0-9.-]*[A-Za-z0-9])?)>"#,
            with: "$1",
            options: [.regularExpression, .caseInsensitive]
            )
        .replacingOccurrences(
            of: #"<([A-Z][A-Za-z0-9+.-]{1,31}:[^<>\s]+)>"#,
            with: "$1",
            options: [.regularExpression, .caseInsensitive]
            )
    }

    /// Raw inline HTML is another CommonMark presentation surface. Strip only
    /// recognized HTML elements outside fenced, inferred, and inline code so
    /// Swift generics such as `Array<String>` and comparison operators remain
    /// literal while `<strong>text</strong>` projects to `text`.
    private static func projectingCDATASections(in text: String) -> String {
        var result = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard let opening = text.range(
                of: "<![CDATA[",
                options: .caseInsensitive,
                range: cursor..<text.endIndex
                ) else {
                result += String(text[cursor...])
                break
            }
            if isInsideUnclosedInlineCode(
                at: opening.lowerBound,
                in: text
                ) {
                result += String(text[cursor...opening.upperBound])
                cursor = opening.upperBound
                continue
            }
            result += String(text[cursor..<opening.lowerBound])
            if let closing = text.range(
                of: "]]>",
                range: opening.upperBound..<text.endIndex
                ) {
                result += String(text[opening.upperBound..<closing.lowerBound])
                cursor = closing.upperBound
            } else {
                result += String(text[opening.upperBound...])
                break
            }
        }
        return result
    }

    private static func projectingXMLPresentation(in text: String) -> String {
        let cdataProjected = projectingCDATASections(in: text)
        let instructionProjected = removingXMLProcessingInstructions(
            in: cdataProjected
            )
        return removingXMLDeclarations(in: instructionProjected)
    }

    private static func removingXMLProcessingInstructions(
        in text: String
        ) -> String {
        var result = ""
        var cursor = text.startIndex

        while cursor < text.endIndex {
            guard let opening = text.range(
                of: "<?",
                range: cursor..<text.endIndex
                ) else {
                result += String(text[cursor...])
                break
            }
            result += String(text[cursor..<opening.lowerBound])
            guard let closing = text.range(
                of: "?>",
                range: opening.upperBound..<text.endIndex
                ) else {
                // Unlike HTML, a bare `>` does not close an XML processing
                // instruction. The positively identified instruction remains
                // metadata through the terminal boundary when `?>` is absent.
                break
            }
            cursor = closing.upperBound
        }
        return result
    }

    private static func removingXMLDeclarations(in text: String) -> String {
        let names: Set<String> = [
            "doctype", "element", "entity", "attlist", "notation",
            ]
        var result = ""
        var cursor = text.startIndex

        while cursor < text.endIndex {
            guard let opening = text.range(
                of: "<!",
                options: .caseInsensitive,
                range: cursor..<text.endIndex
                ) else {
                result += String(text[cursor...])
                break
            }
            var probe = opening.upperBound
            while probe < text.endIndex, text[probe].isWhitespace {
                probe = text.index(after: probe)
            }
            let nameStart = probe
            while probe < text.endIndex, text[probe].isLetter {
                probe = text.index(after: probe)
            }
            let name = String(text[nameStart..<probe]).lowercased()
            guard names.contains(name) else {
                result += String(text[cursor..<opening.upperBound])
                cursor = opening.upperBound
                continue
            }

            var quote: Character?
            var subsetDepth = 0
            var declarationEnd: String.Index?
            var end = probe
            while end < text.endIndex {
                let character = text[end]
                if let activeQuote = quote {
                    if character == activeQuote { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == "[" {
                    subsetDepth += 1
                } else if character == "]", subsetDepth > 0 {
                    subsetDepth -= 1
                } else if character == ">", subsetDepth == 0 {
                    declarationEnd = text.index(after: end)
                    break
                }
                end = text.index(after: end)
            }

            result += String(text[cursor..<opening.lowerBound])
            if let declarationEnd {
                cursor = declarationEnd
            } else {
                // A recognized declaration remains metadata even when the
                // provider never emits its closing bracket. Releasing a long
                // terminal tail here exposed fragments such as
                // 'html PUBLIC "...' as answer text.
                break
            }
        }
        return result
    }

    private static func removingHTMLPresentation(
        in text: String,
        buffersAmbiguousAdjacentTags: Bool
        ) -> String {
        let voidTagNames: Set<String> = [
            "area", "base", "br", "col", "embed", "hr", "img", "input",
            "link", "meta", "source", "track", "wbr",
            ]
        let blockTagNames: Set<String> = [
            "address", "article", "aside", "blockquote", "body", "caption",
            "dd", "details", "dialog", "div", "dl", "dt", "fieldset",
            "figcaption", "figure", "footer", "form", "h1", "h2", "h3",
            "h4", "h5", "h6", "header", "hgroup", "hr", "html", "main",
            "nav", "ol", "p", "pre", "section", "summary", "table",
            "tbody", "td", "tfoot", "th", "thead", "tr", "ul",
            ]
        var result = text.replacingOccurrences(
            of: #"(?s)<!--.*?-->"#,
            with: "",
            options: .regularExpression
            )
        result = result.replacingOccurrences(
            of: #"(?i)<!DOCTYPE\s+html\s*>"#,
            with: "",
            options: .regularExpression
            )
        result = result.replacingOccurrences(
            of: #"(?is)<\?.*?\?>"#,
            with: "",
            options: .regularExpression
            )
        result = result.replacingOccurrences(
            of: #"(?is)<!\[CDATA\[(.*?)\]\]>"#,
            with: "$1",
            options: .regularExpression
            )
        var projected = ""
        var recognizedOpenTagDepth: [String: Int] = [:]
        var cursor = result.startIndex
        while cursor < result.endIndex {
            guard result[cursor] == "<" else {
                projected.append(result[cursor])
                cursor = result.index(after: cursor)
                continue
            }
            let malformedStart = result.index(after: cursor)
            if malformedStart < result.endIndex,
                result[malformedStart] == "?",
                result[malformedStart...].contains(">") == false {
                // An unfinished processing instruction is metadata from its
                // '<?' opener through the terminal boundary. It must fail
                // closed rather than exposing 'pi ...' when a provider stops
                // before '?>'.
                break
            }
            if malformedStart < result.endIndex,
                "!?/".contains(result[malformedStart]),
                result[malformedStart...].contains(">") == false,
                result.distance(from: malformedStart, to: result.endIndex) > 256 {
                var contentStart = result.index(after: malformedStart)
                if result[malformedStart...].hasPrefix("!--") {
                    contentStart = result.index(
                        malformedStart,
                        offsetBy: 3,
                        limitedBy: result.endIndex
                        ) ?? result.endIndex
                }
                projected += String(result[contentStart...])
                break
            }
            var probe = result.index(after: cursor)
            let isClosing = probe < result.endIndex && result[probe] == "/"
            if isClosing { probe = result.index(after: probe) }
            let nameStart = probe
            while probe < result.endIndex,
                result[probe].isLetter || result[probe].isNumber {
                probe = result.index(after: probe)
            }
            guard probe > nameStart else {
                projected.append(result[cursor])
                cursor = result.index(after: cursor)
                continue
            }
            let originalName = String(result[nameStart..<probe])
            let name = originalName.lowercased()
            let hasTagBoundary = probe < result.endIndex
                && (result[probe].isWhitespace
                || result[probe] == "/"
                || result[probe] == ">")
            let precedingIsToken = cursor > result.startIndex
                && {
                    let preceding = result[result.index(before: cursor)]
                    return preceding.isLetter || preceding.isNumber || preceding == "_"
            }()
            guard htmlTagNames.contains(name), hasTagBoundary else {
                projected.append(result[cursor])
                cursor = result.index(after: cursor)
                continue
            }
            var quote: Character?
            var tagEnd = probe
            while tagEnd < result.endIndex {
                let character = result[tagEnd]
                if let activeQuote = quote {
                    if character == activeQuote { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == ">" {
                    break
                } else if character.isNewline {
                    tagEnd = result.endIndex
                    break
                }
                tagEnd = result.index(after: tagEnd)
            }
            guard tagEnd < result.endIndex, result[tagEnd] == ">" else {
                projected.append(result[cursor])
                cursor = result.index(after: cursor)
                continue
            }
            let nameBoundaryCharacter = result[probe]
            let hasExplicitTagSyntax = nameBoundaryCharacter.isWhitespace
                || nameBoundaryCharacter == "/"
            let isUppercaseTagSpelling = originalName == originalName.uppercased()
                && originalName.contains(where: \Character.isLetter)
            let isUnambiguousLowercaseTagSpelling = originalName == name
                && name.count > 1
            let isTitleCaseNonVoidTagSpelling = voidTagNames.contains(name) == false
                && originalName.first?.isUppercase == true
                && originalName.dropFirst().allSatisfy(\Character.isLowercase)
            let isCanonicalVoidSpelling = voidTagNames.contains(name)
                && (originalName == name
                || isUppercaseTagSpelling
                || (["br", "hr", "wbr"].contains(name)
                    && originalName.first?.isUppercase == true
                    && originalName.dropFirst().allSatisfy(\Character.isLowercase)))
            let hasMatchingClosingTag = isClosing == false
                && result.range(
                    of: "</\(name)",
                    options: [.caseInsensitive, .literal],
                    range: probe..<result.endIndex
                ) != nil
            let afterTag = result.index(after: tagEnd)
            let nextCharacterProvesGeneric = afterTag < result.endIndex
                && {
                    let next = result[afterTag]
                    return next.isWhitespace || ".,;:!?)]".contains(next)
            }()
            let isAmbiguousAdjacentCasedOpening = isClosing == false
                && precedingIsToken
                && hasExplicitTagSyntax == false
                && isUnambiguousLowercaseTagSpelling == false
                && isCanonicalVoidSpelling == false
                && (isTitleCaseNonVoidTagSpelling || isUppercaseTagSpelling)
            let recognizesProvisionalStreamingTag = buffersAmbiguousAdjacentTags
                && isAmbiguousAdjacentCasedOpening
                && nextCharacterProvesGeneric == false
            let recognizesTag: Bool
            if isClosing {
                recognizesTag = recognizedOpenTagDepth[name, default: 0] > 0
                    || precedingIsToken == false
                    || isUnambiguousLowercaseTagSpelling
                    || isTitleCaseNonVoidTagSpelling
                    || isUppercaseTagSpelling
                    || isCanonicalVoidSpelling
            } else {
                recognizesTag = precedingIsToken == false
                    || hasExplicitTagSyntax
                    || isUnambiguousLowercaseTagSpelling
                    || hasMatchingClosingTag
                    || recognizesProvisionalStreamingTag
                    || isCanonicalVoidSpelling
            }
            guard recognizesTag else {
                projected.append(result[cursor])
                cursor = result.index(after: cursor)
                continue
            }
            let isSelfClosing = tagEnd > cursor
                && result[result.index(before: tagEnd)] == "/"
            if isClosing {
                if recognizedOpenTagDepth[name, default: 0] > 0 {
                    recognizedOpenTagDepth[name, default: 0] -= 1
                }
            } else if voidTagNames.contains(name) == false, isSelfClosing == false {
                recognizedOpenTagDepth[name, default: 0] += 1
            }
            if name == "br", isClosing == false {
                if projected.last?.isNewline != true { projected.append("\n") }
            } else if name == "li" {
                if isClosing {
                    if projected.last?.isNewline != true { projected.append("\n") }
                } else {
                    if projected.isEmpty == false,
                        projected.last?.isNewline != true {
                        projected.append("\n")
                    }
                    projected += "• "
                }
            } else if blockTagNames.contains(name) {
                if projected.isEmpty == false,
                    projected.last?.isNewline != true {
                    projected.append("\n")
                }
            }
            cursor = result.index(after: tagEnd)
        }
        return projected
    }

    /// Decodes the character references Foundation Models most commonly emits
    /// as presentation text. Numeric references cover the full valid Unicode
    /// scalar range; fenced and inline code bypass this prose transform.
    private static func decodingHTMLCharacterReferences(in text: String) -> String {
        func decoded(_ token: Substring) -> String? {
            if token.hasPrefix("#x") || token.hasPrefix("#X") {
                let digits = token.dropFirst(2)
                guard digits.isEmpty == false,
                    let value = UInt32(digits, radix: 16),
                    let scalar = Unicode.Scalar(value) else { return nil }
                return String(scalar)
            }
            if token.hasPrefix("#") {
                let digits = token.dropFirst()
                guard digits.isEmpty == false,
                    let value = UInt32(digits, radix: 10),
                    let scalar = Unicode.Scalar(value) else { return nil }
                return String(scalar)
            }
            return htmlCharacterReferences[String(token).lowercased()]
        }
        var result = ""
        var cursor = text.startIndex
        while cursor < text.endIndex {
            guard text[cursor] == "&",
                let semicolon = text[cursor...].firstIndex(of: ";"),
                text.distance(from: cursor, to: semicolon) <= 18 else {
                result.append(text[cursor])
                cursor = text.index(after: cursor)
                continue
            }
            let tokenStart = text.index(after: cursor)
            if let value = decoded(text[tokenStart..<semicolon]) {
                result += value
                cursor = text.index(after: semicolon)
            } else {
                result.append(text[cursor])
                cursor = text.index(after: cursor)
            }
        }
        return result
    }

    /// Removes CDATA wrappers before Markdown/image detection. The state is
    /// rebuilt from each cumulative snapshot and spans physical lines, so a
    /// multiline terminator can never leak as ']]>' into the transcript.
    private static func removingStreamingCDATASections(
        from line: String,
        state: inout StreamingCDATAState?,
        buffersTrailingTerminator: Bool
        ) -> String {
        var result = ""
        var cursor = line.startIndex
        while cursor < line.endIndex {
            if state != nil {
                if let closing = line.range(
                    of: "]]>",
                    range: cursor..<line.endIndex
                    ) {
                    result += String(line[cursor..<closing.lowerBound])
                    state = nil
                    cursor = closing.upperBound
                    continue
                }
                var content = String(line[cursor...])
                if buffersTrailingTerminator {
                    if content.hasSuffix("]]") {
                        content.removeLast(2)
                    } else if content.hasSuffix("]") {
                        content.removeLast()
                    }
                }
                result += content
                return result
            }

            guard let opening = line.range(
                of: "<![CDATA[",
                options: .caseInsensitive,
                range: cursor..<line.endIndex
                ) else {
                result += String(line[cursor...])
                break
            }
            if isInsideUnclosedInlineCode(
                at: opening.lowerBound,
                in: line
                ) {
                result += String(line[cursor..<opening.upperBound])
                cursor = opening.upperBound
                continue
            }
            result += String(line[cursor..<opening.lowerBound])
            state = StreamingCDATAState()
            cursor = opening.upperBound
        }
        return result
    }

    private static func removingStreamingHTMLComments(
        from line: String,
        state: inout StreamingHTMLCommentState?,
        releasesMalformedTail: Bool = false
        ) -> String {
        var result = ""
        var cursor = line.startIndex
        while cursor < line.endIndex {
            if var active = state {
                if let end = line.range(of: "-->", range: cursor..<line.endIndex) {
                    state = nil
                    cursor = end.upperBound
                    continue
                }
                active.continuationLineCount += 1
                let wouldConsume = active.consumedCharacterCount
                    + line.distance(from: cursor, to: line.endIndex)
                if releasesMalformedTail {
                    state = nil
                    // The comment was positively identified by its opener.
                    // Its unterminated contents remain metadata at settle;
                    // exposing them would leak comment directives into the
                    // visible answer.
                    return result
                }
                active.consumedCharacterCount = wouldConsume
                state = active
                return result
            }
            let opening = line.range(
                of: "<!--",
                range: cursor..<line.endIndex
                )
            var codeOpening = line[cursor...].firstIndex(of: "`")
            while let candidate = codeOpening,
                isEscaped(at: candidate, in: line) {
                let next = line.index(after: candidate)
                codeOpening = next < line.endIndex
                    ? line[next...].firstIndex(of: "`")
                    : nil
            }
            if let codeOpening,
                opening.map({ codeOpening < $0.lowerBound }) ?? true {
                let markerEnd = endOfRun(of: "`", from: codeOpening, in: line)
                if let codeClosing = line.range(
                    of: String(line[codeOpening...markerEnd]),
                    range: markerEnd..<line.endIndex
                    ) {
                    result += String(line[cursor..<codeClosing.upperBound])
                    cursor = codeClosing.upperBound
                    continue
                }
                // Only a closed code span is opaque. Continue scanning after
                // an unmatched marker so a later comment cannot leak.
                result += String(line[cursor..<markerEnd])
                cursor = markerEnd
                continue
            }
            guard let opening else {
                result += String(line[cursor...])
                break
            }
            result += String(line[cursor..<opening.lowerBound])
            if let end = line.range(
                of: "-->",
                range: opening.upperBound..<line.endIndex
                ) {
                cursor = end.upperBound
                continue
            }
            let heldCount = line.distance(
                from: opening.lowerBound,
                to: line.endIndex
                )
            if releasesMalformedTail {
                // Keep a positively identified, unterminated comment opaque.
                // Ordinary malformed prose is never routed through this path
                // because it lacks the complete '<!--' opener.
                return result
            }
            state = StreamingHTMLCommentState(
                consumedCharacterCount: heldCount,
                continuationLineCount: 0
                )
            return result
        }
        return result
    }

    /// Removes a recognized HTML tag whose attributes span physical lines.
    /// Complete single-line tags remain for the structure-aware inline scanner,
    /// which supplies paragraph/list separators. While a multiline tag is open,
    /// code-looking attribute lines are metadata and cannot escape through the
    /// inferred-code fast path.
    private static func removingStreamingMultilineHTMLTag(
        from line: String,
        state: inout StreamingHTMLTagState?,
        releasesMalformedTail: Bool = false
        ) -> String {
        var result = ""
        var cursor = line.startIndex
        if var active = state {
            active.continuationLineCount += 1
            while cursor < line.endIndex {
                let character = line[cursor]
                if let quote = active.quote {
                    if character == quote { active.quote = nil }
                } else if character == "\"" || character == "'" {
                    active.quote = character
                } else if character == ">" {
                    state = nil
                    cursor = line.index(after: cursor)
                    break
                }
                cursor = line.index(after: cursor)
            }
            if cursor == line.endIndex, state != nil {
                let wouldConsume = active.consumedCharacterCount + line.count
                if releasesMalformedTail {
                    state = nil
                    // A tag recognized on an earlier physical line remains
                    // structural metadata when its closing bracket is absent.
                    return ""
                }
                active.consumedCharacterCount = wouldConsume
                state = active
                return ""
            }
        }

        while cursor < line.endIndex {
            guard let opening = line[cursor...].firstIndex(of: "<") else {
                result += String(line[cursor...])
                break
            }
            result += String(line[cursor..<opening])
            if isInsideUnclosedInlineCode(at: opening, in: line) {
                result.append("<")
                cursor = line.index(after: opening)
                continue
            }
            var probe = line.index(after: opening)
            if probe < line.endIndex, line[probe] == "/" {
                probe = line.index(after: probe)
            }
            let nameStart = probe
            while probe < line.endIndex,
                line[probe].isLetter || line[probe].isNumber {
                probe = line.index(after: probe)
            }
            let originalName = String(line[nameStart..<probe])
            let name = originalName.lowercased()
            let boundaryIsValid = probe == line.endIndex
                || line[probe].isWhitespace
                || line[probe] == "/"
                || line[probe] == ">"
            let precedingIsToken = opening > line.startIndex
                && {
                    let preceding = line[line.index(before: opening)]
                    return preceding.isLetter || preceding.isNumber || preceding == "_"
            }()
            let voidNames: Set<String> = [
                "area", "base", "br", "col", "embed", "hr", "img", "input",
                "link", "meta", "source", "track", "wbr",
                ]
            let isUppercaseTagSpelling = originalName == originalName.uppercased()
                && originalName.contains(where: \Character.isLetter)
            let isUnambiguousLowercaseTagSpelling = originalName == name
                && name.count > 1
            let isCanonicalVoidSpelling = voidNames.contains(name)
                && (originalName == name || isUppercaseTagSpelling)
            let recognizesInlineTag = precedingIsToken == false
                || isUnambiguousLowercaseTagSpelling
                || isCanonicalVoidSpelling
            guard name.isEmpty == false,
                htmlTagNames.contains(name),
                boundaryIsValid,
                recognizesInlineTag else {
                result.append("<")
                cursor = line.index(after: opening)
                continue
            }

            var quote: Character?
            var end = probe
            while end < line.endIndex {
                let character = line[end]
                if let activeQuote = quote {
                    if character == activeQuote { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == ">" {
                    break
                }
                end = line.index(after: end)
            }
            if end < line.endIndex {
                // Preserve complete tags for removingHTMLPresentation.
                result += String(line[opening...end])
                cursor = line.index(after: end)
                continue
            }
            let heldCharacterCount = line.distance(
                from: opening,
                to: line.endIndex
                )
            if releasesMalformedTail {
                // Once a real HTML tag name and boundary are recognized, its
                // unfinished attribute tail is never semantic answer text.
                // Failing closed avoids terminal flashes such as
                // `title="...` while unrelated `<not really prose` remains
                // literal through the non-tag path above.
                return result
            }
            state = StreamingHTMLTagState(
                quote: quote,
                consumedCharacterCount: heldCharacterCount,
                continuationLineCount: 0
                )
            return result
        }
        return result
    }

    private static func shouldProtectBackslashes(in token: String) -> Bool {
        guard token.contains("\\") else { return false }
        if token.hasPrefix("\\\\") { return true }

        let characters = Array(token)
        if characters.count >= 3,
            characters[0].isLetter,
            characters[1] == ":",
            characters[2] == "\\" {
            return true
        }

        let regexEscapes = [
            "\\d", "\\D", "\\w", "\\W", "\\s", "\\S",
            "\\b", "\\B", "\\p", "\\P", "\\A", "\\Z",
            "\\z", "\\G", "\\k", "\\x", "\\u", "\\.",
            ]
        if regexEscapes.contains(where: token.contains) { return true }

        let structuralRegexEscapes = ["\\{", "\\}", "\\(", "\\)"]
        if (token.hasPrefix("^") || token.hasSuffix("$")),
            structuralRegexEscapes.contains(where: token.contains) {
            return true
        }

        return false
    }

    private static func projectingQuotedLiterals(
        in text: String,
        projectProse: (String) -> String
        ) -> String {
        var result = ""
        var cursor = text.startIndex
        var proseStart = cursor

        while cursor < text.endIndex {
            let quote = text[cursor]
            let isDoubleQuote = quote == "\""
            let isBoundarySingleQuote = quote == "'"
                && (cursor == text.startIndex
                || {
                    let previous = text[text.index(before: cursor)]
                    return previous.isLetter == false
                        && previous.isNumber == false
                }())
            guard (isDoubleQuote || isBoundarySingleQuote),
                isEscaped(at: cursor, in: text) == false,
                isInsideUnclosedAngleConstruct(
                    at: cursor,
                    in: text
                ) == false,
                isInsideUnclosedLinkDestination(
                    at: cursor,
                    in: text
                ) == false else {
                cursor = text.index(after: cursor)
                continue
            }

            var closing = text.index(after: cursor)
            while closing < text.endIndex {
                if text[closing] == quote,
                    isEscaped(at: closing, in: text) == false {
                    break
                }
                closing = text.index(after: closing)
            }
            guard closing < text.endIndex else {
                result += projectProse(String(text[proseStart..<cursor]))
                let preservesAsCode = isLikelyCodeStringLiteralOpening(
                    cursor,
                    in: text
                    )
                result += preservesAsCode
                    ? String(text[cursor...])
                    : projectProse(String(text[cursor...]))
                return result
            }
            result += projectProse(String(text[proseStart..<cursor]))
            let quoted = String(text[cursor...closing])
            if isLikelyCodeStringLiteral(
                opening: cursor,
                closing: closing,
                in: text
                ) {
                result += quoted
            } else {
                // Quotation marks are semantic prose, but Markdown/HTML inside
                // an ordinary quotation is still presentation syntax and must
                // cross the same plain-text boundary as surrounding text.
                result += projectProse(quoted)
            }
            cursor = text.index(after: closing)
            proseStart = cursor
        }

        result += projectProse(String(text[proseStart...]))
        return result
    }

    private static func isLikelyCodeStringLiteral(
        opening: String.Index,
        closing: String.Index,
        in text: String
        ) -> Bool {
        // Classification must depend on the already-seen opening context, not
        // on the character after the closing quote. Otherwise a cumulative
        // stream preserves the literal at `key="value"` and retracts it as
        // soon as the following space arrives.
        isLikelyCodeStringLiteralOpening(opening, in: text)
    }

    private static func isLikelyCodeStringLiteralOpening(
        _ opening: String.Index,
        in text: String
        ) -> Bool {
        guard opening > text.startIndex else { return false }
        let before = text[text.index(before: opening)]
        if "([{:,".contains(before) { return true }

        let keyword = text[..<opening]
            .trimmingCharacters(in: .whitespaces)
        return ["return", "throw", "await", "try"].contains(keyword)
    }

    private static func isInsideUnclosedAngleConstruct(
        at position: String.Index,
        in text: String
        ) -> Bool {
        var opening: String.Index?
        var quote: Character?
        var cursor = text.startIndex
        while cursor < position {
            let character = text[cursor]
            if opening != nil {
                if let activeQuote = quote {
                    if character == activeQuote { quote = nil }
                } else if character == "\"" || character == "'" {
                    quote = character
                } else if character == ">" {
                    opening = nil
                }
            } else if character == "<",
                isPotentialStreamingAngleConstruct(
                    at: cursor,
                    in: text
                ) {
                opening = cursor
            }
            cursor = text.index(after: cursor)
        }
        return opening != nil
    }

    private static func isInsideUnclosedLinkDestination(
        at position: String.Index,
        in text: String
        ) -> Bool {
        let prefix = text[..<position]
        guard let marker = prefix.range(of: "](", options: .backwards) else {
            return false
        }
        var depth = 1
        var quote: Character?
        var cursor = marker.upperBound
        while cursor < position {
            if text[cursor] == "\\" {
                cursor = text.index(after: cursor)
                if cursor < position { cursor = text.index(after: cursor) }
                continue
            }
            let character = text[cursor]
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 { return false }
            }
            cursor = text.index(after: cursor)
        }
        return depth > 0
    }

    private static func projectingInlineCode(
        in text: String,
        hidesIncompleteClosingRuns: Bool,
        projectText: (String) -> String
        ) -> String {
        var result = ""
        var cursor = text.startIndex
        var plainStart = cursor

        while cursor < text.endIndex {
            guard text[cursor] == "`",
                isEscaped(at: cursor, in: text) == false else {
                cursor = text.index(after: cursor)
                continue
            }

            let markerEnd = endOfRun(of: "`", from: cursor, in: text)
            let marker = String(text[cursor..<markerEnd])
            guard let closing = text.range(of: marker, range: markerEnd..<text.endIndex) else {
                result += projectText(String(text[plainStart..<cursor]))
                var visibleEnd = text.endIndex
                if hidesIncompleteClosingRuns {
                    var trailingStart = text.endIndex
                    while trailingStart > markerEnd {
                        let previous = text.index(before: trailingStart)
                        guard text[previous] == "`" else { break }
                        trailingStart = previous
                    }
                    let trailingLength = text.distance(
                        from: trailingStart,
                        to: text.endIndex
                        )
                    if trailingLength > 0, trailingLength < marker.count {
                        visibleEnd = trailingStart
                    }
                }
                result += String(text[markerEnd..<visibleEnd])
                return result
            }

            result += projectText(String(text[plainStart..<cursor]))
            result += String(text[markerEnd..<closing.lowerBound])
            cursor = closing.upperBound
            plainStart = cursor
        }

        result += projectText(String(text[plainStart...]))
        return result
    }

    private static func removingLinkDestinations(
        in text: String,
        referenceLinkLabels: Set<String>,
        buffersAmbiguousTrailingLink: Bool,
        preservesReferenceLinks: Bool,
        remainingLinkNestingDepth: Int
        ) -> String {
        var result = ""
        var cursor = text.startIndex

        func projectNestedLabel(_ value: String) -> String {
            guard remainingLinkNestingDepth > 0 else { return value }
            return projectInlinePresentation(
                value,
                referenceLinkLabels: referenceLinkLabels,
                remainingLinkNestingDepth: remainingLinkNestingDepth - 1
                )
        }

        while cursor < text.endIndex {
            let isImage = text[cursor] == "!"
                && isEscaped(at: cursor, in: text) == false
                && text.index(after: cursor) < text.endIndex
                && text[text.index(after: cursor)] == "["
            let isBracketOfEscapedImage = text[cursor] == "["
                && cursor > text.startIndex
                && text[text.index(before: cursor)] == "!"
                && isEscaped(at: text.index(before: cursor), in: text)
            let labelStart: String.Index
            if isImage {
                labelStart = text.index(cursor, offsetBy: 2)
            } else if text[cursor] == "[",
                    isBracketOfEscapedImage == false,
                    isEscaped(at: cursor, in: text) == false {
                labelStart = text.index(after: cursor)
            } else {
                result.append(text[cursor])
                cursor = text.index(after: cursor)
                continue
            }
            guard let labelEnd = balancedLinkLabelEnd(from: labelStart, in: text) else {
                let likelyPresentation = isImage
                    || isLikelyIncompleteLinkLabel(
                        opening: cursor,
                        labelStart: labelStart,
                        in: text
                    )
                    || (buffersAmbiguousTrailingLink
                    && isAdjacentTokenBracket(at: cursor, in: text))
                let bufferedLabel = text[labelStart...]
                if buffersAmbiguousTrailingLink,
                    likelyPresentation,
                    bufferedLabel.count <= 64 {
                    // The same cumulative prefix may become either a link or
                    // a literal bracket expression. Hold it behind the paced
                    // reveal until the next character proves which one; no
                    // already-visible glyph then needs to retract or reflow.
                    break
                } else if likelyPresentation {
                    // A cumulative stream should not briefly reveal '[' and
                    // then retract it when the destination arrives. Preserve
                    // a useful label for malformed final/legacy output.
                    result += projectNestedLabel(String(text[labelStart...]))
                } else {
                    result += String(text[cursor...])
                }
                break
            }

            let afterLabel = text.index(after: labelEnd)
            if afterLabel < text.endIndex, text[afterLabel] == "[" {
                let referenceStart = text.index(after: afterLabel)
                if preservesReferenceLinks || buffersAmbiguousTrailingLink {
                    result += String(text[cursor...labelEnd])
                    cursor = afterLabel
                    continue
                }
                guard isImage || isPresentationLinkBoundary(at: cursor, in: text),
                    let referenceEnd = firstUnescaped("]", from: referenceStart, in: text) else {
                    result += String(text[cursor...labelEnd])
                    cursor = afterLabel
                    continue
                }
                let rawReference = String(text[referenceStart..<referenceEnd])
                let resolvedReference = rawReference.isEmpty
                    ? normalizedReferenceLabel(String(text[labelStart..<labelEnd]))
                    : normalizedReferenceLabel(rawReference)
                guard referenceLinkLabels.contains(resolvedReference) else {
                    result += String(text[cursor...labelEnd])
                    cursor = afterLabel
                    continue
                }
                result += projectNestedLabel(String(text[labelStart..<labelEnd]))
                cursor = text.index(after: referenceEnd)
                continue
            }
            guard afterLabel < text.endIndex, text[afterLabel] == "(" else {
                let label = String(text[labelStart..<labelEnd])
                if buffersAmbiguousTrailingLink,
                    afterLabel == text.endIndex,
                    label.count <= 64,
                    (isImage
                    || isLikelyIncompleteLinkLabel(
                        opening: cursor,
                        labelStart: labelStart,
                        in: text
                        )
                    || isAdjacentTokenBracket(at: cursor, in: text)) {
                    cursor = afterLabel
                    continue
                }
                if isImage {
                    result += projectNestedLabel(label)
                } else if buffersAmbiguousTrailingLink,
                    label.count > 64,
                    isLikelyIncompleteLinkLabel(
                        opening: cursor,
                        labelStart: labelStart,
                        in: text
                    ) {
                    result += projectNestedLabel(label)
                } else {
                    result += String(text[cursor...labelEnd])
                }
                cursor = afterLabel
                continue
            }

            let destinationStart = text.index(after: afterLabel)
            let destinationEnd = balancedLinkDestinationEnd(
                from: destinationStart,
                in: text
                )
            let isAdjacentURLLink = destinationEnd.map { end in
                isLikelyLinkDestination(text[destinationStart..<end])
            } ?? false
            let isAdjacent = isImage == false
                && isPresentationLinkBoundary(at: cursor, in: text) == false
            if isAdjacent, buffersAmbiguousTrailingLink {
                let destinationPrefix = destinationEnd.map {
                    text[destinationStart..<$0]
                } ?? text[destinationStart...]
                let isLikelyURL = isAdjacentURLLink
                    || isLikelyAdjacentURLDestinationPrefix(destinationPrefix)
                if isLikelyURL {
                    if result.last?.isWhitespace == false { result.append(" ") }
                    result += projectNestedLabel(String(text[labelStart..<labelEnd]))
                    if let destinationEnd {
                        cursor = text.index(after: destinationEnd)
                        continue
                    }
                    break
                }
                if let destinationEnd {
                    result += String(text[cursor...destinationEnd])
                    cursor = text.index(after: destinationEnd)
                    continue
                }
                if text.distance(from: cursor, to: text.endIndex) > 96 {
                    result += String(text[cursor...])
                }
                break
            }
            if isAdjacent, isAdjacentURLLink == false {
                result += String(text[cursor...labelEnd])
                cursor = afterLabel
                continue
            }

            if isAdjacentURLLink,
                isPresentationLinkBoundary(at: cursor, in: text) == false,
                result.last?.isWhitespace == false {
                result.append(" ")
            }
            result += projectNestedLabel(String(text[labelStart..<labelEnd]))
            if let destinationEnd {
                let destination = text[destinationStart..<destinationEnd]
                if destination.count > 256,
                    isLikelyLinkDestinationPrefix(destination) == false {
                    if result.last?.isWhitespace == false { result.append(" ") }
                    result += projectNestedLabel(String(destination))
                }
                cursor = text.index(after: destinationEnd)
            } else {
                let malformedTail = text[destinationStart...]
                if malformedTail.count > 256,
                    isLikelyLinkDestinationPrefix(malformedTail) == false {
                    if result.last?.isWhitespace == false { result.append(" ") }
                    result += projectNestedLabel(String(malformedTail))
                }
                // Short unfinished URLs remain presentation metadata; a long
                // malformed tail is released above so useful prose cannot be
                // swallowed indefinitely.
                break
            }
        }
        return result
    }

    private static func isLikelyLinkDestination(_ raw: Substring) -> Bool {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if candidate.hasPrefix("<"), candidate.hasSuffix(">") {
            candidate = String(candidate.dropFirst().dropLast())
        }
        guard candidate.isEmpty == false else { return false }
        if candidate.hasPrefix("/") || candidate.hasPrefix("#")
            || candidate.hasPrefix("./") || candidate.hasPrefix("../") {
            return true
        }
        guard let colon = candidate.firstIndex(of: ":") else { return false }
        let scheme = candidate[..<colon]
        return scheme.count >= 2
            && scheme.first?.isLetter == true
            && scheme.allSatisfy {
                $0.isLetter || $0.isNumber || "+-.".contains($0)
        }
    }

    private static func isLikelyLinkDestinationPrefix(_ raw: Substring) -> Bool {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if candidate.hasPrefix("<") { candidate.removeFirst() }
        guard candidate.isEmpty == false else { return false }
        if let whitespace = candidate.firstIndex(where: \Character.isWhitespace) {
            let title = candidate[whitespace...]
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let opener = title.first, "\"'(".contains(opener) {
                return true
            }
        }
        if candidate.hasPrefix("/") || candidate.hasPrefix("#")
            || candidate.hasPrefix("./") || candidate.hasPrefix("../") {
            return true
        }
        let knownPrefixes = ["http://", "https://", "mailto:"]
        if knownPrefixes.contains(where: {
            $0.hasPrefix(candidate) || candidate.hasPrefix($0)
        }) {
            return true
        }
        guard let colon = candidate.firstIndex(of: ":") else {
            return candidate.contains(where: \Character.isWhitespace) == false
        }
        let scheme = candidate[..<colon]
        return scheme.count >= 2
            && scheme.first?.isLetter == true
            && scheme.allSatisfy {
                $0.isLetter || $0.isNumber || "+-.".contains($0)
        }
    }

    private static func isLikelyAdjacentURLDestinationPrefix(
        _ raw: Substring
        ) -> Bool {
        var candidate = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if candidate.hasPrefix("<") { candidate.removeFirst() }
        guard candidate.isEmpty == false else { return false }
        let knownPrefixes = ["http://", "https://", "mailto:"]
        if knownPrefixes.contains(where: {
                $0.hasPrefix(candidate) || candidate.hasPrefix($0)
            }) {
            return true
        }
        guard let colon = candidate.firstIndex(of: ":") else { return false }
        let scheme = candidate[..<colon]
        return scheme.count >= 2
            && scheme.first?.isLetter == true
            && scheme.allSatisfy {
                $0.isLetter || $0.isNumber || "+-.".contains($0)
        }
    }

    private static func isAdjacentTokenBracket(
        at opening: String.Index,
        in text: String
        ) -> Bool {
        guard opening > text.startIndex else { return false }
        let previous = text[text.index(before: opening)]
        return previous.isLetter || previous.isNumber
            || previous == "_" || previous == ")" || previous == "]"
    }

            /// Removes complete inline links selected by their visible label while
            /// honoring nested/escaped parentheses and quoted titles in destinations.
            /// Callers use this before generic prose cleanup so a removed citation
            /// cannot leave its URL or title behind as answer text.
            static func removingLinks(
                in text: String,
                where shouldRemoveLabel: (String) -> Bool
        ) -> String {
                var result = ""
                var cursor = text.startIndex
                while cursor < text.endIndex {
                    guard text[cursor] == "[" ,
                        isEscaped(at: cursor, in: text) == false else {
                        result.append(text[cursor])
                        cursor = text.index(after: cursor)
                        continue
            }
                    let labelStart = text.index(after: cursor)
                    guard let labelEnd = balancedLinkLabelEnd(
                        from: labelStart,
                        in: text
                ) else {
                        result += String(text[cursor...])
                        break
            }
                    let destinationOpening = text.index(after: labelEnd)
                    guard destinationOpening < text.endIndex,
                        text[destinationOpening] == "(" else {
                        result += String(text[cursor...labelEnd])
                        cursor = destinationOpening
                        continue
            }
                    let destinationStart = text.index(after: destinationOpening)
                    guard let destinationEnd = balancedLinkDestinationEnd(
                        from: destinationStart,
                        in: text
                ) else {
                        result += String(text[cursor...])
                        break
            }
                    let label = String(text[labelStart..<labelEnd])
                    if shouldRemoveLabel(label) == false {
                        result += String(text[cursor...destinationEnd])
            }
                    cursor = text.index(after: destinationEnd)
        }
                return result
    }
            private static func isLikelyIncompleteLinkLabel(
                opening: String.Index,
                labelStart: String.Index,
                in text: String
        ) -> Bool {
                guard labelStart < text.endIndex, text[labelStart].isLetter else { return false }
                guard opening > text.startIndex else { return true }
                let previous = text[text.index(before: opening)]
                return previous.isWhitespace
                    || ".,;:!?(){}<>\"'\"—".contains(previous)
    }

    private static func isPresentationLinkBoundary(
        at opening: String.Index,
        in text: String
        ) -> Bool {
        guard opening > text.startIndex else { return true }
        let previous = text[text.index(before: opening)]
        return previous.isWhitespace
            || ".,;:!?(){}<>\"'“”‘’—".contains(previous)
    }

    private static func balancedLinkDestinationEnd(
        from start: String.Index,
        in text: String
        ) -> String.Index? {
        var depth = 1
        var index = start
        var quote: Character?
        while index < text.endIndex {
            if text[index] == "\\" {
                index = text.index(after: index)
                if index < text.endIndex {
                    index = text.index(after: index)
                }
                continue
            }
            let character = text[index]
            if let activeQuote = quote {
                if character == activeQuote { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "(" {
                depth += 1
            } else if character == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func balancedLinkLabelEnd(
        from start: String.Index,
        in text: String
        ) -> String.Index? {
        var depth = 1
        var index = start
        while index < text.endIndex {
            if text[index] == "\\" {
                index = text.index(after: index)
                if index < text.endIndex {
                    index = text.index(after: index)
                }
                continue
            }
            if text[index] == "[" {
                depth += 1
            } else if text[index] == "]" {
                depth -= 1
                if depth == 0 { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func deescapingPresentationPunctuation(in text: String) -> String {
        let safePresentationPunctuation: Set<Character> = [
            "*", "_", "-", "#", ">", "-", "+", "!", "`",
            "[", "]", "(", ")",
            "<", ">", "{", "}", ":", ".", "=", "/", "?", "@",
            "$", "%", "^", ",", ";", "\\", "\"", "@",
            ]
        var result = ""
        var index = text.startIndex

        while index < text.endIndex {
            guard text[index] == "\\" else {
                result.append(text[index])
                index = text.index(after: index)
                continue
            }
            let next = text.index(after: index)
            guard next < text.endIndex, safePresentationPunctuation.contains(text[next]) else {
                result.append(text[index])
                index = next
                continue
            }
            result.append(
                escapedPresentationSentinels[text[next]] ?? text[next]
                )
            index = text.index(after: next)
        }
        return result
    }

    fileprivate static func protectingEscapedPresentationPunctuation(
        in text: String
        ) -> String {
        deescapingPresentationPunctuation(in: text)
    }

    fileprivate static func restoreEscapedPresentationPunctuation(
        in text: String
        ) -> String {
        let restored = Dictionary(
            escapedPresentationSentinels.map { ($0.value, $0.key) },
            uniquingKeysWith: { current, _ in current }
            )
        return String(text.map { restored[$0] ?? $0 })
    }

    fileprivate static func protectingLikelyDunderIdentifiers(
        in text: String
        ) -> String {
        guard let underscoreSentinel = escapedPresentationSentinels["_"] else {
            return text
        }
        let marker = "__"
        var result = ""
        var cursor = text.startIndex

        while let opening = text.range(of: marker, range: cursor..<text.endIndex) {
            let bodyStart = opening.upperBound
            guard let closing = text.range(
                of: marker,
                range: bodyStart..<text.endIndex
                ) else { break }
            let body = text[bodyStart..<closing.lowerBound]
            let before = opening.lowerBound > text.startIndex
                ? text[text.index(before: opening.lowerBound)]
                : nil
            let after = closing.upperBound < text.endIndex
                ? text[closing.upperBound]
                : nil
            let isIdentifier = isLikelyDunderIdentifier(body)
                && (before == nil
                    || (before?.isLetter == false
                        && before?.isNumber == false
                        && before != "_"))
                && (after == nil
                    || (after?.isLetter == false
                        && after?.isNumber == false
                        && after != "_"))

            result += String(text[cursor..<opening.lowerBound])
            if isIdentifier {
                result += String(repeating: String(underscoreSentinel), count: 2)
                result += body
                result += String(repeating: String(underscoreSentinel), count: 2)
            } else {
                result += String(text[opening.lowerBound..<closing.upperBound])
            }
            cursor = closing.upperBound
        }
        result += String(text[cursor...])
        return result
    }

    private static func removingPresentationDelimiter(
        _ delimiter: String,
        from text: String,
        hidesOpenDelimiter: Bool,
        preservesLiteralOperators: Bool
        ) -> String {
        var result = ""
        var cursor = text.startIndex

        while let opening = text.range(of: delimiter, range: cursor..<text.endIndex) {
            let before = opening.lowerBound > text.startIndex
                ? text[text.index(before: opening.lowerBound)]
                : nil
            let afterOpening = opening.upperBound < text.endIndex
                ? text[opening.upperBound]
                : nil
            let isPartOfLongerDelimiterRun = delimiter.count == 1
                && (before == delimiter.first || afterOpening == delimiter.first)
            let canOpen = afterOpening?.isWhitespace == false
                // Presentation delimiters may open at a word boundary, but an
                // unmatched intraword operator is literal data. Preserve math
                // and complexity notation such as `5*3`, `O(n*m)`, and `2**3`.
                && !(isLetterOrNumber(before) && isLetterOrNumber(afterOpening))
                && (delimiter.contains("_") == false || isLetterOrNumber(before) == false)
                && isPartOfLongerDelimiterRun == false
            guard canOpen else {
                result += String(text[cursor..<opening.upperBound])
                cursor = opening.upperBound
                continue
            }
            let searchRange = opening.upperBound..<text.endIndex
            guard let closing = text.range(of: delimiter, range: searchRange),
                closing.lowerBound > opening.upperBound else {
                result += String(text[cursor..<opening.lowerBound])
                if hidesOpenDelimiter {
                    let unresolvedBody = text[opening.upperBound...]
                    if hasSettledLiteralDelimiterPrefix(
                        unresolvedBody,
                        delimiter: delimiter
                        ) {
                        result += String(unresolvedBody)
                    } else if unresolvedBody.contains(where: \Character.isWhitespace) {
                        // Once the first semantic token has settled, revealing
                        // the body remains forward-only if presentation chrome
                        // later closes. A terminal literal correction is handled
                        // as one whole-view crossfade by the continuous reveal.
                        result += String(unresolvedBody)
                    }
                    return result
                } else if preservesLiteralOperators {
                    // A single unmatched marker is literal by CommonMark and
                    // may carry real model data (`*node`, `**argv`,
                    // `_internal`, `~~flags`). Provider output has explicit
                    // plain-text provenance, so preserve it there.
                    result += String(text[opening.lowerBound...])
                } else {
                    // Legacy/Markdown projection treats an unmatched opener
                    // as truncated presentation and keeps only useful text,
                    // preventing raw chrome from entering copy/cache output.
                    result += String(text[opening.upperBound...])
                }
                return result
            }
            let beforeClosing = text[text.index(before: closing.lowerBound)]
            let afterClosing = closing.upperBound < text.endIndex
                ? text[closing.upperBound]
                : nil
            let canClose = beforeClosing.isWhitespace == false
                && (delimiter != "_" || isLetterOrNumber(afterClosing) == false)
            guard canClose else {
                result += String(text[cursor..<opening.upperBound])
                cursor = opening.upperBound
                continue
            }

            let delimitedBody = text[opening.upperBound..<closing.lowerBound]
            if delimiter == "_",
                preservesLiteralOperators,
                isLikelyDunderIdentifier(delimitedBody) {
                // Foundation Models is asked for plain text. A compact token
                // such as `__init__`, `__name__`, or `__main__` is therefore
                // much more likely to be a literal identifier than legacy
                // emphasis. Retain its spelling at the canonical boundary.
                result += String(text[cursor..<closing.upperBound])
                cursor = closing.upperBound
                continue
            }

            result += String(text[cursor..<opening.lowerBound])
            result += String(text[opening.upperBound..<closing.lowerBound])
            cursor = closing.upperBound
        }

        result += String(text[cursor...])
        return result
    }

    private static func isLetterOrNumber(_ character: Character?) -> Bool {
        guard let character else { return false }
        return character.isLetter || character.isNumber
    }

    private static func isLikelyDunderIdentifier(_ body: Substring) -> Bool {
        guard body.isEmpty == false else { return false }
        return body.allSatisfy { character in
            character.isLetter || character.isNumber || character == "_"
        }
    }

    private static func hasSettledLiteralDelimiterPrefix(
        _ body: Substring,
        delimiter: String
        ) -> Bool {
        guard let first = body.first, first.isWhitespace == false else {
            return false
        }
        guard let boundary = body.firstIndex(where: \Character.isWhitespace) else {
            return false
        }
        let token = String(body[..<boundary]).lowercased()
        switch delimiter {
            case "*":
            return token.hasPrefix("*")
                || ["node", "ptr", "pointer"].contains(token)
            case "_":
            return ["internal", "private"].contains(token)
            case "**":
            return ["argv", "kwargs", "ptr", "pointer"].contains(token)
            case "~~":
            return ["flags", "mask"].contains(token)
            default:
            return false
        }
    }

    private static func endOfRun(
        of character: Character,
        from start: String.Index,
        in text: String
        ) -> String.Index {
        var index = start
        while index < text.endIndex, text[index] == character {
            index = text.index(after: index)
        }
        return index
    }

    private static func firstUnescaped(
        _ character: Character,
        from start: String.Index,
        in text: String
        ) -> String.Index? {
        var index = start
        while index < text.endIndex {
            if text[index] == character {
                var slashCount = 0
                var probe = index
                while probe > text.startIndex {
                    let previous = text.index(before: probe)
                    guard text[previous] == "\\" else { break }
                    slashCount += 1
                    probe = previous
                }
                if slashCount.isMultiple(of: 2) { return index }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func isEscaped(
        at index: String.Index,
        in text: String
        ) -> Bool {
        var slashCount = 0
        var probe = index
        while probe > text.startIndex {
            let previous = text.index(before: probe)
            guard text[previous] == "\\" else { break }
            slashCount += 1
            probe = previous
        }
        return slashCount.isMultiple(of: 2) == false
    }
}

enum AssistantMarkdownTextStyle {
    case paragraph
    case heading1
    case heading2
    case heading3
    case bulletedItem
    case numberedItem
    case quote
}

private extension AssistantMarkdownTextStyle {
    var isListItem: Bool {
        switch self {
            case .bulletedItem, .numberedItem:
            true
            case .paragraph, .heading1, .heading2, .heading3, .quote:
            false
        }
    }
}

struct AssistantMarkdownTextBlock {
    var style: AssistantMarkdownTextStyle
    var text: AssistantMarkdownRichText
}

struct AssistantMarkdownChecklistBlock {
    var text: AssistantMarkdownRichText
    var isChecked: Bool
}

struct AssistantMarkdownCodeBlock {
    var language: String
    var code: String
}

enum AssistantMarkdownBlockContent {
    case text(AssistantMarkdownTextBlock)
    case checklist(AssistantMarkdownChecklistBlock)
    case divider
    case code(AssistantMarkdownCodeBlock)
}

    struct AssistantMarkdownBlock: Identifiable {
        let id: UUID
        var content: AssistantMarkdownBlockContent
        init(id: UUID = UUID(), content: AssistantMarkdownBlockContent) {
            self.id = id
            self.content = content
    }

        static func paragraph(_ text: String = "") -> AssistantMarkdownBlock {
            AssistantMarkdownBlock(
                content: .text(
                    AssistantMarkdownTextBlock(
                        style: .paragraph,
                        text: AssistantMarkdownRichText(text)
                    )
                )
            )
    }
}

    /// Converts the response Markdown surface into native, display-only blocks.
    /// The parser is deliberately local and deterministic: it does not resolve
    /// remote images or arbitrary HTML.
    enum AssistantMarkdownParser {
        static func parse(_ markdown: String) -> [AssistantMarkdownBlock] {
            let normalized = markdown
                .replacingOccurrences(of: "\r\n", with: "\n")
                .replacingOccurrences(of: "\r", with: "\n")
            let lines = normalized.split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            var blocks: [AssistantMarkdownBlock] = []
            var paragraphLines: [String] = []
            var lineIndex = 0
            func flushParagraph() {
                let body = paragraphLines
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { $0.isEmpty == false }
                    .joined(separator: " ")
                paragraphLines.removeAll(keepingCapacity: true)
                guard body.isEmpty == false else { return }
                blocks.append(textBlock(style: .paragraph, markdown: body))
        }
            while lineIndex < lines.count {
                let rawLine = lines[lineIndex]
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                if let fence = fenceOpening(in: line) {
                    flushParagraph()
                    lineIndex += 1
                    var codeLines: [String] = []
                    while lineIndex < lines.count,
                        isFenceClosing(
                            lines[lineIndex],
                            marker: fence.marker,
                            minimumLength: fence.length
                    ) == false {
                        codeLines.append(lines[lineIndex])
                        lineIndex += 1
                }
                    if lineIndex < lines.count { lineIndex += 1 }
                blocks.append(
                    AssistantMarkdownBlock(
                        content: .code(
                            AssistantMarkdownCodeBlock(
                                language: displayLanguage(for: fence.language),
                                code: codeLines.joined(separator: "\n")
                                )
                            )
                        )
                    )
                continue
            }
            guard line.isEmpty == false else {
                flushParagraph()
                lineIndex += 1
                continue
            }
            if let heading = heading(in: line) {
                flushParagraph()
                blocks.append(textBlock(style: heading.style, markdown: heading.body))
            } else if let checklist = checklist(in: line) {
                flushParagraph()
                blocks.append(
                    AssistantMarkdownBlock(
                        content: .checklist(
                            AssistantMarkdownChecklistBlock(
                                text: richText(from: checklist.body),
                                isChecked: checklist.isChecked
                                )
                            )
                        )
                    )
            } else if let body = bulletBody(in: line) {
                flushParagraph()
                blocks.append(textBlock(style: .bulletedItem, markdown: body))
            } else if let body = numberedBody(in: line) {
                flushParagraph()
                blocks.append(textBlock(style: .numberedItem, markdown: body))
            } else if let body = quoteBody(in: line) {
                flushParagraph()
                blocks.append(textBlock(style: .quote, markdown: body))
            } else if isDivider(line) {
                flushParagraph()
                blocks.append(AssistantMarkdownBlock(content: .divider))
            } else {
                paragraphLines.append(rawLine)
            }
            lineIndex += 1
        }
        flushParagraph()
        return blocks
    }

    private static func richText(from markdown: String) -> AssistantMarkdownRichText {
        do {
            let dunderProtected = AssistantMarkdownProjection
                .protectingLikelyDunderIdentifiers(in: markdown)
            let verbatimProtected = AssistantMarkdownProjection
                .protectVerbatimBackslashes(in: dunderProtected)
            let protectedMarkdown = AssistantMarkdownProjection
                .protectingEscapedPresentationPunctuation(in: verbatimProtected)
            let attributed = try AttributedString(
                markdown: protectedMarkdown,
                options: .init(
                    interpretedSyntax: .inlineOnlyPreservingWhitespace,
                    failurePolicy: .returnPartiallyParsedIfPossible
                    )
                )
            var runs: [AssistantMarkdownTextRun] = []
            for run in attributed.runs {
                let parsedValue = AssistantMarkdownProjection.restoreVerbatimBackslashes(
                    in: String(attributed[run.range].characters)
                    )
                var styles: Set<AssistantMarkdownInlineStyle> = []
                if let intent = run.inlinePresentationIntent {
                    if intent.contains(.stronglyEmphasized) { styles.insert(.bold) }
                    if intent.contains(.emphasized) { styles.insert(.italic) }
                    if intent.contains(.strikethrough) { styles.insert(.strikethrough) }
                    if intent.contains(.code) { styles.insert(.code) }
                }
                // Foundation Models can stop between the opening and closing
                // delimiter of an inline construct. AttributedString's
                // partial-parse mode correctly preserves the text, but may
                // also preserve that unfinished presentation punctuation.
                // Project only unstyled/unlinked runs so literal code and
                // successfully parsed emphasis keep their native semantics.
                let projected = styles.isEmpty && run.link == nil
                    ? AssistantMarkdownProjection.projectInlinePresentation(
                        parsedValue,
                        hidesOpenDelimiter: false,
                        preservesLiteralOperators: true
                    )
                    : parsedValue
                let value = AssistantMarkdownProjection
                    .restoreEscapedPresentationPunctuation(in: projected)
                guard value.isEmpty == false else { continue }
                appendRun(
                    AssistantMarkdownTextRun(text: value, styles: styles, link: run.link),
                    to: &runs
                    )
            }
            return AssistantMarkdownRichText(runs: runs)
        } catch {
            return AssistantMarkdownRichText(
                AssistantMarkdownProjection.projectInlinePresentation(
                    markdown,
                    hidesOpenDelimiter: false,
                    preservesLiteralOperators: true
                    )
                )
        }
    }

    private static func textBlock(
        style: AssistantMarkdownTextStyle,
        markdown: String
        ) -> AssistantMarkdownBlock {
        AssistantMarkdownBlock(
            content: .text(
                AssistantMarkdownTextBlock(style: style, text: richText(from: markdown))
                )
            )
    }

    private static func appendRun(
        _ run: AssistantMarkdownTextRun,
        to runs: inout [AssistantMarkdownTextRun]
        ) {
        if let lastIndex = runs.indices.last,
            runs[lastIndex].styles == run.styles,
            runs[lastIndex].link == run.link {
            runs[lastIndex].text += run.text
        } else {
            runs.append(run)
        }
    }

    fileprivate static func heading(
        in line: String
        ) -> (style: AssistantMarkdownTextStyle, body: String)? {
        guard line.hasPrefix("\\#") == false else { return nil }
        let candidate = line
        let markerCount = candidate.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(markerCount), candidate.count > markerCount else { return nil }
        let boundary = candidate.index(candidate.startIndex, offsetBy: markerCount)
        guard candidate[boundary].isWhitespace else { return nil }
        let bodyStart = candidate.index(after: boundary)
        let style: AssistantMarkdownTextStyle = switch markerCount {
            case 1: .heading1
            case 2: .heading2
            default: .heading3
        }
        var body = String(candidate[bodyStart...])
        if let trailingHashes = body.range(
            of: #"\s+#\s*$"#,
            options: .regularExpression
            ) {
            body.removeSubrange(trailingHashes)
        }
        return (style, body)
    }

    static func checklist(in line: String) -> (isChecked: Bool, body: String)? {
        let prefixes: [(String, Bool)] = [
            ("- [ ] ", false), ("* [ ] ", false), ("+ [ ] ", false),
            ("• [ ] ", false),
            ("- [x] ", true), ("* [x] ", true), ("+ [x] ", true),
            ("• [x] ", true),
            ("- [X] ", true), ("* [X] ", true), ("+ [X] ", true),
            ("• [X] ", true),
            ]
        guard line.hasPrefix("\\-") == false,
            line.hasPrefix("\\*") == false,
            line.hasPrefix("\\+") == false else { return nil }
        let candidate = line
        for (prefix, isChecked) in prefixes where candidate.hasPrefix(prefix) {
            return (isChecked, String(candidate.dropFirst(prefix.count)))
        }
        return nil
    }

    static func bulletBody(in line: String) -> String? {
        guard line.hasPrefix("\\-") == false,
            line.hasPrefix("\\*") == false,
            line.hasPrefix("\\+") == false else { return nil }
        let candidate = line
        for prefix in ["- ", "* ", "+ ", "• "] where candidate.hasPrefix(prefix) {
            return String(candidate.dropFirst(prefix.count))
        }
        return nil
    }

    static func numberedBody(in line: String) -> String? {
        guard let numberEnd = line.firstIndex(where: { $0.isNumber == false }),
            numberEnd != line.startIndex else { return nil }
        // A long leading number is overwhelmingly more likely to be semantic
        // data (most commonly a year) than an ordered-list ordinal. Treating
        // '2024. Revenue grew' as list chrome would discard the year at the
        // final render, copy, accessibility, and cache boundaries.
        let digitCount = line.distance(from: line.startIndex, to: numberEnd)
        guard digitCount <= 3 else { return nil }
        let delimiter = numberEnd
        if line[delimiter] == "\\" {
            return nil
        }
        guard line[delimiter] == "." || line[delimiter] == ")" else { return nil }
        let afterDelimiter = line.index(after: delimiter)
        guard afterDelimiter < line.endIndex,
            line[afterDelimiter].isWhitespace else { return nil }
        let bodyStart = line.index(after: afterDelimiter)
        return String(line[bodyStart...])
    }

    fileprivate static func quoteBody(in line: String) -> String? {
        guard line.hasPrefix("\\>") == false else { return nil }
        let candidate = line
        guard candidate.hasPrefix(">") else { return nil }
        return String(candidate.dropFirst())
            .trimmingCharacters(in: .whitespaces)
    }

    fileprivate static func isDivider(_ line: String) -> Bool {
        let compact = line.filter { $0.isWhitespace == false }
        guard compact.count >= 3, let marker = compact.first,
            marker == "-" || marker == "*" || marker == "_" else { return false }
        return compact.allSatisfy { $0 == marker }
    }

    static func fenceOpening(
        in line: String
        ) -> (marker: Character, length: Int, language: String)? {
        guard line.hasPrefix("```") || line.hasPrefix("~~~") else { return nil }
        let marker = line.first ?? "\""
        let length = line.prefix(while: { $0 == marker }).count
        let language = String(line.dropFirst(length))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (marker, length, language)
    }

    static func isFenceClosing(
        _ line: String,
        marker: Character,
        minimumLength: Int = 3
        ) -> Bool {
        let compact = line.trimmingCharacters(in: .whitespaces)
        return compact.count >= minimumLength && compact.allSatisfy { $0 == marker }
    }

    private static func displayLanguage(for markdownLabel: String) -> String {
        let normalized = markdownLabel.lowercased()
        return switch normalized {
            case "": "Plain Text"
            case "swift": "Swift"
            case "python", "py": "Python"
            case "javascript", "js": "JavaScript"
            case "typescript", "ts": "TypeScript"
            case "json": "JSON"
            case "html": "HTML"
            case "css": "CSS"
            case "sql": "SQL"
            default: markdownLabel
        }
    }
}