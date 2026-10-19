import Foundation
import HyperDRKit
import UniformTypeIdentifiers
import XCTest
@testable import HyperDR

@MainActor final class ScriptedEditorServices: EditorServices {
    var openClock: any EditorOpenClock = SystemEditorOpenClock.shared
    var openHandler: ((URL) async throws -> EditorPhoto)?
    var engineStatus: EngineStatus = .ready(version: "test")
    let displayState = DisplayState(screenName: "", currentHeadroom: 2, potentialHeadroom: 4, gainWeight: 1)
    let openableContentTypes: [UTType] = [.jpeg]
    let preferences: UserDefaults
    private let preferencesName: String
    var streams: [URL: AsyncStream<EditorPreviewEvent>.Continuation] = [:]
    var refresh: AsyncStream<EditorRefreshEvent>.Continuation?
    var closed: [EditorPhoto] = []
    var submitted: [EditOptions] = []
    var restoreWaiter: CheckedContinuation<RestoreResult, Never>?
    var startHandler: (() async -> Void)?
    var startsCompleted = 0
    var starts = 0
    var subscriptions = 0
    var usesRestoreGate = false
    var factsCalls = 0
    var usesFactsGate = false
    var factsWaiters: [URL: CheckedContinuation<CaptureFacts, Never>] = [:]

    init() { (preferences, preferencesName) = UserDefaults.ephemeral() }
    deinit { UserDefaults.standard.removePersistentDomain(forName: preferencesName) }
    func engineUpdates() -> AsyncStream<EngineStatus> { AsyncStream { $0.yield(engineStatus) } }
    func displayUpdates() -> AsyncStream<DisplayState> { AsyncStream { $0.yield(displayState) } }
    func start() async {
        starts += 1
        await startHandler?()
        startsCompleted += 1
    }
    func canOpen(_ url: URL) -> Bool { ["jpg", "ARW"].contains(url.pathExtension) }
    func placeholder(for url: URL) -> EditorPhoto {
        EditorPhoto(url: url, name: url.lastPathComponent, formatLabel: url.pathExtension == "ARW" ? "RAW" : "JPEG", byteCount: 1)
    }
    func open(_ url: URL) async throws -> EditorPhoto {
        if let openHandler { return try await openHandler(url) }
        return placeholder(for: url)
    }
    func restoreLast() async -> RestoreResult {
        guard usesRestoreGate else { return .none }
        return await withCheckedContinuation { restoreWaiter = $0 }
    }
    func previews(for photo: EditorPhoto, encoding: String, maxEdge: Int) -> AsyncStream<EditorPreviewEvent> {
        AsyncStream { streams[photo.url] = $0 }
    }
    func refreshes(for photo: EditorPhoto) -> AsyncStream<EditorRefreshEvent> {
        subscriptions += 1
        return AsyncStream { refresh = $0 }
    }
    func submit(_ photo: EditorPhoto, options: EditOptions, maxEdge: Int) {
        submitted.append(options)
    }
    func modelTable() -> ModelTable { .unavailable }
    func modelGainToken(for photo: EditorPhoto, options: EditOptions) async throws -> ModelGainToken {
        throw UserFacingError(code: "model_not_ready")
    }
    func computeModelGain(for photo: EditorPhoto, options: EditOptions) async throws -> ModelGainOutcome {
        throw UserFacingError(code: "model_not_ready")
    }
    func captureFacts(for photo: EditorPhoto) async -> CaptureFacts {
        factsCalls += 1
        guard usesFactsGate else { return CaptureFacts(model: "review-body") }
        return await withCheckedContinuation { factsWaiters[photo.url] = $0 }
    }
    func close(_ photo: EditorPhoto) async { closed.append(photo) }
}

@MainActor final class EditorFlowTests: XCTestCase {
    private let a = URL(fileURLWithPath: "/fixtures/a.jpg")
    private let b = URL(fileURLWithPath: "/fixtures/b.jpg")
    private let c = URL(fileURLWithPath: "/fixtures/c.jpg")
    private var preview: EditorPreview {
        EditorPreview(pixelSize: PixelSize(width: 6000, height: 4000),
            source: SourceSummary(domain: .hdr, colorName: "Display P3", degradationReasons: []), hasGain: true)
    }

