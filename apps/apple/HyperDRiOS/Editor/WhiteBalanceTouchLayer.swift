import HyperDRDesign
import SwiftUI

/// The white balance eyedropper over the canvas for a finger or the Pencil:
/// touching shows the loupe above the finger, moving drags it along the
/// photo and lifting picks the pixel the finger was on (adjust-controls F1).
/// A lift off the photo keeps waiting. It lies over the canvas, so while it
/// is up the photo does not pan or zoom.
struct WhiteBalanceTouchLayer: View {
    let picker: WhiteBalancePicker
    /// What the canvas draws and where: the photo's rectangle for the point
    /// under the finger, and the frame under it (the split's two sides) for
    /// the loupe.
    let frames: WhiteBalanceFrames

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
            .onChange(of: frames) { wire() }
        }
    }

    /// The photo's rectangle and frames as the canvas draws them now.
    private func wire() {
        let frames = frames
        picker.photoPoint = { WhiteBalanceFrames.photoPoint($0, in: frames.imageFrame, drawsThroughCrop: false) }
        picker.texture = { frames.texture(at: $0) }
    }
}
