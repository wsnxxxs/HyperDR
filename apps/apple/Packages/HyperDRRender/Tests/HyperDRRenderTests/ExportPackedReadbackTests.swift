import CoreImage
import Foundation
import HyperDRRecipe
import Metal
import Testing
@testable import HyperDRRender

private extension RenderEngine {
    func packedFixture(channels: Int) throws -> DisplayGainPair {
        let command = queue.makeCommandBuffer()!
        let node = nodeContext(domain: .hdr, buffer: command)
        let width = 13, height = 5
        let base = try node.texture(width: width, height: height)
        let gain = try node.texture(width: width, height: height, format: channels == 3 ? .rgba32Float : .r32Float)
        let rgba = (0..<(width * height)).map { i in
            SIMD4<Float>(Float(i % 17) / 8 - 0.25, Float(i % 13) / 12,
                         Float(i % 9) / 4, Float(i % 5) / 4)
        }
        rgba.withUnsafeBytes { base.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: width * 16) }
        let gains = (0..<(width * height)).map { i in SIMD4<Float>(Float(i % 9) / 4 - 0.5, 1.25, 0.75, 0) }
        if channels == 3 {
            gains.withUnsafeBytes { gain.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: width * 16) }
        } else {
            let mono = gains.map(\.x)
            mono.withUnsafeBytes { gain.replace(region: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0,
                withBytes: $0.baseAddress!, bytesPerRow: width * 4) }
        }
        return DisplayGainPair(base: base, gain: gain, gainChannelCount: channels == 3 ? 3 : 1,
            baseOffset: SIMD3(repeating: 1 / 64), alternateOffset: SIMD3(repeating: 1 / 32),
            alternateHeadroom: 3, region: CGRect(x: 0, y: 0, width: width, height: height))
    }

    func packedReadback(_ pair: DisplayGainPair, channels: Int, flatten: Bool = false,
                        resplit: Bool = false) throws -> ExportPackedReadback {
        try exportPackedPair(pair, domain: .hdr, channels: channels, resplit: resplit,
            flatten: flatten, sdrOnly: channels == 0, ceiling: 2, shoulder: true,
            command: queue.makeCommandBuffer()!)
    }

    /// The existing texture destination is the bit oracle. Both kernels call
    /// the same pixel operator; this catches packing stride and sampling drift.
    func textureReadback(_ pair: DisplayGainPair, channels: Int, flatten: Bool,
                         resplit: Bool) throws -> (base: [Float], gain: [Float]) {
        let command = queue.makeCommandBuffer()!
        let node = nodeContext(domain: .hdr, buffer: command)
        let base = try node.texture(width: pair.base.width, height: pair.base.height)
        let gain = try node.texture(width: base.width, height: base.height, format: channels == 3 ? .rgba32Float : .r32Float)
        var p = ExportUniform(pair, resplit: resplit, flatten: flatten, sdrOnly: channels == 0, ceiling: 2, shoulder: true)
        try node.dispatch("exportPair", width: base.width, height: base.height,
            textures: [pair.base, pair.gain, base, gain], value: &p)
        try finish(command)
        return (Self.readRGB(base), channels == 0 ? [] : channels == 1 ? Self.readTexture(gain) : Self.readRGB(gain))
    }
}

private final class PackedStripeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stripes: [ExportStripe] = []
    func append(_ value: ExportStripe) { lock.withLock { stripes.append(value) } }
    var base: [Float] { lock.withLock { stripes.flatMap(\.baseRGB) } }
    var gain: [Float] { lock.withLock { stripes.flatMap(\.gain) } }
}

@Suite(.serialized) struct ExportPackedReadbackTests {
    @Test(arguments: [0, 1, 3], [false, true])
    func packedValuesMatchTextureBits(channels: Int, resplit: Bool) async throws {
        let engine = try RenderEngine()
        let pair = try await engine.packedFixture(channels: channels)
        for flatten in [false, true] {
            let expected = try await engine.textureReadback(pair, channels: channels, flatten: flatten, resplit: resplit)
            var packed = try await engine.packedReadback(pair, channels: channels, flatten: flatten, resplit: resplit)
            let actual = packed.read()
            #expect(actual.base.map(\.bitPattern) == expected.base.map(\.bitPattern))
            #expect(actual.gain.map(\.bitPattern) == expected.gain.map(\.bitPattern))
        }
    }

