import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Publisher cover art passes through unmodified unless it would render
/// badly or bloat the audiobook: oversized files/dimensions are downscaled,
/// CMYK JPEGs (black/garbled in several players) are re-encoded, and alpha
/// PNGs are flattened onto white (iTunes-lineage UIs composite them onto
/// black). Normalization failures fall back to the original bytes — a
/// suboptimal cover beats no cover.
enum CoverPolicy {
  static let maxPassthroughBytes = 3 * 1024 * 1024
  static let maxPassthroughPixels = 3_000
  static let normalizedMaxPixels = 1_600

  static func prepare(_ cover: EPUBCover) -> M4BMetadataPlan.Cover {
    let passthrough = M4BMetadataPlan.Cover(
      data: cover.data, format: cover.kind == .jpeg ? .jpeg : .png)

    guard let source = CGImageSourceCreateWithData(cover.data as CFData, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    else { return passthrough }

    let width = (properties[kCGImagePropertyPixelWidth] as? Int) ?? 0
    let height = (properties[kCGImagePropertyPixelHeight] as? Int) ?? 0
    let colorModel = properties[kCGImagePropertyColorModel] as? String
    let hasAlpha = (properties[kCGImagePropertyHasAlpha] as? Bool) ?? false

    let isCMYK = colorModel == (kCGImagePropertyColorModelCMYK as String)
    let tooLarge =
      cover.data.count > maxPassthroughBytes
      || max(width, height) > maxPassthroughPixels
    let alphaPNG = cover.kind == .png && hasAlpha

    guard isCMYK || tooLarge || alphaPNG else { return passthrough }

    if alphaPNG && !isCMYK && !tooLarge {
      return flattenAlpha(source: source, fallback: passthrough)
    }
    return reencodeJPEG(source: source, fallback: passthrough)
  }

  private static func reencodeJPEG(
    source: CGImageSource, fallback: M4BMetadataPlan.Cover
  ) -> M4BMetadataPlan.Cover {
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: normalizedMaxPixels,
      kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
      let data = encode(image, type: UTType.jpeg, quality: 0.85)
    else { return fallback }
    return M4BMetadataPlan.Cover(data: data, format: .jpeg)
  }

  private static func flattenAlpha(
    source: CGImageSource, fallback: M4BMetadataPlan.Cover
  ) -> M4BMetadataPlan.Cover {
    guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return fallback }
    let width = image.width
    let height = image.height
    guard width > 0, height > 0,
      let context = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return fallback }
    context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let flattened = context.makeImage(),
      let data = encode(flattened, type: UTType.png, quality: 1)
    else { return fallback }
    return M4BMetadataPlan.Cover(data: data, format: .png)
  }

  private static func encode(_ image: CGImage, type: UTType, quality: Double) -> Data? {
    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output, type.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(
      destination, image,
      [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
    guard CGImageDestinationFinalize(destination), output.length > 0 else { return nil }
    return output as Data
  }
}
