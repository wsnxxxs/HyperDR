// Sizes converted from the web front end's tokens.css and dialogs.css (2026-10-17; the web front end was deleted on 2026-10-20).
// This file is now their only definition.

import CoreGraphics

/// Spacing on a 4 pt grid (CSS `--space-1…6`).
public enum Space {
    public static let s1: CGFloat = 4
    public static let s2: CGFloat = 8
    public static let s3: CGFloat = 12
    public static let s4: CGFloat = 16
    public static let s5: CGFloat = 24
    public static let s6: CGFloat = 32
}

/// Corner radii (CSS `--radius-*`). Dialogs 12, cards 8–10, controls 6.
public enum Radius {
    public static let xs: CGFloat = 4
    public static let sm: CGFloat = 6
    /// Same as `sm` on the web; kept so control code reads like its CSS.
    public static let md: CGFloat = 6
    /// CSS `--radius`.
    public static let standard: CGFloat = 8
    public static let lg: CGFloat = 10
    public static let xl: CGFloat = 12
}

/// Control heights (CSS `--control-compact`, `--control-height`). The web's
/// touch sizes are not carried over: this package targets macOS only.
public enum ControlMetrics {
    /// Dense toolbars, icon buttons, segmented controls.
    public static let compact: CGFloat = 32
    /// Default button and field height.
    public static let regular: CGFloat = 36
    /// Horizontal padding inside a text button.
    public static let horizontalPadding: CGFloat = 14
    /// Icon glyph size inside a compact button.
    public static let iconSize: CGFloat = 16
}

/// Window frame (CSS `--rail-width*`, `--status-height`, `--frame-pad`,
/// `--panel-padding`, and the dialog frame in dialogs.css). The header height
/// is not here: the window toolbar is the system's.
public enum Layout {
    /// Inspector width in a wide window (≥ 1150 pt).
    public static let inspectorWidth: CGFloat = 342
    /// Inspector width in a regular window (860–1150 pt).
    public static let inspectorWidthRegular: CGFloat = 320
    /// Inspector width in a narrow window (< 860 pt).
    public static let inspectorWidthNarrow: CGFloat = 300
    /// Window widths at which the inspector narrows.
    public static let regularBreakpoint: CGFloat = 1150
    public static let narrowBreakpoint: CGFloat = 860

    /// Margin around the canvas: wide, regular and narrow windows.
    public static let canvasPadding: CGFloat = 22
    public static let canvasPaddingRegular: CGFloat = 16
    public static let canvasPaddingNarrow: CGFloat = 12
    /// Gutter between the canvas frame and the photograph inside it.
    public static let canvasGutter: CGFloat = 28

    public static let statusBarHeight: CGFloat = 28
    /// Padding inside panels and dialog bodies.
    public static let panelPadding: CGFloat = 24

    /// Shared frame of the large sheets (export, preferences, history).
    public static let dialogWidth: CGFloat = 840
    public static let dialogHeight: CGFloat = 600
    public static let dialogCompactWidth: CGFloat = 560
    public static let dialogRailWidth: CGFloat = 200

    /// Inspector width for a window of the given width.
    public static func inspectorWidth(forWindowWidth width: CGFloat) -> CGFloat {
        width >= regularBreakpoint ? inspectorWidth
            : width >= narrowBreakpoint ? inspectorWidthRegular : inspectorWidthNarrow
    }

    /// Canvas margin for a window of the given width.
    public static func canvasPadding(forWindowWidth width: CGFloat) -> CGFloat {
        width >= regularBreakpoint ? canvasPadding
            : width >= narrowBreakpoint ? canvasPaddingRegular : canvasPaddingNarrow
    }
}
