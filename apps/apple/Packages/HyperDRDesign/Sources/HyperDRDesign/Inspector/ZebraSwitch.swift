import SwiftUI

/// Which zebra overlay a `ZebraSwitch` turns on.
public enum ZebraKind: Sendable, CaseIterable {
    /// Highlights that will be clipped on export.
    case highlights
    /// Shadows that are pure black in the SDR version.
    case shadows

    var title: Text {
        switch self {
        case .highlights: Text("design.zebra.highlights", bundle: .module)
        case .shadows: Text("design.zebra.shadows", bundle: .module)
        }
    }

    var help: Text {
        switch self {
        case .highlights: Text("design.zebra.highlights.help", bundle: .module)
        case .shadows: Text("design.zebra.shadows.help", bundle: .module)
        }
    }

    /// The stripe colour on the panel: the same hue the canvas stripes in.
    var color: Color {
        switch self {
        case .highlights: .hdr.zebraHot
        case .shadows: .hdr.zebraCold
        }
    }
}

/// A 12 × 12 swatch of the canvas's 45° stripes, so a switch or a legend row
/// shows what its overlay looks like on the photograph.
struct StripeSwatch: View {
    let color: Color

    var body: some View {
        Canvas { context, size in
            let shape = Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2)
            context.clip(to: shape)
            context.fill(shape, with: .color(color.opacity(0.18)))
            var stripes = Path()
            var x = -size.height
            while x < size.width {
                stripes.move(to: CGPoint(x: x, y: size.height))
                stripes.addLine(to: CGPoint(x: x + size.height, y: 0))
                x += 4.5
            }
            context.stroke(stripes, with: .color(color), lineWidth: 2)
            context.stroke(shape, with: .color(color.opacity(0.6)), lineWidth: 1)
        }
        .frame(width: 12, height: 12)
        .accessibilityHidden(true)
    }
}

/// A small on / off button under the scope with a stripe swatch, which both
/// switches a zebra overlay on the canvas and says what it looks like.
///
/// The words say what is marked ("Clipped highlights"), not the feature's
/// name; the tooltip adds the rest. Read by VoiceOver as a switch.
public struct ZebraSwitch: View {
    private let kind: ZebraKind
    @Binding private var isOn: Bool

    public init(_ kind: ZebraKind, isOn: Binding<Bool>) {
        self.kind = kind
        _isOn = isOn
    }

    public var body: some View {
        Toggle(isOn: $isOn) { kind.title }
            .toggleStyle(ZebraToggleStyle(kind: kind))
            .help(kind.help)
    }
}

private struct ZebraToggleStyle: ToggleStyle {
    let kind: ZebraKind

    func makeBody(configuration: Configuration) -> some View {
        ZebraToggleBody(kind: kind, configuration: configuration)
    }
}

private struct ZebraToggleBody: View {
    let kind: ZebraKind
    let configuration: ToggleStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    var body: some View {
        let on = configuration.isOn
        Button { configuration.isOn.toggle() } label: {
            HStack(spacing: 6) {
                StripeSwatch(color: kind.color).opacity(on ? 1 : 0.55)
                configuration.label
                    .font(.system(size: TypeScale.Size.caption, weight: on ? .medium : .regular))
                    .lineLimit(1)
            }
            .foregroundStyle(!isEnabled ? Color.hdr.inkDisabled : on ? Color.hdr.selectedInk : Color.hdr.inkMuted)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(on ? Color.hdr.selectedBackground : hovered && isEnabled ? Color.hdr.surfaceHover : .clear,
                        in: .rect(cornerRadius: Radius.xs))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.xs)
                    .strokeBorder(on && isEnabled ? Color.hdr.selectedLine : Color.hdr.line)
            }
            .opacity(isEnabled ? 1 : 0.6)
            .contentShape(.rect(cornerRadius: Radius.xs))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .hdrAnimation(Motion.fast, value: hovered)
        .hdrAnimation(Motion.fast, value: on)
        .accessibilityAddTraits(.isToggle)
        .accessibilityValue(Text(verbatim: on ? "1" : "0"))
    }
}
