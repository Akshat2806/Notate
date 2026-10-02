import CoreGraphics
import CoreTransferable
import Foundation
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

/// File-backed transfer used by PhotosPicker. The provider-owned URL is
/// copied while the transfer callback is active, then removed by the caller
/// after image decoding finishes.
struct CanvasImageTransfer: Transferable, Sendable {
  let fileURL: URL

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(importedContentType: .image) { received in
      let fileExtension = received.file.pathExtension
      let destination = FileManager.default.temporaryDirectory
        .appendingPathComponent("Notate-Import-\(UUID().uuidString)")
        .appendingPathExtension(fileExtension)
      try FileManager.default.copyItem(at: received.file, to: destination)
      return CanvasImageTransfer(fileURL: destination)
    }
  }

  func discard() {
    try? FileManager.default.removeItem(at: fileURL)
  }
}

// MARK: - Ingestion error domain

enum CanvasImageIngestionError: Error, Sendable {
  case unreadableSource
  case sourceFileTooLarge(actualBytes: Int, maximumBytes: Int)
  case sourcePixelBudgetExceeded(actualPixels: Int, maximumPixels: Int)
  case decodedPixelBudgetExceeded(height: Int, maximumPixels: Int)
  case invalidDimensions(width: Int, height: Int)
  case decodeFailed
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
    return (value as? Int) ?? (value as? NSNumber)?.intValue
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

  /// Builds the full metadata payload for raw encoded image bytes, throwing
  /// when the data is not a decodable image or exceeds the policy budgets.
  static func metadata(
    for data: Data,
    policy: CanvasImageIngestionPolicy
  ) throws -> CanvasImageSourceMetadata {
    guard data.isEmpty == false else {
      throw CanvasImageIngestionError.unreadableSource
    }
    guard data.count <= policy.maximumEncodedByteCount else {
      throw CanvasImageIngestionError.sourceFileTooLarge(
        actualBytes: data.count,
        maximumBytes: policy.maximumEncodedByteCount)
    }
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      throw CanvasImageIngestionError.unreadableSource
    }
    guard CGImageSourceGetCount(source) > 0 else {
      throw CanvasImageIngestionError.unreadableSource
    }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
      as? [CFString: Any] ?? [:]
    guard let size = sizeProperties(properties) else {
      throw CanvasImageIngestionError.invalidDimensions(width: 0, height: 0)
    }
    guard size.width > 0, size.height > 0 else {
      throw CanvasImageIngestionError.invalidDimensions(
        width: size.width,
        height: size.height
      )
    }
    let (pixelCount, overflow) = size.width.multipliedReportingOverflow(by: size.height)
    guard overflow == false else {
      throw CanvasImageIngestionError.sourcePixelBudgetExceeded(
        actualPixels: Int.max,
        maximumPixels: policy.maximumSourcePixelCount
      )
    }
    guard pixelCount <= policy.maximumSourcePixelCount else {
      throw CanvasImageIngestionError.sourcePixelBudgetExceeded(
        actualPixels: pixelCount,
        maximumPixels: policy.maximumSourcePixelCount)
    }
    let orientationValue = integerProperty(properties, kCGImagePropertyOrientation) ?? 1
    let orientation = CGImagePropertyOrientation(
      rawValue: UInt32(exactly: orientationValue) ?? 1
    ) ?? .up
    let orientedPixelSize: CGSize
    switch orientation {
    case .left, .right, .leftMirrored, .rightMirrored:
      orientedPixelSize = CGSize(width: size.height, height: size.width)
    default:
      orientedPixelSize = CGSize(width: size.width, height: size.height)
    }
    return CanvasImageSourceMetadata(
      encodedByteCount: data.count,
      rawPixelSize: CGSize(width: size.width, height: size.height),
      orientedPixelSize: orientedPixelSize,
      orientation: orientation)
  }
}

// MARK: - Ingestion actor

