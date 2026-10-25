import Foundation
import HyperDRRecipe


extension DoubleReference {
    /// Y >= SDR white is an identity segment, independent of the curve shape.
    public static func toneCurve(_ rgb: RGB, curve: ToneCurve) -> RGB {
        let y = luma(rgb)
        guard !curve.isIdentity, y > 0, y < 1 else { return rgb }
        let encoded = y <= 0.0031308 ? 12.92*y : 1.055*pow(y, 1/2.4)-0.055
        let mapped = curve.value(at: encoded)
        let target = mapped <= 0.04045 ? mapped/12.92 : pow((mapped+0.055)/1.055, 2.4)
        return rgb*(target/y)
    }
}

extension ToneAdjustments {
    /// Four overlapping smooth, monotone local lifts in encoded lightness.
    public func parametricValue(at input: Double) -> Double {
        var x = input
        let b = [0.0, Double(parametricSplit1), Double(parametricSplit2), Double(parametricSplit3), 1.0]
        let amounts = [parametricShadows, parametricDarks, parametricLights, parametricHighlights]
        for i in 0..<4 where amounts[i] != 0 {
            let lo = b[max(0,i-1)], hi = b[min(4,i+2)]
            guard hi > lo, x > lo, x < hi else { continue }
            let t = (x-lo)/(hi-lo)
            x += 4*Double(amounts[i])*(hi-lo)*t*t*(1-t)*(1-t)
        }
        return x
    }

    /// Eight 1024-entry tables. Slots are stable and shared with Adjustments.metal.
    func curveTables() -> [SIMD4<Float>] {
        var result: [SIMD4<Float>] = []
        let curves = [curve, curveSDR, curveHDR, curveRed, curveGreen, curveBlue, curve, curveHDR]
        for (slot,c) in curves.enumerated() {
            for i in 0..<1024 {
                let x = Double(i)/1023
                let input = slot >= 6 ? 1+4*x : slot == 0 ? parametricValue(at: x) : x
                result.append(SIMD4(Float(c.value(at: input)),0,0,0))
            }
        }
        return result
    }
}

extension DoubleReference {
    public static func curveCoordinate(_ luminance: Double) -> Double {
        luminance > 1 ? 1+log2(luminance)
            : luminance <= 0.0031308 ? 12.92*max(0,luminance) : 1.055*pow(luminance,1/2.4)-0.055
    }
    static func linearCurveCoordinate(_ x: Double) -> Double {
        x > 1 ? exp2(x-1) : x <= 0.04045 ? x/12.92 : pow((x+0.055)/1.055,2.4)
    }
    public static func sceneCurves(_ rgb: RGB, tone: ToneAdjustments) -> RGB {
        guard tone.hasCurves else { return rgb }
        var result = rgb
        let y = luma(rgb)
        if y > 0 && y < 1 {
            let x = curveCoordinate(y)
            let target = linearCurveCoordinate(tone.curve.value(at: tone.parametricValue(at: x)))
            result *= target/y
        }
        for (channel,curve) in [tone.curveRed,tone.curveGreen,tone.curveBlue].enumerated()
        where result[channel] > 0 && result[channel] < 1 && !curve.isIdentity {
            result[channel] = linearCurveCoordinate(curve.value(at: curveCoordinate(result[channel])))
        }
        return result
    }
    /// Endpoint curves run after HDR generation, before the range shoulder.
    public static func endpointCurves(base: RGB, hdr: RGB, tone: ToneAdjustments) -> (base: RGB, hdr: RGB) {
        let b = toneCurve(base, curve: tone.curveSDR)
        var h = hdr
        func map(_ curve: ToneCurve, sdr: Bool) {
            let y = luma(h)
            guard y > 0, !curve.isIdentity else { return }
            let x = curveCoordinate(y)
            if x <= 1 && !sdr { return }
            let mapped = curve.value(at: x)
            if x <= 1 && mapped <= x { return }
            let target = linearCurveCoordinate(x <= 1 ? max(x,mapped) : max(1,mapped))
            h *= target/y
        }
        map(tone.curve,sdr:false)
        map(tone.curveHDR,sdr:true)
        return (b,h)
    }
}
