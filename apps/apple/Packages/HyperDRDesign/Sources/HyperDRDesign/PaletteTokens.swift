// Generated with Palette.swift: the token list the gallery and tests walk.

import SwiftUI

public extension Palette {
    struct Token: Identifiable, Sendable {
        public let group: String
        public let name: String
        /// The CSS custom property this token was converted from, if any.
        public let css: String?
        public var id: String { name }
        public var color: Color { Color(name, bundle: .module) }
    }

    /// Every colour set, in catalogue order.
    static let tokens: [Token] = [
        .init(group: "Surface", name: "surfacePage", css: "--surface-page"),
        .init(group: "Surface", name: "surfacePanel", css: "--surface-panel"),
        .init(group: "Surface", name: "surfaceCard", css: "--surface-card"),
        .init(group: "Surface", name: "surfaceSunken", css: "--surface-sunken"),
        .init(group: "Surface", name: "surfaceHover", css: "--surface-hover"),
        .init(group: "Surface", name: "surfaceActive", css: "--surface-active"),
        .init(group: "Surface", name: "surfaceGlass", css: "--surface-glass"),
        .init(group: "Ink", name: "inkStrong", css: "--ink-strong"),
        .init(group: "Ink", name: "ink", css: "--ink"),
        .init(group: "Ink", name: "inkMuted", css: "--ink-muted"),
        .init(group: "Ink", name: "inkDisabled", css: "--ink-disabled"),
        .init(group: "Line", name: "line", css: "--line"),
        .init(group: "Line", name: "lineStrong", css: "--line-strong"),
        .init(group: "Line", name: "lineFocus", css: "--line-focus"),
        .init(group: "Line", name: "glassBorder", css: "--glass-border"),
        .init(group: "Line", name: "glassEdge", css: "--glass-edge"),
        .init(group: "Line", name: "glassEdgeSubtle", css: "--glass-edge-subtle"),
        .init(group: "Accent", name: "accent", css: "--accent"),
        .init(group: "Accent", name: "accentHover", css: "--accent-hover"),
        .init(group: "Accent", name: "accentFill", css: "--accent-fill"),
        .init(group: "Accent", name: "accentFillHover", css: "--accent-fill-hover"),
        .init(group: "Accent", name: "accentInk", css: "--accent-ink"),
        .init(group: "Accent", name: "accentSoft", css: "--accent-soft"),
        .init(group: "Accent", name: "selectedBackground", css: "--selected-bg"),
        .init(group: "Accent", name: "selectedLine", css: "--selected-line"),
        .init(group: "Accent", name: "selectedInk", css: "--selected-ink"),
        .init(group: "Status", name: "danger", css: "--danger"),
        .init(group: "Status", name: "warn", css: "--warn"),
        .init(group: "Status", name: "warnSoft", css: "--warn-soft"),
        .init(group: "Status", name: "successLine", css: "--success-line"),
        .init(group: "Status", name: "dialogBackdrop", css: "--dialog-backdrop"),
        .init(group: "Amber", name: "amber", css: "--hdr"),
        .init(group: "Amber", name: "amberInk", css: "--hdr-ink"),
        .init(group: "Amber", name: "amberSoft", css: "--hdr-soft"),
        .init(group: "Amber", name: "amberBorder", css: "--hdr-border"),
        .init(group: "Control", name: "controlFill", css: "--control-fill"),
        .init(group: "Control", name: "controlTrack", css: "--control-track"),
        .init(group: "Control", name: "controlThumb", css: "--control-thumb"),
        .init(group: "Control", name: "controlRing", css: "--control-ring"),
        .init(group: "Control", name: "controlGlow", css: "--control-glow"),
        .init(group: "Canvas", name: "zebraHot", css: "--zebra-hot"),
        .init(group: "Canvas", name: "zebraCold", css: "--zebra-cold"),
        .init(group: "Canvas", name: "maskTint", css: "--mask-tint"),
        .init(group: "Canvas", name: "histogramGrid", css: "--hist-grid"),
        .init(group: "Canvas", name: "histogramLuma", css: "--hist-luma"),
        .init(group: "Canvas", name: "histogramRed", css: "--hist-red"),
        .init(group: "Canvas", name: "histogramGreen", css: "--hist-green"),
        .init(group: "Canvas", name: "histogramBlue", css: "--hist-blue"),
        .init(group: "Overlay", name: "previewBackdrop", css: "--preview-backdrop"),
        .init(group: "Overlay", name: "previewDetailBackdrop", css: "--preview-detail-backdrop"),
        .init(group: "Overlay", name: "previewDarkroom", css: "--preview-darkroom-bg"),
        .init(group: "Overlay", name: "overlay", css: "--overlay"),
        .init(group: "Overlay", name: "overlayInk", css: "--overlay-ink"),
        .init(group: "Overlay", name: "overlayMuted", css: "--overlay-muted"),
        .init(group: "Overlay", name: "overlayTrack", css: "--overlay-track"),
        .init(group: "Overlay", name: "overlayHover", css: "--overlay-hover"),
        .init(group: "Overlay", name: "overlayLine", css: "--overlay-line"),
        .init(group: "Overlay", name: "overlayLineStrong", css: "--overlay-line-strong"),
        .init(group: "Overlay", name: "overlayShadow", css: "--overlay-shadow"),
        .init(group: "Overlay", name: "insetShade", css: "--inset-shade"),
        .init(group: "Overlay", name: "qrSurface", css: "--qr-surface"),
        .init(group: "Overlay", name: "focusHalo", css: "--focus-halo"),
        .init(group: "Overlay", name: "railFade", css: "--rail-fade"),
        .init(group: "Amber", name: "amberGradientStart", css: nil),
        .init(group: "Amber", name: "amberGradientEnd", css: nil),
        .init(group: "Canvas", name: "histogramRampShadow", css: nil),
        .init(group: "Canvas", name: "histogramRampWhite", css: nil),
        .init(group: "Canvas", name: "histogramRampHDR", css: nil),
        .init(group: "Canvas", name: "histogramRampPeak", css: nil),
    ]
}
