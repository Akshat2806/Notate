import CoreGraphics
import Foundation
import PaperKit
import PencilKit
import UIKit

enum CanvasPaperRenderingEnvironment {
    static var lightOptions: RenderingOptions {
        let languageIdentifier = Locale.preferredLanguages.first
            ?? Locale.current.identifier
        let isRightToLeft = Locale.Language(identifier: languageIdentifier)
            .characterDirection == .rightToLeft
        return RenderingOptions(
            darkUserInterfaceStyle: false,
            layoutRightToLeft: isRightToLeft
        )
    }
}

public enum CanvasTool: String, CaseIterable, Codable, Sendable {
    case lasso
    case pen
    case ballpoint
    case calligraphy
    case pencil
    case fountainPen
    case watercolor
    case crayon
    case highlighter
    case laserPointer
    case eraser

    public var title: String {
        switch self {
            case .lasso: "Lasso"
            case .pen: "Monoline"
            case .ballpoint: "Ballpoint"
            case .calligraphy: "Calligraphy"
            case .pencil: "Pencil"
            case .fountainPen: "Fountain Pen"
            case .watercolor: "Watercolor"
            case .crayon: "Crayon"
            case .highlighter: "Highlighter"
            case .laserPointer: "Laser Pointer"
            case .eraser: "Eraser"
        }
    }

    public var supportsOptions: Bool {
        self != .lasso
    }

    /// Extra inks share an existing toolbar slot so the primary picker keeps
    /// its current width, spacing, and five-writing-tool rhythm.
    public var toolbarFamilyRoot: CanvasTool {
        switch self {
        case .ballpoint, .calligraphy:
            .pen
        case .watercolor, .crayon:
            .fountainPen
        default:
            self
        }
    }

    public var toolbarFamilyVariants: [CanvasTool] {
        switch toolbarFamilyRoot {
        case .pen:
            [.pen, .ballpoint, .calligraphy]
        case .fountainPen:
            [.fountainPen, .watercolor, .crayon]
        default:
            [toolbarFamilyRoot]
        }
    }

    public var toolbarFamilyTitle: String {
        switch toolbarFamilyRoot {
            case .pen: "Pen"
            case .fountainPen: "Brush"
            default: toolbarFamilyRoot.title
        }
    }
}

public enum CanvasOverlay: Equatable, Sendable {
    case none
    case toolOptions(CanvasTool)
    case insert
    case geometryTools
    case shapes
    case tableSizePicker
}

public enum CanvasInputMode: String, Codable, Sendable {
    case pencilOnly
    case pencilAndFinger
}

public enum CanvasLaserPointerStyle: String, CaseIterable, Codable, Sendable {
    case dot
    case trail

    public var title: String {
        switch self {
            case .dot: "Dot"
            case .trail: "Trail"
        }
    }
}

public enum CanvasPageInsertionPosition: Sendable {
    case start
    case afterCurrent
    case end
}

public enum CanvasPageRotationDirection: Equatable, Sendable {
    case left
    case right
}

    /// Editing topology is deliberately separate from the library route. Paged
    /// documents retain the notebook stack while a freeform item owns one logical
    /// board whose coordinate space grows around the viewport.
public enum CanvasDocumentMode: Equatable, Sendable {
    case paged
    case freeform
}

    /// The authored page order never changes when the user changes how a paged
    /// document is presented. This value selects only the primary scrolling axis.
public enum CanvasScrollDirection: String, CaseIterable, Codable, Sendable {
    case vertical
    case horizontal

    public var title: String {
        switch self {
        case .vertical: "Vertical"
        case .horizontal: "Horizontal"
        }
    }
}

    /// Legacy display values retained so older preference files continue to decode.
    /// Current UI and runtime behavior normalize every document to one page per slot.
public enum CanvasPageDisplayMode: String, CaseIterable, Codable, Sendable {
    case singlePage
    case twoPage

    public var title: String {
        switch self {
        case .singlePage: "Single Page"
        case .twoPage: "Two Pages"
        }
    }
}

public struct CanvasPageLayoutPreferences: Codable, Equatable, Sendable {
    public var scrollDirection: CanvasScrollDirection
    public var pageDisplayMode: CanvasPageDisplayMode

    public init(
        scrollDirection: CanvasScrollDirection = .vertical,
        pageDisplayMode: CanvasPageDisplayMode = .singlePage
    ) {
        self.scrollDirection = scrollDirection
        self.pageDisplayMode = pageDisplayMode
    }

    /// Two-page presentation is retained only for decoding older preference
    /// files. Current settings always preserve the chosen scrolling axis while
    /// presenting one page at a time.
    public var singlePageOnly: Self {
        Self(
            scrollDirection: scrollDirection,
            pageDisplayMode: .singlePage
        )
    }

    public static let `default` = CanvasPageLayoutPreferences()
}

    /// The page-turn animation used by Reader Mode's horizontal presentation.
    /// Vertical reading pages one full screen at a time and always uses the
    /// standard slide transition regardless of the stored preference.
public enum CanvasReaderPageTransition: String, CaseIterable, Codable, Sendable {
    case slide
    case pageCurl

    public var title: String {
        switch self {
        case .slide: "Slide"
        case .pageCurl: "Page Curl"
        }
    }
}

    /// Reader preferences are intentionally independent from the editing layout.
    /// Editing stays one-page-per-slot, while Reader Mode may present a spread
    /// when the actual canvas viewport is landscape.
public struct CanvasReaderPreferences: Codable, Equatable, Sendable {
    public var scrollDirection: CanvasScrollDirection
    public var landscapeDisplayMode: CanvasPageDisplayMode
    public var pageTransition: CanvasReaderPageTransition

    public init(
        scrollDirection: CanvasScrollDirection = .vertical,
        landscapeDisplayMode: CanvasPageDisplayMode = .singlePage,
        pageTransition: CanvasReaderPageTransition = .slide
    ) {
        self.scrollDirection = scrollDirection
        self.landscapeDisplayMode = landscapeDisplayMode
        self.pageTransition = pageTransition
    }

    /// Portrait, square, and portrait-shaped split-view canvases never show
    /// more than one page. A two-page spread is available only for horizontal
    /// reading when the canvas itself is wider than it is tall.
    public func resolvedPageLayout(for viewportSize: CGSize) -> CanvasPageLayoutPreferences {
        let hasUsableLandscapeViewport = viewportSize.width.isFinite
            && viewportSize.height.isFinite
            && viewportSize.width > viewportSize.height
            && viewportSize.height > 0
        let resolvedDisplayMode: CanvasPageDisplayMode = scrollDirection == .horizontal
            && hasUsableLandscapeViewport
            ? landscapeDisplayMode
            : .singlePage
        return CanvasPageLayoutPreferences(
            scrollDirection: scrollDirection,
            pageDisplayMode: resolvedDisplayMode
        )
    }

    public func resolvedPageTransition(
        for viewportSize: CGSize,
        reduceMotion: Bool
    ) -> CanvasReaderPageTransition {
        guard reduceMotion == false,
            scrollDirection == .horizontal,
            viewportSize.width.isFinite,
            viewportSize.height.isFinite,
            viewportSize.width > 0,
            viewportSize.height > 0 else {
            return .slide
        }
        return pageTransition
    }

    public static let `default` = CanvasReaderPreferences()
}

public enum CanvasPageBoundary: Hashable, Sendable {
    case start
    case end
}

public struct CanvasBoundaryPagePull: Equatable, Sendable {
    public let boundary: CanvasPageBoundary
    public let progress: CGFloat

    public init(boundary: CanvasPageBoundary, progress: CGFloat) {
        self.boundary = boundary
        self.progress = progress.isFinite ? progress.clamped(to: 0...1) : 0
    }

    public var isArmed: Bool { progress >= 1 }
}

public enum CanvasPaperStyle: String, CaseIterable, Codable, Sendable {
    case blank
    case ruled
    case grid
    case dotted
    case cornell
    case music

    public var title: String {
        switch self {
        case .blank: "Blank"
        case .ruled: "Ruled"
        case .grid: "Grid"
        case .dotted: "Dotted"
        case .cornell: "Cornell"
        case .music: "Music"
        }
    }

    public var systemImage: String {
        switch self {
        case .blank: "doc"
        case .ruled: "line.3.horizontal"
        case .grid: "square.grid.3x3"
        case .dotted: "circle.grid.3x3.fill"
        case .cornell: "rectangle.split.2x1"
        case .music: "music.note.list"
        }
    }
}

public enum CanvasPaperDensity: String, CaseIterable, Codable, Sendable {
    case narrow
    case standard
    case wide

    public var title: String {
        switch self {
        case .narrow: "Narrow"
        case .standard: "Standard"
        case .wide: "Wide"
        }
    }

    public var spacing: CGFloat {
        switch self {
        case .narrow: 20
        case .standard: 28
        case .wide: 36
        }
    }
}

public enum CanvasPaperTone: String, CaseIterable, Codable, Sendable {
    case white
    case warmWhite
    case cream
    case lightGray
    case blush
    case sky
    case mint
    case charcoal
    case midnight
    case black

    public var title: String {
        switch self {
        case .white: "White"
        case .warmWhite: "Warm White"
        case .cream: "Cream"
        case .lightGray: "Light Gray"
        case .blush: "Blush"
        case .sky: "Sky"
        case .mint: "Mint"
        case .charcoal: "Charcoal"
        case .midnight: "Midnight"
        case .black: "Black"
        }
    }

    public static let lightTones: [CanvasPaperTone] = [
        .white,
        .warmWhite,
        .cream,
        .lightGray,
        .blush,
        .sky,
        .mint,
    ]

    public static let darkTones: [CanvasPaperTone] = [
        .charcoal,
        .midnight,
        .black,
    ]

    public var isDark: Bool {
        switch self {
        case .charcoal, .midnight, .black:
            true
        case .white, .warmWhite, .cream, .lightGray, .blush, .sky, .mint:
            false
        }
    }

