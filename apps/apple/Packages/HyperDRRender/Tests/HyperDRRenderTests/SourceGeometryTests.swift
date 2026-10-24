import Foundation
import CoreGraphics
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import Testing
import HyperDRRecipe
@testable import HyperDRRender

/// The crop pane's geometry where the source opens: the cropped photo is the photo.
@Suite(.serialized) struct SourceGeometryTests {
    /// A PNG in quarters: red top left, green top right, blue bottom left, white bottom right.
    static func quarters(width: Int, height: Int) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("quarters.png")
        let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        // CGContext's origin is bottom left.
        let fills: [(CGRect, [CGFloat])] = [
            (CGRect(x: 0, y: height / 2, width: width / 2, height: height / 2), [1, 0, 0]),
            (CGRect(x: width / 2, y: height / 2, width: width / 2, height: height / 2), [0, 1, 0]),
            (CGRect(x: 0, y: 0, width: width / 2, height: height / 2), [0, 0, 1]),
            (CGRect(x: width / 2, y: 0, width: width / 2, height: height / 2), [1, 1, 1])]
        for (rect, rgb) in fills {
            context.setFillColor(red: rgb[0], green: rgb[1], blue: rgb[2], alpha: 1)
            context.fill(rect)
        }
        let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    enum Colour { case red, green, blue, white, other }

    static func colour(_ source: RenderSource, x: Int, y: Int) -> Colour {
        let pixels = RenderEngine.readTexture(source.texture)
        let index = (y * source.texture.width + x) * 4
        let (r, g, b) = (pixels[index], pixels[index + 1], pixels[index + 2])
        switch (r > 0.5, g > 0.5, b > 0.5) {
        case (true, false, false): return .red
        case (false, true, false): return .green
        case (false, false, true): return .blue
        case (true, true, true): return .white
        default: return .other
        }
    }

    func load(_ url: URL, _ geometry: Geometry) async throws -> RenderSource {
        var options = SourceOptions()
        options.geometry = geometry
        return try await RenderEngine().load(url, options: options)
    }

    @Test func cropTurnAndMirrorMoveWholePixels() async throws {
        let url = try Self.quarters(width: 8, height: 6)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

        let crop = try await load(url, Geometry(crop: CropRect(centreX: -0.25, centreY: -0.25, width: 0.5, height: 0.5)))
        #expect(crop.size == PixelSize(width: 4, height: 3) && crop.nativeSize == crop.size)
        #expect(crop.uncroppedSize == PixelSize(width: 8, height: 6))
        #expect((0..<4).allSatisfy { x in (0..<3).allSatisfy { Self.colour(crop, x: x, y: $0) == .red } })

        // Anticlockwise: the top right comes to the top left, the top left to the bottom left.
        let turned = try await load(url, Geometry.identity.turnedLeft())
        #expect(turned.size == PixelSize(width: 6, height: 8))
        #expect(Self.colour(turned, x: 0, y: 0) == .green && Self.colour(turned, x: 0, y: 7) == .red)
        #expect(Self.colour(turned, x: 5, y: 7) == .blue && Self.colour(turned, x: 5, y: 0) == .white)

        let mirrored = try await load(url, Geometry.identity.mirrored())
        #expect(mirrored.size == PixelSize(width: 8, height: 6))
        #expect(Self.colour(mirrored, x: 0, y: 0) == .green && Self.colour(mirrored, x: 7, y: 5) == .blue)

        let plain = try await load(url, .identity)
        #expect(plain.id != crop.id && plain.id != turned.id, "a geometry is part of the source's identity")
        #expect(plain.uncroppedSize == plain.nativeSize)
    }

    @Test func straighteningAndPerspectiveFillTheCrop() async throws {
        let url = try Self.quarters(width: 160, height: 120)
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        for geometry in [Geometry(angle: 12), Geometry(vertical: 60), Geometry(angle: -8, horizontal: -40, flipped: true)] {
            let source = try await load(url, geometry)
            let expected = geometry.outputSize(of: GeometrySize(width: 160, height: 120))
            #expect(source.size == PixelSize(width: expected.width, height: expected.height))
            #expect(source.size.width < 160 && source.size.height < 120)
            // No edge shows: the corners are the photo's colours, never black.
            let w = source.size.width, h = source.size.height
            for (x, y) in [(0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)] {
                #expect(Self.colour(source, x: x, y: y) != .other, "\(geometry) at \(x), \(y)")
            }
        }
        // Straightened anticlockwise, the red quarter still fills the top left.
        let straight = try await load(url, Geometry(angle: 12))
        #expect(Self.colour(straight, x: 2, y: 2) == .red)
    }

