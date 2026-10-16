import Foundation
import Metal
import XCTest
@testable import HyperDR

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
            let expected = original ? base : try javascriptSample(base: base, hdr: fullHDR, gain: compact ? gain : nil,
                                                                  width: width, height: height, weight: weight)
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
        print("MSL vs JS sampleHdr: 525 channel comparisons, maximum absolute error=\(maximumError), tolerance=0.001")
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

    private func javascriptSample(base: [Float], hdr: [Float], gain: [Float]?, width: Int, height: Int, weight: Float) throws -> [Float] {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("../../..", isDirectory: true).standardized
        let packet = root.appendingPathComponent("apps/panel/web/js/preview/packet.js")
        var frame: [String: Any] = ["width": width, "height": height, "base": base, "hdr": hdr,
            "metadata": ["gainWidth": 3, "gainHeight": 2, "gainMin": -0.5, "gainMax": 3,
                         "gainGamma": 1.7, "baseOffset": 0.015, "alternateOffset": 0.025, "gainWeight": weight]]
        if let gain { frame["gain"] = gain }
        let script = """
        import { pathToFileURL } from 'node:url';
        import { readFileSync } from 'node:fs';
        const { sampleHdr } = await import(pathToFileURL(process.argv[1]));
        const frame = JSON.parse(readFileSync(0, 'utf8'));
        const values = [], rgb = [0, 0, 0];
        for (let i = 0; i < frame.width * frame.height; i++) values.push(...sampleHdr(frame, i, rgb));
        process.stdout.write(JSON.stringify(values));
        """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["node", "--input-type=module", "-e", script, packet.path]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin")
        process.environment = environment
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        try process.run()
        input.fileHandleForWriting.write(try JSONSerialization.data(withJSONObject: frame))
        try input.fileHandleForWriting.close()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)
        return try JSONDecoder().decode([Float].self, from: bytes)
    }
}
