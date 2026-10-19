import Foundation
import HyperDREngine
import Observation

/// Histogram counts in the fixed photographic coordinates of the Web
/// `histogram.js`: the lower 70% of the bins are SDR 0…100% (sRGB-encoded),
/// the upper 30% are +0…+4 EV above SDR white. Counts are unsmoothed.
nonisolated struct HistogramData: Equatable, Sendable {
    static let bins = 256, sdrShare = 0.7, hdrStops = 4.0
    let total: Int
    let luma, red, green, blue: [UInt32]
}

/// Luminance waveform: one column per slice of the photo's width, rows in
/// the histogram's coordinates (row 0 = black).
nonisolated struct WaveformData: Equatable, Sendable {
    static let rows = 256, maxColumns = 512
    let columns: Int
    /// `rows × columns`, row-major: `counts[row * columns + column]`.
    let counts: [UInt32]
}

/// What the scopes panel observes; nothing else does (batch4 §2.9).
@MainActor @Observable final class ScopeState {
    /// The reference frame: changes only with the photo.
    private(set) var original: HistogramData?
    private(set) var current: HistogramData?
    private(set) var waveform: WaveformData?

    func update(original: HistogramData??, current: HistogramData??, waveform: WaveformData??) {
        if let original, original != self.original { self.original = original }
        if let current, current != self.current { self.current = current }
        if let waveform, waveform != self.waveform { self.waveform = waveform }
    }
}

/// The planes of one preview frame, read in place. `PreviewFrame` keeps the
/// native storage alive; tests pass Swift arrays of the same layout.
nonisolated struct ScopeInput: @unchecked Sendable {
    let width, height, baseRowBytes: Int
    let gainWidth, gainHeight, gainRowBytes, gainChannels: Int
    let gainMin, gainMax, gainGamma, baseOffset, alternateOffset: Float
    private let access: ((UnsafeRawBufferPointer, UnsafeRawBufferPointer) -> Void) -> Void

    init(_ frame: PreviewFrame) {
        let metadata = frame.metadata
        width = frame.base.width; height = frame.base.height; baseRowBytes = frame.base.rowBytes
        gainWidth = frame.gain.width; gainHeight = frame.gain.height
        gainRowBytes = frame.gain.rowBytes; gainChannels = frame.gain.channels
        gainMin = Float(metadata.gainMin ?? 0); gainMax = Float(metadata.gainMax ?? 0)
        gainGamma = Float(metadata.gainGamma ?? 1)
        baseOffset = Float(metadata.baseOffset ?? 0); alternateOffset = Float(metadata.alternateOffset ?? 0)
        access = { body in
            frame.base.withUnsafeBytes { base in frame.gain.withUnsafeBytes { gain in body(base, gain) } }
        }
    }

    /// Tightly packed planes: base RGB, gain either one code channel
    /// (`gainChannels == 1`) or an RGB HDR image.
    init(width: Int, height: Int, base: [Float], gainWidth: Int, gainHeight: Int,
         gainChannels: Int, gain: [Float], gainMin: Float = 0, gainMax: Float = 0,
         gainGamma: Float = 1, baseOffset: Float = 0, alternateOffset: Float = 0) {
        self.width = width; self.height = height; baseRowBytes = width * 12
        self.gainWidth = gainWidth; self.gainHeight = gainHeight
        self.gainChannels = gainChannels; gainRowBytes = gainWidth * gainChannels * 4
        self.gainMin = gainMin; self.gainMax = gainMax; self.gainGamma = gainGamma
        self.baseOffset = baseOffset; self.alternateOffset = alternateOffset
        access = { body in
            base.withUnsafeBytes { base in gain.withUnsafeBytes { gain in body(base, gain) } }
        }
    }

    func withPlanes(_ body: (UnsafeRawBufferPointer, UnsafeRawBufferPointer) -> Void) { access(body) }
}

