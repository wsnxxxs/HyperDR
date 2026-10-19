import SwiftUI

/// The small buttons inside cards and rows (24 pt high, 12 pt type): the
/// full-size `HDRButtonStyle` is for dialogs and toolbars.
struct CompactButtonStyle: ButtonStyle {
    enum Kind { case secondary, stop, primary, link, plain }

    let kind: Kind

    func makeBody(configuration: Configuration) -> some View {
        CompactButtonBody(kind: kind, configuration: configuration)
    }
}

private struct CompactButtonBody: View {
    let kind: CompactButtonStyle.Kind
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        let boxed = kind == .secondary || kind == .stop || kind == .primary
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.system(size: TypeScale.Size.caption, weight: kind == .plain ? .regular : .medium))
            .foregroundStyle(foreground)
            .padding(.horizontal, boxed ? 10 : 2)
            .frame(minHeight: boxed ? 24 : 20)
            .background(fill, in: .rect(cornerRadius: Radius.sm))
            .overlay { RoundedRectangle(cornerRadius: Radius.sm).strokeBorder(border) }
            .contentShape(.rect(cornerRadius: Radius.sm))
            .onHover { hovered = isEnabled && $0 }
            .hdrAnimation(Motion.fast, value: hovered)
    }

    private var foreground: Color {
        guard isEnabled else { return .hdr.inkDisabled }
        switch kind {
        case .secondary, .plain: return .hdr.inkStrong
        case .stop: return .hdr.danger
        case .primary: return .hdr.accentInk
        case .link: return hovered ? .hdr.accentHover : .hdr.accent
        }
    }

    private var fill: Color {
        guard isEnabled else { return kind == .link || kind == .plain ? .clear : .hdr.surfaceSunken }
        switch kind {
        case .secondary, .stop:
            return configuration.isPressed ? .hdr.surfaceActive : hovered ? .hdr.surfaceHover : .hdr.surfaceCard
        case .primary:
            return hovered && !configuration.isPressed ? .hdr.accentFillHover : .hdr.accentFill
        case .plain:
            return configuration.isPressed ? .hdr.surfaceActive : hovered ? .hdr.surfaceHover : .clear
        case .link:
            return .clear
        }
    }

    private var border: Color {
        switch kind {
        case .secondary, .stop: return isEnabled ? .hdr.lineStrong : .hdr.line
        case .primary: return isEnabled ? .clear : .hdr.line
        case .link, .plain: return .clear
        }
    }
}
