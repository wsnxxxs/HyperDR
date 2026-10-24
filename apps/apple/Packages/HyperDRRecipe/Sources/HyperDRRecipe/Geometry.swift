import Foundation

/// The photo's crop, straightening, perspective, turns and mirror (the crop
/// pane). Applied where the source is opened, before every adjustment, so the
/// rest of the pipeline sees the cropped photo as the photo.
///
/// The transform, in pixels about the photo's centre with y down: the
/// mirror, then perspective (a tilt of the image plane by `vertical` and
/// `horizontal`), then the straightening `angle`, then `quarterTurns`. Every
/// control therefore means the same on screen whether or not the photo is
/// mirrored; mirroring (`mirrored()`) mirrors the view as it is. The result
/// lives in the *frame*: the photo's size with its width and height swapped by
/// an odd number of turns. The crop is a rectangle in the frame, and has to lie
/// inside the transformed photo, so no edge ever shows.
///
/// Every quantity is relative (degrees, percent, fractions of the frame), so
/// the same geometry gives the same picture at any resolution, and
/// `outputSize(of:)` is the one size the editor, the engine and the export agree on.
public struct Geometry: Codable, Hashable, Sendable {
    public static let identity = Geometry()
    /// Straightening, in degrees.
    public static let angleRange: ClosedRange<Double> = -45...45
    /// Perspective, in percent of `maximumTilt`.
    public static let perspectiveRange: ClosedRange<Double> = -100...100
    /// The image plane's tilt at 100 % perspective, in degrees.
    public static let maximumTilt = 30.0

    /// Degrees; positive turns the photo anticlockwise.
    public var angle: Double = 0
    /// Percent; positive widens the top (verticals that converge upwards come apart).
    public var vertical: Double = 0
    /// Percent; positive widens the right side.
    public var horizontal: Double = 0
    /// Quarter turns anticlockwise, 0...3.
    public var quarterTurns: Int = 0
    /// Mirrored left to right, before everything else.
    public var flipped = false
    /// The ratio the crop keeps while it is dragged.
    public var aspect: CropAspect = .original
    /// The crop in the frame; nil is the largest rectangle of `aspect` that the
    /// transformed photo fills, centred.
    public var crop: CropRect?

    public init(angle: Double = 0, vertical: Double = 0, horizontal: Double = 0, quarterTurns: Int = 0,
                flipped: Bool = false, aspect: CropAspect = .original, crop: CropRect? = nil) {
        self.angle = angle
        self.vertical = vertical
        self.horizontal = horizontal
        self.quarterTurns = quarterTurns
        self.flipped = flipped
        self.aspect = aspect
        self.crop = crop
    }

    public var isIdentity: Bool { self == .identity }

    /// Whether the photo is resampled at all: crop alone moves whole rectangles.
    public var transformsPixels: Bool { angle != 0 || vertical != 0 || horizontal != 0 }

    // MARK: Frame

    /// The photo's size after the turns.
    public func frameSize(of photo: GeometrySize) -> GeometrySize {
        quarterTurns % 2 == 0 ? photo : GeometrySize(width: photo.height, height: photo.width)
    }

    /// The forward map, photo pixels about its centre (y down) to frame pixels
    /// about the frame's centre.
    public func transform(for photo: GeometrySize) -> Homography {
        let perspective = Homography.tilt(vertical: Self.clamped(vertical, Self.perspectiveRange) / 100 * Self.maximumTilt,
                                          horizontal: Self.clamped(horizontal, Self.perspectiveRange) / 100 * Self.maximumTilt,
                                          focal: max(photo.width, photo.height))
        let turns = ((quarterTurns % 4) + 4) % 4
        let mirror = flipped ? Homography.scale(x: -1, y: 1) : .identity
        return Homography.rotation(degrees: Double(turns) * 90)
            * Homography.rotation(degrees: Self.clamped(angle, Self.angleRange)) * perspective * mirror
    }

