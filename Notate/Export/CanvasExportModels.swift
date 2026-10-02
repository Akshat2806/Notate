import Foundation

public enum CanvasExportFormat: String, CaseIterable, Identifiable, Sendable {
    case pdf
    case images

    public var id: Self { self }

    public var title: String {
        switch self {
        case .pdf: "PDF"
        case .images: "Image"
        }
    }

    public var systemImage: String {
        switch self {
        case .pdf: "doc.text"
        case .images: "photo.stack"
        }
    }
}

public struct CanvasExportDocument: Identifiable, Sendable {
    public let id: UUID
    public let pages: [CanvasPageSnapshot]

    public init(id: UUID = UUID(), pages: [CanvasPageSnapshot]) {
        self.id = id
        self.pages = pages
    }

    public func selectedPages(pageIDs: Set<UUID>) -> [CanvasExportPage] {
        pages.enumerated().compactMap { index, page in
            guard pageIDs.contains(page.id) else { return nil }
            return CanvasExportPage(sourcePageNumber: index + 1, snapshot: page)
        }
    }
}

public struct CanvasExportPage: Sendable {
    public let sourcePageNumber: Int
    public let snapshot: CanvasPageSnapshot

    public init(sourcePageNumber: Int, snapshot: CanvasPageSnapshot) {
        self.sourcePageNumber = sourcePageNumber
        self.snapshot = snapshot
    }
}

public struct CanvasExportArtifact: Identifiable, Sendable {
    public let id: UUID
    public let format: CanvasExportFormat
    public let urls: [URL]
    public let temporaryDirectory: URL

    public init(
        id: UUID = UUID(),
        format: CanvasExportFormat,
        urls: [URL],
        temporaryDirectory: URL
    ) {
        self.id = id
        self.format = format
        self.urls = urls
        self.temporaryDirectory = temporaryDirectory
    }

    public func removeTemporaryFiles() {
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }
}

public enum CanvasPageRangeError: Error, Equatable, LocalizedError, Sendable {
    case empty
    case malformed(String)
    case descending(String)
    case outsideDocument(page: Int, pageCount: Int)

    public var errorDescription: String? {
        switch self {
        case .empty:
            "Enter at least one page number."
        case let .malformed(value):
            "\"\(value)\" isn't a valid page or range. Try something like 1–3, 5."
        case let .descending(value):
            "\"\(value)\" needs to run from the lower page to the higher page."
        case let .outsideDocument(page, pageCount):
            "Page \(page) is outside this document's 1–\(pageCount) range."
        }
    }
}

public enum CanvasPageRangeParser {
    /// Parses one-based pages and inclusive ranges into zero-based document indices.
    public static func parse(_ value: String, pageCount: Int) throws -> IndexSet {
        let normalized = value
            .replacingOccurrences(of: "\u{2013}", with: "-")
            .replacingOccurrences(of: "\u{2014}", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.isEmpty == false else { throw CanvasPageRangeError.empty }

        let rawTokens = normalized.split(separator: ",", omittingEmptySubsequences: false)
        var result = IndexSet()

        for rawToken in rawTokens {
            let token = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
            guard token.isEmpty == false else {
                throw CanvasPageRangeError.malformed(String(rawToken))
            }

            let components = token.split(separator: "-", omittingEmptySubsequences: false)
            switch components.count {
            case 1:
                let page = try parsePage(String(components[0]), token: token, pageCount: pageCount)
                result.insert(page - 1)

            case 2:
                let lower = try parsePage(
                    String(components[0]),
                    token: token,
                    pageCount: pageCount
                )
                let upper = try parsePage(
                    String(components[1]),
                    token: token,
                    pageCount: pageCount
                )
                guard lower <= upper else { throw CanvasPageRangeError.descending(token) }
                result.insert(integersIn: (lower - 1)...(upper - 1))

            default:
                throw CanvasPageRangeError.malformed(token)
            }
        }

        guard result.isEmpty == false else { throw CanvasPageRangeError.empty }
        return result
    }

    public static func formattedSelection(
        pageIDs: Set<UUID>,
        in pages: [CanvasPageSnapshot]
    ) -> String {
        let selectedNumbers = pages.enumerated().compactMap { index, page in
            pageIDs.contains(page.id) ? index + 1 : nil
        }

        guard let first = selectedNumbers.first else { return "" }

        var groups: [String] = []
        var rangeStart = first
        var previous = first

        for page in selectedNumbers.dropFirst() {
            if page == previous + 1 {
                previous = page
                continue
            }
            groups.append(formatRange(from: rangeStart, through: previous))
            rangeStart = page
            previous = page
        }
        groups.append(formatRange(from: rangeStart, through: previous))
        return groups.joined(separator: ", ")
    }

    private static func parsePage(
        _ value: String,
        token: String,
        pageCount: Int
    ) throws -> Int {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let page = Int(trimmed), trimmed.isEmpty == false else {
            throw CanvasPageRangeError.malformed(token)
        }
        guard pageCount > 0, (1...pageCount).contains(page) else {
            throw CanvasPageRangeError.outsideDocument(page: page, pageCount: max(pageCount, 0))
        }
        return page
    }

    private static func formatRange(from lower: Int, through upper: Int) -> String {
        lower == upper ? "\(lower)" : "\(lower)-\(upper)"
    }
}

public enum CanvasExportError: Error, Equatable, LocalizedError, Sendable {
    case noPagesSelected
    case invalidSourcePageNumber(Int)
    case duplicateSourcePageNumber(Int)
    case canvasUnavailable
    case graphicsContextUnavailable
    case rasterSurfaceTooLarge(
        width: Int,
        height: Int,
        maximumDimension: Int,
        maximumPixelCount: Int
    )
    case aggregateTileLimitExceeded(maximum: Int)
    case aggregateRasterPixelLimitExceeded(maximum: Int)
    case backgroundRenderingFailed
    case imageEncodingFailed(page: Int)
    case outputValidationFailed
    case fileSystem(String)

    public var errorDescription: String? {
        switch self {
        case .noPagesSelected:
            "Select at least one page to export."
        case let .invalidSourcePageNumber(page):
            "Page number \(page) isn't valid for export."
        case let .duplicateSourcePageNumber(page):
            "Page \(page) was selected more than once."
        case .canvasUnavailable:
            "The latest canvas content couldn't be prepared for export."
        case .graphicsContextUnavailable:
            "Notate couldn't create the export graphics context."
        case let .rasterSurfaceTooLarge(width, height, maximumDimension, _):
            "The requested \(width)×\(height) image is too large for one safe export surface. Notate can export it as tiles up to \(maximumDimension) pixels per side."
        case let .aggregateTileLimitExceeded(maximum):
            "This export would create too many image files or PDF pages. Select fewer pages or a smaller range; Notate supports up to \(maximum.formatted()) export tiles at once."
        case let .aggregateRasterPixelLimitExceeded(maximum):
            "This image export is too large to create safely. Select fewer or smaller pages, or use PDF; Notate supports up to \(maximum.formatted()) pixels in one image export."
        case .backgroundRenderingFailed:
            "An imported page background couldn't be rendered, so Notate stopped instead of exporting a blank page."
        case let .imageEncodingFailed(page):
            "Page \(page) couldn't be encoded as an image."
        case .outputValidationFailed:
            "Notate created an export file but couldn't verify that it was complete."
        case let .fileSystem(reason):
            "The export files couldn't be created. \(reason)"
        }
    }
}
