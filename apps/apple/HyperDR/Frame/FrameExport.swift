import CoreGraphics
import Foundation
import HyperDREngine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// What an export needs to carry a frame: the `command.frame` document and
/// the layout the engine will produce for it.
///
/// M3 attaches it to the export request:
///
///     if let plan = try FrameExportPlan.make(settings: model.frame, facts: facts,
///                                            photoSize: exportSize, directory: exportDirectory) {
///         try request.setCommand("frame", .object(plan.frame))
///     }
///
/// `photoSize` must be the size the engine renders the photograph at (its
/// oriented, cropped size after any export size limit): the engine recomputes
/// the layout from the rendered photo and rejects a caption of another size.
struct FrameExportPlan {
    let frame: [String: JSONValue]
    let layout: FrameLayout

    static func make(settings: FrameSettings, facts: CaptureFacts, photoSize: PixelSize,
                     directory: URL) throws -> FrameExportPlan? {
        guard settings.isEnabled else { return nil }
        let caption = settings.style.caption(settings, facts: facts)
        var frame = settings.engineFrame(hasCaption: !caption.isEmpty)
        let layout = try Engine.frameLayout(frame: frame, photoWidth: photoSize.width,
                                            photoHeight: photoSize.height)
        if !caption.isEmpty, layout.caption.height > 0 {
            let overlay = directory.appendingPathComponent("frame-caption.png")
            try FrameOverlayRenderer.write(caption, settings: settings, layout: layout, to: overlay)
            frame["overlay"] = .string(overlay.path)
        }
        return FrameExportPlan(frame: frame, layout: layout)
    }
}

/// Renders a caption band as the engine's overlay: one point per pixel,
/// Display P3, straight alpha (PNG), transparent wherever there is no text so
/// the mat and the print's shadow, which the engine draws, show through.
enum FrameOverlayRenderer {
    struct Failure: Error {}

    static func write(_ caption: FrameCaption, settings: FrameSettings, layout: FrameLayout, to url: URL) throws {
        let band = layout.caption
        guard band.width > 0, band.height > 0,
              let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: band.width, height: band.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { throw Failure() }
        let content = FrameCaptionView(caption: caption, settings: settings, layout: layout, scale: 1)
            .frame(width: CGFloat(band.width), height: CGFloat(band.height))
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: CGFloat(band.width), height: CGFloat(band.height))
        renderer.scale = 1
        renderer.render { _, draw in draw(context) }
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)
        else { throw Failure() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure() }
    }
}
