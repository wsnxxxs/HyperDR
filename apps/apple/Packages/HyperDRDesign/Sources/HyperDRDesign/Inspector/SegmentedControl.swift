import SwiftUI

/// One choice of a `ParameterSegmented`.
public struct SegmentedChoice<Value: Hashable>: Identifiable {
    public let value: Value
    public let title: LocalizedStringKey
    public let systemImage: String?
    public let isEnabled: Bool
    public var id: Value { value }

    public init(_ title: LocalizedStringKey, value: Value, systemImage: String? = nil, isEnabled: Bool = true) {
        self.title = title
        self.value = value
        self.systemImage = systemImage
        self.isEnabled = isEnabled
    }
}

/// The height of a `ParameterSegmented`.
public enum SegmentedSize: Sendable {
    /// 28 pt segments (CSS `.segmented`).
    case regular
    /// 23 pt segments, no outline (CSS `.segmented--small`).
    case small
}

/// A segmented choice in the inspector (CSS `.segmented`): a sunken,
/// outlined track holding one button per choice, the selected one tinted.
///
/// Unlike the system segmented picker it shows a disabled state, and single
/// choices can be disabled. Each segment is a button marked selected for
/// VoiceOver and reachable with keyboard navigation; the group is named by
/// `title`. With Increase Contrast on, the selected segment is filled with
/// the accent and every segment is outlined (CSS `forced-colors`).
public struct ParameterSegmented<Value: Hashable>: View {
    private let title: LocalizedStringKey
    @Binding private var selection: Value
    private let choices: [SegmentedChoice<Value>]
    private let size: SegmentedSize
    private let fillsWidth: Bool

    /// `fillsWidth`: segments share the full width (CSS `.field > .segmented`).
    public init(_ title: LocalizedStringKey, selection: Binding<Value>, choices: [SegmentedChoice<Value>],
                size: SegmentedSize = .regular, fillsWidth: Bool = true) {
        self.title = title
        _selection = selection
        self.choices = choices
        self.size = size
        self.fillsWidth = fillsWidth
    }

    public var body: some View {
        let inset: CGFloat = size == .regular ? 3 : 2
        HStack(spacing: 3) {
            ForEach(choices) { choice in
                let selected = choice.value == selection
                Button {
                    selection = choice.value
                } label: {
                    if let systemImage = choice.systemImage {
                        Label(choice.title, systemImage: systemImage)
                    } else {
                        Text(choice.title)
                    }
                }
                .buttonStyle(SegmentButtonStyle(selected: selected, size: size, fillsWidth: fillsWidth))
                .disabled(!choice.isEnabled)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(inset)
        .frame(maxWidth: fillsWidth ? .infinity : nil)
        .background(Color.hdr.surfaceSunken, in: .rect(cornerRadius: Radius.md))
        .overlay {
            if size == .regular {
                RoundedRectangle(cornerRadius: Radius.md).strokeBorder(Color.hdr.lineStrong)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(title))
    }
}

private struct SegmentButtonStyle: ButtonStyle {
    let selected: Bool
    let size: SegmentedSize
    let fillsWidth: Bool

    func makeBody(configuration: Configuration) -> some View {
        SegmentBody(selected: selected, size: size, fillsWidth: fillsWidth, configuration: configuration)
    }
}

private struct SegmentBody: View {
    let selected: Bool
    let size: SegmentedSize
    let fillsWidth: Bool
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.colorSchemeContrast) private var contrast
    @State private var hovered = false

    var body: some View {
        let increased = contrast == .increased
        configuration.label
            .labelStyle(.titleAndIcon)
            .font(.system(size: TypeScale.Size.caption, weight: increased && selected ? .semibold : .medium))
            .lineLimit(1)
            .foregroundStyle(foreground(increased))
            .padding(.horizontal, fillsWidth ? 3 : size == .regular ? 12 : 9)
            .frame(maxWidth: fillsWidth ? .infinity : nil, minHeight: size == .regular ? 28 : 23)
            .background(fill(increased), in: .rect(cornerRadius: Radius.xs))
            .overlay {
                if increased && !selected {
                    RoundedRectangle(cornerRadius: Radius.xs).strokeBorder(Color.hdr.lineStrong)
                }
            }
            .contentShape(.rect(cornerRadius: Radius.xs))
            .opacity(isEnabled ? 1 : 0.45)
            .onHover { hovered = isEnabled && $0 }
            .hdrAnimation(Motion.fast, value: hovered)
            .hdrAnimation(Motion.standard, value: selected)
    }

    private func foreground(_ increased: Bool) -> Color {
        if selected { return increased ? .hdr.accentInk : .hdr.selectedInk }
        return hovered ? .hdr.inkStrong : .hdr.inkMuted
    }

    private func fill(_ increased: Bool) -> Color {
        if selected { return increased ? .hdr.accentFill : .hdr.selectedBackground }
        if configuration.isPressed { return .hdr.surfaceActive }
        return hovered ? .hdr.surfaceHover : .clear
    }
}
