import HyperDRDesign
import Metal
import SwiftUI

/// The white balance eyedropper over the canvas for a finger or the Pencil:
/// touching shows the loupe above the finger, moving drags it along the
/// photo and lifting picks the pixel the finger was on (adjust-controls F1).
/// A lift off the photo keeps waiting. It lies over the canvas, so while it
/// is up the photo does not pan or zoom.
struct WhiteBalanceTouchLayer: View {
    let picker: WhiteBalancePicker
    /// The canvas's geometry: where the photo is, for the point under the finger.
    let transform: CanvasTransform?
    /// The frame whose pixels the loupe magnifies.
    let texture: () -> (any MTLTexture)?

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color.clear
                    .contentShape(.rect)
                    .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                        .onChanged { picker.move(to: $0.location) }
                        .onEnded { value in
                            picker.click(at: value.location)
                            picker.move(to: nil)
                        })
                WhiteBalanceLoupe(picker: picker, canvas: proxy.size, offset: CGSize(width: 0, height: -110), diameter: 132)
                Text("ipad.wb.hint")
                    .font(.footnote.weight(.medium))
                    .padding(.horizontal, Space.s4)
                    .padding(.vertical, Space.s2)
                    .glassEffect(.regular, in: .capsule)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, Space.s2)
                    .allowsHitTesting(false)
            }
            .onAppear { wire() }
            .onChange(of: transform) { wire() }
        }
    }

    /// The photo's rectangle as the canvas draws it now.
    private func wire() {
        let frame = transform?.imageFrame ?? .zero
        picker.photoPoint = { point in
            guard frame.width > 0, frame.height > 0, frame.contains(point) else { return nil }
            return CGPoint(x: (point.x - frame.minX) / frame.width, y: (point.y - frame.minY) / frame.height)
        }
        picker.texture = texture
    }
}
