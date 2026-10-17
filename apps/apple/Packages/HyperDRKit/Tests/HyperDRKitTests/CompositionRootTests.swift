import Foundation
import Testing
@testable import HyperDRKit

@Suite struct CompositionRootTests {
    @Test func compositionRootWiresEngineSchemaFormatsAndSessions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyperdr-kit-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = KitConfiguration(
            supportDirectory: root.appendingPathComponent("support", isDirectory: true),
            cacheDirectory: root.appendingPathComponent("cache", isDirectory: true))
        let kit = try await HyperDRKit(configuration: configuration)
        #expect(!kit.schema.settings.isEmpty)
        #expect(kit.capabilities.codecs)
        #expect(!kit.formats.contentTypes.isEmpty)
        #expect(kit.formats.prefixBytes == 16)
        _ = kit.sessions
    }
}

private actor CleanupGate {
    private var calls = 0
    private var released = false
    private var first: CheckedContinuation<Void, Never>?

    func run() async -> Int {
        calls += 1
        if calls == 1, !released {
            await withCheckedContinuation { first = $0 }
        }
        return 0
    }

    var callCount: Int { calls }

    func releaseFirst() {
        released = true
        first?.resume()
        first = nil
    }
}

private func waitUntil(timeout: Duration = .seconds(2),
                       _ condition: @Sendable () async -> Bool) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

private func schedulingConfiguration() -> (KitConfiguration, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("hyperdr-k2-schedule-\(UUID().uuidString)", isDirectory: true)
    return (KitConfiguration(
        supportDirectory: root.appendingPathComponent("support", isDirectory: true),
        cacheDirectory: root.appendingPathComponent("cache", isDirectory: true)), root)
}

@Suite struct CleanupSchedulingTests {
    @Test func startStopStartKeepsOneCleanupLoop() async throws {
        let (configuration, root) = schedulingConfiguration()
        defer { try? FileManager.default.removeItem(at: root) }
        let kit = try await HyperDRKit(configuration: configuration,
            cleanupInterval: .milliseconds(30), cleanup: { 0 })

        await kit.start()
        #expect(await waitUntil { kit.activeCleanupLoops == 1 })
        kit.stop()
        #expect(await waitUntil { kit.activeCleanupLoops == 0 })

        await kit.start()
        #expect(await waitUntil { kit.activeCleanupLoops == 1 })
        kit.stop()
        #expect(await waitUntil { kit.activeCleanupLoops == 0 })
    }

    @Test func stopDuringStartupCleanupCancelsTheStaleStart() async throws {
        let (configuration, root) = schedulingConfiguration()
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = CleanupGate()
        let kit = try await HyperDRKit(configuration: configuration,
            cleanupInterval: .milliseconds(30), cleanup: { await gate.run() })

        let first = Task { await kit.start() }
        #expect(await waitUntil { await gate.callCount == 1 })
        kit.stop()

        let second = Task { await kit.start() }
        #expect(await waitUntil { await gate.callCount == 2 })
        await gate.releaseFirst()
        await first.value
        await second.value

        #expect(await waitUntil { kit.activeCleanupLoops == 1 })
        kit.stop()
        #expect(await waitUntil { kit.activeCleanupLoops == 0 })
    }
}
