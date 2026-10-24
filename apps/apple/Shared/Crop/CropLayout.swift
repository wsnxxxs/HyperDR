import CoreGraphics
import Foundation
import HyperDRRecipe
import simd

/// Where the crop pane puts the photo on the canvas: the crop fitted inside a
/// margin, centred, and the whole photo around it turned and tilted as the
/// geometry says. One scale (canvas points per frame pixel) and one centre
/// (the frame point at the canvas's middle) place everything, so the Metal
/// canvas (`display`) and the crop box over it (`point`, `rect`) agree.
struct CropLayout: Equatable {
    /// The photo's own size, in pixels.
    let photo: GeometrySize
    let geometry: Geometry
    let viewport: CGSize
    let scale: Double
    let centre: GeometryPoint
    /// The room kept around the crop when it is fitted.
    let margin: CGFloat

    init(photo: GeometrySize, geometry: Geometry, viewport: CGSize, margin: CGFloat) {
        let crop = geometry.rasterCropRect(for: photo)
        let room = CGSize(width: max(1, viewport.width - 2 * margin), height: max(1, viewport.height - 2 * margin))
        self.init(photo: photo, geometry: geometry, viewport: viewport,
                  scale: min(Double(room.width) / max(crop.width, 1), Double(room.height) / max(crop.height, 1)),
                  centre: crop.centre, margin: margin)
    }

    private init(photo: GeometrySize, geometry: Geometry, viewport: CGSize, scale: Double, centre: GeometryPoint,
                 margin: CGFloat) {
        self.photo = photo
        self.geometry = geometry
        self.viewport = viewport
        self.scale = scale
        self.centre = centre
        self.margin = margin
    }

    /// The same placement for another geometry: a drag keeps the photo still.
    func with(_ geometry: Geometry) -> CropLayout {
        CropLayout(photo: photo, geometry: geometry, viewport: viewport, scale: scale, centre: centre, margin: margin)
    }

    /// Where the pane settles for this geometry: its crop fitted and centred again.
    var fitted: CropLayout { CropLayout(photo: photo, geometry: geometry, viewport: viewport, margin: margin) }

    /// Part of the way (`t`, 0...1) from this placement to `other`'s, with
    /// this geometry. The scale moves by equal ratios, so a zoom reads evenly.
    func moving(towards other: CropLayout, _ t: Double) -> CropLayout {
        let t = min(max(t, 0), 1)
        let scale = scale > 0 && other.scale > 0 ? scale * pow(other.scale / scale, t) : other.scale
        let centre = GeometryPoint(x: centre.x + (other.centre.x - centre.x) * t,
                                   y: centre.y + (other.centre.y - centre.y) * t)
        return CropLayout(photo: photo, geometry: geometry, viewport: viewport, scale: scale, centre: centre, margin: margin)
    }

    /// The placement differs from `other`'s by less than a point anywhere on
    /// the crop: nothing left worth animating.
    func settles(at other: CropLayout) -> Bool {
        let a = cropRect, b = other.with(geometry).cropRect
        return abs(a.minX - b.minX) < 0.5 && abs(a.minY - b.minY) < 0.5
            && abs(a.maxX - b.maxX) < 0.5 && abs(a.maxY - b.maxY) < 0.5
    }

    var frame: GeometrySize { geometry.frameSize(of: photo) }

    /// A frame point (pixels about the frame's centre) on the canvas.
    func point(_ p: GeometryPoint) -> CGPoint {
        CGPoint(x: Double(viewport.width) / 2 + (p.x - centre.x) * scale,
                y: Double(viewport.height) / 2 + (p.y - centre.y) * scale)
    }

    /// A frame rectangle on the canvas.
    func rect(_ r: GeometryRect) -> CGRect {
        let a = point(GeometryPoint(x: r.minX, y: r.minY)), b = point(GeometryPoint(x: r.maxX, y: r.maxY))
        return CGRect(x: a.x, y: a.y, width: b.x - a.x, height: b.y - a.y)
    }

