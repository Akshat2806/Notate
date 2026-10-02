import CoreGraphics
import ImageIO
import UIKit

/// Draws immutable imported page backgrounds without handing PaperKit an
/// unbounded source image.
///
/// PDF pages are painted directly from their original vector content. Images
/// are decoded by ImageIO at the pixel size the destination can actually use,
/// which avoids decoding a camera-sized original only to shrink it again.
enum CanvasPageBackgroundRenderer {
    /// A single visible background is allowed enough pixels to remain crisp on
    /// a Retina iPad, while still staying well below an unbounded 4K-square
    /// allocation. Hidden page hosts release the resulting CGImage.
    static let maximumRasterPixelDimension: CGFloat = 4_096
    static let maximumRasterPixelCount: CGFloat = 8_388_608
    /// A live tiled image may progressively promote its one decoded source as
    /// the user zooms. The larger ceiling is live-editor-only: ordinary
    /// thumbnails and exports keep the established raster budget below.
    /// Sixteen megapixels is at most 64 MiB for an 8-bit RGBA decode, and the
    /// page render window destroys the source when its host is evicted.
    static let maximumLiveRasterPixelDimension: CGFloat = 8_192
    static let maximumLiveRasterPixelCount: CGFloat = 16_777_216
    private static let minimumLiveRasterDecodeDimension: CGFloat = 512

    @MainActor
    static func image(
        for background: CanvasPageBackground,
        geometry: CanvasPageGeometry,
        maximumPixelSize: CGSize? = nil
    ) -> CGImage? {
        guard background != .paper,
              geometry.isValid,
              let targetSize = boundedRasterSize(
                displaySize: geometry.displaySize,
                requestedMaximum: maximumPixelSize ?? geometry.displaySize
              ) else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        format.preferredRange = .standard

        var didDrawSource = false
        let rendered = UIGraphicsImageRenderer(size: targetSize, format: format).image { output in
            didDrawSource = draw(
                background,
                geometry: geometry,
                in: output.cgContext,
                destinationRect: CGRect(origin: .zero, size: targetSize),
                maximumImagePixelDimension: max(targetSize.width, targetSize.height)
            )
        }
        return didDrawSource ? rendered.cgImage : nil
    }

    /// Draws into a context whose current coordinate space has its origin at
    /// the top-left. This is the coordinate system used by PaperKit and by the
    /// compositing exporter after it installs its page transform.
    ///
    /// Drawing a PDF this way keeps vectors and text vector-sharp in a PDF
    /// export and avoids the old thumbnail -> bitmap -> layer double resample.
    @discardableResult
    static func draw(
        _ background: CanvasPageBackground,
        geometry: CanvasPageGeometry,
        in context: CGContext,
        destinationRect: CGRect,
        maximumImagePixelDimension: CGFloat? = nil
    ) -> Bool {
        guard let source = drawingSource(
            for: background,
            geometry: geometry,
            maximumImagePixelDimension: maximumImagePixelDimension
        ) else { return false }
        source.draw(in: context, destinationRect: destinationRect)
        return true
    }

    static func drawingSource(
        for background: CanvasPageBackground,
        geometry: CanvasPageGeometry,
        maximumImagePixelDimension: CGFloat? = nil,
        maximumImagePixelCount: CGFloat = maximumRasterPixelCount,
        adaptsImageResolutionToContext: Bool = false
    ) -> CanvasPageBackgroundDrawingSource? {
        CanvasPageBackgroundDrawingSource(
            background: background,
            geometry: geometry,
            maximumImagePixelDimension: maximumImagePixelDimension,
            maximumImagePixelCount: maximumImagePixelCount,
            adaptsImageResolutionToContext: adaptsImageResolutionToContext
        )
    }

