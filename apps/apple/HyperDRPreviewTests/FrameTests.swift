import XCTest
import HyperDREngine
import ImageIO
import AppKit
import SwiftUI
import HyperDRDesign
import UniformTypeIdentifiers
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

    private func storyLayout(_ width: Int, _ height: Int, hasCaption: Bool = true) throws -> FramePixelLayout {
        var settings = FrameSettings()
        settings.isEnabled = true
        settings.style = .story
        return FramePixelLayout(try Engine.frameLayout(frame: settings.engineFrame(hasCaption: hasCaption),
                                                       photoWidth: width, photoHeight: height))
    }

    private func expect(_ layout: FramePixelLayout, _ width: Int, _ height: Int, photo: [Int], caption: [Int],
                        reference: Int, variant: String?, line: UInt = #line) {
        XCTAssertEqual(layout.width, width, line: line)
        XCTAssertEqual(layout.height, height, line: line)
        XCTAssertEqual(layout.photo, .init(x: photo[0], y: photo[1], width: photo[2], height: photo[3]), line: line)
        XCTAssertEqual(layout.caption, .init(x: caption[0], y: caption[1], width: caption[2], height: caption[3]), line: line)
        XCTAssertEqual(layout.referenceEdge, reference, line: line)
        XCTAssertEqual(layout.variant, variant, line: line)
    }

    /// story's layouts by photograph proportion (frame-story-panorama §5.1).
    func testStoryVariantsFollowThePhotoProportion() throws {
        expect(try storyLayout(1000, 4000), 2393, 4254, photo: [696, 54, 1000, 4000],
               caption: [0, 4054, 2393, 200], reference: 1000, variant: nil)
        expect(try storyLayout(4000, 1000), 4160, 1400, photo: [80, 80, 4000, 1000],
               caption: [0, 1080, 4160, 320], reference: 4000, variant: "wide")
        expect(try storyLayout(10000, 1000), 10400, 2000, photo: [200, 200, 10000, 1000],
               caption: [0, 1200, 10400, 800], reference: 10000, variant: "wide")
        expect(try storyLayout(2500, 1000), 2608, 4636, photo: [54, 1474, 2500, 1000],
               caption: [0, 2474, 2608, 2162], reference: 1000, variant: nil)
        expect(try storyLayout(2600, 1000), 2704, 1260, photo: [52, 52, 2600, 1000],
               caption: [0, 1052, 2704, 208], reference: 2600, variant: "wide")
        expect(try storyLayout(1000, 9000), 1108, 9254, photo: [54, 54, 1000, 9000],
               caption: [0, 9054, 1108, 200], reference: 1000, variant: "tall")
        expect(try storyLayout(6000, 4000), 6440, 11449, photo: [220, 2920, 6000, 4000],
               caption: [0, 6920, 6440, 4529], reference: 4000, variant: nil)
        // Without text the band shrinks to the mat, in the variant as well.
        expect(try storyLayout(4000, 1000, hasCaption: false), 4160, 1160, photo: [80, 80, 4000, 1000],
               caption: [0, 1080, 4160, 80], reference: 4000, variant: "wide")
    }

    func testEngineDocumentWritesTheVariants() {
        var settings = FrameSettings()
        settings.style = .story
        func variants(_ hasCaption: Bool) -> [String: [String: JSONValue]] {
            guard case .object(let all)? = settings.engineFrame(hasCaption: hasCaption)["variants"] else { return [:] }
            return all.compactMapValues { if case .object(let entry) = $0 { entry } else { nil } }
        }
        let wide = variants(true)["wide"]
        XCTAssertEqual(wide?["minRatio"], .number(2.5))
        XCTAssertEqual(wide?["reference"], .string("long"))
        XCTAssertEqual(wide?["caption"], .number(0.06))
        XCTAssertEqual(wide?["aspect"], .null)
        XCTAssertEqual(variants(true)["tall"]?["maxRatio"], .number(0.125))
        XCTAssertNil(variants(true)["tall"]?["caption"])
        // No text: the top level and every variant lose the band.
        XCTAssertEqual(settings.engineFrame(hasCaption: false)["caption"], .number(0))
        XCTAssertEqual(variants(false)["wide"]?["caption"], .number(0))
        XCTAssertEqual(variants(false)["tall"]?["caption"], .number(0))
        // The other styles have none.
        settings.style = .gallery
        XCTAssertNil(settings.engineFrame(hasCaption: true)["variants"])
    }

    /// Captions that fit are set exactly as before long text was bounded:
    /// the overlay of every style, tone, photo shape and text combination is
    /// pixel-identical to the frozen reference view's.
    func testOrdinaryCaptionsMatchTheReferenceLayout() throws {
        func pixels(_ draw: (CGContext) -> Void, _ band: FramePixelLayout.Rect) throws -> Data {
            let context = try XCTUnwrap(CGContext(data: nil, width: band.width, height: band.height,
                bitsPerComponent: 8, bytesPerRow: band.width * 4, space: CGColorSpace(name: CGColorSpace.displayP3)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            draw(context)
            return Data(bytes: try XCTUnwrap(context.data), count: band.width * band.height * 4)
        }
        var compared = 0
        for style in FrameStyle.allCases {
            for (width, height) in [(1000, 1500), (1500, 1000), (1000, 4000)] {
                for tone in [FrameTone.paper, .ink] {
                    for mask in 0..<17 {
                        var settings = FrameSettings()
                        settings.isEnabled = true
                        settings.style = style
                        settings.tone = tone
                        settings.showsExposure = mask == 16 || mask & 1 != 0
                        settings.showsCamera = mask == 16 || mask & 2 != 0
                        settings.showsDate = mask == 16 || mask & 4 != 0
                        settings.signature = mask == 16 ? "林伟" : (mask & 8 != 0 ? "Lin Wei" : "")
                        let hasCaption = !style.caption(settings, facts: sony).isEmpty
                        let layout = FramePixelLayout(try Engine.frameLayout(
                            frame: settings.engineFrame(hasCaption: hasCaption), photoWidth: width, photoHeight: height))
                        guard layout.caption.height > 0, layout.caption.width > 0 else { continue }
                        XCTAssertNil(layout.variant)
                        let caption = style.caption(settings, facts: sony, variant: layout.variant,
                            bandHeight: Double(layout.caption.height) / Double(layout.referenceEdge))
                        let size = CGSize(width: layout.caption.width, height: layout.caption.height)
                        func render<V: View>(_ view: V) throws -> Data {
                            let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
                                .environment(\.colorScheme, .light))
                            renderer.proposedSize = ProposedViewSize(size)
                            renderer.scale = 1
                            return try pixels({ context in renderer.render { _, draw in draw(context) } }, layout.caption)
                        }
                        let now = try render(FrameCaptionView(caption: caption, settings: settings, layout: layout, scale: 1))
                        let before = try render(ReferenceFrameCaptionView(caption: caption, settings: settings,
                                                                          layout: layout, scale: 1))
                        XCTAssertTrue(now == before, "\(style) \(width)x\(height) \(tone) \(mask): overlay differs")
                        compared += 1
                    }
                }
            }
        }
        XCTAssertGreaterThan(compared, 400)
    }

    /// The laid-out frame of every caption line, measured on the rendered view.
    private func lineFrames(_ settings: FrameSettings, facts: CaptureFacts, layout: FramePixelLayout,
                            file: StaticString = #filePath, line: UInt = #line)
        -> (caption: FrameCaption, frames: [Int: CGRect]) {
        let caption = settings.style.caption(settings, facts: facts, variant: layout.variant,
            bandHeight: Double(layout.caption.height) / Double(layout.referenceEdge))
        var frames: [Int: CGRect] = [:]
        let view = FrameCaptionView(caption: caption, settings: settings, layout: layout, scale: 1,
                                    onLineFrames: { frames = $0 })
            .frame(width: CGFloat(layout.caption.width), height: CGFloat(layout.caption.height))
        let renderer = ImageRenderer(content: view)
        renderer.scale = 1
        renderer.render { _, draw in
            let context = CGContext(data: nil, width: layout.caption.width, height: layout.caption.height,
                                    bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            draw(context)
        }
        return (caption, frames)
    }

    /// The part of the band the text may use: all of it, but in a wide card
    /// the bottom mat stays clear.
    private func textBand(_ layout: FramePixelLayout) -> CGRect {
        var band = CGRect(x: 0, y: 0, width: layout.caption.width, height: layout.caption.height)
        if layout.variant == "wide" {
            band.size.height -= CGFloat(layout.height - layout.photo.y - layout.photo.height - layout.caption.height)
            band.size.height -= CGFloat(layout.photo.y)
        }
        return band
    }

    private func assertInside(_ frames: [Int: CGRect], _ band: CGRect, _ label: String,
                              file: StaticString = #filePath, line: UInt = #line) {
        for (id, frame) in frames {
            XCTAssertTrue(band.insetBy(dx: -0.5, dy: -0.5).contains(frame),
                          "\(label) line \(id) \(frame) outside \(band)", file: file, line: line)
        }
    }

    /// With all four lines on, no line of the caption is cut off by the band
    /// -- measured on the rendered view -- in the portrait, tall and wide cards.
    func testCaptionLinesStayInsideTheBand() throws {
        var settings = FrameSettings()
        settings.isEnabled = true
        settings.style = .story
        settings.showsDate = true
        settings.signature = "Lin Wei"
        let cases: [(Int, Int, String?)] = [(1000, 4000, nil), (900, 1600, nil), (1000, 9000, "tall"),
                                            (2600, 1000, "wide"), (4000, 1000, "wide"), (10000, 1000, "wide"),
                                            (3000, 2000, nil)]
        for (width, height, variant) in cases {
            let layout = try storyLayout(width, height)
            XCTAssertEqual(layout.variant, variant, "\(width)x\(height)")
            let (caption, frames) = lineFrames(settings, facts: sony, layout: layout)
            XCTAssertEqual(caption.leading.count + caption.center.count + caption.trailing.count, 4)
            XCTAssertEqual(frames.count, 4, "\(width)x\(height): lines measured")
            let band = textBand(layout)
            assertInside(frames, band, "\(width)x\(height)")
            if variant == "wide" {
                let left = frames.values.filter { $0.minX < band.midX }.map(\.maxX).max() ?? 0
                let right = frames.values.filter { $0.minX >= band.midX }.map(\.minX).min() ?? .infinity
                XCTAssertLessThan(left, right, "wide columns overlap")
            }
        }
    }

    /// A long signature, camera or lens never runs into another line or out of
    /// the band: it shrinks, then is cut, on one line -- in every card.
    func testLongTextStaysInItsColumn() throws {
        var settings = FrameSettings()
        settings.isEnabled = true
        settings.style = .story
        settings.showsDate = true
        settings.signature = String(repeating: "Alexandra Smith ", count: 8)
        var facts = sony
        facts.lens = String(repeating: "Extraordinarily Long Lens Name ", count: 6)
        for (width, height) in [(2600, 1000), (4000, 1000), (10000, 1000), (1000, 4000), (1000, 9000), (3000, 2000)] {
            let layout = try storyLayout(width, height)
            for facts in [sony, facts] {
                let (caption, frames) = lineFrames(settings, facts: facts, layout: layout)
                let label = "\(width)x\(height)"
                XCTAssertEqual(frames.count, caption.leading.count + caption.center.count + caption.trailing.count, label)
                let band = textBand(layout)
                assertInside(frames, band, label)
                guard layout.variant == "wide" else {
                    // One column: every line within the card's margins.
                    let margin = CGFloat(FrameStyle.story.geometry.applying(layout.variant).left * Double(layout.referenceEdge))
                    assertInside(frames, band.insetBy(dx: margin, dy: 0), label + " margins")
                    continue
                }
                let left = caption.leading.compactMap { frames[$0.id] }
                let right = caption.trailing.compactMap { frames[$0.id] }
                XCTAssertFalse(right.isEmpty, label)
                for l in left { for r in right { XCTAssertFalse(l.intersects(r), "\(label) \(l) \(r)") } }
                let gap = 0.02 * CGFloat(layout.referenceEdge)
                XCTAssertGreaterThanOrEqual((right.map(\.minX).min() ?? 0) - (left.map(\.maxX).max() ?? 0), gap - 0.5, label)
                XCTAssertLessThanOrEqual(right.map(\.width).max() ?? 0, CGFloat(layout.width) * 0.4 + 0.5, label)
            }
        }
    }

    /// With no text there is nothing to keep readable: the preview fits the
    /// window instead of forcing a scroll at the minimum size.
    func testPreviewScaleIgnoresAnEmptyCaption() throws {
        var settings = FrameSettings()
        settings.isEnabled = true
        settings.style = .story
        settings.showsExposure = false
        settings.showsCamera = false
        settings.signature = ""
        let layout = try storyLayout(4000, 1000, hasCaption: false)
        let empty = settings.style.caption(settings, facts: sony, variant: "wide")
        XCTAssertTrue(empty.isEmpty)
        XCTAssertEqual(FrameSheet.previewScale(fit: 0.2, layout: layout, settings: settings, caption: empty), 0.2)
        settings.showsExposure = true
        let text = settings.style.caption(settings, facts: sony, variant: "wide")
        let full = try storyLayout(4000, 1000)
        let scale = FrameSheet.previewScale(fit: 0.2, layout: full, settings: settings, caption: text)
        XCTAssertGreaterThan(scale, 0.2)
        XCTAssertEqual(scale * CGFloat(full.referenceEdge) * 0.010, FrameSheet.minimumBodyPoints, accuracy: 0.001)
    }

    /// story takes a panorama: selectable, a landscape card, and an export plan
    /// whose overlay is the card's band.
    func testStoryAcceptsAWidePanorama() throws {
        let panorama = PixelSize(width: 3500, height: 1000)
        for style in FrameStyle.allCases {
            let layout = try XCTUnwrap(EditorModel.frameLayout(for: style, photoSize: panorama), "\(style)")
            XCTAssertEqual(layout.variant, style == .story ? "wide" : nil, "\(style)")
        }
        var story = FrameSettings()
        story.isEnabled = true
        story.style = .story
        let plan = try XCTUnwrap(FrameExportPlan.make(settings: story, facts: sony, photoSize: panorama))
        XCTAssertEqual(plan.layout.variant, "wide")
        XCTAssertGreaterThan(plan.layout.width, plan.layout.height)
        XCTAssertNotNil(plan.overlayPNG)
        XCTAssertEqual(FrameStyle.variantNote("wide") != nil, true)
        // A canvas past the engine's size limit is still refused.
        XCTAssertThrowsError(try FrameExportPlan.make(settings: story, facts: sony,
                                                      photoSize: PixelSize(width: 60000, height: 1000)))
    }

    /// Offscreen screenshots of the story variants for the design folder;
    /// written only when FRAME_SNAPSHOT is set, to `frame-story-snapshots` in
    /// the test host's temporary directory (the host is sandboxed; the path is
    /// printed). No window is shown and no input is sent.
    func testWriteStoryVariantSnapshots() throws {
        guard ProcessInfo.processInfo.environment["FRAME_SNAPSHOT"] != nil else {
            throw XCTSkip("FRAME_SNAPSHOT not set")
        }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("frame-story-snapshots")
        print("FRAME_SNAPSHOT_PATH=\(folder.path)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let long = String(repeating: "Alexandra Smith ", count: 8)
        let photos: [(String, Int, Int, String)] = [("wide-4x1", 4000, 1000, "Lin Wei"), ("wide-10x1", 10000, 1000, "Lin Wei"),
                                                    ("tall-1x9", 1000, 9000, "Lin Wei"), ("card-3x2", 6000, 4000, "Lin Wei"),
                                                    ("wide-4x1-long", 4000, 1000, long)]
        for (name, width, height, signature) in photos {
            for locale in ["en", "zh-Hans"] {
                for scheme in [ColorScheme.light, .dark] {
                    var settings = FrameSettings()
                    settings.isEnabled = true
                    settings.style = .story
                    settings.showsDate = true
                    settings.signature = signature
                    let layout = try storyLayout(width, height)
                    let caption = settings.style.caption(settings, facts: sony, variant: layout.variant,
                        bandHeight: Double(layout.caption.height) / Double(layout.referenceEdge))
                    let area = CGSize(width: 760, height: 560)
                    var scale = min(area.width / CGFloat(layout.width), area.height / CGFloat(layout.height))
                    if let body = settings.style.bodySize(variant: layout.variant) {
                        scale = max(scale, 10 / (CGFloat(body) * CGFloat(layout.referenceEdge)))
                    }
                    let canvas = CGSize(width: CGFloat(layout.width) * scale, height: CGFloat(layout.height) * scale)
                    let view = HStack(spacing: 0) {
                        // A wide card past the area is cut where the sheet would scroll.
                        FramedPhoto(layout: layout, settings: settings, caption: caption) {
                            LinearGradient(colors: [.orange, .purple, .blue], startPoint: .leading, endPoint: .trailing)
                        }
                        .frame(width: canvas.width, height: canvas.height)
                        .frame(width: area.width, height: area.height, alignment: canvas.width > area.width ? .leading : .center)
                        .clipped()
                        .background(Color.hdr.previewBackdrop)
                        Divider()
                        FrameSettingsPanel(settings: .constant(settings),
                                           photoSize: PixelSize(width: width, height: height))
                            .padding(Layout.panelPadding)
                            .frame(width: 340, height: area.height, alignment: .top)
                            .background(Color.hdr.surfacePanel)
                    }
                    .environment(\.colorScheme, scheme)
                    .environment(\.locale, Locale(identifier: locale))
                    .frame(width: area.width + 341, height: area.height)
                    let renderer = ImageRenderer(content: view)
                    renderer.scale = 2
                    let image = try XCTUnwrap(renderer.nsImage, "\(name)")
                    let tiff = try XCTUnwrap(image.tiffRepresentation)
                    let png = try XCTUnwrap(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
                    try png.write(to: folder.appendingPathComponent(
                        "frame-story-\(name)-\(locale)-\(scheme == .dark ? "dark" : "light").png"))
                }
            }
        }
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

private enum ReferenceFrameCaptionSpace { static let name = "FrameCaptionBand" }

private struct ReferenceFrameLineFramesKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue()) { $1 }
    }
}

/// The caption view as it was before long text was bounded (a frozen copy):
/// the reference that ordinary captions must still match pixel for pixel.
private struct ReferenceFrameCaptionView: View {
    let caption: FrameCaption
    let settings: FrameSettings
    let layout: FramePixelLayout
    /// Points per engine pixel.
    let scale: CGFloat
    /// Told where each line was laid out, by line id, in the band's own
    /// coordinates; tests use it to check that no line is cut off.
    var onLineFrames: (([Int: CGRect]) -> Void)? = nil

    private var reference: CGFloat { CGFloat(layout.referenceEdge) * scale }

    var body: some View {
        let band = CGSize(width: CGFloat(layout.caption.width) * scale,
                          height: CGFloat(layout.caption.height) * scale)
        let place = placement(in: band.height)
        ZStack(alignment: place.alignment) {
            column(caption.center, alignment: .center)
                .frame(maxWidth: .infinity, alignment: .center)
            column(caption.leading, alignment: .leading)
                .padding(.leading, CGFloat(layout.photo.x) * scale)
                .frame(maxWidth: .infinity, alignment: .leading)
            column(caption.trailing, alignment: .trailing)
                .padding(.trailing, CGFloat(layout.width - layout.photo.x - layout.photo.width) * scale)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(width: band.width, height: place.height, alignment: place.alignment)
        .padding(.top, place.offset)
        .frame(width: band.width, height: band.height, alignment: .top)
        .coordinateSpace(name: ReferenceFrameCaptionSpace.name)
        .onPreferenceChange(ReferenceFrameLineFramesKey.self) { onLineFrames?($0) }
        .accessibilityElement(children: .combine)
    }

    /// Where the text sits inside the band.
    private struct Placement {
        var offset: CGFloat
        var height: CGFloat
        var alignment: Alignment
    }

    private func placement(in height: CGFloat) -> Placement {
        switch caption.placement {
        case .middle(let abovePaperMargin):
            let margin = abovePaperMargin
                ? settings.style.geometry.applying(layout.variant).bottom * reference : 0
            return Placement(offset: 0, height: max(0, height - margin), alignment: .center)
        case .top(let fraction):
            let offset = fraction * reference
            return Placement(offset: offset, height: max(0, height - offset), alignment: .top)
        }
    }

    private func column(_ lines: [FrameCaptionLine], alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 0) {
            ForEach(lines) { line in
                Text(verbatim: line.text)
                    .font(font(line))
                    .tracking(line.tracking * line.size * reference)
                    .foregroundStyle((line.ink == .primary ? settings.tone.primaryInk : settings.tone.secondaryInk).color)
                    .lineLimit(1)
                    .fixedSize()
                    .background {
                        GeometryReader { proxy in
                            Color.clear.preference(key: ReferenceFrameLineFramesKey.self,
                                                   value: [line.id: proxy.frame(in: .named(ReferenceFrameCaptionSpace.name))])
                        }
                    }
                    .padding(.top, line.gap * reference)
            }
        }
    }

    private func font(_ line: FrameCaptionLine) -> Font {
        let size = line.size * reference
        switch line.face {
        case .text: return .system(size: size).monospacedDigit()
        case .semibold: return .system(size: size, weight: .semibold)
        // New York italic: a signature set in type rather than a script face.
        case .signature: return .system(size: size, design: .serif).italic()
        }
    }
}
