import HyperDRDesign
import SwiftUI

/// The loupe that follows the pointer or finger while the white balance
/// eyedropper is active: the photo's pixels around the point, magnified with
/// no smoothing, a ring and a reticle on the middle pixel (the one that is
/// picked). Placed beside the point so a finger does not cover it.
struct WhiteBalanceLoupe: View {
    let picker: WhiteBalancePicker
    /// The canvas the loupe floats over, to keep it inside.
    let canvas: CGSize
    /// How far the loupe's centre sits from the point: up and to the right
    /// for a pointer, higher for a finger.
    var offset = CGSize(width: 78, height: -78)
    var diameter: CGFloat = 120

    var body: some View {
        if picker.isActive, let point = picker.hover {
            let centre = placed(point)
            ZStack {
                if let image = picker.loupe {
                    Image(decorative: image, scale: 1)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFill()
                } else {
                    Color.hdr.previewBackdrop
                }
                reticle
            }
            .frame(width: diameter, height: diameter)
            .clipShape(.circle)
            .overlay { Circle().strokeBorder(Color.hdr.overlayInk, lineWidth: 2) }
            .overlay { Circle().strokeBorder(Color.black.opacity(0.35), lineWidth: 1).padding(-1.5) }
            .shadow(color: .black.opacity(0.35), radius: 8, y: 2)
            .position(centre)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    /// The middle pixel's frame, as big as one magnified pixel.
    private var reticle: some View {
        let cell = diameter / CGFloat(WhiteBalancePicker.patch)
        return Rectangle()
            .strokeBorder(Color.white, lineWidth: 1.5)
            .overlay { Rectangle().strokeBorder(Color.black.opacity(0.6), lineWidth: 0.5).padding(-1) }
            .frame(width: cell, height: cell)
    }

    /// The loupe's centre: at `offset` from the point, flipped to the other
    /// side where that would leave the canvas.
    private func placed(_ point: CGPoint) -> CGPoint {
        let r = diameter / 2 + 4
        var x = point.x + offset.width, y = point.y + offset.height
        if x + r > canvas.width { x = point.x - offset.width }
        if y - r < 0 { y = point.y - offset.height }
        return CGPoint(x: min(max(x, r), max(canvas.width - r, r)), y: min(max(y, r), max(canvas.height - r, r)))
    }
}