    static func boundedRasterSize(
        displaySize: CGSize,
        requestedMaximum: CGSize
    ) -> CGSize? {
        guard displaySize.width.isFinite,
              displaySize.height.isFinite,
              displaySize.width > 0,
              displaySize.height > 0,
              requestedMaximum.width.isFinite,
              requestedMaximum.height.isFinite,
              requestedMaximum.width > 0,
              requestedMaximum.height > 0 else { return nil }

        // Unlike the previous implementation, this deliberately allows an
        // imported PDF measured in 72-point units to render above 1 pixel per
        // point. A 612 x 792 page therefore receives a Retina-quality backing
        // image instead of being stretched from a 612 x 792 thumbnail.
        let requestedScale = min(
            requestedMaximum.width / displaySize.width,
            requestedMaximum.height / displaySize.height
        )
        var width = displaySize.width * requestedScale
        var height = displaySize.height * requestedScale

        let dimensionScale = min(
            1,
            maximumRasterPixelDimension / max(width, height)
        )
        width *= dimensionScale
        height *= dimensionScale

        let pixelCount = width * height
        if pixelCount > maximumRasterPixelCount {
            let areaScale = sqrt(maximumRasterPixelCount / pixelCount)
            width *= areaScale
            height *= areaScale
        }

        return CGSize(
            width: max(floor(width), 1),
            height: max(floor(height), 1)
        )
    }

    /// Selects the smallest power-of-two decode tier that covers the current
    /// destination in device pixels. The result is then clamped to both the
    /// source and the caller's dimension/area budgets. Returning `nil` lets a
    /// malformed render transform use the established fixed safe fallback.
    static func adaptiveRasterDecodeMaximum(
        sourcePixelSize: CGSize,
        destinationSize: CGSize,
        contextTransform: CGAffineTransform,
        maximumPixelDimension: CGFloat = maximumLiveRasterPixelDimension,
        maximumPixelCount: CGFloat = maximumLiveRasterPixelCount
    ) -> CGFloat? {
        guard destinationSize.width.isFinite,
              destinationSize.height.isFinite,
              destinationSize.width > 0,
              destinationSize.height > 0,
              maximumPixelDimension.isFinite,
              maximumPixelDimension > 0,
              maximumPixelCount.isFinite,
              maximumPixelCount >= 1 else { return nil }

        let horizontalScale = hypot(contextTransform.a, contextTransform.b)
        let verticalScale = hypot(contextTransform.c, contextTransform.d)
        guard horizontalScale.isFinite,
              verticalScale.isFinite,
              horizontalScale > 0,
              verticalScale > 0 else { return nil }

        let requiredMaximum = max(
            destinationSize.width * horizontalScale,
            destinationSize.height * verticalScale
        )
        guard requiredMaximum.isFinite, requiredMaximum > 0 else { return nil }

        var tier = minimumLiveRasterDecodeDimension
        while tier < requiredMaximum, tier < maximumPixelDimension {
            tier *= 2
        }
        return boundedDecodeMaximum(
            sourcePixelSize: sourcePixelSize,
            requestedMaximum: min(tier, maximumPixelDimension),
            maximumPixelDimension: maximumPixelDimension,
            maximumPixelCount: maximumPixelCount
        )
    }

