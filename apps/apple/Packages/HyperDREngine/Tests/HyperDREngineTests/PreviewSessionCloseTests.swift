import Foundation
import Testing
@testable import HyperDREngine

private let fixtures = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../../../../..", isDirectory: true).standardized

private let settings: [String: JSONValue] = ["preview_max_edge": .number(16)]

private func smokeSource() -> URL? {
    let source = fixtures.appendingPathComponent("build/smoke/input.jpg")
    guard FileManager.default.fileExists(atPath: source.path) else {
        print("skipping preview session lifecycle test: run the smoke suite first")
        return nil
    }
    return source
}

@Test func closingAPreviewSessionReleasesItOnceAndRejectsLaterCalls() async throws {
    guard let source = smokeSource() else { return }
    let engine = try await Engine()
    let session = try engine.openPreview(source: source)
    let identifier = session.identifier
    _ = try await session.renderFrame(EngineRequest(settings: settings))
    #expect(!session.isClosed)
    // `detach` relies on this being a real release, not a no-op that leaves the
    // native session (and its decoded planes) alive until ARC runs.
    session.close()
    #expect(session.isClosed)
    session.close()
    #expect(PreviewSession.closeLog.count(for: identifier) == 1)
    do {
        _ = try await session.renderFrame(EngineRequest(settings: settings))
        Issue.record("A closed session must not render")
    } catch let error as HyperDRError {
        #expect(error.code == "cancelled")
    }
}

@Test func releasingASessionWithoutClosingItStillReleasesTheNativeHandle() async throws {
    guard let source = smokeSource() else { return }
    let engine = try await Engine()
    var session: PreviewSession? = try engine.openPreview(source: source)
    let identifier = try #require(session?.identifier)
    weak var weakSession = session
    session = nil
    #expect(weakSession == nil)
    // ARC-only sessions own the native handle too: exactly one close.
    #expect(PreviewSession.closeLog.count(for: identifier) == 1)
}

@Test func concurrentCloseAndCancellationReleaseExactlyOnce() async throws {
    guard let source = smokeSource() else { return }
    let engine = try await Engine()
    let session = try engine.openPreview(source: source)
    let identifier = session.identifier
    let work = Task {
        try await session.renderFrame(EngineRequest(settings: settings))
    }
    for _ in 0..<200 where !session.isReserved { try await Task.sleep(for: .milliseconds(1)) }
    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<100 { group.addTask { session.close() } }
    }
    work.cancel()
    _ = try? await work.value
    #expect(session.isClosed)
    #expect(!session.isReserved)
    session.close()
    #expect(PreviewSession.closeLog.count(for: identifier) == 1)
    do {
        _ = try await session.renderPacket(EngineRequest(settings: [:]))
        Issue.record("A closed session must not render")
    } catch let error as HyperDRError {
        #expect(error.code == "cancelled")
    }
}
