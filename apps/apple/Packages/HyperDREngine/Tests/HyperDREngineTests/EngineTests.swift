import Foundation
import Testing
@testable import HyperDREngine

@Test func schemaMatchesCommandLineBytes() throws {
    let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../../../..", isDirectory: true).standardized
    let process = Process()
    process.executableURL = root.appendingPathComponent("build-apple/HyperDR")
    process.arguments = ["schema"]
    let output = Pipe()
    process.standardOutput = output
    try process.run()
    let bytes = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    #expect(process.terminationStatus == 0)
    let schema = try Engine.schema()
    #expect(schema.rawJSON == bytes)
    #expect(!schema.settings.isEmpty)
    #expect(Engine.abiVersion == 2)
    #expect(!Engine.version.isEmpty)
}

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

@Test func curveAndEngineErrors() throws {
    let bytes = try Engine.curve(settings: [:], samples: 4)
    #expect(try JSONSerialization.jsonObject(with: bytes) is [String: Any])
    #expect(throws: HyperDRError.self) {
        try Engine.curve(settings: ["unknown_setting": .bool(true)], samples: 4)
    }
}
