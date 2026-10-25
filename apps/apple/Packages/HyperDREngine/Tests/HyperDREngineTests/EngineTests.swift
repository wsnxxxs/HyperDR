import Foundation
import Testing
@testable import HyperDREngine



@Test func frameLayoutIsPureAndStrict() throws {
    let layout = try Engine.frameLayout(frame: ["margins": .number(0.05), "caption": .number(0.1)],
                                        photoWidth: 3000, photoHeight: 2000)
    #expect(layout.width == 3200 && layout.height == 2400)
    #expect(layout.photo == FrameLayout.Rect(x: 100, y: 100, width: 3000, height: 2000))
    #expect(layout.caption == FrameLayout.Rect(x: 0, y: 2100, width: 3200, height: 300))
    #expect(throws: HyperDRError.self) {
        try Engine.frameLayout(frame: ["margin": .number(0.05)], photoWidth: 3000, photoHeight: 2000)
    }
    #expect(throws: HyperDRError.self) {
        try Engine.frameLayout(frame: [:], photoWidth: 0, photoHeight: 2000)
    }
}



@Test func packagingABIVersion() { #expect(Engine.abiVersion == 6) }

@Test func rawConversionAndPreviewReports() async throws {
    var root = URL(fileURLWithPath: #filePath)
    for _ in 0..<7 { root.deleteLastPathComponent() }
    let source = root.appendingPathComponent("build/fixtures/sony-ilce-7s.ARW")
    let output = FileManager.default.temporaryDirectory.appendingPathComponent("engine-raw-compat-\(UUID())")
    defer { try? FileManager.default.removeItem(at: output) }
    try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
    let engine = try await Engine()
    let converted = try await engine.convertRAWToDNG(source, to: output.appendingPathComponent("photo.dng"))
    #expect(converted.converter == Engine.rawConverterID)
    #expect(["cfa", "linear"].contains(converted.layout))
    #expect(converted.width > 0 && converted.height > 0)
    #expect((1...8).contains(converted.orientation))

    let preview = try await engine.extractRAWPreview(source, to: output.appendingPathComponent("preview.jpg"))
    #expect(preview.width > 0 && preview.height > 0)
    #expect((1...8).contains(preview.orientation))
    let capabilities = try await engine.capabilities()
    #expect(capabilities.rawConverter == Engine.rawConverterID)
}
