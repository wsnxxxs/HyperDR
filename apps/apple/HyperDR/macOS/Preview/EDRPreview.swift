import AppKit
import SwiftUI

/// The diagnostic window's EDR prototype: the same canvas and renderer as the
/// photo view, fed with a synthetic 0–8× ramp instead of an engine frame.
struct EDRPreview: NSViewRepresentable {
    var original: Bool
    var onHeadroom: (HeadroomSnapshot) -> Void
    var onError: (String) -> Void

    func makeNSView(context: Context) -> EDRCanvasView {
        let view = EDRCanvasView(onHeadroom: onHeadroom, onError: onError)
        view.showsSyntheticRamp = true
        view.showsOriginal = original
        return view
    }

    func updateNSView(_ view: EDRCanvasView, context: Context) {
        view.showsSyntheticRamp = true
        view.showsOriginal = original
        view.setNeedsRedraw()
    }
}
