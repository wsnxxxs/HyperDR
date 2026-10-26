import Foundation
import HyperDRKit
import HyperDRRecipe
import HyperDRRender
import XCTest
@testable import HyperDR

/// Full-resolution details of the visible region, rendered by the recipe
/// editor once the canvas is still.
@MainActor final class DetailRenderingTests: XCTestCase {
    func testTheVisibleSourceRect() {
        let canvas = CanvasModel()
        canvas.setImageSize(PixelSize(width:6000,height:4000))
        canvas.setViewport(CGSize(width:1000,height:800),backingScale:2)
        canvas.zoomToActualPixels()
        let visible = canvas.visibleSourceRect!
        XCTAssertEqual(visible.width,2000,accuracy:0.001)
        XCTAssertEqual(visible.height,1600,accuracy:0.001)
    }

    private func opened() async -> (EditorModel, FakeEditorRendering) {
        let services = FakeEditorServices(openDelay: .zero)
        let model = EditorModel(services: services)
        model.updateViewport(CGSize(width: 320, height: 240), backingScale: 1)
        model.open([URL(fileURLWithPath: "/fixtures/a.jpg")])
        await eventually(timeout: .seconds(3)) { model.document?.phase == .ready }
        // The fake renders previews at the canvas's size: zoomed in, they lack pixels.
        model.canvas.zoomToActualPixels()
        return (model, services.fakeRendering!)
    }

    private func detailRequests(_ fake: FakeEditorRendering) async -> [EditorRenderRequest] {
        await fake.requests.filter { $0.region != nil }
    }

    /// Waits (up to two seconds) until the fake holds at least `count` renders.
    private func held(_ fake: FakeEditorRendering, _ count: Int = 1) async {
        for _ in 0..<100 where await fake.heldRenderCount < count {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func testLatestRegionWinsAndCloseCancelsWithoutPublishingLatePixels() async throws {
        let (model, fake) = await opened()
        await eventually(timeout: .seconds(3)) { model.editedDetailPair != nil }
        await fake.holdRenders()
        // Far enough from the centre to leave the detail on screen.
        var transform = model.canvas.transform
        transform.pan = transform.clampedPan(CGPoint(x: 2500, y: 1700))
        model.canvas.apply(transform)
        await held(fake)
        transform.pan = transform.clampedPan(CGPoint(x: -2500, y: -1700))
        model.canvas.apply(transform)
        let latest = try XCTUnwrap(model.canvas.visibleSourceRect.map {
            RecipeEditor.detailRegion(visible: $0, source: HyperDRRender.PixelSize(width: 6000, height: 4000))
        })
        await held(fake, 2)
        await fake.releaseRenders()
        await eventually(timeout: .seconds(3)) { model.editedDetailPair?.region == latest }
        await settle(50)
        XCTAssertEqual(model.editedDetailPair?.region, latest, "an obsolete region cannot publish")
        await fake.holdRenders()
        transform.pan = transform.clampedPan(CGPoint(x: 2500, y: 1700))
        model.canvas.apply(transform)
        await held(fake)
        model.closeDocument()
        await fake.releaseRenders()
        await settle(100)
        XCTAssertNil(model.editedDetailPair)
        XCTAssertNil(model.originalDetailPair)
        XCTAssertNil(model.canvasComposition)
    }

    func testComparisonDetailsStayReadyAndDraftsRenderNone() async throws {
        let (model, fake) = await opened()
        await eventually(timeout: .seconds(3)) { model.editedDetailPair != nil }
        await eventually(timeout: .seconds(3)) { model.originalDetailPair != nil }
        let beforeComparison = await detailRequests(fake).count
        model.beginPeekOriginal()
        XCTAssertNotNil(model.originalDetailPair, "comparison starts with native detail")
        model.endPeekOriginal()
        XCTAssertNotNil(model.originalDetailPair, "comparison keeps its prepared detail")
        XCTAssertNotNil(model.editedDetailPair, "releasing comparison keeps the edit sharp")
        let afterComparison = await detailRequests(fake).count
        XCTAssertEqual(afterComparison, beforeComparison)
        let exposure = try XCTUnwrap(Adjustments.declaration("tone.exposure"))
        model.editor.editingChanged(exposure, true)
        model.adjustRecipe(exposure.id, to: 0.9)
        await eventually(timeout: .seconds(3)) { model.editedDetailPair == nil }
        let before = await detailRequests(fake).count
        try await Task.sleep(for: .milliseconds(350))
        let during = await detailRequests(fake).count
        XCTAssertEqual(during, before, "drafts do not render details")
        model.editor.editingChanged(exposure, false)
        await eventually(timeout: .seconds(3)) { model.editedDetailPair != nil }
        model.closeDocument()
    }

    func testDisplayOnlyOptionsDoNotRenderAgain() async throws {
        let (model, fake) = await opened()
        await eventually(timeout: .seconds(3)) { model.editedDetailPair != nil }
        model.toggleCompare()
        await eventually(timeout: .seconds(3)) { model.originalDetailPair != nil }
        await settle(100)
        let before = await fake.requests.count
        model.showsHighlightZebra = true; model.showsShadowZebra = true; model.previewsAsSDR = true
        XCTAssertEqual(model.canvasComposition?.previewsAsSDR, true)
        try await Task.sleep(for: .milliseconds(350))
        let after = await fake.requests.count
        XCTAssertEqual(after, before)
        model.closeDocument()
    }
}
