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

    private func floating(width: CGFloat, height: CGFloat, locale: String, model: EditorModel, frames: Frames,
                          dropNotice: DropNotice? = nil, busy: Bool = false, settle: TimeInterval = 0.4) -> NSHostingView<AnyView> {
        let root = CanvasFloating(model: model, window: EditorWindowState(), hint: CanvasHintState(), showsInspector: false,
                                  dropNotice: dropNotice, busyAlreadyShown: busy)
            .frame(width: width, height: height)
            .onPreferenceChange(CanvasFloatingFramesKey.self) { frames.value = $0 }
            .environment(\.locale, Locale(identifier: locale))
            .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: AnyView(root))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: width, height: height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(settle))
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

// MARK: - The drop notice and the updating chip

extension CanvasFootTests {
    private static let preview = EditorPreview(pixelSize: PixelSize(width: 640, height: 400),
        source: SourceSummary(domain: .sdr, colorName: "sRGB", degradationReasons: []), hasGain: false)

    /// A ready JPEG on a 640×400 canvas, zebras on.
    fileprivate func readyModel(_ services: ScriptedEditorServices) async -> EditorModel {
        let model = EditorModel(services: services)
        let old = URL(fileURLWithPath: "/fixtures/old.jpg")
        model.open([old])
        await eventually(timeout: .seconds(5)) { services.streams[old] != nil }
        services.streams[old]?.yield(.reference(Self.preview)); services.streams[old]?.yield(.edited(Self.preview))
        await eventually(timeout: .seconds(5)) { model.document?.phase == .ready }
        model.showsHighlightZebra = true; model.showsShadowZebra = true
        return model
    }

    func testTheDropNoticeSitsAboveTheCardOnARefusedDrag() async throws {
        let services = ScriptedEditorServices(); services.openClock = ImmediateClock()
        let model = await readyModel(services)
        model.open([URL(fileURLWithPath: "/fixtures/new.ARW")])
        await eventually(timeout: .seconds(5)) { model.document?.isPreparingCameraSupport == true }
        for locale in ["en", "zh-Hans"] {
            for width in [CGFloat(900), 640, 360] {
                model.updateViewport(CGSize(width: width, height: 400), backingScale: 1)
                let frames = Frames()
                let host = floating(width: width, height: 400, locale: locale, model: model, frames: frames, dropNotice: .rejects)
                let notice = try XCTUnwrap(frames.value["drop"], "no notice at \(width) \(locale)")
                let card = try XCTUnwrap(frames.value["status"], "no card at \(width) \(locale)")
                XCTAssertLessThanOrEqual(notice.maxY, card.minY, "the notice covers the card at \(width) \(locale)")
                XCTAssertGreaterThanOrEqual(notice.minY, 0)
                _ = host
            }
        }
        model.cancelOpen()
    }

    func testTheDropNoticeDuringAnExportSitsAboveTheCapsuleAndTheLegendIsUntouched() async throws {
        let services = FakeEditorServices(openDelay: .zero, previewDelay: .zero)
        let model = EditorModel(services: services, ticker: ManualFrameTicker())
        await model.loadExportServices()
        model.open([URL(fileURLWithPath: "/tmp/first.jpg")])
        await eventually(timeout: .seconds(10)) { model.document?.phase == .ready && !model.suggestedFileName.isEmpty }
        model.showsHighlightZebra = true
        model.updateViewport(CGSize(width: 640, height: 400), backingScale: 1)
        model.startExport(destination: URL(fileURLWithPath: "/tmp/chosen.heic"), token: model.prepareExport()!)
        await eventually(timeout: .seconds(10)) { services.hasExportSubscriber }
        XCTAssertTrue(model.export.isInFlight)
        let without = Frames(), with = Frames()
        let a = floating(width: 640, height: 400, locale: "en", model: model, frames: without)
        let b = floating(width: 640, height: 400, locale: "en", model: model, frames: with,
                         dropNotice: .replacesDuringExport(name: "IMG_2041.HEIC"))
        let capsule = try XCTUnwrap(with.value["capsule"]), notice = try XCTUnwrap(with.value["drop"])
        XCTAssertLessThanOrEqual(notice.maxY, capsule.minY, "the notice covers the capsule")
        // It reads the reserve and adds none: nothing else moved.
        XCTAssertEqual(with.value["capsule"], without.value["capsule"])
        XCTAssertEqual(with.value["legend"], without.value["legend"])
        _ = (a, b)
    }

    func testTheUpdatingChipLiftsTheLegendOnlyWhereTheyShareAColumn() async throws {
        let services = ScriptedEditorServices()
        let model = await readyModel(services)
        model.open([URL(fileURLWithPath: "/fixtures/next.jpg")])   // the old frame stays; the chip appears after 300 ms
        var overlapped = 0
        for width in [CGFloat(900), 640, 330, 260] {
            model.updateViewport(CGSize(width: width, height: 400), backingScale: 1)
            let frames = Frames()
            let host = floating(width: width, height: 400, locale: "en", model: model, frames: frames, busy: true)
            let chip = try XCTUnwrap(frames.value["chip"], "no chip at \(width)")
            let legend = try XCTUnwrap(frames.value["legend"], "no legend at \(width)")
            if chip.minX < legend.maxX && legend.minX < chip.maxX {
                overlapped += 1
                XCTAssertLessThanOrEqual(legend.maxY, chip.minY, "the legend sits on the chip at \(width)")
            } else {
                XCTAssertEqual(legend.maxY, 400 - 12, accuracy: 1, "the chip moved a legend that it does not touch at \(width)")
            }
            _ = host
        }
        XCTAssertGreaterThan(overlapped, 0, "a narrow case where they do share a column")
        XCTAssertLessThan(overlapped, 4, "and a wide one where they do not")
    }

    func testTheChipsLiftRule() {
        let reserve = CanvasBottomReserve(status: 0, capsule: 0, chip: 30)
        XCTAssertEqual(CanvasBottomReserve.lift(reserve, columns: 0...100, chip: 200...300), 0)
        XCTAssertEqual(CanvasBottomReserve.lift(reserve, columns: 0...250, chip: 200...300), 30)
        XCTAssertEqual(CanvasBottomReserve.lift(reserve, columns: nil, chip: 200...300), 0)
        XCTAssertEqual(CanvasBottomReserve.capsuleLift(CanvasBottomReserve(status: 70, capsule: 50, chip: 30), capsule: 100...200, chip: 150...300), 100)
    }
}

@MainActor private final class ImmediateClock: EditorOpenClock {
    var now: Duration = .zero
    func sleep(until deadline: Duration) async throws {}
}
