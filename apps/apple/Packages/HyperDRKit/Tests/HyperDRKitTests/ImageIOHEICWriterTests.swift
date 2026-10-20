import CoreImage
import Darwin
import Foundation
import HyperDREngine
import HyperDRRender
import ImageIO
import Testing
@testable import HyperDRKit

@Suite(.serialized) struct ImageIOHEICWriterTests {
    @Test func manualRGBMetadataSurvivesBothReaders() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("heic-manual-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let w = 128, h = 96
        let base = [Float](repeating: 0.3, count: w*h*3)
        var gain = [Float](repeating: 0, count: w*h*3)
        for i in gain.indices { gain[i] = Float(i % 256) / 255 * 2.75 - 0.25 }
        let metadata = ExportGainMetadata(channelCount: 3, baseOffset: .init(0.015625, 0.03125, 0.0625),
            alternateOffset: .init(0.03125, 0.0625, 0.125), baseHeadroom: 0, alternateHeadroom: 3)
        let file = root.appendingPathComponent("rgb.heic")
        let report = try base.withUnsafeBufferPointer { b in try gain.withUnsafeBufferPointer { g in
            try ImageIOHEICWriter.write(base: .init(samples: b, width: w, height: h, channels: 3),
                gain: .init(samples: g, width: w, height: h, channels: 3), metadata: metadata, to: file, quality: 90)
        } }
        let engine = try await Engine(configuration: .init(cacheDirectory: root.appendingPathComponent("cache")))
        let probe = try await engine.probe(file)
        #expect(probe.width == w && probe.height == h)
        #expect(probe.inputDomain == "dual-rendition")
        try ImageIOHEICWriter.verify(file, expected: report)
        #expect(report.channels == 3 && report.gainMin == -0.25 && report.gainMax == 2.5)
    }