    public var cgColor: CGColor {
        switch self {
        case .white:
            CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case .warmWhite:
            CGColor(srgbRed: 1, green: 254 / 255, blue: 252 / 255, alpha: 1)
        case .cream:
            CGColor(srgbRed: 1, green: 248 / 255, blue: 231 / 255, alpha: 1)
        case .lightGray:
            CGColor(srgbRed: 244 / 255, green: 244 / 255, blue: 242 / 255, alpha: 1)
        case .blush:
            CGColor(srgbRed: 253 / 255, green: 238 / 255, blue: 241 / 255, alpha: 1)
        case .sky:
            CGColor(srgbRed: 234 / 255, green: 243 / 255, blue: 251 / 255, alpha: 1)
        case .mint:
            CGColor(srgbRed: 233 / 255, green: 246 / 255, blue: 238 / 255, alpha: 1)
        case .charcoal:
            CGColor(srgbRed: 45 / 255, green: 48 / 255, blue: 55 / 255, alpha: 1)
        case .midnight:
            CGColor(srgbRed: 25 / 255, green: 35 / 255, blue: 53 / 255, alpha: 1)
        case .black:
            CGColor(srgbRed: 17 / 255, green: 18 / 255, blue: 20 / 255, alpha: 1)
        }
    }

    @MainActor
    public var uiColor: UIColor {
        UIColor(cgColor: cgColor)
    }
}

public struct CanvasPaperTemplate: Codable, Equatable, Sendable {
    public var style: CanvasPaperStyle
    public var density: CanvasPaperDensity
    public var tone: CanvasPaperTone

    public init(
        style: CanvasPaperStyle,
        density: CanvasPaperDensity = .standard,
        tone: CanvasPaperTone = .warmWhite
    ) {
        self.style = style
        self.density = density
        self.tone = tone
    }


    public static let `default` = CanvasPaperTemplate(style: .blank)
    public var accessibilityValue: String {
        let densityDescription = style == .blank ? nil : density.title.lowercased()
        return [style.title, densityDescription, tone.title.lowercased()]
            .compactMap { $0 }
            .joined(separator: ", ")
    }
}

    /// Geometry authored by the source page. Rotation is stored independently so
    /// PDF/image bytes remain immutable while PaperKit markup can be transformed
    /// into the currently displayed coordinate space.
public struct CanvasPageGeometry: Codable, Equatable, Sendable {
    public var authoredWidth: Double
    public var authoredHeight: Double
    public var quarterTurns: Int
    /// The logical coordinate represented by stored point (0, 0). Freeform
    /// boards move this origin when space is inserted on their leading/top
    /// edges, allowing content coordinates to remain stable across rebases.
    public var logicalOriginX: Double
    public var logicalOriginY: Double

    public init(
        authoredSize: CGSize = CanvasConstants.a4PortraitSize,
        quarterTurns: Int = 0,
        logicalOrigin: CGPoint = .zero
    ) {
        authoredWidth = Double(authoredSize.width)
        authoredHeight = Double(authoredSize.height)
        self.quarterTurns = Self.normalized(quarterTurns)
        logicalOriginX = Double(logicalOrigin.x)
        logicalOriginY = Double(logicalOrigin.y)
    }

    public var authoredSize: CGSize {
        CGSize(width: authoredWidth, height: authoredHeight)
    }

    public var displaySize: CGSize {
        quarterTurns.isMultiple(of: 2)
            ? authoredSize
            : CGSize(width: authoredHeight, height: authoredWidth)
    }

    public var logicalOrigin: CGPoint {
        CGPoint(x: logicalOriginX, y: logicalOriginY)
    }

    public var isValid: Bool {
        authoredWidth.isFinite && authoredHeight.isFinite
            && authoredWidth > 0 && authoredHeight > 0
            && authoredWidth <= Double(CanvasConstants.maximumPersistedCanvasDimension)
            && authoredHeight <= Double(CanvasConstants.maximumPersistedCanvasDimension)
            && logicalOriginX.isFinite && logicalOriginY.isFinite
            && (0...3).contains(quarterTurns)
    }

    public func rotated(clockwise: Bool) -> CanvasPageGeometry {
        CanvasPageGeometry(
            authoredSize: authoredSize,
            quarterTurns: quarterTurns + (clockwise ? 1 : -1),
            logicalOrigin: logicalOrigin
        )
    }

    private enum CodingKeys: String, CodingKey {
        case authoredWidth
        case authoredHeight
        case quarterTurns
        case logicalOriginX
        case logicalOriginY
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        authoredWidth = try container.decode(Double.self, forKey: .authoredWidth)
        authoredHeight = try container.decode(Double.self, forKey: .authoredHeight)
        quarterTurns = Self.normalized(
            try container.decode(Int.self, forKey: .quarterTurns)
        )
        // Canvas Core v4 files written before freeform rebasing have an
        // implicit zero logical origin.
        logicalOriginX = try container.decodeIfPresent(
            Double.self,
            forKey: .logicalOriginX
        ) ?? 0
        logicalOriginY = try container.decodeIfPresent(
            Double.self,
            forKey: .logicalOriginY
        ) ?? 0
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(authoredWidth, forKey: .authoredWidth)
        try container.encode(authoredHeight, forKey: .authoredHeight)
        try container.encode(quarterTurns, forKey: .quarterTurns)
        try container.encode(logicalOriginX, forKey: .logicalOriginX)
        try container.encode(logicalOriginY, forKey: .logicalOriginY)
    }

    private static func normalized(_ value: Int) -> Int {
        let remainder = value % 4
        return remainder >= 0 ? remainder : remainder + 4
    }
}

/// A stable item-scoped reference to one immutable source PDF.
///
/// `relativePath` is persisted relative to the item's `Sources` directory.
/// `documentData` is hydrated once when a checkpoint opens (or supplied by the
/// importer before its first checkpoint) and is deliberately excluded from
/// the Canvas Core envelope. Every page can therefore share the same source
/// bytes in memory without serializing a full PDF once per page.
public struct CanvasPDFSourceReference: Equatable, Sendable {
    public let relativePath: String
    public let documentData: Data?
    public let contentChecksum: String?

    public init(
        relativePath: String,
        documentData: Data? = nil,
        contentChecksum: String? = nil
    ) {
        self.relativePath = relativePath
        self.documentData = documentData
        self.contentChecksum = contentChecksum
    }

    public var isValid: Bool {
        guard relativePath.isEmpty == false,
            relativePath.hasPrefix("/") == false,
            relativePath.hasPrefix("~") == false else { return false }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        let pathIsValid = components.isEmpty == false
            && components.allSatisfy { component in
                component.isEmpty == false && component != "." && component != ".."
            }
        let checksumIsValid = contentChecksum.map { checksum in
            checksum.count == 64
                && checksum.allSatisfy { $0.isHexDigit && $0.isUppercase == false }
        } ?? true
        return pathIsValid && checksumIsValid
    }

    public func resolving(documentData: Data) -> CanvasPDFSourceReference {
        CanvasPDFSourceReference(
            relativePath: relativePath,
            documentData: documentData,
            contentChecksum: contentChecksum
        )
    }
}

/// A stable item-scoped reference to one immutable source image.
///
/// The original bytes live in the item's `Sources` directory. `imageData` is
/// hydrated for editing/rendering but is never written into a v5-or-later checkpoint.
public struct CanvasImageSourceReference: Equatable, Sendable {
    public let relativePath: String
    public let imageData: Data?
    public let contentChecksum: String?

    public init(
        relativePath: String,
        imageData: Data? = nil,
        contentChecksum: String? = nil
    ) {
        self.relativePath = relativePath
        self.imageData = imageData
        self.contentChecksum = contentChecksum
    }

    public var isValid: Bool {
        guard relativePath.isEmpty == false,
            relativePath.hasPrefix("/") == false,
            relativePath.hasPrefix("~") == false else { return false }
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        let pathIsValid = components.isEmpty == false
            && components.allSatisfy { component in
                component.isEmpty == false && component != "." && component != ".."
            }
        let checksumIsValid = contentChecksum.map { checksum in
            checksum.count == 64
                && checksum.allSatisfy { $0.isHexDigit && $0.isUppercase == false }
        } ?? true
        return pathIsValid && checksumIsValid
    }

    public func resolving(imageData: Data) -> CanvasImageSourceReference {
        CanvasImageSourceReference(
            relativePath: relativePath,
            imageData: imageData,
            contentChecksum: contentChecksum
        )
    }
}

    /// Immutable content rendered beneath PaperKit markup. Images remain embedded
    /// only in memory; both images and PDFs persist as item-scoped source files.
public enum CanvasPageBackground: Equatable, Sendable {
    case paper
    case image(source: CanvasImageSourceReference, suggestedName: String?)
    case pdfPage(
        source: CanvasPDFSourceReference,
        pageIndex: Int,
        suggestedName: String?
    )

    /// Keeps the existing call-site ergonomics for photos created in memory.
    /// Importers that have already written the source should pass its exact
    /// item-relative filename through `sourceRelativePath`.
    public static func image(
        data: Data,
        suggestedName: String?,
        sourceRelativePath: String? = nil
    ) -> CanvasPageBackground {
        let relativePath = sourceRelativePath.flatMap { candidate in
            let reference = CanvasImageSourceReference(relativePath: candidate)
            return reference.isValid ? candidate : nil
        } ?? generatedImageSourcePath(suggestedName: suggestedName)
        return .image(
            source: CanvasImageSourceReference(
                relativePath: relativePath,
                imageData: data
            ),
            suggestedName: suggestedName
        )
    }

    public var isImported: Bool {
        switch self {
        case .paper: false
        case .image, .pdfPage: true
        }
    }

    public var suggestedName: String? {
        switch self {
        case .paper:
            nil
        case let .image(_, suggestedName), let .pdfPage(_, _, suggestedName):
            suggestedName
        }
    }

