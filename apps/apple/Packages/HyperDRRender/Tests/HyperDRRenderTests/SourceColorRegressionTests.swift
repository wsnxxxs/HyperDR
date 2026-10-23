import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import HyperDRRecipe
import ImageIO
import Testing
import UniformTypeIdentifiers
@testable import HyperDRRender

@Suite(.serialized) struct SourceColorRegressionTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("source-colour-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeQuarters(to url: URL, width: Int, height: Int) throws {
        let bitmap = try #require(CGContext(data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        for (x, y, colour) in [(0, 0, CGColor(red: 0, green: 0, blue: 1, alpha: 1)),
                                (width / 2, 0, CGColor(gray: 1, alpha: 1)),
                                (0, height / 2, CGColor(red: 1, green: 0, blue: 0, alpha: 1)),
                                (width / 2, height / 2, CGColor(red: 0, green: 1, blue: 0, alpha: 1))] {
            bitmap.setFillColor(colour)
            bitmap.fill(CGRect(x: x, y: y, width: width / 2, height: height / 2))
        }
        let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, try #require(bitmap.makeImage()), nil)
        #expect(CGImageDestinationFinalize(writer))
    }

    private func close(_ a: [Float], _ b: [Float], tolerance: Float = 1 / 1023) {
        #expect(a.count == b.count)
        #expect(zip(a, b).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) } <= tolerance)
    }

    private func scalarTags(_ gain: AuthoredGainMap) throws -> [String: String] {
        let value = try #require(gain.auxiliaryInfo[kCGImageAuxiliaryDataInfoMetadata])
        var result: [String: String] = [:]
        CGImageMetadataEnumerateTagsUsingBlock(value as! CGImageMetadata, nil,
            [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, tag in
            // Descriptions of arrays/structures contain CGImageMetadataTag
            // object addresses. Compare every scalar leaf's actual contents.
            if CGImageMetadataTagGetType(tag) == .string, let value = CGImageMetadataTagCopyValue(tag) {
                result[path as String] = String(describing: value)
            }
            return true
        }
        return result
    }

    @Test func rasterPreviewBoundDescribesTheTransformedPhoto() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("quarters.png")
        try writeQuarters(to: file, width: 4000, height: 2000)
        let engine = try RenderEngine()
        let native = PixelSize(width: 4000, height: 2000)
        let geometries = [Geometry(crop: CropRect(centreX: 0, centreY: 0, width: 0.5, height: 0.5)),
                          Geometry(quarterTurns: 1),
                          Geometry(quarterTurns: 1, crop: CropRect(centreX: 0.1, centreY: -0.1, width: 0.5, height: 0.5)),
                          Geometry(angle: 11, vertical: 35, horizontal: -20)]
        for geometry in geometries {
            let full = geometry.outputSize(of: native)
            let resolution = try SourceResolution.preview(canvasSize: PixelSize(width: 1280, height: 1280), nativeSize: full)
            guard case .preview(let bound) = resolution else { Issue.record("Expected preview"); continue }
            var options = SourceOptions(resolution: resolution)
            options.geometry = geometry
            let source = try await engine.load(file, options: options)
            #expect(source.size == bound, "\(geometry): \(source.size), requested \(bound)")
            #expect(source.nativeSize == full && source.uncroppedSize == native)
            #expect(try await engine.transparentTexels(source.texture) == 0)
        }
    }

    @Test func croppedTurnedRasterPreviewAndLazyRegionsKeepTheirCoordinates() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("quarters.png")
        try writeQuarters(to: file, width: 1000, height: 600)
        let geometry = Geometry(quarterTurns: 1, crop: CropRect(centreX: 0, centreY: 0, width: 0.5, height: 0.5))
        var fullOptions = SourceOptions()
        fullOptions.geometry = geometry
        var previewOptions = fullOptions
        previewOptions.resolution = .preview(maximumSize: PixelSize(width: 150, height: 250))
        let engine = try RenderEngine()
        let full = try await engine.load(file, options: fullOptions)
        let preview = try await engine.load(file, options: previewOptions)
        #expect(full.size == PixelSize(width: 300, height: 500))
        #expect(preview.size == PixelSize(width: 150, height: 250))
        let recipe = Recipe(inputDomain: .sdr, geometry: geometry)
        let lazy = try await engine.openExportSource(file, options: fullOptions)
        for (x, y) in [(8, 12), (260, 12), (8, 450), (260, 450)] {
            let region = CGRect(x: x, y: y, width: 16, height: 20)
            let expected = RenderEngine.readPixels(try await engine.render(full, recipe: recipe, region: region))
            let tile = try await engine.materializeExportRegion(lazy, outputSize: full.size, region: region)
            let actual = RenderEngine.readPixels(try await engine.render(tile, recipe: recipe, size: full.size, region: region))
            close(expected.baseRGBA, actual.baseRGBA)
            // Sample the same quarter in the preview, away from its boundary.
            let previewRegion = CGRect(x: x / 2, y: y / 2, width: 1, height: 1)
            let small = RenderEngine.readPixels(try await engine.render(preview, recipe: recipe, region: previewRegion))
            close(Array(expected.baseRGBA.prefix(4)), small.baseRGBA)
        }
    }

    /// Write an actual ISO HEIC with a PQ primary, rather than assigning HDR
    /// metadata to a synthetic RenderSource that bypasses ImageIO's thumbnail.
    private func writeHDRBase(to url: URL, reverse: Bool) throws {
        let width = 128, height = 96
        let linear = CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)!
        let pq = CGColorSpace(name: CGColorSpace.itur_2100_PQ)!
        let value: CGFloat = reverse ? 2 : 0.5
        let image = CIImage(color: CIColor(red: value, green: value, blue: value, colorSpace: linear)!)
            .cropped(to: CGRect(x: 0, y: 0, width: width, height: height))
        let context = CIContext(options: [.workingColorSpace: linear, .workingFormat: CIFormat.RGBAf.rawValue])
        let cg = try #require(context.createCGImage(image, from: image.extent, format: .RGBA16, colorSpace: pq))
        let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL, UTType.heic.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(writer, cg, [kCGImageDestinationLossyCompressionQuality: 1,
                                               kCGImagePropertyOrientation: 6] as CFDictionary)
        let gain = reverse ? 2 : 1
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:HDRToneMap="http://ns.apple.com/HDRToneMap/1.0/"><HDRToneMap:Version>1</HDRToneMap:Version><HDRToneMap:BaseColorIsWorkingColor>True</HDRToneMap:BaseColorIsWorkingColor><HDRToneMap:BaseHeadroom>\(reverse ? 2 : 1)</HDRToneMap:BaseHeadroom><HDRToneMap:AlternateHeadroom>\(reverse ? 0 : 2)</HDRToneMap:AlternateHeadroom><HDRToneMap:ChannelMetadata><rdf:Seq><rdf:li rdf:parseType="Resource"><HDRToneMap:GainMapMin>\(gain)</HDRToneMap:GainMapMin><HDRToneMap:GainMapMax>\(gain)</HDRToneMap:GainMapMax><HDRToneMap:Gamma>1</HDRToneMap:Gamma><HDRToneMap:BaseOffset>0</HDRToneMap:BaseOffset><HDRToneMap:AlternateOffset>0</HDRToneMap:AlternateOffset></rdf:li></rdf:Seq></HDRToneMap:ChannelMetadata></rdf:Description></rdf:RDF></x:xmpmeta>
        """
        let metadata = try #require(CGImageMetadataCreateFromXMPData(Data(xml.utf8) as CFData))
        CGImageDestinationAddAuxiliaryDataInfo(writer, kCGImageAuxiliaryDataTypeISOGainMap, [
            kCGImageAuxiliaryDataInfoData: Data(repeating: 255, count: width * height),
            kCGImageAuxiliaryDataInfoDataDescription: ["Width": width, "Height": height,
                "BytesPerRow": width, "PixelFormat": kCVPixelFormatType_OneComponent8],
            kCGImageAuxiliaryDataInfoMetadata: metadata] as CFDictionary)
        #expect(CGImageDestinationFinalize(writer))
    }

    @Test(arguments: [false, true], [false, true])
    func HDRBasePreviewRetainsItsNativeEndpoint(reverse: Bool, croppedTurn: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("hdr-base.heic")
        try writeHDRBase(to: file, reverse: reverse)
        let geometry = croppedTurn
            ? Geometry(quarterTurns: 1, crop: CropRect(centreX: 0, centreY: 0, width: 0.75, height: 0.5)) : .identity
        var fullOptions = SourceOptions()
        fullOptions.geometry = geometry
        var smallOptions = fullOptions
        smallOptions.resolution = .preview(maximumSize: PixelSize(width: 32, height: 32))
        let opened = try RenderEngine.open(file, options: fullOptions)
        let smallOpened = try RenderEngine.open(file, options: smallOptions)
        let authored = try #require(opened.gain), smallAuthored = try #require(smallOpened.gain)
        #expect(CFEqual(opened.baseSpace, smallOpened.baseSpace))
        #expect(CFEqual(authored.baseColorSpace, smallAuthored.baseColorSpace))
        #expect(authored.baseColorSpace.name == CGColorSpace.itur_2100_PQ)
        #expect(smallOpened.image.contentHeadroom == opened.image.contentHeadroom)
        #expect(smallOpened.image.contentHeadroom > 1)
        let nativeTags = try scalarTags(authored), previewTags = try scalarTags(smallAuthored)
        #expect(nativeTags.count >= 9 && previewTags == nativeTags)
        #expect(smallAuthored.tags.filter { nativeTags[$0.key] != nil } == nativeTags)
        #expect(smallAuthored.isoChannels == authored.isoChannels)
        #expect(smallAuthored.baseHeadroom == (reverse ? 2 : 1))
        #expect(smallAuthored.alternateHeadroom == (reverse ? 0 : 2))

        let engine = try RenderEngine()
        let full = try await engine.load(file, options: fullOptions)
        let small = try await engine.load(file, options: smallOptions)
        #expect(small.id == full.id && small.domain == .dual)
        #expect(small.size == (croppedTurn ? PixelSize(width: 32, height: 16) : PixelSize(width: 24, height: 32)))
        let materialized = try #require(small.authoredGainMap)
        #expect(materialized.hasCanonicalSDRBase == reverse)
        #expect(materialized.baseHeadroom == (reverse ? 0 : 1) && materialized.alternateHeadroom == 2)
        #expect(materialized.nativeISOChannels == authored.nativeISOChannels)
        #expect(try scalarTags(materialized) == nativeTags)
        #expect((materialized.auxiliaryInfo[kCGImageAuxiliaryDataInfoData] as? Data) ==
                (authored.auxiliaryInfo[kCGImageAuxiliaryDataInfoData] as? Data))
        close(Array(RenderEngine.readTexture(full.texture).prefix(4)), Array(RenderEngine.readTexture(small.texture).prefix(4)))
        // The lazy export ROI must consume the same native endpoint after the
        // EXIF orientation, crop and quarter turn, including reverse ISO pairs.
        let recipe = Recipe(inputDomain: .dual, geometry: geometry)
        let lazy = try await engine.openExportSource(file, options: fullOptions)
        let region = CGRect(x: 3, y: 4, width: 19, height: 11)
        let expected = RenderEngine.readPixels(try await engine.render(full, recipe: recipe, region: region))
        let tile = try await engine.materializeExportRegion(lazy, outputSize: full.size, region: region)
        let actual = RenderEngine.readPixels(try await engine.render(tile, recipe: recipe, size: full.size, region: region))
        close(expected.baseRGBA, actual.baseRGBA)
    }
}
