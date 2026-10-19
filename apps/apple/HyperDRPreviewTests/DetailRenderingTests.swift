import Foundation
import HyperDREngine
import HyperDRKit
import XCTest
@testable import HyperDR

@MainActor final class DetailRenderingTests: XCTestCase {
    func testVisibleRegionAndConservativePolicy() {
        let canvas = CanvasModel()
        canvas.setImageSize(PixelSize(width:6000,height:4000))
        canvas.setViewport(CGSize(width:1000,height:800),backingScale:2)
        canvas.previewPixelSize = CGSize(width:2048,height:1365)
        XCTAssertFalse(canvas.needsDetail)
        canvas.zoomToActualPixels()
        XCTAssertTrue(canvas.needsDetail)
        let visible = canvas.visibleSourceRect!
        XCTAssertEqual(visible.width,2000,accuracy:0.001)
        XCTAssertEqual(visible.height,1600,accuracy:0.001)
        let region = DetailPolicy.region(visible:visible,source:canvas.transform.imageSize)
        XCTAssertEqual(region.width,2048)
        XCTAssertEqual(region.height,2048)
        let small = DetailPolicy.region(visible:CGRect(x:0,y:0,width:100,height:80),source:CGSize(width:6000,height:4000))
        XCTAssertEqual(small,PreviewRegion(left:0,top:0,width:150,height:120))
        canvas.previewPixelSize = CGSize(width:6000,height:4000)
        XCTAssertFalse(canvas.needsDetail,"full-resolution frames cannot gain more source pixels")
    }

    private func opened() async throws -> (EditorModel,FakeEditorServices,PreviewSession) {
        let bundle = previewFixtureBundle()
        let url = try XCTUnwrap(bundle.url(forResource:"photo",withExtension:"jpg",subdirectory:"Fixtures")
            ?? bundle.url(forResource:"photo",withExtension:"jpg"))
        let engine = try await Engine(), session = try engine.openPreview(source:url)
        let frame = try await session.renderFrame(EngineRequest(settings:["preview_max_edge":.number(32)]))
        let services = FakeEditorServices(openDelay:.zero,previewDelay:.milliseconds(1))
        services.preview = LiveEditorServices.preview(frame)
        let model = EditorModel(services:services)
        model.open([url])
        await eventually(timeout:.seconds(3)) { model.document?.phase == .ready }
        model.updateViewport(CGSize(width:32,height:24),backingScale:1)
        await eventually(timeout:.seconds(3)) { services.receivedEdges.count == 1 }
        await settle(100)
        return (model,services,session)
    }

    func testLatestRegionWinsAndCloseCancelsWithoutPublishingLatePixels() async throws {
        let (model,services,session) = try await opened(); defer { session.close() }
        var gates: [CheckedContinuation<EditorPreview?,Error>] = []
        services.detailHandler = { _,_ in try await withCheckedThrowingContinuation { gates.append($0) } }
        model.canvas.zoomToActualPixels()
        await eventually(timeout:.seconds(3)) { gates.count == 1 }
        XCTAssertFalse(services.detailRequests[0].original)
        var transform = model.canvas.transform
        transform.pan = transform.clampedPan(CGPoint(x:20,y:10))
        model.canvas.apply(transform)
        await eventually(timeout:.seconds(3)) { gates.count == 2 }
        gates[0].resume(returning:services.preview)
        await settle(100)
        XCTAssertNil(model.editedDetailFrame,"an obsolete region cannot publish")
        model.closeDocument()
        gates[1].resume(returning:services.preview)
        await settle(100)
        XCTAssertNil(model.editedDetailFrame)
        XCTAssertNil(model.originalDetailFrame)
        XCTAssertNil(model.canvasComposition)
    }

