import Foundation
import Testing
@testable import HyperDRRecipe

@Suite struct UprightTests {
    let photo = GeometrySize(width: 4000, height: 3000)

    func grid(_ correction: Geometry, vertical: Bool = true, horizontal: Bool = true, noise: Bool = true) -> [UprightLine] {
        let inverse = correction.transform(for: photo).inverse
        var lines = [UprightLine]()
        func add(_ a: GeometryPoint, _ b: GeometryPoint) {
            var a = inverse.apply(a), b = inverse.apply(b)
            if noise {
                let n = Double(lines.count)
                a.x += sin(n * 7) * 0.6; a.y += cos(n * 3) * 0.6
                b.x += cos(n * 5) * 0.6; b.y += sin(n * 11) * 0.6
            }
            lines.append(UprightLine(start: a, end: b))
        }
        for k in -4...4 {
            if vertical { add(GeometryPoint(x: Double(k) * 260, y: -850), GeometryPoint(x: Double(k) * 260, y: 850)) }
            if horizontal { add(GeometryPoint(x: -1250, y: Double(k) * 190), GeometryPoint(x: 1250, y: Double(k) * 190)) }
        }
        return lines
    }

    @Test func fullRecoversBothTiltsDespiteNoiseAndOutliers() throws {
        let target = Geometry(angle: 7, vertical: 42, horizontal: -31)
        var lines = grid(target)
        for k in 0..<8 {
            lines.append(UprightLine(start: GeometryPoint(x: Double(k) * 110 - 500, y: -700),
                                     end: GeometryPoint(x: Double(k) * 110 - 250, y: 650)))
        }
        let result = try #require(UprightSolver.solve(lines: lines, photo: photo, geometry: .identity, mode: .full))
        #expect(abs(result.angle - target.angle) < 0.08)
        #expect(abs(result.vertical - target.vertical) < 0.8)
        #expect(abs(result.horizontal - target.horizontal) < 0.8)
    }

    @Test func levelReplacesExistingPerspectiveAndUsesBothFamilies() throws {
        let result = try #require(UprightSolver.solve(lines: grid(Geometry(angle: -12)), photo: photo,
                                                      geometry: Geometry(angle: 30, vertical: 80, horizontal: -60), mode: .level))
        #expect(abs(result.angle + 12) < 0.05)
        #expect(result.vertical == 0 && result.horizontal == 0)
    }

    @Test func verticalWithMirrorAndOddTurnSolvesThePreTurnHorizontalAxis() throws {
        let target = Geometry(angle: -6, horizontal: 38, quarterTurns: 1, flipped: true)
        let result = try #require(UprightSolver.solve(lines: grid(target, horizontal: false), photo: photo,
                                                      geometry: Geometry(quarterTurns: 1, flipped: true), mode: .vertical))
        #expect(result.quarterTurns == 1 && result.flipped)
        #expect(abs(result.angle - target.angle) < 0.08)
        #expect(result.vertical == 0)
        #expect(abs(result.horizontal - target.horizontal) < 0.8)
    }

    @Test func autoOnlyCorrectsPerspectiveWithDistributedEvidence() throws {
        let both = Geometry(angle: -4, vertical: 25, horizontal: -22)
        let balanced = try #require(UprightSolver.solve(lines: grid(both), photo: photo, geometry: .identity, mode: .auto))
        #expect(abs(balanced.angle - both.angle) < 0.12)
        #expect(abs(balanced.vertical - both.vertical) < 1.5 && abs(balanced.horizontal - both.horizontal) < 1.5)
        let target = Geometry(angle: 5, vertical: 30)
        var lines = grid(target, horizontal: false)
        // A single horizontal edge cannot establish horizontal convergence.
        lines += grid(target, vertical: false).prefix(1)
        let result = try #require(UprightSolver.solve(lines: lines, photo: photo, geometry: .identity, mode: .auto))
        #expect(abs(result.angle - target.angle) < 0.12)
        #expect(abs(result.vertical - target.vertical) < 1.5)
        #expect(result.horizontal == 0)
        let excessive = Geometry(angle: 3, vertical: 28, horizontal: 100)
        let conservative = try #require(UprightSolver.solve(lines: grid(excessive), photo: photo, geometry: .identity, mode: .auto))
        #expect(conservative.horizontal == 0, "Auto discards a vanishing point requiring the slider stop")
    }

    @Test func insufficientAndDegenerateLinesFail() {
        #expect(UprightSolver.solve(lines: [], photo: photo, geometry: .identity, mode: .auto) == nil)
        let oneFamily = grid(Geometry(angle: 4), horizontal: false)
        #expect(UprightSolver.solve(lines: oneFamily, photo: photo, geometry: .identity, mode: .full) == nil)
        #expect(UprightSolver.solve(lines: Array(repeating: oneFamily[0], count: 8), photo: photo, geometry: .identity, mode: .vertical) == nil)
    }

    @Test func absoluteSolutionIsIdempotentAndRecentresTheExistingCrop() throws {
        let target = Geometry(angle: 8, vertical: -28, horizontal: 22, quarterTurns: 3, flipped: true)
        let lines = grid(target)
        let old = Geometry(angle: -30, vertical: 70, quarterTurns: 3, flipped: true, aspect: .free,
                           crop: CropRect(centreX: 0.1, centreY: -0.08, width: 0.6, height: 0.5))
        let once = try #require(UprightSolver.solve(lines: lines, photo: photo, geometry: old, mode: .full))
        let twice = try #require(UprightSolver.solve(lines: lines, photo: photo, geometry: once, mode: .full))
        #expect(abs(once.angle - target.angle) < 0.08)
        #expect(abs(once.vertical - target.vertical) < 0.8 && abs(once.horizontal - target.horizontal) < 0.8)
        #expect(once == twice)
        let crop = try #require(once.crop)
        #expect(crop.centreX == 0 && crop.centreY == 0 && once.aspect == .free)
        #expect(abs(crop.width / crop.height - 1.2) < 1e-9)
        #expect(once.cropRect(for: photo).corners.allSatisfy { Geometry.contains(once.quad(for: photo), $0) })
        #expect(UprightSolver.solve(lines: lines, photo: photo, geometry: target, mode: .full)?.crop == nil)
    }
}
