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
    #expect(Engine.abiVersion == 1)
    #expect(!Engine.version.isEmpty)
}

@Test func curveAndEngineErrors() throws {
    let bytes = try Engine.curve(settings: [:], samples: 4)
    #expect(try JSONSerialization.jsonObject(with: bytes) is [String: Any])
    #expect(throws: HyperDRError.self) {
        try Engine.curve(settings: ["unknown_setting": .bool(true)], samples: 4)
    }
}
