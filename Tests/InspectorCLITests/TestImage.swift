import CoreGraphics
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers

/// PNG files of a given size, for the screenshots a fake Xcode names.
enum TestImage {
  /// Writes a grey PNG of `width` × `height` pixels to `url`.
  static func writePNG(width: Int, height: Int, to url: URL) throws {
    let context = try #require(
      CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(gray: 0.5, alpha: 1)
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let destination = try #require(
      CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
  }

  /// The pixel size of the image at `path`, `nil` when there is none.
  static func size(at path: String) -> [Int]? {
    guard let source = CGImageSourceCreateWithURL(URL(filePath: path) as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
      let width = properties[kCGImagePropertyPixelWidth] as? Int,
      let height = properties[kCGImagePropertyPixelHeight] as? Int
    else { return nil }
    return [width, height]
  }
}
