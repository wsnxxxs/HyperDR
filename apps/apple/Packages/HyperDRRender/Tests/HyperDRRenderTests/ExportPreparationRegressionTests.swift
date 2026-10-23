import CoreImage
import Foundation
import HyperDRRecipe
import Metal
import Testing
@testable import HyperDRRender

private final class SDRExportEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var headers: [ExportRenderReport] = []
    private var bands: [ExportStripe] = []
    func prepare(_ report: ExportRenderReport) { lock.withLock { headers.append(report) } }
    func consume(_ stripe: ExportStripe) {
        lock.withLock {
            #expect(headers.count == 1)
            #expect(stripe.baseRGB.allSatisfy(\.isFinite) && stripe.gain.isEmpty)
            bands.append(stripe)
        }
    }
    var reports: [ExportRenderReport] { lock.withLock { headers } }
    var stripes: [ExportStripe] { lock.withLock { bands } }
}

@Suite(.serialized) struct ExportPreparationRegressionTests {
    private let capabilities = ExportPairCapabilities(supportsThreeChannelGain: true)

    private func image(_ pixels: [SIMD4<Float>], width: Int) -> CIImage {
        CIImage(bitmapData: pixels.withUnsafeBytes { Data($0) }, bytesPerRow: width * 16,
            size: CGSize(width: width, height: pixels.count / width), format: .RGBAf,
            colorSpace: RenderEngine.workingColorSpace)
    }

    @Test func SDRPreparationKeepsHeaderAndFlattensLaterTransparentBands() async throws {
        let engine = try RenderEngine()
        let size = PixelSize(width: 17, height: 600)
        let pixels = (0..<(size.width * size.height)).map { i in
            SIMD4<Float>(4, 2, 1, i / size.width < 300 ? 1 : 0.25)
        }
        let source = try await engine.source(image: image(pixels, width: size.width), domain: .hdr)
        let recipe = Recipe(inputDomain: .hdr)
        let referencePlanes = try await engine.render(source, recipe: recipe)
        let reference = RenderEngine.readPixels(referencePlanes)
        let events = SDRExportEvents()
        let report = try await engine.renderExportStripes(source, recipe: recipe,
            request: ExportRenderRequest(photoSize: size, ceilingStops: 1, includesGain: false, capabilities: capabilities), rows: 64,
            prepare: { events.prepare($0) }, consume: { events.consume($0) })
        #expect(events.reports.count == 1 && events.stripes.count == 10)
        #expect(report.gain == nil && report.resplitReasons.isEmpty)
        #expect(report.sourceProvenance == referencePlanes.provenance && report.provenance == report.sourceProvenance)
        #expect(report.ceilingApplied && report.rangeAfterCeiling == 1)
        #expect(report.resolvedAutomatic["hdr.range"] == 1)
        let expected = (0..<(size.width * size.height)).flatMap { i in
            let alpha = min(1, max(0, reference.baseRGBA[i * 4 + 3]))
            return (0..<3).map { reference.baseRGBA[i * 4 + $0] * alpha }
        }
        let actual = events.stripes.flatMap(\.baseRGB)
        #expect(actual.map(\.bitPattern) == expected.map(\.bitPattern))
    }

    @Test func SDRReadsRejectNonfiniteAlphaAfterPreparation() async throws {
        let engine = try RenderEngine()
        let size = PixelSize(width: 17, height: 600)
        let source = try await engine.source(image: image([SIMD4<Float>](repeating: SIMD4(0.2, 0.3, 0.4, 1),
            count: size.width * size.height), width: size.width), domain: .sdr)
        let recipe = Recipe(inputDomain: .sdr, values: ["hdr.enabled": .bool(false)])
        _ = try await engine.resolvedAutomatic(source, recipe: recipe)
        // A decoder/backend can supply a nonfinite alpha. Put it after the
        // preparation tile: it must fail its read before alpha flattening hides it.
        var invalid = SIMD4<Float>(0.2, 0.3, 0.4, .nan)
        withUnsafeBytes(of: &invalid) {
            source.texture.replace(region: MTLRegionMake2D(size.width - 1, size.height - 1, 1, 1),
                                   mipmapLevel: 0, withBytes: $0.baseAddress!, bytesPerRow: 16)
        }
        let events = SDRExportEvents()
        do {
            _ = try await engine.renderExportStripes(source, recipe: recipe,
                request: ExportRenderRequest(photoSize: size, includesGain: false, capabilities: capabilities), rows: 128,
                prepare: { events.prepare($0) }, consume: { events.consume($0) })
            Issue.record("SDR read accepted nonfinite source alpha")
        } catch RenderError.invalidAdjustment {}
        #expect(events.reports.count == 1)
        #expect(events.stripes.count == 4)
    }
}