    /// The transformed photo, in frame pixels about the frame's centre:
    /// its top-left, top-right, bottom-right and bottom-left corners.
    public func quad(for photo: GeometrySize) -> [GeometryPoint] {
        let map = transform(for: photo)
        let w = photo.width / 2, h = photo.height / 2
        return [GeometryPoint(x: -w, y: -h), GeometryPoint(x: w, y: -h),
                GeometryPoint(x: w, y: h), GeometryPoint(x: -w, y: h)].map { map.apply($0) }
    }

    // MARK: Crop

    /// The crop in force: `crop` where the photo covers it, else that crop
    /// shrunk about its centre until it does; with no crop, the largest
    /// rectangle of `aspect` the photo fills.
    public func resolvedCrop(for photo: GeometrySize) -> CropRect {
        let frame = frameSize(of: photo)
        let quad = quad(for: photo)
        guard let crop else {
            return Self.largest(ratio: aspect.ratio(frame: frame) ?? frame.width / frame.height,
                                centre: GeometryPoint(x: 0, y: 0), in: quad, frame: frame)
        }
        let requested = crop.rect(in: frame)
        guard requested.corners.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              crop.centreX.isFinite, crop.centreY.isFinite,
              crop.width.isFinite, crop.height.isFinite, crop.width > 0, crop.height > 0 else {
            var automatic = self
            automatic.crop = nil
            return automatic.resolvedCrop(for: photo)
        }
        return Self.fitted(crop, in: quad, frame: frame)
    }

    /// The crop in frame pixels about the frame's centre.
    public func cropRect(for photo: GeometrySize) -> GeometryRect {
        resolvedCrop(for: photo).rect(in: frameSize(of: photo))
    }

    /// The exact output window in frame pixels. Continuous crop constraints
    /// stay in `cropRect(for:)`; display and rasterization use this window.
    /// Whole-pixel operations snap the translation on the *native* photo grid,
    /// including odd dimensions, before any preview scaling takes place.
    public func rasterCropRect(for photo: GeometrySize) -> GeometryRect {
        let crop = cropRect(for: photo)
        let output = (width: max(1, Int(crop.width.rounded())), height: max(1, Int(crop.height.rounded())))
        var centre = crop.centre
        if !transformsPixels {
            let origin = transform(for: photo).apply(GeometryPoint(x: -photo.width / 2, y: -photo.height / 2))
            let tx = Double(output.width) / 2 - centre.x + origin.x
            let ty = Double(output.height) / 2 - centre.y + origin.y
            centre.x += tx - tx.rounded()
            centre.y += ty - ty.rounded()
        }
        return GeometryRect(centre: centre, size: GeometrySize(width: Double(output.width), height: Double(output.height)))
    }

    /// Native photo pixels (top-left, y down) to output pixels (top-left,
    /// y down). One rounding rule for display, preview, ROI and export.
    public func photoToOutput(for photo: GeometrySize) -> Homography {
        let crop = rasterCropRect(for: photo)
        return Homography.translation(x: crop.width / 2 - crop.centre.x, y: crop.height / 2 - crop.centre.y)
            * transform(for: photo) * Homography.translation(x: -photo.width / 2, y: -photo.height / 2)
    }

    /// The output in whole pixels: the resolved crop at the photo's own scale.
    public func outputSize(of photo: GeometrySize) -> (width: Int, height: Int) {
        let rect = cropRect(for: photo)
        return (max(1, Int(rect.width.rounded())), max(1, Int(rect.height.rounded())))
    }

