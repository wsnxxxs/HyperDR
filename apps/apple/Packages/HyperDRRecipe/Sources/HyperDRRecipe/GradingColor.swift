import Foundation

/// Colour-wheel swatches for the grading shader's OKLCH hue convention.
/// No platform colour types or renderer dependency enter the recipe package.
public enum GradingColor {
    /// Nonlinear sRGB components in 0...1, for `Color(.sRGB, ...)`.
    /// Hue is the recipe's OKLCH ab angle in degrees; saturation is the recipe's
    /// 0...100 value. This is a global grading wheel applied to 18% neutral grey,
    /// with the shader's chroma strength and physical luminance preservation.
    public static func displayRGB(hue: Double, saturation: Double) -> SIMD3<Double> {
        let grey = 0.18
        let amount = min(100,max(0,saturation))/100
        if amount == 0 { return SIMD3(repeating: encode(grey)) }
        let l = cbrt(grey*(0.4813272912+0.4620679117+0.0564956029))
        let m = cbrt(grey*(0.2288381013+0.6532343999+0.1179544132))
        let s = cbrt(grey*(0.0839860178+0.2242727893+0.6922208389))
        let light = 0.2104542553*l+0.7936177850*m-0.0040720468*s
        let angle = hue * .pi/180, chroma = 0.18*amount*light
        let a = 1.9779984951*l-2.4285922050*m+0.4505937099*s+chroma*cos(angle)
        let b = 0.0259040371*l+0.7827717662*m-0.8086757660*s+chroma*sin(angle)
        let ll = pow(light+0.3963377774*a+0.2158037573*b,3)
        let mm = pow(light-0.1055613458*a-0.0638541728*b,3)
        let ss = pow(light-0.0894841775*a-1.2914855480*b,3)
        var p3 = SIMD3(3.1281105290*ll-2.2570750184*mm+0.1293047884*ss,
                       -1.0911281609*ll+2.4132667618*mm-0.3221681709*ss,
                       -0.0260136497*ll-0.5080276490*mm+1.5333166822*ss)
        p3 *= grey/(0.2289746*p3.x+0.6917385*p3.y+0.0792869*p3.z)
        var linear = SIMD3(1.22494018*p3.x-0.22494018*p3.y,
                           -0.04205695*p3.x+1.04205695*p3.y,
                           -0.01963755*p3.x-0.07863605*p3.y+1.09827360*p3.z)
        // Match the display transform's constant-luminance fit to the sRGB cube.
        var fit = 1.0
        for c in 0..<3 {
            let delta = linear[c]-grey
            if delta > 0 { fit = min(fit,(1-grey)/delta) }
            if delta < 0 { fit = min(fit,-grey/delta) }
        }
        linear = SIMD3(repeating:grey)+fit*(linear-SIMD3(repeating:grey))
        return SIMD3(encode(linear.x),encode(linear.y),encode(linear.z))
    }

    private static func encode(_ value: Double) -> Double {
        let x = min(1,max(0,value))
        return x <= 0.0031308 ? 12.92*x : 1.055*pow(x,1/2.4)-0.055
    }
}