/// Serializes all ImageIO decode work for canvas imports off the main actor.
/// Limits are derived from a base policy so narrower contexts (cover art,
/// page thumbnails) can reuse the same pipeline with tighter budgets.
actor CanvasImageIngestor {
  /// Shared pipeline used by photo pickers and file-import panels.
  static let shared = CanvasImageIngestor()

  private let policy: CanvasImageIngestionPolicy

  init(
    policy basePolicy: CanvasImageIngestionPolicy = .canvasDefault,
    maximumEncodedByteCount: Int? = nil,
    maximumSourcePixelCount: Int? = nil,
    maximumDecodedPixelCount: Int? = nil,
    maximumDecodedDimension: Int? = nil
  ) {
    self.policy = CanvasImageIngestionPolicy(
      maximumEncodedByteCount:
        maximumEncodedByteCount ?? basePolicy.maximumEncodedByteCount,
      maximumSourcePixelCount:
        maximumSourcePixelCount ?? basePolicy.maximumSourcePixelCount,
      maximumDecodedPixelCount:
        maximumDecodedPixelCount ?? basePolicy.maximumDecodedPixelCount,
      maximumDecodedDimension:
        maximumDecodedDimension ?? basePolicy.maximumDecodedDimension
    )
  }

  /// Returns the immutable original bytes after validating them as a
  /// readable, in-budget image, so importers can preserve the source file.
  func validatedOriginalData(fileURL: URL) async throws -> Data {
    let data = try CanvasBoundedFileReader.read(
      from: fileURL,
      maximumByteCount: policy.maximumEncodedByteCount
    )
    _ = try CanvasImageSourceValidator.metadata(for: data, policy: policy)
    return data
  }

  /// Ingests a single image file into a normalized, downsampled decode.
  func ingest(fileURL: URL) async throws -> CanvasIngestedImage {
    try await ingestImage(from: fileURL, policy: policy)
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
  let data = try CanvasBoundedFileReader.read(
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
  let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
    as? [CFString: Any] ?? [:]
  try CanvasImageSourceValidator.validate(properties: sourceProperties)

  let rawWidth = CanvasImageSourceValidator.integerProperty(
    sourceProperties,
    kCGImagePropertyPixelWidth
  ) ?? 0
  let rawHeight = CanvasImageSourceValidator.integerProperty(
    sourceProperties,
    kCGImagePropertyPixelHeight
  ) ?? 0

  // Read orientation once (cached per source)
  let orientationValue = CanvasImageSourceValidator.integerProperty(
    sourceProperties, kCGImagePropertyOrientation) ?? 1
  let sourceOrientation = CGImagePropertyOrientation(
    rawValue: UInt32(exactly: orientationValue) ?? 1
  ) ?? .up

  // --- 4. Dimension budget check against source pixel count -----------------
  let (sourcePixelCount, pixelCountOverflow) = rawWidth.multipliedReportingOverflow(
    by: rawHeight
  )
  guard pixelCountOverflow == false else {
    throw CanvasImageIngestionError.sourcePixelBudgetExceeded(
      actualPixels: Int.max,
      maximumPixels: policy.maximumSourcePixelCount
    )
  }
  guard sourcePixelCount <= policy.maximumSourcePixelCount else {
    throw CanvasImageIngestionError.sourcePixelBudgetExceeded(
      actualPixels: sourcePixelCount,
      maximumPixels: policy.maximumSourcePixelCount)
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
  let scaledPixelCount = rawWidth / candidate * (rawHeight / candidate)
    if scaledPixelCount <= decodedBudget {
      lowerBound = candidate
    } else {
      upperBound = candidate - 1
    }
  }

  // --- 6. Generate thumbnail (oriented, decoded) ---------------------------
  let decodeOptions: [CFString: Any] = [
    kCGImageSourceCreateThumbnailWithTransform: true,
    kCGImageSourceShouldCacheImmediately: true,
    kCGImageSourceThumbnailMaxPixelSize: lowerBound,
  ]
  guard let decodedImage = CGImageSourceCreateThumbnailAtIndex(
    source, 0, decodeOptions as CFDictionary)
  else { throw CanvasImageIngestionError.decodeFailed }

  let (decodedPixelCount, decodedPixelCountOverflow) = decodedImage.width
    .multipliedReportingOverflow(by: decodedImage.height)
  guard decodedPixelCountOverflow == false,
    decodedPixelCount <= policy.maximumDecodedPixelCount else {
    throw CanvasImageIngestionError.decodedPixelBudgetExceeded(
      height: decodedImage.height,
      maximumPixels: policy.maximumDecodedPixelCount
    )
  }
  let wasDownsampled = decodedPixelCount < sourcePixelCount

  // --- 7. Return normalized ingestion result --------------------------------
  let fileMetadata = CanvasImageSourceMetadata(
    encodedByteCount: data.count,
    rawPixelSize: CGSize(width: rawWidth, height: rawHeight),
    orientedPixelSize: CGSize(width: decodedImage.width, height: decodedImage.height),
    orientation: sourceOrientation)

  return CanvasIngestedImage(
    image: decodedImage,
    sourcePixelSize: fileMetadata.orientedPixelSize,
    sourceOrientation: fileMetadata.orientation,
    wasDownsampled: wasDownsampled)
}