    /// Returns an integer longest-edge request whose corresponding short edge
    /// (rounded up as ImageIO may do) cannot cross the pixel-count ceiling.
    /// Binary search also handles panoramas without overflowing intermediate
    /// integer multiplication.
    static func boundedDecodeMaximum(
        sourcePixelSize: CGSize,
        requestedMaximum: CGFloat,
        maximumPixelDimension: CGFloat,
        maximumPixelCount: CGFloat
    ) -> CGFloat? {
        guard sourcePixelSize.width.isFinite,
              sourcePixelSize.height.isFinite,
              sourcePixelSize.width > 0,
              sourcePixelSize.height > 0,
              requestedMaximum.isFinite,
              requestedMaximum > 0,
              maximumPixelDimension.isFinite,
              maximumPixelDimension > 0,
              maximumPixelCount.isFinite,
              maximumPixelCount >= 1 else { return nil }

        let sourceLongest = max(sourcePixelSize.width, sourcePixelSize.height)
        let sourceShortest = min(sourcePixelSize.width, sourcePixelSize.height)
        guard sourceLongest < CGFloat(Int.max),
              sourceShortest < CGFloat(Int.max),
              maximumPixelCount < CGFloat(Int.max) else { return nil }

        var lowerBound = 1
        var upperBound = max(
            1,
            Int(floor(min(sourceLongest, requestedMaximum, maximumPixelDimension)))
        )
        let pixelLimit = Int(floor(maximumPixelCount))
        var best = 1
        while lowerBound <= upperBound {
            let candidate = lowerBound + (upperBound - lowerBound) / 2
            let shortEdge = max(
                1,
                Int(ceil(CGFloat(candidate) * sourceShortest / sourceLongest))
            )
            let (pixelCount, overflow) = candidate.multipliedReportingOverflow(
                by: shortEdge
            )
            if overflow == false, pixelCount <= pixelLimit {
                best = candidate
                lowerBound = candidate + 1
            } else {
                upperBound = candidate - 1
            }
        }
        return CGFloat(best)
    }

    fileprivate static func decodedImage(
        from data: Data,
        maximumPixelDimension: CGFloat?,
        maximumPixelCount: CGFloat = maximumRasterPixelCount
    ) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
            as? [CFString: Any]
        let sourceWidth = CGFloat(
            (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        )
        let sourceHeight = CGFloat(
            (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        )
        let sourceMaximum = max(sourceWidth, sourceHeight)
        guard sourceMaximum > 0 else { return nil }

        let requestedMaximum = maximumPixelDimension.flatMap { value in
            value.isFinite && value > 0 ? value : nil
        } ?? maximumRasterPixelDimension
        guard let decodeMaximum = boundedDecodeMaximum(
            sourcePixelSize: CGSize(width: sourceWidth, height: sourceHeight),
            requestedMaximum: requestedMaximum,
            maximumPixelDimension: requestedMaximum,
            maximumPixelCount: maximumPixelCount
        ) else { return nil }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(ceil(decodeMaximum)),
            kCGImageSourceShouldCacheImmediately: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            options as CFDictionary
        ) else { return nil }
        let (pixelCount, overflow) = image.width.multipliedReportingOverflow(by: image.height)
        guard overflow == false,
              CGFloat(max(image.width, image.height)) <= decodeMaximum,
              CGFloat(pixelCount) <= maximumPixelCount else { return nil }
        return image
    }

    fileprivate static func drawImage(
        _ image: CGImage,
        aspectFitIn destination: CGRect,
        context: CGContext
    ) {
        let sourceSize = CGSize(width: image.width, height: image.height)
        let scale = min(
            destination.width / max(sourceSize.width, 1),
            destination.height / max(sourceSize.height, 1)
        )
        let fittedSize = CGSize(
            width: sourceSize.width * scale,
            height: sourceSize.height * scale
        )
        let frame = CGRect(
            x: destination.midX - fittedSize.width / 2,
            y: destination.midY - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )

        // CGImage uses a bottom-left image coordinate system; flip only the
        // fitted image, leaving the PaperKit page in top-left coordinates.
        context.saveGState()
        context.translateBy(x: frame.minX, y: frame.maxY)
        context.scaleBy(
            x: frame.width / CGFloat(image.width),
            y: -frame.height / CGFloat(image.height)
        )
        context.draw(
            image,
            in: CGRect(x: 0, y: 0, width: image.width, height: image.height)
        )
        context.restoreGState()
    }

