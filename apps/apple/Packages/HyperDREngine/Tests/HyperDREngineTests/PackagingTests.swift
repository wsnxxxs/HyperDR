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
    // The working gamut is one of the metadata fields the C struct carries, and
    // an unset one would silently mean Display P3: a grid measured in another
    // space is refused by name instead of being written as if it were P3.
    do {
        _ = try await engine.package(
            sdr: PackagePlane(samples: UnsafeBufferPointer(start: baseStorage.baseAddress, count: baseStorage.count),
                              width: width, height: height, channels: 3),
            gain: PackagePlane(samples: UnsafeBufferPointer(start: gainStorage.baseAddress, count: gainStorage.count),
                               width: width, height: height, channels: 1),
            gainMetadata: PackageGainMetadata(alternateHeadroom: 1.5, workingGamut: "srgb"),
            to: directory.appendingPathComponent("srgb.jpg"),
            options: PackageOptions(format: "iso-gainmap-jpeg"))
        Issue.record("a non-P3 working gamut must be refused, not written as Display P3")
    } catch let error as HyperDRError {
        #expect(error.code == "unsupported_format")
    }
}

/// A framed canvas (P7): the render graph composites the mat before packaging,
/// so the entry point keeps E5 -- the mat stays SDR -- by writing an exact zero
/// gain code there and reading its own file back to prove it.
@Test func packageKeepsAFramedMatSDR() async throws {
    let engine = try await Engine()
    let width = 64, height = 48
    // The photograph sits inside a mat wide enough for the readback to have
    // pixels of its own to check away from the photo's edge.
    let mat = 14
    let photo = FrameLayout.Rect(x: mat, y: mat, width: width - 2 * mat, height: height - 2 * mat)
    let baseStorage = UnsafeMutableBufferPointer<Float>.allocate(capacity: width * height * 3)
    let gainStorage = UnsafeMutableBufferPointer<Float>.allocate(capacity: width * height)
    let unsignedGainStorage = UnsafeMutableBufferPointer<Float>.allocate(capacity: width * height)
    defer {
        baseStorage.deallocate(); gainStorage.deallocate(); unsignedGainStorage.deallocate()
    }
    let basePlane = PackagePlane(samples: UnsafeBufferPointer(start: baseStorage.baseAddress, count: baseStorage.count),
                                 width: width, height: height, channels: 3)
    let gainPlane = PackagePlane(samples: UnsafeBufferPointer(start: gainStorage.baseAddress, count: gainStorage.count),
                                 width: width, height: height, channels: 1)
    let unsignedGainPlane = PackagePlane(
        samples: UnsafeBufferPointer(start: unsignedGainStorage.baseAddress, count: unsignedGainStorage.count),
        width: width, height: height, channels: 1)
    for y in 0..<height {
        for x in 0..<width {
            let pixel = y * width + x
            let inside = x >= photo.x && x < photo.x + photo.width &&
                         y >= photo.y && y < photo.y + photo.height
            if inside {
                let u = Float(x - photo.x) / Float(photo.width - 1)
                let v = Float(y - photo.y) / Float(photo.height - 1)
                baseStorage[pixel * 3] = 0.10 + 0.70 * u
                baseStorage[pixel * 3 + 1] = 0.10 + 0.60 * v
                baseStorage[pixel * 3 + 2] = 0.12
                // Below and above the base, so zero has to be aligned between
                // two non-zero endpoints rather than falling on an end code.
                gainStorage[pixel] = -0.3 + 1.6 * u * v
                // The adaptive form is ISO 21496-1's Apple shape: no signed
                // gain, so it clips at zero.
                unsignedGainStorage[pixel] = max(0, gainStorage[pixel])
            } else {
                baseStorage[pixel * 3] = 0.18
                baseStorage[pixel * 3 + 1] = 0.18
                baseStorage[pixel * 3 + 2] = 0.18
                gainStorage[pixel] = 0
                unsignedGainStorage[pixel] = 0
            }
        }
    }
    let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("hyperdr-framed-package-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // A signed pair stores the zero code between two non-zero endpoints, and
    // reads back as a framed canvas.
    let signedOutput = directory.appendingPathComponent("framed.jpg")
    let signed = try await engine.package(
        sdr: basePlane, gain: gainPlane,
        gainMetadata: PackageGainMetadata(alternateHeadroom: 1.4),
        to: signedOutput,
        options: PackageOptions(format: "iso-gainmap-jpeg", presentationFrame: true, framePhoto: photo))
    let signedGain = try #require(signed.gain)
    #expect(signedGain.gamma == 1)
    #expect(signedGain.gainMin < 0 && signedGain.gainMax > 1)
    // The report rounds its numbers to six significant digits, which is far
    // below the half code that would make the mat's own code ambiguous.
    var zeroPosition = -signedGain.gainMin / (signedGain.gainMax - signedGain.gainMin) * 255
    #expect(abs(zeroPosition - zeroPosition.rounded()) < 1e-3)

    // Gamma 1 and a zero code aligned to the mat's value are what keep the mat
    // from picking up a tint of its own, in the adaptive container too.
    let output = directory.appendingPathComponent("framed.heic")
    let report = try await engine.package(
        sdr: basePlane, gain: unsignedGainPlane,
        gainMetadata: PackageGainMetadata(alternateHeadroom: 1.3),
        to: output,
        options: PackageOptions(format: "adaptive", presentationFrame: true, framePhoto: photo))
    let gain = try #require(report.gain)
    #expect(gain.gamma == 1)
    #expect(gain.gainMin == 0 && gain.gainMax > 1)
    zeroPosition = -gain.gainMin / (gain.gainMax - gain.gainMin) * 255
    #expect(abs(zeroPosition - zeroPosition.rounded()) < 1e-3)
    #expect(FileManager.default.fileExists(atPath: output.path))

    // A rectangle that leaves part of the photograph in the mat is not a frame
    // this entry point can sign off on, and the half-written file is gone.
    let wrong = FrameLayout.Rect(x: photo.x + 4, y: photo.y + 4,
                                 width: photo.width - 8, height: photo.height - 8)
    await #expect(throws: HyperDRError.self) {
        try await engine.package(
            sdr: basePlane, gain: unsignedGainPlane,
            gainMetadata: PackageGainMetadata(alternateHeadroom: 1.3),
            to: directory.appendingPathComponent("wrong.heic"),
            options: PackageOptions(format: "adaptive", presentationFrame: true, framePhoto: wrong))
    }
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("wrong.heic").path))

    // A rectangle without the frame intention is a caller mistake.
    await #expect(throws: HyperDRError.self) {
        try await engine.package(
            sdr: basePlane, gain: unsignedGainPlane,
            gainMetadata: PackageGainMetadata(alternateHeadroom: 1.3),
            to: directory.appendingPathComponent("noframe.heic"),
            options: PackageOptions(format: "adaptive", framePhoto: photo))
    }
}

