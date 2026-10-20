import Foundation
import Observation
import Synchronization
import HyperDREngine
import XCTest
@testable import HyperDR

/// Deliberately ignores cancellation: generation checks must reject late clocks.
@MainActor private final class ManualOpenClock: EditorOpenClock {
    var now: Duration = .zero
    private(set) var deadlines: [Duration] = []
    private(set) var resumed = 0
    private var waiters: [(Duration, CheckedContinuation<Void, Never>)] = []
    func sleep(until deadline: Duration) async throws {
        deadlines.append(deadline)
        if now >= deadline { return }
        await withCheckedContinuation { waiters.append((deadline, $0)) }
        resumed += 1
    }
    func advance(to instant: Duration) {
        now = instant
        let ready = waiters.filter { $0.0 <= now }
        waiters.removeAll { $0.0 <= now }
        for (_, waiter) in ready { waiter.resume() }
    }
    func finish() { advance(to: .seconds(1000)) }
}

@MainActor final class RawOpeningTests: XCTestCase {
    private let raw = URL(fileURLWithPath: "/fixtures/one.ARW")
    private let next = URL(fileURLWithPath: "/fixtures/two.ARW")
    private let jpeg = URL(fileURLWithPath: "/fixtures/old.jpg")
    /// Opens `url` with the renderer letting it through, then holds later opens again.
    private func ready(_ model: EditorModel, _ services: ScriptedEditorServices, _ url: URL) async {
        let holds = services.scripted.holdsOpens
        services.scripted.releaseOpens()
        await openReady(model, url)
        services.scripted.holdsOpens = holds
    }
    /// Script services whose renderer holds every open until released.
    private func holding(_ clock: ManualOpenClock? = nil) -> ScriptedEditorServices {
        let services = ScriptedEditorServices()
        if let clock { services.openClock = clock }
        services.scripted.holdsOpens = true
        return services
    }

    func testDeadlineAndReferenceHandoff() async {
        let clock = ManualOpenClock(); defer { clock.finish() }
        let services = holding(clock)
        let model = EditorModel(services: services)
        let availabilityChanges = Mutex(0)
        withObservationTracking { _ = model.canCancelOpen } onChange: { availabilityChanges.withLock { $0 += 1 } }
        model.open([raw])
        XCTAssertEqual(availabilityChanges.withLock { $0 }, 1)
        await eventually(timeout: .seconds(3)) { clock.deadlines.count == 1 && services.scripted.isHoldingOpen(self.raw) }
        XCTAssertEqual(clock.deadlines, [.milliseconds(1500)])
        clock.advance(to: .milliseconds(1499))
        XCTAssertEqual(model.document?.isPreparingCameraSupport, false)
        XCTAssertEqual(model.document?.phase, .opening)
        clock.advance(to: .milliseconds(1500))
        await eventually(timeout: .seconds(3)) { model.document?.isPreparingCameraSupport == true }
        XCTAssertTrue(model.canCancelOpen)
        withObservationTracking { _ = model.canCancelOpen } onChange: { availabilityChanges.withLock { $0 += 1 } }
        services.scripted.releaseOpens()
        await eventually(timeout: .seconds(3)) { model.document?.phase == .ready }
        XCTAssertEqual(model.document?.isPreparingCameraSupport, false)
        XCTAssertFalse(model.canCancelOpen)
        XCTAssertEqual(availabilityChanges.withLock { $0 }, 2)
    }

    func testCancelRestoresPhotoTransformAndClosesCandidateWithoutAlert() async {
        let clock = ManualOpenClock(); defer { clock.finish() }
        let services = holding(clock)
        let model = EditorModel(services: services)
        await ready(model, services, jpeg)
        model.updateViewport(CGSize(width: 100, height: 100), backingScale: 2)
        model.canvas.zoomIn(); model.viewMode = .compare
        let oldDocument = model.document, transform = model.canvas.transform
        model.open([raw])
        await eventually(timeout: .seconds(3)) { services.scripted.isHoldingOpen(self.raw) }
        model.cancelOpen()
        XCTAssertEqual(model.document, oldDocument)
        XCTAssertEqual(model.canvas.transform, transform)
        XCTAssertEqual(model.viewMode, .compare)
        XCTAssertNil(model.alert)
        XCTAssertFalse(model.canCancelOpen)
        XCTAssertTrue(model.canOpenDocument)
        await eventually(timeout: .seconds(3)) { services.closed.contains { $0.url == self.raw } }
        XCTAssertFalse(services.closed.contains { $0.url == jpeg })
    }

