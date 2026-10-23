import Foundation

/// What an automatic upright corrects (the crop pane's Auto). Every mode
/// replaces the straightening and perspective it solves for and keeps the
/// turns, mirror and ratio.
public enum UprightMode: String, CaseIterable, Hashable, Sendable {
    /// Balanced: levels the photo and corrects the perspective the lines show
    /// clearly, without over-correcting.
    case auto
    /// Straightening only.
    case level
    /// Straightening and the vertical perspective (converging verticals).
    case vertical
    /// Straightening and both perspectives.
    case full
}

/// An unoriented segment in the untransformed, oriented photo, in pixels
/// about its centre, with y down. Width is in the same pixels.
public struct UprightLine: Hashable, Sendable {
    public var start: GeometryPoint
    public var end: GeometryPoint
    public var width: Double
    public var confidence: Double

    public init(start: GeometryPoint, end: GeometryPoint, width: Double = 1, confidence: Double = 1) {
        self.start = start
        self.end = end
        self.width = width
        self.confidence = confidence
    }

    public var length: Double { hypot(end.x - start.x, end.y - start.y) }
}

/// Independent implementation of line-family upright fitting: the approach
/// of ShiftN/darktable (consensus line families and robust parameter fitting),
/// constrained to Geometry's actual homography. No image or platform APIs.
/// Algorithm references, without incorporating their implementations:
/// https://github.com/darktable-org/darktable/blob/master/src/iop/ashift.c
/// https://research.adobe.com/publication/automatic-upright-adjustment-of-photographs/
public enum UprightSolver {
    private struct Line {
        var a: GeometryPoint
        var b: GeometryPoint
        var weight: Double
        var vertical: Bool
    }