    public var isValid: Bool {
        switch self {
        case .paper:
            true
        case let .image(source, _):
            source.isValid && source.imageData?.isEmpty != true
        case let .pdfPage(source, pageIndex, _):
            source.isValid && pageIndex >= 0 && pageIndex < Int.max
        }
    }

    private static func generatedImageSourcePath(suggestedName: String?) -> String {
        let pathExtension = URL(fileURLWithPath: suggestedName ?? "")
            .pathExtension
            .lowercased()
        let safeExtension = pathExtension.isEmpty
            || pathExtension.count > 12
            || pathExtension.allSatisfy({ $0.isLetter || $0.isNumber }) == false
            ? "image"
            : pathExtension
        return "image-\(UUID().uuidString).\(safeExtension)"
    }
}

public enum CanvasPaperTemplateGeometry {
    private static let maximumAuthoredPositions = 100_000
    public static let cornellHeaderY: CGFloat = 112
    public static let cornellCueX: CGFloat = 168
    public static let cornellSummaryY: CGFloat = 704
    public static let musicStaffLineCount = 5

    /// Music density controls both the distance between staff lines and the
    /// breathing room between complete staffs. A standard 28-point paper
    /// rhythm therefore produces familiar seven-point staff lines while
    /// retaining enough room for notes and annotations between groups.
    public static func musicStaffLineSpacing(for density: CanvasPaperDensity) -> CGFloat {
        density.spacing / CGFloat(musicStaffLineCount - 1)
    }

    public static func musicStaffStride(for density: CanvasPaperDensity) -> CGFloat {
        density.spacing * 2.5
    }

    public static func musicStaffLinePositions(
        for template: CanvasPaperTemplate,
        pageSize: CGSize = CanvasConstants.a4PortraitSize
    ) -> [[CGFloat]] {
        guard template.style == .music,
            pageSize.width.isFinite,
            pageSize.height.isFinite,
            pageSize.width >= 0,
            pageSize.height >= 0 else { return [] }
        let lineSpacing = musicStaffLineSpacing(for: template.density)
        let staffHeight = lineSpacing * CGFloat(musicStaffLineCount - 1)
        guard pageSize.height >= staffHeight else { return [] }
        let topPositions = centeredPositions(
            along: pageSize.height - staffHeight,
            spacing: musicStaffStride(for: template.density)
        )
        guard topPositions.count <= maximumAuthoredPositions / musicStaffLineCount else {
            return []
        }
        return topPositions.map { top in
            (0..<musicStaffLineCount).map { lineIndex in
                top + CGFloat(lineIndex) * lineSpacing
            }
        }
    }

    public static func horizontalRulePositions(
        for template: CanvasPaperTemplate,
        pageSize: CGSize = CanvasConstants.a4PortraitSize
    ) -> [CGFloat] {
        guard template.style != .blank,
            pageSize.width.isFinite,
            pageSize.height.isFinite,
            pageSize.width >= 0,
            pageSize.height >= 0 else { return [] }
        if template.style == .music {
            return musicStaffLinePositions(for: template, pageSize: pageSize).flatMap { $0 }
        }
        if template.style == .cornell {
            let bodyEnd = min(cornellSummaryY, pageSize.height)
            guard cornellHeaderY <= bodyEnd else { return [] }
            return centeredPositions(
                in: cornellHeaderY...bodyEnd,
                spacing: template.density.spacing,
                minimumEdgeGap: template.density.spacing / 2
            )
        }
        return centeredPositions(
            along: pageSize.height,
            spacing: template.density.spacing
        )
    }

    public static func verticalRulePositions(
        for template: CanvasPaperTemplate,
        pageSize: CGSize = CanvasConstants.a4PortraitSize
    ) -> [CGFloat] {
        guard template.style == .grid,
            pageSize.width.isFinite,
            pageSize.height.isFinite,
            pageSize.width >= 0,
            pageSize.height >= 0 else { return [] }
        return centeredPositions(
            along: pageSize.width,
            spacing: template.density.spacing
        )
    }

    public static func dotCenters(
        for template: CanvasPaperTemplate,
        pageSize: CGSize = CanvasConstants.a4PortraitSize
    ) -> [CGPoint] {
        guard template.style == .dotted,
            pageSize.width.isFinite,
            pageSize.height.isFinite,
            pageSize.width >= 0,
            pageSize.height >= 0 else { return [] }
        let xs = centeredPositions(along: pageSize.width, spacing: template.density.spacing)
        let ys = centeredPositions(along: pageSize.height, spacing: template.density.spacing)
        guard xs.isEmpty || ys.count <= maximumAuthoredPositions / xs.count else {
            return []
        }
        return ys.flatMap { y in xs.map { x in CGPoint(x: x, y: y) } }
    }

    /// Creates a periodic lattice across an entire authored dimension without
    /// imposing a writing margin. Any remainder is split equally between both
    /// edges so the pattern looks intentional instead of padded.
    public static func centeredPositions(
        along length: CGFloat,
        spacing: CGFloat
    ) -> [CGFloat] {
        guard length.isFinite, length >= 0 else { return [] }
        return centeredPositions(in: 0...length, spacing: spacing, minimumEdgeGap: 0)
    }

    private static func centeredPositions(
        in range: ClosedRange<CGFloat>,
        spacing: CGFloat,
        minimumEdgeGap: CGFloat
    ) -> [CGFloat] {
        guard spacing.isFinite,
            spacing > 0,
            minimumEdgeGap.isFinite,
            minimumEdgeGap >= 0,
            range.lowerBound.isFinite,
            range.upperBound.isFinite,
            range.lowerBound <= range.upperBound else { return [] }
        let availableLength = range.upperBound - range.lowerBound - (minimumEdgeGap * 2)
        guard availableLength.isFinite,
            availableLength >= 0,
            availableLength / spacing < CGFloat(Int.max) else { return [] }

        let intervalCount = Int(floor(availableLength / spacing))
        guard intervalCount < maximumAuthoredPositions else { return [] }
        let occupiedLength = CGFloat(intervalCount) * spacing
        let balancedRemainder = (availableLength - occupiedLength) / 2
        let first = range.lowerBound + minimumEdgeGap + balancedRemainder

        return (0...intervalCount).map { first + CGFloat($0) * spacing }
    }
}

public enum CanvasEraserMode: String, CaseIterable, Codable, Sendable {
    case pixel
    case stroke
}

public enum CanvasShape: String, CaseIterable, Codable, Sendable {
    case rectangle
    case roundedRectangle
    case ellipse
    case line
    case arrow
    case star
    case speechBubble
    case polygon

    public var title: String {
        switch self {
        case .rectangle: "Rectangle"
        case .roundedRectangle: "Rounded Rectangle"
        case .ellipse: "Ellipse"
        case .line: "Line"
        case .arrow: "Arrow"
        case .star: "Star"
        case .speechBubble: "Speech Bubble"
        case .polygon: "Polygon"
        }
    }

    public var paperKitShape: ShapeConfiguration.Shape {
        switch self {
        case .rectangle: .rectangle
        case .roundedRectangle: .roundedRectangle
        case .ellipse: .ellipse
        case .line: .line
        case .arrow: .arrowShape
        case .star: .star
        case .speechBubble: .chatBubble
        case .polygon: .regularPolygon
        }
    }
}

    /// The explicit size selected in the Add tray before a table is inserted.
    /// Keeping this value typed prevents invalid picker state from crossing the
    /// canvas command boundary.
public struct CanvasTableSize: Codable, Equatable, Hashable, Sendable {
    public static let pickerRange = 1...8
    public static let standard = CanvasTableSize(rowCount: 2, columnCount: 2)

    public let rowCount: Int
    public let columnCount: Int

    public init(rowCount: Int, columnCount: Int) {
        self.rowCount = rowCount
        self.columnCount = columnCount
    }

    public var isValid: Bool {
        (CanvasTable.minimumRowCount...CanvasTable.maximumRowCount).contains(rowCount)
            && (CanvasTable.minimumColumnCount...CanvasTable.maximumColumnCount)
            .contains(columnCount)
    }
}

    /// A semantic table owned by Canvas Core rather than PaperKit. PaperKit 26 has
    /// no table element or stable element identifiers, so keeping this geometry in
    /// the page snapshot lets Notate redraw and resize the table without trying to
    /// reverse-engineer a collection of unrelated line markups.
public struct CanvasTable: Codable, Equatable, Identifiable, Sendable {
    public static let minimumRowCount = 1
    public static let minimumColumnCount = 1
    public static let defaultRowCount = 2
    public static let defaultColumnCount = 2
    public static let maximumRowCount = 256
    public static let maximumColumnCount = 256
    public static let defaultCellSize = CGSize(width: 76, height: 52)
    public static let defaultCornerRadius: CGFloat = 0

    public let id: UUID
    public var origin: CGPoint
    public var rowCount: Int
    public var columnCount: Int
    public var cellSize: CGSize
    public var cornerRadius: CGFloat

    public init(
        id: UUID = UUID(),
        origin: CGPoint,
        rowCount: Int = Self.defaultRowCount,
        columnCount: Int = Self.defaultColumnCount,
        cellSize: CGSize = Self.defaultCellSize,
        cornerRadius: CGFloat = Self.defaultCornerRadius
    ) {
        self.id = id
        self.origin = origin
        self.rowCount = rowCount
        self.columnCount = columnCount
        self.cellSize = cellSize
        self.cornerRadius = cornerRadius
    }

    public var frame: CGRect {
        CGRect(
            origin: origin,
            size: CGSize(
                width: cellSize.width * CGFloat(columnCount),
                height: cellSize.height * CGFloat(rowCount)
            )
        )
    }

