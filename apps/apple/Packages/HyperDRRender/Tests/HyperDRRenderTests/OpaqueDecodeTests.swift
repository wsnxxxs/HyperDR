import Foundation
import CoreImage
import Metal
import Testing
@testable import HyperDRRender

private enum FixtureError: Error { case missingRAW }

private func licensedRAWs() throws -> [URL] {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { root.deleteLastPathComponent() }
    let names = ["sony-ilce-7s.ARW", "canon-eos-5d-iii-lossy.dng", "leica-c-portrait.RWL"]
    let urls = names.map { root.appendingPathComponent("build/fixtures/" + $0) }
    guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
        throw FixtureError.missingRAW // Run scripts/fetch_test_fixtures.py.
    }
    return urls
}

@Suite struct OpaqueDecodeTests {
    /// Core Image's RAW decoder has returned parts of cropped regions of the lossy DNG
    /// transparent, a different part each time. Previews and the analysis source are
    /// built from such crops; none may keep a hole.
    @Test func rawPreviewsAndAnalysisSourcesAreComplete() async throws {
        for url in try licensedRAWs() {
            for _ in 0..<3 {
                let engine = try RenderEngine()
                let full = try await engine.load(url)
                let preview = try await engine.load(url, options: SourceOptions(
                    resolution: .preview(maximumSize: PixelSize(width: 2560, height: 2560))))
                // At 64 pixels the DNG's failing crops are the same every time.
                let thumbnail = try await engine.load(url, options: SourceOptions(
                    resolution: .preview(maximumSize: PixelSize(width: 64, height: 64))))
                let analysis = try await engine.fixedAnalysisSource(full)
                for source in [full, preview, thumbnail, analysis] {
                    #expect(try await engine.transparentTexels(source.texture) == 0,
                            "\(url.lastPathComponent) \(source.size) has transparent texels")
                }
            }
        }
    }

    /// Split halves land where the whole render puts them, in both directions.
    @Test func splitHalvesMatchTheWholeRender() async throws {
        let ramp = CIFilter(name: "CISmoothLinearGradient", parameters: [
            "inputPoint0": CIVector(x: 3, y: 7), "inputPoint1": CIVector(x: 301, y: 149),
            "inputColor0": CIColor(red: 0.1, green: 0.7, blue: 0.2), "inputColor1": CIColor(red: 0.9, green: 0.2, blue: 0.6)])!.outputImage!
        let engine = try RenderEngine()
        for rect in [CGRect(x: 13, y: 21, width: 301, height: 97), CGRect(x: 5, y: 9, width: 77, height: 203)] {
            #expect(try await engine.halvesMatchWhole(ramp.cropped(to: rect)))
        }
    }

    /// A RAW region that stays incomplete fails to decode instead of reading as black.
    @Test func anIncompleteOpaqueRegionFailsToDecode() async throws {
        let engine = try RenderEngine()
        let image = CIImage(color: CIColor(red: 0.2, green: 0.3, blue: 0.4)).cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
            .composited(over: CIImage(color: .clear).cropped(to: CGRect(x: 0, y: 0, width: 16, height: 8)))
        #expect(try await engine.transparentTexels(rasterizing: image, opaque: false) == 64)
        await #expect(throws: RenderError.self) { try await engine.transparentTexels(rasterizing: image, opaque: true) }
        let whole = image.cropped(to: CGRect(x: 0, y: 0, width: 8, height: 8))
        #expect(try await engine.transparentTexels(rasterizing: whole, opaque: true) == 0)
    }
}

extension RenderEngine {
    fileprivate func halvesMatchWhole(_ image: CIImage) throws -> Bool {
        let whole = Self.readTexture(try rasterize(image, space: Self.workingColorSpace))
        let halves = Self.readTexture(try rasterizeHalves(image, space: Self.workingColorSpace, format: .rgba32Float, maximumRows: .max))
        return whole == halves
    }
    fileprivate func transparentTexels(rasterizing image: CIImage, opaque: Bool) throws -> Int {
        try transparentTexels(rasterize(image, space: Self.workingColorSpace, opaque: opaque))
    }
}
