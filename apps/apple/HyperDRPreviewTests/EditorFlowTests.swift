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
    let scripted = ScriptedRendering()
    var rendering: any EditorRendering { scripted }
    var closed: [EditorPhoto] = []
    var restoreWaiter: CheckedContinuation<RestoreResult, Never>?
    var startHandler: (() async -> Void)?
    var startsCompleted = 0
    var starts = 0
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
    func captureFacts(for photo: EditorPhoto) async -> CaptureFacts {
        factsCalls += 1
        guard usesFactsGate else { return CaptureFacts(model: "review-body") }
        return await withCheckedContinuation { factsWaiters[photo.url] = $0 }
    }
    func close(_ photo: EditorPhoto) async { closed.append(photo) }
    func lutCube(_ id: String) async throws -> String { throw CocoaError(.fileNoSuchFile) }
    var relinkHandler: ((URL) async throws -> EditorPhoto)?
    func relink(_ photo: EditorPhoto, to url: URL) async throws -> EditorPhoto {
        guard let relinkHandler else { throw UserFacingError(code: "source_different") }
        return try await relinkHandler(url)
    }
}

/// Opens `url` and waits until its first frame is on the canvas.
@MainActor func openReady(_ model: EditorModel, _ url: URL, file: StaticString = #filePath, line: UInt = #line) async {
    let serial = model.photoSerial
    model.open([url])
    await eventually(timeout: .seconds(5), "\(url.lastPathComponent) to be ready", file: file, line: line) {
        model.photoSerial > serial && model.document?.phase == .ready && model.hasReferenceFrame
    }
}

@MainActor final class EditorFlowTests: XCTestCase {
    private let a = URL(fileURLWithPath: "/fixtures/a.jpg")
    private let b = URL(fileURLWithPath: "/fixtures/b.jpg")
    private let c = URL(fileURLWithPath: "/fixtures/c.jpg")

    private func opened(_ model: EditorModel, _ service: ScriptedEditorServices, url: URL) async {
        await openReady(model, url)
    }

    private func exposure(_ value: Double, _ model: EditorModel) {
        var recipe = model.editor.recipe
        recipe.setValue(.number(value), for: "tone.exposure")
        model.editor.setRecipe(recipe)
    }

    func testFirstRenderFailureRollsBackCompletePreviousState() async {
        let services = ScriptedEditorServices()
        let model = EditorModel(services: services)
        await opened(model, services, url: a)
        let previous = model.document
        model.viewMode = .original
        services.scripted.failRenders(of: b, with: UserFacingError(code: "decode_failed"))
        model.open([b])
        XCTAssertEqual(model.document?.phase, .opening)
        XCTAssertTrue(model.hasEditedFrame, "the previous frames stay up while the new photo opens")
        await eventually { model.alert != nil }
        XCTAssertEqual(model.alert?.code, "decode_failed")
        XCTAssertEqual(model.document, previous)
        XCTAssertEqual(model.viewMode, .original)
        XCTAssertTrue(model.hasEditedFrame)
        XCTAssertEqual(services.closed.map(\.url), [b])
        // The editor holds the previous photo again, and its frames show.
        await eventually { model.editor.source?.url == self.a && model.committedSource == model.editor.source?.id }
        model.closeDocument()
    }

    func testOpenFailureWithoutPreviousPhotoReturnsToEmpty() async {
        let services = ScriptedEditorServices()
        let model = EditorModel(services: services)
        services.scripted.failOpen(a, with: UserFacingError(code: "source_unreadable"))
        model.open([a])
        await eventually { model.alert != nil }
        XCTAssertEqual(model.alert?.code, "source_unreadable")
        XCTAssertNil(model.document)
        XCTAssertFalse(model.hasPreviewFrame)
    }

