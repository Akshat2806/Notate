import PDFKit
import PaperKit
import UIKit

public enum CanvasDocumentImportError: Error, LocalizedError, Sendable {
    case emptyFile
    case sourceIsNotRegularFile
    case sourceFileTooLarge(actualBytes: Int, maximumBytes: Int)
    case unreadableImage
    case unreadablePDF
    case lockedPDF
    case emptyPDF
    case tooManyPDFPages(actual: Int, maximum: Int)
    case invalidPage(Int)
    case pdfPageTooLarge(page: Int, width: Double, height: Double, maximum: Double)
    case pdfTextTooLarge(maximumBytes: Int)

    public var errorDescription: String? {
        switch self {
        case .emptyFile:
            return "The selected file is empty."
        case .sourceIsNotRegularFile:
            return "The selected item is not a regular file and cannot be imported."
        case let .sourceFileTooLarge(actualBytes, maximumBytes):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "The selected file is \(formatter.string(fromByteCount: Int64(actualBytes))). The maximum supported file size is \(formatter.string(fromByteCount: Int64(maximumBytes)))."
        case .unreadableImage:
            return "The selected image could not be decoded."
        case .unreadablePDF:
            return "The selected PDF could not be opened."
        case .lockedPDF:
            return "Password-protected PDFs must be unlocked before they can be imported."
        case .emptyPDF:
            return "The selected PDF has no pages."
        case let .tooManyPDFPages(actual, maximum):
            return "The selected PDF has \(actual.formatted()) pages. Notate supports up to \(maximum.formatted()) pages in one imported PDF."
        case let .invalidPage(number):
            return "Page \(number) has invalid dimensions."
        case let .pdfPageTooLarge(page, width, height, maximum):
            let wholePoints = FloatingPointFormatStyle<Double>.number
                .precision(.fractionLength(0))
            return "Page \(page) is \(width.formatted(wholePoints)) by \(height.formatted(wholePoints)) points. PDF pages must be no larger than \(maximum.formatted(wholePoints)) points per side."
        case let .pdfTextTooLarge(maximumBytes):
            let formatter = ByteCountFormatter()
            formatter.countStyle = .file
            return "The selected PDF contains more than \(formatter.string(fromByteCount: Int64(maximumBytes))) of searchable text. Split the PDF into smaller documents and try again."
        }
    }
}

/// Admission limits shared by library file loading and direct document
/// importer callers. Encoded bytes are bounded before allocation; structural
/// PDF limits keep page-stack construction and native-text extraction finite.
struct CanvasDocumentIngestionPolicy: Sendable, Equatable {
    static let canvasDefault = CanvasDocumentIngestionPolicy(
        maximumPDFEncodedByteCount: 128 * 1_024 * 1_024,
        maximumAttachmentEncodedByteCount: 128 * 1_024 * 1_024,
        maximumPDFPageCount: 1_000,
        maximumPDFPageDimension: 14_400,
        maximumPDFNativeTextByteCount: 8 * 1_024 * 1_024
    )

    let maximumPDFEncodedByteCount: Int
    let maximumAttachmentEncodedByteCount: Int
    let maximumPDFPageCount: Int
    let maximumPDFPageDimension: CGFloat
    let maximumPDFNativeTextByteCount: Int

    init(
        maximumPDFEncodedByteCount: Int,
        maximumAttachmentEncodedByteCount: Int,
        maximumPDFPageCount: Int,
        maximumPDFPageDimension: CGFloat,
        maximumPDFNativeTextByteCount: Int
    ) {
        precondition(maximumPDFEncodedByteCount > 0)
        precondition(maximumAttachmentEncodedByteCount > 0)
        precondition(maximumPDFPageCount > 0)
        precondition(maximumPDFPageDimension.isFinite && maximumPDFPageDimension > 0)
        precondition(maximumPDFNativeTextByteCount > 0)
        self.maximumPDFEncodedByteCount = maximumPDFEncodedByteCount
        self.maximumAttachmentEncodedByteCount = maximumAttachmentEncodedByteCount
        self.maximumPDFPageCount = maximumPDFPageCount
        self.maximumPDFPageDimension = maximumPDFPageDimension
        self.maximumPDFNativeTextByteCount = maximumPDFNativeTextByteCount
    }
}