    fileprivate static func drawPDFPage(
        _ page: CGPDFPage,
        aspectFitIn destination: CGRect,
        context: CGContext
    ) {
        let cropBox = page.getBoxRect(.cropBox)
        let sourceBox: CGPDFBox = cropBox.isNull || cropBox.isEmpty
            ? .mediaBox
            : .cropBox
        // CGPDFPage's drawing transform handles non-zero media-box origins and
        // intrinsic page rotation. Prefer the authored crop box so imported
        // annotations and exports match the page the user saw in the source
        // document instead of revealing clipped printer marks. Flip the coordinate system
        // once because the enclosing PaperKit context is top-left based.
        context.saveGState()
        context.translateBy(x: 0, y: destination.height)
        context.scaleBy(x: 1, y: -1)
        context.concatenate(
            page.getDrawingTransform(
                sourceBox,
                rect: destination,
                rotate: 0,
                preserveAspectRatio: true
            )
        )
        context.drawPDFPage(page)
        context.restoreGState()
    }

    fileprivate static func applyRotation(
        _ quarterTurns: Int,
        authoredSize: CGSize,
        context: CGContext
    ) {
        switch quarterTurns {
        case 1:
            context.concatenate(
                CGAffineTransform(
                    a: 0,
                    b: 1,
                    c: -1,
                    d: 0,
                    tx: authoredSize.height,
                    ty: 0
                )
            )
        case 2:
            context.concatenate(
                CGAffineTransform(
                    a: -1,
                    b: 0,
                    c: 0,
                    d: -1,
                    tx: authoredSize.width,
                    ty: authoredSize.height
                )
            )
        case 3:
            context.concatenate(
                CGAffineTransform(
                    a: 0,
                    b: -1,
                    c: 1,
                    d: 0,
                    tx: 0,
                    ty: authoredSize.width
                )
            )
        default:
            break
        }
    }
}

/// Prepared immutable source shared by CATiledLayer draw callbacks. A PDF page
/// stays vector; an image is decoded once at a bounded, orientation-correct
/// resolution. The PDF lock prevents Quartz from entering the same document
/// concurrently when CATiledLayer asks for adjacent tiles in parallel.
final class CanvasPageBackgroundDrawingSource: @unchecked Sendable {
    private struct ImagePayload {
        let data: Data
        let sourcePixelSize: CGSize
        let maximumPixelDimension: CGFloat
        let maximumPixelCount: CGFloat
        let adaptsResolutionToContext: Bool
    }

    private enum Payload {
        case image(ImagePayload)
        case pdf(document: CGPDFDocument, page: CGPDFPage)
    }

    private let payload: Payload
    private let geometry: CanvasPageGeometry
    private let imageDecodeLock = NSLock()
    private let pdfDrawLock = NSLock()
    private var decodedImage: CGImage?
    /// The demand used to populate `decodedImage`. It is intentionally
    /// monotonic for the lifetime of this visible page source: zooming out
    /// never triggers decode churn or silently replaces a sharper cache.
    private var decodedImageMaximumRequest: CGFloat = 0

