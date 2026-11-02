import Foundation
import ImageIO
import UniformTypeIdentifiers

/// The small copy of a screenshot that an agent reads instead of the full-resolution original.
///
/// A simulator screenshot is about 1200 × 2600 pixels; read as it is, it costs an agent several
/// times the tokens of a copy whose longest edge is ``maxEdge``, and shows nothing more it needs.
enum Screenshot {
  /// The small copy's longest edge, in pixels.
  static let maxEdge = 1000

  /// Writes a copy of the image at `path` beside it, named `<name>-small.png`, scaled so its
  /// longest edge is ``maxEdge``, and returns the copy's path. The original stays as it is.
  ///
  /// - Returns: `nil` when the image is no larger than ``maxEdge`` already, or when it cannot be
  ///   read or the copy cannot be written; the original is then the one to read.
  static func smallCopy(of path: String) -> String? {
    let original = URL(filePath: path)
    guard let source = CGImageSourceCreateWithURL(original as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int,
      max(width, height) > maxEdge
    else { return nil }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceThumbnailMaxPixelSize: maxEdge,
      kCGImageSourceCreateThumbnailWithTransform: true,
    ]
    let small = original.deletingLastPathComponent()
      .appending(path: original.deletingPathExtension().lastPathComponent + "-small.png")
    guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary),
      let destination = CGImageDestinationCreateWithURL(small as CFURL, UTType.png.identifier as CFString, 1, nil)
    else { return nil }
    CGImageDestinationAddImage(destination, image, nil)
    return CGImageDestinationFinalize(destination) ? small.path(percentEncoded: false) : nil
  }
}
