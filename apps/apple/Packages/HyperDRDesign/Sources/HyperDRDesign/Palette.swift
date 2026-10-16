// Generated once from apps/panel/web/css/tokens.css (2026-10-17). This file and
// Resources/Colors.xcassets are now the only definition of HyperDR's colours:
// edit them here, not in the retiring web stylesheet.

import SwiftUI

/// HyperDR's colour tokens. Every colour is a set in `Colors.xcassets` with a light
/// and a dark appearance (and a high-contrast variant where the web had one), so
/// views follow the window's appearance without reading `colorScheme`.
///
/// Use through the `.hdr` namespace: `.foregroundStyle(.hdr.inkMuted)`,
/// `.background(Color.hdr.surfacePanel)`. Contrast ratios are WCAG 2 values
/// measured when the set was converted; recompute them when a value changes.
public struct Palette: Sendable {
    fileprivate init() {}

    // MARK: Surface

    /// Window background behind the canvas and panels.
    /// CSS `--surface-page`.
    public var surfacePage: Color { Color("surfacePage", bundle: .module) }

    /// Inspector, toolbar and status bar background.
    /// CSS `--surface-panel`.
    public var surfacePanel: Color { Color("surfacePanel", bundle: .module) }

    /// Raised cards and secondary button fill.
    /// CSS `--surface-card`.
    public var surfaceCard: Color { Color("surfaceCard", bundle: .module) }

    /// Recessed wells: segmented tracks, fields, histogram backdrop.
    /// CSS `--surface-sunken`.
    public var surfaceSunken: Color { Color("surfaceSunken", bundle: .module) }

    /// Hover wash over controls.
    /// CSS `--surface-hover`.
    public var surfaceHover: Color { Color("surfaceHover", bundle: .module) }

    /// Pressed wash over neutral controls.
    /// CSS `--surface-active`.
    public var surfaceActive: Color { Color("surfaceActive", bundle: .module) }

    /// Opaque stand-in for the retired glass surface. Unused on the web.
    /// CSS `--surface-glass`.
    public var surfaceGlass: Color { Color("surfaceGlass", bundle: .module) }

    // MARK: Ink

    /// Headings and primary values.
    /// Contrast on surfacePanel: light 15.5:1, dark 14.6:1.
    /// CSS `--ink-strong`.
    public var inkStrong: Color { Color("inkStrong", bundle: .module) }

    /// Body text.
    /// Contrast on surfacePanel: light 10.0:1, dark 10.2:1.
    /// CSS `--ink`.
    public var ink: Color { Color("ink", bundle: .module) }

    /// Secondary 12–13 px text. Chosen for ≥ 4.5:1 on panel and page.
    /// Contrast on surfacePanel: light 5.7:1, dark 6.6:1.
    /// CSS `--ink-muted`.
    public var inkMuted: Color { Color("inkMuted", bundle: .module) }

    /// Disabled labels. Neutral like every other ink; not held to 4.5:1 (disabled text is exempt).
    /// CSS `--ink-disabled`.
    public var inkDisabled: Color { Color("inkDisabled", bundle: .module) }

    // MARK: Line

    /// Hairlines between regions.
    /// CSS `--line`.
    public var line: Color { Color("line", bundle: .module) }

    /// Control borders and dialog edges.
    /// CSS `--line-strong`.
    public var lineStrong: Color { Color("lineStrong", bundle: .module) }

    /// Soft focus outline.
    /// CSS `--line-focus`.
    public var lineFocus: Color { Color("lineFocus", bundle: .module) }

    /// Light inner border on raised surfaces.
    /// CSS `--glass-border`.
    public var glassBorder: Color { Color("glassBorder", bundle: .module) }

    /// Top highlight on raised surfaces.
    /// CSS `--glass-edge`.
    public var glassEdge: Color { Color("glassEdge", bundle: .module) }

    /// Faint top highlight. Unused on the web.
    /// CSS `--glass-edge-subtle`.
    public var glassEdgeSubtle: Color { Color("glassEdgeSubtle", bundle: .module) }

