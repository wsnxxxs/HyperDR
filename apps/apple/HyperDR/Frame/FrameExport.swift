import CoreGraphics
import Foundation
import HyperDREngine
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// What an export needs to carry a frame: the `command.frame` document, the
/// caption overlay to go with it, and the layout the engine will produce.
///
/// Nothing is written here. The export (Kit, K3) saves `overlayPNG` in its
/// own export directory and points the document's `overlay` at that file:
///
///     if let plan = try FrameExportPlan.make(settings: model.frame, facts: facts,
///                                            photoSize: exportSize) {
///         var frame = plan.frame
///         if let png = plan.overlayPNG {
///             let overlay = exportDirectory.appendingPathComponent("frame-caption.png")
///             try png.write(to: overlay)
///             frame["overlay"] = .string(overlay.path)
///         }
///         try request.setCommand("frame", .object(frame))
///     }
///
/// `photoSize` must be the size the engine renders the photograph at (its
/// oriented, cropped size after any export size limit): the engine recomputes
/// the layout from the rendered photo and rejects a caption of another size.
struct FrameExportPlan {
    /// `command.frame` without `overlay`.
    let frame: [String: JSONValue]
    /// The caption band as a PNG exactly `layout.caption`'s size; nil when
    /// the frame has no caption.
    let overlayPNG: Data?
    let layout: FramePixelLayout

    /// Nil when the frame is off. Throws the engine's error when the style
    /// rejects the frame (a hand-written spec, or a canvas over its size limits).
    static func make(settings: FrameSettings, facts: CaptureFacts,
                     photoSize: PixelSize) throws -> FrameExportPlan? {
        guard settings.isEnabled else { return nil }
        // Whether there is text does not depend on the layout the engine picks.
        let hasCaption = !settings.style.caption(settings, facts: facts).isEmpty
        let frame = settings.engineFrame(hasCaption: hasCaption)
        let layout = FramePixelLayout(try Engine.frameLayout(frame: frame, photoWidth: photoSize.width,
                                                             photoHeight: photoSize.height))
        let caption = settings.style.caption(settings, facts: facts, variant: layout.variant,
                                             bandHeight: Double(layout.caption.height) / Double(layout.referenceEdge))
        let overlay = !caption.isEmpty && layout.caption.height > 0
            ? try FrameOverlayRenderer.png(caption, settings: settings, layout: layout) : nil
        return FrameExportPlan(frame: frame, overlayPNG: overlay, layout: layout)
    }
}

/// Renders a caption band as the engine's overlay: one point per pixel,
/// Display P3, straight alpha (PNG), transparent wherever there is no text so
/// the mat and the print's shadow, which the engine draws, show through.
enum FrameOverlayRenderer {
    struct Failure: Error {}

    static func png(_ caption: FrameCaption, settings: FrameSettings, layout: FramePixelLayout) throws -> Data {
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
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString,
                                                                 1, nil)
        else { throw Failure() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure() }
        return data as Data
    }
}
