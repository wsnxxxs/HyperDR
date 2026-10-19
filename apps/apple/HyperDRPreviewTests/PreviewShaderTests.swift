import Foundation
import HyperDREngine
import Metal
import QuartzCore
import XCTest
@testable import HyperDR

private struct SampleHDRReference: Decodable {
    struct Case: Decodable {
        let compact: Bool
        let original: Bool
        let weight: Float
        let values: [Float]
    }
    let width: Int
    let height: Int
    let cases: [Case]
}

/// The JPEG bundled with the tests. Not a repository path: the sandboxed app
/// cannot read one, and a missing file must fail rather than skip.
private func fixturePhoto() throws -> URL {
    let bundle = previewFixtureBundle()
    return try XCTUnwrap(bundle.url(forResource: "photo", withExtension: "jpg", subdirectory: "Fixtures")
        ?? bundle.url(forResource: "photo", withExtension: "jpg"), "missing Fixtures/photo.jpg")
}

@MainActor final class PreviewShaderTests: XCTestCase {
    /// Pass 1 against the frozen `sampleHdr` reference from the Web editor.
    /// Both the v2 path (one monochrome gain plane, bilinear) and the v1 path
    /// (a full-size HDR plane) are covered by the fixture's four cases.
    func testPassOneMatchesFrozenWebReference() throws {
        let renderer = try makePreviewRenderer()
        let device = renderer.device
        let width = 7, height = 5
        let base = (0..<(width * height * 3)).map { Float(($0 * 13) % 41) / 40 - 0.025 }
        let fullHDR = base.map { $0 * 4 }
        let gain: [Float] = [-0.2, 0.15, 0.7, 0.9, 0.4, 1.2]
        // The frame stores RGB triples; the planes are the frame's own floats.
        let baseBuffer = try XCTUnwrap(device.makeBuffer(bytes: base,
            length: base.count * MemoryLayout<Float>.size, options: .storageModeShared))
        let gainBuffer = try XCTUnwrap(device.makeBuffer(bytes: gain,
            length: gain.count * MemoryLayout<Float>.size, options: .storageModeShared))
        let hdrBuffer = try XCTUnwrap(device.makeBuffer(bytes: fullHDR,
            length: fullHDR.count * MemoryLayout<Float>.size, options: .storageModeShared))
        func compactPlanes(weight: Float) -> FramePlanes {
            FramePlanes(base: baseBuffer, baseRowBytes: width * 3 * 4,
                        gain: gainBuffer, gainRowBytes: 3 * 4, gainChannels: 1,
                        width: width, height: height, gainWidth: 3, gainHeight: 2,
                        gainMin: -0.5, gainMax: 3, gainGamma: 1.7, gainWeight: weight,
                        baseOffset: 0.015, alternateOffset: 0.025)
        }
        let v1Planes = FramePlanes(base: baseBuffer, baseRowBytes: width * 3 * 4,
                                   gain: hdrBuffer, gainRowBytes: width * 3 * 4,
                                   gainChannels: 3, width: width, height: height,
                                   gainWidth: width, gainHeight: height,
                                   gainWeight: 1)
        var maximumError: Float = 0
        for (compact, weight) in [(true, Float(0)), (true, 0.65), (true, 1), (false, Float(1))] {
            let actual = try renderer.reconstructFloat(planes: compact
                ? compactPlanes(weight: weight) : v1Planes)
            try tracePreviewPixels("sample-\(compact)-\(weight)", actual)
            let expected = try sampledReference(width: width, height: height,
                compact: compact, weight: weight)
            for pixel in 0..<(width * height) {
                for channel in 0..<3 {
                    let error = abs(actual[pixel * 4 + channel] - expected[pixel * 3 + channel])
                    maximumError = max(maximumError, error)
                    XCTAssertEqual(actual[pixel * 4 + channel], expected[pixel * 3 + channel],
                        accuracy: 1e-3,
                        "compact=\(compact), weight=\(weight), pixel=\(pixel), channel=\(channel)")
                }
            }
        }
        print("pass 1 vs frozen Web sampleHdr reference: 420 channel comparisons, "
            + "maximum absolute error=\(maximumError), tolerance=0.001")
    }

