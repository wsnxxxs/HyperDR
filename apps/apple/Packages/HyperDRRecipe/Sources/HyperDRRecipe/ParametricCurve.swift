import Foundation

/// The same smooth parametric curve used to bake Render's curve table.
/// Both axes are sRGB lightness. Amounts and splits use Recipe/UI units.
public enum ParametricCurve {
    /// Amounts: -100...100. Splits: three increasing percentages (default 25/50/75).
    /// Black and white are fixed; values above white pass through unchanged.
    public static func value(at input: Double, highlights: Double = 0, lights: Double = 0,
                             darks: Double = 0, shadows: Double = 0,
                             splits: [Double] = [25, 50, 75]) -> Double {
        guard input > 0, input < 1, splits.count == 3 else { return input }
        var x = input
        let boundaries = [0.0] + splits.map { $0/100 } + [1.0]
        let amounts = [shadows, darks, lights, highlights]
        for zone in 0..<4 where amounts[zone] != 0 {
            let lo = boundaries[max(0,zone-1)], hi = boundaries[min(4,zone+2)]
            guard hi > lo, x > lo, x < hi else { continue }
            let t = (x-lo)/(hi-lo)
            x += 4*(amounts[zone]/100)*(hi-lo)*t*t*(1-t)*(1-t)
        }
        return x
    }
}
