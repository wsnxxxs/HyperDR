import Foundation

/// Shared scale for histogram, luminance waveform and the CPU analyser.
/// Lower 70%: sRGB-encoded SDR; upper 30%: four stops above SDR white.
public enum ScopeScale {
    public static let sdrShare = 0.7
    public static let hdrStops = 4.0

    public static func position(_ linear: Double) -> Double {
        let value = max(0, linear.isFinite ? linear : 0)
        if value <= 1 {
            let encoded = value <= 0.0031308 ? 12.92 * value : 1.055 * pow(value, 1 / 2.4) - 0.055
            return sdrShare * encoded
        }
        return min(1, sdrShare + (1 - sdrShare) * log2(value) / hdrStops)
    }
}
