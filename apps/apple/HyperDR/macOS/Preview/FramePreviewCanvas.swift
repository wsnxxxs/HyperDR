import SwiftUI

/// The editor's current frame on a second EDR canvas, fitted and fixed, for
/// the frame sheet. `FramedPhoto` sizes it to the print's rect, so the photo
/// fills it; the mat around it is SwiftUI and therefore SDR.
struct FramePreviewCanvas: NSViewRepresentable {
    let model: EditorModel

    func makeNSView(context: Context) -> EDRCanvasView {
        let view = EDRCanvasView(onError: { [weak model] detail in model?.reportCanvasFailure(detail) })
        view.allowsZoom = false
        view.frameProvider = { [weak model] in model?.canvasFrame }
        view.setNeedsRedraw()
        return view
    }

    func updateNSView(_ view: EDRCanvasView, context: Context) {
        // Observe the frames so a new edit repaints the sheet too.
        _ = model.hasPreviewFrame
        view.frameProvider = { [weak model] in model?.canvasFrame }
        view.showsOriginal = !model.hasEditedFrame
        view.setNeedsRedraw()
    }
}