    private func opened(_ model: EditorModel, _ service: ScriptedEditorServices, url: URL) async {
        model.open([url])
        await eventually { service.streams[url] != nil }
        service.streams[url]?.yield(.reference(preview))
        service.streams[url]?.yield(.edited(preview))
        await eventually { model.document?.phase == .ready }
    }

    func testReferenceThenFailureRollsBackCompletePreviousState() async {
        let services = ScriptedEditorServices()
        let model = EditorModel(services: services)
        await opened(model, services, url: a)
        let previous = model.document
        model.viewMode = .original
        model.open([b])
        XCTAssertEqual(model.document?.phase, .opening)
        XCTAssertTrue(model.hasEditedFrame)
        await eventually { services.streams[self.b] != nil }
        services.streams[b]?.yield(.reference(preview))
        await eventually { !model.hasEditedFrame }
        services.streams[b]?.yield(.failed(UserFacingError(code: "decode_failed")))
        await eventually { model.alert?.code == "decode_failed" }
        XCTAssertEqual(model.document, previous)
        XCTAssertEqual(model.viewMode, .original)
        XCTAssertTrue(model.hasEditedFrame)
        XCTAssertEqual(services.closed.map(\.url), [b])
        model.closeDocument()
    }

    func testReferenceThenFailureWithoutPreviousPhotoReturnsToEmpty() async {
        let services = ScriptedEditorServices()
        let model = EditorModel(services: services)
        model.open([a])
        await eventually { services.streams[self.a] != nil }
        services.streams[a]?.yield(.reference(preview))
        await eventually { model.hasReferenceFrame }
        services.streams[a]?.yield(.failed(UserFacingError(code: "decode_failed")))
        await eventually { model.alert != nil }
        XCTAssertNil(model.document)
        XCTAssertFalse(model.hasPreviewFrame)
    }

    func testSupersededOpenCannotPublishOrRollbackNewerOpen() async {
        let services = ScriptedEditorServices()
        let model = EditorModel(services: services)
        await opened(model, services, url: a)
        model.open([b])
        await eventually { services.streams[self.b] != nil }
        model.open([c])
        await eventually { services.streams[self.c] != nil }
        services.streams[b]?.yield(.failed(UserFacingError(code: "decode_failed")))
        services.streams[c]?.yield(.reference(preview))
        services.streams[c]?.yield(.edited(preview))
        await eventually { model.document?.phase == .ready }
        XCTAssertEqual(model.document?.name, "c.jpg")
        XCTAssertNil(model.alert)
        await eventually { services.closed.contains { $0.url == self.b } }
        model.closeDocument()
    }

    func testFinderOpenReplacesPendingRestoreAndClosesItsResult() async {
        let services = ScriptedEditorServices()
        services.usesRestoreGate = true
        let model = EditorModel(services: services)
        model.launch()
        await eventually { services.restoreWaiter != nil }
        await opened(model, services, url: b)
        services.restoreWaiter?.resume(returning: .restored(services.placeholder(for: a)))
        services.restoreWaiter = nil
        await eventually { services.closed.contains { $0.url == self.a } }
        XCTAssertEqual(model.document?.name, "b.jpg")
        model.launch()
        XCTAssertEqual(services.starts, 1)
        model.closeDocument()
    }

    func testThousandAdjustmentsUseFrameClockAndLastValueWins() async {
        let services = ScriptedEditorServices()
        let ticker = ManualFrameTicker()
        let model = EditorModel(services: services, ticker: ticker)
        await opened(model, services, url: a)
        for value in 1...1000 {
            model.adjust("brightness", to: Double(value) / 1000)
            if value % 20 == 0 {
                await eventually { ticker.isWaiting }
                ticker.tick()
                await settle()
            }
        }
        await eventually { services.submitted.last?["brightness"] == .number(1) }
        XCTAssertLessThanOrEqual(services.submitted.count, ticker.ticks + 1)
        services.refresh?.yield(.edited(preview, isLatest: true))
        await eventually { model.document?.isRefreshing == false }
        XCTAssertEqual(model.document?.pixelSize, PixelSize(width: 6000, height: 4000))
        model.closeDocument()
    }