    /// The crop in force, on the canvas.
    var cropRect: CGRect { rect(geometry.rasterCropRect(for: photo)) }

    /// The photo's outline on the canvas.
    var photoOutline: [CGPoint] { geometry.quad(for: photo).map(point) }

    /// What the canvas draws: each canvas point looked up in the frame shown,
    /// which was rendered with `rendered` (the whole photo, or until it arrives
    /// on entering the pane, the crop it had). A cropped frame lands on its
    /// crop and the canvas stays clear around it, so the pane opens in place.
    func display(clipsToCrop: Bool, dimsOutsideCrop: Bool, rendered: Geometry = .identity) -> GeometryDisplay {
        let w = Double(viewport.width), h = Double(viewport.height)
        // Canvas fractions to frame pixels, back through the geometry to the
        // photo's pixels about its centre, then forward through the rendered
        // geometry to the fractions of its output.
        let canvasToFrame = Homography(m: [w / scale, 0, centre.x - w / (2 * scale),
                                           0, h / scale, centre.y - h / (2 * scale), 0, 0, 1])
        let output = rendered.rasterCropRect(for: photo)
        let outputToFractions = Homography.scale(x: 1 / output.width, y: 1 / output.height)
        let fromCentre = Homography.translation(x: photo.width / 2, y: photo.height / 2)
        let m = (outputToFractions * rendered.photoToOutput(for: photo) * fromCentre
                 * geometry.transform(for: photo).inverse * canvasToFrame).m.map(Float.init)
        let crop = cropRect
        return GeometryDisplay(
            photoFromCanvas: simd_float3x3(columns: (SIMD3(m[0], m[3], m[6]), SIMD3(m[1], m[4], m[7]), SIMD3(m[2], m[5], m[8]))),
            crop: SIMD4(Float(crop.minX / viewport.width), Float(crop.minY / viewport.height),
                        Float(crop.maxX / viewport.width), Float(crop.maxY / viewport.height)),
            clipsToCrop: clipsToCrop, dimsOutsideCrop: dimsOutsideCrop)
    }
}

/// Dragging the crop box (`CropOverlay`): what a touch takes hold of, and
/// the crop it leaves, always inside the photo with a minimum long edge.
enum CropDrag: Equatable {
    case move
    /// The edges that follow the finger: −1 is the left (top), +1 the right (bottom), 0 neither.
    case resize(x: Int, y: Int)

    /// How far from an edge a finger still takes hold of it: a band of
    /// 2 × 24 pt, wider than the 44 pt touch target. A pointer is precise.
    #if os(macOS)
    static let reach: CGFloat = 10
    #else
    static let reach: CGFloat = 24
    #endif

    /// What a touch at `location` takes hold of on a crop box `box`: a corner
    /// or an edge within reach, else the box when inside it. Inside, the
    /// edges reach at most a quarter of the way in, so a small box still has
    /// a middle to move it by; a corner takes precedence over its edges.
    static func at(_ location: CGPoint, box: CGRect, reach: CGFloat = Self.reach) -> CropDrag? {
        func side(_ value: CGFloat, _ low: CGFloat, _ high: CGFloat) -> Int {
            let inner = min(reach, (high - low) / 4)
            func near(_ edge: CGFloat, inward: CGFloat) -> Bool {
                let offset = (value - edge) * inward
                return offset <= 0 ? -offset <= reach : offset <= inner
            }
            let toLow = abs(value - low), toHigh = abs(value - high)
            if near(low, inward: 1), toLow <= toHigh { return -1 }
            if near(high, inward: -1) { return 1 }
            return 0
        }
        let within = box.insetBy(dx: -reach, dy: -reach).contains(location)
        guard within else { return nil }
        let x = side(location.x, box.minX, box.maxX), y = side(location.y, box.minY, box.maxY)
        if x != 0 || y != 0 { return .resize(x: x, y: y) }
        return box.contains(location) ? .move : nil
    }

