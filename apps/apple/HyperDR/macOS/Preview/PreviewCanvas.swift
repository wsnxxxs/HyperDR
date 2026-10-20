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
                gainWeight: model.currentEditedFrame.map { DisplayWeight.value(headroom: HeadroomPolicy.configured.target(snapshot), metadata: $0.metadata) }.map(Double.init)))
        }, onError: { [weak model] detail in model?.reportCanvasFailure(detail) })
        view.compositionProvider = { [weak model] in model?.canvasComposition }
        view.frameProvider = { [weak model] in model?.canvasFrame }
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
        _ = model.display.currentHeadroom
        _ = model.canvas.imageFrame
        _ = model.canvas.zoom
        view.compositionProvider = { [weak model] in model?.canvasComposition }
        view.frameProvider = { [weak model] in model?.canvasFrame }
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
