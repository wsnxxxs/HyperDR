import SwiftUI

/// What the view layer hears of the pointer on the canvas, in the canvas's own
/// points: it times press-and-hold for the original and dismisses hints. The
/// canvas still handles pan and zoom itself.
struct CanvasPointerHandlers {
    var down: (CGPoint) -> Void = { _ in }
    var drag: (CGPoint) -> Void = { _ in }
    var up: () -> Void = {}
    /// The wheel or a pinch.
    var zoomGesture: () -> Void = {}
}

/// Draws only the photo rect; background, corners, shadow and badges stay in the
/// view layer and align to `canvas.imageFrame` (§3.5). Zoom and pan gestures run
/// here and are mirrored into `CanvasModel`; keyboard handling does not.
struct PreviewCanvas: NSViewRepresentable {
    let model: EditorModel
    var pointer = CanvasPointerHandlers()

    init(model: EditorModel, pointer: CanvasPointerHandlers = CanvasPointerHandlers()) {
        self.model = model
        self.pointer = pointer
    }

    func makeNSView(context: Context) -> EDRCanvasView {
        #if DEBUG
        A3StressRunner.arm(model: model)
        #endif
        let view = EDRCanvasView(onHeadroom: { [weak model] snapshot in
            guard let model else { return }
            model.receiveDisplay(DisplayState(screenName: snapshot.screen ?? "",
                currentHeadroom: Double(snapshot.current),
                potentialHeadroom: Double(snapshot.potential),
                gainWeight: model.editedPair.map { Double($0.weight(headroom: HeadroomPolicy.configured.target(snapshot))) }))
        }, onError: { [weak model] detail in model?.reportCanvasFailure(detail) })
        view.compositionProvider = { [weak model] in model?.canvasComposition }
        view.onTransformChange = { [weak model] transform in model?.canvas.apply(transform) }
        view.onViewportChange = { [weak model] size, scale in
            model?.updateViewport(size, backingScale: scale)
        }
        view.onRefreshRateChange = { [weak model] rate in model?.updateRefreshRate(rate) }
        install(pointer, on: view)
        view.setNeedsRedraw()
        return view
    }

    private func install(_ pointer: CanvasPointerHandlers, on view: EDRCanvasView) {
        view.onPointerDown = pointer.down
        view.onPointerDrag = pointer.drag
        view.onPointerUp = pointer.up
        view.onZoomGesture = pointer.zoomGesture
    }

    func updateNSView(_ view: EDRCanvasView, context: Context) {
        // Observe the frame, the mode and the geometry so a new frame, a view
        // mode switch or a menu zoom actually repaints.
        _ = model.frameRevision
        _ = model.viewMode
        _ = model.splitRatio
        _ = model.isPeekingOriginal
        _ = model.previewsAsSDR
        _ = model.showsHighlightZebra
        _ = model.showsShadowZebra
        _ = model.clippingMasks
        _ = model.display.currentHeadroom
        _ = model.canvas.imageFrame
        _ = model.canvas.zoom
        _ = model.isCropping
        _ = model.cropFreeze
        _ = model.editor.recipe.geometry
        // The crop pane has the pointer; the photo stays fitted.
        view.allowsZoom = !model.isCropping
        view.compositionProvider = { [weak model] in model?.canvasComposition }
        install(pointer, on: view)
        view.showsOriginal = model.viewMode == .original || !model.hasEditedFrame
        // Until the view has reported its size, the model still has a zero
        // viewport; pushing that back would collapse the canvas.
        if model.canvas.transform.viewport != .zero {
            view.transform = model.canvas.transform
        }
        view.setNeedsRedraw()
    }
}
