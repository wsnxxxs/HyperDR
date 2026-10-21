import HyperDRRender
import XCTest
@testable import HyperDR

@MainActor final class PhotoBadgeTests: XCTestCase {
    func testBadgeFollowsShownContentAndComparisonMode() {
        XCTAssertEqual(PhotoBadgeKind(viewMode: .edited, originalAvailable: true, hasHDR: true), .hdr)
        XCTAssertNil(PhotoBadgeKind(viewMode: .edited, originalAvailable: true, hasHDR: false))
        for hdr in [false, true] {
            XCTAssertEqual(PhotoBadgeKind(viewMode: .original, originalAvailable: true, hasHDR: hdr), .original)
            XCTAssertNil(PhotoBadgeKind(viewMode: .original, originalAvailable: false, hasHDR: hdr))
            XCTAssertNil(PhotoBadgeKind(viewMode: .compare, originalAvailable: true, hasHDR: hdr))
            for mode in [ViewMode.edited, .original, .compare] {
                XCTAssertNil(PhotoBadgeKind(viewMode: mode, originalAvailable: true, hasHDR: hdr, isPeeking: true))
            }
        }
    }

    func testSDRDisplayFixtureKeepsTheBadgeUnlessPreviewingSDR() {
        let model = EditorModel.preview(.editingSDRDisplay)
        XCTAssertEqual(model.display.gainWeight, 0)
        XCTAssertTrue(model.showsHDRBadge)
        model.previewsAsSDR = true
        XCTAssertFalse(model.showsHDRBadge)
    }

    /// Real JPEG → editor → render → model. This caught both the expanded
    /// "original" and the HDR badge on a frame whose gain was entirely zero.
    func testJPEGOriginalAndBadgeAcrossHDRSwitchAndStrength() async throws {
        let photo = try TinyPhoto()
        defer { photo.remove() }
        let model = EditorModel(services: FakeEditorServices(openDelay: .zero, rendering: try RenderSession()))
        await openReady(model, photo.url)
        defer { model.closeDocument() }
        await model.editor.settle()
        model.editorChanged()
        let original = try XCTUnwrap(model.referenceFrame)
        let on = try XCTUnwrap(model.editedFrame)
        XCTAssertTrue(RenderEngine.readTexture(original.display.gain).allSatisfy { $0 == 0 })
        XCTAssertGreaterThan(RenderEngine.readTexture(on.display.gain).max() ?? 0, 0)
        XCTAssertTrue(model.showsHDRBadge)

        // A screen with no extra headroom must not hide real HDR content.
        model.receiveDisplay(DisplayState(screenName: "SDR", currentHeadroom: 1, potentialHeadroom: 1, gainWeight: 0))
        await eventually { model.display.currentHeadroom == 1 }
        XCTAssertTrue(model.showsHDRBadge)

        var recipe = model.editor.recipe
        recipe.setValue(.bool(false), for: "hdr.enabled")
        model.editor.setRecipe(recipe)
        // The rendered HDR frame stays on screen until the replacement arrives.
        XCTAssertTrue(model.showsHDRBadge)
        await model.editor.settle()
        model.editorChanged()
        let off = try XCTUnwrap(model.editedFrame)
        XCTAssertTrue(RenderEngine.readTexture(off.display.gain).allSatisfy { $0 == 0 })
        let offBase = RenderEngine.readTexture(off.display.base)
        let originalBase = RenderEngine.readTexture(original.display.base)
        XCTAssertEqual(offBase.count, originalBase.count)
        XCTAssertLessThan(zip(offBase, originalBase).map { abs($0 - $1) }.max() ?? 0, 0.00001)
        XCTAssertFalse(model.showsHDRBadge)
        XCTAssertTrue(model.referencePair?.base === original.display.base)
        model.beginPeekOriginal()
        XCTAssertEqual(model.canvasComposition?.mode, .original)
        XCTAssertTrue(model.canvasComposition?.original?.base === original.display.base)
        model.endPeekOriginal()
        XCTAssertEqual(model.canvasComposition?.mode, .edited)

        recipe.setValue(.bool(true), for: "hdr.enabled")
        recipe.setValue(.number(0), for: "hdr.strength")
        model.editor.setRecipe(recipe)
        await model.editor.settle()
        model.editorChanged()
        XCTAssertFalse(model.showsHDRBadge, "enabled with zero strength has no HDR content")
        recipe.setValue(.number(100), for: "hdr.strength")
        model.editor.setRecipe(recipe)
        await model.editor.settle()
        model.editorChanged()
        XCTAssertTrue(model.showsHDRBadge)
        model.editor.bypassedGroups = [.hdr]
        await model.editor.settle()
        model.editorChanged()
        XCTAssertFalse(model.showsHDRBadge, "bypassing HDR must also clear the badge")
    }
}
