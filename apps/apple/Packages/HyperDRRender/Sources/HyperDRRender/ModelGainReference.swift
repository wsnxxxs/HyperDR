import Foundation

extension DoubleReference {
    /// Double reference for the guided model postprocess. Prediction and guide
    /// arrays are on the fixed analysis grid; signed negative predictions do not
    /// create highlight gain. Auto start leaves model participation untouched.
    public static func modelGain(_ predicted: [Double], guide: [Double], size: PixelSize,
                                 expansionStart: Double? = nil) -> [Double] {
        precondition(predicted.count == guide.count && guide.count == size.width*size.height)
        let radius = min(8,max(4,min(size.width,size.height)/96))
        let weights = guide.indices.map { i -> SIMD4<Double> in
            let y = guide[i]
            var g = max(0,predicted[i])
            if let start = expansionStart { g *= smoothStep(0.75*start,max(0.001,min(1,1.1*start)),y) }
            return SIMD4(y,g,y*y,y*g)
        }
        func box(_ input: [SIMD4<Double>]) -> [SIMD4<Double>] {
            var intermediate = input, output = input
            for y in 0..<size.height { for x in 0..<size.width {
                let lo = max(0,x-radius), hi = min(size.width-1,x+radius)
                var sum = SIMD4<Double>.zero
                for k in lo...hi { sum += input[y*size.width+k] }
                intermediate[y*size.width+x] = sum/Double(hi-lo+1)
            } }
            for y in 0..<size.height { for x in 0..<size.width {
                let lo = max(0,y-radius), hi = min(size.height-1,y+radius)
                var sum = SIMD4<Double>.zero
                for k in lo...hi { sum += intermediate[k*size.width+x] }
                output[y*size.width+x] = sum/Double(hi-lo+1)
            } }
            return output
        }
        let coefficients = box(weights).map { m -> SIMD4<Double> in
            let a = (m.w-m.x*m.y)/(max(0,m.z-m.x*m.x)+0.005)
            return SIMD4(a,m.y-a*m.x,0,0)
        }
        let filtered = box(coefficients)
        return guide.indices.map { min(weights[$0].y,max(0,filtered[$0].x*guide[$0]+filtered[$0].y)) }
    }
}
