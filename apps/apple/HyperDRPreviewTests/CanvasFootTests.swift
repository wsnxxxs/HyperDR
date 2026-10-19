import AppKit
import SwiftUI
import XCTest
@testable import HyperDR

/// The foot of the canvas is shared by the zebra legend, the hint, the
/// camera-support card, the busy chip and the export capsule: none covers
/// another, whatever the language, the wrapping or the window width.
@MainActor final class CanvasFootTests: XCTestCase {
    // MARK: The arithmetic

    func testNothingReservedNeedsNoClearance() {
        XCTAssertEqual(CanvasBottomReserve.clearance(reserve: 0, canvasHeight: 400, visibleMaxY: 400), 0)
    }

    func testAPhotoThatEndsAboveTheReserveNeedsNone() {
        // 100 pt of canvas below the photograph, 80 pt reserved: the legend is already clear.
        XCTAssertEqual(CanvasBottomReserve.clearance(reserve: 80, canvasHeight: 400, visibleMaxY: 300), 0)
    }

    func testAPhotoThatFillsTheCanvasLiftsByTheWholeReserveAndAGap() {
        XCTAssertEqual(CanvasBottomReserve.clearance(reserve: 80, canvasHeight: 400, visibleMaxY: 400), 88)
    }

    func testAPhotoThatReachesPartwayIntoTheReserveLiftsByTheOverlap() {
        XCTAssertEqual(CanvasBottomReserve.clearance(reserve: 80, canvasHeight: 400, visibleMaxY: 350), 38)
    }

    func testTheCapsuleStacksOnTheCard() {
        XCTAssertEqual(CanvasBottomReserve(status: 70, capsule: 50).total, 120)
    }

    // MARK: The geometry

    private final class Frames { var value: [String: CGRect] = [:] }

    private func floating(width: CGFloat, height: CGFloat, locale: String, model: EditorModel, frames: Frames) -> NSHostingView<AnyView> {
        let root = CanvasFloating(model: model, window: EditorWindowState(), hint: CanvasHintState(), showsInspector: false)
            .frame(width: width, height: height)
            .onPreferenceChange(CanvasFloatingFramesKey.self) { frames.value = $0 }
            .environment(\.locale, Locale(identifier: locale))
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: AnyView(root))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        host.layoutSubtreeIfNeeded()
        return host
    }

    func testThePreparingCardNeverCoversTheLegendInEitherLanguageOrAtAnyWidth() async throws {
        let services = ScriptedEditorServices(); services.openClock = ImmediateClock()
        let model = EditorModel(services: services)
        let old = URL(fileURLWithPath: "/fixtures/old.jpg")
        let preview = EditorPreview(pixelSize: PixelSize(width: 640, height: 400),
                                    source: SourceSummary(domain: .sdr, colorName: "sRGB", degradationReasons: []), hasGain: false)
        model.open([old])
        await eventually(timeout: .seconds(5)) { services.streams[old] != nil }
        services.streams[old]?.yield(.reference(preview)); services.streams[old]?.yield(.edited(preview))
        await eventually(timeout: .seconds(5)) { model.document?.phase == .ready }
        model.showsHighlightZebra = true; model.showsShadowZebra = true
        model.open([URL(fileURLWithPath: "/fixtures/new-and-a-very-long-file-name-from-a-camera-DSC01468.ARW")])
        await eventually(timeout: .seconds(5)) { model.document?.isPreparingCameraSupport == true }

        for locale in ["en", "zh-Hans"] {
            for (width, height) in [(CGFloat(900), CGFloat(500)), (640, 400), (480, 400), (360, 320)] {
                model.updateViewport(CGSize(width: width, height: height), backingScale: 1)
                let frames = Frames()
                let host = floating(width: width, height: height, locale: locale, model: model, frames: frames)
                let legend = try XCTUnwrap(frames.value["legend"], "no legend at \(width)×\(height) \(locale)")
                let card = try XCTUnwrap(frames.value["status"], "no card at \(width)×\(height) \(locale)")
                XCTAssertLessThanOrEqual(legend.maxY, card.minY, "legend is covered by the card at \(width)×\(height) \(locale)")
                XCTAssertGreaterThanOrEqual(legend.minY, 0, "legend leaves the canvas at \(width)×\(height) \(locale)")
                XCTAssertLessThanOrEqual(card.maxY, height, "card leaves the canvas at \(width)×\(height) \(locale)")
                _ = host
            }
        }
        model.cancelOpen()
    }

    func testTheLegendStaysWhereItWasWhenNothingElseIsAtTheFoot() async throws {
        let services = ScriptedEditorServices()
        let model = EditorModel(services: services)
        let old = URL(fileURLWithPath: "/fixtures/old.jpg")
        let preview = EditorPreview(pixelSize: PixelSize(width: 640, height: 400),
                                    source: SourceSummary(domain: .sdr, colorName: "sRGB", degradationReasons: []), hasGain: false)
        model.open([old])
        await eventually(timeout: .seconds(5)) { services.streams[old] != nil }
        services.streams[old]?.yield(.reference(preview)); services.streams[old]?.yield(.edited(preview))
        await eventually(timeout: .seconds(5)) { model.document?.phase == .ready }
        model.showsHighlightZebra = true
        model.updateViewport(CGSize(width: 640, height: 400), backingScale: 1)
        let frames = Frames()
        let host = floating(width: 640, height: 400, locale: "en", model: model, frames: frames)
        let legend = try XCTUnwrap(frames.value["legend"])
        XCTAssertNil(frames.value["status"])
        XCTAssertEqual(legend.maxY, 400 - 12, accuracy: 1, "an unobstructed legend keeps its 12 pt margin")
        _ = host
    }
}

@MainActor private final class ImmediateClock: EditorOpenClock {
    var now: Duration = .zero
    func sleep(until deadline: Duration) async throws {}
}
