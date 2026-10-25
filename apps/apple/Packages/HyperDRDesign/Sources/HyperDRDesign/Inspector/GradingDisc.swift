import CoreGraphics
import SwiftUI

/// The colour disc the grading wheels are drawn on (controls-polish §5): every
/// point in OKLCH at one lightness, its hue the angle (clockwise from the
/// right, as the puck and the recipe's hue are: the shader's OKLab ab angle)
/// and its chroma growing from the neutral middle to the rim. The rim holds
/// the most chroma the lightness allows in sRGB, up to `chromaCap`, so every
/// hue reads clearly and none is muddied by a grey laid over it.
///
/// It shows which way a hue pushes, not the colour the photo takes: that is
/// the puck's (`GradingColor.displayRGB`, the shader's own result on grey).
enum GradingDisc {
    /// The most chroma the rim takes.
    static let chromaCap = 0.13

    /// The disc's lightness: light on a light panel, lower on a dark one, so
    /// it sits in the panel rather than glowing out of it.
    static func lightness(_ scheme: ColorScheme) -> Double { scheme == .dark ? 0.68 : 0.80 }

    /// Linear sRGB of an OKLab colour.
    static func linearSRGB(l: Double, a: Double, b: Double) -> SIMD3<Double> {
        let l1 = pow(l + 0.3963377774 * a + 0.2158037573 * b, 3)
        let m1 = pow(l - 0.1055613458 * a - 0.0638541728 * b, 3)
        let s1 = pow(l - 0.0894841775 * a - 1.2914855480 * b, 3)
        return SIMD3(4.0767416621 * l1 - 3.3077115913 * m1 + 0.2309699292 * s1,
                     -1.2684380046 * l1 + 2.6097574011 * m1 - 0.3413193965 * s1,
                     -0.0041960863 * l1 - 0.7034186147 * m1 + 1.7076147010 * s1)
    }

    /// OKLab of a linear sRGB colour, for the tests' check that the disc's
    /// angle is the recipe's hue.
    static func oklab(linear rgb: SIMD3<Double>) -> SIMD3<Double> {
        let l = cbrt(0.4122214708 * rgb.x + 0.5363325363 * rgb.y + 0.0514459929 * rgb.z)
        let m = cbrt(0.2119034982 * rgb.x + 0.6806995451 * rgb.y + 0.1073969566 * rgb.z)
        let s = cbrt(0.0883024619 * rgb.x + 0.2817188376 * rgb.y + 0.6299787005 * rgb.z)
        return SIMD3(0.2104542553 * l + 0.7936177850 * m - 0.0040720468 * s,
                     1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s,
                     0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s)
    }

    static func encode(_ value: Double) -> Double {
        let x = min(1, max(0, value))
        return x <= 0.0031308 ? 12.92 * x : 1.055 * pow(x, 1 / 2.4) - 0.055
    }

    /// The most chroma at a lightness and hue (degrees) that stays in sRGB, capped.
    static func maxChroma(lightness: Double, hue: Double) -> Double {
        let angle = hue * .pi / 180
        var low = 0.0, high = chromaCap
        func inside(_ c: Double) -> Bool {
            let rgb = linearSRGB(l: lightness, a: c * cos(angle), b: c * sin(angle))
            return rgb.min() >= -1e-6 && rgb.max() <= 1 + 1e-6
        }
        if inside(high) { return high }
        for _ in 0..<18 {
            let mid = (low + high) / 2
            if inside(mid) { low = mid } else { high = mid }
        }
        return low
    }

    /// The disc's colour, nonlinear sRGB, at a hue (degrees) and saturation
    /// (0…100, the distance from the middle to the rim).
    static func rgb(hue: Double, saturation: Double, lightness: Double) -> SIMD3<Double> {
        let angle = hue * .pi / 180
        let chroma = min(max(saturation, 0), 100) / 100 * maxChroma(lightness: lightness, hue: hue)
        let linear = linearSRGB(l: lightness, a: chroma * cos(angle), b: chroma * sin(angle))
        return SIMD3(encode(linear.x), encode(linear.y), encode(linear.z))
    }

    static func colour(hue: Double, saturation: Double, lightness: Double) -> Color {
        let c = rgb(hue: hue, saturation: saturation, lightness: lightness)
        return Color(.sRGB, red: c.x, green: c.y, blue: c.z, opacity: 1)
    }

    /// The rim, from hue 0 round to 360: a hue track.
    static func ring(lightness: Double, steps: Int = 24) -> [Color] {
        (0...steps).map { colour(hue: 360 * Double($0) / Double(steps), saturation: 100, lightness: lightness) }
    }

    private struct Key: Hashable { let diameter: Int; let travel: Int; let lightness: Double }
    @MainActor private static var cache: [Key: CGImage] = [:]

    /// The disc as an image `diameter` pixels across, whose saturation reaches
    /// 100 at `travel` pixels from the middle (the puck's reach; past it, out
    /// to the edge, the rim's colour holds). Made once per size and lightness.
    @MainActor static func image(diameter: Int, travel: Int, lightness: Double) -> CGImage? {
        let key = Key(diameter: max(diameter, 2), travel: max(travel, 1), lightness: lightness)
        if let cached = cache[key] { return cached }
        let side = key.diameter
        let centre = Double(side) / 2
        // Chroma by whole degree, so a pixel only looks its hue up.
        let chromas = (0..<360).map { maxChroma(lightness: lightness, hue: Double($0)) }
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        for y in 0..<side {
            for x in 0..<side {
                let dx = Double(x) + 0.5 - centre, dy = Double(y) + 0.5 - centre
                let distance = (dx * dx + dy * dy).squareRoot()
                let coverage = min(max(centre - distance + 0.5, 0), 1)
                guard coverage > 0 else { continue }
                var hue = atan2(dy, dx) * 180 / .pi
                if hue < 0 { hue += 360 }
                let lower = Int(hue) % 360, upper = (lower + 1) % 360, t = hue - floor(hue)
                let limit = chromas[lower] * (1 - t) + chromas[upper] * t
                let chroma = min(distance / Double(key.travel), 1) * limit
                let angle = hue * .pi / 180
                let linear = linearSRGB(l: lightness, a: chroma * cos(angle), b: chroma * sin(angle))
                let i = (y * side + x) * 4
                bytes[i] = UInt8((encode(linear.x) * coverage * 255).rounded())
                bytes[i + 1] = UInt8((encode(linear.y) * coverage * 255).rounded())
                bytes[i + 2] = UInt8((encode(linear.z) * coverage * 255).rounded())
                bytes[i + 3] = UInt8((coverage * 255).rounded())
            }
        }
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: side, height: side, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: side * 4,
                                  space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        if cache.count > 24 { cache.removeAll() }
        cache[key] = image
        return image
    }
}

/// The disc at the size it is laid out, `travel` points from the middle to
/// where saturation reaches 100.
struct GradingDiscImage: View {
    let travel: CGFloat
    @Environment(\.colorScheme) private var scheme
    @Environment(\.displayScale) private var displayScale

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            if let image = GradingDisc.image(diameter: Int((side * displayScale).rounded()),
                                             travel: Int((travel * displayScale).rounded()),
                                             lightness: GradingDisc.lightness(scheme)) {
                Image(decorative: image, scale: displayScale)
                    .resizable()
                    .frame(width: side, height: side)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .accessibilityHidden(true)
    }
}
