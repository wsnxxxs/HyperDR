import SwiftUI

/// The pill of text at the foot of the canvas that tells how to use it
/// ("Press and hold the photo or Space to see the original").
///
/// This is only the look: a 30 pt capsule on the overlay colour, at most 560
/// pt wide, wrapping to centred lines beyond that. When it appears, how long
/// it stays and how often are the canvas view's.
public struct CanvasHint: View {
    private let text: Text

    public init(_ text: Text) { self.text = text }

    public var body: some View {
        CappedWidth(max: Self.maxWidth) {
            pill
        }
        .accessibilityElement(children: .combine)
    }

    private var pill: some View {
        text
            .font(.hdr.caption)
            .foregroundStyle(Color.hdr.overlayInk)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .frame(minHeight: 30)
            .background(Color.hdr.overlay, in: .capsule)
            .overlay { Capsule().strokeBorder(Color.hdr.overlayLine) }
    }

    /// The widest the pill gets; the canvas narrows it further with its own
    /// width less 32 pt.
    public static let maxWidth: CGFloat = 560
}

/// Sizes to its content, which is offered at most `max` points of width:
/// unlike `frame(maxWidth:)`, it does not grow to the room it is given.
private struct CappedWidth: SwiftUI.Layout {
    let max: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        return subview.sizeThatFits(ProposedViewSize(width: Swift.min(proposal.width ?? max, max), height: proposal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}
