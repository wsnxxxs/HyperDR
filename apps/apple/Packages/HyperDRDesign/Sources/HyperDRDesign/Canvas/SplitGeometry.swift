import CoreGraphics

/// The arithmetic of the compare divider, apart from its views.
public enum SplitGeometry {
    /// The divider stays inside this share of the photograph, so neither side
    /// shrinks to nothing and the handle stays reachable.
    public static let ratioRange = 0.05...0.95
    /// A side's label fades once the divider is this close to its edge.
    public static let labelFadeDistance: CGFloat = 72
    /// How far one arrow-key press moves the divider.
    public static let nudgeStep = 0.05
    /// Width of the divider's pointer target around its line.
    public static let hitWidth: CGFloat = 24
    /// The same on touch layouts (p7-adjustments §5.4: a 44 pt target).
    public static let touchHitWidth: CGFloat = 44

    /// The divider ratio for a pointer at `x`, across the photograph's frame.
    public static func ratio(forX x: CGFloat, in imageFrame: CGRect) -> Double {
        guard imageFrame.width > 0 else { return 0.5 }
        let ratio = Double((x - imageFrame.minX) / imageFrame.width)
        return min(max(ratio, ratioRange.lowerBound), ratioRange.upperBound)
    }

    /// Where the divider's line is, in the frame's coordinates.
    public static func dividerX(ratio: Double, in imageFrame: CGRect) -> CGFloat {
        imageFrame.minX + CGFloat(ratio) * imageFrame.width
    }

    /// Which side of the divider a label is on.
    public enum Side: Sendable { case original, edited }

    /// 1 for a label to show, 0 for one to fade: a side's label goes when the
    /// divider is nearer than `labelFadeDistance` to the visible edge that
    /// label is at, since the label would sit on the divider.
    public static func labelOpacity(_ side: Side, dividerX: CGFloat, visible: CGRect) -> Double {
        let distance = side == .original ? dividerX - visible.minX : visible.maxX - dividerX
        return distance < labelFadeDistance ? 0 : 1
    }
}
