import SwiftUI

/// Shadows (CSS `--shadow-*`). Each is the web's layers, with colours per
/// appearance from the asset catalog. SwiftUI shadows have no spread, so the
/// CSS spread (−1…−12 px) is dropped and the blur halved into a radius, which
/// is how SwiftUI and CSS blur compare. Inset highlights are not drawn.
public enum Elevation: CaseIterable, Sendable {
    /// Resting controls.
    case sm
    /// Cards, the photograph frame.
    case md
    /// Dialogs, floating panels, toasts.
    case lg
    /// Raised glass surfaces.
    case glass
    /// Large floating glass surfaces.
    case glassLarge
    /// Accent glow for a drop target.
    case glow
    /// Amber glow for HDR badges.
    case hdr

    struct Layer { let color: Color; let radius: CGFloat; let y: CGFloat }

    var layers: [Layer] {
        let p = Color.hdr
        switch self {
        case .sm: return [.init(color: p.shadowSm1, radius: 1.5, y: 1), .init(color: p.shadowSm2, radius: 1, y: 1)]
        case .md: return [.init(color: p.shadowMd1, radius: 12, y: 8), .init(color: p.shadowMd2, radius: 3, y: 2)]
        case .lg: return [.init(color: p.shadowLg1, radius: 20, y: 16), .init(color: p.shadowLg2, radius: 8, y: 4)]
        case .glass: return [.init(color: p.shadowGlass1, radius: 18, y: 12)]
        case .glassLarge: return [.init(color: p.shadowGlassLg1, radius: 30, y: 24), .init(color: p.shadowGlassLg2, radius: 12, y: 8)]
        case .glow: return [.init(color: p.shadowGlow1, radius: 12, y: 0)]
        case .hdr: return [.init(color: p.shadowHdr1, radius: 12, y: 0)]
        }
    }
}

private struct ElevationModifier: ViewModifier {
    let elevation: Elevation

    func body(content: Content) -> some View {
        // Every shadow has one or two layers; a missing second layer is clear.
        let layers = elevation.layers
        let key = layers[0], ambient = layers.count > 1 ? layers[1] : .init(color: .clear, radius: 0, y: 0)
        content
            .shadow(color: key.color, radius: key.radius, y: key.y)
            .shadow(color: ambient.color, radius: ambient.radius, y: ambient.y)
    }
}

public extension View {
    /// Apply one of HyperDR's shadows: `.elevation(.md)`.
    func elevation(_ elevation: Elevation) -> some View {
        modifier(ElevationModifier(elevation: elevation))
    }
}
