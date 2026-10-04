import CoreGraphics
import Foundation
import ImageIO
import PaperKit
import UniformTypeIdentifiers

public actor CanvasDocumentExporter {
    public static let shared = CanvasDocumentExporter()
    public nonisolated static let imageScale: CGFloat = 2
    /// A single export surface stays below roughly 64 MiB before encoder
    /// copies. Larger authored pages are emitted as lossless adjacent tiles.
    public nonisolated static let maximumRasterPixelDimension = 4_096
    public nonisolated static let maximumRasterPixelCount = 16_777_216
    /// Very large PDF media boxes are poorly supported by common consumers.
    /// PaperKit remains vector-sharp because oversized boards are translated
    /// into adjacent PDF pages rather than rasterized or scaled down.
    public nonisolated static let maximumPDFPageDimension: CGFloat = 4_096
    /// A maximum-size 65,536-point freeform board produces 32 x 32 raster
    /// tiles at the two-times export scale. Reject larger synthetic or corrupt
    /// geometry before reserving an attacker-controlled tile array.
    public nonisolated static let maximumExportTileCount = 1_024
    /// Bound the total work and output-file cardinality for one export while
    /// still allowing every page in a maximum-size ordinary document to be
    /// exported in one operation. This is checked before a temporary
    /// directory is created and uses overflow-safe arithmetic.
    public nonisolated static let maximumAggregateExportTileCount = 4_096
    /// At four RGBA bytes per pixel this caps the uncompressed image-export
    /// work at 1 GiB across the whole batch. Rendering remains sequential, but
    /// this also bounds worst-case encoder work and output-disk amplification.
    /// The budget still covers more than 100 A4 pages at the standard 2x scale.
    public nonisolated static let maximumAggregateRasterPixelCount = 268_435_456

    enum ImageRenderingMode: Equatable, Sendable {
        case completePage
        case authoredContent
        case imagePlaygroundSource
    }

    private struct ExportTile: Sendable {
        let cropRect: CGRect
        let row: Int
        let column: Int
    }

    private struct ExportTileLayout: Sendable {
        let columnCount: Int
        let rowCount: Int
        let tileCount: Int
    }

    private let temporaryDirectoryProvider: @Sendable () -> URL

    public init() {
        temporaryDirectoryProvider = {
            FileManager.default.temporaryDirectory.appendingPathComponent(
                "Notate-Export-\(UUID().uuidString)",
                isDirectory: true
            )
        }
    }

    init(temporaryDirectoryProvider: @escaping @Sendable () -> URL) {
        self.temporaryDirectoryProvider = temporaryDirectoryProvider
    }

    public func thumbnail(
        for page: CanvasPageSnapshot,
        maximumPixelSize: CGSize = CGSize(width: 240, height: 340)
    ) async throws -> CGImage {
        try await thumbnail(
            for: page,
            cropRect: CGRect(origin: .zero, size: page.displaySize),
            maximumPixelSize: maximumPixelSize
        )
    }

    public func freeformThumbnail(
        for page: CanvasPageSnapshot,
        maximumPixelSize: CGSize = CGSize(width: 320, height: 240)
    ) async throws -> CGImage {
        let previewPixelSize = FreeformCanvasPreviewLayout.libraryPixelSize(
            inside: maximumPixelSize
        )
        guard previewPixelSize != .zero else {
            throw CanvasExportError.graphicsContextUnavailable
        }
        let cropRect = FreeformCanvasPreviewLayout.cropRect(
            canvasSize: page.displaySize,
            viewport: page.viewport,
            outputAspectRatio: CanvasConstants.freeformLibraryAspectRatio
        )
        return try await thumbnail(
            for: page,
            cropRect: cropRect,
            maximumPixelSize: previewPixelSize
        )
    }

    private func thumbnail(
        for page: CanvasPageSnapshot,
        cropRect: CGRect,
        maximumPixelSize: CGSize
    ) async throws -> CGImage {
        let pageSize = cropRect.size
        let scale = min(
            maximumPixelSize.width / pageSize.width,
            maximumPixelSize.height / pageSize.height
        )
        return try await renderImage(
            page,
            cropRect: cropRect,
            // A thumbnail budget is a hard pixel ceiling. Large-format PDFs
            // and high-resolution photos routinely need scales below 0.1;
            // forcing a floor there can allocate a raster many times larger
            // than the library card will ever display.
            scale: scale
        )
    }

    public func export(
        pages: [CanvasExportPage],
        format: CanvasExportFormat,
        suggestedFilename: String? = nil
    ) async throws -> CanvasExportArtifact {
        guard pages.isEmpty == false else { throw CanvasExportError.noPagesSelected }
        var sourcePageNumbers = Set<Int>()
        for page in pages {
            guard page.sourcePageNumber > 0 else {
                throw CanvasExportError.invalidSourcePageNumber(page.sourcePageNumber)
            }
            guard sourcePageNumbers.insert(page.sourcePageNumber).inserted else {
                throw CanvasExportError.duplicateSourcePageNumber(page.sourcePageNumber)
            }
        }

        let aggregateTileCount = try Self.preflightExportResources(
            pages: pages,
            format: format
        )
        try Task.checkCancellation()

        let directory = temporaryDirectoryProvider().standardizedFileURL
        do {
            try FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        } catch {
            throw CanvasExportError.fileSystem(error.localizedDescription)
        }

        do {
            let urls: [URL]
            let baseFilename = Self.sanitizedFilenameBase(suggestedFilename)
            switch format {
            case .pdf:
                let url = directory.appendingPathComponent("\(baseFilename).pdf")
                try await Self.writePDF(
                    pages: pages,
                    title: baseFilename,
                    expectedPageCount: aggregateTileCount,
                    to: url
                )
                urls = [url]

            case .images:
                var imageURLs: [URL] = []
                imageURLs.reserveCapacity(aggregateTileCount)
                let imageFilenameBase = suggestedFilename == nil ? "Notate" : baseFilename
                for page in pages {
                    let tiles = try Self.rasterExportTiles(
                        pageSize: page.snapshot.displaySize,
                        scale: Self.imageScale
                    )
                    for tile in tiles {
                        try Task.checkCancellation()
                        let image = try await renderImage(
                            page.snapshot,
                            cropRect: tile.cropRect,
                            scale: Self.imageScale
                        )
                        try Task.checkCancellation()
                        let tileSuffix = tiles.count == 1
                            ? ""
                            : " Tile \(tile.row + 1)-\(tile.column + 1)"
                        let url = directory.appendingPathComponent(
                            "\(imageFilenameBase) Page \(page.sourcePageNumber)\(tileSuffix).png"
                        )
                        try Self.writePNG(
                            image,
                            pageNumber: page.sourcePageNumber,
                            scale: Self.imageScale,
                            to: url
                        )
                        imageURLs.append(url)
                        await Task.yield()
                    }
                }
                urls = imageURLs
            }

            try Task.checkCancellation()

            return CanvasExportArtifact(
                format: format,
                urls: urls,
                temporaryDirectory: directory
            )
        } catch {
            try? FileManager.default.removeItem(at: directory)
            if let exportError = error as? CanvasExportError {
                throw exportError
            }
            if error is CancellationError {
                throw error
            }
            throw CanvasExportError.fileSystem(error.localizedDescription)
        }
    }

    func renderImage(
        _ page: CanvasPageSnapshot,
        cropRect requestedCropRect: CGRect? = nil,
        scale: CGFloat,
        mode: ImageRenderingMode = .completePage
    ) async throws -> CGImage {
        try Task.checkCancellation()
        let pageBounds = CGRect(origin: .zero, size: page.displaySize)
        let cropRect = requestedCropRect?.intersection(pageBounds) ?? pageBounds
        guard cropRect.isNull == false, cropRect.isEmpty == false else {
            throw CanvasExportError.graphicsContextUnavailable
        }
        let pageSize = cropRect.size
        guard scale.isFinite, scale > 0 else {
            throw CanvasExportError.graphicsContextUnavailable
        }
        let (pixelWidth, pixelHeight) = try Self.validatedRasterDimensions(
            pageSize: pageSize,
            scale: scale
        )
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(
                data: nil,
                width: pixelWidth,
                height: pixelHeight,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              ) else {
            throw CanvasExportError.graphicsContextUnavailable
        }

        context.interpolationQuality = .high
        let scaleX = CGFloat(pixelWidth) / pageSize.width
        let scaleY = CGFloat(pixelHeight) / pageSize.height
        Self.prepareTopLeftCoordinates(
            in: context,
            outputHeight: CGFloat(pixelHeight),
            scaleX: scaleX,
            scaleY: scaleY
        )
        context.translateBy(x: -cropRect.minX, y: -cropRect.minY)
        try await Self.draw(
            page,
            in: context,
            maximumImagePixelDimension: max(
                cropRect.width * scaleX,
                cropRect.height * scaleY
            ),
            mode: mode
        )
        try Task.checkCancellation()

        guard let image = context.makeImage() else {
            throw CanvasExportError.graphicsContextUnavailable
        }
        return image
    }

    private static func writePDF(
        pages: [CanvasExportPage],
        title: String,
        expectedPageCount: Int,
        to url: URL
    ) async throws {
        guard let firstPage = pages.first,
              let firstTile = try pdfExportTiles(
                pageSize: firstPage.snapshot.displaySize
              ).first else {
            throw CanvasExportError.graphicsContextUnavailable
        }
        var mediaBox = CGRect(origin: .zero, size: firstTile.cropRect.size)
        guard let consumer = CGDataConsumer(url: url as CFURL),
              let context = CGContext(
                consumer: consumer,
                mediaBox: &mediaBox,
                [
                    kCGPDFContextTitle as String: title,
                    kCGPDFContextCreator as String: "Notate",
                ] as CFDictionary
              ) else {
            throw CanvasExportError.graphicsContextUnavailable
        }
        do {
            for page in pages {
                try Task.checkCancellation()
                // Keep only one source page's tile descriptors resident. A
                // validated page may contain up to 1,024 tiles, so retaining
                // every page's array could otherwise amplify memory with
                // document length before any PDF page is written.
                let tiles = try pdfExportTiles(
                    pageSize: page.snapshot.displaySize
                )
                for tile in tiles {
                    try Task.checkCancellation()
                    var tileBounds = CGRect(origin: .zero, size: tile.cropRect.size)
                    let mediaBoxData = NSData(
                        bytes: &tileBounds,
                        length: MemoryLayout<CGRect>.size
                    )
                    context.beginPDFPage([
                        kCGPDFContextMediaBox as String: mediaBoxData,
                    ] as CFDictionary)
                    context.saveGState()
                    prepareTopLeftCoordinates(
                        in: context,
                        outputHeight: tileBounds.height,
                        scaleX: 1,
                        scaleY: 1
                    )
                    context.translateBy(
                        x: -tile.cropRect.minX,
                        y: -tile.cropRect.minY
                    )
                    try await draw(
                        page.snapshot,
                        in: context,
                        maximumImagePixelDimension: nil,
                        mode: .completePage
                    )
                    context.restoreGState()
                    context.endPDFPage()
                    try Task.checkCancellation()
                    await Task.yield()
                }
            }
            context.closePDF()
        } catch {
            context.closePDF()
            throw error
        }

        guard let document = CGPDFDocument(url as CFURL),
              document.numberOfPages == expectedPageCount else {
            throw CanvasExportError.outputValidationFailed
        }
    }

    private static func preflightExportResources(
        pages: [CanvasExportPage],
        format: CanvasExportFormat
    ) throws -> Int {
        var aggregateTileCount = 0
        var aggregateRasterPixelCount = 0
        for page in pages {
            try Task.checkCancellation()
            let pageTileCount: Int
            switch format {
            case .pdf:
                pageTileCount = try exportTileLayout(
                    pageSize: page.snapshot.displaySize,
                    maximumLogicalDimension: maximumPDFPageDimension
                ).tileCount
            case .images:
                guard imageScale.isFinite, imageScale > 0 else {
                    throw CanvasExportError.graphicsContextUnavailable
                }
                let layout = try exportTileLayout(
                    pageSize: page.snapshot.displaySize,
                    maximumLogicalDimension: CGFloat(maximumRasterPixelDimension) / imageScale
                )
                pageTileCount = layout.tileCount
                aggregateRasterPixelCount = try preflightAggregateRasterPixelCount(
                    pageSize: page.snapshot.displaySize,
                    scale: imageScale,
                    layout: layout,
                    aggregatePixelCount: aggregateRasterPixelCount
                )
            }
            aggregateTileCount = try validatedAggregateTileCount(
                adding: pageTileCount,
                to: aggregateTileCount
            )
        }
        return aggregateTileCount
    }

    private static func preflightAggregateRasterPixelCount(
        pageSize: CGSize,
        scale: CGFloat,
        layout: ExportTileLayout,
        aggregatePixelCount: Int
    ) throws -> Int {
        let maximumLogicalDimension = CGFloat(maximumRasterPixelDimension) / scale
        var result = aggregatePixelCount
        for row in 0..<layout.rowCount {
            try Task.checkCancellation()
            let minY = CGFloat(row) * maximumLogicalDimension
            let height = min(maximumLogicalDimension, pageSize.height - minY)
            for column in 0..<layout.columnCount {
                let minX = CGFloat(column) * maximumLogicalDimension
                let width = min(maximumLogicalDimension, pageSize.width - minX)
                let dimensions = try validatedRasterDimensions(
                    pageSize: CGSize(width: width, height: height),
                    scale: scale
                )
                let (tilePixelCount, overflowed) = dimensions.width
                    .multipliedReportingOverflow(by: dimensions.height)
                guard overflowed == false else {
                    throw CanvasExportError.aggregateRasterPixelLimitExceeded(
                        maximum: maximumAggregateRasterPixelCount
                    )
                }
                result = try validatedAggregateRasterPixelCount(
                    adding: tilePixelCount,
                    to: result
                )
            }
        }
        return result
    }

    /// Kept internal so overflow behavior can be regression-tested without
    /// constructing an impossibly large in-memory page collection.
    nonisolated static func validatedAggregateTileCount(
        adding tileCount: Int,
        to aggregateTileCount: Int,
        maximum: Int = maximumAggregateExportTileCount
    ) throws -> Int {
        guard tileCount >= 0,
              aggregateTileCount >= 0,
              maximum >= 0 else {
            throw CanvasExportError.graphicsContextUnavailable
        }
        let (result, overflowed) = aggregateTileCount.addingReportingOverflow(
            tileCount
        )
        guard overflowed == false, result <= maximum else {
            throw CanvasExportError.aggregateTileLimitExceeded(maximum: maximum)
        }
        return result
    }

    /// Kept internal for the same reason as the aggregate tile validator: an
    /// arithmetic overflow cannot be induced through a realistic page array.
    nonisolated static func validatedAggregateRasterPixelCount(
        adding pixelCount: Int,
        to aggregatePixelCount: Int,
        maximum: Int = maximumAggregateRasterPixelCount
    ) throws -> Int {
        guard pixelCount >= 0,
              aggregatePixelCount >= 0,
              maximum >= 0 else {
            throw CanvasExportError.graphicsContextUnavailable
        }
        let (result, overflowed) = aggregatePixelCount.addingReportingOverflow(
            pixelCount
        )
        guard overflowed == false, result <= maximum else {
            throw CanvasExportError.aggregateRasterPixelLimitExceeded(maximum: maximum)
        }
        return result
    }

    /// Produces one safe, user-recognizable filename without changing the
    /// established export name for callers that do not supply a document
    /// title. File-system separators and control characters are replaced so a
    /// note name can never escape the temporary export directory.
    private static func sanitizedFilenameBase(_ suggestion: String?) -> String {
        let fallback = "Notate Export"
        guard let suggestion else { return fallback }

        let disallowed = CharacterSet.controlCharacters
            .union(.newlines)
            .union(CharacterSet(charactersIn: "#/:\\\"?*<>|\"#"))
        let components = suggestion
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .unicodeScalars
            .map { disallowed.contains($0) ? " " : String($0) }
        let normalized = components
            .joined()
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard normalized.isEmpty == false else { return fallback }

        // APFS limits a filename component by encoded bytes, not by Swift
        // Character count. Keep enough room for the page suffix and extension
        // while preserving whole grapheme clusters in emoji-heavy note names.
        let maximumUTF8Bytes = 160
        var byteCount = 0
        var result = ""
        for character in normalized {
            let characterBytes = String(character).utf8.count
            guard byteCount + characterBytes <= maximumUTF8Bytes else { break }
            result.append(character)
            byteCount += characterBytes
        }
        return result.isEmpty ? fallback : result
    }

    private static func draw(
        _ page: CanvasPageSnapshot,
        in context: CGContext,
        maximumImagePixelDimension: CGFloat?,
        mode: ImageRenderingMode
    ) async throws {
        let pageBounds = CGRect(origin: .zero, size: page.displaySize)
        if mode != .authoredContent {
            switch page.background {
            case .paper:
                if mode == .completePage {
                    CanvasPaperTemplateArtwork.draw(
                        template: page.paperTemplate,
                        in: context,
                        pageBounds: pageBounds
                    )
                }
            case .image, .pdfPage:
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(pageBounds)
                guard CanvasPageBackgroundRenderer.draw(
                    page.background,
                    geometry: page.geometry,
                    in: context,
                    destinationRect: pageBounds,
                    maximumImagePixelDimension: maximumImagePixelDimension
                ) else {
                    throw CanvasExportError.backgroundRenderingFailed
                }
            }
        }
        if mode != .authoredContent {
            CanvasTableArtwork.draw(
                tables: page.tables,
                in: context,
                pageBounds: pageBounds,
                paperTone: page.background.isImported ? nil : page.paperTemplate.tone
            )
        }
        await page.markup.draw(
            in: context,
            frame: pageBounds,
            options: CanvasPaperRenderingEnvironment.lightOptions
        )
    }

    private static func prepareTopLeftCoordinates(
        in context: CGContext,
        outputHeight: CGFloat,
        scaleX: CGFloat,
        scaleY: CGFloat
    ) {
        context.translateBy(x: 0, y: outputHeight)
        context.scaleBy(x: scaleX, y: -scaleY)
    }

    private static func writePNG(
        _ image: CGImage,
        pageNumber: Int,
        scale: CGFloat,
        to url: URL
    ) throws {
        guard let destination = CGImageDestinationCreateWithURL(
            url as CFURL,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw CanvasExportError.imageEncodingFailed(page: pageNumber)
        }
        let dpi = max(scale, 0.0001) * 72
        let properties = [
            kCGImagePropertyDPIWidth as String: dpi,
            kCGImagePropertyDPIHeight as String: dpi,
            kCGImagePropertyPNGDictionary as String: [
                kCGImagePropertyPNGTitle as String: "Notate Page \(pageNumber)",
            ],
        ] as CFDictionary
        CGImageDestinationAddImage(destination, image, properties)
        guard CGImageDestinationFinalize(destination) else {
            throw CanvasExportError.imageEncodingFailed(page: pageNumber)
        }
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
                as? [CFString: Any],
              properties[kCGImagePropertyPixelWidth] as? Int == image.width,
              properties[kCGImagePropertyPixelHeight] as? Int == image.height else {
            throw CanvasExportError.outputValidationFailed
        }
    }

    private static func validatedRasterDimensions(
        pageSize: CGSize,
        scale: CGFloat
    ) throws -> (width: Int, height: Int) {
        let width = ceil(pageSize.width * scale)
        let height = ceil(pageSize.height * scale)
        guard width.isFinite,
              height.isFinite,
              width > 0,
              height > 0,
              width < CGFloat(Int.max),
              height < CGFloat(Int.max) else {
            throw CanvasExportError.graphicsContextUnavailable
        }
        let pixelWidth = max(Int(width), 1)
        let pixelHeight = max(Int(height), 1)
        let (pixelCount, overflowed) = pixelWidth.multipliedReportingOverflow(
            by: pixelHeight
        )
        guard overflowed == false,
              pixelWidth <= maximumRasterPixelDimension,
              pixelHeight <= maximumRasterPixelDimension,
              pixelCount <= maximumRasterPixelCount else {
            throw CanvasExportError.rasterSurfaceTooLarge(
                width: pixelWidth,
                height: pixelHeight,
                maximumDimension: maximumRasterPixelDimension,
                maximumPixelCount: maximumRasterPixelCount
            )
        }
        return (pixelWidth, pixelHeight)
    }

    private static func rasterExportTiles(
        pageSize: CGSize,
        scale: CGFloat
    ) throws -> [ExportTile] {
        guard scale.isFinite, scale > 0 else {
            throw CanvasExportError.graphicsContextUnavailable
        }
        return try exportTiles(
            pageSize: pageSize,
            maximumLogicalDimension: CGFloat(maximumRasterPixelDimension) / scale
        )
    }

    private static func pdfExportTiles(pageSize: CGSize) throws -> [ExportTile] {
        try exportTiles(
            pageSize: pageSize,
            maximumLogicalDimension: maximumPDFPageDimension
        )
    }

    private static func exportTiles(
        pageSize: CGSize,
        maximumLogicalDimension: CGFloat
    ) throws -> [ExportTile] {
        let layout = try exportTileLayout(
            pageSize: pageSize,
            maximumLogicalDimension: maximumLogicalDimension
        )
        var tiles: [ExportTile] = []
        tiles.reserveCapacity(layout.tileCount)
        for row in 0..<layout.rowCount {
            let minY = CGFloat(row) * maximumLogicalDimension
            let height = min(maximumLogicalDimension, pageSize.height - minY)
            for column in 0..<layout.columnCount {
                let minX = CGFloat(column) * maximumLogicalDimension
                let width = min(maximumLogicalDimension, pageSize.width - minX)
                tiles.append(ExportTile(
                    cropRect: CGRect(x: minX, y: minY, width: width, height: height),
                    row: row,
                    column: column
                ))
            }
        }
        return tiles
    }

    private static func exportTileLayout(
        pageSize: CGSize,
        maximumLogicalDimension: CGFloat
    ) throws -> ExportTileLayout {
        guard pageSize.width.isFinite,
              pageSize.height.isFinite,
              pageSize.width > 0,
              pageSize.height > 0,
              maximumLogicalDimension.isFinite,
              maximumLogicalDimension > 0 else {
            throw CanvasExportError.graphicsContextUnavailable
        }
        let rawColumnCount = ceil(pageSize.width / maximumLogicalDimension)
        let rawRowCount = ceil(pageSize.height / maximumLogicalDimension)
        guard rawColumnCount.isFinite,
              rawRowCount.isFinite,
              rawColumnCount > 0,
              rawRowCount > 0,
              rawColumnCount <= CGFloat(Int.max),
              rawRowCount <= CGFloat(Int.max) else {
            throw CanvasExportError.graphicsContextUnavailable
        }
        let columnCount = max(Int(rawColumnCount), 1)
        let rowCount = max(Int(rawRowCount), 1)
        let (tileCount, tileCountOverflowed) = columnCount.multipliedReportingOverflow(
            by: rowCount
        )
        guard tileCountOverflowed == false,
              tileCount <= maximumExportTileCount else {
            throw CanvasExportError.graphicsContextUnavailable
        }
        return ExportTileLayout(
            columnCount: columnCount,
            rowCount: rowCount,
            tileCount: tileCount
        )
    }
}
