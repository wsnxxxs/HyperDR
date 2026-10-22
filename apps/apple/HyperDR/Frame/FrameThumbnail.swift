import CoreGraphics
import Foundation
import SwiftUI

/// Everything a thumbnail needs to show the frame an export will carry, taken
/// at one moment so a picture built while the settings change still matches
/// the photograph it was built from.
struct ThumbnailFraming: Equatable {
    let layout: FramePixelLayout
    let settings: FrameSettings
    /// What the caption band says; empty when the frame has no text.
    let caption: FrameCaption
}

/// Where the parts of a framed export fall in a thumbnail: the layout scaled
/// so the canvas fits `maxPixelSize` on its long edge (M3 §20.3 rule 2). Pure
/// arithmetic, so the placement is checked without drawing anything.
struct FrameThumbnailGeometry: Equatable {
    struct Rect: Equatable {
        var x, y, width, height: Int
        var isEmpty: Bool { width <= 0 || height <= 0 }
    }

    /// Thumbnail pixels per engine pixel; at most 1, a thumbnail never magnifies.
    let scale: Double
    let width, height: Int
    let photo, caption: Rect

    init(layout: FramePixelLayout, maxPixelSize: Int) {
        let longEdge = max(layout.width, layout.height, 1)
        let scale = min(1, Double(max(maxPixelSize, 1)) / Double(longEdge))
        let width = max(1, Int((Double(layout.width) * scale).rounded()))
        let height = max(1, Int((Double(layout.height) * scale).rounded()))
        // Both edges of a rectangle are rounded, not its origin and size, so
        // neighbours (the photograph and the band under it) still touch.
        func rect(_ source: FramePixelLayout.Rect) -> Rect {
            let x0 = min(width, Int((Double(source.x) * scale).rounded()))
            let y0 = min(height, Int((Double(source.y) * scale).rounded()))
            let x1 = min(width, Int((Double(source.x + source.width) * scale).rounded()))
            let y1 = min(height, Int((Double(source.y + source.height) * scale).rounded()))
            return Rect(x: x0, y: y0, width: max(0, x1 - x0), height: max(0, y1 - y0))
        }
        self.scale = scale
        self.width = width
        self.height = height
        photo = rect(layout.photo)
        caption = layout.caption.width > 0 && layout.caption.height > 0 ? rect(layout.caption) : Rect(x: 0, y: 0, width: 0, height: 0)
    }

    /// The long edge to ask for when shrinking the photograph itself.
    var photoPixelSize: Int { max(photo.width, photo.height, 1) }
}

/// Builds the picture of a framed export: the paper, the photograph's SDR
/// base on it, the caption on the band. The print's shadow is left out; at
/// this size it is under a pixel.
enum FrameThumbnail {
    static func framing(settings: FrameSettings, layout: FramePixelLayout?, facts: CaptureFacts) -> ThumbnailFraming? {
        guard settings.isEnabled, let layout else { return nil }
        let caption = settings.style.caption(settings, facts: facts, variant: layout.variant,
                                             bandHeight: layout.referenceEdge > 0
                                                 ? Double(layout.caption.height) / Double(layout.referenceEdge) : nil)
        return ThumbnailFraming(layout: layout, settings: settings, caption: caption)
    }

    /// `photo` is the photograph's SDR picture (its proportions are those of
    /// `framing.layout.photo`); the result is 8-bit Display P3.
    static func compose(photo: CGImage, framing: ThumbnailFraming, maxPixelSize: Int) -> CGImage? {
        let geometry = FrameThumbnailGeometry(layout: framing.layout, maxPixelSize: maxPixelSize)
        guard !geometry.photo.isEmpty, let space = CGColorSpace(name: CGColorSpace.displayP3),
              let context = CGContext(data: nil, width: geometry.width, height: geometry.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        let paper = framing.settings.tone.background
        context.setFillColor(CGColor(colorSpace: space, components: [paper.red, paper.green, paper.blue, 1]) ?? CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: geometry.width, height: geometry.height))
        context.interpolationQuality = .high
        context.draw(photo, in: bounds(geometry.photo, canvasHeight: geometry.height))
        if !framing.caption.isEmpty, !geometry.caption.isEmpty,
           let band = FrameOverlayRenderer.image(framing.caption, settings: framing.settings, layout: framing.layout,
                                                 pixelWidth: geometry.caption.width, pixelHeight: geometry.caption.height,
                                                 scale: geometry.scale) {
            context.draw(band, in: bounds(geometry.caption, canvasHeight: geometry.height))
        }
        return context.makeImage()
    }

    /// CoreGraphics counts rows from the bottom.
    private static func bounds(_ rect: FrameThumbnailGeometry.Rect, canvasHeight: Int) -> CGRect {
        CGRect(x: rect.x, y: canvasHeight - rect.y - rect.height, width: rect.width, height: rect.height)
    }
}
