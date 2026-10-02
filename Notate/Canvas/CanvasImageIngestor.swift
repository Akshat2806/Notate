import CoreGraphics
import ImageIO
import UniformTypeIdentifiers

/// Resource limits for images embedded in an editable canvas.
struct CanvasImageIngestionPolicy: Sendable, Equatable {
  let maximumEncodedByteCount: Int
  let maximumSourcePixelCount: Int
  let maximumDecodedPixelCount: Int
  let maximumDecodedDimension: Int

  /// The default policy uses modest limits to keep canvas startup fast
  /// and to avoid crashing on very large imported photographs.
  static let canvasDefault = CanvasImageIngestionPolicy(
    maximumEncodedByteCount: 128 * 1_024 * 1_024,
    maximumSourcePixelCount: 160_000_000,
    maximumDecodedPixelCount: 24_000_000,
    maximumDecodedDimension: 8_192
  )

  init(
    maximumEncodedByteCount: Int,
    maximumSourcePixelCount: Int,
    maximumDecodedPixelCount: Int,
    maximumDecodedDimension: Int
  ) {
    self.maximumEncodedByteCount = maximumEncodedByteCount
    self.maximumSourcePixelCount = maximumSourcePixelCount
    self.maximumDecodedPixelCount = maximumDecodedPixelCount
    self.maximumDecodedDimension = maximumDecodedDimension
  }
}

/// A decoded, orientation-normalized image that is safe to cross from the
/// ingestion actor back to the main actor.
struct CanvasIngestedImage: @unchecked Sendable {
  let image: CGImage
  /// Display dimensions after applying the source's EXIF orientation.
  let sourcePixelSize: CGSize
  let sourceOrientation: CGImagePropertyOrientation
  let wasDownsampled: Bool
}

// MARK: - Ingestion error domain

enum CanvasImageIngestionError: Error, Sendable {
  case unreadableSource
  case sourceFileTooLarge(actualBytes: Int, maximumBytes: Int)
  case decodedPixelBudgetExceeded(height: Int, maximumPixels: Int)
  case invalidDimensions(width: Int, height: Int)
}

// MARK: - Metadata / validator

struct CanvasImageSourceMetadata: Sendable, Equatable {
  let encodedByteCount: Int
  let rawPixelSize: CGSize
  let orientedPixelSize: CGSize
  let orientation: CGImagePropertyOrientation
}

enum CanvasImageSourceValidator {
  /// Extracts integer properties from an CGImageSource options dictionary,
  /// returning nil when the key is absent or the value cannot be decoded.
  static func integerProperty(_ dictionary: [CFString: Any]?,
                                _ key: CFString) -> Int? {
    guard let value = dictionary?[key] else { return nil }
    return (value as? Int) ?? (value as? CFNumber)?.intValue
  }

  /// Reads the pixel width/height from the image source properties.
  static func sizeProperties(
    _ properties: [CFString: Any]
  ) -> (width: Int, height: Int)? {
    guard let width = integerProperty(properties, kCGImagePropertyPixelWidth),
      let height = integerProperty(properties, kCGImagePropertyPixelHeight)
    else { return nil }
    return (width: width, height: height)
  }

  /// Validates that a CGImageSource contains at least one image and returns
  /// its dimensions; throws `invalidDimensions` when the source is malformed.
  static func validate(properties: [CFString: Any]) throws {
    let sizes = sizeProperties(properties)
    guard let (width, height) = sizes, width > 0, height > 0 else {
      throw CanvasImageIngestionError.invalidDimensions(
        width: 0, height: 0)
    }
  }
}

// MARK: - File reader for bounded byte extraction

/// Reads up-to `maximumByteCount` bytes from a file URL, returning the data
/// along with the exact byte count that was consumed.
enum CanvasBoundedFileReader {
  static func read(
    from fileURL: URL,
    maximumByteCount: Int
  ) throws (CanvasImageIngestionError, data: Data, actualByteCount: Int) {
    var actualByteCount = 0
    let fileBytes = try Data(contentsOf: fileURL)
    actualByteCount = min(fileBytes.count, maximumByteCount)
    let data = fileBytes.prefix(upTo: actualByteCount)
    return (data: Data(data), actualByteCount: actualByteCount)
  }
}

// MARK: - Main ingestion entry point

