// Draws several images side by side into one PNG whose longest edge is at most a given size.
// Called by screenshot.sh, which checks its arguments first.
// Usage: swift contact-sheet.swift <max edge> <out.png> <image…>
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments.dropFirst()
guard arguments.count >= 3, let maxEdge = Double(arguments.first!) else {
  FileHandle.standardError.write(Data("usage: contact-sheet.swift <max edge> <out.png> <image…>\n".utf8))
  exit(64)
}
let output = URL(filePath: arguments.dropFirst().first!)
let images: [CGImage] = arguments.dropFirst(2).map { path in
  guard let source = CGImageSourceCreateWithURL(URL(filePath: path) as CFURL, nil),
    let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
  else {
    FileHandle.standardError.write(Data("cannot read \(path)\n".utf8))
    exit(1)
  }
  return image
}

// One row up to four images, then more rows; every cell as large as the largest image.
let columns = min(images.count, 4)
let rows = (images.count + columns - 1) / columns
let cellWidth = Double(images.map(\.width).max()!)
let cellHeight = Double(images.map(\.height).max()!)
let gap = 0.02 * max(cellWidth, cellHeight)
let fullWidth = Double(columns) * cellWidth + Double(columns + 1) * gap
let fullHeight = Double(rows) * cellHeight + Double(rows + 1) * gap
let scale = min(1, maxEdge / max(fullWidth, fullHeight))
let width = Int((fullWidth * scale).rounded())
let height = Int((fullHeight * scale).rounded())

guard
  let context = CGContext(
    data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
else { exit(1) }
context.interpolationQuality = .high
context.setFillColor(gray: 0.85, alpha: 1)
context.fill(CGRect(x: 0, y: 0, width: width, height: height))
context.scaleBy(x: scale, y: scale)
for (index, image) in images.enumerated() {
  let column = Double(index % columns)
  let row = Double(index / columns)
  // CoreGraphics counts y from the bottom; the first row goes on top.
  let x = gap + column * (cellWidth + gap) + (cellWidth - Double(image.width)) / 2
  let y = fullHeight - (gap + row * (cellHeight + gap)) - cellHeight + (cellHeight - Double(image.height)) / 2
  context.draw(image, in: CGRect(x: x, y: y, width: Double(image.width), height: Double(image.height)))
}

guard let sheet = context.makeImage(),
  let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil)
else { exit(1) }
CGImageDestinationAddImage(destination, sheet, nil)
exit(CGImageDestinationFinalize(destination) ? 0 : 1)