    /// `crop` inside the photo: kept where it fits, else shrunk about its
    /// centre (moved to the photo's centre when that is outside the photo).
    static func fitted(_ crop: CropRect, in quad: [GeometryPoint], frame: GeometrySize) -> CropRect {
        let rect = crop.rect(in: frame)
        if rect.corners.allSatisfy({ contains(quad, $0) }) { return crop }
        var centre = contains(quad, rect.centre) ? rect.centre : GeometryPoint(x: 0, y: 0)
        var largest = largest(ratio: rect.width / max(rect.height, 1e-9), centre: centre, in: quad, frame: frame)
        if largest.width <= 0 || largest.height <= 0 {
            // A centre on the boundary has no positive inscribed rectangle.
            // Recentring keeps the stored crop usable on the next resolution.
            centre = GeometryPoint(x: 0, y: 0)
            largest = Self.largest(ratio: rect.width / rect.height, centre: centre, in: quad, frame: frame)
        }
        // Never larger than asked for.
        return largest.width < crop.width ? largest : CropRect(centre: centre, size: GeometrySize(width: rect.width, height: rect.height), frame: frame)
    }

    /// The largest rectangle of `ratio` (width over height, in pixels) centred
    /// on `centre` inside the convex `quad`.
    static func largest(ratio: Double, centre: GeometryPoint, in quad: [GeometryPoint], frame: GeometrySize) -> CropRect {
        let ratio = ratio.isFinite && ratio > 0 ? ratio : 1
        if isFrame(quad, frame) {
            // Nothing resampled: the photo is the frame itself, solved exactly.
            let height = max(0, min(frame.height / 2 - abs(centre.y), (frame.width / 2 - abs(centre.x)) / ratio)) * 2
            return CropRect(centre: centre, size: GeometrySize(width: height * ratio, height: height), frame: frame)
        }
        // Each oriented edge gives a half-plane constraint on the rectangle's
        // half-height t: cross(edge, centre - a) >= t * (abs(dx) + ratio * abs(dy)).
        // Solve the four constraints directly, independent of image resolution.
        var halfHeight = Double.infinity
        for index in quad.indices {
            let a = quad[index], b = quad[(index + 1) % quad.count]
            let dx = b.x - a.x, dy = b.y - a.y
            let distance = abs(dx * (centre.y - a.y) - dy * (centre.x - a.x))
            let support = abs(dx) + ratio * abs(dy)
            if support > 0 { halfHeight = min(halfHeight, distance / support) }
        }
        let height = halfHeight.isFinite ? max(0, halfHeight * 2) : 0
        return CropRect(centre: centre, size: GeometrySize(width: height * ratio, height: height), frame: frame)
    }

    /// The quad is the frame's own rectangle (crop, turns and mirror only).
    static func isFrame(_ quad: [GeometryPoint], _ frame: GeometrySize) -> Bool {
        let corners = GeometryRect(centre: GeometryPoint(x: 0, y: 0), size: frame).corners
        return Set(quad.map { [$0.x, $0.y] }) == Set(corners.map { [$0.x, $0.y] })
    }

    /// Inside the convex quad, edges included (a little tolerance, so a crop
    /// fitted exactly to an edge stays inside).
    public static func contains(_ quad: [GeometryPoint], _ point: GeometryPoint) -> Bool {
        guard quad.count >= 3, point.x.isFinite, point.y.isFinite,
              quad.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        var sign = 0.0
        for index in quad.indices {
            let a = quad[index], b = quad[(index + 1) % quad.count]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            let scale = max(1, hypot(b.x - a.x, b.y - a.y))
            if abs(cross) / scale < 1e-6 { continue }
            if sign == 0 { sign = cross } else if (cross > 0) != (sign > 0) { return false }
        }
        return true
    }

    static func clamped(_ value: Double, _ range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : 0
    }

    // MARK: Edits

    /// The crop at `aspect`: the largest rectangle of that ratio the photo
    /// fills around the crop's centre. Free keeps the crop as it is; the
    /// photo's own ratio with no crop stays the automatic largest one.
    public func settingAspect(_ aspect: CropAspect, photo: GeometrySize) -> Geometry {
        var result = self
        result.aspect = aspect
        let frame = frameSize(of: photo)
        let current = resolvedCrop(for: photo)
        guard let ratio = aspect.ratio(frame: frame) else {
            result.crop = current
            return result
        }
        if aspect == .original, crop == nil { return result }
        result.crop = Self.largest(ratio: ratio, centre: current.rect(in: frame).centre, in: quad(for: photo), frame: frame)
        return result
    }

