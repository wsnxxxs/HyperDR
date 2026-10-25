import Foundation
import HyperDREngine
import HyperDRRender
import Testing
@testable import HyperDRKit

private actor ConversionCounter {
    private(set) var value = 0
    func add() { value += 1 }
}

@Suite(.timeLimit(.minutes(1))) struct RAWCompatibilityConverterTests {
    @Test func concurrentConversionIsSharedAndRevisionCacheIsReused() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("raw-compat-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("photo.ARW")
        try Data("first".utf8).write(to: source)
        let count = ConversionCounter()
        let converter = RAWCompatibilityConverter(root: root.appendingPathComponent("cache"),
            converterID: "test-libraw/dng-1", convert: { _, output in
                await count.add()
                try await Task.sleep(for: .milliseconds(30))
                try Data("converted".utf8).write(to: output)
            }, extract: { _, output in
                try Data("preview".utf8).write(to: output)
            })

        async let first = converter.convertDNG(from: source)
        async let second = converter.convertDNG(from: source)
        let pair = try await [first, second]
        #expect(await count.value == 1)
        #expect(pair[0].url == pair[1].url)
        #expect(!pair[0].usedCache)
        let cached = try await converter.convertDNG(from: source)
        #expect(cached.usedCache)
        #expect(cached.url == pair[0].url)
        #expect(try Data(contentsOf: cached.url) == Data("converted".utf8))

        try Data("a different revision".utf8).write(to: source)
        _ = try await converter.convertDNG(from: source)
        #expect(await count.value == 2)
    }

    @Test func engineFailuresKeepTheirPublicCompatibilityMeaning() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("raw-compat-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("photo.ARW")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([1]).write(to: source)
        let converter = RAWCompatibilityConverter(root: root.appendingPathComponent("cache"),
            converterID: "test-libraw/dng-1", convert: { _, _ in
                throw HyperDRError(code: "raw_unsupported", message: "unsupported",
                    detail: .object(["container": .string("camera"), "model": .string("ILCE-7M5")]))
            }, extract: { _, _ in
                throw HyperDRError(code: "no_preview", message: "none")
            })
        do {
            _ = try await converter.convertDNG(from: source)
            Issue.record("Unsupported conversion succeeded")
        } catch RenderError.rawUnsupported(let camera) {
            #expect(camera == "ILCE-7M5")
        }
        do {
            _ = try await converter.extractEmbeddedPreview(from: source)
            Issue.record("Missing preview succeeded")
        } catch RAWCompatibilityError.noPreview {
        }
    }
}