/// Reads a regular file without trusting a mutable preflight size. The second
/// in-stream count closes the grow-after-stat window without ever allocating
/// beyond the caller's admission ceiling.
enum CanvasBoundedFileReader {
    private static let chunkByteCount = 1_024 * 1_024

    static func read(
        from url: URL,
        maximumByteCount: Int
    ) throws -> Data {
        guard maximumByteCount > 0 else {
            throw CanvasDocumentImportError.sourceFileTooLarge(
                actualBytes: 0,
                maximumBytes: max(maximumByteCount, 0)
            )
        }
        let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard values.isRegularFile == true,
              let advertisedByteCount = values.fileSize,
              advertisedByteCount >= 0 else {
            throw CanvasDocumentImportError.sourceIsNotRegularFile
        }
        guard advertisedByteCount <= maximumByteCount else {
            throw CanvasDocumentImportError.sourceFileTooLarge(
                actualBytes: advertisedByteCount,
                maximumBytes: maximumByteCount
            )
        }

        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var result = Data()
        result.reserveCapacity(advertisedByteCount)
        var byteCount = 0
        while let chunk = try handle.read(upToCount: chunkByteCount), chunk.isEmpty == false {
            try Task.checkCancellation()
            let (nextByteCount, overflow) = byteCount.addingReportingOverflow(chunk.count)
            guard overflow == false, nextByteCount <= maximumByteCount else {
                throw CanvasDocumentImportError.sourceFileTooLarge(
                    actualBytes: overflow ? Int.max : nextByteCount,
                    maximumBytes: maximumByteCount
                )
            }
            result.append(chunk)
            byteCount = nextByteCount
        }
        return result
    }
}

struct CanvasValidatedPDF {
    let document: PDFDocument
    let pageSizes: [CGSize]
    let nativeText: String
}

/// Swift 6.3 deliberately disallows direct thread inspection from an async
/// context. Keep the optional executor regression observation synchronous;
/// production behavior does not otherwise depend on thread identity.
private func canvasImportWorkerIsMainThread() -> Bool {
    Thread.isMainThread
}

enum CanvasPDFSourceValidator {
    static func validate(
        data: Data,
        policy: CanvasDocumentIngestionPolicy = .canvasDefault
    ) throws -> CanvasValidatedPDF {
        guard data.isEmpty == false else { throw CanvasDocumentImportError.emptyFile }
        guard data.count <= policy.maximumPDFEncodedByteCount else {
            throw CanvasDocumentImportError.sourceFileTooLarge(
                actualBytes: data.count,
                maximumBytes: policy.maximumPDFEncodedByteCount
            )
        }
        guard let document = PDFDocument(data: data) else {
            throw CanvasDocumentImportError.unreadablePDF
        }
        guard document.isLocked == false else { throw CanvasDocumentImportError.lockedPDF }
        guard document.pageCount > 0 else { throw CanvasDocumentImportError.emptyPDF }
        guard document.pageCount <= policy.maximumPDFPageCount else {
            throw CanvasDocumentImportError.tooManyPDFPages(
                actual: document.pageCount,
                maximum: policy.maximumPDFPageCount
            )
        }

        var pageSizes: [CGSize] = []
        pageSizes.reserveCapacity(document.pageCount)
        var textSegments: [String] = []
        textSegments.reserveCapacity(document.pageCount)
        var nativeTextByteCount = 0

        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else {
                throw CanvasDocumentImportError.invalidPage(index + 1)
            }
            let cropBounds = page.bounds(for: .cropBox)
            let sourceBounds = cropBounds.isNull || cropBounds.isEmpty
                ? page.bounds(for: .mediaBox)
                : cropBounds
            let size = CanvasDocumentImporter.normalizedPDFPageSize(
                sourceBounds.size,
                intrinsicRotation: page.rotation
            )
            guard size.width.isFinite,
                  size.height.isFinite,
                  size.width > 0,
                  size.height > 0 else {
                throw CanvasDocumentImportError.invalidPage(index + 1)
            }
            guard size.width <= policy.maximumPDFPageDimension,
                  size.height <= policy.maximumPDFPageDimension else {
                throw CanvasDocumentImportError.pdfPageTooLarge(
                    page: index + 1,
                    width: Double(size.width),
                    height: Double(size.height),
                    maximum: Double(policy.maximumPDFPageDimension)
                )
            }
            pageSizes.append(size)

            let separatorByteCount = textSegments.isEmpty ? 0 : 1
            let (withSeparator, separatorOverflow) = nativeTextByteCount
                .addingReportingOverflow(separatorByteCount)
            guard separatorOverflow == false,
                  withSeparator <= policy.maximumPDFNativeTextByteCount else {
                throw CanvasDocumentImportError.pdfTextTooLarge(
                    maximumBytes: policy.maximumPDFNativeTextByteCount
                )
            }
            let remainingTextByteCount = policy.maximumPDFNativeTextByteCount
                - withSeparator
            let characterCount = page.numberOfCharacters
            guard characterCount >= 0,
                  characterCount <= remainingTextByteCount else {
                throw CanvasDocumentImportError.pdfTextTooLarge(
                    maximumBytes: policy.maximumPDFNativeTextByteCount
                )
            }
            let pageText = page.string ?? ""
            let (nextTextByteCount, textOverflow) = withSeparator
                .addingReportingOverflow(pageText.utf8.count)
            guard textOverflow == false,
                  nextTextByteCount <= policy.maximumPDFNativeTextByteCount else {
                throw CanvasDocumentImportError.pdfTextTooLarge(
                    maximumBytes: policy.maximumPDFNativeTextByteCount
                )
            }
            nativeTextByteCount = nextTextByteCount
            textSegments.append(pageText)
        }