    /// Stores a box gesture's proposed frame fractions after applying the
    /// aspect lock and transformed-photo bounds. Keeps the requested centre
    /// when it lies in the photo, shrinks rather than enlarges, and recentres
    /// when the centre is outside. Call with the gesture's original box plus
    /// total translation, rather than repeatedly fitting the previous result.
    /// `resolvedCrop(for:)` remains the authoritative visible/exported box.
    public func settingCrop(_ proposed: CropRect, photo: GeometrySize) -> Geometry {
        var result = self
        let frame = frameSize(of: photo)
        var proposed = proposed
        if let ratio = aspect.ratio(frame: frame), proposed.width > 0, proposed.height > 0,
           proposed.width.isFinite, proposed.height.isFinite {
            let height = min(proposed.height * frame.height, proposed.width * frame.width / ratio)
            proposed.width = height * ratio / frame.width
            proposed.height = height / frame.height
        }
        result.crop = proposed
        result.crop = result.resolvedCrop(for: photo)
        return result
    }

    /// A quarter turn anticlockwise: the crop turns with the photo.
    public func turnedLeft() -> Geometry {
        var result = self
        result.quarterTurns = (((quarterTurns % 4) + 4) % 4 + 1) % 4
        result.aspect = aspect.turned
        // Frame fractions: the new x is the old y, the new y minus the old x.
        result.crop = crop.map { CropRect(centreX: $0.centreY, centreY: -$0.centreX, width: $0.height, height: $0.width) }
        return result
    }

    /// The view mirrored left to right. A mirror reverses every turn and the
    /// horizontal tilt (M·R(t)·R(a)·P(v, h) = R(−t)·R(−a)·P(v, −h)·M), so those
    /// change sign; the crop mirrors with the photo.
    public func mirrored() -> Geometry {
        var result = self
        result.flipped.toggle()
        result.angle = -angle
        result.horizontal = -horizontal
        result.quarterTurns = (4 - quarterTurns % 4) % 4
        result.crop = crop.map { CropRect(centreX: -$0.centreX, centreY: $0.centreY, width: $0.width, height: $0.height) }
        return result
    }
}

extension Geometry {
    private enum CodingKeys: String, CodingKey {
        case angle, vertical, horizontal, quarterTurns, flipped, aspect, crop
    }

    /// Missing fields are their defaults; an aspect this build does not know is free.
    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(angle: try container.decodeIfPresent(Double.self, forKey: .angle) ?? 0,
                  vertical: try container.decodeIfPresent(Double.self, forKey: .vertical) ?? 0,
                  horizontal: try container.decodeIfPresent(Double.self, forKey: .horizontal) ?? 0,
                  quarterTurns: ((try container.decodeIfPresent(Int.self, forKey: .quarterTurns) ?? 0) % 4 + 4) % 4,
                  flipped: try container.decodeIfPresent(Bool.self, forKey: .flipped) ?? false,
                  aspect: (try container.decodeIfPresent(String.self, forKey: .aspect)).map { CropAspect(rawValue: $0) ?? .free } ?? .original,
                  crop: try container.decodeIfPresent(CropRect.self, forKey: .crop))
    }

    /// Only what differs from the identity.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        if angle != 0 { try container.encode(angle, forKey: .angle) }
        if vertical != 0 { try container.encode(vertical, forKey: .vertical) }
        if horizontal != 0 { try container.encode(horizontal, forKey: .horizontal) }
        if quarterTurns != 0 { try container.encode(quarterTurns, forKey: .quarterTurns) }
        if flipped { try container.encode(flipped, forKey: .flipped) }
        if aspect != .original { try container.encode(aspect.rawValue, forKey: .aspect) }
        try container.encodeIfPresent(crop, forKey: .crop)
    }
}