    /// Persistence validation is intentionally stricter than drawing-time
    /// clamping. Invalid or off-page tables must never make an otherwise valid
    /// checkpoint unrecoverable after it has been published.
    public func isValid(in pageBounds: CGRect) -> Bool {
        guard origin.x.isFinite,
            origin.y.isFinite,
            cellSize.width.isFinite,
            cellSize.height.isFinite,
            cornerRadius.isFinite,
            cellSize.width > 0,
            cellSize.height > 0,
            (Self.minimumRowCount...Self.maximumRowCount).contains(rowCount),
            (Self.minimumColumnCount...Self.maximumColumnCount).contains(columnCount),
            cornerRadius >= 0,
            cornerRadius <= min(cellSize.width, cellSize.height) / 2 else {
            return false
        }

        let frame = frame
        guard frame.origin.x.isFinite,
            frame.origin.y.isFinite,
            frame.width.isFinite,
            frame.height.isFinite,
            frame.isNull == false,
            frame.isInfinite == false,
            frame.isEmpty == false else {
            return false
        }
        return pageBounds.contains(frame)
    }
}
    /// Transient drawing aids that sit above the focused PaperKit page. Only the
    /// ruler is supplied by PaperKit; Notate owns the protractor and compass
    /// presentations. Their state is intentionally excluded from checkpoints and
    /// preferences, just like the existing ruler state.

public enum CanvasGeometryTool: String, CaseIterable, Sendable {
    case ruler
    case protractor
    case compass

    public var title: String {
        switch self {
        case .ruler: "Ruler"
        case .protractor: "Protractor"
        case .compass: "Compass"
        }
    }

    public var systemImage: String {
        switch self {
        case .ruler: "ruler"
        case .protractor: "angle"
        case .compass: "compass.drawing"
        }
    }
}

public enum CanvasToolbarIntent: Sendable {
    case undo
    case redo
    case tapTool(CanvasTool)
    case showOptions(CanvasTool)
    case setWidth(CanvasTool, Double)
    case setColor(CanvasTool, RGBAColor)
    case setEraserMode(CanvasEraserMode)
    case setLaserPointerStyle(CanvasLaserPointerStyle)
    case toggleInsert
    case tapGeometryToolSlot
    case toggleGeometryTool(CanvasGeometryTool)
    // Kept as a source-compatible alias for existing callers and tests.
    case toggleRuler
    case showShapes
    case dismissOverlay
    case insertText
    case insertShape(CanvasShape)
    case showTableSizePicker
    case insertTable(CanvasTableSize)
    case requestImageWand
    case requestPhoto
    case requestFile
}

public struct RGBAColor: Codable, Equatable, Hashable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double = 1) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public init(uiColor: UIColor) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        self.init(
            red: Double(red),
            green: Double(green),
            blue: Double(blue),
            alpha: Double(alpha)
        )
    }

    @MainActor
    public var uiColor: UIColor {
        UIColor(
            red: red.clampedToUnit,
            green: green.clampedToUnit,
            blue: blue.clampedToUnit,
            alpha: alpha.clampedToUnit
        )
    }

    public var isValid: Bool {
        [red, green, blue, alpha].allSatisfy { $0.isFinite && (0...1).contains($0) }
    }

    public static let black = RGBAColor(red: 0, green: 0, blue: 0)
    public static let graphite = RGBAColor(red: 32 / 255, green: 32 / 255, blue: 32 / 255)
    public static let white = RGBAColor(red: 1, green: 1, blue: 1)
    public static let laserRed = RGBAColor(red: 1, green: 45 / 255, blue: 38 / 255)
    public static let slate = RGBAColor(red: 95 / 255, green: 99 / 255, blue: 104 / 255)
    public static let blue = RGBAColor(red: 47 / 255, green: 111 / 255, blue: 235 / 255)
    public static let cyan = RGBAColor(red: 22 / 255, green: 156 / 255, blue: 191 / 255)
    public static let teal = RGBAColor(red: 24 / 255, green: 138 / 255, blue: 118 / 255)
    public static let green = RGBAColor(red: 46 / 255, green: 139 / 255, blue: 87 / 255)
    public static let yellow = RGBAColor(red: 209 / 255, green: 155 / 255, blue: 0)
    public static let orange = RGBAColor(red: 228 / 255, green: 106 / 255, blue: 50 / 255)
    public static let red = RGBAColor(red: 216 / 255, green: 72 / 255, blue: 72 / 255)
    public static let rose = RGBAColor(red: 201 / 255, green: 79 / 255, blue: 124 / 255)
    public static let violet = RGBAColor(red: 114 / 255, green: 87 / 255, blue: 217 / 255)

    public static let inkPalette: [RGBAColor] = [
        .black, .white, .slate, .blue, .cyan, .teal,
        .green, .yellow, .orange, .red, .rose, .violet,
    ]

    /// The five swatches shown inline in the compact picker; the remaining
    /// palette stays reachable through the system color picker.
    public static let quickInkPalette: [RGBAColor] = [
        .black, .blue, .red, .green, .orange,
    ]

    public static let highlighterPalette: [RGBAColor] = [
        RGBAColor(red: 1, green: 225 / 255, blue: 104 / 255, alpha: 0.45),
        RGBAColor(red: 214 / 255, green: 240 / 255, blue: 109 / 255, alpha: 0.45),
        RGBAColor(red: 143 / 255, green: 227 / 255, blue: 192 / 255, alpha: 0.45),
        RGBAColor(red: 142 / 255, green: 221 / 255, blue: 242 / 255, alpha: 0.45),
        RGBAColor(red: 158 / 255, green: 199 / 255, blue: 1, alpha: 0.45),
        RGBAColor(red: 198 / 255, green: 180 / 255, blue: 244 / 255, alpha: 0.45),
        RGBAColor(red: 246 / 255, green: 175 / 255, blue: 200 / 255, alpha: 0.45),
        RGBAColor(red: 1, green: 195 / 255, blue: 155 / 255, alpha: 0.45),
        RGBAColor(red: 1, green: 180 / 255, blue: 93 / 255, alpha: 0.45),
        RGBAColor(red: 242 / 255, green: 154 / 255, blue: 154 / 255, alpha: 0.45),
        RGBAColor(red: 200 / 255, green: 205 / 255, blue: 211 / 255, alpha: 0.45),
        RGBAColor(red: 200 / 255, green: 162 / 255, blue: 125 / 255, alpha: 0.45),
    ]
}

public struct CanvasToolConfiguration: Codable, Equatable, Sendable {
    public var width: Double
    public var color: RGBAColor

    public init(width: Double, color: RGBAColor) {
        self.width = width
        self.color = color
    }

    public var isValid: Bool {
        width.isFinite && width > 0 && color.isValid
    }
}

public struct CanvasToolState: Codable, Equatable, Sendable {
    public var activeTool: CanvasTool {
        didSet {
            switch activeTool.toolbarFamilyRoot {
                case .pen:
                    preferredPenTool = activeTool
                case .fountainPen:
                    preferredBrushTool = activeTool
                default:
                    break
            }
        }
    }
    public var configurations: [CanvasTool: CanvasToolConfiguration]
    public var eraserMode: CanvasEraserMode
    public var laserPointerStyle: CanvasLaserPointerStyle
    public private(set) var preferredPenTool: CanvasTool
    public private(set) var preferredBrushTool: CanvasTool

    public init(
        activeTool: CanvasTool = .pen,
        configurations: [CanvasTool: CanvasToolConfiguration] = Self.defaults,
        eraserMode: CanvasEraserMode = .pixel,
        laserPointerStyle: CanvasLaserPointerStyle = .dot,
        preferredPenTool: CanvasTool? = nil,
        preferredBrushTool: CanvasTool? = nil
    ) {
        self.activeTool = activeTool
        self.configurations = configurations
        self.eraserMode = eraserMode
        self.laserPointerStyle = laserPointerStyle
        self.preferredPenTool = Self.validPreferredTool(
            preferredPenTool ?? activeTool,
            inFamily: .pen,
            fallback: .pen
        )
        self.preferredBrushTool = Self.validPreferredTool(
            preferredBrushTool ?? activeTool,
            inFamily: .fountainPen,
            fallback: .fountainPen
        )
    }

    public static let defaults: [CanvasTool: CanvasToolConfiguration] = [
        .pen: .init(width: 2, color: .black),
        .ballpoint: .init(width: 2, color: .black),
        .calligraphy: .init(width: 29, color: .black),
        .pencil: .init(width: 2.5, color: .black),
        .fountainPen: .init(width: 4, color: .black),
        .watercolor: .init(width: 40, color: .black),
        .crayon: .init(width: 30, color: .black),
        .highlighter: .init(width: 12, color: .highlighterPalette[0]),
        .eraser: .init(width: 16, color: .graphite),
        .laserPointer: .init(width: 4, color: .laserRed),
    ]

    public func configuration(for tool: CanvasTool) -> CanvasToolConfiguration? {
        configurations[tool]
    }

    public static func widthPresets(for tool: CanvasTool) -> [Double] {
        switch tool {
            case .pen: [0.5, 1, 2, 3, 4, 6]
            case .ballpoint: [0.5, 1, 2, 3, 4, 6]
            case .calligraphy: [5, 10, 18, 24, 29, 40]
            case .pencil: [2.5, 4, 6, 8, 12, 16]
            case .fountainPen: [1, 2, 4, 6, 8, 12]
            case .watercolor: [10, 20, 30, 40, 60, 80]
            case .crayon: [10, 18, 24, 30, 40, 50]
            case .highlighter: [8, 12, 18, 24, 32, 48]
            case .eraser: [16, 24, 32, 48]
            case .lasso, .laserPointer: []
        }
    }

    public var hasValidConfigurations: Bool {
        Self.defaults.keys.allSatisfy { configurations[$0]?.isValid == true }
    }