    /// The presentation texture keeps extended values: a 3-stop gain reaching a
    /// white of 8.0; original mode preserves the source's HDR rendition.
    func testPresentationKeepsPeakWhiteAndOriginalMode() throws {
        let renderer = try makePreviewRenderer()
        let planes = try Self.uniformPlanes(device: renderer.device, base: 1, gainMin: 3, gainMax: 3)
        let hdr = try renderer.readIntermediate(planes: planes, original: false)
        try tracePreviewPixels("white-hdr", hdr)
        XCTAssertEqual(hdr[0], 8, accuracy: 0.01)
        XCTAssertEqual(hdr[1], 8, accuracy: 0.01)
        let original = try renderer.readIntermediate(planes: planes, original: true)
        try tracePreviewPixels("white-original", original)
        XCTAssertEqual(original[0], 8, accuracy: 0.001)
        print("rgba16Float intermediate: HDR white=\(hdr[0]), original HDR white=\(original[0])")

        // The diagnostic window's synthetic ramp uses the same pass and must
        // still reach the same 8× peak (and 1.0 in original mode).
        let ramp = try PreviewRenderer.syntheticRamp(device: renderer.device)
        let rampPixels = try renderer.readIntermediate(planes: ramp, original: false)
        let rampOriginal = try renderer.readIntermediate(planes: ramp, original: true)
        try tracePreviewPixels("ramp-hdr", rampPixels)
        try tracePreviewPixels("ramp-original", rampOriginal)
        // At column x, v = x/(width-1): the base is v and the gain v · 3 stops,
        // so the reconstructed value is v · 2^(3v), from 0 to 8 at the right
        // edge. Every column of the white middle band is checked, in all three
        // channels, so a misread base plane cannot pass.
        let row = ramp.height / 2
        var maximumError: Float = 0
        for x in 0..<ramp.width {
            let v = Float(x) / Float(ramp.width - 1)
            let hdr = v * exp2(3 * v)
            for channel in 0..<3 {
                let index = (row * ramp.width + x) * 4 + channel
                // Half-float storage: about 1/1000 of the value, plus a floor near 0.
                let tolerance = max(0.002, hdr * 0.002)
                maximumError = max(maximumError, abs(rampPixels[index] - hdr))
                XCTAssertEqual(rampPixels[index], hdr, accuracy: tolerance, "HDR column \(x), channel \(channel)")
                XCTAssertEqual(rampOriginal[index], hdr, accuracy: tolerance, "original column \(x), channel \(channel)")
            }
        }
        XCTAssertEqual(rampPixels[(row * ramp.width + ramp.width - 1) * 4], 8, accuracy: 0.01)
        print("synthetic ramp: \(ramp.width) columns × 3 channels vs v · 2^(3v), "
            + "maximum absolute error=\(maximumError)")
    }

    /// The renderer holds the frame it prepared until a newer one replaces it
    /// or the canvas is cleared. Before, it kept only the frame's address: a
    /// new frame allocated where a released one had been was served the old
    /// texture (40 of 40 in the A1 review probe).
    func testNewFrameNeverGetsAReleasedFramesTexture() async throws {
        let source = try fixturePhoto()
        let engine = try await Engine()
        let session = try engine.openPreview(source: source)
        defer { session.close() }
        let renderer = try makePreviewRenderer()
        // Builds every intermediate from scratch: the truth for each frame.
        let reference = try makePreviewRenderer()
        func render(_ exposure: Double) async throws -> PreviewFrame {
            try await session.renderFrame(EngineRequest(settings: ["preview_max_edge": .number(64),
                                                                   "exposure": .number(exposure)]))
        }
        for attempt in 0..<20 {
            var shownFrame: PreviewFrame? = try await render(-2)
            let shownTexture = try renderer.prepare(frame: shownFrame!, original: false)
            // The cache holds the frame object itself, so no newer frame can be
            // allocated at its address while it is cached.
            XCTAssertTrue(renderer.isPrepared(from: shownFrame!), "attempt \(attempt)")
            // The model drops the frame it showed: under the old address-only
            // cache, the next frame could land where it was.
            shownFrame = nil

            let next = try await render(Double(attempt % 3))
            XCTAssertFalse(try renderer.prepare(frame: next, original: false) === shownTexture,
                           "attempt \(attempt): a new frame was served the previous texture")
            let shown = try renderer.readIntermediate(frame: next, original: false)
            let truth = try reference.readIntermediate(planes: FramePlanes(next, device: reference.device),
                                                       original: false)
            try tracePreviewPixels("R1-\(attempt)-shown", shown)
            try tracePreviewPixels("R1-\(attempt)-truth", truth)
            XCTAssertEqual(shown, truth, "attempt \(attempt): the canvas shows another frame's pixels")
        }

        // Closing the photo lets go of the intermediate and its frame.
        let last = try await render(1)
        try renderer.prepare(frame: last, original: false)
        XCTAssertTrue(renderer.isPrepared(from: last))
        renderer.clear(in: CAMetalLayer())
        XCTAssertFalse(renderer.isPrepared(from: last))
        XCTAssertNil(renderer.readyFrameIdentity)
    }

