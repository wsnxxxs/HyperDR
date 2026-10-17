import CoreGraphics
import Foundation
import Observation

@MainActor @Observable final class CanvasModel {
    private(set) var zoom: ZoomLevel = .fit
    private(set) var imageFrame: CGRect?

    @ObservationIgnored private var geometry = CanvasTransform(
        imageSize: .zero, viewport: .zero)
    @ObservationIgnored private var imageSize: PixelSize?

    var zoomPercent: Int { Int((geometry.zoom * 100).rounded()) }
    var canZoomIn: Bool { imageSize != nil && geometry.zoom < CanvasTransform.maxZoom }
    var canZoomOut: Bool { imageSize != nil && geometry.zoom > CanvasTransform.minZoom }

    /// Renderer-facing geometry. Views only consume the contract in §3.4; the
    /// canvas reads `transform` and pushes gesture results back through
    /// `apply(_:)`.
    var transform: CanvasTransform { geometry }

    func apply(_ transform: CanvasTransform) {
        geometry = transform
        publish()
    }

    /// Q9: menu Cmd+/Cmd- and focused +/- use these same actions.
    func zoomIn() {
        guard canZoomIn else { return }
        setZoom((floor(geometry.zoom / 0.25 + 1e-6) + 1) * 0.25)
    }

    func zoomOut() {
        guard canZoomOut else { return }
        setZoom((ceil(geometry.zoom / 0.25 - 1e-6) - 1) * 0.25)
    }

    /// Menu Cmd0 or focused F; all keyboard event handling belongs to Views.
    func fitToWindow() {
        geometry.zoom = CanvasTransform.minZoom
        geometry.pan = .zero
        publish()
    }

    /// Menu Cmd1; one source pixel per backing pixel, within the viewer's bounds.
    func zoomToActualPixels() {
        guard let size = imageSize, let fitted = fittedSize else { return }
        let scale = max(1, geometry.backingScale)
        setZoom(Double(size.width) / (fitted.width * scale), anchor: nil)
    }

    // Renderer-facing geometry; Views only consume the contract above.
    func setViewport(_ size: CGSize, backingScale: Double) {
        geometry.viewport = size
        geometry.backingScale = max(1, backingScale)
        publish()
    }

    func setImageSize(_ size: PixelSize?, zoom: ZoomLevel = .fit) {
        imageSize = size
        geometry.imageSize = size.map { CGSize(width: $0.width, height: $0.height) } ?? .zero
        geometry.zoom = zoom.factor
        if geometry.zoom <= CanvasTransform.minZoom { geometry.pan = .zero }
        publish()
    }

    private var fittedSize: CGSize? {
        let fitted = geometry.fittedSize
        return fitted.width > 0 && fitted.height > 0 ? fitted : nil
    }

    private func setZoom(_ value: Double, anchor: CGPoint? = nil) {
        let clamped = min(CanvasTransform.maxZoom, max(CanvasTransform.minZoom, value))
        if let anchor {
            geometry = geometry.zoomed(to: clamped, anchorInView: anchor)
        } else {
            geometry.zoom = clamped
            if clamped <= CanvasTransform.minZoom { geometry.pan = .zero }
            geometry.pan = geometry.clampedPan(geometry.pan)
        }
        publish()
    }

    private func publish() {
        zoom = geometry.zoom <= CanvasTransform.minZoom ? .fit : .scale(geometry.zoom)
        imageFrame = fittedSize == nil ? nil : geometry.imageFrame
    }
}

extension ZoomLevel {
    var factor: Double {
        switch self {
        case .fit: return CanvasTransform.minZoom
        case .scale(let value): return value
        }
    }
}
