import XCTest
import HyperDREngine
@testable import HyperDR

@MainActor final class FrameTests: XCTestCase {
    private let sony = CaptureFacts(make: "SONY", model: "ILCE-7RM5", lens: "FE 24-70mm F2.8 GM II",
        focalLength: 35, fNumber: 8, exposureTime: 1.0 / 250, iso: 100, dateTimeOriginal: "2026:09:21 17:42:10")

    func testCaptionTextIsPhotographic() {
        XCTAssertEqual(sony.exposureLine, "35 mm  ·  f/8  ·  1/250 s  ·  ISO 100")
        XCTAssertEqual(sony.cameraName, "Sony α7R V")
        XCTAssertEqual(sony.lensName, "FE 24–70mm F2.8 GM II")
        XCTAssertEqual(sony.dateLine, "2026.09.21")
        XCTAssertEqual(CaptureFacts.decimal(2.8), "2.8")
        XCTAssertEqual(CaptureFacts.decimal(18.3), "18.3")
        XCTAssertEqual(CaptureFacts.shutter(1.0 / 3), "1/3 s")
        XCTAssertEqual(CaptureFacts.shutter(0.8), "0.8 s")
        XCTAssertEqual(CaptureFacts.shutter(30), "30 s")
        XCTAssertEqual(CaptureFacts.sonyAlpha("ILCE-1M2"), "α1 II")
        XCTAssertEqual(CaptureFacts.sonyAlpha("ILCE-6700"), "α6700")
        XCTAssertEqual(CaptureFacts(make: "RICOH IMAGING COMPANY, LTD.", model: "RICOH GR IIIx").cameraName,
                       "Ricoh GR IIIx")
        XCTAssertEqual(CaptureFacts(make: "Apple", model: "iPhone 17 Pro").cameraName, "iPhone 17 Pro")
        XCTAssertEqual(CaptureFacts(make: "NIKON CORPORATION", model: "NIKON Z 8").cameraName, "Nikon Z 8")
        // Only what was recorded is shown.
        XCTAssertEqual(CaptureFacts(fNumber: 1.4, iso: 3200).exposureLine, "f/1.4  ·  ISO 3200")
        XCTAssertNil(CaptureFacts().exposureLine)
    }

    func testEngineDocumentFollowsTheSettings() {
        var settings = FrameSettings()
        settings.isEnabled = true
        let gallery = settings.engineFrame(hasCaption: true)
        XCTAssertEqual(gallery["background"], .string("#F5F3EE"))
        XCTAssertEqual(gallery["caption"], .number(0.13))
        XCTAssertNotNil(gallery["shadow"])
        XCTAssertNil(gallery["aspect"])
        // No text, no band: the gallery mat is then even on every side.
        XCTAssertEqual(settings.engineFrame(hasCaption: false)["caption"], .number(0))
        settings.showsShadow = false
        settings.style = .story
        settings.tone = .ink
        let story = settings.engineFrame(hasCaption: true, overlay: URL(fileURLWithPath: "/tmp/caption.png"))
        XCTAssertEqual(story["background"], .string("#0D0D0F"))
        XCTAssertEqual(story["aspect"], .object(["width": .number(9), "height": .number(16), "topShare": .number(0.42)]))
        XCTAssertNil(story["shadow"])
        XCTAssertEqual(story["overlay"], .string("/tmp/caption.png"))
    }

    func testCaptionsFollowTheStyle() throws {
        var settings = FrameSettings()
        settings.signature = "  Lin  "
        let gallery = FrameStyle.gallery.caption(settings, facts: sony)
        XCTAssertEqual(gallery.center.map(\.text),
                       [try XCTUnwrap(sony.exposureLine), try XCTUnwrap(sony.cameraLine), "Lin"])
        XCTAssertEqual(gallery.center.first?.gap, 0)
        let label = FrameStyle.label.caption(settings, facts: sony)
        XCTAssertEqual(label.leading.first?.text, "SONY α7R V")
        XCTAssertEqual(label.trailing.map(\.text), ["Lin"])
        settings.signature = ""
        XCTAssertEqual(FrameStyle.instant.caption(settings, facts: sony).leading.map(\.text), ["Sony α7R V"])
        XCTAssertTrue(FrameStyle.hairline.caption(settings, facts: sony).isEmpty)
        settings.showsExposure = false
        settings.showsCamera = false
        XCTAssertTrue(FrameStyle.gallery.caption(settings, facts: sony).isEmpty)
    }

    func testEngineLaysOutTheSettings() throws {
        var settings = FrameSettings()
        settings.isEnabled = true
        let layout = try Engine.frameLayout(frame: settings.engineFrame(hasCaption: true),
                                            photoWidth: 6000, photoHeight: 9000)
        // 6% and 13% of the 6000-pixel short edge.
        XCTAssertEqual(layout.width, 6720)
        XCTAssertEqual(layout.height, 10500)
        XCTAssertEqual(layout.photo, FrameLayout.Rect(x: 360, y: 360, width: 6000, height: 9000))
        XCTAssertEqual(layout.caption, FrameLayout.Rect(x: 0, y: 9360, width: 6720, height: 1140))
    }

    func testSettingsRoundTripThroughDefaults() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "FrameTests"))
        defer { defaults.removePersistentDomain(forName: "FrameTests") }
        var settings = FrameSettings()
        settings.style = .label
        settings.signature = "Lin"
        settings.save(to: defaults)
        XCTAssertEqual(FrameSettings.load(from: defaults), settings)
    }
}
