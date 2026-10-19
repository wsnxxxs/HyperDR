import SwiftUI

/// The text button at the right of a section heading that resets the
/// section ("Reset"), and for a moment afterwards says it did ("✓ All
/// reset").
///
/// `isDone` is the caller's: it shows the done title, in the success colour,
/// while the caller keeps it up (1.5 s in the inspector), and a click in the
/// meantime does nothing. A disabled button has nothing to reset.
public struct SectionResetButton: View {
    private let title: LocalizedStringKey
    private let doneTitle: LocalizedStringKey
    private let isDone: Bool
    private let action: () -> Void

    @Environment(\.isEnabled) private var isEnabled
    @State private var hovered = false

    public init(_ title: LocalizedStringKey, doneTitle: LocalizedStringKey, isDone: Bool, action: @escaping () -> Void) {
        self.title = title
        self.doneTitle = doneTitle
        self.isDone = isDone
        self.action = action
    }

    public var body: some View {
        Button {
            if !isDone { action() }
        } label: {
            if isDone {
                Label(doneTitle, systemImage: "checkmark")
                    .labelStyle(.titleAndIcon)
                    .foregroundStyle(Color.hdr.success)
            } else {
                Text(title)
                    .foregroundStyle(!isEnabled ? Color.hdr.inkDisabled : hovered ? Color.hdr.accentHover : Color.hdr.accent)
            }
        }
        .buttonStyle(.plain)
        .font(.system(size: TypeScale.Size.caption, weight: .medium))
        .onHover { hovered = $0 }
        .hdrAnimation(Motion.fast, value: hovered)
        .hdrAnimation(Motion.standard, value: isDone)
    }
}
