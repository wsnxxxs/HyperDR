import Foundation
import HyperDREngine
import Testing
@testable import HyperDRKit

private let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    .appendingPathComponent("../../../../../..", isDirectory: true).standardized

private actor FakeRenderer: PreviewRenderSession {
    let frame: PreviewFrame
    private var delay: Duration
    private var failure: HyperDRError?
    private(set) var calls = 0
    private(set) var cancellations = 0
    private(set) var maxConcurrent = 0
    private(set) var closes = 0
    private var active = 0

    init(frame: PreviewFrame, delay: Duration = .zero) {
        self.frame = frame
        self.delay = delay
    }

    func setDelay(_ value: Duration) { delay = value }
    func setFailure(_ value: HyperDRError?) { failure = value }

    func renderFrame(_ request: EngineRequest) async throws -> PreviewFrame {
        calls += 1
        active += 1
        maxConcurrent = max(maxConcurrent, active)
        defer { active -= 1 }
        do { try await Task.sleep(for: delay) }
        catch {
            cancellations += 1
            throw error
        }
        if let failure { throw failure }
        return frame
    }

    func close() async { closes += 1 }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.withLock { count += 1 }
    }

    var value: Int { lock.withLock { count } }
}

private actor EventRecorder {
    private var events: [PreviewEvent] = []
    func append(_ event: PreviewEvent) { events.append(event) }
    func snapshot() -> [PreviewEvent] { events }
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

private func makeFrame() async throws -> PreviewFrame {
    let engine = try await Engine()
    let session = try engine.openPreview(source: repository.appendingPathComponent("build/smoke/input.jpg"))
    return try await session.renderFrame(EngineRequest(settings: ["preview_max_edge": .number(8)]))
}

private func fakeSession(_ format: InputFormat = .jpeg) -> PhotoSession {
    let suffix = format.isRaw ? "arw" : "jpg"
    return PhotoSession(id: SessionID(rawValue: String(repeating: "b", count: 32)),
        sourceURL: URL(fileURLWithPath: "/tmp/fake.\(suffix)"), displayName: "fake.\(suffix)",
        byteCount: 1, sha256: "fake-digest", format: format)
}

private func request(_ session: PhotoSession, contrast: Double = 1.0) -> PreviewRequest {
    var values = EditDefaults.initial(encoding: "adaptive", sourceDomain: nil, unadjusted: nil).values
    values["contrast"] = .number(contrast)
    return PreviewRequest(session: session.id, options: EditOptions(values),
        maxEdge: 128, purpose: .edit)
}

private func makeService(_ renderer: any PreviewRenderSession, _ session: PhotoSession,
                         timeout: Duration = .seconds(1), rawTimeout: Duration = .seconds(1),
                         rawSlots: Int = 1, cacheEntries: Int = 2,
                         cacheBytes: Int = 4 << 20) throws -> PreviewService {
    PreviewService(schema: try Engine.schema(), buildFingerprint: "test-build",
        knownModels: ["research-cnn-v1": true], previewMaxEdge: 2048,
        previewTimeout: timeout, rawDecodeSlots: rawSlots, rawDecodeTimeout: rawTimeout,
        cacheEntries: cacheEntries, cacheBytes: cacheBytes,
        sessionProvider: { _ in session }, rendererFactory: { _ in renderer })
}

private func started(_ request: PreviewRequest, in events: [PreviewEvent]) -> Bool {
    events.contains { if case .started(let value) = $0 { return value == request }; return false }
}

private func finished(_ request: PreviewRequest, in events: [PreviewEvent]) -> PreviewResult? {
    for event in events {
        if case .finished(let result) = event, result.request == request { return result }
    }
    return nil
}

private func superseded(_ request: PreviewRequest, in events: [PreviewEvent]) -> Bool {
    events.contains { if case .superseded(let value) = $0 { return value == request }; return false }
}


/// A provider whose first lookup is slow: it reproduces "an older submit is
/// still resolving its session while a newer submit already renders".
private actor StaggeredProvider {
    private let photo: PhotoSession
    private let firstDelay: Duration
    private var calls = 0

    init(_ photo: PhotoSession, firstDelay: Duration) {
        self.photo = photo
        self.firstDelay = firstDelay
    }

    func session(_ id: SessionID) async -> PhotoSession {
        calls += 1
        if calls == 1 { try? await Task.sleep(for: firstDelay) }
        return photo
    }
}

/// Locks the first session lookup until the test releases it, so a submit can
/// be parked inside `attachedState` while a newer submit completes.
private actor ProviderGate {
    private let photo: PhotoSession
    private var calls = 0
    private var first: CheckedContinuation<Void, Never>?

    init(_ photo: PhotoSession) { self.photo = photo }

    var lookupCount: Int { calls }

    func lookup(_ id: SessionID) async -> PhotoSession {
        calls += 1
        if calls == 1 { await withCheckedContinuation { first = $0 } }
        return photo
    }

    func release() {
        first?.resume()
        first = nil
    }
}

/// A provider whose photo digest can change, standing in for a source file
/// replaced behind an open session.
private actor DigestProvider {
    private var photo: PhotoSession

    init(_ photo: PhotoSession) { self.photo = photo }
    func session(_ id: SessionID) async -> PhotoSession { photo }
    func replaceDigest(_ digest: String) {
        photo = PhotoSession(id: photo.id, sourceURL: photo.sourceURL,
            displayName: photo.displayName, byteCount: photo.byteCount,
            sha256: digest, format: photo.format)
    }
}

/// Translates cancellation into the engine's typed `cancelled` error, as the
/// native wrapper does for a cancelled C call.
private actor TypedCancelRenderer: PreviewRenderSession {
    let frame: PreviewFrame
    private(set) var calls = 0

    init(_ frame: PreviewFrame) { self.frame = frame }

    func renderFrame(_ request: EngineRequest) async throws -> PreviewFrame {
        calls += 1
        do { try await Task.sleep(for: .milliseconds(120)) }
        catch { throw HyperDRError(code: "cancelled", message: "Native cancellation") }
        return frame
    }

    func close() async {}
}

/// Parks one chosen session lookup until the test releases it, and answers
/// every lookup with the current (replaceable) photo.
private actor ParkingProvider {
    private var photo: PhotoSession
    private let parkedCall: Int
    private var calls = 0
    private var parked: CheckedContinuation<Void, Never>?

    init(_ photo: PhotoSession, parkedCall: Int) {
        self.photo = photo
        self.parkedCall = parkedCall
    }

    var lookupCount: Int { calls }
    var isParked: Bool { parked != nil }

    func lookup(_ id: SessionID) async -> PhotoSession {
        calls += 1
        if calls == parkedCall { await withCheckedContinuation { parked = $0 } }
        return photo
    }

    func replaceDigest(_ digest: String) {
        photo = PhotoSession(id: photo.id, sourceURL: photo.sourceURL,
            displayName: photo.displayName, byteCount: photo.byteCount,
            sha256: digest, format: photo.format)
    }

    func release() {
        parked?.resume()
        parked = nil
    }
}

/// A renderer whose first `close()` blocks until released, so a source-refresh
/// replacement can be held open while another request resolves its session.
private actor BlockingCloseRenderer: PreviewRenderSession {
    let frame: PreviewFrame
    private(set) var calls = 0
    private(set) var closes = 0
    private var blocked: CheckedContinuation<Void, Never>?
    private var blocksClose: Bool

    init(_ frame: PreviewFrame, blocksClose: Bool) {
        self.frame = frame
        self.blocksClose = blocksClose
    }

    var isClosing: Bool { blocked != nil }

    func renderFrame(_ request: EngineRequest) async throws -> PreviewFrame {
        calls += 1
        return frame
    }

    func close() async {
        closes += 1
        if blocksClose {
            blocksClose = false
            await withCheckedContinuation { blocked = $0 }
        }
    }

    func releaseClose() {
        blocked?.resume()
        blocked = nil
    }
}

@Suite(.timeLimit(.minutes(1))) struct PreviewServiceTests {
    @Test func repeatedValuesKeepDistinctTerminalIdentitiesWithoutMissingTheCache() async throws {
        let photo = fakeSession()
        let renderer = FakeRenderer(frame: try await makeFrame())
        let service = try makeService(renderer, photo)
        var first = request(photo)
        first.submissionID = UUID()
        var latest = first
        latest.submissionID = UUID()
        #expect(first != latest)
        let rendered = try await service.render(first)
        let cached = try await service.render(latest)
        #expect(rendered.request == first)
        #expect(cached.request == latest && cached.fromCache)
        #expect(await renderer.calls == 1)
        await service.detach(photo.id)
    }

    @Test func equalValueSubmitSupersedesOnlyTheOlderIdentity() async throws {
        let photo = fakeSession()
        let renderer = FakeRenderer(frame: try await makeFrame(), delay: .milliseconds(80))
        let service = try makeService(renderer, photo)
        let stream = service.events(for: photo.id)
        let recorder = EventRecorder()
        let observer = Task { for await event in stream { await recorder.append(event) } }
        defer { observer.cancel() }
        var first = request(photo)
        first.submissionID = UUID()
        var latest = first
        latest.submissionID = UUID()
        await service.submit(first)
        try #require(await waitUntil { await renderer.calls == 1 })
        let newest = latest
        await service.submit(newest)
        try #require(await waitUntil { finished(newest, in: await recorder.snapshot()) != nil })
        let events = await recorder.snapshot()
        #expect(superseded(first, in: events))
        #expect(!superseded(latest, in: events))
        #expect(finished(first, in: events) == nil)
        #expect(await renderer.calls == 1)
        await service.detach(photo.id)
    }

    @Test func renderCoalescesAndCaches() async throws {
        let frame = try await makeFrame()
        let renderer = FakeRenderer(frame: frame, delay: .milliseconds(60))
        let session = fakeSession()
        let service = try makeService(renderer, session)
        try await service.attach(session)
        let value = request(session)
        async let first = service.render(value)
        async let second = service.render(value)
        let a = try await first
        let b = try await second
        #expect(await renderer.calls == 1)
        #expect(!a.fromCache && !b.fromCache)
        let cached = try await service.render(value)
        #expect(cached.fromCache)
        #expect(cached.frame === a.frame)
        #expect(await renderer.calls == 1)
    }

    @Test func submitIsLatestWinsWithOnePending() async throws {
        let frame = try await makeFrame()
        let renderer = FakeRenderer(frame: frame, delay: .milliseconds(80))
        let session = fakeSession()
        let service = try makeService(renderer, session)
        try await service.attach(session)
        let recorder = EventRecorder()
        // Register the stream synchronously; the collector task itself may not
        // start before the first submit emits .started.
        let eventStream = service.events(for: session.id)
        let collector = Task { for await event in eventStream { await recorder.append(event) } }
        let a = request(session, contrast: 1.1)
        let b = request(session, contrast: 1.2)
        let c = request(session, contrast: 1.3)
        await service.submit(a)
        #expect(await waitUntil { started(a, in: await recorder.snapshot()) })
        await service.submit(b)
        await service.submit(c)
        #expect(await waitUntil {
            let events = await recorder.snapshot()
            return finished(a, in: events) != nil && finished(c, in: events) != nil && started(c, in: events)
        })
        let events = await recorder.snapshot()
        #expect(await renderer.calls == 2)
        #expect(!started(b, in: events))
        #expect(superseded(b, in: events))
        collector.cancel()
    }

    @Test func cachedSliderValueCancelsAnObsoleteRender() async throws {
        let frame = try await makeFrame()
        let renderer = FakeRenderer(frame: frame)
        let session = fakeSession()
        let service = try makeService(renderer, session)
        try await service.attach(session)
        let cachedRequest = request(session, contrast: 1.1)
        _ = try await service.render(cachedRequest)
        await renderer.setDelay(.milliseconds(300))
        let slow = request(session, contrast: 1.2)
        let recorder = EventRecorder()
        // Register the stream synchronously; the collector task itself may not
        // start before the first submit emits .started.
        let eventStream = service.events(for: session.id)
        let collector = Task { for await event in eventStream { await recorder.append(event) } }
        await service.submit(slow)
        #expect(await waitUntil { started(slow, in: await recorder.snapshot()) })
        // The .started event precedes the renderer task. Wait until the fake
        // engine is actually running before asking for the cached value, so
        // the cancellation is observable rather than a task that never began.
        // The first (cached) render above already counted one call, so the
        // slow render is call number two.
        #expect(await waitUntil { await renderer.calls >= 2 })
        await service.submit(cachedRequest)
        #expect(await waitUntil {
            let events = await recorder.snapshot()
            return finished(cachedRequest, in: events)?.fromCache == true
        })
        #expect(await waitUntil { await renderer.cancellations >= 1 })
        let after = await recorder.snapshot()
        #expect(finished(slow, in: after) == nil)
        #expect(superseded(slow, in: after))
        collector.cancel()
    }

    @Test func timeoutCancelsTheEngineRender() async throws {
        let frame = try await makeFrame()
        let renderer = FakeRenderer(frame: frame, delay: .seconds(2))
        let session = fakeSession()
        let service = try makeService(renderer, session, timeout: .milliseconds(60))
        try await service.attach(session)
        let start = ContinuousClock.now
        do {
            _ = try await service.render(request(session))
            Issue.record("Expected preview_timeout")
        } catch let error as HyperDRError {
            #expect(error.code == "preview_timeout")
        }
        #expect(start.duration(to: .now) < .milliseconds(500))
        #expect(await waitUntil { await renderer.cancellations == 1 })
    }

    @Test func rawGateTimeoutIsReportedAndReleaseRecovers() async throws {
        let frame = try await makeFrame()
        let renderer = FakeRenderer(frame: frame)
        let session = fakeSession(.raw(".arw"))
        let service = try makeService(renderer, session, rawTimeout: .milliseconds(50))
        try await service.attach(session)
        let ticket = try await service.rawGate.acquire(timeout: .seconds(1))
        do {
            _ = try await service.render(request(session))
            Issue.record("Expected raw_budget")
        } catch let error as HyperDRError {
            #expect(error.code == "raw_budget")
        }
        await ticket.release()
        let result = try await service.render(request(session))
        #expect(!result.fromCache)
        #expect(await renderer.calls == 1)
    }

    @Test func renderFailureIsPublishedToSubscribers() async throws {
        let frame = try await makeFrame()
        let renderer = FakeRenderer(frame: frame)
        await renderer.setFailure(HyperDRError(code: "decode_failed", message: "bad file"))
        let session = fakeSession()
        let service = try makeService(renderer, session)
        try await service.attach(session)
        let recorder = EventRecorder()
        // Register the stream synchronously; the collector task itself may not
        // start before the first submit emits .started.
        let eventStream = service.events(for: session.id)
        let collector = Task { for await event in eventStream { await recorder.append(event) } }
        let value = request(session)
        await service.submit(value)
        #expect(await waitUntil {
            let events = await recorder.snapshot()
            return events.contains {
                if case .failed(let request, let error) = $0 {
                    return request == value && error.code == "decode_failed"
                }
                return false
            }
        })
        collector.cancel()
    }

    @Test func realEngineJPEGAndARWRenderMatchesProbe() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyperdr-preview-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let kit = try await HyperDRKit(configuration: KitConfiguration(
            supportDirectory: root.appendingPathComponent("support", isDirectory: true),
            cacheDirectory: root.appendingPathComponent("cache", isDirectory: true)))
        for path in ["build/smoke/input.jpg", "build/fixtures/sony-ilce-7s.ARW"] {
            let url = repository.appendingPathComponent(path)
            #expect(FileManager.default.fileExists(atPath: url.path), "Run fetch_test_fixtures.py first")
            let session = try await kit.sessions.open(url)
            try await kit.previews.attach(session)
            let probe = try await kit.engine.probe(url)
            let value = PreviewRequest(session: session.id,
                options: EditDefaults.initial(encoding: "adaptive", sourceDomain: nil, unadjusted: nil),
                maxEdge: 64, purpose: .reference)
            let first = try await kit.previews.render(value)
            #expect(first.frame.metadata.sourceWidth == probe.width, "\(path) width")
            #expect(first.frame.metadata.sourceHeight == probe.height, "\(path) height")
            let second = try await kit.previews.render(value)
            #expect(second.fromCache)
            #expect(second.frame === first.frame)
            await kit.previews.detach(session.id)
            await kit.sessions.close(session.id)
        }
    }

    @Test func submitAndDirectRenderShareOneSerializedEngineSession() async throws {
        let frame = try await makeFrame()
        let renderer = FakeRenderer(frame: frame, delay: .milliseconds(80))
        let session = fakeSession()
        let service = try makeService(renderer, session)
        try await service.attach(session)
        let submitted = request(session, contrast: 1.1)
        let direct = request(session, contrast: 1.2)
        await service.submit(submitted)
        #expect(await waitUntil { await renderer.calls == 1 })
        _ = try await service.render(direct)
        #expect(await waitUntil { await renderer.calls == 2 })
        #expect(await renderer.maxConcurrent == 1)
    }

    @Test func differentDirectRendersAreSerializedByTheSessionGate() async throws {
        let frame = try await makeFrame()
        let renderer = FakeRenderer(frame: frame, delay: .milliseconds(60))
        let session = fakeSession()
        let service = try makeService(renderer, session)
        try await service.attach(session)
        async let first = service.render(request(session, contrast: 1.1))
        async let second = service.render(request(session, contrast: 1.2))
        _ = try await (first, second)
        #expect(await renderer.calls == 2)
        #expect(await renderer.maxConcurrent == 1)
    }

    @Test func serviceCacheEvictsTheOldestOfTwoEntries() async throws {
        let frame = try await makeFrame()
        let renderer = FakeRenderer(frame: frame)
        let session = fakeSession()
        let service = try makeService(renderer, session, cacheEntries: 2, cacheBytes: 4 << 20)
        try await service.attach(session)
        let first = request(session, contrast: 1.1)
        let second = request(session, contrast: 1.2)
        let third = request(session, contrast: 1.3)
        _ = try await service.render(first)
        _ = try await service.render(second)
        _ = try await service.render(third)
        #expect(await renderer.calls == 3)
        _ = try await service.render(first)
        #expect(await renderer.calls == 4)
        let cachedThird = try await service.render(third)
        #expect(cachedThird.fromCache)
    }

    @Test func queuedTimingIncludesThePendingWait() async throws {
        let frame = try await makeFrame()
        let renderer = FakeRenderer(frame: frame, delay: .milliseconds(80))
        let session = fakeSession()
        let service = try makeService(renderer, session)
        try await service.attach(session)
        let recorder = EventRecorder()
        let eventStream = service.events(for: session.id)
        let collector = Task { for await event in eventStream { await recorder.append(event) } }
        let first = request(session, contrast: 1.1)
        let second = request(session, contrast: 1.2)
        await service.submit(first)
        #expect(await waitUntil { started(first, in: await recorder.snapshot()) })
        await service.submit(second)
        #expect(await waitUntil { finished(second, in: await recorder.snapshot()) != nil })
        let queued = finished(second, in: await recorder.snapshot())?.timings.queued ?? .zero
        #expect(queued > .milliseconds(30))
        collector.cancel()
    }

    @Test func detachCancelsInFlightAndClosesTheSession() async throws {
        let frame = try await makeFrame()
        let renderer = FakeRenderer(frame: frame, delay: .seconds(1))
        let session = fakeSession()
        let service = try makeService(renderer, session)
        try await service.attach(session)
        await service.submit(request(session))
        #expect(await waitUntil { await renderer.calls == 1 })
        await service.detach(session.id)
        #expect(await waitUntil { await renderer.cancellations == 1 })
        #expect(await renderer.closes == 1)
    }

    @Test func cancellingDirectRenderMapsToCancelled() async throws {
        let frame = try await makeFrame()
        let renderer = FakeRenderer(frame: frame, delay: .seconds(1))
        let session = fakeSession()
        let service = try makeService(renderer, session)
        try await service.attach(session)
        let task = Task { try await service.render(request(session)) }
        #expect(await waitUntil { await renderer.calls == 1 })
        task.cancel()
        do {
            _ = try await task.value
            Issue.record("Expected cancelled")
        } catch let error as HyperDRError {
            #expect(error.code == "cancelled")
        }
        #expect(await waitUntil { await renderer.cancellations == 1 })
    }

    @Test func concurrentAttachCreatesOneRenderer() async throws {
        let frame = try await makeFrame()
        let session = fakeSession()
        let factoryCalls = LockedCounter()
        let service = try PreviewService(schema: Engine.schema(), buildFingerprint: "test-build",
            knownModels: ["research-cnn-v1": true], previewMaxEdge: 2048,
            previewTimeout: .seconds(1), rawDecodeSlots: 1, rawDecodeTimeout: .seconds(1),
            cacheEntries: 2, cacheBytes: 4 << 20,
            sessionProvider: { _ in session },
            rendererFactory: { _ in
                factoryCalls.increment()
                return FakeRenderer(frame: frame)
            })
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask { try? await service.attach(session) }
            }
        }
        #expect(factoryCalls.value == 1)
    }

    @Test func detachClearsCachedFramesForThePhoto() async throws {
        let frame = try await makeFrame()
        let renderer = FakeRenderer(frame: frame)
        let session = fakeSession()
        let service = try makeService(renderer, session)
        try await service.attach(session)
        let value = request(session)
        _ = try await service.render(value)
        #expect(await renderer.calls == 1)
        await service.detach(session.id)
        let again = try await service.render(value)
        #expect(!again.fromCache)
        #expect(await renderer.calls == 2)
    }

    @Test func attachingANewDigestCancelsTheInFlightRender() async throws {
        let frame = try await makeFrame()
        let renderer = FakeRenderer(frame: frame, delay: .seconds(1))
        let session = fakeSession()
        // The renderer's one-second delay is deliberately long enough to be
        // still running at attach time, so the preview timeout must be well
        // above it; otherwise the follow-up render races the timeout.
        let service = try makeService(renderer, session, timeout: .seconds(5))
        try await service.attach(session)
        await service.submit(request(session))
        #expect(await waitUntil { await renderer.calls == 1 })
        let replacement = PhotoSession(id: session.id, sourceURL: session.sourceURL,
            displayName: session.displayName, byteCount: session.byteCount,
            sha256: "replacement-digest", format: session.format)
        try await service.attach(replacement)
        #expect(await waitUntil { await renderer.cancellations == 1 })
        #expect(await renderer.closes == 1)
        let rendered = try await service.render(PreviewRequest(session: replacement.id,
            options: request(replacement).options, maxEdge: 128, purpose: .edit))
        #expect(rendered.frame === frame)
        #expect(await renderer.calls == 2)
    }

    @Test func rasterPreviewDoesNotWaitForTheRawSlot() async throws {
        let frame = try await makeFrame()
        let renderer = FakeRenderer(frame: frame)
        let raw = fakeSession(.raw(".arw"))
        let jpeg = PhotoSession(id: SessionID(rawValue: String(repeating: "c", count: 32)),
            sourceURL: URL(fileURLWithPath: "/tmp/other.jpg"), displayName: "other.jpg",
            byteCount: 1, sha256: "jpeg-digest", format: .jpeg)
        let service = try makeService(renderer, raw)
        try await service.attach(raw)
        try await service.attach(jpeg)
        let ticket = try await service.rawGate.acquire(timeout: .seconds(1))
        let clock = ContinuousClock()
        let started = clock.now
        let result = try await service.render(request(jpeg))
        #expect(!result.fromCache)
        #expect(started.duration(to: clock.now) < .milliseconds(300))
        await ticket.release()
    }

    @Test func olderSubmitMustNotReplaceANewerSubmitAfterProviderAwait() async throws {
        let frame = try await makeFrame()
        let renderer = FakeRenderer(frame: frame, delay: .milliseconds(60))
        let session = fakeSession()
        let gate = ProviderGate(session)
        let service = try PreviewService(schema: Engine.schema(), buildFingerprint: "test-build",
            knownModels: ["research-cnn-v1": true], previewMaxEdge: 2048,
            previewTimeout: .seconds(2), rawDecodeSlots: 1, rawDecodeTimeout: .seconds(1),
            cacheEntries: 2, cacheBytes: 4 << 20,
            sessionProvider: { id in await gate.lookup(id) },
            rendererFactory: { _ in renderer })
        let recorder = EventRecorder()
        let eventStream = service.events(for: session.id)
        let collector = Task { for await event in eventStream { await recorder.append(event) } }
        let older = request(session, contrast: 1.1)
        let newer = request(session, contrast: 1.2)
        // Park the older submit inside the session lookup, let the newer one
        // render, then release the older one: it must not become pending and
        // overwrite the newer frame.
        let slowSubmit = Task { await service.submit(older) }
        #expect(await waitUntil { await gate.lookupCount == 1 })
        await service.submit(newer)
        #expect(await waitUntil { finished(newer, in: await recorder.snapshot()) != nil })
        await gate.release()
        await slowSubmit.value
        #expect(await waitUntil { superseded(older, in: await recorder.snapshot()) })
        let events = await recorder.snapshot()
        #expect(finished(older, in: events) == nil)
        let renderedRequests = events.compactMap { event -> PreviewRequest? in
            if case .finished(let result) = event, !result.fromCache { return result.request }
            return nil
        }
        #expect(renderedRequests.last == newer)
        #expect(await renderer.calls == 1)
        collector.cancel()
    }

    @Test func detachMustCancelADirectRender() async throws {
        let frame = try await makeFrame()
        let renderer = FakeRenderer(frame: frame, delay: .milliseconds(600))
        let session = fakeSession()
        let service = try makeService(renderer, session, timeout: .seconds(5))
        try await service.attach(session)
        let direct = Task { try? await service.render(request(session)) }
        #expect(await waitUntil { await renderer.calls == 1 })
        let clock = ContinuousClock()
        let start = clock.now
        await service.detach(session.id)
        let elapsed = start.duration(to: clock.now)
        #expect(elapsed < .milliseconds(300), "detach waited \(elapsed) for the engine")
        #expect(await waitUntil { await renderer.cancellations == 1 })
        #expect(await renderer.closes == 1)
        _ = await direct.value
    }

    @Test func changedSourceMustInvalidateAttachedFrameCache() async throws {
        let frame = try await makeFrame()
        let renderer = FakeRenderer(frame: frame)
        let session = fakeSession()
        let provider = DigestProvider(session)
        let factoryCalls = LockedCounter()
        let service = try PreviewService(schema: Engine.schema(), buildFingerprint: "test-build",
            knownModels: ["research-cnn-v1": true], previewMaxEdge: 2048,
            previewTimeout: .seconds(1), rawDecodeSlots: 1, rawDecodeTimeout: .seconds(1),
            cacheEntries: 2, cacheBytes: 4 << 20,
            sessionProvider: { id in await provider.session(id) },
            rendererFactory: { _ in
                factoryCalls.increment()
                return renderer
            })
        let value = request(session)
        let first = try await service.render(value)
        #expect(!first.fromCache)
        #expect(first.sourceDigest == session.sha256)
        #expect(factoryCalls.value == 1)
        let cached = try await service.render(value)
        #expect(cached.fromCache)
        #expect(cached.sourceDigest == session.sha256)
        // The file behind the session was replaced: same id, new digest.
        await provider.replaceDigest("replacement-digest")
        let refreshed = try await service.render(value)
        #expect(!refreshed.fromCache, "a replaced source must not serve the old frame")
        #expect(refreshed.sourceDigest == "replacement-digest")
        #expect(await renderer.calls == 2)
        #expect(factoryCalls.value == 2, "the stale engine session must be replaced")
    }

    @Test func duplicateSubmitDoesNotPublishTwoFramePairs() async throws {
        let frame = try await makeFrame()
        let renderer = FakeRenderer(frame: frame, delay: .milliseconds(120))
        let session = fakeSession()
        let service = try makeService(renderer, session)
        try await service.attach(session)
        let recorder = EventRecorder()
        let eventStream = service.events(for: session.id)
        let collector = Task { for await event in eventStream { await recorder.append(event) } }
        let value = request(session, contrast: 1.1)
        await service.submit(value)
        #expect(await waitUntil { started(value, in: await recorder.snapshot()) })
        await service.submit(value)
        #expect(await waitUntil { finished(value, in: await recorder.snapshot()) != nil })
        try await Task.sleep(for: .milliseconds(200))
        let events = await recorder.snapshot()
        let starts = events.filter {
            if case .started(let request) = $0 { return request == value }
            return false
        }
        let finishes = events.filter {
            if case .finished(let result) = $0 { return result.request == value }
            return false
        }
        #expect(starts.count == 1)
        #expect(finishes.count == 1)
        #expect(await renderer.calls == 1)
        collector.cancel()
    }

    @Test func submitAcrossADetachMustNotResurrectTheSession() async throws {
        let frame = try await makeFrame()
        let renderer = FakeRenderer(frame: frame)
        let session = fakeSession()
        let provider = StaggeredProvider(session, firstDelay: .milliseconds(200))
        let service = try PreviewService(schema: Engine.schema(), buildFingerprint: "test-build",
            knownModels: ["research-cnn-v1": true], previewMaxEdge: 2048,
            previewTimeout: .seconds(1), rawDecodeSlots: 1, rawDecodeTimeout: .seconds(1),
            cacheEntries: 2, cacheBytes: 4 << 20,
            sessionProvider: { id in await provider.session(id) },
            rendererFactory: { _ in renderer })
        let recorder = EventRecorder()
        let eventStream = service.events(for: session.id)
        let collector = Task { for await event in eventStream { await recorder.append(event) } }
        try await service.attach(session)
        let value = request(session)
        let submit = Task { await service.submit(value) }
        try await Task.sleep(for: .milliseconds(50))
        await service.detach(session.id)
        await submit.value
        // The stale submit must not re-open the engine session on its own: that
        // would decode the photo nobody is showing any more.
        try await Task.sleep(for: .milliseconds(300))
        #expect(await renderer.calls == 0)
        #expect(finished(value, in: await recorder.snapshot()) == nil)
        collector.cancel()
    }

    @Test func replacedSourceOnDiskInvalidatesTheAttachedFrame() async throws {
        let original = repository.appendingPathComponent("build/smoke/input.jpg")
        let replacement = repository.appendingPathComponent("build/smoke/read-dng.jpg")
        guard FileManager.default.fileExists(atPath: original.path),
              FileManager.default.fileExists(atPath: replacement.path) else {
            print("skipping replacedSourceOnDiskInvalidatesTheAttachedFrame: run the smoke suite first")
            return
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyperdr-freshness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.jpg")
        try FileManager.default.copyItem(at: original, to: source)
        let kit = try await HyperDRKit(configuration: KitConfiguration(
            supportDirectory: root.appendingPathComponent("support", isDirectory: true),
            cacheDirectory: root.appendingPathComponent("cache", isDirectory: true)))
        let photo = try await kit.sessions.open(source)
        try await kit.previews.attach(photo)
        let value = PreviewRequest(session: photo.id,
            options: EditDefaults.initial(encoding: "adaptive", sourceDomain: nil, unadjusted: nil),
            maxEdge: 64, purpose: .edit)
        let before = try await kit.previews.render(value)
        #expect(!before.fromCache)
        try FileManager.default.removeItem(at: source)
        try FileManager.default.copyItem(at: replacement, to: source)
        let updated = try await kit.sessions.session(photo.id)
        #expect(updated.sha256 != photo.sha256, "the store must re-hash a replaced source")
        let probe = try await kit.engine.probe(source)
        let after = try await kit.previews.render(value)
        #expect(!after.fromCache, "a replaced source must not serve the old frame")
        #expect(after.frame.metadata.sourceWidth == probe.width)
        await kit.previews.detach(photo.id)
        await kit.sessions.close(photo.id)
    }

    @Test func cancelledRawWaiterDoesNotBlockTheNextOrLeakTheSlot() async throws {
        let gate = RawDecodeGate(slots: 1)
        let first = try await gate.acquire(timeout: .seconds(1))
        let cancelled = Task { try await gate.acquire(timeout: .seconds(1)) }
        try await Task.sleep(for: .milliseconds(10))
        let next = Task { try await gate.acquire(timeout: .seconds(1)) }
        try await Task.sleep(for: .milliseconds(10))
        cancelled.cancel()
        do {
            _ = try await cancelled.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {
        }
        await first.release()
        let second = try await next.value
        await second.release()
        let third = try await gate.acquire(timeout: .milliseconds(50))
        await third.release()
    }

    @Test func modelStrengthEntersTheNormalizedCacheKey() throws {
        let photo = fakeSession()
        let resolver = try OptionResolver(schema: Engine.schema(),
            knownModels: ["research-cnn-v1": true], maxEdgeCeiling: 2048)
        var weak = request(photo), strong = request(photo)
        weak.options["useModel"] = .bool(true)
        strong.options["useModel"] = .bool(true)
        weak.options["modelStrength"] = .number(0.2)
        strong.options["modelStrength"] = .number(0.8)
        let weakRequest = try resolver.resolve(weak, session: photo)
        let strongRequest = try resolver.resolve(strong, session: photo)
        #expect(weakRequest.settings["gain_strength"] == .number(0.2))
        #expect(strongRequest.settings["gain_strength"] == .number(0.8))
        #expect(try PreviewCacheKey(session: photo, request: weakRequest, buildFingerprint: "r")
            != PreviewCacheKey(session: photo, request: strongRequest, buildFingerprint: "r"))
    }

    @Test func returningToTheInFlightValueDiscardsADifferentPendingValue() async throws {
        let frame = try await makeFrame()
        let renderer = FakeRenderer(frame: frame, delay: .milliseconds(120))
        let session = fakeSession()
        let service = try makeService(renderer, session)
        try await service.attach(session)
        let recorder = EventRecorder()
        let eventStream = service.events(for: session.id)
        let collector = Task { for await event in eventStream { await recorder.append(event) } }
        let a = request(session, contrast: 1.1)
        let b = request(session, contrast: 1.2)
        await service.submit(a)
        #expect(await waitUntil { started(a, in: await recorder.snapshot()) })
        await service.submit(b)
        await service.submit(a)
        #expect(await waitUntil { finished(a, in: await recorder.snapshot()) != nil })
        try await Task.sleep(for: .milliseconds(250))
        let events = await recorder.snapshot()
        let finishes = events.compactMap { event -> Double? in
            guard case .finished(let result) = event,
                  case .number(let contrast)? = result.request.options["contrast"] else { return nil }
            return contrast
        }
        #expect(finishes.last == 1.1, "the newest request must own the last frame")
        #expect(finished(b, in: events) == nil)
        #expect(superseded(b, in: events))
        #expect(await renderer.calls == 1)
        collector.cancel()
    }

    @Test func submitAfterASourceRefreshReachesTheExistingSubscriber() async throws {
        let frame = try await makeFrame()
        let renderer = FakeRenderer(frame: frame)
        let session = fakeSession()
        let provider = DigestProvider(session)
        let service = try PreviewService(schema: Engine.schema(), buildFingerprint: "test-build",
            knownModels: ["research-cnn-v1": true], previewMaxEdge: 2048,
            previewTimeout: .seconds(2), rawDecodeSlots: 1, rawDecodeTimeout: .seconds(1),
            cacheEntries: 2, cacheBytes: 4 << 20,
            sessionProvider: { id in await provider.session(id) },
            rendererFactory: { _ in renderer })
        try await service.attach(session)
        let recorder = EventRecorder()
        let eventStream = service.events(for: session.id)
        let collector = Task { for await event in eventStream { await recorder.append(event) } }
        await provider.replaceDigest("changed-digest")
        let value = request(session)
        await service.submit(value)
        #expect(await waitUntil { finished(value, in: await recorder.snapshot()) != nil })
        #expect(await renderer.calls == 1)
        collector.cancel()
    }

    @Test func delayedSubmitDoesNotCreateAStateAfterDetach() async throws {
        let frame = try await makeFrame()
        let renderer = FakeRenderer(frame: frame)
        let session = fakeSession()
        let gate = ProviderGate(session)
        let factoryCalls = LockedCounter()
        let service = try PreviewService(schema: Engine.schema(), buildFingerprint: "test-build",
            knownModels: ["research-cnn-v1": true], previewMaxEdge: 2048,
            previewTimeout: .seconds(2), rawDecodeSlots: 1, rawDecodeTimeout: .seconds(1),
            cacheEntries: 2, cacheBytes: 4 << 20,
            sessionProvider: { id in await gate.lookup(id) },
            rendererFactory: { _ in
                factoryCalls.increment()
                return renderer
            })
        try await service.attach(session)
        let submit = Task { await service.submit(request(session)) }
        #expect(await waitUntil { await gate.lookupCount == 1 })
        await service.detach(session.id)
        await gate.release()
        await submit.value
        #expect(factoryCalls.value == 1, "a detached request must not install a renderer")
        #expect(await renderer.calls == 0)
    }

    @Test func repeatedCacheHitsDoNotRewriteTheSessionManifest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("hyperdr-manifest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.jpg")
        try FileManager.default.copyItem(
            at: repository.appendingPathComponent("build/smoke/input.jpg"), to: source)
        let kit = try await HyperDRKit(configuration: KitConfiguration(
            supportDirectory: root.appendingPathComponent("support", isDirectory: true),
            cacheDirectory: root.appendingPathComponent("cache", isDirectory: true)))
        let photo = try await kit.sessions.open(source)
        try await kit.previews.attach(photo)
        let value = request(photo)
        _ = try await kit.previews.render(value)
        let manifest = root.appendingPathComponent(
            "support/sessions/\(photo.id.rawValue)/session.json")
        func inode() throws -> UInt64 {
            let attributes = try FileManager.default.attributesOfItem(atPath: manifest.path)
            return (attributes[.systemFileNumber] as? NSNumber)?.uint64Value ?? 0
        }
        let before = try inode()
        for _ in 0..<40 {
            let result = try await kit.previews.render(value)
            #expect(result.fromCache)
        }
        #expect(try inode() == before, "cache hits must not rewrite session.json")
        await kit.previews.detach(photo.id)
        await kit.sessions.close(photo.id)
    }

    @Test func aLiveFollowerRetriesTheLeadersTypedCancellation() async throws {
        let frame = try await makeFrame()
        let renderer = TypedCancelRenderer(frame)
        let session = fakeSession()
        let service = try makeService(renderer, session, timeout: .seconds(2))
        try await service.attach(session)
        let value = request(session)
        let leader = Task { try await service.render(value) }
        #expect(await waitUntil { await renderer.calls == 1 })
        let follower = Task { try await service.render(value) }
        try await Task.sleep(for: .milliseconds(20))
        leader.cancel()
        _ = try? await leader.value
        do {
            let result = try await follower.value
            #expect(!result.fromCache)
        } catch let error as HyperDRError {
            Issue.record("A live follower inherited \(error.code)")
        }
        #expect(await renderer.calls == 2)
    }

    /// Two submits both see a changed source digest. The newer one starts
    /// replacing the engine session; the older one finishes its lookup while
    /// that replacement is still closing the old renderer. The newer request
    /// must still render (or at worst be superseded), never be reported as a
    /// `cancelled` failure, and no second replacement renderer may be opened
    /// while the old one is closing.
    @Test(arguments: [false, true]) func concurrentSubmitsAcrossASourceRefreshAreNotReportedAsFailures(closeFirst: Bool) async throws {
        let frame = try await makeFrame()
        let original = BlockingCloseRenderer(frame, blocksClose: true)
        let replacement = BlockingCloseRenderer(frame, blocksClose: false)
        let session = fakeSession()
        // Lookup 1 is the explicit attach below; lookup 2 is the older submit.
        let provider = ParkingProvider(session, parkedCall: 2)
        let factoryCalls = LockedCounter()
        let service = try PreviewService(schema: Engine.schema(), buildFingerprint: "test-build",
            knownModels: ["research-cnn-v1": true], previewMaxEdge: 2048,
            previewTimeout: .seconds(2), rawDecodeSlots: 1, rawDecodeTimeout: .seconds(1),
            cacheEntries: 2, cacheBytes: 4 << 20,
            sessionProvider: { id in await provider.lookup(id) },
            rendererFactory: { _ in
                factoryCalls.increment()
                return factoryCalls.value == 1 ? original : replacement
            })
        _ = try await service.render(request(session, contrast: 0.9))
        #expect(factoryCalls.value == 1)
        let recorder = EventRecorder()
        let eventStream = service.events(for: session.id)
        let collector = Task { for await event in eventStream { await recorder.append(event) } }
        await provider.replaceDigest("replacement-digest")
        let older = request(session, contrast: 1.1)
        let newer = request(session, contrast: 1.2)
        let olderSubmit = Task { await service.submit(older) }
        try #require(await waitUntil { await provider.isParked })
        let newerSubmit = Task { await service.submit(newer) }
        // The newer submit is now inside the replacement, holding the old
        // renderer's gate while it closes.
        try #require(await waitUntil { await original.isClosing })
        if closeFirst { await original.releaseClose() }
        await provider.release()
        // The older submit now has its (refreshed) photo too. It must wait for
        // the replacement rather than open a renderer beside the closing one.
        if !closeFirst {
            #expect(await waitUntil(timeout: .milliseconds(200)) { factoryCalls.value > 1 } == false,
                "a second renderer must not open while the replaced one is closing")
        }
        await original.releaseClose()
        await olderSubmit.value
        await newerSubmit.value
        #expect(await waitUntil { finished(newer, in: await recorder.snapshot()) != nil })
        let events = await recorder.snapshot()
        let failures = events.compactMap { event -> String? in
            if case .failed(_, let error) = event { return error.code }
            return nil
        }
        #expect(failures.isEmpty, "unexpected failures: \(failures)")
        #expect(superseded(older, in: events))
        #expect(finished(older, in: events) == nil)
        #expect(finished(newer, in: events)?.sourceDigest == "replacement-digest")
        #expect(factoryCalls.value == 2)
        #expect(await original.closes == 1)
        #expect(await replacement.calls == 1)
        collector.cancel()
    }
}

