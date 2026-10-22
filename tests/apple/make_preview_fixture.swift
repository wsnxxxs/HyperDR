// Generates the synthetic, redistributable JPEG used by sandboxed app tests.
// DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift tests/apple/make_preview_fixture.swift
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let width = 2400, height = 1600
var pixels = [UInt8](repeating: 255, count: width * height * 4)
for y in 0..<height {
    for x in 0..<width {
        let offset = (y * width + x) * 4
        pixels[offset] = UInt8(x * 255 / (width - 1))
        pixels[offset + 1] = UInt8(y * 255 / (height - 1))
        pixels[offset + 2] = UInt8((x + y) * 255 / (width + height - 2))
    }
}
let data = Data(pixels) as CFData
let provider = CGDataProvider(data: data)!
let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
    bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider,
    decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
let output = URL(fileURLWithPath: "apps/apple/HyperDRPreviewTests/Fixtures/photo.jpg")
let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.jpeg.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.85,
    kCGImagePropertyOrientation: 6] as CFDictionary)
precondition(CGImageDestinationFinalize(destination))
// ImageIO may omit the top-level orientation when writing from a bare CGImage.
// Store a minimal EXIF IFD0 explicitly so the decoder must apply orientation 6.
let jpeg = try Data(contentsOf: output)
let exif: [UInt8] = [0xff, 0xe1, 0, 34, 0x45, 0x78, 0x69, 0x66, 0, 0,
    0x49, 0x49, 42, 0, 8, 0, 0, 0, 1, 0,
    0x12, 1, 3, 0, 1, 0, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0]
var oriented = jpeg.prefix(2)
oriented.append(contentsOf: exif)
oriented.append(jpeg.dropFirst(2))
try oriented.write(to: output)
