import SwiftUI

/// A label and its value on one line: the export summary, the result card,
/// the camera and lens group. The label column is a fixed 64 pt wide so
/// the values of a stack of rows line up; a long value wraps under itself.
public struct FactRow: View {
    public enum Tone: Sendable {
        case normal
        /// Good news in the accent ("Read back and verified").
        case success
        /// Something to look at, in the warning colour.
        case warn
        /// A value that is not there ("—"): quieter than a real one.
        case muted
    }

    public static let labelWidth: CGFloat = 64

    private let label: Text
    private let value: Text
    private let tone: Tone
    private let monospaced: Bool

    public init(label: Text, value: Text, tone: Tone = .normal, monospaced: Bool = false) {
        self.label = label
        self.value = value
        self.tone = tone
        self.monospaced = monospaced
    }

    public var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Space.s2) {
            label
                .font(.hdr.caption)
                .foregroundStyle(Color.hdr.inkMuted)
                .frame(width: Self.labelWidth, alignment: .leading)
            value
                .font(monospaced ? .hdr.readout : .hdr.caption)
                .foregroundStyle(valueColor)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
    }

    private var valueColor: Color {
        switch tone {
        case .normal: .hdr.ink
        case .success: .hdr.success
        case .warn: .hdr.warn
        case .muted: .hdr.inkMuted
        }
    }
}