        return CanvasValidatedPDF(
            document: document,
            pageSizes: pageSizes,
            nativeText: textSegments.joined(separator: "\n")
        )
    }
}

public enum CanvasDocumentImporter {
    /// App-owned source namespace for the optional page-one notebook cover.
    /// Ordinary imported image pages never use this prefix, so reconciliation
    /// cannot mistake user content for a managed cover.
    public static let managedNotebookCoverSourcePrefix = "NotateCovers/"
    public static func importPDF(
        data: Data,
        suggestedName: String?,
        into itemID: UUID,
        storageRootURL: URL? = nil,
        sourceRelativePath: String? = nil
    ) async throws -> CanvasCoreSnapshot {
        let snapshot = try await makePDFSnapshotOffMain(
            data: data,
            suggestedName: suggestedName,
            sourceRelativePath: sourceRelativePath
        )
        return try await persist(
            snapshot: snapshot,
            itemID: itemID,
            storageRootURL: storageRootURL
        )
    }

    /// PDFKit parsing, native-text traversal, and large page-stack construction
    /// are proportional to untrusted document complexity. Public imports can be
    /// called from the application main actor, so perform that entire bounded
    /// phase on a worker before returning the Sendable immutable snapshot.
    static func makePDFSnapshotOffMain(
        data: Data,
        suggestedName: String?,
        sourceRelativePath: String? = nil,
        policy: CanvasDocumentIngestionPolicy = .canvasDefault,
        workerObservation: (@Sendable (_ isMainThread: Bool) -> Void)? = nil
    ) async throws -> CanvasCoreSnapshot {
        try await Task.detached(priority: .userInitiated) {
            workerObservation?(canvasImportWorkerIsMainThread())
            return try CanvasDocumentImporter.makePDFSnapshot(
                data: data,
                suggestedName: suggestedName,
                sourceRelativePath: sourceRelativePath,
                policy: policy
            )
        }.value
    }

    /// Builds the editable page stack without touching durable storage. The
    /// public import path persists this exact snapshot after validation.
    static func makePDFSnapshot(
        data: Data,
        suggestedName: String?,
        sourceRelativePath: String? = nil,
        policy: CanvasDocumentIngestionPolicy = .canvasDefault
    ) throws -> CanvasCoreSnapshot {
        let validated = try CanvasPDFSourceValidator.validate(data: data, policy: policy)
        let document = validated.document

        let source = CanvasPDFSourceReference(
            relativePath: normalizedPDFSourcePath(
                sourceRelativePath ?? suggestedName
            ),
            documentData: data
        )
        guard source.isValid else { throw CanvasDocumentImportError.unreadablePDF }

        var pages: [CanvasPageSnapshot] = []
        pages.reserveCapacity(document.pageCount)
        for index in 0..<document.pageCount {
            guard document.page(at: index) != nil else {
                throw CanvasDocumentImportError.invalidPage(index + 1)
            }
            let size = validated.pageSizes[index]
            let geometry = CanvasPageGeometry(authoredSize: size)
            let markup = PaperMarkup(bounds: CGRect(origin: .zero, size: size))
            pages.append(
                CanvasPageSnapshot(
                    markup: markup,
                    geometry: geometry,
                    background: .pdfPage(
                        source: source,
                        pageIndex: index,
                        suggestedName: suggestedName
                    )
                )
            )
        }
        return try makeSnapshot(pages: pages)
    }

