import SwiftUI

// Base components carried over from components.css / darkroom.css. Standard
// macOS controls (toolbar items, pickers, toggles, sliders) keep the system's
// own look; these styles are for the panel's own surfaces.

/// Text buttons (CSS `.button`, `.button--primary`, `.button--ghost`).
///
/// - `primary`: the one committed action in a view (Export). `accentFill` with white text.
/// - `secondary`: an outlined card-coloured button (Done, Save).
/// - `ghost`: a toolbar-style button with no box until pointed at.
public struct HDRButtonStyle: ButtonStyle {
    public enum Kind: Sendable { case primary, secondary, ghost }

    let kind: Kind
    let height: CGFloat

    public init(_ kind: Kind = .secondary, height: CGFloat = ControlMetrics.regular) {
        self.kind = kind
        self.height = height
    }

    public func makeBody(configuration: Configuration) -> some View {
        HDRButtonBody(kind: kind, height: height, configuration: configuration)
    }
}

private struct HDRButtonBody: View {
    let kind: HDRButtonStyle.Kind
    let height: CGFloat
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        configuration.label
            .font(kind == .primary ? .system(size: TypeScale.Size.control, weight: .semibold) : .hdr.controlLabel)
            .labelStyle(.titleAndIcon)
            .foregroundStyle(foreground)
            .padding(.horizontal, ControlMetrics.horizontalPadding)
            .frame(minHeight: height)
            .background(fill, in: .rect(cornerRadius: Radius.md))
            .overlay { RoundedRectangle(cornerRadius: Radius.md).strokeBorder(border) }
            .contentShape(.rect(cornerRadius: Radius.md))
            .onHover { hovered = $0 }
            .hdrAnimation(Motion.fast, value: hovered)
    }

    private var foreground: Color {
        guard isEnabled else { return .hdr.inkDisabled }
        return kind == .primary ? .hdr.accentInk : .hdr.inkStrong
    }

    private var fill: Color {
        guard isEnabled else { return kind == .ghost ? .clear : .hdr.surfaceSunken }
        switch kind {
        case .primary:
            return hovered && !configuration.isPressed ? .hdr.accentFillHover : .hdr.accentFill
        case .secondary:
            return configuration.isPressed ? .hdr.surfaceActive : hovered ? .hdr.surfaceHover : .hdr.surfaceCard
        case .ghost:
            return configuration.isPressed ? .hdr.surfaceActive : hovered ? .hdr.surfaceHover : .clear
        }
    }

    private var border: Color {
        switch kind {
        case .ghost: return .clear
        // A disabled primary becomes a sunken, outlined slot like the others.
        case .primary: return isEnabled ? .clear : .hdr.line
        case .secondary: return isEnabled ? .hdr.lineStrong : .hdr.line
        }
    }
}

/// Square icon buttons (CSS `.icon-button`): muted glyph, wash on hover.
public struct HDRIconButtonStyle: ButtonStyle {
    let size: CGFloat

    public init(size: CGFloat = ControlMetrics.compact) { self.size = size }

    public func makeBody(configuration: Configuration) -> some View {
        HDRIconButtonBody(size: size, configuration: configuration)
    }
}

private struct HDRIconButtonBody: View {
    let size: CGFloat
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        configuration.label
            .labelStyle(.iconOnly)
            .font(.system(size: ControlMetrics.iconSize))
            .foregroundStyle(hovered ? Color.hdr.inkStrong : Color.hdr.inkMuted)
            .frame(width: size, height: size)
            .background(configuration.isPressed ? Color.hdr.surfaceActive : hovered ? Color.hdr.surfaceHover : .clear,
                        in: .rect(cornerRadius: Radius.md))
            .contentShape(.rect(cornerRadius: Radius.md))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovered = isEnabled && $0 }
            .hdrAnimation(Motion.fast, value: hovered)
    }
}

public extension ButtonStyle where Self == HDRButtonStyle {
    static var hdrPrimary: HDRButtonStyle { HDRButtonStyle(.primary) }
    static var hdrSecondary: HDRButtonStyle { HDRButtonStyle(.secondary) }
    static var hdrGhost: HDRButtonStyle { HDRButtonStyle(.ghost, height: ControlMetrics.compact) }
}

public extension ButtonStyle where Self == HDRIconButtonStyle {
    static var hdrIcon: HDRIconButtonStyle { HDRIconButtonStyle() }
}

// MARK: Surfaces

/// A raised card (CSS `.stage-empty-card`, export cards): card fill, hairline,
/// 10 pt corners, small shadow.
public struct CardModifier: ViewModifier {
    let padding: CGFloat

    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color.hdr.surfaceCard, in: .rect(cornerRadius: Radius.lg))
            .overlay { RoundedRectangle(cornerRadius: Radius.lg).strokeBorder(Color.hdr.line) }
            .elevation(.sm)
    }
}

/// A recessed well (CSS `--surface-sunken` panels: segmented tracks, notes).
public struct WellModifier: ViewModifier {
    let padding: CGFloat

    public func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(Color.hdr.surfaceSunken, in: .rect(cornerRadius: Radius.md))
    }
}

/// A chip floating on the photograph (CSS `.view-tag`, upload and detail
/// status): dark in both appearances, so the photograph decides nothing.
public struct OverlayChipModifier: ViewModifier {
    public func body(content: Content) -> some View {
        content
            .font(.hdr.caption)
            .foregroundStyle(Color.hdr.overlayInk)
            .padding(.horizontal, Space.s2)
            .padding(.vertical, Space.s1)
            .background(Color.hdr.overlay, in: .rect(cornerRadius: Radius.sm))
            .overlay { RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(Color.hdr.overlayLine) }
            .environment(\.colorScheme, .dark)
    }
}

public extension View {
    func hdrCard(padding: CGFloat = Space.s4) -> some View { modifier(CardModifier(padding: padding)) }
    func hdrWell(padding: CGFloat = Space.s3) -> some View { modifier(WellModifier(padding: padding)) }
    func hdrOverlayChip() -> some View { modifier(OverlayChipModifier()) }
}

/// The amber "HDR" badge (CSS `.stage-badge`). Amber is reserved for
/// extended-range things; do not use this for anything else.
public struct HDRBadge: View {
    let text: String

    public init(_ text: String = "HDR") { self.text = text }

    public var body: some View {
        Text(verbatim: text)
            .font(.system(size: TypeScale.Size.caption, weight: .bold))
            .tracking(0.5)
            .foregroundStyle(Color.hdr.amberInk)
            .padding(.horizontal, Space.s2)
            .padding(.vertical, 3)
            .background(Color.hdr.amberGradient, in: .rect(cornerRadius: Radius.xs))
            .elevation(.hdr)
    }
}

/// A section heading in the inspector (CSS `.group-head h2`).
public struct SectionHeading: View {
    let title: LocalizedStringKey

    public init(_ title: LocalizedStringKey) { self.title = title }

    public var body: some View {
        Text(title).font(.hdr.heading).foregroundStyle(Color.hdr.inkStrong)
    }
}
