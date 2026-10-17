import Foundation
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

@MainActor final class PreviewShaderTests: XCTestCase {
    func testMSLMatchesJavaScriptSampleHdr() throws {
        let renderer = try PreviewRenderer()
        let function = try XCTUnwrap(renderer.library.makeFunction(name: "previewVerify"))
        let pipeline = try renderer.device.makeComputePipelineState(function: function)
        let width = 7, height = 5
        let base = (0..<(width * height * 3)).map { Float(($0 * 13) % 41) / 40 - 0.025 }
        let fullHDR = base.map { $0 * 4 }
        let gain: [Float] = [-0.2, 0.15, 0.7, 0.9, 0.4, 1.2]
        func rgba(_ rgb: [Float]) -> [Float] {
            stride(from: 0, to: rgb.count, by: 3).flatMap { [rgb[$0], rgb[$0 + 1], rgb[$0 + 2], 1] }
        }
        let baseTexture = try PreviewRenderer.texture(device: renderer.device, width: width, height: height, values: rgba(base))
        let gainTexture = try PreviewRenderer.texture(device: renderer.device, width: 3, height: 2, values: gain, monochrome: true)
        let fullTexture = try PreviewRenderer.texture(device: renderer.device, width: width, height: height, values: rgba(fullHDR))
        var maximumError: Float = 0
        for (compact, original, weight) in [(true, false, Float(0)), (true, false, 0.65), (true, false, 1),
                                             (false, false, 1), (true, true, 1)] {
            var p = PreviewParams(original: original ? 1 : 0, width: Float(width), height: Float(height),
                compact: compact ? 1 : 0, gainMin: -0.5, gainMax: 3, inverseGamma: 1 / 1.7,
                baseOffset: 0.015, alternateOffset: 0.025, gainWeight: weight)
            let output = try XCTUnwrap(renderer.device.makeBuffer(length: width * height * MemoryLayout<SIMD4<Float>>.stride, options: .storageModeShared))
            let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeComputeCommandEncoder())
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(baseTexture, index: 0)
            encoder.setTexture(compact ? gainTexture : fullTexture, index: 1)
            encoder.setBytes(&p, length: MemoryLayout<PreviewParams>.stride, index: 0)
            encoder.setBuffer(output, offset: 0, index: 1)
            encoder.dispatchThreads(MTLSize(width: width, height: height, depth: 1),
                                    threadsPerThreadgroup: MTLSize(width: 7, height: 1, depth: 1))
            encoder.endEncoding()
            command.commit()
            command.waitUntilCompleted()
            XCTAssertNil(command.error)
            let expected = original ? base : try sampledReference(
                width: width, height: height, compact: compact, weight: weight)
            let actual = output.contents().bindMemory(to: SIMD4<Float>.self, capacity: width * height)
            for pixel in 0..<(width * height) {
                for channel in 0..<3 {
                    let error = abs(actual[pixel][channel] - expected[pixel * 3 + channel])
                    maximumError = max(maximumError, error)
                    XCTAssertEqual(actual[pixel][channel], expected[pixel * 3 + channel], accuracy: 1e-3,
                                   "compact=\(compact), original=\(original), weight=\(weight), pixel=\(pixel), channel=\(channel)")
                }
            }
        }
        print("MSL vs frozen Web sampleHdr reference: 525 channel comparisons, maximum absolute error=\(maximumError), tolerance=0.001")
    }

    func testFloat16PresentationPreservesExtendedPixels() throws {
        let renderer = try PreviewRenderer()
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba16Float,
            width: 512, height: 128, mipmapped: false)
        descriptor.storageMode = .shared
        descriptor.usage = .renderTarget
        let texture = try XCTUnwrap(renderer.device.makeTexture(descriptor: descriptor))
        for original in [false, true] {
            let command = try XCTUnwrap(renderer.queue.makeCommandBuffer())
            renderer.encode(into: texture, command: command, original: original)
            command.commit()
            command.waitUntilCompleted()
            XCTAssertNil(command.error)
            var pixel = [UInt16](repeating: 0, count: 4)
            pixel.withUnsafeMutableBytes {
                texture.getBytes($0.baseAddress!, bytesPerRow: 8,
                    from: MTLRegionMake2D(511, 64, 1, 1), mipmapLevel: 0)
            }
            let white = Float(Float16(bitPattern: pixel[0]))
            XCTAssertEqual(white, original ? 1 : 8, accuracy: 0.001)
        }
        print("rgba16Float presentation readback: HDR white=8.0, SDR white=1.0")
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