    func testFramePreferencesAreInjectedAndIsolated() {
        let services = ScriptedEditorServices()
        var settings = FrameSettings()
        settings.isEnabled = true
        settings.signature = "Injected suite"
        settings.save(to: services.preferences)
        let model = EditorModel(services: services)
        XCTAssertEqual(model.frame, settings)
        model.frame.signature = "Changed"
        XCTAssertEqual(FrameSettings.load(from: services.preferences).signature, "Changed")
        let independent = EditorModel(services: ScriptedEditorServices())
        XCTAssertEqual(independent.frame.signature, "")
    }

    func testImportFailureAndCancellationMapping() {
        let model = EditorModel(services: ScriptedEditorServices())
        model.report(openFailure: CocoaError(.fileReadNoPermission))
        XCTAssertEqual(model.alert?.code, "source_unreadable")
        model.report(openFailure: CancellationError())
        XCTAssertNil(model.alert)
        XCTAssertEqual(UserFacingError.service(CancellationError()).code, "cancelled")
    }
}

extension EditorFlowTests {
    func testReviewExplicitOpenBeforeLaunchMustWinOverRestore() async {
        let services = ScriptedEditorServices()
        services.usesRestoreGate = true
        let model = EditorModel(services: services)
        model.open([b])
        await eventually { services.streams[self.b] != nil }
        model.launch()
        await eventually { services.starts == 1 }
        XCTAssertNil(services.restoreWaiter, "Explicit open must disable launch restoration")
        await settle(100)
        print("review prelaunch open: displayed=\(model.document?.name ?? "nil")")
        XCTAssertEqual(model.document?.name, "b.jpg", "Launch restore replaced an explicit Finder open")
        model.closeDocument()
    }

    func testReviewRollbackMustResubmitPendingAdjustment() async {
        let services = ScriptedEditorServices()
        let ticker = ManualFrameTicker()
        let model = EditorModel(services: services, ticker: ticker)
        await opened(model, services, url: a)
        model.adjust("brightness", to: 0.7)
        await eventually { ticker.isWaiting }
        model.open([b])
        await eventually { services.streams[self.b] != nil }
        services.streams[b]?.yield(.reference(preview))
        services.streams[b]?.yield(.failed(UserFacingError(code: "decode_failed")))
        await eventually { model.alert != nil }
        ticker.tick()
        await settle(100)
        // Repeating the same value is normally a no-op, so it cannot repair
        // the mismatch if rollback discarded the only dirty slot.
        model.adjust("brightness", to: 0.7)
        ticker.tick()
        await settle(100)
        print("review rollback pending: submitted=\(services.submitted), refreshing=\(String(describing: model.document?.isRefreshing))")
        XCTAssertEqual(services.submitted.last?["brightness"], .number(0.7))
        model.closeDocument()
    }

    func testReviewRollbackMustRestorePan() async {
        let services = ScriptedEditorServices()
        let model = EditorModel(services: services)
        await opened(model, services, url: a)
        model.canvas.setViewport(CGSize(width: 1000, height: 800), backingScale: 2)
        var transform = model.canvas.transform
        transform.zoom = 2
        transform.pan = CGPoint(x: 120, y: 90)
        model.canvas.apply(transform)
        let previousFrame = model.canvas.imageFrame
        model.open([b])
        await eventually { services.streams[self.b] != nil }
        services.streams[b]?.yield(.reference(preview))
        services.streams[b]?.yield(.failed(UserFacingError(code: "decode_failed")))
        await eventually { model.alert != nil }
        print("review rollback pan: old=\(transform.pan), new=\(model.canvas.transform.pan)")
        XCTAssertEqual(model.canvas.transform.pan, transform.pan)
        XCTAssertEqual(model.canvas.imageFrame, previousFrame)
        model.closeDocument()
    }

