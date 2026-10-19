import SwiftUI

/// What an export's progress bar shows.
public enum ExportProgressStyle: Sendable, Equatable {
    /// A fraction 0…1 (clamped).
    case determinate(Double)
    /// Nothing is known yet: a band moves to and fro.
    case indeterminate
    /// Past the estimate: the bar waits at 99 % and its stripes keep moving,
    /// so it does not look dead.
    case overdue
    /// Being stopped: grey and still, where it was.
    case stopped(Double)

    /// The cap of a bar that is not done: 99 % until the export completes.
    public static let overdueFraction = 0.99

    /// How full the bar is, 0…1; nil when it has no fraction.
    public var fraction: Double? {
        switch self {
        case .determinate(let value), .stopped(let value): Self.clamp(value)
        case .overdue: Self.overdueFraction
        case .indeterminate: nil
        }
    }

    static func clamp(_ value: Double) -> Double { value.isNaN ? 0 : min(max(value, 0), 1) }
}

/// The export's progress bar: 4 pt in the inspector's status card, 8 pt in
/// the export panel. A fixed fill for a known fraction; for the others a
/// band that moves (a slow fade instead under Reduce Motion).
public struct ExportProgressBar: View {
    private let progress: ExportProgressStyle
    private let height: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(progress: ExportProgressStyle, height: CGFloat = 4) {
        self.progress = progress
        self.height = height
    }

    public var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.hdr.controlTrack)
                fill(width: proxy.size.width)
            }
            .clipShape(Capsule())
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel(Text("design.export.progress", bundle: .module))
        .accessibilityValue(progress.fraction.map { Text("\(Int(($0 * 100).rounded()))%") } ?? Text(verbatim: ""))
    }

    @ViewBuilder private func fill(width: CGFloat) -> some View {
        switch progress {
        case .determinate(let value):
            Capsule().fill(Color.hdr.accent).frame(width: width * ExportProgressStyle.clamp(value))
        case .stopped(let value):
            Capsule().fill(Color.hdr.inkDisabled).frame(width: width * ExportProgressStyle.clamp(value))
        case .overdue:
            Capsule().fill(Color.hdr.accent)
                .overlay { Stripes(animated: !reduceMotion).clipShape(Capsule()) }
                .frame(width: width * ExportProgressStyle.overdueFraction)
        case .indeterminate:
            Indeterminate(width: width, reduceMotion: reduceMotion)
        }
    }
}

/// A band 30 % of the track wide, moving to and fro every 1.4 s; with
/// Reduce Motion the whole bar breathes at about 40 % instead.
private struct Indeterminate: View {
    let width: CGFloat
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            if reduceMotion {
                Capsule().fill(Color.hdr.accent)
                    .opacity(0.4 + 0.15 * sin(t * 2 * .pi / 1.4))
            } else {
                let phase = (t / 1.4).truncatingRemainder(dividingBy: 1)
                let position = phase < 0.5 ? phase * 2 : (1 - phase) * 2
                let eased = position * position * (3 - 2 * position)
                Capsule()
                    .fill(LinearGradient(colors: [Color.hdr.accent.opacity(0), Color.hdr.accent, Color.hdr.accent.opacity(0)],
                                         startPoint: .leading, endPoint: .trailing))
                    .frame(width: width * 0.3)
                    .offset(x: eased * width * 0.7)
            }
        }
    }
}

/// Diagonal light stripes drifting right.
private struct Stripes: View {
    let animated: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: !animated)) { context in
            let drift = animated ? context.date.timeIntervalSinceReferenceDate * 10 : 0
            Canvas { graphics, size in
                let pitch: CGFloat = 12
                let start = CGFloat(drift.truncatingRemainder(dividingBy: Double(pitch))) - pitch * 2
                var x = start
                while x < size.width + size.height {
                    var stripe = Path()
                    stripe.move(to: CGPoint(x: x, y: size.height))
                    stripe.addLine(to: CGPoint(x: x + size.height, y: 0))
                    stripe.addLine(to: CGPoint(x: x + size.height + pitch / 2, y: 0))
                    stripe.addLine(to: CGPoint(x: x + pitch / 2, y: size.height))
                    stripe.closeSubpath()
                    graphics.fill(stripe, with: .color(.white.opacity(0.28)))
                    x += pitch
                }
            }
        }
        .allowsHitTesting(false)
    }
}

/// A small ring: a fraction of a circle filled, or, with no fraction, an arc
/// that turns. White on the accent by default, for the toolbar's button.
public struct ProgressRing: View {
    private let fraction: Double?
    private let size: CGFloat
    private let tint: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    public init(fraction: Double?, size: CGFloat = 14, tint: Color = Color.hdr.accentInk) {
        self.fraction = fraction
        self.size = size
        self.tint = tint
    }

    public var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.3), lineWidth: lineWidth)
            if let fraction {
                arc(from: 0, to: ExportProgressStyle.clamp(fraction))
            } else if reduceMotion {
                arc(from: 0, to: 0.25)
            } else {
                TimelineView(.animation(minimumInterval: 1.0 / 30)) { context in
                    let turn = (context.date.timeIntervalSinceReferenceDate / 0.9).truncatingRemainder(dividingBy: 1)
                    arc(from: 0, to: 0.28).rotationEffect(.degrees(turn * 360))
                }
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    private var lineWidth: CGFloat { max(size / 7, 1.5) }

    private func arc(from: Double, to: Double) -> some View {
        Circle()
            .trim(from: from, to: to)
            .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
            .rotationEffect(.degrees(-90))
    }
}
