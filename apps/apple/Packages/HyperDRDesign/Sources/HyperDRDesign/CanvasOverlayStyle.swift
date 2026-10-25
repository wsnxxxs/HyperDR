import Foundation

/// Fixed photograph overlays, independent of window appearance (M2-D §6).
/// Source values are sRGB; Metal consumes linear Display P3 values.
public enum CanvasOverlayStyle {
    public static let maskSRGB: UInt32 = 0xC026D3
    public static let highlightSRGB: UInt32 = 0xEF4444
    public static let shadowSRGB: UInt32 = 0x3B82F6
    public static let maskOpacity: Float = 0.47
    public static let zebraOpacity: Float = 0.92
    /// The clipping display covers the photo solidly, not in stripes; a little
    /// of the photo shows through so the shapes stay readable.
    public static let clippingOpacity: Float = 0.82
    public static let stripePeriodPoints: Float = 8
    public static let stripeWidthPoints: Float = 3
    public static let stripeAngleDegrees: Float = 45
    public static let stripeDirection = SIMD2<Float>(cos(stripeAngleDegrees * .pi / 180), sin(stripeAngleDegrees * .pi / 180))

    public static func linearDisplayP3(_ rgb: UInt32) -> SIMD3<Float> {
        func linear(_ code: UInt32) -> Float {
            let value = Float(code) / 255
            return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        let r = linear((rgb >> 16) & 255), g = linear((rgb >> 8) & 255), b = linear(rgb & 255)
        return SIMD3(0.82259287*r + 0.17753395*g,
                     0.03319951*r + 0.96678350*g,
                     0.01708535*r + 0.07239572*g + 0.91030150*b)
    }

    public static let mask = linearDisplayP3(maskSRGB)
    public static let highlight = linearDisplayP3(highlightSRGB)
    public static let shadow = linearDisplayP3(shadowSRGB)
}
