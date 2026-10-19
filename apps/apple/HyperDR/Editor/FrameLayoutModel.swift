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

extension EditorModel {
    /// The frame around the full-size photograph, or the bare photograph while
    /// the frame is off; nil without a photo size. A synchronous, pure engine
    /// computation (§3.1).
    var frameLayout: FramePixelLayout? {
        guard let size = document?.pixelSize else { return nil }
        let spec = frame.isEnabled ? frame.engineFrame(hasCaption: !frameCaption.isEmpty) : [:]
        return (try? Engine.frameLayout(frame: spec, photoWidth: size.width, photoHeight: size.height))
            .map(FramePixelLayout.init)
    }

    /// What the export panel's Frame row says (M3 §3.1).
    enum FrameSummary: Equatable {
        /// The switch is off: the export has no frame.
        case none
        /// The export carries this style.
        case style(FrameStyle)
        /// The switch is on but the engine refuses the style for this photograph's proportions.
        case misfit(FrameStyle)
    }

    var exportFrameSummary: FrameSummary {
        guard frame.isEnabled else { return .none }
        return document?.pixelSize != nil && frameLayout == nil ? .misfit(frame.style) : .style(frame.style)
    }

    /// A style's proportions around a nominal photo, with default settings,
    /// for the style picker's miniatures. Nil if the engine rejects the document.
    static func frameLayout(for style: FrameStyle, photoWidth: Int = 1000,
                            photoHeight: Int = 1500) -> FramePixelLayout? {
        var settings = FrameSettings()
        settings.style = style
        let layout = try? Engine.frameLayout(frame: settings.engineFrame(hasCaption: style.hasCaption),
                                             photoWidth: photoWidth, photoHeight: photoHeight)
        return layout.map(FramePixelLayout.init)
    }
}
