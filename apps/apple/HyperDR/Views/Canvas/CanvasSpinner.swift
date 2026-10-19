import SwiftUI
import HyperDRDesign

/// A spinner for the always-dark things on the canvas. `ProgressView` is an
/// AppKit control that follows the window's appearance, not the colour scheme
/// a view sets for itself, so on a light window it drew dark grey on the dark
/// canvas. This one is drawn in the overlay ink. Under Reduce Motion it stays
/// still: the words beside it say what is going on.
struct CanvasSpinner: View {
    var size: CGFloat = 16

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.canvasSpinnerTurn) private var fixedTurn

    var body: some View {
        TimelineView(.animation(paused: reduceMotion || fixedTurn != nil)) { context in
            let turn = fixedTurn ?? (reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9)
            Circle()
                .trim(from: 0, to: 0.72)
                .stroke(Color.hdr.overlayInk, style: StrokeStyle(lineWidth: max(1.5, size / 9), lineCap: .round))
                .rotationEffect(.degrees(turn * 360))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

extension EnvironmentValues {
    /// A turn (0…1) to hold the spinner at, so a picture of it is the same every time.
    @Entry var canvasSpinnerTurn: Double? = nil
}
