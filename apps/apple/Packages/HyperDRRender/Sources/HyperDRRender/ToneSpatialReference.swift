import Foundation

public struct ReferenceToneSpatial: Sendable {
    public let size: PixelSize
    public let air: DoubleReference.RGB
    /// Transmission, HDR log low frequency, SDR log low frequency, reserved.
    public let samples: [SIMD4<Double>]
}

extension DoubleReference {
    public static func dehaze(_ rgb: RGB, air: RGB, transmission: Double, amount: Double) -> RGB {
        guard amount != 0 else { return rgb }
        if amount < 0 { return rgb + (air-rgb)*(-amount*0.45) }
        let y = luma(rgb), a = luma(air)
        guard y > 0 else { return rgb }
        // White objects and sky near atmospheric light carry no reliable haze
        // estimate. Relax their transmission instead of subtracting their light.
        let t = max(max(0.2,transmission),min(1,0.3/max(0.001,abs(y-a))))
        let recovered = (y-a)/t+a
        // Recover luminance only: atmospheric colour errors cannot become blue
        // edge fringes. Bound the correction to preserve bright surfaces/details.
        let ratio = min(1.2,max(0.75,recovered/y))
        return rgb*(1+(ratio-1)*amount)
    }
    public static func clarity(_ rgb: RGB, lowFrequency: Double, amount: Double) -> RGB {
        let y = luma(rgb)
        guard amount != 0, y > 0 else { return rgb }
        let weight = smoothStep(0.01,0.1,y)*(1-smoothStep(0.8,2,y))
        let detail = log2(y+1e-4)-lowFrequency
        return rgb*exp2(0.8*amount*weight*detail)
    }

    /// Atmospheric light from the brightest dark-channel percentile, using a
    /// fixed histogram so production and reference choose the same candidate.
    static func toneAtmosphere(_ scene: [RGB], dark: [Double]) -> RGB {
        var histogram = [Int](repeating: 0,count: 256)
        for value in dark { histogram[min(255,Int(value*255))] += 1 }
        var remaining = max(1,scene.count/1000),threshold = 255
        while threshold > 0 && histogram[threshold] < remaining {
            remaining -= histogram[threshold]; threshold -= 1
        }
        var air = RGB(repeating: 1),brightest = -Double.infinity
        for i in scene.indices where Int(dark[i]*255) >= threshold {
            let y = luma(scene[i])
            if y > brightest { brightest = y; air = scene[i] }
        }
        return RGB(min(1,max(0.05,air.x)),min(1,max(0.05,air.y)),min(1,max(0.05,air.z)))
    }

    /// Fixed-scale double reference estimator. Linear dark-channel prior and
    /// self-guided log-luminance low frequencies; no render-region dependencies.
    public static func toneSpatialAnalysis(_ pixels: [RGB], base: [RGB], size: PixelSize,
                                           tone: ToneAdjustments, color: ColorAdjustments,
                                           sdr: Bool) -> ReferenceToneSpatial {
        let w = size.width, h = size.height, count = w*h
        func exposed(_ input: RGB, base: Bool) -> RGB {
            var x = point(input,operation: .warmth,value: Double(color.warmth))
            x = point(x,operation: .tint,value: Double(color.tint))
            return point(x,operation: .exposure,value: Double(tone.exposure),sdr: sdr || base)
        }
        let scene = pixels.map { exposed($0,base: false) }
        func minimum(_ input: [Double], radius: Int) -> [Double] {
            var temp = input, output = input
            for y in 0..<h { for x in 0..<w {
                var m = Double.infinity
                for k in max(0,x-radius)...min(w-1,x+radius) { m = min(m,input[y*w+k]) }
                temp[y*w+x] = m
            }}
            for y in 0..<h { for x in 0..<w {
                var m = Double.infinity
                for k in max(0,y-radius)...min(h-1,y+radius) { m = min(m,temp[k*w+x]) }
                output[y*w+x] = m
            }}
            return output
        }
        func box(_ input: [Double], radius: Int) -> [Double] {
            var temp = input, output = input
            for y in 0..<h {
                var sum = input[(y*w)...(y*w+min(w-1,radius))].reduce(0,+)
                for x in 0..<w {
                    temp[y*w+x] = sum/Double(min(w-1,x+radius)-max(0,x-radius)+1)
                    if x-radius >= 0 { sum -= input[y*w+x-radius] }
                    if x+radius+1 < w { sum += input[y*w+x+radius+1] }
                }
            }
            for x in 0..<w {
                var sum = (0...min(h-1,radius)).reduce(0.0) { $0+temp[$1*w+x] }
                for y in 0..<h {
                    output[y*w+x] = sum/Double(min(h-1,y+radius)-max(0,y-radius)+1)
                    if y-radius >= 0 { sum -= temp[(y-radius)*w+x] }
                    if y+radius+1 < h { sum += temp[(y+radius+1)*w+x] }
                }
            }
            return output
        }
        func guided(_ guide: [Double], _ input: [Double], epsilon: Double, radius: Int) -> [Double] {
            let mg = box(guide,radius: radius), mi = box(input,radius: radius)
            let gg = box(guide.map { $0*$0 },radius: radius)
            let gi = box(zip(guide,input).map(*),radius: radius)
            var a = input, b = input
            for i in 0..<count {
                a[i] = (gi[i]-mg[i]*mi[i])/(max(0,gg[i]-mg[i]*mg[i])+epsilon)
                b[i] = mi[i]-a[i]*mg[i]
            }
            a = box(a,radius: radius); b = box(b,radius: radius)
            return (0..<count).map { a[$0]*guide[$0]+b[$0] }
        }
        var air = RGB(repeating: 1), transmission = [Double](repeating: 1,count: count)
        if tone.dehaze != 0 {
            let dark = minimum(scene.map { max(0,min(1,$0.x,$0.y,$0.z)) },radius: 7)
            air = toneAtmosphere(scene,dark: dark)
            let normalized = minimum(scene.map { max(0,min($0.x/air.x,$0.y/air.y,$0.z/air.z)) },radius: 7)
            let raw = normalized.map { max(0.2,1-0.95*$0) }
            let guide = scene.map { min(1,luma($0)) }
            transmission = guided(guide,raw,epsilon: 0.001,radius: 8).map { min(1,max(0.2,$0)) }
        }
        func low(_ input: [RGB], base: Bool) -> [Double] {
            let logs = input.enumerated().map { i, pixel -> Double in
                var x = base ? exposed(pixel,base: true) : scene[i]
                x = dehaze(x,air: air,transmission: transmission[i],amount: Double(tone.dehaze))
                for (operation,value) in [(AdjustmentOperation.contrast,tone.contrast),(.highlights,tone.highlights),
                    (.shadows,tone.shadows),(.whites,tone.whites),(.blacks,tone.blacks)] {
                    x = point(x,operation: operation,value: Double(value))
                }
                return log2(luma(x)+1e-4)
            }
            return guided(logs,logs,epsilon: 0.04,radius: 8)
        }
        let hdrLow = tone.clarity == 0 ? [Double](repeating: 0,count: count) : low(pixels,base: false)
        let baseLow = tone.clarity == 0 ? hdrLow : low(base,base: true)
        return ReferenceToneSpatial(size: size,air: air,samples: (0..<count).map { SIMD4(transmission[$0],hdrLow[$0],baseLow[$0],0) })
    }
}
