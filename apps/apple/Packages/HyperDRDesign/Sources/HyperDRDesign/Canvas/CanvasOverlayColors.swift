import SwiftUI

/// `CanvasOverlayStyle`'s fixed colours as SwiftUI colours, for the chips,
/// legends and swatches that sit on the photograph and so do not follow the
/// window's appearance.
extension CanvasOverlayStyle {
    static func color(srgb rgb: UInt32) -> Color {
        Color(.sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
              blue: Double(rgb & 255) / 255)
    }

    static var highlightColor: Color { color(srgb: highlightSRGB) }
    static var shadowColor: Color { color(srgb: shadowSRGB) }
    static var maskColor: Color { color(srgb: maskSRGB) }
}