    func testReviewRefreshStreamTerminationMustClearBusyState() async {
        let services = ScriptedEditorServices()
        let ticker = ManualFrameTicker()
        let model = EditorModel(services: services, ticker: ticker)
        await opened(model, services, url: a)
        model.adjust("brightness", to: 0.7)
        await eventually { ticker.isWaiting }
        ticker.tick()
        await eventually { !services.submitted.isEmpty }
        services.refresh?.finish()
        await settle(100)
        print("review refresh stream closed: refreshing=\(String(describing: model.document?.isRefreshing))")
        XCTAssertFalse(model.document?.isRefreshing ?? true)
        model.closeDocument()
    }
}

import Observation
private final class ReviewObservationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}

extension EditorFlowTests {
    func testReviewSliderUpdatesDoNotInvalidateTheDocumentAtInputRate() async {
        let services = ScriptedEditorServices()
        let ticker = ManualFrameTicker()
        let model = EditorModel(services: services, ticker: ticker)
        await opened(model, services, url: a)
        let changes = ReviewObservationCounter()
        for i in 1...100 {
            withObservationTracking { _ = model.document } onChange: { changes.increment() }
            model.adjust("brightness", to: Double(i) / 100)
        }
        print("review slider observation: 100 changes, document notifications=\(changes.value), submitted=\(services.submitted.count)")
        XCTAssertLessThanOrEqual(changes.value, 1, "Only the first isRefreshing transition should invalidate document observers")
        model.closeDocument()
    }
}


extension EditorFlowTests {
    func testRollbackResubmitsAnAdjustmentAlreadyInFlight() async {
        let services = ScriptedEditorServices()
        let ticker = ManualFrameTicker()
        let model = EditorModel(services: services, ticker: ticker)
        await opened(model, services, url: a)
        model.adjust("brightness", to: 0.7)
        await eventually { ticker.isWaiting }
        ticker.tick()
        await eventually { services.submitted.count == 1 }
        model.open([b])
        await eventually { services.streams[self.b] != nil }
        services.streams[b]?.yield(.reference(preview))
        services.streams[b]?.yield(.failed(UserFacingError(code: "decode_failed")))
        await eventually { model.alert != nil }
        await eventually { ticker.isWaiting }
        ticker.tick()
        await eventually { services.submitted.count == 2 }
        XCTAssertEqual(services.submitted.last?["brightness"], .number(0.7))
        await eventually(timeout: .seconds(2)) { model.document?.isRefreshing == true }
        services.refresh?.yield(.edited(preview, isLatest: true))
        await eventually { model.document?.isRefreshing == false }
        model.closeDocument()
    }

    func testSupersededOnlyFinishesLatestAndResubscribes() async {
        let services = ScriptedEditorServices()
        let ticker = ManualFrameTicker()
        let model = EditorModel(services: services, ticker: ticker)
        await opened(model, services, url: a)
        model.adjust("brightness", to: 0.7)
        await eventually { ticker.isWaiting }
        ticker.tick()
        await eventually { services.submitted.count == 1 }
        services.refresh?.yield(.superseded(isLatest: false))
        await settle(100)
        await eventually(timeout: .seconds(2)) { model.document?.isRefreshing == true }
        XCTAssertEqual(services.subscriptions, 1)
        services.refresh?.yield(.superseded(isLatest: true))
        await eventually { model.document?.isRefreshing == false && services.subscriptions == 2 }
        model.adjust("brightness", to: 0.8)
        await eventually { ticker.isWaiting }
        ticker.tick()
        await eventually { services.submitted.count == 2 }
        services.refresh?.yield(.edited(preview, isLatest: true))
        await eventually { model.document?.isRefreshing == false }
        model.closeDocument()
    }

    func testStreamReattachesAndCanFinishTheNextEdit() async {
        let services = ScriptedEditorServices()
        let ticker = ManualFrameTicker()
        let model = EditorModel(services: services, ticker: ticker)
        await opened(model, services, url: a)
        model.adjust("brightness", to: 0.7)
        await eventually { ticker.isWaiting }
        ticker.tick()
        await eventually { services.submitted.count == 1 }
        services.refresh?.finish()
        await eventually { model.document?.isRefreshing == false && services.subscriptions == 2 }
        model.adjust("brightness", to: 0.8)
        await eventually { ticker.isWaiting }
        ticker.tick()
        await eventually { services.submitted.count == 2 }
        services.refresh?.yield(.edited(preview, isLatest: true))
        await eventually { model.document?.isRefreshing == false }
        model.closeDocument()
    }
}