    @Test func packedBasePreservesSignedZeroSubnormalsAndLargeFiniteValues() async throws {
        let engine = try RenderEngine()
        let pair = try await engine.packedFixture(channels: 3)
        let values: [Float] = [0, -0.0, Float(bitPattern: 1), Float(bitPattern: 0x007fffff),
                               -Float(bitPattern: 1), .greatestFiniteMagnitude, -.greatestFiniteMagnitude]
        let rgba = (0..<(pair.base.width * pair.base.height)).map { i in
            SIMD4(values[i % values.count], values[(i + 1) % values.count], values[(i + 2) % values.count], 1)
        }
        rgba.withUnsafeBytes { pair.base.replace(region: MTLRegionMake2D(0, 0, pair.base.width, pair.base.height),
            mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: pair.base.width * 16) }
        let expected = try await engine.textureReadback(pair, channels: 3, flatten: false, resplit: false)
        var packed = try await engine.packedReadback(pair, channels: 3)
        let actual = packed.read()
        #expect(actual.base.map(\.bitPattern) == expected.base.map(\.bitPattern))
    }

    @Test(arguments: [Float.nan, .infinity, -.infinity])
    func sdrPackingRejectsNonfiniteAlphaBeforeFlattening(alpha: Float) async throws {
        let engine = try RenderEngine()
        let pair = try await engine.packedFixture(channels: 1)
        let value = [SIMD4<Float>(0.2, 0.3, 0.4, alpha)]
        value.withUnsafeBytes { pair.base.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: 16) }
        do {
            _ = try await engine.packedReadback(pair, channels: 0, flatten: true)
            Issue.record("SDR packing accepted a nonfinite alpha")
        } catch {
            guard case RenderError.invalidAdjustment = error else { throw error }
        }
    }

    @Test func sdrPackingRejectsOverflowingAffineHDR() async throws {
        let engine = try RenderEngine()
        let pair = try await engine.packedFixture(channels: 1)
        let gain: [Float] = [200]
        gain.withUnsafeBytes { pair.gain.replace(region: MTLRegionMake2D(0, 0, 1, 1), mipmapLevel: 0,
            withBytes: $0.baseAddress!, bytesPerRow: 4) }
        do {
            _ = try await engine.packedReadback(pair, channels: 0, flatten: true)
            Issue.record("SDR packing accepted an overflowing HDR reconstruction")
        } catch {
            guard case RenderError.invalidAdjustment = error else { throw error }
        }
    }

    @Test func packedArraysRemainOwnedAfterTheNextRead() async throws {
        let engine = try RenderEngine()
        let pair = try await engine.packedFixture(channels: 3)
        var first = try await engine.packedReadback(pair, channels: 3)
        let saved = first.read()
        let bits = saved.base.map(\.bitPattern) + saved.gain.map(\.bitPattern)
        for _ in 0..<4 {
            var next = try await engine.packedReadback(pair, channels: 3)
            let replay = next.read()
            #expect(replay.base.map(\.bitPattern) + replay.gain.map(\.bitPattern) == bits)
        }
        #expect(saved.base.map(\.bitPattern) + saved.gain.map(\.bitPattern) == bits)
    }

    @Test(arguments: [false, true])
    func framedAndUnframedRowsReplayExactly(framed: Bool) async throws {
        let engine = try RenderEngine()
        let image = CIImage(color: CIColor(red: 2, green: 1, blue: 0.25))
            .cropped(to: CGRect(x: 0, y: 0, width: 2, height: 2))
        let source = try await engine.source(image: image, domain: .hdr)
        let frame = framed ? FrameSnapshot(canvasSize: PixelSize(width: 6, height: 6),
            photo: ExportRect(x: 2, y: 2, width: 2, height: 2), paper: SIMD3(repeating: 0.7)) : nil
        let request = ExportRenderRequest(photoSize: source.size,
            capabilities: ExportPairCapabilities(supportsThreeChannelGain: true), frame: frame)
        let first = PackedStripeCollector(), replay = PackedStripeCollector()
        _ = try await engine.renderExportStripes(source, recipe: Recipe(inputDomain: .hdr), request: request, rows: 1,
            prepare: { _ in }, consume: { first.append($0) })
        _ = try await engine.renderExportStripes(source, recipe: Recipe(inputDomain: .hdr), request: request, rows: 4,
            prepare: { _ in }, consume: { replay.append($0) })
        #expect(first.base.map(\.bitPattern) == replay.base.map(\.bitPattern))
        #expect(first.gain.map(\.bitPattern) == replay.gain.map(\.bitPattern))
        if framed {
            for y in 0..<6 { for x in 0..<6 where !(2..<4).contains(x) || !(2..<4).contains(y) {
                #expect(first.gain[y * 6 + x] == 0)
            } }
        }
    }
}
