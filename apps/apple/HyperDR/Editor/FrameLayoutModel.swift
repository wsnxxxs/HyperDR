import HyperDREngine

extension EditorModel {
    /// The frame around the full-size photograph, or the bare photograph while
    /// the frame is off; nil without a photo size. A synchronous, pure engine
    /// computation (§3.1).
    var frameLayout: FramePixelLayout? {
        guard let size = document?.pixelSize else { return nil }
        let spec = frame.isEnabled ? frame.engineFrame() : [:]
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
        let layout = try? Engine.frameLayout(frame: settings.engineFrame(),
                                             photoWidth: photoWidth, photoHeight: photoHeight)
        return layout.map(FramePixelLayout.init)
    }
}
