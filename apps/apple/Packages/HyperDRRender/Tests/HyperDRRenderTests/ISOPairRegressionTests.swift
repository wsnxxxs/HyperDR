import CoreImage
import CoreVideo
import Foundation
import HyperDRRecipe
import ImageIO
import simd
import Testing
@testable import HyperDRRender

private final class ISOPairRows: @unchecked Sendable {
    var report: ExportRenderReport?
    var base: [Float] = []
    var gain: [Float] = []
}

/// Real ISO files are checked against Apple's native gain application and an
/// independent Double/ColorSync reference for a different gain working gamut.
/// Apple's auxiliary CIImage stays at its native resolution.
@Suite(.serialized) struct ISOPairRegressionTests {
    private let linearP3 = RenderEngine.workingColorSpace
    private let size = PixelSize(width: 64, height: 48)
    private let capabilities = ExportPairCapabilities(supportsThreeChannelGain: true)

    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("iso-pair-\(UUID())")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ url: URL, reverse: Bool, rgb: Bool = false, alternateGamut: Bool = false,
                       alternateOffsetMultiplier: Double = 2) throws {
        let colour: SIMD3<Float> = reverse ? SIMD3(0.35, 0.30, 0.25) : SIMD3(repeating: 0.25)
        let image = CIImage(color: CIColor(red: CGFloat(colour.x), green: CGFloat(colour.y), blue: CGFloat(colour.z), colorSpace: linearP3)!)
            .cropped(to: CGRect(x: 0, y: 0, width: size.width, height: size.height))
        let context = CIContext(options: [.workingColorSpace: linearP3, .workingFormat: CIFormat.RGBAf.rawValue])
        let space = CGColorSpace(name: reverse ? CGColorSpace.itur_2100_PQ : CGColorSpace.displayP3)!
        let cg = try #require(context.createCGImage(image, from: image.extent, format: reverse ? .RGBA16 : .RGBA8, colorSpace: space))
        let writer = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.heic" as CFString, 1, nil))
        CGImageDestinationAddImage(writer, cg, [kCGImageDestinationLossyCompressionQuality: 1] as CFDictionary)
        let channels = rgb ? 3 : 1, width = 32, height = 24
        let codes = Data((0..<(width * height * channels)).map { index in
            UInt8(index / channels % width < width / 2 ? 0 : 255)
        })
        let fields = (0..<channels).map { c in
            let low = reverse ? -0.5 + Double(c) * 0.1 : 0
            let high = reverse ? 1.5 - Double(c) * 0.1 : 2
            let gamma = 2 - Double(c) * 0.25
            let offset = reverse ? 0.01 * Double(c + 1) : 0
            return """
            <rdf:li rdf:parseType="Resource"><HDRToneMap:GainMapMin>\(low)</HDRToneMap:GainMapMin><HDRToneMap:GainMapMax>\(high)</HDRToneMap:GainMapMax><HDRToneMap:Gamma>\(gamma)</HDRToneMap:Gamma><HDRToneMap:BaseOffset>\(offset)</HDRToneMap:BaseOffset><HDRToneMap:AlternateOffset>\(offset * alternateOffsetMultiplier)</HDRToneMap:AlternateOffset></rdf:li>
            """
        }.joined()
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#"><rdf:Description rdf:about="" xmlns:HDRToneMap="http://ns.apple.com/HDRToneMap/1.0/"><HDRToneMap:Version>1</HDRToneMap:Version><HDRToneMap:BaseColorIsWorkingColor>\(alternateGamut ? "False" : "True")</HDRToneMap:BaseColorIsWorkingColor><HDRToneMap:BaseHeadroom>\(reverse ? 2 : 0)</HDRToneMap:BaseHeadroom><HDRToneMap:AlternateHeadroom>\(reverse ? 0 : 2)</HDRToneMap:AlternateHeadroom><HDRToneMap:ChannelMetadata><rdf:Seq>\(fields)</rdf:Seq></HDRToneMap:ChannelMetadata></rdf:Description></rdf:RDF></x:xmpmeta>
        """
        let metadata = try #require(CGImageMetadataCreateFromXMPData(Data(xml.utf8) as CFData))
        var auxiliary: [CFString: Any] = [
            kCGImageAuxiliaryDataInfoData: codes,
            kCGImageAuxiliaryDataInfoDataDescription: ["Width": width, "Height": height,
                "BytesPerRow": width * channels, "PixelFormat": rgb ? kCVPixelFormatType_24RGB : kCVPixelFormatType_OneComponent8],
            kCGImageAuxiliaryDataInfoMetadata: metadata]
        if alternateGamut { auxiliary[kCGImageAuxiliaryDataInfoColorSpace] = CGColorSpace(name: CGColorSpace.sRGB)! }
        CGImageDestinationAddAuxiliaryDataInfo(writer, kCGImageAuxiliaryDataTypeISOGainMap, auxiliary as CFDictionary)
        #expect(CGImageDestinationFinalize(writer))
    }

    private func system(_ url: URL, headroom: Float) throws -> [Float] {
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let decoded = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let base = CIImage(cgImage: decoded, options: [.toneMapHDRtoSDR: false])
        let gain = try #require(CIImage(contentsOf: url, options: [.auxiliaryHDRGainMap: true, .applyOrientationProperty: false]))
        let hdr = base.applyingGainMap(gain, headroom: headroom)
        let topDown = hdr.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(size.height)))
        var rgba = [Float](repeating: 0, count: size.width * size.height * 4)
        rgba.withUnsafeMutableBytes {
            CIContext(options: [.workingColorSpace: linearP3, .workingFormat: CIFormat.RGBAf.rawValue, .cacheIntermediates: false])
                .render(topDown, toBitmap: $0.baseAddress!, rowBytes: size.width * 16,
                    bounds: CGRect(x: 0, y: 0, width: size.width, height: size.height), format: .RGBAf, colorSpace: linearP3)
        }
        return stride(from: 0, to: rgba.count, by: 4).flatMap { Array(rgba[$0..<$0 + 3]) }
    }

    private func scalarTags(_ dictionary: NSDictionary) throws -> [String: String] {
        let metadata = try #require(dictionary[kCGImageAuxiliaryDataInfoMetadata]) as! CGImageMetadata
        var result: [String: String] = [:]
        CGImageMetadataEnumerateTagsUsingBlock(metadata, nil,
            [kCGImageMetadataEnumerateRecursively: true] as CFDictionary) { path, tag in
            // Container descriptions include object addresses; scalar contents
            // are the stable, complete metadata values to compare across opens.
            if CGImageMetadataTagGetType(tag) == .string, let value = CGImageMetadataTagCopyValue(tag) {
                result[path as String] = String(describing: value)
            }
            return true
        }
        return result
    }

    /// Apply the native ISO equation without Render's matrix or GPU kernels.
    /// ColorSync converts complete images into/out of the gain working gamut;
    /// encoded gain filtering, inverse gamma and signed weights use Double.
    private func mathematicalReference(_ url: URL, headroom: Double, outputSize: PixelSize? = nil) throws -> [Float] {
        let size = outputSize ?? self.size
        let source = try #require(CGImageSourceCreateWithURL(url as CFURL, nil))
        let primary = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        let info = try #require(CGImageSourceCopyAuxiliaryDataInfoAtIndex(source, 0, kCGImageAuxiliaryDataTypeISOGainMap)) as NSDictionary
        let tags = try scalarTags(info)
        func value(_ key: String) throws -> Double { try #require(tags[key].flatMap(Double.init)) }
        let baseHeadroom = try value("HDRToneMap:BaseHeadroom"), alternateHeadroom = try value("HDRToneMap:AlternateHeadroom")
        let weight = (min(max(log2(headroom), min(baseHeadroom, alternateHeadroom)), max(baseHeadroom, alternateHeadroom)) - baseHeadroom)
            / abs(alternateHeadroom - baseHeadroom)
        let usesBase = tags["HDRToneMap:BaseColorIsWorkingColor"] == "True"
        let encodedSpace = try #require(usesBase ? primary.colorSpace : (info[kCGImageAuxiliaryDataInfoColorSpace] as! CGColorSpace?))
        let gainSpace = try #require(CGColorSpaceCreateExtendedLinearized(encodedSpace))
        let context = CIContext(options: [.workingColorSpace: gainSpace, .workingFormat: CIFormat.RGBAf.rawValue])
        func rgba(_ image: CIImage, width: Int, height: Int, space: CGColorSpace?) -> [Float] {
            let topDown = image.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(height)))
            var result = [Float](repeating: 0, count: width * height * 4)
            result.withUnsafeMutableBytes {
                context.render(topDown, toBitmap: $0.baseAddress!, rowBytes: width * 16,
                    bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf, colorSpace: space)
            }
            return result
        }
        let primaryImage = CIImage(cgImage: primary, options: [.toneMapHDRtoSDR: false])
            .transformed(by: CGAffineTransform(scaleX: Double(size.width) / Double(primary.width),
                                              y: Double(size.height) / Double(primary.height)))
        let base = rgba(primaryImage, width: size.width, height: size.height, space: gainSpace)
        let encodedImage = try #require(CIImage(contentsOf: url, options: [.auxiliaryHDRGainMap: true,
            .applyOrientationProperty: false, .colorSpace: NSNull()]))
        let gainWidth = Int(encodedImage.extent.width), gainHeight = Int(encodedImage.extent.height)
        let encoded = rgba(encodedImage, width: gainWidth, height: gainHeight, space: nil)
        let count = tags["HDRToneMap:ChannelMetadata[1].Gamma"] == nil ? 1 : 3
        let channels = try (0..<3).map { channel -> (Double, Double, Double, Double, Double) in
            let prefix = "HDRToneMap:ChannelMetadata[\(count == 1 ? 0 : channel)]."
            return try (value(prefix + "GainMapMin"), value(prefix + "GainMapMax"), value(prefix + "Gamma"),
                        value(prefix + "BaseOffset"), value(prefix + "AlternateOffset"))
        }
        func sample(_ x: Double, _ y: Double, channel: Int) -> Double {
            let x0 = Int(floor(x)), y0 = Int(floor(y)), dx = x - floor(x), dy = y - floor(y)
            func at(_ px: Int, _ py: Int) -> Double {
                Double(encoded[(min(max(py, 0), gainHeight - 1) * gainWidth + min(max(px, 0), gainWidth - 1)) * 4 + channel])
            }
            return (at(x0, y0) * (1 - dx) + at(x0 + 1, y0) * dx) * (1 - dy)
                + (at(x0, y0 + 1) * (1 - dx) + at(x0 + 1, y0 + 1) * dx) * dy
        }
        var result = base
        for y in 0..<size.height { for x in 0..<size.width { for c in 0..<3 {
            let (low, high, gamma, baseOffset, alternateOffset) = channels[c]
            let code = min(max(sample((Double(x) + 0.5) * Double(gainWidth) / Double(size.width) - 0.5,
                                      (Double(y) + 0.5) * Double(gainHeight) / Double(size.height) - 0.5,
                                      channel: count == 1 ? 0 : c), 0), 1)
            let gain = low + (high - low) * pow(code, 1 / gamma)
            let i = (y * size.width + x) * 4 + c
            result[i] = Float((Double(base[i]) + baseOffset) * exp2(weight * gain) - alternateOffset)
        } } }
        // result has top-down rows; restore CI coordinates for the final whole-
        // image conversion, which is independent of Render's basis matrices.
        let image = CIImage(bitmapData: result.withUnsafeBytes { Data($0) }, bytesPerRow: size.width * 16,
            size: CGSize(width: size.width, height: size.height), format: .RGBAf, colorSpace: gainSpace)
            .transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: CGFloat(size.height)))
        let converted = rgba(image, width: size.width, height: size.height, space: linearP3)
        return stride(from: 0, to: converted.count, by: 4).flatMap { Array(converted[$0..<$0 + 3]) }
    }

    private func pixels(_ pair: DisplayGainPair, weight: Float) -> [Float] {
        #expect(pair.base.width == pair.gain.width && pair.base.height == pair.gain.height)
        let base = RenderEngine.readTexture(pair.base), gain = RenderEngine.readTexture(pair.gain)
        return (0..<(pair.base.width * pair.base.height)).flatMap { i -> [Float] in
            let j = i * 4, k = i * (pair.gainChannelCount == 1 ? 1 : 4)
            let b = SIMD3(base[j], base[j + 1], base[j + 2])
            let g = pair.gainChannelCount == 1 ? SIMD3(repeating: gain[k]) : SIMD3(gain[k], gain[k + 1], gain[k + 2])
            let value = pair.gainToP3 * ((pair.p3ToGain * b + pair.baseOffset)
                * SIMD3(exp2(g.x * weight), exp2(g.y * weight), exp2(g.z * weight)) - pair.alternateOffset)
            return [value.x, value.y, value.z]
        }
    }

    private func crop(_ rgb: [Float], size: PixelSize, region: CGRect) -> [Float] {
        (Int(region.minY)..<Int(region.maxY)).flatMap { y in
            Array(rgb[(y * size.width + Int(region.minX)) * 3..<(y * size.width + Int(region.maxX)) * 3])
        }
    }

    private func close(_ actual: [Float], _ expected: [Float], tolerance: Float = 0.0002) {
        #expect(actual.count == expected.count)
        #expect(zip(actual, expected).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) } <= tolerance)
    }

    private func closeCodes(_ actual: [Float], _ expected: [Float]) {
        #expect(actual.count == expected.count)
        // ImageIO's RGB auxiliary decode contains ~7e-8 at an encoded zero;
        // gamma=2 amplifies that noise. Bound it by one 10-bit display/export
        // code in both sRGB and PQ rather than widening a linear tolerance.
        func sRGB(_ value: Double) -> Double {
            let magnitude = abs(value)
            return (value < 0 ? -1 : 1) * (magnitude <= 0.0031308 ? 12.92 * magnitude : 1.055 * pow(magnitude, 1 / 2.4) - 0.055)
        }
        func pq(_ value: Double) -> Double {
            let p = pow(max(0, value) * 203 / 10_000, 2610.0 / 16384)
            return pow((3424.0 / 4096 + 2413.0 / 128 * p) / (1 + 2392.0 / 128 * p), 2523.0 / 32)
        }
        for curve in [sRGB, pq] {
            let error = zip(actual, expected).reduce(0.0) { max($0, abs(curve(Double($1.0)) - curve(Double($1.1))) * 1023) }
            #expect(error <= 1)
        }
    }

    private func collect(_ engine: RenderEngine, source: RenderSource, request: ExportRenderRequest,
                         recipe: Recipe? = nil) async throws -> ISOPairRows {
        let rows = ISOPairRows()
        _ = try await engine.renderExportStripes(source, recipe: recipe ?? Recipe(inputDomain: .dual), request: request, rows: 7,
            prepare: { rows.report = $0 }, consume: { rows.base += $0.baseRGB; rows.gain += $0.gain })
        return rows
    }

    private func hdr(_ rows: ISOPairRows) throws -> [Float] {
        let metadata = try #require(rows.report?.gain)
        return rows.base.indices.map { i in
            let channel = i % 3, pixel = i / 3
            let gain = rows.gain[pixel * metadata.channelCount + (metadata.channelCount == 1 ? 0 : channel)]
            return (rows.base[i] + metadata.baseOffset[channel]) * exp2(gain) - metadata.alternateOffset[channel]
        }
    }

    @Test func gammaTwoMatchesAppleAcrossIdentityHDRControlsROIAndExport() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("gamma-two.heic")
        try write(url, reverse: false)
        let reference = try system(url, headroom: 4)
        let engine = try RenderEngine(), source = try await engine.load(url)
        let full = try await engine.reconstructedHDR(source)
        let rgba = RenderEngine.readTexture(full.texture)
        close(stride(from: 0, to: rgba.count, by: 4).flatMap { Array(rgba[$0..<$0 + 3]) }, reference)
        for strength: Float in [0.999, 1, 1.001] {
            var edit = RenderAdjustments(); edit.hdr.strength = strength
            // A raised range keeps the >1 continuity check away from a shoulder.
            edit.hdr.range = 3
            let planes = try await engine.render(source, adjustments: edit)
            let pair = try await engine.displayPair(planes, source: source)
            let expected = try system(url, headroom: exp2(2 * min(1, strength)))
            if strength <= 1 { close(pixels(pair, weight: 1), expected) }
            else { close(pixels(pair, weight: 1), reference, tolerance: 0.0015) }
        }
        let region = CGRect(x: 27, y: 11, width: 12, height: 9)
        let planes = try await engine.render(source, recipe: Recipe(inputDomain: .dual), region: region)
        close(pixels(try await engine.displayPair(planes, source: source), weight: 1), crop(reference, size: size, region: region))
        let output = try await collect(engine, source: source, request: ExportRenderRequest(photoSize: size, capabilities: capabilities))
        close(try hdr(output), reference)
    }

    @Test(arguments: [false, true])
    func reverseSignedRGBKeepsNativeMetadataAndDisplayWeights(alternateGamut: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("reverse-rgb.heic")
        try write(url, reverse: true, rgb: true, alternateGamut: alternateGamut)
        let file = try Data(contentsOf: url)
        let native = try RenderEngine.open(url, options: SourceOptions())
        let original = try #require(native.gain)
        let engine = try RenderEngine(), source = try await engine.load(url)
        let metadata = try #require(source.authoredGainMap)
        let originalTags = try scalarTags(original.auxiliaryInfo)
        let expectedKeys = Set(["Version", "BaseColorIsWorkingColor", "BaseHeadroom", "AlternateHeadroom"]
            .map { "HDRToneMap:" + $0 } + (0..<3).flatMap { c in
                ["GainMapMin", "GainMapMax", "Gamma", "BaseOffset", "AlternateOffset"]
                    .map { "HDRToneMap:ChannelMetadata[\(c)]." + $0 }
            })
        #expect(metadata.hasCanonicalSDRBase && Set(originalTags.keys) == expectedKeys)
        #expect(try scalarTags(metadata.auxiliaryInfo) == originalTags)
        #expect(metadata.tags.filter { originalTags[$0.key] != nil } == originalTags)
        #expect(metadata.nativeISOChannels == original.nativeISOChannels)
        #expect((metadata.auxiliaryInfo[kCGImageAuxiliaryDataInfoDataDescription] as? NSDictionary)
            == (original.auxiliaryInfo[kCGImageAuxiliaryDataInfoDataDescription] as? NSDictionary))
        #expect(metadata.auxiliaryInfo[kCGImageAuxiliaryDataInfoData] as? Data
            == original.auxiliaryInfo[kCGImageAuxiliaryDataInfoData] as? Data)
        #expect(metadata.image.extent == original.image.extent)
        #expect(metadata.baseHeadroom == 0 && metadata.alternateHeadroom == 2)
        #expect(metadata.isoChannels?.allSatisfy { $0.baseOffset == $0.alternateOffset } == true)
        #expect(original.isoChannels?.contains { $0.minimum < 0 && $0.baseOffset != $0.alternateOffset } == true)
        if alternateGamut {
            #expect(metadata.usesBaseColorSpace == false)
            #expect(metadata.auxiliaryColorSpace?.name == CGColorSpace.sRGB)
        }
        func reference(_ headroom: Float) throws -> [Float] {
            // Core Image's applyingGainMap does not use the auxiliary sRGB
            // profile here. Its native same-gamut path remains an independent
            // oracle; use whole-image ColorSync + Double ISO math otherwise.
            try alternateGamut ? mathematicalReference(url, headroom: Double(headroom)) : system(url, headroom: headroom)
        }
        let planes = try await engine.render(source, recipe: Recipe(inputDomain: .dual))
        let pair = try await engine.displayPair(planes, source: source)
        for weight: Float in [0, 0.5, 1] {
            closeCodes(pixels(pair, weight: weight), try reference(exp2(2 * weight)))
        }
        let fullReference = try reference(4)
        let hdrTexture = try await engine.reconstructedHDR(source)
        let rgba = RenderEngine.readTexture(hdrTexture.texture)
        close(stride(from: 0, to: rgba.count, by: 4).flatMap { Array(rgba[$0..<$0 + 3]) }, fullReference)
        var disabled = RenderAdjustments(); disabled.hdr.enabled = false
        let sdr = try await engine.render(source, adjustments: disabled)
        closeCodes(pixels(try await engine.displayPair(sdr, source: source), weight: 1), try reference(1))
        var strength = RenderAdjustments(); strength.hdr.strength = 0.999
        let near = try await engine.render(source, adjustments: strength)
        closeCodes(pixels(try await engine.displayPair(near, source: source), weight: 1), try reference(exp2(1.998)))
        let output = try await collect(engine, source: source, request: ExportRenderRequest(photoSize: size, capabilities: capabilities))
        close(try hdr(output), fullReference)
        let sdrOutput = try await collect(engine, source: source,
            request: ExportRenderRequest(photoSize: size, includesGain: false, capabilities: capabilities))
        closeCodes(sdrOutput.base, try reference(1))
        #expect(try Data(contentsOf: url) == file)
    }

    @Test func reverseNormalizationPreservesNegativeSDRUntilReconstruction() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("reverse-signed-sdr.heic")
        try write(url, reverse: true, alternateOffsetMultiplier: 15)
        let engine = try RenderEngine(), source = try await engine.load(url)
        #expect(RenderEngine.readTexture(source.texture).contains { $0 < 0 })
        let planes = try await engine.render(source, recipe: Recipe(inputDomain: .dual))
        let pair = try await engine.displayPair(planes, source: source)
        for weight: Float in [0, 0.5, 1] {
            close(pixels(pair, weight: weight), try system(url, headroom: exp2(2 * weight)))
        }
        let region = CGRect(x: 28, y: 9, width: 10, height: 7)
        let tile = try await engine.render(source, recipe: Recipe(inputDomain: .dual), region: region)
        close(pixels(try await engine.displayPair(tile, source: source), weight: 1),
              crop(try system(url, headroom: 4), size: size, region: region))
        let output = try await collect(engine, source: source, request: ExportRenderRequest(photoSize: size, capabilities: capabilities))
        close(try hdr(output), try system(url, headroom: 4))
    }

    @Test(arguments: [false, true])
    func reverseDownscaleLightEditsUseTheSameTargetPair(alternateGamut: Bool) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("reverse-light-edit.heic")
        try write(url, reverse: true, rgb: true, alternateGamut: alternateGamut)
        let engine = try RenderEngine(), source = try await engine.load(url)
        let lazy = try await engine.openExportSource(url)
        for outputSize in [size, PixelSize(width: 32, height: 24), PixelSize(width: 39, height: 29)] {
            let original = try await engine.displayPair(engine.render(source, recipe: Recipe(inputDomain: .dual), size: outputSize), source: source)
            for weight: Float in [0, 0.5, 1] {
                closeCodes(pixels(original, weight: weight),
                    try mathematicalReference(url, headroom: Double(exp2(2 * weight)), outputSize: outputSize))
            }
            for colourEdit in [false, true] {
                var edit = RenderAdjustments()
                if colourEdit { edit.color.saturation = 0.0001 } else { edit.tone.exposure = 0.0001 }
                let full = try await engine.displayPair(engine.render(source, adjustments: edit, size: outputSize), source: source)
                // A tiny edit must not switch from output-grid normalization to
                // interpolation of a different, native-grid SDR rendition.
                close(pixels(full, weight: 0), pixels(original, weight: 0))
                close(pixels(full, weight: 1), pixels(original, weight: 1))
                let region = CGRect(x: outputSize.width / 2 - 3, y: outputSize.height / 2 - 2, width: 7, height: 5)
                let roi = try await engine.displayPair(engine.render(source, adjustments: edit, size: outputSize, region: region), source: source)
                let tile = try await engine.materializeExportRegion(lazy, outputSize: outputSize, region: region)
                let exportROI = try await engine.displayPair(engine.render(tile, adjustments: edit, size: outputSize, region: region), source: tile)
                for weight: Float in [0, 0.5, 1] {
                    let expected = crop(pixels(full, weight: weight), size: outputSize, region: region)
                    close(pixels(roi, weight: weight), expected)
                    close(pixels(exportROI, weight: weight), expected)
                }
            }
        }
    }

    @Test func reverseDownscaleGeometryAndLazyRowsKeepTheHDREndpoint() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("reverse-regions.heic")
        try write(url, reverse: true, alternateGamut: true)
        let reference = try system(url, headroom: 4)
        // Primary pixels and offsets are constant: the full HDR rendition must
        // stay constant through arbitrary resizes, even across the gain edge.
        let colour = Array(reference.prefix(3))
        let engine = try RenderEngine()
        for geometry in [Geometry.identity, Geometry(quarterTurns: 1, crop: CropRect(centreX: 0, centreY: 0, width: 0.75, height: 0.5))] {
            var options = SourceOptions(); options.geometry = geometry
            let source = try await engine.load(url, options: options)
            let outputSize = PixelSize(width: max(5, source.size.width * 3 / 5), height: max(5, source.size.height * 3 / 5))
            let planes = try await engine.render(source, recipe: Recipe(inputDomain: .dual), size: outputSize)
            let pair = try await engine.displayPair(planes, source: source)
            close(pixels(pair, weight: 1), (0..<(outputSize.width * outputSize.height)).flatMap { _ in colour })
            var edit = RenderAdjustments(); edit.tone.exposure = 0.0001
            let changed = try await engine.displayPair(engine.render(source, adjustments: edit, size: outputSize), source: source)
            close(pixels(changed, weight: 0), pixels(pair, weight: 0))
            close(pixels(changed, weight: 1), pixels(pair, weight: 1))
            let lazy = try await engine.openExportSource(url, options: options)
            let region = CGRect(x: outputSize.width / 2 - 3, y: outputSize.height / 2 - 2, width: 7, height: 5)
            let tile = try await engine.materializeExportRegion(lazy, outputSize: outputSize, region: region)
            let changedROI = try await engine.displayPair(engine.render(tile, adjustments: edit, size: outputSize, region: region), source: tile)
            for weight: Float in [0, 0.5, 1] {
                close(pixels(changedROI, weight: weight), crop(pixels(changed, weight: weight), size: outputSize, region: region))
            }
            var recipe = Recipe(inputDomain: .dual); recipe.setValue(.number(0.0001), for: "tone.exposure")
            let editedRows = try await collect(engine, source: source,
                request: ExportRenderRequest(photoSize: outputSize, capabilities: capabilities), recipe: recipe)
            close(try hdr(editedRows), pixels(changed, weight: 1))
            let request = ExportRenderRequest(photoSize: outputSize, capabilities: capabilities)
            let reader = try await engine.prepareExportRows(lazy, recipe: Recipe(inputDomain: .dual), request: request)
            let first = try reader.read(y: 1, count: 3), replay = try reader.read(y: 1, count: 3)
            #expect(first.baseRGB == replay.baseRGB && first.gain == replay.gain)
            let rows = ISOPairRows(); rows.report = reader.report; rows.base = first.baseRGB; rows.gain = first.gain
            close(try hdr(rows), (0..<(outputSize.width * 3)).flatMap { _ in colour })
        }
    }
}
