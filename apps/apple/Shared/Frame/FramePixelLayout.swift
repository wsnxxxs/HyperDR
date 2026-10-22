import HyperDREngine

/// Where a presentation frame puts the photograph and its caption, in pixels
/// of the framed image: the app's copy of the engine's `FrameLayout`, so views
/// lay out frames without reaching the engine (batch 3 §3.4). Not to be
/// confused with `FrameGeometry`, a style's proportions.
struct FramePixelLayout: Hashable, Sendable {
    struct Rect: Hashable, Sendable {
        let x, y, width, height: Int
    }

    let width, height: Int
    let photo, caption: Rect
    /// The photo edge, in pixels, that the frame's fractions measure.
    let referenceEdge: Int
    /// The layout variant the engine picked (story's "wide" or "tall"); nil for the style's default layout.
    let variant: String?

    init(width: Int, height: Int, photo: Rect, caption: Rect, referenceEdge: Int, variant: String? = nil) {
        self.width = width
        self.height = height
        self.photo = photo
        self.caption = caption
        self.referenceEdge = referenceEdge
        self.variant = variant
    }

    init(_ layout: FrameLayout) {
        self.init(width: layout.width, height: layout.height,
                  photo: Rect(layout.photo), caption: Rect(layout.caption),
                  referenceEdge: layout.referenceEdge, variant: layout.variant)
    }
}

extension FramePixelLayout.Rect {
    init(_ rect: FrameLayout.Rect) {
        self.init(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
    }
}
