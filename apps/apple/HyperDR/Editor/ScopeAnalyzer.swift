import Foundation
import HyperDRRender
import Metal
import simd
import HyperDRDesign
import Observation
import Synchronization

/// Histogram counts in the fixed photographic coordinates of the Web
/// `histogram.js`: the lower 70% of the bins are SDR 0…100% (sRGB-encoded),
/// the upper 30% are +0…+4 EV above SDR white. Counts are unsmoothed.
nonisolated struct HistogramData: Equatable, Sendable {
    static let bins = 256
    static let sdrShare = ScopeScale.sdrShare, hdrStops = ScopeScale.hdrStops
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

/// The planes the scopes read: base RGB, and either a gain code plane or the
/// HDR rendition itself. Built from a small render (`init(pair:)`); tests
/// pass Swift arrays of the same layout.
nonisolated struct ScopeInput: @unchecked Sendable {
    let width, height, baseRowBytes: Int
    let gainWidth, gainHeight, gainRowBytes, gainChannels: Int
    let gainMin, gainMax, gainGamma, baseOffset, alternateOffset: Float
    private let access: ((UnsafeRawBufferPointer, UnsafeRawBufferPointer) -> Void) -> Void

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

    /// A display pair at full gain, i.e. the file's own HDR rendition: the
    /// base, and the HDR it reconstructs per base pixel (ISO 21496-1 with the
    /// pair's matrices and offsets, gain sampled bilinearly). Reads both
    /// textures back through a blit, whatever their storage.
    static func read(_ pair: DisplayGainPair) async throws -> ScopeInput {
        let base = try await TextureReadback.floats(pair.base)
        let gain = try await TextureReadback.floats(pair.gain)
        let width = pair.base.width, height = pair.base.height
        let gw = pair.gain.width, gh = pair.gain.height
        let gainStride = gain.count / max(1, gw * gh)
        var rgb = [Float](repeating: 0, count: width * height * 3)
        var hdr = rgb
        let identity = pair.p3ToGain == matrix_identity_float3x3 && pair.gainToP3 == matrix_identity_float3x3
        for y in 0..<height {
            if y & 31 == 0 { try Task.checkCancellation() }
            let fy = min(max((Float(y) + 0.5) * Float(gh) / Float(height) - 0.5, 0), Float(gh - 1))
            let y0 = Int(fy), y1 = min(y0 + 1, gh - 1), wy = fy - Float(y0)
            for x in 0..<width {
                let fx = min(max((Float(x) + 0.5) * Float(gw) / Float(width) - 0.5, 0), Float(gw - 1))
                let x0 = Int(fx), x1 = min(x0 + 1, gw - 1), wx = fx - Float(x0)
                func g(_ px: Int, _ py: Int) -> SIMD3<Float> {
                    let i = (py * gw + px) * gainStride
                    return pair.gainChannelCount == 1 ? SIMD3(repeating: gain[i]) : SIMD3(gain[i], gain[i + 1], gain[i + 2])
                }
                let stops = (g(x0, y0) * (1 - wx) + g(x1, y0) * wx) * (1 - wy) + (g(x0, y1) * (1 - wx) + g(x1, y1) * wx) * wy
                let b = (y * width + x) * 4
                let sdr = SIMD3(base[b], base[b + 1], base[b + 2])
                let scale = SIMD3(exp2f(stops.x), exp2f(stops.y), exp2f(stops.z))
                var value = identity ? (sdr + pair.baseOffset) * scale - pair.alternateOffset
                    : pair.gainToP3 * ((pair.p3ToGain * sdr + pair.baseOffset) * scale - pair.alternateOffset)
                value = simd_max(value, .zero)
                let o = (y * width + x) * 3
                rgb[o] = sdr.x; rgb[o + 1] = sdr.y; rgb[o + 2] = sdr.z
                hdr[o] = value.x; hdr[o + 1] = value.y; hdr[o + 2] = value.z
            }
        }
        return ScopeInput(width: width, height: height, base: rgb, gainWidth: width, gainHeight: height,
                          gainChannels: 3, gain: hdr)
    }
}

/// Copies a texture into shared memory as floats (half, float, R or RGBA).
nonisolated enum TextureReadback {
    private static let queues = Mutex<[ObjectIdentifier: any MTLCommandQueue]>([:])

    static func floats(_ texture: any MTLTexture) async throws -> [Float] {
        let device = texture.device
        let queue = try queues.withLock { queues -> any MTLCommandQueue in
            if let queue = queues[ObjectIdentifier(device)] { return queue }
            guard let queue = device.makeCommandQueue() else { throw CancellationError() }
            queues[ObjectIdentifier(device)] = queue
            return queue
        }
        let (channels, half): (Int, Bool) = switch texture.pixelFormat {
        case .r16Float: (1, true)
        case .r32Float: (1, false)
        case .rgba16Float: (4, true)
        default: (4, false)
        }
        let rowBytes = texture.width * channels * (half ? 2 : 4)
        guard let buffer = device.makeBuffer(length: max(1, rowBytes * texture.height), options: .storageModeShared),
              let command = queue.makeCommandBuffer(), let blit = command.makeBlitCommandEncoder() else {
            throw CancellationError()
        }
        blit.copy(from: texture, sourceSlice: 0, sourceLevel: 0, sourceOrigin: MTLOrigin(),
                  sourceSize: MTLSize(width: texture.width, height: texture.height, depth: 1),
                  to: buffer, destinationOffset: 0, destinationBytesPerRow: rowBytes,
                  destinationBytesPerImage: rowBytes * texture.height)
        blit.endEncoding()
        await withCheckedContinuation { continuation in
            command.addCompletedHandler { _ in continuation.resume() }
            command.commit()
        }
        if let error = command.error { throw error }
        let count = texture.width * texture.height * channels
        if half {
            let values = buffer.contents().bindMemory(to: Float16.self, capacity: count)
            return (0..<count).map { Float(values[$0]) }
        }
        return Array(UnsafeBufferPointer(start: buffer.contents().bindMemory(to: Float.self, capacity: count), count: count))
    }
}

/// CPU statistics of a frame at full gain, i.e. the file's own HDR rendition,
/// independent of the screen (batch4 §2.9). Pure; runs off the main thread.
nonisolated enum ScopeAnalyzer {
    /// Display P3 luminance weights (the working colour space).
    static let lumaWeights: (Float, Float, Float) = (0.2289746, 0.6917385, 0.0792869)

    /// Linear value → 0…1 position on the histogram axis (`toneToNorm`).
    static func position(_ value: Float) -> Float {
        Float(ScopeScale.position(Double(value)))
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
