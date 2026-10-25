import HyperDRDesign
import SwiftUI

/// The export's one ring. While Kit cannot yet say how far the export has
/// come (reading the photo, predicting HDR), a short arc turns on the same
/// track; it gives way to the arc that fills once, from the first row to the
/// saved file. While the file is checked and saved, a faint light runs round
/// the part still to fill, so a long check does not look stuck. Reduce Motion
/// keeps the arcs and stops the turning and the light.
struct ExportProgressRing: View {
    /// Kit's overall fraction, never moving back; nil while it is unknown.
    let fraction: Double?
    /// Every row is written: what is left is checking and saving the file.
    let finishing: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let line: CGFloat = 6
    /// Seconds for the waiting arc's turn and the light's run.
    private static let period = 1.4

    var body: some View {
        let moving = !reduceMotion && (fraction == nil || finishing)
        TimelineView(.animation(paused: !moving)) { context in
            let phase = context.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: Self.period) / Self.period
            ZStack {
                Circle().stroke(Color.white.opacity(0.1), lineWidth: Self.line)
                // Waiting: a quarter arc turning.
                Circle()
                    .trim(from: 0, to: 0.24)
                    .stroke(Color.hdr.accent, style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
                    .rotationEffect(.degrees(-90 + (reduceMotion ? 0 : 360 * phase)))
                    .opacity(fraction == nil ? 1 : 0)
                // Running: the arc that fills once.
                Circle()
                    .trim(from: 0, to: fraction ?? 0)
                    .stroke(Color.hdr.accent, style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                if finishing, let fraction, fraction < 1, !reduceMotion {
                    let start = fraction + (1 - fraction) * phase
                    Circle()
                        .trim(from: start, to: min(1, start + 0.06))
                        .stroke(Color.hdr.accent.opacity(0.45 * (1 - phase)),
                                style: StrokeStyle(lineWidth: Self.line, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                }
                if let fraction {
                    Text(fraction, format: .percent.precision(.fractionLength(0)))
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .contentTransition(.numericText(value: fraction))
                        .transition(.opacity.combined(with: .scale(scale: 0.8)))
                }
            }
        }
        .animation(.smooth(duration: 0.45), value: fraction)
        .accessibilityElement()
        .accessibilityValue(fraction.map { Text($0, format: .percent.precision(.fractionLength(0))) } ?? Text(""))
    }
}
