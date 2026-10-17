import Foundation
import Observation

@MainActor @Observable final class CanvasModel {
    private(set) var zoom: ZoomLevel = .fit
    private(set) var imageFrame: CGRect?

    @ObservationIgnored private var imageSize: PixelSize?
    @ObservationIgnored private var viewport: CGSize = .zero
    @ObservationIgnored private var backingScale: Double = 1

    var zoomPercent: Int { Int((factor * 100).rounded()) }
    var canZoomIn: Bool { imageSize != nil && factor < 4 }
    var canZoomOut: Bool { imageSize != nil && factor > 1 }

    private var factor: Double {
        if case .scale(let value) = zoom { return value }
        return 1
    }

    /// Q9: menu Cmd+/Cmd- and focused +/- use these same actions.
    func zoomIn() {
        guard canZoomIn else { return }
        setZoom((floor(factor / 0.25 + 1e-6) + 1) * 0.25)
    }

    func zoomOut() {
        guard canZoomOut else { return }
        setZoom((ceil(factor / 0.25 - 1e-6) - 1) * 0.25)
    }

    /// Menu Cmd0 or focused F; all keyboard event handling belongs to Views.
    func fitToWindow() {
        zoom = .fit
        updateFrame()
    }

    /// Menu Cmd1; one source pixel per backing pixel, within the viewer's bounds.
    func zoomToActualPixels() {
        guard let size = imageSize, let fitted = fittedSize else { return }
        setZoom(Double(size.width) / (fitted.width * backingScale))
    }

    // Renderer-facing geometry; Views only consume the contract above.
    func setViewport(_ size: CGSize, backingScale: Double) {
        viewport = size
        self.backingScale = max(1, backingScale)
        updateFrame()
    }

    func setImageSize(_ size: PixelSize?, zoom: ZoomLevel = .fit) {
        imageSize = size
        self.zoom = zoom
        updateFrame()
    }

    private var fittedSize: CGSize? {
        guard let size = imageSize, size.width > 0, size.height > 0,
              viewport.width > 0, viewport.height > 0 else { return nil }
        let fit = min(viewport.width / Double(size.width), viewport.height / Double(size.height))
        return CGSize(width: Double(size.width) * fit, height: Double(size.height) * fit)
    }

    private func setZoom(_ value: Double) {
        let clamped = min(4, max(1, value))
        zoom = clamped == 1 ? .fit : .scale(clamped)
        updateFrame()
    }

    private func updateFrame() {
        guard let fitted = fittedSize else { imageFrame = nil; return }
        let size = CGSize(width: fitted.width * factor, height: fitted.height * factor)
        imageFrame = CGRect(x: (viewport.width - size.width) / 2,
                            y: (viewport.height - size.height) / 2,
                            width: size.width, height: size.height)
    }
}
