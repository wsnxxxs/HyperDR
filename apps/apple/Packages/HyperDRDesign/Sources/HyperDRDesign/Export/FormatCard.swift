import SwiftUI

/// One choice among the export formats: its name, a line about it, and,
/// when this Mac or this photo cannot make it, the short reason.
///
/// - Normal, hover: a card on `surfaceCard`, a wash on hover.
/// - Selected: tinted, an accent outline and a check at the top right.
/// - Unavailable: sunken and muted, the reason in the warning colour in
///   place of the line; it does not take clicks. A selected format that
///   became unavailable keeps both looks, so the user sees what is chosen
///   and why it will not export.
/// - Disabled (the environment's `isEnabled`, while an export runs): the
///   same shapes, muted, without hover.
///
/// `help` is the full reason, as a tooltip.
public struct FormatCard: View {
    public static let height: CGFloat = 62

    private let name: Text
    private let detail: Text
    private let isSelected: Bool
    private let unavailableReason: Text?
    private let help: Text?
    private let width: CGFloat?
    private let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    public init(name: Text, detail: Text, isSelected: Bool, unavailableReason: Text? = nil, help: Text? = nil,
                width: CGFloat? = nil, action: @escaping () -> Void) {
        self.name = name
        self.detail = detail
        self.isSelected = isSelected
        self.unavailableReason = unavailableReason
        self.help = help
        self.width = width
        self.action = action
    }

    private var isAvailable: Bool { unavailableReason == nil }

    public var body: some View {
        // An unavailable card is not `.disabled`: the system would dim its
        // label, and the reason has to stay in the full warning colour. It only
        // does not take the click.
        Button(action: { if isAvailable { action() } }) {
            VStack(alignment: .leading, spacing: 3) {
                name
                    .font(.system(size: TypeScale.Size.control, weight: .semibold))
                    .foregroundStyle(nameColor)
                    .lineLimit(1)
                if let unavailableReason {
                    HStack(alignment: .firstTextBaseline, spacing: 3) {
                        Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 9)).accessibilityHidden(true)
                        unavailableReason.lineLimit(2).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.system(size: 11))
                    .foregroundStyle(Color.hdr.warn)
                } else {
                    detail
                        .font(.system(size: 11))
                        .foregroundStyle(isEnabled ? Color.hdr.inkMuted : Color.hdr.inkDisabled)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .frame(width: width, height: Self.height, alignment: .topLeading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .topLeading)
            // The state's fill is drawn over the opaque card surface (a
            // later `background` goes behind an earlier one), so the
            // translucent selected wash shows instead of being covered.
            .background(fill, in: .rect(cornerRadius: Radius.md))
            .background(Color.hdr.surfaceCard, in: .rect(cornerRadius: Radius.md))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.md)
                    .strokeBorder(stroke, lineWidth: isSelected ? 1.5 : 1)
            }
            .overlay(alignment: .topTrailing) {
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(isEnabled ? Color.hdr.accent : Color.hdr.inkDisabled)
                        .padding(7)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(.rect(cornerRadius: Radius.md))
        }
        .buttonStyle(.plain)
        .onHover { hovered = isEnabled && isAvailable && $0 }
        .hdrAnimation(Motion.fast, value: hovered)
        .help(help ?? Text(verbatim: ""))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .accessibilityRemoveTraits(isAvailable ? [] : .isButton)
    }

    /// Unavailable reads muted but legible; only a locked card (the export is
    /// running) goes to the disabled ink.
    private var nameColor: Color {
        if !isEnabled { return isSelected && isAvailable ? .hdr.inkMuted : .hdr.inkDisabled }
        if !isAvailable { return .hdr.inkMuted }
        return isSelected ? .hdr.selectedInk : .hdr.inkStrong
    }

    private var fill: Color {
        if isSelected { return isEnabled ? .hdr.selectedBackground : .hdr.selectedBackground.opacity(0.6) }
        if !isAvailable || !isEnabled { return .hdr.surfaceSunken }
        return hovered ? .hdr.surfaceHover : .hdr.surfaceCard
    }

    private var stroke: Color {
        if isSelected { return isEnabled ? .hdr.accent : .hdr.selectedLine }
        return .hdr.line
    }
}
