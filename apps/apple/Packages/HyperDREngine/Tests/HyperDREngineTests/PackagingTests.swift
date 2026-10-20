import Foundation
import Testing
@testable import HyperDREngine

/// `hyperdr_package` hands a render graph's planes to the engine's writers. The
/// C ABI test owns the format matrix; this checks the Swift side end to end:
/// the plane views, the parameter JSON and the report decode.
@Test func packageWritesAGainMapPair() async throws {
    let engine = try await Engine()
    let width = 24, height = 16
    let baseStorage = UnsafeMutableBufferPointer<Float>.allocate(capacity: width * height * 3)
    let gainStorage = UnsafeMutableBufferPointer<Float>.allocate(capacity: width * height)
    defer { baseStorage.deallocate(); gainStorage.deallocate() }
    for y in 0..<height {
        for x in 0..<width {
            let pixel = y * width + x
            baseStorage[pixel * 3] = 0.20 + 0.50 * Float(x) / Float(width - 1)
            baseStorage[pixel * 3 + 1] = 0.20 + 0.40 * Float(y) / Float(height - 1)
            baseStorage[pixel * 3 + 2] = 0.15
            gainStorage[pixel] = 1.5 * Float(x * y) / Float((width - 1) * (height - 1))
        }
    }
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("hyperdr-package-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("pair.jpg")

    let report = try await engine.package(
        sdr: PackagePlane(samples: UnsafeBufferPointer(start: baseStorage.baseAddress, count: baseStorage.count),
                          width: width, height: height, channels: 3),
        gain: PackagePlane(samples: UnsafeBufferPointer(start: gainStorage.baseAddress, count: gainStorage.count),
                           width: width, height: height, channels: 1),
        gainMetadata: PackageGainMetadata(alternateHeadroom: 1.5),
        to: output,
        options: PackageOptions(format: "iso-gainmap-jpeg", quality: 88))

    #expect(report.schema == "hyperdr.package/v1")
    #expect(report.format == "iso-gainmap-jpeg")
    #expect(report.width == width && report.height == height)
    #expect(report.verified && report.verification == "iso-gainmap-jpeg")
    #expect(report.metadata.icc == "display-p3" && !report.metadata.exif)
    let gain = try #require(report.gain)
    #expect(gain.stored && gain.channels == 1)
    #expect(gain.gainMax > 1.4 && gain.gainMax <= 1.5)
    #expect(gain.alternateHeadroom == 1.5)
    #expect(FileManager.default.fileExists(atPath: output.path))

    // A package call never replaces an existing file unless it was asked to.
    await #expect(throws: HyperDRError.self) {
        try await engine.package(
            sdr: PackagePlane(samples: UnsafeBufferPointer(start: baseStorage.baseAddress, count: baseStorage.count),
                              width: width, height: height, channels: 3),
            to: output, options: PackageOptions(format: "sdr-jpeg"))
    }
    // A gain plane without its ISO metadata is a caller mistake, not a format
    // the writer refuses.
    await #expect(throws: HyperDRError.self) {
        try await engine.package(
            sdr: PackagePlane(samples: UnsafeBufferPointer(start: baseStorage.baseAddress, count: baseStorage.count),
                              width: width, height: height, channels: 3),
            gain: PackagePlane(samples: UnsafeBufferPointer(start: gainStorage.baseAddress, count: gainStorage.count),
                               width: width, height: height, channels: 1),
            to: directory.appendingPathComponent("unused.jpg"), options: PackageOptions(format: "adaptive"))
    }
}