    func testOriginalDetailsAreDemandDrivenAndDoNotChangeScopeData() async throws {
        let (model,services,session) = try await opened(); defer { session.close() }
        services.detailHandler = { region,_ in
            var request = EngineRequest(settings:["preview_max_edge":.number(2048)])
            try request.setCommand("region",.object(["left":.number(Double(region.left)),"top":.number(Double(region.top)),
                "width":.number(Double(region.width)),"height":.number(Double(region.height))]))
            return LiveEditorServices.preview(try await session.renderFrame(request))
        }
        model.canvas.zoomToActualPixels()
        await eventually(timeout:.seconds(3)) { model.editedDetailFrame != nil }
        XCTAssertFalse(services.detailRequests.contains { $0.original })
        model.beginPeekOriginal()
        await eventually(timeout:.seconds(3)) { model.originalDetailFrame != nil }
        model.endPeekOriginal()
        let count = services.detailRequests.count
        model.beginPeekOriginal()
        try await Task.sleep(for:.milliseconds(350))
        XCTAssertEqual(services.detailRequests.count,count,"cached original detail is reused")
        model.endPeekOriginal()
        let histogram = model.scopes.original
        services.autoCompletesRefreshes = false
        model.beginAdjusting("brightness")
        model.adjust("brightness",to:0.9)
        XCTAssertNil(model.editedDetailFrame)
        XCTAssertNotNil(model.originalDetailFrame)
        let before = services.detailRequests.count
        try await Task.sleep(for:.milliseconds(350))
        XCTAssertEqual(services.detailRequests.count,before,"drafts do not render details")
        XCTAssertEqual(model.scopes.original,histogram)
        model.endAdjusting("brightness")
        model.closeDocument()
    }

    /// A new original frame (the lens correction switch) has a histogram of its own.
    func testANewOriginalFrameRecomputesTheOriginalHistogram() async throws {
        let (model,services,session) = try await opened(); defer { session.close() }
        await eventually(timeout:.seconds(5)) { model.scopes.original != nil }
        model.scopes.update(original:.some(nil),current:nil,waveform:nil)
        XCTAssertNil(model.scopes.original)
        model.edit.lensCorrection = false
        model.editChanged()
        await eventually(timeout:.seconds(5)) { services.referenceRenders.count == 1 }
        await eventually(timeout:.seconds(5)) { model.scopes.original != nil }
        XCTAssertEqual(services.referenceRenders.last?["lensCorrection"],.bool(false))
        model.closeDocument()
    }

    private func openedAtTier(_ viewport: CGSize, backingScale: Double) async throws -> (EditorModel,FakeEditorServices) {
        let bundle = previewFixtureBundle()
        let url = try XCTUnwrap(bundle.url(forResource:"photo",withExtension:"jpg",subdirectory:"Fixtures")
            ?? bundle.url(forResource:"photo",withExtension:"jpg"))
        let services = FakeEditorServices(openDelay:.zero,previewDelay:.milliseconds(1))
        let model = EditorModel(services:services)
        model.updateViewport(viewport,backingScale:backingScale)
        model.open([url])
        await eventually(timeout:.seconds(3)) { model.document?.phase == .ready }
        return (model,services)
    }

    /// V-13: the "original" is rendered at the preview tier it was opened at, and
    /// asks for a larger one when the window grows to a larger tier.
    func testTheOriginalIsRenderedAgainWhenTheWindowGrowsToALargerTier() async throws {
        let (model,services) = try await openedAtTier(CGSize(width:800,height:600),backingScale:1) // the 960 tier
        XCTAssertEqual(model.previewEdge,960)
        XCTAssertTrue(services.referenceEdges.isEmpty, "opening supplies the first original itself")

        model.updateViewport(CGSize(width:1000,height:700),backingScale:1) // 1280
        await eventually(timeout:.seconds(3)) { services.referenceEdges == [1280] }
        model.updateViewport(CGSize(width:1600,height:1000),backingScale:2) // 2048
        await eventually(timeout:.seconds(3)) { services.referenceEdges == [1280,2048] }
        XCTAssertEqual(services.referenceRenders.last, model.referenceOptions, "the same neutral options at a larger edge")

        model.updateViewport(CGSize(width:800,height:600),backingScale:1) // smaller tiers never re-render
        await settle(100)
        XCTAssertEqual(services.referenceEdges,[1280,2048])
        model.updateViewport(CGSize(width:1600,height:1000),backingScale:2)
        await settle(100)
        XCTAssertEqual(services.referenceEdges,[1280,2048],"a tier already shown is not asked for again")
        model.closeDocument()
    }