@Test func packageRowsUsesBorrowedBandsAndPropagatesFailure() async throws {
    let engine = try await Engine()
    #expect(Engine.supportsPackageRows(format: "iso-gainmap-jpeg"))
    // AVIF stages quantized rows on disk and encodes one cell at a time.
    #expect(Engine.supportsPackageRows(format: "avif-pq"))
    #expect(Engine.supportsPackageRows(format: "avif-hlg"))
    #expect(!Engine.supportsPackageRows(format: "not-a-format"))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("band.jpg")
    let report = try await engine.packageRows(width: 35, height: 29, gainChannels: 1,
        gainMetadata: PackageGainMetadata(alternateHeadroom: 2), rows: 7,
        to: output, options: PackageOptions(format: "iso-gainmap-jpeg")) { y, rows, base, gain in
            #expect(rows <= 7 && base.count == 35 * rows * 3)
            for i in 0..<base.count { base[i] = 0.3 }
            for i in 0..<gain!.count { gain![i] = Float(y + i / 35) / 29 }
        }
    #expect(report.width == 35 && report.height == 29 && report.verified)
    enum Stop: Error { case requested }
    let stopped = directory.appendingPathComponent("stopped.jpg")
    do {
        _ = try await engine.packageRows(width: 35, height: 29, to: stopped,
            options: PackageOptions(format: "sdr-jpeg")) { _, _, _, _ in throw Stop.requested }
        Issue.record("A throwing row reader succeeded")
    } catch Stop.requested {}
    #expect(!FileManager.default.fileExists(atPath: stopped.path))
}
