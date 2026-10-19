import Foundation
import HyperDRKit
import Testing

/// This file deliberately imports the public interface, without @testable.
@Suite struct M3PublicAPITests {
    @Test func diagnosticsAndEncodingAvailabilityAreReadableByAppClients() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hyperdr-public-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let kit = try await HyperDRKit(configuration: KitConfiguration(
            supportDirectory: root.appendingPathComponent("support"), cacheDirectory: root.appendingPathComponent("cache")))
        #expect(!kit.capabilities.version.isEmpty)
        #expect(!kit.capabilities.buildFingerprint.isEmpty)
        #expect(!kit.capabilities.encodings.isEmpty)
        _ = kit.capabilities.encoder
        _ = kit.capabilities.models
        #expect(await kit.jobs.activity == .idle)
    }
}
