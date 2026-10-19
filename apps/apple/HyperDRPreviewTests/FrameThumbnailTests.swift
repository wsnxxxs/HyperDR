import AppKit
import HyperDREngine
import XCTest
@testable import HyperDR

/// Framed thumbnails (M3 §20.3 rule 2, F-T1) and the export panel's Frame row (§3.1).
@MainActor final class FrameThumbnailTests: XCTestCase {
    private let source = URL(fileURLWithPath: "/tmp/frame-thumbnail.jpg")
    private let destination = URL(fileURLWithPath: "/tmp/frame-thumbnail-result.heic")

    // MARK: Helpers

    private func solid(_ width: Int, _ height: Int, red: CGFloat, green: CGFloat, blue: CGFloat) throws -> CGImage {
        let context = try XCTUnwrap(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        // In Display P3 itself: a device RGB colour would be converted into it.
        context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.displayP3)!, components: [red, green, blue, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return try XCTUnwrap(context.makeImage())
    }

    /// 8-bit Display P3 RGBA of an image, row 0 at the top.
    private func pixels(_ image: CGImage) throws -> (width: Int, height: Int, data: [UInt8]) {
        var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = try XCTUnwrap(CGContext(data: &data, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.displayP3)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return (image.width, image.height, data)
    }

    private func pixel(_ p: (width: Int, height: Int, data: [UInt8]), _ x: Int, _ y: Int) -> [Int] {
        let i = (y * p.width + x) * 4
        return [Int(p.data[i]), Int(p.data[i + 1]), Int(p.data[i + 2])]
    }

    private func layout(_ style: FrameStyle, _ width: Int = 6000, _ height: Int = 4000) throws -> FramePixelLayout {
        try XCTUnwrap(EditorModel.frameLayout(for: style, photoWidth: width, photoHeight: height))
    }

    private func services(photoSize: PixelSize = PixelSize(width: 6000, height: 4000)) -> FakeEditorServices {
        let services = FakeEditorServices(openDelay: .zero, previewDelay: .zero)
        services.preview = EditorPreview(pixelSize: photoSize,
            source: SourceSummary(domain: .sdr, colorName: "Display P3", degradationReasons: []), hasGain: true, frame: nil)
        return services
    }

    private func ready(_ services: FakeEditorServices) async throws -> (EditorModel, PreviewFrame) {
        let photo = try TinyPhoto(); defer { photo.remove() }
        let engine = try await Engine(), session = try engine.openPreview(source: photo.url)
        defer { session.close() }
        let frame = try await session.renderFrame(EngineRequest(settings: ["preview_max_edge": .number(8)]))
        services.preview.frame = frame
        let model = EditorModel(services: services, ticker: ManualFrameTicker())
        await model.loadExportServices(); model.open([source])
        await eventually(timeout: .seconds(10)) { model.document?.phase == .ready && !model.suggestedFileName.isEmpty }
        return (model, frame)
    }

    // MARK: Geometry

    func testTheCanvasShrinksToTheLongEdgeAndNeverMagnifies() throws {
        let gallery = try layout(.gallery)
        let big = FrameThumbnailGeometry(layout: gallery, maxPixelSize: 344)
        XCTAssertEqual(max(big.width, big.height), 344)
        XCTAssertEqual(Double(big.width) / Double(big.height), Double(gallery.width) / Double(gallery.height), accuracy: 0.01)
        XCTAssertEqual(big.scale, 344.0 / Double(max(gallery.width, gallery.height)), accuracy: 1e-9)
        let small = FrameThumbnailGeometry(layout: try layout(.gallery, 100, 60), maxPixelSize: 344)
        XCTAssertEqual(small.scale, 1)
        XCTAssertEqual(small.width, try layout(.gallery, 100, 60).width)
    }

    func testThePhotographAndTheCaptionLandWhereTheLayoutPutThem() throws {
        for style in FrameStyle.allCases {
            let layout = try layout(style)
            let geometry = FrameThumbnailGeometry(layout: layout, maxPixelSize: 256)
            let s = geometry.scale
            XCTAssertEqual(Double(geometry.photo.x), Double(layout.photo.x) * s, accuracy: 1, "\(style)")
            XCTAssertEqual(Double(geometry.photo.y), Double(layout.photo.y) * s, accuracy: 1, "\(style)")
            XCTAssertEqual(Double(geometry.photo.width), Double(layout.photo.width) * s, accuracy: 1, "\(style)")
            XCTAssertEqual(Double(geometry.photo.height), Double(layout.photo.height) * s, accuracy: 1, "\(style)")
            XCTAssertLessThanOrEqual(geometry.photo.x + geometry.photo.width, geometry.width)
            XCTAssertLessThanOrEqual(geometry.photo.y + geometry.photo.height, geometry.height)
            if layout.caption.width > 0 && layout.caption.height > 0 {
                XCTAssertEqual(Double(geometry.caption.y), Double(layout.caption.y) * s, accuracy: 1, "\(style)")
                XCTAssertEqual(Double(geometry.caption.height), Double(layout.caption.height) * s, accuracy: 1, "\(style)")
                XCTAssertLessThanOrEqual(geometry.caption.y + geometry.caption.height, geometry.height)
            } else {
                XCTAssertTrue(geometry.caption.isEmpty, "\(style) has no band")
            }
        }
    }

    func testThePhotographAsksForItsOwnSizeNotTheCanvas() throws {
        let layout = try layout(.label)
        let geometry = FrameThumbnailGeometry(layout: layout, maxPixelSize: 344)
        XCTAssertEqual(geometry.photoPixelSize, max(geometry.photo.width, geometry.photo.height))
        XCTAssertLessThan(geometry.photoPixelSize, 344)
    }

    // MARK: Composition

    func testTheCardHasPaperAroundTheTonedPhotograph() throws {
        for tone in [FrameTone.paper, .ink] {
            var settings = FrameSettings(); settings.isEnabled = true; settings.style = .hairline; settings.tone = tone
            let layout = try layout(.hairline, 300, 200)
            let framing = try XCTUnwrap(FrameThumbnail.framing(settings: settings, layout: layout, facts: CaptureFacts()))
            let picture = try XCTUnwrap(FrameThumbnail.compose(photo: try solid(30, 20, red: 1, green: 0, blue: 0),
                                                               framing: framing, maxPixelSize: 100))
            let geometry = FrameThumbnailGeometry(layout: layout, maxPixelSize: 100)
            XCTAssertEqual(picture.width, geometry.width); XCTAssertEqual(picture.height, geometry.height)
            let p = try pixels(picture)
            let paper = [tone.background.red, tone.background.green, tone.background.blue].map { Int(($0 * 255).rounded()) }
            for (x, y) in [(0, 0), (picture.width - 1, 0), (0, picture.height - 1), (picture.width - 1, picture.height - 1)] {
                for (a, b) in zip(pixel(p, x, y), paper) { XCTAssertEqual(a, b, accuracy: 2, "\(tone) corner") }
            }
            let centre = pixel(p, geometry.photo.x + geometry.photo.width / 2, geometry.photo.y + geometry.photo.height / 2)
            XCTAssertGreaterThan(centre[0], 240); XCTAssertLessThan(centre[1], 20); XCTAssertLessThan(centre[2], 20)
            // Just inside the photograph's edge is already the photograph.
            let edge = pixel(p, geometry.photo.x + 1, geometry.photo.y + 1)
            XCTAssertGreaterThan(edge[0], 240)
        }
    }

    func testTheCaptionIsDrawnInItsBandOnly() throws {
        var settings = FrameSettings(); settings.isEnabled = true; settings.style = .gallery
        settings.showsExposure = false; settings.showsCamera = false; settings.showsDate = false
        let layout = try layout(.gallery)
        let blank = try XCTUnwrap(FrameThumbnail.framing(settings: settings, layout: layout, facts: CaptureFacts()))
        XCTAssertTrue(blank.caption.isEmpty)
        settings.showsCamera = true
        let facts = CaptureFacts(make: "SONY", model: "ILCE-7RM5", lens: "FE 24-70mm F2.8 GM II", focalLength: 35, fNumber: 2.8,
                                 exposureTime: 1.0 / 250, iso: 100)
        let captioned = try XCTUnwrap(FrameThumbnail.framing(settings: settings, layout: layout, facts: facts))
        XCTAssertFalse(captioned.caption.isEmpty)
        let photo = try solid(30, 20, red: 0.5, green: 0.5, blue: 0.5)
        let without = try pixels(try XCTUnwrap(FrameThumbnail.compose(photo: photo, framing: blank, maxPixelSize: 344)))
        let with = try pixels(try XCTUnwrap(FrameThumbnail.compose(photo: photo, framing: captioned, maxPixelSize: 344)))
        let geometry = FrameThumbnailGeometry(layout: layout, maxPixelSize: 344)
        var inBand = 0, outside = 0
        for y in 0..<with.height {
            for x in 0..<with.width where pixel(with, x, y) != pixel(without, x, y) {
                let band = x >= geometry.caption.x && x < geometry.caption.x + geometry.caption.width
                    && y >= geometry.caption.y && y < geometry.caption.y + geometry.caption.height
                if band { inBand += 1 } else { outside += 1 }
            }
        }
        XCTAssertGreaterThan(inBand, 0, "the text shows")
        XCTAssertEqual(outside, 0, "and only in the band")
    }

    func testNoFramingWhileTheSwitchIsOffOrTheStyleDoesNotFit() throws {
        let settings = FrameSettings()
        XCTAssertFalse(settings.isEnabled)
        XCTAssertNil(FrameThumbnail.framing(settings: settings, layout: try layout(.gallery), facts: CaptureFacts()))
        var on = settings; on.isEnabled = true
        XCTAssertNil(FrameThumbnail.framing(settings: on, layout: nil, facts: CaptureFacts()))
    }

    // MARK: Model

    func testTheSummaryPictureIsTheFramedCardWhileTheFrameIsOn() async throws {
        let photo = try solid(4, 2, red: 1, green: 0, blue: 0)
        let services = services(); services.thumbnailHandler = { _, _ in photo }
        let (model, _) = try await ready(services)
        var settings = model.frame; settings.isEnabled = true; settings.style = .label; model.frame = settings
        let layout = try XCTUnwrap(model.frameLayout)
        let geometry = FrameThumbnailGeometry(layout: layout, maxPixelSize: 344)
        let tracking = Task { await model.trackExportSummaryThumbnail() }
        defer { tracking.cancel() }
        await eventually(timeout: .seconds(10)) { if case .ready = model.exportSummaryThumbnail { true } else { false } }
        guard case .ready(let framed) = model.exportSummaryThumbnail else { return XCTFail("no picture") }
        XCTAssertEqual(framed.width, geometry.width); XCTAssertEqual(framed.height, geometry.height)
        XCTAssertEqual(services.thumbnailCalls.last, geometry.photoPixelSize, "the service shrinks only the photograph")
        // Turning the frame off puts the bare photograph back.
        settings.isEnabled = false; model.frame = settings
        await eventually(timeout: .seconds(10)) { model.exportSummaryThumbnail == .ready(photo) }
        XCTAssertEqual(services.thumbnailCalls.last, 344)
    }

    func testAnExportWithAFrameFreezesAndPassesTheFramedPicture() async throws {
        let photo = try solid(4, 2, red: 1, green: 0, blue: 0)
        let services = services(); services.thumbnailHandler = { _, _ in photo }
        let (model, _) = try await ready(services)
        var settings = model.frame; settings.isEnabled = true; settings.style = .gallery; model.frame = settings
        let geometry = FrameThumbnailGeometry(layout: try XCTUnwrap(model.frameLayout), maxPixelSize: 256)
        let tracking = Task { await model.trackExportSummaryThumbnail() }
        defer { tracking.cancel() }
        await eventually(timeout: .seconds(10)) { if case .ready = model.exportSummaryThumbnail { true } else { false } }
        model.startExport(destination: destination, token: try XCTUnwrap(model.prepareExport()))
        await eventually(timeout: .seconds(10)) { services.hasExportSubscriber }
        let passed = try XCTUnwrap(services.exportCalls[0].thumbnail)
        XCTAssertEqual(passed.width, geometry.width); XCTAssertEqual(passed.height, geometry.height)
        XCTAssertNotNil(services.exportCalls[0].frame)
        XCTAssertEqual(model.export.thumbnail, .ready(passed))
        XCTAssertLessThanOrEqual(max(passed.width, passed.height), 256)
        model.cancelExport()
        await eventually(timeout: .seconds(10)) { !model.export.isInFlight }
    }

    func testAnExportWithoutAFrameStillPassesTheBarePhotograph() async throws {
        let photo = try solid(4, 2, red: 1, green: 0, blue: 0)
        let services = services(); services.thumbnailHandler = { _, _ in photo }
        let (model, _) = try await ready(services)
        XCTAssertFalse(model.frame.isEnabled)
        let tracking = Task { await model.trackExportSummaryThumbnail() }
        defer { tracking.cancel() }
        await eventually(timeout: .seconds(10)) { model.exportSummaryThumbnail == .ready(photo) }
        model.startExport(destination: destination, token: try XCTUnwrap(model.prepareExport()))
        await eventually(timeout: .seconds(10)) { services.hasExportSubscriber }
        XCTAssertTrue(services.exportCalls[0].thumbnail === photo)
        XCTAssertNil(services.exportCalls[0].frame)
        model.cancelExport()
        await eventually(timeout: .seconds(10)) { !model.export.isInFlight }
    }

    // MARK: The Frame row

    func testTheFrameRowSaysNoneTheStyleOrThatItDoesNotFit() async throws {
        let (model, _) = try await ready(services())
        XCTAssertEqual(model.exportFrameSummary, .none)
        var settings = model.frame; settings.isEnabled = true; settings.style = .story; model.frame = settings
        XCTAssertEqual(model.exportFrameSummary, .style(.story))
        XCTAssertNil(model.export.blockerKey)
        // A photograph far wider than the Instant card can be: the engine refuses it.
        let wide = services(photoSize: PixelSize(width: 20_000, height: 100))
        let (stretched, _) = try await ready(wide)
        var instant = stretched.frame; instant.isEnabled = true; instant.style = .instant; stretched.frame = instant
        XCTAssertNil(stretched.frameLayout)
        XCTAssertEqual(stretched.exportFrameSummary, .misfit(.instant))
        XCTAssertEqual(stretched.export.blockerKey, "export.blocker.frame")
        XCTAssertNil(stretched.thumbnailFraming(), "the bare photograph stands in")
    }

    func testTheSwitchStaysLiveWhileEditingIsFree() async throws {
        let (model, _) = try await ready(services())
        XCTAssertNil(model.editingLockReason)
        model.frame.isEnabled = true
        XCTAssertTrue(model.frame.isEnabled)
        model.frame.isEnabled = false
        XCTAssertFalse(model.frame.isEnabled)
    }

    // MARK: Changing the frame from the export panel

    func testChangeFrameHandsTheWindowOverAndBack() async throws {
        let window = EditorWindowState()
        window.showsExport = true
        window.changeFrameFromExport(delay: .zero)
        XCTAssertFalse(window.showsExport)
        XCTAssertTrue(window.returnsToExport)
        await eventually(timeout: .seconds(3)) { window.isFraming }
        window.isFraming = false
        window.frameSheetClosed(canExport: true, delay: .zero)
        await eventually(timeout: .seconds(3)) { window.showsExport }
        XCTAssertFalse(window.returnsToExport)
    }

    func testClosingTheFrameSheetOpenedFromTheToolbarLeavesExportClosed() async throws {
        let window = EditorWindowState()
        window.isFraming = true; window.isFraming = false
        window.frameSheetClosed(canExport: true, delay: .zero)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(window.showsExport)
    }

    func testNoReturnToExportWhenThePhotographIsGone() async throws {
        let window = EditorWindowState()
        window.changeFrameFromExport(delay: .zero)
        await eventually(timeout: .seconds(3)) { window.isFraming }
        window.isFraming = false
        window.frameSheetClosed(canExport: false, delay: .zero)
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertFalse(window.showsExport); XCTAssertFalse(window.returnsToExport)
    }
}