    init?(
        background: CanvasPageBackground,
        geometry: CanvasPageGeometry,
        maximumImagePixelDimension: CGFloat?,
        maximumImagePixelCount: CGFloat,
        adaptsImageResolutionToContext: Bool
    ) {
        guard geometry.isValid else { return nil }
        self.geometry = geometry

        switch background {
        case .paper:
            return nil

        case let .image(source, _):
            guard let data = source.imageData,
                  let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(imageSource) > 0,
                  let properties = CGImageSourceCopyPropertiesAtIndex(
                    imageSource,
                    0,
                    [kCGImageSourceShouldCache: false] as CFDictionary
                  ) as? [CFString: Any],
                  let sourceWidth = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let sourceHeight = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  sourceWidth.doubleValue.isFinite,
                  sourceHeight.doubleValue.isFinite,
                  sourceWidth.doubleValue > 0,
                  sourceHeight.doubleValue > 0 else { return nil }
            // Keep the original encoded bytes and defer the bounded decode to
            // CATiledLayer's asynchronous draw callback. Opening a large photo
            // therefore does not synchronously inflate a multi-megabyte bitmap
            // on the main actor.
            let configuredMaximum = maximumImagePixelDimension.flatMap { value in
                value.isFinite && value > 0 ? value : nil
            } ?? CanvasPageBackgroundRenderer.maximumRasterPixelDimension
            let configuredPixelCount = maximumImagePixelCount.isFinite
                && maximumImagePixelCount >= 1
                ? maximumImagePixelCount
                : CanvasPageBackgroundRenderer.maximumRasterPixelCount
            payload = .image(ImagePayload(
                data: data,
                sourcePixelSize: CGSize(
                    width: sourceWidth.doubleValue,
                    height: sourceHeight.doubleValue
                ),
                maximumPixelDimension: configuredMaximum,
                maximumPixelCount: configuredPixelCount,
                adaptsResolutionToContext: adaptsImageResolutionToContext
            ))

        case let .pdfPage(source, pageIndex, _):
            guard let data = source.documentData,
                  let provider = CGDataProvider(data: data as CFData),
                  let document = CGPDFDocument(provider),
                  document.isUnlocked,
                  pageIndex >= 0,
                  pageIndex < document.numberOfPages,
                  let page = document.page(at: pageIndex + 1) else { return nil }
            payload = .pdf(document: document, page: page)
        }
    }

    func draw(in context: CGContext, destinationRect: CGRect) {
        guard destinationRect.isNull == false,
              destinationRect.isEmpty == false,
              destinationRect.width.isFinite,
              destinationRect.height.isFinite else { return }

        context.saveGState()
        defer { context.restoreGState() }
        context.clip(to: destinationRect)
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(destinationRect)
        context.interpolationQuality = .high

        let displaySize = geometry.displaySize
        context.translateBy(x: destinationRect.minX, y: destinationRect.minY)
        context.scaleBy(
            x: destinationRect.width / displaySize.width,
            y: destinationRect.height / displaySize.height
        )
        CanvasPageBackgroundRenderer.applyRotation(
            geometry.quarterTurns,
            authoredSize: geometry.authoredSize,
            context: context
        )

        let authoredRect = CGRect(origin: .zero, size: geometry.authoredSize)
        switch payload {
        case let .image(imagePayload):
            let adaptiveMaximum = imagePayload.adaptsResolutionToContext
                ? CanvasPageBackgroundRenderer.adaptiveRasterDecodeMaximum(
                    sourcePixelSize: imagePayload.sourcePixelSize,
                    destinationSize: destinationRect.size,
                    contextTransform: context.ctm,
                    maximumPixelDimension: imagePayload.maximumPixelDimension,
                    maximumPixelCount: imagePayload.maximumPixelCount
                )
                : nil
            let requestedMaximum = adaptiveMaximum ?? min(
                imagePayload.maximumPixelDimension,
                CanvasPageBackgroundRenderer.maximumRasterPixelDimension
            )
            let requestedPixelCount = adaptiveMaximum == nil
                ? min(
                    imagePayload.maximumPixelCount,
                    CanvasPageBackgroundRenderer.maximumRasterPixelCount
                )
                : imagePayload.maximumPixelCount

            imageDecodeLock.lock()
            let image: CGImage?
            if let decodedImage,
               decodedImageMaximumRequest >= requestedMaximum {
                image = decodedImage
            } else {
                let previousImage = decodedImage
                let previousRequest = decodedImageMaximumRequest
                let promotedImage = CanvasPageBackgroundRenderer.decodedImage(
                    from: imagePayload.data,
                    maximumPixelDimension: requestedMaximum,
                    maximumPixelCount: requestedPixelCount
                )
                if let promotedImage {
                    decodedImage = promotedImage
                    decodedImageMaximumRequest = requestedMaximum
                    image = promotedImage
                } else {
                    // A transient decode failure must not replace a valid lower
                    // resolution page with white. Keep the last bounded cache;
                    // a later tile may retry the promotion.
                    decodedImage = previousImage
                    decodedImageMaximumRequest = previousRequest
                    image = previousImage
                }
            }
            imageDecodeLock.unlock()
            guard let image else { return }
            CanvasPageBackgroundRenderer.drawImage(
                image,
                aspectFitIn: authoredRect,
                context: context
            )

        case let .pdf(_, page):
            pdfDrawLock.lock()
            defer { pdfDrawLock.unlock() }
            CanvasPageBackgroundRenderer.drawPDFPage(
                page,
                aspectFitIn: authoredRect,
                context: context
            )
        }
    }