extension PreviewServiceTests {
    @Test(.timeLimit(.minutes(1))) func detachDuringReplacementClosesIdempotentlyAndFinishesStream() async throws {
        let frame = try await makeFrame()
        let original = BlockingCloseRenderer(frame, blocksClose: true)
        let replacement = BlockingCloseRenderer(frame, blocksClose: false)
        let session = fakeSession()
        let provider = DigestProvider(session)
        let factories = LockedCounter()
        let streamFinished = LockedCounter()
        let service = try PreviewService(schema: Engine.schema(), buildFingerprint: "review",
            knownModels: ["research-cnn-v1": true], previewMaxEdge: 2048,
            previewTimeout: .seconds(2), rawDecodeSlots: 1, rawDecodeTimeout: .seconds(1),
            cacheEntries: 2, cacheBytes: 4 << 20,
            sessionProvider: { id in await provider.session(id) },
            rendererFactory: { _ in
                factories.increment()
                return factories.value == 1 ? original : replacement
            })
        _ = try await service.render(request(session))
        let stream = service.events(for: session.id)
        let collector = Task { for await _ in stream {} ; streamFinished.increment() }
        await provider.replaceDigest("changed")
        let submit = Task { await service.submit(request(session, contrast: 1.2)) }
        try #require(await waitUntil { await original.isClosing })
        let detach = Task { await service.detach(session.id) }
        try #require(await waitUntil { streamFinished.value == 1 })
        await original.releaseClose()
        await submit.value
        await detach.value
        await collector.value
        #expect(factories.value == 1)
        #expect(await original.closes == 2)
        print("review detach/replacement: close calls=\(await original.closes), stream finished=\(streamFinished.value), factories=\(factories.value)")
    }

