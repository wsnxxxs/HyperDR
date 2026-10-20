import CoreGraphics
import Foundation
import Observation

enum ZoomReadout: Equatable {
    case fit
    case percent(Int)
}

@MainActor @Observable final class CanvasModel {
    private(set) var zoom: ZoomLevel = .fit
    private(set) var imageFrame: CGRect?

    @ObservationIgnored private var geometry = CanvasTransform(
        imageSize: .zero, viewport: .zero)
    @ObservationIgnored private var imageSize: PixelSize?
    @ObservationIgnored var onGeometryChange: (() -> Void)?

    var visibleSourceRect: CGRect? {
        let image = geometry.imageFrame
        guard image.width > 0, image.height > 0 else { return nil }
        let visible = image.intersection(CGRect(origin: .zero, size: geometry.viewport))
        guard !visible.isNull, !visible.isEmpty else { return nil }
        let sx = geometry.imageSize.width / image.width, sy = geometry.imageSize.height / image.height
        return CGRect(x: (visible.minX-image.minX)*sx, y: (visible.minY-image.minY)*sy,
                      width: visible.width*sx, height: visible.height*sy)
    }

    private(set) var zoomReadout: ZoomReadout = .fit
    private(set) var zoomPercent = 100
    var canZoomIn: Bool { imageFrame != nil && zoom.factor < geometry.maxZoom - 1e-9 }
    var canZoomOut: Bool { imageFrame != nil && zoom.factor > CanvasTransform.minZoom + 1e-9 }

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
        if let next = geometry.zoomStops.first(where: { $0 > geometry.zoom + 1e-9 }) { setZoom(next) }
    }

    func zoomOut() {
        guard canZoomOut else { return }
        if let next = geometry.zoomStops.last(where: { $0 < geometry.zoom - 1e-9 }) { setZoom(next) }
    }

    /// Menu Cmd0 or focused F; all keyboard event handling belongs to Views.
    func fitToWindow() {
        geometry.zoom = CanvasTransform.minZoom
        geometry.pan = .zero
        publish()
    }

    /// Menu Cmd1; one source pixel per backing pixel, within the viewer's bounds.
    func zoomToActualPixels() {
        guard imageSize != nil, fittedSize != nil else { return }
        setZoom(geometry.actualPixelsZoom)
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
        let clamped = min(geometry.maxZoom, max(CanvasTransform.minZoom, value))
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
        geometry.zoom = min(geometry.maxZoom, max(CanvasTransform.minZoom, geometry.zoom))
        geometry.pan = geometry.clampedPan(geometry.pan)
        zoomPercent = Int((geometry.zoom / geometry.actualPixelsZoom * 100).rounded())
        zoomReadout = geometry.zoom <= CanvasTransform.minZoom ? .fit : .percent(zoomPercent)
        zoom = geometry.zoom <= CanvasTransform.minZoom ? .fit : .scale(geometry.zoom)
        imageFrame = fittedSize == nil ? nil : geometry.imageFrame
        onGeometryChange?()
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
