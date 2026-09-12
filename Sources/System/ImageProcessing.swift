import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// A photo downscaled for the model, with the decoded image used for the on-screen preview.
struct PreparedImage: @unchecked Sendable {
  let jpegData: Data
  let preview: CGImage
}

enum ImageProcessing {
  /// Longest edge, in pixels, of images given to a model. Smaller images use much less memory during
  /// vision encoding, and larger ones can make a model server hang.
  static let maxPixelSize = 1024

  /// Decodes anything ImageIO reads (HEIC, JPEG, PNG, …), downscales without ever decoding the
  /// full-size image, and re-encodes as JPEG so the model always receives a small, common format.
  static func prepare(_ data: Data) -> PreparedImage? {
    let sourceOptions = [kCGImageSourceShouldCache: false] as CFDictionary
    guard let source = CGImageSourceCreateWithData(data as CFData, sourceOptions) else {
      return nil
    }

    let thumbnailOptions: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
    ]
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(source, 0, thumbnailOptions as CFDictionary)
    else { return nil }

    let output = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        output as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
    else { return nil }
    let encodeOptions = [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary
    CGImageDestinationAddImage(destination, image, encodeOptions)
    guard CGImageDestinationFinalize(destination) else { return nil }

    return PreparedImage(jpegData: output as Data, preview: image)
  }

  /// Decodes a photo that was saved with a chat, for display.
  static func decode(_ data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }
}