    @Test(.timeLimit(.minutes(1))) func lookupCancellationHasTerminalSuperseded() async throws {
        let session = fakeSession()
        let frame = try await makeFrame()
        let renderer = FakeRenderer(frame: frame)
        let service = try PreviewService(schema: Engine.schema(), buildFingerprint: "review",
            knownModels: ["research-cnn-v1": true], previewMaxEdge: 2048,
            previewTimeout: .seconds(2), rawDecodeSlots: 1, rawDecodeTimeout: .seconds(1),
            cacheEntries: 2, cacheBytes: 4 << 20,
            sessionProvider: { _ in throw HyperDRError(code: "cancelled", message: "Store closed") },
            rendererFactory: { _ in renderer })
        let recorder = EventRecorder()
        let stream = service.events(for: session.id)
        let collector = Task { for await event in stream { await recorder.append(event) } }
        let value = request(session)
        await service.submit(value)
        try #require(await waitUntil { superseded(value, in: await recorder.snapshot()) })
        let events = await recorder.snapshot()
        #expect(events.count == 1)
        collector.cancel()
    }
}

private actor SnapshotProvider {
    private var photo: PhotoSession
    private var calls = 0
    private var parked: CheckedContinuation<Void, Never>?
    init(_ photo: PhotoSession) { self.photo = photo }
    var isParked: Bool { parked != nil }
    func lookup(_ id: SessionID) async -> PhotoSession {
        calls += 1
        let snapshot = photo
        if calls == 2 { await withCheckedContinuation { parked = $0 } }
        return snapshot
    }
    func replaceDigest(_ digest: String) {
        photo = PhotoSession(id: photo.id, sourceURL: photo.sourceURL,
            displayName: photo.displayName, byteCount: photo.byteCount, sha256: digest, format: photo.format)
    }
    func release() { parked?.resume(); parked = nil }
}

