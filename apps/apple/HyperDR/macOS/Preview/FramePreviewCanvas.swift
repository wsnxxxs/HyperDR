import SwiftUI

/// The editor's current frame on a second EDR canvas, fitted and fixed, for
/// the frame sheet. `FramedPhoto` sizes it to the print's rect, so the photo
/// fills it; the mat around it is SwiftUI and therefore SDR.
///
/// `showsSDR` swaps the photograph for its SDR version (the sheet's "hold for
/// SDR"); the main canvas's "preview as SDR" is not read here, so the sheet
/// always opens in HDR.
struct FramePreviewCanvas: NSViewRepresentable {
    let model: EditorModel
    var showsSDR = false
    /// What the canvas reports of the pointer, for the sheet's press-and-hold.
    var pointer = CanvasPointerHandlers()

    /// What the canvas draws: the edited frame, in SDR only while comparing.
    static func composition(of model: EditorModel, showsSDR: Bool) -> CanvasComposition? {
        model.editedPair.map { CanvasComposition(edited: $0, headroom: model.display.currentHeadroom, previewsAsSDR: showsSDR) }
    }

    func makeNSView(context: Context) -> EDRCanvasView {
        let view = EDRCanvasView(onError: { [weak model] detail in model?.reportCanvasFailure(detail) })
        view.allowsZoom = false
        install(on: view)
        view.setNeedsRedraw()
        return view
    }

    private func install(on view: EDRCanvasView) {
        let showsSDR = showsSDR
        view.compositionProvider = { [weak model] in model.flatMap { Self.composition(of: $0, showsSDR: showsSDR) } }
        view.onPointerDown = pointer.down
        view.onPointerDrag = pointer.drag
        view.onPointerUp = pointer.up
    }

    func updateNSView(_ view: EDRCanvasView, context: Context) {
        // Observe the frames so a new edit repaints the sheet too.
        _ = model.frameRevision
        install(on: view)
        view.showsOriginal = false
        if let size = model.document?.pixelSize {
            view.transform.imageSize = CGSize(width: size.width, height: size.height)
        }
        view.setNeedsRedraw()
    }
}