    func testCancelDoesNotWaitForNativeOpenAndLateCandidateCloses() async {
        let clock = ManualOpenClock(); defer { clock.finish() }
        let services = holding(clock)
        var gate: CheckedContinuation<EditorPhoto, Never>?
        services.openHandler = { _ in await withCheckedContinuation { gate = $0 } }
        let model = EditorModel(services: services)
        model.open([raw])
        await eventually(timeout: .seconds(3)) { gate != nil && !clock.deadlines.isEmpty }
        clock.advance(to: .milliseconds(1500))
        await eventually(timeout: .seconds(3)) { model.document?.isPreparingCameraSupport == true }
        model.cancelOpen()
        XCTAssertNil(model.document); XCTAssertEqual(model.workspace, .empty)
        XCTAssertNil(model.alert); XCTAssertTrue(model.canOpenDocument)
        services.openHandler = nil
        await ready(model, services, next)
        gate?.resume(returning: services.placeholder(for: raw)); gate = nil
        await eventually(timeout: .seconds(3)) { services.closed.contains { $0.url == self.raw } }
        XCTAssertEqual(model.document?.name, next.lastPathComponent)
        XCTAssertEqual(model.document?.phase, .ready)
        XCTAssertNil(model.alert)
    }

    func testNonRawAndObsoleteDeadlineNeverPublish() async {
        let clock = ManualOpenClock(); defer { clock.finish() }
        let services = holding(clock)
        let model = EditorModel(services: services)
        model.open([raw])
        await eventually(timeout: .seconds(3)) { clock.deadlines.count == 1 }
        await ready(model, services, jpeg)
        clock.advance(to: .seconds(3))
        // A due second RAW deadline is an explicit drain barrier for the first.
        model.open([next])
        await eventually(timeout: .seconds(3)) { clock.deadlines.count == 3 && clock.resumed == 2 }
        XCTAssertEqual(model.document?.isPreparingCameraSupport, false)
        await eventually(timeout: .seconds(3)) { services.scripted.isHoldingOpen(self.next) }
        model.cancelOpen()
        clock.advance(to: .seconds(5))
        await eventually(timeout: .seconds(3)) { services.closed.contains { $0.url == self.next } }
        XCTAssertEqual(model.document?.formatLabel, "JPEG")
        XCTAssertEqual(model.document?.isPreparingCameraSupport, false)
    }

    func testFrameBeforeDeadlineAndNonRawNeverShowPreparation() async {
        let clock = ManualOpenClock(); defer { clock.finish() }
        let services = holding(clock)
        let model = EditorModel(services: services)
        model.open([raw])
        await eventually(timeout: .seconds(3)) { clock.deadlines.count == 1 && services.scripted.isHoldingOpen(self.raw) }
        services.scripted.releaseOpens()
        await eventually(timeout: .seconds(3)) { model.document?.phase == .ready }
        clock.advance(to: .seconds(2))
        await eventually(timeout: .seconds(3)) { clock.resumed == 1 }
        XCTAssertEqual(model.document?.isPreparingCameraSupport, false)
        services.scripted.holdsOpens = true
        model.open([jpeg])
        await eventually(timeout: .seconds(3)) { services.scripted.isHoldingOpen(self.jpeg) }
        clock.advance(to: .seconds(10))
        XCTAssertEqual(clock.deadlines.count, 2, "A non-RAW open shares the 1.5 s deadline")
        await eventually(timeout: .seconds(3)) { model.document?.isOpeningSlowly == true }
        XCTAssertEqual(model.document?.isPreparingCameraSupport, false, "…but it is never 'camera support'")
        model.cancelOpen()
    }