    private enum CodingKeys: String, CodingKey {
        case activeTool
        case configurations
        case eraserMode
        case laserPointerStyle
        case preferredPenTool
        case preferredBrushTool
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        activeTool = try container.decode(CanvasTool.self, forKey: .activeTool)
        configurations = try Self.addingMissingDefaults(to: try container.decode(
            [CanvasTool: CanvasToolConfiguration].self,
            forKey: .configurations
        ))
        eraserMode = try container.decode(CanvasEraserMode.self, forKey: .eraserMode)
        laserPointerStyle = try container.decodeIfPresent(
            CanvasLaserPointerStyle.self,
            forKey: .laserPointerStyle
        ) ?? .dot
        preferredPenTool = Self.validPreferredTool(
            try container.decodeIfPresent(CanvasTool.self, forKey: .preferredPenTool)
                ?? activeTool,
            inFamily: .pen,
            fallback: .pen
        )
        preferredBrushTool = Self.validPreferredTool(
            try container.decodeIfPresent(CanvasTool.self, forKey: .preferredBrushTool)
                ?? activeTool,
            inFamily: .fountainPen,
            fallback: .fountainPen
        )
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(activeTool, forKey: .activeTool)
        try container.encode(configurations, forKey: .configurations)
        try container.encode(eraserMode, forKey: .eraserMode)
        try container.encode(laserPointerStyle, forKey: .laserPointerStyle)
        try container.encode(preferredPenTool, forKey: .preferredPenTool)
        try container.encode(preferredBrushTool, forKey: .preferredBrushTool)
    }

    fileprivate static func validPreferredTool(
        _ tool: CanvasTool,
        inFamily family: CanvasTool,
        fallback: CanvasTool
    ) -> CanvasTool {
        tool.toolbarFamilyRoot == family ? tool : fallback
    }

    fileprivate static func addingMissingDefaults(
        to configurations: [CanvasTool: CanvasToolConfiguration]
    ) -> [CanvasTool: CanvasToolConfiguration] {
        var merged = configurations
        for (tool, configuration) in defaults where merged[tool] == nil {
            merged[tool] = configuration
        }
        return merged
    }
}

public struct CanvasViewportState: Codable, Equatable, Sendable {
    public var normalizedCenterX: Double
    public var normalizedCenterY: Double
    public var visibleWidth: Double
    public var usesFitPage: Bool

    public init(
        normalizedCenterX: Double = 0.5,
        normalizedCenterY: Double = 0,
        visibleWidth: Double = Double(CanvasConstants.a4PortraitSize.width),
        usesFitPage: Bool = true
    ) {
        self.normalizedCenterX = normalizedCenterX
        self.normalizedCenterY = normalizedCenterY
        self.visibleWidth = visibleWidth
        self.usesFitPage = usesFitPage
    }

    public var isValid: Bool {
        normalizedCenterX.isFinite && (0...1).contains(normalizedCenterX)
            && normalizedCenterY.isFinite && (0...1).contains(normalizedCenterY)
            && visibleWidth.isFinite && visibleWidth > 0
    }

    /// The continuous notebook keeps this four-key value on disk for Canvas
    /// Core v2 compatibility. `visibleWidth` is the logical width of an A4
    /// page visible at the notebook's effective zoom scale. `usesFitPage`
    /// records automatic-fit intent separately, so a fitted horizontal page
    /// can retain its actual scale while adapting to a later window size.
    public var stackZoomScale: CGFloat {
        let requested = CanvasConstants.a4PortraitSize.width / CGFloat(visibleWidth)
        guard requested.isFinite else { return CanvasConstants.defaultZoomScale }
        return requested.clamped(to: CanvasConstants.absoluteZoomRange)
    }

    public static func stackViewport(
        zoomScale: CGFloat,
        normalizedCenterX: CGFloat,
        normalizedCenterY: CGFloat
    ) -> CanvasViewportState {
        let resolvedScale = zoomScale.clamped(to: CanvasConstants.absoluteZoomRange)
        return CanvasViewportState(
            normalizedCenterX: Double(normalizedCenterX.clamped(to: 0...1)),
            normalizedCenterY: Double(normalizedCenterY.clamped(to: 0...1)),
            visibleWidth: Double(CanvasConstants.a4PortraitSize.width / resolvedScale),
            // Settled/user-authored viewports are explicit, including one
            // that happens to remain at exactly 100%. Automatic horizontal
            // fitting opts in after this value is created.
            usesFitPage: false
        )
    }

    /// Carries the same authored point through a quarter-turn so rotating a
    /// page does not jump the viewport to a different part of the sheet.
    public func rotated(clockwise: Bool) -> CanvasViewportState {
        guard isValid else { return self }
        let x = CGFloat(normalizedCenterX)
        let y = CGFloat(normalizedCenterY)
        let center = clockwise
            ? CGPoint(x: 1 - y, y: x)
            : CGPoint(x: y, y: 1 - x)
        return CanvasViewportState(
            normalizedCenterX: Double(center.x.clamped(to: 0...1)),
            normalizedCenterY: Double(center.y.clamped(to: 0...1)),
            visibleWidth: visibleWidth,
            usesFitPage: usesFitPage
        )
    }

    private enum CodingKeys: String, CodingKey {
        case normalizedCenterX
        case normalizedCenterY
        case visibleWidth
        case usesFitPage
        // Canvas Core v2 originally called automatic fitting "Fit Width".
        // Decode the old key so this refinement never discards a viewport.
        case usesFitWidth
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        normalizedCenterX = try container.decode(Double.self, forKey: .normalizedCenterX)
        normalizedCenterY = try container.decode(Double.self, forKey: .normalizedCenterY)
        visibleWidth = try container.decode(Double.self, forKey: .visibleWidth)
        usesFitPage = try container.decodeIfPresent(Bool.self, forKey: .usesFitPage)
            ?? container.decodeIfPresent(Bool.self, forKey: .usesFitWidth)
            ?? true
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(normalizedCenterX, forKey: .normalizedCenterX)
        try container.encode(normalizedCenterY, forKey: .normalizedCenterY)
        try container.encode(visibleWidth, forKey: .visibleWidth)
        try container.encode(usesFitPage, forKey: .usesFitPage)
    }
}

/// Shared zoom semantics for pinch gestures, the bottom-left zoom control,
/// keyboard shortcuts, and accessibility adjustments. PaperKit keeps a stable,
/// geometry-budgeted native surface while UIKit owns positioning and carries
/// the remaining transient and settled presentation zoom.
public enum CanvasZoom {
    private static let scrubPointsPerDoubling: CGFloat = 120
    public static let steps: [CGFloat] = [
        0.5, 0.75, 1, 1.25, 1.5, 2, 4, 8, 10,
    ]

    public static func clampedScale(_ scale: CGFloat) -> CGFloat {
        guard scale.isFinite else { return CanvasConstants.defaultZoomScale }
        return scale.clamped(to: CanvasConstants.absoluteZoomRange)
    }

    public static func percentage(for scale: CGFloat) -> Int {
        Int((clampedScale(scale) * 100).rounded())
    }

    public static func increasedScale(from scale: CGFloat) -> CGFloat {
        let current = clampedScale(scale)
        return steps.first(where: { $0 > current + 0.001 })
            ?? CanvasConstants.absoluteZoomRange.upperBound
    }

    public static func decreasedScale(from scale: CGFloat) -> CGFloat {
        let current = clampedScale(scale)
        return steps.reversed().first(where: { $0 < current - 0.001 })
            ?? CanvasConstants.absoluteZoomRange.lowerBound
    }

    public static func matches(_ scale: CGFloat, preset: CGFloat) -> Bool {
        abs(clampedScale(scale) - clampedScale(preset)) < 0.005
    }

    /// A logarithmic position keeps the useful range around 100% spacious
    /// while still making the full 50-1000% range reachable.
    public static func scrubberPosition(for scale: CGFloat) -> CGFloat {
        let range = CanvasConstants.absoluteZoomRange
        let lowerBound = Double(range.lowerBound)
        let ratio = Double(clampedScale(scale)) / lowerBound
        let fullRatio = Double(range.upperBound) / lowerBound
        return CGFloat(log(ratio) / log(fullRatio))
    }

    /// Horizontal direct manipulation mirrors pinch zoom: equal travel makes
    /// an equal proportional change at every magnification.
    public static func scale(
        afterScrubbing startScale: CGFloat,
        horizontalTranslation: CGFloat
    ) -> CGFloat {
        guard horizontalTranslation.isFinite else { return clampedScale(startScale) }
        let exponent = Double(horizontalTranslation / scrubPointsPerDoubling)
        let multiplier = CGFloat(pow(2, exponent))
        return clampedScale(clampedScale(startScale) * multiplier)
    }
}


public struct CanvasPreferences: Codable, Equatable, Sendable {
    public static let currentVersion = 5
    private static let readableLegacyVersions: Set<Int> = [1, 2, 3, 4]
    public var formatVersion: Int
    public var configurations: [CanvasTool: CanvasToolConfiguration]
    public var eraserMode: CanvasEraserMode
    public var laserPointerStyle: CanvasLaserPointerStyle
    public var preferredPenTool: CanvasTool
    public var preferredBrushTool: CanvasTool
    public var inputMode: CanvasInputMode
    public var viewport: CanvasViewportState
    public var pageLayout: CanvasPageLayoutPreferences
    public var readerPreferences: CanvasReaderPreferences

    public init(
        formatVersion: Int = Self.currentVersion,
        configurations: [CanvasTool: CanvasToolConfiguration] = CanvasToolState.defaults,
        eraserMode: CanvasEraserMode = .pixel,
        laserPointerStyle: CanvasLaserPointerStyle = .dot,
        preferredPenTool: CanvasTool = .pen,
        preferredBrushTool: CanvasTool = .fountainPen,
        inputMode: CanvasInputMode = .pencilOnly,
        viewport: CanvasViewportState = CanvasViewportState(),
        pageLayout: CanvasPageLayoutPreferences = .default,
        readerPreferences: CanvasReaderPreferences = .default
    ) {
        self.formatVersion = formatVersion
        self.configurations = configurations
        self.eraserMode = eraserMode
        self.laserPointerStyle = laserPointerStyle
        self.preferredPenTool = CanvasToolState.validPreferredTool(
            preferredPenTool,
            inFamily: .pen,
            fallback: .pen
        )
        self.preferredBrushTool = CanvasToolState.validPreferredTool(
            preferredBrushTool,
            inFamily: .fountainPen,
            fallback: .fountainPen
        )
        self.inputMode = inputMode
        self.viewport = viewport
        self.pageLayout = pageLayout.singlePageOnly
        self.readerPreferences = readerPreferences
    }