    // MARK: Accent

    /// The accent as ink and stroke: links, focus, selected text. Dark value is light so it reaches 4.5:1 on the dark panel.
    /// Contrast on surfacePanel: light 4.5:1, dark 7.2:1.
    /// CSS `--accent`.
    public var accent: Color { Color("accent", bundle: .module) }

    /// Accent ink under the pointer.
    /// CSS `--accent-hover`.
    public var accentHover: Color { Color("accentHover", bundle: .module) }

    /// Fill behind white text (primary button, switches). Never use `accent` as a fill.
    /// CSS `--accent-fill`.
    public var accentFill: Color { Color("accentFill", bundle: .module) }

    /// Primary button under the pointer.
    /// CSS `--accent-fill-hover`.
    public var accentFillHover: Color { Color("accentFillHover", bundle: .module) }

    /// Text on `accentFill`.
    /// Contrast on accentFill: light 4.7:1, dark 4.8:1 (dark hover 4.5:1).
    /// CSS `--accent-ink`.
    public var accentInk: Color { Color("accentInk", bundle: .module) }

    /// Faint accent wash.
    /// CSS `--accent-soft`.
    public var accentSoft: Color { Color("accentSoft", bundle: .module) }

    /// Selected row or segment background.
    /// CSS `--selected-bg`.
    public var selectedBackground: Color { Color("selectedBackground", bundle: .module) }

    /// Selected row or segment border.
    /// CSS `--selected-line`.
    public var selectedLine: Color { Color("selectedLine", bundle: .module) }

    /// Text in a selected row or segment.
    /// Contrast on surfacePanel: light 5.6:1, dark 9.4:1.
    /// CSS `--selected-ink`.
    public var selectedInk: Color { Color("selectedInk", bundle: .module) }

    // MARK: Status

    /// Errors, used as text: measured against the panel.
    /// Contrast on surfacePanel: light 5.0:1, dark 6.0:1.
    /// CSS `--danger`.
    public var danger: Color { Color("danger", bundle: .module) }

    /// Warnings and stale results, used as text: measured against the panel.
    /// Contrast on surfacePanel: light 4.9:1, dark 9.3:1.
    /// CSS `--warn`.
    public var warn: Color { Color("warn", bundle: .module) }

    /// Warning notice background.
    /// CSS `--warn-soft`.
    public var warnSoft: Color { Color("warnSoft", bundle: .module) }

    /// Border of a success badge on the photograph.
    /// CSS `--success-line`.
    public var successLine: Color { Color("successLine", bundle: .module) }

    /// Dim behind a modal (where the system does not draw its own).
    /// CSS `--dialog-backdrop`.
    public var dialogBackdrop: Color { Color("dialogBackdrop", bundle: .module) }

    // MARK: Amber

    /// HDR amber. Reserved for extended-range things; fills and curves only — as light-mode text it is 3.7:1, so HDR text uses `warn`.
    /// Contrast on surfacePanel: light 3.1:1, dark 7.7:1.
    /// CSS `--hdr`.
    public var amber: Color { Color("amber", bundle: .module) }

    /// Text on an amber fill: near-black in both appearances. White on the
    /// light gradient measured only 2.2–3.2:1 (CSS shipped it that way).
    /// Contrast on amber / the gradient's light stop: light 5.9:1 / 8.7:1,
    /// dark 8.7:1 / 11.2:1.
    /// CSS `--hdr-ink` (light value darkened from #FFFFFF).
    public var amberInk: Color { Color("amberInk", bundle: .module) }

    /// Amber wash.
    /// CSS `--hdr-soft`.
    public var amberSoft: Color { Color("amberSoft", bundle: .module) }

    /// Amber outline.
    /// CSS `--hdr-border`.
    public var amberBorder: Color { Color("amberBorder", bundle: .module) }

    // MARK: Control

    /// Slider track up to the value. Neutral: the value is read from the number field, not the colour.
    /// CSS `--control-fill`.
    public var controlFill: Color { Color("controlFill", bundle: .module) }

