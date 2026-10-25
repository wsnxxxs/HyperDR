import SwiftUI

/// What the clipping display's colours mean (controls-polish §6): a chip at
/// the photo's bottom leading corner while the canvas marks clipped
/// highlights (red) and crushed black (blue), in the overlay's own colours.
public struct ClippingLegend: View {
    public init() {}

    public var body: some View {
        HStack(spacing: Space.s3) {
            key(CanvasOverlayStyle.highlightSRGB, Text("design.clipping.highlights", bundle: .module))
            key(CanvasOverlayStyle.shadowSRGB, Text("design.clipping.shadows", bundle: .module))
        }
        .hdrOverlayChip()
        .accessibilityElement(children: .combine)
    }

    private func key(_ rgb: UInt32, _ label: Text) -> some View {
        HStack(spacing: Space.s1) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Color(.sRGB, red: Double((rgb >> 16) & 255) / 255, green: Double((rgb >> 8) & 255) / 255,
                            blue: Double(rgb & 255) / 255))
                .frame(width: 9, height: 9)
            label
        }
    }
}
