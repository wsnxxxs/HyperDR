import AppKit
import HyperDRDesign
import SwiftUI

/// The pane laid over the canvas while a drag eyedropper is active (the curve
/// section's): the eyedropper pointer, the press and the drag for the picker,
/// and Esc to leave. Like the white balance pane it takes the pointer from
/// the canvas underneath.
struct TargetPickSurface: NSViewRepresentable {
    let picker: TargetPicker

    func makeNSView(context: Context) -> TargetPickSurfaceView {
        let view = TargetPickSurfaceView()
        view.picker = picker
        return view
    }

    func updateNSView(_ view: TargetPickSurfaceView, context: Context) {
        view.picker = picker
    }
}

@MainActor
final class TargetPickSurfaceView: NSView {
    var picker: TargetPicker?

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.makeFirstResponder(self)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: WhiteBalanceSurfaceView.eyedropper)
    }

    override func mouseDown(with event: NSEvent) {
        picker?.press(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        picker?.move(to: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        picker?.release()
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { picker?.cancel() } else { super.keyDown(with: event) }
    }

    override func cancelOperation(_ sender: Any?) {
        picker?.cancel()
    }
}

/// The drag eyedroppers' layer over the canvas: the pane that takes the
/// pointer and a line saying what to do. It also ends the mode whenever the
/// photo, the crop pane or the editor's lock changes under it.
struct TargetPickCanvasLayer: View {
    let model: EditorModel

    var body: some View {
        let picker = model.curvePick.picker
        ZStack {
            if picker.isActive {
                TargetPickSurface(picker: picker)
                Text("mac.curve.pickHint")
                    .font(Font.hdr.control)
                    .hdrOverlayChip()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .padding(.top, Space.s3)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
        }
        .hdrAnimation(value: picker.isActive)
        .onChange(of: model.photoSerial) { model.resetTargetPickers() }
        .onChange(of: model.isCropping) { if model.isCropping { model.resetTargetPickers() } }
        .onChange(of: model.isEditingLocked) { if model.isEditingLocked { model.resetTargetPickers() } }
    }
}
