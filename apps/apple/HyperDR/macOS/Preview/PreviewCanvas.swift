import AppKit
import SwiftUI

/// A0 placeholder. A1 replaces the synthetic ramp with engine-owned planes.
/// Q9: Views owns focused keys; EditorCommands owns menu shortcuts. No keyboard
/// handling belongs to this representable or its AppKit view.
/// M1 focused keys are F, + and -; C and Space actions are deferred to M2.
struct PreviewCanvas: NSViewRepresentable {
    let model: EditorModel

    init(model: EditorModel) { self.model = model }

    func makeNSView(context: Context) -> PlaceholderCanvasView {
        PlaceholderCanvasView(model: model)
    }

    func updateNSView(_ view: PlaceholderCanvasView, context: Context) {
        // Observe frame availability and geometry as well as the mode.
        _ = model.hasPreviewFrame
        _ = model.canvas.imageFrame
        _ = model.viewMode
        view.model = model
        view.needsLayout = true
    }
}

@MainActor final class PlaceholderCanvasView: NSView {
    var model: EditorModel
    private var ramp: EDRMetalView?
    private var layoutPending = false
    override var isOpaque: Bool { false }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }

    init(model: EditorModel) {
        self.model = model
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        guard !layoutPending else { return }
        layoutPending = true
        // Publish observable geometry outside AppKit/SwiftUI's layout pass.
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            layoutPending = false
            model.canvas.setViewport(bounds.size, backingScale: Double(window?.backingScaleFactor ?? 1))
            guard model.hasPreviewFrame, let frame = model.canvas.imageFrame else {
                ramp?.removeFromSuperview()
                ramp = nil
                return
            }
            if ramp == nil {
                let view = EDRMetalView(onHeadroom: { [weak self] snapshot in
                    guard let self else { return }
                    model.receiveDisplay(DisplayState(screenName: snapshot.screen,
                        currentHeadroom: Double(snapshot.current),
                        potentialHeadroom: Double(snapshot.potential), gainWeight: model.display.gainWeight))
                }, onError: { [weak self] in self?.model.reportCanvasFailure($0) })
                addSubview(view)
                ramp = view
            }
            ramp?.frame = frame
            ramp?.original = model.viewMode == .original || !model.hasEditedFrame
            ramp?.drawPreview()
        }
    }
}
