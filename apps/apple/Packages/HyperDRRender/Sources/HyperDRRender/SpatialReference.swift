import Foundation

public struct ReferenceSpatialAnalysis: Sendable {
    public let size: PixelSize
    public let cells: [SIMD4<Double>]
    public let masks: [SIMD4<Double>]
    public let expansion: [Double]
    public let peaks: SIMD4<Double>
    public let sourceHeadroom: Double
}

extension DoubleReference {
    /// Independent double integration/filtering on the same fixed analysis grid.
    /// This does not call Metal or render-side float helpers.
    public static func spatialAnalysis(_ pixels: [RGB], size: PixelSize,
                                        settings: RenderAdjustments, sdr: Bool) -> ReferenceSpatialAnalysis {
        precondition(pixels.count == size.width*size.height)
        let scale = min(1,768/Double(max(size.width,size.height)))
        let w = max(1,Int((Double(size.width)*scale).rounded()))
        let h = max(1,Int((Double(size.height)*scale).rounded()))
        var cells = [SIMD4<Double>](repeating:.zero,count:w*h)
        var peaks = SIMD4<Double>.zero
        var originalPeak = 1.0
        let start = Double(settings.hdr.expansionStart ?? 0.25)
        for row in 0..<h { for column in 0..<w {
            let x0 = column*size.width/w, x1 = (column+1)*size.width/w
            let y0 = row*size.height/h, y1 = (row+1)*size.height/h
            var sum = SIMD4<Double>.zero
            for y in y0..<y1 { for x in x0..<x1 {
                let original = pixels[y*size.width+x]
                originalPeak = max(originalPeak,original.x,original.y,original.z)
                let pair = prepare(original,settings:settings,sdr:sdr)
                let brightness = luma(pair.base), logValue = min(8,max(-8,log2(brightness+1e-6)))
                sum += SIMD4(brightness,smoothStep(start,1,brightness),logValue,logValue*logValue)
                let basePeak = max(pair.base.x,pair.base.y,pair.base.z)
                peaks.x = max(peaks.x,basePeak*exp2(pair.gain)); peaks.y = max(peaks.y,basePeak)
                peaks.z = max(peaks.z,pair.gain)
            }}
            cells[row*w+column] = sum/Double((x1-x0)*(y1-y0))
        }}
        func box(_ input: [SIMD4<Double>], radius: Int) -> [SIMD4<Double>] {
            var horizontal = input, result = input
            for y in 0..<h { for x in 0..<w {
                let low = max(0,x-radius), high = min(w-1,x+radius)
                var sum = SIMD4<Double>.zero
                for k in low...high { sum += input[y*w+k] }
                horizontal[y*w+x] = sum/Double(high-low+1)
            }}
            for y in 0..<h { for x in 0..<w {
                let low = max(0,y-radius), high = min(h-1,y+radius)
                var sum = SIMD4<Double>.zero
                for k in low...high { sum += horizontal[k*w+x] }
                result[y*w+x] = sum/Double(high-low+1)
            }}
            return result
        }
        let environment = box(cells,radius:min(32,max(4,min(w,h)*3/100)))
        var weights = cells
        for i in cells.indices {
            let c = cells[i], e = environment[i]
            let specular = smoothStep(1,2.5,c.z-e.z)
            let absolute = smoothStep(0.7,1.5,c.x*exp2(3*c.y))
            let noise = 0.35*(1-smoothStep(0.03,0.2,c.x))*smoothStep(0.005,0.07,max(0,e.w-e.z*e.z))
            let coverage = Double(settings.hdr.coverage)
            let gain = 3*c.y*(coverage+(1-coverage)*specular*absolute)*(1-noise)
            weights[i] = SIMD4(c.x,gain,c.x*c.x,c.x*gain)
        }
        let radius = min(8,max(4,min(w,h)/96))
        let mean = box(weights,radius:radius)
        let coefficients = mean.map { m -> SIMD4<Double> in
            let a = (m.w-m.x*m.y)/(max(0,m.z-m.x*m.x)+0.005)
            return SIMD4(a,m.y-a*m.x,0,0)
        }
        let filtered = box(coefficients,radius:radius)
        let expansion = cells.indices.map { i in min(weights[i].y,max(0,filtered[i].x*cells[i].x+filtered[i].y)) }
        peaks.w = expansion.max() ?? 0
        let masks = cells.map { c in SIMD4(smoothStep(0.4,1,c.x),1-smoothStep(0,0.5,c.x),1-smoothStep(0,0.1,c.x),c.y) }
        return ReferenceSpatialAnalysis(size:PixelSize(width:w,height:h),cells:cells,masks:masks,expansion:expansion,peaks:peaks,
                                        sourceHeadroom:log2(originalPeak))
    }

    public static func sampleGrid(_ values: [Double], grid: PixelSize, output: PixelSize, x: Int, y: Int) -> Double {
        let u = min(Double(grid.width-1),max(0,(Double(x)+0.5)*Double(grid.width)/Double(output.width)-0.5))
        let v = min(Double(grid.height-1),max(0,(Double(y)+0.5)*Double(grid.height)/Double(output.height)-0.5))
        let x0 = Int(floor(u)), y0 = Int(floor(v)), x1 = min(x0+1,grid.width-1), y1 = min(y0+1,grid.height-1)
        let tx = u-Double(x0), ty = v-Double(y0)
        let lower = values[y0*grid.width+x0]+tx*(values[y0*grid.width+x1]-values[y0*grid.width+x0])
        let upper = values[y1*grid.width+x0]+tx*(values[y1*grid.width+x1]-values[y1*grid.width+x0])
        return lower+ty*(upper-lower)
    }
}