    /// V-13: a failed larger original leaves the smaller one up and is tried again.
    func testAFailedLargerOriginalIsRetriedOnTheNextTierChange() async throws {
        let (model,services) = try await openedAtTier(CGSize(width:800,height:600),backingScale:1)
        services.referenceHandler = { _ in throw UserFacingError(code:"decode_failed") }
        model.updateViewport(CGSize(width:1600,height:1000),backingScale:2)
        await eventually(timeout:.seconds(3)) { services.referenceEdges == [2048] }
        await settle(50)
        XCTAssertEqual(model.shownReferenceEdge,960)
        services.referenceHandler = nil
        model.updateViewport(CGSize(width:1500,height:1000),backingScale:2)
        await eventually(timeout:.seconds(3)) { services.referenceEdges == [2048,2048] }
        await eventually(timeout:.seconds(3)) { model.shownReferenceEdge == 2048 }
        model.closeDocument()
    }

    /// V-13: an original smaller than the canvas shows asks for its own detail
    /// even when the edited frame is large enough.
    func testTheOriginalNeedsDetailWhenItIsSmallerThanTheEditedFrame() {
        let canvas = CanvasModel()
        canvas.setImageSize(PixelSize(width:6000,height:4000))
        canvas.setViewport(CGSize(width:1000,height:800),backingScale:2)
        canvas.previewPixelSize = CGSize(width:2048,height:1365)
        canvas.referencePixelSize = CGSize(width:960,height:640)
        XCTAssertFalse(canvas.needsEditedDetail)
        XCTAssertTrue(canvas.needsOriginalDetail)
        canvas.referencePixelSize = CGSize(width:2048,height:1365)
        XCTAssertFalse(canvas.needsOriginalDetail)
        canvas.referencePixelSize = CGSize(width:6000,height:4000)
        canvas.zoomToActualPixels()
        XCTAssertFalse(canvas.needsOriginalDetail,"a full-resolution original has nothing more to give")
    }

    func testDisplayOnlyOptionsAndPeekingDoNotSubmitNewEdits() async throws {
        let (model,services,session) = try await opened(); defer { session.close() }
        let before = services.receivedOptions.count
        model.showsHighlightZebra = true; model.showsShadowZebra = true; model.previewsAsSDR = true
        model.showMask(for:"hdrStrength")
        model.toggleCompare()
        model.beginPeekOriginal()
        XCTAssertEqual(model.canvasComposition?.mode,.original)
        XCTAssertEqual(model.canvasComposition?.previewsAsSDR,true)
        model.endPeekOriginal()
        XCTAssertEqual(model.canvasComposition?.mode,.compare)
        await settle(100)
        XCTAssertEqual(services.receivedOptions.count,before)
        model.closeDocument()
    }
}

extension DetailRenderingTests {
    func testReplacementDiscoveredByADetailRequestReopensThePhoto() async throws {
        let (model,services,session) = try await opened(); defer { session.close() }
        let previous = model.photo
        services.detailHandler = { _,_ in
            services.detailHandler = nil
            throw EditorDetailError.sourceReplaced
        }
        model.canvas.zoomToActualPixels()
        await eventually(timeout:.seconds(3)) { model.photo != previous && model.document?.phase == .ready }
        XCTAssertEqual(model.photo?.url,previous?.url)
        XCTAssertNil(model.originalDetailFrame)
        model.closeDocument()
    }
}

extension DetailRenderingTests {
    func testReviewerOriginalLatestRegionAndSourceEventInvalidateCachedDetails() async throws {
        let (model,services,session)=try await opened(); defer { session.close() }
        var gates:[CheckedContinuation<EditorPreview?,Error>] = []
        services.detailHandler = { _,_ in try await withCheckedThrowingContinuation { gates.append($0) } }
        model.viewMode = .original
        model.canvas.zoomToActualPixels()
        await eventually(timeout:.seconds(3)) { gates.count == 1 }
        XCTAssertTrue(services.detailRequests[0].original)
        var transform=model.canvas.transform
        transform.pan=transform.clampedPan(CGPoint(x:20,y:10))
        model.canvas.apply(transform)
        await eventually(timeout:.seconds(3)) { gates.count == 2 }
        gates[0].resume(returning:services.preview)
        await settle(50)
        XCTAssertNil(model.originalDetailFrame)
        gates[1].resume(returning:services.preview)
        await eventually(timeout: .seconds(3)) { model.originalDetailFrame != nil }
        let old=try XCTUnwrap(model.photo)
        services.sendRefresh(.sourceReplaced,for:old)
        await eventually(timeout:.seconds(3)) { model.photo != old && model.document?.phase == .ready }
        XCTAssertNil(model.originalDetailFrame)
        XCTAssertNil(model.editedDetailFrame)
        model.closeDocument()
    }
}
