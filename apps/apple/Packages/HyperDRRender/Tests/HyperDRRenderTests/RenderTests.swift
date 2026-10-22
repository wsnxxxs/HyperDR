import Foundation
import CoreImage
import CoreML
import ImageIO
import Metal
import Testing
import HyperDRRecipe
@testable import HyperDRRender

private let p3 = RenderEngine.workingColorSpace
private func image(_ pixels: [SIMD4<Float>], width: Int, height: Int) -> CIImage {
    CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
            size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: p3)
}
private func close(_ a: [Float], _ b: [Float], tolerance: Float = 0.00001) {
    #expect(a.count == b.count)
    for (x, y) in zip(a, b) { #expect(abs(x - y) <= tolerance) }
}

@Suite(.serialized) struct RenderTests {
    @Test func oldSourceCannotAnalyzeReplacementFile() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tiff")
        defer { try? FileManager.default.removeItem(at:url) }
        func write(_ gray: UInt8, modified: Date) throws {
            let bytes = Data([gray,gray,gray,255])
            let provider = CGDataProvider(data:bytes as CFData)!
            let cg = CGImage(width:1,height:1,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,
                bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue),provider:provider,
                decode:nil,shouldInterpolate:false,intent:.defaultIntent)!
            let destination = CGImageDestinationCreateWithURL(url as CFURL,"public.tiff" as CFString,1,nil)!
            CGImageDestinationAddImage(destination,cg,nil)
            #expect(CGImageDestinationFinalize(destination))
            try FileManager.default.setAttributes([.modificationDate:modified],ofItemAtPath:url.path)
        }
        try write(32,modified:Date(timeIntervalSince1970:1000))
        let engine = try RenderEngine()
        let old = try await engine.load(url)
        let before = RenderEngine.readPixels(try await engine.render(old,recipe:Recipe(inputDomain:.sdr)))
        #expect(before.gain == [0])
        let provider = try CoreMLModelGainProvider(computeUnits:.cpuOnly,analysisLongSide:32)
        let prediction = try await engine.predictModelGain(old,provider:provider)
        let different = try await engine.load(url,options:SourceOptions(lensCorrection:false))
        let restored = try await engine.load(url)
        #expect(different.id != old.id && restored.id == old.id)
        let reused = try await engine.predictModelGain(restored,provider:provider)
        #expect(prediction.gain === reused.gain)
        let transferred = try await RenderEngine().load(url)
        #expect(transferred.id == old.id)
        await engine.clearCaches()
        #expect(try await engine.load(url).id == old.id)
        try write(240,modified:Date(timeIntervalSince1970:2000))
        let new = try await engine.load(url)
        #expect(new.id != old.id)
        let current = try await engine.analysis(new)
        #expect(current.peaks.x > 0.8)
        // New-source analysis must not be silently reused under the old identity.
        do { _ = try await engine.render(old,recipe:Recipe(inputDomain:.sdr)); Issue.record("Replaced source rendered") }
        catch RenderError.sourceChanged {}
        await engine.clearCaches()
        do { _ = try await engine.sourceReport(old); Issue.record("Replaced source analyzed after cache clear") }
        catch RenderError.sourceChanged {}
        let other = try RenderEngine()
        do { _ = try await other.analysis(old); Issue.record("Replaced source analyzed by another engine") }
        catch RenderError.sourceChanged {}
        // Already materialized pixels remain the original photo, independent of the URL.
        let retained = RenderEngine.readPixels(try await engine.render(old,nodes:[IdentityNode()]))
        #expect(retained.baseRGBA == before.baseRGBA)
    }

    @Test func identityPreservesEDRNegativesAndAlpha() async throws {
        let engine = try RenderEngine()
        let values: [SIMD4<Float>] = [SIMD4(-0.1, 0.2, 2, 1), SIMD4(0.18, 0.18, 0.18, 1)]
        let source = try await engine.source(image: image(values, width: 2, height: 1), domain: .sdr)
        let planes = try await engine.render(source, nodes: [IdentityNode()])
        let output = RenderEngine.readPixels(planes)
        close(output.baseRGBA, values.flatMap { [$0.x, $0.y, $0.z, $0.w] })
        #expect(output.gain == [0, 0])
        #expect(DoubleReference.identity(SIMD3(-0.1, 0.2, 2)) == SIMD3(-0.1, 0.2, 2))
    }

    @Test func splitMatchesDoubleAndStripesAtRequestedSize() async throws {
        let engine = try RenderEngine()
        let samples: [SIMD4<Float>] = [SIMD4(4, 2, 1, 1), SIMD4(0.18, 0.18, 0.18, 1),
                                     SIMD4(-0.1, 0.6, 1.5, 1), SIMD4(16, 12, 2, 1)]
        let source = try await engine.source(image: image(samples, width: 2, height: 2), domain: .hdr)
        let full = RenderEngine.readPixels(try await engine.render(source))
        // CI bitmap inputs use top-down scanlines, just like ImageIO.
        for (index, input) in samples.enumerated() {
            let expected = DoubleReference.sourceHDRSplit(SIMD3(Double(input.x), Double(input.y), Double(input.z)))
            for c in 0..<3 { #expect(abs(Double(full.baseRGBA[index * 4 + c]) - expected.base[c]) < 0.00005) }
            #expect(abs(Double(full.gain[index]) - expected.gain) < 0.00001)
        }
        let target = PixelSize(width: 7, height: 5)
        let resized = RenderEngine.readPixels(try await engine.render(source, size: target))
        let collector = Collector()
        try await engine.renderStripes(source, size: target, rows: 2) { collector.append($0) }
        close(collector.base, resized.baseRGBA)
        close(collector.gain, resized.gain)
    }

    @Test func repeatAcrossContextsWithinOneCode() async throws {
        let input = image([SIMD4(4.1, 0.6, 0.1, 1), SIMD4(-0.03, 0.7, 2.1, 1)], width: 2, height: 1)
        let firstEngine = try RenderEngine()
        let source = try await firstEngine.source(image: input, domain: .rawEDR)
        let first = RenderEngine.readPixels(try await firstEngine.render(source))
        await firstEngine.clearCaches()
        let repeated = RenderEngine.readPixels(try await firstEngine.render(source))
        let nextEngine = try RenderEngine()
        let nextSource = try await nextEngine.source(image: input, domain: .rawEDR)
        let next = RenderEngine.readPixels(try await nextEngine.render(nextSource))
        for candidate in [repeated, next] {
            func code(_ sample: Float) -> Int {
                let value = min(1, max(0, Double(sample)))
                let encoded = value <= 0.0031308 ? value * 12.92 : 1.055 * pow(value, 1 / 2.4) - 0.055
                return Int((encoded * 1023).rounded())
            }
            for (a, b) in zip(candidate.baseRGBA, first.baseRGBA) {
                #expect(abs(code(a) - code(b)) <= 1)
            }
            for (a, b) in zip(candidate.gain, first.gain) {
                #expect(abs(Int((a * 1023 / 3).rounded()) - Int((b * 1023 / 3).rounded())) <= 1)
            }
        }
    }

    @Test func duplicateSourceSplitIsRejectedBeforeRendering() async throws {
        let engine = try RenderEngine()
        let source = try await engine.source(image: image([SIMD4(4,2,1,1)],width:1,height:1),domain:.hdr)
        let valid = RenderEngine.readPixels(try await engine.render(source,nodes:[SourceHDRSplitNode()]))
        close(valid.baseRGBA,[1,0.5,0.25,1]); close(valid.gain,[2])
        let duplicate: [any RenderNode] = [SourceHDRSplitNode(),IdentityNode(),SourceHDRSplitNode()]
        do {
            _ = try await engine.render(source,nodes:duplicate)
            Issue.record("Duplicate split graph accepted")
        } catch RenderError.duplicateHDRSplit {}
        do {
            try await engine.renderStripes(source,nodes:duplicate) { _ in Issue.record("Invalid stripe graph consumed") }
            Issue.record("Duplicate stripe split graph accepted")
        } catch RenderError.duplicateHDRSplit {}
    }

    @Test func imageIOOrientationAndCache() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".tiff")
        defer { try? FileManager.default.removeItem(at: url) }
        // First CGImage scanline is the top row. EXIF 6 rotates this clockwise.
        let bytes = Data([255, 0, 0, 255, 0, 255, 0, 255])
        let cg = CGImage(width: 2, height: 1, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: 8, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
            provider: CGDataProvider(data: bytes as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.tiff" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cg, [kCGImagePropertyOrientation: 6] as CFDictionary)
        #expect(CGImageDestinationFinalize(destination))
        let engine = try RenderEngine()
        let source = try await engine.load(url)
        let cached = try await engine.load(url)
        #expect(source.id == cached.id)
        #expect(source.domain == .sdr)
        #expect(source.size == PixelSize(width: 1, height: 2))
        let pixels = RenderEngine.readPixels(try await engine.render(source))
        #expect(pixels.baseRGBA[0] > pixels.baseRGBA[1])
        #expect(pixels.baseRGBA[5] > pixels.baseRGBA[4])
        let thumbnail = try await engine.sdrThumbnail(try await engine.render(source))
        let roundTrip = try await engine.source(image:CIImage(cgImage:thumbnail),domain:.sdr)
        let thumbnailPixels = RenderEngine.readPixels(try await engine.render(roundTrip))
        #expect(thumbnailPixels.baseRGBA[0] > thumbnailPixels.baseRGBA[1])
        #expect(thumbnailPixels.baseRGBA[5] > thumbnailPixels.baseRGBA[4])
        let preview = try await engine.load(url,options:SourceOptions(resolution:.preview(maximumSize:PixelSize(width:1,height:1))))
        #expect(preview.domain == .sdr && preview.size == PixelSize(width:1,height:1))
        #expect(preview.nativeSize == PixelSize(width:1,height:2))
        let fixed = try await engine.analysis(preview)
        let another = try RenderEngine()
        let independent = try await another.analysis(preview)
        #expect(fixed.size == PixelSize(width:1,height:2) && fixed.size == independent.size)
        close(RenderEngine.readTexture(fixed.cells),RenderEngine.readTexture(independent.cells))
        #expect(try SourceResolution.preview(canvasSize:PixelSize(width:1400,height:900),nativeSize:PixelSize(width:6000,height:4000))
                == .preview(maximumSize:PixelSize(width:2048,height:1365)))
    }

    @Test func authoredISOPairPassesThroughAndReconstructs() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".heic")
        defer { try? FileManager.default.removeItem(at: url) }
        let base = CIImage(color: CIColor(red: 0.25, green: 0.2, blue: 0.1, colorSpace: p3)!)
            .cropped(to: CGRect(x: 0, y: 0, width: 16, height: 8))
        let hdr = image(Array(repeating: SIMD4(4, 2, 1, 1), count: 128), width: 16, height: 8).settingContentHeadroom(4)
        let writer = CIContext(options: [.workingFormat: CIFormat.RGBAf.rawValue, .workingColorSpace: p3])
        try writer.writeHEIFRepresentation(of: base, to: url, format: .RGBA8,
                                           colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, options: [.hdrImage: hdr])
        let engine = try RenderEngine()
        let source = try await engine.load(url)
        #expect(source.domain == .dual)
        let authored = try #require(source.authoredGainMap)
        #expect(authored.channelCount == 1 || authored.channelCount == 3)
        #expect(authored.isoChannels != nil)
        let pair = try await engine.render(source, nodes: [IdentityNode()])
        #expect(pair.provenance == .authored)
        #expect(pair.base === source.texture)
        #expect(pair.gain === source.gainTexture!)
        if case .authored(let carried) = pair.encoding {
            #expect(carried.auxiliaryInfo == authored.auxiliaryInfo)
        } else { Issue.record("Lost authored metadata") }
        let reconstructed = RenderEngine.readTexture(try await engine.reconstructedHDR(source).texture)
        #expect(reconstructed.max()! > 1)
        // An explicit HDR operation crosses the edit boundary and produces scalar zero-offset gain.
        let edited = try await engine.render(source, nodes: [AdjustmentNode(.exposure, value: 0.5)])
        #expect(edited.provenance == .resplit)
        #expect(edited.gainChannelCount == 1)
        if case .log2 = edited.encoding {} else { Issue.record("Edited pair was not resplit") }
        let preview = try await engine.load(url,options:SourceOptions(resolution:.preview(maximumSize:PixelSize(width:8,height:4))))
        #expect(preview.domain == .dual && preview.size == PixelSize(width:8,height:4))
        #expect(preview.nativeSize == PixelSize(width:16,height:8))
        let previewGain = try #require(preview.authoredGainMap)
        #expect(previewGain.isoChannels == authored.isoChannels)
        #expect(previewGain.baseHeadroom == authored.baseHeadroom && previewGain.alternateHeadroom == authored.alternateHeadroom)
        #expect(previewGain.usesBaseColorSpace == authored.usesBaseColorSpace)
        #expect((previewGain.auxiliaryInfo[kCGImageAuxiliaryDataInfoData] as? Data) ==
                (authored.auxiliaryInfo[kCGImageAuxiliaryDataInfoData] as? Data))
        #expect(RenderEngine.readTexture(try await engine.reconstructedHDR(preview).texture).max()! > 1)
        let pqURL = url.deletingPathExtension().appendingPathExtension("pq.heic")
        defer { try? FileManager.default.removeItem(at:pqURL) }
        try writer.writeHEIF10Representation(of:hdr,to:pqURL,colorSpace:CGColorSpace(name:CGColorSpace.itur_2100_PQ)!,options:[:])
        let pqPreview = try await engine.load(pqURL,options:SourceOptions(resolution:.preview(maximumSize:PixelSize(width:8,height:4))))
        #expect(pqPreview.domain == .hdr && pqPreview.size == PixelSize(width:8,height:4))
        #expect(RenderEngine.readTexture(try await engine.reconstructedHDR(pqPreview).texture).max()! > 1)
    }

    @Test func rawG2KeepsFileBaselineAndCachesDevelopment() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let fixture = root.appendingPathComponent("build/fixtures/sony-ilce-7s.ARW")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            throw FixtureError.missingRAW // Run scripts/fetch_test_fixtures.py.
        }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ARW")
        try FileManager.default.copyItem(at: fixture, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let defaults = try #require(CIRAWFilter(imageURL: temporary))
        let engine = try RenderEngine()
        let target = PixelSize(width:2560,height:1707)
        let fullStart = DispatchTime.now().uptimeNanoseconds
        let source = try await engine.load(temporary, options: SourceOptions(lensCorrection: false))
        let fullLoaded = DispatchTime.now().uptimeNanoseconds
        _ = try await engine.render(source,recipe:Recipe(inputDomain:.rawEDR),size:target)
        let fullRendered = DispatchTime.now().uptimeNanoseconds
        let cached = try await engine.load(temporary, options: SourceOptions(lensCorrection: false))
        #expect(source.id == cached.id)
        #expect(source.domain == .rawEDR)
        let settings = try #require(source.rawSettings)
        #expect(settings.boost == 1)
        #expect(settings.boostShadow == defaults.boostShadowAmount)
        #expect(settings.baselineExposure == defaults.baselineExposure)
        #expect(settings.localToneMap == 0 && settings.extendedDynamicRange == 1)
        #expect(!settings.lensCorrectionApplied)
        #expect(settings.sharpness == defaults.sharpnessAmount)
        #expect(settings.luminanceNR == defaults.luminanceNoiseReductionAmount)
        #expect(settings.colorNR == defaults.colorNoiseReductionAmount)
        #expect(settings.temperature == defaults.neutralTemperature)
        #expect(settings.tint == defaults.neutralTint)
        #expect(settings.sourceValues["develop.tint"] == Double(defaults.neutralTint))
        #expect(settings.sourceValues["develop.temperature"] == Double(defaults.neutralTemperature))
        #expect(settings.sourceValues["develop.luminanceNR"] == Double(defaults.luminanceNoiseReductionAmount)*100)
        #expect(settings.capabilities.contains("CIRAWFilter.isSharpnessSupported") == defaults.isSharpnessSupported)
        #expect(settings.scaleFactor == 1 && !settings.isDraft)
        let previewOptions = SourceOptions(lensCorrection:false,rawResolution:.preview(maximumSize:target))
        let previewStart = DispatchTime.now().uptimeNanoseconds
        let preview = try await engine.load(temporary,options:previewOptions)
        let previewLoaded = DispatchTime.now().uptimeNanoseconds
        _ = try await engine.render(preview,recipe:Recipe(inputDomain:.rawEDR),size:target)
        let previewRendered = DispatchTime.now().uptimeNanoseconds
        let previewCached = try await engine.load(temporary,options:previewOptions)
        let previewSettings = try #require(preview.rawSettings)
        #expect(preview.id == source.id && preview.id == previewCached.id)
        #expect(preview.texture !== source.texture)
        let restoredFull = try await engine.load(temporary,options:SourceOptions(lensCorrection:false))
        #expect(restoredFull.texture === source.texture)
        let previewAnalysis = try await engine.analysis(preview)
        let fullAnalysis = try await engine.analysis(source)
        #expect(previewAnalysis.cells === fullAnalysis.cells && previewAnalysis.expansion === fullAnalysis.expansion)
        #expect(preview.size.width <= target.width+1 && preview.size.height <= target.height+1)
        #expect(previewSettings.nativeSize == settings.nativeSize && previewSettings.scaleFactor < 1)
        #expect(!previewSettings.isDraft && previewSettings.sharpness == settings.sharpness)
        func milliseconds(_ duration: UInt64) -> Double { Double(duration)/1e6 }
        print("P7-1c RAW output=2560x1707 full_source=\(source.size.width)x\(source.size.height) full_decode_ms=\(milliseconds(fullLoaded-fullStart)) full_graph_ms=\(milliseconds(fullRendered-fullLoaded)) preview_source=\(preview.size.width)x\(preview.size.height) preview_decode_ms=\(milliseconds(previewLoaded-previewStart)) preview_graph_ms=\(milliseconds(previewRendered-previewLoaded))")
        // Independent AE-2 G2 development, with the file defaults left intact.
        defaults.boostAmount = 1
        defaults.exposure = 0
        defaults.extendedDynamicRangeAmount = 1
        defaults.isGamutMappingEnabled = true
        defaults.isDraftModeEnabled = false
        if defaults.isContrastSupported { defaults.contrastAmount = 0 }
        if defaults.isLocalToneMapSupported { defaults.localToneMapAmount = 0 }
        if defaults.isLensCorrectionSupported { defaults.isLensCorrectionEnabled = false }
        let reference = try #require(defaults.outputImage)
        let x = source.size.width / 3, y = source.size.height / 3
        var actual = [Float](repeating: 0, count: 4)
        actual.withUnsafeMutableBytes { bytes in
            source.texture.getBytes(bytes.baseAddress!, bytesPerRow: 16,
                                    from: MTLRegionMake2D(x, y, 1, 1), mipmapLevel: 0)
        }
        var expected = [Float](repeating: 0, count: 4)
        let context = CIContext(options: [.workingFormat: CIFormat.RGBAf.rawValue, .workingColorSpace: p3])
        expected.withUnsafeMutableBytes { bytes in
            context.render(reference, toBitmap: bytes.baseAddress!, rowBytes: 16,
                bounds: CGRect(x: x, y: source.size.height - 1 - y, width: 1, height: 1), format: .RGBAf, colorSpace: p3)
        }
        close(actual, expected, tolerance: 0.00005)
        var raw = RAWAdjustments()
        raw.temperature = settings.temperature + 200
        raw.tint = settings.tint + 2
        raw.luminanceNR = 0.4; raw.colorNR = 0.3; raw.sharpness = 0.2
        let developed = try await engine.load(temporary, options: SourceOptions(lensCorrection: false, raw: raw))
        let adjusted = try #require(developed.rawSettings)
        #expect(developed.id != source.id)
        #expect(adjusted.temperature == raw.temperature && adjusted.tint == raw.tint)
        #expect(adjusted.sourceValues == settings.sourceValues)
        if adjusted.supportsLuminanceNR { #expect(adjusted.luminanceNR == 0.4) }
        if adjusted.supportsColorNR { #expect(adjusted.colorNR == 0.3) }
        if adjusted.supportsSharpness { #expect(adjusted.sharpness == 0.2) }
    }

    @Test func logLookSelectsSceneLinearDevelopment() throws {
        let look = LUTReference(contentHash: "sha256:" + String(repeating: "ab", count: 32), name: "Log")
        let active = Recipe(inputDomain: .rawEDR, look: look, values: ["look.input": .string("slog3-sgamut3cine")])
        #expect(try SourceOptions(recipe: active).sceneLinear)
        for id in ["slog3-sgamut3", "vlog-vgamut", "flog2-fgamut", "logc3-awg3", "logc4-awg4", "clog3-cinemagamut"] {
            let recipe = Recipe(inputDomain: .rawEDR, look: look, values: ["look.input": .string(id)])
            #expect(try SourceOptions(recipe: recipe).sceneLinear)
        }
        let disabled = Recipe(inputDomain: .rawEDR, look: look, values: [
            "look.input": .string("slog3-sgamut3"), "look.enabled": .bool(false)])
        let zero = Recipe(inputDomain: .rawEDR, look: look, values: [
            "look.input": .string("vlog-vgamut"), "look.strength": .number(0)])
        let display = Recipe(inputDomain: .rawEDR, look: look, values: ["look.input": .string("p3")])
        let absent = Recipe(inputDomain: .rawEDR, values: ["look.input": .string("slog3-sgamut3cine")])
        #expect(try !SourceOptions(recipe: disabled).sceneLinear)
        #expect(try !SourceOptions(recipe: zero).sceneLinear)
        #expect(try !SourceOptions(recipe: display).sceneLinear)
        #expect(try !SourceOptions(recipe: absent).sceneLinear)
        #expect(try !SourceOptions(recipe: active, options: RenderOptions(bypassedGroups: [.look])).sceneLinear)
    }

    @Test func logLookKeepsSceneMiddleGrayOnTheSLog3Code() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let fixture = root.appendingPathComponent("build/fixtures/sony-ilce-7s.ARW")
        guard FileManager.default.fileExists(atPath: fixture.path) else { throw FixtureError.missingRAW }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ARW")
        try FileManager.default.copyItem(at: fixture, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let look = LUTReference(contentHash: "sha256:" + String(repeating: "cd", count: 32), name: "Log")
        let active = Recipe(inputDomain: .rawEDR, look: look, values: [
            "look.input": .string("slog3-sgamut3cine"), "look.output": .string("rec709")])
        let idle = Recipe(inputDomain: .rawEDR)
        let preview = SourceResolution.preview(maximumSize: PixelSize(width: 320, height: 320))
        let engine = try RenderEngine()
        let scene = try await engine.load(temporary, options: try SourceOptions(recipe: active, resolution: preview))
        let apple = try await engine.load(temporary, options: try SourceOptions(recipe: idle, resolution: preview))
        let sceneSettings = try #require(scene.rawSettings)
        let appleSettings = try #require(apple.rawSettings)
        #expect(sceneSettings.boost == 0 && sceneSettings.boostShadow == 0)
        #expect(appleSettings.boost == 1 && appleSettings.boostShadow != 0)
        #expect(sceneSettings.baselineExposure == appleSettings.baselineExposure)
        let scenePixels = RenderEngine.readTexture(scene.texture)
        let applePixels = RenderEngine.readTexture(apple.texture)
        #expect(scenePixels.count == applePixels.count)
        var codes: [Double] = [], lifted: [Double] = []
        for index in stride(from: 0, to: scenePixels.count, by: 4) {
            for channel in 0..<3 {
                let linear = Double(scenePixels[index + channel])
                guard abs(linear - 0.18) <= 0.008 else { continue }
                codes.append(DoubleReference.encodeLUT(SIMD3(repeating: linear), space: .sLog3).x)
                lifted.append(Double(applePixels[index + channel]) / linear)
            }
        }
        #expect(codes.count > 30)
        let sortedCodes = codes.sorted(), sortedLift = lifted.sorted()
        let medianCode = sortedCodes[sortedCodes.count / 2]
        let medianLift = sortedLift[sortedLift.count / 2]
        #expect(abs(medianCode - 420.0 / 1023) < 10.0 / 1023)
        #expect(medianLift > 1.9 && medianLift < 2.4)
    }

    @Test func logLookKeepsAIOnTheAppleBoostPhotograph() async throws {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let fixture = root.appendingPathComponent("build/fixtures/sony-ilce-7s.ARW")
        guard FileManager.default.fileExists(atPath: fixture.path) else { throw FixtureError.missingRAW }
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".ARW")
        try FileManager.default.copyItem(at: fixture, to: temporary)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let preview = SourceResolution.preview(maximumSize: PixelSize(width: 128, height: 128))
        let appleOptions = SourceOptions(lensCorrection: false, resolution: preview)
        let linearOptions = SourceOptions(lensCorrection: false, resolution: preview, sceneLinear: true)
        let engine = try RenderEngine()
        let apple = try await engine.load(temporary, options: appleOptions)
        let linear = try await engine.load(temporary, options: linearOptions)
        #expect(apple.id != linear.id)
        #expect(linear.modelSourceID == apple.id && apple.modelSourceID == apple.id)
        #expect(try await RenderEngine().load(temporary, options: linearOptions).id == linear.id)

        let provider = try CoreMLModelGainProvider(computeUnits: .cpuOnly, analysisLongSide: 32)
        let fromLinear = try await engine.predictModelGain(linear, provider: provider)
        let fromApple = try await engine.predictModelGain(apple, provider: provider)
        #expect(fromLinear.sourceID == apple.id && fromLinear.gain === fromApple.gain)
        let exported = try await RenderEngine().predictModelGain(linear, provider: provider)
        let previewed = try await RenderEngine().predictModelGain(apple, provider: provider)
        #expect(exported.sourceID == previewed.sourceID)
        #expect(RenderEngine.readTexture(exported.gain) == RenderEngine.readTexture(previewed.gain))

        var edit = RenderAdjustments()
        edit.hdr.source = .capturedAI
        edit.hdr.modelGain = fromLinear
        edit.hdr.expansionStart = 0.5
        // Separate engines avoid the shared prediction key hiding a guide made
        // from the wrong development. Gating and smoothing must use Apple boost too.
        func filtered(_ engine: isolated RenderEngine, _ source: RenderSource, _ edit: RenderAdjustments) throws -> [Float] {
            let result = try engine.filteredModelGain(source, edit: edit)
            return RenderEngine.readTexture(try #require(result).gain)
        }
        let linearFilter = try await filtered(RenderEngine(), linear, edit)
        let appleFilter = try await filtered(RenderEngine(), apple, edit)
        let guideDifference = zip(linearFilter, appleFilter)
            .map { abs($0 - $1) }.max() ?? 0
        #expect(guideDifference < 0.00001)
        #expect(try await engine.render(linear, adjustments: edit).aiPending == false)
        #expect(try await engine.render(apple, adjustments: edit).aiPending == false)
    }

    @Test func threeChannelOffsetsReferenceAndCancellation() async throws {
        let base = SIMD3<Double>(0.1, 0.3, 0.6)
        let offset = SIMD3<Double>(repeating: 1 / 64)
        let result = DoubleReference.reconstruct(base, gain: SIMD3(1, 2, 3), baseOffset: offset, alternateOffset: offset)
        #expect(result == (base + offset) * SIMD3(2, 4, 8) - offset)
        #expect(DoubleReference.decodeGain(0.25, minimum: -1, maximum: 3, gamma: 2) == 1)
        let engine = try RenderEngine()
        let baseSource = try await engine.source(image: image([SIMD4(0.1, 0.3, 0.6, 1)], width: 1, height: 1), domain: .sdr)
        let gainSource = try await engine.source(image: image([SIMD4(0.2, 0.4, 0.6, 1)], width: 1, height: 1), domain: .sdr)
        var tags = ["HDRToneMap:BaseHeadroom": "0", "HDRToneMap:AlternateHeadroom": "3",
                    "HDRToneMap:BaseColorIsWorkingColor": "True"]
        for channel in 0..<3 {
            let prefix = "HDRToneMap:ChannelMetadata[\(channel)]."
            tags[prefix + "GainMapMin"] = "0"
            tags[prefix + "GainMapMax"] = "3"
            tags[prefix + "Gamma"] = "1"
            tags[prefix + "BaseOffset"] = "0.015625"
            tags[prefix + "AlternateOffset"] = "0.015625"
        }
        let gain = AuthoredGainMap(standard: .iso, auxiliaryInfo: tags as NSDictionary,
            image: gainSource.hdrImage, channelCount: 3, baseColorSpace: p3,
            alternateColorSpace: nil, auxiliaryColorSpace: nil, tags: tags)
        let pairSource = RenderSource(id: UUID(), renderID:UUID(), origin:nil, domain: .dual, size: baseSource.size, nativeSize: baseSource.nativeSize,
            authoredGainMap: gain, hdrImage: baseSource.hdrImage, authoredBaseImage: baseSource.hdrImage,
            rawSettings: nil, texture: baseSource.texture, baseSpace: p3, gainTexture: gainSource.texture)
        let carriedPair = try await engine.render(pairSource)
        #expect(carriedPair.gainChannelCount == 3)
        close(RenderEngine.readPixels(carriedPair).gain, [0.2, 0.4, 0.6])
        #expect(gain.isoChannels?.count == 3)
        #expect(gain.isoChannels?.first?.baseOffset == 1.0 / 64)
        let source = try await engine.source(image: image([SIMD4(2, 1, 0.5, 1)], width: 1, height: 1), domain: .hdr)
        let task = Task {
            try Task.checkCancellation()
            return try await engine.render(source)
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancellation ignored") } catch is CancellationError {}
    }
}

private final class Collector: @unchecked Sendable {
    var base: [Float] = []
    var gain: [Float] = []
    func append(_ planes: RenderPlanes) {
        let pixels = RenderEngine.readPixels(planes)
        base += pixels.baseRGBA
        gain += pixels.gain
    }
}

private enum FixtureError: Error { case missingRAW }
