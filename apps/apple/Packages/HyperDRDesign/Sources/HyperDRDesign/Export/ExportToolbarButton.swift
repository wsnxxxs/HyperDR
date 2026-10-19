import SwiftUI

/// What the toolbar's export button shows.
public enum ExportButtonState {
    /// Ready: the button's title ("Export", "Save JPEG").
    case idle(title: Text)
    /// An export is running; `fraction` is nil until there is an estimate.
    case exporting(fraction: Double?)
    /// Cannot export now, and why (the tooltip).
    case disabled(title: Text, reason: Text)
}

/// The toolbar's export button: an accent capsule, 28 pt high. While an
/// export runs it carries a ring and the percentage and opens the progress.
/// Its width is that of "Exporting 100%" in every state, so the toolbar
/// does not shift as the state or the digits change.
public struct ExportToolbarButton: View {
    public static let height: CGFloat = 28

    private let state: ExportButtonState
    private let action: () -> Void

    @State private var hovered = false

    public init(state: ExportButtonState, action: @escaping () -> Void) {
        self.state = state
        self.action = action
    }

    public var body: some View {
        Button(action: action) {
            ZStack {
                // The widest content, unseen, sets the minimum width.
                content(for: .exporting(fraction: 1)).hidden()
                content(for: state)
            }
            .padding(.horizontal, 12)
            .frame(height: Self.height)
            .background(fill, in: .capsule)
            .overlay { Capsule().strokeBorder(isDisabled ? Color.hdr.line : .clear) }
            .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .onHover { hovered = !isDisabled && $0 }
        .hdrAnimation(Motion.fast, value: hovered)
        .help(helpText)
    }

    private var isDisabled: Bool {
        if case .disabled = state { return true }
        return false
    }

    private var helpText: Text {
        if case .disabled(_, let reason) = state { return reason }
        return Text(verbatim: "")
    }

    private var fill: Color {
        isDisabled ? .hdr.surfaceSunken : hovered ? .hdr.accentFillHover : .hdr.accentFill
    }

    @ViewBuilder private func content(for state: ExportButtonState) -> some View {
        HStack(spacing: 6) {
            switch state {
            case .idle(let title):
                Image(systemName: "square.and.arrow.up").font(.system(size: 12, weight: .medium)).accessibilityHidden(true)
                title.lineLimit(1)
            case .exporting(let fraction):
                ProgressRing(fraction: fraction, size: 13)
                if let fraction {
                    Text("design.export.toolbar.exporting \(Self.percent(fraction))", bundle: .module)
                        .monospacedDigit().lineLimit(1)
                } else {
                    Text("design.export.toolbar.indeterminate", bundle: .module).lineLimit(1)
                }
            case .disabled(let title, _):
                Image(systemName: "square.and.arrow.up").font(.system(size: 12, weight: .medium)).accessibilityHidden(true)
                title.lineLimit(1)
            }
        }
        .font(.system(size: TypeScale.Size.control, weight: .semibold))
        .foregroundStyle(isDisabled ? Color.hdr.inkDisabled : Color.hdr.accentInk)
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((ExportProgressStyle.clamp(fraction) * 100).rounded()))%"
    }
}