    public init(
        toolState: CanvasToolState,
        inputMode: CanvasInputMode,
        viewport: CanvasViewportState,
        pageLayout: CanvasPageLayoutPreferences = .default,
        readerPreferences: CanvasReaderPreferences = .default
    ) {
        self.init(
            configurations: toolState.configurations,
            eraserMode: toolState.eraserMode,
            laserPointerStyle: toolState.laserPointerStyle,
            preferredPenTool: toolState.preferredPenTool,
            preferredBrushTool: toolState.preferredBrushTool,
            inputMode: inputMode,
            viewport: viewport,
            pageLayout: pageLayout,
            readerPreferences: readerPreferences
        )
    }

    public var isValid: Bool {
        formatVersion == Self.currentVersion
            && CanvasToolState(
                activeTool: .pen,
                configurations: configurations,
                eraserMode: eraserMode,
                laserPointerStyle: laserPointerStyle
            ).hasValidConfigurations
            && viewport.isValid
    }

    public var launchToolState: CanvasToolState {
        var migratedConfigurations = configurations
        for tool in [CanvasTool.pen, .pencil, .fountainPen] {
            guard var configuration = migratedConfigurations[tool],
                configuration.color == .graphite else { continue }
            configuration.color = .black
            migratedConfigurations[tool] = configuration
        }
        if var pencil = migratedConfigurations[.pencil], pencil.width < 2.5 {
            // PencilKit clamps the former 1-point choice to roughly 2.4
            // points. Normalize it to the first distinct inspector preset.
            pencil.width = 2.5
            migratedConfigurations[.pencil] = pencil
        }
        if var eraser = migratedConfigurations[.eraser], eraser.width < 16 {
            // PencilKit clamps the fixed-width bitmap eraser to roughly 16
            // points. Normalize the former 8-point choice to the same visible
            // size so the inspector can show a selected preset after upgrade.
            eraser.width = 16
            migratedConfigurations[.eraser] = eraser
        }
        return CanvasToolState(
            activeTool: .pen,
            configurations: migratedConfigurations,
            eraserMode: eraserMode,
            laserPointerStyle: laserPointerStyle,
            preferredPenTool: preferredPenTool,
            preferredBrushTool: preferredBrushTool
        )
    }

    private enum CodingKeys: String, CodingKey {
        case formatVersion
        case configurations
        case eraserMode
        case laserPointerStyle
        case preferredPenTool
        case preferredBrushTool
        case inputMode
        case viewport
        case pageLayout
        case readerPreferences
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try container.decode(Int.self, forKey: .formatVersion)
        guard Self.readableLegacyVersions.contains(storedVersion)
            || storedVersion == Self.currentVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .formatVersion,
                in: container,
                debugDescription: "Unsupported canvas preferences version \(storedVersion)."
            )
        }
        // A successfully decoded file is immediately canonicalized in memory.
        // This also repairs early version-3 files written before every expanded
        // ink existed, without discarding established preferences.
        formatVersion = Self.currentVersion
        let decodedConfigurations = try container.decode(
            [CanvasTool: CanvasToolConfiguration].self,
            forKey: .configurations
        )
        configurations = CanvasToolState.addingMissingDefaults(to: decodedConfigurations)
        eraserMode = try container.decode(CanvasEraserMode.self, forKey: .eraserMode)
        laserPointerStyle = try container.decodeIfPresent(
            CanvasLaserPointerStyle.self,
            forKey: .laserPointerStyle
        ) ?? .dot
        preferredPenTool = CanvasToolState.validPreferredTool(
            try container.decodeIfPresent(CanvasTool.self, forKey: .preferredPenTool) ?? .pen,
            inFamily: .pen,
            fallback: .pen
        )
        preferredBrushTool = CanvasToolState.validPreferredTool(
            try container.decodeIfPresent(CanvasTool.self, forKey: .preferredBrushTool)
                ?? .fountainPen,
            inFamily: .fountainPen,
            fallback: .fountainPen
        )
        inputMode = try container.decode(CanvasInputMode.self, forKey: .inputMode)
        viewport = try container.decode(CanvasViewportState.self, forKey: .viewport)
        let decodedPageLayout = try container.decodeIfPresent(
            CanvasPageLayoutPreferences.self,
            forKey: .pageLayout
        )
        pageLayout = (decodedPageLayout ?? .default).singlePageOnly
        // Reader presentation is supplemental. A malformed future/partial
        // reader payload must not discard otherwise valid pen, input, or
        // viewport preferences for the document.
        readerPreferences = (try? container.decode(
            CanvasReaderPreferences.self,
            forKey: .readerPreferences
        )) ?? .default
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(configurations, forKey: .configurations)
        try container.encode(eraserMode, forKey: .eraserMode)
        try container.encode(laserPointerStyle, forKey: .laserPointerStyle)
        try container.encode(preferredPenTool, forKey: .preferredPenTool)
        try container.encode(preferredBrushTool, forKey: .preferredBrushTool)
        try container.encode(inputMode, forKey: .inputMode)
        try container.encode(viewport, forKey: .viewport)
        try container.encode(pageLayout, forKey: .pageLayout)
        try container.encode(readerPreferences, forKey: .readerPreferences)
    }
}

    /// A bounded, immutable region captured for Image Wand in authored page
    /// coordinates. The thumbnail is masked to the user's precise path before it
    /// is handed to Image Playground.
    public struct CanvasRegionSelectionContext: Identifiable, @unchecked Sendable {
        public let id: UUID
        public let pageID: UUID
        public let pageNumber: Int
        public let pageBounds: CGRect
        public let pagePath: CGPath
        public let thumbnail: CGImage
        public let checkpointGeneration: Int64

        public init(
            id: UUID = UUID(),
            pageID: UUID,
            pageNumber: Int,
            pageBounds: CGRect,
            pagePath: CGPath,
            thumbnail: CGImage,
            checkpointGeneration: Int64
        ) {
            self.id = id
            self.pageID = pageID
            self.pageNumber = pageNumber
            self.pageBounds = pageBounds
            self.pagePath = pagePath
            self.thumbnail = thumbnail
            self.checkpointGeneration = checkpointGeneration
        }
    }

    public struct CanvasImageWandRequest: Identifiable, @unchecked Sendable {
        public let id: UUID
        public let selection: CanvasRegionSelectionContext

        public init(
            id: UUID = UUID(),
            selection: CanvasRegionSelectionContext
        ) {
            self.id = id
            self.selection = selection
    }
}


    public enum CanvasInsertion {
        case text
        case shape(CanvasShape)
        case table(CanvasTableSize)
        case circle(frame: CGRect)
        case image(CGImage)
        case positionedImage(CGImage, frame: CGRect)

        public var historyActionName: String {
            switch self {
                case .text: "Insert Text"
                case .shape: "Insert Shape"
                case .table: "Insert Table"
                case .circle: "Insert Circle"
                case .image: "Insert Image"
                case .positionedImage: "Insert Image"
            }
        }
    }

    public struct PaperCanvasInsertionReceipt: Equatable, Sendable {
        public let acceptanceSequence: UInt64
        public let page: CanvasPageSnapshot

        public init(acceptanceSequence: UInt64, page: CanvasPageSnapshot) {
            self.acceptanceSequence = acceptanceSequence
            self.page = page
    }
}

    public enum PaperCanvasInsertionCommitError: Error, LocalizedError, Equatable, Sendable {
        case controllerBusy
        case pageUnavailable
        case serializationOrHostValidationFailed

        public var errorDescription: String? {
            switch self {
            case .controllerBusy:
                "The canvas is finishing another interaction. Try the insertion again."
            case .pageUnavailable:
                "The destination page is no longer available."
            case .serializationOrHostValidationFailed:
                "The canvas could not safely serialize the insertion. Try again."
    }
    }
}

public struct PaperCanvasCallbacks {
    public var markupChanged: @MainActor (UUID, PaperMarkup) -> Void
    public var pageReplaced: @MainActor (CanvasPageSnapshot) -> Void
    public var paperTemplateChanged: @MainActor (UUID, CanvasPaperTemplate) -> Void
    public var interactionBegan: @MainActor (UUID) -> Void
    public var undoAvailabilityChanged: @MainActor (UUID, Bool, Bool) -> Void
    public var viewportChanged: @MainActor (UUID, CanvasViewportState) -> Void
    public var focusedPageChanged: @MainActor (UUID) -> Void
    // Published only after the controller has drained contact-deferred UI
    // commands and delivered the final PaperKit markup for that contact.
    // Persistence can use this stable boundary to retry a lifecycle save that
    // deliberately failed closed while Pencil or finger contact was active.
    public var snapshotContactEnded: @MainActor () -> Void
    // A fire-and-forget toolbar insertion still owes the user a visible
    // failure if PaperKit cannot serialize or retain its post-insertion host.
    public var programmaticInsertionFailed:
        @MainActor (PaperCanvasInsertionCommitError) -> Void
    public var presentationInteractionBegan: @MainActor () -> Void
    public var zoomInteractionChanged: @MainActor (Bool) -> Void
    public var boundaryPullChanged: @MainActor (CanvasBoundaryPagePull?) -> Void
    public var boundaryPageInsertionRequested: @MainActor (CanvasPageBoundary) -> Void
    public var imageWandSelectionCompleted:
        @MainActor (CanvasImageWandRequest) -> Void
    public var pencilPreferredActionRequested:
        @MainActor (UIPencilPreferredAction) -> Void

