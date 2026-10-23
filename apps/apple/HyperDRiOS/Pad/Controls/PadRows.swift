import HyperDRDesign
import SwiftUI

/// An on/off control as a Studio row: its name, and the system switch.
struct PadToggleRow: View {
    let title: Text
    @Binding var isOn: Bool
    var symbol: String? = nil
    var tint: Color = Color.hdr.accentFill

    var body: some View {
        Toggle(isOn: $isOn) {
            HStack(spacing: Space.s2) {
                if let symbol {
                    Image(systemName: symbol)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(width: 20)
                }
                title.font(.subheadline).lineLimit(1).minimumScaleFactor(0.8)
            }
        }
        .tint(tint)
        .padding(.horizontal, PadMetrics.inset)
        .frame(height: PadMetrics.row)
        .padRow()
        .sensoryFeedback(.selection, trigger: isOn)
    }
}

/// A choice of two to four as segments in a row: the chosen one lit, the
/// highlight sliding between them. Options that cannot be chosen now stay
/// in their place, disabled.
struct PadSegments<Value: Hashable>: View {
    struct Option: Identifiable {
        let value: Value
        let label: Text
        var symbol: String? = nil
        var isEnabled = true
        var id: Value { value }
    }

    let options: [Option]
    let selection: Value
    var tint: Color = Color.primary
    let choose: (Value) -> Void
    @Namespace private var highlight

    var body: some View {
        HStack(spacing: 0) {
            ForEach(options) { option in
                let isCurrent = option.value == selection
                Button { choose(option.value) } label: {
                    HStack(spacing: 5) {
                        if let symbol = option.symbol { Image(systemName: symbol).imageScale(.small) }
                        option.label.lineLimit(1).minimumScaleFactor(0.75)
                    }
                    .font(.subheadline.weight(isCurrent ? .semibold : .regular))
                    .foregroundStyle(isCurrent ? tint : Color.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        if isCurrent {
                            RoundedRectangle(cornerRadius: PadMetrics.rowRadius - 3, style: .continuous)
                                .fill(Color.white.opacity(0.14))
                                .matchedGeometryEffect(id: "segment", in: highlight)
                        }
                    }
                    .contentShape(.rect)
                    .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: PadMetrics.rowRadius - 3))
                    .hoverEffect(.highlight)
                }
                .buttonStyle(.plain)
                .disabled(!option.isEnabled)
                .opacity(option.isEnabled ? 1 : 0.4)
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
            }
        }
        .padding(3)
        .frame(height: PadMetrics.row)
        .padRow()
        .animation(.smooth(duration: 0.25), value: selection)
        .sensoryFeedback(.selection, trigger: selection)
        .accessibilityElement(children: .contain)
    }
}

/// A row whose value opens a menu of choices: the name on the left, what is
/// chosen and the menu's chevrons on the right.
struct PadMenuRow<Menu: View>: View {
    let title: Text
    let value: Text
    @ViewBuilder let menu: Menu

    var body: some View {
        SwiftUI.Menu {
            menu
        } label: {
            HStack(spacing: Space.s2) {
                title.font(.subheadline).foregroundStyle(Color.primary).lineLimit(1)
                Spacer(minLength: Space.s2)
                value.font(.subheadline).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, PadMetrics.inset)
            .frame(height: PadMetrics.row)
            .padRow()
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: PadMetrics.rowRadius))
        .hoverEffect(.highlight)
    }
}

/// A line of explanation among the controls: a symbol and wrapped text.
struct PadNote: View {
    let text: Text
    var symbol = "info.circle"
    var tint: Color = .secondary

    var body: some View {
        Label { text } icon: { Image(systemName: symbol) }
            .font(.footnote)
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
    }
}

/// A row-sized button with a symbol over a short name, for actions such as a
/// quarter turn; laid out in a row of equal tiles.
struct PadActionTile: View {
    let title: Text
    let symbol: String
    let action: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol).font(.system(size: 17, weight: .medium))
                title.font(.caption.weight(.medium)).lineLimit(1).minimumScaleFactor(0.75)
            }
            .foregroundStyle(Color.primary)
            .frame(maxWidth: .infinity, minHeight: 56)
            .padRow()
            .contentShape(.rect)
            .contentShape(.hoverEffect, RoundedRectangle(cornerRadius: PadMetrics.rowRadius))
            .hoverEffect(.highlight)
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.4)
        .accessibilityLabel(title)
    }
}
