import Foundation

/// The ruler shared by the histogram and the waveform: where its marks sit
/// and what they say, on top of `ScopeScale`'s coordinates (M2-D §4).
public extension ScopeScale {
    /// Position of an sRGB-encoded SDR value, 0…1 → 0…`sdrShare`.
    static func position(sdrEncoded value: Double) -> Double {
        sdrShare * min(max(value.isFinite ? value : 0, 0), 1)
    }

    /// Position of a level `stops` above SDR white, clamped to SDR white …
    /// `hdrStops` above it. Same coordinates as `position(_:)` for a linear
    /// value of `2^stops`.
    static func position(stops: Double) -> Double {
        sdrShare + (1 - sdrShare) * min(max(stops.isFinite ? stops : 0, 0), hdrStops) / hdrStops
    }

    /// One mark on the ruler.
    struct Tick: Sendable, Equatable {
        public enum Anchor: Sendable { case leading, center, trailing }
        public let position: Double
        /// The text under the mark: a number and a unit, so not localized.
        public let label: String?
        /// A long mark (with its label) or a short one.
        public let isMajor: Bool

        /// Which edge of its label sits on the mark: the first label starts
        /// at it and the last ends at it, so neither leaves the ruler.
        public var anchor: Anchor { position <= 0 ? .leading : position >= 1 ? .trailing : .center }
    }

    /// 0, sRGB 50%, SDR white, +1 EV … +4 EV. Only 0, SDR 100%, +2 and +4 EV
    /// are labelled; the rest are marks.
    static let ticks: [Tick] = [
        Tick(position: 0, label: "0", isMajor: true),
        Tick(position: position(sdrEncoded: 0.5), label: nil, isMajor: false),
        Tick(position: position(stops: 0), label: "SDR 100%", isMajor: true),
        Tick(position: position(stops: 1), label: nil, isMajor: false),
        Tick(position: position(stops: 2), label: "+2", isMajor: true),
        Tick(position: position(stops: 3), label: nil, isMajor: false),
        Tick(position: position(stops: 4), label: "+4 EV", isMajor: true),
    ]
}
