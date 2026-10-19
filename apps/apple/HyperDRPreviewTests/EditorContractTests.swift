import AppKit
import XCTest
@testable import HyperDR

@MainActor final class EditorContractTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/fixtures/photo.ARW")

    private func waitUntil(_ condition: @MainActor () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        await eventually(timeout: .seconds(3), "state transition", file: file, line: line, condition)
    }

    func testOpenTransitionsThroughReferenceAndEditedFrames() async throws {
        let services = FakeEditorServices(openDelay: .milliseconds(60), previewDelay: .milliseconds(60))
        let model = EditorModel(services: services)
        XCTAssertEqual(model.workspace, .empty)
        XCTAssertFalse(model.isAvailable(.compare))
        model.open([URL(fileURLWithPath: "/fixtures/unsupported.txt"), source])
        XCTAssertEqual(model.workspace, .editing)
        XCTAssertEqual(model.document?.phase, .opening)
        XCTAssertNil(model.document?.pixelSize)
        try await waitUntil { model.hasReferenceFrame }
        XCTAssertEqual(model.document?.phase, .rendering)
        XCTAssertEqual(model.document?.source, services.preview.source)
        XCTAssertFalse(model.hasEditedFrame)
        try await waitUntil { model.document?.phase == .ready }
        XCTAssertEqual(model.document?.pixelSize, PixelSize(width: 6000, height: 4000))
        XCTAssertEqual(services.renderedPurposes, [true, false])
        XCTAssertTrue(model.isAvailable(.original))
        XCTAssertTrue(model.isAvailable(.edited))
        model.viewMode = .original
        XCTAssertNil(model.display.gainWeight)
        model.viewMode = .compare
        XCTAssertEqual(model.viewMode, .compare)
        XCTAssertTrue(model.isAvailable(.compare))
        model.viewMode = .edited
        XCTAssertNotNil(model.display.gainWeight)
    }

    func testFailedOpenKeepsPreviousPhotoModeAndZoom() async throws {
        let services = FakeEditorServices(openDelay: .milliseconds(5), previewDelay: .milliseconds(5))
        let model = EditorModel(services: services)
        model.open([source])
        try await waitUntil { model.document?.phase == .ready }
        model.viewMode = .original
        model.canvas.setViewport(CGSize(width: 1000, height: 800), backingScale: 2)
        model.canvas.zoomIn()
        let old = model.document
        let oldFrame = model.canvas.imageFrame
        let unreadable = URL(fileURLWithPath: "/fixtures/unreadable.jpg")
        let error = UserFacingError(code: "source_unreadable", detail: "fixture")
        services.openFailures[unreadable] = error
        model.open([unreadable])
        XCTAssertEqual(model.document?.phase, .opening)
        XCTAssertNil(model.document?.pixelSize)
        XCTAssertTrue(model.hasPreviewFrame)
        XCTAssertEqual(model.canvas.imageFrame, oldFrame)
        XCTAssertEqual(model.viewMode, .original)
        try await waitUntil { model.alert == error }
        XCTAssertEqual(model.document, old)
        XCTAssertEqual(model.workspace, .editing)
        XCTAssertEqual(model.viewMode, .original)
        XCTAssertEqual(model.canvas.zoomPercent, 50)
        XCTAssertTrue(model.hasPreviewFrame)
        model.dismissAlert()
        XCTAssertNil(model.alert)
    }

    func testOpeningKeepsOldFrameUntilReferenceAndRestoresEditStateOnFailure() async throws {
        let services = FakeEditorServices(openDelay: .milliseconds(10), previewDelay: .milliseconds(10))
        let ticker = ManualFrameTicker()
        let model = EditorModel(services: services, ticker: ticker)
        model.open([source])
        try await waitUntil { model.document?.phase == .ready }
        model.adjust("brightness", to: 0.612345)
        await eventually { ticker.isWaiting }
        ticker.tick()
        try await waitUntil { services.renderedPurposes.count >= 3 }
        model.canvas.setViewport(CGSize(width: 1000, height: 800), backingScale: 2)
        model.canvas.zoomIn()
        model.viewMode = .original
        let previousDocument = model.document
        let previousFrame = model.canvas.imageFrame
        let previousPreview = services.preview
        services.openDelay = .milliseconds(60)
        services.previewDelay = .milliseconds(60)
        services.preview = EditorPreview(pixelSize: PixelSize(width: 4000, height: 6000),
            source: SourceSummary(domain: .hdr, colorName: "Display P3", degradationReasons: []),
            hasGain: true)
        let replacement = URL(fileURLWithPath: "/fixtures/replacement.heic")
        model.open([replacement])
        XCTAssertEqual(model.document?.name, replacement.lastPathComponent)
        XCTAssertEqual(model.document?.phase, .opening)
        XCTAssertEqual(model.canvas.imageFrame, previousFrame)
        XCTAssertTrue(model.hasEditedFrame)
        try await waitUntil { model.document?.pixelSize == services.preview.pixelSize }
        XCTAssertFalse(model.hasEditedFrame)
        XCTAssertTrue(model.hasPreviewFrame)
        XCTAssertNotEqual(model.canvas.imageFrame, previousFrame)
        let error = UserFacingError(code: "decode_failed")
        services.previewFailure = error
        try await waitUntil { model.alert == error }
        XCTAssertEqual(model.document, previousDocument)
        XCTAssertEqual(model.canvas.imageFrame, previousFrame)
        XCTAssertEqual(model.canvas.zoomPercent, 50)
        XCTAssertEqual(model.viewMode, .original)
        XCTAssertTrue(model.hasEditedFrame)
        services.previewFailure = nil
        services.preview = previousPreview
        model.adjust("hdrStrength", to: 0.723456)
        await eventually { ticker.isWaiting }
        ticker.tick()
        try await waitUntil { services.receivedOptions.last?["hdrStrength"] == .number(0.72) && services.renderedPurposes.count >= 4 }
        XCTAssertEqual(services.receivedOptions.last?["brightness"], .number(0.61))
        XCTAssertEqual(services.receivedOptions.last?["hdrStrength"], .number(0.72))
    }

    func testUnsupportedAndEngineFailureDoNotReplacePhoto() {
        let model = EditorModel.preview(.editingHDRDisplay)
        let old = model.document
        model.open([URL(fileURLWithPath: "/fixtures/unsupported.txt")])
        XCTAssertEqual(model.alert?.code, "unsupported_format")
        XCTAssertEqual(model.document, old)
        let failed = EditorModel.preview(.engineFailed)
        failed.open([source])
        XCTAssertEqual(failed.alert?.code, "engine_unavailable")
        XCTAssertNil(failed.document)
        XCTAssertEqual(failed.workspace, .empty)
    }

    func testFirstFrameFailureHasNoDrawableFrame() async throws {
        let services = FakeEditorServices(openDelay: .zero, previewDelay: .milliseconds(5))
        let error = UserFacingError(code: "decode_failed")
        services.previewFailure = error
        let model = EditorModel(services: services)
        model.open([source])
        try await waitUntil { model.alert == error }
        XCTAssertNil(model.document)
        XCTAssertEqual(model.workspace, .empty)
        XCTAssertFalse(model.hasPreviewFrame)
        XCTAssertNil(model.canvas.imageFrame)
    }

    func testEditedFrameFailureWithoutPreviousPhotoReturnsToEmpty() async throws {
        let services = FakeEditorServices(openDelay: .zero, previewDelay: .milliseconds(60))
        let model = EditorModel(services: services)
        model.open([source])
        try await waitUntil { model.hasReferenceFrame }
        XCTAssertEqual(model.document?.phase, .rendering)
        XCTAssertTrue(model.hasPreviewFrame)
        let error = UserFacingError(code: "decode_failed")
        services.previewFailure = error
        try await waitUntil { model.alert == error }
        XCTAssertNil(model.document)
        XCTAssertEqual(model.workspace, .empty)
        XCTAssertFalse(model.hasPreviewFrame)
        XCTAssertNil(model.canvas.imageFrame)
    }

    func testRefreshRetainsFrameAndQuantizedValues() async throws {
        let services = FakeEditorServices(openDelay: .zero, previewDelay: .milliseconds(10))
        let ticker = ManualFrameTicker()
        let model = EditorModel(services: services, ticker: ticker)
        model.open([source])
        try await waitUntil { model.document?.phase == .ready }
        model.adjust("brightness", to: 0.612345)
        await eventually { ticker.isWaiting }
        ticker.tick()
        XCTAssertEqual(model.document?.isRefreshing, false)
        XCTAssertTrue(model.hasPreviewFrame)
        try await waitUntil { services.renderedPurposes.count >= 3 }
        XCTAssertEqual(services.receivedOptions.last?["brightness"], .number(0.61))
        services.previewFailure = UserFacingError(code: "raw_budget")
        model.adjust("brightness", to: 0.712345)
        await eventually { ticker.isWaiting }
        ticker.tick()
        try await waitUntil { model.document?.previewError?.code == "raw_budget" }
        XCTAssertEqual(model.document?.phase, .ready)
        XCTAssertTrue(model.hasPreviewFrame)
        XCTAssertEqual(model.document?.isRefreshing, false)
    }

    func testCanvasFailureRollsBackAnOpenButFailsAnAlreadyOpenedDocument() async throws {
        let services = FakeEditorServices(openDelay: .milliseconds(60))
        let opening = EditorModel(services: services)
        opening.open([source])
        opening.reportCanvasFailure("fixture")
        XCTAssertEqual(opening.workspace, .empty)
        XCTAssertNil(opening.document)
        XCTAssertEqual(opening.alert?.code, "metal_unavailable")
        try await Task.sleep(for: .milliseconds(80))
        XCTAssertNil(opening.document)
        XCTAssertFalse(opening.hasPreviewFrame)

        let opened = EditorModel.preview(.editingHDRDisplay)
        let name = opened.document?.name
        opened.reportCanvasFailure("fixture")
        guard case .failed(let error) = opened.document?.phase else {
            return XCTFail("An already opened document without drawable frames must fail")
        }
        XCTAssertEqual(error.code, "metal_unavailable")
        XCTAssertEqual(opened.document?.name, name)
        XCTAssertEqual(opened.workspace, .editing)
        XCTAssertFalse(opened.hasPreviewFrame)
        XCTAssertNil(opened.canvas.imageFrame)
    }

    func testCanvasFailureDuringRefreshCannotBeOverwrittenByLateEditedFrame() async throws {
        let services = FakeEditorServices(openDelay: .zero, previewDelay: .milliseconds(5))
        let ticker = ManualFrameTicker()
        let model = EditorModel(services: services, ticker: ticker)
        model.open([source])
        try await waitUntil { model.document?.phase == .ready }
        services.previewDelay = .milliseconds(100)
        model.adjust("brightness", to: 0.712345)
        await eventually { ticker.isWaiting }
        ticker.tick()
        XCTAssertEqual(model.document?.isRefreshing, false)
        // Allow the refresh operation to start before the renderer fails.
        try await Task.sleep(for: .milliseconds(20))
        model.reportCanvasFailure("fixture")
        let failedPhase = model.document?.phase
        guard case .failed(let error) = failedPhase else {
            return XCTFail("Canvas failure must fail the opened document")
        }
        XCTAssertEqual(error.code, "metal_unavailable")
        XCTAssertFalse(model.hasPreviewFrame)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(model.document?.phase, failedPhase)
        XCTAssertEqual(model.document?.isRefreshing, false)
        XCTAssertFalse(model.hasPreviewFrame)
        XCTAssertNil(model.canvas.imageFrame)
        XCTAssertNil(model.display.gainWeight)
    }

    func testReplacedOpenCannotRestoreAnUnfinishedDocument() async throws {
        let services = FakeEditorServices(openDelay: .milliseconds(20), previewDelay: .milliseconds(10))
        let model = EditorModel(services: services)
        let bad = URL(fileURLWithPath: "/fixtures/bad.jpg")
        services.openFailures[bad] = UserFacingError(code: "source_unreadable")
        model.open([source])
        model.open([bad])
        try await waitUntil { model.alert != nil }
        XCTAssertEqual(model.workspace, .empty)
        XCTAssertNil(model.document)
        model.open([source])
        model.closeDocument()
        try await Task.sleep(for: .milliseconds(60))
        XCTAssertNil(model.document)
        XCTAssertEqual(model.workspace, .empty)
        XCTAssertNil(model.alert)
        XCTAssertFalse(model.hasPreviewFrame)
    }

    func testDisplayUpdatesPublishLatestStateWithoutCreatingAnImage() async throws {
        let services = FakeEditorServices()
        let model = EditorModel(services: services)
        for value in [1.0, 1.5, 2.0] {
            services.sendDisplay(DisplayState(screenName: "fixture-screen", currentHeadroom: value,
                potentialHeadroom: 4, gainWeight: 0.5))
        }
        try await waitUntil { model.display.currentHeadroom == 2 }
        XCTAssertTrue(model.display.supportsEDR)
        XCTAssertNil(model.display.gainWeight)
        XCTAssertNil(model.document)
    }

    func testAllPreviewScenariosAreDeterministicAndMatchContract() {
        XCTAssertEqual(PreviewScenario.allCases.count, 10)
        for scenario in PreviewScenario.allCases {
            let model = EditorModel.preview(scenario)
            let repeated = EditorModel.preview(scenario)
            XCTAssertEqual(model.document, repeated.document)
            XCTAssertEqual(model.engine, repeated.engine)
            XCTAssertEqual(model.alert, repeated.alert)
            XCTAssertEqual(model.isAvailable(.compare), model.hasReferenceFrame && model.hasEditedFrame)
            switch scenario {
            case .empty:
                XCTAssertEqual(model.workspace, .empty)
                XCTAssertNil(model.document)
            case .opening:
                XCTAssertEqual(model.document?.phase, .opening)
            case .firstFrameRendering:
                XCTAssertEqual(model.document?.phase, .rendering)
            case .firstFrameFailed:
                guard case .failed(let error) = model.document?.phase else {
                    XCTFail("Expected failed first frame"); continue
                }
                XCTAssertEqual(error.code, "metal_unavailable")
                XCTAssertFalse(model.hasPreviewFrame)
            case .engineFailed:
                guard case .failed(let error) = model.engine else {
                    XCTFail("Expected failed engine"); continue
                }
                XCTAssertEqual(error.code, "engine_unavailable")
            case .editingHDRDisplay, .editingSDRDisplay, .refreshing, .previewFailedKeepsFrame, .openFailed:
                XCTAssertEqual(model.document?.phase, .ready)
                XCTAssertTrue(model.hasPreviewFrame)
                XCTAssertEqual(model.display.supportsEDR, scenario != .editingSDRDisplay)
                XCTAssertEqual(model.document?.isRefreshing, scenario == .refreshing)
                XCTAssertEqual(model.document?.previewError?.code,
                               scenario == .previewFailedKeepsFrame ? "raw_budget" : nil)
                XCTAssertEqual(model.alert?.code, scenario == .openFailed ? "source_unreadable" : nil)
            }
        }
    }

    func testCanvasGeometryZoomAndEmptyCanvas() async throws {
        let model = EditorModel.preview(.editingHDRDisplay)
        let canvas = model.canvas
        canvas.setViewport(CGSize(width: 1000, height: 800), backingScale: 2)
        XCTAssertEqual(canvas.zoomPercent, 33)
        let fitted = try XCTUnwrap(canvas.imageFrame)
        XCTAssertEqual(fitted.width, 1000, accuracy: 1e-6)
        XCTAssertEqual(fitted.height, 2000.0 / 3, accuracy: 1e-6)
        XCTAssertEqual(fitted.minY, 200.0 / 3, accuracy: 1e-6)
        canvas.zoomToActualPixels()
        XCTAssertEqual(canvas.zoomPercent, 100)
        for _ in 0..<20 { canvas.zoomIn() }
        XCTAssertEqual(canvas.zoomPercent, 400)
        XCTAssertFalse(canvas.canZoomIn)
        canvas.zoomOut()
        XCTAssertEqual(canvas.zoomPercent, 300)
        canvas.fitToWindow()
        XCTAssertFalse(canvas.canZoomOut)
        model.closeDocument()
        XCTAssertNil(canvas.imageFrame)
        XCTAssertFalse(canvas.canZoomIn)
        let view = EDRCanvasView()
        XCTAssertFalse(view.isOpaque)
        XCTAssertFalse(view.acceptsFirstResponder)
    }

    /// The canvas and the view layer agree on where the photo is: the same
    /// rect drives the display pass and `canvas.imageFrame`.
    func testCanvasDrawsOnlyThePublishedPhotoRect() async throws {
        let model = EditorModel.preview(.editingHDRDisplay)
        let canvas = model.canvas
        canvas.setViewport(CGSize(width: 1000, height: 800), backingScale: 2)
        let view = EDRCanvasView()
        view.frameProvider = { model.canvasFrame }
        view.transform = canvas.transform
        XCTAssertEqual(view.transform.viewport, CGSize(width: 1000, height: 800))
        XCTAssertFalse(view.isOpaque)
        XCTAssertFalse(view.acceptsFirstResponder)
        XCTAssertEqual(model.canvas.imageFrame, model.canvas.transform.imageFrame)
        // A2 supplies the frames; until then the canvas has nothing to draw.
        XCTAssertNil(model.canvasFrame)
        canvas.zoomIn()
        view.transform = canvas.transform
        XCTAssertEqual(view.transform.zoom, 1.5, accuracy: 1e-9)
        model.closeDocument()
        XCTAssertNil(model.canvas.imageFrame)
    }

    /// The canvas reports its own size so the model can publish `imageFrame`
    /// for the overlays, and a gesture result flows back through `apply`.
    func testCanvasReportsItsGeometryToTheModel() async throws {
        let model = EditorModel.preview(.editingHDRDisplay)
        let view = EDRCanvasView()
        view.onViewportChange = { [weak model] size, scale in
            model?.canvas.setViewport(size, backingScale: scale)
        }
        view.frameProvider = { model.canvasFrame }
        view.onTransformChange = { [weak model] transform in model?.canvas.apply(transform) }
        view.setFrameSize(CGSize(width: 900, height: 700))
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(model.canvas.transform.viewport, CGSize(width: 900, height: 700))
        XCTAssertNotNil(model.canvas.imageFrame)
    }
}
