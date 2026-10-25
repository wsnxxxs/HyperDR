import SwiftUI

/// The white balance eyedropper as the generated controls see it: whether the
/// host is waiting for a click on the photograph, what the last pick said,
/// and how to start or stop it. The host owns the sampling (the canvas, the
/// loupe, the editor's `pickWhiteBalance`); the controls only show the button
/// beside the temperature row and a line under it (adjust-controls F1).
public struct WhiteBalancePicking {
    /// What the last pick left to say under the temperature row.
    public enum Notice: Equatable, Sendable {
        /// The neutral needs a value beyond the slider's end; the end was set.
        case clamped
        /// The point could not be sampled.
        case failed
    }

    /// The canvas is waiting for a click.
    public var isActive: Bool
    public var notice: Notice?
    /// Starts picking, or stops it when it is active.
    public var toggle: () -> Void

    public init(isActive: Bool, notice: Notice? = nil, toggle: @escaping () -> Void) {
        self.isActive = isActive
        self.notice = notice
        self.toggle = toggle
    }

    /// The rows the eyedropper belongs to: RAW's temperature and the
    /// warmth of every other photo.
    public static func offers(_ id: String) -> Bool {
        id == "develop.temperature" || id == "color.warmth"
    }
}

extension EnvironmentValues {
    /// Set by a host that can sample white balance from its canvas. Without
    /// it the temperature row has no eyedropper (the iPhone's, for now).
    @Entry public var whiteBalancePicking: WhiteBalancePicking?
}

/// The eyedropper button: a 22 pt square beside the readout on the Mac, a
/// 44 pt one for a finger.
public struct WhiteBalancePickButton: View {
    private let picking: WhiteBalancePicking
    private let size: CGFloat
    @State private var hovered = false
    @Environment(\.isEnabled) private var isEnabled

    public init(_ picking: WhiteBalancePicking, size: CGFloat = 22) {
        self.picking = picking
        self.size = size
    }

    public var body: some View {
        let label = Text(picking.isActive ? "design.wb.stop" : "design.wb.pick", bundle: .module)
        Button(action: picking.toggle) {
            Image(systemName: "eyedropper")
                .font(.system(size: touch ? 17 : 12, weight: .medium))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .background(fill, in: .rect(cornerRadius: radius))
                .overlay {
                    if !touch { RoundedRectangle(cornerRadius: radius).strokeBorder(picking.isActive ? Color.clear : Color.hdr.line) }
                }
                .contentShape(.rect(cornerRadius: radius))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(label)
        .accessibilityLabel(label)
        .accessibilityAddTraits(picking.isActive ? .isSelected : [])
    }

    /// A finger's size: a filled square like the Studio's rows, not an outlined one.
    private var touch: Bool { size >= 40 }
    private var radius: CGFloat { touch ? 10 : Radius.xs }

    private var fill: Color {
        if picking.isActive { return Color.hdr.accentFill }
        if touch { return Color.white.opacity(0.06) }
        return hovered && isEnabled ? Color.hdr.surfaceHover : Color.clear
    }

    private var foreground: Color {
        if !isEnabled { return Color.hdr.inkDisabled }
        return picking.isActive ? Color.white : hovered ? Color.hdr.inkStrong : Color.hdr.inkMuted
    }
}

/// The line under the temperature row after a pick that was held at the end
/// of the slider, or could not be taken.
public struct WhiteBalanceNoticeLine: View {
    private let notice: WhiteBalancePicking.Notice

    public init(_ notice: WhiteBalancePicking.Notice) { self.notice = notice }

    public var body: some View {
        Label {
            Text(notice == .clamped ? "design.wb.clamped" : "design.wb.failed", bundle: .module)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(Font.hdr.caption)
        .foregroundStyle(Color.hdr.warn)
        .fixedSize(horizontal: false, vertical: true)
        .transition(.opacity)
    }
}