/// The crop, as fractions of the frame: its centre from the frame's centre
/// (−0.5...0.5 across the frame) and its size.
public struct CropRect: Codable, Hashable, Sendable {
    public var centreX: Double
    public var centreY: Double
    public var width: Double
    public var height: Double

    public init(centreX: Double, centreY: Double, width: Double, height: Double) {
        self.centreX = centreX
        self.centreY = centreY
        self.width = width
        self.height = height
    }

    public init(centre: GeometryPoint, size: GeometrySize, frame: GeometrySize) {
        self.init(centreX: centre.x / frame.width, centreY: centre.y / frame.height,
                  width: size.width / frame.width, height: size.height / frame.height)
    }

    /// In frame pixels about the frame's centre.
    public func rect(in frame: GeometrySize) -> GeometryRect {
        GeometryRect(centre: GeometryPoint(x: centreX * frame.width, y: centreY * frame.height),
                     size: GeometrySize(width: width * frame.width, height: height * frame.height))
    }
}

/// The crop's ratio while it is dragged. Each fixed ratio has its other
/// orientation (`turned`); square and the two free kinds are their own.
public enum CropAspect: String, Codable, CaseIterable, Hashable, Sendable {
    /// The photo's own ratio, in the frame's orientation.
    case original
    case free
    case square = "1:1"
    case portrait4x5 = "4:5", landscape5x4 = "5:4"
    case portrait3x4 = "3:4", landscape4x3 = "4:3"
    case portrait2x3 = "2:3", landscape3x2 = "3:2"
    case portrait9x16 = "9:16", landscape16x9 = "16:9"

    /// Width over height in pixels; nil when free.
    public func ratio(frame: GeometrySize) -> Double? {
        switch self {
        case .original: return frame.width / frame.height
        case .free: return nil
        case .square: return 1
        default:
            let parts = rawValue.split(separator: ":").compactMap { Double($0) }
            return parts.count == 2 ? parts[0] / parts[1] : nil
        }
    }

    /// The same ratio the other way up.
    public var turned: CropAspect {
        switch self {
        case .original, .free, .square: return self
        case .portrait4x5: return .landscape5x4
        case .landscape5x4: return .portrait4x5
        case .portrait3x4: return .landscape4x3
        case .landscape4x3: return .portrait3x4
        case .portrait2x3: return .landscape3x2
        case .landscape3x2: return .portrait2x3
        case .portrait9x16: return .landscape16x9
        case .landscape16x9: return .portrait9x16
        }
    }

    public var isLandscape: Bool {
        switch self {
        case .landscape5x4, .landscape4x3, .landscape3x2, .landscape16x9: return true
        default: return false
        }
    }

    /// The fixed ratios in menu order, one orientation each.
    public static let presets: [CropAspect] = [.original, .free, .square, .portrait4x5, .portrait3x4, .portrait2x3, .portrait9x16]
}

public struct GeometrySize: Hashable, Sendable {
    public var width: Double
    public var height: Double
    public init(width: Double, height: Double) {
        self.width = width
        self.height = height
    }
}

public struct GeometryPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double
    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

public struct GeometryRect: Hashable, Sendable {
    public var centre: GeometryPoint
    public var size: GeometrySize
    public init(centre: GeometryPoint, size: GeometrySize) {
        self.centre = centre
        self.size = size
    }
    public var width: Double { size.width }
    public var height: Double { size.height }
    public var minX: Double { centre.x - size.width / 2 }
    public var minY: Double { centre.y - size.height / 2 }
    public var maxX: Double { centre.x + size.width / 2 }
    public var maxY: Double { centre.y + size.height / 2 }
    public var corners: [GeometryPoint] {
        [GeometryPoint(x: minX, y: minY), GeometryPoint(x: maxX, y: minY),
         GeometryPoint(x: maxX, y: maxY), GeometryPoint(x: minX, y: maxY)]
    }
}

/// A 3×3 projective map of points, row-major.
public struct Homography: Hashable, Sendable {
    public var m: [Double]