    public static func importImage(
        data: Data,
        suggestedName: String?,
        into itemID: UUID,
        storageRootURL: URL? = nil,
        sourceRelativePath: String? = nil
    ) async throws -> CanvasCoreSnapshot {
        let snapshot = try makeImageSnapshot(
            data: data,
            suggestedName: suggestedName,
            sourceRelativePath: sourceRelativePath
        )
        return try await persist(
            snapshot: snapshot,
            itemID: itemID,
            storageRootURL: storageRootURL
        )
    }

    /// Builds an annotatable single-page image document while preserving the
    /// original bytes as the immutable background payload.
    static func makeImageSnapshot(
        data: Data,
        suggestedName: String?,
        sourceRelativePath: String? = nil,
        policy: CanvasImageIngestionPolicy = .canvasDefault
    ) throws -> CanvasCoreSnapshot {
        guard data.isEmpty == false else { throw CanvasDocumentImportError.emptyFile }
        let metadata: CanvasImageSourceMetadata
        do {
            metadata = try CanvasImageSourceValidator.metadata(
                for: data,
                policy: policy
            )
        } catch let error as CanvasImageIngestionError {
            switch error {
            case .sourceFileTooLarge, .sourcePixelBudgetExceeded:
                // Preserve the actionable limit message for the picker UI.
                throw error
            case .unreadableSource, .invalidDimensions, .decodeFailed,
                 .decodedPixelBudgetExceeded:
                throw CanvasDocumentImportError.unreadableImage
            }
        }
        let size = normalizedImagePageSize(metadata.orientedPixelSize)
        guard size.width > 0, size.height > 0 else {
            throw CanvasDocumentImportError.unreadableImage
        }
        let geometry = CanvasPageGeometry(authoredSize: size)
        let page = CanvasPageSnapshot(
            markup: PaperMarkup(bounds: CGRect(origin: .zero, size: size)),
            geometry: geometry,
            background: .image(
                data: data,
                suggestedName: suggestedName,
                sourceRelativePath: sourceRelativePath
            )
        )
        return try makeSnapshot(pages: [page])
    }

    public static func createBlankNotebook(
        itemID: UUID,
        storageRootURL: URL? = nil,
        coverImageData: Data? = nil,
        coverSourceRelativePath: String? = nil
    ) async throws -> CanvasCoreSnapshot {
        let contentPage = CanvasPageSnapshot(
            markup: PaperMarkup(
                bounds: CGRect(origin: .zero, size: CanvasConstants.a4PortraitSize)
            )
        )
        var pages: [CanvasPageSnapshot] = []
        if let coverImageData, let coverSourceRelativePath {
            let coverPage = CanvasPageSnapshot(
                markup: PaperMarkup(
                    bounds: CGRect(origin: .zero, size: CanvasConstants.a4PortraitSize)
                ),
                geometry: CanvasPageGeometry(
                    authoredSize: CanvasConstants.a4PortraitSize
                ),
                background: .image(
                    data: coverImageData,
                    suggestedName: "Notebook Cover",
                    sourceRelativePath: coverSourceRelativePath
                )
            )
            pages.append(coverPage)
        }
        pages.append(contentPage)
        return try await persist(
            snapshot: makeSnapshot(
                pages: pages,
                currentPageID: contentPage.id
            ),
            itemID: itemID,
            storageRootURL: storageRootURL
        )
    }

    public static func isManagedNotebookCover(_ page: CanvasPageSnapshot) -> Bool {
        guard case let .image(source, _) = page.background else { return false }
        return source.relativePath.hasPrefix(managedNotebookCoverSourcePrefix)
    }