    /// No drawable (a layer without a device hands out none) presents nothing
    /// and is retried: the next call, with a working layer, draws.
    func testNilDrawableIsRetriedOnTheNextDraw() async throws {
        let renderer = try makePreviewRenderer()
        try renderer.prepare(planes: try PreviewRenderer.syntheticRamp(device: renderer.device), original: false)
        let transform = CanvasTransform(imageSize: CGSize(width: 16, height: 16),
                                        viewport: CGSize(width: 16, height: 16))
        let broken = CAMetalLayer()
        broken.drawableSize = CGSize(width: 16, height: 16)
        XCTAssertFalse(renderer.draw(in: broken, transform: transform))
        XCTAssertTrue(renderer.needsRetry)

        let layer = CAMetalLayer()
        layer.device = renderer.device
        layer.pixelFormat = .rgba16Float
        layer.drawableSize = CGSize(width: 16, height: 16)
        XCTAssertTrue(renderer.draw(in: layer, transform: transform))
        XCTAssertFalse(renderer.needsRetry)
        // The in-flight gate (A2b-1) holds further presents until it completes.
        await eventually("the presentation to complete") { !renderer.isBusy }

        XCTAssertFalse(renderer.clear(in: broken))
        XCTAssertTrue(renderer.needsRetry)
        XCTAssertNil(renderer.readyFrameIdentity, "clear lets go of the frame even when it cannot present")
        XCTAssertTrue(renderer.clear(in: layer))
        XCTAssertFalse(renderer.needsRetry)
    }

    /// A miss followed by a layer with nothing to present (zero size, or no
    /// frame) must not leave `needsRetry` set, or the view retries every tick.
    func testNothingToPresentClearsTheRetryFlag() throws {
        let renderer = try makePreviewRenderer()
        try renderer.prepare(planes: try PreviewRenderer.syntheticRamp(device: renderer.device), original: false)
        let transform = CanvasTransform(imageSize: CGSize(width: 16, height: 16),
                                        viewport: CGSize(width: 16, height: 16))
        let broken = CAMetalLayer()
        broken.drawableSize = CGSize(width: 16, height: 16)
        let empty = CAMetalLayer()

        XCTAssertFalse(renderer.draw(in: broken, transform: transform))
        XCTAssertTrue(renderer.needsRetry)
        XCTAssertTrue(renderer.draw(in: empty, transform: transform))
        XCTAssertFalse(renderer.needsRetry, "zero-size layer")

        XCTAssertFalse(renderer.draw(in: broken, transform: transform))
        XCTAssertFalse(renderer.clear(in: broken))      // also drops the frame
        XCTAssertTrue(renderer.needsRetry)
        XCTAssertFalse(renderer.clear(in: empty))
        XCTAssertTrue(renderer.needsRetry, "zero-size clear must be retried at a drawable size")

        XCTAssertFalse(renderer.clear(in: broken))
        XCTAssertTrue(renderer.needsRetry)
        XCTAssertTrue(renderer.draw(in: broken, transform: transform), "no frame: nothing to draw")
        XCTAssertFalse(renderer.needsRetry, "no frame")
    }

    /// A real engine frame renders through the same pass, and the Metal buffers
    /// are the frame's own page-aligned planes: no pixel copy on the way in.
    func testEngineFramePlanesAreUsedWithoutCopying() async throws {
        let source = try fixturePhoto()
        let engine = try await Engine()
        let session = try engine.openPreview(source: source)
        defer { session.close() }
        let frame = try await session.renderFrame(EngineRequest(
            settings: ["preview_max_edge": .number(32)]))
        let renderer = try makePreviewRenderer()
        let buffers = try frame.metalBuffers(device: renderer.device)
        let basePointer = frame.base.withUnsafeBytes { $0.baseAddress }
        let gainPointer = frame.gain.withUnsafeBytes { $0.baseAddress }
        XCTAssertEqual(buffers.base.contents(), UnsafeMutableRawPointer(mutating: basePointer),
                       "the base plane must be shared, not copied")
        XCTAssertEqual(buffers.gain.contents(), UnsafeMutableRawPointer(mutating: gainPointer),
                       "the gain plane must be shared, not copied")

        let pixels = try renderer.readIntermediate(frame: frame, original: false)
        try tracePreviewPixels("native-hdr", pixels)
        XCTAssertEqual(pixels.count, frame.base.width * frame.base.height * 4)
        // Spot-check the reconstruction against the same maths in Swift.
        let metadata = frame.metadata
        let x = frame.base.width / 2, y = frame.base.height / 2
        let expected = try expectation(frame: frame, x: x, y: y, metadata: metadata)
        XCTAssertEqual(pixels[(y * frame.base.width + x) * 4 + 0], expected.0,
                       accuracy: max(1e-2, abs(expected.0) * 1e-3))
        let original = try renderer.readIntermediate(frame: frame, original: true)
        try tracePreviewPixels("native-original", original)
        XCTAssertEqual(original[(y * frame.base.width + x) * 4 + 0], expected.0,
                       accuracy: max(1e-2, abs(expected.0) * 1e-3))
    }