    func testFailureAfterDeadlineClearsPreparationAndRollsBack() async {
        let clock = ManualOpenClock(); defer { clock.finish() }
        let services = holding(clock)
        let model = EditorModel(services: services)
        model.open([raw])
        await eventually(timeout: .seconds(3)) { clock.deadlines.count == 1 && services.scripted.isHoldingOpen(self.raw) }
        clock.advance(to: .seconds(2))
        await eventually(timeout: .seconds(3)) { model.document?.isPreparingCameraSupport == true }
        services.scripted.failOpen(raw, with: UserFacingError(code: "raw_unsupported", variant: "camera"))
        services.scripted.releaseOpens()
        await eventually(timeout: .seconds(3)) { model.alert != nil }
        XCTAssertNil(model.document); XCTAssertFalse(model.canCancelOpen)
        XCTAssertEqual(model.alert?.code, "raw_unsupported")
        await ready(model, services, jpeg)
        XCTAssertNil(model.alert); XCTAssertEqual(model.document?.isPreparingCameraSupport, false)
    }

    func testPreviewMetadataPreservesRawCapabilitiesForTheEditor() throws {
        let json = Data(#"""
        {"schema":"hyperdr.native-preview/v1","width":4,"height":2,"channels":4,
         "layout":"rgba","sampleType":"float32","colorSpace":"linear-display-p3",
         "relativeSdrWhite":1,"headroomStops":0,"inputDomain":"scene-referred","status":"ok",
         "sourceColor":{"name":"Display P3","primaries":"p3","transfer":"linear","source":"raw"},
         "degradationReasons":[],
         "hasCaptureMetadata":true,"inputHeadroomStops":0,
         "raw":{"supported":true,"lensCorrectionSupported":false,"decoderVersion":"8.dng","osBuild":"engine-build"}}
        """#.utf8)
        let metadata = try JSONDecoder().decode(PreviewMetadata.self, from: json)
        let summary = SourceSummary(metadata)
        XCTAssertEqual(summary.raw, RawCapabilities(supported: true, lensCorrectionSupported: false,
            decoderVersion: "8.dng", osBuild: "engine-build"))
        XCTAssertEqual(summary.domain, .sceneReferred)
        XCTAssertEqual(summary.colorSource, "raw")
    }

    func testCancelWhileLaunchRestoreIsStillSuspended() async {
        let services = holding(); services.usesRestoreGate = true
        let model = EditorModel(services: services)
        model.launch()
        await eventually(timeout: .seconds(3)) { services.restoreWaiter != nil }
        XCTAssertTrue(model.isRestoring)
        XCTAssertTrue(model.canCancelOpen)
        model.cancelOpen()
        XCTAssertFalse(model.isRestoring)
        XCTAssertFalse(model.canCancelOpen)
        XCTAssertTrue(model.canOpenDocument)
        XCTAssertNil(model.document); XCTAssertNil(model.alert)
        services.restoreWaiter?.resume(returning: .restored(services.placeholder(for: raw)))
        services.restoreWaiter = nil
        await eventually(timeout: .seconds(3)) { services.closed.contains { $0.url == self.raw } }
        let opened = await services.scripted.fake.opened
        XCTAssertFalse(opened.contains(raw), "the renderer never opened it")
        XCTAssertNil(model.document); XCTAssertNil(model.alert)
    }

    func testCancelRestoreAllowsImmediateOpenAndClosesLateCandidate() async {
        let clock = ManualOpenClock(); defer { clock.finish() }
        let services = holding(clock); services.usesRestoreGate = true
        let model = EditorModel(services: services)
        model.launch()
        await eventually(timeout: .seconds(3)) { services.restoreWaiter != nil && clock.deadlines.count == 1 }
        model.cancelOpen()
        await ready(model, services, jpeg)
        let current = model.document
        services.restoreWaiter?.resume(returning: .restored(services.placeholder(for: raw)))
        services.restoreWaiter = nil
        await eventually(timeout: .seconds(3)) { services.closed.contains { $0.url == self.raw } }
        clock.advance(to: .seconds(2))
        await eventually(timeout: .seconds(3)) { clock.resumed == 2 }
        XCTAssertEqual(model.document, current)
        XCTAssertFalse(model.canCancelOpen)
        XCTAssertFalse(model.isRestoring)
        let opened = await services.scripted.fake.opened
        XCTAssertFalse(opened.contains(raw)); XCTAssertNil(model.alert)
        XCTAssertFalse(services.closed.contains { $0.url == self.jpeg })
    }

    func testCancelWhileStartupIsSuspendedSkipsRestoreAndAllowsOpen() async {
        let services = holding(); services.usesRestoreGate = true
        var startWaiter: CheckedContinuation<Void, Never>?
        services.startHandler = { await withCheckedContinuation { startWaiter = $0 } }
        let model = EditorModel(services: services)
        model.launch()
        await eventually(timeout: .seconds(3)) { startWaiter != nil }
        XCTAssertTrue(model.canCancelOpen)
        model.cancelOpen()
        XCTAssertTrue(model.canOpenDocument)
        await ready(model, services, jpeg)
        let current = model.document
        // The gate ignores cancellation. The post-start generation guard runs
        // on this actor before the completion counter can be observed here.
        startWaiter?.resume(); startWaiter = nil
        await eventually(timeout: .seconds(3)) { services.startsCompleted == 1 }
        model.launch()
        XCTAssertEqual(services.starts, 1)
        XCTAssertNil(services.restoreWaiter)
        XCTAssertEqual(model.document, current)
        XCTAssertFalse(model.isRestoring); XCTAssertNil(model.alert)
    }

    func testLaunchRestoreUsesOpeningDeadline() async {
        let clock = ManualOpenClock(); defer { clock.finish() }
        let services = holding(clock); services.usesRestoreGate = true
        let model = EditorModel(services: services)
        model.launch()
        await eventually(timeout: .seconds(3)) { services.restoreWaiter != nil && clock.deadlines.count == 1 }
        XCTAssertNil(model.document, "Unknown restore format must not publish a RAW placeholder")
        clock.advance(to: .seconds(2))
        services.restoreWaiter?.resume(returning: .restored(services.placeholder(for: raw))); services.restoreWaiter = nil
        await eventually(timeout: .seconds(3)) { model.document?.isPreparingCameraSupport == true }
        XCTAssertEqual(clock.deadlines, [.milliseconds(1500)])
        model.cancelOpen()
        XCTAssertNil(model.document); XCTAssertNil(model.alert)
    }

    func testStructuredUnsupportedVariantsAndUnreadableRemainDistinct() {
        for container in ["camera", "dng"] {
            for model in ["", "SONY ILCE-9M3"] {
                let error = UserFacingError(HyperDRError(code: "raw_unsupported", message: "unrelated wording", detail:
                    .object(["container": .string(container), "model": .string(model)])))
                XCTAssertEqual(error.variant, container)
                XCTAssertEqual(error.detail, model.isEmpty ? nil : model)
            }
        }
        for detail: JSONValue? in [nil, .string("dng"), .object(["container": .string("unknown"), "model": .string("ignored")])] {
            let error = UserFacingError(HyperDRError(code: "raw_unsupported", message: "DNG camera", detail: detail))
            XCTAssertEqual(error.variant, "camera"); XCTAssertNil(error.detail)
        }
        let unreadable = UserFacingError(HyperDRError(code: "source_unreadable", message: "unreadable DNG"))
        XCTAssertEqual(unreadable.code, "source_unreadable"); XCTAssertNil(unreadable.variant)
    }

    func testExportOutcomeKeepsCameraModelSeparateFromLogText() {
        let model = EditorModel()
        model.export.lastLine = "Failed to export unsupported RAW"
        model.finishExport(result: nil,
            failure: UserFacingError(code: "raw_unsupported", detail: "SONY", variant: "camera"),
            snapshot: model.exportChoices, framed: false)
        XCTAssertEqual(model.export.failure?.detail, "SONY")
        XCTAssertEqual(model.export.failure?.variant, "camera")
        XCTAssertEqual(model.export.failure?.messageVariantKey, "err.server.raw_unsupported.model %@")
    }

    func testDiagnosticsUsesEngineOSBuild() async {
        let source = SourceSummary(domain: .sceneReferred, colorName: "P3", degradationReasons: [], raw:
            RawCapabilities(supported: true, lensCorrectionSupported: true, decoderVersion: "8.dng", osBuild: "engine-build-sentinel"))
        let document = DocumentState(name: "raw", formatLabel: "RAW", byteCount: 1, phase: .ready, isRefreshing: false, source: source)
        let model = EditorModel(document: document)
        let text = await model.diagnosticText
        XCTAssertTrue(text.contains("RAW: apple-ciraw · decoder 8.dng · macOS build engine-build-sentinel"))
        XCTAssertTrue(text.contains("Lens correction: supported"))
    }
}
