import HyperDRDesign
import SwiftUI

/// A drag eyedropper over the canvas for a finger or the Pencil (the curve
/// section's): pressing samples the pixel under the finger and dragging up or
/// down edits what it points at, until the finger lifts. It lies over the
/// canvas, so while it is up the photo does not pan or zoom.
struct TargetPickTouchLayer: View {
    let picker: TargetPicker
    /// The photo's rectangle on the canvas, for the point under the finger.
    let imageFrame: CGRect

    var body: some View {
        ZStack {
            Color.clear
                .contentShape(.rect)
                .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { value in
                        if !picker.isPressing { picker.press(at: value.startLocation) }
                        picker.move(to: value.location)
                    }
                    .onEnded { _ in picker.release() })
            Text("ipad.curve.pickHint")
                .font(.footnote.weight(.medium))
                .padding(.horizontal, Space.s4)
                .padding(.vertical, Space.s2)
                .glassEffect(.regular, in: .capsule)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, Space.s2)
                .allowsHitTesting(false)
        }
        .onAppear { wire() }
        .onChange(of: imageFrame) { wire() }
    }

    private func wire() {
        let frame = imageFrame
        picker.photoPoint = { WhiteBalanceFrames.photoPoint($0, in: frame, drawsThroughCrop: false) }
    }
}
