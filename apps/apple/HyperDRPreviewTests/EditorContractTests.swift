import AppKit
import XCTest
@testable import HyperDR

@MainActor final class EditorContractTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/fixtures/photo.ARW")

    private func waitUntil(_ condition: @MainActor () -> Bool,
                           file: StaticString = #filePath, line: UInt = #line) async throws {
        await eventually(timeout: .seconds(3), "state transition", file: file, line: line, condition)
    }

    private func setExposure(_ value: Double, _ model: EditorModel) {
        var recipe = model.editor.recipe
        recipe.setValue(.number(value), for: "tone.exposure")
        model.editor.setRecipe(recipe)
    }

    func testOpenTransitionsToReadyWithBothFrames() async throws {
        let services = FakeEditorServices(openDelay: .milliseconds(30))
        let model = EditorModel(services: services)
        XCTAssertEqual(model.workspace, .empty)
        XCTAssertFalse(model.isAvailable(.compare))
        model.open([URL(fileURLWithPath: "/fixtures/unsupported.txt"), source])
        XCTAssertEqual(model.workspace, .editing)
        XCTAssertEqual(model.document?.phase, .opening)
        XCTAssertNil(model.document?.pixelSize)
        try await waitUntil { model.document?.phase == .ready }
        XCTAssertEqual(model.document?.pixelSize, PixelSize(width: 6000, height: 4000))
        XCTAssertTrue(model.hasReferenceFrame)
        XCTAssertTrue(model.hasEditedFrame)
        XCTAssertTrue(model.isAvailable(.original))
        XCTAssertTrue(model.isAvailable(.compare))
        XCTAssertNotNil(model.canvasComposition)
        model.viewMode = .original
        XCTAssertNil(model.display.gainWeight)
        model.viewMode = .edited
        XCTAssertNotNil(model.display.gainWeight)
        model.closeDocument()
    }

    func testFailedOpenKeepsPreviousPhotoModeAndZoom() async throws {
        let services = FakeEditorServices(openDelay: .milliseconds(5))
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
        model.closeDocument()
    }

    func testFirstFrameFailureHasNoDrawableFrame() async throws {
        let services = ScriptedEditorServices()
        services.scripted.failRenders(of: source, with: UserFacingError(code: "decode_failed"))
        let model = EditorModel(services: services)
        model.open([source])
        try await waitUntil { model.alert != nil }
        XCTAssertEqual(model.alert?.code, "decode_failed")
        XCTAssertNil(model.document)
        XCTAssertEqual(model.workspace, .empty)
        XCTAssertFalse(model.hasPreviewFrame)
        XCTAssertNil(model.canvas.imageFrame)
    }

    /// A render that fails after the photo is open keeps the last frame and
    /// says why under the photo; the photo stays ready.
    func testRenderFailureKeepsTheFrame() async throws {
        let services = ScriptedEditorServices()
        let model = EditorModel(services: services)
        // A file that is there: its renders failing is not a missing file.
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("contract-\(UUID().uuidString).jpg")
        try Data([1]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        await openReady(model, file)
        services.scripted.failRenders(of: file, with: UserFacingError(code: "raw_budget"))
        setExposure(0.6, model)
        try await waitUntil { model.document?.previewError != nil }
        XCTAssertEqual(model.document?.previewError?.code, "decode_failed")
        XCTAssertEqual(model.document?.phase, .ready)
        XCTAssertTrue(model.hasPreviewFrame)
        try await waitUntil { model.document?.isRefreshing == false }
        model.closeDocument()
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

    func testCanvasFailureCannotBeOverwrittenByALateFrame() async throws {
        let services = FakeEditorServices(openDelay: .zero)
        let model = EditorModel(services: services)
        model.open([source])
        try await waitUntil { model.document?.phase == .ready }
        await services.fakeRendering?.holdRenders()
        setExposure(0.7, model)
        let fake = try XCTUnwrap(services.fakeRendering)
        var waited = 0
        while await fake.heldRenderCount == 0, waited < 400 { await settle(5); waited += 1 }
        model.reportCanvasFailure("fixture")
        let failedPhase = model.document?.phase
        guard case .failed(let error) = failedPhase else {
            return XCTFail("Canvas failure must fail the opened document")
        }
        XCTAssertEqual(error.code, "metal_unavailable")
        await services.fakeRendering?.releaseRenders()
        await model.editor.settle()
        await settle()
        XCTAssertEqual(model.document?.phase, failedPhase)
        XCTAssertEqual(model.document?.isRefreshing, false)
        XCTAssertFalse(model.hasPreviewFrame)
        XCTAssertNil(model.canvas.imageFrame)
        XCTAssertNil(model.display.gainWeight)
        model.closeDocument()
    }

    func testReplacedOpenCannotRestoreAnUnfinishedDocument() async throws {
        let services = FakeEditorServices(openDelay: .milliseconds(20))
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
        view.compositionProvider = { model.canvasComposition }
        view.transform = canvas.transform
        XCTAssertEqual(view.transform.viewport, CGSize(width: 1000, height: 800))
        XCTAssertFalse(view.isOpaque)
        XCTAssertFalse(view.acceptsFirstResponder)
        XCTAssertEqual(model.canvas.imageFrame, model.canvas.transform.imageFrame)
        // The scenario has no rendered pairs, so there is nothing to draw.
        XCTAssertNil(model.canvasComposition)
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
        view.compositionProvider = { model.canvasComposition }
        view.onTransformChange = { [weak model] transform in model?.canvas.apply(transform) }
        view.setFrameSize(CGSize(width: 900, height: 700))
        view.needsLayout = true
        view.layoutSubtreeIfNeeded()
        XCTAssertEqual(model.canvas.transform.viewport, CGSize(width: 900, height: 700))
        XCTAssertNotNil(model.canvas.imageFrame)
    }
}
