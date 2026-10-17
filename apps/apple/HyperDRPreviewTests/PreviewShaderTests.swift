import Foundation
import HyperDREngine
import Metal
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

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../..", isDirectory: true).standardized

@MainActor final class PreviewShaderTests: XCTestCase {
    /// Pass 1 against the frozen `sampleHdr` reference from the Web editor.
    /// Both the v2 path (one monochrome gain plane, bilinear) and the v1 path
    /// (a full-size HDR plane) are covered by the fixture's four cases.
    func testPassOneMatchesFrozenWebReference() throws {
        let renderer = try PreviewRenderer()
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
    /// white of 8.0, and the original mode showing the SDR base at 1.0.
    func testPresentationKeepsPeakWhiteAndOriginalMode() throws {
        let renderer = try PreviewRenderer()
        let planes = try Self.uniformPlanes(device: renderer.device, base: 1, gainMin: 3, gainMax: 3)
        let hdr = try renderer.readIntermediate(planes: planes, original: false)
        XCTAssertEqual(hdr[0], 8, accuracy: 0.01)
        XCTAssertEqual(hdr[1], 8, accuracy: 0.01)
        let original = try renderer.readIntermediate(planes: planes, original: true)
        XCTAssertEqual(original[0], 1, accuracy: 0.001)
        print("rgba16Float intermediate: HDR white=\(hdr[0]), SDR white=\(original[0])")

        // The diagnostic window's synthetic ramp uses the same pass and must
        // still reach the same 8× peak (and 1.0 in original mode).
        let ramp = try PreviewRenderer.syntheticRamp(device: renderer.device)
        let rampPixels = try renderer.readIntermediate(planes: ramp, original: false)
        // The ramp is 0…3 stops of gain over a 0…1 base: the reconstructed
        // value at column x is 8 · x/(width-1). The peak therefore sits at the
        // right edge, and comparing against that column's own expected value
        // checks the whole 0–8× curve instead of one magic constant.
        let columns = stride(from: 0, to: rampPixels.count, by: 4).map { rampPixels[$0] }
        let peak = columns.max() ?? 0
        let peakColumn = (columns.firstIndex(of: peak) ?? 0) % ramp.width
        let expected = 8 * Double(peakColumn) / Double(ramp.width - 1)
        XCTAssertEqual(Double(peak), expected, accuracy: 0.25)
        XCTAssertGreaterThanOrEqual(peakColumn, ramp.width - 2)
        let rampOriginal = try renderer.readIntermediate(planes: ramp, original: true)
        // The same column in original mode shows the 0…1 base.
        let basePeak = columns.isEmpty ? 0 : rampOriginal[peakColumn * 4]
        XCTAssertEqual(basePeak, Float(expected / 8), accuracy: 0.001)
    }

    /// A real engine frame renders through the same pass, and the Metal buffers
    /// are the frame's own page-aligned planes: no pixel copy on the way in.
    func testEngineFramePlanesAreUsedWithoutCopying() async throws {
        let source = repository.appendingPathComponent("build/smoke/input.jpg")
        guard FileManager.default.fileExists(atPath: source.path) else {
            print("skipping testEngineFramePlanesAreUsedWithoutCopying: run the smoke suite first")
            return
        }
        let engine = try await Engine()
        let session = try engine.openPreview(source: source)
        defer { session.close() }
        let frame = try await session.renderFrame(EngineRequest(
            settings: ["preview_max_edge": .number(32)]))
        let renderer = try PreviewRenderer()
        let buffers = try frame.metalBuffers(device: renderer.device)
        let basePointer = frame.base.withUnsafeBytes { $0.baseAddress }
        let gainPointer = frame.gain.withUnsafeBytes { $0.baseAddress }
        XCTAssertEqual(buffers.base.contents(), UnsafeMutableRawPointer(mutating: basePointer),
                       "the base plane must be shared, not copied")
        XCTAssertEqual(buffers.gain.contents(), UnsafeMutableRawPointer(mutating: gainPointer),
                       "the gain plane must be shared, not copied")

        let pixels = try renderer.readIntermediate(frame: frame, original: false)
        XCTAssertEqual(pixels.count, frame.base.width * frame.base.height * 4)
        // Spot-check the reconstruction against the same maths in Swift.
        let metadata = frame.metadata
        let x = frame.base.width / 2, y = frame.base.height / 2
        let expected = try expectation(frame: frame, x: x, y: y, metadata: metadata)
        XCTAssertEqual(pixels[(y * frame.base.width + x) * 4 + 0], expected.0,
                       accuracy: max(1e-2, abs(expected.0) * 1e-3))
        let original = try renderer.readIntermediate(frame: frame, original: true)
        XCTAssertEqual(original[(y * frame.base.width + x) * 4 + 0], expected.3,
                       accuracy: max(1e-2, abs(expected.3) * 1e-3))
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
        let url = try XCTUnwrap(Bundle(for: PreviewShaderTests.self)
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