    public static func createFreeformCanvas(
        itemID: UUID,
        storageRootURL: URL? = nil
    ) async throws -> CanvasCoreSnapshot {
        let size = CanvasConstants.freeformInitialSize
        let page = CanvasPageSnapshot(
            markup: PaperMarkup(bounds: CGRect(origin: .zero, size: size)),
            viewport: CanvasViewportState.stackViewport(
                zoomScale: CanvasConstants.defaultZoomScale,
                normalizedCenterX: 0.5,
                normalizedCenterY: 0.5
            ),
            geometry: CanvasPageGeometry(authoredSize: size)
        )
        return try await persist(
            snapshot: makeSnapshot(pages: [page]),
            itemID: itemID,
            storageRootURL: storageRootURL
        )
    }

    private static func makeSnapshot(
        pages: [CanvasPageSnapshot],
        currentPageID: UUID? = nil
    ) throws -> CanvasCoreSnapshot {
        guard let resolvedCurrentPageID = currentPageID ?? pages.first?.id else {
            throw CanvasDocumentImportError.emptyPDF
        }
        return CanvasCoreSnapshot(
            generation: 1,
            pages: pages,
            currentPageID: resolvedCurrentPageID
        )
    }

    private static func persist(
        snapshot: CanvasCoreSnapshot,
        itemID: UUID,
        storageRootURL: URL?
    ) async throws -> CanvasCoreSnapshot {
        let store: CanvasCoreStore
        if let storageRootURL {
            store = CanvasCoreStore(rootURL: storageRootURL)
        } else {
            store = try CanvasCoreStore.live(itemID: itemID)
        }
        try await store.checkpoint(snapshot)
        return snapshot
    }

    private static func normalizedPageSize(_ source: CGSize) -> CGSize {
        guard source.width.isFinite, source.height.isFinite,
              source.width > 0, source.height > 0 else { return .zero }
        // PDF authored geometry is semantic document data and must remain
        // faithful to the source. Raster images use the separate A4-envelope
        // path below because their dimensions are normally camera pixels, not
        // meaningful document points.
        return source
    }

    /// PDF media-box bounds are expressed in the page's unrotated coordinate
    /// space. An intrinsic `/Rotate` entry is applied only while drawing, so a
    /// quarter-turned source needs swapped authored dimensions to make the
    /// editable canvas match the page users actually see. App-owned page
    /// rotation remains independent in `CanvasPageGeometry.quarterTurns`.
    fileprivate static func normalizedPDFPageSize(
        _ source: CGSize,
        intrinsicRotation: Int
    ) -> CGSize {
        let size = normalizedPageSize(source)
        guard size != .zero else { return .zero }

        let normalizedRotation = ((intrinsicRotation % 360) + 360) % 360
        switch normalizedRotation {
        case 90, 270:
            return CGSize(width: size.height, height: size.width)
        default:
            return size
        }
    }

    /// Raster images commonly report camera pixels as UIKit points (for
    /// example 4,032 x 3,024). Treating those values as authored paper makes
    /// even the 50% zoom floor several screens wide. Keep the immutable source
    /// bytes at their full resolution, but author the editable page inside an
    /// A4-sized envelope so portrait and landscape imports share the same
    /// 50–1000% zoom semantics as notebook paper.
    private static func normalizedImagePageSize(_ source: CGSize) -> CGSize {
        guard source.width.isFinite, source.height.isFinite,
              source.width > 0, source.height > 0 else { return .zero }
        let maximumAuthoredDimension = max(
            CanvasConstants.a4LandscapeSize.width,
            CanvasConstants.a4LandscapeSize.height
        )
        let scale = min(1, maximumAuthoredDimension / max(source.width, source.height))
        return CGSize(
            width: source.width * scale,
            height: source.height * scale
        )
    }

    private static func normalizedPDFSourcePath(_ candidate: String?) -> String {
        let component = URL(fileURLWithPath: candidate ?? "Imported.pdf")
            .lastPathComponent
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = component.isEmpty ? "Imported.pdf" : component
        return fallback.lowercased().hasSuffix(".pdf") ? fallback : "\(fallback).pdf"
    }
}