    /// The crop after the finger moved `delta` frame pixels from where the
    /// drag started on `start`. A locked `ratio` (width over height) holds;
    /// the result is the farthest point towards the finger that stays inside
    /// `quad` and with a long edge of at least `minimum` pixels (unless the
    /// starting box is already smaller).
    func apply(_ delta: GeometryPoint, to start: GeometryRect, ratio: Double?, quad: [GeometryPoint],
               minimum: Double) -> GeometryRect {
        resolve(delta, to: start, ratio: ratio, quad: quad, minimum: minimum).rect
    }

    /// As `apply`, and whether the photo's edge stopped the drag short of the finger.
    func resolve(_ delta: GeometryPoint, to start: GeometryRect, ratio: Double?, quad: [GeometryPoint],
                 minimum: Double) -> (rect: GeometryRect, stopped: Bool) {
        let target = proposed(delta, start, ratio: ratio, minimum: minimum)
        func valid(_ r: GeometryRect) -> Bool { r.corners.allSatisfy { Geometry.contains(quad, $0) } }
        if valid(target) { return (target, false) }
        // The farthest point along the way that still fits.
        var low = 0.0, high = 1.0
        for _ in 0..<30 {
            let t = (low + high) / 2
            if valid(Self.mix(start, target, t)) { low = t } else { high = t }
        }
        return (Self.mix(start, target, low), true)
    }

    private func proposed(_ d: GeometryPoint, _ s: GeometryRect, ratio: Double?, minimum: Double) -> GeometryRect {
        switch self {
        case .move:
            return GeometryRect(centre: GeometryPoint(x: s.centre.x + d.x, y: s.centre.y + d.y), size: s.size)
        case .resize(let x, let y):
            // `minimum` bounds the long edge. Scale the starting dimensions
            // together, so a panorama's short edge may remain below it. Never
            // enlarge an already smaller starting box merely to meet a floor.
            let minimumScale = min(1, max(0, minimum) / max(s.width, s.height))
            let minimumWidth = s.width * minimumScale
            let minimumHeight = s.height * minimumScale
            var minX = s.minX, maxX = s.maxX, minY = s.minY, maxY = s.maxY
            if x < 0 { minX = min(s.minX + d.x, s.maxX - minimumWidth) }
            if x > 0 { maxX = max(s.maxX + d.x, s.minX + minimumWidth) }
            if y < 0 { minY = min(s.minY + d.y, s.maxY - minimumHeight) }
            if y > 0 { maxY = max(s.maxY + d.y, s.minY + minimumHeight) }
            guard let ratio else {
                return GeometryRect(centre: GeometryPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2),
                                    size: GeometrySize(width: maxX - minX, height: maxY - minY))
            }
            // Locked: the dimension that moved more leads; the other follows,
            // anchored at the opposite side (or centred when its edges stay).
            var width = maxX - minX, height = maxY - minY
            if x != 0 && y != 0 {
                if abs(width / s.width - 1) >= abs(height / s.height - 1) {
                    height = width / ratio
                } else {
                    width = height * ratio
                }
            } else if x != 0 {
                height = width / ratio
            } else {
                width = height * ratio
            }
            height = max(height, minimumHeight, minimumWidth / ratio)
            width = height * ratio
            let cx = x < 0 ? s.maxX - width / 2 : x > 0 ? s.minX + width / 2 : s.centre.x
            let cy = y < 0 ? s.maxY - height / 2 : y > 0 ? s.minY + height / 2 : s.centre.y
            return GeometryRect(centre: GeometryPoint(x: cx, y: cy), size: GeometrySize(width: width, height: height))
        }
    }

    static func mix(_ a: GeometryRect, _ b: GeometryRect, _ t: Double) -> GeometryRect {
        GeometryRect(centre: GeometryPoint(x: a.centre.x + (b.centre.x - a.centre.x) * t, y: a.centre.y + (b.centre.y - a.centre.y) * t),
                     size: GeometrySize(width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t))
    }
}
