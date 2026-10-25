import CoreGraphics

/// Where the iPad Studio puts the canvas and its panel (ipad-studio §2), by
/// the window's size rather than the device's orientation, so Split View and
/// Stage Manager pick the right form as the window changes:
///
/// - Clearly wider than tall and at least 960 pt wide: the panel stands on
///   the right, full height under the toolbar.
/// - Otherwise: the panel lies along the foot, the canvas above it.
///
/// Collapsed, the panel keeps only its tool rail, and the canvas takes the
/// rest. The canvas never runs under the panel, so the photo is never covered,
/// and the strip under the canvas holds the canvas bar.
struct PadLayout: Equatable {
    enum Placement: Equatable { case side, bottom }

    let placement: Placement
    /// The canvas, the canvas bar's strip under it, and the panel, in the
    /// editor's space (under the toolbar, down to the window's foot).
    let canvas: CGRect
    let bar: CGRect
    let panel: CGRect

    /// `size` is the space under the toolbar; `bottomInset` the home
    /// indicator's, which the canvas bar keeps clear of.
    init(size: CGSize, bottomInset: CGFloat, expanded: Bool) {
        let margin = PadMetrics.margin
        let strip = PadMetrics.canvasBarStrip
        var standing = size.width >= 960 && size.width >= size.height * 1.15
        #if DEBUG
        // The simulator ignores the landscape request of a multitasking app.
        if DebugLaunch.standsPanel { standing = true }
        #endif
        if standing {
            placement = .side
            let width = expanded ? min(392, max(352, size.width * 0.28)) : PadMetrics.railWidth
            panel = CGRect(x: size.width - margin - width, y: 2, width: width, height: max(0, size.height - 2 - margin))
            let foot = max(margin, bottomInset)
            bar = CGRect(x: 0, y: size.height - foot - strip, width: panel.minX - margin, height: strip)
            canvas = CGRect(x: 0, y: 0, width: bar.width, height: max(0, bar.minY))
        } else {
            placement = .bottom
            let height = expanded ? min(430, max(300, size.height * 0.36)) : PadMetrics.railHeight
            panel = CGRect(x: margin, y: size.height - margin - height, width: max(0, size.width - 2 * margin), height: height)
            bar = CGRect(x: 0, y: panel.minY - strip, width: size.width, height: strip)
            canvas = CGRect(x: 0, y: 0, width: size.width, height: max(0, bar.minY))
        }
    }

    /// Controls side by side: one column standing, two lying.
    var columns: Int { placement == .side ? 1 : 2 }
}
