import HyperDREngine
import SwiftUI

/// One frame the canvas can draw plus the mode it is drawn in.
struct PreviewCanvasFrame {
    let frame: PreviewFrame
    let showsOriginal: Bool
}

/// The app hands frames to the canvas through this. A0's placeholder model has
/// no pixels yet, so the default is "nothing to draw"; A2 conforms `EditorModel`
/// by storing the latest engine frame.
@MainActor protocol PreviewFrameSource: AnyObject {
    var canvasFrame: PreviewCanvasFrame? { get }
}

extension PreviewFrameSource {
    var canvasFrame: PreviewCanvasFrame? { nil }
}

extension EditorModel: PreviewFrameSource {}

/// Draws only the photo rect; background, corners, shadow and badges stay in the
/// view layer and align to `canvas.imageFrame` (§3.5). Zoom and pan gestures run
/// here and are mirrored into `CanvasModel`; keyboard handling does not.
struct PreviewCanvas: NSViewRepresentable {
    let model: EditorModel

    init(model: EditorModel) { self.model = model }

    func makeNSView(context: Context) -> EDRCanvasView {
        let view = EDRCanvasView(onHeadroom: { [weak model] snapshot in
            guard let model else { return }
            model.receiveDisplay(DisplayState(screenName: snapshot.screen,
                currentHeadroom: Double(snapshot.current),
                potentialHeadroom: Double(snapshot.potential),
                gainWeight: model.display.gainWeight))
        }, onError: { [weak model] detail in model?.reportCanvasFailure(detail) })
        view.frameProvider = { [weak model] in model?.canvasFrame }
        view.onTransformChange = { [weak model] transform in model?.canvas.apply(transform) }
        view.onViewportChange = { [weak model] size, scale in
            model?.updateViewport(size, backingScale: scale)
        }
        view.onRefreshRateChange = { [weak model] rate in model?.updateRefreshRate(rate) }
        view.setNeedsRedraw()
        return view
    }

    func updateNSView(_ view: EDRCanvasView, context: Context) {
        // Observe the frame, the mode and the geometry so a new frame, a view
        // mode switch or a menu zoom actually repaints.
        _ = model.frameRevision
        _ = model.viewMode
        _ = model.canvas.imageFrame
        _ = model.canvas.zoom
        view.frameProvider = { [weak model] in model?.canvasFrame }
        view.showsOriginal = model.viewMode == .original || !model.hasEditedFrame
        // Until the view has reported its size, the model still has a zero
        // viewport; pushing that back would collapse the canvas.
        if model.canvas.transform.viewport != .zero {
            view.transform = model.canvas.transform
        }
        view.setNeedsRedraw()
    }
}