extension PreviewServiceTests {
    @Test(.timeLimit(.minutes(1))) func olderSnapshotMustNotCancelANewerSourceRender() async throws {
        let frame = try await makeFrame()
        let original = FakeRenderer(frame: frame)
        let current = FakeRenderer(frame: frame, delay: .milliseconds(600))
        let photo = fakeSession()
        let provider = SnapshotProvider(photo)
        let factories = LockedCounter()
        let service = try PreviewService(schema: Engine.schema(), buildFingerprint: "review",
            knownModels: ["research-cnn-v1": true], previewMaxEdge: 2048,
            previewTimeout: .seconds(2), rawDecodeSlots: 1, rawDecodeTimeout: .seconds(1),
            cacheEntries: 2, cacheBytes: 4 << 20,
            sessionProvider: { id in await provider.lookup(id) },
            rendererFactory: { _ in
                factories.increment()
                if factories.value == 1 { return original }
                return current
            })
        _ = try await service.render(request(photo, contrast: 0.9))
        let recorder = EventRecorder()
        let stream = service.events(for: photo.id)
        let collector = Task { for await e in stream { await recorder.append(e) } }
        await provider.replaceDigest("B")
        let older = request(photo, contrast: 1.1)
        let newer = request(photo, contrast: 1.2)
        let oldTask = Task { await service.submit(older) }
        try #require(await waitUntil { await provider.isParked })
        await provider.replaceDigest("C")
        await service.submit(newer)
        try #require(await waitUntil { await current.calls == 1 })
        await provider.release()
        await oldTask.value
        try await Task.sleep(for: .milliseconds(700))
        let events = await recorder.snapshot()
        print("review stale snapshot: factories=\(factories.value), latest cancellations=\(await current.cancellations), latest finished=\(finished(newer, in: events) != nil), latest superseded=\(superseded(newer, in: events))")
        #expect(await current.cancellations == 0, "An older snapshot cancelled the current source's latest render")
        #expect(finished(newer, in: events)?.sourceDigest == "C")
        #expect(factories.value == 2, "Old lookup must not roll C back to B then forward again")
        collector.cancel()
        await service.detach(photo.id)
    }
}

