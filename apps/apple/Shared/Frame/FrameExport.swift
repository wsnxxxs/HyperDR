import CoreGraphics
import Foundation
import HyperDREngine
import HyperDRKit
import HyperDRRender
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

/// What an export needs to carry a frame: the frame document, the caption
/// band drawn at the layout Kit computes for the export
/// (`ExportPlanner.frameLayout`), and Render's `FrameSnapshot`, which goes
/// into the export's `RecipeExportSnapshot` with the caption's PNG.
///
/// `photoSize` is the photograph's full oriented size; the layout applies the
/// export choice's size limit to it.
struct FrameExportPlan {
    /// `command.frame` without `overlay`.
    let frame: [String: JSONValue]
    /// The caption band as a PNG exactly `layout.caption`'s size; nil when
    /// the frame has no caption.
    let overlayPNG: Data?
    let layout: FramePixelLayout
    /// The same frame as Render composites it on export (P7-3b-U).
    let snapshot: FrameSnapshot

    /// Nil when the frame is off. Throws the engine's error when the style
    /// rejects the frame (a hand-written spec, or a canvas over its size limits).
    /// `choice` is the export's destination or format: Kit lays the card out
    /// around the photo at the size that choice writes it.
    static func make(settings: FrameSettings, facts: CaptureFacts, photoSize: PixelSize,
                     choice: ExportChoice = .custom(CustomExportFormat())) throws -> FrameExportPlan? {
        guard settings.isEnabled else { return nil }
        let frame = settings.engineFrame()
        let layout = FramePixelLayout(try ExportPlanner.frameLayout(
            frame: frame, choice: choice, photo: ExportPixelSize(width: photoSize.width, height: photoSize.height)))
        let caption = settings.style.caption(settings, facts: facts, variant: layout.variant,
                                             bandHeight: Double(layout.caption.height) / Double(layout.referenceEdge))
        let overlay = !caption.isEmpty && layout.caption.height > 0
            ? try FrameOverlayRenderer.png(caption, settings: settings, layout: layout) : nil
        return FrameExportPlan(frame: frame, overlayPNG: overlay, layout: layout,
                               snapshot: snapshot(settings, layout: layout, caption: overlay))
    }

    /// Render's frame: the mat in linear Display P3 (the tone is P3 with the
    /// sRGB transfer), the shadow's sigma and downward offset in pixels.
    private static func snapshot(_ settings: FrameSettings, layout: FramePixelLayout, caption: Data?) -> FrameSnapshot {
        func linear(_ v: Double) -> Float { Float(v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4)) }
        func rect(_ r: FramePixelLayout.Rect) -> ExportRect { ExportRect(x: r.x, y: r.y, width: r.width, height: r.height) }
        let tone = settings.tone.background, edge = Double(layout.referenceEdge)
        let shadow = settings.showsShadow ? settings.style.geometry.shadow.map {
            HyperDRRender.FrameShadow(opacity: Float($0.opacity), sigma: Float($0.blur * edge),
                                      offset: SIMD2(0, Float($0.offset * edge)))
        } : nil
        return FrameSnapshot(canvasSize: HyperDRRender.PixelSize(width: layout.width, height: layout.height),
                             photo: rect(layout.photo),
                             paper: SIMD3(linear(tone.red), linear(tone.green), linear(tone.blue)),
                             shadow: shadow ?? HyperDRRender.FrameShadow(),
                             caption: caption.map { HyperDRRender.FrameCaption(png: $0, rect: rect(layout.caption)) })
    }
}

/// Renders a caption band as the engine's overlay: one point per pixel,
/// Display P3, straight alpha (PNG), transparent wherever there is no text so
/// the mat and the print's shadow, which the engine draws, show through.
enum FrameOverlayRenderer {
    struct Failure: Error {}

    static func png(_ caption: FrameCaption, settings: FrameSettings, layout: FramePixelLayout) throws -> Data {
        guard let image = image(caption, settings: settings, layout: layout,
                                pixelWidth: layout.caption.width, pixelHeight: layout.caption.height, scale: 1)
        else { throw Failure() }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString,
                                                                 1, nil)
        else { throw Failure() }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw Failure() }
        return data as Data
    }

    /// The caption band as `pixelWidth` × `pixelHeight` pixels of Display P3,
    /// premultiplied alpha; `scale` is pixels per engine pixel (1 for the
    /// export's overlay, less for a thumbnail).
    static func image(_ caption: FrameCaption, settings: FrameSettings, layout: FramePixelLayout,
                      pixelWidth: Int, pixelHeight: Int, scale: CGFloat) -> CGImage? {
        guard pixelWidth > 0, pixelHeight > 0,
              let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let content = FrameCaptionView(caption: caption, settings: settings, layout: layout, scale: scale)
            .frame(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
            .environment(\.colorScheme, .light)
        let renderer = ImageRenderer(content: content)
        renderer.proposedSize = ProposedViewSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))
        renderer.scale = 1
        renderer.render { _, draw in draw(context) }
        return context.makeImage()
    }
}
