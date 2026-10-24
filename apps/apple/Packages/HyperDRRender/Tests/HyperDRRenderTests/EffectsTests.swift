import CoreImage
import Foundation
import Metal
import HyperDRRecipe
import Testing
@testable import HyperDRRender

@Suite(.serialized) struct EffectsTests {
    private func image(width: Int = 96, height: Int = 96, peak: Float = 8) -> CIImage {
        var pixels = [SIMD4<Float>](repeating: SIMD4(0.18, 0.18, 0.18, 1), count: width * height)
        for y in (height / 2)..<min(height, height / 2 + 8) {
            for x in (width / 2)..<min(width, width / 2 + 8) { pixels[y * width + x] = SIMD4(peak, peak, peak, 1) }
        }
        return CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
                       size: CGSize(width: width, height: height), format: .RGBAf, colorSpace: RenderEngine.workingColorSpace)
    }

    @Test(arguments: [false, true])
    func infinitesimalGrainKeepsGeneratedHDREndpointsContinuous(model: Bool) async throws {
        let device = try #require(MTLCreateSystemDefaultDevice()), engine = try RenderEngine(device: device)
        let level: Float = model ? 0.2 : 0.7
        let values = [SIMD4<Float>](repeating: SIMD4(level, level, level, 1), count: 64 * 64)
        let photo = CIImage(bitmapData: values.withUnsafeBytes { Data($0) }, bytesPerRow: 64 * 16,
            size: CGSize(width: 64, height: 64), format: .RGBAf, colorSpace: RenderEngine.workingColorSpace)
        let source = try await engine.source(image: photo, domain: .sdr)
        var edit = RenderAdjustments(); edit.hdr.range = 4
        if model {
            edit.hdr.source = .ai
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r32Float, width: 1, height: 1, mipmapped: false)
            descriptor.storageMode = .shared; descriptor.usage = .shaderRead
            let gain = try #require(device.makeTexture(descriptor: descriptor))
            var two: Float = 2
            gain.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0, withBytes: &two, bytesPerRow: 4)
            edit.hdr.modelGain = ModelGainPrediction(sourceID: source.id, modelID: "effects-continuity", gain: gain)
        } else { edit.hdr.expansionStart = 0.18; edit.hdr.coverage = 1 }
        for strength: Float in [0.5, 1, 1.5] {
            edit.hdr.strength = strength; edit.effects.grain = 0
            let original = effectHDR(try await engine.render(source, adjustments: edit))
            #expect(original.max()! > level + 0.001)
            if model && strength == 1 { #expect(abs(original[0] - 0.8) < 1e-5) }
            for amount: Float in [1e-7, 1e-5] {
                edit.effects.grain = amount
                let actual = effectHDR(try await engine.render(source, adjustments: edit))
                let worst = zip(original, actual).reduce(Float(0)) { max($0, abs($1.0-$1.1)) }
                // Enabling the offset-aware pair adds log/exp roundtrips.
                // Around 12x HDR white, even 11 float32 ULPs exceed 1e-5.
                // Retain the absolute floor and bound HDR roundoff per value.
                let continuous = zip(original, actual).allSatisfy { a, b in
                    a.isFinite && b.isFinite && abs(a-b) <= max(1e-5, 16*max(a.ulp, b.ulp))
                }
                #expect(continuous, "model \(model) strength \(strength) grain \(amount): \(original[0]) -> \(actual[0]), max \(worst)")
            }
        }
    }

    @Test func tinyGrainDoesNotCompressLegalHDRWhite() async throws {
        let engine = try RenderEngine()
        let source = try await engine.source(image: image(peak: 4), domain: .hdr)
        var edit = RenderAdjustments(); edit.hdr.range = 2
        let original = effectHDR(try await engine.render(source, adjustments: edit))
        edit.effects.grain = 0.01
        let actual = effectHDR(try await engine.render(source, adjustments: edit))
        let white = original.indices.filter { original[$0] > 3.999 }
        #expect(!white.isEmpty)
        #expect(white.allSatisfy { abs(actual[$0]-original[$0]) < 2e-6 })
    }

    @Test(arguments: [false, true], [InputDomain.sdr, .hdr])
    func selectedStockEffectDeltaDoesNotFadeWithColourStrength(halation: Bool, domain: InputDomain) async throws {
        let engine = try RenderEngine()
        let source = try await engine.source(image: image(peak: domain == .sdr ? 0.8 : 3), domain: domain)
        let size = PixelSize(width: 4000, height: 4000)
        let region = CGRect(x: 1950, y: 1950, width: 100, height: 100)
        var edit = RenderAdjustments()
        edit.film.stock = .portra400; edit.film.exposure = 0; edit.film.antihalation = false
        edit.hdr.enabled = domain != .sdr; edit.hdr.range = 4
        let noPhysics = try await engine.render(source, adjustments: edit, size: size, region: region)
        let s0 = RenderEngine.readPixels(noPhysics), h0 = effectHDR(noPhysics)
        if halation { edit.effects.halation = 1 } else { edit.effects.grain = 1 }
        let withPhysics = try await engine.render(source, adjustments: edit, size: size, region: region)
        let s1 = RenderEngine.readPixels(withPhysics), h1 = effectHDR(withPhysics)
        #expect(zip(s0.baseRGBA, s1.baseRGBA).contains { abs($0-$1) > 1e-5 })
        for strength: Float in [0, 0.00001, 0.01, 0.99999, 1] {
            edit.film.strength = strength
            let actualPlanes = try await engine.render(source, adjustments: edit, size: size, region: region)
            let actual = RenderEngine.readPixels(actualPlanes), actualHDR = effectHDR(actualPlanes)
            var neutral = edit; neutral.effects = EffectAdjustments()
            let colourPlanes = try await engine.render(source, adjustments: neutral, size: size, region: region)
            let colour = RenderEngine.readPixels(colourPlanes), colourHDR = effectHDR(colourPlanes)
            var checked = 0, worst: Float = 0
            for i in 0..<(s0.baseRGBA.count/4) {
                let expected = (0..<3).map { c in colour.baseRGBA[i*4+c]+s1.baseRGBA[i*4+c]-s0.baseRGBA[i*4+c] }
                guard expected.allSatisfy({ $0 > 0.02 && $0 < 0.95 }) else { continue }
                for c in 0..<3 {
                    let expectedHDR = colourHDR[i*3+c]+h1[i*3+c]-h0[i*3+c]
                    guard expectedHDR > 0.01 else { continue }
                    checked += 1
                    worst = max(worst, abs(actual.baseRGBA[i*4+c]-expected[c]), abs(actualHDR[i*3+c]-expectedHDR))
                }
            }
            #expect(checked > 100)
            #expect(worst < 8e-6, "stock delta at strength \(strength), halation \(halation), domain \(domain): \(worst)")
            if strength == 1 { #expect(actual.baseRGBA == s1.baseRGBA && actual.gain == s1.gain) }
        }
    }

    @Test func declarationsAreIndependentAndOldIDsAreIgnored() throws {
        #expect(Array(Adjustments.parameters(in: .color).suffix(2).map(\.id)) == Adjustments.effectIDs)
        #expect(ParameterGroup.displayOrder == [.hdr, .light, .color, .look, .detail, .local])
        for domain in InputDomain.allCases {
            var recipe = Recipe(inputDomain: domain)
            #expect(try RenderAdjustments(recipe: recipe).effects.isIdentity)
            for id in Adjustments.effectIDs {
                let declaration = try #require(Adjustments.declaration(id))
                #expect(Adjustments.isVisible(declaration, in: recipe))
                #expect(declaration.group == .color && declaration.range == 0...200)
                recipe.setValue(.number(100), for: id)
            }
            let edit = try RenderAdjustments(recipe: recipe)
            #expect(edit.effects.grain == 1 && edit.effects.halation == 1)
            #expect(try RenderAdjustments(recipe: recipe, options: RenderOptions(bypassedGroups: [.color])).effects.isIdentity)
            #expect(!recipe.needsLookBaseline)
            recipe.setValue(.number(200), for: "look.filmGrain")
            recipe.setValue(.number(200), for: "look.filmHalation")
            #expect(try RenderAdjustments(recipe: recipe).effects == edit.effects)
        }
    }

    @Test(arguments: [false, true]) func effectsWithoutALookAndWithAnIdentityLUT(halation: Bool) async throws {
        let engine = try RenderEngine()
        let source = try await engine.source(image: image(), domain: .hdr)
        var edit = RenderAdjustments()
        edit.hdr.range = 4
        let original = RenderEngine.readPixels(try await engine.render(source, adjustments: edit))
        // Explicit zero follows the same path and preserves the previous pixels.
        edit.effects.grain = 0; edit.effects.halation = 0
        let zero = RenderEngine.readPixels(try await engine.render(source, adjustments: edit))
        #expect(original.baseRGBA == zero.baseRGBA && original.gain == zero.gain)
        if halation { edit.effects.halation = 1 } else { edit.effects.grain = 1 }
        let effected = try await engine.render(source, adjustments: edit)
        guard case let .pairedLog2(offset, _) = effected.encoding else {
            Issue.record("Independent endpoints require equal-offset RGB gain"); return
        }
        #expect(offset == 0.015625)
        let plain = RenderEngine.readPixels(effected)
        #expect(zip(plain.baseRGBA, original.baseRGBA).contains { abs($0-$1) > 1e-5 })
        #expect(plain.gainChannelCount == 3 && plain.gain.allSatisfy(\.isFinite))
        let identity = try ColorLUT(cube: "LUT_1D_SIZE 2\n0 0 0\n1 1 1\n")
        edit.look.lut = identity
        edit.look.input = .displayP3; edit.look.output = .displayP3
        for strength: Float in [0, 0.25, 1] {
            edit.look.strength = strength
            let actual = RenderEngine.readPixels(try await engine.render(source, adjustments: edit))
            #expect(zip(actual.baseRGBA, plain.baseRGBA).allSatisfy { abs($0-$1) < 2e-6 })
            #expect(zip(actual.gain, plain.gain).allSatisfy { abs($0-$1) < 2e-5 })
        }
    }

    @Test func aColourLUTCannotRecolourOrFadeTheGlow() async throws {
        let engine = try RenderEngine()
        let source = try await engine.source(image: image(peak: 1), domain: .sdr)
        let lut = try ColorLUT(cube: "LUT_1D_SIZE 2\n0.3 0.5 0.6\n0.3 0.5 0.6\n")
        var edit = RenderAdjustments(); edit.hdr.enabled = false
        edit.look.lut = lut; edit.look.input = .displayP3; edit.look.output = .displayP3
        var reference: [Float]?
        for strength: Float in [0, 0.25, 1] {
            edit.look.strength = strength; edit.effects.halation = 0
            let plain = RenderEngine.readPixels(try await engine.render(source, adjustments: edit))
            edit.effects.halation = 1
            let glow = RenderEngine.readPixels(try await engine.render(source, adjustments: edit))
            var delta: [Float] = []
            // The central patch can clip at white. Compare the surrounding mat of
            // midtones, where the output-stage additive glow has no clipping.
            for i in 0..<(96*96) where plain.baseRGBA[i*4] < 0.9 {
                for c in 0..<3 { delta.append(glow.baseRGBA[i*4+c]-plain.baseRGBA[i*4+c]) }
            }
            // Restrict to a fixed top half, away from the patch in either CI orientation.
            let edgeDelta = (0..<96).flatMap { x in (0..<3).map { c in
                glow.baseRGBA[(39*96+x)*4+c]-plain.baseRGBA[(39*96+x)*4+c]
            } }
            if let reference { #expect(zip(edgeDelta, reference).allSatisfy { abs($0-$1) < 2e-6 }) }
            else { reference = edgeDelta }
            #expect(delta.contains { $0 > 1e-6 })
        }
    }

    @Test func hdrHighlightsDriveTheGlow() async throws {
        let engine = try RenderEngine()
        let low = try await engine.source(image: image(peak: 1), domain: .hdr)
        let high = try await engine.source(image: image(peak: 12), domain: .hdr)
        var edit = RenderAdjustments(); edit.effects.halation = 1
        let lowAnalysis = try await engine.analysis(low, adjustments: edit)
        let highAnalysis = try await engine.analysis(high, adjustments: edit)
        let lowMap = RenderEngine.readTexture(try #require(lowAnalysis.filmHalation))
        let highMap = RenderEngine.readTexture(try #require(highAnalysis.filmHalation))
        #expect(highMap.reduce(0,+) > 20 * lowMap.reduce(0,+))
    }

    @Test func grainKeepsAnalysisAndRolloffKeepsTheHDREndpoint() async throws {
        let engine = try RenderEngine()
        let source = try await engine.source(image: image(peak: 2), domain: .hdr)
        var edit = RenderAdjustments(); edit.effects.halation = 1; edit.hdr.range = 4
        let analysis = try await engine.analysis(source, adjustments: edit)
        edit.effects.grain = 1
        let reused = try await engine.analysis(source, adjustments: edit)
        #expect(analysis.cells === reused.cells && analysis.expansion === reused.expansion)
        let original = RenderEngine.readPixels(try await engine.render(source, adjustments: edit))
        edit.hdr.sdrRolloff = 1
        let rolled = RenderEngine.readPixels(try await engine.render(source, adjustments: edit))
        #expect(zip(original.baseRGBA, rolled.baseRGBA).contains { abs($0-$1) > 1e-5 })
        for i in 0..<(96*96) { for c in 0..<3 {
            let before = (original.baseRGBA[i*4+c]+0.015625)*exp2(original.gain[i*3+c])-0.015625
            let after = (rolled.baseRGBA[i*4+c]+0.015625)*exp2(rolled.gain[i*3+c])-0.015625
            #expect(abs(before-after) < 1e-5)
        } }
    }

    @Test func globalGrainAndGlowAgreeAcrossROIAndBands() async throws {
        let engine = try RenderEngine()
        let source = try await engine.source(image: image(width: 48, height: 560), domain: .hdr)
        var edit = RenderAdjustments(); edit.effects.grain = 1; edit.effects.halation = 1; edit.hdr.range = 4
        let size = PixelSize(width: 96, height: 1120)
        let banded = RenderEngine.readPixels(try await engine.render(source, adjustments: edit, size: size))
        let analysis = try await engine.analysis(source, adjustments: edit)
        let whole = RenderEngine.readPixels(try await engine.graphRegion(source, edit: edit, size: size,
            region: CGRect(x: 0, y: 0, width: size.width, height: size.height), analysis: analysis))
        #expect(banded.baseRGBA == whole.baseRGBA && banded.gain == whole.gain)
        let stripes = EffectStripeCollector()
        try await engine.renderStripes(source, adjustments: edit, size: size, rows: 73) { stripes.append($0) }
        #expect(stripes.base == whole.baseRGBA && stripes.gain == whole.gain)
        let roi = CGRect(x: 40, y: 550, width: 24, height: 24)
        let cropped = RenderEngine.readPixels(try await engine.render(source, adjustments: edit, size: size, region: roi))
        for y in 0..<24 { for x in 0..<24 {
            let small = y * 24 + x, large = (y + 550) * size.width + x + 40
            for c in 0..<3 {
                #expect(cropped.baseRGBA[small*4+c] == whole.baseRGBA[large*4+c])
                #expect(cropped.gain[small*3+c] == whole.gain[large*3+c])
            }
        } }
    }
}

private final class EffectStripeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var base: [Float] = [], gain: [Float] = []
    func append(_ planes: RenderPlanes) {
        let pixels = RenderEngine.readPixels(planes)
        lock.lock(); defer { lock.unlock() }
        base += pixels.baseRGBA; gain += pixels.gain
    }
}

private func effectHDR(_ planes: RenderPlanes) -> [Float] {
    let pixels = RenderEngine.readPixels(planes)
    let offset: Float
    if case let .pairedLog2(value, _) = planes.encoding { offset = value } else { offset = 0 }
    return (0..<(pixels.baseRGBA.count/4)).flatMap { i in (0..<3).map { c in
        (pixels.baseRGBA[i*4+c]+offset)*exp2(pixels.gain[i*pixels.gainChannelCount+(pixels.gainChannelCount == 1 ? 0 : c)])-offset
    } }
}
