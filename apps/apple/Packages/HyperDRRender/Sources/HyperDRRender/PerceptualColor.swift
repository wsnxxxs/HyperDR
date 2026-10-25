import Foundation

extension DoubleReference {
    public static func oklab(_ rgb: RGB) -> RGB {
        let l = cbrt(0.4813272912*rgb.x+0.4620679117*rgb.y+0.0564956029*rgb.z)
        let m = cbrt(0.2288381013*rgb.x+0.6532343999*rgb.y+0.1179544132*rgb.z)
        let s = cbrt(0.0839860178*rgb.x+0.2242727893*rgb.y+0.6922208389*rgb.z)
        return RGB(0.2104542553*l+0.7936177850*m-0.0040720468*s,
                   1.9779984951*l-2.4285922050*m+0.4505937099*s,
                   0.0259040371*l+0.7827717662*m-0.8086757660*s)
    }
    public static func oklabRGB(_ lab: RGB) -> RGB {
        labRGB(lab.x, lab.y, lab.z)
    }
    /// Restore physical luminance after a perceptual chroma edit. HDR uses the
    /// same chroma geometry as its normalized endpoint, retaining its brightness.
    static func preserveLuminance(_ rgb: RGB, target: Double) -> RGB {
        let y = luma(rgb)
        return y > 1e-8 ? rgb*(target/y) : RGB(repeating: target)
    }
    public static func vibrance(_ rgb: RGB, amount: Double) -> RGB {
        guard amount != 0 else { return rgb }
        let y = luma(rgb), scale = max(1, y)
        var lab = oklab(rgb/scale)
        let chroma = hypot(lab.y, lab.z), relative = chroma/max(0.001,lab.x)
        var hue = atan2(lab.z,lab.y)*180/Double.pi
        if hue < 0 { hue += 360 }
        let skin = smoothStep(20,30,hue)*(1-smoothStep(75,90,hue))*(1-smoothStep(0.3,0.5,relative))
        let weight = amount > 0 ? (1-smoothStep(0.08,0.45,relative))*(1-2*skin/3)
                                : 0.25+0.75*smoothStep(0.08,0.45,relative)
        let factor = 1+amount*weight*(amount > 0 ? 1.2 : 0.65)
        lab.y *= factor; lab.z *= factor
        return preserveLuminance(oklabRGB(lab),target:y)
    }
    /// Cyclic adjacent-band membership; chroma fades it to zero on neutrals.
    public static func hslWeights(_ rgb: RGB) -> [Double] {
        let lab = oklab(rgb/max(1,luma(rgb)))
        let fade = smoothStep(0.015,0.06,hypot(lab.y,lab.z)/max(0.001,lab.x))
        var hue = atan2(lab.z,lab.y)*180/Double.pi
        if hue < 25 { hue += 360 }
        let centers = [25.0,55,95,145,195,265,305,335,385]
        var weights = [Double](repeating:0,count:8)
        for i in 0..<8 where hue >= centers[i] && hue < centers[i+1] {
            let t = smoothStep(centers[i],centers[i+1],hue)
            weights[i] = (1-t)*fade; weights[(i+1)%8] = t*fade
        }
        return weights
    }
    public static func hslMixer(_ rgb: RGB, bands: [SIMD3<Float>]) -> RGB {
        guard bands.contains(where: { $0 != .zero }) else { return rgb }
        let weights = hslWeights(rgb)
        var delta = RGB.zero
        for i in 0..<8 { delta += RGB(Double(bands[i].x),Double(bands[i].y),Double(bands[i].z))*weights[i] }
        if delta == .zero { return rgb }
        let y = luma(rgb)
        var lab = oklab(rgb/max(1,y))
        let hue = atan2(lab.z,lab.y)+delta.x*Double.pi/6
        let chroma = hypot(lab.y,lab.z)*max(0,1+delta.y)
        lab.y = chroma*cos(hue); lab.z = chroma*sin(hue)
        return preserveLuminance(oklabRGB(lab),target:y*exp2(delta.z))
    }

}