    func testSupersededOpenCannotPublishOrRollbackNewerOpen() async {
        let services = ScriptedEditorServices()
        let model = EditorModel(services: services)
        await opened(model, services, url: a)
        services.scripted.failRenders(of: b, with: UserFacingError(code: "decode_failed"))
        model.open([b])
        await openReady(model, c)
        await settle(100)
        XCTAssertEqual(model.document?.name, "c.jpg")
        XCTAssertNil(model.alert)
        XCTAssertEqual(model.editor.source?.url, c)
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

    /// The editor submits at most one render per frame, the newest recipe.
    func testThousandEditsUseTheFrameClockAndTheLastValueWins() async {
        let services = ScriptedEditorServices()
        let ticker = ManualFrameTicker()
        let model = EditorModel(services: services, frameClock: ticker)
        model.open([a])
        await eventually { ticker.isWaiting }
        ticker.tick()
        await eventually { model.document?.phase == .ready }
        let before = await services.scripted.fake.requests.count
        let ticksBefore = ticker.ticks
        for value in 1...1000 {
            exposure(Double(value) / 1000, model)
            if value % 20 == 0 {
                await eventually { ticker.isWaiting }
                ticker.tick()
                await settle()
            }
        }
        for _ in 0..<20 where model.editor.frame?.request.recipe != model.editor.recipe {
            if ticker.isWaiting { ticker.tick() }
            await settle(5)
        }
        let scope = EditorModel.scopeSize(model.editor.source!.pixelSize)
        let edits = await services.scripted.fake.requests.dropFirst(before)
            .filter { $0.region == nil && $0.size != scope && $0.recipe.value(for: "tone.exposure") != nil }
        XCTAssertLessThanOrEqual(edits.count, ticker.ticks - ticksBefore + 1)
        XCTAssertEqual(edits.last?.recipe.value(for: "tone.exposure"), .number(1))
        await eventually { model.document?.isRefreshing == false }
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
        model.launch()
        await eventually { services.starts == 1 }
        XCTAssertNil(services.restoreWaiter, "Explicit open must disable launch restoration")
        await settle(100)
        XCTAssertEqual(model.document?.name, "b.jpg", "Launch restore replaced an explicit Finder open")
        model.closeDocument()
    }

    /// A rollback puts the previous photo back in the editor with its recipe,
    /// but not its undo steps once the new photo had opened.
    func testRollbackKeepsThePreviousRecipeAndRendersIt() async {
        let services = ScriptedEditorServices()
        let model = EditorModel(services: services)
        await opened(model, services, url: a)
        exposure(0.7, model)
        await model.editor.settle()
        services.scripted.failRenders(of: b, with: UserFacingError(code: "decode_failed"))
        model.open([b])
        await eventually { model.alert != nil }
        await eventually { model.editor.source?.url == self.a && model.editor.recipe.value(for: "tone.exposure") == .number(0.7) }
        await model.editor.settle()
        XCTAssertEqual(model.editor.frame?.request.recipe.value(for: "tone.exposure"), .number(0.7))
        // b did open before its first frame failed, so a's steps went (R27-001).
        XCTAssertFalse(model.canUndo)
        model.closeDocument()
    }

    /// A photo that cannot be opened leaves the open photo's undo steps.
    func testAPhotoThatFailsToOpenKeepsTheUndoSteps() async {
        let services = ScriptedEditorServices()
        let model = EditorModel(services: services)
        await opened(model, services, url: a)
        exposure(0.7, model)
        await model.editor.settle()
        services.scripted.failOpen(b, with: UserFacingError(code: "decode_failed"))
        model.open([b])
        await eventually { model.alert != nil && model.document?.phase == .ready }
        XCTAssertTrue(model.canUndo)
        model.undo()
        XCTAssertTrue(model.editor.recipe.isDefault("tone.exposure"))
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
        services.scripted.failRenders(of: b, with: UserFacingError(code: "decode_failed"))
        model.open([b])
        await eventually { model.alert != nil }
        XCTAssertEqual(model.canvas.transform.pan, transform.pan)
        XCTAssertEqual(model.canvas.imageFrame, previousFrame)
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
        let model = EditorModel(services: services, frameClock: ticker)
        model.open([a])
        await eventually { ticker.isWaiting }
        ticker.tick()
        await eventually { model.document?.phase == .ready }
        let changes = ReviewObservationCounter()
        for i in 1...100 {
            withObservationTracking { _ = model.document } onChange: { changes.increment() }
            exposure(Double(i) / 100, model)
            await settle(2)
        }
        XCTAssertLessThanOrEqual(changes.value, 1, "Only the first isRefreshing transition should invalidate document observers")
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
