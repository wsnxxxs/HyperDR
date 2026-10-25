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