    #if DEBUG
    var cachedRasterPixelSizeForTesting: CGSize? {
        imageDecodeLock.lock()
        defer { imageDecodeLock.unlock() }
        return decodedImage.map {
            CGSize(width: $0.width, height: $0.height)
        }
    }

    var cachedRasterMaximumRequestForTesting: CGFloat {
        imageDecodeLock.lock()
        defer { imageDecodeLock.unlock() }
        return decodedImageMaximumRequest
    }
    #endif
}

/// CATiledLayer invokes `draw(in:)` on one or more private background queues.
/// Keeping that callback on the layer is important: `UIView.draw(_:)` is
/// MainActor-isolated, so using a UIView draw override with CATiledLayer trips
/// Swift's runtime queue precondition as soon as the first PDF/image tiles are
/// requested. This layer owns only immutable, Sendable drawing input and a
/// thread-safe drawing source, so its nonisolated callback is safe to execute
/// on Core Animation's render workers.
final class CanvasImportedPageTiledLayer: CATiledLayer {
    private let drawingSource: CanvasPageBackgroundDrawingSource?

    init(drawingSource: CanvasPageBackgroundDrawingSource) {
        self.drawingSource = drawingSource
        super.init()

        tileSize = CGSize(width: 512, height: 512)
        levelsOfDetail = 1
        levelsOfDetailBias = 4
        drawsAsynchronously = true
    }

    override init(layer: Any) {
        drawingSource = (layer as? CanvasImportedPageTiledLayer)?.drawingSource
        super.init(layer: layer)
    }

    nonisolated override func draw(in context: CGContext) {
        drawingSource?.draw(in: context, destinationRect: bounds)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }
}

/// Live editor surface for an imported page. CATiledLayer asks Quartz for only
/// the visible tiles at the current zoom, so PDFs remain vector-sharp without
/// allocating a full-page bitmap at 1000%. PaperPageContentView destroys this
/// view when its page leaves the render window, evicting all cached tiles.
final class CanvasImportedPageBackgroundView: UIView {
    private let tiledLayer: CanvasImportedPageTiledLayer

    init?(
        background: CanvasPageBackground,
        geometry: CanvasPageGeometry,
        maximumImagePixelDimension: CGFloat =
            CanvasPageBackgroundRenderer.maximumLiveRasterPixelDimension
    ) {
        guard let drawingSource = CanvasPageBackgroundRenderer.drawingSource(
            for: background,
            geometry: geometry,
            maximumImagePixelDimension: maximumImagePixelDimension,
            maximumImagePixelCount: CanvasPageBackgroundRenderer.maximumLiveRasterPixelCount,
            adaptsImageResolutionToContext: true
        ) else { return nil }
        tiledLayer = CanvasImportedPageTiledLayer(drawingSource: drawingSource)
        super.init(frame: .zero)

        isOpaque = true
        isUserInteractionEnabled = false
        backgroundColor = .white
        layer.addSublayer(tiledLayer)
        tiledLayer.contentsScale = traitCollection.displayScale
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        tiledLayer.frame = bounds
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        tiledLayer.contentsScale = window?.screen.scale ?? traitCollection.displayScale
    }

    #if DEBUG
    var usesBackgroundSafeTiledLayerForTesting: Bool {
        tiledLayer.superlayer === layer
    }
    #endif

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        return nil
    }
}