extension PreviewServiceTests {
    @Test(.timeLimit(.minutes(1))) func replacementTerminatesBothRunningAndPendingSubmits() async throws {
        let frame = try await makeFrame()
        let original = FakeRenderer(frame: frame, delay: .milliseconds(600))
        let replacement = FakeRenderer(frame: frame)
        let photo = fakeSession()
        let provider = DigestProvider(photo)
        let factories = LockedCounter()
        let service = try PreviewService(schema: Engine.schema(), buildFingerprint: "test-build",
            knownModels: ["research-cnn-v1": true], previewMaxEdge: 2048,
            previewTimeout: .seconds(2), rawDecodeSlots: 1, rawDecodeTimeout: .seconds(1),
            cacheEntries: 2, cacheBytes: 4 << 20,
            sessionProvider: { id in await provider.session(id) },
            rendererFactory: { _ in
                factories.increment()
                return factories.value == 1 ? original : replacement
            })
        let recorder = EventRecorder()
        let stream = service.events(for: photo.id)
        let collector = Task { for await event in stream { await recorder.append(event) } }
        defer { collector.cancel() }
        let running = request(photo, contrast: 1.1)
        let pending = request(photo, contrast: 1.2)
        await service.submit(running)
        try #require(await waitUntil { await original.calls == 1 })
        await service.submit(pending)
        await provider.replaceDigest("new-source")
        // A direct reference render also replaces a changed source, and must
        // end both edit requests whose engine state is being discarded.
        var reference = request(photo, contrast: 0.9)
        reference.purpose = .reference
        let result = try await service.render(reference)
        #expect(result.sourceDigest == "new-source")
        try #require(await waitUntil {
            let events = await recorder.snapshot()
            return superseded(running, in: events) && superseded(pending, in: events)
        })
        let events = await recorder.snapshot()
        for request in [running, pending] {
            let terminals = events.filter {
                switch $0 {
                case .superseded(let value): value == request
                case .failed(let value, _): value == request
                case .finished(let value): value.request == request
                default: false
                }
            }
            #expect(terminals.count == 1, "every discarded request ends exactly once")
        }
        #expect(await original.cancellations == 1)
        await service.detach(photo.id)
    }
}

