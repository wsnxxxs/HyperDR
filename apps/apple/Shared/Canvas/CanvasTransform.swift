import CoreGraphics
import Foundation

/// Canvas geometry is measured relative to fit. Limits and button stops
/// account for the original photo's pixels and the display backing scale.
nonisolated struct CanvasTransform: Equatable, Sendable {
    static let minZoom = 1.0

    /// The fit-relative zoom at one source pixel per backing pixel.
    var actualPixelsZoom: Double {
        let fitted = fittedSize
        guard fitted.width > 0, backingScale > 0 else { return 1 }
        return imageSize.width / (fitted.width * backingScale)
    }

    var maxZoom: Double { max(4, 4 * actualPixelsZoom) }

    /// Actual-pixel stops with fit and the upper limit inserted. Small
    /// percentages continue by halves for very large source photos.
    var zoomStops: [Double] {
        var percentages: [Double] = [0.25, 1 / 3, 0.5, 2 / 3, 1, 2, 3, 4]
        var small = 0.125
        while small * actualPixelsZoom > Self.minZoom {
            percentages.append(small)
            small /= 2
        }
        let candidates = ([Self.minZoom, maxZoom] + percentages.map { $0 * actualPixelsZoom })
            .filter { $0 >= Self.minZoom && $0 <= maxZoom }.sorted()
        return candidates.reduce(into: []) { result, value in
            if let last = result.last, abs(last - value) < 1e-9 { return }
            result.append(value)
        }
    }

    var imageSize: CGSize
    var viewport: CGSize
    /// 1 = fit the window; actual-pixel zoom depends on the geometry.
    var zoom: Double = 1
    /// Offset from the centred position, in view points.
    var pan: CGPoint = .zero
    /// Backing-store scale, used to keep the drawn rect on whole device pixels.
    var backingScale: CGFloat = 1

    /// The fitted rect, before zoom and pan. The Web stage fits inside the
    /// viewer with no gutter, exactly as the app's canvas does.
    var fittedSize: CGSize {
        guard imageSize.width > 0, imageSize.height > 0,
              viewport.width > 0, viewport.height > 0 else { return .zero }
        let scale = min(viewport.width / imageSize.width, viewport.height / imageSize.height)
        return CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
    }

    var displayedSize: CGSize {
        let fitted = fittedSize
        return CGSize(width: fitted.width * zoom, height: fitted.height * zoom)
    }

    /// Largest pan for the current zoom: `width * (zoom - 1) / 2` in
    /// `geometry.js`, where `width` is the *fitted* size, not the zoomed one.
    var panLimit: CGSize {
        let fitted = fittedSize
        return CGSize(width: fitted.width * (zoom - 1) / 2,
                      height: fitted.height * (zoom - 1) / 2)
    }

    /// The photo rect in view coordinates, top-left origin. This is pure
    /// geometry: device-pixel snapping happens in the display pass so overlays
    /// keep the exact fitted rect.
    var imageFrame: CGRect {
        let size = displayedSize
        guard size.width > 0, size.height > 0 else { return .zero }
        let clamped = clampedPan(pan)
        return CGRect(x: (viewport.width - size.width) / 2 + clamped.x,
                      y: (viewport.height - size.height) / 2 + clamped.y,
                      width: size.width, height: size.height)
    }

    func clampedPan(_ candidate: CGPoint) -> CGPoint {
        let limit = panLimit
        return CGPoint(x: min(limit.width, max(-limit.width, candidate.x)),
                       y: min(limit.height, max(-limit.height, candidate.y)))
    }

    /// Pointer-anchored zoom: the detail under the pointer stays put
    /// (`zoomAtPointer` in `geometry.js`).
    func zoomed(to factor: Double, anchorInView: CGPoint) -> CanvasTransform {
        let next = min(maxZoom, max(Self.minZoom, factor))
        guard next != zoom else { return self }
        let centre = CGPoint(x: viewport.width / 2, y: viewport.height / 2)
        let offset = CGPoint(x: anchorInView.x - centre.x, y: anchorInView.y - centre.y)
        let current = clampedPan(pan)
        let ratio = next / zoom
        var result = self
        result.zoom = next
        result.pan = CGPoint(
            x: offset.x - (offset.x - current.x) * ratio,
            y: offset.y - (offset.y - current.y) * ratio)
        // Clamp against the *new* zoom: the old limit is smaller.
        result.pan = result.clampedPan(result.pan)
        return result
    }

    func panned(by delta: CGSize) -> CanvasTransform {
        var result = self
        result.pan = clampedPan(CGPoint(x: pan.x + delta.width, y: pan.y + delta.height))
        return result
    }

    /// `wheelZoomLevel` from `geometry.js`: a trackpad pinch arrives as a
    /// ctrl-wheel and zooms faster than a plain wheel. `nil` means "no change".
    func wheelZoom(fromZoom zoom: Double, deltaY: CGFloat, ctrl: Bool) -> Double? {
        let pixels = deltaY
        let next = min(maxZoom, max(Self.minZoom, zoom * Foundation.exp(-Double(pixels) * (ctrl ? 0.01 : 0.0015))))
        return abs(next - zoom) < 1e-4 ? nil : next
    }
}