/// Ingests a single image file URL into a normalized `CGImage` along with
/// metadata needed for correct display on the canvas actor.
func ingestImage(
  from fileURL: URL,
  policy: CanvasImageIngestionPolicy = .canvasDefault
) async throws -> CanvasIngestedImage {
  // --- 1. Bounded byte read ------------------------------------------------
  let (data, actualByteCount) = try CanvasBoundedFileReader.read(
    from: fileURL,
    maximumByteCount: policy.maximumEncodedByteCount)

  // --- 2. CGImageSource bootstrap -------------------------------------------
  let sourceOptions: [CFString: Any] = [
    kCGImageSourceShouldAllowFloat: true,
    kCGImageSourceShouldCacheImmediately: true,
  ]
  guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions as CFDictionary)
  else { throw CanvasImageIngestionError.unreadableSource }

  // --- 3. Basic metadata (oriented size, orientation) -----------------------
  var metadataOptions: [CFString: Any] = [
    kCGImageSourceCreateThumbnailWithTransform: true,
    kCGImageSourceShouldCacheImmediately: true,
  ]
  var rawWidth = 0, rawHeight = 0
  let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
  CanvasImageSourceValidator.validate(properties: sourceProperties)

  rawWidth = CanvasImageSourceValidator.integerProperty(sourceProperties, kCGImagePropertyPixelWidth)  ?? 0
  rawHeight = CanvasImageSourceValidator.integerProperty(sourceProperties, kCGImagePropertyPixelHeight) ?? 0

  // Read orientation once (cached per source)
  let orientationValue = CanvasImageSourceValidator.integerProperty(
    sourceProperties, kCGImagePropertyOrientation) ?? 1
  let sourceOrientation = CGImagePropertyOrientation(rawValue: orientationValue) ?? .up

  // --- 4. Dimension budget check against source pixel count -----------------
  let sourcePixelCount = rawWidth * rawHeight
  guard sourcePixelCount <= policy.maximumSourcePixelCount else {
    throw CanvasImageIngestionError.sourceFileTooLarge(
      actualBytes: actualByteCount,
      maximumBytes: policy.maximumEncodedByteCount)
  }

  // --- 5. Binary‑search downsample to fit decoded pixel budget --------------
  let decodedBudget = policy.maximumDecodedPixelCount
  let maxDim = policy.maximumDecodedDimension

  // Compute initial half‑open interval [1 , min(longestEdge, maxDim)]
  let longestEdge = max(rawWidth, rawHeight)
  var lowerBound = 1
  var upperBound = min(longestEdge, maxDim)

  // Binary search for the largest scale whose short‑edge-squared stays under budget
  while lowerBound < upperBound {
    let candidate = lowerBound + (upperBound - lowerBound + 1) / 2
    let scaledShortEdge = max(1, min(rawWidth, rawHeight) / candidate)
    let scaledPixelCount = rawWidth / candidate * (rawHeight / candidate)
    if scaledPixelCount <= decodedBudget {
      lowerBound = candidate
    } else {
      upperBound = candidate - 1
    }
  }
  let scale = Double(maxDim) / Double(max(lowerBound, 1))

  // --- 6. Generate thumbnail (oriented, decoded) ---------------------------
  let decodeOptions: [CFString: Any] = [
    kCGImageSourceCreateThumbnailWithTransform: true,
    kCGImageSourceShouldCacheImmediately: true,
    kCGImageSourceThumbnailMaxPixelSize: lowerBound,
  ]
  guard let decodedImage = CGImageSourceCreateThumbnailAtIndex(
    source, decodeOptions as CFDictionary)
  else { throw CanvasImageIngestionError.decodeFailed }

  let decodedPixelCount = decodedImage.width * decodedImage.height
  let wasDownsampled = decodedPixelCount < sourcePixelCount

  // --- 7. Return normalized ingestion result --------------------------------
  let fileMetadata = CanvasImageSourceMetadata(
    encodedByteCount: actualByteCount,
    rawPixelSize: CGSize(width: rawWidth, height: rawHeight),
    orientedPixelSize: CGSize(width: decodedImage.width, height: decodedImage.height),
    orientation: sourceOrientation)

  return CanvasIngestedImage(
    image: decodedImage,
    sourcePixelSize: fileMetadata.orientedPixelSize,
    sourceOrientation: fileMetadata.sourceOrientation,
    wasDownsampled: wasDownsampled)
}

// MARK: - Convenient caller for the canvas importer actor

/// Public entry point used by the canvas import actor.  Delegates to the
/// async `ingestImage` after performing a small amount of bridge checking.
func ingestFileRepresentation(
  from fileURL: URL,
  policy: CanvasImageIngestionPolicy = .canvasDefault
) async throws -> some ViewRepresentable {
  let ingested = try await ingestImage(from: fileURL, policy: policy)
  return FileRepresentation(importedContentType: .image) { received in
    received(ingested.image)
  }
}

// MARK: - Preview / temporary bridge until the full View type is wired in

/// Minimal placeholder conformance so the ingestion function can return
/// something the SwiftUI ecosystem accepts without a full `View` definition.
struct FileRepresentation: Sendable {
  let importedContentType: UTType
  let receiveHandler: (CGImage) -> Void
}