    public init(
        markupChanged: @escaping @MainActor (UUID, PaperMarkup) -> Void,
        pageReplaced: @escaping @MainActor (CanvasPageSnapshot) -> Void,
        paperTemplateChanged: @escaping @MainActor (UUID, CanvasPaperTemplate) -> Void = { _, _ in },
        interactionBegan: @escaping @MainActor (UUID) -> Void,
        undoAvailabilityChanged: @escaping @MainActor (UUID, Bool, Bool) -> Void,
        viewportChanged: @escaping @MainActor (UUID, CanvasViewportState) -> Void,
        focusedPageChanged: @escaping @MainActor (UUID) -> Void,
        snapshotContactEnded: @escaping @MainActor () -> Void = {},
        programmaticInsertionFailed:
            @escaping @MainActor (PaperCanvasInsertionCommitError) -> Void = { _ in },
        presentationInteractionBegan: @escaping @MainActor () -> Void = {},
        zoomInteractionChanged: @escaping @MainActor (Bool) -> Void = { _ in },
        boundaryPullChanged: @escaping @MainActor (CanvasBoundaryPagePull?) -> Void = { _ in },
        boundaryPageInsertionRequested: @escaping @MainActor (CanvasPageBoundary) -> Void = { _ in },
        imageWandSelectionCompleted:
            @escaping @MainActor (CanvasImageWandRequest) -> Void = { _ in },
        pencilPreferredActionRequested:
            @escaping @MainActor (UIPencilPreferredAction) -> Void = { _ in }
    ) {
        self.markupChanged = markupChanged
        self.pageReplaced = pageReplaced
        self.paperTemplateChanged = paperTemplateChanged
        self.interactionBegan = interactionBegan
        self.undoAvailabilityChanged = undoAvailabilityChanged
        self.viewportChanged = viewportChanged
        self.focusedPageChanged = focusedPageChanged
        self.snapshotContactEnded = snapshotContactEnded
        self.programmaticInsertionFailed = programmaticInsertionFailed
        self.presentationInteractionBegan = presentationInteractionBegan
        self.zoomInteractionChanged = zoomInteractionChanged
        self.boundaryPullChanged = boundaryPullChanged
        self.boundaryPageInsertionRequested = boundaryPageInsertionRequested
        self.imageWandSelectionCompleted = imageWandSelectionCompleted
        self.pencilPreferredActionRequested = pencilPreferredActionRequested
    }

    /// Transitional source compatibility for the single-page model. The
    /// editor model can migrate independently from the UIKit stack.
    public init(
        markupChanged: @escaping @MainActor (UUID, PaperMarkup) -> Void,
        interactionBegan: @escaping @MainActor () -> Void,
        undoAvailabilityChanged: @escaping @MainActor (Bool, Bool) -> Void,
        viewportChanged: @escaping @MainActor (UUID, CanvasViewportState) -> Void
    ) {
        self.init(
            markupChanged: markupChanged,
            pageReplaced: { _ in },
            paperTemplateChanged: { _, _ in },
            interactionBegan: { _ in interactionBegan() },
            undoAvailabilityChanged: { _, canUndo, canRedo in
                undoAvailabilityChanged(canUndo, canRedo)
            },
            viewportChanged: viewportChanged,
            focusedPageChanged: { _ in }
        )
    }
    }

public struct CanvasActivePageSnapshot: Equatable, Sendable {
    public let id: UUID
    public let markup: PaperMarkup
    public let tables: [CanvasTable]
    public let viewport: CanvasViewportState

    public init(
        id: UUID,
        markup: PaperMarkup,
        tables: [CanvasTable] = [],
        viewport: CanvasViewportState
    ) {
        self.id = id
        self.markup = markup
        self.tables = tables
        self.viewport = viewport
    }
}

public struct CanvasDocumentSnapshot: Equatable, Sendable {
    public let pages: [CanvasPageSnapshot]
    public let currentPageID: UUID
    public let viewport: CanvasViewportState

    public init(
        pages: [CanvasPageSnapshot],
        currentPageID: UUID,
        viewport: CanvasViewportState
    ) {
        self.pages = pages
        self.currentPageID = currentPageID
        self.viewport = viewport
    }
}

/// The public, single-board view of a current Canvas Core checkpoint.
/// Canvas Core still stores a freeform board as one `CanvasPageSnapshot`, so
/// it receives the same verified current/previous checkpoint guarantees as a
/// notebook. This value makes the freeform contract explicit without adding a
/// second persistence format: bounds and the logical origin are carried by
/// `CanvasPageGeometry`, while viewport, zoom, and generation remain stable
/// across recovery.
///
public struct FreeformCanvasSnapshot: Equatable, Sendable {
    public let pageID: UUID
    public let markup: PaperMarkup
    public let tables: [CanvasTable]
    public let logicalOrigin: CGPoint
    public let bounds: CGRect
    public let viewport: CanvasViewportState
    public let zoomScale: CGFloat
    public let generation: Int64
    public let paperTemplate: CanvasPaperTemplate
    public let background: CanvasPageBackground

    public init?(page: CanvasPageSnapshot, generation: Int64) {
        guard generation >= 0,
            page.geometry.isValid,
            page.geometry.quarterTurns == 0,
            page.markup.bounds.origin == .zero,
            page.markup.bounds.size == page.geometry.displaySize,
            page.viewport.isValid else { return nil }
        pageID = page.id
        markup = page.markup
        tables = page.tables
        logicalOrigin = page.geometry.logicalOrigin
        bounds = page.markup.bounds
        viewport = page.viewport
        zoomScale = page.viewport.stackZoomScale
        self.generation = generation
        paperTemplate = page.paperTemplate
        background = page.background
    }

    public init?(checkpoint: CanvasCoreSnapshot) {
        guard checkpoint.pages.count == 1,
            let page = checkpoint.currentPage else { return nil }
        self.init(page: page, generation: checkpoint.generation)
    }

    public var pageSnapshot: CanvasPageSnapshot {
        CanvasPageSnapshot(
            id: pageID,
            markup: markup,
            tables: tables,
            viewport: viewport,
            paperTemplate: paperTemplate,
            geometry: CanvasPageGeometry(
                authoredSize: bounds.size,
                logicalOrigin: logicalOrigin
            ),
            background: background
        )
    }

    public var coreSnapshot: CanvasCoreSnapshot {
        CanvasCoreSnapshot(
            generation: generation,
            pages: [pageSnapshot],
            currentPageID: pageID
        )
    }
}

@MainActor
public protocol PaperCanvasCommanding: AnyObject {
    /// Snapshot/export callers must wait until PaperKit has committed the
    /// contact currently under the Pencil or finger.
    var hasActiveSnapshotContact: Bool { get }
    /// True after an ordinary app insertion has been accepted but before its
    /// immutable undo pair and Canvas Core publication are complete.
    var hasPendingProgrammaticInsertions: Bool { get }
    func applyToolState(_ state: CanvasToolState)
    func applyInputMode(_ mode: CanvasInputMode)
    @discardableResult
    func setReaderModeEnabled(_ isEnabled: Bool) -> Bool
    func setPageLayout(_ layout: CanvasPageLayoutPreferences)
    func setGeometryTool(_ tool: CanvasGeometryTool?)
    func setRulerActive(_ isActive: Bool)
    func beginZoomScrubbing()
    @discardableResult
    func setZoomScale(_ scale: CGFloat) -> CGFloat
    func endZoomScrubbing()
    func setPaperTemplate(_ template: CanvasPaperTemplate, for pageID: UUID)
    func insertPage(_ page: CanvasPageSnapshot, at index: Int, scrollTo: Bool)
    func insertPage(
        _ page: CanvasPageSnapshot,
        at index: Int,
        scrollTo: Bool,
        animated: Bool
    )
    @discardableResult
    func removePage(id: UUID, focusOn pageID: UUID) -> Bool
    /// Applies a complete stable-ID order without recreating any live page
    /// hosts. The focused page remains the same logical page after the move.
    @discardableResult
    func reorderPages(_ orderedPageIDs: [UUID], focusOn pageID: UUID) -> Bool
    func replacePage(_ page: CanvasPageSnapshot)
    func scrollToPage(id: UUID, animated: Bool)
    func navigateToPageRegion(pageID: UUID, pageBounds: CGRect, animated: Bool)
    func snapshotDocument() -> CanvasDocumentSnapshot?
    /// Temporarily prevents interaction while a newly-created controller is
    /// waiting for an older controller's accepted insertion tail.
    func setDocumentSynchronizationPending(_ isPending: Bool)
    /// Hydrates a replacement controller from the authoritative model without
    /// creating user-visible undo history.
    @discardableResult
    func synchronizeDocumentAfterAttachment(_ snapshot: CanvasDocumentSnapshot) -> Bool
    func beginImageWandSelection(checkpointGeneration: Int64)
    func cancelImageWandSelection()
    /// Kept during the model migration; continuous-stack callers should use
    /// insertPage/scrollToPage/snapshotDocument.
    func activatePage(id: UUID, markup: PaperMarkup, viewport: CanvasViewportState)
    func performInsertion(_ insertion: CanvasInsertion)
    /// Performs an insertion on the page that owned the command when it was
    /// submitted. Controller replacement must not silently retarget queued work
    /// to whichever page happens to be focused when replay begins.
    func performInsertion(_ insertion: CanvasInsertion, on pageID: UUID)
    /// Accepts one insertion for an explicit page and returns only after the
    /// controller has serialized its undo pair, retained the authoritative
    /// host, and delivered the resulting page snapshot to the model.
    func performInsertionWithReceipt(
        _ insertion: CanvasInsertion,
        on pageID: UUID
    ) async throws -> PaperCanvasInsertionReceipt
    /// Waits until a programmatic insertion has a serialized before/after
    /// history pair and has been published to Canvas Core. One-shot producers
    /// such as Image Playground must not consume their source request merely
    /// because an asynchronous insertion was queued.
    @discardableResult
    func performInsertionAndWait(_ insertion: CanvasInsertion) async -> Bool
    /// Waits for the insertion tail that was accepted before this call. A
    /// false result means a live contact or newer command kept the snapshot
    /// boundary from becoming stable; callers must fail closed and retry.
    @discardableResult
    func finishPendingProgrammaticInsertions() async -> Bool
    /// Releases native view/controller resources after the owning model has
    /// captured the final stable document. This is separate from SwiftUI's
    /// synchronous dismantle callback because an accepted insertion may still
    /// need the retiring controller long enough to publish its last snapshot.
    func completeDismantle()
    @discardableResult
    func performImageInsertion(_ image: CGImage, atViewportPoint point: CGPoint) -> Bool
    func undo()
    func redo()
    func snapshotActivePage() -> CanvasActivePageSnapshot?
}

