import Foundation

/// What the write step does with the gain map (gpu-pipeline §3).
public struct GainMapPlan: Sendable, Hashable {
    public enum Origin: String, Sendable, Hashable, Codable {
        /// The output is SDR: no gain map is written at all.
        case none
        /// We separated it ourselves (max-channel, `hdr` / `rawEDR`, or expansion
        /// from an `sdr` source): one channel, offsets zero.
        case separated
        /// The photo's own pair: its channel count and offsets are kept (a `dual`
        /// source with no edit, or with only the HDR group changed; p7-adjustments
        /// H1 exception). A framed export keeps it too and zeroes the gain under
        /// the frame (E5), so `zeroGainInFrame` still applies.
        case authored
        /// The photo's own pair re-separated by us (gpu-pipeline §3, "resplit").
        case resplit
    }

    public let origin: Origin
    /// 1 for everything we separate; 1 or 3 for an authored pair.
    public let channels: Int
    /// Framed exports keep the frame SDR: every pixel the frame fills carries
    /// zero gain, so a mat and its shadow never become HDR.
    public let zeroGainInFrame: Bool
    /// Set for `.resplit`, nil otherwise.
    public let resplitReason: ResplitReason?

    public var writesGainMap: Bool { origin != .none }

    /// Everything we separate is mono with base and alternate offset zero; an
    /// authored pair keeps the offsets the file carries.
    public var usesZeroOffsets: Bool { origin == .separated || origin == .resplit }

    public init(origin: Origin, channels: Int, zeroGainInFrame: Bool,
                resplitReason: ResplitReason? = nil) {
        self.origin = origin
        self.channels = channels
        self.zeroGainInFrame = zeroGainInFrame
        self.resplitReason = resplitReason
    }

    public static let sdr = GainMapPlan(origin: .none, channels: 0, zeroGainInFrame: false)
}

/// Why an authored pair could not be written as it is.
public enum ResplitReason: String, Sendable, Hashable, Codable {
    /// The chosen writer only carries a one-channel gain map, so a three-channel
    /// authored pair has to be separated again.
    case writerCarriesOneChannel
    /// Tone, colour or look changed, so the gain is no longer a transform of the
    /// photo's own map (gpu-pipeline §3): rebuild the HDR, process, re-separate.
    case editedBeyondGain
}