extension PreviewServiceTests {
    @Test func rawAndModelModePreviewsUseTheSameBudgetAndFailureReturnsTheSlot() async throws {
        let renderer = FakeRenderer(frame: try await makeFrame())
        let photo = fakeSession(.raw(".arw"))
        let service = try makeService(renderer, photo, rawTimeout: .milliseconds(20))
        try await service.attach(photo)
        let held = try await service.rawGate.acquire(timeout: .seconds(1))
        for modelMode in [false, true] {
            var value = request(photo)
            value.options["useModel"] = .bool(modelMode)
            do { _ = try await service.render(value); Issue.record("Expected shared raw_budget") }
            catch let error as HyperDRError { #expect(error.code == "raw_budget") }
        }
        #expect(await renderer.calls == 0)
        await held.release()
        await renderer.setFailure(HyperDRError(code: "decode_failed", message: "bad RAW"))
        do { _ = try await service.render(request(photo)); Issue.record("Expected decode_failed") }
        catch let error as HyperDRError { #expect(error.code == "decode_failed") }
        await renderer.setFailure(nil)
        let recovered = try await service.render(request(photo))
        #expect(!recovered.fromCache)
        #expect(await renderer.calls == 2, "The failed RAW render must return its gate ticket")
        await service.detach(photo.id)
    }
    @Test func changingTheEngineBuildFingerprintInvalidatesPreviewIdentity() throws {
        let photo = fakeSession()
        let resolver = OptionResolver(schema: try Engine.schema(), knownModels: [:], maxEdgeCeiling: 2048)
        let prepared = try resolver.resolve(request(photo), session: photo)
        let old = try PreviewCacheKey(session: photo, request: prepared, buildFingerprint: "engine-before")
        let new = try PreviewCacheKey(session: photo, request: prepared, buildFingerprint: "engine-after")
        #expect(old != new)
        #expect(old.sourceDigest == new.sourceDigest && old.requestJSON == new.requestJSON)
    }
}

extension PreviewServiceTests {
    @Test func degradedMetadataRetainsStatusAndReasons() async throws {
        let frame = try await makeFrame()
        var document = try #require(JSONSerialization.jsonObject(with: frame.metadataJSON) as? [String: Any])
        document["status"] = "degraded"
        document["degradationReasons"] = ["ultrahdr_decode_failed_sdr_fallback"] // E4r alias migration follows engine.
        let bytes = try JSONSerialization.data(withJSONObject: document)
        let decoded = try JSONDecoder().decode(PreviewMetadata.self, from: bytes)
        #expect(decoded.status == "degraded")
        #expect(decoded.degradationReasons == ["ultrahdr_decode_failed_sdr_fallback"])
        #expect(decoded.colorSpace == frame.metadata.colorSpace)
        #expect(decoded.width == frame.base.width && decoded.height == frame.base.height)
    }
}
