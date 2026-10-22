import Foundation

/// Independent CPU-double specification. This is a reference, never a render fallback.
public enum DoubleReference {
    public typealias RGB = SIMD3<Double>
    public struct Split: Sendable {
        public let base: RGB
        public let gains: RGB
        public var gain: Double { max(gains.x, gains.y, gains.z) }
        public init(base: RGB, gain: Double) { self.base = base; self.gains = RGB(repeating: gain) }
        public init(base: RGB, gains: RGB) { self.base = base; self.gains = gains }
    }

    public static func identity(_ rgb: RGB) -> RGB { rgb }
    public static func luma(_ rgb: RGB) -> Double {
        max(0, 0.2289746 * rgb.x + 0.6917385 * rgb.y + 0.0792869 * rgb.z)
    }
    private static func smooth(_ low: Double, _ high: Double, _ value: Double) -> Double {
        let t = min(1, max(0, (value - low) / (high - low)))
        return t * t * (3 - 2 * t)
    }
    private static func clamp(_ rgb: RGB, upper: Double) -> RGB {
        RGB(min(upper, max(0, rgb.x)), min(upper, max(0, rgb.y)), min(upper, max(0, rgb.z)))
    }
    private static func labRGB(_ L: Double, _ A: Double, _ B: Double) -> RGB {
        let l = L + 0.3963377774 * A + 0.2158037573 * B
        let m = L - 0.1055613458 * A - 0.0638541728 * B
        let s = L - 0.0894841775 * A - 1.2914855480 * B
        let ll = l * l * l, mm = m * m * m, ss = s * s * s
        return RGB(3.1281105290 * ll - 2.2570750184 * mm + 0.1293047884 * ss,
                   -1.0911281609 * ll + 2.4132667618 * mm - 0.3221681709 * ss,
                   -0.0260136497 * ll - 0.5080276490 * mm + 1.5333166822 * ss)
    }

    public static func fitP3(_ rgb: RGB, upper: Double = 1) -> RGB {
        if rgb.x >= 0 && rgb.y >= 0 && rgb.z >= 0 && rgb.x <= upper && rgb.y <= upper && rgb.z <= upper { return rgb }
        let y = min(upper, luma(rgb)), neutral = RGB(repeating: min(upper, luma(rgb)))
        guard y > 0 && y < upper else { return neutral }
        let l = cbrt(0.4813272912 * rgb.x + 0.4620679117 * rgb.y + 0.0564956029 * rgb.z)
        let m = cbrt(0.2288381013 * rgb.x + 0.6532343999 * rgb.y + 0.1179544132 * rgb.z)
        let s = cbrt(0.0839860178 * rgb.x + 0.2242727893 * rgb.y + 0.6922208389 * rgb.z)
        let L = 0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s
        let A = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let B = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        guard hypot(A, B) > 1e-9 else { return neutral }
        let hue = atan2(B, A) * 180 / Double.pi
        let weight = smooth(-170, -150, hue) * (1 - smooth(-60, -40, hue))
        var straight = neutral
        if weight > 0 {
            var amount = 1.0
            for channel in 0..<3 {
                let delta = rgb[channel] - y
                if delta > 0 { amount = min(amount, (upper - y) / delta) }
                if delta < 0 { amount = min(amount, -y / delta) }
            }
            straight = neutral + min(1, max(0, amount)) * (rgb - neutral)
            if weight >= 1 { return clamp(straight, upper: upper) }
        }
        var low = 0.0, high = 1.0, best = neutral
        for _ in 0..<32 {
            let mid = (low + high) / 2
            var candidate = labRGB(L, A * mid, B * mid)
            let brightness = luma(candidate)
            if brightness > 0 { candidate *= y / brightness }
            let tolerance = 1e-7 * max(upper, 1)
            if brightness > 0 && candidate.x >= -tolerance && candidate.y >= -tolerance && candidate.z >= -tolerance &&
                candidate.x <= upper + tolerance && candidate.y <= upper + tolerance && candidate.z <= upper + tolerance {
                low = mid
                best = candidate
            } else { high = mid }
        }
        return clamp(weight * straight + (1 - weight) * best, upper: upper)
    }

    // Source decomposition is independent of the downstream HDR capacity.
    public static func sourceHDRSplit(_ hdr: RGB) -> Split {
        let gain = log2(max(1, hdr.x, hdr.y, hdr.z))
        return Split(base: fitP3(hdr * exp2(-gain)), gain: gain)
    }

    /// AE-3 native-c controls with the same C1 upper contrast segment as P7-1.
    /// The editor's signed -100...100 contrast maps to c=0.625...1.6.
    public static func grade(_ source: RGB, exposure: Double = 0, contrast: Double = 1,
                             vibrance: Double = 0) -> RGB {
        var rgb = source * exp2(exposure)
        if contrast == 1 && vibrance == 0 { return rgb }
        let y = luma(rgb)
        guard y > 1e-6 else { return rgb }
        var target = y
        if contrast != 1 && y < 1 {
            if y <= 0.18 { target = 0.18 * pow(y / 0.18, contrast) }
            else {
                let t = (y-0.18)/0.82
                target = 0.18+0.82*(t+(contrast-1)*t*(1-t)*(1-t))
            }
        }
        rgb *= target / y
        let chroma = rgb - RGB(repeating: target)
        let saturation = max(abs(chroma.x), abs(chroma.y), abs(chroma.z)) / max(target, 1e-6)
        return RGB(repeating: target) + chroma * (1 + vibrance * (1 - smooth(0.15, 1, saturation)))
    }

    public static func decodeGain(_ encoded: Double, minimum: Double, maximum: Double, gamma: Double) -> Double {
        minimum + (maximum - minimum) * pow(min(1, max(0, encoded)), 1 / gamma)
    }

    /// Full alternate-headroom ISO reconstruction in the gain's working gamut.
    /// A one-channel gain is passed as RGB(repeating: gain). No clipping of negatives.
    public static func reconstruct(_ base: RGB, gain: RGB,
                                   baseOffset: RGB = .zero, alternateOffset: RGB = .zero) -> RGB {
        (base + baseOffset) * RGB(exp2(gain.x), exp2(gain.y), exp2(gain.z)) - alternateOffset
    }
}