    private static func uniformPlanes(device: any MTLDevice, base: Float,
                                      gainMin: Float, gainMax: Float) throws -> FramePlanes {
        let width = 4, height = 2
        let baseValues = [Float](repeating: base, count: width * height * 3)
        let gainValues = [Float](repeating: 0, count: width * height)
        let baseBuffer = try XCTUnwrap(device.makeBuffer(bytes: baseValues,
            length: baseValues.count * MemoryLayout<Float>.size, options: .storageModeShared))
        let gainBuffer = try XCTUnwrap(device.makeBuffer(bytes: gainValues,
            length: gainValues.count * MemoryLayout<Float>.size, options: .storageModeShared))
        return FramePlanes(base: baseBuffer, baseRowBytes: width * 3 * 4,
                           gain: gainBuffer, gainRowBytes: width * 4, gainChannels: 1,
                           width: width, height: height, gainWidth: width, gainHeight: height,
                           gainMin: gainMin, gainMax: gainMax, gainGamma: 1, gainWeight: 1)
    }

    private func expectation(frame: PreviewFrame, x: Int, y: Int,
                             metadata: PreviewMetadata) throws -> (Float, Float, Float, Float) {
        let base = frame.base.withUnsafeBytes { raw -> (Float, Float, Float) in
            let pointer = raw.baseAddress!.assumingMemoryBound(to: Float.self)
            let index = y * (frame.base.rowBytes / 4) + x * 3
            return (pointer[index], pointer[index + 1], pointer[index + 2])
        }
        let gain = frame.gain.withUnsafeBytes { raw -> Float in
            let pointer = raw.baseAddress!.assumingMemoryBound(to: Float.self)
            let gx = frame.metadata.gainWidth ?? frame.gain.width
            let gy = frame.metadata.gainHeight ?? frame.gain.height
            let fxRaw: Float = (Float(x) + 0.5) * Float(gx) / Float(frame.base.width) - 0.5
            let fyRaw: Float = (Float(y) + 0.5) * Float(gy) / Float(frame.base.height) - 0.5
            let fx: Float = min(max(fxRaw, 0), Float(gx - 1))
            let fy: Float = min(max(fyRaw, 0), Float(gy - 1))
            let x0 = Int(floor(max(0, fx))), y0 = Int(floor(max(0, fy)))
            let x1 = min(x0 + 1, gx - 1), y1 = min(y0 + 1, gy - 1)
            let wx = max(0, fx) - Float(x0), wy = max(0, fy) - Float(y0)
            func value(_ px: Int, _ py: Int) -> Float {
                pointer[py * (frame.gain.rowBytes / 4) + px]
            }
            let top = value(x0, y0) + (value(x1, y0) - value(x0, y0)) * wx
            let bottom = value(x0, y1) + (value(x1, y1) - value(x0, y1)) * wx
            return min(max(top + (bottom - top) * wy, 0), 1)
        }
        let gamma = Float(metadata.gainGamma ?? 1)
        let gainMin = Float(metadata.gainMin ?? 0)
        let gainMax = Float(metadata.gainMax ?? 0)
        let gainWeight = Float(metadata.gainWeight ?? 1)
        let decoded = powf(gain, 1 / max(gamma, 0.0001))
        let exponent = (gainMin + (gainMax - gainMin) * decoded) * gainWeight
        let multiplier = powf(2, exponent)
        let baseOffset = Float(metadata.baseOffset ?? 0)
        let alternateOffset = Float(metadata.alternateOffset ?? 0)
        func reconstruct(_ value: Float) -> Float {
            max(0, (value + baseOffset) * multiplier - alternateOffset)
        }
        return (reconstruct(base.0), reconstruct(base.1), reconstruct(base.2), base.0)
    }

    private func sampledReference(width: Int, height: Int, compact: Bool, weight: Float) throws -> [Float] {
        let url = try XCTUnwrap(previewFixtureBundle()
            .url(forResource: "sample-hdr-reference", withExtension: "json"),
            "missing sample-hdr-reference.json")
        let reference = try JSONDecoder().decode(SampleHDRReference.self, from: Data(contentsOf: url))
        XCTAssertEqual(reference.width, width)
        XCTAssertEqual(reference.height, height)
        let item = try XCTUnwrap(reference.cases.first {
            $0.compact == compact && !$0.original && abs($0.weight - weight) < 1e-6
        })
        return item.values
    }
}