public extension PaperCanvasCommanding {
    var hasActiveSnapshotContact: Bool { false }
    var hasPendingProgrammaticInsertions: Bool { false }
    func completeDismantle() {}
    @discardableResult
    func setReaderModeEnabled(_ isEnabled: Bool) -> Bool { isEnabled == false }
    func setPageLayout(_ layout: CanvasPageLayoutPreferences) {}
    func setGeometryTool(_ tool: CanvasGeometryTool?) {
        setRulerActive(tool == .ruler)
    }
    func setRulerActive(_ isActive: Bool) {}
    func beginZoomScrubbing() {}
    @discardableResult
    func setZoomScale(_ scale: CGFloat) -> CGFloat {
        CanvasZoom.clampedScale(scale)
    }
    func endZoomScrubbing() {}
    func setPaperTemplate(_ template: CanvasPaperTemplate, for pageID: UUID) {}
    func insertPage(_ page: CanvasPageSnapshot, at index: Int, scrollTo: Bool) {}
    func insertPage(
        _ page: CanvasPageSnapshot,
        at index: Int,
        scrollTo: Bool,
        animated: Bool
    ) {
        insertPage(page, at: index, scrollTo: scrollTo)
    }
    @discardableResult
    func removePage(id: UUID, focusOn pageID: UUID) -> Bool { false }
    @discardableResult
    func reorderPages(_ orderedPageIDs: [UUID], focusOn pageID: UUID) -> Bool { false }
    func replacePage(_ page: CanvasPageSnapshot) {}
    func performInsertion(_ insertion: CanvasInsertion, on pageID: UUID) {}
    func performInsertion(_ insertion: CanvasInsertion) {}
    func performInsertionWithReceipt(
        _ insertion: CanvasInsertion,
        on pageID: UUID
    ) async throws -> PaperCanvasInsertionReceipt {
        // A legacy conformer cannot prove that its implicit focused-page
        // command was applied to `pageID`, nor that the returned snapshot is
        // the exact post-insertion value. Durable callers must fail closed.
        throw PaperCanvasInsertionCommitError.serializationOrHostValidationFailed
    }
    @discardableResult
    func performInsertionAndWait(_ insertion: CanvasInsertion) async -> Bool {
        performInsertion(insertion)
        return true
    }

    @discardableResult
    func finishPendingProgrammaticInsertions() async -> Bool { true }
    @discardableResult
    func performImageInsertion(_ image: CGImage, atViewportPoint point: CGPoint) -> Bool {
        performInsertion(.image(image))
        return true
    }
    func scrollToPage(id: UUID, animated: Bool) {}
    func navigateToPageRegion(pageID: UUID, pageBounds: CGRect, animated: Bool) {
        scrollToPage(id: pageID, animated: animated)
    }
    // No defaults for snapshotting, synchronization, or Wand: a silent no-op
    // here once hid an unimplemented Wand. The compiler should insist that a
    // conformer implements these.
}

public enum CanvasConstants {
    public static let a4PortraitSize = CGSize(width: 595, height: 842)
    public static let a4LandscapeSize = CGSize(
        width: a4PortraitSize.height,
        height: a4PortraitSize.width
    )
    public static let freeformInitialSize = CGSize(width: 4_096, height: 4_096)
    /// Library artwork is a view into an infinite board, not a representation
    /// of its square backing coordinate space. Keep that view consistently
    /// landscape everywhere it is generated or presented.
    public static let freeformLibraryAspectRatio: CGFloat = 4 / 3
    /// Infinite boards grow lazily within a deliberately large coordinate
    /// space. PaperKit and Core Animation still require finite, bounded layer
    /// geometry; an unbounded backing board can overflow those systems after
    /// repeated low-zoom edge expansion even when the visible region is small.
    /// 65,536 points is sixteen times the initial board along each axis while
    /// keeping transforms, tile indexes, and persisted snapshots predictable.
    public static let maximumPersistedCanvasDimension: CGFloat = 65_536
    public static let freeformExpansionChunk: CGFloat = 2_048
    public static let freeformEdgeThreshold: CGFloat = 320
    public static let pageGap: CGFloat = 24
    public static let toolbarTopPadding: CGFloat = 8
    public static let toolbarHeight: CGFloat = 48
    public static let firstPageToolbarGap: CGFloat = 24
    public static let defaultZoomScale: CGFloat = 1
    public static let absoluteZoomRange: ClosedRange<CGFloat> = 0.5...10
    /// A pull starts only when a new drag begins this close to a settled edge.
    public static let boundaryPullStartSlop: CGFloat = 10
    /// The 42-point affordance is not shown until it has 12 points of clear
    /// workspace between it and the page edge.
    public static let boundaryPullRevealDistance: CGFloat = 24
    public static let boundaryPullArmDistance: CGFloat = 56
    /// Once armed, a little reversal is tolerated so the ready state does not
    /// chatter around the arming threshold.
    public static let boundaryPullDisarmDistance: CGFloat = 46
    public static let boundaryPullMaximumReleaseVelocityPointsPerSecond: CGFloat = 450
    public static let boundaryPullVerticalDominance: CGFloat = 1.25
    /// The neutral editing workspace behind authored notebook pages. This is
    /// deliberately close to paper in Light Mode; page elevation and the
    /// hairline carry the hierarchy without turning most of the editor into a
    /// dark beige mat. It is UI chrome, not a paper tone, and must never leak
    /// into page persistence or export rendering.
    public static let pagedWorkspaceBackground = UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(
                red: 36 / 255,
                green: 35 / 255,
                blue: 33 / 255,
                alpha: 1
            )
        }
        return UIColor(
            red: 247 / 255,
            green: 246 / 255,
            blue: 243 / 255,
            alpha: 1
        )
    }
    /// The default authored paper color remains separate from the workspace.
    public static let paperBackground = UIColor(
        red: 1,
        green: 254 / 255,
        blue: 252 / 255,
        alpha: 1
    )

    /// Infinite boards should feel like a single uninterrupted surface in
    /// Light Mode, matching the white-board convention used by Freeform and
    /// Goodnotes. Dark Mode keeps the existing neutral surround because the
    /// authored paper itself remains a light drawing surface.
    public static let freeformWorkspaceBackground = UIColor { traits in
        if traits.userInterfaceStyle == .dark {
            return UIColor(
                red: 36 / 255,
                green: 35 / 255,
                blue: 33 / 255,
                alpha: 1
            )
        }
        return paperBackground
    }

    public static func workspaceBackground(
        for documentMode: CanvasDocumentMode
    ) -> UIColor {
        switch documentMode {
        case .paged:
            pagedWorkspaceBackground
        case .freeform:
            freeformWorkspaceBackground
    }
}

    /// Compatibility spellings for callers that do not yet distinguish the
    /// document presentation. Paged paper is the conservative default.
    public static let workspaceBackground = pagedWorkspaceBackground
}

public enum CanvasNativeToolMapper {
    @MainActor
    public static func nativeTool(for state: CanvasToolState) -> (any PKTool)? {
        switch state.activeTool {
        case .lasso:
            PKLassoTool()
        case .pen:
            inkingTool(.monoline, state: state, tool: .pen)
        case .ballpoint:
            inkingTool(.pen, state: state, tool: .ballpoint)
        case .calligraphy:
            inkingTool(.reed, state: state, tool: .calligraphy)
        case .pencil:
            inkingTool(.pencil, state: state, tool: .pencil)
        case .fountainPen:
            inkingTool(.fountainPen, state: state, tool: .fountainPen)
        case .watercolor:
            inkingTool(.watercolor, state: state, tool: .watercolor)
        case .crayon:
            inkingTool(.crayon, state: state, tool: .crayon)
        case .highlighter:
            inkingTool(.marker, state: state, tool: .highlighter)
        case .laserPointer:
            nil
        case .eraser:
            if state.eraserMode == .stroke {
                PKEraserTool(.vector)
            } else {
                PKEraserTool(
                    .fixedWidthBitmap,
                    width: CGFloat(state.configuration(for: .eraser)?.width ?? 16)
                )
            }
        }
    }

    @MainActor
    private static func inkingTool(
        _ ink: PKInkingTool.InkType,
        state: CanvasToolState,
        tool: CanvasTool
    ) -> PKInkingTool {
        guard let configuration = state.configuration(for: tool)
            ?? CanvasToolState.defaults[tool] else {
            // A newly added ink tool must not turn an incomplete defaults map
            // into a force-unwrap crash. Use a conservative visible stroke
            // until its authored configuration is supplied.
            return PKInkingTool(ink, color: .black, width: 2)
        }
        return PKInkingTool(
            ink,
            color: configuration.color.uiColor,
            width: CGFloat(configuration.width)
        )
    }
}

private extension Double {
    var clampedToUnit: CGFloat {
        CGFloat(min(max(self, 0), 1))
    }
}


private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