    /// Slider track after the value.
    /// CSS `--control-track`.
    public var controlTrack: Color { Color("controlTrack", bundle: .module) }

    /// Slider thumb.
    /// CSS `--control-thumb`.
    public var controlThumb: Color { Color("controlThumb", bundle: .module) }

    /// Slider thumb outline.
    /// CSS `--control-ring`.
    public var controlRing: Color { Color("controlRing", bundle: .module) }

    /// Accent glow around an active control. Unused on the web.
    /// CSS `--control-glow`.
    public var controlGlow: Color { Color("controlGlow", bundle: .module) }

    // MARK: Canvas

    /// Clipping stripes over highlights. Resolve to RGBA per appearance before drawing.
    /// CSS `--zebra-hot`.
    public var zebraHot: Color { Color("zebraHot", bundle: .module) }

    /// Clipping stripes over shadows.
    /// CSS `--zebra-cold`.
    public var zebraCold: Color { Color("zebraCold", bundle: .module) }

    /// Tint showing where an adjustment applies.
    /// CSS `--mask-tint`.
    public var maskTint: Color { Color("maskTint", bundle: .module) }

    /// Histogram grid lines.
    /// CSS `--hist-grid`.
    public var histogramGrid: Color { Color("histogramGrid", bundle: .module) }

    /// Luminance histogram.
    /// CSS `--hist-luma`.
    public var histogramLuma: Color { Color("histogramLuma", bundle: .module) }

    /// Red channel.
    /// CSS `--hist-red`.
    public var histogramRed: Color { Color("histogramRed", bundle: .module) }

    /// Green channel.
    /// CSS `--hist-green`.
    public var histogramGreen: Color { Color("histogramGreen", bundle: .module) }

    /// Blue channel.
    /// CSS `--hist-blue`.
    public var histogramBlue: Color { Color("histogramBlue", bundle: .module) }

    // MARK: Overlay

    /// Behind the photograph. Dark in both appearances.
    /// CSS `--preview-backdrop`.
    public var previewBackdrop: Color { Color("previewBackdrop", bundle: .module) }

    /// Behind the 1:1 detail view.
    /// CSS `--preview-detail-backdrop`.
    public var previewDetailBackdrop: Color { Color("previewDetailBackdrop", bundle: .module) }

    /// Darkroom surround.
    /// CSS `--preview-darkroom-bg`.
    public var previewDarkroom: Color { Color("previewDarkroom", bundle: .module) }

    /// Chips and controls floating on the photograph. Dark in both appearances.
    /// CSS `--overlay`.
    public var overlay: Color { Color("overlay", bundle: .module) }

    /// Text on `overlay`; also the focus ring colour on the photograph (the accent is only 2.7:1 there).
    /// Contrast on overlay over previewBackdrop: 17.8:1.
    /// CSS `--overlay-ink`.
    public var overlayInk: Color { Color("overlayInk", bundle: .module) }

    /// Secondary text on `overlay`.
    /// CSS `--overlay-muted`.
    public var overlayMuted: Color { Color("overlayMuted", bundle: .module) }

    /// Tracks on the photograph.
    /// CSS `--overlay-track`.
    public var overlayTrack: Color { Color("overlayTrack", bundle: .module) }

    /// Hover wash on the photograph.
    /// CSS `--overlay-hover`.
    public var overlayHover: Color { Color("overlayHover", bundle: .module) }

    /// Chip outline on the photograph.
    /// CSS `--overlay-line`.
    public var overlayLine: Color { Color("overlayLine", bundle: .module) }

    /// Strong outline on the photograph.
    /// CSS `--overlay-line-strong`.
    public var overlayLineStrong: Color { Color("overlayLineStrong", bundle: .module) }

    /// Shadow under the split divider.
    /// CSS `--overlay-shadow`.
    public var overlayShadow: Color { Color("overlayShadow", bundle: .module) }

    /// Inner shade of recessed wells.
    /// CSS `--inset-shade`.
    public var insetShade: Color { Color("insetShade", bundle: .module) }