    /// Opt-in one-process-per-writer comparison; excluded from routine work.
    @Test func writerComparisonMeasurement() async throws {
        guard let writer = ProcessInfo.processInfo.environment["HYPERDR_HEIC8_BENCH_WRITER"] else { return }
        let quality = Int(ProcessInfo.processInfo.environment["HYPERDR_HEIC8_BENCH_QUALITY"] ?? "90") ?? 90
        let root = URL(fileURLWithPath: "/tmp/p7-heic8-lab")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let w = 2048, h = 1536, count = w*h
        let base = UnsafeMutablePointer<Float>.allocate(capacity: count*3)
        let gain = UnsafeMutablePointer<Float>.allocate(capacity: count)
        defer { base.deallocate(); gain.deallocate() }
        for y in 0..<h { for x in 0..<w {
            let i = y*w+x, u = (Float(x)+0.5)/Float(w), v = (Float(y)+0.5)/Float(h)
            let detail = 0.025 * cosf(v * 80 * .pi) * sinf(u * 90 * .pi)
            base[i*3] = min(0.95, max(0.005, 0.03 + 0.8*u + detail))
            base[i*3+1] = min(0.95, max(0.005, 0.08 + 0.65*(1-u) + detail))
            base[i*3+2] = min(0.95, max(0.005, 0.05 + 0.6*sinf(v * .pi) + detail))
            gain[i] = 2 * u
        } }
        let b = PackagePlane(samples: .init(start: base, count: count*3), width: w, height: h, channels: 3)
        let g = PackagePlane(samples: .init(start: gain, count: count), width: w, height: h, channels: 1)
        let file = root.appendingPathComponent("\(writer)-q\(quality).heic")
        try? FileManager.default.removeItem(at: file)
        let engine = try await Engine(configuration: .init(cacheDirectory: root.appendingPathComponent("cache")))
        var before = rusage(); getrusage(RUSAGE_SELF, &before)
        let start = Date()
        if writer == "imageIO" {
            _ = try ImageIOHEICWriter.write(base: b, gain: g, metadata: .init(channelCount: 1, alternateHeadroom: 2),
                to: file, quality: quality)
        } else {
            _ = try await engine.package(sdr: b, gain: g, gainMetadata: .init(alternateHeadroom: 2), to: file,
                options: .init(format: "adaptive", quality: quality, depth: 8, verify: false))
        }
        let elapsed = Date().timeIntervalSince(start)
        var after = rusage(); getrusage(RUSAGE_SELF, &after)
        let probe = try await engine.probe(file)
        #expect(probe.inputDomain == "dual-rendition")
        let bytes = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize!
        var output: [String: Any] = ["writer": writer, "quality": quality, "width": w, "height": h,
            "bytes": bytes, "seconds": elapsed, "inputPeakBytes": before.ru_maxrss, "writePeakBytes": after.ru_maxrss]
        let context = CIContext(options: [.cacheIntermediates: false])
        let sdr = try #require(CIImage(contentsOf: file, options: [.expandToHDR: false]))
        let aux = try #require(CIImage(contentsOf: file, options: [.auxiliaryHDRGainMap: true]))
        output["SDR"] = metrics(sdr, context: context, base: base, gain: gain, width: w, height: h, hdr: false)
        output["HDR"] = metrics(sdr.applyingGainMap(aux, headroom: 4), context: context,
            base: base, gain: gain, width: w, height: h, hdr: true)
        let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted])
        try data.write(to: root.appendingPathComponent("\(writer)-q\(quality).json"))
        print("HEIC_COMPARISON " + String(data: data, encoding: .utf8)!)
    }

    private func metrics(_ image: CIImage, context: CIContext, base: UnsafePointer<Float>, gain: UnsafePointer<Float>,
                         width: Int, height: Int, hdr: Bool) -> [String: Double] {
        func code(_ value: Float) -> Double {
            let v = Double(max(0, value))
            if !hdr { return 255 * (v <= 0.0031308 ? 12.92*v : 1.055*pow(v, 1/2.4)-0.055) }
            let p = pow(v*203/10000, 2610.0/16384)
            return 1023 * pow((3424.0/4096 + 2413.0/128*p)/(1 + 2392.0/128*p), 2523.0/32)
        }
        var histogram = [Int](repeating: 0, count: 102400), maximum: Double = 0, sum: Double = 0
        // Full readback keeps the source and decoded bitmap's top-down row
        // convention identical. Metrics happen after the write peak is captured.
        var pixels = [Float](repeating: 0, count: width * height * 4)
        pixels.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: width*16,
            bounds: CGRect(x: 0, y: 0, width: width, height: height), format: .RGBAf,
            colorSpace: CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3)) }
        for i in 0..<(width*height) {
            for c in 0..<3 {
                let expected = base[i*3+c] * (hdr ? exp2f(gain[i]) : 1)
                let error = abs(code(pixels[i*4+c]) - code(expected))
                maximum = max(maximum, error); sum += error*error
                histogram[min(histogram.count-1, Int(error*100))] += 1
            }
        }
        let n = width*height*3, threshold = Int(ceil(Double(n)*0.999))
        var running = 0, percentile: Double = 0
        for i in histogram.indices {
            running += histogram[i]
            if running >= threshold { percentile = Double(i)/100; break }
        }
        let top: Double = hdr ? 1023 : 255
        return ["max": maximum, "p99.9": percentile, "PSNR": 10*log10(top*top*Double(n)/max(sum, 1e-30))]
    }

    @Test func frameCompressionExperiment() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("heic-frame-\(UUID()).heic")
        defer { try? FileManager.default.removeItem(at: file) }
        let w = 256, h = 192
        var base = [Float](repeating: 0.8, count: w*h*3), gain = [Float](repeating: 0, count: w*h)
        for y in 14..<178 { for x in 10..<246 {
            let i = y*w+x
            base[i*3] = 0.25; base[i*3+1] = 0.5; base[i*3+2] = 0.2
            gain[i] = (x+y) % 3 == 0 ? 0 : 2
        } }
        _ = try base.withUnsafeBufferPointer { b in try gain.withUnsafeBufferPointer { g in
            try ImageIOHEICWriter.write(base: .init(samples: b, width: w, height: h, channels: 3),
                gain: .init(samples: g, width: w, height: h, channels: 1),
                metadata: .init(channelCount: 1, alternateHeadroom: 2), to: file, quality: 90)
        } }
        let image = try #require(CIImage(contentsOf: file, options: [.auxiliaryHDRGainMap: true]))
        let gw = Int(image.extent.width), gh = Int(image.extent.height)
        var codes = [Float](repeating: 0, count: gw*gh)
        let context = CIContext(options: [.cacheIntermediates: false])
        codes.withUnsafeMutableBytes { context.render(image, toBitmap: $0.baseAddress!, rowBytes: gw*4,
            bounds: image.extent, format: .Rf, colorSpace: nil) }
        var count = 0, maximum: Float = 0
        for y in 0..<gh { for x in 0..<gw {
            if x * w / gw < 10 || x * w / gw >= 246 || y * h / gh < 14 || y * h / gh >= 178 {
                maximum = max(maximum, codes[y*gw+x]); if codes[y*gw+x] > 0.5/255 { count += 1 }
            }
        } }
        print("HEIC_FRAME_EXPERIMENT gain=\(gw)x\(gh) mat_nonzero=\(count) max_code=\(maximum*255)")
    }
}