/// Bounds the PaperKit work that can materialize searchable text. PaperKit 26
/// exposes only the eager `indexableContent` projection, so legacy extraction
/// first rejects an oversized serialized markup and globally limits calls that
/// may ignore cancellation. PaperKit 27 exposes its elements; read their text
/// incrementally instead so no framework-owned aggregate String is requested.
private actor CanvasPaperTextExtractionArbiter {
    static let shared = CanvasPaperTextExtractionArbiter()

    // The iOS 26 compatibility path must serialize markup before it can reject
    // an oversized projection. One process-wide owner prevents two large
    // legacy pages from retaining those temporary buffers at once.
    private static let maximumConcurrentOwners = 1
    private var owners = Set<UUID>()

    func reserve(ownerID: UUID) -> Bool {
        guard owners.count < Self.maximumConcurrentOwners else { return false }
        owners.insert(ownerID)
        return true
    }

    func release(ownerID: UUID) {
        owners.remove(ownerID)
    }
}

enum CanvasBoundedPaperTextExtractor {
    /// This is deliberately lower than Canvas Core's persistence ceiling.
    /// Search text is optional derived data and should never deserialize a
    /// very large annotation merely to improve discovery.
    static let maximumEncodedMarkupByteCount = 8 * 1_024 * 1_024
    static let maximumVisitedElementCount = 65_536
    static let maximumTextBearingElementCount = 4_096

    static func text(
        from markup: PaperMarkup,
        maximumUTF8ByteCount: Int
    ) async -> String? {
        guard !Task.isCancelled else { return nil }
        guard maximumUTF8ByteCount >= 0 else { return nil }
        if #available(iOS 27.0, *) {
            // The element walker is bounded and cooperative, so it does not
            // need the legacy framework-call lane. Image descriptions and
            // links remain indexable even with no editable-text feature.
            return textFromExposedElements(
                markup,
                maximumUTF8ByteCount: maximumUTF8ByteCount
            )
        }
        guard markup.featureSet.contains(.text) else {
            return ""
        }

        let ownerID = UUID()
        guard await CanvasPaperTextExtractionArbiter.shared.reserve(
            ownerID: ownerID
        ) else {
            // Search content is derived and will be rebuilt after a later
            // verified save. Fail closed instead of queuing unbounded markup
            // snapshots behind cancellation-resistant framework work.
            return nil
        }

        let result = await legacyText(
            from: markup,
            maximumUTF8ByteCount: maximumUTF8ByteCount
        )
        await CanvasPaperTextExtractionArbiter.shared.release(ownerID: ownerID)
        return result
    }

    @available(iOS 27.0, *)
    private static func textFromExposedElements(
        _ markup: PaperMarkup,
        maximumUTF8ByteCount: Int
    ) -> String? {
        let elements = markup.subelements
        // Ordinary handwriting can contain thousands of PKStroke elements.
        // Bound the complete walk separately while applying the tighter cap
        // only to elements that can contribute searchable strings.
        guard elements.count <= maximumVisitedElementCount else { return nil }

        var result = ""
        var remainingBytes = maximumUTF8ByteCount
        var textBearingElementCount = 0
        for (offset, element) in elements.enumerated() {
            if offset.isMultiple(of: 64), Task.isCancelled { return nil }
            let appendResult: TextAppendResult?
            if let shape = element as? ShapeMarkup {
                appendResult = append(
                    shape.attributedText.characters,
                    to: &result,
                    remainingBytes: &remainingBytes
                )
            } else if let image = element as? ImageMarkup,
                let description = image.accessibilityDescription {
                appendResult = append(
                    description,
                    to: &result,
                    remainingBytes: &remainingBytes
                )
            } else if let link = element as? LinkMarkup {
                appendResult = append(
                    link.url.absoluteString,
                    to: &result,
                    remainingBytes: &remainingBytes
                )
            } else {
                appendResult = nil
            }
            switch appendResult {
            case .some(.appended):
                guard textBearingElementCount < maximumTextBearingElementCount else {
                    return nil
                }
                textBearingElementCount += 1
            case .some(.blank), .none:
                break
            case .some(.rejected):
                return nil
            }
        }
        return result
    }

    private enum TextAppendResult {
        case appended
        case blank
        case rejected
    }

    private static func append<Characters: Collection>(
        _ characters: Characters,
        to result: inout String,
        remainingBytes: inout Int
    ) -> TextAppendResult where Characters.Element == Character {
        let startingRemainingBytes = remainingBytes
        let needsSeparator = result.isEmpty == false
        var appendedSeparator = false
        var exceededBudget = false
        if needsSeparator, remainingBytes > 0 {
            result.append("\n")
            remainingBytes -= 1
            appendedSeparator = true
        } else if needsSeparator {
            exceededBudget = true
        }
        var visitedCharacterCount = 0
        var appendedCharacterCount = 0
        var containsNonWhitespace = false
        for character in characters {
            if visitedCharacterCount.isMultiple(of: 2_048), Task.isCancelled {
                return .rejected
            }
            let byteCount = character.utf8.count
            if exceededBudget == false, byteCount <= remainingBytes {
                result.append(character)
                remainingBytes -= byteCount
                appendedCharacterCount += 1
            } else {
                exceededBudget = true
            }
            containsNonWhitespace = containsNonWhitespace
                || character.isWhitespace == false
            visitedCharacterCount += 1
        }
        if containsNonWhitespace == false {
            // Never retain a String.Index across mutation: doing so can trap.
            // Remove exactly the Characters appended by this field instead.
            result.removeLast(
                appendedCharacterCount + (appendedSeparator ? 1 : 0)
            )
            remainingBytes = startingRemainingBytes
            return .blank
        }
        return exceededBudget ? .rejected : .appended
    }

    private static func legacyText(
        from markup: PaperMarkup,
        maximumUTF8ByteCount: Int
    ) async -> String? {
        // iOS 26 has no public element collection. Serializing is the only
        // available complexity signal, and Canvas Core already performs this
        // operation for every verified checkpoint. Release the preflight Data
        // before asking PaperKit to build its searchable projection.
        let isAdmitted: Bool
        do {
            let encoded = try await markup.dataRepresentation()
            isAdmitted = encoded.isEmpty == false
                && encoded.count <= maximumEncodedMarkupByteCount
        } catch {
            return nil
        }
        guard isAdmitted, !Task.isCancelled else { return nil }
        let result = await markup.indexableContent
        guard !Task.isCancelled else { return nil }
        guard let result else { return "" }
        guard result.contains(where: { $0.isWhitespace == false }) else {
            return ""
        }
        guard result.utf8.count <= maximumUTF8ByteCount else { return nil }
        return result
    }
}

