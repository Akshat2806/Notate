import CoreGraphics
import PaperKit
import PencilKit

public enum PaperFeatureSetFactory {
    /// Enables HDR color selection across PaperKit's shared markup and
    /// insertion experiences. PaperKit tone-maps this exposure to the
    /// display's supported headroom.
    public static let defaultColorMaximumLinearExposure: CGFloat = 2.5

    /// Feature fingerprints are persisted inside checksummed canvas files.
    /// Keep the pre-rename values readable even though all newly written files
    /// use the Notate namespace.
    private static let preRenameLegacyFingerprint = [
        "jotori-canvas/paperkit-v1",
        "drawing, text, images, shapeFills, shapeStrokes, shapeOpacity",
        "monoline, pencil, fountainPen, marker",
        "all-shapes",
        "sdr",
    ].joined(separator: ";")

    private static let preRenameFingerprint = [
        "jotori-canvas/paperkit-v2",
        "drawing, text, images, shapeFills, shapeStrokes, shapeOpacity",
        "monoline, pencil, fountainPen, marker",
        "all-shapes",
        "sdr",
    ].joined(separator: ";")

    /// The most recent SDR format remains readable after enabling HDR in v3.
    private static let preHDRFingerprint = [
        "notate-canvas/paperkit-v2",
        "drawing, text, images, shapeFills, shapeStrokes, shapeOpacity",
        "monoline, pencil, fountainPen, marker, reed, watercolor, crayon",
        "all-shapes",
        "sdr",
    ].joined(separator: ";")

    /// Keep documents created with the previous HDR ceiling readable.
    private static let previousHDRFingerprint = [
        "notate-canvas/paperkit-v3",
        "drawing, text, images, shapeFills, shapeStrokes, shapeOpacity",
        "monoline, pencil, fountainPen, marker, reed, watercolor, crayon",
        "all-shapes",
        "hdr-linear-exposure-4",
    ].joined(separator: ";")

    /// Checkpoints written before the expanded native-ink set remain fully
    /// editable because every feature they contain is a subset of v2.
    public static let legacyFingerprint = [
        "notate-canvas/paperkit-v1",
        "drawing, text, images, shapeFills, shapeStrokes, shapeOpacity",
        "monoline, pencil, fountainPen, marker",
        "all-shapes",
        "sdr",
    ].joined(separator: ";")

    public static let fingerprint = [
        "notate-canvas/paperkit-v4",
        "drawing, text, images, shapeFills, shapeStrokes, shapeOpacity",
        "monoline, pencil, fountainPen, marker, reed, watercolor, crayon",
        "all-shapes",
        "hdr-linear-exposure-2.5",
    ].joined(separator: ";")

    public static func canRead(fingerprint: String) -> Bool {
        fingerprint == Self.fingerprint
            || fingerprint == legacyFingerprint
            || fingerprint == preHDRFingerprint
            || fingerprint == previousHDRFingerprint
            || fingerprint == preRenameFingerprint
            || fingerprint == preRenameLegacyFingerprint
    }

    public static var canvas: FeatureSet {
        var features = FeatureSet.version1
        features.features = [
            .drawing,
            .text,
            .images,
            .shapeFills,
            .shapeStrokes,
            .shapeOpacity,
        ]
        features.inks = [
            .monoline,
            .pen,
            .pencil,
            .fountainPen,
            .marker,
            .reed,
            .watercolor,
            .crayon,
        ]
        features.shapes = Set(ShapeConfiguration.Shape.allCases)
        features.lineMarkerPositions = .all
        features.colorMaximumLinearExposure = defaultColorMaximumLinearExposure
        return features
    }

    public static func canEdit(_ markup: PaperMarkup) -> Bool {
        markup.featureSet.isSubset(of: canvas)
    }
}