    @Test func aGainMapTurnsAndCropsWithItsPhoto() async throws {
        let png = try Self.quarters(width: 64, height: 48)
        defer { try? FileManager.default.removeItem(at: png.deletingLastPathComponent()) }
        let heic = png.deletingLastPathComponent().appendingPathComponent("pair.heic")
        let base = CIImage(contentsOf: png)!
        let hdr = base.applyingFilter("CIColorMatrix", parameters: ["inputRVector": CIVector(x: 4, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 4, z: 0, w: 0), "inputBVector": CIVector(x: 0, y: 0, z: 4, w: 0)])
            .settingContentHeadroom(4)
        try CIContext().writeHEIFRepresentation(of: base, to: heic, format: .RGBA8,
            colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, options: [.hdrImage: hdr])
        let geometry = Geometry(angle: 5, quarterTurns: 1, crop: CropRect(centreX: 0.1, centreY: 0, width: 0.5, height: 0.5))
        var options = SourceOptions()
        options.geometry = geometry
        let engine = try RenderEngine()
        let source = try await engine.load(heic, options: options)
        #expect(source.domain == .dual)
        let expected = geometry.outputSize(of: GeometrySize(width: 64, height: 48))
        #expect(source.size == PixelSize(width: expected.width, height: expected.height))
        let gain = try #require(source.gainTexture)
        #expect(abs(Double(gain.width) / Double(gain.height) - Double(source.size.width) / Double(source.size.height)) < 0.25,
                "the gain map keeps the photo's shape at its own resolution")
        let planes = try await engine.render(source, recipe: Recipe(inputDomain: .dual, values: ["tone.exposure": .number(0.3)],
                                                                    geometry: geometry))
        #expect(planes.base.width == source.size.width && planes.base.height == source.size.height)
        let export = try await engine.openExportSource(heic, options: options)
        #expect(export.id == source.id && export.nativeSize == source.nativeSize)
    }
    @Test func projectivePixelsAndRegionReadsUseTheModelsInverseCoordinates() throws {
        let width = 160, height = 120
        var pixels = [Float]()
        for y in 0..<height {
            for x in 0..<width {
                pixels += [Float(x + 1) / Float(width), Float(y + 1) / Float(height), 1, 1]
            }
        }
        let space = CGColorSpace(name: CGColorSpace.extendedLinearSRGB)!
        let data = pixels.withUnsafeBytes { Data($0) }
        let image = CIImage(bitmapData: data, bytesPerRow: width * 16,
                            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: space)
        let context = CIContext(options: [.workingColorSpace: space])
        let photo = GeometrySize(width: Double(width), height: Double(height))
        for geometry in [Geometry(angle: 31, vertical: 100, horizontal: -100, quarterTurns: 1),
                         Geometry(angle: -45, horizontal: 90, quarterTurns: 3, flipped: true)] {
            let result = try OpenedSource.transform(image, geometry)
            let crop = geometry.cropRect(for: photo)
            let output = geometry.outputSize(of: photo)
            let inverse = geometry.transform(for: photo).inverse
            var full = [Float](repeating: 0, count: output.width * output.height * 4)
            context.render(result, toBitmap: &full, rowBytes: output.width * 16,
                           bounds: result.extent, format: .RGBAf, colorSpace: space)
            for (x, y) in [(output.width / 3, output.height / 3), (output.width * 2 / 3, output.height * 2 / 3)] {
                let source = inverse.apply(GeometryPoint(x: Double(x) + 0.5 - Double(output.width) / 2 + crop.centre.x,
                                                        y: Double(output.height) / 2 - Double(y) - 0.5 + crop.centre.y))
                // Core Image bitmap rows run from the top; bounds use y up.
                let index = ((output.height - 1 - y) * output.width + x) * 4
                #expect(abs(Double(full[index]) - (source.x + photo.width / 2 + 0.5) / photo.width) < 0.015)
                #expect(abs(Double(full[index + 1]) - (photo.height / 2 + source.y + 0.5) / photo.height) < 0.015)
                var region = [Float](repeating: 0, count: 4)
                context.render(result, toBitmap: &region, rowBytes: 16,
                               bounds: CGRect(x: x, y: y, width: 1, height: 1), format: .RGBAf, colorSpace: space)
                #expect(zip(region, full[index..<(index + 4)]).allSatisfy { abs($0 - $1) < 1e-5 })
            }
        }
    }

    @Test func oddCheckerboardHasTheSamePixelPhaseInPreviewRegionAndExport() async throws {
        let width = 95, height = 63
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                let index = (y * width + x) * 4
                bytes[index] = (x + y) % 2 == 0 ? 255 : 0
                bytes[index + 1] = bytes[index]
                bytes[index + 2] = bytes[index]
            }
        }
        let context = CIContext()
        let image = CIImage(bitmapData: Data(bytes), bytesPerRow: width * 4,
                            size: CGSize(width: width, height: height), format: .RGBA8,
                            colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("checker.png")
        try context.writePNGRepresentation(of: image, to: file, format: .RGBA8,
                                           colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!)
        let engine = try RenderEngine()
        for turns in 0..<4 {
            let geometry = Geometry(quarterTurns: turns, flipped: turns % 2 == 0,
                                    crop: CropRect(centreX: 0.071, centreY: -0.043, width: 0.53, height: 0.61))
            // A scaled/translated decoded preview must retain the native
            // crop phase, rather than snap its translation a second time.
            let transformed = try OpenedSource.transform(image, geometry)
            let decodedPreview = image.transformed(by: CGAffineTransform(translationX: 3, y: 7).scaledBy(x: 0.37, y: 0.41))
            let scaled = try OpenedSource.transform(decodedPreview, geometry,
                nativePhoto: GeometrySize(width: Double(width), height: Double(height)))
            let expected = transformed.transformed(by: CGAffineTransform(
                scaleX: scaled.extent.width / transformed.extent.width,
                y: scaled.extent.height / transformed.extent.height))
            let count = Int(scaled.extent.width * scaled.extent.height) * 4
            var expectedPixels = [Float](repeating: 0, count: count)
            var scaledPixels = expectedPixels
            context.render(expected, toBitmap: &expectedPixels, rowBytes: Int(scaled.extent.width) * 16,
                           bounds: scaled.extent, format: .RGBAf, colorSpace: nil)
            context.render(scaled, toBitmap: &scaledPixels, rowBytes: Int(scaled.extent.width) * 16,
                           bounds: scaled.extent, format: .RGBAf, colorSpace: nil)
            #expect(zip(expectedPixels, scaledPixels).allSatisfy { abs($0 - $1) < 1e-5 })
            var options = SourceOptions()
            options.geometry = geometry
            let full = try await engine.load(file, options: options)
            options.resolution = .preview(maximumSize: full.nativeSize)
            let preview = try await engine.load(file, options: options)
            let pixels = RenderEngine.readTexture(full.texture)
            let previewPixels = RenderEngine.readTexture(preview.texture)
            #expect(full.size == preview.size)
            #expect(zip(pixels, previewPixels).allSatisfy { abs($0 - $1) < 1e-5 })
            // Whole-pixel crop/turn/mirror must not blur the one-pixel checks.
            #expect(stride(from: 0, to: pixels.count, by: 4).allSatisfy { pixels[$0] < 0.001 || pixels[$0] > 0.999 })
            let export = try await engine.openExportSource(file, options: optionsWithFullResolution(options))
            let region = CGRect(x: 3, y: 5, width: 11, height: 9)
            let tile = try await engine.materializeExportRegion(export, outputSize: full.nativeSize, region: region, halo: 0)
            let tilePixels = RenderEngine.readTexture(tile.texture)
            for y in 0..<9 {
                for x in 0..<11 {
                    let sourceIndex = ((y + 5) * full.size.width + x + 3) * 4
                    let tileIndex = (y * 11 + x) * 4
                    #expect(abs(pixels[sourceIndex] - tilePixels[tileIndex]) < 1e-5)
                }
            }
        }
    }

    private func optionsWithFullResolution(_ options: SourceOptions) -> SourceOptions {
        var full = options
        full.resolution = .full
        return full
    }

}