    /// White quiet zone for QR codes in both appearances.
    /// CSS `--qr-surface`.
    public var qrSurface: Color { Color("qrSurface", bundle: .module) }

    /// Halo separating a focus ring from busy content.
    /// CSS `--focus-halo`.
    public var focusHalo: Color { Color("focusHalo", bundle: .module) }

    /// Scroll-edge fade of the inspector. Unused on the web.
    /// CSS `--rail-fade`.
    public var railFade: Color { Color("railFade", bundle: .module) }

    // MARK: Amber

    /// First stop of the amber gradient (CSS `--hdr-gradient`).
    public var amberGradientStart: Color { Color("amberGradientStart", bundle: .module) }

    /// Last stop of the amber gradient.
    public var amberGradientEnd: Color { Color("amberGradientEnd", bundle: .module) }

    // MARK: Canvas

    /// Histogram tone ramp: black point.
    public var histogramRampShadow: Color { Color("histogramRampShadow", bundle: .module) }

    /// Histogram tone ramp: SDR white (70 %).
    public var histogramRampWhite: Color { Color("histogramRampWhite", bundle: .module) }

    /// Histogram tone ramp: start of extended range.
    public var histogramRampHDR: Color { Color("histogramRampHDR", bundle: .module) }

    /// Histogram tone ramp: peak.
    public var histogramRampPeak: Color { Color("histogramRampPeak", bundle: .module) }

    // MARK: Aliases

    /// Success shares the accent (CSS `--success`).
    public var success: Color { accent }
    /// Focus rings (CSS `--focus`). Controls on the photograph use `overlayInk` instead.
    public var focus: Color { accent }
    /// Histogram backdrop (CSS `--hist-backdrop`).
    public var histogramBackdrop: Color { surfaceSunken }
    /// Histogram output curve and the SDR-white marker (CSS `--hist-output`, `--hist-marker`).
    public var histogramOutput: Color { amber }

    // MARK: Gradients

    /// CSS `--hdr-gradient`, drawn at 135°: use with `.topLeading` → `.bottomTrailing`.
    public var amberGradient: LinearGradient {
        LinearGradient(colors: [amberGradientStart, amberGradientEnd], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// CSS `--hist-rgb`: the RGB legend swatch.
    public var histogramRGB: LinearGradient {
        LinearGradient(colors: [histogramRed, histogramGreen, histogramBlue], startPoint: .leading, endPoint: .trailing)
    }
    /// CSS `--hist-ramp`: the tone axis, SDR up to 70 %, extended range after.
    public var histogramRamp: LinearGradient {
        LinearGradient(stops: [
            .init(color: histogramRampShadow, location: 0), .init(color: histogramRampWhite, location: 0.7),
            .init(color: histogramRampHDR, location: 0.7), .init(color: histogramRampPeak, location: 1),
        ], startPoint: .leading, endPoint: .trailing)
    }

    // MARK: Shadow layers (used by `ElevationModifier`)

    var shadowSm1: Color { Color("shadowSm1", bundle: .module) }
    var shadowSm2: Color { Color("shadowSm2", bundle: .module) }
    var shadowMd1: Color { Color("shadowMd1", bundle: .module) }
    var shadowMd2: Color { Color("shadowMd2", bundle: .module) }
    var shadowLg1: Color { Color("shadowLg1", bundle: .module) }
    var shadowLg2: Color { Color("shadowLg2", bundle: .module) }
    var shadowGlass1: Color { Color("shadowGlass1", bundle: .module) }
    var shadowGlassLg1: Color { Color("shadowGlassLg1", bundle: .module) }
    var shadowGlassLg2: Color { Color("shadowGlassLg2", bundle: .module) }
    var shadowGlow1: Color { Color("shadowGlow1", bundle: .module) }
    var shadowHdr1: Color { Color("shadowHdr1", bundle: .module) }
}

public extension ShapeStyle where Self == Color {
    /// HyperDR's colour tokens: `.foregroundStyle(.hdr.inkMuted)`.
    static var hdr: Palette { Palette() }
}
