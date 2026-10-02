import PaperKit
import PencilKit

public enum PaperFeatureSetFactory {
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
        "notate-canvas/paperkit-v2",
        "drawing, text, images, shapeFills, shapeStrokes, shapeOpacity",
        "monoline, pencil, fountainPen, marker, reed, watercolor, crayon",
        "all-shapes",
        "sdr",
    ].joined(separator: ";")

    public static func canRead(fingerprint: String) -> Bool {
        fingerprint == Self.fingerprint
            || fingerprint == legacyFingerprint
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
            .pencil,
            .fountainPen,
            .marker,
            .reed,
            .watercolor,
            .crayon,
        ]
        features.shapes = Set(ShapeConfiguration.Shape.allCases)
        features.lineMarkerPositions = .all
        features.colorMaximumLinearExposure = 1
        return features
    }

    public static func canEdit(_ markup: PaperMarkup) -> Bool {
        markup.featureSet.isSubset(of: canvas)
    }
}