    /// An absolute solution, independent of the current correction. Nil means
    /// insufficient evidence for the requested mode. Explicit modes require
    /// evidence for every perspective they solve; Auto drops unsupported axes.
    public static func solve(lines: [UprightLine], photo: GeometrySize,
                             geometry: Geometry, mode: UprightMode) -> Geometry? {
        let long = max(photo.width, photo.height)
        guard photo.width.isFinite, photo.height.isFinite, min(photo.width, photo.height) > 0 else { return nil }
        // Work in long-edge units, so thresholds and conditioning do not depend
        // on the detector's resolution. Mirror before classifying, like Geometry.
        let candidates = lines.compactMap { line -> Line? in
            let values = [line.start.x, line.start.y, line.end.x, line.end.y, line.confidence]
            guard values.allSatisfy(\.isFinite), line.length.isFinite, line.length >= long * 0.025, line.confidence > 0 else { return nil }
            let mirror = geometry.flipped ? -1.0 : 1.0
            return Line(a: GeometryPoint(x: mirror * line.start.x / long, y: line.start.y / long),
                        b: GeometryPoint(x: mirror * line.end.x / long, y: line.end.y / long),
                        weight: min(line.length / long, 0.5) * min(line.confidence, 1), vertical: false)
        }.sorted { $0.weight > $1.weight }.prefix(400)
        guard candidates.count >= 2 else { return nil }
        let input = Array(candidates)
        // Deterministic roll consensus, modulo 90 degrees. Starting from zero,
        // rather than the previous Geometry, makes repeated clicks idempotent.
        func phase(_ line: Line) -> Double {
            let direction = atan2(line.b.y - line.a.y, line.b.x - line.a.x) * 180 / .pi
            return wrapped(direction, period: 90)
        }
        var roll = stride(from: -44.0, through: 44, by: 2).min { a, b in
            input.reduce(0) { $0 + $1.weight * min(pow(wrapped(phase($1) - a, period: 90) / 5, 2), 1) }
                < input.reduce(0) { $0 + $1.weight * min(pow(wrapped(phase($1) - b, period: 90) / 5, 2), 1) }
        } ?? 0
        for _ in 0..<3 {
            let aligned = input.filter { abs(wrapped(phase($0) - roll, period: 90)) < 15 }
            let weight = aligned.reduce(0) { $0 + $1.weight }
            if weight > 0 { roll += aligned.reduce(0) { $0 + $1.weight * wrapped(phase($1) - roll, period: 90) } / weight }
        }
        var selected: [Line] = []
        // Reclassify after fitting once: perspective can move marginal lines
        // into the correct family. The consensus remains fixed during a fit.
        var estimate = [roll, 0.0, 0.0]
        let normalized = GeometrySize(width: photo.width / long, height: photo.height / long)
        let worldVerticalIsY = geometry.quarterTurns % 2 == 0
        for iteration in 0..<2 {
            guard !Task.isCancelled else { return nil }
            let map = Geometry(angle: estimate[0], vertical: estimate[1], horizontal: estimate[2]).transform(for: normalized)
            var families = [[Line](), [Line]()]
            for var line in input {
                let a = map.apply(line.a), b = map.apply(line.b)
                let angle = abs(wrapped(atan2(b.y - a.y, b.x - a.x) * 180 / .pi, period: 180))
                let vertical = angle > 45
                guard min(angle, abs(90 - angle)) <= 25 else { continue }
                line.vertical = vertical
                families[vertical ? 1 : 0].append(line)
            }
            families = families.map { consensus($0, roll: roll) }
            let hasY = evidence(families[1], strong: mode == .auto)
            let hasX = evidence(families[0], strong: mode == .auto)
            let solvesY: Bool
            let solvesX: Bool
            switch mode {
            case .level:
                // Estimate roll from a vanishing family, rather than averaging
                // its slopes: an off-centre facade has asymmetric convergence.
                // Prefer the displayed verticals; horizontal facade edges may
                // run towards a different, oblique vanishing point. The fitted
                // perspective is only a nuisance parameter, discarded below.
                solvesY = worldVerticalIsY ? hasY : (!hasX && hasY)
                solvesX = worldVerticalIsY ? (!hasY && hasX) : hasX
            case .vertical:
                guard worldVerticalIsY ? hasY : hasX else { return nil }
                solvesY = worldVerticalIsY; solvesX = !worldVerticalIsY
            case .full:
                guard hasY, hasX else { return nil }
                solvesY = true; solvesX = true
            case .auto: solvesY = hasY; solvesX = hasX
            }
            selected = families.flatMap { $0 }
            if mode == .vertical { selected = selected.filter { $0.vertical == worldVerticalIsY } }
            if mode == .level, solvesY || solvesX { selected = selected.filter { $0.vertical == solvesY } }
            if mode == .auto, solvesY != solvesX { selected = selected.filter { $0.vertical == solvesY } }
            guard selected.count >= 2, selected.reduce(0, { $0 + $1.weight }) >= 0.15 else { return nil }
            estimate = fit(selected, photo: normalized, roll: roll, solvesY: solvesY, solvesX: solvesX,
                           regularize: mode == .auto, coarse: iteration == 0)
            if solvesY || solvesX {
                // A vanishing family may belong to an oblique facade rather
                // than a correctable horizon. No mode should force it to the
                // slider stop, or accept a fit that leaves its lines slanted.
                let map = Geometry(angle: estimate[0], vertical: estimate[1], horizontal: estimate[2]).transform(for: normalized)
                func reliable(_ family: [Line], parameter: Double) -> Bool {
                    guard abs(parameter) < 95 else { return false }
                    let aligned = family.filter { line in
                        let a = map.apply(line.a), b = map.apply(line.b)
                        let residual = (line.vertical ? b.x - a.x : b.y - a.y) / max(hypot(b.x - a.x, b.y - a.y), 1e-9)
                        return abs(residual) < 0.035 // two degrees
                    }
                    return evidence(aligned, strong: mode == .auto)
                        && aligned.reduce(0, { $0 + $1.weight }) >= family.reduce(0, { $0 + $1.weight }) * 0.7
                }
                let y = solvesY && reliable(families[1], parameter: estimate[1])
                let x = solvesX && reliable(families[0], parameter: estimate[2])
                if y != solvesY || x != solvesX {
                    // Explicit modes promise every requested axis. Reject an
                    // unsupported fit rather than silently applying a stop.
                    guard mode == .auto else { return nil }
                    // Keep the reliable family's roll; unsupported scene lines
                    // cannot pull it towards the discarded vanishing point.
                    selected = (y ? families[1] : []) + (x ? families[0] : [])
                    if selected.isEmpty { selected = families[worldVerticalIsY ? 1 : 0] }
                    if selected.count < 2 { selected = families.flatMap { $0 } }
                    estimate = fit(selected, photo: normalized, roll: roll, solvesY: y, solvesX: x,
                                   regularize: true, coarse: true)
                }
            }
        }
        var result = geometry
        result.angle = estimate[0]
        result.vertical = mode == .level ? 0 : estimate[1]
        result.horizontal = mode == .level ? 0 : estimate[2]
        if let crop = geometry.crop {
            let frame = geometry.frameSize(of: photo)
            let rect = crop.rect(in: frame)
            guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return nil }
            let largest = Geometry.largest(ratio: rect.width / rect.height, centre: GeometryPoint(x: 0, y: 0),
                                            in: result.quad(for: photo), frame: frame)
            // Reconstructing a ratio through frame pixels can round by one
            // ulp. Keep an already-centred maximal crop exactly, so a second
            // click cannot manufacture another undo step from that rounding.
            let same = crop.centreX == 0 && crop.centreY == 0
                && abs(crop.width - largest.width) < 1e-12 && abs(crop.height - largest.height) < 1e-12
            result.crop = same ? crop : largest
        }
        return result
    }

    private static func wrapped(_ angle: Double, period: Double) -> Double {
        angle - period * floor((angle + period / 2) / period)
    }

    /// A family of image lines intersects at one vanishing point. In a rolled
    /// coordinate system, slope = a * intercept + b, including infinity (a=0).
    /// Pair hypotheses are a deterministic RANSAC, weighted by segment length.
    private static func consensus(_ lines: [Line], roll: Double) -> [Line] {
        guard lines.count >= 3 else { return lines }
        let rotation = Homography.rotation(degrees: roll)
        let measurements = lines.map { line -> (Double, Double) in
            let a = rotation.apply(line.a), b = rotation.apply(line.b)
            let dx = line.vertical ? b.x - a.x : b.y - a.y
            let dy = line.vertical ? b.y - a.y : b.x - a.x
            let slope = dx / (abs(dy) < 1e-8 ? 1e-8 : dy)
            return ((line.vertical ? a.x : a.y) - slope * (line.vertical ? a.y : a.x), slope)
        }
        var best = [Int](), bestWeight = -1.0
        let limit = min(lines.count, 32)
        for i in 0..<limit {
            for j in i..<limit {
                let (xi, yi) = measurements[i], (xj, yj) = measurements[j]
                if i != j, abs(xj - xi) < 0.06 { continue }
                let a = i == j ? 0 : (yj - yi) / (xj - xi), b = yi - a * xi
                let inliers = measurements.indices.filter { k in
                    abs(atan(measurements[k].1) - atan(a * measurements[k].0 + b)) < 2.5 * .pi / 180
                }
                let weight = inliers.reduce(0) { $0 + lines[$1].weight }
                if weight > bestWeight { bestWeight = weight; best = inliers }
            }
        }
        return best.map { lines[$0] }
    }

    private static func evidence(_ lines: [Line], strong: Bool) -> Bool {
        guard lines.count >= (strong ? 3 : 2), lines.reduce(0, { $0 + $1.weight }) >= (strong ? 0.35 : 0.2) else { return false }
        let locations = lines.map { $0.vertical ? ($0.a.x + $0.b.x) / 2 : ($0.a.y + $0.b.y) / 2 }
        return (locations.max()! - locations.min()!) >= (strong ? 0.18 : 0.08)
    }

    private static func fit(_ lines: [Line], photo: GeometrySize, roll: Double,
                            solvesY: Bool, solvesX: Bool, regularize: Bool, coarse: Bool) -> [Double] {
        let dimensions = [0] + (solvesY ? [1] : []) + (solvesX ? [2] : [])
        let total = lines.reduce(0) { $0 + $1.weight }
        func bounded(_ p: [Double]) -> [Double] {
            [Geometry.clamped(p[0], Geometry.angleRange), solvesY ? Geometry.clamped(p[1], Geometry.perspectiveRange) : 0,
             solvesX ? Geometry.clamped(p[2], Geometry.perspectiveRange) : 0]
        }
        func cost(_ p: [Double]) -> Double {
            let q = bounded(p)
            let map = Geometry(angle: q[0], vertical: q[1], horizontal: q[2]).transform(for: photo)
            var sum = 0.0
            for line in lines {
                let a = map.apply(line.a), b = map.apply(line.b)
                let dx = b.x - a.x, dy = b.y - a.y
                let residual = (line.vertical ? dx : dy) / max(hypot(dx, dy), 1e-9)
                // Cauchy loss; a few surviving off-axis edges cannot pull a fit.
                sum += line.weight * 0.0004 * log1p(residual * residual / 0.0004)
            }
            let penalty = zip(p, q).reduce(0) { $0 + pow(($1.0 - $1.1) / 100, 2) }
            return sum / total + penalty + (regularize ? 0.00002 * (pow(q[1] / 100, 2) + pow(q[2] / 100, 2)) : 0)
        }
        struct Vertex {
            var point: [Double]
            var score: Double
        }
        func vertex(_ point: [Double]) -> Vertex { Vertex(point: point, score: cost(point)) }
        var seeds = [Vertex]()
        let gridY = solvesY ? [-100.0, -50, 0, 50, 100] : [0]
        let gridX = solvesX ? [-100.0, -50, 0, 50, 100] : [0]
        for v in gridY { for h in gridX { seeds.append(vertex([roll, v, h])) } }
        seeds.sort { $0.score < $1.score }
        var best = seeds[0]
        // Nelder-Mead in the 1–3 active parameters, with several grid starts.
        for seed in seeds.prefix(coarse ? 4 : 2) {
            var simplex = [seed] + dimensions.map { dimension in
                var p = seed.point; p[dimension] += dimension == 0 ? 3 : 12; return vertex(p)
            }
            for _ in 0..<180 {
                if Task.isCancelled { return bounded(best.point) }
                simplex.sort { $0.score < $1.score }
                let n = dimensions.count
                if zip(simplex[0].point, simplex[n].point).allSatisfy({ abs($0 - $1) < 0.00001 }) { break }
                var centre = [Double](repeating: 0, count: 3)
                for p in simplex.prefix(n) { for d in 0..<3 { centre[d] += p.point[d] / Double(n) } }
                func point(_ factor: Double) -> Vertex { vertex((0..<3).map { centre[$0] + factor * (centre[$0] - simplex[n].point[$0]) }) }
                let reflected = point(1)
                if reflected.score < simplex[0].score {
                    let expanded = point(2)
                    simplex[n] = expanded.score < reflected.score ? expanded : reflected
                } else if reflected.score < simplex[n - 1].score {
                    simplex[n] = reflected
                } else {
                    let contracted = point(reflected.score < simplex[n].score ? 0.5 : -0.5)
                    if contracted.score < min(reflected.score, simplex[n].score) { simplex[n] = contracted }
                    else { for i in 1...n { simplex[i] = vertex((0..<3).map { (simplex[0].point[$0] + simplex[i].point[$0]) / 2 }) } }
                }
            }
            if let candidate = simplex.min(by: { $0.score < $1.score }), candidate.score < best.score { best = candidate }
        }
        return bounded(best.point)
    }
}
