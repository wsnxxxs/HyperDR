import XCTest
import HyperDREngine
import ImageIO
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

    /// Placeholders are not facts: Sony's "----" for an unreported lens, blank
    /// or NUL-padded fields are left out of the caption.
    func testPlaceholderTextIsNotRecorded() {
        XCTAssertNil(CaptureFacts.recorded("----"))
        XCTAssertNil(CaptureFacts.recorded(" -- - "))
        XCTAssertNil(CaptureFacts.recorded("   "))
        XCTAssertNil(CaptureFacts.recorded("\0\0\0"))
        XCTAssertNil(CaptureFacts.recorded(nil))
        XCTAssertEqual(CaptureFacts.recorded(" FE 24-70mm F2.8 GM II\0"), "FE 24-70mm F2.8 GM II")
        XCTAssertEqual(CaptureFacts.recorded("-1"), "-1")
        for placeholder in ["unknown", "Unknown", " UNKNOWN ", "n/a", "N/A", "none", "None"] {
            XCTAssertNil(CaptureFacts.recorded(placeholder), placeholder)
        }
        // Only the whole value: a name that contains one of the words stays.
        XCTAssertEqual(CaptureFacts.recorded("Unknown Lens 50mm"), "Unknown Lens 50mm")
        XCTAssertEqual(CaptureFacts.recorded("None-such"), "None-such")

        let noLens = CaptureFacts(properties: [
            kCGImagePropertyTIFFDictionary: [kCGImagePropertyTIFFMake: "SONY", kCGImagePropertyTIFFModel: "ILCE-7RM5"],
            kCGImagePropertyExifDictionary: [kCGImagePropertyExifLensModel: "----"],
        ])
        XCTAssertNil(noLens.lens)
        XCTAssertNil(noLens.lensName)
        XCTAssertEqual(noLens.cameraLine, "Sony α7R V")
        // The label style prints the lens on a line of its own: none here.
        var label = FrameSettings()
        label.style = .label
        let lines = FrameStyle.label.caption(label, facts: noLens).leading.map(\.text)
        XCTAssertEqual(lines.first, "SONY α7R V")
        XCTAssertFalse(lines.contains { $0.contains("--") }, "\(lines)")
        XCTAssertEqual(lines.count, 1)
        XCTAssertNil(CaptureFacts(make: "SONY", model: "ILCE-7RM5", lens: "----").lens)
        // Body and maker too: the caption then has no camera line at all.
        let blank = CaptureFacts(make: "Unknown", model: "n/a", lens: "NONE", fNumber: 2)
        XCTAssertNil(blank.make)
        XCTAssertNil(blank.model)
        XCTAssertNil(blank.cameraLine)
        XCTAssertEqual(blank.exposureLine, "f/2")
    }

    /// Below 0.3 s, the 1/n camera stops; from 0.3 s, tenths of a second,
    /// since a rounded fraction would misstate 0.4 s as 1/3 s and 0.6 s as 1/2 s.
    func testShutterSpeeds() {
        XCTAssertEqual(CaptureFacts.shutter(1.0 / 8000), "1/8000 s")
        XCTAssertEqual(CaptureFacts.shutter(1.0 / 250), "1/250 s")
        XCTAssertEqual(CaptureFacts.shutter(1.0 / 4), "1/4 s")
        XCTAssertEqual(CaptureFacts.shutter(0.3), "0.3 s")
        XCTAssertEqual(CaptureFacts.shutter(1.0 / 3), "0.3 s")
        XCTAssertEqual(CaptureFacts.shutter(0.4), "0.4 s")
        XCTAssertEqual(CaptureFacts.shutter(0.5), "0.5 s")
        XCTAssertEqual(CaptureFacts.shutter(0.6), "0.6 s")
        XCTAssertEqual(CaptureFacts.shutter(0.8), "0.8 s")
        XCTAssertEqual(CaptureFacts.shutter(1), "1 s")
        XCTAssertEqual(CaptureFacts.shutter(1.3), "1.3 s")
        XCTAssertEqual(CaptureFacts.shutter(30), "30 s")
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

    /// Views see the engine's layout as `FramePixelLayout`, field for field.
    func testGeometryMirrorsTheEngineLayout() throws {
        var settings = FrameSettings()
        settings.isEnabled = true
        let layout = try Engine.frameLayout(frame: settings.engineFrame(hasCaption: true),
                                            photoWidth: 6000, photoHeight: 9000)
        let pixels = FramePixelLayout(layout)
        XCTAssertEqual(pixels, FramePixelLayout(
            width: 6720, height: 10500,
            photo: FramePixelLayout.Rect(x: 360, y: 360, width: 6000, height: 9000),
            caption: FramePixelLayout.Rect(x: 0, y: 9360, width: 6720, height: 1140),
            referenceEdge: layout.referenceEdge))
        // The style picker's miniatures: each style around a nominal 2:3 print.
        for style in FrameStyle.allCases {
            var styled = FrameSettings()
            styled.style = style
            let expected = try Engine.frameLayout(frame: styled.engineFrame(hasCaption: style.hasCaption),
                                                  photoWidth: 1000, photoHeight: 1500)
            XCTAssertEqual(EditorModel.frameLayout(for: style), FramePixelLayout(expected), "\(style)")
        }
    }

    /// The export plan writes nothing: it hands back the document without
    /// `overlay` and the caption as PNG data exactly the caption band's size.
    func testExportPlanCarriesTheOverlayAsData() throws {
        var settings = FrameSettings()
        settings.isEnabled = true
        let size = PixelSize(width: 1200, height: 1800)
        let plan = try XCTUnwrap(FrameExportPlan.make(settings: settings, facts: sony, photoSize: size))
        XCTAssertNil(plan.frame["overlay"])
        let engine = try Engine.frameLayout(frame: plan.frame, photoWidth: size.width, photoHeight: size.height)
        XCTAssertEqual(plan.layout, FramePixelLayout(engine))
        XCTAssertGreaterThan(plan.layout.caption.height, 0)

        let png = try XCTUnwrap(plan.overlayPNG)
        XCTAssertEqual(Array(png.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        XCTAssertEqual(String(decoding: png[12..<16], as: UTF8.self), "IHDR")
        let bigEndian = { (offset: Int) in png[offset..<offset + 4].reduce(0) { $0 << 8 | Int($1) } }
        XCTAssertEqual(bigEndian(16), plan.layout.caption.width)
        XCTAssertEqual(bigEndian(20), plan.layout.caption.height)

        // No caption, no overlay; the frame off, no plan.
        settings.style = .hairline
        XCTAssertNil(try XCTUnwrap(FrameExportPlan.make(settings: settings, facts: sony, photoSize: size)).overlayPNG)
        settings.isEnabled = false
        XCTAssertNil(try FrameExportPlan.make(settings: settings, facts: sony, photoSize: size))
    }

    /// Story's 9:16 canvas cannot take a 3.5:1 panorama (the engine's six-times
    /// area limit): the style is unavailable for it, the others are not, and
    /// the export plan refuses rather than drawing a different frame.
    /// Temporary guard until the new story design (U8) lands; remove it then.
    func testStoryDoesNotFitAWidePanorama() throws {
        let panorama = PixelSize(width: 3500, height: 1000)
        XCTAssertFalse(FrameStyle.story.fits(panorama))
        for style in FrameStyle.allCases where style != .story {
            XCTAssertTrue(style.fits(panorama), "\(style)")
        }
        XCTAssertTrue(FrameStyle.story.fits(PixelSize(width: 3000, height: 1000)))
        XCTAssertTrue(FrameStyle.story.fits(nil))

        var story = FrameSettings()
        story.isEnabled = true
        story.style = .story
        XCTAssertThrowsError(try FrameExportPlan.make(settings: story, facts: sony, photoSize: panorama))

        // What the sheet shows instead: the photograph alone.
        let bare = FramePixelLayout.unframed(panorama)
        XCTAssertEqual(bare.photo, FramePixelLayout.Rect(x: 0, y: 0, width: 3500, height: 1000))
        XCTAssertEqual(bare.width, 3500)
        XCTAssertEqual(bare.caption.height, 0)
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
