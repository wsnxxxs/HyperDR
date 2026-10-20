import Foundation

extension DoubleReference {
    /// Exact ISO reconstruction in P3; caller applies ICC matrices when needed.
    public static func exportHDR(base: RGB, gain: RGB, baseOffset: RGB = .zero,
                                 alternateOffset: RGB = .zero, alpha: Double = 1) -> RGB {
        (base+baseOffset)*RGB(exp2(gain.x),exp2(gain.y),exp2(gain.z))*alpha-alternateOffset*alpha
    }

    /// H1: derive the base from the unbounded HDR before limiting the multiplier.
    public static func exportSplit(_ hdr: RGB, ceilingStops: Double? = nil, shoulder: Bool = false) -> Split {
        let peak = max(hdr.x,max(hdr.y,hdr.z)), rawGain = log2(max(1,peak))
        let base = fitP3(hdr*exp2(-rawGain))
        var mapped = peak
        if shoulder, let stops = ceilingStops, peak > 1 {
            let limit = exp2(stops), knee = 1+0.75*(limit-1), width = limit-knee
            if peak > knee { mapped = knee+width*(1-exp(-(peak-knee)/width)) }
        }
        return Split(base:base,gain:max(0,rawGain+(peak>0 ? log2(max(mapped,1e-20)/peak) : 0)))
    }

    /// Paper/shadow/straight-alpha caption, independent of all photo HDR pixels.
    public static func framePixel(x: Int, y: Int, frame: FrameSnapshot,
                                  captionRGB: RGB = .zero, captionAlpha: Double = 0) -> RGB {
        func coverage(_ t: Double,_ lo: Double,_ hi: Double) -> Double {
            let sigma = Double(frame.shadow.sigma)
            if sigma == 0 { return t >= lo && t < hi ? 1 : 0 }
            return 0.5*(erf((t-lo)/(sigma*sqrt(2)))-erf((t-hi)/(sigma*sqrt(2))))
        }
        let loX = Double(frame.photo.x)+Double(frame.shadow.offset.x)
        let loY = Double(frame.photo.y)+Double(frame.shadow.offset.y)
        let cover = coverage(Double(x)+0.5,loX,loX+Double(frame.photo.width))
                  * coverage(Double(y)+0.5,loY,loY+Double(frame.photo.height))
        let paper = RGB(Double(frame.paper.x),Double(frame.paper.y),Double(frame.paper.z))
        return paper*(1-Double(frame.shadow.opacity)*cover)*(1-captionAlpha)+captionRGB*captionAlpha
    }
}