/// Produces the library's searchable payload from editable text plus the
/// native text layer of an imported PDF. A shared source reference is indexed
/// once even when the document contains hundreds of pages.
enum CanvasDocumentSearchIndexer {
    static let maximumSearchableTextUTF8ByteCount =
        CanvasDocumentIngestionPolicy.canvasDefault
            .maximumPDFNativeTextByteCount

    static func searchableText(for pages: [CanvasPageSnapshot]) async -> String {
        var result = ""
        var remainingBytes = maximumSearchableTextUTF8ByteCount
        var indexedPDFSources = Set<String>()

        func appendIfWithinBudget(_ text: String) -> Bool {
            guard text.contains(where: { $0.isWhitespace == false }) else {
                return true
            }
            let separatorByteCount = result.isEmpty ? 0 : 1
            let textByteCount = text.utf8.count
            guard separatorByteCount <= remainingBytes,
                  textByteCount <= remainingBytes - separatorByteCount else {
                return false
            }
            if separatorByteCount == 1 { result.append("\n") }
            result.append(contentsOf: text)
            remainingBytes -= separatorByteCount + textByteCount
            return true
        }

        for page in pages {
            guard !Task.isCancelled else { return result }
            if let text = await CanvasBoundedPaperTextExtractor.text(
                from: page.markup,
                maximumUTF8ByteCount: remainingBytes
            ),
            appendIfWithinBudget(text) == false {
                return result
            }

            if case let .pdfPage(source, _, _) = page.background,
                indexedPDFSources.insert(source.relativePath).inserted,
                let documentData = source.documentData {
                let document = PDFDocument(data: documentData)
                for pageIndex in 0..<document.pageCount {
                    guard !Task.isCancelled else { return result }
                    guard let pdfPage = document.page(at: pageIndex) else {
                        continue
                    }
                    // UTF-8 bytes are never fewer than Unicode scalar/code
                    // units, so this avoids asking PDFKit to materialize a
                    // page string that cannot fit the remaining projection.
                    let characterCount = pdfPage.numberOfCharacters
                    guard characterCount >= 0,
                          characterCount <= remainingBytes else {
                        return result
                    }
                    if let text = pdfPage.string,
                        appendIfWithinBudget(text) == false {
                        return result
                    }
                }
            }
        }

        return result
    }
}