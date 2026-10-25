import CoreImage
import Foundation
import Metal
import simd
import Testing
import HyperDRRecipe
@testable import HyperDRRender

@Suite(.serialized) struct HDRInputTests {
    @available(macOS 26, iOS 26, *)
    private func image(_ rgb: SIMD3<Float>) -> CIImage {
        let pixels = [SIMD4(rgb, 1)]
        return CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: 16,
            size: CGSize(width: 1, height: 1), format: .RGBAf, colorSpace: RenderEngine.workingColorSpace)
    }

    @available(macOS 26, iOS 26, *)
    private func authored(_ engine: RenderEngine, rgb: SIMD3<Float> = SIMD3(0.3, 0.2, 0.1),
                          offset: Float = 0, systemScale: Float = 1) async throws -> RenderSource {
        let base = image(rgb), hdr = image(((rgb + offset) * 4 - offset) * systemScale)
        let baseSource = try await engine.source(image: base, domain: .sdr)
        let gainSource = try await engine.source(image: image(SIMD3(repeating: 1)), domain: .sdr)
        let tags = ["HDRToneMap:BaseHeadroom": "0", "HDRToneMap:AlternateHeadroom": "2",
            "HDRToneMap:ChannelMetadata[0].GainMapMin": "0", "HDRToneMap:ChannelMetadata[0].GainMapMax": "2",
            "HDRToneMap:ChannelMetadata[0].Gamma": "1",
            "HDRToneMap:ChannelMetadata[0].BaseOffset": String(offset), "HDRToneMap:ChannelMetadata[0].AlternateOffset": String(offset),
            "HDRToneMap:BaseColorIsWorkingColor": "True"]
        let metadata = AuthoredGainMap(standard: .iso, auxiliaryInfo: tags as NSDictionary,
            image: gainSource.hdrImage, channelCount: 1, baseColorSpace: RenderEngine.workingColorSpace,
            alternateColorSpace: nil, auxiliaryColorSpace: nil, tags: tags)
        _ = try #require(metadata.isoChannels)
        return RenderSource(id: UUID(), renderID: UUID(), origin: nil, domain: .dual,
            size: baseSource.size, nativeSize: baseSource.size, authoredGainMap: metadata,
            hdrImage: hdr.settingContentHeadroom(4), authoredBaseImage: base, rawSettings: nil,
            texture: baseSource.texture, baseSpace: RenderEngine.workingColorSpace, gainTexture: gainSource.texture)
    }

    @available(macOS 26, iOS 26, *)
    @Test func independentEffectsKeepTheAuthoredSDREndpoint() async throws {
        let engine = try RenderEngine(), source = try await authored(engine, offset: 1/64)
        let size = PixelSize(width: 2000, height: 2), region = CGRect(x: 100, y: 0, width: 64, height: 2)
        for halation in [false, true] {
            var edit = RenderAdjustments()
            edit.hdr.range = 4
            if halation { edit.effects.halation = 1 } else { edit.effects.grain = 1 }
            let full = try await engine.render(source, adjustments: edit, size: size, region: region)
            let hdr = RenderEngine.readPixels(full)
            #expect(hdr.gainChannelCount == 3 && hdr.gain.allSatisfy(\.isFinite))
            guard case let .pairedLog2(offset, _) = full.encoding else {
                Issue.record("Effects must retain equal-offset RGB endpoint gain"); continue
            }
            #expect(offset == 0.015625)
            edit.hdr.enabled = false
            let sdr = RenderEngine.readPixels(try await engine.render(source, adjustments: edit, size: size, region: region))
            #expect(sdr.baseRGBA == hdr.baseRGBA && sdr.gain.allSatisfy { $0 == 0 })
            edit.hdr.enabled = true; edit.hdr.strength = 0.3
            let partial = RenderEngine.readPixels(try await engine.render(source, adjustments: edit, size: size, region: region))
            #expect(partial.baseRGBA == hdr.baseRGBA)
            for i in hdr.gain.indices { #expect(abs(partial.gain[i] - 0.3 * hdr.gain[i]) < 1e-6) }
        }
    }

    @available(macOS 26, iOS 26, *)
    private func pixels(_ pair: DisplayGainPair, weight: Float) -> [Float] {
        let base = RenderEngine.readTexture(pair.base), gain = RenderEngine.readTexture(pair.gain)
        return stride(from: 0, to: base.count, by: 4).flatMap { i -> [Float] in
            let b = SIMD3(base[i], base[i+1], base[i+2])
            let x = Float(i/4 % pair.base.width), y = Float(i/4 / pair.base.width)
            let gx = max(0, min(Float(pair.gain.width-1), (x+0.5)*Float(pair.gain.width)/Float(pair.base.width)-0.5))
            let gy = max(0, min(Float(pair.gain.height-1), (y+0.5)*Float(pair.gain.height)/Float(pair.base.height)-0.5))
            let x0 = Int(gx), y0 = Int(gy), x1 = min(x0+1, pair.gain.width-1), y1 = min(y0+1, pair.gain.height-1)
            let tx = gx-Float(x0), ty = gy-Float(y0)
            func read(_ x: Int, _ y: Int) -> SIMD3<Float> {
                let stride = pair.gain.pixelFormat == .r32Float ? 1 : 4
                let j = (y*pair.gain.width+x)*stride
                return pair.gainChannelCount == 1 ? SIMD3(repeating: gain[j]) : SIMD3(gain[j], gain[j+1], gain[j+2])
            }
            let top = read(x0,y0)*(1-tx)+read(x1,y0)*tx
            let bottom = read(x0,y1)*(1-tx)+read(x1,y1)*tx
            let g = top*(1-ty)+bottom*ty
            let scale = SIMD3(exp2(g.x * weight), exp2(g.y * weight), exp2(g.z * weight))
            let rgb = pair.gainToP3 * ((pair.p3ToGain * b + pair.baseOffset) * scale - pair.alternateOffset)
            return [rgb.x, rgb.y, rgb.z]
        }
    }

    @available(macOS 26, iOS 26, *)
    @Test func tinyExposureDoesNotReplaceAuthoredSDRBase() async throws {
        let engine = try RenderEngine(), source = try await authored(engine)
        let original = try await engine.displayPair(engine.render(source, adjustments: .init()), source: source)
        var edit = RenderAdjustments(); edit.tone.exposure = 0.0001
        let changed = try await engine.displayPair(engine.render(source, adjustments: edit), source: source)
        let before = RenderEngine.readTexture(original.base), after = RenderEngine.readTexture(changed.base)
        #expect(zip(before, after).allSatisfy { abs($0 - $1) < 0.001 })
    }

    @Test(arguments: ["tone.exposure", "tone.contrast", "tone.highlights", "tone.shadows", "tone.blacks",
                      "color.warmth", "color.tint", "color.vibrance", "color.saturation"])
    @available(macOS 26, iOS 26, *)
    func allSmallEditsKeepBothEndpoints(parameter: String) async throws {
        let engine = try RenderEngine(), source = try await authored(engine)
        let original = try await engine.displayPair(engine.render(source, adjustments: .init()), source: source)
        for sign in [-1.0, 1.0] {
            var recipe = Recipe(inputDomain: .dual)
            recipe.setValue(.number(sign * 0.0001), for: parameter)
            let pair = try await engine.displayPair(engine.render(source, recipe: recipe), source: source)
            for weight: Float in [0, 0.5, 1] {
                #expect(zip(pixels(original, weight: weight), pixels(pair, weight: weight)).allSatisfy { abs($0 - $1) < 0.001 })
            }
            #expect(pair.alternateHeadroom == original.alternateHeadroom)
        }
    }

    @available(macOS 26, iOS 26, *)
    @Test func exposureScalesHDRAndNegativeExposureScalesSDR() async throws {
        let engine = try RenderEngine(), source = try await authored(engine)
        let original = try await engine.displayPair(engine.render(source, adjustments: .init()), source: source)
        for ev: Float in [-2, -1, 1, 2] {
            var edit = RenderAdjustments(); edit.tone.exposure = ev
            let pair = try await engine.displayPair(engine.render(source, adjustments: edit), source: source)
            #expect(zip(pixels(original, weight: 1), pixels(pair, weight: 1)).allSatisfy { abs($0 * exp2(ev) - $1) < 0.0001 })
            if ev < 0 {
                #expect(zip(pixels(original, weight: 0), pixels(pair, weight: 0)).allSatisfy { abs($0 * exp2(ev) - $1) < 0.0001 })
            }
            edit.hdr.enabled = false
            let disabled = try await engine.displayPair(engine.render(source, adjustments: edit), source: source)
            #expect(pixels(pair, weight: 0) == pixels(disabled, weight: 0))
            #expect(zip(pixels(disabled, weight: 0), pixels(disabled, weight: 1)).allSatisfy { abs($0 - $1) < 0.00001 })
        }
    }

    @available(macOS 26, iOS 26, *)
    @Test func ISOEditingDoesNotSwitchToTheSystemHDRRendition() async throws {
        let engine = try RenderEngine()
        let source = try await authored(engine, systemScale: 0.25)
        var edit = RenderAdjustments(); edit.tone.exposure = 0.5
        let pair = try await engine.displayPair(engine.render(source, adjustments: edit), source: source)
        let expected: [Float] = [1.2, 0.8, 0.4].map { $0 * exp2(0.5) }
        #expect(zip(expected, pixels(pair, weight: 1)).allSatisfy { abs($0 - $1) < 0.00001 })
    }

    @available(macOS 26, iOS 26, *)
    @Test func offsetsPreserveHDRWhenTheSDRChannelIsBlack() async throws {
        let engine = try RenderEngine(), source = try await authored(engine, rgb: .zero, offset: 1/64)
        var edit = RenderAdjustments(); edit.tone.exposure = -1
        let pair = try await engine.displayPair(engine.render(source, adjustments: edit), source: source)
        #expect(RenderEngine.readTexture(pair.gain).allSatisfy { $0.isFinite })
        #expect(pixels(pair, weight: 0).allSatisfy { abs($0) < 0.000001 })
        #expect(pixels(pair, weight: 1).allSatisfy { abs($0 - 3/128) < 0.000001 })
    }

    @available(macOS 26, iOS 26, *)
    @Test(arguments: [false, true]) func partialLooksMixTheAuthoredEndpoints(film: Bool) async throws {
        let engine = try RenderEngine(), source = try await authored(engine)
        var edit = RenderAdjustments()
        if film {
            edit.film.stock = .portra400; edit.effects.grain = 0; edit.effects.halation = 0
        } else {
            edit.look.lut = try ColorLUT(cube: "LUT_1D_SIZE 2\n0 0 0\n0.8 0.7 0.6\n")
            edit.look.input = .displayP3; edit.look.output = .displayP3
        }
        func at(_ strength: Float) async throws -> DisplayGainPair {
            var settings = edit
            if film { settings.film.strength = strength } else { settings.look.strength = strength }
            return try await engine.displayPair(engine.render(source, adjustments: settings), source: source)
        }
        let neutral = try await at(0), full = try await at(1), half = try await at(0.5)
        for weight: Float in [0, 1] {
            let expected = zip(pixels(neutral, weight: weight), pixels(full, weight: weight)).map { ($0 + $1) / 2 }
            #expect(zip(expected, pixels(half, weight: weight)).allSatisfy { abs($0 - $1) < 0.0001 })
        }
    }

    @available(macOS 26, iOS 26, *)
    @Test func localHDRSamplesExposureProbe() async throws {
        guard ProcessInfo.processInfo.environment["HYPERDR_HDR_PROBE"] == "1" else { return }
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        for name in ["IMG_3891.HEIC", "IMG_20261007_113127_1791482308927edit.jpg", "DSC01422.HIF"] {
            let engine = try RenderEngine()
            let source = try await engine.load(root.appendingPathComponent("测试照片/" + name),
                options: SourceOptions(resolution: .preview(maximumSize: PixelSize(width: 256, height: 256))))
            var original: DisplayGainPair?
            for ev: Float in [0, 0.0001, -1, 1] {
                var edit = RenderAdjustments(); edit.tone.exposure = ev
                let pair = try await engine.displayPair(engine.render(source, adjustments: edit), source: source)
                if ev == 0 { original = pair }
                if ev == 0.0001, let original {
                    for weight: Float in [0, 0.5, 1] {
                        let errors = zip(pixels(original, weight: weight), pixels(pair, weight: weight)).map { abs($0 - $1) }
                        #expect((errors.max() ?? 0) < 0.001)
                    }
                }
            }
        }
    }
}