/// CPU statistics of a frame at full gain, i.e. the file's own HDR rendition,
/// independent of the screen (batch4 §2.9). Pure; runs off the main thread.
nonisolated enum ScopeAnalyzer {
    /// Display P3 luminance weights (the working colour space).
    static let lumaWeights: (Float, Float, Float) = (0.2289746, 0.6917385, 0.0792869)

    /// Linear value → 0…1 position on the histogram axis (`toneToNorm`).
    static func position(_ value: Float) -> Float {
        let v = max(0, value.isFinite ? value : 0)
        if v <= 1 {
            let encoded = v <= 0.0031308 ? 12.92 * v : 1.055 * powf(v, 1 / 2.4) - 0.055
            return Float(HistogramData.sdrShare) * encoded
        }
        return min(1, Float(HistogramData.sdrShare)
                   + Float(1 - HistogramData.sdrShare) * log2f(v) / Float(HistogramData.hdrStops))
    }

    static func bin(_ value: Float, count: Int) -> Int {
        min(count - 1, Int(position(value) * Float(count)))
    }

    struct Result: Sendable, Equatable {
        let histogram: HistogramData
        let waveform: WaveformData?
    }

    /// Nil when cancelled. `waveform: false` skips the waveform (the original).
    static func analyze(_ input: ScopeInput, waveform wantsWaveform: Bool) -> Result? {
        let width = input.width, height = input.height
        guard width > 0, height > 0 else { return nil }
        let bins = HistogramData.bins, rows = WaveformData.rows
        let columns = min(width, WaveformData.maxColumns)
        var luma = [UInt32](repeating: 0, count: bins), red = luma, green = luma, blue = luma
        var wave = [UInt32](repeating: 0, count: wantsWaveform ? rows * columns : 0)
        var cancelled = false
        let (wr, wg, wb) = lumaWeights
        let inverseGamma = 1 / max(input.gainGamma, 0.0001)
        input.withPlanes { base, gain in
            let baseStride = input.baseRowBytes / 4, gainStride = input.gainRowBytes / 4
            let basePixels = base.bindMemory(to: Float.self), gainPixels = gain.bindMemory(to: Float.self)
            let sx = Float(input.gainWidth) / Float(width), sy = Float(input.gainHeight) / Float(height)
            let maxGX = Float(input.gainWidth - 1), maxGY = Float(input.gainHeight - 1)
            for y in 0..<height {
                if y & 31 == 0, Task.isCancelled { cancelled = true; return }
                let gy = min(max((Float(y) + 0.5) * sy - 0.5, 0), maxGY)
                let y0 = Int(gy), y1 = min(y0 + 1, input.gainHeight - 1), fy = gy - Float(y0)
                for x in 0..<width {
                    var r: Float, g: Float, b: Float
                    if input.gainChannels == 1 {
                        let gx = min(max((Float(x) + 0.5) * sx - 0.5, 0), maxGX)
                        let x0 = Int(gx), x1 = min(x0 + 1, input.gainWidth - 1), fx = gx - Float(x0)
                        let top = gainPixels[y0 * gainStride + x0] * (1 - fx) + gainPixels[y0 * gainStride + x1] * fx
                        let bottom = gainPixels[y1 * gainStride + x0] * (1 - fx) + gainPixels[y1 * gainStride + x1] * fx
                        let code = min(max(top * (1 - fy) + bottom * fy, 0), 1)
                        let multiplier = exp2f(input.gainMin + (input.gainMax - input.gainMin) * powf(code, inverseGamma))
                        let i = y * baseStride + x * 3
                        r = max(0, (basePixels[i] + input.baseOffset) * multiplier - input.alternateOffset)
                        g = max(0, (basePixels[i + 1] + input.baseOffset) * multiplier - input.alternateOffset)
                        b = max(0, (basePixels[i + 2] + input.baseOffset) * multiplier - input.alternateOffset)
                    } else {
                        let i = y * gainStride + x * 3
                        r = gainPixels[i]; g = gainPixels[i + 1]; b = gainPixels[i + 2]
                    }
                    if !r.isFinite { r = 0 }; if !g.isFinite { g = 0 }; if !b.isFinite { b = 0 }
                    r = max(0, r); g = max(0, g); b = max(0, b)
                    let l = wr * r + wg * g + wb * b
                    let lumaBin = bin(l, count: bins)
                    luma[lumaBin] += 1
                    red[bin(r, count: bins)] += 1
                    green[bin(g, count: bins)] += 1
                    blue[bin(b, count: bins)] += 1
                    if wantsWaveform {
                        let column = x * columns / width
                        wave[bin(l, count: rows) * columns + column] += 1
                    }
                }
            }
        }
        guard !cancelled else { return nil }
        return Result(histogram: HistogramData(total: width * height, luma: luma, red: red, green: green, blue: blue),
                      waveform: wantsWaveform ? WaveformData(columns: columns, counts: wave) : nil)
    }
}
