/// Which scope the panel shows.
public enum ScopeKind: String, Sendable, CaseIterable {
    case histogram, waveform
}

/// Whether the histogram is of luminance or of the three colour channels.
public enum HistogramChannels: String, Sendable, CaseIterable {
    case luma, rgb
}

/// Histogram bin counts on the scope's ruler (`ScopeScale`): bin `i` of `n`
/// covers positions `i/n …(i+1)/n`. Plain values, so the package does not
/// depend on the app's analyser; the app converts its own.
public struct HistogramCounts: Sendable, Equatable {
    public var luma: [UInt32]
    public var red: [UInt32]
    public var green: [UInt32]
    public var blue: [UInt32]

    public init(luma: [UInt32], red: [UInt32], green: [UInt32], blue: [UInt32]) {
        self.luma = luma
        self.red = red
        self.green = green
        self.blue = blue
    }
}

/// Luminance waveform counts: `rows × columns`, row-major
/// (`counts[row * columns + column]`), row 0 at black, columns across the
/// photograph, rows on the scope's ruler.
public struct WaveformCounts: Sendable, Equatable {
    public var columns: Int
    public var rows: Int
    public var counts: [UInt32]

    public init(columns: Int, rows: Int, counts: [UInt32]) {
        self.columns = columns
        self.rows = rows
        self.counts = counts
    }
}

/// What the scope panel draws once there is a measurement.
public struct ScopeData: Sendable, Equatable {
    /// The reference frame: what the photo looks like before any adjustment.
    public var original: HistogramCounts?
    /// The edited frame.
    public var current: HistogramCounts?
    public var waveform: WaveformCounts?

    public init(original: HistogramCounts? = nil, current: HistogramCounts? = nil, waveform: WaveformCounts? = nil) {
        self.original = original
        self.current = current
        self.waveform = waveform
    }
}

/// The scope panel's state of the measurement.
public enum ScopeContent: Sendable, Equatable {
    /// Waiting for the first measurement.
    case measuring
    /// The preview failed, so there is nothing to measure.
    case unavailable
    case data(ScopeData)
}
