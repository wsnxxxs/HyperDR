import HyperDREngine

/// The engine's frame layouts for the iOS views, which never reach the
/// engine themselves: synchronous, pure computations (batch 3 §3.1).
enum FrameLayouts {
    /// `settings` around a photo of this size; nil when the frame is off or
    /// the engine refuses the style for these proportions.
    static func layout(_ settings: FrameSettings, width: Int, height: Int) -> FramePixelLayout? {
        guard settings.isEnabled else { return nil }
        let spec = settings.engineFrame()
        return (try? Engine.frameLayout(frame: spec, photoWidth: width, photoHeight: height)).map(FramePixelLayout.init)
    }

    /// A style's proportions around a photo of this size (a nominal 2:3 print
    /// before it is known), with the default caption, for the miniatures.
    static func miniature(_ style: FrameStyle, width: Int?, height: Int?) -> FramePixelLayout? {
        var settings = FrameSettings()
        settings.isEnabled = true
        settings.style = style
        let spec = settings.engineFrame()
        return (try? Engine.frameLayout(frame: spec, photoWidth: width ?? 1000, photoHeight: height ?? 1500))
            .map(FramePixelLayout.init)
    }
}