    public init(m: [Double]) {
        precondition(m.count == 9)
        self.m = m
    }

    public static let identity = Homography(m: [1, 0, 0, 0, 1, 0, 0, 0, 1])

    /// Anticlockwise on screen (y down).
    public static func rotation(degrees: Double) -> Homography {
        let r = degrees * .pi / 180, c = cos(r), s = sin(r)
        // Snap whole quarter turns, so 90° moves pixels without resampling.
        let snap = { (v: Double) in abs(v - v.rounded()) < 1e-12 ? v.rounded() : v }
        return Homography(m: [snap(c), snap(s), 0, -snap(s), snap(c), 0, 0, 0, 1])
    }

    public static func translation(x: Double, y: Double) -> Homography {
        Homography(m: [1, 0, x, 0, 1, y, 0, 0, 1])
    }

    public static func scale(x: Double, y: Double) -> Homography {
        Homography(m: [x, 0, 0, 0, y, 0, 0, 0, 1])
    }

    /// The image plane tilted about its horizontal axis by `vertical` degrees
    /// and its vertical axis by `horizontal`, seen through a lens of `focal`
    /// pixels, with the photo's centre kept in place.
    static func tilt(vertical: Double, horizontal: Double, focal: Double) -> Homography {
        guard vertical != 0 || horizontal != 0, focal > 0 else { return .identity }
        // Negated: a positive tilt brings the top (the right) towards the viewer, so it widens.
        let a = -vertical * .pi / 180, b = -horizontal * .pi / 180
        let rx = Homography(m: [1, 0, 0, 0, cos(a), sin(a), 0, -sin(a), cos(a)])
        let ry = Homography(m: [cos(b), 0, -sin(b), 0, 1, 0, sin(b), 0, cos(b)])
        let k = Homography(m: [focal, 0, 0, 0, focal, 0, 0, 0, 1])
        let kInverse = Homography(m: [1 / focal, 0, 0, 0, 1 / focal, 0, 0, 0, 1])
        let projective = k * ry * rx * kInverse
        let centre = projective.apply(GeometryPoint(x: 0, y: 0))
        return Homography.translation(x: -centre.x, y: -centre.y) * projective
    }

    public func apply(_ point: GeometryPoint) -> GeometryPoint {
        let x = m[0] * point.x + m[1] * point.y + m[2]
        let y = m[3] * point.x + m[4] * point.y + m[5]
        let w = m[6] * point.x + m[7] * point.y + m[8]
        return GeometryPoint(x: x / w, y: y / w)
    }

    public static func * (lhs: Homography, rhs: Homography) -> Homography {
        var result = [Double](repeating: 0, count: 9)
        for row in 0..<3 {
            for column in 0..<3 {
                result[row * 3 + column] = (0..<3).reduce(0) { $0 + lhs.m[row * 3 + $1] * rhs.m[$1 * 3 + column] }
            }
        }
        return Homography(m: result)
    }

    public var inverse: Homography {
        let a = m
        let c00 = a[4] * a[8] - a[5] * a[7], c01 = a[5] * a[6] - a[3] * a[8], c02 = a[3] * a[7] - a[4] * a[6]
        let determinant = a[0] * c00 + a[1] * c01 + a[2] * c02
        let d = 1 / determinant
        return Homography(m: [
            c00 * d, (a[2] * a[7] - a[1] * a[8]) * d, (a[1] * a[5] - a[2] * a[4]) * d,
            c01 * d, (a[0] * a[8] - a[2] * a[6]) * d, (a[2] * a[3] - a[0] * a[5]) * d,
            c02 * d, (a[1] * a[6] - a[0] * a[7]) * d, (a[0] * a[4] - a[1] * a[3]) * d])
    }

    /// Whether the map is an affine one (no perspective row).
    public var isAffine: Bool { abs(m[6]) < 1e-12 && abs(m[7]) < 1e-12 }
}