extension EditorFlowTests {
    func testOpenCommitLoadsCaptureFactsWithoutOpeningTheSheet() async {
        let services = ScriptedEditorServices()
        let model = EditorModel(services: services)
        await opened(model, services, url: a)
        await eventually { model.captureFacts.model == "review-body" }
        XCTAssertEqual(services.factsCalls, 1)
        model.closeDocument()
    }

    func testOlderCaptureFactsCannotOverwriteNewPhotoOrClosedDocument() async {
        let services = ScriptedEditorServices()
        services.usesFactsGate = true
        let model = EditorModel(services: services)
        await opened(model, services, url: a)
        await eventually { services.factsWaiters[self.a] != nil }
        await opened(model, services, url: b)
        await eventually { services.factsWaiters[self.b] != nil }
        services.factsWaiters.removeValue(forKey: b)?.resume(returning: CaptureFacts(model: "B"))
        await eventually { model.captureFacts.model == "B" }
        services.factsWaiters.removeValue(forKey: a)?.resume(returning: CaptureFacts(model: "A"))
        await settle()
        XCTAssertEqual(model.captureFacts.model, "B")
        await opened(model, services, url: c)
        await eventually { services.factsWaiters[self.c] != nil }
        model.closeDocument()
        services.factsWaiters.removeValue(forKey: c)?.resume(returning: CaptureFacts(model: "C"))
        await settle()
        XCTAssertEqual(model.captureFacts, CaptureFacts())
    }
}

extension EditorFlowTests {
    func testOpenCommandIsLockedWhileRestoreWaitsButFinderCanReplaceIt() async {
        let services = ScriptedEditorServices()
        services.usesRestoreGate = true
        let model = EditorModel(services:services)
        model.launch()
        XCTAssertFalse(model.canOpenDocument)
        await eventually(timeout:.seconds(2)) { services.restoreWaiter != nil }
        XCTAssertTrue(model.isRestoring)
        XCTAssertFalse(model.canOpenDocument)
        await opened(model,services,url:b)
        XCTAssertFalse(model.isRestoring)
        XCTAssertTrue(model.canOpenDocument)
        services.restoreWaiter?.resume(returning:.restored(services.placeholder(for:a)))
        services.restoreWaiter = nil
        await eventually(timeout:.seconds(2)) { services.closed.contains { $0.url == self.a } }
        XCTAssertEqual(model.document?.name,"b.jpg")
        model.closeDocument()
    }
}

extension EditorFlowTests {
    func testReviewerOpeningCommandIsLockedWhileRestorationIsSuspended() async {
        let services = ScriptedEditorServices()
        services.usesRestoreGate = true
        let model = EditorModel(services: services)
        model.launch()
        await eventually(timeout: .seconds(3)) { services.restoreWaiter != nil }
        XCTAssertTrue(model.isEditingLocked)
        XCTAssertFalse(model.canOpenDocument, "§2.12 restore must disable the Open command before the photo exists")
        services.restoreWaiter?.resume(returning: .none)
        services.restoreWaiter = nil
        model.closeDocument()
    }
}

extension EditorFlowTests {
    func testEachCommittedPhotoBumpsThePhotoSerialEvenWithTheSameName() async {
        let services = ScriptedEditorServices()
        let model = EditorModel(services: services)
        let other = URL(fileURLWithPath: "/elsewhere/a.jpg")
        XCTAssertEqual(model.photoSerial, 0)
        await opened(model, services, url: a)
        XCTAssertEqual(model.photoSerial, 1)
        let hintBefore = model.viewerHintKey
        await opened(model, services, url: other)
        XCTAssertEqual(model.photoSerial, 2)
        XCTAssertEqual(model.document?.name, "a.jpg")
        XCTAssertEqual(model.viewerHintKey, hintBefore, "the key alone cannot tell the two photos apart")
        model.closeDocument()
    }
}
