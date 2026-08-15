import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

enum IconRenderError: LocalizedError {
    case invalidArguments
    case unreadableSource(String)
    case invalidDimensions(width: Int, height: Int)
    case contextCreationFailed(Int)
    case destinationCreationFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments:
            return "usage: render-app-icon.swift SOURCE_PNG OUTPUT_ICONSET"
        case .unreadableSource(let path):
            return "Unable to read icon source: \(path)"
        case .invalidDimensions(let width, let height):
            return "Icon source must be square and at least 1024 px; got \(width)x\(height)."
        case .contextCreationFailed(let size):
            return "Unable to create an RGBA drawing context for \(size)x\(size)."
        case .destinationCreationFailed(let path):
            return "Unable to create PNG destination: \(path)"
        case .writeFailed(let path):
            return "Unable to write PNG: \(path)"
        }
    }
}

func render(source: CGImage, pixels: Int, to outputURL: URL) throws {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)

    guard let context = CGContext(
        data: nil,
        width: pixels,
        height: pixels,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: bitmapInfo.rawValue
    ) else {
        throw IconRenderError.contextCreationFailed(pixels)
    }

    context.interpolationQuality = .high
    context.draw(source, in: CGRect(x: 0, y: 0, width: pixels, height: pixels))

    guard let rendered = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(
              outputURL as CFURL,
              UTType.png.identifier as CFString,
              1,
              nil
          ) else {
        throw IconRenderError.destinationCreationFailed(outputURL.path)
    }

    CGImageDestinationAddImage(destination, rendered, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw IconRenderError.writeFailed(outputURL.path)
    }
}

do {
    guard CommandLine.arguments.count == 3 else {
        throw IconRenderError.invalidArguments
    }

    let sourceURL = URL(fileURLWithPath: CommandLine.arguments[1])
    let iconsetURL = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)

    guard let imageSource = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
          let source = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {
        throw IconRenderError.unreadableSource(sourceURL.path)
    }

    guard source.width == source.height, source.width >= 1024 else {
        throw IconRenderError.invalidDimensions(width: source.width, height: source.height)
    }

    try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)

    let representations: [(filename: String, pixels: Int)] = [
        ("icon_16x16.png", 16),
        ("icon_16x16@2x.png", 32),
        ("icon_32x32.png", 32),
        ("icon_32x32@2x.png", 64),
        ("icon_128x128.png", 128),
        ("icon_128x128@2x.png", 256),
        ("icon_256x256.png", 256),
        ("icon_256x256@2x.png", 512),
        ("icon_512x512.png", 512),
        ("icon_512x512@2x.png", 1024),
    ]

    for representation in representations {
        try render(
            source: source,
            pixels: representation.pixels,
            to: iconsetURL.appendingPathComponent(representation.filename)
        )
    }
} catch {
    fputs("\(error.localizedDescription)\n", stderr)
    exit(1)
}
